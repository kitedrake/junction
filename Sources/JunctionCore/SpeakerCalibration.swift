import Foundation
import Observation

// The Calibrate Speakers sheet, without the window: setup (microphone, its input channel and calibration file, the
// channels to measure), measuring (the level check, then a sweep per channel at each listening position) and results
// (the measurements against the target, the correction and what it should sound like, refitted at once whenever a
// control changes, from the saved curves). Saving puts the profile into the output's Calibration effect as one undo
// step; Adjust… opens the results of a saved profile without measuring. The engine's steps block, so they run on
// another thread while the sheet waits.

/// Where the sheet measures and saves: the app (or a test).
@MainActor
public protocol SpeakerCalibrationHost: AnyObject {
    /// A measurement engine for these devices, holding the routing that uses them while it runs.
    func makeMeasurement(_ configuration: MeasurementEngine.Configuration) -> MeasurementEngine
    /// Asks for the Microphone permission measuring needs; whether it is allowed.
    func requestMicrophone() async -> Bool
    /// Plays `profile` in the output's Calibration effect without editing the setup (nil: what is saved again).
    func audition(_ profile: CalibrationProfile?, node: UUID, effect: UUID)
    /// Saves `profile` into the output's Calibration effect as one undo step.
    func save(_ profile: CalibrationProfile, node: UUID, effect: UUID)
}

/// The results page's controls: what the correction aims for and how far it may go.
public struct SpeakerCalibrationSettings: Equatable, Sendable {
    /// dB per octave about 1 kHz (negative: warmer).
    public var tilt: Double = 0
    /// dB; 0 is no shelf.
    public var bassShelf: Double = 0
    public var bassShelfFrequency: Double = 105
    public var trebleShelf: Double = 0
    public var trebleShelfFrequency: Double = 8_000
    /// Hz; nil: from the speaker's −6 dB point.
    public var lowFrequency: Double?
    public var highFrequency: Double = 20_000
    public var maxBoost: Double = 6
    public var filterCount: Int = 16
    /// Each channel's delay and level line the speakers up at the listening position.
    public var alignsSpeakers = true

    public static let tiltRange: ClosedRange<Double> = -1.5...1.5
    public static let shelfRange: ClosedRange<Double> = -9...9
    public static let boostRange: ClosedRange<Double> = 0...12
    public static let filterRange: ClosedRange<Int> = 1...CalibrationLimits.maximumFilters

    public init() {}

    /// A saved profile's settings.
    public init(_ profile: CalibrationProfile) {
        tilt = profile.target.tilt
        if let shelf = profile.target.lowShelf {
            bassShelf = shelf.gain
            bassShelfFrequency = shelf.frequency
        }
        if let shelf = profile.target.highShelf {
            trebleShelf = shelf.gain
            trebleShelfFrequency = shelf.frequency
        }
        lowFrequency = profile.limits.lowFrequency
        highFrequency = profile.limits.highFrequency
        maxBoost = profile.limits.maxBoost
        filterCount = profile.limits.filterCount
        alignsSpeakers = profile.alignment?.isOn ?? profile.channels.contains { $0.delay != 0 || $0.level != 0 }
    }

    public var target: CalibrationTarget {
        CalibrationTarget(tilt: tilt,
                          lowShelf: bassShelf == 0 ? nil : .init(frequency: bassShelfFrequency, gain: bassShelf),
                          highShelf: trebleShelf == 0 ? nil : .init(frequency: trebleShelfFrequency, gain: trebleShelf))
    }

    public var limits: CalibrationLimits {
        CalibrationLimits(lowFrequency: lowFrequency, highFrequency: highFrequency, maxBoost: maxBoost,
                          filterCount: filterCount)
    }
}

@MainActor @Observable
public final class SpeakerCalibration: Identifiable {
    public enum Page: Int, CaseIterable, Sendable {
        case setup, measuring, results
    }

    /// An input that can measure: a device with input channels.
    public struct Microphone: Hashable, Identifiable, Sendable {
        public var uid: String
        public var name: String
        public var channels: Int
        public var id: String { uid }

        public init(uid: String, name: String, channels: Int) {
            self.uid = uid
            self.name = name
            self.channels = channels
        }
    }

