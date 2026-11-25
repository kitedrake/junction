import Accelerate
import Foundation

// Measuring a speaker with an exponential sine sweep (Farina, "Simultaneous measurement of impulse response and
// distortion with a swept-sine technique", AES 108th Convention, 2000). The sweep's frequency rises exponentially, so
// every octave gets the same time and the sweep's spectrum falls 3 dB per octave. Dividing the recording's spectrum by
// the sweep's, regularised outside the swept band (Kirkeby and Nelson, "Digital filter design for inversion problems in
// sound reproduction", JAES 47, 1999), turns it into the impulse response; the harmonic distortion of the speaker lands
// before it (at negative times) and doesn't touch the linear response. Pure maths: nothing here opens a device.

/// A power-of-two FFT on Doubles: Accelerate's in-place split-complex radix-2 transform.
final class CalibrationFFT {
    let count: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    /// The smallest power of two of at least `n`.
    static func size(atLeast n: Int) -> Int {
        var size = 1
        while size < n { size <<= 1 }
        return size
    }

    init(count: Int) {
        precondition(count > 1 && count & (count - 1) == 0, "FFT sizes are powers of two")
        self.count = count
        log2n = vDSP_Length(count.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// X[k] = Σ x[n]·e^(−2πikn/N), unscaled.
    func forward(_ real: inout [Double], _ imaginary: inout [Double]) {
        transform(&real, &imaginary, FFTDirection(kFFTDirection_Forward))
    }

    /// The inverse, scaled by 1/N so that forward then inverse gives the input back.
    func inverse(_ real: inout [Double], _ imaginary: inout [Double]) {
        transform(&real, &imaginary, FFTDirection(kFFTDirection_Inverse))
        var scale = 1 / Double(count)
        vDSP_vsmulD(real, 1, &scale, &real, 1, vDSP_Length(count))
        vDSP_vsmulD(imaginary, 1, &scale, &imaginary, 1, vDSP_Length(count))
    }

    /// The spectrum of real samples, zero-padded to the FFT's size.
    func spectrum(of samples: [Double]) -> (real: [Double], imaginary: [Double]) {
        var real = [Double](repeating: 0, count: count)
        var imaginary = [Double](repeating: 0, count: count)
        real.replaceSubrange(0..<min(samples.count, count), with: samples.prefix(count))
        forward(&real, &imaginary)
        return (real, imaginary)
    }

    private func transform(_ real: inout [Double], _ imaginary: inout [Double], _ direction: FFTDirection) {
        precondition(real.count == count && imaginary.count == count)
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2n, direction)
            }
        }
    }
}

/// An exponential sine sweep from 20 Hz to min(20 kHz, 0.45 × rate), faded in and out, with silence before it (so the
/// device and the room settle) and a tail after it (so the room's decay and the devices' delay are recorded).
public struct CalibrationSweep: Sendable {
    public let sampleRate: Double
    public let startFrequency: Double
    public let endFrequency: Double
    /// Seconds: the sweep itself, the silence before it and the tail after it.
    public let duration: Double
    public let leadSilence: Double
    public let tail: Double
    /// Peak level of the sweep (linear, full scale = 1).
    public let amplitude: Double
    /// What to play: the lead silence, the sweep and the tail. A recording of it (same length, started together) goes
    /// to `impulseResponse(of:)`.
    public let samples: [Double]

    /// The lead silence in samples: where no delay falls in an impulse response.
    public var leadSamples: Int { Int((leadSilence * sampleRate).rounded()) }

    public init(sampleRate: Double, duration: Double = 3, leadSilence: Double = 0.25, tail: Double = 1.5,
                amplitude: Double = 0.5) {
        self.sampleRate = sampleRate
        self.duration = duration
        self.leadSilence = leadSilence
        self.tail = tail
        self.amplitude = amplitude
        startFrequency = 20
        endFrequency = min(20_000, 0.45 * sampleRate)

        let lead = Int((leadSilence * sampleRate).rounded())  // leadSamples
        let length = Int((duration * sampleRate).rounded())
        let after = Int((tail * sampleRate).rounded())
        let rate = log(endFrequency / startFrequency)
        let octaves = log2(endFrequency / startFrequency)
        // Fades take a sixth of the first octave and a twenty-fourth of the last, so they touch only the band edges.
        let fadeIn = max(1, Int(duration / octaves / 6 * sampleRate))
        let fadeOut = max(1, Int(duration / octaves / 24 * sampleRate))
        var samples = [Double](repeating: 0, count: lead + length + after)
        for n in 0..<length {
            let t = Double(n) / sampleRate
            // Instantaneous frequency f1·e^(t·ln(f2/f1)/T); the phase is its integral.
            let phase = 2 * Double.pi * startFrequency * duration / rate * (exp(t / duration * rate) - 1)
            var gain = amplitude
            if n < fadeIn { gain *= 0.5 - 0.5 * cos(Double.pi * Double(n) / Double(fadeIn)) }
            if n >= length - fadeOut { gain *= 0.5 - 0.5 * cos(Double.pi * Double(length - 1 - n) / Double(fadeOut)) }
            samples[lead + n] = gain * sin(phase)
        }
        self.samples = samples
    }

