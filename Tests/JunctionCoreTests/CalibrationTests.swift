import Foundation
import XCTest
@testable import JunctionCore

/// A repeatable random source (SplitMix64) with Gaussian samples, for the simulated rooms' noise.
private struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-300), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

/// A made-up room: the speaker and room as known filters and a level, the sound's flight as a delay, the microphone's
/// hiss as noise, and the recording device's clock running slightly fast or slow.
private struct SimulatedRoom {
    var filters: [CalibrationFilter]
    var level = 0.0
    var delay = 0
    var noise = -80.0
    var drift = 0.0
    var seed: UInt64 = 1

    /// The known response in dB at frequencies.
    func response(_ frequencies: [Double], sampleRate: Double) -> [Double] {
        CalibrationFilter.response(of: filters, preamp: level, sampleRate: sampleRate, at: frequencies)
    }

    func record(_ played: [Double], sampleRate: Double) -> [Double] {
        var signal = played
        for biquad in filters.compactMap({ $0.coefficients(sampleRate: sampleRate) }) { signal = biquad.process(signal) }
        let gain = pow(10, level / 20)
        var recording = [Double](repeating: 0, count: played.count)
        for n in recording.indices {
            // Sample n of the recording is taken at the player's time n·(1 + drift), read between samples with a
            // Lanczos (windowed sinc) kernel.
            let time = Double(n) * (1 + drift) - Double(delay)
            if drift == 0 {
                let index = n - delay
                if index >= 0, index < signal.count { recording[n] = gain * signal[index] }
                continue
            }
            let base = Int(time.rounded(.down))
            var sum = 0.0
            for k in (base - 15)...(base + 16) where k >= 0 && k < signal.count {
                let x = time - Double(k)
                guard abs(x) < 16 else { continue }
                let kernel = x == 0 ? 1 : 16 * sin(Double.pi * x) * sin(Double.pi * x / 16) / (Double.pi * Double.pi * x * x)
                sum += signal[k] * kernel
            }
            recording[n] = gain * sum
        }
        var random = SeededRandom(state: seed)
        let amplitude = pow(10, noise / 20)
        return recording.map { $0 + amplitude * random.gaussian() }
    }
}

/// A second-order Butterworth high-pass's magnitude in dB: the speaker's own low-frequency roll-off.
private func highPass(_ frequency: Double, cutoff: Double) -> Double {
    let ratio = pow(frequency / cutoff, 4)
    return 10 * log10(ratio / (1 + ratio))
}

/// 1/96-octave points over a band, for checking curves between the grid's points.
private func dense(_ low: Double, _ high: Double) -> [Double] {
    (0...Int(log2(high / low) * 96)).map { low * pow(2, Double($0) / 96) }
}

final class CalibrationTests: XCTestCase {
    private let rate = 48_000.0

    // MARK: Filters

    func testCoefficientsMatchTheCookbook() throws {
        // Worked out separately from the published formulae.
        let cases: [(CalibrationFilter, Double, [Double])] = [
            (CalibrationFilter(.peaking, frequency: 1000, gain: 6, q: 1), 48_000,
             [1.043953086990, -1.895320723937, 0.867722284760, -1.895320723937, 0.911675371750]),
            (CalibrationFilter(.lowShelf, frequency: 100, gain: -4), 44_100,
             [0.997677897572, -1.977439977918, 0.979921516965, -1.977393351222, 0.977646041233]),
            (CalibrationFilter(.highShelf, frequency: 8000, gain: 3), 96_000,
             [1.327279882166, -1.771448848238, 0.671953838362, -1.220826978259, 0.448611850550]),
        ]
        for (filter, sampleRate, expected) in cases {
            let biquad = try XCTUnwrap(filter.coefficients(sampleRate: sampleRate))
            for (value, known) in zip([biquad.b0, biquad.b1, biquad.b2, biquad.a1, biquad.a2], expected) {
                XCTAssertEqual(value, known, accuracy: 1e-9, "\(filter.kind)")
            }
        }
        let peak = try XCTUnwrap(cases[0].0.coefficients(sampleRate: 48_000))
        XCTAssertEqual(peak.gain(at: 1000, sampleRate: 48_000), 6, accuracy: 1e-9)
        XCTAssertEqual(peak.gain(at: 20, sampleRate: 48_000), 0, accuracy: 0.05)
        let shelf = try XCTUnwrap(cases[1].0.coefficients(sampleRate: 44_100))
        XCTAssertEqual(shelf.gain(at: 1, sampleRate: 44_100), -4, accuracy: 0.01)
        XCTAssertEqual(shelf.gain(at: 100, sampleRate: 44_100), -2, accuracy: 0.01)
        XCTAssertEqual(shelf.gain(at: 20_000, sampleRate: 44_100), 0, accuracy: 0.01)
    }

