import CoreAudio
import Foundation
import JunctionKernel
import os

/// How one sink is doing.
public struct SinkStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, failed }
    public var state: State
    public var message: String?
    /// While running: roughly how long audio takes from the sink's sources to the sink (seconds), and the buffer size
    /// macOS gave its routing (frames).
    public var latency: TimeInterval?
    public var bufferFrames: Int?

    public init(state: State, message: String? = nil, latency: TimeInterval? = nil, bufferFrames: Int? = nil) {
        self.state = state
        self.message = message
        self.latency = latency
        self.bufferFrames = bufferFrames
    }
}

/// A node channel for meters: `isOutput` is the node's right side.
public struct PortKey: Hashable, Sendable {
    public var node: UUID
    public var isOutput: Bool
    public var channel: Int

    public init(node: UUID, isOutput: Bool, channel: Int) {
        self.node = node
        self.isOutput = isOutput
        self.channel = channel
    }
}

/// Builds and runs what a RoutingPlan describes: per sink, process taps, a private aggregate device and an IOProc.
/// All Core Audio work happens on the router's own queue; meters can be read from any thread.
public final class Router: @unchecked Sendable {
    public typealias StatusHandler = @Sendable ([UUID: SinkStatus]) -> Void

    private let queue = DispatchQueue(label: "local.junction.router", qos: .userInitiated)
    private let lock = NSLock()
    private var runners: [UUID: SinkRunner] = [:]  // mutated on `queue`, under `lock`
    private var statuses: [UUID: SinkStatus] = [:]  // `queue` only
    private let onStatus: StatusHandler
    // `queue` only from here on.
    private var lastPlan = RoutingPlan()
    /// Sinks that failed to build or stopped running, and when to try again.
    private var failures: [UUID: Failure] = [:]
    private var retry: DispatchWorkItem?
    /// IO cycles per running sink at the last health check, and how many checks in a row they didn't move.
    private var progress: [UUID: (cycles: UInt64, still: Int)] = [:]
    private var healthTimer: DispatchSourceTimer?
    static let log = Logger(subsystem: "local.junction", category: "routing")
    private let events: EventLog

    struct Failure {
        var key: String
        var count: Int
        var next: Date
    }

    /// Waits before each new attempt at a sink that keeps failing (the last one repeats).
    static let retryDelays: [TimeInterval] = [2, 4, 8, 16, 32, 60]
    /// How long to wait after the `attempt`th failure in a row (counting from 1).
    public static func retryDelay(attempt: Int) -> TimeInterval {
        retryDelays[min(max(attempt, 1), retryDelays.count) - 1]
    }

    /// A sink whose IO hasn't moved for this many health checks (2 s apart) is rebuilt.
    static let stalledChecks = 2
    /// A sink that has run this long since its last failure starts again from the shortest retry delay.
    static let healthyAfter: TimeInterval = 30

    public init(events: EventLog = .shared, onStatus: @escaping StatusHandler) {
        self.events = events
        self.onStatus = onStatus
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthTimer = timer
    }

    deinit {
        healthTimer?.cancel()
    }

    /// How long a rebuilt sink and its replacement overlap, fading out and in.
    static let crossFadeSeconds = 0.025

    /// Brings the running sinks in line with the plan: unchanged sinks only get new gains; changed ones are rebuilt
    /// next to the running one and cross-faded with it, so edits don't leave a gap or click.
    public func apply(_ plan: RoutingPlan) {
        queue.async { self.applyNow(plan) }
    }

    /// After Core Audio restarts every tap, aggregate device and IOProc is gone (and their IDs may soon name other
    /// objects): drop all sinks without calling Core Audio. The next `apply` builds them again.
    public func forgetAfterRestart() {
        queue.async {
            self.lock.lock()
            let old = self.runners
            self.runners = [:]
            self.lock.unlock()
            for runner in old.values { runner.forget() }
            self.statuses = [:]
            self.failures = [:]
            self.progress = [:]
            self.retry?.cancel()
            self.onStatus(self.statuses)
        }
    }

    /// Stops everything and waits until it has stopped.
    public func stopAll() {
        queue.sync { self.applyNow(RoutingPlan()) }
    }

    /// Builds every sink again (cross-faded) and retries failed ones at once, e.g. after a permission was granted:
    /// a sink that started without it may be running on silence.
    public func rebuildAll() {
        queue.async {
            self.failures = [:]
            if !self.lastPlan.sinks.isEmpty { self.events.add(.info, "Rebuilding every destination") }
            self.applyNow(self.lastPlan, rebuildingAll: true)
        }
    }

