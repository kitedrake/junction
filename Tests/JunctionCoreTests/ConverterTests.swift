import CoreAudio
import Darwin
import JunctionKernel
import XCTest

/// Drives the sample-rate converter with two simulated clocks: a source device writing one IO cycle at a time at its
/// own (possibly drifting) rate, and a sink reading at its rate, with the time stamps Core Audio would pass.
final class ConverterTests: XCTestCase {
    struct Clocks {
        var inputRate: Double
        var outputRate: Double
        /// How much faster the source's real clock runs than its nominal rate (0.001 = 0.1 %).
        var drift = 0.0
        var writeFrames = 512
        var readFrames = 512
        var channels = 1
    }

    struct Run {
        /// Channel 0 of everything read.
        var output: [Float] = []
        /// Seconds and fill, at each read.
        var fills: [(time: Double, fill: Double)] = []
    }

    static let ticksPerSecond: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }()

    static func stamp(sample: Double, seconds: Double) -> AudioTimeStamp {
        var time = AudioTimeStamp()
        time.mSampleTime = sample
        time.mHostTime = UInt64(1_000_000 + seconds * ticksPerSecond)
        time.mFlags = [.sampleTimeValid, .hostTimeValid]
        return time
    }

    /// Runs `seconds` of both clocks. `signal(n, channel)` is the source's nth frame; `writing(t)` and `reading(t)`
    /// say whether each side runs at time t (a stalled device doesn't call its IOProc; its clock goes on).
    static func run(_ converter: OpaquePointer, _ clocks: Clocks, seconds: Double, from start: Double = 0,
                    signal: (Int, Int) -> Float, writing: (Double) -> Bool = { _ in true },
                    reading: (Double) -> Bool = { _ in true }) -> Run {
        let realInputRate = clocks.inputRate * (1 + clocks.drift)
        var nextWrite = Int((start * realInputRate / Double(clocks.writeFrames)).rounded(.up))
        var nextRead = Int((start * clocks.outputRate / Double(clocks.readFrames)).rounded(.up))
        let input = UnsafeMutablePointer<Float>.allocate(capacity: clocks.writeFrames * clocks.channels)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: clocks.readFrames * clocks.channels)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.deallocate(); output.deallocate(); free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: UInt32(clocks.channels),
                              mDataByteSize: UInt32(clocks.writeFrames * clocks.channels * 4), mData: input)
        var result = Run()
        while true {
            // A device calls its IOProc once a whole buffer has been captured; the time stamp is its first frame's.
            let writeTime = Double((nextWrite + 1) * clocks.writeFrames) / realInputRate
            let readTime = Double(nextRead * clocks.readFrames) / clocks.outputRate
            if min(writeTime, readTime) >= start + seconds { break }
            if writeTime <= readTime {
                if writing(writeTime) {
                    let first = nextWrite * clocks.writeFrames
                    for f in 0..<clocks.writeFrames {
                        for c in 0..<clocks.channels { input[f * clocks.channels + c] = signal(first + f, c) }
                    }
                    var time = stamp(sample: Double(first), seconds: Double(first) / realInputRate)
                    jk_converter_write(converter, list.unsafePointer, &time)
                }
                nextWrite += 1
            } else {
                var time = stamp(sample: Double(nextRead * clocks.readFrames), seconds: readTime)
                if reading(readTime) {
                    jk_converter_read(converter, output, UInt32(clocks.readFrames), UInt32(clocks.readFrames), &time)
                    result.output.append(contentsOf: UnsafeBufferPointer(start: output, count: clocks.readFrames))
                    result.fills.append((readTime, jk_converter_fill(converter)))
                }
                nextRead += 1
            }
        }
        return result
    }

    /// Frequency from interpolated rising zero crossings.
    static func frequency(_ samples: ArraySlice<Float>, rate: Double) -> Double {
        var crossings: [Double] = []
        var previous = samples.first ?? 0
        for (offset, value) in samples.dropFirst().enumerated() {
            if previous < 0, value >= 0 { crossings.append(Double(offset) + Double(-previous / (value - previous))) }
            previous = value
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) / (last - first) * rate
    }

    /// Least-squares fit of a sine at `frequency`: its amplitude, and what is left over (noise and distortion) as
    /// RMS relative to the sine's RMS, in dB.
    static func fit(_ samples: ArraySlice<Float>, frequency: Double, rate: Double) -> (amplitude: Double, residualDB: Double) {
        let w = 2 * Double.pi * frequency / rate
        var ss = 0.0, cc = 0.0, sc = 0.0, sy = 0.0, cy = 0.0
        for (n, value) in samples.enumerated() {
            let s = sin(w * Double(n)), c = cos(w * Double(n)), y = Double(value)
            ss += s * s; cc += c * c; sc += s * c; sy += s * y; cy += c * y
        }
        let det = ss * cc - sc * sc
        let a = (sy * cc - cy * sc) / det, b = (cy * ss - sy * sc) / det
        var residual = 0.0
        for (n, value) in samples.enumerated() {
            let e = Double(value) - a * sin(w * Double(n)) - b * cos(w * Double(n))
            residual += e * e
        }
        let amplitude = (a * a + b * b).squareRoot()
        let rms = (residual / Double(samples.count)).squareRoot()
        return (amplitude, 20 * log10(max(rms, 1e-12) / (amplitude / 2.squareRoot())))
    }

    func convertsSine(from inputRate: Double, to outputRate: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let clocks = Clocks(inputRate: inputRate, outputRate: outputRate, writeFrames: 512, readFrames: 480, channels: 2)
        let converter = try XCTUnwrap(jk_converter_create(2, inputRate, outputRate))
        defer { jk_converter_destroy(converter) }
        let tone = 997.0, level: Float = 0.5
        let run = Self.run(converter, clocks, seconds: 3) { n, channel in
            level * Float(sin(2 * Double.pi * tone * Double(n) / inputRate)) * (channel == 0 ? 1 : -1)
        }
        // Skip the first second (filling, fading in, the clocks being measured), then check one second.
        let start = Int(outputRate), window = run.output[start..<(start + Int(outputRate))]
        let measured = Self.frequency(window, rate: outputRate)
        XCTAssertEqual(measured, tone, accuracy: 0.05, "frequency (Hz)", file: file, line: line)
        // Fit 0.1 s pieces (the ratio is steered, so the phase may wander slowly over longer stretches).
        for piece in stride(from: start, to: start + Int(outputRate), by: Int(outputRate / 10)) {
            let slice = run.output[piece..<(piece + Int(outputRate / 10))]
            let result = Self.fit(slice, frequency: Self.frequency(slice, rate: outputRate), rate: outputRate)
            XCTAssertEqual(20 * log10(result.amplitude / Double(level)), 0, accuracy: 0.01, "level (dB)", file: file, line: line)
            XCTAssertLessThan(result.residualDB, -90, "noise and distortion (dB below the tone)", file: file, line: line)
        }
        XCTAssertEqual(jk_converter_underrun_count(converter), 0, file: file, line: line)
        XCTAssertEqual(jk_converter_overrun_count(converter), 0, file: file, line: line)
        XCTAssertEqual(jk_converter_ratio(converter), inputRate / outputRate, accuracy: inputRate / outputRate * 1e-5,
                       file: file, line: line)
    }

    func testConverts44100To48000() throws {
        try convertsSine(from: 44100, to: 48000)
    }

    func testConverts48000To44100() throws {
        try convertsSine(from: 48000, to: 44100)
    }

    func testFiltersOutWhatTheLowerRateCannotCarry() throws {
        // 23 kHz at 48 kHz has no place below 22.05 kHz: it must not fold back into the audible band.
        let converter = try XCTUnwrap(jk_converter_create(1, 48000, 44100))
        defer { jk_converter_destroy(converter) }
        let run = Self.run(converter, Clocks(inputRate: 48000, outputRate: 44100), seconds: 2) { n, _ in
            Float(0.5 * sin(2 * Double.pi * 23000 * Double(n) / 48000))
        }
        let tail = run.output[44100...]
        let rms = (tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count)).squareRoot()
        XCTAssertLessThan(20 * log10(rms / (0.5 / 2.squareRoot())), -60, "alias of 23 kHz (dB)")
    }

    func testRingStaysSteadyWhileTheClocksDrift() throws {
        // The source's clock runs 0.1 % fast. Without steering the ring would gain 44 frames a second and overflow.
        var clocks = Clocks(inputRate: 44100, outputRate: 48000, drift: 0.001, writeFrames: 256, readFrames: 512)
        let converter = try XCTUnwrap(jk_converter_create(1, 44100, 48000))
        defer { jk_converter_destroy(converter) }
        let run = Self.run(converter, clocks, seconds: 120) { n, _ in Float(0.5 * sin(Double(n) * 0.1)) }
        let settled = run.fills.filter { $0.time > 20 }.map(\.fill)
        let target = jk_converter_target_fill(converter)
        let lowest = try XCTUnwrap(settled.min()), highest = try XCTUnwrap(settled.max())
        // The fill moves by one write between reads; its average stays at the target.
        XCTAssertLessThan(highest - lowest, Double(clocks.writeFrames) + 64, "fill range \(lowest)…\(highest)")
        let average = settled.reduce(0, +) / Double(settled.count)
        XCTAssertEqual(average, target, accuracy: 32, "average fill against the target")
        let early = run.fills.filter { $0.time > 20 && $0.time < 30 }.map(\.fill)
        let late = run.fills.filter { $0.time > 110 }.map(\.fill)
        XCTAssertEqual(early.reduce(0, +) / Double(early.count), late.reduce(0, +) / Double(late.count), accuracy: 8,
                       "no creep over 90 s")
        XCTAssertEqual(jk_converter_ratio(converter), 44100 * 1.001 / 48000, accuracy: 44100.0 / 48000 * 2e-5,
                       "the ratio follows the measured clocks")
        XCTAssertEqual(jk_converter_underrun_count(converter), 0)
        XCTAssertEqual(jk_converter_overrun_count(converter), 0)
        // The delay counts the ring's buffering and the filter's: half its taps at the input rate.
        let delay = jk_converter_delay(converter)
        XCTAssertEqual(delay, (target - Double(JK_CONVERTER_TAPS) / 2) / 44100, accuracy: 1e-9)
        XCTAssertGreaterThan(delay, Double(JK_CONVERTER_TAPS) / 2 / 44100)
        clocks.drift = -0.001  // and the other way
        let slow = try XCTUnwrap(jk_converter_create(1, 44100, 48000))
        defer { jk_converter_destroy(slow) }
        let slowRun = Self.run(slow, clocks, seconds: 120) { n, _ in Float(0.5 * sin(Double(n) * 0.1)) }
        let slowFills = slowRun.fills.filter { $0.time > 20 }.map(\.fill)
        XCTAssertLessThan(try XCTUnwrap(slowFills.max()) - XCTUnwrap(slowFills.min()), Double(clocks.writeFrames) + 64)
        XCTAssertEqual(jk_converter_underrun_count(slow), 0)
    }

    /// The largest step between neighbouring output samples.
    static func largestStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    func testUnderrunsAndOverrunsFadeInsteadOfClicking() throws {
        let clocks = Clocks(inputRate: 48000, outputRate: 44100, writeFrames: 512, readFrames: 256)
        let converter = try XCTUnwrap(jk_converter_create(1, 48000, 44100))
        defer { jk_converter_destroy(converter) }
        let tone = 440.0
        func signal(_ n: Int, _: Int) -> Float { Float(0.8 * sin(2 * Double.pi * tone * Double(n) / 48000)) }
        // The source stops for 0.2 s (underrun), later the sink stops for 1.5 s while the source goes on (the ring
        // overflows), and later still the sink misses 0.15 s (it falls behind and skips ahead).
        let run = Self.run(converter, clocks, seconds: 8, signal: signal,
                           writing: { !(2...2.2).contains($0) },
                           reading: { !(4...5.5).contains($0) && !(6.5...6.65).contains($0) })
        XCTAssertGreaterThanOrEqual(jk_converter_underrun_count(converter), 1)
        XCTAssertGreaterThanOrEqual(jk_converter_overrun_count(converter), 2)
        // The steepest a 440 Hz sine at 0.8 gets between two samples at 44.1 kHz is about 0.05; a click is a jump
        // towards or from silence (up to 0.8). Fades take 64 frames: at most 0.8 / 64 on top of the sine's own slope.
        let sineStep = Float(0.8 * 2 * Double.pi * tone / 44100)
        XCTAssertLessThan(Self.largestStep(run.output), sineStep + 0.8 / 64 + 0.002)
        // Audio comes back after each interruption.
        let end = run.output.suffix(4410)
        XCTAssertGreaterThan(end.map(abs).max() ?? 0, 0.79)
        let afterUnderrun = run.output[Int(3 * 44100)..<Int(3.1 * 44100)]
        XCTAssertGreaterThan(afterUnderrun.map(abs).max() ?? 0, 0.79)
    }

    func testOddSizesStayInBounds() throws {
        // Reads longer than JK_MAX_FRAMES, writes of uneven length, empty and missing buffers.
        let converter = try XCTUnwrap(jk_converter_create(3, 96000, 44100))
        defer { jk_converter_destroy(converter) }
        let big = UInt32(JK_MAX_FRAMES) * 2
        let output = UnsafeMutablePointer<Float>.allocate(capacity: Int(big) * 3)
        defer { output.deallocate() }
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 5000 * 2)
        defer { input.deallocate() }
        input.initialize(repeating: 0.25, count: 5000 * 2)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var time = AudioTimeStamp()
        for size in [1, 7, 333, 5000, 0, 4096, 1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024] {
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(size * 8), mData: input)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)  // a stream with no data: silence
            jk_converter_write(converter, list.unsafePointer, &time)
            output.initialize(repeating: 9, count: Int(big) * 3)
            jk_converter_read(converter, output, big, big, &time)
            for c in 0..<3 {
                for f in Int(JK_MAX_FRAMES)..<Int(big) { XCTAssertEqual(output[c * Int(big) + f], 0) }
            }
            XCTAssertLessThanOrEqual((0..<Int(big) * 3).map { abs(output[$0]) }.max() ?? 0, 0.26)
        }
        jk_converter_write(converter, nil, nil)
        jk_converter_read(converter, output, big, 0, nil)
        XCTAssertNil(jk_converter_create(0, 48000, 44100))
        XCTAssertNil(jk_converter_create(2, 0, 44100))
    }

    func testRendererMixesConvertedChannelsAfterTheAggregates() throws {
        // The aggregate has one input channel; a converted stereo device follows as inputs 1 and 2.
        let converter = try XCTUnwrap(jk_converter_create(2, 44100, 48000))
        defer { jk_converter_destroy(converter) }
        let renderer = try XCTUnwrap(jk_renderer_create_converting(1, 2, 3, [0, 1, 2], [0, 0, 1], [1, 1, 0.5],
                                                                   [converter], 1))
        defer { jk_renderer_destroy(renderer) }
        let frames = 480, writeFrames = 441
        let aggregateInput = KernelTests.Buffers(streams: [1], frames: frames)
        let output = KernelTests.Buffers(streams: [2], frames: frames)
        for f in 0..<frames { aggregateInput.set(stream: 0, channel: 0, frame: f, 0.125) }
        let source = KernelTests.Buffers(streams: [2], frames: writeFrames)
        for f in 0..<writeFrames {
            source.set(stream: 0, channel: 0, frame: f, 0.25)
            source.set(stream: 0, channel: 1, frame: f, 0.5)
        }
        // 0.5 s: 50 cycles on each side, 10 ms apart.
        for cycle in 0..<50 {
            var inputTime = Self.stamp(sample: Double(cycle * writeFrames), seconds: Double(cycle) / 100)
            jk_converter_write(converter, source.list.unsafePointer, &inputTime)
            var outputTime = Self.stamp(sample: Double(cycle * frames), seconds: Double(cycle) / 100 + 0.005)
            _ = jk_renderer_ioproc(0, &outputTime, aggregateInput.list.unsafePointer, &outputTime,
                                   output.list.unsafeMutablePointer, &outputTime, UnsafeMutableRawPointer(renderer))
        }
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 100), 0.125 + 0.25, accuracy: 1e-4)
        XCTAssertEqual(output.get(stream: 0, channel: 1, frame: 100), 0.25, accuracy: 1e-4)
        XCTAssertEqual(jk_renderer_take_input_peak(renderer, 2), 0.5, accuracy: 1e-3, "converted channels are metered")
        XCTAssertEqual(jk_renderer_layout_mismatch_count(renderer), 0)
    }
}
