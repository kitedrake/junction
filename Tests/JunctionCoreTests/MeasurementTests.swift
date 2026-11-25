import Foundation
import JunctionKernel
import XCTest
@testable import JunctionCore

/// A repeatable random source (SplitMix64) with Gaussian samples, for the simulated microphone's noise.
private struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Double {
        let u = max(Double(next() >> 11) / Double(1 << 53), 1e-300), v = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

/// A made-up output device and microphone in a made-up room, standing in for Core Audio: a thread runs IO cycles
/// (faster than real time) through the kernel's measurement IOProc. Each speaker is a set of filters, a level and the
/// sound's flight time; the devices add latency; the microphone's clock wanders around the output's (what is left
/// after drift compensation), it hisses, and it clips at full scale. Cycles can be dropped (a lost buffer) and the
/// microphone can disappear.
final class SimulatedMeasurementDevice: MeasurementDevice, @unchecked Sendable {
    struct Speaker {
        var filters: [CalibrationFilter]
        /// dB from the output to the microphone.
        var level: Double
        /// Samples of flight from the speaker to the microphone.
        var delay: Int
    }

    let outputName = "Desk Speakers"
    let micName = "Measuring Mic"
    var sampleRate = 48_000.0
    var bufferFrames = 256
    var outputChannels = 2
    var micChannels = 2
    var micChannel = 1
    /// Samples from output to input through the devices (at least a buffer more than the interpolator's reach).
    var latency = 300
    /// dBFS of hiss at the microphone.
    var noise = -80.0
    /// The largest rate difference between the microphone's clock and the output's (wandering over `driftPeriod`).
    var drift = 0.0
    var driftPeriod = 2.0
    /// Microseconds of real time per IO cycle.
    var pace: UInt32 = 100
    var seed: UInt64 = 1
    /// `rooms[position][channel]`; nil: not connected.
    var rooms: [[Speaker?]]

    private let lock = NSLock()
    private var _position = 0
    private var _gone = false
    private var _running = false
    private var _stats: [(peak: Float, lastSound: Int)] = []
    private var _opens = 0, _closes = 0, _drops = 0
    private var measure: OpaquePointer?
    private var finished: DispatchSemaphore?
    private var thread: Thread?
    private var _dropCycle: ((Int, OpaquePointer) -> Bool)?
    private var _onCycle: ((Int, OpaquePointer) -> Void)?
    /// Asked before each cycle (on the IO thread): true drops it.
    var dropCycle: ((Int, OpaquePointer) -> Bool)? {
        get { lock.withLock { _dropCycle } }
        set { lock.withLock { _dropCycle = newValue } }
    }
    /// Told after each cycle (on the IO thread).
    var onCycle: ((Int, OpaquePointer) -> Void)? {
        get { lock.withLock { _onCycle } }
        set { lock.withLock { _onCycle = newValue } }
    }

    init(rooms: [[Speaker?]]) { self.rooms = rooms }

    var position: Int {
        get { lock.withLock { _position } }
        set { lock.withLock { _position = newValue } }
    }
    var opens: Int { lock.withLock { _opens } }
    var closes: Int { lock.withLock { _closes } }
    var drops: Int { lock.withLock { _drops } }
    var isRunning: Bool { lock.withLock { _running } }
    /// Per IO cycle: the output's peak, and the last frame with sound in it (−1: silent).
    var stats: [(peak: Float, lastSound: Int)] { lock.withLock { _stats } }

    func disappear() { lock.withLock { _gone = true } }

    /// The room's response at a position and channel, in dB.
    func response(position: Int, channel: Int, at frequencies: [Double] = CalibrationGrid.frequencies) -> [Double] {
        let speaker = rooms[position][channel]!
        return CalibrationFilter.response(of: speaker.filters, preamp: speaker.level, sampleRate: sampleRate, at: frequencies)
    }

    // MARK: MeasurementDevice

    func open() throws -> MeasurementFormat {
        lock.withLock { _opens += 1 }
        if lock.withLock({ _gone }) { throw MeasurementError.deviceDisappeared(micName) }
        return MeasurementFormat(sampleRate: sampleRate, outputChannels: outputChannels, micChannel: micChannel,
                                 bufferFrames: bufferFrames)
    }

    func start(_ measure: OpaquePointer) throws {
        let done = DispatchSemaphore(value: 0)
        lock.withLock {
            self.measure = measure
            _running = true
            finished = done
        }
        let thread = Thread { [self] in
            run(measure)
            lock.withLock { _running = false }
            done.signal()
        }
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func close() {
        let (done, onThread) = lock.withLock { () -> (DispatchSemaphore?, Bool) in
            _closes += 1
            _running = false
            defer { finished = nil }
            return (finished, Thread.current == thread)
        }
        if !onThread { done?.wait() }
        lock.withLock { measure = nil }
    }

    func missingDevice() -> String? { lock.withLock { _gone } ? micName : nil }

    // MARK: IO

    /// One speaker's played samples after its filters, kept for the last `ringSize` frames.
    private struct Channel {
        var ring = [Double](repeating: 0, count: SimulatedMeasurementDevice.ringSize)
        var states: [(Double, Double)] = []
        var biquads: [CalibrationBiquad] = []
    }

    static let ringSize = 1 << 17

    private func run(_ measure: OpaquePointer) {
        let frames = bufferFrames
        var random = SeededRandom(state: seed)
        let noiseAmplitude = pow(10, noise / 20)
        let wander = drift * driftPeriod * sampleRate / (2 * Double.pi)
        var channels = [Channel](repeating: Channel(), count: outputChannels)
        var position = -1
        var clock = 0
        var cycle = 0

        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * micChannels)
        let outputs = (0..<outputChannels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        inputList[0] = AudioBuffer(mNumberChannels: UInt32(micChannels), mDataByteSize: UInt32(frames * micChannels * 4),
                                   mData: input)
        let outputList = AudioBufferList.allocate(maximumBuffers: outputChannels)  // one buffer per channel
        for (index, buffer) in outputs.enumerated() {
            outputList[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buffer)
        }
        defer {
            input.deallocate()
            outputs.forEach { $0.deallocate() }
            free(inputList.unsafeMutablePointer)
            free(outputList.unsafeMutablePointer)
        }

        while lock.withLock({ _running && !_gone }) {
            let (now, rooms) = lock.withLock { (_position, self.rooms) }
            let gains = rooms[now].map { $0.map { pow(10, $0.level / 20) } ?? 0 }
            if now != position {  // the microphone moved: the room's filters change
                position = now
                for c in channels.indices {
                    let speaker = c < rooms[position].count ? rooms[position][c] : nil
                    channels[c].biquads = (speaker?.filters ?? []).compactMap { $0.coefficients(sampleRate: sampleRate) }
                    channels[c].states = channels[c].biquads.map { _ in (0, 0) }
                }
            }
            // What the microphone hears this cycle: sound played at least `latency` frames ago, read between samples
            // where the clocks have wandered apart (held for the cycle: it moves a few thousandths of a sample in one).
            let offset = wander * sin(2 * Double.pi * (Double(clock) + Double(frames) / 2) / (driftPeriod * sampleRate))
            let whole = Int(offset.rounded(.down)), frac = offset - Double(whole)
            let weights = Self.lanczos(frac)
            var heard = (0..<frames).map { _ in noiseAmplitude * random.gaussian() }
            for (c, speaker) in rooms[position].enumerated() where c < channels.count {
                guard let speaker else { continue }
                channels[c].ring.withUnsafeBufferPointer { ring in
                    for i in 0..<frames {
                        let base = clock + i - latency - speaker.delay + whole
                        var value = 0.0
                        if let weights {
                            for m in -16...15 where base - m >= 0 {
                                value += ring[(base - m) & (Self.ringSize - 1)] * weights[m + 16]
                            }
                        } else if base >= 0 {
                            value = ring[base & (Self.ringSize - 1)]
                        }
                        heard[i] += gains[c] * value
                    }
                }
            }
            for i in 0..<frames {
                for m in 0..<micChannels {
                    let value = m == micChannel ? heard[i] : noiseAmplitude * random.gaussian()
                    input[i * micChannels + m] = Float(max(-1, min(1, value)))
                }
            }
            for buffer in outputs { buffer.initialize(repeating: 0, count: frames) }
            if dropCycle?(cycle, measure) == true {
                lock.withLock { _drops += 1 }
            } else {
                var time = AudioTimeStamp()
                time.mSampleTime = Double(clock)
                time.mFlags = .sampleTimeValid
                _ = jk_measure_ioproc(0, &time, inputList.unsafePointer, &time, outputList.unsafeMutablePointer, &time,
                                      UnsafeMutableRawPointer(measure))
            }
            // The speakers play it: through their filters into the room.
            var peak: Float = 0, lastSound = -1
            for c in channels.indices {
                for i in 0..<frames {
                    let played = outputs[c][i]
                    if played != 0 {
                        peak = max(peak, abs(played))
                        lastSound = max(lastSound, i)
                    }
                    var value = Double(played)
                    for (k, biquad) in channels[c].biquads.enumerated() {
                        let (s1, s2) = channels[c].states[k]
                        let out = biquad.b0 * value + s1
                        channels[c].states[k] = (biquad.b1 * value - biquad.a1 * out + s2, biquad.b2 * value - biquad.a2 * out)
                        value = out
                    }
                    channels[c].ring[(clock + i) & (Self.ringSize - 1)] = value
                }
            }
            lock.withLock { _stats.append((peak, lastSound)) }
            clock += frames
            onCycle?(cycle, measure)
            cycle += 1
            if pace > 0 { usleep(pace) }
        }
    }

    /// Lanczos (windowed sinc, 32 samples) weights for reading `frac` of a sample after sample k: weight m + 16 goes
    /// with sample k − m. Nil when no interpolation is needed.
    private static func lanczos(_ frac: Double) -> [Double]? {
        guard frac > 0 else { return nil }
        return (-16...15).map { m in
            let x = frac + Double(m)
            return 16 * sin(Double.pi * x) * sin(Double.pi * x / 16) / (Double.pi * Double.pi * x * x)
        }
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Stands in for the router: records what it was asked to hold and resume.
final class RecordingRouting: MeasurementRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _holds: [Set<UUID>] = []
    private var _resumes: [Set<UUID>] = []
    var holds: [Set<UUID>] { lock.withLock { _holds } }
    var resumes: [Set<UUID>] { lock.withLock { _resumes } }

    func hold(_ sinks: Set<UUID>, done: @escaping @Sendable () -> Void) {
        lock.withLock { _holds.append(sinks) }
        DispatchQueue.global().async { done() }
    }

    func resume(_ sinks: Set<UUID>) { lock.withLock { _resumes.append(sinks) } }
}

/// A made-up setup: the measured speakers and microphone in use by two sinks, and an interface's sinks that aren't.
enum MeasuringSetup {
    static let speakers = DeviceInfo(uid: "DeskSpeakers", name: "Desk Speakers", inputChannels: 0, outputChannels: 2)
    static let mic = DeviceInfo(uid: "MeasuringMic", name: "Measuring Mic", inputChannels: 2, outputChannels: 0)
    static let interface = DeviceInfo(uid: "USBInterface", name: "Scarlett 2i2", inputChannels: 2, outputChannels: 2)

    /// The graph's plan, and the sinks that use the speakers or the microphone.
    static func plan() -> (plan: RoutingPlan, affected: Set<UUID>) {
        let inventory = Inventory(
            devices: [speakers, mic, interface,
                      DeviceInfo(uid: Demo.streamMix.uid, name: Demo.streamMix.name, inputChannels: 2, outputChannels: 2, isJunction: true),
                      DeviceInfo(uid: Demo.chat.uid, name: Demo.chat.name, inputChannels: 2, outputChannels: 2, isJunction: true)],
            defaultOutputUID: speakers.uid, defaultInputUID: mic.uid, driver: .installed(version: "test"))
        func device(_ info: DeviceInfo, on canvas: UUID) -> Node {
            Node(kind: .device(DeviceRef(uid: info.uid, name: info.name, inputChannels: info.inputChannels,
                                         outputChannels: info.outputChannels)), canvas: canvas)
        }
        // Stream Mix: the microphone into the virtual device, which plays on the speakers.
        let micNode = device(mic, on: Demo.streamMix.id)
        let streamMix = Node(kind: .virtualDevice(Demo.streamMix.id), canvas: Demo.streamMix.id)
        let speakersNode = device(speakers, on: Demo.streamMix.id)
        // Chat: the interface's input into the virtual device, which plays on the interface.
        let interfaceIn = device(interface, on: Demo.chat.id)
        let chat = Node(kind: .virtualDevice(Demo.chat.id), canvas: Demo.chat.id)
        let interfaceOut = device(interface, on: Demo.chat.id)
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat],
                          nodes: [micNode, streamMix, speakersNode, interfaceIn, chat, interfaceOut])
        func cable(_ from: Node, _ to: Node, _ channel: Int) -> Cable {
            Cable(from: PortRef(node: from.id, channel: channel), to: PortRef(node: to.id, channel: channel))
        }
        graph.cables = [cable(micNode, streamMix, 0), cable(streamMix, speakersNode, 0), cable(streamMix, speakersNode, 1),
                        cable(interfaceIn, chat, 0), cable(chat, interfaceOut, 0)]
        graph.isRoutingOn = true
        return (Planner.plan(graph, inventory: inventory), [streamMix.id, speakersNode.id])
    }
}

final class MeasurementTests: XCTestCase {
    private let rate = 48_000.0

    /// Two speakers 48 samples apart and 3 dB apart, each with a room mode; at three positions the modes and the
    /// distances change.
    private func room() -> SimulatedMeasurementDevice {
        func left(_ gain: Double, moved: Int) -> SimulatedMeasurementDevice.Speaker {
            .init(filters: [CalibrationFilter(.peaking, frequency: 70, gain: gain, q: 4)], level: -10, delay: 300 + moved)
        }
        func right(_ gain: Double, moved: Int) -> SimulatedMeasurementDevice.Speaker {
            .init(filters: [CalibrationFilter(.peaking, frequency: 90, gain: gain, q: 3),
                            CalibrationFilter(.highShelf, frequency: 6000, gain: -3)], level: -13, delay: 348 + moved)
        }
        return SimulatedMeasurementDevice(rooms: [[left(7, moved: 0), right(5, moved: 0)],
                                                  [left(5, moved: 20), right(6, moved: 9)],
                                                  [left(8, moved: 35), right(4, moved: 17)]])
    }

    private func configuration(level: Double = -18) -> MeasurementEngine.Configuration {
        MeasurementEngine.Configuration(outputUID: MeasuringSetup.speakers.uid, outputName: "Desk Speakers",
                                        micUID: MeasuringSetup.mic.uid, micName: "Measuring Mic", micChannel: 1,
                                        channels: 2, level: level, sweepDuration: 1.5, leadSilence: 0.2, tail: 0.6)
    }

    private func engine(_ device: SimulatedMeasurementDevice, routing: MeasurementRouting? = nil,
                        level: Double = -18) -> (MeasurementEngine, RecordingRouting, Set<UUID>) {
        let recording = RecordingRouting()
        let (plan, affected) = MeasuringSetup.plan()
        let engine = MeasurementEngine(configuration: configuration(level: level), plan: plan, device: device,
                                       routing: routing ?? recording)
        return (engine, recording, affected)
    }

    private func assertError(_ expected: MeasurementError, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? MeasurementError, expected, file: file, line: line)
        }
    }

    /// Everything freed and routing back: the device closed, its IO stopped, every held sink resumed once.
    private func assertReleased(_ device: SimulatedMeasurementDevice, _ routing: RecordingRouting, _ affected: Set<UUID>,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(device.closes, 1, file: file, line: line)
        XCTAssertFalse(device.isRunning, file: file, line: line)
        XCTAssertEqual(routing.holds, [affected], file: file, line: line)
        XCTAssertEqual(routing.resumes, [affected], file: file, line: line)
    }

    // MARK: Sinks to hold

    func testOnlySinksUsingTheOutputOrTheMicrophoneAreHeld() {
        let (plan, affected) = MeasuringSetup.plan()
        XCTAssertEqual(plan.sinks.count, 4)
        XCTAssertEqual(affected.count, 2)
        XCTAssertEqual(plan.sinks(using: [MeasuringSetup.speakers.uid, MeasuringSetup.mic.uid]), affected)
        XCTAssertEqual(plan.sinks(using: [MeasuringSetup.mic.uid]).count, 1)
        XCTAssertEqual(plan.sinks(using: ["Nothing"]), [])
        let engine = MeasurementEngine(configuration: configuration(), plan: plan, device: room(), routing: nil)
        XCTAssertEqual(engine.heldSinks, affected)
    }

    // MARK: A whole measurement

    func testMeasuringSeveralPositionsReproducesTheRoom() throws {
        let device = room()
        device.drift = 20e-6
        // One lost buffer in the middle of the first sweep: that sweep is played again.
        let dropped = NSLock()
        var hasDropped = false
        device.dropCycle = { _, measure in
            dropped.withLock {
                guard !hasDropped, jk_measure_recorded(measure) > 80_000 else { return false }
                hasDropped = true
                return true
            }
        }
        let (engine, routing, affected) = engine(device)
        try engine.start()
        XCTAssertEqual(routing.holds, [affected], "held before the devices open")
        XCTAssertEqual(device.opens, 1)

        let floor = try engine.checkNoiseFloor()
        XCTAssertEqual(floor, -80, accuracy: 0.5)
        let reading = try engine.checkLevel()
        XCTAssertEqual(reading.level, -18)
        XCTAssertEqual(reading.noiseFloor, floor)
        XCTAssertGreaterThan(reading.snr, MeasurementEngine.minimumSNR)
        XCTAssertLessThan(reading.micPeak, 0)
        XCTAssertEqual(reading.micLevel, -28, accuracy: 3, "pink noise at −18 dBFS through a −10 dB speaker")

        for position in 0..<3 {
            device.position = position
            let captures = try engine.measurePosition()
            XCTAssertEqual(captures.count, 2)
        }
        XCTAssertEqual(device.drops, 1)
        XCTAssertEqual(engine.positions, 3)
        let profile = try XCTUnwrap(engine.profile(name: "Desk", date: Date(timeIntervalSince1970: 0)))
        engine.finish()
        assertReleased(device, routing, affected)
        XCTAssertEqual(device.opens, 1)

        // Within the maths' tolerances: every curve within 0.5 dB (1/6 octave, 30 Hz–16 kHz), the delay to a sample,
        // the level to 0.3 dB, each mode taken out to 1 dB.
        func worst(_ measured: CalibrationCurve, _ expected: [Double]) -> Double {
            let a = measured.smoothed(.sixth), b = CalibrationCurve(levels: expected).smoothed(.sixth)
            return zip(a.frequencies.indices, a.frequencies).filter { (30...16_000).contains($0.1) }
                .map { abs(a.levels[$0.0] - b.levels[$0.0]) }.max() ?? .infinity
        }
        for channel in 0..<2 {
            for position in 0..<3 {
                let measured = engine.captures[channel][position].curve
                XCTAssertLessThanOrEqual(worst(measured, device.response(position: position, channel: channel)), 0.5,
                                         "channel \(channel), position \(position)")
            }
            let expected = CalibrationAnalysis.average((0..<3).map {
                CalibrationCurve(levels: device.response(position: $0, channel: channel))
            })
            let average = try XCTUnwrap(profile.measurements.first { $0.channel == channel && $0.position == nil })
            XCTAssertLessThanOrEqual(worst(average.curve, expected.levels), 0.5, "channel \(channel) average")
            let mode = device.rooms[0][channel]!.filters[0].frequency
            let correction = profile.curve(channel: channel, sampleRate: rate, at: [mode])[0] - profile.preamp
                - profile.channels[channel].level
            XCTAssertEqual(correction, -(expected.level(at: mode) - expected.level(at: 1000)), accuracy: 1)
        }
        XCTAssertEqual(profile.kind, .speakers)
        XCTAssertEqual(profile.deviceUID, MeasuringSetup.speakers.uid)
        XCTAssertEqual(profile.channels[0].delay * rate, 48, accuracy: 1)
        XCTAssertEqual(profile.channels[1].delay, 0)
        XCTAssertEqual(profile.channels[0].level, -3, accuracy: 0.3)
        XCTAssertEqual(profile.measurements.count, 8)
    }

    func testSweepsAreRecordedInStepWithWhatPlays() throws {
        // No clock wander: the arrival is exactly the devices' latency and the flight.
        let device = room()
        let (engine, _, _) = engine(device)
        try engine.start()
        try engine.checkLevel()
        try engine.measurePosition()
        engine.finish()
        XCTAssertEqual(engine.captures[0][0].arrival * rate, 600, accuracy: 0.5)
        XCTAssertEqual(engine.captures[1][0].arrival * rate, 648, accuracy: 0.5)
    }

    // MARK: Errors

    func testErrorsSayWhatWentWrong() {
        let messages: [(MeasurementError, String)] = [
            (.noSignal(channel: nil), "The microphone doesn't hear the test signal."),
            (.noSignal(channel: 1), "The microphone didn't hear speaker 2."),
            (.inputClipping(level: -24), "The microphone's input is clipping. Junction lowered the test level to -24.0 dBFS; check the level again"),
            (.lowSNR(17.24), "The test signal is only 17.2 dB above the room's noise; a measurement needs at least 30 dB."),
            (.deviceDisappeared("Measuring Mic"), "“Measuring Mic” went away during the measurement. Reconnect it and start again."),
            (.dropouts, "Audio kept dropping out"),
            (.microphoneDenied, "Privacy & Security › Microphone"),
        ]
        for (error, message) in messages {
            XCTAssertTrue(error.localizedDescription.hasPrefix(message) || error.localizedDescription.contains(message),
                          error.localizedDescription)
        }
        XCTAssertEqual(Set(messages.map { $0.0.localizedDescription }).count, messages.count)
    }

    func testSilentSpeakersGiveNoSignal() throws {
        let device = room()
        device.rooms = [[nil, nil]]
        let (engine, routing, affected) = engine(device)
        try engine.start()
        assertError(.noSignal(channel: nil)) { try engine.checkLevel() }
        XCTAssertLessThan(try XCTUnwrap(engine.reading).snr, 6)
        assertError(.levelNotChecked) { try engine.measurePosition() }
        XCTAssertTrue(device.isRunning, "the user can fix it and check again")
        engine.finish()
        assertReleased(device, routing, affected)
    }

    func testASpeakerThatStaysSilentIsNamed() throws {
        let device = room()
        device.rooms[0][1] = nil
        let (engine, routing, affected) = engine(device)
        try engine.start()
        try engine.checkLevel()
        assertError(.noSignal(channel: 1)) { try engine.measurePosition() }
        XCTAssertEqual(engine.positions, 0, "a position counts only once every channel is measured")
        engine.finish()
        assertReleased(device, routing, affected)
    }

    func testClippingLowersTheLevelAndAsksToCheckAgain() throws {
        let device = room()
        device.rooms = [[.init(filters: [], level: 8, delay: 300), nil]]
        let (engine, routing, affected) = engine(device)
        try engine.start()
        assertError(.inputClipping(level: -24)) { try engine.checkLevel() }
        XCTAssertEqual(engine.level, -24)
        assertError(.levelNotChecked) { try engine.measurePosition() }
        let reading = try engine.checkLevel()
        XCTAssertEqual(reading.level, -24)
        XCTAssertLessThan(reading.micPeak, -0.2)
        engine.finish()
        assertReleased(device, routing, affected)
    }

    func testANoisyRoomIsRefused() throws {
        let device = room()
        device.noise = -45
        let (engine, routing, affected) = engine(device)
        try engine.start()
        XCTAssertThrowsError(try engine.checkLevel()) { error in
            guard case .lowSNR(let snr) = error as? MeasurementError else { return XCTFail("\(error)") }
            XCTAssertEqual(snr, 17, accuracy: 3)
            XCTAssertLessThan(snr, MeasurementEngine.minimumSNR)
        }
        engine.finish()
        assertReleased(device, routing, affected)
    }

    func testAMicrophoneThatDisappearsEndsTheMeasurement() throws {
        let device = room()
        let (engine, routing, affected) = engine(device)
        try engine.start()
        try engine.checkLevel()
        device.onCycle = { [weak device] _, measure in
            if jk_measure_is_done(measure) == 0, jk_measure_recorded(measure) > 50_000 { device?.disappear() }  // mid-sweep
        }
        assertError(.deviceDisappeared("Measuring Mic")) { try engine.measurePosition() }
        XCTAssertTrue(engine.isFinished)
        assertReleased(device, routing, affected)
        assertError(.unusable("This measurement has finished.")) { try engine.checkLevel() }
    }

    func testDropoutsInEveryTakeGiveUp() throws {
        let device = room()
        device.dropCycle = { cycle, _ in cycle % 40 == 39 }
        let (engine, routing, affected) = engine(device)
        try engine.start()
        assertError(.dropouts) { try engine.checkNoiseFloor() }
        engine.finish()
        assertReleased(device, routing, affected)
    }

    // MARK: Cancelling

    func testCancellingASweepIsSilentWithinOneBufferAndFreesEverything() throws {
        let device = room()
        let (engine, routing, affected) = engine(device)
        try engine.start()
        try engine.checkLevel()
        let cancelledAt = NSLock()
        var cycleAtCancel: Int?
        device.onCycle = { cycle, measure in
            // A third of the way into the first sweep (the level check's finished take also counts 72 000 frames).
            guard cancelledAt.withLock({ cycleAtCancel == nil }), jk_measure_is_done(measure) == 0,
                  jk_measure_recorded(measure) > 30_000 else { return }
            cancelledAt.withLock { cycleAtCancel = cycle }
            engine.cancel()  // from the IO thread, between two buffers: it must not wait
        }
        let finished = expectation(description: "the sweep stops")
        let thrown = Locked<Error?>(nil)
        DispatchQueue.global().async {
            do { try engine.measurePosition() } catch { thrown.value = error }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        XCTAssertEqual(thrown.value as? MeasurementError, .cancelled)
        XCTAssertTrue(engine.isFinished)
        assertReleased(device, routing, affected)
        let cancel = try XCTUnwrap(cancelledAt.withLock { cycleAtCancel })
        let stats = device.stats
        XCTAssertGreaterThan(stats[cancel].peak, 0.01, "it was playing")
        if stats.count > cancel + 1 {  // IO may have run on until the engine closed the device
            XCTAssertLessThan(stats[cancel + 1].lastSound, Int(JK_MEASURE_FADE_FRAMES), "faded out within the next buffer")
            XCTAssertTrue(stats[(cancel + 1)...].dropFirst().allSatisfy { $0.peak == 0 }, "silent after that")
        }
        assertError(.cancelled) { try engine.measurePosition() }
    }

    /// The kernel's stage on its own, one buffer at a time: a take plays and records in the same cycles, and a stop
    /// fades out within the next buffer.
    func testStoppedTakeFadesOutWithinTheNextBuffer() throws {
        let frames = 256
        let measure = try XCTUnwrap(jk_measure_create(1, 4096))
        defer { jk_measure_destroy(measure) }
        var input = [Float](repeating: 0, count: frames * 2)
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        let signal = (0..<4096).map { Float(sin(Double($0) * 0.05) * 0.5) }
        var sampleTime = 0.0
        func cycle() {
            for i in 0..<frames { input[2 * i + 1] = Float(sampleTime) + Float(i) }  // the microphone: a frame count
            input.withUnsafeMutableBufferPointer { mic in
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        let inputs = AudioBufferList.allocate(maximumBuffers: 1)
                        inputs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: mic.baseAddress)
                        let outputs = AudioBufferList.allocate(maximumBuffers: 2)
                        outputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l.baseAddress)
                        outputs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: r.baseAddress)
                        var time = AudioTimeStamp()
                        time.mSampleTime = sampleTime
                        time.mFlags = .sampleTimeValid
                        _ = jk_measure_ioproc(0, &time, inputs.unsafePointer, &time, outputs.unsafeMutablePointer, &time,
                                              UnsafeMutableRawPointer(measure))
                        free(inputs.unsafeMutablePointer)
                        free(outputs.unsafeMutablePointer)
                    }
                }
            }
            sampleTime += Double(frames)
        }
        cycle()  // idle: silence
        XCTAssertTrue(left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 })
        XCTAssertEqual(jk_measure_start(measure, signal, 1000, 1), 1)
        XCTAssertEqual(jk_measure_start(measure, signal, 1000, 1), 0, "one take at a time")
        cycle()
        XCTAssertEqual(Array(right), Array(signal.prefix(frames)), "the take plays on its channel only")
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        XCTAssertEqual(jk_measure_recorded(measure), UInt32(frames))
        XCTAssertEqual(jk_measure_recording(measure)[0], Float(frames), "recorded from the cycle it started in")
        jk_measure_stop(measure)
        cycle()
        let fading = Array(right)
        XCTAssertEqual(fading[0], signal[frames], accuracy: 1e-6)
        XCTAssertTrue(fading[Int(JK_MEASURE_FADE_FRAMES)...].allSatisfy { $0 == 0 }, "silent within the buffer")
        XCTAssertEqual(jk_measure_recorded(measure), UInt32(frames), "nothing recorded after the stop")
        XCTAssertEqual(jk_measure_is_done(measure), 0)
        cycle()
        XCTAssertTrue(right.allSatisfy { $0 == 0 })

        // A full take: done once every frame is recorded, then silence; a lost buffer counts as a dropout.
        XCTAssertEqual(jk_measure_start(measure, signal, 600, 0), 1)
        for _ in 0..<3 { cycle() }
        XCTAssertEqual(jk_measure_is_done(measure), 1)
        XCTAssertEqual(jk_measure_recorded(measure), 600)
        XCTAssertEqual(jk_measure_recording(measure)[0], Float(4 * frames))
        XCTAssertEqual(jk_measure_recording(measure)[599], Float(4 * frames + 599))
        XCTAssertEqual(jk_measure_dropouts(measure), 0)
        sampleTime += Double(frames)
        cycle()
        XCTAssertEqual(jk_measure_dropouts(measure), 1)
        XCTAssertEqual(jk_measure_cycles(measure), 8)
    }

    func testCancellingBetweenPositionsFreesEverythingAtOnce() throws {
        let device = room()
        let (engine, routing, affected) = engine(device)
        try engine.start()
        try engine.checkLevel()
        engine.cancel()
        XCTAssertTrue(engine.isFinished)
        assertReleased(device, routing, affected)
        engine.cancel()
        engine.finish()
        XCTAssertEqual(routing.resumes.count, 1, "resumed once")
    }

    // MARK: Holding sinks in the router

    func testRouterHoldsTheAffectedSinksWhileMeasuringAndBringsThemBack() throws {
        let (plan, affected) = MeasuringSetup.plan()
        let all = Set(plan.sinks.map(\.sinkNode))
        let starts = Locked<[UUID: Int]>([:])
        let statuses = Locked<[UUID: SinkStatus]>([:])
        let router = Router(events: EventLog(file: nil), onStatus: { statuses.value = $0 }, checksHealth: false) { runner, _ in
            starts.value[runner.plan.sinkNode, default: 0] += 1  // opens nothing
        }
        router.apply(plan)
        XCTAssertEqual(router.heldSinks, [])
        XCTAssertEqual(router.runningSinks, all)

        let device = room()
        let engine = MeasurementEngine(configuration: configuration(), plan: plan, device: device, routing: router)
        try engine.start()
        XCTAssertEqual(router.heldSinks, affected)
        XCTAssertEqual(router.runningSinks, all.subtracting(affected), "held sinks have nothing running: silent")
        for sink in affected { XCTAssertEqual(statuses.value[sink]?.state, .held) }
        for sink in all.subtracting(affected) { XCTAssertEqual(statuses.value[sink]?.state, .running) }

        // A new plan (a level changed), a rebuild and Core Audio restarting don't bring them back.
        var louder = plan
        for index in louder.sinks.indices { louder.sinks[index].masterGain = 0.5 }
        router.apply(louder)
        router.rebuildAll()
        router.forgetAfterRestart()
        router.apply(louder)
        XCTAssertEqual(router.heldSinks, affected)
        XCTAssertEqual(router.runningSinks, all.subtracting(affected))
        for sink in affected { XCTAssertEqual(starts.value[sink], 1, "not started again while held") }

        try engine.checkLevel()
        engine.finish()
        let deadline = Date().addingTimeInterval(5)
        while router.runningSinks != all, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(router.heldSinks, [])
        XCTAssertEqual(router.runningSinks, all, "back once the measurement is done")
        for sink in all { XCTAssertEqual(statuses.value[sink]?.state, .running) }
        for sink in affected { XCTAssertEqual(starts.value[sink], 2) }
        router.stopAll()
    }
}
