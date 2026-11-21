import AudioToolbox
import Foundation
import JunctionKernel

// Effects on nodes. A source's chain processes its channels before they are mixed into the virtual device; the
// virtual device's chain processes the mix before it goes into the device; an output's chain processes what it
// receives. Gain, pan, mono and the noise gate are built into the render kernel; high-pass, EQ, dynamics and the
// limiter are Apple's Audio Units, rendered by the kernel through AudioUnitRender. Everything here that creates or
// configures a unit runs off the audio thread (the router's queue, or the app for saving a unit's state).

/// One effect in a node's chain, as saved: the Audio Unit component it is (built-in effects have codes of their own),
/// its bypass, the parameters set in Junction and, for Audio Units, the unit's whole state.
public struct Effect: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Four-character component codes: type, subtype, manufacturer.
    public var type: String
    public var subtype: String
    public var manufacturer: String
    public var bypass: Bool
    /// Parameter values by parameter ID ("0", "1000"…): the built-in effects' settings, and the parameters changed on
    /// an Audio Unit (applied after its state, and while it runs).
    public var parameters: [String: Double]
    /// An Audio Unit's state (kAudioUnitProperty_ClassInfo) as a binary property list; restored when its unit is made.
    public var state: Data?

    public init(id: UUID = UUID(), type: String, subtype: String, manufacturer: String, bypass: Bool = false,
                parameters: [String: Double] = [:], state: Data? = nil) {
        self.id = id
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.bypass = bypass
        self.parameters = parameters
        self.state = state
    }

    /// A new effect of a kind, with its starting settings.
    public init(_ kind: EffectKind) {
        let codes = kind.codes
        self.init(type: codes.type, subtype: codes.subtype, manufacturer: codes.manufacturer, parameters: kind.setup)
    }

    public var kind: EffectKind? { EffectKind(type: type, subtype: subtype, manufacturer: manufacturer) }

    /// A parameter's value: as set, or the effect's default.
    public func value(_ parameter: EffectParameter) -> Double {
        parameters[String(parameter.id)] ?? parameter.defaultValue
    }

    public mutating func set(_ parameter: EffectParameter, _ value: Double) {
        parameters[String(parameter.id)] = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
    }

    /// The parameters as Audio Unit parameter IDs.
    var unitParameters: [(AudioUnitParameterID, Float)] {
        parameters.compactMap { key, value in UInt32(key).map { ($0, Float(value)) } }.sorted { $0.0 < $1.0 }
    }
}

/// The effects Junction offers.
public enum EffectKind: String, CaseIterable, Sendable {
    case gain, pan, mono, gate, highPass, equalizer, dynamics, limiter

    public var title: String {
        switch self {
        case .gain: "Gain"
        case .pan: "Pan"
        case .mono: "Mono"
        case .gate: "Noise Gate"
        case .highPass: "High-Pass Filter"
        case .equalizer: "Equalizer"
        case .dynamics: "Compressor"
        case .limiter: "Limiter"
        }
    }

    public var symbol: String {
        switch self {
        case .gain: "speaker.wave.2"
        case .pan: "arrow.left.and.right"
        case .mono: "circle.circle"
        case .gate: "door.left.hand.closed"
        case .highPass: "line.diagonal.arrow"
        case .equalizer: "slider.vertical.3"
        case .dynamics: "arrow.down.right.and.arrow.up.left"
        case .limiter: "rectangle.compress.vertical"
        }
    }

    /// Built into the render kernel (no Audio Unit).
    public var isBuiltIn: Bool { kernelKind != nil }

    var kernelKind: JKEffectKind? {
        switch self {
        case .gain: JK_EFFECT_GAIN
        case .pan: JK_EFFECT_PAN
        case .mono: JK_EFFECT_MONO
        case .gate: JK_EFFECT_GATE
        default: nil
        }
    }

    static let builtInType = "aufx", builtInManufacturer = "Jnct"

