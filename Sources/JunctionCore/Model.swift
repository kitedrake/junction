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

    public init(id: UUID = UUID(), name: String, channels: Int = 2, sampleRate: Double = 48000, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.channels = channels
        self.sampleRate = sampleRate
        self.isEnabled = isEnabled
    }

    /// The Core Audio device UID; apps that remember a chosen device find it again by this.
    public var uid: String { "junction.\(id.uuidString.lowercased())" }

    public static let channelChoices = [1, 2, 4, 6, 8, 16, 32, 64]
    public static let sampleRateChoices: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
    public static let maximumCount = 32
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

    public init(id: UUID = UUID(), kind: NodeKind, x: Double = 0, y: Double = 0, gainDB: Double = 0, isMuted: Bool = false,
                mutesOriginal: Bool = false, canvas: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.mutesOriginal = mutesOriginal
        self.canvas = canvas
    }
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
    /// 1: one shared canvas. 2: a canvas per virtual device.
    public static let currentSchema = 2
    public var schema = Graph.currentSchema
    public var virtualDevices: [VirtualDevice] = []
    public var nodes: [Node] = []
    public var cables: [Cable] = []
    /// The master switch: when off, nothing is routed (virtual devices stay published).
    public var isRoutingOn = true

    public init(virtualDevices: [VirtualDevice] = [], nodes: [Node] = [], cables: [Cable] = [], isRoutingOn: Bool = true) {
        self.virtualDevices = virtualDevices
        self.nodes = nodes
        self.cables = cables
        self.isRoutingOn = isRoutingOn
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

    public mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        cables.removeAll { $0.from.node == id || $0.to.node == id }
    }

    /// Removes a virtual device and its canvas: its nodes and cables.
    public mutating func removeVirtualDevice(_ id: UUID) {
        let gone = Set(nodes.filter { $0.canvas == id || $0.kind == .virtualDevice(id) }.map(\.id))
        nodes.removeAll { gone.contains($0.id) }
        cables.removeAll { gone.contains($0.from.node) || gone.contains($0.to.node) }
        virtualDevices.removeAll { $0.id == id }
    }

    /// Brings a loaded graph up to date: converts the shared canvas of schema 1, then tidies the canvases.
    public mutating func upgrade() {
        if schema < 2 { moveToCanvases() }
        schema = Graph.currentSchema
        tidyCanvases()
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
