import Foundation

// The routing graph Junction saves and edits: virtual devices it publishes through its driver, nodes on their
// canvases, and cables between node channels.
//
// Every virtual device has its own canvas: its device node in the middle, sources on the left that feed it and
// outputs on the right that play it. A cable always runs into the canvas's device or out of it, so virtual devices
// never feed each other.
//
// Sides: a node's *inputs* (left) are what it can be sent (a device's playback channels, a virtual device's
// feed); its *outputs* (right) are what it provides (a microphone's capture channels, an app's audio, what comes
// out of a virtual device). A cable always runs from an output to an input.

/// A loopback device published by the Junction driver. Disabled devices are kept here but not published.
public struct VirtualDevice: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var channels: Int
    public var sampleRate: Double
    public var isEnabled: Bool
    /// Which sides apps see. Junction itself always reaches both (through the hidden companion device).
    public var direction: DeviceDirection
    /// A name per channel, shown by apps that list channels ("" or missing: no name).
    public var channelNames: [String]
    /// The picture apps such as Audio MIDI Setup show for it.
    public var icon: DeviceIcon
    /// Left out of apps' device lists (Junction still uses it).
    public var isHidden: Bool
    /// Volume (0…1) and mute of what is played into it (output) and recorded from it (input). Sound settings and the
    /// volume keys change them too; Junction reads them back from the driver.
    public var outputVolume: Double
    public var outputMuted: Bool
    public var inputVolume: Double
    public var inputMuted: Bool

    public init(id: UUID = UUID(), name: String, channels: Int = 2, sampleRate: Double = 48000, isEnabled: Bool = true,
                direction: DeviceDirection = .both, channelNames: [String] = [], icon: DeviceIcon = .junction,
                isHidden: Bool = false, outputVolume: Double = 1, outputMuted: Bool = false, inputVolume: Double = 1,
                inputMuted: Bool = false) {
        self.id = id
        self.name = name
        self.channels = channels
        self.sampleRate = sampleRate
        self.isEnabled = isEnabled
        self.direction = direction
        self.channelNames = channelNames
        self.icon = icon
        self.isHidden = isHidden
        self.outputVolume = outputVolume
        self.outputMuted = outputMuted
        self.inputVolume = inputVolume
        self.inputMuted = inputMuted
    }

    /// Files before schema 4 have only the first five fields; the rest take their defaults (see `Graph.upgrade`).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        channels = try values.decode(Int.self, forKey: .channels)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        direction = try values.decodeIfPresent(DeviceDirection.self, forKey: .direction) ?? .both
        channelNames = try values.decodeIfPresent([String].self, forKey: .channelNames) ?? []
        icon = try values.decodeIfPresent(DeviceIcon.self, forKey: .icon) ?? .junction
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        outputVolume = try values.decodeIfPresent(Double.self, forKey: .outputVolume) ?? 1
        outputMuted = try values.decodeIfPresent(Bool.self, forKey: .outputMuted) ?? false
        inputVolume = try values.decodeIfPresent(Double.self, forKey: .inputVolume) ?? 1
        inputMuted = try values.decodeIfPresent(Bool.self, forKey: .inputMuted) ?? false
    }

    /// The Core Audio device UID; apps that remember a chosen device find it again by this.
    public var uid: String { "junction.\(id.uuidString.lowercased())" }

    /// The hidden companion the driver publishes when apps see only one side: it carries the other side, so Junction
    /// can still feed an input-only device or record an output-only one.
    public var companionUID: String { uid + VirtualDevice.companionSuffix }
    public static let companionSuffix = ".routing"

    /// The device Junction plays into (its feed) and the one it records from (what comes out of it).
    public var feedUID: String { direction == .inputOnly ? companionUID : uid }
    public var returnUID: String { direction == .outputOnly ? companionUID : uid }

    /// The name of a channel (0-based), or nil when it has none.
    public func channelName(_ channel: Int) -> String? {
        guard channel >= 0, channel < min(channels, channelNames.count) else { return nil }
        let name = channelNames[channel].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Whether apps see a side (and it has a volume and mute).
    public var showsOutput: Bool { direction != .inputOnly }
    public var showsInput: Bool { direction != .outputOnly }

    public static let channelChoices = [1, 2, 4, 6, 8, 16, 32, 64]
    public static let sampleRateChoices: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
    public static let maximumCount = 32
}

