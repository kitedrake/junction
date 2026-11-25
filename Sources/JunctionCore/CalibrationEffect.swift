import Foundation
import JunctionKernel

// The Calibration effect: a CalibrationProfile run by the kernel's correction stage on an output. Its one parameter,
// Amount, scales the filters' gains in dB. The kernel gets an immutable block of coefficients made here for the
// chain's sample rate, on the router's queue, whenever the profile or Amount changes; it cross-fades to it over one
// buffer, so neither clicks and the sink isn't rebuilt.

extension CalibrationProfile {
    /// The profile at `amount` (0…1): every filter's gain, and the preamp that makes room for them, scaled in dB.
    /// Channels' delays and levels stay as they are.
    public func scaled(by amount: Double) -> CalibrationProfile {
        let amount = min(max(amount, 0), 1)
        guard amount != 1 else { return self }
        var scaled = self
        scaled.preamp = preamp * amount
        for c in scaled.channels.indices {
            for f in scaled.channels[c].filters.indices { scaled.channels[c].filters[f].gain *= amount }
        }
        return scaled
    }

    /// How many of an output's first channels the profile corrects: every one when it has a single entry (a
    /// headphone preset), otherwise one per entry. The rest pass through.
    public func correctedChannels(of outputChannels: Int) -> Int {
        channels.count == 1 ? outputChannels : min(channels.count, outputChannels)
    }

    /// Whether the profile was made for another device than `uid` (one not tied to a device fits any).
    public func isForAnotherDevice(than uid: String?) -> Bool {
        guard let deviceUID else { return false }
        return deviceUID != uid
    }
}

enum CalibrationKernel {
    /// A kernel block (JKCorrection) for `channels` output channels at `sampleRate`, at `amount` (0…1): each corrected
    /// channel's biquads (the first JK_CORRECTION_MAX_SECTIONS the rate can carry), its delay in frames (at most
    /// `maxDelayFrames`) and level, and the preamp. Nil when memory runs out. The caller hands it to a chain or frees it.
    static func block(_ profile: CalibrationProfile, amount: Double, channels: Int, sampleRate: Double,
                      maxDelayFrames: Int) -> OpaquePointer? {
        let profile = profile.scaled(by: amount)
        let corrected = profile.correctedChannels(of: channels)
        guard corrected > 0, let block = jk_correction_create(UInt32(corrected)) else { return nil }
        for c in 0..<corrected {
            let channel = profile.channel(c)
            let biquads = profile.coefficients(channel: c, sampleRate: sampleRate).prefix(Int(JK_CORRECTION_MAX_SECTIONS))
            let coefficients = biquads.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
            let delay = min(max(0, Int((channel.delay * sampleRate).rounded())), max(0, maxDelayFrames))
            let level = Float(pow(10, channel.level / 20))
            if jk_correction_set_channel(block, UInt32(c), coefficients, UInt32(biquads.count), UInt32(delay), level) == 0 {
                jk_correction_set_channel(block, UInt32(c), nil, 0, UInt32(delay), level)  // unusable filters: none
            }
        }
        jk_correction_set_preamp(block, Float(pow(10, profile.preamp / 20)))
        return block
    }
}
