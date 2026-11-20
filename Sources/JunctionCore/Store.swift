import Foundation

/// Saves the graph as JSON in Application Support (or `$JUNCTION_HOME` when set, for tests and screenshots).
public struct Store: Sendable {
    public let folder: URL

    public init(folder: URL? = nil) {
        if let folder {
            self.folder = folder
        } else if let home = ProcessInfo.processInfo.environment["JUNCTION_HOME"], !home.isEmpty {
            self.folder = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            self.folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Junction", isDirectory: true)
        }
    }

    public var graphURL: URL { folder.appendingPathComponent("graph.json") }

    /// The saved graph, or nil when there is none yet. A file that can't be read is kept aside (graph.json.unreadable)
    /// rather than overwritten.
    public func load() -> Graph? {
        guard let data = try? Data(contentsOf: graphURL) else { return nil }
        do {
            return try JSONDecoder().decode(Graph.self, from: data)
        } catch {
            let aside = folder.appendingPathComponent("graph.json.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.copyItem(at: graphURL, to: aside)
            return nil
        }
    }

    public func save(_ graph: Graph) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(graph).write(to: graphURL, options: .atomic)
    }
}

/// Ready-made setups.
public enum Templates {
    /// Chat and call apps people usually want to keep out of a stream.
    public static let chatApps: [AppRef] = [
        AppRef(bundleID: "com.hnc.Discord", name: "Discord"),
        AppRef(bundleID: "com.hnc.DiscordPTB", name: "Discord PTB"),
        AppRef(bundleID: "com.hnc.DiscordCanary", name: "Discord Canary"),
        AppRef(bundleID: "us.zoom.xos", name: "zoom.us"),
        AppRef(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        AppRef(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        AppRef(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        AppRef(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        AppRef(bundleID: "com.skype.skype", name: "Skype"),
        AppRef(bundleID: "com.mumble.Mumble", name: "Mumble"),
        AppRef(bundleID: "com.teamspeak.TeamSpeak3", name: "TeamSpeak"),
    ]

    /// Apps offered to leave out of a stream: apps using audio now, then the known chat apps that are installed and
    /// the apps the user picked. Each appears once; apps using audio come first, each group sorted by name.
    public static func chatCandidates(usingAudio: [AppRef], installedChatApps: [AppRef], picked: [AppRef] = []) -> [AppRef] {
        var seen = Set<String>()
        func unique(_ apps: [AppRef]) -> [AppRef] {
            apps.filter { seen.insert($0.bundleID).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let first = unique(usingAudio)
        return first + unique(installedChatApps + picked)
    }

    /// What Stream Without Chat leaves out unless the user changes it: every version of Discord on offer.
    public static func defaultExclusions(from candidates: [AppRef]) -> Set<String> {
        Set(candidates.map(\.bundleID).filter { $0.hasPrefix("com.hnc.Discord") })
    }

    /// "Stream without chat": a virtual device named `deviceName` that carries everything apps play except the
    /// chosen chat apps. A streaming app records it; people in the call don't hear themselves on stream.
    /// Reuses a virtual device and system-audio node of the same name/kind when present. Returns the device.
    @discardableResult
    public static func streamWithoutChat(_ graph: inout Graph, excluding chat: [AppRef], deviceName: String = "Stream Mix",
                                         at origin: (x: Double, y: Double) = (80, 80)) -> VirtualDevice {
        let device: VirtualDevice
        if let existing = graph.virtualDevices.first(where: { $0.name == deviceName }) {
            device = existing
            if let index = graph.virtualDevices.firstIndex(where: { $0.id == existing.id }) { graph.virtualDevices[index].isEnabled = true }
        } else {
            device = VirtualDevice(name: deviceName, channels: 2)
            graph.virtualDevices.append(device)
        }
        let system = Node(kind: .systemAudio(excluding: chat), x: origin.x, y: origin.y)
        graph.nodes.append(system)
        let deviceNode: Node
        if let existing = graph.nodes.first(where: { $0.kind == .virtualDevice(device.id) }) {
            deviceNode = existing
        } else {
            deviceNode = Node(kind: .virtualDevice(device.id), x: origin.x + 340, y: origin.y)
            graph.nodes.append(deviceNode)
        }
        for channel in 0..<min(2, device.channels) {
            graph.cables.append(Cable(from: PortRef(node: system.id, channel: channel), to: PortRef(node: deviceNode.id, channel: channel)))
        }
        if device.channels == 1 {
            graph.cables.append(Cable(from: PortRef(node: system.id, channel: 1), to: PortRef(node: deviceNode.id, channel: 0)))
        }
        return device
    }
}
