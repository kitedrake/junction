import AppKit
import Foundation
import JunctionCore
import ServiceManagement

/// Junction Driver Installer, which installs and removes the driver without a password in builds made for it
/// (build.sh's DRIVER_DAEMON): where it is, whether this build uses it, and registering it with macOS.
enum DriverInstaller {
    static var executableURL: URL { Bundle.main.bundleURL.appendingPathComponent(DriverDaemon.executablePath) }
    static var plistURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(DriverDaemon.plistName)")
    }

    static var buildUsesDaemon: Bool { Bundle.main.object(forInfoDictionaryKey: DriverDaemon.usesDaemonKey) as? Bool ?? false }

    static var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path) && FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static var daemon: SMAppService { SMAppService.daemon(plistName: DriverDaemon.plistName) }

    /// What macOS says about the daemon now, without registering it.
    static var approval: DaemonApproval { approval(daemon.status) }

    /// Registers the daemon unless it already is (macOS then asks the user to approve it in Login Items); returns
    /// where it stands.
    static func register() -> DaemonApproval {
        let daemon = daemon
        if daemon.status == .notRegistered || daemon.status == .notFound {
            do {
                try daemon.register()
            } catch {
                return daemon.status == .requiresApproval ? .requiresApproval : .failed(error.localizedDescription)
            }
        }
        return approval(daemon.status)
    }

    static func unregister() {
        let daemon = daemon
        guard daemon.status != .notRegistered, daemon.status != .notFound else { return }
        try? daemon.unregister()
    }

    private static func approval(_ status: SMAppService.Status) -> DaemonApproval {
        switch status {
        case .enabled: .approved
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// A client for the daemon, which must be signed like this app.
    static func client() -> DriverDaemonClient {
        DriverDaemonClient(requirement: DriverDaemon.daemonRequirement(teamID: RoutingXPC.ownTeamID()))
    }
}

/// What a build without CRASH_REPORT_URL does, and where a release build sends reports.
enum CrashReporting {
    static var destination: URL? { CrashReports.destination(info: Bundle.main.infoDictionary ?? [:]) }
}
