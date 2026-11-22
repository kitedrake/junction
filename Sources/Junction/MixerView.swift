import JunctionCore
import SwiftUI

/// The shown canvas as a mixing desk: a strip per source, the device and each output, then the headphone monitor.
/// Every control edits the same nodes and cables as the canvas (see Mixer.swift).
struct MixerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.mixerStrips) { strip in
                    if let node = model.node(strip.node) {
                        if strip.role == .device { Divider() }
                        ChannelStrip(strip: strip, node: node)
                        if strip.role == .device { Divider() }
                    }
                }
                Divider()
                MonitorStrip()
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mixer")
    }
}

enum StripMetrics {
    static let width: CGFloat = 112
    static let effectsHeight: CGFloat = 66
}

private struct ChannelStrip: View {
    @Environment(AppModel.self) private var model
    let strip: MixerStrip
    let node: Node

    var body: some View {
        let info = model.info
        let ports = info.ports(node)
        let tint = NodeStyle.tint(node.kind)
        let title = info.title(node)
        let issues = model.issues(for: node.id)
        let selected = model.isSelected(node.id)
        VStack(spacing: 8) {
            Button {
                model.selection = .node(node.id)
            } label: {
                VStack(spacing: 4) {
                    NodeIcon(kind: node.kind, ports: ports, size: 24)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(height: 28, alignment: .top)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if model.isFailing(node.id) || !issues.isEmpty {
                        Image(systemName: model.isFailing(node.id) ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.isFailing(node.id) ? .red : .yellow)
                            .help(issues.joined(separator: "\n"))
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Show \(title) in the inspector")
            .accessibilityLabel("\(title), \(roleName)")

            StripEffects(node: node)

            PanKnob(strip: strip, title: title)

            HStack(alignment: .bottom, spacing: 6) {
                VerticalFader(dB: node.gainDB, fader: AppModel.levelKey(node: node.id), tint: tint, label: "\(title) level") { value in
                    model.moveLevel(node: node.id, to: value)
                }
                StripMeters(levels: strip.ports.map {
                    model.level(node.id, output: strip.role != .output, channel: $0.channel)
                }, tint: tint, label: "\(title) meter")
            }
            .frame(maxHeight: .infinity)

            Text(Gain.text(node.gainDB))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                StripButton(letter: "M", isOn: node.isMuted, color: .red, help: node.isMuted ? "Unmute" : "Mute") {
                    model.updateNode(node.id, node.isMuted ? "Unmute" : "Mute") { $0.isMuted.toggle() }
                }
                StripButton(letter: "S", isOn: model.monitor?.isListening(to: node.id) ?? false, color: .yellow,
                            help: model.hasMonitorOutput ? "Listen to \(title) alone on the monitor (the mix doesn't change)"
                                                         : "Choose a monitor output to listen on") {
                    model.toggleSolo(strip)
                }
                .disabled(!model.hasMonitorOutput)
            }

            if strip.role == .source {
                MonitorSendControl(node: node.id, title: title)
            } else {
                Text(" ").font(.caption2).frame(height: 34)  // keeps the strips' faders level
            }
        }
        .padding(8)
        .frame(width: StripMetrics.width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.07)))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .opacity(node.isMuted ? 0.75 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) strip")
    }

    private var roleName: String {
        switch strip.role {
        case .source: "source"
        case .device: "virtual device"
        case .output: "output"
        }
    }
}

/// A strip's effect chain: each effect with its bypass, and a menu to add more (the inspector edits their settings).
private struct StripEffects: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.effects) { effect in
                        Button {
                            model.setEffectBypass(effect.id, in: node.id, !effect.bypass)
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(effect.bypass ? Color.secondary.opacity(0.4) : .green).frame(width: 6, height: 6)
                                Text(effect.title).lineLimit(1).strikethrough(effect.bypass)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(effect.bypass ? "\(effect.title) is bypassed: click to turn it on" : "Click to bypass \(effect.title)")
                        .accessibilityLabel(effect.title)
                        .accessibilityValue(effect.bypass ? "Bypassed" : "On")
                    }
                }
            }
            .frame(height: StripMetrics.effectsHeight - 20)
            Menu {
                ForEach(EffectKind.allCases, id: \.self) { kind in
                    Button(kind.title, systemImage: kind.symbol) { model.addEffect(kind, to: node.id) }
                }
                Divider()
                Button("Audio Unit…", systemImage: "puzzlepiece.extension") { model.showPluginPicker(for: node.id) }
            } label: {
                Text(node.effects.isEmpty ? "Add Effect" : "Add")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add an effect to \(model.info.title(node))")
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: StripMetrics.effectsHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}

