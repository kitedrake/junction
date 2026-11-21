import JunctionCore
import SwiftUI

/// Virtual devices (with their on/off switches) and everything that can be added to the canvas.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.canvas }, set: { if let id = $0 { model.showCanvas(id) } })) {
            // Pinning this under the list (safeAreaInset) stops the whole window from drawing on macOS 26, so it is a
            // section of the list.
            if model.driverUpdate != .upToDate {
                Section { DriverNotice() }
            }
            Section {
                ForEach(model.graph.virtualDevices) { device in
                    VirtualDeviceRow(device: device)
                        .tag(device.id)
                }
                if model.graph.virtualDevices.isEmpty {
                    Text("None yet. Apps see virtual devices as microphones and speakers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Button {
                    model.addVirtualDevice()
                } label: {
                    Label("New Virtual Device", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Virtual Devices")
            }

            Section("Sources") {
                PaletteRow(kind: .systemAudio(excluding: []), role: .source, title: "System Audio", detail: "Everything apps play")
                PaletteRow(kind: .defaultInput, role: .source, title: "Default Input",
                           detail: model.inventory.device(model.inventory.defaultInputUID)?.name ?? "None")
                ForEach(model.inventory.inputDevices) { device in
                    PaletteRow(kind: .device(device.ref), role: .source, title: device.name, detail: channels(device.inputChannels))
                }
            }

            Section("Apps") {
                if model.inventory.apps.isEmpty {
                    Text("Apps appear here once they have used audio.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                ForEach(model.inventory.apps) { app in
                    PaletteRow(kind: .application(app.ref), role: .source, title: app.name, detail: app.isPlaying ? "Playing" : nil)
                }
            }

            Section("Outputs") {
                PaletteRow(kind: .defaultOutput, role: .output, title: "Default Output",
                           detail: model.inventory.device(model.inventory.defaultOutputUID)?.name ?? "None")
                ForEach(model.inventory.outputDevices) { device in
                    PaletteRow(kind: .device(device.ref), role: .output, title: device.name, detail: channels(device.outputChannels))
                }
            }

            if case .installed(let version) = model.inventory.driver {
                Section("Driver") {
                    Label("Junction driver \(version) installed", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func channels(_ count: Int) -> String { count == 1 ? "1 channel" : "\(count) channels" }
}

struct VirtualDeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice

    var body: some View {
        HStack(spacing: 8) {
            NodeIcon(kind: .virtualDevice(device.id), ports: PortCounts(inputs: device.channels, outputs: device.channels), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { device.isEnabled },
                set: { value in model.updateVirtualDevice(device.id, value ? "Turn On" : "Turn Off") { $0.isEnabled = value } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(device.isEnabled ? "Published: apps can use it" : "Off: apps don't see it")
        }
        // Dropped on its own canvas, the device moves there.
        .draggable(PaletteItem(kind: .virtualDevice(device.id), role: nil))
        .contextMenu {
            Button(device.isEnabled ? "Turn Off" : "Turn On") {
                model.updateVirtualDevice(device.id, device.isEnabled ? "Turn Off" : "Turn On") { $0.isEnabled.toggle() }
            }
            Button(device.isHidden ? "Show to Apps" : "Hide from Apps") {
                model.updateVirtualDevice(device.id, device.isHidden ? "Show to Apps" : "Hide from Apps") { $0.isHidden.toggle() }
            }
            Menu("Apps See It As") {
                ForEach(DeviceDirection.allCases, id: \.self) { direction in
                    Toggle(direction.title, isOn: Binding(
                        get: { device.direction == direction },
                        set: { _ in model.updateVirtualDevice(device.id, "Change Direction") { $0.direction = direction } }))
                }
            }
            Divider()
            Button("Delete Virtual Device…", role: .destructive) { model.deviceToDelete = device.id }
        }
    }
}

extension VirtualDeviceRow {
    /// "2 ch · 48 kHz", plus the direction when apps see one side only and "hidden" when they see none.
    var details: String {
        var parts = ["\(device.channels) ch", formatRate(device.sampleRate)]
        switch device.direction {
        case .both: break
        case .inputOnly: parts.append("input only")
        case .outputOnly: parts.append("output only")
        }
        if device.isHidden { parts.append("hidden") }
        return parts.joined(separator: " · ")
    }
}

struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    let kind: NodeKind
    let role: NodeRole
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            NodeIcon(kind: kind, ports: NodeInfo(graph: model.graph, inventory: model.inventory).ports(Node(kind: kind)), size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.addNode(kind, as: role)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.canvas == nil)
            .help(model.canvasDevice.map { "Add to \($0.name)" } ?? "Create a virtual device first")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.addNode(kind, as: role) }
        .draggable(PaletteItem(kind: kind, role: role))
        .accessibilityAction(named: "Add to Canvas") { model.addNode(kind, as: role) }
    }
}

struct DriverNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.driverUpdate {
            case .available(let installed, let bundled):
                Label("Driver update available", systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.medium))
                note("Installed: \(installed). This copy of Junction has \(bundled). Updating asks for your password and restarts Core Audio (sound stops for a moment); routing starts again on its own.")
                Button(model.isInstallingDriver ? "Installing…" : "Update Driver…") { model.installDriver() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingDriver || model.isDemo)
            case .appIsOlder(let installed, let bundled):
                Label("Newer driver installed", systemImage: "info.circle.fill")
                    .font(.callout.weight(.medium))
                note("The installed driver (\(installed)) is newer than this copy of Junction (\(bundled)). Open the latest Junction.")
            case .notInstalled, .upToDate:
                Label("Driver not installed", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout.weight(.medium))
                note("Virtual devices need Junction's audio driver. Installing asks for your password and restarts Core Audio (sound stops for a moment).")
                Button(model.isInstallingDriver ? "Installing…" : "Install Driver…") { model.installDriver() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingDriver || model.isDemo)
            }
        }
        .padding(.vertical, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func formatRate(_ rate: Double) -> String {
    let value = rate / 1000
    return formatSampleRate(rate)
}
