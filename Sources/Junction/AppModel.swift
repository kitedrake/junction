import AppKit
import AVFoundation
import CoreAudio
import JunctionCore
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers

enum Selection: Hashable {
    case node(UUID)
    case cable(UUID)
}

/// Which side of the canvas a new node goes on: sources feed the virtual device, outputs play it.
enum NodeRole {
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
    /// The virtual device whose canvas is shown, as picked in the sidebar.
    private var pickedCanvas: UUID?
    /// A virtual device waiting for the user to confirm its deletion.
    var deviceToDelete: UUID?
    var showInspector = true
    var showStreamTemplate = false
    /// A problem to show in an alert (driver install, publishing).
    var alert: String?
    /// macOS's Microphone permission, which covers every audio input: microphones, interfaces, Junction's devices.
    private(set) var microphoneAccess: AVAuthorizationStatus = .authorized
    /// App and System Audio nodes that have heard nothing for a while although apps they capture are playing: most
    /// likely Junction may not record system audio.
    private(set) var silentTaps: Set<UUID> = []
    private(set) var isInstallingDriver = false
    /// The known chat apps (`Templates.chatApps`) installed on this Mac.
    private(set) var installedChatApps: [AppRef] = []

    /// Screenshots and demos: made-up devices, nothing saved, nothing routed.
    let isDemo: Bool
    private let store = Store()
    @ObservationIgnored private var router: Router?
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
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var started = false
    /// Virtual devices Junction just created, turned on or reformatted, and until when its own sample rate wins.
    @ObservationIgnored private var assertRateUntil: [UUID: Date] = [:]
    private static let log = Logger(subsystem: "local.junction", category: "routing")

    init(demo: Bool) {
        isDemo = demo
        graph = Graph()
    }

    // MARK: Life cycle

