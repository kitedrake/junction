import AppKit
import Foundation
import JunctionCore
import ServiceManagement

/// Junction Helper, which routes in the background in builds made for it (build.sh's ROUTING_HELPER): where it is,
/// whether this build uses it, and registering it with macOS.
enum RoutingHelper {
    static let keepRoutingKey = "keepRoutingAfterQuit"

    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent(RoutingXPC.helperBundlePath) }
    static var agentPlistURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(RoutingXPC.agentPlistName)")
    }

    static var buildUsesHelper: Bool { Bundle.main.object(forInfoDictionaryKey: RoutingXPC.usesHelperKey) as? Bool ?? false }

    static var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent(RoutingXPC.helperExecutablePath).path)
            && FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    static var isTesting: Bool { NSClassFromString("XCTestCase") != nil }

    private static var agent: SMAppService { SMAppService.agent(plistName: RoutingXPC.agentPlistName) }

    /// Registers the helper unless it already is, or the user turned it off in Login Items (then it stays off).
    static func register() -> HelperRegistration {
        let agent = agent
        if agent.status == .notRegistered || agent.status == .notFound {
            do {
                try agent.register()
            } catch {
                return agent.status == .requiresApproval ? .requiresApproval : .failed(error.localizedDescription)
            }
        }
        switch agent.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// A client for the helper, which must be signed like this app (same team, when there is one).
    static func client(keepRouting: Bool, handler: @escaping (RoutingClient.Event) -> Void) -> RoutingClient {
        let requirement = RoutingXPC.peerRequirement(identifier: RoutingXPC.helperBundleIdentifier, teamID: RoutingXPC.ownTeamID())
        return RoutingClient(requirement: requirement, keepRouting: keepRouting,
                             appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                             callbackQueue: .main, handler: handler)
    }
}

/// Whether macOS opened Junction as a login item: then it starts in the menu bar, without its window.
enum LoginLaunch {
    @MainActor private(set) static var isActive = false

    /// Call from `applicationWillFinishLaunching`, while the launch event is current.
    @MainActor static func detect() {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return }
        isActive = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
