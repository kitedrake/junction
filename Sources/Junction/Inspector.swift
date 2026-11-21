import JunctionCore
import SwiftUI

/// Settings for whatever is selected on the canvas.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.selection {
                case .node(let id):
                    if let node = model.node(id) { NodeInspector(node: node) } else { Overview() }
                case .nodes(let ids):
                    SelectionInspector(nodes: model.canvasNodes.filter { ids.contains($0.id) })
                case .cable(let id):
                    if let cable = model.graph.cables.first(where: { $0.id == id }) { CableInspector(cable: cable) } else { Overview() }
                case nil:
                    Overview()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Overview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing").font(.title3.weight(.semibold))
            if !model.graph.isRoutingOn {
                Text("Routing is off. Virtual devices stay available but receive silence.")
                    .foregroundStyle(.secondary)
            } else {
                let running = model.runningSinkCount, failing = model.failingSinkCount
                Text(running == 0 && failing == 0 ? "Nothing is connected yet."
                     : "\(running) destination\(running == 1 ? "" : "s") running" + (failing > 0 ? ", \(failing) with problems." : "."))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Help(symbol: "rectangle.stack", text: "Each virtual device has its own canvas: pick it in the sidebar. Sources on the left feed it; outputs on the right play it.")
                Help(symbol: "contextualmenu.and.cursorarrow", text: "Right-click the canvas, or drag from the sidebar, to add a source or an output; it connects to the device by itself.")
                Help(symbol: "hand.draw", text: "Drag from a channel on the right of a node to a channel on the left of another to change the wiring.")
                Help(symbol: "line.3.horizontal", text: "Drag the bar beside a node's title onto another node to connect all channels at once.")
                Help(symbol: "rectangle.dashed", text: "⌘-drag a box on empty canvas, or ⇧-click nodes, to select several: move, copy, duplicate or remove them together. Paste works on any device's canvas.")
                Help(symbol: "magnifyingglass", text: "Scroll or drag empty canvas to move around; pinch, ⌘-scroll, ⌘+ or ⌘− to zoom. The minimap shows where you are.")
                Help(symbol: "cursorarrow.click", text: "To remove a cable, drag it off the channel it plugs into and let go on empty canvas, or click it and press Delete.")
                Help(symbol: "mic", text: "Apps see each virtual device as a microphone (what you send into it) and as a speaker; its inspector can make it one or the other, or hide it.")
            }
            Button("Stream Without Chat…") { model.showStreamTemplate = true }
                .buttonStyle(.glass)
        }
    }
}

