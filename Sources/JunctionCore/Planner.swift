import Foundation

// Turns the graph into what the router builds. Every node that receives cables (a "sink") becomes one private
// aggregate device: the sink's device first (it is the clock), then every source device, then one process tap per
// app/system-audio source. Core Audio keeps the clocks in step (drift compensation), so the render callback only
// copies channels with gains; devices in the sink's clock domain (Junction's own devices share one) need none. A
// source device at another nominal sample rate stays out of the aggregate when the sink's conversion is Automatic:
// it runs on its own IOProc and the kernel converts it to the sink's rate. An "<app> through <device>" source reads
// the driver's per-app ring for that app (see Capture.swift) and is converted the same way, after the converted
// devices. Each source gets a slot of lanes (one per channel its cables use) after all of those channels: routes read
// the lanes, which carry the source's channels through its effect chain (or untouched while it has none), and the
// sink's own chain runs after the mix. Effects aren't part of a sink's structure: changing them swaps a chain.

public struct RoutingPlan: Equatable, Sendable {
    public var sinks: [SinkPlan] = []
    /// Problems to show on nodes (not available, sample-rate mismatch, would feed back…).
    public var issues: [UUID: [String]] = [:]
    /// Cables that exist but carry nothing right now.
    public var idleCables: Set<UUID> = []
    /// Device nodes whose audio is converted to or from another sample rate.
    public var conversions: [UUID: ConversionNote] = [:]

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
    /// IO buffer size to ask for, in frames (nil: macOS's default).
    public var bufferFrames: Int? = nil
    /// Input channels the aggregate should have: all sub-devices' inputs, then two per tap.
    public var inputChannels: Int
    /// Output channels the aggregate should have: the sink's first, then other sub-devices' outputs.
    public var outputChannels: Int
    /// Source devices running at another rate, converted to the sink's: they stay out of the aggregate and their
    /// channels follow its inputs (route inputs from `inputChannels` on), one device after another.
    public var converted: [SubDevice] = []
    /// Apps captured through a virtual device: their channels follow the converted devices', one after another.
    public var captures: [CapturePlan] = []
    /// One per source node, in the order of its first cable: the lanes routes read (from `laneBase` on), each carrying
    /// one input channel, and the effects that process them before the mix.
    public var slots: [EffectSlot] = []
    /// The sink node's effects, after the mix.
    public var effects: [Effect] = []

    /// The first lane: after the aggregate's inputs, the converted devices' and the captures' channels.
    public var laneBase: Int {
        inputChannels + converted.reduce(0) { $0 + $1.inputChannels } + captures.reduce(0) { $0 + $1.channels }
    }

    public var id: UUID { sinkNode }

    /// The sink's nominal sample rate: the aggregate's, and what converted devices are converted to.
    public var sampleRate: Double { subDevices.first?.sampleRate ?? 0 }

    /// Everything that needs a rebuild when it changes (gains don't), including which devices are converted.
    public var structureKey: String {
        func key(_ devices: [SubDevice]) -> String {
            devices.map { "\($0.uid):\($0.inputChannels):\($0.outputChannels)@\($0.sampleRate)\($0.sameClock ? "=" : "~")" }
                .joined(separator: ",")
        }
        let tapKeys = taps.map { "\($0.node.uuidString):\($0.mode):\($0.mutesOriginal)" }.joined(separator: ",")
        let routeKeys = routes.map { "\($0.input)>\($0.output)" }.joined(separator: ",")
        let captureKeys = captures.map(\.key).joined(separator: ",")
        let slotKeys = slots.map { $0.inputs.map(String.init).joined(separator: "+") }.joined(separator: ",")
        return "\(sinkUID)|\(key(subDevices))|\(tapKeys)|\(routeKeys)|\(bufferFrames ?? 0)|converted:\(key(converted))|captures:\(captureKeys)|slots:\(slotKeys)"
    }
}

