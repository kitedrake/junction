import CoreAudio
import Foundation
import JunctionKernel
import XPC

// Per-app capture through a virtual device: the driver keeps what each app plays into one of Junction's devices in a
// ring of its own (JunctionCaptureRing.h), in one shared memory region. Junction Driver Installer (the privileged
// daemon) takes the region from the driver over its Mach service `com.kitedrake.junction.driverd.capture` and hands it only to
// Junction and Junction Helper signed by its own team. The canvas offers "<app> through <device>" for apps playing
// into a virtual device right now (the driver's 'jcli' list); the router reads their rings.

/// A client of one of Junction's virtual devices that the driver captures: an app's process playing into it.
public struct DeviceClient: Hashable, Sendable {
    public var pid: Int32
    /// The client process's own bundle ID (a helper's, for apps that play from helpers).
    public var bundleID: String
    /// The virtual device it plays into.
    public var deviceUID: String
    /// Channels kept per frame (the device's first ones, at most `CaptureRegion.maxChannels`).
    public var channels: Int
    /// The app it belongs to.
    public var app: AppRef

    public init(pid: Int32, bundleID: String, deviceUID: String, channels: Int = 2, app: AppRef) {
        self.pid = pid
        self.bundleID = bundleID
        self.deviceUID = deviceUID
        self.channels = channels
        self.app = app
    }
}

/// An "<app> through <device>" source: which apps play into which virtual devices right now.
public struct AppThroughDevice: Hashable, Sendable, Identifiable {
    public var app: AppRef
    public var device: UUID
    public var id: String { "\(app.bundleID)>\(device.uuidString)" }

    public init(app: AppRef, device: UUID) {
        self.app = app
        self.device = device
    }
}

extension Inventory {
    /// The captured clients of one app playing into a virtual device.
    public func clients(of app: String, through device: VirtualDevice) -> [DeviceClient] {
        deviceClients.filter { $0.app.bundleID == app && $0.deviceUID == device.uid }
    }

    /// Apps playing into Junction's devices right now, one entry per app and device, by device then app name.
    public func appsThroughDevices(_ devices: [VirtualDevice]) -> [AppThroughDevice] {
        var result: [AppThroughDevice] = []
        for device in devices {
            var seen = Set<String>()
            let apps = deviceClients.filter { $0.deviceUID == device.uid }.map(\.app)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for app in apps where seen.insert(app.bundleID).inserted {
                result.append(AppThroughDevice(app: app, device: device.id))
            }
        }
        return result
    }
}

/// The driver's capture region, mapped into this process.
public final class CaptureRegion: @unchecked Sendable {
    public static let slots = Int(JCAP_SLOTS)
    public static let frames = Int(JCAP_FRAMES)
    public static let maxChannels = Int(JCAP_MAX_CHANNELS)
    public static let byteCount = jcap_region_bytes()

    public let base: UnsafeMutableRawPointer
    public let size: UInt64
    private let deallocate: Bool

