import AppKit
import AVFoundation
import JunctionCore
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--list", "--diagnose", "--self-test", "--loopback-test", "--device-test", "--help"].contains(arguments.first ?? "") {
            exit(CommandLineTool.run(arguments))
        }
        JunctionApp.main()
    }
}

struct JunctionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Junction", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 560)
                .onAppear {
                    model.start()
                    Snapshot.runIfRequested(model)
                }
        }
        .defaultSize(width: 1240, height: 760)
        .commands {
            if let updates = Updates.shared {
                CommandGroup(after: .appInfo) { UpdateCommands(updates: updates) }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Device") { model.addVirtualDevice() }
                    .keyboardShortcut("n")
                TemplateMenuItems()
                    .environment(model)
            }
            EditCommands(model: model)
            CommandMenu("Routing") {
                Toggle("Routing On", isOn: Binding(get: { model.graph.isRoutingOn }, set: { model.graph.isRoutingOn = $0 }))
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                SceneMenuItems(shortcuts: true)
                    .environment(model)
                Divider()
                Group {
                    switch model.driverUpdate {
                    case .notInstalled:
                        Button("Install Driver…") { model.installDriver() }
                    case .available(_, let bundled):
                        Button("Update Driver to \(bundled)…") { model.installDriver() }
                        Button("Uninstall Driver…") { model.uninstallDriver() }
                    case .appIsOlder(_, let bundled):
                        Button("Install Older Driver (\(bundled))…") { model.installDriver() }
                        Button("Uninstall Driver…") { model.uninstallDriver() }
                    case .upToDate:
                        Button("Reinstall Driver…") { model.installDriver() }
                        Button("Uninstall Driver…") { model.uninstallDriver() }
                    }
                }
                .disabled(model.isInstallingDriver || model.isDemo)
                Divider()
                ShowLogButton()
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button(model.showMinimap ? "Hide Minimap" : "Show Minimap") { model.showMinimap.toggle() }
                Divider()
                Group {
                    Button("Zoom In") { model.zoom(in: true) }
                        .keyboardShortcut("+")
                    Button("Zoom Out") { model.zoom(in: false) }
                        .keyboardShortcut("-")
                    Button("Actual Size") { model.zoomToActualSize() }
                        .keyboardShortcut("0")
                    Button("Zoom to Fit") { model.zoomToFit() }
                        .keyboardShortcut("0", modifiers: [.command, .option])
                }
                .disabled(model.canvas == nil)
                Divider()
            }
        }

        MenuBarExtra("Junction", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            MenuBarContent()
                .environment(model)
        }

        Window("Routing Log", id: "log") {
            LogView()
                .environment(model)
        }
        .defaultSize(width: 680, height: 420)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !DockIcon.isShown { NSApp.setActivationPolicy(.accessory) }
        MainActor.assumeIsolated { LoginLaunch.detect() }
    }

    /// Routing starts with the app, not with the window (which a menu-bar-only setup may never show). Opened at login,
    /// Junction stays in the menu bar: its window is closed straight away.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            guard LoginLaunch.isActive, !AppModel.shared.isDemo else { return }
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") ?? false { window.close() }
            }
        }
    }

    /// Routing keeps running from the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}