private struct Help: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NodeInspector: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        let info = model.info
        let ports = info.ports(node)
        HStack(spacing: 10) {
            NodeIcon(kind: node.kind, ports: ports, size: 34)
            VStack(alignment: .leading) {
                Text(info.title(node)).font(.title3.weight(.semibold))
                Text(info.subtitle(node)).font(.callout).foregroundStyle(.secondary)
            }
        }

        let issues = model.issues(for: node.id)
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues, id: \.self) { issue in
                    Label(issue, systemImage: model.isFailing(node.id) ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(model.isFailing(node.id) ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.silentTaps.contains(node.id) {
                    Button("Open Privacy Settings…") { model.openPrivacySettings(.systemAudio) }
                        .controlSize(.small)
                }
            }
        }

        if case .virtualDevice(let id) = node.kind, let device = model.graph.virtualDevice(id) {
            VirtualDeviceSettings(device: device)
            VirtualDeviceLevels(device: device)
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                GainSlider(title: ports.outputs > 0 && ports.inputs == 0 ? "Level sent" : "Level", dB: node.gainDB) { value in
                    model.updateNode(node.id, "Change Level") { $0.gainDB = value }
                }
                Toggle("Mute", isOn: Binding(get: { node.isMuted }, set: { value in model.updateNode(node.id, value ? "Mute" : "Unmute") { $0.isMuted = value } }))
                if node.kind.isTap {
                    Toggle(isOn: Binding(get: { node.mutesOriginal }, set: { value in model.updateNode(node.id, "Only Through Junction") { $0.mutesOriginal = value } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Only through Junction")
                            Text("Takes this audio away from the speakers it normally plays on while Junction captures it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(6)
        }

        if case .systemAudio(let excluded) = node.kind {
            ExcludedApps(node: node, excluded: excluded)
        }

        if ports.inputs > 0 || info.sampleRate(node) != nil {
            SampleRateSettings(node: node, receives: ports.inputs > 0)
        }

        if ports.inputs > 0 {
            SinkTiming(node: node)
        }

        Connections(node: node)

        HStack {
            Button(model.isDeviceNode(node) ? "Disconnect Everything" : "Disconnect") { model.disconnectAll(node.id) }
                .disabled(model.linkedNodes(node.id).isEmpty)
            Spacer()
            if !model.isDeviceNode(node) {
                Button("Remove", role: .destructive) { model.removeNode(node.id) }
            }
        }
    }
}

/// Several nodes selected: what they are, and what can be done to all of them.
private struct SelectionInspector: View {
    @Environment(AppModel.self) private var model
    let nodes: [Node]

    var body: some View {
        let info = model.info
        Text("\(nodes.count) Nodes Selected").font(.title3.weight(.semibold))
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(nodes) { node in
                    HStack(spacing: 8) {
                        NodeIcon(kind: node.kind, ports: info.ports(node), size: 18)
                        Text(info.title(node)).lineLimit(1)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("Drag any of them to move them together. Copy and paste carry the cables between them, onto this canvas or another device's.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Duplicate") { model.duplicateSelection() }
                .disabled(!model.canCopy)
            Button("Tidy Up") { model.tidyUp() }
            Spacer()
            Button("Remove", role: .destructive) { model.deleteSelection() }
                .disabled(!model.canCopy)
        }
    }
}

private struct VirtualDeviceSettings: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var name = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Available to apps", isOn: Binding(
                    get: { device.isEnabled },
                    set: { value in model.updateVirtualDevice(device.id, "Available to Apps") { $0.isEnabled = value } }))
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .onSubmit { commitName() }
                        .onChange(of: device.id, initial: true) { name = device.name }
                        .onChange(of: device.name) { name = device.name }
                        .onDisappear { commitName() }
                }
                Picker("Channels", selection: Binding(
                    get: { device.channels },
                    set: { value in model.updateVirtualDevice(device.id, "Change Channels") { $0.channels = value } })) {
                    ForEach(VirtualDevice.channelChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Sample rate", selection: Binding(
                    get: { device.sampleRate },
                    set: { value in model.updateVirtualDevice(device.id, "Change Sample Rate") { $0.sampleRate = value } })) {
                    ForEach(VirtualDevice.sampleRateChoices, id: \.self) { Text(formatRate($0)).tag($0) }
                }
                Picker("Apps see it as", selection: Binding(
                    get: { device.direction },
                    set: { value in model.updateVirtualDevice(device.id, "Change Direction") { $0.direction = value } })) {
                    ForEach(DeviceDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Icon", selection: Binding(
                    get: { device.icon },
                    set: { value in model.updateVirtualDevice(device.id, "Change Icon") { $0.icon = value } })) {
                    ForEach(DeviceIcon.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Hidden from apps", isOn: Binding(
                    get: { device.isHidden },
                    set: { value in model.updateVirtualDevice(device.id, "Hide from Apps") { $0.isHidden = value } }))
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Delete Virtual Device…", role: .destructive) { model.deviceToDelete = device.id }
                    .controlSize(.small)
            }
            .padding(6)
        }
    }

    private var explanation: String {
        let hidden = device.isHidden ? " It is hidden: apps don't list it, but Junction still routes it." : ""
        switch device.direction {
        case .both:
            return "Apps list it as “\(device.name)” for both input and output. Anything sent into it comes back out, so a streaming or call app can record it." + hidden
        case .inputOnly:
            return "Apps list it as a microphone only: they record what this canvas sends into it." + hidden
        case .outputOnly:
            return "Apps list it as a speaker only: what they play into it comes out on the right of this canvas." + hidden
        }
    }

    private func commitName() {
        guard name != device.name else { return }
        model.updateVirtualDevice(device.id, "Rename") { $0.name = name }
    }
}