    /// Wraps memory holding a region. With `owned`, the memory is a VM allocation or mapping this object frees.
    public init?(base: UnsafeMutableRawPointer, size: UInt64, owned: Bool) {
        guard jcap_valid(base, size) != 0 else {
            if owned { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: base)), vm_size_t(size)) }
            return nil
        }
        self.base = base
        self.size = size
        deallocate = owned
    }

    deinit {
        if deallocate { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: base)), vm_size_t(size)) }
    }

    /// A new, empty region in this process, laid out as the driver lays it out (tests, snapshots and the self-test
    /// write it with the driver's own functions).
    public static func makeLocal() -> CaptureRegion? {
        var address: vm_address_t = 0
        guard vm_allocate(mach_task_self_, &address, vm_size_t(byteCount), VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
              let base = UnsafeMutableRawPointer(bitPattern: UInt(address))
        else { return nil }
        jcap_init(base, mach_absolute_time(), mach_absolute_time())
        return CaptureRegion(base: base, size: byteCount, owned: true)
    }

    /// A client slot as the reader sees it.
    public struct Slot: Equatable, Sendable {
        public var index: Int
        public var sequence: UInt32
        public var pid: Int32
        public var bundleID: String
        public var deviceUID: String
        public var channels: Int
        /// Device sample time just past the last frame written.
        public var end: UInt64
        public var overruns: UInt64
    }

    /// The live slots.
    public func slots() -> [Slot] {
        (0..<Self.slots).compactMap { index in
            var client = JCapClient()
            guard jcap_client(base, UInt32(index), &client) != 0, client.live != 0 else { return nil }
            return Slot(index: index, sequence: client.sequence, pid: client.pid,
                        bundleID: Self.text(&client.bundleID), deviceUID: Self.text(&client.deviceUID),
                        channels: Int(client.channels), end: client.end, overruns: client.overruns)
        }
    }

    /// The slots of the given processes playing into a device (at most `JK_CAPTURE_MAX_SLOTS`).
    public func slots(device uid: String, clients: [CaptureClientRef]) -> [Slot] {
        Array(slots().filter { slot in
            slot.deviceUID == uid && clients.contains { $0.pid == slot.pid && $0.bundleID == slot.bundleID }
        }.prefix(Int(JK_CAPTURE_MAX_SLOTS)))
    }

    /// Frames [time, time + frames) of a slot, interleaved, `channels` per frame; nil when the slot changed hands.
    public func read(_ slot: Slot, at time: UInt64, frames: Int, channels: Int) -> [Float]? {
        var out = [Float](repeating: 0, count: frames * channels)
        let result = out.withUnsafeMutableBufferPointer {
            jcap_read(base, UInt32(slot.index), slot.sequence, time, UInt32(frames), $0.baseAddress!, UInt32(channels))
        }
        return result == Int64(JCAP_READ_GONE) ? nil : out
    }

    private static func text<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Where the router gets it

    /// What the router reads rings from. By default the region comes from Junction Driver Installer; tests and
    /// snapshot mode put a local one here.
    nonisolated(unsafe) public static var source: () -> CaptureRegion? = { CaptureBrokerClient.fetchRegion() }
}

/// One process of an app the planner wants captured.
public struct CaptureClientRef: Hashable, Sendable {
    public var pid: Int32
    public var bundleID: String

