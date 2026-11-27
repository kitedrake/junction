import CoreAudio
import Foundation
import JunctionKernel
import os

/// How one sink is doing.
public struct SinkStatus: Codable, Equatable, Sendable {
    /// `held`: stopped for now, while Junction measures a device the sink uses (see `Router.hold`).
    public enum State: String, Codable, Equatable, Sendable { case running, failed, held }
    public var state: State
    public var message: String?
    /// While running: roughly how long audio takes from the sink's sources to the sink (seconds), and the buffer size
    /// macOS gave its routing (frames).
    public var latency: TimeInterval?
    public var bufferFrames: Int?
    /// While running: the delay each node's effect chain adds in this sink (included in `latency`), by node.
    public var effectLatencies: [UUID: TimeInterval]?
    /// Effects that couldn't be made (left out of their chain), by effect, with the reason.
    public var effectProblems: [UUID: String]?
    /// While running: IO cycles whose rendering took longer than Core Audio allows (JK_OVERLOAD_LOAD of the buffer's
    /// duration) since the sink was first built, and the share of real time its rendering took lately.
    public var overloads: Int?
    public var load: Double?
    /// What each effect costs in this sink, by effect.
    public var effectCosts: [UUID: EffectCost]?
    /// Effects holding up the audio thread (see `StallWatch`): offered for bypass.
    public var stallingEffects: Set<UUID>?

    public init(state: State, message: String? = nil, latency: TimeInterval? = nil, bufferFrames: Int? = nil,
                effectLatencies: [UUID: TimeInterval]? = nil, effectProblems: [UUID: String]? = nil,
                overloads: Int? = nil, load: Double? = nil, effectCosts: [UUID: EffectCost]? = nil,
                stallingEffects: Set<UUID>? = nil) {
        self.state = state
        self.message = message
        self.latency = latency
        self.bufferFrames = bufferFrames
        self.effectLatencies = effectLatencies
        self.effectProblems = effectProblems
        self.overloads = overloads
        self.load = load
        self.effectCosts = effectCosts
        self.stallingEffects = stallingEffects
    }
}

/// A node channel for meters: `isOutput` is the node's right side.
public struct PortKey: Codable, Hashable, Sendable {
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

    private let queue = DispatchQueue(label: "com.kitedrake.junction.router", qos: .userInitiated)
    private let lock = NSLock()
    private var runners: [UUID: SinkRunner] = [:]  // mutated on `queue`, under `lock`
    private var statuses: [UUID: SinkStatus] = [:]  // `queue` only
    private let onStatus: StatusHandler
    // `queue` only from here on.
    private var lastPlan = RoutingPlan()
    /// Sinks that failed to build or stopped running, and when to try again.
    private var failures: [UUID: Failure] = [:]
    private var retry: DispatchWorkItem?
    /// IO cycles per running sink (and per converted device feeding it) at the last health check, and how many checks
    /// in a row one of them didn't move.
    private var progress: [UUID: (cycles: [UInt64], still: Int)] = [:]
    private var healthTimer: DispatchSourceTimer?
    static let log = Logger(subsystem: "com.kitedrake.junction", category: "routing")
    private let events: EventLog
    /// Audio Units by effect, kept across sink rebuilds (`queue` only).
    private let effects = EffectPool()
    /// Which effects hold up the audio thread (`queue` only).
    private var stallWatch = StallWatch()
    /// Told (on `queue`) a plugin's state after its window changed it.
    private var effectStateHandler: (@Sendable (UUID, Data) -> Void)?
    /// Sinks stopped while a measurement uses their devices (`queue` only): plans keep them, but they stay down.
    private var held: Set<UUID> = []
    /// Builds a sink's taps, aggregate and IOProc: `SinkRunner.start`, or a stand-in that opens nothing in tests.
    private let startSink: (SinkRunner, [HAL.AudioProcess]) throws -> Void

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

    public convenience init(events: EventLog = .shared, onStatus: @escaping StatusHandler) {
        self.init(events: events, onStatus: onStatus) { runner, processes in
            try runner.start(processes: processes, fadingIn: true)
        }
    }

