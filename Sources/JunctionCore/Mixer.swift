import Foundation

// The mixer: another view of one virtual device's canvas, a channel strip per source, the device and each output.
// It has no state of its own: a strip's fader and mute are its node's level and mute, its pan the levels of the
// node's cables into (or out of) the device's first two channels, and its effects the node's chain. So the mixer
// and the canvas always edit the same graph.
//
// Each device can also have a headphone monitor (`MonitorMix`): another output, fed from the device's sources with
// its own levels, that the planner adds as one more sink. Solo/listen on a port sends just that port to the monitor
// instead; the device's own mix and every other sink stay as they are.

/// Where a monitor plays.
public enum MonitorOutput: Codable, Hashable, Sendable {
    /// A hardware device (headphones, an interface's outputs).
    case device(DeviceRef)
    /// Whatever device macOS currently uses for output.
    case defaultOutput

    /// The node kind the planner gives the monitor's sink (it is never put on a canvas).
    public var kind: NodeKind {
        switch self {
        case .device(let ref): .device(ref)
        case .defaultOutput: .defaultOutput
        }
    }
}

/// One source's level in a monitor.
public struct MonitorSend: Codable, Hashable, Sendable {
    public var node: UUID
    public var gainDB: Double
    public var isOn: Bool

    public init(node: UUID, gainDB: Double = 0, isOn: Bool = true) {
        self.node = node
        self.gainDB = gainDB
        self.isOn = isOn
    }
}

/// A headphone monitor of one virtual device: what its sources sound like, at levels of its own, on an output of
/// its own. It hears each source as it is cabled into the device (the same channels and pan) but before the source's
/// fader, mute and effects, so turning the stream's mic down doesn't take it out of your headphones. Sources without
/// a send of their own are heard at 0 dB.
public struct MonitorMix: Codable, Identifiable, Hashable, Sendable {
    /// Also the ID the router builds the monitor's sink under (its status and meters).
    public var id: UUID
    /// The virtual device whose canvas it monitors.
    public var device: UUID
    /// Where it plays (nil: nowhere yet).
    public var output: MonitorOutput?
    public var gainDB: Double
    public var isMuted: Bool
    public var sends: [MonitorSend]
    /// Solo/listen: ports sent to the monitor instead of its mix (a source's or the device's output channels, an
    /// output's input channels). Cleared when a saved graph is loaded.
    public var listening: [PortRef]

    public init(id: UUID = UUID(), device: UUID, output: MonitorOutput? = nil, gainDB: Double = 0, isMuted: Bool = false,
                sends: [MonitorSend] = [], listening: [PortRef] = []) {
        self.id = id
        self.device = device
        self.output = output
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.sends = sends
        self.listening = listening
    }

    /// A source's send (0 dB and on unless changed).
    public func send(_ node: UUID) -> MonitorSend { sends.first { $0.node == node } ?? MonitorSend(node: node) }

    public mutating func setSend(_ send: MonitorSend) {
        if let index = sends.firstIndex(where: { $0.node == send.node }) { sends[index] = send } else { sends.append(send) }
    }

    public func isListening(to node: UUID) -> Bool { listening.contains { $0.node == node } }
    public func isListening(to port: PortRef) -> Bool { listening.contains(port) }

    /// Starts or stops listening to one port.
    public mutating func toggleListening(_ port: PortRef) {
        if let index = listening.firstIndex(of: port) { listening.remove(at: index) } else { listening.append(port) }
    }
}

/// What a strip stands for on its canvas.
public enum StripRole: Sendable {
    case source, device, output
}

/// One channel strip of the mixer.
public struct MixerStrip: Identifiable, Equatable, Sendable {
    public var node: UUID
    public var role: StripRole
    /// The ports solo/listen sends to the monitor: a source's or the device's output channels, an output's inputs.
    public var ports: [PortRef]
    /// Whether the routing has a left and a right to balance (see `Mixer.pan`).
    public var hasPan: Bool
    public var id: UUID { node }
}

