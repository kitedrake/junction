import AudioToolbox
import AVFoundation
import Foundation
import JunctionKernel

// Third-party Audio Units ("plugins") in effect chains. The picker lists the effect units installed on the Mac
// (AVAudioUnitComponentManager); a plugin is saved like any other effect, with its name, maker and whole state. The
// router loads plugins out of process where macOS allows it (EffectUnit), times every effect on the audio thread
// (jk_chain_stage_timing) and counts each sink's overloads (jk_renderer_timing); `StallWatch` decides which effects
// to offer for bypass.

/// An installed effect Audio Unit, as the picker shows it.
public struct PluginInfo: Codable, Hashable, Identifiable, Sendable {
    /// Four-character component codes (see `fourCCText`).
    public var type: String
    public var subtype: String
    public var manufacturer: String
    public var name: String
    public var vendor: String
    public var version: String
    /// Whether it has a window of its own (otherwise its parameters show in a generic one).
    public var hasCustomView: Bool

    public init(type: String = "aufx", subtype: String, manufacturer: String, name: String, vendor: String,
                version: String = "", hasCustomView: Bool = false) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.name = name
        self.vendor = vendor
        self.version = version
        self.hasCustomView = hasCustomView
    }

    public var id: String { "\(type) \(subtype) \(manufacturer)" }

    /// Whether `effect` is this plugin.
    public func matches(_ effect: Effect) -> Bool {
        effect.type == type && effect.subtype == subtype && effect.manufacturer == manufacturer
    }
}

public enum PluginCatalog {
    /// The effect Audio Units installed on this Mac (Apple's included), by maker, then name. Off the audio thread.
    public static func installed() -> [PluginInfo] {
        let wanted = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0,
                                               componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        let components = AVAudioUnitComponentManager.shared().components(matching: wanted)
        return sorted(components.map { component in
            let description = component.audioComponentDescription
            return PluginInfo(type: fourCCText(description.componentType), subtype: fourCCText(description.componentSubType),
                              manufacturer: fourCCText(description.componentManufacturer), name: component.name,
                              vendor: component.manufacturerName, version: component.versionString,
                              hasCustomView: component.hasCustomView)
        })
    }

    static func sorted(_ plugins: [PluginInfo]) -> [PluginInfo] {
        plugins.sorted {
            let vendor = $0.vendor.localizedStandardCompare($1.vendor)
            return vendor == .orderedSame ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                          : vendor == .orderedAscending
        }
    }

    /// The plugins whose name or maker contain every word of `query` (ignoring case and accents); all of them for an
    /// empty query.
    public static func search(_ plugins: [PluginInfo], for query: String) -> [PluginInfo] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return plugins }
        return plugins.filter { plugin in
            let text = plugin.name + " " + plugin.vendor
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Whether the effect's Audio Unit is installed (built-in effects always are).
    public static func isInstalled(_ effect: Effect) -> Bool {
        if effect.kind?.isBuiltIn == true { return true }
        guard var description = effect.component else { return false }
        return AudioComponentFindNext(nil, &description) != nil
    }
}

/// What an effect costs where it runs, as the router last measured it.
public struct EffectCost: Codable, Equatable, Sendable {
    /// The share of real time its rendering took since the last measurement (0.02 = 2 % of one CPU core).
    public var load: Double
    /// The largest share of one buffer's duration a single render took since the last measurement.
    public var peak: Double
    /// Renders that took more than half of their buffer's duration (JK_STALL_LOAD) since its chain was built.
    public var stalls: Int
    /// The delay it adds (an Audio Unit's kAudioUnitProperty_Latency), in seconds.
    public var latency: TimeInterval
    /// Whether it runs in a process of its own.
    public var outOfProcess: Bool

    public init(load: Double, peak: Double, stalls: Int, latency: TimeInterval = 0, outOfProcess: Bool = false) {
        self.load = load
        self.peak = peak
        self.stalls = stalls
        self.latency = latency
        self.outOfProcess = outOfProcess
    }

