import Accelerate
import Foundation

// Fitting a correction to a measured response. The measurement is moved to the target's level in the midrange, and
// inside the correction range the fitter aims for target − measurement, held within the boost and cut limits. Narrow
// deep dips (a room null, where boosting only spends the speaker's headroom and sounds no better) are bridged rather
// than filled. Filters are picked one at a time where the remaining error is largest, then all of them are optimised
// together (Levenberg–Marquardt on frequency, gain and Q).

/// The response to aim for: flat by default, tilted by `tilt` dB per octave about 1 kHz, with optional shelves.
public struct CalibrationTarget: Codable, Hashable, Sendable {
    public struct Shelf: Codable, Hashable, Sendable {
        public var frequency: Double
        public var gain: Double

        public init(frequency: Double, gain: Double) {
            self.frequency = frequency
            self.gain = gain
        }
    }

    public var tilt: Double
    public var lowShelf: Shelf?
    public var highShelf: Shelf?

    public static let flat = CalibrationTarget()

    public init(tilt: Double = 0, lowShelf: Shelf? = nil, highShelf: Shelf? = nil) {
        self.tilt = tilt
        self.lowShelf = lowShelf
        self.highShelf = highShelf
    }

    /// The target in dB at a frequency. Shelves are the cookbook's at Q 0.707, read at a rate high enough to be the
    /// analogue shape.
    public func level(at frequency: Double) -> Double {
        var level = tilt * log2(frequency / 1000)
        let shelves = [(CalibrationFilter.Kind.lowShelf, lowShelf), (.highShelf, highShelf)]
        for case let (kind, shelf?) in shelves {
            if let biquad = CalibrationFilter(kind, frequency: shelf.frequency, gain: shelf.gain).coefficients(sampleRate: 384_000) {
                level += biquad.gain(at: frequency, sampleRate: 384_000)
            }
        }
        return level
    }

    public func curve(at frequencies: [Double] = CalibrationGrid.frequencies) -> CalibrationCurve {
        CalibrationCurve(frequencies: frequencies, levels: frequencies.map(level(at:)))
    }
}

/// How far a correction may go.
public struct CalibrationLimits: Codable, Hashable, Sendable {
    public static let maximumFilters = 32

    /// Hz. The bottom of the correction range: nil for the speaker's −6 dB point.
    public var lowFrequency: Double?
    public var highFrequency: Double
    /// dB the correction may lift or lower any frequency by.
    public var maxBoost: Double
    public var maxCut: Double
    /// Filters per channel (1…32).
    public var filterCount: Int

    public init(lowFrequency: Double? = nil, highFrequency: Double = 20_000, maxBoost: Double = 6, maxCut: Double = 15,
                filterCount: Int = 16) {
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.maxBoost = maxBoost
        self.maxCut = maxCut
        self.filterCount = filterCount
    }
}

/// A channel's fitted correction.
public struct CalibrationFit: Hashable, Sendable {
    /// Sorted by frequency.
    public var filters: [CalibrationFilter]
    /// The measurement's level against the target in the midrange (dB); the fit works on the measurement minus this.
    public var offset: Double
    /// The correction range used (Hz).
    public var range: ClosedRange<Double>
    /// The measurement, moved by −offset, with the filters applied: what the correction should sound like.
    public var corrected: CalibrationCurve
}

public enum CalibrationFitter {
    /// Where the measurement is matched to the target.
    public static let normalisationRange: ClosedRange<Double> = 300...3000