    func start() {
        guard !started else { return }
        started = true
        refreshInstalledChatApps()
        if isDemo {
            Demo.load(into: self)
            return
        }
        if let saved = store.load() {
            graph = saved
        } else {
            graph = Graph()
        }
        let router = Router { statuses in
            Task { @MainActor in AppModel.shared.statuses = statuses }
        }
        self.router = router
        // Rates changed from outside while Junction wasn't running (Audio MIDI Setup, a DAW) are kept.
        if let published = DriverClient.publishedDevices() {
            var adopted = graph
            for index in adopted.virtualDevices.indices {
                guard let live = published.first(where: { $0.id == adopted.virtualDevices[index].id }),
                      VirtualDevice.sampleRateChoices.contains(live.sampleRate) else { continue }
                adopted.virtualDevices[index].sampleRate = live.sampleRate
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
                Self.log.notice("Woke from sleep; checking routing")
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
        microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        replan(force: true)
        refreshPermissions()
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        restartTask?.cancel()
        router?.stopAll()
        saveNow()
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
        if !isDemo {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
            if old.virtualDevices != graph.virtualDevices {
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
        guard !isDemo else { return }
        do {
            try store.save(graph)
        } catch {
            alert = "Couldn't save the routing setup: \(error.localizedDescription)"
        }
    }

    private func replan(force: Bool = false) {
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
        let uids = Set(plan.sinks.flatMap { $0.subDevices.map(\.uid) })
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
        guard fresh != inventory else { return }
        let driverAppeared = !inventory.driver.isInstalled && fresh.driver.isInstalled
        inventory = fresh
        // Remember the current shape of devices on the canvas, for when they are unplugged.
        var updated = graph
        for index in updated.nodes.indices {
            guard case .device(let ref) = updated.nodes[index].kind, let live = fresh.device(ref.uid), live.ref != ref else { continue }
            updated.nodes[index].kind = .device(live.ref)
        }
        if updated != graph { graph = updated }
        if driverAppeared {
            // Devices the driver doesn't have yet will appear now; Core Audio may give them a remembered rate.
            let published = Set((DriverClient.publishedDevices() ?? []).map(\.id))
            publishVirtualDevices(changed: Set(graph.virtualDevices.filter { !published.contains($0.id) }.map(\.id)))
        }
        replan()
        reconcileSampleRates()
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
        let installed = Templates.chatApps.filter { app in
            isDemo ? Demo.installedChatApps.contains(app.bundleID)
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
        }
        if installed != installedChatApps { installedChatApps = installed }
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
        Self.log.notice("Core Audio restarted; rebuilding routing")
        router?.forgetAfterRestart()  // at once, so no refresh in between tries to stop the dead sinks
        watchedUIDs = []  // device IDs change: listen again on the next plan
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
        guard let router, graph.isRoutingOn else {
            if !meters.isEmpty { meters = [:] }
            return
        }
        let fresh = router.takeMeters()
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

    /// Whether routing reads any audio input: a sink's aggregate reads its device's own inputs and every source device.
    var needsMicrophone: Bool {
        plan.sinks.contains { $0.subDevices.contains { $0.inputChannels > 0 } }
    }

    /// Follows the Microphone permission. When it is granted, every sink is built again (one that started without it
    /// may be running on silence). When routing needs it and macOS hasn't asked yet, asks now; the banner says why.
    func refreshPermissions() {
        guard !isDemo else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != microphoneAccess {
            let granted = status == .authorized
            microphoneAccess = status
            Self.log.notice("Microphone permission: \(String(describing: status.rawValue), privacy: .public)")
            if granted { router?.rebuildAll() }
        }
        if status == .notDetermined, needsMicrophone, graph.isRoutingOn, !askedForMicrophone { requestMicrophone() }
    }

    func requestMicrophone() {
        guard !isDemo else { return }
        askedForMicrophone = true
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
        runPrivileged(script: script, arguments: [driver.path], prompt: "Junction wants to install its audio driver.")
    }

    func uninstallDriver() {
        guard let script = Bundle.main.url(forResource: "uninstall-driver", withExtension: "sh") else { return }
        runPrivileged(script: script, arguments: [], prompt: "Junction wants to remove its audio driver.")
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
            try? await Task.sleep(for: .seconds(2))  // coreaudiod restarts
            await MainActor.run {
                let model = AppModel.shared
                model.isInstallingDriver = false
                if let message, !cancelled { model.alert = message }
                model.refreshInventory()
                model.publishVirtualDevices()
                // The script restarts Core Audio; rebuild routing even if the restart notice didn't arrive.
                let noticed = model.lastCoreAudioRestart.map { Date().timeIntervalSince($0) < 15 } ?? false
                if message == nil, !noticed {
                    AppModel.log.notice("No restart notice after the driver script; rebuilding routing anyway")
                    model.coreAudioRestarted()
                }
            }
        }
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
    var canvasNodes: [Node] { canvas.map(graph.nodes(on:)) ?? [] }
    var canvasCables: [Cable] { canvas.map(graph.cables(on:)) ?? [] }

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
        var updated = graph
        updated.nodes.append(node)
        updated.cables += role == .source
            ? Rules.busCables(from: node.id, to: device.id, graph: updated, inventory: inventory)
            : Rules.busCables(from: device.id, to: node.id, graph: updated, inventory: inventory)
        graph = updated
        selection = .node(node.id)
        return node.id
    }

    /// Sources go on the left, outputs on the right, below what is already there.
    private func freeSpot(role: NodeRole, canvas: UUID) -> CGPoint {
        let column = role == .source ? CanvasColumn.sources : CanvasColumn.outputs
        let bottom = graph.nodes(on: canvas).filter { abs($0.x - column) < 150 }
            .map { $0.y + Double(NodeLayout.height(for: info.ports($0))) }.max() ?? 20
        return CGPoint(x: column, y: bottom + 30)
    }

    // MARK: Editing

    func moveNode(_ id: UUID, to point: CGPoint) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].x = max(0, point.x)
        graph.nodes[index].y = max(0, point.y)
    }

    func updateNode(_ id: UUID, _ change: (inout Node) -> Void) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&graph.nodes[index])
    }