/// Balance between the cables to the left and right channels, where the routing has both.
private struct PanKnob: View {
    @Environment(AppModel.self) private var model
    let strip: MixerStrip
    let title: String

    var body: some View {
        VStack(spacing: 1) {
            if strip.hasPan, let saved = Mixer.pan(strip.node, graph: model.graph) {
                let pan = model.fader(AppModel.panKey(node: strip.node)).value ?? saved
                Slider(value: Binding(get: { pan }, set: { model.setPan(($0 * 20).rounded() / 20, of: strip.node) }),
                       in: -1...1, onEditingChanged: { if !$0 { model.endEditing() } })
                    .controlSize(.mini)
                    .onTapGesture(count: 2) { model.setPan(0, of: strip.node); model.endEditing() }
                    .accessibilityLabel("\(title) pan")
                    .accessibilityValue(Mixer.panText(pan))
                    .help("Pan: sets the levels of the cables to the left and right channels. Double-click to center.")
                Text(Mixer.panText(pan))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("No pan")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(height: 30)
                    .help("Pan needs cables to both the left and the right channel")
            }
        }
        .frame(height: 32)
    }
}

/// A level fader standing up: drag to change, double-click (or Option-click) for 0 dB.
struct VerticalFader: View {
    @Environment(AppModel.self) private var model
    let dB: Double
    /// What it moves (`AppModel.levelKey`): while it moves it shows that value, before the graph has it.
    let fader: String
    let tint: Color
    let label: String
    let onChange: (Double) -> Void
    @State private var start: Double?

    private static let range = Gain.floorDB...Gain.ceilingDB

    var body: some View {
        let dB = model.fader(fader).value ?? dB
        GeometryReader { geometry in
            let height = max(geometry.size.height - 14, 1)
            let fraction = (min(max(dB, Self.range.lowerBound), Self.range.upperBound) - Self.range.lowerBound)
                / (Self.range.upperBound - Self.range.lowerBound)
            let unity = (0 - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)
            ZStack(alignment: .top) {
                Capsule().fill(.quaternary).frame(width: 5)
                    .padding(.vertical, 7)
                Rectangle().fill(.secondary).frame(width: 14, height: 1)
                    .offset(y: 7 + height * (1 - unity))
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .overlay(Rectangle().fill(.white.opacity(0.8)).frame(height: 1))
                    .frame(width: 22, height: 14)
                    .shadow(radius: 1, y: 0.5)
                    .offset(y: height * (1 - fraction))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if NSEvent.modifierFlags.contains(.option) { onChange(0); return }
                        let base = start ?? dB
                        if start == nil { start = dB }
                        let span = Self.range.upperBound - Self.range.lowerBound
                        let value = base - Double(value.translation.height / height) * span
                        onChange((min(max(value, Self.range.lowerBound), Self.range.upperBound) * 2).rounded() / 2)
                    }
                    .onEnded { _ in
                        start = nil
                        model.endEditing()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0); model.endEditing() })
        }
        .frame(width: 26)
        .frame(minHeight: 60)
        .help("Drag to change the level. Double-click or Option-click for 0 dB.")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Gain.text(dB))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            onChange(min(max(dB + step, Self.range.lowerBound), Self.range.upperBound))
            model.endEditing()
        }
    }
}

/// One bar per channel, bottom to top: −60 dB to 0 dB, yellow above −6 dB, red at full scale.
struct StripMeters: View {
    let levels: [Float]
    let tint: Color
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.prefix(8).enumerated()), id: \.offset) { _, level in
                GeometryReader { geometry in
                    let dB = level > 0 ? 20 * log10(Double(level)) : -90
                    let fraction = max(0, min(1, (dB + 60) / 60))
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(level >= 1 ? Color.red : (dB > -6 ? Color.yellow : tint))
                            .frame(height: geometry.size.height * fraction)
                    }
                }
                .frame(width: 4)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(CanvasAccessibility.meterValue(levels.max() ?? 0))
    }
}