    public static func fit(_ measured: CalibrationCurve, target: CalibrationTarget = .flat,
                           limits: CalibrationLimits = CalibrationLimits(), sampleRate: Double = 48_000) -> CalibrationFit {
        let frequencies = measured.frequencies
        let targetLevels = frequencies.map(target.level(at:))
        let offset = offsetToTarget(measured, targetLevels)
        // Measurement against the target, after normalising: 0 is right, −3 is 3 dB too quiet.
        let relative = CalibrationCurve(frequencies: frequencies,
                                        levels: zip(measured.levels, targetLevels).map { $0 - $1 - offset })
        let low = max(frequencies.first ?? 20, limits.lowFrequency ?? minusSixPoint(relative))
        let high = max(low * 1.01, min(limits.highFrequency, 0.45 * sampleRate, frequencies.last ?? 20_000))

        var desired = relative.levels.map { -$0 }
        bridgeNarrowDips(relative, &desired)
        desired = desired.map { max(-limits.maxCut, min(limits.maxBoost, $0)) }

        let problem = Problem(frequencies: frequencies, desired: desired, range: low...high, limits: limits,
                              sampleRate: sampleRate)
        let count = max(1, min(CalibrationLimits.maximumFilters, limits.filterCount))
        var filters: [CalibrationFilter] = []
        for _ in 0..<count {
            let response = problem.response(of: filters)
            guard let next = problem.nextFilter(after: filters, response: response) else { break }
            filters.append(next)
            filters = problem.optimise(filters, iterations: 15)
        }
        filters = problem.optimise(filters, iterations: 100)
        filters = enforceLimits(filters, limits: limits, sampleRate: sampleRate)
            .filter { abs($0.gain) >= 0.05 }
            .sorted { $0.frequency < $1.frequency }

        let correction = CalibrationFilter.response(of: filters, sampleRate: sampleRate, at: frequencies)
        let corrected = CalibrationCurve(frequencies: frequencies,
                                         levels: zip(measured.levels, correction).map { $0 - offset + $1 })
        return CalibrationFit(filters: filters, offset: offset, range: low...high, corrected: corrected)
    }

    /// The preamp for a set of channels' filters: low enough that no channel's combined curve goes above 0 dB (rounded
    /// down to 0.1 dB; never positive).
    public static func preamp(for channels: [[CalibrationFilter]], sampleRate: Double) -> Double {
        let peak = channels.map { CalibrationFilter.peak(of: $0, sampleRate: sampleRate) }.max() ?? 0
        return peak > 0 ? -(peak * 10).rounded(.up) / 10 : 0
    }

    /// Per-channel delay (seconds) and level (dB) that line the channels up: the earlier channels wait for the latest,
    /// the louder ones come down to the quietest.
    public static func alignment(arrivals: [Double], levels: [Double]) -> [(delay: Double, level: Double)] {
        let latest = arrivals.max() ?? 0, quietest = levels.min() ?? 0
        return zip(arrivals, levels).map { (latest - $0, quietest - $1) }
    }

    /// The measurement's mean level against the target in `normalisationRange` (all of it if the curve misses that).
    static func offsetToTarget(_ measured: CalibrationCurve, _ target: [Double]) -> Double {
        var differences = zip(measured.frequencies, zip(measured.levels, target))
            .filter { normalisationRange.contains($0.0) }.map { $0.1.0 - $0.1.1 }
        if differences.isEmpty { differences = zip(measured.levels, target).map { $0 - $1 } }
        return differences.isEmpty ? 0 : differences.reduce(0, +) / Double(differences.count)
    }

    /// The speaker's −6 dB point: going up from the bottom of a normalised curve (1/3-octave smoothed, so a room null
    /// doesn't count), where it first reaches −6 dB.
    public static func minusSixPoint(_ relative: CalibrationCurve) -> Double {
        let smoothed = relative.smoothed(.third)
        let (frequencies, levels) = (smoothed.frequencies, smoothed.levels)
        guard let first = frequencies.first else { return CalibrationGrid.low }
        for i in frequencies.indices where frequencies[i] < normalisationRange.lowerBound {
            guard levels[i] >= -6 else { continue }
            if i == 0 { return first }
            let t = (-6 - levels[i - 1]) / (levels[i] - levels[i - 1])
            return frequencies[i - 1] * pow(frequencies[i] / frequencies[i - 1], t)
        }
        return first
    }

