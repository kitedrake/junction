import Foundation
import JunctionKernel

// Measuring speakers in the room: a noise-floor check, a level check with pink noise on one channel (it reports the
// microphone's level; the sweeps play at the level it checked), then one sweep per channel at each listening
// position, each turned into a response and arrival by the calibration maths. The engine sits behind a device protocol
// (Core Audio's in the app, a simulated room in tests); the kernel's measurement stage plays and records in the same
// IO cycles. While it measures, the router holds every sink that uses the output device or the microphone. Calls run
// one at a time on a thread that may wait (each blocks for the take's length); `cancel` works from any thread.

/// What goes wrong while measuring, as the user is told.
public enum MeasurementError: Error, LocalizedError, Equatable, Sendable {
    /// The microphone doesn't hear the test signal (`channel`: the output channel that played, 0-based; nil for the
    /// level check).
    case noSignal(channel: Int?)
    /// The microphone's input clipped; the test level was lowered to `level` dBFS.
    case inputClipping(level: Double)
    /// The test signal is less than `MeasurementEngine.minimumSNR` above the room's noise (dB).
    case lowSNR(Double)
    /// A device went away (or stopped running) in the middle of the measurement.
    case deviceDisappeared(String)
    /// IO kept losing buffers, so takes kept coming out of step.
    case dropouts
    case microphoneDenied
    /// A device couldn't be used: why.
    case unusable(String)
    /// Sweeps need a level check that passed first.
    case levelNotChecked
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noSignal(let channel?):
            "The microphone didn't hear speaker \(channel + 1). Check that it is connected, switched on and turned up, then measure this position again."
        case .noSignal(nil):
            "The microphone doesn't hear the test signal. Check that the speakers are switched on and turned up, that the right microphone and input channel are chosen, and that its gain is up."
        case .inputClipping(let level):
            "The microphone's input is clipping. Junction lowered the test level to \(Self.format(level)) dBFS; check the level again (or turn the microphone's gain down)."
        case .lowSNR(let snr):
            "The test signal is only \(Self.format(snr)) dB above the room's noise; a measurement needs at least \(Int(MeasurementEngine.minimumSNR)) dB. Make the room quieter, or turn the speakers or the microphone's gain up, and check the level again."
        case .deviceDisappeared(let name):
            "“\(name)” went away during the measurement. Reconnect it and start again."
        case .dropouts:
            "Audio kept dropping out during the sweep, so it couldn't be measured. Close other audio apps and try again."
        case .microphoneDenied:
            "macOS didn't allow Junction to use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .unusable(let reason): reason
        case .levelNotChecked: "Check the level before measuring."
        case .cancelled: "The measurement was cancelled."
        }
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// What the measuring IO runs at.
public struct MeasurementFormat: Equatable, Sendable {
    public var sampleRate: Double
    public var outputChannels: Int
    /// The microphone's channel among the IOProc's input channels (or the converter's, for a microphone at another
    /// rate).
    public var micChannel: Int
    public var bufferFrames: Int

    public init(sampleRate: Double, outputChannels: Int, micChannel: Int, bufferFrames: Int) {
        self.sampleRate = sampleRate
        self.outputChannels = outputChannels
        self.micChannel = micChannel
        self.bufferFrames = bufferFrames
    }
}

/// Plays on the output device and records the microphone in the same IO cycles.
public protocol MeasurementDevice: AnyObject {
    /// Finds the devices and builds what plays and records, without starting IO.
    func open() throws -> MeasurementFormat
    /// Starts IO running `jk_measure_ioproc` with `measure` (a `JKMeasure`) as its client data.
    func start(_ measure: OpaquePointer) throws
    /// Stops IO and frees what `open` built. Safe to call more than once, and after a device went away.
    func close()
    /// The name of a device that has gone away, if one has.
    func missingDevice() -> String?
}

/// Where routing runs (the router in the app, or Junction Helper): stops sinks while their devices are measured.
public protocol MeasurementRouting: AnyObject {
    /// Stops these sinks until `resume`; `done` runs once they have stopped (on any thread).
    func hold(_ sinks: Set<UUID>, done: @escaping @Sendable () -> Void)
    func resume(_ sinks: Set<UUID>)
}

