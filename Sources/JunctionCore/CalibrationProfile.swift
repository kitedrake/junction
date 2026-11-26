import Foundation

// A calibration as saved: per-channel correction filters, delay and level, a preamp, the target and limits it was
// fitted with, and the measured curves it came from. Also the text files around it: microphone calibration files and
// measurement exports ("frequency dB [phase]" lines), and parametric EQ presets ("Preamp: …", "Filter 1: ON PK …").

/// A speaker or headphone correction.
public struct CalibrationProfile: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Measured in the room by Junction.
        case speakers
        /// From a parametric EQ preset.
        case headphones
        /// Fitted to a measurement exported by another program.
        case imported
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var date: Date
    /// The output it was made for (nil when it isn't tied to one).
    public var deviceUID: String?
    public var deviceName: String?
    /// Per output channel; a single entry applies to every channel.
    public var channels: [CalibrationChannel]
    /// dB, never positive: keeps the combined curve at or below 0 dB.
    public var preamp: Double
    public var target: CalibrationTarget
    public var limits: CalibrationLimits
    /// The measuring microphone's calibration file, by name.
    public var micCalibration: String?
    /// Measured curves on `CalibrationGrid`: every channel at every position, and each channel's average.
    public var measurements: [CalibrationMeasurement]
    /// A measured profile's arrivals and whether the channels are lined up (absent for other profiles, and in
    /// profiles saved before it was kept: refitting then lines the channels up from their delays).
    public var alignment: CalibrationAlignment?
    /// For a preset from the headphone library: where it came from and who made it (absent for other profiles).
    public var library: HeadphoneLibraryCredit?

    public init(id: UUID = UUID(), name: String, kind: Kind, date: Date = Date(), deviceUID: String? = nil,
                deviceName: String? = nil, channels: [CalibrationChannel], preamp: Double,
                target: CalibrationTarget = .flat, limits: CalibrationLimits = CalibrationLimits(),
                micCalibration: String? = nil, measurements: [CalibrationMeasurement] = [],
                alignment: CalibrationAlignment? = nil, library: HeadphoneLibraryCredit? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.date = date
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.channels = channels
        self.preamp = preamp
        self.target = target
        self.limits = limits
        self.micCalibration = micCalibration
        self.measurements = measurements
        self.alignment = alignment
        self.library = library
    }

    /// The correction for an output channel (the single entry, or the last one for channels beyond the list).
    public func channel(_ index: Int) -> CalibrationChannel {
        channels.isEmpty ? CalibrationChannel(filters: []) : channels[max(0, min(index, channels.count - 1))]
    }

    /// An output channel's biquads at a sample rate (filters the rate can't carry are dropped).
    public func coefficients(channel index: Int, sampleRate: Double) -> [CalibrationBiquad] {
        channel(index).filters.compactMap { $0.coefficients(sampleRate: sampleRate) }
    }

    /// An output channel's combined curve in dB: filters, preamp and level.
    public func curve(channel index: Int, sampleRate: Double,
                      at frequencies: [Double] = CalibrationGrid.frequencies) -> [Double] {
        let channel = channel(index)
        return CalibrationFilter.response(of: channel.filters, preamp: preamp + channel.level, sampleRate: sampleRate,
                                          at: frequencies)
    }

    /// A headphone profile from a parametric EQ preset (one set of filters for every channel).
    public init(name: String, preset: ParametricPreset) {
        self.init(name: name, kind: .headphones, channels: [CalibrationChannel(filters: preset.filters)],
                  preamp: min(0, preset.preamp))
    }

    /// The preset for one channel's filters and the preamp (delay and level aren't part of the format).
    public func preset(channel index: Int = 0) -> ParametricPreset {
        ParametricPreset(preamp: preamp, filters: channel(index).filters)
    }

    /// A speaker profile from sweeps: `captures[channel][position]`, the first position being the listening position
    /// the channels' delays are lined up for. Each channel's positions are averaged, smoothed and fitted; with
    /// `alignsSpeakers` the louder channels are brought down to the quietest and the nearer ones delayed to the
    /// farthest. The fit is made from the curves as saved, so `refitted` with the same settings gives the same profile.
    public static func speakers(name: String, deviceUID: String? = nil, deviceName: String? = nil,
                                captures: [[CalibrationCapture]], target: CalibrationTarget = .flat,
                                limits: CalibrationLimits = CalibrationLimits(), smoothing: CalibrationSmoothing = .twelfth,
                                alignsSpeakers: Bool = true, micCalibration: String? = nil, sampleRate: Double,
                                date: Date = Date()) -> CalibrationProfile {
        var measurements: [CalibrationMeasurement] = []
        for (channel, positions) in captures.enumerated() {
            let curves = positions.map { $0.curve.resampled() }
            for (position, curve) in curves.enumerated() {
                measurements.append(CalibrationMeasurement(channel: channel, position: position, curve: curve))
            }
            measurements.append(CalibrationMeasurement(channel: channel, position: nil,
                                                       curve: CalibrationAnalysis.average(curves)))
        }
        let measured = CalibrationProfile(name: name, kind: .speakers, date: date, deviceUID: deviceUID,
                                          deviceName: deviceName, channels: [], preamp: 0, micCalibration: micCalibration,
                                          measurements: measurements,
                                          alignment: CalibrationAlignment(arrivals: captures.map { $0.first?.arrival ?? 0 },
                                                                          isOn: alignsSpeakers))
        return measured.refitted(target: target, limits: limits, alignsSpeakers: alignsSpeakers, smoothing: smoothing,
                                 sampleRate: sampleRate)
    }

    /// The channels the saved measurements cover, in order.
    public var measuredChannels: [Int] { Array(Set(measurements.map(\.channel))).sorted() }

    /// A channel's saved average (or, without one, the average of its saved positions).
    public func averageMeasurement(channel: Int) -> CalibrationCurve? {
        if let average = measurements.first(where: { $0.channel == channel && $0.position == nil }) { return average.curve }
        let positions = measurements.filter { $0.channel == channel && $0.position != nil }.map(\.curve)
        return positions.isEmpty ? nil : CalibrationAnalysis.average(positions)
    }

    /// Whether the profile can be fitted again from what it keeps (a measured one).
    public var canRefit: Bool { !measuredChannels.isEmpty }

    /// The profile fitted again from its saved measurements, without measuring: new filters, preamp, delays and
    /// levels for a target and limits; everything else (name, device, curves) kept. Without arrivals saved, the
    /// channels' delays stand in for them. Unchanged when it has no measurements.
    public func refitted(target: CalibrationTarget, limits: CalibrationLimits, alignsSpeakers: Bool,
                         smoothing: CalibrationSmoothing = .twelfth, sampleRate: Double = 48_000) -> CalibrationProfile {
        let averages = measuredChannels.compactMap { averageMeasurement(channel: $0) }
        guard !averages.isEmpty else { return self }
        let fits = averages.map {
            CalibrationFitter.fit($0.smoothed(smoothing), target: target, limits: limits, sampleRate: sampleRate)
        }
        let arrivals = alignment.map(\.arrivals).flatMap { $0.count == fits.count ? $0 : nil }
            ?? fits.indices.map { -self.channel($0).delay }
        let aligned = CalibrationFitter.alignment(arrivals: arrivals, levels: fits.map(\.offset))
        var profile = self
        profile.channels = zip(fits, aligned).map { fit, alignment in
            alignsSpeakers ? CalibrationChannel(filters: fit.filters, delay: alignment.delay, level: alignment.level)
                : CalibrationChannel(filters: fit.filters)
        }
        profile.preamp = CalibrationFitter.preamp(for: fits.map(\.filters), sampleRate: sampleRate)
        profile.target = target
        profile.limits = limits
        profile.alignment = CalibrationAlignment(arrivals: arrivals, isOn: alignsSpeakers)
        return profile
    }

    /// A profile fitted to a measurement imported from a text export (one set of filters for every channel).
    public static func imported(name: String, measurement: CalibrationCurve, target: CalibrationTarget = .flat,
                                limits: CalibrationLimits = CalibrationLimits(), sampleRate: Double = 48_000,
                                date: Date = Date()) -> CalibrationProfile {
        let curve = measurement.resampled()
        let fit = CalibrationFitter.fit(curve, target: target, limits: limits, sampleRate: sampleRate)
        return CalibrationProfile(name: name, kind: .imported, date: date, channels: [CalibrationChannel(filters: fit.filters)],
                                  preamp: CalibrationFitter.preamp(for: [fit.filters], sampleRate: sampleRate),
                                  target: target, limits: limits,
                                  measurements: [CalibrationMeasurement(channel: 0, position: nil, curve: curve)])
    }
}