    /// Replaces the correction across narrow deep dips (at least 6 dB below the half-octave average over at most a
    /// third of an octave) by a line between its values beside them, so they are never boosted for their own sake.
    static func bridgeNarrowDips(_ relative: CalibrationCurve, _ desired: inout [Double]) {
        let average = relative.smoothed(octaves: 0.5).levels
        let (frequencies, levels) = (relative.frequencies, relative.levels)
        var i = 0
        while i < levels.count {
            guard levels[i] < average[i] - 6 else { i += 1; continue }
            var (start, end) = (i, i)
            while end + 1 < levels.count, levels[end + 1] < average[end + 1] - 6 { end += 1 }
            i = end + 1
            guard log2(frequencies[end] / frequencies[start]) <= 1.0 / 3 else { continue }
            // Take in the dip's sides down to 1 dB below the average.
            while start > 0, levels[start - 1] < average[start - 1] - 1 { start -= 1 }
            while end + 1 < levels.count, levels[end + 1] < average[end + 1] - 1 { end += 1 }
            let before = start > 0 ? desired[start - 1] : (end + 1 < levels.count ? desired[end + 1] : 0)
            let after = end + 1 < levels.count ? desired[end + 1] : before
            let (from, to) = (log(frequencies[max(0, start - 1)]), log(frequencies[min(levels.count - 1, end + 1)]))
            for j in start...end {
                let t = to > from ? (log(frequencies[j]) - from) / (to - from) : 0
                desired[j] = before + t * (after - before)
            }
            i = max(i, end + 1)
        }
    }

    /// Lowers the boosting (or cutting) filters' gains until the combined curve stays inside the limits.
    static func enforceLimits(_ filters: [CalibrationFilter], limits: CalibrationLimits, sampleRate: Double)
        -> [CalibrationFilter] {
        var filters = filters
        let top = min(20_000, sampleRate * 0.499)
        let frequencies = (0...Int(log2(top / 20) * 192)).map { 20 * pow(2, Double($0) / 192) } + [top]
        for _ in 0..<100 {
            let response = CalibrationFilter.response(of: filters, sampleRate: sampleRate, at: frequencies)
            let (highest, lowest) = (response.max() ?? 0, response.min() ?? 0)
            if highest <= limits.maxBoost, lowest >= -limits.maxCut { break }
            for i in filters.indices {
                if highest > limits.maxBoost, filters[i].gain > 0 { filters[i].gain *= 0.998 * limits.maxBoost / highest }
                if lowest < -limits.maxCut, filters[i].gain < 0 { filters[i].gain *= 0.998 * limits.maxCut / -lowest }
            }
        }
        return filters
    }

    /// The fitting problem on the measurement's frequencies, with the cosines the biquad responses need worked out once.
    struct Problem {
        let frequencies: [Double]
        var desired: [Double]
        let range: ClosedRange<Double>
        let limits: CalibrationLimits
        let sampleRate: Double
        private let inRange: [Bool]
        private let cosines: [(Double, Double)]

        init(frequencies: [Double], desired: [Double], range: ClosedRange<Double>, limits: CalibrationLimits,
             sampleRate: Double) {
            self.frequencies = frequencies
            self.desired = desired
            self.range = range
            self.limits = limits
            self.sampleRate = sampleRate
            inRange = frequencies.map { range.contains($0) }
            cosines = frequencies.map {
                let w = 2 * Double.pi * $0 / sampleRate
                return (cos(w), cos(2 * w))
            }
        }

        func response(of filter: CalibrationFilter) -> [Double] {
            guard let b = filter.coefficients(sampleRate: sampleRate) else { return [Double](repeating: 0, count: frequencies.count) }
            return cosines.map { c1, c2 in
                let numerator = b.b0 * b.b0 + b.b1 * b.b1 + b.b2 * b.b2 + 2 * (b.b0 * b.b1 + b.b1 * b.b2) * c1 + 2 * b.b0 * b.b2 * c2
                let denominator = 1 + b.a1 * b.a1 + b.a2 * b.a2 + 2 * (b.a1 + b.a1 * b.a2) * c1 + 2 * b.a2 * c2
                return 10 * log10(max(numerator, 1e-300) / max(denominator, 1e-300))
            }
        }

        func response(of filters: [CalibrationFilter]) -> [Double] {
            var total = [Double](repeating: 0, count: frequencies.count)
            for filter in filters { for (i, level) in response(of: filter).enumerated() { total[i] += level } }
            return total
        }

