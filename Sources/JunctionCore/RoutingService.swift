import Foundation

/// What the routing service drives: the `Router` in the helper, a stand-in in tests.
public protocol SinkRouting: AnyObject {
    func apply(_ plan: RoutingPlan)
    func forgetAfterRestart()
    func stopAll()
    func rebuildAll()
    func resetHealth()
    func processesChanged()
    func takeMeters() -> [PortKey: Float]
    /// Opens a plugin's window where its unit runs (on the main thread); returns why it can't, if it can't.
    func openPluginWindow(_ effect: UUID, title: String) -> String?
    /// Has `handler` told a plugin's state whenever its window changed it.
    func observeEffectStates(_ handler: @escaping @Sendable (UUID, Data) -> Void)
    /// Stops sinks while a measurement uses their devices (returns once they have stopped), and builds them again.
    func hold(_ sinks: Set<UUID>)
    func resume(_ sinks: Set<UUID>)
}

extension SinkRouting {
    public func openPluginWindow(_ effect: UUID, title: String) -> String? { "Plugin windows aren't available here." }
    public func observeEffectStates(_ handler: @escaping @Sendable (UUID, Data) -> Void) {}
}

extension Router: SinkRouting {}

/// The helper's side of routing: holds the setup the app last sent (or graph.json at launch), plans it with what is
/// on the system, runs it through a `SinkRouting`, and serves apps over XPC. Everything happens on `queue`; the
/// helper's main feeds it system changes (devices, Core Audio restarts, wake, permission) and a meter clock.
public final class RoutingService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// What the service needs from the system, so tests can stand in for it.
    public struct Environment {
        public var readInventory: () -> Inventory
        public var permission: () -> PermissionState
        public var requestMicrophone: (@escaping @Sendable () -> Void) -> Void
        public var processName: String
        /// This helper's CFBundleVersion (nil: don't compare with the app's).
        public var version: String?
        /// After a Core Audio restart: wait this long, rebuild, then rebuild again after each further delay (for
        /// devices that come back late).
        public var restartDelays: [TimeInterval]
        /// Code-signing requirement for apps that connect (nil: anyone in this user session, for tests).
        public var clientRequirement: String?

        public init(readInventory: @escaping () -> Inventory, permission: @escaping () -> PermissionState,
                    requestMicrophone: @escaping (@escaping @Sendable () -> Void) -> Void,
                    processName: String = RoutingXPC.helperDisplayName, version: String? = nil,
                    restartDelays: [TimeInterval] = [1.5, 2, 4], clientRequirement: String? = nil) {
            self.readInventory = readInventory
            self.permission = permission
            self.requestMicrophone = requestMicrophone
            self.processName = processName
            self.version = version
            self.restartDelays = restartDelays
            self.clientRequirement = clientRequirement
        }
    }

    public let queue: DispatchQueue
    private let environment: Environment
    private let events: EventLog
    private var router: SinkRouting!
    // `queue` only from here on.
    public private(set) var graph: Graph
    public private(set) var inventory = Inventory()
    public private(set) var plan = RoutingPlan()
    public private(set) var statuses: [UUID: SinkStatus] = [:]
    public private(set) var permission: PermissionState
    /// Whether routing goes on when no app is connected.
    public private(set) var keepRouting: Bool
    /// Whether the service is routing (it waits for an app, or `keepRouting`, before it starts).
    public private(set) var isRouting = false
    private var clients: [ObjectIdentifier: NSXPCConnection] = [:]
    private var lastEventID = -1
    private var metersWereShown = false
    private var restartGeneration = 0
    private var refreshPending = false
    /// MIDI control: mappings live in `graph`; this keeps learn and pick-up between messages.
    private var midi = MIDIControl()
    /// The MIDI controllers listened to (the helper's `MIDIInput` reports them).
    public private(set) var midiSources: [String] = []
    /// Sinks held for each app's measurement (in-process requests under the service's own key).
    private var holds: [ObjectIdentifier: Set<UUID>] = [:]

    /// Called on `queue` with each new plan (the helper watches the devices it uses).
    public var onPlan: ((RoutingPlan) -> Void)?
    /// Called on `queue` when `keepRouting` changes, to save it.
    public var onKeepRoutingChanged: ((Bool) -> Void)?
    /// Called on `queue` when no app is connected and routing shouldn't go on: the helper quits.
    public var onIdle: (() -> Void)?
    /// Called on `queue` when an app of another version connected: the helper quits (launchd starts the new one).
    public var onOutdated: (() -> Void)?
    /// Called on `queue` when MIDI changed the setup while no app is connected (old setup, new one): the helper saves
    /// it, and publishes the virtual devices when one was turned on or off. With an app connected, the app does both.
    public var onMIDIChange: ((Graph, Graph) -> Void)?

    public init(graph: Graph, keepRouting: Bool, events: EventLog = .shared, queue: DispatchQueue = .main,
                environment: Environment, makeRouter: (@escaping Router.StatusHandler) -> SinkRouting) {
        self.graph = graph
        self.keepRouting = keepRouting
        self.events = events
        self.queue = queue
        self.environment = environment
        permission = environment.permission()
        super.init()
        router = makeRouter { [weak self] statuses in
            guard let self else { return }
            self.queue.async {
                self.statuses = statuses
                self.broadcast(.statuses(statuses))
            }
        }
        events.observe { [weak self] in
            guard let self else { return }
            self.queue.async { self.forwardEvents() }
        }
        router.observeEffectStates { [weak self] effect, state in
            guard let self else { return }
            self.queue.async { self.broadcast(.effectState(effect: effect, state: state)) }
        }
    }

    // MARK: Life cycle

    /// At launch: routes the saved setup straight away when it should keep going without the app; otherwise waits
    /// for an app to connect. Call on `queue`.
    public func start() {
        lastEventID = events.recent.last?.id ?? -1
        events.add(.info, "\(environment.processName) started (process \(ProcessInfo.processInfo.processIdentifier))")
        if keepRouting { startRouting() }
    }

    private func startRouting() {
        guard !isRouting else { return }
        isRouting = true
        inventory = environment.readInventory()
        replan(force: true)
    }

    private func stopRouting(_ reason: String) {
        guard isRouting else { return }
        isRouting = false
        events.add(.info, reason)
        router.stopAll()
        plan = RoutingPlan()
        statuses = [:]
        onPlan?(plan)
    }

    private func replan(force: Bool = false) {
        guard isRouting else { return }
        let new = Planner.plan(graph, inventory: inventory)
        guard force || new != plan else { return }
        plan = new
        router.apply(new)
        onPlan?(new)
    }

    // MARK: System changes (call on `queue`)

    /// Reads devices and apps again; a change replans.
    public func refreshInventory() {
        guard isRouting else { return }
        let fresh = environment.readInventory()
        guard fresh != inventory else { return }
        inventory = fresh
        replan()
    }

    /// Devices, defaults or audio processes changed: soon (changes come in bursts) read them again and update the
    /// taps' process lists.
    public func systemChanged() {
        guard isRouting, !refreshPending else { return }
        refreshPending = true
        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
            refreshPending = false
            refreshInventory()
            if isRouting { router.processesChanged() }
        }
    }

    /// Core Audio restarted: every tap, aggregate device and IOProc is gone. Rebuild once devices are back, and again
    /// a little later for the ones that come back late.
    public func coreAudioRestarted() {
        guard isRouting else { return }
        events.add(.warning, "Core Audio restarted; rebuilding routing")
        router.forgetAfterRestart()
        restartGeneration += 1
        let generation = restartGeneration
        var wait: TimeInterval = 0
        for (index, delay) in environment.restartDelays.enumerated() {
            wait += delay
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                guard generation == restartGeneration, isRouting else { return }
                if index == 0 { inventory = environment.readInventory() }
                replan(force: true)
            }
        }
    }

    /// The Mac woke: IO takes a moment to resume, so count stalls afresh, and look at the devices again.
    public func woke() {
        guard isRouting else { return }
        events.add(.info, "Woke from sleep; checking routing")
        router.resetHealth()
        systemChanged()
    }

    /// Follows the Microphone permission; once it is granted every sink is built again (one that started without it
    /// may be running on silence).
    public func refreshPermission() {
        let fresh = environment.permission()
        guard fresh != permission else { return }
        permission = fresh
        events.add(fresh == .allowed ? .info : .warning, "Microphone permission for \(environment.processName): \(fresh.rawValue)")
        broadcast(.permission(fresh))
        if fresh == .allowed, isRouting { router.rebuildAll() }
    }

    /// Sends the peak levels since the last call to connected apps (about 20 times a second).
    public func sendMeters() {
        guard isRouting, !clients.isEmpty else { return }
        let meters = graph.isRoutingOn ? router.takeMeters().filter { $0.value > 0.0005 } : [:]
        guard !meters.isEmpty || metersWereShown else { return }
        metersWereShown = !meters.isEmpty
        broadcast(.meters(meters))
    }

    // MARK: MIDI

    /// Messages from a MIDI controller (`source`: its name): each makes the changes its mappings call for, or, while
    /// learning, the new mapping. Levels and mutes only change gains in the running sinks. Call on `queue`.
    public func receiveMIDI(_ messages: [MIDIMessage], from source: String?) {
        var actions: [MIDIAction] = []
        let before = graph
        for message in messages {
            for action in midi.handle(message, from: source, graph: graph) where action.apply(to: &graph, inventory: inventory) {
                actions.append(action)
                if case .learned(let mapping) = action {
                    events.add(.info, "MIDI learn: \(mapping.trigger.title) now drives \(graph.describe(mapping.target, inventory: inventory))")
                } else if case .scene(let id) = action, let scene = graph.scenes.first(where: { $0.id == id }) {
                    events.add(.info, "Switched to scene \(scene.name) from MIDI")
                }
            }
        }
        guard !actions.isEmpty else { return }
        replan()
        if clients.isEmpty {
            onMIDIChange?(before, graph)
        } else {
            broadcast(.midi(actions))
        }
    }

    /// The MIDI controllers listened to changed. Call on `queue`.
    public func midiSourcesChanged(_ sources: [String]) {
        guard sources != midiSources else { return }
        midiSources = sources
        broadcast(.midiSources(sources))
    }

    /// The target MIDI learn waits for, if any.
    public var midiLearning: MIDITarget? { midi.learning }

    // MARK: Requests

    /// Answers one request from `connection` (nil: a request made in this process). Call on `queue`.
    public func handle(_ request: RoutingRequest, from connection: NSXPCConnection?) -> RoutingReply {
        switch request {
        case .hello(let version, let appVersion, let keep):
            if version != RoutingXPC.protocolVersion || (appVersion != nil && environment.version != nil && appVersion != environment.version) {
                let reason = "\(environment.processName) \(environment.version ?? "?") (protocol \(RoutingXPC.protocolVersion)) "
                    + "doesn't match Junction \(appVersion ?? "?") (protocol \(version))."
                stopRouting("\(reason) Quitting so the matching one starts.")
                queue.async { self.onOutdated?() }
                return .outdated(reason)
            }
            if let connection { clients[ObjectIdentifier(connection)] = connection }
            setKeepRouting(keep)
            startRouting()
            return .welcome(state)
        case .graph(let new):
            guard isClient(connection) else { return .refused("Say hello first.") }
            if new != graph {
                graph = new
                replan()
            }
            return .done
        case .rebuildAll:
            guard isClient(connection) else { return .refused("Say hello first.") }
            router.rebuildAll()
            return .done
        case .requestMicrophone:
            environment.requestMicrophone { [weak self] in
                guard let self else { return }
                self.queue.async { self.refreshPermission() }
            }
            return .done
        case .keepRouting(let keep):
            setKeepRouting(keep)
            return .done
        case .goodbye:
            releaseHolds(of: holder(connection))
            if let connection { clients[ObjectIdentifier(connection)] = nil }
            if clients.isEmpty { midi.learn(nil) }  // nobody is left to see what it learns
            stopIfIdle()
            return .done
        case .openPluginWindow(let effect, let title):
            guard isClient(connection) else { return .refused("Say hello first.") }
            return router.openPluginWindow(effect, title: title).map { .refused($0) } ?? .done
        case .learnMIDI(let target):
            guard isClient(connection) else { return .refused("Say hello first.") }
            midi.learn(target)
            return .done
        case .hold(let sinks):
            guard isClient(connection) else { return .refused("Say hello first.") }
            holds[holder(connection), default: []].formUnion(sinks)
            router.hold(sinks)
            return .done
        case .resume(let sinks):
            guard isClient(connection) else { return .refused("Say hello first.") }
            let key = holder(connection)
            holds[key]?.subtract(sinks)
            if holds[key]?.isEmpty == true { holds[key] = nil }
            router.resume(sinks.subtracting(holds.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }))
            return .done
        }
    }

    /// Sinks held right now, by any app.
    public var heldSinks: Set<UUID> { holds.values.reduce(into: Set<UUID>()) { $0.formUnion($1) } }

    private func holder(_ connection: NSXPCConnection?) -> ObjectIdentifier {
        connection.map(ObjectIdentifier.init) ?? ObjectIdentifier(self)
    }

    /// An app went away in the middle of a measurement: its held sinks come back.
    private func releaseHolds(of key: ObjectIdentifier) {
        guard let sinks = holds.removeValue(forKey: key) else { return }
        router.resume(sinks.subtracting(heldSinks))
    }

    public var state: HelperState {
        HelperState(processName: environment.processName, processID: ProcessInfo.processInfo.processIdentifier,
                    keepRouting: keepRouting, permission: permission, statuses: statuses, midiSources: midiSources)
    }

    /// Apps connected right now.
    public var clientCount: Int { clients.count }

    private func isClient(_ connection: NSXPCConnection?) -> Bool {
        connection.map { clients[ObjectIdentifier($0)] != nil } ?? true
    }

    private func setKeepRouting(_ keep: Bool) {
        guard keep != keepRouting else { return }
        keepRouting = keep
        onKeepRoutingChanged?(keep)
        events.add(.info, keep ? "Routing will keep going after Junction quits" : "Routing will stop when Junction quits")
    }

    private func stopIfIdle() {
        guard clients.isEmpty, !keepRouting else { return }
        stopRouting("Junction quit; routing stopped")
        onIdle?()
    }

    // MARK: Telling apps

    private func broadcast(_ notice: RoutingNotice) {
        guard !clients.isEmpty, let data = try? RoutingXPC.encode(notice) else { return }
        for connection in clients.values {
            (connection.remoteObjectProxyWithErrorHandler { _ in } as? RoutingAppXPC)?.receive(data)
        }
    }

    private func forwardEvents() {
        let fresh = events.recent.filter { $0.id > lastEventID }
        guard let last = fresh.last else { return }
        lastEventID = last.id
        broadcast(.events(fresh.map { LoggedEvent(date: $0.date, kind: $0.kind, message: $0.message) }))
    }

    // MARK: NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = environment.clientRequirement { connection.setCodeSigningRequirement(requirement) }
        connection.exportedInterface = RoutingXPC.helperInterface()
        connection.exportedObject = Exported(service: self, connection: connection)
        connection.remoteObjectInterface = RoutingXPC.appInterface()
        // An app that quits or crashes without saying goodbye counts as gone.
        let key = ObjectIdentifier(connection)
        let gone: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard let connection = self.clients.removeValue(forKey: key) else { return }
                connection.exportedObject = nil
                self.releaseHolds(of: key)
                self.stopIfIdle()
            }
        }
        connection.invalidationHandler = gone
        connection.interruptionHandler = gone
        connection.resume()
        return true
    }

    /// The object apps call: decodes each request and answers it on the service's queue.
    private final class Exported: NSObject, RoutingHelperXPC, @unchecked Sendable {
        weak var service: RoutingService?
        weak var connection: NSXPCConnection?

        init(service: RoutingService, connection: NSXPCConnection) {
            self.service = service
            self.connection = connection
        }

        func handle(_ request: Data, reply: @escaping (Data) -> Void) {
            guard let service else { return }
            guard let decoded = try? RoutingXPC.decode(RoutingRequest.self, from: request) else {
                reply((try? RoutingXPC.encode(RoutingReply.refused("Unreadable request."))) ?? Data())
                return
            }
            nonisolated(unsafe) let connection = connection
            service.queue.async {
                let answer = service.handle(decoded, from: connection)
                reply((try? RoutingXPC.encode(answer)) ?? Data())
            }
        }
    }
}
