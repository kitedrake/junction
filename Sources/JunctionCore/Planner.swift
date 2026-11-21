import Foundation

// Turns the graph into what the router builds. Every node that receives cables (a "sink") becomes one private
// aggregate device: the sink's device first (it is the clock), then every source device, then one process tap per
// app/system-audio source. Core Audio keeps the clocks in step (drift compensation), so the render callback only
// copies channels with gains.

public struct RoutingPlan: Equatable, Sendable {
    public var sinks: [SinkPlan] = []
    /// Problems to show on nodes (not available, sample-rate mismatch, would feed back…).
    public var issues: [UUID: [String]] = [:]
    /// Cables that exist but carry nothing right now.
    public var idleCables: Set<UUID> = []

    public init() {}

    mutating func note(_ node: UUID, _ message: String) {
        if !(issues[node] ?? []).contains(message) { issues[node, default: []].append(message) }
    }
}

public struct SinkPlan: Equatable, Sendable, Identifiable {
    public var sinkNode: UUID
    public var name: String
    public var sinkUID: String
    public var sinkOutputChannels: Int
    public var subDevices: [SubDevice]
    public var taps: [TapPlan]
    public var routes: [Route]
    public var masterGain: Float
    /// Input channels the aggregate should have: all sub-devices' inputs, then two per tap.
    public var inputChannels: Int
    /// Output channels the aggregate should have: the sink's first, then other sub-devices' outputs.
    public var outputChannels: Int

    public var id: UUID { sinkNode }

    /// Everything that needs a rebuild when it changes (gains don't).
    public var structureKey: String {
        let devices = subDevices.map { "\($0.uid):\($0.inputChannels):\($0.outputChannels)@\($0.sampleRate)" }
            .joined(separator: ",")
        let tapKeys = taps.map { "\($0.node.uuidString):\($0.mode):\($0.mutesOriginal)" }.joined(separator: ",")
        let routeKeys = routes.map { "\($0.input)>\($0.output)" }.joined(separator: ",")
        return "\(sinkUID)|\(devices)|\(tapKeys)|\(routeKeys)"
    }
}

public struct SubDevice: Equatable, Sendable {
    public var uid: String
    public var inputChannels: Int
    public var outputChannels: Int
    /// Part of the structure: an aggregate is rebuilt when one of its devices changes rate.
    public var sampleRate: Double
}

public enum TapMode: Equatable, Sendable, CustomStringConvertible {
    /// Only these apps (bundle IDs).
    case only([String])
    /// Every app except these (Junction itself is always left out).
    case allExcept([String])

    public var description: String {
        switch self {
        case .only(let ids): "only[\(ids.joined(separator: ";"))]"
        case .allExcept(let ids): "except[\(ids.joined(separator: ";"))]"
        }
    }
}

public struct TapPlan: Equatable, Sendable {
    public var node: UUID
    public var name: String
    public var mode: TapMode
    public var mutesOriginal: Bool
}

public struct Route: Equatable, Sendable {
    public var cable: UUID
    public var source: PortRef
    /// Channel index in the aggregate's input.
    public var input: Int
    /// Channel index in the sink's output.
    public var output: Int
    public var gain: Float
}