    var codes: (type: String, subtype: String, manufacturer: String) {
        switch self {
        case .gain: (Self.builtInType, "gain", Self.builtInManufacturer)
        case .pan: (Self.builtInType, "pan ", Self.builtInManufacturer)
        case .mono: (Self.builtInType, "mono", Self.builtInManufacturer)
        case .gate: (Self.builtInType, "gate", Self.builtInManufacturer)
        case .highPass: ("aufx", "hpas", "appl")
        case .equalizer: ("aufx", "nbeq", "appl")
        case .dynamics: ("aufx", "dcmp", "appl")
        case .limiter: ("aufx", "lmtr", "appl")
        }
    }

    init?(type: String, subtype: String, manufacturer: String) {
        guard let kind = Self.allCases.first(where: { $0.codes == (type, subtype, manufacturer) }) else { return nil }
        self = kind
    }

    /// The Audio Unit to make (nil for built-in effects).
    public var component: AudioComponentDescription? {
        guard !isBuiltIn else { return nil }
        let codes = self.codes
        return AudioComponentDescription(componentType: fourCC(codes.type), componentSubType: fourCC(codes.subtype),
                                         componentManufacturer: fourCC(codes.manufacturer), componentFlags: 0,
                                         componentFlagsMask: 0)
    }

    /// Bands of the equalizer: a low shelf, a bell and a high shelf.
    static let equalizerBands = 3

    /// The parameters the inspector shows, with Apple's ranges and defaults for its units.
    public var parameters: [EffectParameter] {
        switch self {
        case .gain: [EffectParameter(id: 0, name: "Level", range: -60...24, defaultValue: 0, unit: .decibels)]
        case .pan: [EffectParameter(id: 0, name: "Balance", range: -1...1, defaultValue: 0, unit: .balance)]
        case .mono: []
        case .gate:
            [EffectParameter(id: 0, name: "Threshold", range: -80...0, defaultValue: -40, unit: .decibels),
             EffectParameter(id: 1, name: "Release", range: 0.02...2, defaultValue: 0.15, unit: .seconds)]
        case .highPass:
            [EffectParameter(id: UInt32(kHipassParam_CutoffFrequency), name: "Cutoff", range: 10...2000, defaultValue: 80,
                             unit: .hertz),
             EffectParameter(id: UInt32(kHipassParam_Resonance), name: "Resonance", range: -20...20, defaultValue: 0,
                             unit: .decibels)]
        case .equalizer:
            [("Low", 100.0), ("Mid", 1000.0), ("High", 8000.0)].enumerated().flatMap { band, entry in
                [EffectParameter(id: UInt32(kAUNBandEQParam_Gain) + UInt32(band), name: "\(entry.0) gain",
                                 range: -24...24, defaultValue: 0, unit: .decibels),
                 EffectParameter(id: UInt32(kAUNBandEQParam_Frequency) + UInt32(band), name: "\(entry.0) frequency",
                                 range: 20...20000, defaultValue: entry.1, unit: .hertz)]
            }
        case .dynamics:
            [EffectParameter(id: UInt32(kDynamicsProcessorParam_Threshold), name: "Threshold", range: -40...20,
                             defaultValue: -20, unit: .decibels),
             EffectParameter(id: UInt32(kDynamicsProcessorParam_HeadRoom), name: "Headroom", range: 0.1...40,
                             defaultValue: 5, unit: .decibels),
             EffectParameter(id: UInt32(kDynamicsProcessorParam_AttackTime), name: "Attack", range: 0.0001...0.2,
                             defaultValue: 0.001, unit: .seconds),
             EffectParameter(id: UInt32(kDynamicsProcessorParam_ReleaseTime), name: "Release", range: 0.01...3,
                             defaultValue: 0.05, unit: .seconds),
             EffectParameter(id: UInt32(kDynamicsProcessorParam_OverallGain), name: "Make-up gain", range: -40...40,
                             defaultValue: 0, unit: .decibels)]
        case .limiter:
            [EffectParameter(id: UInt32(kLimiterParam_PreGain), name: "Input gain", range: -40...40, defaultValue: 0,
                             unit: .decibels),
             EffectParameter(id: UInt32(kLimiterParam_AttackTime), name: "Attack", range: 0.001...0.03,
                             defaultValue: 0.012, unit: .seconds),
             EffectParameter(id: UInt32(kLimiterParam_DecayTime), name: "Release", range: 0.001...0.06,
                             defaultValue: 0.024, unit: .seconds)]
        }
    }

