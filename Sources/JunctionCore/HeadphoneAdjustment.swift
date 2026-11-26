import Foundation

// Tilt, bass and treble on top of a headphone preset: the speaker sheet's target controls, kept in the profile's
// `adjustment` and played as extra filters after the preset's, which stay as they are. The shelves are the target's
// own (the cookbook's at Q 0.707). A tilt isn't one biquad: it is five shelves two octaves apart (low shelves below
// 1 kHz, high shelves above it), each lifting or lowering two octaves' worth of the slope, which follows the straight
// line within a third of a dB per dB/octave from 20 Hz to 20 kHz. Preset and adjustment together stay within the
// correction stage's sections: an adjustment that doesn't fit isn't played (the inspector says so). When the
// adjustment boosts past what the preset's preamp leaves room for, the preamp comes down to make room.

extension CalibrationTarget {
    /// Where the tilt's shelves sit: low shelves at 31.25, 125 and 500 Hz, high shelves at 2 and 8 kHz.
    public static let tiltShelfFrequencies: [(kind: CalibrationFilter.Kind, frequency: Double)] = [
        (.lowShelf, 500), (.lowShelf, 125), (.lowShelf, 31.25), (.highShelf, 2_000), (.highShelf, 8_000),
    ]
    /// The octaves between neighbouring tilt shelves (each one's gain is the tilt times this).
    public static let tiltShelfSpacing = 2.0

    /// The most sections an adjustment takes: the tilt's shelves, a bass and a treble shelf.
    public static let maximumSections = tiltShelfFrequencies.count + 2

    /// The bass and treble shelves' frequencies when they are first moved.
    public static let defaultBassFrequency = 105.0
    public static let defaultTrebleFrequency = 8_000.0

    /// Whether it changes nothing (no tilt, no shelf with a gain).
    public var isNeutral: Bool { tilt == 0 && (lowShelf?.gain ?? 0) == 0 && (highShelf?.gain ?? 0) == 0 }

    /// The adjustment as filters: the tilt's shelves (when there is a tilt), then the bass and treble shelves (when they
    /// have a gain).
    public var filters: [CalibrationFilter] {
        var filters: [CalibrationFilter] = []
        if tilt != 0 {
            for (kind, frequency) in Self.tiltShelfFrequencies {
                let gain = tilt * Self.tiltShelfSpacing * (kind == .lowShelf ? -1 : 1)
                filters.append(CalibrationFilter(kind, frequency: frequency, gain: gain))
            }
        }
        if let lowShelf, lowShelf.gain != 0 {
            filters.append(CalibrationFilter(.lowShelf, frequency: lowShelf.frequency, gain: lowShelf.gain))
        }
        if let highShelf, highShelf.gain != 0 {
            filters.append(CalibrationFilter(.highShelf, frequency: highShelf.frequency, gain: highShelf.gain))
        }
        return filters
    }

    /// Tilt and shelf gains times `amount` (frequencies kept).
    public func scaled(by amount: Double) -> CalibrationTarget {
        var scaled = self
        scaled.tilt *= amount
        scaled.lowShelf?.gain *= amount
        scaled.highShelf?.gain *= amount
        return scaled
    }
}

extension CalibrationProfile {
    /// Whether the profile offers tilt, bass and treble on top: a headphone preset (from the library or a file).
    public var isAdjustable: Bool { kind == .headphones }

    /// The most sections the preset's own filters take on a channel (switched-off filters take none).
    public var presetSections: Int { channels.map { $0.filters.filter(\.isOn).count }.max() ?? 0 }

    /// Whether a full adjustment fits beside the preset in the correction stage's sections.
    public var adjustmentFits: Bool { presetSections + CalibrationTarget.maximumSections <= CalibrationLimits.maximumFilters }

    /// The adjustment's filters as they play: none for a profile that isn't adjustable, or when they wouldn't fit
    /// beside the preset's.
    public var adjustmentFilters: [CalibrationFilter] {
        guard isAdjustable, let adjustment else { return [] }
        let filters = adjustment.filters
        return presetSections + filters.count <= CalibrationLimits.maximumFilters ? filters : []
    }

    /// A channel's filters as they play: the preset's, then the adjustment's.
    public func playedFilters(channel index: Int) -> [CalibrationFilter] {
        channel(index).filters + adjustmentFilters
    }

    /// The preamp as it plays: the preset's, or lower when the adjustment needs more room than it leaves (the
    /// fitter's preamp for the combined filters, at 48 kHz).
    public var playedPreamp: Double {
        let added = adjustmentFilters
        guard !added.isEmpty else { return preamp }
        let channels = channels.isEmpty ? [added] : channels.map { $0.filters + added }
        return min(preamp, CalibrationFitter.preamp(for: channels, sampleRate: 48_000))
    }

    /// A channel's preset alone in dB: its filters, preamp and level, without the adjustment.
    public func presetCurve(channel index: Int, sampleRate: Double,
                            at frequencies: [Double] = CalibrationGrid.frequencies) -> [Double] {
        let channel = channel(index)
        return CalibrationFilter.response(of: channel.filters, preamp: preamp + channel.level, sampleRate: sampleRate,
                                          at: frequencies)
    }

    /// What the adjustment adds in dB: its filters and the extra room the preamp makes for them. With the preset's
    /// curve it makes `curve`.
    public func adjustmentCurve(sampleRate: Double, at frequencies: [Double] = CalibrationGrid.frequencies) -> [Double] {
        CalibrationFilter.response(of: adjustmentFilters, preamp: playedPreamp - preamp, sampleRate: sampleRate,
                                   at: frequencies)
    }

    /// The profile with another adjustment; a neutral one (or nil) leaves the preset exactly as it came.
    public func adjusted(_ adjustment: CalibrationTarget?) -> CalibrationProfile {
        var profile = self
        profile.adjustment = adjustment.flatMap { $0.isNeutral ? nil : $0 }
        return profile
    }
}
