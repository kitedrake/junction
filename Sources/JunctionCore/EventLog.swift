import Foundation

/// Something the router or the app did that helps explain what you hear: sinks built, failures, retries, restarts.
public struct RoutingEvent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case info, warning, error }
    public let id: Int
    public let date: Date
    public let kind: Kind
    public let message: String

    /// One line for the log file and reports: `2026-11-21 14:03:07  error  Stream Mix: …`.
    public var line: String {
        "\(Self.format(date))  \(kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))\(message)"
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// The last few hundred routing events, kept in memory for the Routing Log window and appended to
/// `events.log` next to `graph.json` so `Junction --diagnose` can include them. Safe to use from any thread.
public final class EventLog: @unchecked Sendable {
    public static let shared = EventLog(file: Store().folder.appendingPathComponent("events.log"))

    /// Kept in memory; the file is cut down to about this many lines once it grows past twice that.
    public static let limit = 500

    private let lock = NSLock()
    private var events: [RoutingEvent] = []
    private var nextID = 0
    private var file: URL?
    private var onChange: (@Sendable () -> Void)?

    public init(file: URL?) {
        self.file = file
    }

    /// Stops writing to disk (screenshots and demos).
    public func keepInMemoryOnly() {
        lock.withLock { file = nil }
    }

    /// Called (on any thread) after every change.
    public func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onChange = handler }
    }

    public func add(_ kind: RoutingEvent.Kind, _ message: String) {
        let (event, file, handler) = lock.withLock { () -> (RoutingEvent, URL?, (@Sendable () -> Void)?) in
            let event = RoutingEvent(id: nextID, date: Date(), kind: kind, message: message)
            nextID += 1
            events.append(event)
            if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
            return (event, self.file, onChange)
        }
        if let file { Self.append(event.line, to: file) }
        handler?()
    }

    public var recent: [RoutingEvent] { lock.withLock { events } }

    public func clear() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            events.removeAll()
            return onChange
        }
        handler?()
    }

    /// The saved log's last `count` lines (for `--diagnose`, which runs in another process).
    public static func savedLines(at file: URL, count: Int = limit) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }

    private static func append(_ line: String, to file: URL) {
        let data = Data((line + "\n").utf8)
        let manager = FileManager.default
        if !manager.fileExists(atPath: file.path) {
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: file.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: data)
        // Rough line count from the size: keep the file from growing without end.
        if size > UInt64(limit * 2 * 120) {
            let kept = savedLines(at: file, count: limit).joined(separator: "\n") + "\n"
            try? Data(kept.utf8).write(to: file, options: .atomic)
        }
    }
}

/// A plain-text report for bug reports: versions, devices, apps, the routing plan, recent events and the saved graph.
/// It contains device and app names; nothing else about the Mac.
public enum Diagnostics {
    public static func report(graph: Graph, inventory: Inventory, plan: RoutingPlan, statuses: [UUID: SinkStatus]?,
                              events: [String], appVersion: String?, bundledDriver: String?) -> String {
        var out: [String] = ["Junction diagnostic report", "Made: \(RoutingEvent.format(Date()))"]
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("Junction: \(appVersion ?? "unknown"); bundled driver: \(bundledDriver ?? "none")")
        switch inventory.driver {
        case .notInstalled: out.append("Installed driver: none")
        case .installed(let version): out.append("Installed driver: \(version)")
        }
        out.append("Routing: \(graph.isRoutingOn ? "on" : "off")")

        out += ["", "Virtual devices:"]
        for device in graph.virtualDevices {
            out.append("  \(device.name): \(device.channels) ch, \(Int(device.sampleRate)) Hz\(device.isEnabled ? "" : ", off")  \(device.uid)")
        }
        out += ["", "Audio devices:"]
        for device in inventory.devices {
            var marks: [String] = []
            if device.uid == inventory.defaultOutputUID { marks.append("default output") }
            if device.uid == inventory.defaultInputUID { marks.append("default input") }
            if device.isJunction { marks.append("Junction") }
            out.append("  \(device.name): in \(device.inputChannels), out \(device.outputChannels), \(Int(device.sampleRate)) Hz"
                       + (marks.isEmpty ? "" : " [\(marks.joined(separator: ", "))]") + "  \(device.uid)")
        }
        out += ["", "Apps using audio:"]
        for app in inventory.apps { out.append("  \(app.name)\(app.isPlaying ? " (playing)" : "")  \(app.bundleID)") }

        out += ["", "Routing plan:"]
        for sink in plan.sinks {
            var line = "  \(sink.name): \(sink.routes.count) route(s), \(sink.taps.count) tap(s), devices "
                + sink.subDevices.map { "\($0.uid)@\(Int($0.sampleRate))" }.joined(separator: ", ")
                + ", aggregate \(sink.inputChannels) in / \(sink.outputChannels) out"
            if !sink.converted.isEmpty {
                line += ", converted to \(Int(sink.sampleRate)): "
                    + sink.converted.map { "\($0.uid)@\(Int($0.sampleRate))" }.joined(separator: ", ")
            }
            if let frames = sink.bufferFrames { line += ", buffer \(frames)" }
            if let status = statuses?[sink.sinkNode] {
                line += status.state == .running ? ", running" : ", failed"
                if let latency = status.latency { line += String(format: ", about %.1f ms", latency * 1000) }
                if let message = status.message { line += ": \(message)" }
            }
            out.append(line)
        }
        if statuses == nil { out.append("  (statuses are only known inside the running app)") }
        for (node, issues) in plan.issues.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let title = graph.node(node).map { "\($0.kind)" } ?? node.uuidString
            for issue in issues { out.append("  issue on \(title): \(issue)") }
        }

        out += ["", "Recent events:"]
        out.append(contentsOf: events.isEmpty ? ["  (none)"] : events.map { "  " + $0 })

        out += ["", "graph.json:"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(graph), let json = String(data: data, encoding: .utf8) { out.append(json) }
        return out.joined(separator: "\n") + "\n"
    }
}