    /// Settings a new effect starts with beyond the defaults: the equalizer's bands switched on, as shelves and a bell.
    var setup: [String: Double] {
        switch self {
        case .highPass: ["\(kHipassParam_CutoffFrequency)": 80]
        case .equalizer:
            (0..<Self.equalizerBands).reduce(into: [:]) { values, band in
                values["\(Int(kAUNBandEQParam_BypassBand) + band)"] = 0
                values["\(Int(kAUNBandEQParam_FilterType) + band)"] =
                    Double([kAUNBandEQFilterType_LowShelf, kAUNBandEQFilterType_Parametric, kAUNBandEQFilterType_HighShelf][band])
                values["\(Int(kAUNBandEQParam_Frequency) + band)"] = [100.0, 1000.0, 8000.0][band]
                values["\(Int(kAUNBandEQParam_Bandwidth) + band)"] = 1
                values["\(Int(kAUNBandEQParam_Gain) + band)"] = 0
            }
        default: [:]
        }
    }
}

public struct EffectParameter: Sendable, Identifiable, Hashable {
    public enum Unit: Sendable, Hashable { case decibels, hertz, seconds, balance }

    public var id: UInt32
    public var name: String
    public var range: ClosedRange<Double>
    public var defaultValue: Double
    public var unit: Unit

    /// "−12.0 dB", "80 Hz", "1.2 kHz", "150 ms", "L 30", "Center".
    public func text(_ value: Double) -> String {
        switch unit {
        case .decibels: return Gain.text(value).replacingOccurrences(of: "−∞ dB", with: String(format: "%.1f dB", value))
        case .hertz: return value >= 1000 ? String(format: "%.1f kHz", value / 1000) : "\(Int(value.rounded())) Hz"
        case .seconds: return value < 1 ? String(format: value < 0.01 ? "%.1f ms" : "%.0f ms", value * 1000) : String(format: "%.2f s", value)
        case .balance:
            let percent = Int((abs(value) * 100).rounded())
            return percent == 0 ? "Center" : (value < 0 ? "L \(percent)" : "R \(percent)")
        }
    }

    /// Frequencies and times move along a logarithmic scale on a slider.
    public var isLogarithmic: Bool { (unit == .hertz || unit == .seconds) && range.lowerBound > 0 }
}

func fourCC(_ text: String) -> OSType {
    text.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
}

// MARK: Audio Units

public enum EffectError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case failed(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) isn't available on this Mac."
        case .failed(let name, let status): "\(name) couldn't start (\(HAL.describe(status)))."
        }
    }
}

/// An Apple effect unit, set up for the kernel's chains: non-interleaved float channels at a fixed rate, room for
/// JK_MAX_FRAMES per render, its input callback and buffers made (`kernel`). Freed when the last chain using it is.
public final class EffectUnit: @unchecked Sendable {
    public let unit: AudioUnit
    /// The kernel's side (a JKUnit).
    let kernel: OpaquePointer
    public let kind: EffectKind
    public let channels: Int
    public let sampleRate: Double
    /// Parameter values applied so far, so only changes are sent.
    private var applied: [AudioUnitParameterID: Float] = [:]

