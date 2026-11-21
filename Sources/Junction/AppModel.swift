import AppKit
import AVFoundation
import CoreAudio
import JunctionCore
import Observation
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

typealias Selection = CanvasSelection

/// Which side of the canvas a new node goes on: sources feed the virtual device, outputs play it.
enum NodeRole: String, Codable {
    case source, output
}

/// The app's state: the graph (saved), what is on the system, the routing plan and how it runs.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel(demo: ProcessInfo.processInfo.environment["JUNCTION_SNAPSHOT"] != nil)

    var graph: Graph {
        didSet { graphChanged(from: oldValue) }
    }
    private(set) var inventory = Inventory()
    private(set) var plan = RoutingPlan()
    private(set) var statuses: [UUID: SinkStatus] = [:]
    var meters: [PortKey: Float] = [:]
    var selection: Selection?
    /// Nodes copied or cut, ready to paste onto any canvas (also on the pasteboard).
    private(set) var clipboard: Clipboard?
    /// Bumped on every edit, undo and redo, so the Edit menu's Undo and Redo titles follow.
    private(set) var historyVersion = 0
    /// A text field is being edited: the Edit menu passes Undo, Cut, Copy, Paste… on to it.
    private(set) var isEditingText = false
    /// The virtual device whose canvas is shown, as picked in the sidebar.
    private var pickedCanvas: UUID?
    /// How far each canvas is zoomed and panned (not saved: a canvas opens at actual size, top left).
    private var viewports: [UUID: CanvasViewport] = [:]
    /// The size of the canvas area in the window, for zooming about its centre and for the minimap.
    var canvasViewSize = CGSize.zero
    var showMinimap = UserDefaults.standard.object(forKey: "showMinimap") as? Bool ?? true {
        didSet { if !isDemo { UserDefaults.standard.set(showMinimap, forKey: "showMinimap") } }
    }
    /// A virtual device waiting for the user to confirm its deletion.
    var deviceToDelete: UUID?
    var showInspector = true
    /// The template sheet that is open.
    var template: TemplateKind?
    /// The scene being named (a new one, or one being renamed).
    var sceneNaming: SceneNaming?
    /// The node the plugin picker adds an Audio Unit to (the sheet is open while set).
    var pluginPicker: PluginPickerRequest?
    /// The installed effect Audio Units, read when the picker opens (made-up ones in snapshot mode).
    private(set) var plugins: [PluginInfo] = []
    /// Effects offered for bypass that the user chose to keep running.
    private(set) var keptStallingEffects: Set<UUID> = []
    /// The control MIDI learn is waiting for a MIDI message for (nil: not learning).
    private(set) var midiLearning: MIDITarget?
    /// The MIDI controllers the process that routes listens to.
    private(set) var midiSources: [String] = []
    /// A problem to show in an alert (driver install, publishing).
    var alert: String?
    /// macOS's Microphone permission, which covers every audio input: microphones, interfaces, Junction's devices.
    private(set) var microphoneAccess: AVAuthorizationStatus = .authorized
    /// App and System Audio nodes that have heard nothing for a while although apps they capture are playing: most
    /// likely Junction may not record system audio.
    private(set) var silentTaps: Set<UUID> = []
    /// The routing log (newest last), for the Routing Log window.
    private(set) var events: [RoutingEvent] = []
    private(set) var isInstallingDriver = false
    /// What macOS says about Junction Driver Installer, which installs the driver without a password (nil: this build
    /// doesn't use it).
    private(set) var driverInstaller: DaemonApproval?
    /// Settings › Uninstall Junction… is under way.
    private(set) var isUninstalling = false
    /// A crash report waiting for the user to read, then send, copy or leave.
    var crashOffer: CrashOffer?
    /// Opt-in: after a crash, the next launch offers a report.
    var offersCrashReports = UserDefaults.standard.bool(forKey: CrashReports.optInKey) {
        didSet {
            guard !isDemo, offersCrashReports != oldValue else { return }
            UserDefaults.standard.set(offersCrashReports, forKey: CrashReports.optInKey)
            // Only crashes from now on are offered.
            if offersCrashReports { UserDefaults.standard.set(Date(), forKey: CrashReports.checkedKey) }
        }
    }
    /// The known chat apps (`Templates.chatApps`) installed on this Mac.
    private(set) var installedChatApps: [AppRef] = []
    /// The known music apps (`Templates.dawApps`) installed on this Mac.
    private(set) var installedDAWApps: [AppRef] = []
    /// Where routing runs: in Junction Helper (in the background) or in the app, and why.
    private(set) var placement: RoutingPlacement = .inProcess("Junction hasn't started routing yet.")
    /// What macOS said when Junction registered its helper (nil: this build doesn't use it).
    private(set) var helperRegistration: HelperRegistration?
    /// Routing goes on after Junction quits (and resumes at login). Only Junction Helper can do that.
    var keepRoutingAfterQuit = UserDefaults.standard.bool(forKey: RoutingHelper.keepRoutingKey) {
        didSet {
            guard !isDemo, keepRoutingAfterQuit != oldValue else { return }
            UserDefaults.standard.set(keepRoutingAfterQuit, forKey: RoutingHelper.keepRoutingKey)
            helper?.setKeepRouting(keepRoutingAfterQuit)
        }
    }

    /// Screenshots and demos: made-up devices, nothing saved, nothing routed.
    let isDemo: Bool
    private let store = Store()
    /// Routing inside the app (plain builds, or when the helper isn't available)…
    @ObservationIgnored private var router: Router?
    /// …or in Junction Helper, over XPC.
    @ObservationIgnored private var helper: RoutingClient?
    /// Peak levels the helper sent since the meters were last read.
    @ObservationIgnored private var helperMeters: [PortKey: Float] = [:]
    /// MIDI input and control, while routing runs inside the app (Junction Helper has its own otherwise).
    @ObservationIgnored private var midiInput: MIDIInput?
    @ObservationIgnored private var midiControl = MIDIControl()
    @ObservationIgnored private var watcher: HAL.SystemWatcher?
    @ObservationIgnored private var restartWatcher: HAL.SystemWatcher?
    /// Watches the rate and channel layout of every device a sink uses, so a change rebuilds that sink at once.
    @ObservationIgnored private var deviceWatcher: HAL.DeviceWatcher?
    @ObservationIgnored private var watchedUIDs: Set<String> = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// When each running app or System Audio node last carried sound (or started running).
    @ObservationIgnored private var heard: [UUID: Date] = [:]
    @ObservationIgnored private var askedForMicrophone = false
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var lastCoreAudioRestart: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The parameters each Audio Unit effect had when its state was last read (see `refreshEffectStates`).
    @ObservationIgnored private var capturedParameters: [UUID: [String: Double]] = [:]
    /// Whether each plugin is installed, by component, and when that was last looked up.
    @ObservationIgnored private var installedPlugins: [String: (installed: Bool, checked: Date)] = [:]
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var started = false
    /// Virtual devices Junction just created, turned on or reformatted, and until when its own sample rate wins.
    @ObservationIgnored private var assertRateUntil: [UUID: Date] = [:]
    /// Virtual devices whose volume or mute Junction just changed, and until when its own values win.
    @ObservationIgnored private var assertControlsUntil: [UUID: Date] = [:]
    /// Tells when the driver changes its list by itself (a volume set in Sound settings).
    @ObservationIgnored private var configWatcher: DriverClient.ConfigWatcher?
    /// Undo and redo of every canvas and sidebar edit.
    @ObservationIgnored private var history: EditHistory!
    @ObservationIgnored private var textObservers: [NSObjectProtocol] = []
    /// The pasteboard's change count when Junction last put nodes on it.
    @ObservationIgnored private var clipboardChangeCount = 0
    /// What to do when Junction Driver Installer can't be reached: the same change with the administrator prompt.
    @ObservationIgnored private var driverChangeWithPassword: (() -> Void)?
    /// Called once a driver install or removal is over, with whether it worked.
    @ObservationIgnored private var driverChangeDone: ((Bool) -> Void)?
    /// Junction uninstalled itself: nothing is saved any more.
    @ObservationIgnored private var isUninstalled = false
    private static let log = Logger(subsystem: "local.junction", category: "routing")

    init(demo: Bool) {
        isDemo = demo
        graph = Graph()
        history = EditHistory(read: { [unowned self] in graph }, write: { [unowned self] restored in
            // Undo puts back the canvases; whether routing is on stays as it is.
            var restored = restored
            restored.isRoutingOn = graph.isRoutingOn
            graph = restored
            historyVersion += 1
        })
    }

    // MARK: Life cycle

    func start() {
        guard !started else { return }
        started = true
        if isDemo { EventLog.shared.keepInMemoryOnly() }
        EventLog.shared.observe {
            Task { @MainActor in AppModel.shared.events = EventLog.shared.recent }
        }
        refreshInstalledChatApps()
        for (name, editing) in [(NSText.didBeginEditingNotification, true), (NSText.didEndEditingNotification, false)] {
            textObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.isEditingText = editing }
            })
        }
        if isDemo {
            Demo.load(into: self)
            return
        }
        if let saved = store.load() {
            graph = saved
        } else {
            graph = Graph()
        }
        history.clear()
        // Only a build made for the helper asks macOS to register it; the others route here as before.
        let asksForHelper = RoutingHelper.buildUsesHelper && RoutingHelper.isBundled && !RoutingHelper.isTesting
        helperRegistration = asksForHelper ? RoutingHelper.register() : nil
        placement = RoutingPlacement.choose(isDemo: isDemo, isTesting: RoutingHelper.isTesting,
                                            buildUsesHelper: RoutingHelper.buildUsesHelper, helperBundled: RoutingHelper.isBundled,
                                            registration: helperRegistration ?? .notRegistered)
        if placement.usesHelper {
            startHelper()
        } else {
            if case .inProcess(let reason) = placement, RoutingHelper.buildUsesHelper {
                note("Routing runs inside Junction: \(reason)", .warning)
            }
            startRoutingInProcess()
        }
        // Builds made for the driver installer register it now, so Settings can show whether it's approved.
        if DriverInstaller.buildUsesDaemon, DriverInstaller.isBundled, !RoutingHelper.isTesting {
            driverInstaller = DriverInstaller.register()
        }
        // Rates, volumes and mutes changed from outside while Junction wasn't running (Audio MIDI Setup, a DAW, Sound
        // settings) are kept.
        if let published = DriverClient.publishedDevices() {
            var adopted = graph
            for index in adopted.virtualDevices.indices {
                guard let live = published.first(where: { $0.id == adopted.virtualDevices[index].id }) else { continue }
                if VirtualDevice.sampleRateChoices.contains(live.sampleRate) { adopted.virtualDevices[index].sampleRate = live.sampleRate }
                if driverReportsControls { Self.adoptControls(of: live, into: &adopted.virtualDevices[index]) }
            }
            if adopted != graph { graph = adopted }
        }
        refreshInventory()  // publishes the devices once it sees the driver
        watcher = HAL.SystemWatcher(queue: .main) {
            Task { @MainActor in AppModel.shared.scheduleRefresh() }
        }
        restartWatcher = HAL.SystemWatcher(selectors: [kAudioHardwarePropertyServiceRestarted], queue: .main) {
            Task { @MainActor in AppModel.shared.coreAudioRestarted() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.note("Woke from sleep; checking routing")
                AppModel.shared.router?.resetHealth()  // the router rebuilds any sink whose audio doesn't resume
                AppModel.shared.scheduleRefresh()
            }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.pollMeters() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.refreshInventory()
                AppModel.shared.refreshInstalledChatApps()
                AppModel.shared.refreshPermissions()
                AppModel.shared.checkSilentTaps()
            }
        })
        if helper == nil { microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio) }
        replan(force: true)
        refreshPermissions()
        // Once devices and the plan are known, so the report shows them.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            AppModel.shared.checkForCrashes()
        }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        restartTask?.cancel()
        router?.stopAll()
        saveNow()
        helper?.goodbye()  // the helper stops routing unless it should keep going
    }

    // MARK: Where routing runs

    private func startRoutingInProcess() {
        router = Router { statuses in
            Task { @MainActor in AppModel.shared.statuses = statuses }
        }
        router?.observeEffectStates { effect, state in
            Task { @MainActor in AppModel.shared.adoptEffectState(effect, state) }
        }
        guard !isDemo, !RoutingHelper.isTesting else { return }
        midiControl.learn(midiLearning)  // learning that had started in the helper goes on here
        midiInput = MIDIInput(name: "Junction", queue: .main, onMessages: { messages, source in
            MainActor.assumeIsolated { AppModel.shared.receiveMIDI(messages, from: source) }
        }, onSources: { sources in
            MainActor.assumeIsolated { AppModel.shared.midiSources = sources }
        })
    }

    /// Connects to Junction Helper (launchd starts it); it routes what the app sends it.
    private func startHelper() {
        let client = RoutingHelper.client(keepRouting: keepRoutingAfterQuit) { event in
            MainActor.assumeIsolated { AppModel.shared.helperSaid(event) }
        }
        helper = client
        client.connect()
        client.send(graph: graph)  // sent once the helper answers
    }

    private func helperSaid(_ event: RoutingClient.Event) {
        switch event {
        case .connected(let state):
            statuses = state.statuses
            microphoneAccess = Self.authorization(state.permission)
            midiSources = state.midiSources
            if midiLearning != nil { helper?.learnMIDI(midiLearning) }  // after the helper restarted
            Self.log.notice("Connected to \(state.processName, privacy: .public) (process \(state.processID))")
            refreshPermissions()
        case .notice(.statuses(let fresh)):
            statuses = fresh
        case .notice(.meters(let fresh)):
            for (key, value) in fresh { helperMeters[key] = max(helperMeters[key] ?? 0, value) }
        case .notice(.events(let logged)):
            for event in logged { EventLog.shared.add(event.kind, event.message, date: event.date, persist: false) }
        case .notice(.permission(let permission)):
            microphoneAccess = Self.authorization(permission)
            refreshPermissions()
        case .notice(.effectState(let effect, let state)):
            adoptEffectState(effect, state)
        case .notice(.midi(let actions)):
            adoptMIDI(actions)
        case .notice(.midiSources(let sources)):
            midiSources = sources
        case .unavailable(let reason):
            // Route here instead, so audio keeps going.
            guard helper != nil else { return }
            helper = nil
            helperMeters = [:]
            placement = .inProcess(reason)
            note("\(reason) Routing runs inside Junction instead.", .warning)
            microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
            startRoutingInProcess()
            replan(force: true)
            refreshPermissions()
        }
    }

    /// The name macOS shows in permission prompts and System Settings for the process that routes.
    var routingProcessName: String { placement.usesHelper ? RoutingXPC.helperDisplayName : "Junction" }

    private static func authorization(_ permission: PermissionState) -> AVAuthorizationStatus {
        switch permission {
        case .allowed: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notAsked: .notDetermined
        }
    }

    /// Demo mode: pretend macOS gave this answer about the Microphone permission (for screenshots).
    func setDemoMicrophoneAccess(_ status: AVAuthorizationStatus) {
        guard isDemo else { return }
        microphoneAccess = status
    }

    /// Demo mode sets the system picture directly.
    func setDemoState(inventory: Inventory, statuses: [UUID: SinkStatus], meters: [PortKey: Float]) {
        self.inventory = inventory
        self.statuses = statuses
        self.meters = meters
        replan(force: true)
    }

    // MARK: Changes

    private func graphChanged(from old: Graph) {
        if let selection, selection.pruned(to: graph) != selection { self.selection = selection.pruned(to: graph) }
        if !isDemo {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
            if old.isRoutingOn != graph.isRoutingOn { note(graph.isRoutingOn ? "Routing turned on" : "Routing turned off") }
            if old.virtualDevices != graph.virtualDevices {
                let until = Date().addingTimeInterval(3)
                for device in graph.virtualDevices {
                    guard let before = old.virtualDevice(device.id), !Self.sameControls(device, before) else { continue }
                    assertControlsUntil[device.id] = until
                }
                let changed = graph.virtualDevices.filter { device in
                    guard let before = old.virtualDevice(device.id) else { return true }
                    return (device.isEnabled && !before.isEnabled) || device.sampleRate != before.sampleRate
                        || device.channels != before.channels
                }
                publishVirtualDevices(changed: Set(changed.map(\.id)))
            }
        }
        replan()
    }

    private func saveNow() {
        guard !isDemo, !isUninstalled else { return }
        refreshEffectStates()
        do {
            try store.save(graph)
        } catch {
            alert = "Couldn't save the routing setup: \(error.localizedDescription)"
        }
    }

    /// Reads the whole state of Audio Unit effects whose parameters changed since it was last read (a unit is made
    /// here, not rendered), so the file keeps it. Not an undo step: the state follows the parameters.
    private func refreshEffectStates() {
        var updated = graph
        var changed = false
        for node in updated.nodes.indices {
            for index in updated.nodes[node].effects.indices {
                let effect = updated.nodes[node].effects[index]
                guard effect.kind?.isBuiltIn == false,
                      effect.state == nil || capturedParameters[effect.id] != effect.parameters else { continue }
                capturedParameters[effect.id] = effect.parameters
                guard let state = EffectUnit.capturedState(effect), state != effect.state else { continue }
                updated.nodes[node].effects[index].state = state
                changed = true
            }
        }
        if changed { graph = updated }
    }

    private func replan(force: Bool = false) {
        helper?.send(graph: graph)  // the helper plans for itself; it gets every change (sent only when it differs)
        let new = Planner.plan(graph, inventory: inventory)
        guard force || new != plan else { return }
        plan = new
        router?.apply(new)
        watchDevices(in: new)
    }

    /// A device on a running sink changing rate or channels changes the plan; notice it at once instead of at the
    /// next periodic refresh. Changed sinks are rebuilt (cross-faded); the others keep running.
    private func watchDevices(in plan: RoutingPlan) {
        guard !isDemo else { return }
        let uids = Set(plan.sinks.flatMap { ($0.subDevices + $0.converted).map(\.uid) })
        guard uids != watchedUIDs else { return }
        watchedUIDs = uids
        deviceWatcher = uids.isEmpty ? nil : HAL.DeviceWatcher(uids: uids, queue: .main) {
            Task { @MainActor in AppModel.shared.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            refreshPending = false
            refreshInventory()
            router?.processesChanged()
        }
    }

    func refreshInventory() {
        guard !isDemo else { return }
        let fresh = HAL.readInventory()
        guard fresh != inventory else {
            reconcileControls()
            return
        }
        let driverAppeared = !inventory.driver.isInstalled && fresh.driver.isInstalled
        inventory = fresh
        // Remember the current shape of devices on the canvas, for when they are unplugged.
        var updated = graph
        for index in updated.nodes.indices {
            guard case .device(let ref) = updated.nodes[index].kind, let live = fresh.device(ref.uid), live.ref != ref else { continue }
            updated.nodes[index].kind = .device(live.ref)
        }
        if updated != graph { graph = updated }
        if fresh.driver.isInstalled, configWatcher == nil {
            configWatcher = DriverClient.ConfigWatcher(queue: .main) {
                Task { @MainActor in AppModel.shared.scheduleRefresh() }
            }
        }
        if driverAppeared {
            // Devices the driver doesn't have yet will appear now; Core Audio may give them a remembered rate.
            let published = Set((DriverClient.publishedDevices() ?? []).map(\.id))
            publishVirtualDevices(changed: Set(graph.virtualDevices.filter { !published.contains($0.id) }.map(\.id)))
        }
        replan()
        reconcileSampleRates()
        reconcileControls()
    }

    /// Driver 0.2 and newer report volume and mute; older ones don't have them.
    private var driverReportsControls: Bool {
        let driver = inventory.driver.isInstalled ? inventory.driver : DriverClient.status()
        guard case .installed(let version) = driver else { return false }
        return DriverUpdate.compare(version, "0.2.0").map { $0 != .orderedAscending } ?? false
    }

    private static func sameControls(_ a: VirtualDevice, _ b: VirtualDevice) -> Bool {
        a.outputVolume == b.outputVolume && a.outputMuted == b.outputMuted && a.inputVolume == b.inputVolume
            && a.inputMuted == b.inputMuted
    }

    private static func adoptControls(of live: VirtualDevice, into device: inout VirtualDevice) {
        device.outputVolume = live.outputVolume
        device.outputMuted = live.outputMuted
        device.inputVolume = live.inputVolume
        device.inputMuted = live.inputMuted
    }

    /// Volume and mute can change outside Junction (Sound settings, the volume keys, Audio MIDI Setup): the driver
    /// keeps them in its list, and Junction takes them over, except shortly after changing them itself.
    private func reconcileControls() {
        guard !isDemo, inventory.driver.isInstalled, driverReportsControls,
              let published = DriverClient.publishedDevices() else { return }
        let now = Date()
        assertControlsUntil = assertControlsUntil.filter { $0.value > now }
        var adopted = graph
        for index in adopted.virtualDevices.indices {
            let device = adopted.virtualDevices[index]
            guard device.isEnabled, assertControlsUntil[device.id] == nil,
                  let live = published.first(where: { $0.id == device.id }), !Self.sameControls(device, live) else { continue }
            Self.adoptControls(of: live, into: &adopted.virtualDevices[index])
        }
        if adopted != graph { graph = adopted }
    }

    /// Core Audio can change a virtual device's sample rate behind Junction's back: when a device appears it puts back
    /// the rate it remembers for that device, and Audio MIDI Setup or a DAW can set it. Shortly after Junction creates,
    /// turns on or reformats a device its own rate wins; later outside changes are adopted, so Junction doesn't fight
    /// another app over the rate.
    private func reconcileSampleRates() {
        guard !isDemo, inventory.driver.isInstalled else { return }
        let now = Date()
        assertRateUntil = assertRateUntil.filter { $0.value > now }
        var adopted = graph
        for (index, device) in graph.virtualDevices.enumerated() where device.isEnabled {
            guard let rate = inventory.device(device.uid)?.sampleRate, rate > 0, rate != device.sampleRate else { continue }
            if assertRateUntil[device.id] != nil {
                let uid = device.uid, wanted = device.sampleRate
                Task.detached { HAL.setNominalSampleRate(uid: uid, wanted) }
            } else if VirtualDevice.sampleRateChoices.contains(rate) {
                adopted.virtualDevices[index].sampleRate = rate
            }
        }
        if adopted != graph { graph = adopted }
    }

    /// Apps installed or removed while Junction runs show up within a few seconds. Demo mode uses made-up apps.
    private func refreshInstalledChatApps() {
        func installed(_ apps: [AppRef], demo: Set<String>) -> [AppRef] {
            apps.filter { app in
                isDemo ? demo.contains(app.bundleID) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
            }
        }
        let chat = installed(Templates.chatApps, demo: Demo.installedChatApps)
        if chat != installedChatApps { installedChatApps = chat }
        let daws = installed(Templates.dawApps, demo: Demo.installedDAWApps)
        if daws != installedDAWApps { installedDAWApps = daws }
    }

    /// The apps to offer for leaving out of a stream: using audio now, installed chat apps, and `picked`.
    func chatCandidates(picked: [AppRef] = []) -> [AppRef] {
        Templates.chatCandidates(usingAudio: inventory.apps.map(\.ref), installedChatApps: installedChatApps, picked: picked)
    }

    /// Asks for any app (one the chat list doesn't know) to leave out.
    func chooseApp() -> AppRef? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "Choose an app to leave out of the stream."
        panel.prompt = "Leave Out"
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return AppRef(bundleID: bundleID, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }

    /// Core Audio restarted (a driver install, update or removal, or a crash): every tap, aggregate device and IOProc
    /// Junction had is gone. Routing is rebuilt once devices are back, and what failed is tried again a little later.
    private func coreAudioRestarted() {
        guard !isDemo else { return }
        lastCoreAudioRestart = Date()
        note("Core Audio restarted; rebuilding routing", .warning)
        router?.forgetAfterRestart()  // at once, so no refresh in between tries to stop the dead sinks
        watchedUIDs = []  // device IDs change: listen again on the next plan
        configWatcher = nil
        restartTask?.cancel()
        restartTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            refreshInventory()
            publishVirtualDevices()
            replan(force: true)  // builds every sink that isn't running
            Self.log.notice("Rebuilding \(self.plan.sinks.count, privacy: .public) destination(s) after the restart")
            for delay in [2.0, 4.0] {  // devices that come back late
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                replan(force: true)  // builds sinks that failed; running ones only get their gains again
            }
        }
    }

    private func pollMeters() {
        guard graph.isRoutingOn, router != nil || helper != nil else {
            if !meters.isEmpty { meters = [:] }
            return
        }
        let fresh: [PortKey: Float]
        if let router {
            fresh = router.takeMeters()
        } else {
            fresh = helperMeters
            helperMeters = [:]
        }
        let now = Date()
        for (key, value) in fresh where key.isOutput && value > 0.0005 { heard[key.node] = now }
        var next: [PortKey: Float] = [:]
        for key in Set(fresh.keys).union(meters.keys) {
            let value = max(fresh[key] ?? 0, (meters[key] ?? 0) * 0.72)
            if value > 0.0005 { next[key] = value }
        }
        if next != meters { meters = next }
    }

    // MARK: Permissions

    enum PrivacyPane: String {
        case microphone = "Privacy_Microphone"
        case systemAudio = "Privacy_ScreenCapture"  // Screen & System Audio Recording
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        guard !isDemo, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether routing reads any audio input: a sink's aggregate reads its device's own inputs and every source device,
    /// and a converted device is read on its own.
    var needsMicrophone: Bool {
        plan.sinks.contains { !$0.converted.isEmpty || $0.subDevices.contains { $0.inputChannels > 0 } }
    }

    /// Follows the Microphone permission. When it is granted, every sink is built again (one that started without it
    /// may be running on silence). When routing needs it and macOS hasn't asked yet, asks now; the banner says why.
    /// With Junction Helper it is the helper's permission that counts: the helper reports it and rebuilds by itself.
    func refreshPermissions() {
        guard !isDemo else { return }
        if helper == nil {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status != microphoneAccess {
                let granted = status == .authorized
                microphoneAccess = status
                note("Microphone permission: \(Self.describe(status))", status == .authorized ? .info : .warning)
                if granted { router?.rebuildAll() }
            }
        }
        if microphoneAccess == .notDetermined, needsMicrophone, graph.isRoutingOn, !askedForMicrophone { requestMicrophone() }
    }

    static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    /// Writes to the system log and the routing log.
    func note(_ message: String, _ kind: RoutingEvent.Kind = .info) {
        Self.log.notice("\(message, privacy: .public)")
        EventLog.shared.add(kind, message)
    }

    /// The text of `Junction --diagnose`, with what only the running app knows (statuses, the log in memory).
    func diagnosticReport() -> String {
        Diagnostics.report(graph: graph, inventory: inventory, plan: plan, statuses: statuses,
                           events: EventLog.shared.recent.map(\.line), appVersion: Self.appVersion,
                           bundledDriver: DriverClient.bundledVersion)
    }

    nonisolated static var appVersion: String? {
        guard let info = Bundle.main.infoDictionary, let version = info["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info["CFBundleVersion"] as? String, build != version else { return version }
        return "\(version) (build \(build))"
    }

    /// Asks macOS for the Microphone permission for the process that routes: the prompt names it.
    func requestMicrophone() {
        guard !isDemo else { return }
        askedForMicrophone = true
        if let helper {
            helper.requestMicrophone()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in AppModel.shared.refreshPermissions() }
        }
    }

    /// There is no way to ask macOS whether Junction may record system audio: without the permission, taps simply
    /// deliver silence. So an app or System Audio node that has heard nothing for 8 s while apps it captures are
    /// playing gets a hint (an app can also play silence, so the hint stays a question).
    func checkSilentTaps() {
        guard !isDemo else { return }
        let now = Date()
        var running: Set<UUID> = []
        if graph.isRoutingOn {
            for sink in plan.sinks where statuses[sink.sinkNode]?.state == .running {
                running.formUnion(sink.taps.map(\.node))
            }
        }
        heard = heard.filter { running.contains($0.key) }
        for node in running where heard[node] == nil { heard[node] = now }
        let playing = inventory.apps.filter { $0.isPlaying && $0.bundleID != Bundle.main.bundleIdentifier }
        var silent: Set<UUID> = []
        for id in running {
            guard let node = graph.node(id), let last = heard[id], now.timeIntervalSince(last) > 8 else { continue }
            switch node.kind {
            case .application(let app):
                if playing.contains(where: { $0.bundleID == app.bundleID }) { silent.insert(id) }
            case .systemAudio(let excluded):
                if playing.contains(where: { app in !excluded.contains { $0.bundleID == app.bundleID } }) { silent.insert(id) }
            default:
                break
            }
        }
        if silent != silentTaps { silentTaps = silent }
    }

    // MARK: Driver

    /// Sends the device list to the driver. `changed` names the devices whose sample rate Junction should insist on
    /// for the next few seconds (all of them when nil).
    private func publishVirtualDevices(changed: Set<UUID>? = nil) {
        guard !isDemo, inventory.driver.isInstalled else { return }
        let until = Date().addingTimeInterval(5)
        for id in changed ?? Set(graph.virtualDevices.map(\.id)) { assertRateUntil[id] = until }
        let devices = graph.virtualDevices
        Task.detached {
            do {
                try DriverClient.publish(devices)
            } catch {
                let message = error.localizedDescription
                await MainActor.run { AppModel.shared.alert = message }
                return
            }
            // A device that just appeared may be switched to a remembered rate a moment later.
            for delay in [1.0, 2.5] {
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run { AppModel.shared.refreshInventory() }
            }
        }
    }

    var bundledDriverVersion: String? { DriverClient.bundledVersion }

    var driverUpdate: DriverUpdate { DriverUpdate(installed: inventory.driver, bundled: bundledDriverVersion) }

    func installDriver() {
        guard let driver = DriverClient.bundledDriverURL,
              let script = Bundle.main.url(forResource: "install-driver", withExtension: "sh")
        else {
            alert = "This copy of Junction doesn't contain the driver. Build it with build.sh."
            return
        }
        var allowOlder = false
        if case .appIsOlder = driverUpdate { allowOlder = true }  // the user picked Install Older Driver…
        changeDriver(.installDriver(allowOlder: allowOlder)) {
            AppModel.shared.runPrivileged(script: script, arguments: [driver.path], prompt: "Junction wants to install its audio driver.")
        }
    }

    func uninstallDriver() { removeDriver(done: nil) }

    private func removeDriver(done: ((Bool) -> Void)?) {
        guard let script = Bundle.main.url(forResource: "uninstall-driver", withExtension: "sh") else {
            done?(false)
            return
        }
        changeDriver(.removeDriver, done: done) {
            AppModel.shared.runPrivileged(script: script, arguments: [], prompt: "Junction wants to remove its audio driver.")
        }
    }

    /// Installs or removes the driver through Junction Driver Installer when this build has it and the user approved
    /// it; otherwise, or when it can't be reached, through macOS's administrator prompt (`withPassword`).
    private func changeDriver(_ request: DaemonRequest, done: ((Bool) -> Void)? = nil, withPassword: @escaping () -> Void) {
        guard !isDemo, !isInstallingDriver else {
            done?(false)
            return
        }
        driverChangeDone = done
        if DriverInstaller.buildUsesDaemon, DriverInstaller.isBundled, !RoutingHelper.isTesting {
            driverInstaller = DriverInstaller.register()
        }
        let route = DriverInstallRoute.choose(buildUsesDaemon: DriverInstaller.buildUsesDaemon,
                                              daemonBundled: DriverInstaller.isBundled,
                                              approval: driverInstaller ?? .notRegistered)
        guard route == .daemon else {
            if case .administratorPrompt(let reason) = route, DriverInstaller.buildUsesDaemon {
                note("\(reason) Asking for an administrator password instead.", .warning)
            }
            withPassword()
            return
        }
        isInstallingDriver = true
        driverChangeWithPassword = withPassword
        DriverInstaller.client().send(request) { outcome in
            Task { @MainActor in AppModel.shared.driverInstallerAnswered(outcome) }
        }
    }

    private func driverInstallerAnswered(_ outcome: DriverDaemonClient.Outcome) {
        let withPassword = driverChangeWithPassword
        driverChangeWithPassword = nil
        switch DriverInstallRoute.next(after: outcome) {
        case .done(let message):
            note(message)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))  // coreaudiod restarts
                AppModel.shared.driverChanged(succeeded: true, problem: nil)
            }
        case .problem(let reason):
            note("\(DriverDaemon.displayName): \(reason)", .error)
            driverChanged(succeeded: false, problem: reason)
        case .fallBack(let reason):
            isInstallingDriver = false
            note("\(reason) Asking for an administrator password instead.", .warning)
            withPassword?()
        }
    }

    /// Runs a bundled script as root after macOS asks for an administrator password. Core Audio restarts, so all
    /// sound stops for a moment.
    private func runPrivileged(script: URL, arguments: [String], prompt: String) {
        func literal(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let words = ([script.path] + arguments).map { "quoted form of \(literal($0))" }.joined(separator: " & \" \" & ")
        let source = "do shell script \"/bin/sh \" & \(words) with prompt \(literal(prompt)) with administrator privileges"
        isInstallingDriver = true
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message = error?[NSAppleScript.errorMessage] as? String
            let cancelled = (error?[NSAppleScript.errorNumber] as? Int) == -128
            let succeeded = error == nil
            try? await Task.sleep(for: .seconds(2))  // coreaudiod restarts
            await MainActor.run {
                AppModel.shared.driverChanged(succeeded: succeeded, problem: cancelled ? nil : message)
            }
        }
    }

    /// After a driver install or removal: follow the new state and rebuild routing (the change restarts Core Audio).
    private func driverChanged(succeeded: Bool, problem: String?) {
        isInstallingDriver = false
        if let problem { alert = problem }
        let done = driverChangeDone
        driverChangeDone = nil
        refreshInventory()
        publishVirtualDevices()
        // Rebuild routing even if the restart notice didn't arrive.
        let noticed = lastCoreAudioRestart.map { Date().timeIntervalSince($0) < 15 } ?? false
        if succeeded, !noticed, !isUninstalling {
            note("No restart notice after the driver change; rebuilding routing anyway", .warning)
            coreAudioRestarted()
            helper?.rebuildAll()
        }
        done?(succeeded)
    }

    // MARK: Uninstalling

    /// Settings › Uninstall Junction…: removes the driver, Junction Helper, the driver installer and the login item,
    /// and with `removeSettings` the saved setup and preferences too, then quits. The user moves the app to the Bin.
    func uninstallJunction(removeSettings: Bool) {
        guard !isDemo, !isUninstalling else { return }
        let driverInstalled = inventory.driver.isInstalled || FileManager.default.fileExists(atPath: DriverClient.installPath)
        isUninstalling = true
        note("Uninstalling Junction\(removeSettings ? " and its settings" : "")")
        uninstall(CleanUninstall.steps(driverInstalled: driverInstalled, removeSettings: removeSettings)[...])
    }

    private func uninstall(_ steps: ArraySlice<CleanUninstall.Step>) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        switch step {
        case .removeDriver:
            removeDriver { removed in
                let model = AppModel.shared
                guard removed else {
                    // Cancelled or failed: nothing else has been removed yet.
                    model.isUninstalling = false
                    model.note("Uninstalling stopped: the driver wasn't removed.", .warning)
                    return
                }
                model.uninstall(rest)
            }
            return
        case .stopRouting:
            timers.forEach { $0.invalidate() }
            timers.removeAll()
            restartTask?.cancel()
            router?.stopAll()
            router = nil
            helper?.goodbye()
            helper = nil
        case .unregisterRoutingHelper:
            RoutingHelper.unregister()
        case .unregisterDriverInstaller:
            DriverInstaller.unregister()
        case .unregisterLoginItem:
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try? SMAppService.mainApp.unregister()
            }
        case .removeSavedSetup:
            isUninstalled = true
            saveTask?.cancel()
            EventLog.shared.keepInMemoryOnly()  // so the routing log doesn't write its file again
            try? FileManager.default.removeItem(at: store.folder)
        case .removePreferences:
            isUninstalled = true
            for domain in CleanUninstall.preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        case .quit:
            let done = NSAlert()
            done.messageText = "Junction is uninstalled"
            done.informativeText = isUninstalled
                ? "Its driver, helpers, saved setup and settings are gone. Move Junction to the Bin to finish."
                : "Its driver and helpers are gone; your setup stays in case you install Junction again. Move Junction to the Bin to finish."
            done.runModal()
            NSApp.terminate(nil)
            return
        }
        uninstall(rest)
    }

    // MARK: Crash reports

    /// With crash reports on: crash logs macOS wrote for Junction or Junction Helper since the last look become an offer.
    func checkForCrashes() {
        guard !isDemo, offersCrashReports, !RoutingHelper.isTesting, crashOffer == nil else { return }
        guard let since = UserDefaults.standard.object(forKey: CrashReports.checkedKey) as? Date else {
            UserDefaults.standard.set(Date(), forKey: CrashReports.checkedKey)
            return
        }
        let crashes = CrashReports.find(since: since)
        guard !crashes.isEmpty else { return }
        note("Found \(crashes.count) crash log\(crashes.count == 1 ? "" : "s") from \(Set(crashes.map(\.process)).sorted().joined(separator: " and "))")
        crashOffer = CrashOffer(report: CrashReports.compose(diagnostic: diagnosticReport(), crashes: crashes),
                                crashes: crashes, destination: CrashReporting.destination)
    }

    /// The offer was answered (sent, copied or left): its crashes aren't offered again.
    func finishCrashOffer() {
        guard let crashOffer else { return }
        if !isDemo { UserDefaults.standard.set(crashOffer.offeredUntil, forKey: CrashReports.checkedKey) }
        self.crashOffer = nil
    }

    /// Sends the report exactly as shown. Returns why it couldn't, or nil once it's sent.
    func sendCrashReport(_ offer: CrashOffer) async -> String? {
        guard !isDemo, let destination = offer.destination else { return "This copy of Junction has no address to send reports to." }
        do {
            let (_, response) = try await URLSession.shared.data(for: CrashReports.request(sending: offer.report, to: destination))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return "The report wasn't accepted (HTTP \(status)). Copy it instead?" }
            note("Sent a crash report")
            return nil
        } catch {
            return "Couldn't send the report: \(error.localizedDescription)"
        }
    }

    /// Snapshot mode: the Settings and crash-offer states to show.
    func setDemoCrashOffer(_ offer: CrashOffer?) {
        guard isDemo else { return }
        crashOffer = offer
    }

    func setDemoDriverInstaller(_ approval: DaemonApproval?, offersCrashReports offers: Bool) {
        guard isDemo else { return }
        driverInstaller = approval
        offersCrashReports = offers
    }

    // MARK: Editing

    var info: NodeInfo { NodeInfo(graph: graph, inventory: inventory) }

    func node(_ id: UUID) -> Node? { graph.node(id) }

    // MARK: Canvases

    /// The virtual device whose canvas is shown: the one picked in the sidebar, else the first.
    var canvas: UUID? {
        if let pickedCanvas, graph.virtualDevice(pickedCanvas) != nil { return pickedCanvas }
        return graph.virtualDevices.first?.id
    }

    var canvasDevice: VirtualDevice? { canvas.flatMap(graph.virtualDevice) }

    /// "<app> through <device>" sources the shown canvas can use: apps playing into Junction's other devices.
    var appsThroughOtherDevices: [AppThroughDevice] {
        inventory.appsThroughDevices(graph.virtualDevices.filter { $0.id != canvas && $0.isEnabled })
    }
    var canvasNodes: [Node] { canvas.map(graph.nodes(on:)) ?? [] }
    var canvasCables: [Cable] { canvas.map(graph.cables(on:)) ?? [] }

    // MARK: Zoom and pan

    /// The shown canvas's zoom and scroll position. Setting it keeps the canvas within reach.
    var viewport: CanvasViewport {
        get { canvas.flatMap { viewports[$0] } ?? CanvasViewport() }
        set {
            guard let canvas else { return }
            let clamped = newValue.clamped(content: canvasContentSize, viewSize: canvasViewSize)
            if viewports[canvas] != clamped { viewports[canvas] = clamped }
        }
    }

    /// The shown canvas's drawing area.
    var canvasContentSize: CGSize { CanvasGeometry.contentSize(of: canvasNodes, info: info) }

    private var viewCenter: CGPoint { CGPoint(x: canvasViewSize.width / 2, y: canvasViewSize.height / 2) }

    /// ⌘+ and ⌘−: one step about the middle of the canvas area.
    func zoom(in zoomIn: Bool) { viewport = viewport.stepped(in: zoomIn, about: viewCenter) }

    /// ⌘0.
    func zoomToActualSize() { viewport = viewport.zoomed(to: 1, about: viewCenter) }

    /// Every node in view, no larger than actual size.
    func zoomToFit() {
        guard let bounds = CanvasGeometry.bounds(of: canvasNodes, info: info) else { return }
        viewport = CanvasViewport.fitting(bounds, in: canvasViewSize)
    }

    func showCanvas(_ device: UUID) {
        guard device != canvas else { return }
        pickedCanvas = device
        selection = nil
    }

    /// Adds a node to the shown canvas and wires it to the virtual device: a source into it, an output out of it
    /// (`role` decides for hardware that has both sides). `point` is where it goes; nil finds a free spot.
    @discardableResult
    func addNode(_ kind: NodeKind, as role: NodeRole? = nil, at point: CGPoint? = nil) -> UUID? {
        guard let canvas, let device = graph.deviceNode(canvas) else {
            alert = "Create a virtual device first: each one has its own canvas."
            return nil
        }
        if case .virtualDevice = kind {  // only the canvas's own device belongs here, and it is already there
            selection = .node(device.id)
            return device.id
        }
        let ports = info.ports(Node(kind: kind))
        let role = role ?? (ports.outputs > 0 && ports.inputs == 0 ? .source : .output)
        let spot = point ?? freeSpot(role: role, canvas: canvas)
        let node = Node(kind: kind, x: spot.x, y: spot.y, canvas: canvas)
        let inventory = inventory
        edit("Add \(info.title(node))") { graph in
            graph.nodes.append(node)
            graph.cables += role == .source
                ? Rules.busCables(from: node.id, to: device.id, graph: graph, inventory: inventory)
                : Rules.busCables(from: device.id, to: node.id, graph: graph, inventory: inventory)
        }
        selection = .node(node.id)
        return node.id
    }

    /// Something dragged from the sidebar and dropped on the shown canvas at `point` (canvas coordinates): it lands
    /// with its title under the pointer. Dropped on a cable it goes onto that cable (see `Editing.insert`); otherwise,
    /// or when the cable refuses it, it is wired to the device as `addNode` would. The canvas's own device moves to the
    /// drop point. Returns why it couldn't go where it was dropped, if it couldn't.
    @discardableResult
    func drop(_ kind: NodeKind, as role: NodeRole?, at point: CGPoint) -> String? {
        guard let canvas, let device = graph.deviceNode(canvas) else {
            alert = "Create a virtual device first: each one has its own canvas."
            return nil
        }
        let origin = CanvasGeometry.dropOrigin(point)
        if case .virtualDevice(let id) = kind {
            guard id == canvas else { return "Virtual devices don't feed each other: each one has its own canvas." }
            moveNodes([device.id: origin])
            endEditing()
            selection = .node(device.id)
            return nil
        }
        let node = Node(kind: kind, x: origin.x, y: origin.y, canvas: canvas)
        let ports = info.ports(node)
        let role = role ?? (ports.outputs > 0 && ports.inputs == 0 ? .source : .output)
        let hit = CanvasGeometry.cable(at: point, among: canvasCables, graph: graph,
                                       tolerance: CanvasGeometry.dropTolerance / viewport.scale)
        let inventory = inventory
        var problem: Rules.Problem?
        edit("Add \(info.title(node))") { graph in
            graph.nodes.append(node)
            if let hit {
                problem = Editing.insert(node.id, onto: hit, graph: &graph, inventory: inventory)
                if problem == nil { return }
            }
            graph.cables += role == .source
                ? Rules.busCables(from: node.id, to: device.id, graph: graph, inventory: inventory)
                : Rules.busCables(from: device.id, to: node.id, graph: graph, inventory: inventory)
        }
        selection = .node(node.id)
        return problem.map { "It couldn't go onto that cable: \($0.message)" }
    }

    /// A node with no cables yet, let go over a cable: it goes onto that cable. Returns why not, if it can't.
    @discardableResult
    func insertOnCable(_ id: UUID) -> String? {
        guard let node = graph.node(id), !isDeviceNode(node),
              !graph.cables.contains(where: { $0.from.node == id || $0.to.node == id }) else { return nil }
        let titlePoint = CGPoint(x: node.x + 30, y: node.y + CanvasMetrics.header / 2)
        let others = canvasCables
        guard let hit = CanvasGeometry.cable(at: titlePoint, among: others, graph: graph,
                                             tolerance: CanvasGeometry.dropTolerance / viewport.scale)
        else { return nil }
        var updated = graph
        if let problem = Editing.insert(id, onto: hit, graph: &updated, inventory: inventory) {
            return "It couldn't go onto that cable: \(problem.message)"
        }
        edit("Insert on Cable") { $0 = updated }
        return nil
    }

    /// Sources go on the left, outputs on the right, below what is already there.
    private func freeSpot(role: NodeRole, canvas: UUID) -> CGPoint {
        let column = role == .source ? CanvasColumn.sources : CanvasColumn.outputs
        let bottom = graph.nodes(on: canvas).filter { abs($0.x - column) < 150 }
            .map { $0.y + Double(NodeLayout.height(for: info.ports($0))) }.max() ?? 20
        return CGPoint(x: column, y: bottom + 30)
    }

    // MARK: Undo

    /// Applies a user's edit to the graph as one undo step (several, with the same `key` in a row, make one step: a
    /// drag, a fader). Routing, inventory and driver updates change `graph` directly and aren't undone.
    @discardableResult
    private func edit(_ name: String, coalescing key: String? = nil, _ change: (inout Graph) -> Void) -> Bool {
        // A mapping whose node, cable, effect, device or scene went goes with it (in the same undo step).
        let changed = history.perform(name, coalescing: key) { graph in
            change(&graph)
            graph.pruneMIDI()
        }
        if changed { historyVersion += 1 }
        return changed
    }

    /// A drag or a fader was let go: the next change is a new undo step.
    func endEditing() { history.endCoalescing() }

    var canUndo: Bool { _ = historyVersion; return history.canUndo }
    var canRedo: Bool { _ = historyVersion; return history.canRedo }
    var undoTitle: String { _ = historyVersion; return history.canUndo ? history.undoManager.undoMenuItemTitle : "Undo" }
    var redoTitle: String { _ = historyVersion; return history.canRedo ? history.undoManager.redoMenuItemTitle : "Redo" }

    func undo() {
        history.undo()
        historyVersion += 1
    }

    func redo() {
        history.redo()
        historyVersion += 1
    }

    // MARK: Editing

    /// Moves nodes to new top-left corners (one undo step per drag, see `endEditing`).
    func moveNodes(_ positions: [UUID: CGPoint]) {
        edit(positions.count == 1 ? "Move" : "Move Nodes", coalescing: "move") { graph in
            for index in graph.nodes.indices {
                guard let point = positions[graph.nodes[index].id] else { continue }
                graph.nodes[index].x = max(0, point.x)
                graph.nodes[index].y = max(0, point.y)
            }
        }
    }

    func updateNode(_ id: UUID, _ name: String = "Change Node", _ change: (inout Node) -> Void) {
        edit(name, coalescing: "node \(id) \(name)") { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            change(&graph.nodes[index])
        }
    }

    // MARK: Effects

    func addEffect(_ kind: EffectKind, to node: UUID) {
        updateNode(node, "Add \(kind.title)") { $0.effects.append(Effect(kind)) }
        endEditing()
    }

    func removeEffect(_ effect: UUID, from node: UUID) {
        let title = self.node(node)?.effects.first { $0.id == effect }?.kind?.title ?? "Effect"
        updateNode(node, "Remove \(title)") { $0.effects.removeAll { $0.id == effect } }
        endEditing()
    }

    /// Moves an effect earlier (-1) or later (+1) in its chain.
    func moveEffect(_ effect: UUID, in node: UUID, by offset: Int) {
        updateNode(node, "Move Effect") { node in
            guard let index = node.effects.firstIndex(where: { $0.id == effect }) else { return }
            let target = index + offset
            guard node.effects.indices.contains(target) else { return }
            node.effects.swapAt(index, target)
        }
        endEditing()
    }

    func setEffectBypass(_ effect: UUID, in node: UUID, _ bypass: Bool) {
        updateNode(node, bypass ? "Bypass Effect" : "Turn On Effect") { node in
            guard let index = node.effects.firstIndex(where: { $0.id == effect }) else { return }
            node.effects[index].bypass = bypass
        }
        endEditing()
    }

    /// A parameter while its slider moves (one undo step per drag, see `endEditing`).
    func setEffectParameter(_ effect: UUID, in node: UUID, _ parameter: EffectParameter, _ value: Double) {
        updateNode(node, "Change \(parameter.name)") { node in
            guard let index = node.effects.firstIndex(where: { $0.id == effect }) else { return }
            node.effects[index].set(parameter, value)
        }
    }

    /// The delay a node's effects add where it runs (from the routing's status), or nil when it isn't running.
    func effectLatency(_ node: UUID) -> TimeInterval? {
        let values = statuses.values.compactMap { $0.effectLatencies?[node] }
        return values.isEmpty ? nil : values.max()
    }

    /// Why an effect is left out of its chain, if it is.
    func effectProblem(_ effect: UUID) -> String? {
        statuses.values.lazy.compactMap { $0.effectProblems?[effect] }.first
    }

    // MARK: Plugins

    /// Opens the plugin picker for a node's chain, with the effect Audio Units installed right now.
    func showPluginPicker(for node: UUID) {
        plugins = isDemo ? Demo.plugins : PluginCatalog.installed()
        pluginPicker = PluginPickerRequest(node: node)
    }

    func addPlugin(_ plugin: PluginInfo, to node: UUID) {
        updateNode(node, "Add \(plugin.name)") { $0.effects.append(Effect(plugin: plugin)) }
        endEditing()
    }

    /// Whether an effect's Audio Unit is on this Mac (looked up again after a few seconds, so installing or removing
    /// a plugin shows soon).
    func isInstalled(_ effect: Effect) -> Bool {
        guard effect.isPlugin else { return true }
        if isDemo { return Demo.plugins.contains { $0.matches(effect) } }
        let key = "\(effect.type) \(effect.subtype) \(effect.manufacturer)"
        if let known = installedPlugins[key], Date().timeIntervalSince(known.checked) < 5 { return known.installed }
        let installed = PluginCatalog.isInstalled(effect)
        installedPlugins[key] = (installed, Date())
        return installed
    }

    /// Opens a plugin's own window in the process that runs it (Junction Helper, or Junction itself).
    func openPluginWindow(_ effect: Effect, in node: UUID) {
        let title = "\(effect.title) · \(self.node(node).map(info.title) ?? "Junction")"
        if let helper {
            helper.openPluginWindow(effect.id, title: title) { problem in
                MainActor.assumeIsolated { if let problem { AppModel.shared.alert = problem } }
            }
        } else if let router {
            if let problem = router.openPluginWindow(effect.id, title: title) { alert = problem }
        } else {
            alert = "\(effect.title)'s window opens while routing is on and its node is connected."
        }
    }

    /// A plugin's window changed its state: keep it with the graph (not an undo step: the plugin changed itself).
    func adoptEffectState(_ effect: UUID, _ state: Data) {
        var updated = graph
        for node in updated.nodes.indices {
            guard let index = updated.nodes[node].effects.firstIndex(where: { $0.id == effect }),
                  updated.nodes[node].effects[index].state != state else { continue }
            updated.nodes[node].effects[index].state = state
            graph = updated
            return
        }
    }

    /// What an effect costs where it runs (CPU, delay), as the router last measured it.
    func effectCost(_ effect: UUID) -> EffectCost? {
        statuses.values.lazy.compactMap { $0.effectCosts?[effect] }.first
    }

    /// Whether an effect holds up the audio thread and is offered for bypass.
    func isStalling(_ effect: Effect) -> Bool {
        !effect.bypass && !keptStallingEffects.contains(effect.id)
            && statuses.values.contains { $0.stallingEffects?.contains(effect.id) == true }
    }

    /// The user keeps a stalling effect running: stop offering to bypass it.
    func keepStallingEffect(_ effect: UUID) { keptStallingEffects.insert(effect) }

    func updateCable(_ id: UUID, _ name: String = "Change Level", _ change: (inout Cable) -> Void) {
        edit(name, coalescing: "cable \(id) \(name)") { graph in
            guard let index = graph.cables.firstIndex(where: { $0.id == id }) else { return }
            change(&graph.cables[index])
        }
    }

    /// Removes a node from its canvas; a virtual device's own node stays (it is the canvas).
    func removeNode(_ id: UUID) {
        guard let node = graph.node(id), !isDeviceNode(node) else { return }
        edit("Remove \(info.title(node))") { Editing.remove([id], from: &$0) }
    }

    func isDeviceNode(_ node: Node) -> Bool { Editing.isDeviceNode(node) }

    func removeCable(_ id: UUID) {
        edit("Disconnect") { $0.cables.removeAll { $0.id == id } }
    }

    /// The nodes selected on the canvas (one or several).
    var selectedNodes: Set<UUID> { selection?.nodeIDs ?? [] }

    func isSelected(_ node: UUID) -> Bool { selection?.contains(node: node) ?? false }

    /// A click on a node: selects it alone, or with ⇧ adds it to (or takes it out of) the selection.
    func click(_ node: UUID, extending: Bool) {
        selection = extending ? Selection.toggling(node, in: selection) : .node(node)
    }

    /// A drag box: selects the nodes it touches (added to the selection with ⇧).
    func selectNodes(in rect: CGRect, extending: Bool) {
        guard let canvas else { return }
        let boxed = Editing.nodes(in: rect, canvas: canvas, graph: graph, inventory: inventory)
        selection = extending ? Selection.boxed(boxed, extending: selection) : Selection.of(boxed)
    }

    func selectAll() {
        selection = Selection.of(Set(canvasNodes.map(\.id)))
    }

    /// Delete: a cable, or the selected nodes. The virtual device alone asks first (it takes its canvas with it); in a
    /// selection of several it stays.
    func deleteSelection() {
        switch selection {
        case .node(let id):
            if let node = graph.node(id), case .virtualDevice(let device) = node.kind {
                deviceToDelete = device
            } else {
                removeNode(id)
            }
        case .nodes(let ids):
            edit("Remove Nodes") { Editing.remove(ids, from: &$0) }
        case .cable(let id): removeCable(id)
        case nil: break
        }
    }

    /// Whether the selection has nodes that can be copied (anything but the canvas's device).
    var canCopy: Bool { Editing.copy(selectedNodes, from: graph) != nil }

    func copySelection() {
        guard let copied = Editing.copy(selectedNodes, from: graph) else { return }
        clipboard = copied
        guard let data = try? JSONEncoder().encode(copied) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(Clipboard.pasteboardType))
        clipboardChangeCount = pasteboard.changeCount
    }

    func cutSelection() {
        copySelection()
        guard clipboard != nil else { return }
        let ids = selectedNodes
        edit("Cut") { Editing.remove(ids, from: &$0) }
    }

    var canPaste: Bool { clipboard != nil && canvas != nil }

    /// Pastes the copied nodes onto the shown canvas (which can be another device's) and selects them. Cables that
    /// wouldn't be allowed here are left out.
    func paste() {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != clipboardChangeCount {  // copied elsewhere since, or by another Junction
            clipboard = pasteboard.data(forType: NSPasteboard.PasteboardType(Clipboard.pasteboardType))
                .flatMap { try? JSONDecoder().decode(Clipboard.self, from: $0) }
            clipboardChangeCount = pasteboard.changeCount
        }
        guard let clipboard, let canvas else { return }
        paste(clipboard, name: "Paste", onto: canvas)
    }

    func duplicateSelection() {
        guard let canvas, let copied = Editing.copy(selectedNodes, from: graph) else { return }
        paste(copied, name: "Duplicate", onto: canvas)
    }

    private func paste(_ clipboard: Clipboard, name: String, onto canvas: UUID) {
        var pasted: Set<UUID> = []
        let inventory = inventory
        edit(name) { pasted = Editing.paste(clipboard, into: &$0, canvas: canvas, inventory: inventory) }
        selection = Selection.of(pasted)
    }

    /// Tidy Up: sources on the left, the device in the middle, outputs on the right, none overlapping.
    func tidyUp() {
        guard let canvas else { return }
        let inventory = inventory
        edit("Tidy Up") { Editing.tidyUp(&$0, canvas: canvas, inventory: inventory) }
    }

    /// Connects two channels; returns why not when it can't.
    @discardableResult
    func connect(from: PortRef, to: PortRef) -> Rules.Problem? {
        if let problem = Rules.check(from: from, to: to, graph: graph, inventory: inventory) { return problem }
        let cable = Cable(from: from, to: to)
        edit("Connect") { $0.cables.append(cable) }
        selection = .cable(cable.id)
        return nil
    }

    /// Connects every channel of one node to the next node's channels in order.
    @discardableResult
    func connectAll(from source: UUID, to target: UUID) -> Rules.Problem? {
        let cables = Rules.busCables(from: source, to: target, graph: graph, inventory: inventory)
        guard !cables.isEmpty else {
            let outputs = graph.node(source).map { info.ports($0).outputs } ?? 0
            let inputs = graph.node(target).map { info.ports($0).inputs } ?? 0
            if outputs == 0 || inputs == 0 { return .noSuchPort }
            return Rules.check(from: PortRef(node: source, channel: 0), to: PortRef(node: target, channel: 0),
                               graph: graph, inventory: inventory) ?? .alreadyConnected
        }
        edit("Connect All Channels") { $0.cables.append(contentsOf: cables) }
        return nil
    }

    func disconnectAll(_ node: UUID) {
        edit("Disconnect") { $0.cables.removeAll { $0.from.node == node || $0.to.node == node } }
    }

    /// Removes the cables between two nodes, in either direction.
    func disconnect(_ a: UUID, _ b: UUID) {
        edit("Disconnect") {
            $0.cables.removeAll { ($0.from.node == a && $0.to.node == b) || ($0.from.node == b && $0.to.node == a) }
        }
    }

    /// The nodes a node has cables to or from, in canvas order.
    func linkedNodes(_ node: UUID) -> [Node] {
        let ids = Set(graph.cables.compactMap { $0.from.node == node ? $0.to.node : ($0.to.node == node ? $0.from.node : nil) })
        return graph.nodes.filter { ids.contains($0.id) }
    }

    /// Moves a cable's input end to another channel, keeping its level. Returns why not when it can't.
    @discardableResult
    func moveCable(_ id: UUID, to port: PortRef) -> Rules.Problem? {
        var updated = graph
        if let problem = Rules.move(id, to: port, in: &updated, inventory: inventory) { return problem }
        edit("Move Cable") { $0 = updated }
        selection = .cable(id)
        return nil
    }

    // MARK: Virtual devices

    /// Creates a virtual device and shows its (empty) canvas.
    @discardableResult
    func addVirtualDevice(name: String? = nil, channels: Int = 2) -> VirtualDevice? {
        guard graph.virtualDevices.count < VirtualDevice.maximumCount else {
            alert = "Junction can publish up to \(VirtualDevice.maximumCount) virtual devices."
            return nil
        }
        let base = name ?? "Virtual Device"
        var candidate = base, number = 2
        while graph.virtualDevices.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(number)"
            number += 1
        }
        let device = VirtualDevice(name: candidate, channels: channels)
        edit("New Virtual Device") { graph in
            graph.virtualDevices.append(device)
            graph.nodes.append(Node(kind: .virtualDevice(device.id), x: CanvasColumn.device, y: 60, canvas: device.id))
        }
        pickedCanvas = device.id
        selection = nil
        return device
    }

    func updateVirtualDevice(_ id: UUID, _ name: String = "Change Virtual Device", _ change: (inout VirtualDevice) -> Void) {
        let inventory = inventory
        edit(name, coalescing: "device \(id) \(name)") { updated in
            guard let index = updated.virtualDevices.firstIndex(where: { $0.id == id }) else { return }
            change(&updated.virtualDevices[index])
            let name = updated.virtualDevices[index].name.trimmingCharacters(in: .whitespaces)
            updated.virtualDevices[index].name = name.isEmpty ? "Virtual Device" : name
            let info = NodeInfo(graph: updated, inventory: inventory)
            updated.pruneCables { info.ports($0) }
        }
    }

    /// Deletes a virtual device with its canvas.
    func removeVirtualDevice(_ id: UUID) {
        let name = graph.virtualDevice(id)?.name ?? "Virtual Device"
        edit("Delete \(name)") { $0.removeVirtualDevice(id) }
    }

    /// Makes the "stream without chat" setup and shows its canvas.
    func addStreamWithoutChat(excluding apps: [AppRef], deviceName: String) {
        addTemplate("Stream Without Chat", deviceName: deviceName) {
            Templates.streamWithoutChat(&$0, excluding: apps, deviceName: deviceName)
        }
    }

    /// Makes a template's setup (one undo step) and shows its device's canvas.
    func addTemplate(_ name: String, deviceName: String, _ make: (inout Graph) -> VirtualDevice) {
        guard graph.virtualDevices.count < VirtualDevice.maximumCount
                || graph.virtualDevices.contains(where: { $0.name == deviceName }) else {
            alert = "Junction can publish up to \(VirtualDevice.maximumCount) virtual devices."
            return
        }
        var device: VirtualDevice?
        edit(name) { device = make(&$0) }
        if let device { pickedCanvas = device.id }
        selection = nil
    }

    /// Apps to offer a template: using audio now, the installed ones of `known`, and `picked`.
    func appCandidates(installed: [AppRef], picked: [AppRef] = []) -> [AppRef] {
        Templates.appCandidates(usingAudio: inventory.apps.map(\.ref), installed: installed, picked: picked)
    }

    // MARK: Scenes

    /// Saves the current setup as a new scene.
    func addScene(named name: String) {
        let scene = RoutingScene(name: sceneName(name), capturing: graph)
        edit("New Scene") { $0.scenes.append(scene) }
    }

    /// Replaces a scene with the current setup.
    func updateScene(_ id: UUID) {
        edit("Update Scene") { graph in
            guard let index = graph.scenes.firstIndex(where: { $0.id == id }) else { return }
            graph.scenes[index] = RoutingScene(id: id, name: graph.scenes[index].name, capturing: graph)
        }
    }

    func renameScene(_ id: UUID, to name: String) {
        let name = sceneName(name)
        edit("Rename Scene") { graph in
            guard let index = graph.scenes.firstIndex(where: { $0.id == id }) else { return }
            graph.scenes[index].name = name
        }
    }

    func deleteScene(_ id: UUID) {
        let name = graph.scenes.first { $0.id == id }?.name ?? "Scene"
        edit("Delete \(name)") { $0.scenes.removeAll { $0.id == id } }
    }

    /// Switches to a scene (one undo step). Only canvases that differ change, so the router rebuilds, cross-faded,
    /// just the sinks whose structure changed; the others keep playing with their new levels.
    func switchToScene(_ id: UUID) {
        guard let scene = graph.scenes.first(where: { $0.id == id }) else { return }
        let inventory = inventory
        if edit("Switch to \(scene.name)", { Scenes.apply(scene, to: &$0, inventory: inventory) }) {
            note("Switched to scene \(scene.name)")
        }
    }

    /// The scene the setup is in right now, if any.
    var currentScene: UUID? { graph.scenes.first { Scenes.isCurrent($0, in: graph) }?.id }

    private func sceneName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Scenes.newName(in: graph) : trimmed
    }

    // MARK: MIDI

    /// MIDI learn: the next control moved on any MIDI controller drives `target`. Again, or nil, stops it.
    func learnMIDI(_ target: MIDITarget?) {
        let target = target == midiLearning ? nil : target
        midiLearning = target
        if let helper { helper.learnMIDI(target) } else { midiControl.learn(target) }
    }

    func cancelMIDILearn() { if midiLearning != nil { learnMIDI(nil) } }

    func midiMapping(for target: MIDITarget) -> MIDIMapping? { graph.midiMapping(for: target) }

    /// What a mapping drives, in words.
    func describe(_ target: MIDITarget) -> String { graph.describe(target, inventory: inventory) }

    func removeMIDIMapping(_ id: UUID) {
        edit("Remove MIDI Control") { $0.midi.removeAll { $0.id == id } }
    }

    func setMIDIMode(_ id: UUID, _ mode: MIDIControlMode) {
        edit("Change MIDI Control") { graph in
            guard let index = graph.midi.firstIndex(where: { $0.id == id }) else { return }
            graph.midi[index].mode = mode
        }
    }

    /// Messages from a controller while routing runs here.
    private func receiveMIDI(_ messages: [MIDIMessage], from source: String?) {
        var working = graph
        var actions: [MIDIAction] = []
        for message in messages {
            for action in midiControl.handle(message, from: source, graph: working)
            where action.apply(to: &working, inventory: inventory) {
                actions.append(action)
            }
        }
        adoptMIDI(actions, log: true)
    }

    /// Makes the changes MIDI made where routing runs. Moving a control isn't an undo step (the controller still shows
    /// where it is); a learned mapping is.
    private func adoptMIDI(_ actions: [MIDIAction], log: Bool = false) {
        var updated = graph
        var learned: [MIDIMapping] = []
        for action in actions {
            if case .learned(let mapping) = action {
                learned.append(mapping)
            } else {
                action.apply(to: &updated, inventory: inventory)
                if log, case .scene(let id) = action, let scene = graph.scenes.first(where: { $0.id == id }) {
                    note("Switched to scene \(scene.name) from MIDI")
                }
            }
        }
        if updated != graph { graph = updated }
        guard !learned.isEmpty else { return }
        midiLearning = nil
        let inventory = inventory
        edit("Learn MIDI Control") { graph in
            for mapping in learned { MIDIAction.learned(mapping).apply(to: &graph, inventory: inventory) }
        }
        endEditing()
        if log, let mapping = learned.last {
            note("MIDI learn: \(mapping.trigger.title) now drives \(describe(mapping.target))")
        }
    }

    /// Snapshot mode: show MIDI learn waiting for a control, and made-up controllers.
    func setDemoMIDI(learning: MIDITarget?, sources: [String]) {
        guard isDemo else { return }
        midiLearning = learning
        midiSources = sources
    }

    // MARK: Status for the canvas

    func issues(for node: UUID) -> [String] {
        var result = plan.issues[node] ?? []
        if let status = statuses[node], let message = status.message { result.insert(message, at: 0) }
        for effect in graph.node(node)?.effects ?? [] {
            if !isInstalled(effect) {
                result.append("\(effect.title) isn't installed on this Mac, so it passes the audio through. Its settings are kept.")
            } else if isStalling(effect) {
                result.append("\(effect.title) is holding up the audio. Bypass it in the inspector if you hear dropouts.")
            }
        }
        if silentTaps.contains(node) {
            result.append("No sound yet, although apps it captures are playing. If you expect some, check that \(routingProcessName) may record system audio: System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        return result
    }

    func isFailing(_ node: UUID) -> Bool { statuses[node]?.state == .failed }
    func isRunning(_ node: UUID) -> Bool { statuses[node]?.state == .running }

    func level(_ node: UUID, output: Bool, channel: Int) -> Float {
        meters[PortKey(node: node, isOutput: output, channel: channel)] ?? 0
    }

    var runningSinkCount: Int { statuses.values.filter { $0.state == .running }.count }
    var failingSinkCount: Int { statuses.values.filter { $0.state == .failed }.count }
}
