import Foundation
import Security

// Password-free driver installs: Junction Driver Installer, a launch daemon inside Junction.app
// (Contents/Library/HelperTools/JunctionDriverDaemon), registered with SMAppService.daemon and approved by the user in
// System Settings › General › Login Items & Extensions. It runs as root and does three things only: install (or
// update) the driver from the copy inside its own Junction.app, remove it, and restart Core Audio. Requests name no
// paths. Before installing it copies the driver into a root-owned staging folder and checks that copy's signature
// against its own (same team, the driver's identifier), so nothing can be swapped in between. It accepts XPC only from
// Junction signed by the same team; an ad-hoc signed daemon accepts nobody (an ad-hoc signature proves nothing).

/// What the app calls on the daemon.
@objc public protocol DriverDaemonXPC {
    /// `request` is a JSON `DaemonRequest`; the reply a JSON `DaemonReply`.
    func handle(_ request: Data, reply: @escaping (Data) -> Void)
}

public enum DriverDaemon {
    /// Bumped when a message changes shape.
    public static let protocolVersion = 1
    /// The launchd label and the Mach service the daemon listens on.
    public static let label = "local.junction.driverd"
    public static let machServiceName = label
    /// In Junction.app/Contents/Library/LaunchDaemons, for `SMAppService.daemon(plistName:)`.
    public static let plistName = "local.junction.driverd.plist"
    /// The daemon inside Junction.app (signed with `label` as its identifier).
    public static let executablePath = "Contents/Library/HelperTools/JunctionDriverDaemon"
    /// The driver it installs: only ever this copy, inside the same Junction.app.
    public static let bundledDriverPath = "Contents/Resources/JunctionDriver.driver"
    /// Info.plist key of Junction.app: whether this build installs through the daemon (build.sh's DRIVER_DAEMON).
    public static let usesDaemonKey = "JunctionDriverDaemon"
    /// The name macOS shows for it.
    public static let displayName = "Junction Driver Installer"

    public static func interface() -> NSXPCInterface { NSXPCInterface(with: DriverDaemonXPC.self) }

    /// The Junction.app whose daemon executable is at `executable`, or nil when it isn't where build.sh puts it.
    public static func appBundle(containingExecutable executable: URL) -> URL? {
        let path = executable.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasSuffix("/" + executablePath) else { return nil }
        let app = URL(fileURLWithPath: String(path.dropLast(executablePath.count + 1)), isDirectory: true)
        return app.pathExtension == "app" ? app : nil
    }

    public static func bundledDriver(inApp app: URL) -> URL { app.appendingPathComponent(bundledDriverPath) }

    /// The requirement callers must meet: Junction, signed by the daemon's team. Nil when the daemon has no team
    /// (ad-hoc signed): then it accepts nobody.
    public static func clientRequirement(teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        return RoutingXPC.peerRequirement(identifier: RoutingXPC.appBundleIdentifier, teamID: teamID)
    }

    /// The requirement the app puts on the daemon: its identifier, and the app's team when there is one.
    public static func daemonRequirement(teamID: String?) -> String {
        RoutingXPC.peerRequirement(identifier: label, teamID: teamID)
    }
}

/// App to daemon. No request names a path: the daemon only ever installs the driver inside its own Junction.app.
public enum DaemonRequest: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int)
    /// Installs or updates the bundled driver, then restarts Core Audio. `allowOlder`: the user chose to replace a
    /// newer installed driver with this copy's.
    case installDriver(allowOlder: Bool)
    /// Removes the installed driver, then restarts Core Audio.
    case removeDriver
}

/// Daemon to app.
public enum DaemonReply: Codable, Equatable, Sendable {
    case welcome(protocolVersion: Int)
    case installed(version: String)
    case removed
    /// There was no driver to remove.
    case notInstalled
    /// The daemon wouldn't do it (a signature that doesn't match, an older driver, an unknown request).
    case refused(String)
    /// It tried and failed.
    case failed(String)
}

