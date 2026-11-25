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
            Menu("Templates") { TemplateMenuItems() }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
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
                GainSlider(title: ports.outputs > 0 && ports.inputs == 0 ? "Level sent" : "Level", dB: node.gainDB,
                           fader: AppModel.levelKey(node: node.id)) { value in
                    model.moveLevel(node: node.id, to: value)
                }
                HStack {
                    Toggle("Mute", isOn: Binding(get: { node.isMuted }, set: { value in model.updateNode(node.id, value ? "Mute" : "Unmute") { $0.isMuted = value } }))
                    Spacer()
                    MIDILearnButton(target: .nodeMute(node.id))
                }
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

        EffectsSection(node: node)

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
                HStack {
                    Toggle("Available to apps", isOn: Binding(
                        get: { device.isEnabled },
                        set: { value in model.updateVirtualDevice(device.id, "Available to Apps") { $0.isEnabled = value } }))
                    Spacer()
                    MIDILearnButton(target: .deviceEnabled(device.id))
                }
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
                         fader: AppModel.volumeKey(device: device.id, input: false),
                         setVolume: { value in model.moveVolume(device: device.id, input: false, to: value) },
                         setMuted: { value in model.updateVirtualDevice(device.id, "Mute") { $0.outputMuted = value } })
                }
                if device.showsInput {
                    side("Recorded from it", volume: device.inputVolume, muted: device.inputMuted,
                         fader: AppModel.volumeKey(device: device.id, input: true),
                         setVolume: { value in model.moveVolume(device: device.id, input: true, to: value) },
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

    private func side(_ title: String, volume: Double, muted: Bool, fader: String, setVolume: @escaping (Double) -> Void,
                      setMuted: @escaping (Bool) -> Void) -> some View {
        VolumeSide(title: title, volume: volume, muted: muted, fader: fader, setVolume: setVolume, setMuted: setMuted)
    }
}

/// One side's volume and mute.
private struct VolumeSide: View {
    @Environment(AppModel.self) private var model
    let title: String
    let volume: Double
    let muted: Bool
    let fader: String
    let setVolume: (Double) -> Void
    let setMuted: (Bool) -> Void

    var body: some View {
        let volume = model.fader(fader).value ?? volume
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
        text += "."
        if let overloads = status.overloads, overloads > 0 {
            text += " \(overloads) overload\(overloads == 1 ? "" : "s"): buffers its routing didn't finish in time."
        }
        return text
    }
}

/// A node's effect chain: add, reorder, bypass and adjust effects, with the levels after the chain and the delay it
/// adds.
private struct EffectsSection: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        let ports = model.info.ports(node)
        // Sources are metered on their way out (after their effects); the device and outputs on their way in.
        let metersOutput = !model.isDeviceNode(node) && ports.inputs == 0
        let channels = metersOutput ? ports.outputs : ports.inputs
        GroupBox("Effects") {
            VStack(alignment: .leading, spacing: 10) {
                if node.effects.isEmpty {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(node.effects.enumerated()), id: \.element.id) { index, effect in
                    if index > 0 { Divider() }
                    EffectRow(node: node, effect: effect, isFirst: index == 0, isLast: index == node.effects.count - 1)
                }
                HStack {
                    Menu("Add Effect") {
                        Section("Built in") {
                            ForEach([EffectKind.gain, .pan, .mono, .gate, .calibration].filter {
                                $0.isOffered(onOutput: model.isOutputNode(node))
                            }, id: \.self) { kind in
                                Button(kind.title, systemImage: kind.symbol) { model.addEffect(kind, to: node.id) }
                            }
                        }
                        Section("Audio Units") {
                            ForEach([EffectKind.highPass, .equalizer, .dynamics, .limiter], id: \.self) { kind in
                                Button(kind.title, systemImage: kind.symbol) { model.addEffect(kind, to: node.id) }
                            }
                        }
                        Section("Plugins") {
                            Button("Audio Unit…", systemImage: "puzzlepiece.extension") { model.showPluginPicker(for: node.id) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if !node.effects.isEmpty, let latency = model.effectLatency(node.id) {
                        Text(latency > 0.0005 ? "Adds \(formatDelay(latency))" : "No added delay")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Included in the delay shown for the destination")
                    }
                }
                if !node.effects.isEmpty, channels > 0 {
                    HStack(spacing: 6) {
                        Text("After effects").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        ForEach(0..<min(channels, 8), id: \.self) { channel in
                            LevelBar(level: model.level(node.id, output: metersOutput, channel: channel), tint: .green,
                                     label: "Level after effects, channel \(channel + 1)")
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var explanation: String {
        if model.isDeviceNode(node) { return "Effects here process the mix before it goes into the device, so apps recording it hear them." }
        if model.info.ports(node).inputs > 0 { return "Effects here process what this output receives." }
        return "Effects here process this source before it is mixed into the device, for example a noise gate on a microphone."
    }
}

private struct EffectRow: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let effect: Effect
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let kind = effect.kind
        let installed = model.isInstalled(effect)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind?.symbol ?? (effect.isPlugin ? "puzzlepiece.extension" : "questionmark.square.dashed"))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(effect.title).lineLimit(1)
                    if let vendor = effect.vendor {
                        Text(vendor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                MIDILearnButton(target: .effectBypass(effect.id))
                Toggle("On", isOn: Binding(get: { !effect.bypass },
                                           set: { model.setEffectBypass(effect.id, in: node.id, !$0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(effect.bypass ? "Bypassed: turn on" : "On: bypass")
                Button { model.moveEffect(effect.id, in: node.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(isFirst)
                    .help("Move earlier in the chain")
                Button { model.moveEffect(effect.id, in: node.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast)
                    .help("Move later in the chain")
                Button { model.removeEffect(effect.id, from: node.id) } label: { Image(systemName: "minus.circle") }
                    .help("Remove")
            }
            .buttonStyle(.borderless)
            if !installed {
                Label("Not installed on this Mac: the audio passes through it. Its settings are kept for when it's back.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = model.effectProblem(effect.id) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installed, model.isStalling(effect) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Holding up the audio: it often takes over half of each buffer's time. Bypass it if you hear dropouts.",
                          systemImage: "gauge.with.dots.needle.100percent")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Bypass") { model.setEffectBypass(effect.id, in: node.id, true) }
                        Button("Keep Running") { model.keepStallingEffect(effect.id) }
                    }
                    .controlSize(.small)
                }
            }
            if effect.isPlugin, installed {
                HStack {
                    Button("Open Window", systemImage: "macwindow") { model.openPluginWindow(effect, in: node.id) }
                        .controlSize(.small)
                        .help("Opens the plugin's own window; its settings are saved with your setup")
                    Spacer()
                    if let cost = model.effectCost(effect.id) { CostText(cost: cost) }
                }
            } else if let cost = model.effectCost(effect.id), !effect.bypass {
                HStack {
                    Spacer()
                    CostText(cost: cost)
                }
            }
            if let kind, !effect.bypass {
                ForEach(kind.parameters) { parameter in
                    EffectSlider(parameter: parameter, value: effect.value(parameter),
                                 fader: AppModel.effectKey(effect.id, parameter)) { value in
                        model.setEffectParameter(effect.id, in: node.id, parameter, value)
                    }
                }
            }
            if kind == .calibration { CalibrationDetails(node: node, effect: effect) }
        }
        .opacity(effect.bypass ? 0.6 : 1)
    }
}

/// Calibration's profile: what it is and what it's for, its curves, and loading and exporting EQ presets.
private struct CalibrationDetails: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let effect: Effect

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let profile = effect.calibration {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(details(profile)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let current = model.currentDevice(node)
                if profile.isForAnotherDevice(than: current?.uid) {
                    Label(mismatch(profile, current: current?.name), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FrequencyResponseGraph(curves: curves(profile))
            } else {
                Text("No correction loaded, so the audio passes through. Measure your speakers, or load a parametric EQ preset for your headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Calibrate Speakers…") { model.calibrateSpeakers(node.id) }
                    .help("Measures the speakers with a measurement microphone and fits a correction")
                    .disabled(model.currentDevice(node) == nil)
                if let profile = effect.calibration, profile.kind == .speakers, profile.canRefit {
                    Button("Adjust…") { model.adjustCalibration(effect.id, in: node.id) }
                        .help("Changes the target and limits and fits again from the saved measurements, without measuring")
                }
            }
            .controlSize(.small)
            HStack {
                Button("Load EQ Preset…") { model.loadEQPreset(into: effect.id, in: node.id) }
                    .help("Reads a text file with a Preamp line and Filter lines (peaking and shelving filters)")
                if let profile = effect.calibration {
                    if profile.channels.count > 1 {
                        Menu("Export EQ Preset…") {
                            ForEach(profile.channels.indices, id: \.self) { channel in
                                Button("Channel \(channel + 1)…") { model.exportEQPreset(profile, channel: channel) }
                            }
                        }
                        .fixedSize()
                    } else {
                        Button("Export EQ Preset…") { model.exportEQPreset(profile) }
                    }
                }
            }
            .controlSize(.small)
        }
    }

    /// "Headphones, from an EQ preset · 25 Nov 2026 · for AirPods Pro".
    private func details(_ profile: CalibrationProfile) -> String {
        let kind = switch profile.kind {
        case .speakers: "Speakers, measured in the room"
        case .headphones: "Headphones, from an EQ preset"
        case .imported: "From an imported measurement"
        }
        var parts = [kind, profile.date.formatted(date: .abbreviated, time: .omitted)]
        if let device = profile.deviceName ?? profile.deviceUID { parts.append("for \(device)") }
        return parts.joined(separator: " · ")
    }

    private func mismatch(_ profile: CalibrationProfile, current: String?) -> String {
        let made = profile.deviceName ?? "another device"
        let now = current ?? "no device"
        let place = node.kind == .defaultOutput ? "Default Output plays on \(now) now (Sound settings)" : "This output is \(now)"
        return "Made for \(made). \(place), so the correction may not suit it."
    }

    /// The correction per channel (at Amount), and for a measured profile each channel's average measurement and,
    /// for the first channel, the result with the correction.
    private func curves(_ profile: CalibrationProfile) -> [ResponseCurve] {
        let amount = effect.value(EffectKind.calibration.parameters[0]) / 100
        let scaled = profile.scaled(by: amount)
        let frequencies = CalibrationGrid.frequencies
        let colors: [Color] = [.accentColor, .orange, .green, .pink]
        let channels = Set(profile.channels.map(\.filters)).count > 1 || Set(profile.channels.map(\.level)).count > 1
            ? min(profile.channels.count, colors.count) : 1
        var curves = (0..<channels).map { channel in
            ResponseCurve(name: channels == 1 ? "Correction" : "Correction \(channel + 1)", color: colors[channel],
                          frequencies: frequencies, levels: scaled.curve(channel: channel, sampleRate: 48_000))
        }
        let averages = profile.measurements.filter { $0.position == nil }.sorted { $0.channel < $1.channel }.prefix(2)
        for measurement in averages {
            curves.append(ResponseCurve(name: averages.count == 1 ? "Measured" : "Measured \(measurement.channel + 1)",
                                        color: measurement.channel == 0 ? .secondary : .brown,
                                        frequencies: frequencies, levels: centered(measurement), isDashed: true))
        }
        if let first = averages.first {
            let correction = scaled.curve(channel: first.channel, sampleRate: 48_000)
            curves.append(ResponseCurve(name: "Result", color: .purple, frequencies: frequencies,
                                        levels: zip(centered(first), correction).map(+)))
        }
        return curves
    }

    /// A measurement on the grid, moved so its midrange sits at 0 dB (the correction's scale).
    private func centered(_ measurement: CalibrationMeasurement) -> [Double] {
        let levels = measurement.curve.resampled().levels
        let midrange = zip(CalibrationGrid.frequencies, levels).filter { CalibrationAnalysis.midrange.contains($0.0) }.map(\.1)
        let offset = midrange.isEmpty ? 0 : midrange.reduce(0, +) / Double(midrange.count)
        return levels.map { $0 - offset }
    }
}

/// "CPU 1.2 % · adds 3 ms · own process".
private struct CostText: View {
    let cost: EffectCost

    var body: some View {
        var parts = [String(format: cost.load < 0.1 ? "CPU %.1f %%" : "CPU %.0f %%", cost.load * 100)]
        if cost.latency > 0.0005 { parts.append("adds \(formatDelay(cost.latency))") }
        if cost.outOfProcess { parts.append("own process") }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .help(String(format: "Share of one CPU core it used lately; its slowest buffer took %.0f %% of the buffer's time.", cost.peak * 100))
    }
}

/// One effect parameter. Frequencies and times move along a logarithmic scale.
private struct EffectSlider: View {
    @Environment(AppModel.self) private var model
    let parameter: EffectParameter
    let value: Double
    /// What it moves (`AppModel.effectKey`): while it moves it shows that value, before the graph has it.
    let fader: String
    let onChange: (Double) -> Void

    var body: some View {
        let value = model.fader(fader).value ?? value
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.name).font(.callout)
                Spacer()
                Text(parameter.text(value)).monospacedDigit().foregroundStyle(.secondary).font(.callout)
            }
            Slider(value: Binding(get: { position(value) }, set: { onChange(parameterValue(at: $0)) }), in: 0...1,
                   onEditingChanged: { if !$0 { model.endEditing() } })
                .controlSize(.small)
                .onTapGesture(count: 2) {
                    onChange(parameter.defaultValue)
                    model.endEditing()
                }
                .accessibilityLabel(parameter.name)
                .accessibilityValue(parameter.text(value))
                .help("Double-click to reset to \(parameter.text(parameter.defaultValue))")
        }
    }

    private func position(_ value: Double) -> Double {
        let range = parameter.range
        if parameter.isLogarithmic {
            return log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func parameterValue(at position: Double) -> Double {
        let range = parameter.range, position = min(max(position, 0), 1)
        let raw = parameter.isLogarithmic
            ? range.lowerBound * pow(range.upperBound / range.lowerBound, position)
            : range.lowerBound + position * (range.upperBound - range.lowerBound)
        // Round to what the label shows.
        switch parameter.unit {
        case .decibels: return (raw * 2).rounded() / 2
        case .hertz: return raw >= 1000 ? (raw / 100).rounded() * 100 : raw.rounded()
        case .seconds: return raw < 0.01 ? (raw * 10_000).rounded() / 10_000 : (raw * 1000).rounded() / 1000
        case .balance: return (raw * 100).rounded() / 100
        case .percent: return raw.rounded()
        }
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
            HStack(alignment: .bottom, spacing: 6) {
                GainSlider(title: nil, dB: cable.gainDB, fader: AppModel.levelKey(cable: cable.id)) { value in
                    model.moveLevel(cable: cable.id, to: value)
                }
                MIDILearnButton(target: .cableLevel(cable.id))
            }
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
            HStack(alignment: .bottom, spacing: 6) {
                GainSlider(title: "Level", dB: cable.gainDB, fader: AppModel.levelKey(cable: cable.id)) { value in
                    model.moveLevel(cable: cable.id, to: value)
                }
                MIDILearnButton(target: .cableLevel(cable.id))
            }
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
    /// What it moves (`AppModel.levelKey`): while it moves it shows that value, before the graph has it.
    let fader: String
    let onChange: (Double) -> Void
    /// Option or Command is held: a click on the fader resets it instead of moving it.
    @State private var resetArmed = false

    var body: some View {
        let dB = model.fader(fader).value ?? dB
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
                .onTapGesture(count: 2) { reset() }
                .overlay {
                    // The slider handles its own clicks, so while a modifier is down a clear layer takes them.
                    if resetArmed {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { reset() }
                    }
                }
                .onModifierKeysChanged(mask: [.option, .command]) { _, keys in resetArmed = !keys.isEmpty }
                .help("Option-click or Command-click to reset to 0 dB")
        }
    }

    private func reset() {
        onChange(0)
        model.endEditing()
    }
}