public enum Mixer {
    /// The strips of a canvas: its sources (top to bottom, as on the canvas), the device, then its outputs. Nodes not
    /// wired to the device yet count by their sides: something with outputs only is a source.
    public static func strips(on canvas: UUID, graph: Graph, inventory: Inventory) -> [MixerStrip] {
        guard let device = graph.deviceNode(canvas) else { return [] }
        let info = NodeInfo(graph: graph, inventory: inventory)
        var sources: [Node] = [], outputs: [Node] = []
        for node in graph.nodes(on: canvas) where node.id != device.id {
            switch role(of: node, device: device, graph: graph, info: info) {
            case .source: sources.append(node)
            case .output: outputs.append(node)
            case .device: break
            }
        }
        func byPlace(_ a: Node, _ b: Node) -> Bool { (a.y, a.x) < (b.y, b.x) }
        func strip(_ node: Node, _ role: StripRole) -> MixerStrip {
            let ports = info.ports(node)
            let channels = role == .output ? ports.inputs : ports.outputs
            return MixerStrip(node: node.id, role: role,
                              ports: (0..<channels).map { PortRef(node: node.id, channel: $0) },
                              hasPan: role != .device && panCables(node.id, graph: graph) != nil)
        }
        return sources.sorted(by: byPlace).map { strip($0, .source) } + [strip(device, .device)]
            + outputs.sorted(by: byPlace).map { strip($0, .output) }
    }

    static func role(of node: Node, device: Node, graph: Graph, info: NodeInfo) -> StripRole {
        if node.id == device.id { return .device }
        if graph.cables.contains(where: { $0.from.node == node.id && $0.to.node == device.id }) { return .source }
        if graph.cables.contains(where: { $0.from.node == device.id && $0.to.node == node.id }) { return .output }
        let ports = info.ports(node)
        return ports.outputs > 0 && ports.inputs == 0 ? .source : .output
    }

    /// The cables a strip's pan balances: a source's cables into the device's channels 1 and 2, or an output's cables
    /// arriving at its own channels 1 and 2. Nil unless there are some on both sides.
    public static func panCables(_ node: UUID, graph: Graph) -> (left: [Cable], right: [Cable])? {
        guard let canvas = graph.node(node)?.canvas, let device = graph.deviceNode(canvas), device.id != node else { return nil }
        let cables: [Cable]
        if graph.cables.contains(where: { $0.from.node == node && $0.to.node == device.id }) {
            cables = graph.cables.filter { $0.from.node == node && $0.to.node == device.id }
        } else {
            cables = graph.cables.filter { $0.from.node == device.id && $0.to.node == node }
        }
        let left = cables.filter { $0.to.channel == 0 }, right = cables.filter { $0.to.channel == 1 }
        return left.isEmpty || right.isEmpty ? nil : (left, right)
    }

    /// A strip's pan, from −1 (left) to 1 (right): how much quieter one side's cables are than the other's (nil
    /// without a left and a right).
    public static func pan(_ node: UUID, graph: Graph) -> Double? {
        guard let (left, right) = panCables(node, graph: graph) else { return nil }
        let l = Double(Gain.linear(left.map(\.gainDB).max()!)), r = Double(Gain.linear(right.map(\.gainDB).max()!))
        if l == r { return 0 }
        return l > r ? -(1 - r / l) : 1 - l / r
    }

    /// Pans a strip by setting the levels of its cables: the louder side keeps its level, the other side is turned
    /// down by the pan (all the way at ±1). Does nothing without a left and a right.
    public static func setPan(_ pan: Double, of node: UUID, in graph: inout Graph) {
        guard let (left, right) = panCables(node, graph: graph) else { return }
        let pan = min(1, max(-1, pan))
        let base = max(left.map(\.gainDB).max()!, right.map(\.gainDB).max()!)
        func level(_ keep: Double) -> Double {
            keep <= 0 ? Gain.floorDB : max(Gain.floorDB, base + 20 * log10(keep))
        }
        let leftDB = level(pan > 0 ? 1 - pan : 1), rightDB = level(pan < 0 ? 1 + pan : 1)
        let lefts = Set(left.map(\.id)), rights = Set(right.map(\.id))
        for index in graph.cables.indices {
            if lefts.contains(graph.cables[index].id) { graph.cables[index].gainDB = leftDB }
            if rights.contains(graph.cables[index].id) { graph.cables[index].gainDB = rightDB }
        }
    }

    /// "C", "L 30", "R 100".
    public static func panText(_ pan: Double) -> String {
        let amount = Int((abs(pan) * 100).rounded())
        return amount == 0 ? "C" : (pan < 0 ? "L \(amount)" : "R \(amount)")
    }

    /// Solo on a strip: listens to all of its ports, or stops when it already listens to any of them.
    public static func toggleSolo(_ strip: MixerStrip, in monitor: inout MonitorMix) {
        if monitor.isListening(to: strip.node) {
            monitor.listening.removeAll { $0.node == strip.node }
        } else {
            monitor.listening += strip.ports
        }
    }

    /// The monitor's channels (2 for a stereo output; what the device has, at most 2, when it is gone).
    static func channels(_ output: MonitorOutput, inventory: Inventory) -> Int {
        let uid: String? = switch output {
        case .device(let ref): ref.uid
        case .defaultOutput: inventory.defaultOutputUID
        }
        let count = inventory.device(uid)?.outputChannels ?? 2
        return min(max(count, 1), 2)
    }

