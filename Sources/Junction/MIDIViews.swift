import JunctionCore
import SwiftUI

/// The small keyboard button beside a level, a mute, a bypass or a device's switch: click it, then move a control on
/// a MIDI controller to map it. Tinted while mapped; its context menu forgets the mapping.
struct MIDILearnButton: View {
    @Environment(AppModel.self) private var model
    let target: MIDITarget

    var body: some View {
        let learning = model.midiLearning == target
        let mapping = model.midiMapping(for: target)
        Button { model.learnMIDI(target) } label: {
            Image(systemName: learning ? "pianokeys.inverse" : "pianokeys")
                .symbolEffect(.pulse, isActive: learning)
                .foregroundStyle(learning || mapping != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help(learning ? "Move a control on your MIDI controller, or click to stop listening"
              : mapping.map { "MIDI: \($0.trigger.title). Click to learn another control" }
              ?? "MIDI Learn: click, then move a control on your MIDI controller")
        .accessibilityLabel("MIDI Learn")
        .accessibilityValue(learning ? "Listening" : mapping?.trigger.title ?? "Not mapped")
        .contextMenu {
            if let mapping {
                Button("Forget MIDI Control (\(mapping.trigger.title))") { model.removeMIDIMapping(mapping.id) }
            }
        }
    }
}

/// Shown over the canvas while MIDI learn waits for a control.
struct MIDILearnBanner: View {
    @Environment(AppModel.self) private var model
    let target: MIDITarget

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Label("MIDI Learn: move a control for \(model.describe(target))", systemImage: "pianokeys")
                    .symbolEffect(.pulse)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .help(target.isLevel ? "Turn a knob, move a fader or an encoder." : "Press a button, a pad or a key, turn a knob, or send a program change.")
                Button("Cancel") { model.cancelMIDILearn() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
    }
}

/// Settings › MIDI: the controllers listened to, and every mapping, with how its values are read.
struct MIDISection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Text(model.midiSources.isEmpty ? "None connected" : model.midiSources.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } label: {
                Label("MIDI controllers", systemImage: "pianokeys")
            }
            if model.graph.midi.isEmpty {
                Text("No MIDI controls yet. Click the keyboard button beside a level, a mute, an effect, a device's switch or a scene's menu, then move a control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.graph.midi) { mapping in
                MIDIMappingRow(mapping: mapping)
            }
        } header: {
            Text("MIDI")
        } footer: {
            Text("Controls work wherever routing runs, also after Junction quits when routing keeps going. A knob or fader takes over a level once it reaches it, so the level doesn't jump. Deleting what a control drives removes its mapping.")
        }
    }
}

private struct MIDIMappingRow: View {
    @Environment(AppModel.self) private var model
    let mapping: MIDIMapping

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.describe(mapping.target)).lineLimit(2)
                Text([mapping.trigger.title, mapping.controller].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if mapping.trigger.isController {
                Picker("Reads", selection: Binding(get: { mapping.mode }, set: { model.setMIDIMode(mapping.id, $0) })) {
                    ForEach(MIDIControlMode.choices(for: mapping.target), id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("How this control's values are read")
            }
            Button { model.removeMIDIMapping(mapping.id) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this MIDI control")
            .accessibilityLabel("Remove MIDI control for \(model.describe(mapping.target))")
        }
    }
}
