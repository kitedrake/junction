import Foundation

// From an impulse response to the curves the fitter works on: the arrival time, the magnitude response on a fixed log
// grid through a frequency-dependent window (long at low frequencies, where the room's modes ring, short at high ones,
// where reflections would add comb filtering), fractional-octave smoothing, averaging over listening positions and a
// channel's level.

/// A magnitude response: levels in dB at rising frequencies in Hz.
public struct CalibrationCurve: Codable, Hashable, Sendable {
    public var frequencies: [Double]
    public var levels: [Double]

    public init(frequencies: [Double], levels: [Double]) {
        precondition(frequencies.count == levels.count, "a level for every frequency")
        self.frequencies = frequencies
        self.levels = levels
    }

    /// A curve on the standard grid.
    public init(levels: [Double]) { self.init(frequencies: CalibrationGrid.frequencies, levels: levels) }

    /// The level at any frequency, interpolated in log frequency; beyond the ends the end values hold.
    public func level(at frequency: Double) -> Double {
        guard let first = frequencies.first, let last = frequencies.last else { return 0 }
        if frequency <= first { return levels[0] }
        if frequency >= last { return levels[levels.count - 1] }
        var low = 0, high = frequencies.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if frequencies[middle] <= frequency { low = middle } else { high = middle }
        }
        let t = log(frequency / frequencies[low]) / log(frequencies[high] / frequencies[low])
        return levels[low] + t * (levels[high] - levels[low])
    }

    public func resampled(to frequencies: [Double] = CalibrationGrid.frequencies) -> CalibrationCurve {
        CalibrationCurve(frequencies: frequencies, levels: frequencies.map(level(at:)))
    }

    /// Every level moved by `offset` dB.
    public func shifted(by offset: Double) -> CalibrationCurve {
        CalibrationCurve(frequencies: frequencies, levels: levels.map { $0 + offset })
    }

    public func smoothed(_ smoothing: CalibrationSmoothing) -> CalibrationCurve {
        smoothed(octaves: 1 / Double(smoothing.rawValue))
    }

    /// Power averaged over a band `octaves` wide centred on each point (cut short at the curve's ends), whatever the
    /// curve's spacing: the curve is read at 1/192-octave steps first.
    public func smoothed(octaves width: Double) -> CalibrationCurve {
        guard frequencies.count > 1, width > 0 else { return self }
        let step = 1.0 / 192
        let start = log2(frequencies[0]), end = log2(frequencies[frequencies.count - 1])
        let count = Int(((end - start) / step).rounded(.up)) + 1
        // sums[i] = power of the fine points before i.
        var sums = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            let frequency = pow(2, min(end, start + Double(i) * step))
            sums[i + 1] = sums[i] + pow(10, level(at: frequency) / 10)
        }
        let levels = frequencies.map { frequency -> Double in
            let centre = (log2(frequency) - start) / step
            let low = max(0, Int((centre - width / 2 / step).rounded(.up)))
            let high = min(count - 1, Int((centre + width / 2 / step).rounded(.down)))
            guard high >= low else { return level(at: frequency) }
            return 10 * log10(max((sums[high + 1] - sums[low]) / Double(high - low + 1), 1e-30))
        }
        return CalibrationCurve(frequencies: frequencies, levels: levels)
    }
}

/// Fractional-octave smoothing widths.
public enum CalibrationSmoothing: Int, Codable, CaseIterable, Sendable {
    case third = 3, sixth = 6, twelfth = 12

    public var title: String { "1/\(rawValue) octave" }
}

/// The fixed grid measured curves are kept on: 240 log-spaced points from 20 Hz to 20 kHz (about 1/24 octave apart).
public enum CalibrationGrid {
    public static let count = 240
    public static let low = 20.0, high = 20_000.0
    public static let frequencies: [Double] = (0..<count).map { low * pow(high / low, Double($0) / Double(count - 1)) }
}

public enum CalibrationAnalysis {
    /// The band a channel's level is read in and positions are matched over.
    public static let midrange: ClosedRange<Double> = 500...2000