/// What a code signature says, as the daemon reads it.
public struct CodeSignature: Equatable, Sendable {
    /// The signature is intact and covers the code as it is now.
    public var isValid: Bool
    public var identifier: String?
    /// The signing team (nil when ad-hoc signed).
    public var teamID: String?

    public init(isValid: Bool, identifier: String?, teamID: String?) {
        self.isValid = isValid
        self.identifier = identifier
        self.teamID = teamID
    }

    public static let unsigned = CodeSignature(isValid: false, identifier: nil, teamID: nil)

    /// Reads the signature of the bundle or executable at `url`, checking it is intact.
    public static func read(_ url: URL) -> CodeSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        return read(code)
    }

    /// The signature of this process.
    public static func own() -> CodeSignature {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unsigned }
        return read(staticCode)
    }

    private static func read(_ code: SecStaticCode) -> CodeSignature {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let valid = SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return CodeSignature(isValid: false, identifier: nil, teamID: nil) }
        return CodeSignature(isValid: valid, identifier: info[kSecCodeInfoIdentifier as String] as? String,
                             teamID: info[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}

/// Whether the driver about to be installed is signed like the daemon (and so like the app that carries both).
public enum SignatureVerdict: Equatable, Sendable {
    case matches
    /// The daemon itself has no team (ad-hoc signed): it can't vouch for anything.
    case adHoc
    /// The driver's signature is missing or broken.
    case invalid
    case wrongIdentifier(String?)
    case otherTeam(String?)

    /// Why the daemon refuses, for the user.
    public var problem: String? {
        switch self {
        case .matches: nil
        case .adHoc: "This copy of Junction isn't signed by a developer team, so its driver installer can't check the driver."
        case .invalid: "The driver inside Junction isn't intact (its code signature doesn't check out)."
        case .wrongIdentifier(let identifier): "The driver inside Junction is signed as \(identifier ?? "nothing"), not as Junction's driver."
        case .otherTeam(let team): "The driver inside Junction is signed by \(team.map { "team \($0)" } ?? "nobody"), not by Junction's team."
        }
    }
}

/// The daemon's decisions, kept apart from what it does so they can be tested.
public enum DriverInstallPolicy {
    public static func verdict(driver: CodeSignature, own: CodeSignature) -> SignatureVerdict {
        guard own.isValid, let team = own.teamID, !team.isEmpty else { return .adHoc }
        guard driver.isValid else { return .invalid }
        guard driver.identifier == DriverClient.bundleID else { return .wrongIdentifier(driver.identifier) }
        guard driver.teamID == team else { return .otherTeam(driver.teamID) }
        return .matches
    }

    public enum Decision: Equatable, Sendable {
        case install(version: String)
        case refuse(String)
    }

    /// Whether to install the bundled driver over what is installed. The same version is installed again (Reinstall
    /// Driver…); a newer installed driver is replaced only when the user chose Install Older Driver…. An installed
    /// driver without a readable version is replaced.
    public static func decide(bundled: String?, installed: String?, allowOlder: Bool) -> Decision {
        guard let bundled, !bundled.isEmpty else { return .refuse("This copy of Junction doesn't contain the driver.") }
        if let installed, !allowOlder, DriverUpdate.compare(installed, bundled) == .orderedDescending {
            return .refuse("A newer driver (\(installed)) is installed than the one inside this copy of Junction (\(bundled)).")
        }
        return .install(version: bundled)
    }
}

/// What the daemon does as root, behind a protocol so tests can stand in for it.
public protocol PrivilegedActions: AnyObject, Sendable {
    /// The CFBundleShortVersionString of the driver bundle at `url`, nil when there is none.
    func driverVersion(at url: URL) -> String?
    /// Copies the driver at `source` into a root-owned staging folder next to the installed one; returns the copy.
    func stage(_ source: URL) throws -> URL
    func signature(of url: URL) -> CodeSignature
    /// The daemon's own signature, which build.sh makes the app's.
    func ownSignature() -> CodeSignature
    /// Replaces the installed driver with the staged copy.
    func commit(_ staged: URL) throws
    func discard(_ staged: URL)
    /// Removes the installed driver; false when there was none.
    func removeInstalled() throws -> Bool
    func restartCoreAudio()
}

/// Serves `DaemonRequest`s, one at a time, with `actions`.
public final class DriverDaemonService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// The Junction.app the daemon is inside.
    public let app: URL
    public let actions: PrivilegedActions
    /// Nil: refuse every connection (an ad-hoc signed daemon).
    public let clientRequirement: String?
    /// False only for tests and the self-test, which talk to an anonymous listener in their own process.
    public let checksClients: Bool
    public let queue = DispatchQueue(label: "local.junction.driverd.service")
    /// When the last request finished (the daemon quits after a while without any).
    public private(set) var lastActivity = Date()

    public init(app: URL, actions: PrivilegedActions, clientRequirement: String?, checksClients: Bool = true) {
        self.app = app
        self.actions = actions
        self.clientRequirement = clientRequirement
        self.checksClients = checksClients
    }

    public var installURL: URL { URL(fileURLWithPath: DriverClient.installPath) }

    /// Answers one request (on `queue`).
    public func perform(_ request: DaemonRequest) -> DaemonReply {
        defer { lastActivity = Date() }
        switch request {
        case .hello(let version):
            return version == DriverDaemon.protocolVersion
                ? .welcome(protocolVersion: DriverDaemon.protocolVersion)
                : .refused("Junction and its driver installer are different versions.")
        case .installDriver(let allowOlder):
            return install(allowOlder: allowOlder)
        case .removeDriver:
            do {
                guard try actions.removeInstalled() else { return .notInstalled }
                actions.restartCoreAudio()
                return .removed
            } catch {
                return .failed("Couldn't remove the driver: \(error.localizedDescription)")
            }
        }
    }

    private func install(allowOlder: Bool) -> DaemonReply {
        let source = DriverDaemon.bundledDriver(inApp: app)
        let decision = DriverInstallPolicy.decide(bundled: actions.driverVersion(at: source),
                                                  installed: actions.driverVersion(at: installURL), allowOlder: allowOlder)
        if case .refuse(let reason) = decision { return .refused(reason) }
        let staged: URL
        do {
            staged = try actions.stage(source)
        } catch {
            return .failed("Couldn't copy the driver: \(error.localizedDescription)")
        }
        // Check the copy that will be installed, not the original the user can still change.
        let verdict = DriverInstallPolicy.verdict(driver: actions.signature(of: staged), own: actions.ownSignature())
        guard verdict == .matches, let version = actions.driverVersion(at: staged) else {
            actions.discard(staged)
            return .refused(verdict.problem ?? "The driver copy has no version.")
        }
        do {
            try actions.commit(staged)
        } catch {
            actions.discard(staged)
            return .failed("Couldn't install the driver: \(error.localizedDescription)")
        }
        actions.restartCoreAudio()
        return .installed(version: version)
    }

    // MARK: NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if checksClients {
            guard let clientRequirement else { return false }
            connection.setCodeSigningRequirement(clientRequirement)
        }
        connection.exportedInterface = DriverDaemon.interface()
        connection.exportedObject = Exported(service: self)
        connection.resume()
        return true
    }

    private final class Exported: NSObject, DriverDaemonXPC, @unchecked Sendable {
        weak var service: DriverDaemonService?

        init(service: DriverDaemonService) { self.service = service }

        func handle(_ request: Data, reply: @escaping (Data) -> Void) {
            guard let service else { return }
            guard let decoded = try? JSONDecoder().decode(DaemonRequest.self, from: request) else {
                reply((try? JSONEncoder().encode(DaemonReply.refused("Unreadable request."))) ?? Data())
                return
            }
            service.queue.async {
                let answer = service.perform(decoded)
                reply((try? JSONEncoder().encode(answer)) ?? Data())
            }
        }
    }
}

