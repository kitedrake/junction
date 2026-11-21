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
                                          .graph(graph), .rebuildAll, .requestMicrophone, .keepRouting(false), .goodbye]
        let replies: [RoutingReply] = [.welcome(state), .done, .refused("no"), .outdated("old")]
        let notices: [RoutingNotice] = [
            .statuses(statuses),
            .meters([PortKey(node: node, isOutput: true, channel: 1): 0.5, PortKey(node: node, isOutput: false, channel: 0): 0.25]),
            .events([LoggedEvent(date: Date(timeIntervalSince1970: 1_700_000_000), kind: .warning, message: "Core Audio restarted")]),
            .permission(.allowed), .permission(.notAsked), .permission(.restricted),
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
        XCTAssertEqual(RoutingXPC.peerRequirement(identifier: "local.junction.app", teamID: nil), "identifier \"local.junction.app\"")
        XCTAssertEqual(RoutingXPC.peerRequirement(identifier: "local.junction.helper", teamID: "ABCDE12345"),
                       "identifier \"local.junction.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
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
        let client = RoutingClient(machServiceName: "local.junction.test.no-such-service-\(UUID().uuidString)", requirement: nil,
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
