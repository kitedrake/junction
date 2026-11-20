import JunctionCore
import SwiftUI

/// Virtual devices (with their on/off switches) and everything that can be added to the canvas.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            // Pinning this under the list (safeAreaInset) stops the whole window from drawing on macOS 26, so it is a
            // section of the list.
            if model.driverUpdate != .upToDate {
                Section { DriverNotice() }
            }
            Section {
                ForEach(model.graph.virtualDevices) { device in
                    VirtualDeviceRow(device: device)
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
                PaletteRow(kind: .systemAudio(excluding: []), title: "System Audio", detail: "Everything apps play")
                PaletteRow(kind: .defaultInput, title: "Default Input",
                           detail: model.inventory.device(model.inventory.defaultInputUID)?.name ?? "None")
                ForEach(model.inventory.inputDevices) { device in
                    PaletteRow(kind: .device(device.ref), title: device.name, detail: channels(device.inputChannels))
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
                    PaletteRow(kind: .application(app.ref), title: app.name, detail: app.isPlaying ? "Playing" : nil)
                }
            }

            Section("Outputs") {
                PaletteRow(kind: .defaultOutput, title: "Default Output",
                           detail: model.inventory.device(model.inventory.defaultOutputUID)?.name ?? "None")
                ForEach(model.inventory.outputDevices) { device in
                    PaletteRow(kind: .device(device.ref), title: device.name, detail: channels(device.outputChannels))
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
                Text("\(device.channels) ch · \(formatRate(device.sampleRate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { device.isEnabled },
                set: { value in model.updateVirtualDevice(device.id) { $0.isEnabled = value } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(device.isEnabled ? "Published: apps can use it" : "Off: apps don't see it")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let id = model.addNode(.virtualDevice(device.id))
            model.selection = .node(id)
        }
        .contextMenu {
            Button("Show on Canvas") { model.addNode(.virtualDevice(device.id)) }
            Divider()
            Button("Delete Virtual Device", role: .destructive) { model.removeVirtualDevice(device.id) }
        }
    }
}

struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    let kind: NodeKind
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
                model.addNode(kind)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Add to the canvas")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.addNode(kind) }
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
    return value == value.rounded() ? "\(Int(value)) kHz" : String(format: "%.1f kHz", value)
}
