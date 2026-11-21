import Foundation

/// The app's side of routing in the helper: connects (launchd starts the helper on the first message), says hello,
/// sends every new setup, and passes on what the helper reports. If the helper crashes, the next message starts it
/// again and the client sends hello and the setup once more. When the helper can't be reached the client reports
/// `unavailable` and stops; the app then routes by itself.
public final class RoutingClient: NSObject, RoutingAppXPC, @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case connected(HelperState)
        case notice(RoutingNotice)
        case unavailable(String)
    }

    private let makeConnection: () -> NSXPCConnection
    private let callbackQueue: DispatchQueue
    private let handler: (Event) -> Void
    private let lock = NSLock()
    // Under `lock`.
    private var connection: NSXPCConnection?
    private var keepRouting: Bool
    private let appVersion: String?
    /// Reconnections after the helper said it was outdated.
    private var outdatedRetries = 0
    private var sentGraph: Graph?
    private var pendingGraph: Graph?
    private var isConnected = false
    private var isFinished = false
    private var interruptions: [Date] = []

    /// How long the helper has to answer hello.
    public var helloTimeout: TimeInterval = 5
    /// The helper restarting this many times within a minute counts as unavailable.
    public static let interruptionLimit = 3

    /// Talks to the helper's Mach service. `requirement`: the code-signing requirement the helper must meet.
    public convenience init(machServiceName: String = RoutingXPC.machServiceName, requirement: String?, keepRouting: Bool,
                            appVersion: String? = nil, callbackQueue: DispatchQueue = .main, handler: @escaping (Event) -> Void) {
        self.init(keepRouting: keepRouting, appVersion: appVersion, callbackQueue: callbackQueue, handler: handler) {
            let connection = NSXPCConnection(machServiceName: machServiceName)
            if let requirement { connection.setCodeSigningRequirement(requirement) }
            return connection
        }
    }

    /// Talks to a listener in this process (tests).
    public convenience init(endpoint: NSXPCListenerEndpoint, keepRouting: Bool, appVersion: String? = nil,
                            callbackQueue: DispatchQueue, handler: @escaping (Event) -> Void) {
        self.init(keepRouting: keepRouting, appVersion: appVersion, callbackQueue: callbackQueue, handler: handler) {
            NSXPCConnection(listenerEndpoint: endpoint)
        }
    }

    init(keepRouting: Bool, appVersion: String?, callbackQueue: DispatchQueue, handler: @escaping (Event) -> Void,
         makeConnection: @escaping () -> NSXPCConnection) {
        self.keepRouting = keepRouting
        self.appVersion = appVersion
        self.callbackQueue = callbackQueue
        self.handler = handler
        self.makeConnection = makeConnection
    }

    /// Opens the connection and says hello.
    public func connect() {
        let connection = makeConnection()
        connection.remoteObjectInterface = RoutingXPC.helperInterface()
        connection.exportedInterface = RoutingXPC.appInterface()
        connection.exportedObject = WeakReceiver(self)
        connection.interruptionHandler = { [weak self] in self?.interrupted() }
        connection.invalidationHandler = { [weak self] in self?.fail("The connection to \(RoutingXPC.helperDisplayName) closed.") }
        let old = lock.withLock { () -> NSXPCConnection? in
            let old = self.connection
            self.connection = connection
            isConnected = false
            isFinished = false
            return old
        }
        old?.invalidationHandler = nil
        old?.invalidate()
        connection.resume()
        sayHello()
    }

    private func sayHello() {
        let keep = lock.withLock { keepRouting }
        var answered = false
        let answeredLock = NSLock()
        send(.hello(protocolVersion: RoutingXPC.protocolVersion, appVersion: appVersion, keepRouting: keep)) { [weak self] reply in
            answeredLock.withLock { answered = true }
            guard let self else { return }
            switch reply {
            case .welcome(let state):
                let graph = self.lock.withLock { () -> Graph? in
                    self.isConnected = true
                    self.sentGraph = nil
                    return self.pendingGraph
                }
                self.deliver(.connected(state))
                if let graph { self.send(graph: graph) }
            case .refused(let reason): self.fail(reason)
            case .outdated(let reason): self.replaceOutdatedHelper(reason)
            case .done, nil: self.fail("\(RoutingXPC.helperDisplayName) didn't answer.")
            }
        }
        callbackQueue.asyncAfter(deadline: .now() + helloTimeout) { [weak self] in
            guard !answeredLock.withLock({ answered }) else { return }
            self?.fail("\(RoutingXPC.helperDisplayName) didn't answer within \(Int(self?.helloTimeout ?? 0)) s.")
        }
    }

    /// The helper left running is another version; it quits. Connect again once, which starts the one inside this app.
    private func replaceOutdatedHelper(_ reason: String) {
        let retry = lock.withLock { () -> Bool in
            outdatedRetries += 1
            return outdatedRetries <= 1 && !isFinished
        }
        guard retry else { return fail(reason) }
        let connection = lock.withLock { self.connection }
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        callbackQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    /// Sends the setup when it differs from the last one sent (and again after the helper restarts).
    public func send(graph: Graph) {
        let send = lock.withLock { () -> Bool in
            pendingGraph = graph
            guard isConnected, sentGraph != graph else { return false }
            sentGraph = graph
            return true
        }
        guard send else { return }
        self.send(.graph(graph)) { _ in }
    }

    public func rebuildAll() { send(.rebuildAll) { _ in } }

    /// Asks the helper to open a plugin's window; `done` gets why it couldn't (nil once it did), on the callback queue.
    public func openPluginWindow(_ effect: UUID, title: String, done: @escaping (String?) -> Void) {
        let callbackQueue = callbackQueue
        send(.openPluginWindow(effect: effect, title: title)) { reply in
            let problem: String? = switch reply {
            case .done: nil
            case .refused(let reason): reason
            default: "\(RoutingXPC.helperDisplayName) didn't answer."
            }
            callbackQueue.async { done(problem) }
        }
    }

    public func requestMicrophone() { send(.requestMicrophone) { _ in } }

    public func setKeepRouting(_ keep: Bool) {
        lock.withLock { keepRouting = keep }
        send(.keepRouting(keep)) { _ in }
    }

    /// The app is quitting: tells the helper (waiting up to `timeout`), then closes the connection.
    public func goodbye(timeout: TimeInterval = 1) {
        let (connection, connected) = lock.withLock { () -> (NSXPCConnection?, Bool) in
            isFinished = true
            return (self.connection, isConnected)
        }
        guard let connection else { return }
        if connected, let data = try? RoutingXPC.encode(RoutingRequest.goodbye) {
            let done = DispatchSemaphore(value: 0)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? RoutingHelperXPC
            proxy?.handle(data) { _ in done.signal() }
            _ = done.wait(timeout: .now() + timeout)
        }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
    }

    /// Closes the connection without a goodbye, as a crash would (tests).
    func dropConnection() {
        let connection = lock.withLock { () -> NSXPCConnection? in
            isFinished = true
            return self.connection
        }
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    // MARK: Plumbing

    private func send(_ request: RoutingRequest, reply: @escaping (RoutingReply?) -> Void) {
        guard let connection = lock.withLock({ isFinished ? nil : self.connection }),
              let data = try? RoutingXPC.encode(request) else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply(nil) } as? RoutingHelperXPC
        proxy?.handle(data) { answer in reply(try? RoutingXPC.decode(RoutingReply.self, from: answer)) }
    }

    /// The helper went away (crashed or was killed); launchd starts it again on the next message.
    private func interrupted() {
        let now = Date()
        let tooOften = lock.withLock { () -> Bool in
            guard !isFinished else { return false }
            isConnected = false
            interruptions = interruptions.filter { now.timeIntervalSince($0) < 60 } + [now]
            return interruptions.count >= Self.interruptionLimit
        }
        if tooOften {
            fail("\(RoutingXPC.helperDisplayName) stopped \(Self.interruptionLimit) times within a minute.")
        } else {
            callbackQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sayHello() }
        }
    }

    private func fail(_ reason: String) {
        let connection = lock.withLock { () -> NSXPCConnection? in
            guard !isFinished else { return nil }
            isFinished = true
            isConnected = false
            return self.connection
        }
        guard let connection else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        deliver(.unavailable(reason))
    }

    private func deliver(_ event: Event) {
        callbackQueue.async { self.handler(event) }
    }

    public func receive(_ notice: Data) {
        guard let notice = try? RoutingXPC.decode(RoutingNotice.self, from: notice) else { return }
        deliver(.notice(notice))
    }

    /// The connection keeps its exported object alive; this keeps it from keeping the client alive too.
    private final class WeakReceiver: NSObject, RoutingAppXPC, @unchecked Sendable {
        weak var client: RoutingClient?
        init(_ client: RoutingClient) { self.client = client }
        func receive(_ notice: Data) { client?.receive(notice) }
    }
}
