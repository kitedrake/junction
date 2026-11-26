import JunctionCore
import SwiftUI

/// Calibrate Speakers: setup, measuring at the listening positions, and the results with their controls (see
/// `SpeakerCalibration`). Sized to fit the window at its minimum size.
struct CalibrateSpeakersSheet: View {
    @Environment(AppModel.self) private var model
    let calibration: SpeakerCalibration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Group {
                switch calibration.page {
                case .setup: SetupPage(calibration: calibration)
                case .measuring: MeasuringPage(calibration: calibration)
                case .results: ResultsPage(calibration: calibration)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let problem = calibration.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 720, height: 490)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(calibration.isAdjusting ? "Adjust Calibration" : "Calibrate Speakers").font(.title2.weight(.semibold))
                Text(calibration.outputName).foregroundStyle(.secondary)
            }
            Spacer()
            if !calibration.isAdjusting {
                HStack(spacing: 6) {
                    ForEach(SpeakerCalibration.Page.allCases, id: \.self) { page in
                        Text(title(page))
                            .font(.caption.weight(page == calibration.page ? .semibold : .regular))
                            .foregroundStyle(page == calibration.page ? .primary : .secondary)
                        if page != .results { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func title(_ page: SpeakerCalibration.Page) -> String {
        switch page {
        case .setup: "1 Setup"
        case .measuring: "2 Measure"
        case .results: "3 Results"
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { model.closeSpeakerCalibration() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch calibration.page {
            case .setup:
                Button("Continue") { Task { await calibration.startMeasuring() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!calibration.canStart)
            case .measuring:
                Button("Back") { calibration.back() }
                    .disabled(calibration.isBusy)
                Button("See Results") { calibration.showResults() }
                    .keyboardShortcut(calibration.isDoneMeasuring ? .defaultAction : nil)
                    .buttonStyle(.glassProminent)
                    .disabled(!calibration.canShowResults)
            case .results:
                Button("Save") { calibration.save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(calibration.result == nil)
                    .help("Puts this correction into the output's Calibration effect (Undo takes it back)")
            }
        }
    }
}

// MARK: Setup

private struct SetupPage: View {
    @Environment(AppModel.self) private var model
    @Bindable var calibration: SpeakerCalibration

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $calibration.micUID) {
                    if calibration.microphones.isEmpty { Text("No microphone connected").tag(String?.none) }
                    ForEach(calibration.microphones) { mic in Text(mic.name).tag(Optional(mic.uid)) }
                }
                if let mic = calibration.microphone, mic.channels > 1 {
                    Picker("Input channel", selection: $calibration.micChannel) {
                        ForEach(0..<mic.channels, id: \.self) { channel in Text("Input \(channel + 1)").tag(channel) }
                    }
                }
                LabeledContent("Calibration file") {
                    HStack {
                        if let file = calibration.micCalibration {
                            Text(file.name).lineLimit(1)
                            Button("Remove") { calibration.setMicCalibration(nil) }
                        }
                        Button(calibration.micCalibration == nil ? "Load…" : "Change…") {
                            model.chooseMicCalibration(for: calibration)
                        }
                    }
                }
                if calibration.micCalibration == nil {
                    Text("Without the microphone's calibration file, its own response is measured too. A measurement microphone is close enough in the midrange; the lowest bass and the treble are less accurate, and any other microphone much less.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Picker("Speakers to measure", selection: $calibration.channelCount) {
                    ForEach(1...max(1, calibration.channelNames.count), id: \.self) { count in
                        Text(channels(count)).tag(count)
                    }
                }
                Stepper(value: $calibration.positionCount, in: SpeakerCalibration.positionRange) {
                    LabeledContent("Listening positions", value: "\(calibration.positionCount)")
                }
            }
            Section {
                Label("Pause music, videos and calls before you continue: anything else playing ends up in the measurement. Junction stops its own routing to these speakers and from the microphone while it measures, and starts it again afterwards.",
                      systemImage: "speaker.slash")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// "Left and Right", "Left, Right and 3".
    private func channels(_ count: Int) -> String {
        let names = (0..<count).map(calibration.channelName)
        guard names.count > 1 else { return names.first ?? "1" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

// MARK: Measuring

private struct MeasuringPage: View {
    let calibration: SpeakerCalibration

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                level
                Divider()
                Text(instruction).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: calibration.progress) {
                    Text("\(calibration.positions.count) of \(calibration.positionCount) positions measured")
                        .font(.callout)
                }
                HStack {
                    Button(calibration.isDoneMeasuring ? "All Measured" : "Measure Position \(calibration.positions.count + 1)") {
                        Task { await calibration.measureNextPosition() }
                    }
                    .disabled(!calibration.canMeasure)
                    Button("Redo Last") { Task { await calibration.redoLastPosition() } }
                        .disabled(calibration.positions.isEmpty || !calibration.isLevelChecked || calibration.isBusy)
                        .help("Measures the last position again")
                    Menu("Drop") {
                        ForEach(calibration.positions.indices, id: \.self) { index in
                            Button("Position \(index + 1)") { calibration.dropPosition(index) }
                        }
                    }
                    .fixedSize()
                    .disabled(calibration.positions.isEmpty || calibration.isBusy)
                    .help("Leaves a position out, for example one where something made a noise")
                }
                if case .measuring = calibration.activity {
                    Label("Sweeping each speaker in turn. Keep quiet and still…", systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PositionDiagram(count: calibration.positionCount, measured: calibration.positions.count,
                            isMeasuring: calibration.activity != .idle && calibration.activity != .checkingLevel)
                .frame(width: 230, height: 230)
        }
    }

    @ViewBuilder private var level: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Level check").font(.headline)
                Spacer()
                if calibration.activity == .checkingLevel {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Again") { Task { await calibration.checkLevel() } }
                        .controlSize(.small)
                        .disabled(calibration.isBusy)
                }
            }
            if calibration.activity == .checkingLevel {
                Text("Playing a hiss on \(calibration.channelName(0))…").font(.callout).foregroundStyle(.secondary)
            } else if let reading = calibration.reading {
                Label(String(format: "The microphone hears %.0f dBFS, %.0f dB above the room's noise.", reading.micLevel, reading.snr),
                      systemImage: calibration.isLevelChecked ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(calibration.isLevelChecked ? Color.green : Color.orange)
            }
        }
    }

    private var instruction: String {
        switch calibration.positions.count {
        case 0: "Position 1: put the microphone where your head is when you listen, at ear height, pointing the way its calibration file says (usually straight up)."
        case calibration.positionCount...: "Every position is measured. See the results, or redo or drop a position first."
        default: "Position \(calibration.positions.count + 1): move the microphone to the next spot, within about 30 cm of the first and at about the same height."
        }
    }
}

/// The listening spot from above: position 1 in the middle, the others on a circle about 30 cm around it; measured
/// ones filled, the next one ringed.
private struct PositionDiagram: View {
    let count: Int
    let measured: Int
    let isMeasuring: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = size * 0.34
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                Text("about 30 cm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .position(x: center.x, y: center.y + radius + 14)
                Image(systemName: "hifispeaker.2")
                    .foregroundStyle(.secondary)
                    .position(x: center.x, y: 10)
                ForEach(0..<count, id: \.self) { index in
                    spot(index).position(point(index, center: center, radius: radius))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Listening positions")
        .accessibilityValue("\(measured) of \(count) measured")
    }

    private func point(_ index: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        guard index > 0 else { return center }
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index - 1) / Double(max(1, count - 1))
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    @ViewBuilder private func spot(_ index: Int) -> some View {
        let done = index < measured, next = index == measured
        ZStack {
            Circle()
                .fill(done ? Color.accentColor : Color.clear)
                .overlay(Circle().strokeBorder(next ? Color.accentColor : .secondary.opacity(0.6), lineWidth: next ? 2.5 : 1))
            Text("\(index + 1)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(done ? .white : .primary)
        }
        .frame(width: 26, height: 26)
        .opacity(next && isMeasuring ? 0.6 : 1)
    }
}

// MARK: Results

private struct ResultsPage: View {
    @Bindable var calibration: SpeakerCalibration
    @State private var showsPositions = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                if calibration.channelCount > 1 {
                    Picker("Speaker", selection: $calibration.shownChannel) {
                        ForEach(0..<calibration.channelCount, id: \.self) { channel in
                            Text(calibration.channelName(channel)).tag(channel)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                FrequencyResponseGraph(curves: curves, height: 230)
                Toggle("Show each position", isOn: $showsPositions).controlSize(.small)
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Picker("Compare", selection: $calibration.isComparing) {
                        Text("Before").tag(true)
                        Text("After").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Text(comparison).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            ResultControls(calibration: calibration)
                .frame(width: 250)
        }
    }

    private var curves: [ResponseCurve] {
        guard let curves = calibration.curves(channel: calibration.shownChannel) else { return [] }
        let frequencies = CalibrationGrid.frequencies
        var shown: [ResponseCurve] = []
        if showsPositions {
            for (index, levels) in curves.positions.enumerated() {
                shown.append(ResponseCurve(name: "Position \(index + 1)", color: .secondary, frequencies: frequencies,
                                           levels: levels, isFaint: true))
            }
        }
        shown += [ResponseCurve(name: "Measured", color: .secondary, frequencies: frequencies, levels: curves.average),
                  ResponseCurve(name: "Target", color: .green, frequencies: frequencies, levels: curves.target, isDashed: true),
                  ResponseCurve(name: "Correction", color: .accentColor, frequencies: frequencies, levels: curves.correction),
                  ResponseCurve(name: "Result", color: .purple, frequencies: frequencies, levels: curves.predicted)]
        return shown
    }

    /// "Preamp −5.2 dB · 14 filters · delay 1.0 ms · level −3.0 dB".
    private var summary: String {
        guard let result = calibration.result else { return "" }
        let channel = result.channel(calibration.shownChannel)
        var parts = [String(format: "Preamp %.1f dB", result.preamp), "\(channel.filters.count) filters"]
        if calibration.settings.alignsSpeakers, calibration.channelCount > 1 {
            parts.append(String(format: "delay %.1f ms", channel.delay * 1000))
            parts.append(String(format: "level %.1f dB", channel.level))
        }
        return parts.joined(separator: " · ")
    }

    private var comparison: String {
        String(format: "Before plays without the correction, %.1f dB quieter, so both sound equally loud.",
               -calibration.comparisonLevel)
    }
}

/// Target, correction range, most boost, filters and alignment; each change refits at once (a slider when let go).
private struct ResultControls: View {
    @Bindable var calibration: SpeakerCalibration

    private static let lowChoices: [Double?] = [nil, 30, 40, 50, 60, 80, 100, 150, 200]
    private static let highChoices: [Double] = [2_000, 5_000, 10_000, 15_000, 20_000]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Target").font(.headline)
                SettingSlider(name: "Tilt", value: $calibration.settings.tilt, range: SpeakerCalibrationSettings.tiltRange,
                              step: 0.1, format: "%+.1f dB/oct")
                SettingSlider(name: "Bass", value: $calibration.settings.bassShelf, range: SpeakerCalibrationSettings.shelfRange,
                              step: 0.5, format: "%+.1f dB")
                SettingSlider(name: "Treble", value: $calibration.settings.trebleShelf,
                              range: SpeakerCalibrationSettings.shelfRange, step: 0.5, format: "%+.1f dB")
                Text("Correction").font(.headline).padding(.top, 4)
                Picker("From", selection: $calibration.settings.lowFrequency) {
                    ForEach(Self.lowChoices, id: \.self) { hertz in
                        Text(hertz.map(Self.hertz) ?? "Speaker's limit").tag(hertz)
                    }
                }
                Picker("Up to", selection: $calibration.settings.highFrequency) {
                    ForEach(Self.highChoices, id: \.self) { hertz in Text(Self.hertz(hertz)).tag(hertz) }
                }
                SettingSlider(name: "Most boost", value: $calibration.settings.maxBoost,
                              range: SpeakerCalibrationSettings.boostRange, step: 0.5, format: "%.1f dB")
                Stepper(value: $calibration.settings.filterCount, in: SpeakerCalibrationSettings.filterRange) {
                    LabeledContent("Filters", value: "\(calibration.settings.filterCount)")
                }
                if calibration.channelCount > 1 {
                    Toggle("Line up speakers", isOn: $calibration.settings.alignsSpeakers)
                        .help("Delays the nearer speakers and lowers the louder ones, so all arrive together and equally loud")
                }
            }
            .controlSize(.small)
            .padding(.trailing, 6)
        }
    }

    private static func hertz(_ value: Double) -> String {
        value >= 1000 ? "\(Int(value / 1000)) kHz" : "\(Int(value)) Hz"
    }
}

/// A slider that shows its value as it moves and changes the setting when let go (a refit at every step of a drag
/// would lag). The inspector's headphone adjustments use it too.
struct SettingSlider: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    @State private var moving: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(name, value: String(format: format, moving ?? value))
            Slider(value: Binding(get: { moving ?? value }, set: { moving = $0 }), in: range, step: step) { editing in
                if !editing, let moving {
                    value = moving
                    self.moving = nil
                }
            }
            .labelsHidden()
            .accessibilityLabel(name)
        }
    }
}