    /// What the measuring page is doing.
    public enum Activity: Equatable, Sendable {
        case idle
        case checkingLevel
        /// Sweeping every channel at a position (0-based).
        case measuring(position: Int)
    }

    public static let positionRange = 1...9
    public static let defaultPositions = 7

    public let id = UUID()
    public let node: UUID
    public let effect: UUID
    public let outputUID: String
    public let outputName: String
    /// The output's channels by name (as the node shows them).
    public let channelNames: [String]
    public let microphones: [Microphone]
    /// Opened with Adjust…: results of a saved profile; there is nothing to measure.
    public let isAdjusting: Bool
    @ObservationIgnored private weak var host: SpeakerCalibrationHost?

    public private(set) var page: Page

    // MARK: Setup

    public var micUID: String? {
        didSet { micChannel = min(micChannel, max(0, (microphone?.channels ?? 1) - 1)) }
    }
    /// The microphone's input channel (0-based).
    public var micChannel = 0
    public private(set) var micCalibration: MicCalibration?
    /// How many of the output's first channels are measured (1 to as many as it has).
    public var channelCount: Int {
        get { measuredChannelCount }
        set { measuredChannelCount = min(max(1, newValue), max(1, channelNames.count)) }
    }
    /// Listening positions to measure (1…9): the first at ear height where you listen, the rest within about 30 cm.
    public var positionCount: Int {
        get { listeningPositions }
        set { listeningPositions = min(max(Self.positionRange.lowerBound, newValue), Self.positionRange.upperBound) }
    }
    private var measuredChannelCount = 2
    private var listeningPositions = SpeakerCalibration.defaultPositions

    public var microphone: Microphone? { microphones.first { $0.uid == micUID } }
    public var canStart: Bool { microphone != nil && !channelNames.isEmpty }

    // MARK: Measuring

    public private(set) var activity = Activity.idle
    /// The last level check's reading.
    public private(set) var reading: MeasurementEngine.LevelReading?
    /// The level check passed: positions can be measured.
    public private(set) var isLevelChecked = false
    /// What went wrong last, as the user is told (nil: nothing).
    public private(set) var problem: String?
    /// Measured positions in order, each with one capture per channel.
    public private(set) var positions: [[CalibrationCapture]] = []
    @ObservationIgnored private var engine: MeasurementEngine?
    @ObservationIgnored private var sampleRate = 48_000.0
    @ObservationIgnored private var measuredAt = Date()

    public var isBusy: Bool { activity != .idle }
    public var progress: Double { Double(min(positions.count, positionCount)) / Double(positionCount) }
    public var isDoneMeasuring: Bool { positions.count >= positionCount }
    public var canMeasure: Bool { isLevelChecked && !isBusy && !isDoneMeasuring }
    public var canShowResults: Bool { !positions.isEmpty && !isBusy }

    // MARK: Results

    /// The measurements the results are fitted from (as saved with the profile).
    public private(set) var measured: CalibrationProfile?
    public var settings = SpeakerCalibrationSettings() {
        didSet { if settings != oldValue { refit() } }
    }
    /// The correction fitted from `measured` with `settings`: what Save writes.
    public private(set) var result: CalibrationProfile?
    /// Before/after: true plays the output without the correction, at matched loudness.
    public var isComparing = false {
        didSet { if isComparing != oldValue { audition() } }
    }
    /// The channel the graph shows.
    public var shownChannel = 0

    /// A new measurement of an output, its Calibration effect being `effect` on `node`.
    public init(node: UUID, effect: UUID, outputUID: String, outputName: String, channelNames: [String],
                microphones: [Microphone], defaultMicUID: String? = nil, host: SpeakerCalibrationHost) {
        self.node = node
        self.effect = effect
        self.outputUID = outputUID
        self.outputName = outputName
        self.channelNames = channelNames
        self.microphones = microphones
        self.host = host
        isAdjusting = false
        page = .setup
        measuredChannelCount = max(1, min(2, channelNames.count))
        micUID = microphones.first { $0.uid == defaultMicUID }?.uid ?? microphones.first?.uid
    }

