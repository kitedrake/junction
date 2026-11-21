import Foundation

// Opt-in crash reports. When Junction or Junction Helper crashes, macOS writes a crash log to
// ~/Library/Logs/DiagnosticReports (`Junction-<date>.ips`). With "Offer to send crash reports" on in Settings, the
// next launch finds the logs written since it last looked and offers a report: the diagnostic report (as `--diagnose`
// writes it) followed by each crash log in full, all shown before anything is sent. Release builds send it to
// CRASH_REPORT_URL (build.sh writes it into Info.plist); builds without one offer Copy Report instead.

/// One crash log macOS wrote for Junction or Junction Helper.
public struct CrashLog: Equatable, Sendable {
    public var file: URL
    /// "Junction" or "JunctionHelper".
    public var process: String
    public var date: Date
    public var appVersion: String?
    /// The whole file, as macOS wrote it.
    public var contents: String

    public init(file: URL, process: String, date: Date, appVersion: String?, contents: String) {
        self.file = file
        self.process = process
        self.date = date
        self.appVersion = appVersion
        self.contents = contents
    }
}

public enum CrashReports {
    /// The processes whose crashes Junction offers to report (the driver installer runs as root: macOS keeps its
    /// crash logs where the app can't read them).
    public static let processNames: Set<String> = ["Junction", "JunctionHelper"]
    public static let bundleIdentifiers: Set<String> = [RoutingXPC.appBundleIdentifier, RoutingXPC.helperBundleIdentifier]
    /// UserDefaults: whether crash reports are offered (off until the user turns it on).
    public static let optInKey = "offersCrashReports"
    /// UserDefaults: crashes up to this date have been offered (or happened before the user opted in).
    public static let checkedKey = "crashReportsCheckedUntil"
    /// Info.plist key build.sh writes from CRASH_REPORT_URL.
    public static let urlKey = "JunctionCrashReportURL"
    /// macOS's crash type for a process that crashed (as opposed to hangs, spins and the like).
    static let crashBugType = "309"

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Reads a crash log: an `.ips` file (a JSON header line, then the report) or an older `.crash` text file. Nil
    /// when it isn't a crash of Junction or Junction Helper. `modified` is the date used when the file has none.
    public static func parse(_ contents: String, file: URL, modified: Date) -> CrashLog? {
        if file.pathExtension == "ips" {
            guard let headerLine = contents.split(separator: "\n", maxSplits: 1).first,
                  let header = try? JSONSerialization.jsonObject(with: Data(headerLine.utf8)) as? [String: Any],
                  header["bug_type"] as? String == crashBugType else { return nil }
            let name = header["app_name"] as? String ?? header["name"] as? String
            let bundleID = header["bundleID"] as? String
            guard let name, processNames.contains(name) || bundleID.map(bundleIdentifiers.contains) == true else { return nil }
            let date = (header["timestamp"] as? String).flatMap(ipsDate) ?? modified
            return CrashLog(file: file, process: name, date: date, appVersion: header["app_version"] as? String,
                            contents: contents)
        }
        if file.pathExtension == "crash" {
            func field(_ key: String) -> String? {
                contents.split(separator: "\n").first { $0.hasPrefix(key + ":") }
                    .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
            }
            // "Process:               Junction [1234]"
            guard let process = field("Process")?.split(separator: " ").first.map(String.init),
                  processNames.contains(process) else { return nil }
            let version = field("Version")?.split(separator: " ").first.map(String.init)
            return CrashLog(file: file, process: process, date: modified, appVersion: version, contents: contents)
        }
        return nil
    }

    /// The crash logs in `folder` from after `since`, oldest first.
    public static func find(in folder: URL = defaultFolder, since: Date) -> [CrashLog] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var found: [CrashLog] = []
        // `Junction-<date>.ips`, or `Junction_<date>.crash` from older macOS versions.
        let name = { (file: URL) in file.lastPathComponent }
        for file in files where processNames.contains(where: { name(file).hasPrefix($0 + "-") || name(file).hasPrefix($0 + "_") }) {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified > since,
                  let data = try? Data(contentsOf: file), data.count < 8_000_000,
                  let crash = parse(String(decoding: data, as: UTF8.self), file: file, modified: modified),
                  crash.date > since else { continue }
            found.append(crash)
        }
        return found.sorted { $0.date < $1.date }
    }

    /// The report the user sees in full and may send: the diagnostic report, then each crash log as macOS wrote it.
    public static func compose(diagnostic: String, crashes: [CrashLog]) -> String {
        var out = ["Junction crash report", "Crashes: " + crashes.map { crash in
            "\(crash.process) \(crash.appVersion ?? "?") at \(RoutingEvent.format(crash.date))"
        }.joined(separator: "; "), ""]
        out.append(diagnostic.hasSuffix("\n") ? String(diagnostic.dropLast()) : diagnostic)
        for crash in crashes {
            out += ["", "==== Crash log: \(crash.file.lastPathComponent) ====", crash.contents]
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Where this build sends reports: CRASH_REPORT_URL from its Info.plist (https only), nil when it has none.
    public static func destination(info: [String: Any]) -> URL? {
        guard let text = (info[urlKey] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The upload: the report as plain text, nothing else.
    public static func request(sending report: String, to url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(report.utf8)
        return request
    }

    /// `2026-11-20 10:15:02.00 +0100`, as `.ips` headers write it.
    static func ipsDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// A crash report offered at launch.
public struct CrashOffer: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case send(URL)
        case copy
    }

    public var report: String
    public var crashes: [CrashLog]
    /// Nil in builds without CRASH_REPORT_URL.
    public var destination: URL?

    public init(report: String, crashes: [CrashLog], destination: URL?) {
        self.report = report
        self.crashes = crashes
        self.destination = destination
    }

    /// Sending (release builds) and copying; builds without an address only copy.
    public var actions: [Action] { (destination.map { [.send($0)] } ?? []) + [.copy] }

    /// Marks these crashes as offered, whatever the user chose.
    public var offeredUntil: Date { crashes.map(\.date).max() ?? Date() }
}

/// Settings › Uninstall Junction…: what goes, in order.
public enum CleanUninstall {
    public enum Step: Equatable, Sendable {
        /// Through the driver installer when it is approved, otherwise the administrator prompt.
        case removeDriver
        case stopRouting
        case unregisterRoutingHelper
        case unregisterDriverInstaller
        case unregisterLoginItem
        /// graph.json, its scenes and the routing log (Application Support/Junction).
        case removeSavedSetup
        /// Junction's and Junction Helper's preferences.
        case removePreferences
        case quit
    }

    /// The driver goes first, while the installer that can remove it without a password is still registered.
    public static func steps(driverInstalled: Bool, removeSettings: Bool) -> [Step] {
        var steps: [Step] = driverInstalled ? [.removeDriver] : []
        steps += [.stopRouting, .unregisterRoutingHelper, .unregisterDriverInstaller, .unregisterLoginItem]
        if removeSettings { steps += [.removeSavedSetup, .removePreferences] }
        return steps + [.quit]
    }

    /// The preference domains a full uninstall removes.
    public static let preferenceDomains = [RoutingXPC.appBundleIdentifier, RoutingXPC.helperBundleIdentifier]
}