    func updateCable(_ id: UUID, _ change: (inout Cable) -> Void) {
        guard let index = graph.cables.firstIndex(where: { $0.id == id }) else { return }
        change(&graph.cables[index])
    }

    /// Removes a node from its canvas; a virtual device's own node stays (it is the canvas).
    func removeNode(_ id: UUID) {
        guard let node = graph.node(id), !isDeviceNode(node) else { return }
        graph.removeNode(id)
        if selection == .node(id) { selection = nil }
    }

    func isDeviceNode(_ node: Node) -> Bool {
        if case .virtualDevice = node.kind { return true }
        return false
    }

    func removeCable(_ id: UUID) {
        graph.cables.removeAll { $0.id == id }
        if selection == .cable(id) { selection = nil }
    }

    func deleteSelection() {
        switch selection {
        case .node(let id):
            if let node = graph.node(id), case .virtualDevice(let device) = node.kind {
                deviceToDelete = device
            } else {
                removeNode(id)
            }
        case .cable(let id): removeCable(id)
        case nil: break
        }
    }

    /// Connects two channels; returns why not when it can't.
    @discardableResult
    func connect(from: PortRef, to: PortRef) -> Rules.Problem? {
        if let problem = Rules.check(from: from, to: to, graph: graph, inventory: inventory) { return problem }
        let cable = Cable(from: from, to: to)
        graph.cables.append(cable)
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
        graph.cables.append(contentsOf: cables)
        return nil
    }

    func disconnectAll(_ node: UUID) {
        graph.cables.removeAll { $0.from.node == node || $0.to.node == node }
    }

    /// Removes the cables between two nodes, in either direction.
    func disconnect(_ a: UUID, _ b: UUID) {
        graph.cables.removeAll { ($0.from.node == a && $0.to.node == b) || ($0.from.node == b && $0.to.node == a) }
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
        graph = updated
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
        var updated = graph
        updated.virtualDevices.append(device)
        updated.nodes.append(Node(kind: .virtualDevice(device.id), x: CanvasColumn.device, y: 60, canvas: device.id))
        graph = updated
        pickedCanvas = device.id
        selection = nil
        return device
    }

    func updateVirtualDevice(_ id: UUID, _ change: (inout VirtualDevice) -> Void) {
        guard let index = graph.virtualDevices.firstIndex(where: { $0.id == id }) else { return }
        var updated = graph
        change(&updated.virtualDevices[index])
        let name = updated.virtualDevices[index].name.trimmingCharacters(in: .whitespaces)
        updated.virtualDevices[index].name = name.isEmpty ? "Virtual Device" : name
        let info = NodeInfo(graph: updated, inventory: inventory)
        updated.pruneCables { info.ports($0) }
        graph = updated
    }

    /// Deletes a virtual device with its canvas.
    func removeVirtualDevice(_ id: UUID) {
        graph.removeVirtualDevice(id)
        switch selection {
        case .node(let node) where graph.node(node) == nil: selection = nil
        case .cable(let cable) where !graph.cables.contains(where: { $0.id == cable }): selection = nil
        default: break
        }
    }

    /// Makes the "stream without chat" setup and shows its canvas.
    func addStreamWithoutChat(excluding apps: [AppRef], deviceName: String) {
        guard graph.virtualDevices.count < VirtualDevice.maximumCount
                || graph.virtualDevices.contains(where: { $0.name == deviceName }) else {
            alert = "Junction can publish up to \(VirtualDevice.maximumCount) virtual devices."
            return
        }
        var updated = graph
        let device = Templates.streamWithoutChat(&updated, excluding: apps, deviceName: deviceName)
        graph = updated
        pickedCanvas = device.id
        selection = nil
    }

    // MARK: Status for the canvas

    func issues(for node: UUID) -> [String] {
        var result = plan.issues[node] ?? []
        if let status = statuses[node], let message = status.message { result.insert(message, at: 0) }
        if silentTaps.contains(node) {
            result.append("No sound yet, although apps it captures are playing. If you expect some, check that Junction may record system audio: System Settings › Privacy & Security › Screen & System Audio Recording.")
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