/// The app's side: one request, one answer (or why there was none).
public final class DriverDaemonClient: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case reply(DaemonReply)
        /// The daemon couldn't be reached, didn't answer in time or answered nonsense.
        case unreachable(String)
    }

    private let makeConnection: () -> NSXPCConnection

    /// Talks to the daemon's Mach service; the daemon must meet `requirement`.
    public convenience init(requirement: String?) {
        self.init {
            let connection = NSXPCConnection(machServiceName: DriverDaemon.machServiceName, options: .privileged)
            if let requirement { connection.setCodeSigningRequirement(requirement) }
            return connection
        }
    }

    /// Talks to a listener in this process (tests and the self-test).
    public convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    init(makeConnection: @escaping () -> NSXPCConnection) {
        self.makeConnection = makeConnection
    }

    /// Says hello, then sends `request`; `completion` runs once, on `queue`. Installing restarts Core Audio, which takes
    /// a few seconds: `timeout` leaves room for it.
    public func send(_ request: DaemonRequest, timeout: TimeInterval = 30, queue: DispatchQueue = .main,
                     completion: @escaping @Sendable (Outcome) -> Void) {
        nonisolated(unsafe) let connection = makeConnection()
        connection.remoteObjectInterface = DriverDaemon.interface()
        connection.resume()
        let lock = NSLock()
        nonisolated(unsafe) var finished = false
        let finish: @Sendable (Outcome) -> Void = { outcome in
            guard lock.withLock({ () -> Bool in
                defer { finished = true }
                return !finished
            }) else { return }
            connection.invalidate()
            queue.async { completion(outcome) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            finish(.unreachable("\(DriverDaemon.displayName) couldn't be reached (\(error.localizedDescription))."))
        } as? DriverDaemonXPC
        guard let proxy, let hello = try? JSONEncoder().encode(DaemonRequest.hello(protocolVersion: DriverDaemon.protocolVersion)),
              let body = try? JSONEncoder().encode(request) else {
            return finish(.unreachable("\(DriverDaemon.displayName) couldn't be reached."))
        }
        proxy.handle(hello) { answer in
            switch try? JSONDecoder().decode(DaemonReply.self, from: answer) {
            case .welcome?:
                proxy.handle(body) { answer in
                    guard let reply = try? JSONDecoder().decode(DaemonReply.self, from: answer) else {
                        return finish(.unreachable("\(DriverDaemon.displayName) gave an unreadable answer."))
                    }
                    finish(.reply(reply))
                }
            case .refused(let reason)?: finish(.unreachable(reason))
            default: finish(.unreachable("\(DriverDaemon.displayName) didn't say hello."))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.unreachable("\(DriverDaemon.displayName) didn't answer within \(Int(timeout)) s."))
        }
    }
}