/// Which sides of a virtual device apps see.
public enum DeviceDirection: String, Codable, CaseIterable, Sendable {
    /// A microphone and a speaker.
    case both
    /// A microphone only: apps record what Junction sends into it.
    case inputOnly = "input"
    /// A speaker only: apps play into it and Junction picks the sound up.
    case outputOnly = "output"

    public var title: String {
        switch self {
        case .both: "Input and output"
        case .inputOnly: "Input only"
        case .outputOnly: "Output only"
        }
    }
}

/// The icons bundled in the driver (`Driver/Icons`).
public enum DeviceIcon: String, Codable, CaseIterable, Sendable {
    case junction, microphone, speaker, headphones, stream

    public var title: String { rawValue == "junction" ? "Junction" : rawValue.capitalized }
}

/// An application, by bundle identifier (its helper processes count as part of it).
public struct AppRef: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A hardware (or third-party virtual) device, by UID. The name and channel counts are remembered so the node keeps
/// its shape while the device is unplugged.
public struct DeviceRef: Codable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int

    public init(uid: String, name: String, inputChannels: Int, outputChannels: Int) {
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }
}

public enum NodeKind: Codable, Hashable, Sendable {
    /// One of Junction's own virtual devices (inputs: its feed; outputs: what comes out of it).
    case virtualDevice(UUID)
    /// A hardware device: inputs are its playback channels, outputs its capture channels.
    case device(DeviceRef)
    /// Whatever device macOS currently uses for output (follows changes in Sound settings).
    case defaultOutput
    /// Whatever device macOS currently uses for input.
    case defaultInput
    /// The audio of one application (stereo).
    case application(AppRef)
    /// Everything apps play (stereo), except the listed apps. Junction's own output is never included.
    case systemAudio(excluding: [AppRef])
    /// What one app plays into one of Junction's virtual devices, on its own (the driver's per-app capture): the
    /// device's first channels, at most `CaptureRegion.maxChannels`. Audio passes through that device, so the
    /// feedback rules treat it as the device's own audio.
    case appThroughDevice(AppRef, device: UUID)

    /// Process taps: their source is app audio rather than a device.
    public var isTap: Bool {
        switch self {
        case .application, .systemAudio: true
        default: false
        }
    }
}

public struct Node: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: NodeKind
    public var x: Double
    public var y: Double
    /// Level in dB applied to everything leaving (source side) or arriving at (sink side) this node.
    public var gainDB: Double
    public var isMuted: Bool
    /// For app and system audio nodes: take the audio away from where the app normally plays it.
    public var mutesOriginal: Bool
    /// The virtual device whose canvas this node is on (nil only in graphs saved before canvases, see `upgrade()`).
    public var canvas: UUID?
    /// For nodes that receive cables: the IO buffer size of their routing, in frames (nil: macOS's default).
    public var bufferFrames: Int?
    /// For nodes that receive cables: whether devices running at another sample rate are converted.
    public var rateConversion: RateConversion
    /// The node's effect chain, in order: on a source, its channels before they are mixed into the device; on the
    /// virtual device, the mix before it goes into the device; on an output, what it receives (see Effects.swift).
    public var effects: [Effect]

    public static let bufferChoices = [64, 128, 256, 512, 1024]

    public init(id: UUID = UUID(), kind: NodeKind, x: Double = 0, y: Double = 0, gainDB: Double = 0, isMuted: Bool = false,
                mutesOriginal: Bool = false, canvas: UUID? = nil, bufferFrames: Int? = nil,
                rateConversion: RateConversion = .automatic, effects: [Effect] = []) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.mutesOriginal = mutesOriginal
        self.canvas = canvas
        self.bufferFrames = bufferFrames
        self.rateConversion = rateConversion
        self.effects = effects
    }

    /// Files before schema 4 have no `rateConversion` or `effects`; `Graph.upgrade` decides what they become.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(NodeKind.self, forKey: .kind)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        gainDB = try values.decode(Double.self, forKey: .gainDB)
        isMuted = try values.decode(Bool.self, forKey: .isMuted)
        mutesOriginal = try values.decode(Bool.self, forKey: .mutesOriginal)
        canvas = try values.decodeIfPresent(UUID.self, forKey: .canvas)
        bufferFrames = try values.decodeIfPresent(Int.self, forKey: .bufferFrames)
        rateConversion = try values.decodeIfPresent(RateConversion.self, forKey: .rateConversion) ?? .automatic
        effects = try values.decodeIfPresent([Effect].self, forKey: .effects) ?? []
    }
}