/// When each measured channel's sound arrived at the listening position, kept so the channels can be lined up again
/// when a profile is refitted.
public struct CalibrationAlignment: Codable, Hashable, Sendable {
    /// Seconds, per channel.
    public var arrivals: [Double]
    /// Whether the channels' delays and levels line them up (off: every channel plays as it is).
    public var isOn: Bool

    public init(arrivals: [Double], isOn: Bool = true) {
        self.arrivals = arrivals
        self.isOn = isOn
    }
}

/// One output channel's correction.
public struct CalibrationChannel: Codable, Hashable, Sendable {
    public var filters: [CalibrationFilter]
    /// Seconds the channel waits so it arrives with the others.
    public var delay: Double
    /// dB, never positive: brings the channel down to the quietest one.
    public var level: Double

    public init(filters: [CalibrationFilter], delay: Double = 0, level: Double = 0) {
        self.filters = filters
        self.delay = delay
        self.level = level
    }
}

/// A measured curve as saved: its levels on `CalibrationGrid`, to 0.01 dB.
public struct CalibrationMeasurement: Codable, Hashable, Sendable {
    public var channel: Int
    /// Which position (nil: the channel's average over its positions).
    public var position: Int?
    public var levels: [Double]

    public init(channel: Int, position: Int?, curve: CalibrationCurve) {
        self.channel = channel
        self.position = position
        levels = curve.resampled().levels.map { ($0 * 100).rounded() / 100 }
    }