/// Whether the daemon can be used, as `SMAppService` reports it.
public enum DaemonApproval: Equatable, Sendable {
    case approved
    /// Registered, waiting for the user in System Settings › General › Login Items & Extensions.
    case requiresApproval
    case notRegistered
    case notFound
    case failed(String)
}

/// How Install Driver… and Uninstall Driver… run.
public enum DriverInstallRoute: Equatable, Sendable {
    /// Through the daemon: no password.
    case daemon
    /// Through macOS's administrator prompt (the scripts in Contents/Resources), and why.
    case administratorPrompt(String)

    /// The daemon is used only in builds made for it, once the user approved it; everything else asks for a password.
    public static func choose(buildUsesDaemon: Bool, daemonBundled: Bool,
                              approval: @autoclosure () -> DaemonApproval) -> DriverInstallRoute {
        if !buildUsesDaemon { return .administratorPrompt("This build installs the driver with an administrator password.") }
        if !daemonBundled { return .administratorPrompt("\(DriverDaemon.displayName) is missing from Junction.app.") }
        switch approval() {
        case .approved: return .daemon
        case .requiresApproval:
            return .administratorPrompt("\(DriverDaemon.displayName) is waiting for your approval in System Settings › General › Login Items & Extensions.")
        case .notRegistered: return .administratorPrompt("\(DriverDaemon.displayName) isn't registered with macOS.")
        case .notFound: return .administratorPrompt("macOS couldn't find \(DriverDaemon.displayName).")
        case .failed(let reason): return .administratorPrompt("\(DriverDaemon.displayName) couldn't be registered: \(reason)")
        }
    }