    /// Makes, configures and initialises the unit, restores `effect.state` and applies its parameters.
    public init(_ effect: Effect, channels: Int, sampleRate: Double) throws {
        guard let kind = effect.kind, let description = kind.component else {
            throw EffectError.notInstalled(effect.kind?.title ?? "\(effect.manufacturer) \(effect.subtype)")
        }
        var unit: AudioUnit?
        var componentDescription = description
        guard let component = AudioComponentFindNext(nil, &componentDescription) else { throw EffectError.notInstalled(kind.title) }
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw EffectError.failed(kind.title, status) }
        func fail(_ status: OSStatus) -> EffectError {
            AudioComponentInstanceDispose(unit)
            return EffectError.failed(kind.title, status)
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard status == noErr else { throw fail(status) }
        }
        var maximumFrames = UInt32(JK_MAX_FRAMES)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                      &maximumFrames, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw fail(status) }
        if kind == .equalizer {
            var bands = UInt32(EffectKind.equalizerBands)
            AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands,
                                 UInt32(MemoryLayout<UInt32>.size))
        }
        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw fail(status) }
        if let state = effect.state { _ = Self.restore(state, into: unit) }
        guard let kernel = jk_unit_create(unit, UInt32(channels)) else {
            AudioUnitUninitialize(unit)
            throw fail(kAudio_MemFullError)
        }
        self.unit = unit
        self.kernel = kernel
        self.kind = kind
        self.channels = channels
        self.sampleRate = sampleRate
        apply(effect)
    }

    deinit {
        jk_unit_destroy(kernel)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Sends the parameters that changed since the last call (safe while it renders).
    public func apply(_ effect: Effect) {
        for (id, value) in effect.unitParameters where applied[id] != value {
            if AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0) == noErr { applied[id] = value }
        }
    }

    public func parameter(_ id: AudioUnitParameterID) -> Float? {
        var value: AudioUnitParameterValue = 0
        return AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &value) == noErr ? value : nil
    }

    /// The delay the unit adds (kAudioUnitProperty_Latency), in seconds.
    public var latency: TimeInterval {
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
        return status == noErr && seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// The unit's whole state (kAudioUnitProperty_ClassInfo) as a binary property list.
    public var state: Data? {
        var list: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &list, &size) == noErr,
              let plist = list?.takeRetainedValue()
        else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// Puts a saved state back. Only off the audio thread, before the unit renders.
    static func restore(_ state: Data, into unit: AudioUnit) -> Bool {
        guard let object = try? PropertyListSerialization.propertyList(from: state, format: nil) else { return false }
        var plist = object as CFPropertyList
        return AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist,
                                    UInt32(MemoryLayout<CFPropertyList>.size)) == noErr
    }

    /// Renders `frames` frames of non-interleaved channels in place through the kernel's unit stage (for tests and the
    /// self-test; the router renders units inside chains).
    public func process(_ channels: [UnsafeMutablePointer<Float>], frames: Int) {
        channels.withUnsafeBufferPointer { pointers in
            jk_unit_process(UnsafeMutableRawPointer(kernel), pointers.baseAddress!, UInt32(channels.count), UInt32(frames))
        }
    }

    /// Renders that failed so far (the audio passed through).
    public var errorCount: UInt64 { jk_unit_error_count(kernel) }

    /// The state an effect would be saved with: a unit is made (not rendered) with its state and parameters, and its
    /// ClassInfo read back. Nil for built-in effects, or when the unit isn't available.
    public static func capturedState(_ effect: Effect) -> Data? {
        guard effect.kind?.isBuiltIn == false, let unit = try? EffectUnit(effect, channels: 2, sampleRate: 48_000) else { return nil }
        return unit.state
    }
}

// MARK: Chains

/// Where a chain runs: before the mix on a source's channels, or after it on the sink's.
public enum ChainPosition: String, Hashable, Sendable { case source, mix }

/// Keeps Audio Units alive and configured across sink rebuilds and chain changes, by effect and where it runs. Only on
/// the router's queue.
final class EffectPool {
    struct Key: Hashable {
        var effect: UUID
        var position: ChainPosition
    }

    private var units: [Key: EffectUnit] = [:]
    private(set) var problems: [UUID: String] = [:]

    /// The unit for an effect, made if needed, or remade when the channels or rate changed (a running unit is never
    /// reconfigured: an older chain may still render it). Nil, with the reason in `problems`, when it can't be made.
    func unit(for effect: Effect, position: ChainPosition, channels: Int, sampleRate: Double) -> EffectUnit? {
        let key = Key(effect: effect.id, position: position)
        if let unit = units[key], unit.kind == effect.kind, unit.channels == channels, unit.sampleRate == sampleRate {
            unit.apply(effect)
            return unit
        }
        var seeded = effect
        if let old = units[key], old.kind == effect.kind, let state = old.state { seeded.state = state }  // keep its settings
        do {
            let unit = try EffectUnit(seeded, channels: channels, sampleRate: sampleRate)
            units[key] = unit
            problems[effect.id] = nil
            return unit
        } catch {
            units[key] = nil
            problems[effect.id] = error.localizedDescription
            return nil
        }
    }

