import CoreAudio
import Foundation
import JunctionKernel
import XCTest
import XPC
@testable import JunctionCore

/// Per-app capture through a virtual device, without the driver: a region in this process laid out and written with
/// the driver's own functions (JunctionCaptureRing.h).
final class CaptureTests: XCTestCase {
    static let spotify = AppRef(bundleID: "com.spotify.client", name: "Spotify")

    /// A value for every sample time and channel, never zero, different per client.
    static func signal(_ which: Int, _ time: UInt64, _ channel: Int) -> Float {
        Float(which) * 2 + 0.001 + Float((time * 31 + UInt64(channel) * 7) % 1000) / 1000
    }

    static func play(_ region: CaptureRegion, slot: UInt32, which: Int, at time: UInt64, frames: Int, channels: Int = 2) {
        var samples = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames { for c in 0..<channels { samples[f * channels + c] = signal(which, time + UInt64(f), c) } }
        jcap_write(region.base, slot, samples, UInt32(channels), UInt32(frames), time)
    }

    func testAFakeSharedRingReadsBackEachClientOnItsOwn() throws {
        let region = try XCTUnwrap(CaptureRegion.makeLocal())
        let music = jcap_claim(region.base, 3, 501, "com.spotify.client", Demo.streamMix.uid, 2)
        let call = jcap_claim(region.base, 7, 502, "com.hnc.Discord", Demo.streamMix.uid, 2)
        for t in stride(from: UInt64(48_000), to: 48_000 + 4096, by: 512) {
            Self.play(region, slot: 3, which: 1, at: t, frames: 512)
            Self.play(region, slot: 7, which: 2, at: t, frames: 512)
        }
        let slots = region.slots()
        XCTAssertEqual(slots.map(\.index), [3, 7])
        XCTAssertEqual(slots.first?.bundleID, "com.spotify.client")
        XCTAssertEqual(slots.first?.deviceUID, Demo.streamMix.uid)
        XCTAssertEqual(slots.first?.pid, 501)
        XCTAssertEqual(slots.first?.end, 48_000 + 4096)
        XCTAssertEqual(slots.first?.sequence, music)
        let spotifySlots = region.slots(device: Demo.streamMix.uid, clients: [CaptureClientRef(pid: 501, bundleID: "com.spotify.client")])
        XCTAssertEqual(spotifySlots.map(\.index), [3], "only the asked-for client's slot")

        let read = try XCTUnwrap(region.read(slots[0], at: 48_000, frames: 4096, channels: 2))
        XCTAssertEqual(read[0], Self.signal(1, 48_000, 0))
        XCTAssertTrue((0..<4096).allSatisfy { read[$0 * 2 + 1] == Self.signal(1, 48_000 + UInt64($0), 1) }, "only its own client")
        let other = try XCTUnwrap(region.read(slots[1], at: 48_000, frames: 4096, channels: 2))
        XCTAssertTrue((0..<4096).allSatisfy { other[$0 * 2] == Self.signal(2, 48_000 + UInt64($0), 0) })
        // Wider than the client: the extra channels are silent.
        let wide = try XCTUnwrap(region.read(slots[0], at: 48_000, frames: 4, channels: 4))
        XCTAssertEqual(wide[2], 0)
        XCTAssertEqual(wide[4], Self.signal(1, 48_001, 0))

        // A client that left: readers are told; a new client in the slot gets a new sequence.
        jcap_release(region.base, 7)
        XCTAssertNil(region.read(slots[1], at: 48_000, frames: 16, channels: 2))
        XCTAssertEqual(region.slots().map(\.index), [3])
        let next = jcap_claim(region.base, 7, 503, "com.example.game", Demo.streamMix.uid, 2)
        XCTAssertNotEqual(next, call)

        // Overrun: a reader that fell behind gets silence for what was overwritten, not a later lap.
        Self.play(region, slot: 3, which: 1, at: 48_000 + 4096, frames: CaptureRegion.frames)
        let behind = try XCTUnwrap(region.read(slots[0], at: 48_000 + 4000, frames: 200, channels: 2))
        XCTAssertTrue(behind.prefix(96 * 2).allSatisfy { $0 == 0 }, "overwritten frames read as silence")
        XCTAssertEqual(behind[96 * 2], Self.signal(1, 48_000 + 4096, 0))
    }