    func testLowPassMatchesTheCookbook() throws {
        // Worked out separately from the published formulae (the first is the textbook second-order Butterworth at
        // 1 kHz, 48 kHz).
        let cases: [(CalibrationFilter, Double, [Double])] = [
            (CalibrationFilter(.lowPass, frequency: 1000, gain: 0), 48_000,
             [0.003916126661, 0.007832253321, 0.003916126661, -1.815341082705, 0.831005589347]),
            (CalibrationFilter(.lowPass, frequency: 8000, gain: 0), 44_100,
             [0.177245025541, 0.354490051083, 0.177245025541, -0.508717528105, 0.217697630271]),
            (CalibrationFilter(.lowPass, frequency: 12_000, gain: 0, q: 0.5), 96_000,
             [0.085786437627, 0.171572875254, 0.085786437627, -0.828427124746, 0.171572875254]),
        ]
        for (filter, sampleRate, expected) in cases {
            let biquad = try XCTUnwrap(filter.coefficients(sampleRate: sampleRate))
            for (value, known) in zip([biquad.b0, biquad.b1, biquad.b2, biquad.a1, biquad.a2], expected) {
                XCTAssertEqual(value, known, accuracy: 1e-9, "\(filter.frequency) Hz at \(sampleRate) Hz")
            }
        }
        // Flat below, −3 dB at the cutoff (Q 0.707), 12 dB per octave above; its gain plays no part.
        let lowPass = try XCTUnwrap(cases[0].0.coefficients(sampleRate: 48_000))
        XCTAssertEqual(lowPass.gain(at: 20, sampleRate: 48_000), 0, accuracy: 0.001)
        XCTAssertEqual(lowPass.gain(at: 1000, sampleRate: 48_000), 20 * log10(1 / 2.0.squareRoot()), accuracy: 1e-9)
        XCTAssertEqual(lowPass.gain(at: 4000, sampleRate: 48_000) - lowPass.gain(at: 2000, sampleRate: 48_000), -12, accuracy: 0.2)
        XCTAssertEqual(CalibrationFilter(.lowPass, frequency: 1000, gain: 6).coefficients(sampleRate: 48_000), lowPass)
        XCTAssertNil(CalibrationFilter(.lowPass, frequency: 24_000, gain: 0).coefficients(sampleRate: 48_000))
        XCTAssertNil(CalibrationFilter(.lowPass, frequency: 1000, gain: 0, isOn: false).coefficients(sampleRate: 48_000))
        // The response it processes is the one computed.
        for frequency in [500.0, 1000, 3000] {
            let input = (0..<9600).map { sin(2 * Double.pi * frequency * Double($0) / rate) }
            let output = lowPass.process(input).suffix(4800)
            let rms = (output.reduce(0) { $0 + $1 * $1 } / Double(output.count)).squareRoot()
            XCTAssertEqual(20 * log10(rms * 2.0.squareRoot()), lowPass.gain(at: frequency, sampleRate: rate), accuracy: 0.05)
        }
        // Saved by its kind's name.
        let json = try JSONEncoder().encode(cases[2].0)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#""kind":"lowPass""#))
        XCTAssertEqual(try JSONDecoder().decode(CalibrationFilter.self, from: json), cases[2].0)
    }

    func testFiltersAtOrAboveNyquistAreDropped() {
        let filters = [CalibrationFilter(.peaking, frequency: 1000, gain: 3, q: 1),
                       CalibrationFilter(.highShelf, frequency: 22_050, gain: 3),
                       CalibrationFilter(.peaking, frequency: 30_000, gain: -3, q: 2),
                       CalibrationFilter(.peaking, frequency: 500, gain: -3, q: 2, isOn: false)]
        XCTAssertNil(filters[1].coefficients(sampleRate: 44_100))
        XCTAssertNotNil(filters[1].coefficients(sampleRate: 48_000))
        XCTAssertNil(filters[3].coefficients(sampleRate: 48_000))
        let profile = CalibrationProfile(name: "Test", kind: .headphones, channels: [CalibrationChannel(filters: filters)],
                                         preamp: -3)
        XCTAssertEqual(profile.coefficients(channel: 0, sampleRate: 44_100).count, 1)
        XCTAssertEqual(profile.coefficients(channel: 5, sampleRate: 48_000).count, 2)
        XCTAssertEqual(profile.coefficients(channel: 0, sampleRate: 96_000).count, 3)
        // The combined curve: preamp plus the filters the rate carries.
        XCTAssertEqual(profile.curve(channel: 0, sampleRate: 44_100, at: [1000])[0], 0, accuracy: 1e-9)
    }

    func testBiquadProcessingMatchesItsResponse() throws {
        let filter = CalibrationFilter(.peaking, frequency: 2000, gain: -7, q: 2)
        let biquad = try XCTUnwrap(filter.coefficients(sampleRate: rate))
        for frequency in [500.0, 1800, 2000, 4000] {
            let input = (0..<9600).map { sin(2 * Double.pi * frequency * Double($0) / rate) }
            let output = biquad.process(input).suffix(4800)
            let rms = (output.reduce(0) { $0 + $1 * $1 } / Double(output.count)).squareRoot()
            XCTAssertEqual(20 * log10(rms * 2.0.squareRoot()), biquad.gain(at: frequency, sampleRate: rate), accuracy: 0.05)
        }
    }

    // MARK: Sweeps

