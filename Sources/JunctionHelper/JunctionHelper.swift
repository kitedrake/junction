import AppKit
import AVFoundation
import CoreAudio
import JunctionCore

// Junction Helper: routing in the background. A UI-element app (no Dock icon) inside
// Junction.app/Contents/Library/LoginItems, started by launchd once Junction registers it with SMAppService.agent:
// at login, and whenever the app connects to its XPC service. It loads graph.json, plans and routes, follows Core
// Audio restarts, wake and device changes, and serves the app (see RoutingService). With "Keep routing after
// quitting" off it stops routing and quits once no app is connected.

@main
enum HelperMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = HelperDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var host: HelperHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { host = HelperHost() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { host?.stop() }
    }
}

@MainActor
final class HelperHost {
    static let keepRoutingKey = "keepRoutingAfterQuit"
    /// Without "keep routing", a helper that no app connects to within this time quits again.
    static let idleGrace: TimeInterval = 15

    private let service: RoutingService
    private let listener: NSXPCListener
    private var watcher: HAL.SystemWatcher?
    private var restartWatcher: HAL.SystemWatcher?
    private var deviceWatcher: HAL.DeviceWatcher?
    private var watchedUIDs: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var timers: [Timer] = []
    private var midiInput: MIDIInput?

    init() {
        let defaults = UserDefaults.standard
        let requirement = RoutingXPC.peerRequirement(identifier: RoutingXPC.appBundleIdentifier, teamID: RoutingXPC.ownTeamID())
        let environment = RoutingService.Environment(
            readInventory: { HAL.readInventory() },
            permission: { Self.permission(AVCaptureDevice.authorizationStatus(for: .audio)) },
            requestMicrophone: { done in
                NSApp.activate()  // the prompt comes from this process
                AVCaptureDevice.requestAccess(for: .audio) { _ in done() }
            },
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            clientRequirement: requirement)
        service = RoutingService(graph: Store().load() ?? Graph(), keepRouting: defaults.bool(forKey: Self.keepRoutingKey),
                                 environment: environment) { Router(onStatus: $0) }
        listener = NSXPCListener(machServiceName: RoutingXPC.machServiceName)
        service.onKeepRoutingChanged = { defaults.set($0, forKey: Self.keepRoutingKey) }
        service.onPlan = { plan in MainActor.assumeIsolated { HelperHost.current?.watchDevices(in: plan) } }
        service.onIdle = { MainActor.assumeIsolated { HelperHost.current?.quitIfIdle(after: 0.3) } }
        service.onOutdated = {  // after the reply has gone out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
        // MIDI while Junction is closed: the helper keeps the setup saved and the devices published itself.
        service.onMIDIChange = { old, new in
            try? Store().save(new)
            let enabled = { (graph: Graph) in graph.virtualDevices.map { "\($0.id):\($0.isEnabled)" } }
            if enabled(old) != enabled(new) {
                let devices = new.virtualDevices
                DispatchQueue.global().async { try? DriverClient.publish(devices) }
            }
        }
        Self.current = self
        service.start()
        listener.delegate = service
        listener.resume()
        midiInput = MIDIInput(name: RoutingXPC.helperDisplayName, queue: .main,
                              onMessages: { [service] messages, source in service.receiveMIDI(messages, from: source) },
                              onSources: { [service] sources in service.midiSourcesChanged(sources) })

        watcher = HAL.SystemWatcher(queue: .main) { [service] in service.systemChanged() }
        restartWatcher = HAL.SystemWatcher(selectors: [kAudioHardwarePropertyServiceRestarted], queue: .main) { [service] in
            MainActor.assumeIsolated { HelperHost.current?.watchedUIDs = [] }  // device IDs change: listen again
            service.coreAudioRestarted()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [service] _ in service.woke() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [service] _ in service.sendMeters() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [service] _ in
            service.refreshInventory()
            service.refreshPermission()
        })
        quitIfIdle(after: Self.idleGrace)
    }

    private static weak var current: HelperHost?

    func stop() {
        timers.forEach { $0.invalidate() }
        listener.invalidate()
    }

    /// A device a sink uses changing rate or channels changes the plan: notice it at once.
    private func watchDevices(in plan: RoutingPlan) {
        let uids = Set(plan.sinks.flatMap { ($0.subDevices + $0.converted).map(\.uid) })
        guard uids != watchedUIDs else { return }
        watchedUIDs = uids
        deviceWatcher = uids.isEmpty ? nil : HAL.DeviceWatcher(uids: uids, queue: .main) { [service] in service.systemChanged() }
    }

    /// Quits when no app is connected and routing shouldn't go on without one. launchd starts the helper again when
    /// the app next connects.
    private func quitIfIdle(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [service] in
            guard service.clientCount == 0, !service.keepRouting else { return }
            NSApp.terminate(nil)
        }
    }

    static func permission(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
    }
}