    /// After the Mac wakes, IO takes a moment to resume: start counting stalls afresh.
    public func resetHealth() {
        queue.async { self.progress = [:] }
    }

    /// Re-resolves which processes each tap includes or leaves out (an app started or quit).
    public func processesChanged() {
        queue.async {
            let processes = HAL.audioProcesses()
            self.lock.lock()
            let current = Array(self.runners.values)
            self.lock.unlock()
            for runner in current {
            for change in runner.refreshTaps(processes: processes) { self.events.add(.info, change) }
        }
        }
    }

    /// Peak levels since the last call, per node channel that is in use.
    public func takeMeters() -> [PortKey: Float] {
        lock.lock()
        defer { lock.unlock() }
        var result: [PortKey: Float] = [:]
        for runner in runners.values {
            for (key, value) in runner.takeMeters() { result[key] = max(result[key] ?? 0, value) }
        }
        return result
    }

    private func applyNow(_ plan: RoutingPlan, rebuildingAll: Bool = false) {
        lastPlan = plan
        let wanted = Dictionary(plan.sinks.map { ($0.sinkNode, $0) }, uniquingKeysWith: { first, _ in first })
        var retiring: [SinkRunner] = []
        func retire(_ id: UUID) {
            lock.lock()
            let runner = runners.removeValue(forKey: id)
            lock.unlock()
            guard let runner else { return }
            runner.fadeOut()
            retiring.append(runner)
        }
        for (id, runner) in runners where wanted[id] == nil {
            events.add(.info, "\(runner.plan.name): stopped")
            retire(id)
        }
        statuses = statuses.filter { wanted[$0.key] != nil }
        failures = failures.filter { wanted[$0.key]?.structureKey == $0.value.key }
        let now = Date()
        var processes: [HAL.AudioProcess]?
        for sink in plan.sinks {
            if let runner = runners[sink.sinkNode], runner.plan.structureKey == sink.structureKey, !rebuildingAll {
                runner.update(gains: sink)
                continue
            }
            // A sink that keeps failing waits for its next attempt; its status keeps the reason.
            if let failure = failures[sink.sinkNode], failure.next > now, runners[sink.sinkNode] == nil { continue }
            // Build the replacement while the old sink keeps playing, then swap them over with a cross-fade.
            if processes == nil, !sink.taps.isEmpty { processes = HAL.audioProcesses() }
            guard let runner = SinkRunner(plan: sink) else {
                retire(sink.sinkNode)
                statuses[sink.sinkNode] = SinkStatus(state: .failed, message: "Out of memory.")
                continue
            }
            do {
                try runner.start(processes: processes ?? [], fadingIn: true)
                let replacing = runners[sink.sinkNode] != nil
                retire(sink.sinkNode)
                lock.lock()
                runners[sink.sinkNode] = runner
                lock.unlock()
                progress[sink.sinkNode] = nil
                statuses[sink.sinkNode] = SinkStatus(state: .running, message: runner.layoutWarning,
                                                     latency: runner.latency, bufferFrames: runner.bufferFrames)
                events.add(.info, "\(sink.name): \(replacing ? "rebuilt" : "started"). \(runner.summary)")
                if let warning = runner.layoutWarning { events.add(.warning, "\(sink.name): \(warning)") }
            } catch {
                runner.stop()
                retire(sink.sinkNode)
                recordFailure(sink, error.localizedDescription)
            }
        }
        onStatus(statuses)
        Self.stopAfterFading(retiring)
        scheduleRetry()
    }