    func testSweepCoversTheBandAndIsFadedWithSilenceAround() {
        let sweep = CalibrationSweep(sampleRate: rate, duration: 2, leadSilence: 0.25, tail: 1)
        XCTAssertEqual(sweep.samples.count, Int(3.25 * rate))
        XCTAssertEqual(sweep.startFrequency, 20)
        XCTAssertEqual(sweep.endFrequency, 20_000)
        XCTAssertEqual(CalibrationSweep(sampleRate: 44_100).endFrequency, 19_845, accuracy: 1e-9)
        XCTAssertEqual(CalibrationSweep(sampleRate: 32_000).endFrequency, 14_400, accuracy: 1e-9)
        let lead = Int(0.25 * rate), end = lead + Int(2 * rate)
        XCTAssertTrue(sweep.samples[..<lead].allSatisfy { $0 == 0 })
        XCTAssertTrue(sweep.samples[end...].allSatisfy { $0 == 0 })
        XCTAssertLessThan(abs(sweep.samples[lead + 1]), 0.01)  // faded in
        XCTAssertLessThan(abs(sweep.samples[end - 1]), 0.01)  // and out
        XCTAssertLessThanOrEqual(sweep.samples.map(abs).max() ?? 0, 0.5)
        // Exponential: halfway through, the frequency is the band's geometric middle (zero crossings over 20 ms).
        let middle = lead + Int(rate)
        let window = sweep.samples[(middle - 480)..<(middle + 480)]
        let crossings = zip(window, window.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings) / 0.02, (20.0 * 20_000).squareRoot(), accuracy: 60)
    }

    func testInverseFilterTurnsTheSweepIntoAnImpulse() {
        let sweep = CalibrationSweep(sampleRate: rate, duration: 1, leadSilence: 0.1, tail: 0.2)
        let inverse = sweep.inverseFilter()
        XCTAssertEqual(inverse.count, sweep.samples.count)
        let fft = CalibrationFFT(count: CalibrationFFT.size(atLeast: 2 * inverse.count))
        var a = fft.spectrum(of: sweep.samples), b = fft.spectrum(of: inverse)
        for k in 0..<fft.count {
            (a.real[k], a.imaginary[k]) = (a.real[k] * b.real[k] - a.imaginary[k] * b.imaginary[k],
                                           a.real[k] * b.imaginary[k] + a.imaginary[k] * b.real[k])
        }
        fft.inverse(&a.real, &a.imaginary)
        let impulse = a.real
        XCTAssertEqual(CalibrationAnalysis.arrival(in: impulse, sampleRate: rate), Double(inverse.count - 1), accuracy: 0.5)
        let response = CalibrationAnalysis.response(of: impulse, sampleRate: rate, arrival: Double(inverse.count - 1))
        for (frequency, level) in zip(response.frequencies, response.levels) where (30...16_000).contains(frequency) {
            XCTAssertEqual(level, 0, accuracy: 0.2, "\(frequency) Hz")
        }
    }

    private let room = SimulatedRoom(filters: [
        CalibrationFilter(.peaking, frequency: 50, gain: 6, q: 4),
        CalibrationFilter(.peaking, frequency: 180, gain: -5, q: 2),
        CalibrationFilter(.peaking, frequency: 1200, gain: 3, q: 1.5),
        CalibrationFilter(.peaking, frequency: 3000, gain: -3, q: 3),
        CalibrationFilter(.highShelf, frequency: 6000, gain: -4),
    ], level: -12, delay: 517, noise: -75)

    private func assertMeasured(_ room: SimulatedRoom, file: StaticString = #filePath, line: UInt = #line) {
        let sweep = CalibrationSweep(sampleRate: rate, duration: 2, leadSilence: 0.25, tail: 1)
        let capture = CalibrationCapture(recording: room.record(sweep.samples, sampleRate: rate), sweep: sweep)
        if room.drift == 0 {
            XCTAssertEqual(capture.arrival * rate, Double(room.delay), accuracy: 1, file: file, line: line)
        }
        let measured = capture.curve.smoothed(.sixth)
        let expected = CalibrationCurve(levels: room.response(CalibrationGrid.frequencies, sampleRate: rate)).smoothed(.sixth)
        var worst = 0.0
        for i in measured.frequencies.indices where (30...16_000).contains(measured.frequencies[i]) {
            worst = max(worst, abs(measured.levels[i] - expected.levels[i]))
        }
        XCTAssertLessThanOrEqual(worst, 0.5, file: file, line: line)
    }

    func testSweepThroughARoomGivesItsResponseAndDelay() {
        assertMeasured(room)
    }

    func testClockDriftAndNoiseLeaveTheResponse() {
        var drifting = room
        drifting.drift = 20e-6
        drifting.noise = -60
        drifting.seed = 7
        assertMeasured(drifting)
    }

    func testDistortionStaysOutOfTheResponse() {
        let sweep = CalibrationSweep(sampleRate: rate, duration: 2, leadSilence: 0.25, tail: 1)
        // A soft-clipping speaker: about 1 % third harmonic at full level.
        let recording = sweep.samples.map { $0 - 0.04 * $0 * $0 * $0 }
        let curve = CalibrationCapture(recording: recording, sweep: sweep).curve.smoothed(.sixth)
        for (frequency, level) in zip(curve.frequencies, curve.levels) where (30...16_000).contains(frequency) {
            XCTAssertEqual(level, 20 * log10(1 - 0.03 * 0.25), accuracy: 0.1, "\(frequency) Hz")
        }
    }

    // MARK: Smoothing, averaging and levels

    func testSmoothingAveragesPowerOverTheBand() {
        let frequencies = (0...(7 * 768)).map { 100 * pow(2, Double($0) / 768) }
        let step = CalibrationCurve(frequencies: frequencies, levels: frequencies.map { $0 < 1000 ? 0 : -10 })
        for smoothing in CalibrationSmoothing.allCases {
            let smoothed = step.smoothed(smoothing)
            // Right at the step, half the band is at 0 dB and half at −10 dB.
            XCTAssertEqual(smoothed.level(at: 1000), 10 * log10(0.55), accuracy: 0.25, smoothing.title)
            // Farther than half the width from it, nothing changes.
            let half = 1 / Double(smoothing.rawValue) / 2
            XCTAssertEqual(smoothed.level(at: 1000 * pow(2, -half - 0.03)), 0, accuracy: 1e-9)
            XCTAssertEqual(smoothed.level(at: 1000 * pow(2, half + 0.03)), -10, accuracy: 1e-9)
        }
        // A narrow peak is spread further by wider smoothing; a flat curve stays flat.
        let peak = CalibrationCurve(frequencies: frequencies, levels: frequencies.map { abs(log2($0 / 1000)) < 0.02 ? 12 : 0 })
        let levels = CalibrationSmoothing.allCases.map { peak.smoothed($0).level(at: 1000) }
        XCTAssertLessThan(levels[0], levels[1])
        XCTAssertLessThan(levels[1], levels[2])
        let flat = CalibrationCurve(levels: [Double](repeating: -3, count: CalibrationGrid.count))
        XCTAssertTrue(flat.smoothed(.third).levels.allSatisfy { abs($0 + 3) < 1e-9 })
    }

    func testPositionsAreLevelMatchedThenPowerAveraged() {
        let grid = CalibrationGrid.frequencies
        let shape = grid.map { 3 * sin(log2($0)) }
        let near = CalibrationCurve(levels: shape.map { $0 + 6 })
        let far = CalibrationCurve(levels: shape.map { $0 - 6 })
        let average = CalibrationAnalysis.average([near, far])
        for (level, expected) in zip(average.levels, shape) { XCTAssertEqual(level, expected, accuracy: 1e-9) }
        XCTAssertEqual(CalibrationAnalysis.level(of: average), CalibrationAnalysis.level(of: CalibrationCurve(levels: shape)),
                       accuracy: 1e-9)
        // A null at one position is filled by the other: power average of 1 and nearly 0.
        let null = grid.firstIndex { $0 > 100 }!
        var first = [Double](repeating: 0, count: grid.count), second = first
        first[null] = -40
        second[null + 30] = -40
        let filled = CalibrationAnalysis.average([CalibrationCurve(levels: first), CalibrationCurve(levels: second)])
        XCTAssertEqual(filled.levels[null], 10 * log10((1 + 1e-4) / 2), accuracy: 0.01)
        XCTAssertEqual(filled.levels[null + 30], 10 * log10((1 + 1e-4) / 2), accuracy: 0.01)
        XCTAssertEqual(filled.levels[null + 15], 0, accuracy: 1e-9)
    }

    func testChannelLevelIsTheMidrangePower() {
        let grid = CalibrationGrid.frequencies
        XCTAssertEqual(CalibrationAnalysis.level(of: CalibrationCurve(levels: grid.map { _ in -12 })), -12, accuracy: 1e-9)
        // Outside the midrange doesn't count.
        let bassy = CalibrationCurve(levels: grid.map { $0 < 200 ? 10 : -12 })
        XCTAssertEqual(CalibrationAnalysis.level(of: bassy), -12, accuracy: 1e-9)
    }

    // MARK: Fitting

    /// A speaker rolling off below 28 Hz in a room with modes, a dip and a dull top: all within what EQ can fix.
    private func fixableRoom(_ frequencies: [Double]) -> [Double] {
        let filters = [CalibrationFilter(.peaking, frequency: 55, gain: 8, q: 5),
                       CalibrationFilter(.peaking, frequency: 130, gain: 5, q: 4),
                       CalibrationFilter(.peaking, frequency: 300, gain: -4, q: 1.5),
                       CalibrationFilter(.peaking, frequency: 2500, gain: 3, q: 2),
                       CalibrationFilter(.highShelf, frequency: 8000, gain: -3)]
        let room = CalibrationFilter.response(of: filters, preamp: 7, sampleRate: rate, at: frequencies)
        return zip(frequencies, room).map { highPass($0, cutoff: 28) + $1 }
    }

    private func assertFit(_ fit: CalibrationFit, reaches target: CalibrationTarget, limits: CalibrationLimits,
                           tolerance: Double = 1, file: StaticString = #filePath, line: UInt = #line) {
        for (frequency, level) in zip(fit.corrected.frequencies, fit.corrected.levels) where fit.range.contains(frequency) {
            XCTAssertEqual(level, target.level(at: frequency), accuracy: tolerance, "\(frequency) Hz",
                           file: file, line: line)
        }
        assertWithinLimits(fit.filters, limits, file: file, line: line)
        XCTAssertLessThanOrEqual(fit.filters.count, limits.filterCount, file: file, line: line)
    }

    private func assertWithinLimits(_ filters: [CalibrationFilter], _ limits: CalibrationLimits,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let curve = CalibrationFilter.response(of: filters, sampleRate: rate, at: dense(20, 20_000))
        XCTAssertLessThanOrEqual(curve.max() ?? 0, limits.maxBoost + 1e-9, file: file, line: line)
        XCTAssertGreaterThanOrEqual(curve.min() ?? 0, -limits.maxCut - 1e-9, file: file, line: line)
        let preamp = CalibrationFitter.preamp(for: [filters], sampleRate: rate)
        XCTAssertLessThanOrEqual(preamp, 0, file: file, line: line)
        let combined = CalibrationFilter.response(of: filters, preamp: preamp, sampleRate: rate, at: dense(10, 23_900))
        XCTAssertLessThanOrEqual(combined.max() ?? 0, 1e-9, file: file, line: line)
    }

    func testFittingAFixableRoomReachesTheTarget() {
        let measured = CalibrationCurve(levels: fixableRoom(CalibrationGrid.frequencies))
        let limits = CalibrationLimits()
        let fit = CalibrationFitter.fit(measured, limits: limits, sampleRate: rate)
        XCTAssertEqual(fit.offset, 7, accuracy: 1)
        // The low limit is the speaker's −6 dB point, a little below its 28 Hz cut-off; the top is 20 kHz.
        XCTAssertEqual(fit.range.lowerBound, 28 / pow(3, 0.25), accuracy: 3)
        XCTAssertEqual(fit.range.upperBound, 20_000)
        assertFit(fit, reaches: .flat, limits: limits)
        XCTAssertGreaterThan(CalibrationFitter.preamp(for: [fit.filters], sampleRate: rate), -6.01)
    }

    func testFittingFollowsATiltedTargetWithShelves() {
        let target = CalibrationTarget(tilt: -0.5, lowShelf: .init(frequency: 100, gain: 4),
                                       highShelf: .init(frequency: 10_000, gain: -2))
        XCTAssertEqual(target.level(at: 1000), 0, accuracy: 0.05)
        let shelf = CalibrationFilter(.highShelf, frequency: 10_000, gain: -2).coefficients(sampleRate: 384_000)!
        XCTAssertEqual(target.level(at: 4000), -1 + shelf.gain(at: 4000, sampleRate: 384_000), accuracy: 0.01)
        XCTAssertEqual(CalibrationTarget.flat.level(at: 50), 0)
        let measured = CalibrationCurve(levels: fixableRoom(CalibrationGrid.frequencies))
        let limits = CalibrationLimits(lowFrequency: 40, maxBoost: 8)
        let fit = CalibrationFitter.fit(measured, target: target, limits: limits, sampleRate: rate)
        XCTAssertEqual(fit.range.lowerBound, 40)
        assertFit(fit, reaches: target, limits: limits)
    }

    func testLimitsAreNeverExceeded() {
        let grid = CalibrationGrid.frequencies
        // A huge peak, a wide deep hole and a falling top: more than the limits allow.
        let filters = [CalibrationFilter(.peaking, frequency: 80, gain: 20, q: 2),
                       CalibrationFilter(.peaking, frequency: 600, gain: -14, q: 0.7),
                       CalibrationFilter(.highShelf, frequency: 5000, gain: -12)]
        let measured = CalibrationCurve(levels: CalibrationFilter.response(of: filters, sampleRate: rate, at: grid))
        for limits in [CalibrationLimits(), CalibrationLimits(maxBoost: 3, maxCut: 10, filterCount: 32),
                       CalibrationLimits(maxBoost: 0, maxCut: 6, filterCount: 4)] {
            let fit = CalibrationFitter.fit(measured, limits: limits, sampleRate: rate)
            assertWithinLimits(fit.filters, limits)
            XCTAssertLessThanOrEqual(fit.filters.count, limits.filterCount)
            XCTAssertTrue(fit.filters.allSatisfy { $0.gain <= limits.maxBoost + 1e-9 && $0.gain >= -limits.maxCut - 1e-9 })
        }
    }

    func testADeepNarrowNullIsLeftAlone() {
        let grid = CalibrationGrid.frequencies
        // A room null: 25 dB deep at 120 Hz, a tenth of an octave wide at −6 dB.
        let peak = CalibrationFilter(.peaking, frequency: 6000, gain: 5, q: 2)
        let levels = zip(grid, CalibrationFilter.response(of: [peak], sampleRate: rate, at: grid)).map { frequency, level in
            level - 25 * exp(-pow(log2(frequency / 120) / 0.06, 2))
        }
        let measured = CalibrationCurve(levels: levels)
        let fit = CalibrationFitter.fit(measured, limits: CalibrationLimits(lowFrequency: 20), sampleRate: rate)
        let correction = CalibrationFilter.response(of: fit.filters, sampleRate: rate, at: dense(80, 180))
        XCTAssertLessThanOrEqual(correction.max() ?? 0, 0.5)
        // The peak elsewhere is still taken out.
        XCTAssertEqual(fit.offset, 0, accuracy: 0.1)
        XCTAssertEqual(CalibrationFilter.response(of: fit.filters, sampleRate: rate, at: [6000])[0], -5, accuracy: 1)
    }

    func testMinusSixPointAndAlignment() {
        let grid = CalibrationGrid.frequencies
        let rolloff = CalibrationCurve(levels: grid.map { highPass($0, cutoff: 50) })
        XCTAssertEqual(CalibrationFitter.minusSixPoint(rolloff), 50 / pow(3, 0.25), accuracy: 2)
        XCTAssertEqual(CalibrationFitter.minusSixPoint(CalibrationCurve(levels: grid.map { _ in 0 })), 20)

        let aligned = CalibrationFitter.alignment(arrivals: [0.010, 0.0125, 0.011], levels: [-20, -23, -21])
        XCTAssertEqual(aligned.map(\.delay), [0.0025, 0, 0.0015], accuracy: 1e-12)
        XCTAssertEqual(aligned.map(\.level), [-3, 0, -2], accuracy: 1e-12)
    }

    // MARK: Profiles

    func testSpeakerProfileFromSweepsAtSeveralPositions() throws {
        let sweep = CalibrationSweep(sampleRate: rate, duration: 1.5, leadSilence: 0.2, tail: 0.6)
        let left = SimulatedRoom(filters: [CalibrationFilter(.peaking, frequency: 70, gain: 7, q: 4)], level: -10,
                                 delay: 300, noise: -80)
        let right = SimulatedRoom(filters: [CalibrationFilter(.peaking, frequency: 90, gain: 5, q: 3)], level: -13,
                                  delay: 348, noise: -80, seed: 2)
        func capture(_ room: SimulatedRoom, moved: Int) -> CalibrationCapture {
            var room = room
            room.delay += moved
            room.seed += UInt64(moved)
            return CalibrationCapture(recording: room.record(sweep.samples, sampleRate: rate), sweep: sweep)
        }
        let captures = [[capture(left, moved: 0), capture(left, moved: 20)],
                        [capture(right, moved: 0), capture(right, moved: 9)]]
        let profile = CalibrationProfile.speakers(name: "Desk", deviceUID: "speakers-uid", deviceName: "Desk Speakers",
                                                  captures: captures, micCalibration: "Measuring Mic",
                                                  sampleRate: rate)
        XCTAssertEqual(profile.kind, .speakers)
        XCTAssertEqual(profile.channels.count, 2)
        // The left speaker is 48 samples nearer and 3 dB louder.
        XCTAssertEqual(profile.channels[0].delay * rate, 48, accuracy: 1)
        XCTAssertEqual(profile.channels[1].delay, 0)
        XCTAssertEqual(profile.channels[0].level, -3, accuracy: 0.3)
        XCTAssertEqual(profile.channels[1].level, 0)
        XCTAssertLessThanOrEqual(profile.preamp, 0)
        XCTAssertEqual(profile.measurements.count, 6)
        XCTAssertTrue(profile.measurements.allSatisfy { $0.levels.count == CalibrationGrid.count })
        XCTAssertEqual(profile.measurements.filter { $0.position == nil }.map(\.channel), [0, 1])
        // Each channel's mode is taken out.
        for (channel, room) in [left, right].enumerated() {
            let mode = room.filters[0]
            let correction = profile.curve(channel: channel, sampleRate: rate, at: [mode.frequency])[0]
                - profile.preamp - profile.channels[channel].level
            XCTAssertEqual(correction, -mode.gain, accuracy: 1)
        }

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationProfile.self, from: data), profile)
    }

    func testProfilesStaySmall() throws {
        var random = SeededRandom(state: 3)
        var measurements: [CalibrationMeasurement] = []
        for channel in 0..<2 {
            for position in [0, 1, 2, 3, 4, 5, 6, 7, 8, nil] {
                let levels = (0..<CalibrationGrid.count).map { _ in -60 + 40 * random.uniform() }
                measurements.append(CalibrationMeasurement(channel: channel, position: position,
                                                           curve: CalibrationCurve(levels: levels)))
            }
        }
        let filters = (0..<CalibrationLimits.maximumFilters).map {
            CalibrationFilter(.peaking, frequency: 20 * pow(1.2, Double($0)), gain: -3.3333333, q: 1.4142135)
        }
        let profile = CalibrationProfile(name: "Living Room", kind: .speakers, channels: [CalibrationChannel(filters: filters),
                                         CalibrationChannel(filters: filters, delay: 0.000_123_4, level: -1.25)],
                                         preamp: -6.2, measurements: measurements)
        let data = try JSONEncoder().encode(profile)
        XCTAssertLessThan(data.count, 64 * 1024)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationProfile.self, from: data), profile)
        // Levels are kept to 0.01 dB.
        XCTAssertTrue(profile.measurements[0].levels.allSatisfy { abs($0 * 100 - ($0 * 100).rounded()) < 1e-6 })
    }

    func testFilterDecodesAsOnWhenTheFieldIsMissing() throws {
        let json = #"{"kind":"lowShelf","frequency":105,"gain":5.5,"q":0.71}"#
        let filter = try JSONDecoder().decode(CalibrationFilter.self, from: Data(json.utf8))
        XCTAssertEqual(filter, CalibrationFilter(.lowShelf, frequency: 105, gain: 5.5, q: 0.71))
    }

    // MARK: Text files

    func testMicrophoneCalibrationFile() throws {
        let text = "\"Sens Factor =-1.378dB, SERNO: 1234567\"\r\n* made-up microphone\r\n# comment\r\nFreq(Hz)\tdB\tPhase\r\n"
            + "10\t-3.2\t12.5\r\n\r\n1000, 0.0, 0\r\n  20000 ; 2.5 \r\n100 -0.5\r\n"
        let mic = try MicCalibration(name: "Measuring Mic", text: text)
        XCTAssertEqual(mic.sensitivity, -1.378)
        XCTAssertEqual(mic.curve.frequencies, [10, 100, 1000, 20_000])
        XCTAssertEqual(mic.curve.levels, [-3.2, -0.5, 0, 2.5])
        let measured = CalibrationCurve(frequencies: [5, 100, 1000, 25_000], levels: [1, 1, 1, 1])
        XCTAssertEqual(mic.corrected(measured).levels, [4.2, 1.5, 1, -1.5])

        let plain = try MicCalibration(name: "Plain", text: "Sensitivity: -18.25 dB\n20 0.1\n20000 -0.2\n")
        XCTAssertEqual(plain.sensitivity, -18.25)
        XCTAssertNil(try MicCalibration(name: "None", text: "20 0\n20000 0\n").sensitivity)
    }

    func testUnreadableFilesSayWhy() throws {
        XCTAssertThrowsError(try MicCalibration(name: "Empty", text: "* nothing here\n")) {
            XCTAssertEqual($0 as? CalibrationFileError, .noData("Empty"))
        }
        XCTAssertThrowsError(try MicCalibration(name: "One", text: "1000 0\n")) {
            XCTAssertEqual($0 as? CalibrationFileError, .noData("One"))
        }
        XCTAssertThrowsError(try MicCalibration(name: "Broken", text: "20 0\n100 loud\n")) {
            XCTAssertEqual($0 as? CalibrationFileError, .badLine("Broken", line: 2, text: "100 loud"))
        }
        XCTAssertThrowsError(try MicCalibration(name: "Negative", text: "20 0\n-100 1\n")) {
            XCTAssertEqual($0 as? CalibrationFileError, .badLine("Negative", line: 2, text: "-100 1"))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("mic.cal")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0xFF]).write(to: binary)
        XCTAssertThrowsError(try MicCalibration(contentsOf: binary)) {
            XCTAssertEqual($0 as? CalibrationFileError, .notText("mic.cal"))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "“mic.cal” isn't a text file.")
        }
        let latin = folder.appendingPathComponent("Mic 2.txt")
        try Data("* Mikrofon \u{E9}\n20 0\n20000 1\n".data(using: .isoLatin1)!).write(to: latin)
        let mic = try MicCalibration(contentsOf: latin)
        XCTAssertEqual(mic.name, "Mic 2")
        XCTAssertEqual(mic.curve.levels, [0, 1])
        for error in [CalibrationFileError.noData("a"), .badLine("a", line: 3, text: "x"), .unsupportedFilter("a", line: 1, type: "LP")] {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }

    func testMeasurementExportImportsOntoTheGrid() throws {
        var lines = ["* Measurement data exported as text", "* Freq(Hz) SPL(dB) Phase(degrees)"]
        for k in 0...200 {
            let frequency = 10 * pow(2400.0, Double(k) / 200)
            lines.append(String(format: "%.3f %.3f %.1f", frequency, 75 + 2 * log2(frequency / 1000), -90.0))
        }
        let curve = try CalibrationCurve(measurementText: lines.joined(separator: "\n"), name: "Left.txt")
        XCTAssertEqual(curve.frequencies, CalibrationGrid.frequencies)
        for (frequency, level) in zip(curve.frequencies, curve.levels) {
            XCTAssertEqual(level, 75 + 2 * log2(min(frequency, 24_000) / 1000), accuracy: 0.01)
        }
        let profile = CalibrationProfile.imported(name: "Imported", measurement: curve, sampleRate: rate)
        XCTAssertEqual(profile.kind, .imported)
        XCTAssertEqual(profile.measurements.count, 1)
        XCTAssertLessThanOrEqual(profile.preamp, 0)
    }

    func testParametricPresetsAreRead() throws {
        let text = """
        # Made-up headphones
        Preamp: -6.2dB
        Filter 1: ON PK Fc 105 Hz Gain -3.4 dB Q 1.41
        Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
        Filter 3: ON HSC Fc 10000 Hz Gain -2 dB Q 0.7
        Filter 4: OFF PK Fc 3000 Hz Gain 4 dB Q 2
        Filter 5: ON LS Fc 80 Hz Gain 3 dB
        Filter 6: ON HS 6dB Fc 8000 Hz Gain -4 dB
        Filter 7: ON LS 12 dB Fc 60 Hz Gain 2 dB
        filter 8: on pk fc 1500 hz gain 1.5 db bw oct 1
        Filter 9: ON None
        Filter 10: OFF LP Fc 18000 Hz
        Filter 11: OFF HP Fc 20 Hz
        Filter 12: ON LPQ Fc 12000 Hz Q 0.5
        Filter: ON PK Fc 250 Hz Gain -1 dB Q 4
        Channel: all
        """
        let preset = try ParametricPreset(text: text.replacingOccurrences(of: "\n", with: "\r\n"), name: "Phones.txt")
        XCTAssertEqual(preset.preamp, -6.2)
        let expected = [
            CalibrationFilter(.peaking, frequency: 105, gain: -3.4, q: 1.41),
            CalibrationFilter(.lowShelf, frequency: 105, gain: 5.5, q: 0.71),
            CalibrationFilter(.highShelf, frequency: 10_000, gain: -2, q: 0.7),
            CalibrationFilter(.peaking, frequency: 3000, gain: 4, q: 2, isOn: false),
            CalibrationFilter(.lowShelf, frequency: 80, gain: 3),
            CalibrationFilter(.highShelf, frequency: 8000, gain: -4, q: CalibrationFilter.shelfQ(slope: 0.5, gain: -4)),
            CalibrationFilter(.lowShelf, frequency: 60, gain: 2, q: CalibrationFilter.shelfQ(slope: 1, gain: 2)),
            CalibrationFilter(.peaking, frequency: 1500, gain: 1.5, q: 2.0.squareRoot()),
            CalibrationFilter(.lowPass, frequency: 18_000, gain: 0, isOn: false),
            CalibrationFilter(.lowPass, frequency: 12_000, gain: 0, q: 0.5),
            CalibrationFilter(.peaking, frequency: 250, gain: -1, q: 4),
        ]
        XCTAssertEqual(preset.filters.count, expected.count)
        for (filter, known) in zip(preset.filters, expected) {
            XCTAssertEqual(filter.kind, known.kind)
            XCTAssertEqual(filter.frequency, known.frequency)
            XCTAssertEqual(filter.gain, known.gain)
            XCTAssertEqual(filter.q, known.q, accuracy: 1e-9)
            XCTAssertEqual(filter.isOn, known.isOn)
        }
        // Slope 1 at small gains is about Q 0.707; a gentler slope is a lower Q.
        XCTAssertEqual(CalibrationFilter.shelfQ(slope: 1, gain: 0), 1 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertLessThan(CalibrationFilter.shelfQ(slope: 0.5, gain: -4), 0.6)

        let profile = CalibrationProfile(name: "Phones", preset: preset)
        XCTAssertEqual(profile.kind, .headphones)
        XCTAssertEqual(profile.preamp, -6.2)
        XCTAssertEqual(profile.channel(1).filters, preset.filters)
        XCTAssertEqual(profile.preset(), preset)
    }

    func testBrokenPresetsSayWhy() {
        XCTAssertThrowsError(try ParametricPreset(text: "Hello\nNothing: here\n", name: "Empty.txt")) {
            XCTAssertEqual($0 as? CalibrationFileError, .noData("Empty.txt"))
        }
        XCTAssertThrowsError(try ParametricPreset(text: "Preamp: -3 dB\nFilter 1: ON HP Fc 100 Hz\n", name: "HP.txt")) {
            XCTAssertEqual($0 as? CalibrationFileError, .unsupportedFilter("HP.txt", line: 2, type: "HP"))
        }
        // Low-passes are second order (12 dB per octave) only.
        XCTAssertThrowsError(try ParametricPreset(text: "Filter 1: ON LP 24dB Fc 9000 Hz\n", name: "LP.txt")) {
            XCTAssertEqual($0 as? CalibrationFileError, .unsupportedFilter("LP.txt", line: 1, type: "24 dB/octave LP"))
        }
        XCTAssertEqual(try ParametricPreset(text: "Filter 1: ON LP 12dB Fc 9000 Hz\n", name: "LP12.txt").filters,
                       [CalibrationFilter(.lowPass, frequency: 9000, gain: 0)])
        XCTAssertThrowsError(try ParametricPreset(text: "Filter 1: ON LPQ Q 0.7\n", name: "NoFc.txt")) {
            XCTAssertEqual($0 as? CalibrationFileError, .badLine("NoFc.txt", line: 1, text: "Filter 1: ON LPQ Q 0.7"))
        }
        XCTAssertThrowsError(try ParametricPreset(text: "Filter 1: ON PK Fc 100 Hz Gain -3 dB\n", name: "NoQ.txt")) {
            XCTAssertEqual($0 as? CalibrationFileError,
                           .badLine("NoQ.txt", line: 1, text: "Filter 1: ON PK Fc 100 Hz Gain -3 dB"))
        }
        XCTAssertThrowsError(try ParametricPreset(text: "Filter 1: MAYBE PK Fc 100 Hz Gain -3 dB Q 1\n", name: "a")) {
            XCTAssertEqual($0 as? CalibrationFileError, .badLine("a", line: 1, text: "Filter 1: MAYBE PK Fc 100 Hz Gain -3 dB Q 1"))
        }
        XCTAssertThrowsError(try ParametricPreset(text: "Preamp: loud\n", name: "b")) {
            XCTAssertEqual($0 as? CalibrationFileError, .badLine("b", line: 1, text: "Preamp: loud"))
        }
        // A preamp alone is a preset.
        XCTAssertEqual(try ParametricPreset(text: "Preamp: -3 dB", name: "c"), ParametricPreset(preamp: -3, filters: []))
    }

    func testPresetExportThenImportRoundTrips() throws {
        let filters = [CalibrationFilter(.lowShelf, frequency: 31.26, gain: 4.04, q: 0.6667),
                       CalibrationFilter(.peaking, frequency: 105.04, gain: -3.43, q: 1.414),
                       CalibrationFilter(.peaking, frequency: 3000, gain: 2, q: 4, isOn: false),
                       CalibrationFilter(.highShelf, frequency: 12_345.6, gain: -0.04, q: 0.71),
                       CalibrationFilter(.lowPass, frequency: 15_000, gain: 0)]
        let preset = ParametricPreset(preamp: -4.1, filters: filters)
        XCTAssertEqual(preset.text, """
        Preamp: -4.1 dB
        Filter 1: ON LSC Fc 31.3 Hz Gain 4 dB Q 0.67
        Filter 2: ON PK Fc 105 Hz Gain -3.4 dB Q 1.41
        Filter 3: OFF PK Fc 3000 Hz Gain 2 dB Q 4.00
        Filter 4: ON HSC Fc 12345.6 Hz Gain 0 dB Q 0.71
        Filter 5: ON LPQ Fc 15000 Hz Q 0.71

        """)
        let imported = try ParametricPreset(text: preset.text, name: "Export.txt")
        XCTAssertEqual(imported.preamp, preset.preamp)
        XCTAssertEqual(imported.filters.count, filters.count)
        for (filter, original) in zip(imported.filters, filters) {
            XCTAssertEqual(filter.kind, original.kind)
            XCTAssertEqual(filter.isOn, original.isOn)
            XCTAssertEqual(filter.frequency, original.frequency, accuracy: 0.05)
            XCTAssertEqual(filter.gain, original.gain, accuracy: 0.05)
            XCTAssertEqual(filter.q, original.q, accuracy: 0.005)
        }
        // Once rounded, a preset survives export and import unchanged.
        XCTAssertEqual(try ParametricPreset(text: imported.text, name: "Again.txt"), imported)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Phones.txt")
        try imported.text.write(to: file, atomically: false, encoding: .utf8)
        XCTAssertEqual(try ParametricPreset(contentsOf: file), imported)
    }
}

private func XCTAssertEqual(_ values: [Double], _ expected: [Double], accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(values.count, expected.count, file: file, line: line)
    for (value, known) in zip(values, expected) { XCTAssertEqual(value, known, accuracy: accuracy, file: file, line: line) }
}