    /// What the planner builds for a monitor: a sink node standing for its output (with the monitor's ID, level and
    /// mute) and cables into it. Solo/listen replaces the mix with the listened ports at 0 dB: a single channel goes
    /// to both sides, several go left, right, left… An output's port is what arrives at it (the device's channels its
    /// cables carry, at their levels and the output's). Nil when it plays nowhere or has nothing to play.
    public static func monitorSink(_ monitor: MonitorMix, graph: Graph, inventory: Inventory) -> (sink: Node, cables: [Cable])? {
        guard let output = monitor.output, let device = graph.deviceNode(monitor.device) else { return nil }
        let sink = Node(id: monitor.id, kind: output.kind, gainDB: monitor.gainDB, isMuted: monitor.isMuted,
                        canvas: monitor.device)
        let channels = channels(output, inventory: inventory)
        var pairs: [(from: PortRef, to: Int, gainDB: Double)] = []
        let info = NodeInfo(graph: graph, inventory: inventory)
        if !monitor.listening.isEmpty {
            var heard: [(PortRef, Double)] = []
            for port in monitor.listening {
                guard let node = graph.node(port.node), node.canvas == monitor.device else { continue }
                if role(of: node, device: device, graph: graph, info: info) == .output {
                    guard !node.isMuted else { continue }
                    for cable in graph.cables where cable.from.node == device.id && cable.to == port {
                        heard.append((cable.from, cable.gainDB + node.gainDB))
                    }
                } else if port.channel < info.ports(node).outputs {
                    heard.append((port, 0))
                }
            }
            if heard.count == 1 {
                pairs = (0..<channels).map { (heard[0].0, $0, heard[0].1) }
            } else {
                pairs = heard.enumerated().map { ($0.element.0, $0.offset % channels, $0.element.1) }
            }
        } else {
            for cable in graph.cables where cable.to.node == device.id {
                let send = monitor.send(cable.from.node)
                guard send.isOn, graph.node(cable.from.node)?.canvas == monitor.device else { continue }
                pairs.append((cable.from, cable.to.channel % channels, cable.gainDB + send.gainDB))
            }
        }
        guard !pairs.isEmpty else { return nil }
        let cables = pairs.enumerated().map { index, pair in
            Cable(id: derivedID(monitor.id, index), from: pair.from, to: PortRef(node: monitor.id, channel: pair.to),
                  gainDB: pair.gainDB)
        }
        return (sink, cables)
    }

    /// A stable ID for the `index`th cable of a monitor, so the same graph always plans the same.
    static func derivedID(_ base: UUID, _ index: Int) -> UUID {
        var bytes = base.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            var value = UInt32(truncatingIfNeeded: index + 1)
            for offset in 12..<16 {
                raw[offset] ^= UInt8(value & 0xFF)
                value >>= 8
            }
        }
        return UUID(uuid: bytes)
    }
}

extension Rules {
    /// Whether a monitor may play into an output: never into one of Junction's own devices (Default Output while it
    /// points at one included), so a monitor can't feed anything back into a device. The planner checks the same with
    /// the devices of the moment.
    public static func monitorProblem(_ output: MonitorOutput, inventory: Inventory) -> Problem? {
        let uid: String? = switch output {
        case .device(let ref): ref.uid
        case .defaultOutput: inventory.defaultOutputUID
        }
        guard let uid else { return nil }
        if uid.hasPrefix("junction.") || inventory.device(uid)?.isJunction == true { return .monitorFeedback }
        return nil
    }
}

extension Graph {
    /// A virtual device's monitor, if it has one.
    public func monitor(for device: UUID) -> MonitorMix? { monitors.first { $0.device == device } }

    /// Drops monitor sends and solo/listen ports of nodes that are gone (sends a scene still holds stay).
    public mutating func pruneMonitors() {
        guard !monitors.isEmpty else { return }
        let current = Set(nodes.map(\.id)), held = current.union(scenes.flatMap(\.nodes).map(\.id))
        for index in monitors.indices {
            monitors[index].sends.removeAll { !held.contains($0.node) }
            monitors[index].listening.removeAll { !current.contains($0.node) }
        }
    }

    /// Changes a device's monitor, making one first if it has none.
    public mutating func updateMonitor(for device: UUID, _ change: (inout MonitorMix) -> Void) {
        guard virtualDevice(device) != nil else { return }
        if let index = monitors.firstIndex(where: { $0.device == device }) {
            change(&monitors[index])
        } else {
            var monitor = MonitorMix(device: device)
            change(&monitor)
            monitors.append(monitor)
        }
    }
}
