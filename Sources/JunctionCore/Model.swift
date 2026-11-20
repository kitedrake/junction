import Foundation

// The routing graph Junction saves and edits: virtual devices it publishes through its driver, nodes on the
// canvas, and cables between node channels.
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

    public init(id: UUID = UUID(), kind: NodeKind, x: Double = 0, y: Double = 0, gainDB: Double = 0, isMuted: Bool = false,
                mutesOriginal: Bool = false) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.mutesOriginal = mutesOriginal
    }
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
    public var schema = 1
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

    public mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        cables.removeAll { $0.from.node == id || $0.to.node == id }
    }

    /// Removes a virtual device and its nodes and cables.
    public mutating func removeVirtualDevice(_ id: UUID) {
        for node in nodes where node.kind == .virtualDevice(id) { removeNode(node.id) }
        virtualDevices.removeAll { $0.id == id }
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