    /// When the sound arrives, in samples (fractional): the first peak within 1 ms before the impulse's largest one
    /// that reaches half its height (the direct sound, when a reflection is louder), refined with a parabola through
    /// its neighbours.
    public static func arrival(in impulse: [Double], sampleRate: Double) -> Double {
        guard !impulse.isEmpty else { return 0 }
        var peak = 0
        var height = 0.0
        for (i, sample) in impulse.enumerated() where abs(sample) > height { (peak, height) = (i, abs(sample)) }
        var index = peak
        for i in max(0, peak - Int(0.001 * sampleRate))..<peak {
            let value = abs(impulse[i])
            if value >= 0.5 * height, value >= abs(impulse[i + 1]), i == 0 || value >= abs(impulse[i - 1]) {
                index = i
                break
            }
        }
        guard index > 0, index < impulse.count - 1 else { return Double(index) }
        let (before, at, after) = (abs(impulse[index - 1]), abs(impulse[index]), abs(impulse[index + 1]))
        let curvature = before - 2 * at + after
        guard curvature < 0 else { return Double(index) }
        return Double(index) + max(-0.5, min(0.5, 0.5 * (before - after) / curvature))
    }

    /// The magnitude response of an impulse response, at `frequencies`, through a frequency-dependent window: at each
    /// frequency, `cycles` periods after the arrival (between 2 ms and 500 ms) with a half-Hann fade, and up to 0.5 ms
    /// before it with a rising one.
    public static func response(of impulse: [Double], sampleRate: Double, arrival: Double? = nil, cycles: Double = 15,
                                frequencies: [Double] = CalibrationGrid.frequencies) -> CalibrationCurve {
        let start = Int((arrival ?? self.arrival(in: impulse, sampleRate: sampleRate)).rounded())
        let levels = frequencies.map { frequency -> Double in
            let after = min(impulse.count - start, Int(min(0.5, max(0.002, cycles / frequency)) * sampleRate))
            let before = min(start, Int(0.0005 * sampleRate), after / 4)
            guard after > 0 else { return -300 }
            let omega = 2 * Double.pi * frequency / sampleRate
            let turn = (cos(-omega), sin(-omega))
            // e^(−iω(n − start)) from n = start − before.
            var phasor = (cos(omega * Double(before)), sin(omega * Double(before)))
            var sum = (0.0, 0.0)
            for n in (start - before)..<(start + after) {
                let weight = n < start
                    ? 0.5 - 0.5 * cos(Double.pi * Double(n - start + before) / Double(before))
                    : 0.5 + 0.5 * cos(Double.pi * Double(n - start) / Double(after))
                let value = impulse[n] * weight
                sum.0 += value * phasor.0
                sum.1 += value * phasor.1
                phasor = (phasor.0 * turn.0 - phasor.1 * turn.1, phasor.0 * turn.1 + phasor.1 * turn.0)
            }
            return 20 * log10(max(hypot(sum.0, sum.1), 1e-15))
        }
        return CalibrationCurve(frequencies: frequencies, levels: levels)
    }

    /// A curve's level: the power average of its points in `range`.
    public static func level(of curve: CalibrationCurve, in range: ClosedRange<Double> = midrange) -> Double {
        let inside = zip(curve.frequencies, curve.levels).filter { range.contains($0.0) }.map(\.1)
        guard !inside.isEmpty else { return curve.level(at: sqrt(range.lowerBound * range.upperBound)) }
        return 10 * log10(inside.reduce(0) { $0 + pow(10, $1 / 10) } / Double(inside.count))
    }

    /// Positions averaged: each curve is moved to the curves' mean level in `range`, then their powers are averaged
    /// point by point (so a null at one position is filled by the others). Read on the first curve's frequencies.
    public static func average(_ curves: [CalibrationCurve], matching range: ClosedRange<Double> = midrange)
        -> CalibrationCurve {
        guard let first = curves.first else { return CalibrationCurve(frequencies: [], levels: []) }
        let aligned = curves.map { $0.frequencies == first.frequencies ? $0 : $0.resampled(to: first.frequencies) }
        let levels = aligned.map { level(of: $0, in: range) }
        let reference = levels.reduce(0, +) / Double(levels.count)
        var power = [Double](repeating: 0, count: first.frequencies.count)
        for (curve, level) in zip(aligned, levels) {
            for i in power.indices { power[i] += pow(10, (curve.levels[i] + reference - level) / 10) }
        }
        return CalibrationCurve(frequencies: first.frequencies,
                                levels: power.map { 10 * log10(max($0 / Double(curves.count), 1e-30)) })
    }
}