        /// What's left to fix, weighted: inside the range the miss; outside it only boosting (cutting where the
        /// speaker doesn't play is harmless); anywhere, going past the limits, heavily.
        func residuals(_ response: [Double]) -> [Double] {
            var residuals = [Double]()
            residuals.reserveCapacity(2 * response.count)
            for (i, level) in response.enumerated() {
                residuals.append(inRange[i] ? level - desired[i] : 0.3 * max(0, level))
                residuals.append(10 * (max(0, level - limits.maxBoost) + min(0, level + limits.maxCut)))
            }
            return residuals
        }

        func cost(_ response: [Double]) -> Double { residuals(response).reduce(0) { $0 + $1 * $1 } }

        /// The filter that best takes out the largest remaining error: a peak with the error's width there, or a shelf
        /// when the error runs to the range's edge. Nil when nothing worth fixing is left.
        func nextFilter(after filters: [CalibrationFilter], response: [Double]) -> CalibrationFilter? {
            let indices = frequencies.indices.filter { inRange[$0] }
            guard let first = indices.first, let last = indices.last else { return nil }
            let error = indices.map { desired[$0] - response[$0] }
            guard let worst = error.indices.max(by: { abs(error[$0]) < abs(error[$1]) }), abs(error[worst]) >= 0.25 else {
                return nil
            }
            let height = error[worst]
            var (low, high) = (worst, worst)
            while low > 0, error[low - 1] * height > 0, abs(error[low - 1]) > abs(height) / 2 { low -= 1 }
            while high < error.count - 1, error[high + 1] * height > 0, abs(error[high + 1]) > abs(height) / 2 { high += 1 }
            let bandwidth = max(1.0 / 12, log2(frequencies[indices[high]] / frequencies[indices[low]]))
            let q = max(0.4, min(10, pow(2, bandwidth / 2) / (pow(2, bandwidth) - 1)))
            let gain = max(-limits.maxCut, min(limits.maxBoost, height))
            var candidates = [CalibrationFilter(.peaking, frequency: frequencies[indices[worst]], gain: gain, q: q)]
            if indices[low] == first { candidates.append(CalibrationFilter(.lowShelf, frequency: frequencies[indices[high]], gain: gain)) }
            if indices[high] == last { candidates.append(CalibrationFilter(.highShelf, frequency: frequencies[indices[low]], gain: gain)) }

            let before = cost(response)
            var best: (filter: CalibrationFilter, cost: Double)?
            for candidate in candidates {
                let fitted = optimise([candidate], base: response, iterations: 20)[0]
                let after = cost(zip(response, self.response(of: fitted)).map(+))
                if after < best?.cost ?? before * 0.999 { best = (fitted, after) }
            }
            return best?.filter
        }

