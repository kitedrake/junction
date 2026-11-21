import Foundation
import Security

// Routing can run in a background helper (Junction.app/Contents/Library/LoginItems/JunctionHelper.app), registered
// with SMAppService.agent and reached over XPC, so it keeps going after the app quits. The app stays the editor: it
// saves graph.json and sends every change to the helper; the helper plans and routes, follows Core Audio restarts,
// wake and device changes itself, and sends back statuses, meters, routing events and its Microphone permission.
// Messages are Codable values sent as JSON `Data`, so the XPC interface has one method each way.

/// What the app calls on the helper.
@objc public protocol RoutingHelperXPC {
    /// `request` is a JSON `RoutingRequest`; the reply a JSON `RoutingReply`.
    func handle(_ request: Data, reply: @escaping (Data) -> Void)
}

/// What the helper calls on the app.
@objc public protocol RoutingAppXPC {
    /// `notice` is a JSON `RoutingNotice`.
    func receive(_ notice: Data)
}

public enum RoutingXPC {
    /// Bumped when a message changes shape; an app and a helper that disagree don't talk (the app routes itself).
    public static let protocolVersion = 1
    public static let appBundleIdentifier = "local.junction.app"
    public static let helperBundleIdentifier = "local.junction.helper"
    /// The launchd label and the Mach service the helper listens on.
    public static let machServiceName = "local.junction.helper"
    /// In Junction.app/Contents/Library/LaunchAgents, for `SMAppService.agent(plistName:)`.
    public static let agentPlistName = "local.junction.helper.plist"
    /// The helper inside Junction.app, and its executable.
    public static let helperBundlePath = "Contents/Library/LoginItems/JunctionHelper.app"
    public static let helperExecutablePath = helperBundlePath + "/Contents/MacOS/JunctionHelper"
    /// Info.plist key of Junction.app: whether this build routes in the helper (see build.sh's ROUTING_HELPER).
    public static let usesHelperKey = "JunctionRoutingHelper"
    /// The helper's name, as macOS shows it in permission prompts and System Settings.
    public static let helperDisplayName = "Junction Helper"

    public static func helperInterface() -> NSXPCInterface { NSXPCInterface(with: RoutingHelperXPC.self) }
    public static func appInterface() -> NSXPCInterface { NSXPCInterface(with: RoutingAppXPC.self) }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// The code-signing requirement the other side of a connection must meet: its bundle identifier and, when this
    /// copy is signed by a team (Developer ID, Apple Development), the same team. Ad-hoc builds can only check the
    /// identifier; they route in the app unless built with ROUTING_HELPER=1.
    public static func peerRequirement(identifier: String, teamID: String?) -> String {
        let quoted = "\"" + identifier.replacingOccurrences(of: "\"", with: "") + "\""
        guard let teamID, !teamID.isEmpty else { return "identifier \(quoted)" }
        let team = "\"" + teamID.replacingOccurrences(of: "\"", with: "") + "\""
        return "identifier \(quoted) and anchor apple generic and certificate leaf[subject.OU] = \(team)"
    }

    /// The team that signed this process, if any (nil when ad-hoc signed).
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// macOS's Microphone permission for the process that routes (it covers every audio input).
public enum PermissionState: String, Codable, Sendable {
    case allowed, denied, restricted, notAsked
}

/// App to helper.
public enum RoutingRequest: Codable, Equatable, Sendable {
    /// First message on a connection. `appVersion`: the app's CFBundleVersion; `keepRouting`: whether routing goes on
    /// after the app quits.
    case hello(protocolVersion: Int, appVersion: String?, keepRouting: Bool)
    /// The whole setup, sent whenever it changes (the helper plans with what it sees on the system).
    case graph(Graph)
    /// Build every destination again (the user asked, or a permission was granted).
    case rebuildAll
    /// Ask macOS for the Microphone permission (the prompt names the helper).
    case requestMicrophone
    case keepRouting(Bool)
    /// The app is quitting: routing stops unless it should keep going.
    case goodbye
}

/// What the helper knows when an app says hello.
public struct HelperState: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var processName: String
    public var processID: Int32
    public var keepRouting: Bool
    public var permission: PermissionState
    public var statuses: [UUID: SinkStatus]

    public init(protocolVersion: Int = RoutingXPC.protocolVersion, processName: String, processID: Int32,
                keepRouting: Bool, permission: PermissionState, statuses: [UUID: SinkStatus]) {
        self.protocolVersion = protocolVersion
        self.processName = processName
        self.processID = processID
        self.keepRouting = keepRouting
        self.permission = permission
        self.statuses = statuses
    }
}

/// Helper to app, in answer to a request.
public enum RoutingReply: Codable, Equatable, Sendable {
    case welcome(HelperState)
    case done
    case refused(String)
    /// The helper running is another version than the app (left running across an app update): it stops routing and
    /// quits, so the app's next connection starts the helper now inside the app.
    case outdated(String)
}

/// A routing event as the helper logged it.
public struct LoggedEvent: Codable, Equatable, Sendable {
    public var date: Date
    public var kind: RoutingEvent.Kind
    public var message: String

    public init(date: Date, kind: RoutingEvent.Kind, message: String) {
        self.date = date
        self.kind = kind
        self.message = message
    }
}

/// Helper to app, whenever something changes.
public enum RoutingNotice: Codable, Equatable, Sendable {
    case statuses([UUID: SinkStatus])
    /// Peak levels since the last notice.
    case meters([PortKey: Float])
    case events([LoggedEvent])
    case permission(PermissionState)
}

/// Whether the helper can be registered, as `SMAppService` reports it.
public enum HelperRegistration: Equatable, Sendable {
    case enabled
    /// The user turned Junction off under System Settings › General › Login Items & Extensions.
    case requiresApproval
    case notRegistered
    case notFound
    case failed(String)
}

/// Where routing runs.
public enum RoutingPlacement: Equatable, Sendable {
    case helper
    /// In the app itself, and why.
    case inProcess(String)

    public var usesHelper: Bool { self == .helper }

    /// The helper runs routing only in builds made for it, once macOS has it registered; everything else (plain
    /// builds, tests, snapshot mode, a helper the user turned off) routes inside the app as before.
    public static func choose(isDemo: Bool, isTesting: Bool, buildUsesHelper: Bool, helperBundled: Bool,
                              registration: @autoclosure () -> HelperRegistration) -> RoutingPlacement {
        if isDemo { return .inProcess("Snapshot mode routes nothing.") }
        if isTesting { return .inProcess("Tests route inside the process.") }
        if !buildUsesHelper { return .inProcess("This build routes inside Junction.") }
        if !helperBundled { return .inProcess("Junction Helper is missing from Junction.app.") }
        switch registration() {
        case .enabled: return .helper
        case .requiresApproval:
            return .inProcess("Junction Helper is turned off in System Settings › General › Login Items & Extensions.")
        case .notRegistered: return .inProcess("Junction Helper isn't registered with macOS.")
        case .notFound: return .inProcess("macOS couldn't find Junction Helper.")
        case .failed(let reason): return .inProcess("Junction Helper couldn't be registered: \(reason)")
        }
    }
}