    /// Adjust…: the results of a saved profile, refitted from its measurements without measuring.
    public init(adjusting profile: CalibrationProfile, node: UUID, effect: UUID, channelNames: [String],
                host: SpeakerCalibrationHost) {
        self.node = node
        self.effect = effect
        outputUID = profile.deviceUID ?? ""
        outputName = profile.deviceName ?? profile.name
        self.channelNames = channelNames
        microphones = []
        self.host = host
        isAdjusting = true
        page = .results
        measuredChannelCount = max(1, profile.measuredChannels.count)
        measured = profile
        settings = SpeakerCalibrationSettings(profile)
        refit()
    }

    /// A channel's name ("Left", "3").
    public func channelName(_ channel: Int) -> String {
        channel < channelNames.count ? channelNames[channel] : "\(channel + 1)"
    }

    // MARK: Setup

    public func loadMicCalibration(_ url: URL) {
        do {
            micCalibration = try MicCalibration(contentsOf: url)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    public func setMicCalibration(_ calibration: MicCalibration?) {
        micCalibration = calibration
    }

    /// Continue: asks for the Microphone permission, starts the devices and checks the level.
    public func startMeasuring() async {
        guard canStart, page == .setup else { return }
        problem = nil
        guard await host?.requestMicrophone() == true else {
            problem = MeasurementError.microphoneDenied.localizedDescription
            return
        }
        page = .measuring
        await checkLevel()
    }

    // MARK: Measuring

    /// Plays pink noise on the first channel and checks what the microphone hears; starts the devices first when they
    /// aren't running (at the start, or after an error ended the last run).
    public func checkLevel() async {
        guard page == .measuring, !isBusy else { return }
        activity = .checkingLevel
        problem = nil
        isLevelChecked = false
        defer { activity = .idle }
        do {
            let engine = try await runningEngine()
            let level = try await Self.background { try engine.checkLevel() }
            reading = level
            isLevelChecked = true
        } catch {
            reading = engine?.reading ?? reading
            fail(error)
        }
    }

    /// Sweeps every channel at the microphone's position now, adding the position.
    public func measureNextPosition() async {
        guard page == .measuring, canMeasure, let engine else { return }
        activity = .measuring(position: positions.count)
        problem = nil
        defer { activity = .idle }
        do {
            let captures = try await Self.background { try engine.measurePosition() }
            positions.append(captures)
        } catch {
            if case MeasurementError.inputClipping = error { isLevelChecked = false }
            fail(error)
        }
    }

    /// Redo Last: measures the last position again (the microphone hasn't moved).
    public func redoLastPosition() async {
        guard !positions.isEmpty, !isBusy else { return }
        positions.removeLast()
        await measureNextPosition()
    }

    /// Leaves a position out (0-based); the later ones move up.
    public func dropPosition(_ index: Int) {
        guard positions.indices.contains(index), !isBusy else { return }
        positions.remove(at: index)
    }

    /// Finishes measuring (the devices and routing are freed) and fits the results.
    public func showResults() {
        guard canShowResults, page == .measuring else { return }
        finishEngine()
        let byChannel = (0..<channelCount).map { channel in positions.map { $0[channel] } }
        measured = CalibrationProfile.speakers(name: outputName, deviceUID: outputUID, deviceName: outputName,
                                               captures: byChannel, target: settings.target, limits: settings.limits,
                                               alignsSpeakers: settings.alignsSpeakers, micCalibration: micCalibration?.name,
                                               sampleRate: sampleRate, date: measuredAt)
        result = measured
        shownChannel = min(shownChannel, channelCount - 1)
        page = .results
        audition()
    }

    /// Back to setup from measuring: the devices are freed and the positions measured so far forgotten.
    public func back() {
        guard page == .measuring, !isBusy else { return }
        finishEngine()
        positions = []
        reading = nil
        isLevelChecked = false
        problem = nil
        page = .setup
    }

    // MARK: Results

    /// Fits the correction again from the saved measurements with the controls as they are.
    private func refit() {
        guard let measured else { return }
        result = measured.refitted(target: settings.target, limits: settings.limits,
                                   alignsSpeakers: settings.alignsSpeakers, sampleRate: sampleRate)
        audition()
    }

    /// Save: the profile goes into the output's Calibration effect (one undo step) and the sheet is done.
    public func save() {
        guard let result else { return }
        host?.save(result, node: node, effect: effect)
        isComparing = false
        host?.audition(nil, node: node, effect: effect)
    }

    /// Cancel or close: stops any measurement and plays what is saved again.
    public func cancel() {
        engine?.cancel()
        engine = nil
        host?.audition(nil, node: node, effect: effect)
    }

    /// What the output plays while the results show: the fitted correction, or, while comparing, none at its level.
    public var auditioned: CalibrationProfile? {
        guard page == .results, let result else { return nil }
        return isComparing ? result.comparison() : result
    }

    /// The level "before" is made up by while comparing (dB): the correction's average level change.
    public var comparisonLevel: Double { result?.averageLevelChange() ?? 0 }

    private func audition() {
        guard page == .results else { return }
        host?.audition(auditioned, node: node, effect: effect)
    }

    /// The shown channel's curves for the graph, all in dB relative to the target's level in the midrange: the
    /// average, each position, the target, the correction (its filters) and the predicted result.
    public func curves(channel: Int) -> CalibrationResultCurves? {
        guard let measured, let result, let average = measured.averageMeasurement(channel: channel) else { return nil }
        let frequencies = CalibrationGrid.frequencies
        let target = frequencies.map(result.target.level(at:))
        let offset = CalibrationFitter.offsetToTarget(average.smoothed(.twelfth), target)
        let positions = measured.measurements.filter { $0.channel == channel && $0.position != nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            .map { $0.curve.smoothed(.sixth).levels.map { $0 - offset } }
        let correction = CalibrationFilter.response(of: result.channel(channel).filters, sampleRate: sampleRate, at: frequencies)
        let shown = average.smoothed(.twelfth).levels.map { $0 - offset }
        return CalibrationResultCurves(average: shown, positions: positions, target: target, correction: correction,
                                       predicted: zip(shown, correction).map(+))
    }

    // MARK: Snapshots and tests

    /// Shows made-up measurements, as if they had just been measured (snapshot mode).
    public func showPreview(positions: [[CalibrationCapture]], reading: MeasurementEngine.LevelReading?,
                            page: Page, sampleRate: Double = 48_000, date: Date = Date()) {
        self.positions = positions
        self.reading = reading
        self.sampleRate = sampleRate
        measuredAt = date
        isLevelChecked = reading != nil
        self.page = .measuring
        if page == .results { showResults() } else { self.page = page }
    }

    // MARK: Plumbing

    private func runningEngine() async throws -> MeasurementEngine {
        if let engine, !engine.isFinished { return engine }
        guard let host, let microphone else { throw MeasurementError.unusable("Choose a microphone.") }
        let configuration = MeasurementEngine.Configuration(
            outputUID: outputUID, outputName: outputName, micUID: microphone.uid, micName: microphone.name,
            micChannel: micChannel, channels: channelCount, micCalibration: micCalibration)
        let engine = host.makeMeasurement(configuration)
        self.engine = engine
        if positions.isEmpty { measuredAt = Date() }
        try await Self.background { try engine.start() }
        sampleRate = engine.format?.sampleRate ?? sampleRate
        return engine
    }

    private func fail(_ error: Error) {
        problem = error.localizedDescription
        // An error that ended the run (a device gone): the next level check starts the devices again.
        if engine?.isFinished == true {
            engine = nil
            isLevelChecked = false
        }
    }

    private func finishEngine() {
        engine?.finish()
        engine = nil
    }

    /// Runs a blocking step on another thread.
    private nonisolated static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// One channel's curves on `CalibrationGrid` for the results graph (dB).
public struct CalibrationResultCurves: Equatable, Sendable {
    /// The positions' power average (1/12 octave), at the target's level.
    public var average: [Double]
    /// Each position (1/6 octave), first the listening position.
    public var positions: [[Double]]
    public var target: [Double]
    /// The correction's filters (without the preamp and channel level).
    public var correction: [Double]
    /// The average with the correction: what it should sound like.
    public var predicted: [Double]
}