private struct StripButton: View {
    let letter: String
    let isOn: Bool
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 20)
                .foregroundStyle(isOn ? Color.black : .primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? color : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(letter == "M" ? "Mute" : "Solo")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// How loud a source is in the monitor: its own level, before the source's fader.
private struct MonitorSendControl: View {
    @Environment(AppModel.self) private var model
    let node: UUID
    let title: String

    var body: some View {
        let saved = model.monitor?.send(node) ?? MonitorSend(node: node)
        let send = moving(saved)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    var changed = send
                    changed.isOn.toggle()
                    model.updateMonitor(changed.isOn ? "Monitor \(title)" : "Leave \(title) Out of Monitor") { $0.setSend(changed) }
                    model.endEditing()
                } label: {
                    Image(systemName: send.isOn ? "headphones" : "headphones.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(send.isOn ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(send.isOn ? "In the monitor: click to leave it out" : "Not in the monitor: click to add it")
                .accessibilityLabel("\(title) in monitor")
                .accessibilityValue(send.isOn ? "On" : "Off")
                Text(Gain.text(send.gainDB))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { send.gainDB }, set: { value in
                var changed = saved
                changed.gainDB = (value * 2).rounded() / 2
                model.moveMonitorSend(changed)
            }), in: Gain.floorDB...Gain.ceilingDB, onEditingChanged: { if !$0 { model.endEditing() } })
                .controlSize(.mini)
                .disabled(!send.isOn)
                .accessibilityLabel("\(title) monitor level")
                .help("\(title)'s level in the monitor, before its fader and mute")
        }
        .frame(height: 34)
    }

    /// The send as it shows: with its level while its fader moves.
    private func moving(_ saved: MonitorSend) -> MonitorSend {
        guard let canvas = model.canvas, let dB = model.fader(AppModel.sendKey(canvas: canvas, node: node)).value else { return saved }
        var send = saved
        send.gainDB = dB
        return send
    }
}

/// The headphone monitor: where it plays, its level, mute and meters, and what solo/listen is sending it.
private struct MonitorStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.monitor
        let id = monitor?.id
        let tint = Color.accentColor
        let issues = id.map { model.plan.issues[$0] ?? [] } ?? []
        let status = id.flatMap { model.statuses[$0] }
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                Image(systemName: "headphones")
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(tint)
                Text("Monitor")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 28, alignment: .top)
            }
            .overlay(alignment: .topTrailing) {
                if status?.state == .failed || !issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help(([status?.message].compactMap { $0 } + issues).joined(separator: "\n"))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    Button("None") { model.setMonitorOutput(nil) }
                    Divider()
                    ForEach(model.monitorOutputs, id: \.self) { output in
                        Button(model.monitorOutputTitle(output)) { model.setMonitorOutput(output) }
                    }
                } label: {
                    Text(model.monitorOutputTitle(monitor?.output))
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .help("Where the monitor plays: headphones or speakers, never one of Junction's devices")
                .accessibilityLabel("Monitor output")
                if let issue = issues.first {
                    Text(issue)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .help(issue)
                } else {
                    Text(listeningText(monitor))
                        .font(.system(size: 10))
                        .foregroundStyle(monitor?.listening.isEmpty ?? true ? Color.secondary : .yellow)
                        .lineLimit(2)
                }
                if !(monitor?.listening.isEmpty ?? true) {
                    Button("Stop Listening") { model.clearListening() }
                        .controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: StripMetrics.effectsHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))

            Text(" ").font(.system(size: 10)).frame(height: 32)

            HStack(alignment: .bottom, spacing: 6) {
                VerticalFader(dB: monitor?.gainDB ?? 0, fader: model.canvas.map { AppModel.monitorKey(canvas: $0) } ?? "",
                              tint: tint, label: "Monitor level") { value in
                    model.moveMonitorLevel(to: value)
                }
                StripMeters(levels: (0..<2).map { channel in
                    id.map { model.meters[PortKey(node: $0, isOutput: false, channel: channel)] ?? 0 } ?? 0
                }, tint: tint, label: "Monitor meter")
            }
            .frame(maxHeight: .infinity)

            Text(Gain.text(monitor?.gainDB ?? 0))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                StripButton(letter: "M", isOn: monitor?.isMuted ?? false, color: .red,
                            help: monitor?.isMuted ?? false ? "Unmute the monitor" : "Mute the monitor") {
                    model.updateMonitor(monitor?.isMuted ?? false ? "Unmute Monitor" : "Mute Monitor") { $0.isMuted.toggle() }
                    model.endEditing()
                }
            }
            Text(" ").font(.caption2).frame(height: 34)
        }
        .padding(8)
        .frame(width: StripMetrics.width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.07)))
        .disabled(model.canvas == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monitor strip")
    }

    private func listeningText(_ monitor: MonitorMix?) -> String {
        guard let monitor, monitor.output != nil else { return "Off" }
        guard !monitor.listening.isEmpty else { return "The device's sources" }
        let names = Set(monitor.listening.compactMap { model.node($0.node) }.map { model.info.title($0) })
        return "Listening: " + names.sorted().joined(separator: ", ")
    }
}