/// Undo, Redo, Cut, Copy, Paste, Duplicate, Delete, Select All and Tidy Up act on the canvas; while a text field is
/// focused, the ones a text field knows go to it instead.
struct EditCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.canUndo || model.isEditingText ? model.undoTitle : "Undo") {
                if !forwardToText("undo:") { model.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!model.canUndo && !model.isEditingText)
            Button(model.canRedo || model.isEditingText ? model.redoTitle : "Redo") {
                if !forwardToText("redo:") { model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo && !model.isEditingText)
        }
        CommandGroup(replacing: .pasteboard) {
            // Always enabled: a text field may want them even when the canvas has nothing to act on.
            Button("Cut") { if !forwardToText("cut:") { model.cutSelection() } }
                .keyboardShortcut("x")
            Button("Copy") { if !forwardToText("copy:") { model.copySelection() } }
                .keyboardShortcut("c")
            Button("Paste") { if !forwardToText("paste:") { model.paste() } }
                .keyboardShortcut("v")
            Button("Duplicate") { model.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(!model.canCopy)
            // ⌘⌫ here; plain Delete is handled by the canvas only while it has focus, so typing in the inspector
            // never deletes a node.
            Button("Delete") { model.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection == nil)
            Button("Select All") { if !forwardToText("selectAll:") { model.selectAll() } }
                .keyboardShortcut("a")
            Divider()
            Button("Tidy Up") { model.tidyUp() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(model.canvas == nil)
        }
    }

    /// Sends a standard edit action to the focused text field, if there is one. Returns whether it did.
    @MainActor private func forwardToText(_ action: String) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        return NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Routing On", isOn: Binding(get: { model.graph.isRoutingOn }, set: { model.graph.isRoutingOn = $0 }))
        if !model.graph.scenes.isEmpty {
            Divider()
            SceneMenuItems(offersNew: false)
        }
        if !model.graph.virtualDevices.isEmpty {
            Divider()
            Text("Virtual Devices")
            ForEach(model.graph.virtualDevices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { device.isEnabled },
                    set: { value in model.updateVirtualDevice(device.id, value ? "Turn On" : "Turn Off") { $0.isEnabled = value } }))
            }
        }
        if model.failingSinkCount > 0 {
            Divider()
            Text("\(model.failingSinkCount) destination\(model.failingSinkCount == 1 ? "" : "s") with problems")
            ShowLogButton()
        }
        switch model.driverUpdate {
        case .notInstalled:
            Divider()
            Button(model.isInstallingDriver ? "Installing Driver…" : "Install Driver…") { model.installDriver() }
                .disabled(model.isInstallingDriver || model.isDemo)
        case .available(let installed, let bundled):
            Divider()
            Text("Driver update available (\(installed) → \(bundled))")
            Button(model.isInstallingDriver ? "Installing Driver…" : "Update Driver…") { model.installDriver() }
                .disabled(model.isInstallingDriver || model.isDemo)
        case .appIsOlder, .upToDate:
            EmptyView()
        }
        Divider()
        Button("Open Junction") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        if let updates = Updates.shared {
            Button("Check for Updates…") {
                NSApp.activate()
                updates.checkNow()
            }
        }
        Button("Quit Junction") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            CanvasView()
                .overlay(alignment: .top) {
                    if let target = model.midiLearning {
                        MIDILearnBanner(target: target)
                    } else if !model.inventory.driver.isInstalled && !model.graph.virtualDevices.isEmpty {
                        DriverBanner()
                    } else if model.graph.isRoutingOn, model.needsMicrophone, model.microphoneAccess != .authorized {
                        MicrophoneBanner()
                    }
                }
                .overlay {
                    if model.canvas == nil { EmptyCanvas() }
                }
                .overlay(alignment: .bottom) {
                    if let device = model.canvasDevice, model.canvasNodes.count == 1 { CanvasHint(device: device) }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Toggle(isOn: $model.graph.isRoutingOn) {
                            Label("Routing", systemImage: "power")
                        }
                        .help(model.graph.isRoutingOn ? "Routing is on. Click to stop all routing." : "Routing is off. Click to start.")
                        AddMenu()
                        Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                            .help(model.showInspector ? "Hide the inspector" : "Show the inspector")
                    }
                }
        }
        .navigationTitle(model.canvasDevice?.name ?? "Junction")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .sheet(item: $model.template) { kind in
            TemplateSheet(kind: kind)
        }
        .sheet(item: $model.sceneNaming) { naming in
            SceneNameSheet(naming: naming)
        }
        .sheet(item: $model.pluginPicker) { request in
            PluginPicker(request: request)
        }
        .sheet(isPresented: Binding(get: { model.crashOffer != nil }, set: { if !$0 { model.finishCrashOffer() } })) {
            if let offer = model.crashOffer { CrashReportSheet(offer: offer) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { model.deviceToDelete != nil },
                                                              set: { if !$0 { model.deviceToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = model.deviceToDelete { model.removeVirtualDevice(id) }
                model.deviceToDelete = nil
            }
        } message: {
            Text("Apps using it lose it, and its canvas is removed.")
        }
        .alert("Junction", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var deleteTitle: String {
        let name = model.deviceToDelete.flatMap(model.graph.virtualDevice)?.name ?? "this virtual device"
        return "Delete “\(name)”?"
    }

    private var subtitle: String {
        guard model.graph.isRoutingOn else { return "Routing off" }
        let running = model.runningSinkCount
        let failing = model.failingSinkCount
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if failing > 0 { parts.append("\(failing) with problems") }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }
}

struct AddMenu: View {
    var body: some View {
        Menu {
            AddMenuItems()
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add a source, an output or a virtual device")
    }
}

/// What the toolbar's Add menu and the canvas's right-click menu offer: sources and outputs for the shown canvas,
/// and new virtual devices. `spot` says where the new node goes (read when an item is chosen); nil finds a free spot.
struct AddMenuItems: View {
    @Environment(AppModel.self) private var model
    var spot: () -> CGPoint? = { nil }

    var body: some View {
        Group {
            Section("Sources") {
                Button("System Audio") { add(.systemAudio(excluding: []), .source) }
                Button("Default Input") { add(.defaultInput, .source) }
                ForEach(model.inventory.inputDevices) { device in
                    Button(device.name) { add(.device(device.ref), .source) }
                }
            }
            if !model.inventory.apps.isEmpty || !model.appsThroughOtherDevices.isEmpty {
                Section("Apps") {
                    ForEach(model.inventory.apps) { app in
                        Button(app.name) { add(.application(app.ref), .source) }
                    }
                    ForEach(model.appsThroughOtherDevices) { source in
                        Button("\(source.app.name) through \(model.graph.virtualDevice(source.device)?.name ?? "Deleted Device")") {
                            add(.appThroughDevice(source.app, device: source.device), .source)
                        }
                    }
                }
            }
            Section("Outputs") {
                Button("Default Output") { add(.defaultOutput, .output) }
                ForEach(model.inventory.outputDevices) { device in
                    Button(device.name) { add(.device(device.ref), .output) }
                }
            }
        }
        .disabled(model.canvas == nil)
        Divider()
        Button("New Virtual Device") { model.addVirtualDevice() }
        TemplateMenuItems()
    }

    private func add(_ kind: NodeKind, _ role: NodeRole) { model.addNode(kind, as: role, at: spot()) }
}

struct DriverBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Label("Virtual devices need Junction's audio driver.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                Button(model.isInstallingDriver ? "Installing…" : "Install Driver…") { model.installDriver() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(model.isInstallingDriver || model.isDemo)
            }
        }
        .padding(.top, 14)
    }
}