/// A virtual device's volume and mute per side apps see (Sound settings and the volume keys change them too), and
/// its channel names.
private struct VirtualDeviceLevels: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice

    var body: some View {
        GroupBox("Volume") {
            VStack(alignment: .leading, spacing: 10) {
                if device.showsOutput {
                    side("Played into it", volume: device.outputVolume, muted: device.outputMuted,
                         setVolume: { value in model.updateVirtualDevice(device.id, "Change Volume") { $0.outputVolume = value } },
                         setMuted: { value in model.updateVirtualDevice(device.id, "Mute") { $0.outputMuted = value } })
                }
                if device.showsInput {
                    side("Recorded from it", volume: device.inputVolume, muted: device.inputMuted,
                         setVolume: { value in model.updateVirtualDevice(device.id, "Change Volume") { $0.inputVolume = value } },
                         setMuted: { value in model.updateVirtualDevice(device.id, "Mute") { $0.inputMuted = value } })
                }
                Text("The same volume apps and Sound settings show for “\(device.name)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Channel names") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<min(device.channels, 16), id: \.self) { channel in
                    ChannelNameField(device: device, channel: channel)
                }
                if device.channels > 16 {
                    Text("Channels after 16 keep their numbers.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func side(_ title: String, volume: Double, muted: Bool, setVolume: @escaping (Double) -> Void,
                      setMuted: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Toggle("Mute", isOn: Binding(get: { muted }, set: setMuted))
                    .controlSize(.small)
            }
            Slider(value: Binding(get: { volume }, set: { setVolume(($0 * 100).rounded() / 100) }), in: 0...1,
                   onEditingChanged: { if !$0 { model.endEditing() } })
                .controlSize(.small)
                .disabled(muted)
        }
    }
}

private struct ChannelNameField: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    let channel: Int
    @State private var text = ""

    var body: some View {
        LabeledContent(channelLabels(device.channels)[channel]) {
            TextField("Name", text: $text, prompt: Text("None"))
                .onSubmit { commit() }
                .onChange(of: device.id, initial: true) { text = device.channelName(channel) ?? "" }
                .onDisappear { commit() }
        }
    }

    private func commit() {
        guard text != (device.channelName(channel) ?? "") else { return }
        model.updateVirtualDevice(device.id, "Rename Channel") { device in
            while device.channelNames.count <= channel { device.channelNames.append("") }
            device.channelNames[channel] = text
        }
    }
}