    func testTheKernelPumpsACaptureIntoItsConverter() throws {
        let region = try XCTUnwrap(CaptureRegion.makeLocal())
        let sequence = jcap_claim(region.base, 0, 501, "com.spotify.client", Demo.streamMix.uid, 2)
        let converter = try XCTUnwrap(jk_converter_create(2, 48_000, 48_000))
        defer { jk_converter_destroy(converter) }
        jk_converter_set_same_clock(converter, 1)
        var slots: [UInt32] = [0], sequences = [sequence]
        let capture = try XCTUnwrap(jk_capture_create(region.base, region.size, &slots, &sequences, 1, 2, 48_000, converter))
        defer { jk_capture_destroy(capture) }
        XCTAssertNil(jk_capture_create(region.base, 4096, &slots, &sequences, 1, 2, 48_000, converter), "too small a region")

        var time: UInt64 = 96_000
        var heard: Float = 0
        var output = [Float](repeating: 0, count: 2 * 512)
        for cycle in 0..<200 {
            for _ in 0..<2 {  // the driver writes 256-frame cycles, the sink reads 512
                var samples = [Float](repeating: 0.5, count: 256 * 2)
                jcap_write(region.base, 0, &samples, 2, 256, time)
                time += 256
            }
            jk_capture_pump(capture)
            output.withUnsafeMutableBufferPointer { jk_converter_read(converter, $0.baseAddress!, 512, 512, nil) }
            if cycle > 150 { heard = max(heard, output.map(abs).max() ?? 0) }
        }
        XCTAssertGreaterThan(jk_capture_frame_count(capture), 190 * 512, "frames reach the converter")
        XCTAssertEqual(heard, 0.5, accuracy: 0.01, "the app's audio comes out of the converter")
        XCTAssertEqual(jk_capture_overrun_count(capture), 0)

        // The sink stalls for longer than the ring: the capture skips ahead and counts it.
        for _ in 0..<(CaptureRegion.frames / 256 + 8) {
            var samples = [Float](repeating: 0.5, count: 256 * 2)
            jcap_write(region.base, 0, &samples, 2, 256, time)
            time += 256
        }
        jk_capture_pump(capture)
        XCTAssertEqual(jk_capture_overrun_count(capture), 1)
        // The client leaves: nothing more is passed on.
        let frames = jk_capture_frame_count(capture)
        jcap_release(region.base, 0)
        jk_capture_pump(capture)
        XCTAssertEqual(jk_capture_frame_count(capture), frames)
    }

    func testTheBrokerHandsTheDriversRegionOnlyToJunction() throws {
        let region = try XCTUnwrap(CaptureRegion.makeLocal())
        _ = jcap_claim(region.base, 5, 501, "com.spotify.client", Demo.streamMix.uid, 2)
        Self.play(region, slot: 5, which: 1, at: 1000, frames: 512)
        let broker = CaptureBroker()
        func message(_ op: String, region shared: xpc_object_t? = nil) -> xpc_object_t {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "op", op)
            xpc_dictionary_set_uint64(message, "layout", UInt64(JCAP_LAYOUT))
            if let shared { xpc_dictionary_set_value(message, "region", shared) }
            return message
        }
        let created: xpc_object_t? = xpc_shmem_create(region.base, Int(region.size))
        let shared = try XCTUnwrap(created)
        broker.queue.sync {
            XCTAssertNil(broker.handle(message("publish", region: shared), from: .junction))
        }
        XCTAssertFalse(broker.holdsRegion, "only the driver publishes")
        broker.queue.sync { _ = broker.handle(message("publish", region: shared), from: .driver) }
        XCTAssertTrue(broker.holdsRegion)

        // Junction maps it over XPC (an anonymous listener in this process) and sees the driver's rings.
        let listener = xpc_connection_create(nil, broker.queue)
        broker.serve(listener) { _ in .junction }
        let connection = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
        let mapped = try XCTUnwrap(CaptureBrokerClient.fetchRegion(over: connection))
        let slot = try XCTUnwrap(mapped.slots().first)
        XCTAssertEqual(slot.bundleID, "com.spotify.client")
        XCTAssertEqual(mapped.read(slot, at: 1000, frames: 1, channels: 2), [Self.signal(1, 1000, 0), Self.signal(1, 1000, 1)])
        Self.play(region, slot: 5, which: 1, at: 1512, frames: 16)
        XCTAssertEqual(mapped.slots().first?.end, 1528, "shared memory, not a copy")
        xpc_connection_cancel(connection)

        // A peer that isn't Junction (or the driver asking to map) gets nothing.
        let refused = broker.queue.sync { broker.handle(message("map"), from: .driver) }
        XCTAssertNil(refused.flatMap { xpc_dictionary_get_value($0, "region") })
        let stranger = xpc_connection_create(nil, broker.queue)
        broker.serve(stranger) { _ in nil }
        let strangerConnection = xpc_connection_create_from_endpoint(xpc_endpoint_create(stranger))
        XCTAssertNil(CaptureBrokerClient.fetchRegion(over: strangerConnection, timeout: 0.5))
        xpc_connection_cancel(strangerConnection)

