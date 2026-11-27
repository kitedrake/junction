import XCTest
@testable import JunctionCore

/// Stands in for the Router: records what the service asks of it.
private final class FakeRouter: SinkRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [RoutingPlan] = []
    private var _calls: [String] = []
    var meters: [PortKey: Float] = [:]
    let onStatus: Router.StatusHandler

    init(onStatus: @escaping Router.StatusHandler) { self.onStatus = onStatus }

    var applied: [RoutingPlan] { lock.withLock { _applied } }
    var calls: [String] { lock.withLock { _calls } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func apply(_ plan: RoutingPlan) { lock.withLock { _applied.append(plan) } }
    func forgetAfterRestart() { record("forget") }
    func stopAll() { record("stop") }
    func rebuildAll() { record("rebuild") }
    func resetHealth() { record("resetHealth") }
    func processesChanged() { record("processes") }
    func takeMeters() -> [PortKey: Float] { lock.withLock { meters } }

    /// What measurements asked to hold and resume, in order.
    private var _holds: [Set<UUID>] = []
    private var _resumes: [Set<UUID>] = []
    var holds: [Set<UUID>] { lock.withLock { _holds } }
    var resumes: [Set<UUID>] { lock.withLock { _resumes } }
    func hold(_ sinks: Set<UUID>) { lock.withLock { _holds.append(sinks) } }
    func resume(_ sinks: Set<UUID>) { lock.withLock { _resumes.append(sinks) } }

    /// Plugins it runs (their windows open), and who hears their states.
    var runningEffects: Set<UUID> = []
    private var stateHandler: (@Sendable (UUID, Data) -> Void)?
    func openPluginWindow(_ effect: UUID, title: String) -> String? {
        record("window \(title)")
        return lock.withLock { runningEffects.contains(effect) } ? nil : "\(title) isn't running right now."
    }
    func observeEffectStates(_ handler: @escaping @Sendable (UUID, Data) -> Void) { lock.withLock { stateHandler = handler } }
    /// A plugin window changed a unit's state.
    func pluginChanged(_ effect: UUID, _ state: Data) { lock.withLock { stateHandler }?(effect, state) }
}

