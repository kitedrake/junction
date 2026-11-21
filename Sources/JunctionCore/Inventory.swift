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
    /// Core Audio's clock domain (0: not known). Devices in the same nonzero domain share one clock and never drift.
    public var clockDomain: UInt32

    public var id: String { uid }

    public init(uid: String, objectID: AudioObjectID = 0, name: String, inputChannels: Int, outputChannels: Int,
                sampleRate: Double = 48000, isJunction: Bool = false, clockDomain: UInt32 = 0) {
        self.uid = uid
        self.objectID = objectID
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.isJunction = isJunction
        self.clockDomain = clockDomain
    }

    /// Whether this device runs on the same clock as `other`.
    public func sharesClock(with other: DeviceInfo) -> Bool {
        clockDomain != 0 && clockDomain == other.clockDomain
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

/// The installed driver against the one inside this copy of Junction.
public enum DriverUpdate: Equatable, Sendable {
    /// The versions match, or this copy of Junction has no driver inside.
    case upToDate
    case notInstalled
    /// This copy of Junction carries a newer driver (or the installed one reports no readable version).
    case available(installed: String, bundled: String)
    /// The installed driver is newer: an older copy of Junction is running. Junction doesn't offer to go back.
    case appIsOlder(installed: String, bundled: String)

    public init(installed: DriverStatus, bundled: String?) {
        guard case .installed(let version) = installed else {
            self = .notInstalled
            return
        }
        guard let bundled, version != bundled else {
            self = .upToDate
            return
        }
        switch Self.compare(version, bundled) {
        case .orderedSame?: self = .upToDate
        case .orderedDescending?: self = .appIsOlder(installed: version, bundled: bundled)
        case .orderedAscending?, nil: self = .available(installed: version, bundled: bundled)
        }
    }

    /// Compares dotted version numbers part by part ("0.1.10" is newer than "0.1.9", "1.0" equals "1.0.0"); nil
    /// when either isn't one.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        func parts(_ text: String) -> [Int]? {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty else { return nil }
            var result: [Int] = []
            for piece in pieces {
                guard let number = Int(piece), number >= 0 else { return nil }
                result.append(number)
            }
            return result
        }
        guard let left = parts(a), let right = parts(b) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
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
            guard device.isEnabled else { return "Virtual device · off" }
            switch device.direction {
            case .both: return device.isHidden ? "Virtual device · hidden" : "Virtual device"
            case .inputOnly: return device.isHidden ? "Virtual input · hidden" : "Virtual input"
            case .outputOnly: return device.isHidden ? "Virtual output · hidden" : "Virtual output"
            }
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

    /// The nominal sample rate of the device a node stands for right now (nil for app audio or a missing device).
    public func sampleRate(_ node: Node) -> Double? {
        guard let rate = inventory.device(deviceUID(node))?.sampleRate, rate > 0 else { return nil }
        return rate
    }

    /// A device node's effective rate: "44.1 kHz, converted to 48 kHz" when Junction converts it, else "48 kHz".
    public func rateText(_ node: Node, plan: RoutingPlan) -> String? {
        if let note = plan.conversions[node.id] { return note.text }
        return sampleRate(node).map { formatSampleRate($0) }
    }

    /// Channel names for one side of a node: a virtual device's own names where it has them, else L/R or numbers.
    public func channelLabels(_ node: Node, outputs: Bool) -> [String] {
        let ports = ports(node)
        var labels = JunctionCore.channelLabels(outputs ? ports.outputs : ports.inputs)
        if case .virtualDevice(let id) = node.kind, let device = graph.virtualDevice(id) {
            for index in labels.indices { if let name = device.channelName(index) { labels[index] = name } }
        }
        return labels
    }

    /// The device Junction plays into for a receiving node: a virtual device's feed (its hidden companion when apps
    /// see it as an input only), else the node's device.
    public func feedUID(_ node: Node) -> String? {
        guard case .virtualDevice(let id) = node.kind else { return deviceUID(node) }
        guard deviceUID(node) != nil, let uid = graph.virtualDevice(id)?.feedUID, inventory.device(uid) != nil else { return nil }
        return uid
    }

    /// The device Junction records from for a source node: what comes out of a virtual device (its hidden companion
    /// when apps see it as an output only), else the node's device.
    public func returnUID(_ node: Node) -> String? {
        guard case .virtualDevice(let id) = node.kind else { return deviceUID(node) }
        guard deviceUID(node) != nil, let uid = graph.virtualDevice(id)?.returnUID, inventory.device(uid) != nil else { return nil }
        return uid
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