    public init(pid: Int32, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

// MARK: - The daemon's side

/// Keeps the region the driver publishes and gives it to Junction. Messages are XPC dictionaries with "op":
/// "publish" (from the driver, with "region", an XPC shared memory object, and "layout") and "map" (from Junction;
/// the reply has "region", or "error").
public final class CaptureBroker: @unchecked Sendable {
    /// Who is on the other end of a connection, as the daemon's code-signing checks establish it.
    public enum Peer: Sendable { case driver, junction }

    public static let machServiceName = "com.kitedrake.junction.driverd.capture"
    /// The processes the driver runs in: coreaudiod, or its driver service.
    public static let driverHostRequirement =
        "anchor apple and (identifier \"com.apple.audio.coreaudiod\" or identifier \"com.apple.audio.Core-Audio-Driver-Service\")"
    /// coreaudiod's user (_coreaudiod): only it publishes; everyone else that passes the checks is Junction.
    public static let coreAudioUserID: uid_t = 202

    public let queue: DispatchQueue
    private var region: xpc_object_t?   // `queue` only
    private var connections: [xpc_connection_t] = []
    /// Set while it holds a region: the daemon doesn't quit then (it is the only way Junction gets it).
    public var holdsRegion: Bool { queue.sync { region != nil } }

    public init(queue: DispatchQueue = DispatchQueue(label: "com.kitedrake.junction.driverd.capture")) {
        self.queue = queue
    }

    /// The requirement a peer must meet: the driver's host, or Junction or Junction Helper signed by `teamID`. Nil
    /// without a team (ad-hoc signed daemon): it accepts nobody.
    public static func peerRequirement(teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        let app = RoutingXPC.peerRequirement(identifier: RoutingXPC.appBundleIdentifier, teamID: teamID)
        let helper = RoutingXPC.peerRequirement(identifier: RoutingXPC.helperBundleIdentifier, teamID: teamID)
        return "(\(driverHostRequirement)) or (\(app)) or (\(helper))"
    }

    /// Handles one message. Returns the reply to send, if any. Call on `queue`.
    public func handle(_ message: xpc_object_t, from peer: Peer) -> xpc_object_t? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, let op = xpc_dictionary_get_string(message, "op") else { return nil }
        switch (String(cString: op), peer) {
        case ("publish", .driver):
            guard xpc_dictionary_get_uint64(message, "layout") == UInt64(JCAP_LAYOUT),
                  let shared = xpc_dictionary_get_value(message, "region"), xpc_get_type(shared) == XPC_TYPE_SHMEM
            else { return nil }
            region = shared
            return nil
        case ("map", .junction):
            let reply = xpc_dictionary_create_reply(message) ?? xpc_dictionary_create(nil, nil, 0)
            if let region {
                xpc_dictionary_set_value(reply, "region", region)
            } else {
                xpc_dictionary_set_string(reply, "error", "The driver hasn't shared its capture region yet.")
            }
            return reply
        default:
            let reply = xpc_dictionary_create_reply(message)
            if let reply { xpc_dictionary_set_string(reply, "error", "Not allowed.") }
            return reply
        }
    }

    /// Serves a listener: every new peer is classified by `classify` (nil: refused) before its messages are handled.
    public func serve(_ listener: xpc_connection_t, classify: @escaping (xpc_connection_t) -> Peer?) {
        xpc_connection_set_event_handler(listener) { [weak self] peer in
            guard let self, xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            guard let kind = classify(peer) else {
                xpc_connection_cancel(peer)
                return
            }
            xpc_connection_set_target_queue(peer, self.queue)
            xpc_connection_set_event_handler(peer) { [weak self] message in
                guard let self else { return }
                if xpc_get_type(message) == XPC_TYPE_ERROR {
                    self.connections.removeAll { $0 === peer }
                    return
                }
                if let reply = self.handle(message, from: kind) { xpc_connection_send_message(peer, reply) }
            }
            self.queue.async { self.connections.append(peer) }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
    }

    /// The daemon's listener on its Mach service, with the code-signing checks.
    public func listen(teamID: String?) -> xpc_connection_t {
        let listener = xpc_connection_create_mach_service(Self.machServiceName, queue,
                                                          UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        let requirement = Self.peerRequirement(teamID: teamID)
        serve(listener) { peer in
            guard let requirement, xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else { return nil }
            return xpc_connection_get_euid(peer) == Self.coreAudioUserID ? .driver : .junction
        }
        return listener
    }
}

/// Junction's side: asks the daemon for the region and maps it.
public enum CaptureBrokerClient {
    /// Fetches and maps the region from the daemon's Mach service. Nil when the daemon isn't installed or allowed,
    /// hasn't got a region (no driver loaded yet), or doesn't answer in time.
    public static func fetchRegion(timeout: TimeInterval = 2) -> CaptureRegion? {
        let connection = xpc_connection_create_mach_service(CaptureBroker.machServiceName, nil,
                                                            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        let requirement = DriverDaemon.daemonRequirement(teamID: RoutingXPC.ownTeamID())
        _ = xpc_connection_set_peer_code_signing_requirement(connection, requirement)
        defer { xpc_connection_cancel(connection) }
        return fetchRegion(over: connection, timeout: timeout)
    }

    /// The same over any connection (tests use an anonymous listener).
    public static func fetchRegion(over connection: xpc_connection_t, timeout: TimeInterval = 2) -> CaptureRegion? {
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "op", "map")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: xpc_object_t?
        xpc_connection_send_message_with_reply(connection, message, nil) { reply in
            answer = reply
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let reply = answer,
              xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              let shared = xpc_dictionary_get_value(reply, "region"), xpc_get_type(shared) == XPC_TYPE_SHMEM
        else { return nil }
        var pointer: UnsafeMutableRawPointer?
        let size = xpc_shmem_map(shared, &pointer)
        guard size > 0, let pointer else { return nil }
        return CaptureRegion(base: pointer, size: UInt64(size), owned: true)
    }
}