    public var curve: CalibrationCurve { CalibrationCurve(levels: levels) }
}

/// One sweep, analysed: the response at one position for one channel, and when the sound arrived.
public struct CalibrationCapture: Hashable, Sendable {
    /// On `CalibrationGrid`, corrected for the microphone, not smoothed.
    public var curve: CalibrationCurve
    /// Seconds: the devices' latency and the sound's flight (0 when the recording starts exactly as the sound plays).
    public var arrival: Double

    public init(curve: CalibrationCurve, arrival: Double) {
        self.curve = curve
        self.arrival = arrival
    }

    /// A recording of `sweep.samples` (started together with it) turned into its response and arrival.
    public init(recording: [Double], sweep: CalibrationSweep, micCalibration: MicCalibration? = nil) {
        let impulse = sweep.impulseResponse(of: recording)
        let arrival = CalibrationAnalysis.arrival(in: impulse, sampleRate: sweep.sampleRate)
        var curve = CalibrationAnalysis.response(of: impulse, sampleRate: sweep.sampleRate, arrival: arrival)
        if let micCalibration { curve = micCalibration.corrected(curve) }
        self.init(curve: curve, arrival: (arrival - Double(sweep.leadSamples)) / sweep.sampleRate)
    }
}

// MARK: Text files

public enum CalibrationFileError: Error, LocalizedError, Equatable {
    case notText(String)
    case noData(String)
    case badLine(String, line: Int, text: String)
    case unsupportedFilter(String, line: Int, type: String)

    public var errorDescription: String? {
        switch self {
        case .notText(let name): "“\(name)” isn't a text file."
        case .noData(let name): "“\(name)” has nothing Junction can read in it."
        case .badLine(let name, let line, let text): "Line \(line) of “\(name)” can't be read: \(text)"
        case .unsupportedFilter(let name, let line, let type):
            "Line \(line) of “\(name)” has a \(type) filter; Junction uses peaking, shelving and low-pass filters only."
        }
    }