/// What a receiving node does with a device that runs at another sample rate than the one it receives from.
public enum RateConversion: String, Codable, CaseIterable, Sendable {
    /// Junction converts it: the device runs on its own, outside the sink's aggregate device.
    case automatic
    /// The device joins the aggregate as it is and Core Audio's drift compensation keeps it in step (the behaviour
    /// before schema 4: best when both are set to the same rate).
    case off
}

/// Where nodes go on a canvas: sources, the virtual device, outputs.
public enum CanvasColumn {
    public static let sources = 40.0
    public static let device = 330.0
    public static let outputs = 620.0
}

/// One channel of one node.
public struct PortRef: Codable, Hashable, Sendable {
    public var node: UUID
    public var channel: Int

    public init(node: UUID, channel: Int) {
        self.node = node
        self.channel = channel
    }
}

public struct Cable: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// An output channel of the source node.
    public var from: PortRef
    /// An input channel of the destination node.
    public var to: PortRef
    public var gainDB: Double

    public init(id: UUID = UUID(), from: PortRef, to: PortRef, gainDB: Double = 0) {
        self.id = id
        self.from = from
        self.to = to
        self.gainDB = gainDB
    }
}

public struct Graph: Codable, Equatable, Sendable {
    /// 1: one shared canvas. 2: a canvas per virtual device. 3: nodes can set a buffer size (`Node.bufferFrames`;
    /// absent in older files, which means macOS's default). 4: receiving nodes choose sample-rate conversion
    /// (`Node.rateConversion`), and virtual devices have a direction, channel names, an icon, a hidden switch and a
    /// volume and mute per side, and the graph keeps named scenes (`scenes`; absent in older files, which means none).
    /// Schema 4 also has the "<app> through <device>" source (`NodeKind.appThroughDevice`), which older files can't
    /// contain, so they need no conversion for it, and effect chains on nodes (`Node.effects`: each effect's component
    /// codes, bypass, parameters and Audio Unit state; absent in older files, which means none), and MIDI mappings
    /// (`midi`: each one's control, how its values are read, and the cable, node, effect, device or scene it drives;
    /// absent in older files, which means none), and headphone monitors (`monitors`: per virtual device, its output,
    /// level, mute and a level per source; absent in older files, which means none).
    public static let currentSchema = 4
    public var schema = Graph.currentSchema
    public var virtualDevices: [VirtualDevice] = []
    public var nodes: [Node] = []
    public var cables: [Cable] = []
    /// The master switch: when off, nothing is routed (virtual devices stay published).
    public var isRoutingOn = true
    /// Saved setups to switch between (see `RoutingScene`).
    public var scenes: [RoutingScene] = []
    /// MIDI controls and what they drive (see MIDI.swift).
    public var midi: [MIDIMapping] = []
    /// Headphone monitors, at most one per virtual device (see Mixer.swift).
    public var monitors: [MonitorMix] = []

    public init(virtualDevices: [VirtualDevice] = [], nodes: [Node] = [], cables: [Cable] = [], isRoutingOn: Bool = true,
                scenes: [RoutingScene] = [], midi: [MIDIMapping] = [], monitors: [MonitorMix] = []) {
        self.virtualDevices = virtualDevices
        self.nodes = nodes
        self.cables = cables
        self.isRoutingOn = isRoutingOn
        self.scenes = scenes
        self.midi = midi
        self.monitors = monitors
    }

