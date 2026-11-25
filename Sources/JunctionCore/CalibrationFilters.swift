import Foundation

// The correction's filters: peaking and shelving biquads from Robert Bristow-Johnson's "Cookbook formulae for audio EQ
// biquad filter coefficients" (published as W3C's Audio EQ Cookbook). They are minimum phase, so the correction adds no
// delay. A filter is kept by type, frequency, gain and Q, and its coefficients are worked out for whatever rate the
// output runs at.

/// One correction filter, as saved and as a parametric EQ preset lists it.
public struct CalibrationFilter: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case peaking, lowShelf, highShelf
    }

    public var kind: Kind
    /// Hz: a peak's centre, a shelf's midpoint (where it reaches half its gain in dB).
    public var frequency: Double
    public var gain: Double
    public var q: Double
    /// A switched-off filter from a preset: kept, but it does nothing.
    public var isOn: Bool

    public init(_ kind: Kind, frequency: Double, gain: Double, q: Double = 1 / 2.0.squareRoot(), isOn: Bool = true) {
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.isOn = isOn
    }

    private enum CodingKeys: String, CodingKey { case kind, frequency, gain, q, isOn }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        frequency = try container.decode(Double.self, forKey: .frequency)
        gain = try container.decode(Double.self, forKey: .gain)
        q = try container.decode(Double.self, forKey: .q)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
    }

    /// The Q a shelf of this gain has at the cookbook's slope S (1 is the steepest without a bump; about 12 dB per
    /// octave for large gains).
    public static func shelfQ(slope: Double, gain: Double) -> Double {
        let a = pow(10, gain / 40)
        return 1 / max(1e-6, (a + 1 / a) * (1 / max(slope, 1e-6) - 1) + 2).squareRoot()
    }

    /// The filter's coefficients at a sample rate; nil when it's off or at or above the rate's Nyquist frequency.
    public func coefficients(sampleRate: Double) -> CalibrationBiquad? {
        guard isOn, frequency > 0, frequency < sampleRate / 2, q > 0 else { return nil }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let (cosine, alpha) = (cos(w0), sin(w0) / (2 * q))
        let b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking:
            (b0, b1, b2) = (1 + alpha * a, -2 * cosine, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * cosine, 1 - alpha / a)
        case .lowShelf:
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosine + root)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosine)
            b2 = a * ((a + 1) - (a - 1) * cosine - root)
            a0 = (a + 1) + (a - 1) * cosine + root
            a1 = -2 * ((a - 1) + (a + 1) * cosine)
            a2 = (a + 1) + (a - 1) * cosine - root
        case .highShelf:
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosine + root)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosine)
            b2 = a * ((a + 1) + (a - 1) * cosine - root)
            a0 = (a + 1) - (a - 1) * cosine + root
            a1 = 2 * ((a - 1) - (a + 1) * cosine)
            a2 = (a + 1) - (a - 1) * cosine - root
        }
        return CalibrationBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// The filters' combined response in dB at `frequencies`, plus `preamp`. Filters the rate can't carry are left out,
    /// as they are when the output runs.
    public static func response(of filters: [CalibrationFilter], preamp: Double = 0, sampleRate: Double,
                                at frequencies: [Double] = CalibrationGrid.frequencies) -> [Double] {
        var levels = [Double](repeating: preamp, count: frequencies.count)
        for biquad in filters.compactMap({ $0.coefficients(sampleRate: sampleRate) }) {
            for (i, frequency) in frequencies.enumerated() { levels[i] += biquad.gain(at: frequency, sampleRate: sampleRate) }
        }
        return levels
    }

    /// The highest point of the filters' combined response, read at 1/192-octave steps from 10 Hz to just below
    /// Nyquist (or 24 kHz).
    public static func peak(of filters: [CalibrationFilter], sampleRate: Double) -> Double {
        let top = min(24_000, sampleRate * 0.499)
        let count = Int(log2(top / 10) * 192) + 1
        let frequencies = (0..<count).map { 10 * pow(2, Double($0) / 192) } + [top]
        return response(of: filters, sampleRate: sampleRate, at: frequencies).max() ?? 0
    }
}

/// A biquad's coefficients, normalised so a0 = 1: y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2].
public struct CalibrationBiquad: Hashable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    /// The magnitude response in dB at a frequency: |B(e^iω)|² / |A(e^iω)|², in the cookbook's form with
    /// φ = sin²(ω/2), which keeps its precision for low frequencies and high Qs (expanding it in cos ω loses tenths of
    /// a dB there to cancellation).
    public func gain(at frequency: Double, sampleRate: Double) -> Double {
        let s = sin(Double.pi * frequency / sampleRate)
        let phi = s * s
        let numerator = pow((b0 + b1 + b2) / 2, 2) - phi * (4 * b0 * b2 * (1 - phi) + b1 * (b0 + b2))
        let denominator = pow((1 + a1 + a2) / 2, 2) - phi * (4 * a2 * (1 - phi) + a1 * (1 + a2))
        return 10 * log10(max(numerator, 1e-300) / max(denominator, 1e-300))
    }

    /// The filter run over samples from silence (transposed direct form II).
    public func process(_ samples: [Double]) -> [Double] {
        var (z1, z2) = (0.0, 0.0)
        return samples.map { x in
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