    /// A file's text: UTF-8, or Latin-1 for older files; nil for binary data.
    static func text(of data: Data, name: String) throws -> String {
        guard !data.contains(0) else { throw notText(name) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw notText(name)
    }
}

/// Lines of a text file, numbered from 1, trimmed.
private func numberedLines(_ text: String) -> [(number: Int, text: String)] {
    text.components(separatedBy: CharacterSet.newlines).enumerated().map {
        ($0.offset + 1, $0.element.trimmingCharacters(in: .whitespaces))
    }
}

/// The number at the start of a string ("-1.378dB" → −1.378).
private func leadingNumber(_ text: Substring) -> Double? {
    let number = text.prefix { "0123456789+-.eE".contains($0) }
    return Double(number)
}

extension CalibrationCurve {
    /// Reads "frequency dB [phase]" lines (separated by spaces, tabs, commas or semicolons). Lines starting with `*`,
    /// `#`, `;`, `//` or a quote, and lines starting with a word, are comments or headers; a line mentioning
    /// sensitivity ("Sens Factor =-1.4dB", "Sensitivity: -18.2 dB") gives the sensitivity.
    static func parse(_ text: String, name: String) throws -> (curve: CalibrationCurve, sensitivity: Double?) {
        var points: [(Double, Double)] = []
        var sensitivity: Double?
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;"))
        for (number, line) in numberedLines(text) where !line.isEmpty {
            if let range = line.range(of: "sens", options: .caseInsensitive) {
                let rest = line[range.upperBound...]
                if let equals = rest.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                    sensitivity = leadingNumber(rest[rest.index(after: equals)...].drop { $0 == " " })
                }
                continue
            }
            if ["*", "#", ";", "//", "\""].contains(where: { line.hasPrefix($0) }) { continue }
            let fields = line.components(separatedBy: separators).filter { !$0.isEmpty }
            guard let first = fields.first, let frequency = Double(first) else { continue }  // a header
            guard fields.count >= 2, let level = Double(fields[1]), frequency > 0, frequency.isFinite, level.isFinite else {
                throw CalibrationFileError.badLine(name, line: number, text: line)
            }
            points.append((frequency, level))
        }
        points.sort { $0.0 < $1.0 }
        var unique: [(Double, Double)] = []
        for point in points where point.0 != unique.last?.0 { unique.append(point) }
        guard unique.count >= 2 else { throw CalibrationFileError.noData(name) }
        return (CalibrationCurve(frequencies: unique.map(\.0), levels: unique.map(\.1)), sensitivity)
    }

    /// A measurement exported as text ("frequency dB [phase]" lines), read onto `CalibrationGrid` (the ends hold beyond
    /// the export's range).
    public init(measurementText text: String, name: String) throws {
        self = try Self.parse(text, name: name).curve.resampled()
    }

    public init(measurementFile url: URL) throws {
        let name = url.lastPathComponent
        try self.init(measurementText: CalibrationFileError.text(of: Data(contentsOf: url), name: name), name: name)
    }
}

/// A measuring microphone's calibration: its own response, which is taken out of every measurement.
public struct MicCalibration: Hashable, Sendable {
    public var name: String
    /// dB, when the file gives it (not used for the correction, which is relative).
    public var sensitivity: Double?
    public var curve: CalibrationCurve

    public init(name: String, text: String) throws {
        self.name = name
        (curve, sensitivity) = try CalibrationCurve.parse(text, name: name)
    }

    public init(contentsOf url: URL) throws {
        let name = url.deletingPathExtension().lastPathComponent
        try self.init(name: name, text: CalibrationFileError.text(of: Data(contentsOf: url), name: url.lastPathComponent))
    }

    /// A measurement with the microphone's response taken out (the file's end values hold beyond its range).
    public func corrected(_ measured: CalibrationCurve) -> CalibrationCurve {
        CalibrationCurve(frequencies: measured.frequencies,
                         levels: zip(measured.frequencies, measured.levels).map { $1 - curve.level(at: $0) })
    }
}

/// A parametric EQ preset as text: a "Preamp: -6.2 dB" line and "Filter 1: ON PK Fc 105 Hz Gain -3.4 dB Q 1.41" lines.
/// Peaking (PK), low and high shelves with a Q (LSC, HSC, also LSQ, HSQ), a slope ("LS 6dB", or "S 0.9") or neither
/// (LS, HS: Q 0.707), and 12 dB per octave low-passes with a Q (LPQ) or without (LP: Q 0.707, no gain) are read;
/// switched-off (OFF) filters are kept, switched off. Other lines are ignored.
public struct ParametricPreset: Hashable, Sendable {
    public var preamp: Double
    public var filters: [CalibrationFilter]

    public init(preamp: Double, filters: [CalibrationFilter]) {
        self.preamp = preamp
        self.filters = filters
    }

    public init(contentsOf url: URL) throws {
        let name = url.lastPathComponent
        try self.init(text: CalibrationFileError.text(of: Data(contentsOf: url), name: name), name: name)
    }

