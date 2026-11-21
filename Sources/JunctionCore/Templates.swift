import Foundation

/// Podcast, "DAW into a call" and "Call into the DAW" (Stream Without Chat is in Store.swift).
extension Templates {
    /// Music apps people usually want to send into a call or record a call into.
    public static let dawApps: [AppRef] = [
        AppRef(bundleID: "com.apple.logic10", name: "Logic Pro"),
        AppRef(bundleID: "com.apple.garageband10", name: "GarageBand"),
        AppRef(bundleID: "com.ableton.live", name: "Ableton Live"),
        AppRef(bundleID: "com.cockos.reaper", name: "REAPER"),
        AppRef(bundleID: "com.bitwig.BitwigStudio", name: "Bitwig Studio"),
        AppRef(bundleID: "com.avid.ProTools", name: "Pro Tools"),
    ]

    /// One microphone for a template: an input channel of a device, or of whatever macOS uses for input.
    public struct Microphone: Hashable, Sendable {
        public var kind: NodeKind
        public var channel: Int

        public init(kind: NodeKind, channel: Int = 0) {
            self.kind = kind
            self.channel = channel
        }

        public static let defaultInput = Microphone(kind: .defaultInput)

        /// "Default Input", "MacBook Pro Microphone", "Scarlett 2i2, input 2".
        public func title(_ inventory: Inventory) -> String {
            let node = Node(kind: kind)
            let info = NodeInfo(graph: Graph(), inventory: inventory)
            let name = info.title(node)
            return info.ports(node).outputs > 1 && kind != .defaultInput ? "\(name), input \(channel + 1)" : name
        }
    }

    /// The microphones on offer: the default input, then every input channel of every input device.
    public static func microphones(_ inventory: Inventory) -> [Microphone] {
        [.defaultInput] + inventory.inputDevices.flatMap { device in
            (0..<device.inputChannels).map { Microphone(kind: .device(device.ref), channel: $0) }
        }
    }

    /// The two microphones a podcast starts with: the first two device inputs (the default input when there are fewer).
    public static func podcastMicrophones(_ inventory: Inventory) -> [Microphone] {
        let devices = microphones(inventory).dropFirst()
        return [devices.first ?? .defaultInput, devices.dropFirst().first ?? .defaultInput]
    }

    /// Apps offered for a template: apps using audio now, then the known apps that are installed and the apps the user
    /// picked. Each appears once; apps using audio come first, each group sorted by name.
    public static func appCandidates(usingAudio: [AppRef], installed: [AppRef], picked: [AppRef] = []) -> [AppRef] {
        chatCandidates(usingAudio: usingAudio, installedChatApps: installed, picked: picked)
    }

    /// The app a template starts with: the first candidate that is one of the known apps, else the first candidate.
    public static func likelyApp(in candidates: [AppRef], known: [AppRef]) -> AppRef? {
        let ids = Set(known.map(\.bundleID))
        return candidates.first { ids.contains($0.bundleID) } ?? candidates.first
    }

    /// "Podcast": each microphone and the call on a channel pair of their own in a recorder device (an input only,
    /// for a recording app): microphone 1 on channels 1–2, microphone 2 on 3–4, the call on the pair after them.
    /// Reuses (turns on and widens) a virtual device of that name. Returns the device.
    @discardableResult
    public static func podcast(_ graph: inout Graph, microphones: [Microphone], call: AppRef?,
                               deviceName: String = "Podcast") -> VirtualDevice {
        let pairs = microphones.count + (call == nil ? 0 : 1)
        var names: [String] = []
        for index in microphones.indices { names += Array(repeating: "Mic \(index + 1)", count: 2) }
        if call != nil { names += ["Call L", "Call R"] }
        let channels = VirtualDevice.channelChoices.first { $0 >= 2 * pairs } ?? 2 * pairs
        var builder = Builder(&graph, name: deviceName, channels: channels, names: names)
        for (index, microphone) in microphones.enumerated() {
            let node = builder.source(microphone.kind)
            builder.connect(node, microphone.channel, to: 2 * index)
            builder.connect(node, microphone.channel, to: 2 * index + 1)
        }
        if let call {
            let node = builder.source(.application(call))
            builder.connect(node, 0, to: 2 * microphones.count)
            builder.connect(node, 1, to: 2 * microphones.count + 1)
        }
        return builder.finish(into: &graph)
    }

