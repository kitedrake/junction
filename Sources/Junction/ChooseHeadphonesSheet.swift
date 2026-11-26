import AppKit
import JunctionCore
import SwiftUI

/// Choose Headphones: the headphone library searched by brand and model, the chosen headphones' presets with their
/// authors, compared as curves, and Use (see `HeadphonePicker`). Sized to fit the window at its minimum size.
struct ChooseHeadphonesSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var picker: HeadphonePicker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 16) {
                HeadphoneResults(picker: picker)
                    .frame(width: 250)
                Divider()
                PresetDetails(picker: picker)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(alignment: .center, spacing: 12) {
                LibraryProjectCredit()
                Spacer(minLength: 8)
                LibraryStatus(store: picker.store, compact: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 720, height: 490)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Choose Headphones").font(.title2.weight(.semibold))
            Text(picker.deviceName.map { "Ready-made EQ presets for your headphones, loaded into Calibration on \($0)" }
                 ?? "Ready-made EQ presets for your headphones, loaded into Calibration")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let problem = picker.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { model.headphonePicker = nil }
                .keyboardShortcut(.cancelAction)
            Button("Use") { picker.use() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!picker.canUse)
                .help("Loads this preset into the output's Calibration effect (Undo takes it back)")
        }
    }
}

/// The search field, the type filter and the matching headphones.
private struct HeadphoneResults: View {
    @Bindable var picker: HeadphonePicker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search brand or model", text: $picker.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search headphones")
            Picker("Type", selection: $picker.style) {
                Text("All types").tag(HeadphoneStyle?.none)
                ForEach(picker.styles, id: \.self) { style in Text(style.name).tag(Optional(style)) }
            }
            .fixedSize()
            let results = picker.results
            ScrollViewReader { scroller in
                List(selection: $picker.chosenID) {
                    ForEach(results) { headphones in
                        HeadphoneRow(headphones: headphones).tag(headphones.id)
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .accessibilityLabel("Headphones")
                .overlay {
                    if picker.store.library == nil {
                        ProgressView().controlSize(.small)
                    } else if results.isEmpty {
                        Text("No headphones match.").foregroundStyle(.secondary)
                    }
                }
                .onAppear { if let chosen = picker.chosenID { scroller.scrollTo(chosen, anchor: .center) } }
                .onChange(of: picker.store.library?.summary) {
                    if let chosen = picker.chosenID { scroller.scrollTo(chosen, anchor: .center) }
                }
            }
            Text(count(results.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func count(_ number: Int) -> String {
        number == 1 ? "1 model" : "\(number.formatted()) models"
    }
}

/// "Brand" over "Model", then "Over-ear · 3 presets".
private struct HeadphoneRow: View {
    let headphones: HeadphoneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headphones.brand).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(headphones.model).lineLimit(1)
            Text("\(headphones.style.name) · \(presets)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(headphones.brand) \(headphones.model)")
        .accessibilityValue("\(headphones.style.name), \(presets)")
    }

    private var presets: String {
        headphones.presets.count == 1 ? "1 preset" : "\(headphones.presets.count) presets"
    }
}

/// The colours of compared presets, by their place in the headphones' list.
private let presetColors: [Color] = [.accentColor, .orange, .green, .pink, .purple, .brown, .teal, .indigo]

/// The chosen headphones' presets (pick one to use, tick others to compare) and their curves.
private struct PresetDetails: View {
    @Bindable var picker: HeadphonePicker

    var body: some View {
        if let headphones = picker.chosen {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headphones.name).font(.headline).lineLimit(1)
                    Text("\(headphones.style.name) · pick a preset to use, tick others to compare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                List(selection: $picker.selectedPresetID) {
                    ForEach(Array(headphones.presets.enumerated()), id: \.element.id) { index, preset in
                        PresetRow(picker: picker, preset: preset, index: index).tag(preset.id)
                    }
                }
                .listStyle(.bordered)
                .accessibilityLabel("Presets for \(headphones.name)")
                .frame(minHeight: 90, maxHeight: .infinity)
                FrequencyResponseGraph(curves: curves(headphones), height: 140,
                                       accessibilityTitle: "Preset corrections for \(headphones.name)")
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Choose your headphones to see their presets.").foregroundStyle(.secondary)
                Text("Each preset is made by someone who measured those headphones; most aim at a researched target curve rather than flat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The compared presets at full amount: the one to use solid, the others dashed.
    private func curves(_ headphones: HeadphoneModel) -> [ResponseCurve] {
        picker.comparedPresets.compactMap { preset in
            guard let index = headphones.presets.firstIndex(of: preset), let levels = picker.curve(preset) else { return nil }
            return ResponseCurve(name: "\(index + 1). \(preset.author)", color: presetColors[index % presetColors.count],
                                 frequencies: CalibrationGrid.frequencies, levels: levels,
                                 isDashed: preset.id != picker.selectedPresetID)
        }
    }
}

/// A preset: its author first, then its details and link; a tick to show it on the graph.
private struct PresetRow: View {
    let picker: HeadphonePicker
    let preset: HeadphonePreset
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { picker.compared.contains(preset.id) },
                                 set: { picker.setCompared(preset.id, $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!preset.isAvailable || preset.id == picker.selectedPresetID)
            .help("Show on the graph")
            .accessibilityLabel("Compare preset by \(preset.author)")
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(preset.isAvailable ? presetColors[index % presetColors.count] : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(preset.author.isEmpty ? "Unknown author" : preset.author)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if preset.id == picker.presetInUse {
                        Text("In use")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                if !preset.details.isEmpty {
                    Text(preset.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let problem = preset.problem {
                    Text("Can't be loaded: \(problem).").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let link = preset.link.flatMap(URL.init(string:)), link.scheme?.hasPrefix("http") == true {
                Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                    .help("The author's page for this preset: \(link.absoluteString)")
                    .accessibilityLabel("Open \(preset.author)'s page for this preset")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = ["Preset \(index + 1) by \(preset.author.isEmpty ? "an unknown author" : preset.author)"]
        if !preset.details.isEmpty { parts.append(preset.details) }
        if preset.id == picker.presetInUse { parts.append("in use") }
        if let problem = preset.problem { parts.append("can't be loaded: \(problem)") }
        return parts.joined(separator: ", ")
    }
}

/// The database's credit: its logo, what it is and a link to it (quieter than the presets' authors).
struct LibraryProjectCredit: View {
    var body: some View {
        HStack(spacing: 8) {
            if let url = HeadphoneLibrary.logoURL, let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 16)
                    .accessibilityLabel(HeadphoneLibrary.projectName)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Presets from \(HeadphoneLibrary.projectName). \(HeadphoneLibrary.projectDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Link("github.com/opra-project/OPRA", destination: HeadphoneLibrary.projectURL)
                    .font(.caption2)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Which copy of the library is in use, its date and counts, and Update Library with its progress, Cancel and errors.
struct LibraryStatus: View {
    let store: HeadphoneLibraryStore
    /// One line for the sheet; Settings gives it more room.
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 8) {
                if compact {
                    Text(store.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.status)
                }
                if store.isUpdating {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Updating the headphone library")
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelUpdate() }
                        .controlSize(.small)
                } else {
                    Button("Update Library") { store.update() }
                        .controlSize(.small)
                        .disabled(store.isLoading)
                        .help("Downloads the latest copy of the database and uses it once it has been checked; the current one is kept if anything goes wrong")
                }
            }
            switch store.updateState {
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(compact ? 1 : 3)
                    .help(reason)
            case .updated:
                Label("Updated.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle, .updating:
                EmptyView()
            }
        }
    }
}

/// Settings › Acknowledgements: the licences of the headphone library's data and code, as bundled.
struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let licences = HeadphoneLibraryLicence.bundled()
    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements").font(.title2.weight(.semibold))
            Text("The headphone library comes from \(HeadphoneLibrary.projectName) and includes presets from AutoEQ. Their licences:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if licences.isEmpty {
                Text("The licence texts are missing from this copy of Junction.").foregroundStyle(.orange)
            } else {
                Picker("Licence", selection: Binding(get: { shown ?? licences[0].id }, set: { shown = $0 })) {
                    ForEach(licences) { licence in Text(licence.title).tag(licence.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                let licence = licences.first { $0.id == shown } ?? licences[0]
                Text(licence.summary).font(.callout)
                ScrollView {
                    Text(licence.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(licence.title) licence text")
            }
            HStack {
                Link("\(HeadphoneLibrary.projectName) on GitHub", destination: HeadphoneLibrary.projectURL)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