    /// The sweep's regularised inverse at an FFT size: conj(X) / (|X|² + ε(f)). ε is tiny inside the swept band and
    /// rises to the sweep's peak power over half an octave outside it, so nothing outside the band is amplified.
    private func inverseSpectrum(_ fft: CalibrationFFT) -> (real: [Double], imaginary: [Double]) {
        var (real, imaginary) = fft.spectrum(of: samples)
        let n = fft.count
        var power = [Double](repeating: 0, count: n)
        for k in 0..<n { power[k] = real[k] * real[k] + imaginary[k] * imaginary[k] }
        let peak = power.max() ?? 1
        for k in 0..<n {
            let f = Double(min(k, n - k)) * sampleRate / Double(n)
            let outside: Double  // octaves outside the swept band
            if f < startFrequency { outside = f > 0 ? log2(startFrequency / f) : 1 }
            else if f > endFrequency { outside = log2(f / endFrequency) }
            else { outside = 0 }
            let epsilon = peak * pow(10, -8 * (1 - min(1, outside / 0.5)))
            let scale = 1 / (power[k] + epsilon)
            real[k] *= scale
            imaginary[k] *= -scale
        }
        return (real, imaginary)
    }

    /// The inverse filter in the time domain, as long as `samples`: convolving `samples` with it gives an impulse,
    /// band-limited to the sweep, at `samples.count − 1`. (It is the time-reversed sweep, tilted 3 dB per octave.)
    public func inverseFilter() -> [Double] {
        let length = samples.count
        let fft = CalibrationFFT(count: CalibrationFFT.size(atLeast: 2 * length))
        var (real, imaginary) = inverseSpectrum(fft)
        // Delay by length − 1 so the time-reversed sweep starts at 0.
        let n = fft.count
        for k in 0..<n {
            let angle = -2 * Double.pi * Double(k) * Double(length - 1) / Double(n)
            let (c, s) = (cos(angle), sin(angle))
            (real[k], imaginary[k]) = (real[k] * c - imaginary[k] * s, real[k] * s + imaginary[k] * c)
        }
        fft.inverse(&real, &imaginary)
        return Array(real.prefix(length))
    }

    /// The impulse response in a recording of `samples`, as long as the recording. Index `leadSamples` is no delay, so
    /// the arrival there includes the devices' latency and the sound's flight, and the time before it is there for the
    /// window to start a little early (the second harmonic's response also lands in it, 0.2 s or so ahead). A unity
    /// system gives a unit impulse at `leadSamples`.
    public func impulseResponse(of recording: [Double]) -> [Double] {
        let fft = CalibrationFFT(count: CalibrationFFT.size(atLeast: recording.count + samples.count))
        let inverse = inverseSpectrum(fft)
        var (real, imaginary) = fft.spectrum(of: recording)
        for k in 0..<fft.count {
            (real[k], imaginary[k]) = (real[k] * inverse.real[k] - imaginary[k] * inverse.imaginary[k],
                                       real[k] * inverse.imaginary[k] + imaginary[k] * inverse.real[k])
        }
        fft.inverse(&real, &imaginary)
        // Negative times sit at the far end of the circular result: start the lead silence's length before 0. Higher
        // harmonics land earlier still and are left out.
        let lead = min(leadSamples, fft.count - recording.count)
        return Array(real[(fft.count - lead)...] + real[..<(recording.count - lead)])
    }

    public func impulseResponse(of recording: [Float]) -> [Double] { impulseResponse(of: recording.map(Double.init)) }
}