    /// What the app does with the daemon's answer.
    public enum Next: Equatable, Sendable {
        /// It worked; `message` for the log.
        case done(String)
        /// The daemon refused or failed: say why, and don't go around it with the password prompt (a refusal is
        /// usually a driver whose signature doesn't check out).
        case problem(String)
        /// The daemon couldn't be reached: ask for the password instead.
        case fallBack(String)
    }

    public static func next(after outcome: DriverDaemonClient.Outcome) -> Next {
        switch outcome {
        case .reply(.installed(let version)): .done("Installed driver \(version) without a password")
        case .reply(.removed): .done("Removed the driver")
        case .reply(.notInstalled): .done("The driver wasn't installed")
        case .reply(.refused(let reason)), .reply(.failed(let reason)): .problem(reason)
        case .reply(.welcome): .fallBack("\(DriverDaemon.displayName) gave an unexpected answer.")
        case .unreachable(let reason): .fallBack(reason)
        }
    }
}

/// The real thing, as root: files under /Library/Audio/Plug-Ins/HAL and Core Audio's launchd job. `halFolder` and
/// `setsRootOwnership` are for tests, which run in a temporary folder as the user.
public final class SystemPrivilegedActions: PrivilegedActions, @unchecked Sendable {
    public let halFolder: URL
    public let setsRootOwnership: Bool
    private let fileManager = FileManager.default

    public init(halFolder: URL = URL(fileURLWithPath: DriverClient.installPath).deletingLastPathComponent(),
                setsRootOwnership: Bool = true) {
        self.halFolder = halFolder
        self.setsRootOwnership = setsRootOwnership
    }

    var installed: URL { halFolder.appendingPathComponent("JunctionDriver.driver") }
    var staging: URL { halFolder.appendingPathComponent(".JunctionDriver.installing") }

    public func driverVersion(at url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    public func stage(_ source: URL) throws -> URL {
        try fileManager.createDirectory(at: halFolder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        if setsRootOwnership { try run("/usr/sbin/chown", ["-R", "root:wheel", staging.path]) }
        try run("/bin/chmod", ["-R", "go-w", staging.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
        return staging
    }

    public func signature(of url: URL) -> CodeSignature { CodeSignature.read(url) }

    public func ownSignature() -> CodeSignature { CodeSignature.own() }

    public func commit(_ staged: URL) throws {
        if fileManager.fileExists(atPath: installed.path) { try fileManager.removeItem(at: installed) }
        try fileManager.moveItem(at: staged, to: installed)
    }

    public func discard(_ staged: URL) { try? fileManager.removeItem(at: staged) }

    public func removeInstalled() throws -> Bool {
        guard fileManager.fileExists(atPath: installed.path) else { return false }
        try fileManager.removeItem(at: installed)
        return true
    }

    public func restartCoreAudio() {
        if (try? run("/bin/launchctl", ["kickstart", "-k", "system/com.apple.audio.coreaudiod"])) == nil {
            try? run("/usr/bin/killall", ["coreaudiod"])
        }
    }

    private struct ToolFailed: LocalizedError {
        let tool: String
        let status: Int32
        var errorDescription: String? { "\(tool) exited with status \(status)" }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ToolFailed(tool: (tool as NSString).lastPathComponent, status: process.terminationStatus) }
    }
}