        /// Levenberg–Marquardt over every filter's log frequency, gain and log Q (on top of `base`), with a numeric
        /// Jacobian, each step clamped to the allowed values.
        func optimise(_ filters: [CalibrationFilter], base: [Double]? = nil, iterations: Int) -> [CalibrationFilter] {
            guard !filters.isEmpty else { return filters }
            let base = base ?? [Double](repeating: 0, count: frequencies.count)
            var filters = filters
            var parts = filters.map(response(of:))
            func total(_ parts: [[Double]]) -> [Double] {
                var sum = base
                for part in parts { for i in sum.indices { sum[i] += part[i] } }
                return sum
            }
            var current = total(parts)
            var residual = residuals(current)
            var cost = residual.reduce(0) { $0 + $1 * $1 }
            var lambda = 1e-2
            let steps = [0.005, 0.02, 0.005]  // log frequency, gain, log Q
            for _ in 0..<iterations {
                // The Jacobian, transposed: a row per parameter, three per filter.
                let (n, m) = (3 * filters.count, residual.count)
                var transposed = [Double](repeating: 0, count: n * m)
                for (k, filter) in filters.enumerated() {
                    for p in 0..<3 {
                        let moved = response(of: clamp(adjust(filter, p, steps[p])))
                        var trial = current
                        for i in trial.indices { trial[i] += moved[i] - parts[k][i] }
                        let row = (3 * k + p) * m
                        for (i, value) in residuals(trial).enumerated() {
                            transposed[row + i] = (value - residual[i]) / steps[p]
                        }
                    }
                }
                var jacobian = [Double](repeating: 0, count: n * m)
                vDSP_mtransD(transposed, 1, &jacobian, 1, vDSP_Length(m), vDSP_Length(n))
                var normal = [Double](repeating: 0, count: n * n)
                vDSP_mmulD(transposed, 1, jacobian, 1, &normal, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(m))
                var gradient = [Double](repeating: 0, count: n)
                vDSP_mmulD(transposed, 1, residual, 1, &gradient, 1, vDSP_Length(n), 1, vDSP_Length(m))
                var improved = false
                while lambda < 1e7 {
                    var damped = normal
                    for a in 0..<n { damped[a * n + a] += lambda * (normal[a * n + a] + 1e-9) }
                    guard let delta = solve(damped, gradient.map { -$0 }) else { lambda *= 4; continue }
                    let trial = filters.enumerated().map { k, filter in
                        var moved = filter
                        for p in 0..<3 { moved = adjust(moved, p, delta[3 * k + p]) }
                        return clamp(moved)
                    }
                    let trialParts = trial.map(response(of:))
                    let trialResponse = total(trialParts)
                    let trialResidual = residuals(trialResponse)
                    let trialCost = trialResidual.reduce(0) { $0 + $1 * $1 }
                    if trialCost < cost {
                        improved = cost - trialCost > 1e-9 * max(cost, 1e-9)
                        (filters, parts, current, residual, cost) = (trial, trialParts, trialResponse, trialResidual, trialCost)
                        lambda = max(1e-7, lambda / 3)
                        break
                    }
                    lambda *= 4
                }
                if !improved { break }
            }
            return filters
        }

        /// Moves one parameter: 0 log frequency, 1 gain, 2 log Q.
        private func adjust(_ filter: CalibrationFilter, _ parameter: Int, _ amount: Double) -> CalibrationFilter {
            var filter = filter
            switch parameter {
            case 0: filter.frequency *= exp(amount)
            case 1: filter.gain += amount
            default: filter.q *= exp(amount)
            }
            return filter
        }

        private func clamp(_ filter: CalibrationFilter) -> CalibrationFilter {
            var filter = filter
            let top = min(range.upperBound, 0.45 * sampleRate)
            filter.frequency = max(range.lowerBound / 1.5, min(top, filter.frequency))
            filter.gain = max(-limits.maxCut, min(limits.maxBoost, filter.gain))
            // A shelf's Q stays at or below 0.707, where it has no bump past its gain.
            filter.q = filter.kind == .peaking ? max(0.4, min(10, filter.q)) : max(0.4, min(1 / 2.0.squareRoot(), filter.q))
            return filter
        }

        /// Gaussian elimination with partial pivoting on a row-major square matrix; nil for a singular system.
        private func solve(_ matrix: [Double], _ vector: [Double]) -> [Double]? {
            var a = matrix, b = vector
            let n = b.count
            for column in 0..<n {
                guard let pivot = (column..<n).max(by: { abs(a[$0 * n + column]) < abs(a[$1 * n + column]) }),
                      abs(a[pivot * n + column]) > 1e-12 else { return nil }
                if pivot != column {
                    for k in 0..<n { a.swapAt(column * n + k, pivot * n + k) }
                    b.swapAt(column, pivot)
                }
                for row in (column + 1)..<n {
                    let factor = a[row * n + column] / a[column * n + column]
                    guard factor != 0 else { continue }
                    for k in column..<n { a[row * n + k] -= factor * a[column * n + k] }
                    b[row] -= factor * b[column]
                }
            }
            var x = [Double](repeating: 0, count: n)
            for row in stride(from: n - 1, through: 0, by: -1) {
                var sum = b[row]
                for k in (row + 1)..<n { sum -= a[row * n + k] * x[k] }
                x[row] = sum / a[row * n + row]
            }
            return x
        }
    }
}
