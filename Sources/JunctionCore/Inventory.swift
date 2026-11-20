import CoreAudio
import Foundation

/// What is on the system right now: devices, apps that use audio, defaults, and the driver. Plain data, so the
/// planner and the canvas can work from a snapshot (or a made-up one in tests and screenshots).
public struct Inventory: Equatable, Sendable {
    public var devices: [DeviceInfo]
    public var apps: [AudioApp]
    public var defaultOutputUID: String?
    public var defaultInputUID: String?
    public var driver: DriverStatus

    public init(devices: [DeviceInfo] = [], apps: [AudioApp] = [], defaultOutputUID: String? = nil,
                defaultInputUID: String? = nil, driver: DriverStatus = .notInstalled) {
        self.devices = devices
        self.apps = apps
        self.defaultOutputUID = defaultOutputUID
        self.defaultInputUID = defaultInputUID
        self.driver = driver
    }

    public func device(_ uid: String?) -> DeviceInfo? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// Hardware and third-party devices (not Junction's own, not hidden aggregates).
    public var externalDevices: [DeviceInfo] { devices.filter { !$0.isJunction } }
    public var inputDevices: [DeviceInfo] { externalDevices.filter { $0.inputChannels > 0 } }
    public var outputDevices: [DeviceInfo] { externalDevices.filter { $0.outputChannels > 0 } }
}

public struct DeviceInfo: Hashable, Sendable, Identifiable {
    public var uid: String
    public var objectID: AudioObjectID
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    /// Published by Junction's driver.
    public var isJunction: Bool

    public var id: String { uid }

    public init(uid: String, objectID: AudioObjectID = 0, name: String, inputChannels: Int, outputChannels: Int,
                sampleRate: Double = 48000, isJunction: Bool = false) {
        self.uid = uid
        self.objectID = objectID
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.isJunction = isJunction
    }

    public var ref: DeviceRef { DeviceRef(uid: uid, name: name, inputChannels: inputChannels, outputChannels: outputChannels) }
}

/// An app that has talked to Core Audio since it started (macOS lists those as audio processes).
public struct AudioApp: Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    /// Whether any of its processes is playing audio right now.
    public var isPlaying: Bool

    public var id: String { bundleID }
    public var ref: AppRef { AppRef(bundleID: bundleID, name: name) }

    public init(bundleID: String, name: String, isPlaying: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
    }
}

public enum DriverStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: String)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Port counts and names of nodes, given the graph and what is on the system.
public struct NodeInfo {
    public let graph: Graph
    public let inventory: Inventory

    public init(graph: Graph, inventory: Inventory) {
        self.graph = graph
        self.inventory = inventory
    }

    public func ports(_ node: Node) -> PortCounts {
        switch node.kind {
        case .virtualDevice(let id):
            let channels = graph.virtualDevice(id)?.channels ?? 0
            return PortCounts(inputs: channels, outputs: channels)
        case .device(let ref):
            let live = inventory.device(ref.uid)
            return PortCounts(inputs: live?.outputChannels ?? ref.outputChannels, outputs: live?.inputChannels ?? ref.inputChannels)
        case .defaultOutput:
            return PortCounts(inputs: inventory.device(inventory.defaultOutputUID)?.outputChannels ?? 2, outputs: 0)
        case .defaultInput:
            return PortCounts(inputs: 0, outputs: inventory.device(inventory.defaultInputUID)?.inputChannels ?? 2)
        case .application, .systemAudio:
            return PortCounts(inputs: 0, outputs: 2)
        }
    }

    public func title(_ node: Node) -> String {
        switch node.kind {
        case .virtualDevice(let id): graph.virtualDevice(id)?.name ?? "Deleted Device"
        case .device(let ref): inventory.device(ref.uid)?.name ?? ref.name
        case .defaultOutput: "Default Output"
        case .defaultInput: "Default Input"
        case .application(let app): app.name
        case .systemAudio: "System Audio"
        }
    }

    public func subtitle(_ node: Node) -> String {
        switch node.kind {
        case .virtualDevice(let id):
            guard let device = graph.virtualDevice(id) else { return "" }
            return device.isEnabled ? "Virtual device" : "Virtual device · off"
        case .device(let ref):
            return inventory.device(ref.uid) == nil ? "Not connected" : "Audio device"
        case .defaultOutput:
            return inventory.device(inventory.defaultOutputUID)?.name ?? "None"
        case .defaultInput:
            return inventory.device(inventory.defaultInputUID)?.name ?? "None"
        case .application:
            return node.mutesOriginal ? "App audio · taken from speakers" : "App audio"
        case .systemAudio(let excluded):
            if excluded.isEmpty { return "All apps" }
            let names = excluded.map(\.name)
            return "All apps except " + (names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]) and \(names.count - 1) more")
        }
    }

    /// The device UID a node stands for right now, if it is a device and available.
    public func deviceUID(_ node: Node) -> String? {
        switch node.kind {
        case .virtualDevice(let id):
            guard let device = graph.virtualDevice(id), device.isEnabled, inventory.device(device.uid) != nil else { return nil }
            return device.uid
        case .device(let ref): return inventory.device(ref.uid) != nil ? ref.uid : nil
        case .defaultOutput: return inventory.device(inventory.defaultOutputUID) != nil ? inventory.defaultOutputUID : nil
        case .defaultInput: return inventory.device(inventory.defaultInputUID) != nil ? inventory.defaultInputUID : nil
        case .application, .systemAudio: return nil
        }
    }
}