    /// The cost from two readings of a stage's timing at `sampleRate` (`previous` nil, or from a chain built since:
    /// everything so far). Loads are rounded to 0.1 %, so statuses don't change for noise.
    static func measure(_ timing: JKTiming, since previous: JKTiming?, sampleRate: Double, latency: TimeInterval = 0,
                        outOfProcess: Bool = false) -> EffectCost {
        var frames = timing.frames, seconds = timing.seconds
        if let previous, previous.frames <= timing.frames, previous.late <= timing.late {
            frames -= previous.frames
            seconds -= previous.seconds
        }
        let audio = sampleRate > 0 ? Double(frames) / sampleRate : 0
        func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        return EffectCost(load: audio > 0 ? rounded(max(0, seconds) / audio) : 0, peak: rounded(Double(timing.peakLoad)),
                          stalls: Int(timing.late), latency: latency, outOfProcess: outOfProcess)
    }
}

/// Decides which effects to offer for bypass. An effect holds up the audio thread when its renders keep taking more
/// than half of their buffer's duration: `stallLimit` such stalls within `window`, or one render longer than a whole
/// buffer while its sink overloaded. Bypassed effects aren't offered; an effect that stops stalling stops being offered
/// once its stalls are older than the window.
public struct StallWatch: Sendable {
    public static let window: TimeInterval = 10
    public static let stallLimit = 3

    struct Sample {
        var date: Date
        var stalls: Int
        var peak: Double
        var overloads: Int
    }

    /// The last cumulative counts seen, per effect, and per sink.
    private var lastStalls: [UUID: UInt64] = [:]
    private var lastOverloads: [UUID: UInt64] = [:]
    private var samples: [UUID: [Sample]] = [:]

    public init() {}

    /// Whether these counts within the window make an effect a suspect.
    public static func shouldOffer(stalls: Int, peak: Double, overloads: Int) -> Bool {
        stalls >= stallLimit || (peak >= 1 && overloads > 0)
    }

    /// Records one measurement of `effect`: its stall count and its sink's overload count so far (counts that went
    /// down belong to a rebuilt chain or sink and count from zero), and its peak load since the last one.
    public mutating func record(effect: UUID, stalls: UInt64, peak: Double, sinkOverloads: UInt64, at date: Date) {
        let previousStalls = lastStalls[effect] ?? 0
        let newStalls = stalls >= previousStalls ? stalls - previousStalls : stalls
        lastStalls[effect] = stalls
        // Kept per effect: the sink overloading since this effect's last measurement.
        let previousOverloads = lastOverloads[effect] ?? 0
        let newOverloads = sinkOverloads >= previousOverloads ? sinkOverloads - previousOverloads : sinkOverloads
        lastOverloads[effect] = sinkOverloads
        var list = samples[effect, default: []].filter { date.timeIntervalSince($0.date) < Self.window }
        list.append(Sample(date: date, stalls: Int(newStalls), peak: peak, overloads: Int(newOverloads)))
        samples[effect] = list
    }

    /// The effects to offer for bypass at `date`, leaving out `bypassed` ones.
    public func offers(at date: Date, bypassed: Set<UUID> = []) -> Set<UUID> {
        var result = Set<UUID>()
        for (effect, list) in samples where !bypassed.contains(effect) {
            let recent = list.filter { date.timeIntervalSince($0.date) < Self.window }
            let stalls = recent.reduce(0) { $0 + $1.stalls }
            let late = recent.contains { $0.peak >= 1 && $0.overloads > 0 }
            if Self.shouldOffer(stalls: stalls, peak: late ? 1 : 0, overloads: late ? 1 : 0) { result.insert(effect) }
        }
        return result
    }

    /// Forgets effects that no longer run.
    public mutating func keep(_ effects: Set<UUID>) {
        samples = samples.filter { effects.contains($0.key) }
        lastStalls = lastStalls.filter { effects.contains($0.key) }
        lastOverloads = lastOverloads.filter { effects.contains($0.key) }
    }
}