/// A source's lanes in a sink and the effects on them.
public struct EffectSlot: Equatable, Sendable {
    public var node: UUID
    /// The input channel each lane carries (the source's channels its cables use, in order).
    public var inputs: [Int]
    public var effects: [Effect]
}

/// One app's audio read from the driver's per-app rings of one virtual device.
public struct CapturePlan: Equatable, Sendable {
    public var node: UUID
    public var name: String
    /// The virtual device the app plays into (its UID, not its companion's).
    public var deviceUID: String
    public var sampleRate: Double
    public var channels: Int
    /// The app's processes playing into it right now: a change rebuilds the sink.
    public var clients: [CaptureClientRef]
    /// The sink runs on the driver's clock too (it is one of Junction's devices): converted at the exact ratio.
    public var sameClock: Bool

    var key: String {
        let pids = clients.map { "\($0.pid)/\($0.bundleID)" }.joined(separator: ";")
        return "\(node.uuidString):\(deviceUID)@\(sampleRate):\(channels)\(sameClock ? "=" : "~"):\(pids)"
    }
}

/// A device node whose audio Junction converts between sample rates, for the canvas and the inspector.
public struct ConversionNote: Equatable, Sendable {
    /// The rate of the device the node stands for.
    public var deviceRate: Double
    /// The rate it is converted to (a source) or from (an output fed by its virtual device).
    public var otherRate: Double
    /// A source converted to its sink's rate; otherwise an output that receives converted audio.
    public var isSource: Bool

    public init(deviceRate: Double, otherRate: Double, isSource: Bool) {
        self.deviceRate = deviceRate
        self.otherRate = otherRate
        self.isSource = isSource
    }

    /// "44.1 kHz, converted to 48 kHz".
    public var text: String {
        "\(formatSampleRate(deviceRate)), converted \(isSource ? "to" : "from") \(formatSampleRate(otherRate))"
    }

    /// "44.1 → 48 kHz", where the longer text doesn't fit.
    public var shortText: String {
        let (from, to) = isSource ? (deviceRate, otherRate) : (otherRate, deviceRate)
        return "\(formatSampleRate(from, unit: false)) → \(formatSampleRate(to))"
    }
}

/// "48 kHz", "44.1 kHz" (or without the unit).
public func formatSampleRate(_ rate: Double, unit: Bool = true) -> String {
    let value = rate / 1000
    let number = value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    return unit ? number + " kHz" : number
}

public struct SubDevice: Equatable, Sendable {
    public var uid: String
    public var inputChannels: Int
    public var outputChannels: Int
    /// Part of the structure: an aggregate is rebuilt when one of its devices changes rate.
    public var sampleRate: Double
    /// In the sink's clock domain: joins the aggregate without drift compensation, or is converted at the exact
    /// nominal ratio.
    public var sameClock = false
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
    /// The lane the renderer reads: `input` after its source's effects (see `SinkPlan.slots`).
    public var lane: Int = 0
}