        XCTAssertNil(CaptureBroker.peerRequirement(teamID: nil), "an ad-hoc signed daemon accepts nobody")
        let requirement = try XCTUnwrap(CaptureBroker.peerRequirement(teamID: "TEAM123456"))
        XCTAssertTrue(requirement.contains("com.apple.audio.coreaudiod") && requirement.contains("local.junction.app")
                      && requirement.contains("local.junction.helper") && requirement.contains("TEAM123456"))
    }

    func testTheDriversClientListNamesEachClientsApp() {
        let list: [[String: Any]] = [
            ["pid": 501, "bundleID": "com.spotify.client", "deviceUID": Demo.streamMix.uid, "channels": 2, "slot": 0],
            ["pid": 502, "bundleID": "com.spotify.client.helper", "deviceUID": Demo.streamMix.uid, "channels": 2],
            ["bundleID": "broken"],
        ]
        let clients = DriverClient.deviceClients(from: list) { _, bundleID in
            AppRef(bundleID: bundleID.hasPrefix("com.spotify") ? "com.spotify.client" : bundleID, name: "Spotify")
        }
        XCTAssertEqual(clients.map(\.pid), [501, 502])
        XCTAssertEqual(Set(clients.map(\.app.bundleID)), ["com.spotify.client"], "helpers belong to their app")
        var inventory = Demo.inventory
        inventory.deviceClients = clients
        XCTAssertEqual(inventory.appsThroughDevices([Demo.streamMix, Demo.chat]),
                       [AppThroughDevice(app: clients[0].app, device: Demo.streamMix.id)], "one entry per app and device")
    }

    // MARK: Planning

    /// Spotify plays into Chat; Stream Mix's canvas takes just Spotify from Chat.
    static func streamFromSpotifyThroughChat(playing: Bool = true) -> (Graph, Inventory, Node, Node) {
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat])
        graph.tidyCanvases()
        let mix = graph.deviceNode(Demo.streamMix.id)!
        let source = Node(kind: .appThroughDevice(spotify, device: Demo.chat.id), canvas: Demo.streamMix.id)
        graph.nodes.append(source)
        graph.cables = [0, 1].map { Cable(from: PortRef(node: source.id, channel: $0), to: PortRef(node: mix.id, channel: $0)) }
        var inventory = Demo.inventory
        for index in inventory.devices.indices where inventory.devices[index].isJunction {
            inventory.devices[index].clockDomain = 0x6A6E_6374  // 'jnct': one clock
        }
        if playing {
            inventory.deviceClients = [DeviceClient(pid: 501, bundleID: spotify.bundleID, deviceUID: Demo.chat.uid, app: spotify),
                                       DeviceClient(pid: 777, bundleID: "com.other", deviceUID: Demo.chat.uid,
                                                    app: AppRef(bundleID: "com.other", name: "Other"))]
        }
        return (graph, inventory, mix, source)
    }

    func testThePlannerReadsTheAppsRingAfterTheConvertedDevices() throws {
        let (graph, inventory, mix, source) = Self.streamFromSpotifyThroughChat()
        let info = NodeInfo(graph: graph, inventory: inventory)
        XCTAssertEqual(info.title(source), "Spotify through Chat")
        XCTAssertEqual(info.ports(source), PortCounts(inputs: 0, outputs: 2))
        XCTAssertEqual(info.subtitle(source), "App audio · playing into Chat")
        let plan = Planner.plan(graph, inventory: inventory)
        let sink = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(sink.sinkNode, mix.id)
        XCTAssertEqual(sink.captures.count, 1)
        let capture = sink.captures[0]
        XCTAssertEqual(capture.deviceUID, Demo.chat.uid)
        XCTAssertEqual(capture.clients, [CaptureClientRef(pid: 501, bundleID: Self.spotify.bundleID)], "only Spotify's processes")
        XCTAssertTrue(capture.sameClock)
        XCTAssertTrue(sink.subDevices.allSatisfy { $0.uid != Demo.chat.uid }, "Chat itself isn't recorded")
        XCTAssertEqual(sink.routes.map(\.input), [sink.inputChannels, sink.inputChannels + 1])
        XCTAssertTrue(plan.idleCables.isEmpty)

        // Another process of the app joining rebuilds the sink; a gain change doesn't.
        var more = inventory
        more.deviceClients.append(DeviceClient(pid: 502, bundleID: "com.spotify.helper", deviceUID: Demo.chat.uid, app: Self.spotify))
        XCTAssertNotEqual(Planner.plan(graph, inventory: more).sinks.first?.structureKey, sink.structureKey)
        var louder = graph
        louder.cables[0].gainDB = -6
        XCTAssertEqual(Planner.plan(louder, inventory: inventory).sinks.first?.structureKey, sink.structureKey)
    }

    func testAnAppThatIsntPlayingLeavesItsCablesIdle() {
        let (graph, inventory, _, source) = Self.streamFromSpotifyThroughChat(playing: false)
        let plan = Planner.plan(graph, inventory: inventory)
        XCTAssertTrue(plan.sinks.isEmpty)
        XCTAssertEqual(plan.idleCables, Set(graph.cables.map(\.id)))
        XCTAssertEqual(NodeInfo(graph: graph, inventory: inventory).subtitle(source), "Not playing into Chat")
    }

    func testAnAppThroughADeviceCantFeedThatDevice() throws {
        var (graph, inventory, _, _) = Self.streamFromSpotifyThroughChat()
        // On Chat's own canvas, Spotify through Chat into Chat would feed Chat's audio back into it.
        let chat = try XCTUnwrap(graph.deviceNode(Demo.chat.id))
        let own = Node(kind: .appThroughDevice(Self.spotify, device: Demo.chat.id), canvas: Demo.chat.id)
        graph.nodes.append(own)
        let into = PortRef(node: chat.id, channel: 0)
        XCTAssertEqual(Rules.check(from: PortRef(node: own.id, channel: 0), to: into, graph: graph, inventory: inventory), .feedback)
        var forced = graph
        forced.cables.append(Cable(from: PortRef(node: own.id, channel: 0), to: into))
        let plan = Planner.plan(forced, inventory: inventory)
        XCTAssertTrue(plan.idleCables.contains(forced.cables.last!.id), "the planner refuses it too")
        XCTAssertTrue(plan.issues[chat.id]?.first?.contains("feed its own audio back") ?? false)
        inventory.deviceClients = []
        XCTAssertEqual(Rules.check(from: PortRef(node: own.id, channel: 0), to: into, graph: graph, inventory: inventory), .feedback,
                       "refused whether or not the app is playing")
    }

    func testTheLoopGuardFollowsAnAppThroughItsDevice() throws {
        // Stream Mix takes Spotify through Chat (Chat → Stream Mix). Sending Stream Mix into Chat would close a loop.
        var (graph, inventory, _, _) = Self.streamFromSpotifyThroughChat()
        let chat = try XCTUnwrap(graph.deviceNode(Demo.chat.id))
        let stream = Node(kind: .device(DeviceRef(uid: Demo.streamMix.uid, name: "Stream Mix", inputChannels: 2, outputChannels: 2)),
                          canvas: Demo.chat.id)
        graph.nodes.append(stream)
        let from = PortRef(node: stream.id, channel: 0), to = PortRef(node: chat.id, channel: 0)
        XCTAssertEqual(Rules.check(from: from, to: to, graph: graph, inventory: inventory), .feedback)
        // The planner, given the same loop, uses only one direction of it.
        graph.cables.append(Cable(from: from, to: to))
        let plan = Planner.plan(graph, inventory: inventory)
        XCTAssertEqual(plan.idleCables.count, 1, "one cable of the loop is dropped")
        // Without the cable from Spotify through Chat there's no loop.
        var without = graph
        without.cables.removeAll { $0.to.node != chat.id }
        XCTAssertNil(Rules.check(from: from, to: PortRef(node: chat.id, channel: 1), graph: without, inventory: inventory))
        // Another app through Chat on Chat's canvas is refused, through Stream Mix is fine.
        let other = AppRef(bundleID: "com.other", name: "Other")
        let viaStream = Node(kind: .appThroughDevice(other, device: Demo.streamMix.id), canvas: Demo.chat.id)
        without.nodes.append(viaStream)
        XCTAssertNil(Rules.check(from: PortRef(node: viaStream.id, channel: 0), to: PortRef(node: chat.id, channel: 1),
                                 graph: without, inventory: inventory))
    }

    func testAnAppThroughADeviceIsSavedInSchema4() throws {
        let (graph, _, _, source) = Self.streamFromSpotifyThroughChat()
        let data = try JSONEncoder().encode(graph)
        var loaded = try JSONDecoder().decode(Graph.self, from: data)
        loaded.upgrade()
        XCTAssertEqual(loaded.schema, 4)
        XCTAssertEqual(loaded.node(source.id)?.kind, .appThroughDevice(Self.spotify, device: Demo.chat.id))
        XCTAssertEqual(loaded.cables, graph.cables, "its cables survive tidying")
        // Deleting the device it captures from leaves the node, which then says so.
        var deleted = loaded
        deleted.removeVirtualDevice(Demo.chat.id)
        XCTAssertEqual(NodeInfo(graph: deleted, inventory: Demo.inventory).title(source), "Spotify through Deleted Device")
        XCTAssertEqual(Planner.unavailableReason(source, graph: deleted, inventory: Demo.inventory), "This virtual device was deleted.")
    }
}