    /// "DAW into a call": a microphone for the call app that carries what the music app plays (and, if given, your
    /// microphone on both channels). Reuses (and turns on) a virtual device of that name. Returns the device.
    @discardableResult
    public static func dawIntoCall(_ graph: inout Graph, daw: AppRef, microphone: Microphone?,
                                   deviceName: String = "DAW to Call") -> VirtualDevice {
        var builder = Builder(&graph, name: deviceName, channels: 2, names: microphone == nil ? ["DAW L", "DAW R"] : [])
        let music = builder.source(.application(daw))
        builder.connect(music, 0, to: 0)
        builder.connect(music, 1, to: 1)
        if let microphone {
            let node = builder.source(microphone.kind)
            builder.connect(node, microphone.channel, to: 0)
            builder.connect(node, microphone.channel, to: 1)
        }
        return builder.finish(into: &graph)
    }

    /// "Call into the DAW": a microphone for the music app that carries the call app's audio, to record or process it.
    /// Reuses (and turns on) a virtual device of that name. Returns the device.
    @discardableResult
    public static func callIntoDAW(_ graph: inout Graph, call: AppRef, deviceName: String = "Call to DAW") -> VirtualDevice {
        var builder = Builder(&graph, name: deviceName, channels: 2, names: ["Call L", "Call R"])
        let node = builder.source(.application(call))
        builder.connect(node, 0, to: 0)
        builder.connect(node, 1, to: 1)
        return builder.finish(into: &graph)
    }

    /// Puts a template's virtual device (an input only, under the microphone icon) on the graph and wires sources into
    /// it, below whatever its canvas already has.
    private struct Builder {
        var device: VirtualDevice
        var deviceNode: Node
        var nodes: [Node] = []
        var cables: [Cable] = []
        var nextY: Double

        init(_ graph: inout Graph, name: String, channels: Int, names: [String]) {
            if let index = graph.virtualDevices.firstIndex(where: { $0.name == name }) {
                graph.virtualDevices[index].isEnabled = true
                graph.virtualDevices[index].channels = max(graph.virtualDevices[index].channels, channels)
                if graph.virtualDevices[index].channelNames.isEmpty { graph.virtualDevices[index].channelNames = names }
                device = graph.virtualDevices[index]
            } else {
                device = VirtualDevice(name: name, channels: channels, direction: .inputOnly, channelNames: names,
                                       icon: .microphone)
                graph.virtualDevices.append(device)
            }
            if let existing = graph.deviceNode(device.id) {
                deviceNode = existing
            } else {
                deviceNode = Node(kind: .virtualDevice(device.id), x: CanvasColumn.device, y: 60, canvas: device.id)
                graph.nodes.append(deviceNode)
            }
            nextY = graph.nodes(on: device.id).filter { $0.x < CanvasColumn.device }.map { $0.y + 170 }.max() ?? 60
        }

        /// A source node of this kind on the canvas (one per kind: two inputs of one interface share its node).
        mutating func source(_ kind: NodeKind) -> Node {
            if let node = nodes.first(where: { $0.kind == kind }) { return node }
            let node = Node(kind: kind, x: CanvasColumn.sources, y: nextY, canvas: device.id)
            nodes.append(node)
            nextY += 170
            return node
        }

        mutating func connect(_ node: Node, _ channel: Int, to input: Int) {
            guard input < device.channels else { return }
            cables.append(Cable(from: PortRef(node: node.id, channel: channel), to: PortRef(node: deviceNode.id, channel: input)))
        }

        func finish(into graph: inout Graph) -> VirtualDevice {
            graph.nodes += nodes
            graph.cables += cables
            return device
        }
    }
}