public enum Planner {
    public static func plan(_ graph: Graph, inventory: Inventory) -> RoutingPlan {
        var plan = RoutingPlan()
        let info = NodeInfo(graph: graph, inventory: inventory)
        guard graph.isRoutingOn else {
            plan.idleCables = Set(graph.cables.map(\.id))
            return plan
        }
        // A virtual device and its hidden companion are one loopback: the loop guard counts them as one.
        let loopbacks = Set(inventory.devices.filter(\.isJunction).map(\.uid))
        func loopback(_ uid: String) -> String {
            uid.hasSuffix(VirtualDevice.companionSuffix) && loopbacks.contains(uid)
                ? String(uid.dropLast(VirtualDevice.companionSuffix.count)) : uid
        }
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
            guard let sinkUID = info.feedUID(sink), let sinkDevice = inventory.device(sinkUID), sinkDevice.outputChannels > 0
            else {
                plan.note(sink.id, unavailableReason(sink, graph: graph, inventory: inventory))
                plan.idleCables.formUnion(cables.map(\.id))
                continue
            }
            var subDevices = [SubDevice(uid: sinkUID, inputChannels: sinkDevice.inputChannels,
                                        outputChannels: sinkDevice.outputChannels, sampleRate: sinkDevice.sampleRate,
                                        sameClock: true)]
            var taps: [TapPlan] = []
            var converted: [SubDevice] = []
            var captures: [CapturePlan] = []
            enum Origin { case device(String), tap(Int), converted(String), capture(Int) }
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
                case .appThroughDevice(let app, let deviceID):
                    guard let virtual = graph.virtualDevice(deviceID), virtual.isEnabled,
                          let device = inventory.device(virtual.uid), cable.from.channel < info.ports(source).outputs
                    else {
                        plan.note(source.id, unavailableReason(source, graph: graph, inventory: inventory))
                        plan.idleCables.insert(cable.id)
                        continue
                    }
                    // The app's audio passes through its device: the same loop guard as the device's own audio.
                    if loopbacks.contains(sinkUID) {
                        let from = loopback(virtual.uid), into = loopback(sinkUID)
                        if from == into || reaches(into, from) {
                            plan.note(sink.id, "A cable into \(info.title(sink)) would feed its own audio back into it, so it is not used.")
                            plan.idleCables.insert(cable.id)
                            continue
                        }
                        feeds[from, default: []].insert(into)
                    }
                    let clients = inventory.clients(of: app.bundleID, through: virtual)
                    guard !clients.isEmpty else {
                        plan.idleCables.insert(cable.id)  // not playing into it right now
                        continue
                    }
                    let index: Int
                    if let existing = captures.firstIndex(where: { $0.node == source.id }) {
                        index = existing
                    } else {
                        captures.append(CapturePlan(
                            node: source.id, name: info.title(source), deviceUID: virtual.uid, sampleRate: device.sampleRate,
                            channels: info.ports(source).outputs,
                            clients: clients.map { CaptureClientRef(pid: $0.pid, bundleID: $0.bundleID) },
                            sameClock: device.sharesClock(with: sinkDevice)))
                        index = captures.count - 1
                    }
                    pending.append((cable, .capture(index), gain))
                default:
                    guard let uid = info.returnUID(source), let device = inventory.device(uid),
                          cable.from.channel < device.inputChannels
                    else {
                        plan.note(source.id, unavailableReason(source, graph: graph, inventory: inventory))
                        plan.idleCables.insert(cable.id)
                        continue
                    }
                    if loopbacks.contains(uid), loopbacks.contains(sinkUID) {
                        let from = loopback(uid), into = loopback(sinkUID)
                        if from == into || reaches(into, from) {
                            plan.note(sink.id, "A cable into \(info.title(sink)) would feed its own audio back into it, so it is not used.")
                            plan.idleCables.insert(cable.id)
                            continue
                        }
                        feeds[from, default: []].insert(into)
                    }
                    let sameClock = device.sharesClock(with: sinkDevice)
                    let mismatched = device.sampleRate != sinkDevice.sampleRate && device.sampleRate > 0 && sinkDevice.sampleRate > 0
                    if mismatched, sink.rateConversion == .automatic {
                        if !converted.contains(where: { $0.uid == uid }) {
                            converted.append(SubDevice(uid: uid, inputChannels: device.inputChannels,
                                                       outputChannels: device.outputChannels, sampleRate: device.sampleRate,
                                                       sameClock: sameClock))
                        }
                        // A source is converted to its sink's rate; an output fed by its virtual device shows the
                        // conversion on itself (the virtual device has more than one output).
                        if case .virtualDevice = source.kind, !isVirtualDevice(sink) {
                            plan.conversions[sink.id] = ConversionNote(deviceRate: sinkDevice.sampleRate,
                                                                       otherRate: device.sampleRate, isSource: false)
                        } else {
                            plan.conversions[source.id] = ConversionNote(deviceRate: device.sampleRate,
                                                                         otherRate: sinkDevice.sampleRate, isSource: true)
                        }
                        pending.append((cable, .converted(uid), gain))
                        continue
                    }
                    if !subDevices.contains(where: { $0.uid == uid }) {
                        subDevices.append(SubDevice(uid: uid, inputChannels: device.inputChannels,
                                                    outputChannels: device.outputChannels, sampleRate: device.sampleRate,
                                                    sameClock: sameClock))
                    }
                    if mismatched {
                        plan.note(source.id, "Runs at \(formatSampleRate(device.sampleRate)) while \(info.title(sink)) runs at \(formatSampleRate(sinkDevice.sampleRate)), and sample-rate conversion is off. Set both to the same rate in Audio MIDI Setup, or turn conversion back to Automatic in \(info.title(sink))'s inspector.")
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
            let inputChannels = tapBase + taps.count * 2
            var convertedOffsets: [String: Int] = [:]
            total = inputChannels
            for device in converted {
                convertedOffsets[device.uid] = total
                total += device.inputChannels
            }
            var captureOffsets: [Int] = []
            for capture in captures {
                captureOffsets.append(total)
                total += capture.channels
            }
            var routes = pending.map { item -> Route in
                let input = switch item.origin {
                case .device(let uid): offsets[uid]! + item.cable.from.channel
                case .tap(let index): tapBase + index * 2 + item.cable.from.channel
                case .converted(let uid): convertedOffsets[uid]! + item.cable.from.channel
                case .capture(let index): captureOffsets[index] + item.cable.from.channel
                }
                return Route(cable: item.cable.id, source: item.cable.from, input: input, output: item.cable.to.channel, gain: item.gain)
            }
            guard !routes.isEmpty else { continue }
            // A slot per source node: a lane per channel its cables use. The virtual device's own effects run in its
            // own sink, after the mix, so as a source into outputs it has none here.
            var slots: [EffectSlot] = []
            var laneOf: [PortRef: Int] = [:]
            var lane = total
            var sourceNodes: [UUID] = []
            for route in routes where !sourceNodes.contains(route.source.node) { sourceNodes.append(route.source.node) }
            for node in sourceNodes {
                let used = routes.filter { $0.source.node == node }
                let channels = Set(used.map(\.source.channel)).sorted()
                var inputs: [Int] = []
                for channel in channels {
                    laneOf[PortRef(node: node, channel: channel)] = lane
                    inputs.append(used.first { $0.source.channel == channel }!.input)
                    lane += 1
                }
                let source = graph.node(node)
                let isDevice = if case .virtualDevice = source?.kind { true } else { false }
                slots.append(EffectSlot(node: node, inputs: inputs, effects: isDevice ? [] : source?.effects ?? []))
            }
            for index in routes.indices { routes[index].lane = laneOf[routes[index].source]! }
            plan.sinks.append(SinkPlan(
                sinkNode: sink.id, name: info.title(sink), sinkUID: sinkUID, sinkOutputChannels: sinkDevice.outputChannels,
                subDevices: subDevices, taps: taps, routes: routes,
                masterGain: sink.isMuted ? 0 : Gain.linear(sink.gainDB), bufferFrames: sink.bufferFrames,
                inputChannels: inputChannels,
                outputChannels: subDevices.reduce(0) { $0 + $1.outputChannels }, converted: converted,
                captures: captures, slots: slots, effects: sink.effects))
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
        case .appThroughDevice(let app, let id):
            guard let device = graph.virtualDevice(id) else { return "This virtual device was deleted." }
            if !device.isEnabled { return "\(device.name) is turned off." }
            if !inventory.driver.isInstalled { return "The Junction driver isn't installed, so \(device.name) doesn't exist yet." }
            if inventory.device(device.uid) == nil { return "\(device.name) isn't available yet." }
            return "\(app.name) isn't playing into \(device.name) right now."
        }
    }

    private static func isVirtualDevice(_ node: Node) -> Bool {
        if case .virtualDevice = node.kind { return true }
        return false
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
            case .appThroughDevice(_, let device): "vd:\(device)"  // the device's own audio, one app of it
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