    /// Marks a sink failed and picks when to try it again: sooner at first, then less and less often.
    private func recordFailure(_ sink: SinkPlan, _ reason: String) {
        let count = (failures[sink.sinkNode]?.count ?? 0) + 1
        let delay = Self.retryDelay(attempt: count)
        failures[sink.sinkNode] = Failure(key: sink.structureKey, count: count, next: Date().addingTimeInterval(delay))
        let reason = reason.hasSuffix(".") ? reason : reason + "."
        statuses[sink.sinkNode] = SinkStatus(state: .failed, message: "\(reason) Trying again in \(Int(delay)) s.")
        Self.log.error("\(sink.name, privacy: .public): \(reason, privacy: .public) Attempt \(count), next in \(Int(delay)) s")
        events.add(.error, "\(sink.name): \(reason) Attempt \(count); trying again in \(Int(delay)) s.")
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = nil
        guard let soonest = failures.values.filter({ $0.next > Date() }).map(\.next).min() else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyNow(self.lastPlan)
        }
        retry = item
        queue.asyncAfter(deadline: .now() + max(0.05, soonest.timeIntervalSinceNow), execute: item)
    }

    /// Every 2 s: a sink whose IO has stopped moving (after sleep, a device hiccup, a driver that stopped) is torn
    /// down and built again, with the same growing delays as a sink that fails to build.
    private func checkHealth() {
        lock.lock()
        let current = runners
        lock.unlock()
        progress = progress.filter { current[$0.key] != nil }
        var stalled: [UUID] = []
        for (id, runner) in current {
            let cycles = runner.cycles
            if let last = progress[id], last.cycles == cycles {
                progress[id] = (cycles, last.still + 1)
                if last.still + 1 >= Self.stalledChecks { stalled.append(id) }
            } else {
                progress[id] = (cycles, 0)
                if let failure = failures[id], Date().timeIntervalSince(runner.startedAt) > Self.healthyAfter,
                   failure.next < Date() {
                    failures[id] = nil
                }
            }
        }
        guard !stalled.isEmpty else { return }
        for id in stalled {
            lock.lock()
            let runner = runners.removeValue(forKey: id)
            lock.unlock()
            guard let runner else { continue }
            runner.stop()  // no fade: it isn't rendering
            progress[id] = nil
            Self.log.error("\(runner.plan.name, privacy: .public): audio stopped; rebuilding")
            events.add(.error, "\(runner.plan.name): audio stopped moving (no IO for \(Self.stalledChecks * 2) s); rebuilding")
            recordFailure(runner.plan, "Audio stopped")
            if failures[id]?.count == 1 {  // the first rebuild happens straight away
                failures[id]?.next = Date()
                statuses[id] = SinkStatus(state: .failed, message: "Audio stopped. Restarting…")
            }
        }
        applyNow(lastPlan)
    }

    /// Waits until the retiring sinks have faded out (or a short deadline passes, e.g. when a device stopped
    /// calling its IOProc), then tears them down.
    static func stopAfterFading(_ retiring: [SinkRunner]) {
        guard !retiring.isEmpty else { return }
        let deadline = Date().addingTimeInterval(crossFadeSeconds + 0.2)
        while Date() < deadline, retiring.contains(where: { !$0.isSilent }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        for runner in retiring { runner.stop() }
    }
}

enum RouterError: Error, LocalizedError {
    case tap(String, OSStatus)
    case aggregate(OSStatus)
    case start(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tap(let name, let status):
            "Couldn't capture \(name) (\(HAL.describe(status))). Check System Settings › Privacy & Security › Screen & System Audio Recording."
        case .aggregate(let status): "Couldn't combine the devices (\(HAL.describe(status)))."
        case .start(let status):
            status == kAudioDevicePermissionsError
                ? "macOS didn't allow audio input. Check System Settings › Privacy & Security › Microphone."
                : "Couldn't start audio (\(HAL.describe(status)))."
        }
    }
}

/// One sink: its taps, aggregate device, renderer and IOProc.
final class SinkRunner: @unchecked Sendable {
    private(set) var plan: SinkPlan
    private let renderer: OpaquePointer
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var taps: [(plan: TapPlan, id: AudioObjectID, uuid: UUID, processes: [AudioObjectID])] = []
    private(set) var layoutWarning: String?
    /// Frames in one cross-fade at the aggregate's sample rate.
    private var fadeFrames = UInt32(Router.crossFadeSeconds * 48_000)
    let startedAt = Date()
    /// Measured once the aggregate exists: see `measureTiming`.
    private(set) var latency: TimeInterval?
    private(set) var bufferFrames: Int?

    init?(plan: SinkPlan) {
        self.plan = plan
        let sources = plan.routes.map { UInt32($0.input) }
        let destinations = plan.routes.map { UInt32($0.output) }
        let gains = plan.routes.map(\.gain)
        guard let renderer = jk_renderer_create(UInt32(plan.inputChannels), UInt32(plan.sinkOutputChannels),
                                                UInt32(plan.routes.count), sources, destinations, gains)
        else { return nil }
        self.renderer = renderer
        jk_renderer_set_master_gain(renderer, plan.masterGain)
    }