public enum Planner {
    public static func plan(_ graph: Graph, inventory: Inventory) -> RoutingPlan {
        var plan = RoutingPlan()
        let info = NodeInfo(graph: graph, inventory: inventory)
        guard graph.isRoutingOn else {
            plan.idleCables = Set(graph.cables.map(\.id))
            return plan
        }
        let loopbacks = Set(inventory.devices.filter(\.isJunction).map(\.uid))
        var feeds: [String: Set<String>] = [:]  // loopback device → loopback devices it is routed into

        func reaches(_ start: String, _ target: String) -> Bool {
            var seen: Set<String> = [], stack = [start]
            while let uid = stack.popLast() {
                if uid == target { return true }
                guard seen.insert(uid).inserted else { continue }
                stack.append(contentsOf: feeds[uid] ?? [])
            }
            return false
        }

        for sink in graph.nodes {
            let cables = graph.cables.filter { $0.to.node == sink.id }
            guard !cables.isEmpty else { continue }
            guard let sinkUID = info.deviceUID(sink), let sinkDevice = inventory.device(sinkUID), sinkDevice.outputChannels > 0
            else {
                plan.note(sink.id, unavailableReason(sink, graph: graph, inventory: inventory))
                plan.idleCables.formUnion(cables.map(\.id))
                continue
            }
            var subDevices = [SubDevice(uid: sinkUID, inputChannels: sinkDevice.inputChannels,
                                        outputChannels: sinkDevice.outputChannels, sampleRate: sinkDevice.sampleRate)]
            var taps: [TapPlan] = []
            enum Origin { case device(String), tap(Int) }
            var pending: [(cable: Cable, origin: Origin, gain: Float)] = []

            for cable in cables {
                guard let source = graph.node(cable.from.node), cable.to.channel < sinkDevice.outputChannels else {
                    plan.idleCables.insert(cable.id)
                    continue
                }
                let gain = source.isMuted ? 0 : Gain.linear(source.gainDB) * Gain.linear(cable.gainDB)
                switch source.kind {
                case .application(let app):
                    guard cable.from.channel < 2 else { plan.idleCables.insert(cable.id); continue }
                    let index = tapIndex(&taps, source, name: app.name, mode: .only([app.bundleID]))
                    pending.append((cable, .tap(index), gain))
                case .systemAudio(let excluded):
                    guard cable.from.channel < 2 else { plan.idleCables.insert(cable.id); continue }
                    let index = tapIndex(&taps, source, name: "System Audio", mode: .allExcept(excluded.map(\.bundleID)))
                    pending.append((cable, .tap(index), gain))
                default:
                    guard let uid = info.deviceUID(source), let device = inventory.device(uid),
                          cable.from.channel < device.inputChannels
                    else {
                        plan.note(source.id, unavailableReason(source, graph: graph, inventory: inventory))
                        plan.idleCables.insert(cable.id)
                        continue
                    }
                    if loopbacks.contains(uid), loopbacks.contains(sinkUID) {
                        if uid == sinkUID || reaches(sinkUID, uid) {
                            plan.note(sink.id, "A cable into \(info.title(sink)) would feed its own audio back into it, so it is not used.")
                            plan.idleCables.insert(cable.id)
                            continue
                        }
                        feeds[uid, default: []].insert(sinkUID)
                    }
                    if !subDevices.contains(where: { $0.uid == uid }) {
                        subDevices.append(SubDevice(uid: uid, inputChannels: device.inputChannels,
                                                    outputChannels: device.outputChannels, sampleRate: device.sampleRate))
                    }
                    if device.sampleRate != sinkDevice.sampleRate {
                        plan.note(source.id, "Runs at \(kHz(device.sampleRate)) while \(info.title(sink)) runs at \(kHz(sinkDevice.sampleRate)). Set both to the same rate in Audio MIDI Setup for the best quality.")
                    }
                    pending.append((cable, .device(uid), gain))
                }
            }

            var offsets: [String: Int] = [:]
            var total = 0
            for device in subDevices {
                offsets[device.uid] = total
                total += device.inputChannels
            }
            let tapBase = total
            let routes = pending.map { item -> Route in
                let input = switch item.origin {
                case .device(let uid): offsets[uid]! + item.cable.from.channel
                case .tap(let index): tapBase + index * 2 + item.cable.from.channel
                }
                return Route(cable: item.cable.id, source: item.cable.from, input: input, output: item.cable.to.channel, gain: item.gain)
            }
            guard !routes.isEmpty else { continue }
            plan.sinks.append(SinkPlan(
                sinkNode: sink.id, name: info.title(sink), sinkUID: sinkUID, sinkOutputChannels: sinkDevice.outputChannels,
                subDevices: subDevices, taps: taps, routes: routes,
                masterGain: sink.isMuted ? 0 : Gain.linear(sink.gainDB),
                inputChannels: tapBase + taps.count * 2,
                outputChannels: subDevices.reduce(0) { $0 + $1.outputChannels }))
        }
        return plan
    }

    private static func tapIndex(_ taps: inout [TapPlan], _ node: Node, name: String, mode: TapMode) -> Int {
        if let index = taps.firstIndex(where: { $0.node == node.id }) { return index }
        taps.append(TapPlan(node: node.id, name: name, mode: mode, mutesOriginal: node.mutesOriginal))
        return taps.count - 1
    }

    static func unavailableReason(_ node: Node, graph: Graph, inventory: Inventory) -> String {
        switch node.kind {
        case .virtualDevice(let id):
            guard let device = graph.virtualDevice(id) else { return "This virtual device was deleted." }
            if !device.isEnabled { return "\(device.name) is turned off." }
            if !inventory.driver.isInstalled { return "The Junction driver isn't installed, so \(device.name) doesn't exist yet." }
            return "\(device.name) isn't available yet. If it doesn't appear, reinstall the driver."
        case .device(let ref): return "\(ref.name) isn't connected."
        case .defaultOutput: return "There is no output device."
        case .defaultInput: return "There is no input device."
        case .application, .systemAudio: return ""
        }
    }

    private static func kHz(_ rate: Double) -> String {
        let value = rate / 1000
        return value == value.rounded() ? "\(Int(value)) kHz" : String(format: "%.1f kHz", value)
    }
}