/// Routing reads audio inputs (every sink reads its device's own inputs), which needs macOS's Microphone permission for
/// the process that routes: Junction, or Junction Helper. The banner names it.
struct MicrophoneBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let undecided = model.microphoneAccess == .notDetermined
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Label(undecided ? "\(model.routingProcessName) needs permission to use audio inputs for routing."
                                : "\(model.routingProcessName) isn't allowed to use audio inputs, so routing can't run.",
                      systemImage: "mic.slash.fill")
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .help("macOS calls it the Microphone permission. It covers microphones, audio interfaces and Junction's own virtual devices. Turn on \(model.routingProcessName) under Privacy & Security › Microphone.")
                Button(undecided ? "Allow…" : "Open System Settings") {
                    if undecided { model.requestMicrophone() } else { model.openPrivacySettings(.microphone) }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(.top, 14)
    }
}

/// Shown while a canvas holds only its virtual device.
struct CanvasHint: View {
    let device: VirtualDevice

    var body: some View {
        Text("Add sources and outputs from the sidebar or by right-clicking: they connect to \(device.name) by themselves.")
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 22)
            .padding(.horizontal, 30)
    }
}

struct EmptyCanvas: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Route audio between apps and devices")
                    .font(.title2.weight(.semibold))
                Text("Create virtual devices other apps can record from, then wire app audio, system audio,\nmicrophones and interfaces into them, or out to your speakers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("New Virtual Device") { model.addVirtualDevice() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Menu("Templates") { TemplateMenuItems() }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .fixedSize()
            }
            Text("Each virtual device gets its own canvas: sources on the left feed it, outputs on the right play it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

/// "Stream without chat": a virtual device carrying all app audio except the chosen chat apps.
struct StreamTemplateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Stream Mix"
    @State private var chosen: Set<String> = []
    @State private var picked: [AppRef] = []

    var body: some View {
        let candidates = candidates
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream Without Chat").font(.title2.weight(.semibold))
            Text("Makes a virtual device that carries everything your Mac plays except the apps you leave out. Pick it as the audio source in your streaming app: viewers hear your desktop, music and games, and the people in your call don't hear themselves.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Device name") { TextField("Stream Mix", text: $name).frame(maxWidth: 220) }
            HStack {
                Text("Leave out").font(.headline)
                Spacer()
                Button("Choose App…") {
                    guard let app = model.chooseApp() else { return }
                    if !picked.contains(app) { picked.append(app) }
                    chosen.insert(app.bundleID)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if candidates.isEmpty {
                        Text("No chat apps found. Apps appear here once they play sound; Choose App… picks any other.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(candidates) { app in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(app.bundleID) },
                            set: { if $0 { chosen.insert(app.bundleID) } else { chosen.remove(app.bundleID) } })) {
                            HStack {
                                NodeIcon(kind: .application(app), ports: PortCounts(inputs: 0, outputs: 2), size: 18)
                                Text(app.name)
                                if model.inventory.apps.contains(where: { $0.bundleID == app.bundleID }) {
                                    Text("using audio").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            Text("In OBS: add an “Audio Input Capture” source and choose “\(name.isEmpty ? "Stream Mix" : name)”. Add your microphone as usual.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let excluded = candidates.filter { chosen.contains($0.bundleID) }
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    model.addStreamWithoutChat(excluding: excluded, deviceName: trimmed.isEmpty ? "Stream Mix" : trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { chosen = Templates.defaultExclusions(from: candidates) }
    }

    private var candidates: [AppRef] { model.chatCandidates(picked: picked) }
}