    deinit {
        jk_renderer_destroy(renderer)
    }

    /// Builds and starts the sink. With `fadingIn` it starts silent and fades in over one cross-fade.
    func start(processes: [HAL.AudioProcess], fadingIn: Bool = false) throws {
        for tap in plan.taps {
            let (description, members) = Self.describe(tap, processes: processes, uuid: UUID())
            var id = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &id)
            guard status == noErr, id != kAudioObjectUnknown else { throw RouterError.tap(tap.name, status) }
            taps.append((tap, id, description.uuid, members))
        }

        var subDevices: [[String: Any]] = []
        for (index, device) in plan.subDevices.enumerated() {
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: device.uid]
            if index > 0 { entry[kAudioSubDeviceDriftCompensationKey] = 1 }
            subDevices.append(entry)
        }
        let tapList: [[String: Any]] = taps.map {
            [kAudioSubTapUIDKey: $0.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Junction · \(plan.name)",
            kAudioAggregateDeviceUIDKey: HAL.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: plan.sinkUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else { throw RouterError.aggregate(status) }
        self.aggregate = aggregate

        // The aggregate fills in its streams shortly after creation.
        var inputs = 0, outputs = 0
        for _ in 0..<25 {
            inputs = HAL.channelCount(aggregate, kAudioObjectPropertyScopeInput)
            outputs = HAL.channelCount(aggregate, kAudioObjectPropertyScopeOutput)
            if inputs >= plan.inputChannels && outputs >= plan.sinkOutputChannels { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if inputs != plan.inputChannels || outputs < plan.sinkOutputChannels {
            layoutWarning = "Expected \(plan.inputChannels) input and \(plan.outputChannels) output channels, macOS made \(inputs) and \(outputs); some cables may carry the wrong channel."
        }

        if let frames = plan.bufferFrames { Self.setBufferSize(aggregate, frames) }
        let rate = HAL.value(aggregate, kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))
        if rate > 0 { fadeFrames = UInt32(max(1, (Router.crossFadeSeconds * rate).rounded())) }
        measureTiming(rate: rate)
        if fadingIn { jk_renderer_set_fade_now(renderer, 0) }

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregate, jk_renderer_ioproc, UnsafeMutableRawPointer(renderer), &proc)
        guard status == noErr, let proc else { throw RouterError.start(status) }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw RouterError.start(status) }
        if fadingIn { jk_renderer_fade(renderer, 1, fadeFrames) }
    }

    /// Asks for an IO buffer size, kept within what the aggregate allows.
    private static func setBufferSize(_ aggregate: AudioObjectID, _ frames: Int) {
        let range = HAL.value(aggregate, kAudioDevicePropertyBufferFrameSizeRange,
                              default: AudioValueRange(mMinimum: 0, mMaximum: 0))
        var wanted = Float64(frames)
        if range.mMaximum > 0 { wanted = min(max(wanted, range.mMinimum), range.mMaximum) }
        var value = UInt32(wanted)
        var address = HAL.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Roughly how long audio takes from a source to the sink: the input side's latency and safety offset, the
    /// output side's, and one buffer each way (taps and drift compensation can add a little).
    private func measureTiming(rate: Float64) {
        let buffer = HAL.value(aggregate, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))
        func side(_ scope: AudioObjectPropertyScope) -> UInt32 {
            let streams = HAL.array(aggregate, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self)
            let streamLatency = streams.map { HAL.value($0, kAudioStreamPropertyLatency, default: UInt32(0)) }.max() ?? 0
            return HAL.value(aggregate, kAudioDevicePropertyLatency, scope, default: UInt32(0))
                + HAL.value(aggregate, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0)) + streamLatency
        }
        guard buffer > 0, rate > 0 else { return }
        bufferFrames = Int(buffer)
        latency = Double(side(kAudioObjectPropertyScopeInput) + side(kAudioObjectPropertyScopeOutput) + 2 * buffer) / rate
    }

    /// Starts fading the sink out; `isSilent` turns true once the fade has been rendered.
    func fadeOut() {
        jk_renderer_fade(renderer, 0, fadeFrames)
    }

    var isSilent: Bool { procID == nil || jk_renderer_fade_level(renderer) == 0 }

    var cycles: UInt64 { jk_renderer_cycle_count(renderer) }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        for tap in taps { AudioHardwareDestroyProcessTap(tap.id) }
        taps.removeAll()
    }

    /// Drops what `start` built without calling Core Audio: after a restart those objects no longer exist.
    func forget() {
        procID = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        taps.removeAll()
    }

    func update(gains plan: SinkPlan) {
        for (index, route) in plan.routes.enumerated() where index < self.plan.routes.count {
            jk_renderer_set_route_gain(renderer, UInt32(index), route.gain)
        }
        jk_renderer_set_master_gain(renderer, plan.masterGain)
        self.plan = plan
    }

    /// Updates each tap's process list; returns a line per tap that changed, for the event log.
    func refreshTaps(processes: [HAL.AudioProcess]) -> [String] {
        var changes: [String] = []
        for index in taps.indices {
            let tap = taps[index]
            let (description, members) = Self.describe(tap.plan, processes: processes, uuid: tap.uuid)
            guard Set(members) != Set(tap.processes) else { continue }
            do {
                try AudioHardwareTap(id: tap.id).setDescription(description)
                taps[index].processes = members
                changes.append("\(plan.name): \(tap.plan.name) \(Self.membership(tap.plan, members.count))")
            } catch {
                // Keep the old description; the next change tries again.
                changes.append("\(plan.name): couldn't update \(tap.plan.name) (\(error.localizedDescription))")
            }
        }
        return changes
    }

    static func membership(_ tap: TapPlan, _ count: Int) -> String {
        switch tap.mode {
        case .only: "captures \(count) process\(count == 1 ? "" : "es")"
        case .allExcept: "leaves out \(count) process\(count == 1 ? "" : "es")"
        }
    }

    /// What was built, for the event log.
    var summary: String {
        var parts = ["\(plan.routes.count) cable\(plan.routes.count == 1 ? "" : "s")"]
        for tap in taps { parts.append("\(tap.plan.name) \(Self.membership(tap.plan, tap.processes.count))") }
        if let bufferFrames { parts.append("buffer \(bufferFrames) frames") }
        if let latency { parts.append(String(format: "about %.0f ms", latency * 1000)) }
        return parts.joined(separator: ", ")
    }

    func takeMeters() -> [PortKey: Float] {
        var result: [PortKey: Float] = [:]
        var inputPeaks: [Int: Float] = [:]
        for route in plan.routes {
            let peak = inputPeaks[route.input] ?? jk_renderer_take_input_peak(renderer, UInt32(route.input))
            inputPeaks[route.input] = peak
            let key = PortKey(node: route.source.node, isOutput: true, channel: route.source.channel)
            result[key] = max(result[key] ?? 0, peak)
        }
        for channel in 0..<plan.sinkOutputChannels {
            result[PortKey(node: plan.sinkNode, isOutput: false, channel: channel)] =
                jk_renderer_take_output_peak(renderer, UInt32(channel))
        }
        return result
    }

    /// The tap description for a plan, with the process objects it names right now. Apps are matched with their
    /// helper processes (browsers and Electron apps play sound from helpers). Junction itself is always excluded
    /// from "all apps" taps, or it would hear its own output.
    static func describe(_ tap: TapPlan, processes: [HAL.AudioProcess], uuid: UUID) -> (CATapDescription, [AudioObjectID]) {
        let own = Bundle.main.bundleIdentifier
        let description: CATapDescription
        var bundleIDs: [String]
        var members: [AudioObjectID]
        switch tap.mode {
        case .only(let apps):
            let matching = processes.filter { apps.contains($0.appBundleID) || apps.contains($0.bundleID) }
            members = matching.map(\.objectID)
            bundleIDs = apps + matching.map(\.bundleID)
            description = CATapDescription(stereoMixdownOfProcesses: members)
        case .allExcept(let apps):
            let matching = processes.filter {
                apps.contains($0.appBundleID) || apps.contains($0.bundleID) || $0.pid == getpid()
            }
            members = matching.map(\.objectID)
            bundleIDs = apps + matching.map(\.bundleID) + (own.map { [$0] } ?? [])
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: members)
        }
        description.name = "Junction · \(tap.name)"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = tap.mutesOriginal ? .muted : .unmuted
        description.bundleIDs = Array(Set(bundleIDs.filter { !$0.isEmpty })).sorted()
        description.isProcessRestoreEnabled = true
        return (description, members.sorted())
    }
}