/// Edit-time rules for new cables.
public enum Rules {
    public enum Problem: Equatable, Sendable {
        case noSuchPort
        case alreadyConnected
        /// Neither end is the canvas's virtual device (or the ends are on different canvases).
        case bypassesDevice
        case feedback

        public var message: String {
            switch self {
            case .noSuchPort: "There is no such channel."
            case .alreadyConnected: "These channels are already connected."
            case .bypassesDevice: "Connect sources into the virtual device, and the virtual device out to outputs."
            case .feedback: "That would feed a virtual device's audio back into itself."
            }
        }
    }

    /// Whether a cable from `from` (an output channel) to `to` (an input channel) is allowed.
    public static func check(from: PortRef, to: PortRef, graph: Graph, inventory: Inventory) -> Problem? {
        let info = NodeInfo(graph: graph, inventory: inventory)
        guard let source = graph.node(from.node), let target = graph.node(to.node),
              from.channel >= 0, to.channel >= 0,
              from.channel < info.ports(source).outputs, to.channel < info.ports(target).inputs
        else { return .noSuchPort }
        if graph.cables.contains(where: { $0.from == from && $0.to == to }) { return .alreadyConnected }
        // Each virtual device has its own canvas, and every cable runs into its device or out of it.
        guard let canvas = source.canvas, target.canvas == canvas else { return .bypassesDevice }
        let fromDevice = source.kind == .virtualDevice(canvas), toDevice = target.kind == .virtualDevice(canvas)
        if fromDevice && toDevice { return .feedback }
        if !fromDevice && !toDevice { return .bypassesDevice }
        // Audio only passes through loopback nodes: Junction's virtual devices, a hardware node standing for one, or
        // Default Output/Input while Sound settings point at one. A path back to the source through them would ring
        // forever. (Sound settings can change later; the planner checks again with the devices of the moment.)
        func loopback(uid: String?) -> String? {
            guard let uid, let device = inventory.device(uid), device.isJunction else { return nil }
            return graph.virtualDevices.first { $0.uid == uid }.map { "vd:\($0.id)" } ?? "uid:\(uid)"
        }
        func loopback(_ node: Node) -> String? {
            switch node.kind {
            case .virtualDevice(let id): "vd:\(id)"
            case .device(let ref): loopback(uid: ref.uid)
            case .defaultOutput: loopback(uid: inventory.defaultOutputUID)
            case .defaultInput: loopback(uid: inventory.defaultInputUID)
            case .application, .systemAudio: nil
            }
        }
        guard let start = loopback(source), let end = loopback(target) else { return nil }
        if start == end { return .feedback }
        var edges: [String: Set<String>] = [:]
        for cable in graph.cables {
            guard let a = graph.node(cable.from.node).flatMap(loopback), let b = graph.node(cable.to.node).flatMap(loopback) else { continue }
            edges[a, default: []].insert(b)
        }
        var seen: Set<String> = [], stack = [end]
        while let key = stack.popLast() {
            if key == start { return .feedback }
            guard seen.insert(key).inserted else { continue }
            stack.append(contentsOf: edges[key] ?? [])
        }
        return nil
    }

    /// Moves a cable's input end to `port`, keeping its level and place, if a cable from its source to `port` would be
    /// allowed. Leaves the graph unchanged and returns the problem otherwise.
    public static func move(_ cable: UUID, to port: PortRef, in graph: inout Graph, inventory: Inventory) -> Problem? {
        guard let index = graph.cables.firstIndex(where: { $0.id == cable }) else { return .noSuchPort }
        var without = graph
        var moved = without.cables.remove(at: index)
        if let problem = check(from: moved.from, to: port, graph: without, inventory: inventory) { return problem }
        moved.to = port
        graph.cables[index] = moved
        return nil
    }

    /// Cables for a whole-node connection: output 1 → input 1, 2 → 2… (a mono source goes to both sides of a stereo
    /// input). Skips pairs that are already connected or not allowed.
    public static func busCables(from source: UUID, to target: UUID, graph: Graph, inventory: Inventory) -> [Cable] {
        let info = NodeInfo(graph: graph, inventory: inventory)
        guard let a = graph.node(source), let b = graph.node(target) else { return [] }
        let outs = info.ports(a).outputs, ins = info.ports(b).inputs
        guard outs > 0, ins > 0 else { return [] }
        let pairs: [(Int, Int)] = outs == 1 ? (0..<min(ins, 2)).map { (0, $0) } : (0..<min(outs, ins)).map { ($0, $0) }
        var result: [Cable] = []
        var working = graph
        for (o, i) in pairs {
            let from = PortRef(node: source, channel: o), to = PortRef(node: target, channel: i)
            guard check(from: from, to: to, graph: working, inventory: inventory) == nil else { continue }
            let cable = Cable(from: from, to: to)
            working.cables.append(cable)
            result.append(cable)
        }
        return result
    }
}