/// A device node's effective rate and, for a receiving node, whether devices at other rates are converted.
private struct SampleRateSettings: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let receives: Bool

    var body: some View {
        GroupBox("Sample rate") {
            VStack(alignment: .leading, spacing: 8) {
                if let text = model.info.rateText(node, plan: model.plan) {
                    Text(text).font(.callout)
                }
                if receives {
                    Picker("Conversion", selection: Binding(
                        get: { node.rateConversion },
                        set: { value in model.updateNode(node.id, "Change Conversion") { $0.rateConversion = value } })) {
                        Text("Automatic").tag(RateConversion.automatic)
                        Text("Off").tag(RateConversion.off)
                    }
                    Text(node.rateConversion == .automatic
                         ? "Devices at another rate than this one are converted, so they can stay at the rate they run best at. Conversion adds about one buffer of each device to the delay below, and a little work for the Mac."
                         : "Devices at another rate are combined as they are and can sound off; set both to the same rate in Audio MIDI Setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The buffer size of a receiving node's routing, and the delay it ends up with.
private struct SinkTiming: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        GroupBox("Delay") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Buffer size", selection: Binding(
                    get: { node.bufferFrames ?? 0 },
                    set: { value in model.updateNode(node.id, "Change Buffer Size") { $0.bufferFrames = value == 0 ? nil : value } })) {
                    Text("Automatic").tag(0)
                    ForEach(Node.bufferChoices, id: \.self) { Text("\($0) frames").tag($0) }
                }
                Text(summary).font(.callout)
                Text("Smaller buffers mean less delay but more work for the Mac. Choose a bigger one if you hear crackles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: String {
        guard let status = model.statuses[node.id], status.state == .running, let latency = status.latency else {
            return "Shown while audio flows into it."
        }
        var text = "About \(formatDelay(latency)) from its sources to here"
        if let frames = status.bufferFrames { text += " (buffer: \(frames) frames)" }
        return text + "."
    }
}

/// Milliseconds, rounded, at least 1.
func formatDelay(_ seconds: TimeInterval) -> String {
    "\(max(1, Int((seconds * 1000).rounded()))) ms"
}

private struct ExcludedApps: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let excluded: [AppRef]

    var body: some View {
        GroupBox("Leave out") {
            VStack(alignment: .leading, spacing: 8) {
                if excluded.isEmpty {
                    Text("Nothing: every app is included (except Junction).").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(excluded) { app in
                    HStack {
                        NodeIcon(kind: .application(app), ports: PortCounts(inputs: 0, outputs: 2), size: 18)
                        Text(app.name)
                        Spacer()
                        Button {
                            set(excluded.filter { $0 != app })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Leave Out an App") {
                    let running = model.inventory.apps.map(\.ref).filter { !excluded.contains($0) }
                    if !running.isEmpty {
                        Section("Using audio now") {
                            ForEach(running) { app in Button(app.name) { set(excluded + [app]) } }
                        }
                    }
                    let chat = model.installedChatApps.filter { app in !excluded.contains(app) && !running.contains(app) }
                    if !chat.isEmpty {
                        Section("Chat apps") {
                            ForEach(chat) { app in Button(app.name) { set(excluded + [app]) } }
                        }
                    }
                    Divider()
                    Button("Choose App…") {
                        if let app = model.chooseApp(), !excluded.contains(where: { $0.bundleID == app.bundleID }) { set(excluded + [app]) }
                    }
                    .disabled(model.isDemo)
                }
                .fixedSize()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func set(_ apps: [AppRef]) {
        model.updateNode(node.id, "Change Apps Left Out") { $0.kind = .systemAudio(excluding: apps) }
    }
}

private struct Connections: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        let cables = model.graph.cables.filter { $0.from.node == node.id || $0.to.node == node.id }
        if !cables.isEmpty {
            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(cables) { cable in
                        CableRow(cable: cable)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CableRow: View {
    @Environment(AppModel.self) private var model
    let cable: Cable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cableTitle(cable, model: model))
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button {
                    model.removeCable(cable.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Disconnect")
            }
            GainSlider(title: nil, dB: cable.gainDB) { value in model.updateCable(cable.id) { $0.gainDB = value } }
        }
        .opacity(model.plan.idleCables.contains(cable.id) ? 0.6 : 1)
    }
}

private struct CableInspector: View {
    @Environment(AppModel.self) private var model
    let cable: Cable

    var body: some View {
        Text("Cable").font(.title3.weight(.semibold))
        Text(cableTitle(cable, model: model)).foregroundStyle(.secondary)
        if model.plan.idleCables.contains(cable.id) {
            Label("Not carrying audio: one of its ends isn't available, or routing is off.", systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if let status = model.statuses[cable.to.node], status.state == .running, let latency = status.latency {
            Label("About \(formatDelay(latency)) delay", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("From the start of the cable to the end, including the buffers on both sides")
        }
        GroupBox {
            GainSlider(title: "Level", dB: cable.gainDB) { value in model.updateCable(cable.id) { $0.gainDB = value } }
                .padding(6)
        }
        Button("Disconnect", role: .destructive) { model.removeCable(cable.id) }
    }
}

@MainActor private func cableTitle(_ cable: Cable, model: AppModel) -> String {
    let info = model.info
    func end(_ port: PortRef, output: Bool) -> String {
        guard let node = model.node(port.node) else { return "?" }
        let labels = info.channelLabels(node, outputs: output)
        let label = port.channel < labels.count ? labels[port.channel] : "\(port.channel + 1)"
        return "\(info.title(node)) \(label)"
    }
    return "\(end(cable.from, output: true)) → \(end(cable.to, output: false))"
}

/// A level fader. Option- or Command-click (or double-click) puts it back to 0 dB.
struct GainSlider: View {
    @Environment(AppModel.self) private var model
    let title: String?
    let dB: Double
    let onChange: (Double) -> Void
    /// Option or Command is held: a click on the fader resets it instead of moving it.
    @State private var resetArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let title { Text(title) }
                Spacer()
                Text(Gain.text(dB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Slider(value: Binding(get: { dB }, set: { onChange(($0 * 2).rounded() / 2) }), in: Gain.floorDB...Gain.ceilingDB,
                   onEditingChanged: { if !$0 { model.endEditing() } })
                .controlSize(.small)
                .onTapGesture(count: 2) { onChange(0) }
                .overlay {
                    // The slider handles its own clicks, so while a modifier is down a clear layer takes them.
                    if resetArmed {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { onChange(0) }
                    }
                }
                .onModifierKeysChanged(mask: [.option, .command]) { _, keys in resetArmed = !keys.isEmpty }
                .help("Option-click or Command-click to reset to 0 dB")
        }
    }
}