/// Collects what a client hears.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RoutingClient.Event] = []
    var events: [RoutingClient.Event] { lock.withLock { _events } }
    func add(_ event: RoutingClient.Event) { lock.withLock { _events.append(event) } }

    var notices: [RoutingNotice] {
        events.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }
    var welcome: HelperState? {
        events.lazy.compactMap { if case .connected(let state) = $0 { state } else { nil } }.first
    }
    var unavailable: String? {
        events.lazy.compactMap { if case .unavailable(let reason) = $0 { reason } else { nil } }.first
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class RoutingServiceTests: XCTestCase {
    private var listener: NSXPCListener!
    private var service: RoutingService!
    private var router: FakeRouter!
    private var events: EventLog!
    private let permission = Box(PermissionState.notAsked)
    private let microphoneRequests = Box(0)
    private let idle = Box(0)
    private let keptRouting = Box<[Bool]>([])
    private var graph = Graph()
    private var inventory = Inventory()

    override func setUp() {
        super.setUp()
        let device = Templates.streamWithoutChat(&graph, excluding: [AppRef(bundleID: "com.hnc.Discord", name: "Discord")])
        inventory = Inventory(devices: [DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2,
                                                   isJunction: true)],
                              driver: .installed(version: "test"))
        graph.isRoutingOn = true
    }

    override func tearDown() {
        listener?.invalidate()
        listener = nil
        service = nil
        super.tearDown()
    }

    /// A service with a fake router and a made-up system, listening on an in-process (anonymous) XPC listener.
    private func makeService(saved: Graph? = nil, keepRouting: Bool = false, version: String? = nil) {
        events = EventLog(file: nil)
        let inventory = inventory, permission = permission, requests = microphoneRequests
        let environment = RoutingService.Environment(
            readInventory: { inventory },
            permission: { permission.value },
            requestMicrophone: { done in
                requests.value += 1
                permission.value = .allowed
                done()
            },
            processName: "Test Helper", version: version, restartDelays: [0.05, 0.05])
        var made: FakeRouter?
        service = RoutingService(graph: saved ?? Graph(), keepRouting: keepRouting, events: events,
                                 queue: DispatchQueue(label: "test.routing-service"), environment: environment) { onStatus in
            let router = FakeRouter(onStatus: onStatus)
            made = router
            return router
        }
        router = made
        let idle = idle, kept = keptRouting
        service.onIdle = { idle.value += 1 }
        service.onKeepRoutingChanged = { kept.value.append($0) }
        service.queue.sync { service.start() }
        listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
    }

    private func makeClient(keepRouting: Bool = false, appVersion: String? = nil) -> (RoutingClient, Heard) {
        let heard = Heard()
        let client = RoutingClient(endpoint: listener.endpoint, keepRouting: keepRouting, appVersion: appVersion,
                                   callbackQueue: DispatchQueue(label: "test.routing-client")) { heard.add($0) }
        client.connect()
        return (client, heard)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // MARK: Messages

    func testEveryMessageSurvivesEncoding() throws {
        let sink = UUID(), node = UUID()
        let statuses = [sink: SinkStatus(state: .running, message: "fine", latency: 0.012, bufferFrames: 256),
                        UUID(): SinkStatus(state: .failed, message: "Couldn't start audio.")]
        let state = HelperState(processName: "Junction Helper", processID: 42, keepRouting: true, permission: .denied,
                                statuses: statuses)
        let requests: [RoutingRequest] = [.hello(protocolVersion: RoutingXPC.protocolVersion, appVersion: "1.2", keepRouting: true),
                                          .graph(graph), .rebuildAll, .requestMicrophone, .keepRouting(false), .goodbye,
                                          .openPluginWindow(effect: node, title: "Space Reverb · Microphone"),
                                          .learnMIDI(.cableLevel(node)), .learnMIDI(.scene(sink)), .learnMIDI(nil),
                                          .hold([sink, node]), .hold([]), .resume([sink])]
        var withControllers = state
        withControllers.midiSources = ["Desk Controller", "Pads"]
        let replies: [RoutingReply] = [.welcome(state), .welcome(withControllers), .done, .refused("no"), .outdated("old")]
        let notices: [RoutingNotice] = [
            .statuses(statuses),
            .meters([PortKey(node: node, isOutput: true, channel: 1): 0.5, PortKey(node: node, isOutput: false, channel: 0): 0.25]),
            .events([LoggedEvent(date: Date(timeIntervalSince1970: 1_700_000_000), kind: .warning, message: "Core Audio restarted")]),
            .permission(.allowed), .permission(.notAsked), .permission(.restricted),
            .effectState(effect: node, state: Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])),
            .statuses([sink: SinkStatus(state: .running, overloads: 3, load: 0.12,
                                        effectCosts: [node: EffectCost(load: 0.05, peak: 0.6, stalls: 4, latency: 0.003, outOfProcess: true)],
                                        stallingEffects: [node])]),
            .midi([.cableLevel(node, dB: -6.5), .nodeMute(node, true), .effectBypass(node, false), .deviceEnabled(sink, true),
                   .scene(sink),
                   .learned(MIDIMapping(target: .effectBypass(node), trigger: .note(channel: 9, number: 36), controller: "Pads")),
                   .learned(MIDIMapping(target: .cableLevel(node), trigger: .controller(channel: 0, number: 7), mode: .relativeSigned))]),
            .midiSources(["Desk Controller"]), .midiSources([]),
            .statuses([sink: SinkStatus(state: .held, message: "Paused while Junction measures a device it uses.")]),
        ]
        for request in requests {
            XCTAssertEqual(try RoutingXPC.decode(RoutingRequest.self, from: RoutingXPC.encode(request)), request)
        }
        for reply in replies {
            XCTAssertEqual(try RoutingXPC.decode(RoutingReply.self, from: RoutingXPC.encode(reply)), reply)
        }
        for notice in notices {
            XCTAssertEqual(try RoutingXPC.decode(RoutingNotice.self, from: RoutingXPC.encode(notice)), notice)
        }
        // A request of another kind doesn't decode as this one.
        XCTAssertThrowsError(try RoutingXPC.decode(RoutingRequest.self, from: RoutingXPC.encode(RoutingReply.done)))
    }

    func testRequirementsNameTheBundleAndTeam() {
        XCTAssertEqual(RoutingXPC.peerRequirement(identifier: "com.kitedrake.junction", teamID: nil), "identifier \"com.kitedrake.junction\"")
        XCTAssertEqual(RoutingXPC.peerRequirement(identifier: "com.kitedrake.junction.helper", teamID: "ABCDE12345"),
                       "identifier \"com.kitedrake.junction.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertEqual(RoutingXPC.helperExecutablePath, "Contents/Library/LoginItems/JunctionHelper.app/Contents/MacOS/JunctionHelper")
    }

    // MARK: Over XPC

    func testAppSendsTheSetupAndHearsStatusesMetersEventsAndPermission() throws {
        makeService()
        XCTAssertTrue(router.applied.isEmpty, "without keepRouting the helper waits for an app")
        let (client, heard) = makeClient()
        waitUntil("hello") { heard.welcome != nil }
        let welcome = try XCTUnwrap(heard.welcome)
        XCTAssertEqual(welcome.processName, "Test Helper")
        XCTAssertEqual(welcome.permission, .notAsked)
        XCTAssertFalse(welcome.keepRouting)
        XCTAssertEqual(service.queue.sync { service.clientCount }, 1)

        client.send(graph: graph)
        waitUntil("the setup to be routed") { router.applied.last?.sinks.count == 1 }
        XCTAssertEqual(router.applied.last, Planner.plan(graph, inventory: inventory))
        let applied = router.applied.count
        client.send(graph: graph)  // the same setup again isn't sent
        var moved = graph
        moved.nodes[0].x += 40      // a move doesn't change the plan: nothing is rebuilt
        client.send(graph: moved)
        waitUntil("the moved setup") { service.queue.sync { service.graph } == moved }
        XCTAssertEqual(router.applied.count, applied)

        let sink = try XCTUnwrap(router.applied.last?.sinks.first?.sinkNode)
        router.onStatus([sink: SinkStatus(state: .running, latency: 0.01, bufferFrames: 512)])
        waitUntil("statuses") { heard.notices.contains(.statuses([sink: SinkStatus(state: .running, latency: 0.01, bufferFrames: 512)])) }

        let key = PortKey(node: sink, isOutput: false, channel: 0)
        router.meters = [key: 0.5, PortKey(node: sink, isOutput: false, channel: 1): 0]
        service.queue.async { self.service.sendMeters() }
        waitUntil("meters") { heard.notices.contains(.meters([key: 0.5])) }

        events.add(.error, "Stream Mix: Couldn't start audio.")
        waitUntil("the event") {
            heard.notices.contains { if case .events(let list) = $0 { list.contains { $0.message == "Stream Mix: Couldn't start audio." && $0.kind == .error } } else { false } }
        }

        client.requestMicrophone()
        waitUntil("the permission") { heard.notices.contains(.permission(.allowed)) }
        XCTAssertEqual(microphoneRequests.value, 1)
        XCTAssertTrue(router.calls.contains("rebuild"), "a granted permission rebuilds every destination")

        client.rebuildAll()
        waitUntil("a second rebuild") { router.calls.filter { $0 == "rebuild" }.count == 2 }
        client.goodbye()
    }

    func testPluginWindowsOpenInTheHelperAndTheirStateComesBack() throws {
        makeService()
        let (client, heard) = makeClient()
        waitUntil("hello") { heard.welcome != nil }
        let running = UUID(), stopped = UUID()
        router.runningEffects = [running]
        let answers = Box<[String?]>([])
        client.openPluginWindow(running, title: "Space Reverb · Microphone") { answers.value.append($0) }
        waitUntil("the first answer") { answers.value.count == 1 }
        XCTAssertEqual(answers.value, [nil], "the helper opened it")
        XCTAssertTrue(router.calls.contains("window Space Reverb · Microphone"))
        client.openPluginWindow(stopped, title: "Vocal Rider") { answers.value.append($0) }
        waitUntil("the second answer") { answers.value.count == 2 }
        XCTAssertEqual(answers.value.last, "Vocal Rider isn't running right now.", "the app hears why not")

        // The window changed the plugin: the app hears its state, to save it.
        let state = Data([1, 2, 3, 4])
        router.pluginChanged(running, state)
        waitUntil("the state") { heard.notices.contains(.effectState(effect: running, state: state)) }

        // Before hello, nothing opens.
        let reply = service.queue.sync { service.handle(.openPluginWindow(effect: running, title: "x"), from: NSXPCConnection()) }
        guard case .refused = reply else { return XCTFail("a stranger can't open windows") }
        client.goodbye()
    }

    func testMIDIControlsLevelsAndMutesInTheHelperWithoutRebuilding() throws {
        // A level on an encoder and the destination's mute on a pad, saved with the setup the helper routes at login.
        let sink = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        let cable = try XCTUnwrap(sink.routes.first).cable
        let source = try XCTUnwrap(sink.routes.first).source.node
        graph.midi = [MIDIMapping(target: .cableLevel(cable), trigger: .controller(channel: 0, number: 7), mode: .relative),
                      MIDIMapping(target: .nodeMute(sink.sinkNode), trigger: .note(channel: 9, number: 36))]
        makeService(saved: graph, keepRouting: true)
        let saved = Box<[Graph]>([])
        service.onMIDIChange = { _, new in saved.value.append(new) }
        waitUntil("routing at launch") { router.applied.count == 1 }
        let before = try XCTUnwrap(router.applied.last?.sinks.first)

        // Two encoder steps up while Junction is closed: the gain changes, the structure doesn't (no rebuild), and the
        // helper saves the setup itself.
        service.queue.sync { service.receiveMIDI(MIDIMessage.parse([0xB0, 0x07, 0x02]), from: "Desk Controller") }
        waitUntil("the new level") { router.applied.count == 2 }
        let louder = try XCTUnwrap(router.applied.last?.sinks.first)
        XCTAssertEqual(louder.structureKey, before.structureKey, "a level never rebuilds a sink")
        let route = try XCTUnwrap(louder.routes.first { $0.cable == cable })
        XCTAssertEqual(route.gain, Gain.linear(graph.node(source)!.gainDB) * Gain.linear(2 * MIDIFader.stepDB), accuracy: 0.0001)
        XCTAssertEqual(saved.value.last?.cables.first { $0.id == cable }?.gainDB, 2 * MIDIFader.stepDB)

        // The pad mutes the destination: its master gain goes to 0, again without a rebuild.
        service.queue.sync { service.receiveMIDI(MIDIMessage.parse([0x99, 0x24, 0x7F, 0x89, 0x24, 0x00]), from: "Pads") }
        waitUntil("the mute") { router.applied.count == 3 }
        let muted = try XCTUnwrap(router.applied.last?.sinks.first)
        XCTAssertEqual(muted.masterGain, 0)
        XCTAssertEqual(muted.structureKey, before.structureKey)
        XCTAssertEqual(saved.value.count, 2)

        // With Junction open: it learns through the helper, and hears every change to make it too (the app saves).
        let (client, heard) = makeClient(keepRouting: true)
        waitUntil("hello") { heard.welcome != nil }
        client.learnMIDI(.nodeMute(source))
        waitUntil("learning") { service.queue.sync { service.midiLearning } == .nodeMute(source) }
        service.queue.sync { service.receiveMIDI(MIDIMessage.parse([0x90, 0x28, 0x64]), from: "Pads") }
        waitUntil("the learned mapping") {
            heard.notices.contains { notice in
                guard case .midi(let actions) = notice, actions.count == 1, case .learned(let mapping) = actions[0] else { return false }
                return mapping.target == .nodeMute(source) && mapping.trigger == .note(channel: 0, number: 40)
            }
        }
        XCTAssertNil(service.queue.sync { service.midiLearning })
        XCTAssertEqual(service.queue.sync { service.graph.midi.count }, 3)
        service.queue.sync { service.receiveMIDI(MIDIMessage.parse([0xB0, 0x07, 0x7F]), from: "Desk Controller") }
        waitUntil("the level notice") { heard.notices.contains(.midi([.cableLevel(cable, dB: MIDIFader.stepDB)])) }
        XCTAssertEqual(saved.value.count, 2, "with an app connected, the app saves")
        service.queue.sync { service.midiSourcesChanged(["Desk Controller", "Pads"]) }
        waitUntil("the controllers") { heard.notices.contains(.midiSources(["Desk Controller", "Pads"])) }
        client.goodbye()
    }

    func testGoodbyeStopsRoutingUnlessItShouldKeepGoing() {
        makeService()
        let (client, heard) = makeClient(keepRouting: true)
        waitUntil("hello") { heard.welcome != nil }
        XCTAssertEqual(keptRouting.value, [true])
        client.send(graph: graph)
        waitUntil("routing") { !router.applied.isEmpty }
        client.goodbye()
        waitUntil("the goodbye") { service.queue.sync { service.clientCount } == 0 }
        XCTAssertFalse(router.calls.contains("stop"), "keepRouting: routing goes on without the app")
        XCTAssertEqual(idle.value, 0)
        XCTAssertTrue(service.queue.sync { service.isRouting })

        let (second, heardAgain) = makeClient(keepRouting: false)
        waitUntil("the second hello") { heardAgain.welcome != nil }
        XCTAssertEqual(heardAgain.welcome?.keepRouting, false, "the app's setting wins")
        XCTAssertEqual(keptRouting.value, [true, false])
        second.goodbye()
        waitUntil("routing to stop") { router.calls.contains("stop") }
        XCTAssertEqual(idle.value, 1, "the helper quits once no app needs it")
        XCTAssertFalse(service.queue.sync { service.isRouting })
    }

    func testAnAppThatGoesAwayCountsAsQuitting() {
        makeService()
        let (client, heard) = makeClient()
        waitUntil("hello") { heard.welcome != nil }
        client.dropConnection()  // no goodbye, as when the app crashes
        waitUntil("the app to count as gone") { idle.value == 1 }
        XCTAssertTrue(router.calls.contains("stop"))
    }

    // MARK: Measuring

    func testAMeasurementHoldsAndResumesExactlyTheAffectedSinksOverXPC() throws {
        makeService()
        let (client, heard) = makeClient()
        waitUntil("hello") { heard.welcome != nil }
        let (plan, affected) = MeasuringSetup.plan()
        let device = SimulatedMeasurementDevice(rooms: [[.init(filters: [], level: -10, delay: 100), nil]])
        let configuration = MeasurementEngine.Configuration(outputUID: MeasuringSetup.speakers.uid, outputName: "Desk Speakers",
                                                            micUID: MeasuringSetup.mic.uid, micName: "Measuring Mic",
                                                            micChannel: 1, channels: 1)
        let engine = MeasurementEngine(configuration: configuration, plan: plan, device: device, routing: client)
        try engine.start()
        XCTAssertEqual(router.holds, [affected], "held before the devices opened")
        XCTAssertEqual(device.opens, 1)
        XCTAssertEqual(service.queue.sync { service.heldSinks }, affected)
        try engine.checkLevel()
        XCTAssertTrue(router.resumes.isEmpty)
        engine.finish()
        waitUntil("the resume") { router.resumes.count == 1 }
        XCTAssertEqual(router.resumes, [affected])
        XCTAssertEqual(service.queue.sync { service.heldSinks }, [])
        client.goodbye()
        XCTAssertEqual(router.resumes.count, 1, "nothing left to resume")
    }

    func testSinksAnAppHeldComeBackWhenItGoesAway() {
        makeService()
        let (client, heard) = makeClient()
        waitUntil("hello") { heard.welcome != nil }
        let sinks: Set<UUID> = [UUID(), UUID()]
        let held = expectation(description: "held")
        client.hold(sinks) { held.fulfill() }
        wait(for: [held], timeout: 5)
        XCTAssertEqual(router.holds, [sinks])
        client.dropConnection()  // the app crashed mid-measurement
        waitUntil("the held sinks to come back") { router.resumes == [sinks] }
        // A request from someone who hasn't said hello is refused.
        let refused = service.queue.sync { service.handle(.hold(sinks), from: NSXPCConnection(serviceName: "nobody")) }
        XCTAssertEqual(refused, .refused("Say hello first."))
    }

    func testRoutesTheSavedSetupAtLaunchWhenKeepingRouting() {
        makeService(saved: graph, keepRouting: true)
        XCTAssertEqual(router.applied.last?.sinks.count, 1, "routing resumes at login without the app")
        XCTAssertEqual(service.queue.sync { service.clientCount }, 0)
    }

    func testFollowsRestartsWakeAndDeviceChanges() {
        makeService(saved: graph, keepRouting: true)
        let before = router.applied.count
        service.queue.async { self.service.coreAudioRestarted() }
        waitUntil("the rebuilds after a restart") { router.applied.count >= before + 2 }
        XCTAssertEqual(router.calls.first, "forget", "the dead sinks are dropped before anything else")
        XCTAssertTrue(events.recent.contains { $0.message == "Core Audio restarted; rebuilding routing" })

        service.queue.async { self.service.woke() }
        waitUntil("the wake check") { router.calls.contains("resetHealth") && router.calls.contains("processes") }
    }

    func testAHelperOfAnotherVersionStopsAndQuits() {
        makeService(saved: graph, keepRouting: true, version: "5")
        let outdated = Box(0)
        service.onOutdated = { outdated.value += 1 }
        for hello in [RoutingRequest.hello(protocolVersion: RoutingXPC.protocolVersion + 1, appVersion: "5", keepRouting: true),
                      .hello(protocolVersion: RoutingXPC.protocolVersion, appVersion: "6", keepRouting: true)] {
            let reply = service.queue.sync { service.handle(hello, from: nil) }
            guard case .outdated = reply else { return XCTFail("\(reply)") }
        }
        XCTAssertFalse(service.queue.sync { service.isRouting }, "the old helper stops routing before it quits")
        XCTAssertTrue(router.calls.contains("stop"))
        waitUntil("the helper to quit") { outdated.value == 2 }
        // The same version is welcome.
        let reply = service.queue.sync { service.handle(.hello(protocolVersion: RoutingXPC.protocolVersion, appVersion: "5", keepRouting: true), from: nil) }
        guard case .welcome = reply else { return XCTFail("\(reply)") }
    }

    func testTheAppConnectsAgainOnceWhenTheHelperIsOutdated() {
        makeService(version: "5")
        let (client, heard) = makeClient(appVersion: "6")
        waitUntil("the client to give up after one retry") { heard.unavailable != nil }
        XCTAssertNil(heard.welcome)
        client.goodbye()
        XCTAssertTrue(heard.unavailable?.contains("doesn't match Junction 6") ?? false, heard.unavailable ?? "")
    }

    // MARK: Falling back

    func testAHelperThatCantBeReachedIsReportedUnavailable() {
        let heard = Heard()
        let client = RoutingClient(machServiceName: "com.kitedrake.junction.test.no-such-service-\(UUID().uuidString)", requirement: nil,
                                   keepRouting: false, callbackQueue: DispatchQueue(label: "test.unavailable")) { heard.add($0) }
        client.helloTimeout = 2
        client.connect()
        waitUntil("the client to give up") { heard.unavailable != nil }
        XCTAssertNil(heard.welcome)
        client.send(graph: graph)  // ignored once given up
        client.goodbye()
    }

    func testPlacementRoutesInTheAppUnlessTheHelperIsRegistered() {
        func choose(demo: Bool = false, testing: Bool = false, build: Bool = true, bundled: Bool = true,
                    _ registration: HelperRegistration = .enabled) -> RoutingPlacement {
            RoutingPlacement.choose(isDemo: demo, isTesting: testing, buildUsesHelper: build, helperBundled: bundled,
                                    registration: registration)
        }
        XCTAssertEqual(choose(), .helper)
        XCTAssertFalse(choose(demo: true).usesHelper, "snapshot mode")
        XCTAssertFalse(choose(testing: true).usesHelper, "tests")
        XCTAssertEqual(choose(build: false), .inProcess("This build routes inside Junction."), "plain builds")
        XCTAssertFalse(choose(bundled: false).usesHelper)
        XCTAssertFalse(choose(.requiresApproval).usesHelper, "turned off in Login Items")
        XCTAssertFalse(choose(.notRegistered).usesHelper)
        XCTAssertFalse(choose(.notFound).usesHelper)
        XCTAssertEqual(choose(.failed("Operation not permitted")),
                       .inProcess("Junction Helper couldn't be registered: Operation not permitted"))
        // A plain build never even asks macOS about the helper.
        var asked = false
        _ = RoutingPlacement.choose(isDemo: false, isTesting: false, buildUsesHelper: false, helperBundled: true,
                                    registration: { asked = true; return .enabled }())
        XCTAssertFalse(asked)
    }

    func testForwardedEventsStayOutOfTheLogFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-forwarded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.log")
        let log = EventLog(file: file)
        log.add(.info, "from the app")
        log.add(.warning, "from the helper", date: Date(timeIntervalSince1970: 0), persist: false)
        XCTAssertEqual(log.recent.map(\.message), ["from the app", "from the helper"])
        XCTAssertEqual(log.recent.last?.date, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(EventLog.savedLines(at: file).count, 1, "the helper writes its own events to the file")
    }
}