extension Router: MeasurementRouting {
    public func hold(_ sinks: Set<UUID>, done: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.hold(sinks)
            done()
        }
    }
}

extension RoutingClient: MeasurementRouting {}

public final class MeasurementEngine: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var outputUID: String
        public var outputName: String
        public var micUID: String
        public var micName: String
        /// The microphone's input channel on its device (0-based).
        public var micChannel: Int
        /// Output channels measured: 0..<channels, the profile's channels.
        public var channels: Int
        /// The test signal's RMS level in dBFS (pink noise; the sweeps' RMS matches it).
        public var level: Double
        public var sweepDuration: Double
        public var leadSilence: Double
        public var tail: Double
        public var micCalibration: MicCalibration?

        public init(outputUID: String, outputName: String, micUID: String, micName: String, micChannel: Int,
                    channels: Int, level: Double = -18, sweepDuration: Double = 3, leadSilence: Double = 0.25,
                    tail: Double = 1.5, micCalibration: MicCalibration? = nil) {
            self.outputUID = outputUID
            self.outputName = outputName
            self.micUID = micUID
            self.micName = micName
            self.micChannel = micChannel
            self.channels = channels
            self.level = level
            self.sweepDuration = sweepDuration
            self.leadSilence = leadSilence
            self.tail = tail
            self.micCalibration = micCalibration
        }
    }

    /// What the level check heard (dBFS, RMS unless named peak).
    public struct LevelReading: Equatable, Sendable {
        /// The level played.
        public var level: Double
        public var micLevel: Double
        public var micPeak: Double
        public var noiseFloor: Double
        public var snr: Double { micLevel - noiseFloor }

        public init(level: Double, micLevel: Double, micPeak: Double, noiseFloor: Double) {
            self.level = level
            self.micLevel = micLevel
            self.micPeak = micPeak
            self.noiseFloor = noiseFloor
        }
    }

    /// dB the test signal must stand above the room's noise.
    public static let minimumSNR = 30.0
    /// A microphone sample at or above this (about −0.2 dBFS) counts as clipping.
    public static let clipping: Float = 0.98
    /// dB the level comes down after the input clipped.
    public static let clippingStep = 6.0
    /// dBFS the test level stays within.
    public static let levelRange: ClosedRange<Double> = -60 ... -6
    /// A take that lost IO buffers is played again, up to this many times in all.
    static let attempts = 3
    /// Seconds without an IO cycle that count as a device gone.
    static let stallTimeout = 2.0
    /// Seconds of IO before the first take, so the devices and the converter settle.
    static let settleTime = 0.3

    public let configuration: Configuration
    private let device: MeasurementDevice
    private let routing: MeasurementRouting?
    /// Every sink using the output device or the microphone: held while measuring.
    public let heldSinks: Set<UUID>

    private let lock = NSLock()
    // Under `lock`.
    private var measure: OpaquePointer?
    private var isCancelled = false
    private var isBusy = false
    private var isClosed = false
    private var isStarted = false
    private var isHolding = false
    // The measuring thread only.
    public private(set) var format: MeasurementFormat?
    /// The test level now, in dBFS: lowered after the input clipped.
    public private(set) var level: Double
    public private(set) var noiseFloor: Double?
    /// The last level check's reading (also when it failed).
    public private(set) var reading: LevelReading?
    private var levelChecked = false
    /// Analysed sweeps: `captures[channel][position]`.
    public private(set) var captures: [[CalibrationCapture]]
    public var positions: Int { captures.first?.count ?? 0 }

    /// `plan`: the routing now, to find the sinks to hold. Without `routing` nothing is held (nothing routes).
    public init(configuration: Configuration, plan: RoutingPlan, device: MeasurementDevice, routing: MeasurementRouting?) {
        self.configuration = configuration
        self.device = device
        self.routing = routing
        heldSinks = plan.sinks(using: [configuration.outputUID, configuration.micUID])
        level = min(Self.levelRange.upperBound, max(Self.levelRange.lowerBound, configuration.level))
        captures = Array(repeating: [], count: max(1, configuration.channels))
    }

    deinit { close() }

    // MARK: Steps

    /// Holds the affected sinks, opens the devices and starts IO.
    public func start() throws {
        try step {
            guard !lock.withLock({ isStarted }) else { return }
            lock.withLock { isStarted = true }
            if let routing, !heldSinks.isEmpty {
                lock.withLock { isHolding = true }
                let stopped = DispatchSemaphore(value: 0)
                routing.hold(heldSinks) { stopped.signal() }
                // Up to 5 s: a router that doesn't answer shouldn't keep the measurement from starting.
                let deadline = Date().addingTimeInterval(5)
                while stopped.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline { try checkCancelled() }
                try checkCancelled()
            }
            let format = try device.open()
            guard format.sampleRate > 0, format.outputChannels > 0 else {
                throw MeasurementError.unusable("“\(configuration.outputName)” has no output to measure.")
            }
            guard configuration.channels <= format.outputChannels else {
                throw MeasurementError.unusable("“\(configuration.outputName)” has only \(format.outputChannels) output channels.")
            }
            self.format = format
            // The longest take: a sweep, or the 1.5 s level check.
            let capacity = max(sweep(at: format.sampleRate, level: level).samples.count, Int(1.5 * format.sampleRate))
            guard let measure = jk_measure_create(UInt32(format.micChannel), UInt32(capacity)) else {
                throw MeasurementError.unusable("Out of memory.")
            }
            lock.withLock { self.measure = measure }
            try device.start(measure)
            try settle(measure)
        }
    }

    /// Records the room with nothing playing; returns its level in dBFS.
    @discardableResult
    public func checkNoiseFloor() throws -> Double {
        try step {
            let format = try ready()
            let recording = try take(Array(repeating: 0, count: Int(format.sampleRate)), channel: 0)
            let floor = Self.rms(recording.dropFirst(Int(0.25 * format.sampleRate)))
            noiseFloor = floor
            return floor
        }
    }

    /// Plays pink noise on `channel` (the first by default) at the test level and reports what the microphone hears.
    /// Checks the noise floor first if it hasn't been. Throws when the input clips (the level comes down: check
    /// again), when nothing is heard or when the signal doesn't stand far enough above the noise.
    @discardableResult
    public func checkLevel(channel: Int = 0) throws -> LevelReading {
        if noiseFloor == nil { try checkNoiseFloor() }
        return try step {
            let format = try ready()
            levelChecked = false
            let noise = Self.pinkNoise(count: Int(1.5 * format.sampleRate), level: level, sampleRate: format.sampleRate)
            let recording = try take(noise, channel: channel)
            let heard = recording.dropFirst(Int(0.5 * format.sampleRate))  // after the devices' latency
            let peak = recording.map(abs).max() ?? 0
            let reading = LevelReading(level: level, micLevel: Self.rms(heard), micPeak: Self.decibels(Double(peak)),
                                       noiseFloor: noiseFloor ?? -200)
            self.reading = reading
            if peak >= Self.clipping { throw lowerLevel() }
            if reading.snr < 6 { throw MeasurementError.noSignal(channel: nil) }
            if reading.snr < Self.minimumSNR { throw MeasurementError.lowSNR(reading.snr) }
            levelChecked = true
            return reading
        }
    }

    /// One sweep per channel at the microphone's position now; on success the position is added to `captures`.
    @discardableResult
    public func measurePosition() throws -> [CalibrationCapture] {
        try step {
            let format = try ready()
            guard levelChecked, let noiseFloor else { throw MeasurementError.levelNotChecked }
            let sweep = sweep(at: format.sampleRate, level: level)
            let signal = sweep.samples.map(Float.init)
            var position: [CalibrationCapture] = []
            for channel in 0..<configuration.channels {
                let recording = try take(signal, channel: channel)
                if (recording.map(abs).max() ?? 0) >= Self.clipping {
                    levelChecked = false
                    throw lowerLevel()
                }
                if Self.rms(recording[...]) - noiseFloor < 6 { throw MeasurementError.noSignal(channel: channel) }
                position.append(CalibrationCapture(recording: recording.map(Double.init), sweep: sweep,
                                                   micCalibration: configuration.micCalibration))
            }
            for (channel, capture) in position.enumerated() { captures[channel].append(capture) }
            return position
        }
    }

    /// The speaker profile from every position measured (the first is the listening position).
    public func profile(name: String, target: CalibrationTarget = .flat, limits: CalibrationLimits = CalibrationLimits(),
                        smoothing: CalibrationSmoothing = .twelfth, date: Date = Date()) -> CalibrationProfile? {
        guard let format, positions > 0 else { return nil }
        return CalibrationProfile.speakers(name: name, deviceUID: configuration.outputUID,
                                           deviceName: configuration.outputName, captures: captures, target: target,
                                           limits: limits, smoothing: smoothing,
                                           micCalibration: configuration.micCalibration?.name,
                                           sampleRate: format.sampleRate, date: date)
    }

    /// Done measuring: stops IO, frees the devices and resumes the held sinks.
    public func finish() { close() }

    /// From any thread: the signal stops at once (silent within one IO buffer), and the devices are freed and routing
    /// resumed, by the step that is running (it throws `cancelled`) or right here when none is.
    public func cancel() {
        let idle = lock.withLock { () -> Bool in
            isCancelled = true
            if let measure { jk_measure_stop(measure) }
            return !isBusy
        }
        if idle { close() }
    }

    public var isFinished: Bool { lock.withLock { isClosed } }

    // MARK: Plumbing

    /// Runs one step; a cancel that came meanwhile frees everything once it ends, and so does a device gone.
    private func step<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if isCancelled { throw MeasurementError.cancelled }
            if isClosed { throw MeasurementError.unusable("This measurement has finished.") }
            isBusy = true
        }
        do {
            let result = try body()
            let cancelled = lock.withLock { () -> Bool in
                isBusy = false
                return isCancelled
            }
            if cancelled {
                close()
                throw MeasurementError.cancelled
            }
            return result
        } catch {
            let cancelled = lock.withLock { () -> Bool in
                isBusy = false
                return isCancelled
            }
            let recoverable = (error as? MeasurementError).map { !Self.endsMeasurement($0) } ?? false
            if cancelled || !recoverable || !lock.withLock({ measure != nil }) { close() }
            throw cancelled ? MeasurementError.cancelled : error
        }
    }

    /// Errors after which the devices can't go on; the others (clipping, no signal, noise) can be fixed and the
    /// step tried again.
    private static func endsMeasurement(_ error: MeasurementError) -> Bool {
        switch error {
        case .noSignal, .inputClipping, .lowSNR, .levelNotChecked, .dropouts: false
        case .deviceDisappeared, .microphoneDenied, .unusable, .cancelled: true
        }
    }

    private func checkCancelled() throws {
        if lock.withLock({ isCancelled }) { throw MeasurementError.cancelled }
    }

    private func ready() throws -> MeasurementFormat {
        guard let format, lock.withLock({ measure != nil }) else {
            throw MeasurementError.unusable("The measurement hasn't started.")
        }
        return format
    }

    private func lowerLevel() -> MeasurementError {
        level = max(Self.levelRange.lowerBound, level - Self.clippingStep)
        return .inputClipping(level: level)
    }

    /// The sweep at the test level: its RMS while sweeping matches the pink noise's.
    private func sweep(at sampleRate: Double, level: Double) -> CalibrationSweep {
        CalibrationSweep(sampleRate: sampleRate, duration: configuration.sweepDuration,
                         leadSilence: configuration.leadSilence, tail: configuration.tail,
                         amplitude: pow(10, level / 20) * 2.0.squareRoot())
    }

    /// Lets IO run for `settleTime` before the first take.
    private func settle(_ measure: OpaquePointer) throws {
        guard let format else { return }
        let cycles = Int(Self.settleTime * format.sampleRate) / max(1, format.bufferFrames)
        let start = jk_measure_cycles(measure)
        try wait(measure) { jk_measure_cycles(measure) >= start + UInt64(max(1, cycles)) }
    }

    /// Plays `signal` on `channel` and records as many frames; a take that lost IO buffers is played again.
    private func take(_ signal: [Float], channel: Int) throws -> [Float] {
        guard let measure = lock.withLock({ measure }) else { throw MeasurementError.cancelled }
        for _ in 0..<Self.attempts {
            let dropouts = jk_measure_dropouts(measure)
            try signal.withUnsafeBufferPointer { samples in
                try wait(measure) { jk_measure_start(measure, samples.baseAddress!, UInt32(samples.count), UInt32(channel)) == 1 }
            }
            try wait(measure) { jk_measure_is_done(measure) != 0 }
            if jk_measure_dropouts(measure) == dropouts {
                return Array(UnsafeBufferPointer(start: jk_measure_recording(measure), count: signal.count))
            }
        }
        throw MeasurementError.dropouts
    }

    /// Waits until `condition` holds, while IO keeps running and nothing is cancelled or gone.
    private func wait(_ measure: OpaquePointer, until condition: () -> Bool) throws {
        var cycles = jk_measure_cycles(measure)
        var moved = Date()
        var checked = Date.distantPast
        while !condition() {
            try checkCancelled()
            let now = Date()
            if now.timeIntervalSince(checked) > 0.1 {
                checked = now
                if let missing = device.missingDevice() { throw MeasurementError.deviceDisappeared(missing) }
            }
            let current = jk_measure_cycles(measure)
            if current != cycles {
                cycles = current
                moved = now
            } else if now.timeIntervalSince(moved) > Self.stallTimeout {
                throw MeasurementError.deviceDisappeared(device.missingDevice() ?? configuration.outputName)
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// Stops IO, frees the devices and resumes routing, once.
    private func close() {
        let closing = lock.withLock { () -> (measure: OpaquePointer?, holding: Bool)? in
            guard !isClosed else { return nil }
            isClosed = true
            defer {
                measure = nil
                isHolding = false
            }
            if let measure { jk_measure_stop(measure) }
            return (measure, isHolding)
        }
        guard let (measure, holding) = closing else { return }
        device.close()
        if let measure {
            jk_measure_reset(measure)
            jk_measure_destroy(measure)
        }
        if holding { routing?.resume(heldSinks) }
    }

    // MARK: Signals

    static func decibels(_ amplitude: Double) -> Double { 20 * log10(max(amplitude, 1e-10)) }

    /// RMS level in dBFS.
    static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -200 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return 10 * log10(max(power, 1e-20))
    }

    /// Pink noise (falling 3 dB per octave) at an RMS level in dBFS, faded in and out over 20 ms: Paul Kellet's
    /// filter on repeatable white noise.
    static func pinkNoise(count: Int, level: Double, sampleRate: Double) -> [Float] {
        var state: UInt64 = 0x5DEE_CE66_D1CE_4E5B
        var b = [Double](repeating: 0, count: 7)
        var samples = [Double](repeating: 0, count: count)
        for n in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)
            b[0] = 0.99886 * b[0] + white * 0.0555179
            b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520
            b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522
            b[5] = -0.7616 * b[5] - white * 0.0168980
            samples[n] = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
        }
        let mean = samples.reduce(0, +) / Double(max(1, count))
        let power = samples.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, count))
        let scale = pow(10, level / 20) / max(power.squareRoot(), 1e-12)
        let fade = max(1, min(count / 2, Int(0.02 * sampleRate)))
        return samples.enumerated().map { n, value in
            var gain = scale
            if n < fade { gain *= Double(n) / Double(fade) }
            if n >= count - fade { gain *= Double(count - 1 - n) / Double(fade) }
            return Float(max(-1, min(1, (value - mean) * gain)))
        }
    }
}