    /// `startSink` stands in for `SinkRunner.start` (tests); without `checksHealth` stalled sinks aren't rebuilt.
    init(events: EventLog = .shared, onStatus: @escaping StatusHandler, checksHealth: Bool = true,
         startSink: @escaping (SinkRunner, [HAL.AudioProcess]) throws -> Void) {
        self.events = events
        self.onStatus = onStatus
        self.startSink = startSink
        guard checksHealth else { return }
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

    /// Stops these sinks, fading them out, and keeps them stopped through new plans, rebuilds and retries until
    /// `resume`: a measurement needs their devices to itself. Returns once they have stopped. Not on the router's queue.
    public func hold(_ sinks: Set<UUID>) {
        queue.sync {
            let new = sinks.subtracting(held)
            guard !new.isEmpty else { return }
            held.formUnion(new)
            let names = lastPlan.sinks.filter { new.contains($0.sinkNode) }.map(\.name)
            if !names.isEmpty { events.add(.info, "Paused \(names.joined(separator: ", ")) while Junction measures") }
            applyNow(lastPlan)
        }
    }

    /// Builds held sinks again (the ones the plan still has).
    public func resume(_ sinks: Set<UUID>) {
        queue.async {
            let back = sinks.intersection(self.held)
            guard !back.isEmpty else { return }
            self.held.subtract(back)
            let names = self.lastPlan.sinks.filter { back.contains($0.sinkNode) }.map(\.name)
            if !names.isEmpty { self.events.add(.info, "Resumed \(names.joined(separator: ", "))") }
            self.applyNow(self.lastPlan)
        }
    }

    /// The sinks held right now.
    public var heldSinks: Set<UUID> { queue.sync { held } }

    /// The sinks with a running runner (tests).
    var runningSinks: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(runners.keys)
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
        for sink in plan.sinks where held.contains(sink.sinkNode) {
            retire(sink.sinkNode)
            progress[sink.sinkNode] = nil
            failures[sink.sinkNode] = nil  // it starts afresh once resumed
            statuses[sink.sinkNode] = SinkStatus(state: .held, message: "Paused while Junction measures a device it uses.")
        }
        for sink in plan.sinks where !held.contains(sink.sinkNode) {
            if let runner = runners[sink.sinkNode], runner.plan.structureKey == sink.structureKey, !rebuildingAll {
                runner.update(sink, pool: effects)
                if statuses[sink.sinkNode]?.state == .running {
                    statuses[sink.sinkNode] = runner.status(message: statuses[sink.sinkNode]?.message)
                }
                continue
            }
            // A sink that keeps failing waits for its next attempt; its status keeps the reason.
            if let failure = failures[sink.sinkNode], failure.next > now, runners[sink.sinkNode] == nil { continue }
            // Build the replacement while the old sink keeps playing, then swap them over with a cross-fade.
            if processes == nil, !sink.taps.isEmpty { processes = HAL.audioProcesses() }
            guard let runner = SinkRunner(plan: sink, pool: effects) else {
                retire(sink.sinkNode)
                statuses[sink.sinkNode] = SinkStatus(state: .failed, message: "Out of memory.")
                continue
            }
            do {
                try startSink(runner, processes ?? [])
                let replacing = runners[sink.sinkNode] != nil
                if let old = runners[sink.sinkNode] { runner.overloadCarry = old.overloadCount }  // counted since first built
                if replacing { runner.waitForFirstCycle() }  // so the old one doesn't fade out before this one plays
                retire(sink.sinkNode)
                lock.lock()
                runners[sink.sinkNode] = runner
                lock.unlock()
                progress[sink.sinkNode] = nil
                statuses[sink.sinkNode] = runner.status(message: runner.layoutWarning)
                events.add(.info, "\(sink.name): \(replacing ? "rebuilt" : "started"). \(runner.summary)")
                if let warning = runner.layoutWarning { events.add(.warning, "\(sink.name): \(warning)") }
            } catch {
                runner.stop()
                retire(sink.sinkNode)
                recordFailure(sink, error.localizedDescription)
            }
        }
        effects.keep(Set(plan.sinks.flatMap(\.effectKeys)))
        let live = effects.unitsByEffect
        DispatchQueue.main.async { MainActor.assumeIsolated { PluginWindows.shared.keep(live) } }
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
        for runner in current.values { runner.freeRetiredChains() }
        measureLoad(current)
        for (id, runner) in current {
            let cycles = runner.activity
            if let last = progress[id], zip(last.cycles, cycles).contains(where: { $0 == $1 }) {
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

    /// Every 2 s: what each sink and effect costs, the sinks' overloads, and which effects hold up the audio thread.
    /// Statuses go out only when something changed.
    private func measureLoad(_ current: [UUID: SinkRunner]) {
        let now = Date()
        var running = Set<UUID>()
        for runner in current.values {
            let (overloads, timings) = runner.measure()
            for (effect, timing) in timings {
                running.insert(effect)
                stallWatch.record(effect: effect, stalls: timing.late, peak: Double(timing.peakLoad), sinkOverloads: overloads,
                                  at: now)
            }
        }
        stallWatch.keep(running)
        let all = lastPlan.sinks.flatMap { $0.slots.flatMap(\.effects) + $0.effects }
        let offers = stallWatch.offers(at: now, bypassed: Set(all.filter(\.bypass).map(\.id)))
        var changed = false
        for (id, runner) in current {
            let stalling = offers.intersection(runner.effectIDs)
            for effect in stalling.subtracting(runner.stalling) {
                let title = all.first { $0.id == effect }?.title ?? "An effect"
                Self.log.warning("\(runner.plan.name, privacy: .public): \(title, privacy: .public) is holding up the audio")
                events.add(.warning, "\(runner.plan.name): \(title) is holding up the audio (renders taking over half a buffer); offering to bypass it")
            }
            runner.stalling = stalling
            guard statuses[id]?.state == .running else { continue }
            let fresh = runner.status(message: statuses[id]?.message)
            if fresh != statuses[id] {
                statuses[id] = fresh
                changed = true
            }
        }
        if changed { onStatus(statuses) }
    }

    // MARK: Plugin windows

    /// Has `handler` told (on the router's queue) a plugin's state whenever its window changed it, so it is saved.
    public func observeEffectStates(_ handler: @escaping @Sendable (UUID, Data) -> Void) {
        queue.async { self.effectStateHandler = handler }
    }

    /// Opens the window of an effect's running unit in this process (the one that routes), on the main thread. Any
    /// thread but the router's own. Returns why it can't, if it can't.
    public func openPluginWindow(_ effect: UUID, title: String) -> String? {
        let (unit, handler) = queue.sync { (effects.unit(effect), effectStateHandler) }
        guard let unit else {
            return "\(title) isn't running right now. Its window opens while routing is on and its node is connected."
        }
        let queue = queue
        let open = { @MainActor in
            PluginWindows.shared.open(unit, effect: effect, title: title) { state in
                queue.async { handler?(effect, state) }
            }
        }
        if Thread.isMainThread { MainActor.assumeIsolated { open() } } else { DispatchQueue.main.async { open() } }
        return nil
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
    /// The process that opens the taps and devices (Junction, or Junction Helper), as permission settings list it.
    static var processName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Junction"
    }

    case tap(String, OSStatus)
    case aggregate(OSStatus)
    case start(OSStatus)
    case missingDevice(String)

    var errorDescription: String? {
        switch self {
        case .tap(let name, let status):
            "Couldn't capture \(name) (\(HAL.describe(status))). Check that \(Self.processName) may record system audio: System Settings › Privacy & Security › Screen & System Audio Recording."
        case .aggregate(let status): "Couldn't combine the devices (\(HAL.describe(status)))."
        case .missingDevice(let uid): "A device to convert to this rate went away (\(uid))."
        case .start(let status):
            status == kAudioDevicePermissionsError
                ? "macOS didn't allow \(Self.processName) to use audio input. Check System Settings › Privacy & Security › Microphone."
                : "Couldn't start audio (\(HAL.describe(status)))."
        }
    }
}

/// One sink: its taps, aggregate device, renderer and IOProc, an IOProc and converter per device it converts, and a
/// converter per app it captures through a virtual device (fed from the driver's rings by the renderer's IOProc).
final class SinkRunner: @unchecked Sendable {
    private(set) var plan: SinkPlan
    private let renderer: OpaquePointer
    /// One per `plan.converted`, then one per `plan.captures`, in order; the renderer reads them all. Each converted
    /// device's IOProc writes its own; the renderer pumps the captures' from the driver's rings.
    private let converters: [OpaquePointer]
    /// The driver's capture region (kept mapped while the captures read it) and the readers made from it.
    private var region: CaptureRegion?
    private var captures: [OpaquePointer] = []
    private var converterProcs: [(device: AudioObjectID, proc: AudioDeviceIOProcID)] = []
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var taps: [(plan: TapPlan, id: AudioObjectID, uuid: UUID, processes: [AudioObjectID])] = []
    private(set) var layoutWarning: String?
    /// Frames in one cross-fade at the aggregate's sample rate.
    private var fadeFrames = UInt32(Router.crossFadeSeconds * 48_000)
    let startedAt = Date()
    /// Measured once the aggregate exists: see `measureTiming` (without the effects, which `latency` adds).
    private var baseLatency: TimeInterval?
    private(set) var bufferFrames: Int?
    /// The chains in the renderer: one per source slot, and the one after the mix. Chains swapped out wait in
    /// `retired` until the audio thread is done with them (`freeRetiredChains`).
    private var slotChains: [LiveChain?]
    private var mixChain: LiveChain?
    private var retired: [(chain: LiveChain, ticket: UInt64)] = []
    private var effectProblems: [UUID: String] = [:]
    /// Overloads of the sinks this one replaced, so the count goes on across rebuilds.
    var overloadCount: UInt64 { overloadCarry + rendererTiming.late }
    var overloadCarry: UInt64 = 0
    /// The last measurement (see `measure`), and the effects the router offers for bypass.
    private var rendererTiming = JKTiming()
    private var effectTimings: [UUID: JKTiming] = [:]
    private var load: Double?
    private var costs: [UUID: EffectCost] = [:]
    var stalling: Set<UUID> = []

    init?(plan: SinkPlan, pool: EffectPool) {
        self.plan = plan
        let destinations = plan.routes.map { UInt32($0.output) }
        let gains = plan.routes.map(\.gain)
        var converters: [OpaquePointer] = []
        for device in plan.converted {
            guard let converter = jk_converter_create(UInt32(device.inputChannels), device.sampleRate, plan.sampleRate) else {
                converters.forEach { jk_converter_destroy($0) }
                return nil
            }
            jk_converter_set_same_clock(converter, device.sameClock ? 1 : 0)
            converters.append(converter)
        }
        for capture in plan.captures {
            guard let converter = jk_converter_create(UInt32(capture.channels), capture.sampleRate, plan.sampleRate) else {
                converters.forEach { jk_converter_destroy($0) }
                return nil
            }
            jk_converter_set_same_clock(converter, capture.sameClock ? 1 : 0)
            converters.append(converter)
        }
        let slotChannels = plan.slots.map { UInt32($0.inputs.count) }
        let laneSources = plan.slots.flatMap { $0.inputs.map(UInt32.init) }
        guard let renderer = jk_renderer_create_slots(UInt32(plan.inputChannels), UInt32(plan.sinkOutputChannels),
                                                      UInt32(plan.routes.count), plan.routes.map { UInt32($0.lane) },
                                                      destinations, gains, converters, UInt32(converters.count),
                                                      UInt32(slotChannels.count), slotChannels, laneSources)
        else {
            converters.forEach { jk_converter_destroy($0) }
            return nil
        }
        self.renderer = renderer
        self.converters = converters
        slotChains = Array(repeating: nil, count: plan.slots.count)
        jk_renderer_set_master_gain(renderer, plan.masterGain)
        jk_renderer_set_sample_rate(renderer, plan.sampleRate)  // `start` sets the aggregate's own once it knows it
        updateChains(plan, pool: pool)
    }

    deinit {
        jk_renderer_destroy(renderer)
        captures.forEach { jk_capture_destroy($0) }
        converters.forEach { jk_converter_destroy($0) }
        // The chains (and the units only they hold) go with them: nothing renders them any more.
    }

    /// Brings the chains in line with the plan: effects in the same order only get new bypass and parameters; any
    /// other change builds a new chain and swaps it in.
    private func updateChains(_ plan: SinkPlan, pool: EffectPool) {
        var problems: [UUID: String] = [:]
        func chain(_ current: LiveChain?, _ effects: [Effect], position: ChainPosition, channels: Int,
                   slot: UInt32) -> LiveChain? {
            if let current, current.fits(effects) {
                current.update(effects, pool: pool, position: position)
                return current
            }
            let built = LiveChain(effects, position: position, channels: channels, sampleRate: plan.sampleRate, pool: pool)
            var ticket: UInt64 = 0
            _ = jk_renderer_swap_chain(renderer, slot, built?.pointer, &ticket)
            if let current { retired.append((current, ticket)) }
            return built
        }
        for (index, slot) in plan.slots.enumerated() where index < slotChains.count {
            slotChains[index] = chain(slotChains[index], slot.effects, position: .source, channels: slot.inputs.count,
                                      slot: UInt32(index))
        }
        mixChain = chain(mixChain, plan.effects, position: .mix, channels: plan.sinkOutputChannels, slot: JK_OUTPUT_CHAIN)
        for effect in plan.slots.flatMap(\.effects) + plan.effects {
            if let problem = pool.problems[effect.id] { problems[effect.id] = problem }
        }
        effectProblems = problems
        freeRetiredChains()
    }

    /// Frees chains swapped out once no IO cycle can still be processing them (or the IOProc is gone).
    func freeRetiredChains() {
        retired.removeAll { procID == nil || jk_renderer_is_done_with(renderer, $0.ticket) != 0 }
    }

    /// What effect chains add to the delay: the slowest source chain plus the chain after the mix.
    var effectLatency: TimeInterval {
        (slotChains.compactMap { $0?.latency }.max() ?? 0) + (mixChain?.latency ?? 0)
    }

    var latency: TimeInterval? { baseLatency.map { $0 + effectLatency } }

    /// The delay each node's chain adds here.
    var effectLatencies: [UUID: TimeInterval] {
        var result: [UUID: TimeInterval] = [:]
        for (slot, chain) in zip(plan.slots, slotChains) where chain != nil { result[slot.node] = chain!.latency }
        if let mixChain { result[plan.sinkNode] = mixChain.latency }
        return result
    }

    /// The kernel chains in place (per source slot, then after the mix) and those waiting to be freed, for tests.
    var chainPointers: [OpaquePointer?] { slotChains.map { $0?.pointer } + [mixChain?.pointer] }
    var retiredChainCount: Int { retired.count }

    func status(message: String?) -> SinkStatus {
        SinkStatus(state: .running, message: message, latency: latency, bufferFrames: bufferFrames,
                   effectLatencies: effectLatencies.isEmpty ? nil : effectLatencies,
                   effectProblems: effectProblems.isEmpty ? nil : effectProblems,
                   overloads: Int(overloadCount), load: load, effectCosts: costs.isEmpty ? nil : costs,
                   stallingEffects: stalling.isEmpty ? nil : stalling)
    }

    /// The effects in this sink's chains.
    var effectIDs: Set<UUID> { Set((plan.slots.flatMap(\.effects) + plan.effects).map(\.id)) }

    /// Reads how long rendering took since the last call: the sink's load and overloads, and each effect's cost.
    /// Returns the overloads so far and each effect's timing (cumulative, its peak since the last call).
    func measure() -> (overloads: UInt64, effects: [UUID: JKTiming]) {
        var timing = JKTiming()
        jk_renderer_timing(renderer, &timing, 1)
        let previous = rendererTiming
        rendererTiming = timing
        let sampleRate = plan.sampleRate > 0 ? plan.sampleRate : 48_000
        if timing.frames > previous.frames {
            let audio = Double(timing.frames - previous.frames) / sampleRate
            load = ((timing.seconds - previous.seconds) / audio * 1000).rounded() / 1000
        }
        var timings: [UUID: JKTiming] = [:]
        var fresh: [UUID: EffectCost] = [:]
        for chain in slotChains.compactMap({ $0 }) + [mixChain].compactMap({ $0 }) {
            let units = chain.unitsByEffect
            for (effect, stageTiming) in chain.takeTimings() {
                timings[effect] = stageTiming
                fresh[effect] = EffectCost.measure(stageTiming, since: effectTimings[effect], sampleRate: sampleRate,
                                                   latency: units[effect]?.latency ?? 0,
                                                   outOfProcess: units[effect]?.isOutOfProcess ?? false)
            }
        }
        effectTimings = timings
        costs = fresh
        return (overloadCount, timings)
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

        let subDevices = Self.subDeviceList(plan)
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
        if rate > 0 { jk_renderer_set_sample_rate(renderer, rate) }
        if rate > 0 { fadeFrames = UInt32(max(1, (Router.crossFadeSeconds * rate).rounded())) }

        // Devices at another rate run on their own IOProc, outside the aggregate, and feed their converters.
        var convertedIDs: [AudioObjectID] = []
        for (device, converter) in zip(plan.converted, converters) {
            guard let id = HAL.deviceID(forUID: device.uid) else { throw RouterError.missingDevice(device.uid) }
            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcID(id, jk_converter_ioproc, UnsafeMutableRawPointer(converter), &proc)
            guard status == noErr, let proc else { throw RouterError.start(status) }
            converterProcs.append((id, proc))
            status = AudioDeviceStart(id, proc)
            guard status == noErr else { throw RouterError.start(status) }
            convertedIDs.append(id)
        }
        connectCaptures()
        measureTiming(rate: rate, converted: convertedIDs)
        if fadingIn { jk_renderer_set_fade_now(renderer, 0) }

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregate, jk_renderer_ioproc, UnsafeMutableRawPointer(renderer), &proc)
        guard status == noErr, let proc else { throw RouterError.start(status) }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw RouterError.start(status) }
        if fadingIn { jk_renderer_fade(renderer, 1, fadeFrames) }
    }

    /// Finds each captured app's slots in the driver's region and has the renderer read them. Without the region (no
    /// Junction Driver Installer, or it hasn't got one yet) the sink runs with those channels silent and says why.
    private func connectCaptures() {
        guard !plan.captures.isEmpty else { return }
        guard let region = CaptureRegion.source() else {
            layoutWarning = "Can't capture \(plan.captures.map(\.name).joined(separator: ", ")): Junction Driver Installer doesn't share the driver's per-app audio. It needs the driver and Junction Driver Installer installed and allowed in Login Items."
            return
        }
        self.region = region
        var missing: [String] = []
        for (index, capture) in plan.captures.enumerated() {
            let slots = region.slots(device: capture.deviceUID, clients: capture.clients)
            let converter = converters[plan.converted.count + index]
            let indices = slots.map { UInt32($0.index) }, sequences = slots.map(\.sequence)
            guard !slots.isEmpty,
                  let reader = jk_capture_create(region.base, region.size, indices, sequences, UInt32(slots.count),
                                                 UInt32(capture.channels), capture.sampleRate, converter)
            else {
                missing.append(capture.name)
                continue
            }
            captures.append(reader)
        }
        if !captures.isEmpty { _ = jk_renderer_set_captures(renderer, captures, UInt32(captures.count)) }
        if !missing.isEmpty {
            layoutWarning = "The driver isn't capturing \(missing.joined(separator: ", ")) right now."
        }
    }

    /// The aggregate's sub-devices: the sink first (the clock), then the sources. Core Audio's drift compensation keeps
    /// a source in step with the sink unless both share a clock domain (Junction's own devices do), where it would
    /// only add work and a little filtering.
    static func subDeviceList(_ plan: SinkPlan) -> [[String: Any]] {
        plan.subDevices.enumerated().map { index, device in
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: device.uid]
            if index > 0 { entry[kAudioSubDeviceDriftCompensationKey] = device.sameClock ? 0 : 1 }
            return entry
        }
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
    /// output side's, and one buffer each way (taps and drift compensation can add a little). A converted device
    /// counts its own input side and buffer, and the converter's ring and filter delay, instead of the aggregate's
    /// input side; the slowest path is reported.
    private func measureTiming(rate: Float64, converted: [AudioObjectID]) {
        let buffer = HAL.value(aggregate, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))
        func side(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
            let streams = HAL.array(device, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self)
            let streamLatency = streams.map { HAL.value($0, kAudioStreamPropertyLatency, default: UInt32(0)) }.max() ?? 0
            return HAL.value(device, kAudioDevicePropertyLatency, scope, default: UInt32(0))
                + HAL.value(device, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0)) + streamLatency
        }
        guard buffer > 0, rate > 0 else { return }
        bufferFrames = Int(buffer)
        let outputSide = Double(side(aggregate, kAudioObjectPropertyScopeOutput) + buffer) / rate
        var slowest = Double(side(aggregate, kAudioObjectPropertyScopeInput) + buffer) / rate
        for (index, device) in converted.enumerated() where index < converters.count {
            let deviceRate = plan.converted[index].sampleRate
            let deviceBuffer = HAL.value(device, kAudioDevicePropertyBufferFrameSize, default: UInt32(512))
            let input = Double(side(device, kAudioObjectPropertyScopeInput) + deviceBuffer) / deviceRate
            slowest = max(slowest, input + jk_converter_expected_delay(converters[index], buffer, deviceBuffer))
        }
        for index in plan.captures.indices where plan.converted.count + index < converters.count {
            slowest = max(slowest, jk_converter_expected_delay(converters[plan.converted.count + index], buffer, 512))
        }
        baseLatency = slowest + outputSide
    }

    /// Starts fading the sink out; `isSilent` turns true once the fade has been rendered.
    func fadeOut() {
        jk_renderer_fade(renderer, 0, fadeFrames)
    }

    var isSilent: Bool { procID == nil || jk_renderer_fade_level(renderer) == 0 }

    var cycles: UInt64 { jk_renderer_cycle_count(renderer) }

    /// IO cycles of the sink, then of each converted device: the health check rebuilds the sink when one stops.
    /// Captured apps don't count: an app that stops playing isn't a stalled sink.
    var activity: [UInt64] { [cycles] + converters.prefix(plan.converted.count).map { jk_converter_write_count($0) } }

    /// Waits (up to 0.1 s) until the IOProc has run once.
    func waitForFirstCycle() {
        let deadline = Date().addingTimeInterval(0.1)
        while cycles == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    }

    func stop() {
        for converted in converterProcs {
            AudioDeviceStop(converted.device, converted.proc)
            AudioDeviceDestroyIOProcID(converted.device, converted.proc)
        }
        converterProcs.removeAll()
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
        converterProcs.removeAll()
        procID = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        taps.removeAll()
    }

    /// A plan with the same structure: new gains, and the effect chains brought up to date.
    func update(_ plan: SinkPlan, pool: EffectPool) {
        for (index, route) in plan.routes.enumerated() where index < self.plan.routes.count {
            jk_renderer_set_route_gain(renderer, UInt32(index), route.gain)
        }
        jk_renderer_set_master_gain(renderer, plan.masterGain)
        self.plan = plan
        updateChains(plan, pool: pool)
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
        let shared = plan.subDevices.dropFirst().filter(\.sameClock).count
        if shared > 0 { parts.append("\(shared) device\(shared == 1 ? "" : "s") on the same clock (no drift compensation)") }
        for device in plan.converted {
            parts.append("converts \(device.uid) from \(formatSampleRate(device.sampleRate)) to \(formatSampleRate(plan.sampleRate))")
        }
        for tap in taps { parts.append("\(tap.plan.name) \(Self.membership(tap.plan, tap.processes.count))") }
        for capture in plan.captures { parts.append("captures \(capture.name)") }
        let effectCount = slotChains.compactMap { $0?.stages.compactMap { $0 }.count }.reduce(0, +)
            + (mixChain?.stages.compactMap { $0 }.count ?? 0)
        if effectCount > 0 { parts.append("\(effectCount) effect\(effectCount == 1 ? "" : "s")") }
        if let bufferFrames { parts.append("buffer \(bufferFrames) frames") }
        if let latency { parts.append(String(format: "about %.0f ms", latency * 1000)) }
        return parts.joined(separator: ", ")
    }

    func takeMeters() -> [PortKey: Float] {
        var result: [PortKey: Float] = [:]
        var inputPeaks: [Int: Float] = [:]
        for route in plan.routes {
            // The lane: after the source's effects.
            let peak = inputPeaks[route.lane] ?? jk_renderer_take_input_peak(renderer, UInt32(route.lane))
            inputPeaks[route.lane] = peak
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
            // Junction's app and its routing helper are both left out, whichever of them opens the tap.
            let matching = processes.filter {
                apps.contains($0.appBundleID) || apps.contains($0.bundleID) || $0.pid == getpid()
                    || HAL.ownBundleIDs.contains($0.appBundleID)
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