    /// Files from before scenes have no `scenes`, files from before MIDI control no `midi`, and files from before
    /// monitors no `monitors`: they load with none (see `upgrade`).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        virtualDevices = try values.decode([VirtualDevice].self, forKey: .virtualDevices)
        nodes = try values.decode([Node].self, forKey: .nodes)
        cables = try values.decode([Cable].self, forKey: .cables)
        isRoutingOn = try values.decode(Bool.self, forKey: .isRoutingOn)
        scenes = try values.decodeIfPresent([RoutingScene].self, forKey: .scenes) ?? []
        midi = try values.decodeIfPresent([MIDIMapping].self, forKey: .midi) ?? []
        monitors = try values.decodeIfPresent([MonitorMix].self, forKey: .monitors) ?? []
    }

    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }
    public func virtualDevice(_ id: UUID) -> VirtualDevice? { virtualDevices.first { $0.id == id } }

    /// The node standing for a virtual device in the middle of its canvas.
    public func deviceNode(_ device: UUID) -> Node? {
        nodes.first { $0.kind == .virtualDevice(device) && $0.canvas == device }
    }

    public func nodes(on canvas: UUID) -> [Node] { nodes.filter { $0.canvas == canvas } }

    public func cables(on canvas: UUID) -> [Cable] {
        let ids = Set(nodes(on: canvas).map(\.id))
        return cables.filter { ids.contains($0.from.node) && ids.contains($0.to.node) }
    }

    /// Removes a node, its cables, and the MIDI mappings of both (unless a scene still holds them).
    public mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        cables.removeAll { $0.from.node == id || $0.to.node == id }
        pruneMIDI()
        pruneMonitors()
    }

    /// Removes a virtual device and its canvas: its nodes and cables, also from the scenes, its monitor, and their
    /// MIDI mappings.
    public mutating func removeVirtualDevice(_ id: UUID) {
        let gone = Set(nodes.filter { $0.canvas == id || $0.kind == .virtualDevice(id) }.map(\.id))
        nodes.removeAll { gone.contains($0.id) }
        cables.removeAll { gone.contains($0.from.node) || gone.contains($0.to.node) }
        virtualDevices.removeAll { $0.id == id }
        monitors.removeAll { $0.device == id }
        let devices = Set(virtualDevices.map(\.id))
        for index in scenes.indices { scenes[index].keepOnly(devices) }
        pruneMIDI()
    }

    /// Brings a loaded graph up to date: converts the shared canvas of schema 1, turns on sample-rate conversion and
    /// sets the device options for files from before they existed, then tidies the canvases. Scenes and MIDI mappings
    /// are new in schema 4: older files have none, scenes naming deleted devices lose those parts, and mappings whose
    /// target is gone are dropped. So are monitors: older files have none, a deleted device's monitor goes, a device
    /// keeps one at most, and solo/listen starts off.
    public mutating func upgrade() {
        if schema < 2 { moveToCanvases() }
        if schema < 4 {
            convertRates()
            convertDevices()
            convertEffects()
            scenes = []
            midi = []
            monitors = []
        }
        schema = Graph.currentSchema
        tidyCanvases()
        let devices = Set(virtualDevices.map(\.id))
        for index in scenes.indices { scenes[index].keepOnly(devices) }
        pruneMIDI()
        var monitored = Set<UUID>()
        monitors.removeAll { !devices.contains($0.device) || !monitored.insert($0.device).inserted }
        for index in monitors.indices { monitors[index].listening = [] }
    }

    /// Schema 1 had one shared canvas. Each node moves to the canvas of the virtual device it is wired to (copied, with
    /// its cables, when wired to several); unwired nodes go on the first device's canvas. Cables between virtual
    /// devices, or that bypass them, have no place on a canvas and are dropped.
    mutating func moveToCanvases() {
        var deviceOf: [UUID: UUID] = [:]  // device node → virtual device
        for index in nodes.indices {
            guard case .virtualDevice(let id) = nodes[index].kind else { continue }
            nodes[index].canvas = id
            deviceOf[nodes[index].id] = id
        }
        var moved = nodes.filter { deviceOf[$0.id] != nil }
        var kept: [Cable] = []
        for node in nodes where deviceOf[node.id] == nil {
            func other(_ cable: Cable) -> UUID { cable.from.node == node.id ? cable.to.node : cable.from.node }
            let wired = cables.filter { ($0.from.node == node.id || $0.to.node == node.id) && deviceOf[other($0)] != nil }
            var canvases: [UUID] = []
            for cable in wired {
                if let device = deviceOf[other(cable)], !canvases.contains(device) { canvases.append(device) }
            }
            if canvases.isEmpty, let first = virtualDevices.first { canvases = [first.id] }
            for (index, canvas) in canvases.enumerated() {
                var copy = node
                copy.canvas = canvas
                if index > 0 { copy.id = UUID() }
                moved.append(copy)
                for var cable in wired where deviceOf[other(cable)] == canvas {
                    if index > 0 {
                        cable.id = UUID()
                        if cable.from.node == node.id { cable.from.node = copy.id } else { cable.to.node = copy.id }
                    }
                    kept.append(cable)
                }
            }
        }
        nodes = moved
        cables = kept
    }

    /// Schema 3 and older had no sample-rate conversion: a device at another rate joined the aggregate as it was.
    /// Their nodes get the new default, Automatic, so those devices are converted from now on.
    mutating func convertRates() {
        for index in nodes.indices { nodes[index].rateConversion = .automatic }
    }

    /// Schema 3 and older had no device options: every device showed apps both sides, under the Junction icon, at full
    /// volume. Decoding already gives those defaults; this states them, so a file that has them half (written by a
    /// development build) loads the same way.
    mutating func convertDevices() {
        for index in virtualDevices.indices {
            let device = virtualDevices[index]
            virtualDevices[index] = VirtualDevice(id: device.id, name: device.name, channels: device.channels,
                                                  sampleRate: device.sampleRate, isEnabled: device.isEnabled)
        }
    }

    /// Schema 3 and older had no effects: every node starts with an empty chain (a file half written by a development
    /// build loses what it had, as with its scenes).
    mutating func convertEffects() {
        for index in nodes.indices { nodes[index].effects = [] }
    }

    /// Keeps the canvases consistent: every virtual device has exactly one device node on its own canvas; nodes on no
    /// canvas (or a deleted one) go, and so do cables that don't run into or out of their canvas's device.
    public mutating func tidyCanvases() {
        let devices = Set(virtualDevices.map(\.id))
        var hasDeviceNode = Set<UUID>()
        nodes.removeAll { node in
            guard let canvas = node.canvas, devices.contains(canvas) else { return true }
            guard case .virtualDevice(let id) = node.kind else { return false }
            return id != canvas || !hasDeviceNode.insert(id).inserted
        }
        for device in virtualDevices where !hasDeviceNode.contains(device.id) {
            nodes.append(Node(kind: .virtualDevice(device.id), x: CanvasColumn.device, y: 60, canvas: device.id))
        }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cables.removeAll { cable in
            guard let a = byID[cable.from.node], let b = byID[cable.to.node], let canvas = a.canvas, b.canvas == canvas
            else { return true }
            return (a.kind == .virtualDevice(canvas)) == (b.kind == .virtualDevice(canvas))
        }
    }

    /// Drops cables whose ports no longer exist (a device lost channels, a virtual device got narrower).
    public mutating func pruneCables(ports: (Node) -> PortCounts) {
        let nodes = Dictionary(self.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cables.removeAll { cable in
            guard let from = nodes[cable.from.node], let to = nodes[cable.to.node] else { return true }
            return cable.from.channel >= ports(from).outputs || cable.to.channel >= ports(to).inputs
        }
    }
}

public struct PortCounts: Equatable, Sendable {
    public var inputs: Int
    public var outputs: Int

    public init(inputs: Int, outputs: Int) {
        self.inputs = inputs
        self.outputs = outputs
    }
}

public enum Gain {
    /// Faders bottom out here; at or below it the level is silence.
    public static let floorDB = -60.0
    public static let ceilingDB = 12.0

    public static func linear(_ dB: Double) -> Float {
        dB <= floorDB ? 0 : Float(pow(10, dB / 20))
    }

    public static func text(_ dB: Double) -> String {
        if dB <= floorDB { return "−∞ dB" }
        let rounded = (dB * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f dB", abs(rounded))
    }
}

/// Channel names for a node side: L/R for stereo, numbers otherwise.
public func channelLabels(_ count: Int) -> [String] {
    count == 2 ? ["L", "R"] : (0..<count).map { "\($0 + 1)" }
}