    /// Lets go of units no chain asks for any more (chains still holding one keep it alive until they are freed).
    func keep(_ keys: Set<Key>) {
        units = units.filter { keys.contains($0.key) }
        let effects = Set(keys.map(\.effect))
        problems = problems.filter { effects.contains($0.key) }
    }

    var count: Int { units.count }
}

extension SinkPlan {
    /// The units this sink's chains use.
    var effectKeys: [EffectPool.Key] {
        slots.flatMap { $0.effects.map { EffectPool.Key(effect: $0.id, position: .source) } }
            + effects.map { EffectPool.Key(effect: $0.id, position: .mix) }
    }
}

/// A chain as built for a renderer: the kernel's chain, the units in it (kept alive with it), which stage each effect
/// became, and what it was built from.
final class LiveChain {
    let pointer: OpaquePointer
    let units: [EffectUnit]
    /// Stage index per effect (nil: the effect couldn't be made and is left out).
    let stages: [Int32?]
    let effects: [Effect]
    let latency: TimeInterval

    /// Builds a chain for `channels` channels, or nil when no effect in it could be made.
    init?(_ effects: [Effect], position: ChainPosition, channels: Int, sampleRate: Double, pool: EffectPool) {
        guard !effects.isEmpty, channels > 0,
              let chain = jk_chain_create(UInt32(channels), sampleRate > 0 ? sampleRate : 48_000, UInt32(effects.count))
        else { return nil }
        var units: [EffectUnit] = [], stages: [Int32?] = []
        var latency: TimeInterval = 0
        for effect in effects {
            var stage: Int32 = -1
            if let kind = effect.kind?.kernelKind {
                stage = jk_chain_add(chain, kind)
            } else if let unit = pool.unit(for: effect, position: position, channels: channels, sampleRate: sampleRate) {
                stage = jk_chain_add_unit(chain, unit.kernel)
                if stage >= 0 {
                    units.append(unit)
                    latency += unit.latency
                }
            }
            stages.append(stage >= 0 ? stage : nil)
        }
        guard stages.contains(where: { $0 != nil }) else {
            jk_chain_destroy(chain)
            return nil
        }
        pointer = chain
        self.units = units
        self.stages = stages
        self.effects = effects
        self.latency = latency
        update(effects, pool: nil, position: position)
    }

    deinit { jk_chain_destroy(pointer) }

    /// Whether `effects` can be applied to this chain without building another (the same effects in the same order).
    func fits(_ effects: [Effect]) -> Bool {
        effects.map(\.id) == self.effects.map(\.id) && effects.map(\.kind) == self.effects.map(\.kind)
    }

    /// Bypass and parameters: atomics for built-in effects, AudioUnitSetParameter for units.
    func update(_ effects: [Effect], pool: EffectPool?, position: ChainPosition) {
        var unitIndex = 0
        for (effect, stage) in zip(effects, stages) {
            guard let stage else { continue }
            jk_chain_set_bypass(pointer, UInt32(stage), effect.bypass ? 1 : 0)
            if let kind = effect.kind, kind.isBuiltIn {
                for (index, value) in Self.kernelParameters(kind, effect).enumerated() {
                    jk_chain_set_parameter(pointer, UInt32(stage), UInt32(index), value)
                }
            } else if unitIndex < units.count {
                units[unitIndex].apply(effect)
                unitIndex += 1
            }
        }
    }

    /// A built-in effect's settings as the kernel takes them (linear levels, seconds).
    static func kernelParameters(_ kind: EffectKind, _ effect: Effect) -> [Float] {
        let values = kind.parameters.map { effect.value($0) }
        switch kind {
        case .gain: return [Gain.linear(values[0])]
        case .pan: return [Float(values[0])]
        case .gate: return [Float(pow(10, values[0] / 20)), Float(values[1])]
        default: return []
        }
    }
}
