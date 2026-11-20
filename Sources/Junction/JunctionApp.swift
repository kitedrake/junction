import AppKit
import JunctionCore
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--list", "--self-test", "--loopback-test", "--device-test", "--help"].contains(arguments.first ?? "") {
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
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Device") { model.addVirtualDevice() }
                    .keyboardShortcut("n")
                Button("Stream Without Chat…") { model.showStreamTemplate = true }
            }
            CommandGroup(after: .pasteboard) {
                // ⌘⌫ here; plain Delete is handled by the canvas only while it has focus, so typing in the inspector
                // never deletes a node.
                Button("Delete") { model.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection == nil)
            }
            CommandMenu("Routing") {
                Toggle("Routing On", isOn: Binding(get: { model.graph.isRoutingOn }, set: { model.graph.isRoutingOn = $0 }))
                    .keyboardShortcut("r", modifiers: [.command, .shift])
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
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }

        MenuBarExtra("Junction", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            MenuBarContent()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Routing keeps running from the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Routing On", isOn: Binding(get: { model.graph.isRoutingOn }, set: { model.graph.isRoutingOn = $0 }))
        if !model.graph.virtualDevices.isEmpty {
            Divider()
            Text("Virtual Devices")
            ForEach(model.graph.virtualDevices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { device.isEnabled },
                    set: { value in model.updateVirtualDevice(device.id) { $0.isEnabled = value } }))
            }
        }
        if model.failingSinkCount > 0 {
            Divider()
            Text("\(model.failingSinkCount) destination\(model.failingSinkCount == 1 ? "" : "s") with problems")
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
                    if !model.inventory.driver.isInstalled && !model.graph.virtualDevices.isEmpty {
                        DriverBanner()
                    }
                }
                .overlay {
                    if model.graph.nodes.isEmpty { EmptyCanvas() }
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
        .navigationTitle("Junction")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .sheet(isPresented: $model.showStreamTemplate) {
            StreamTemplateSheet()
        }
        .alert("Junction", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
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
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("New Virtual Device") { model.addVirtualDevice() }
            Divider()
            Section("Sources") {
                Button("System Audio") { model.addNode(.systemAudio(excluding: [])) }
                Button("Default Input") { model.addNode(.defaultInput) }
                ForEach(model.inventory.inputDevices) { device in
                    Button(device.name) { model.addNode(.device(device.ref)) }
                }
            }
            if !model.inventory.apps.isEmpty {
                Section("Apps") {
                    ForEach(model.inventory.apps) { app in
                        Button(app.name) { model.addNode(.application(app.ref)) }
                    }
                }
            }
            Section("Outputs") {
                Button("Default Output") { model.addNode(.defaultOutput) }
                ForEach(model.inventory.outputDevices) { device in
                    Button(device.name) { model.addNode(.device(device.ref)) }
                }
            }
            Divider()
            Button("Stream Without Chat…") { model.showStreamTemplate = true }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add a source, an output or a virtual device")
    }
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
                Button("Stream Without Chat…") { model.showStreamTemplate = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Button("New Virtual Device") { model.addVirtualDevice() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
        .padding(40)
    }
}

/// "Stream without chat": a virtual device carrying all app audio except the chosen chat apps.
struct StreamTemplateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Stream Mix"
    @State private var chosen: Set<String> = ["com.hnc.Discord"]

    var body: some View {
        let candidates = candidates
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream Without Chat").font(.title2.weight(.semibold))
            Text("Makes a virtual device that carries everything your Mac plays except the apps you leave out. Pick it as the audio source in your streaming app: viewers hear your desktop, music and games, and the people in your call don't hear themselves.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Device name") { TextField("Stream Mix", text: $name).frame(maxWidth: 220) }
            Text("Leave out").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates) { app in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(app.bundleID) },
                            set: { if $0 { chosen.insert(app.bundleID) } else { chosen.remove(app.bundleID) } })) {
                            HStack {
                                NodeIcon(kind: .application(app), ports: PortCounts(inputs: 0, outputs: 2), size: 18)
                                Text(app.name)
                                if model.inventory.apps.contains(where: { $0.bundleID == app.bundleID }) {
                                    Text("running").font(.caption).foregroundStyle(.secondary)
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
                    let top = (model.graph.nodes.map { $0.y + 260 }.max() ?? 40) + 20
                    Templates.streamWithoutChat(&model.graph, excluding: excluded, deviceName: trimmed.isEmpty ? "Stream Mix" : trimmed,
                                                at: (60, model.graph.nodes.isEmpty ? 60 : top))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var candidates: [AppRef] {
        var list = Templates.chatApps
        for app in model.inventory.apps where !list.contains(where: { $0.bundleID == app.bundleID }) {
            list.append(app.ref)
        }
        let running = Set(model.inventory.apps.map(\.bundleID))
        return list.sorted { (running.contains($0.bundleID) ? 0 : 1, $0.name) < (running.contains($1.bundleID) ? 0 : 1, $1.name) }
    }
}