    public init(text: String, name: String) throws {
        var preamp: Double?
        var filters: [CalibrationFilter] = []
        for (number, line) in numberedLines(text) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            if key == "preamp" {
                guard let first = fields.first, let value = leadingNumber(first) else {
                    throw CalibrationFileError.badLine(name, line: number, text: line)
                }
                preamp = value
            } else if key == "filter" || key.hasPrefix("filter ") {
                if let filter = try Self.filter(fields, name: name, number: number, line: line) { filters.append(filter) }
            }
        }
        guard preamp != nil || !filters.isEmpty else { throw CalibrationFileError.noData(name) }
        self.init(preamp: preamp ?? 0, filters: filters)
    }

    /// One filter line's fields after "Filter n:"; nil for an empty ("None") or switched-off unsupported filter.
    private static func filter(_ fields: [Substring], name: String, number: Int, line: String) throws -> CalibrationFilter? {
        guard fields.count >= 2 else { return nil }
        let isOn: Bool
        switch fields[0].uppercased() {
        case "ON": isOn = true
        case "OFF": isOn = false
        default: throw CalibrationFileError.badLine(name, line: number, text: line)
        }
        let type = fields[1].uppercased()
        let kind: CalibrationFilter.Kind
        switch type {
        case "PK", "PEQ", "PEAK", "PEAKING": kind = .peaking
        case "LS", "LSC", "LSQ", "LOWSHELF": kind = .lowShelf
        case "HS", "HSC", "HSQ", "HIGHSHELF": kind = .highShelf
        case "LP", "LPQ", "LOWPASS": kind = .lowPass
        case "NONE": return nil
        default:
            guard isOn else { return nil }
            throw CalibrationFileError.unsupportedFilter(name, line: number, type: String(fields[1]))
        }
        var values: [String: Double] = [:]
        var slope: Double?  // dB per octave, after the type ("LS 6dB", "LS 12 dB")
        var i = 2
        if i < fields.count, let value = leadingNumber(fields[i]) {
            slope = value
            i += fields[i].lowercased().hasSuffix("db") ? 1 : 2
        }
        while i < fields.count {
            let key = fields[i].lowercased()
            i += 1
            if key == "bw", i < fields.count, fields[i].lowercased() == "oct" { i += 1 }  // "BW Oct 1.0"
            guard i < fields.count, let value = Double(fields[i]) else { continue }  // units ("Hz", "dB") and words
            values[key] = value
            i += 1
        }
        if kind == .lowPass, let slope, slope != 12 {  // "LP 24dB": not a single biquad
            guard isOn else { return nil }
            throw CalibrationFileError.unsupportedFilter(name, line: number, type: "\(Self.format(slope, 1)) dB/octave \(fields[1])")
        }
        guard let frequency = values["fc"], frequency > 0, let gain = kind == .lowPass ? 0 : values["gain"] else {
            throw CalibrationFileError.badLine(name, line: number, text: line)
        }
        let q: Double
        if let value = values["q"] {
            q = value
        } else if let octaves = values["bw"], octaves > 0 {
            q = pow(2, octaves / 2) / (pow(2, octaves) - 1)
        } else if kind == .lowPass {
            q = 1 / 2.0.squareRoot()
        } else if kind == .peaking {
            throw CalibrationFileError.badLine(name, line: number, text: line)
        } else if let s = values["s"] ?? slope.map({ $0 / 12 }), s > 0 {
            q = CalibrationFilter.shelfQ(slope: min(1, s), gain: gain)
        } else {
            q = 1 / 2.0.squareRoot()
        }
        guard q > 0 else { throw CalibrationFileError.badLine(name, line: number, text: line) }
        return CalibrationFilter(kind, frequency: frequency, gain: gain, q: q, isOn: isOn)
    }

    /// The preset as text: Fc to 0.1 Hz, gains to 0.1 dB, Q to 0.01; shelves and low-passes with their Q (LSC, HSC,
    /// LPQ, which has no gain).
    public var text: String {
        var lines = ["Preamp: \(Self.format(preamp, 1)) dB"]
        for (index, filter) in filters.enumerated() {
            let type = switch filter.kind {
            case .peaking: "PK"
            case .lowShelf: "LSC"
            case .highShelf: "HSC"
            case .lowPass: "LPQ"
            }
            let gain = filter.kind == .lowPass ? "" : "Gain \(Self.format(filter.gain, 1)) dB "
            lines.append("Filter \(index + 1): \(filter.isOn ? "ON" : "OFF") \(type) Fc \(Self.format(filter.frequency, 1)) Hz "
                + "\(gain)Q \(String(format: "%.2f", filter.q))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A number to `decimals` places without trailing zeros ("105", "-3.4").
    private static func format(_ value: Double, _ decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
