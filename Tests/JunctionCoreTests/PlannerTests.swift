import XCTest
@testable import JunctionCore

/// A made-up system: built-in speakers and mic, a USB interface, Junction installed with two virtual devices.
enum Demo {
    static let streamMix = VirtualDevice(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Stream Mix")
    static let chat = VirtualDevice(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Chat", channels: 2)
    static let speakers = DeviceInfo(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2)
    static let mic = DeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0)
    static let interface = DeviceInfo(uid: "USBInterface", name: "Scarlett 2i2", inputChannels: 2, outputChannels: 2, sampleRate: 44100)
    static let discord = AppRef(bundleID: "com.hnc.Discord", name: "Discord")

    static var inventory: Inventory {
        Inventory(
            devices: [speakers, mic, interface,
                      DeviceInfo(uid: streamMix.uid, name: streamMix.name, inputChannels: 2, outputChannels: 2, isJunction: true),
                      DeviceInfo(uid: chat.uid, name: chat.name, inputChannels: 2, outputChannels: 2, isJunction: true)],
            apps: [AudioApp(bundleID: discord.bundleID, name: "Discord", isPlaying: true)],
            defaultOutputUID: speakers.uid, defaultInputUID: mic.uid, driver: .installed(version: "0.1.0"))
    }
}

final class PlannerTests: XCTestCase {
    func testChatCandidatesOnlyOfferInstalledOrPlayingApps() {
        let zoom = AppRef(bundleID: "us.zoom.xos", name: "zoom.us")
        let faceTime = AppRef(bundleID: "com.apple.FaceTime", name: "FaceTime")
        let music = AppRef(bundleID: "com.apple.Music", name: "Music")
        let picked = AppRef(bundleID: "org.example.Chat", name: "Another Chat")
        let candidates = Templates.chatCandidates(usingAudio: [music, Demo.discord],
                                                  installedChatApps: [zoom, Demo.discord, faceTime], picked: [picked, music])
        // Using audio first, then installed chat apps and picked apps; no duplicates, nothing else from the known list.
        XCTAssertEqual(candidates.map(\.name), ["Discord", "Music", "Another Chat", "FaceTime", "zoom.us"])
        XCTAssertEqual(Templates.defaultExclusions(from: candidates), ["com.hnc.Discord"])
        XCTAssertTrue(Templates.chatCandidates(usingAudio: [], installedChatApps: []).isEmpty)
        let canary = AppRef(bundleID: "com.hnc.DiscordCanary", name: "Discord Canary")
        XCTAssertEqual(Templates.defaultExclusions(from: [canary, zoom]), ["com.hnc.DiscordCanary"])
    }

    func testStreamWithoutChatTemplate() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [Demo.discord])
        XCTAssertEqual(graph.virtualDevices.count, 1)
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.cables.count, 2)
        // Pretend the driver published it.
        var inventory = Demo.inventory
        inventory.devices.append(DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2, isJunction: true))
        let plan = Planner.plan(graph, inventory: inventory)
        XCTAssertEqual(plan.sinks.count, 1)
        let sink = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(sink.sinkUID, device.uid)
        XCTAssertEqual(sink.taps.count, 1)
        XCTAssertEqual(sink.taps[0].mode, .allExcept(["com.hnc.Discord"]))
        // The virtual device's own (loopback) inputs come first, then the tap: L and R land on 2 and 3.
        XCTAssertEqual(sink.inputChannels, 4)
        XCTAssertEqual(sink.routes.map(\.input), [2, 3])
        XCTAssertEqual(sink.routes.map(\.output), [0, 1])
        XCTAssertTrue(plan.idleCables.isEmpty)
    }

    func testLayoutWithSeveralDevicesAndTaps() throws {
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let sink = Node(kind: .virtualDevice(Demo.streamMix.id))
        let mic = Node(kind: .defaultInput)
        let interface = Node(kind: .device(Demo.interface.ref))
        let discord = Node(kind: .application(Demo.discord))
        graph.nodes = [sink, mic, interface, discord]
        graph.cables = [
            Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: sink.id, channel: 0)),
            Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: sink.id, channel: 1)),
            Cable(from: PortRef(node: interface.id, channel: 1), to: PortRef(node: sink.id, channel: 1)),
            Cable(from: PortRef(node: discord.id, channel: 0), to: PortRef(node: sink.id, channel: 0), gainDB: -6),
        ]
        let plan = Planner.plan(graph, inventory: Demo.inventory)
        let s = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(s.subDevices.map(\.uid), [Demo.streamMix.uid, Demo.mic.uid, Demo.interface.uid])
        // Stream Mix in (2) + mic (1) + interface (2) = 5, then the Discord tap at 5–6.
        XCTAssertEqual(s.inputChannels, 7)
        XCTAssertEqual(s.outputChannels, 4)  // Stream Mix 2 + interface 2 (silent)
        XCTAssertEqual(s.routes.map(\.input), [2, 2, 4, 5])
        XCTAssertEqual(s.routes[3].gain, Float(pow(10, -6.0 / 20)), accuracy: 1e-6)
        // The interface runs at 44.1 kHz, the virtual device at 48 kHz.
        XCTAssertTrue(plan.issues[interface.id]?.first?.contains("44.1 kHz") ?? false)
    }

    func testGainsDoNotChangeStructure() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        var inventory = Demo.inventory
        inventory.devices.append(DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2, isJunction: true))
        let before = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        graph.cables[0].gainDB = -12
        graph.nodes[0].isMuted = true
        let after = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        XCTAssertEqual(before.structureKey, after.structureKey)
        XCTAssertEqual(after.routes.map(\.gain), [0, 0])
        graph.nodes[0].mutesOriginal = true
        let muted = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        XCTAssertNotEqual(before.structureKey, muted.structureKey, "taking audio away from the speakers needs a new tap")
    }

    func testUnavailableAndDisabledDevices() {
        var graph = Graph(virtualDevices: [Demo.streamMix])
        graph.virtualDevices[0].isEnabled = false
        let sink = Node(kind: .virtualDevice(Demo.streamMix.id))
        let gone = Node(kind: .device(DeviceRef(uid: "Gone", name: "Old Headset", inputChannels: 1, outputChannels: 2)))
        let out = Node(kind: .defaultOutput)
        graph.nodes = [sink, gone, out]
        graph.cables = [
            Cable(from: PortRef(node: gone.id, channel: 0), to: PortRef(node: sink.id, channel: 0)),
            Cable(from: PortRef(node: gone.id, channel: 0), to: PortRef(node: out.id, channel: 0)),
        ]
        let plan = Planner.plan(graph, inventory: Demo.inventory)
        XCTAssertTrue(plan.sinks.isEmpty)
        XCTAssertEqual(plan.idleCables.count, 2)
        XCTAssertEqual(plan.issues[sink.id], ["Stream Mix is turned off."])
        XCTAssertEqual(plan.issues[gone.id], ["Old Headset isn't connected."])
    }

    func testRoutingOffPlansNothing() {
        var graph = Graph()
        Templates.streamWithoutChat(&graph, excluding: [])
        graph.isRoutingOn = false
        let plan = Planner.plan(graph, inventory: Demo.inventory)
        XCTAssertTrue(plan.sinks.isEmpty)
        XCTAssertEqual(plan.idleCables.count, 2)
    }

    func testFeedbackThroughVirtualDevicesIsRefused() {
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat])
        let a = Node(kind: .virtualDevice(Demo.streamMix.id))
        let b = Node(kind: .virtualDevice(Demo.chat.id))
        let speakers = Node(kind: .defaultOutput)
        graph.nodes = [a, b, speakers]
        let inventory = Demo.inventory
        // Into itself.
        XCTAssertEqual(Rules.check(from: PortRef(node: a.id, channel: 0), to: PortRef(node: a.id, channel: 0), graph: graph, inventory: inventory), .feedback)
        // A → B is fine, then B → A closes a loop.
        XCTAssertNil(Rules.check(from: PortRef(node: a.id, channel: 0), to: PortRef(node: b.id, channel: 0), graph: graph, inventory: inventory))
        graph.cables.append(Cable(from: PortRef(node: a.id, channel: 0), to: PortRef(node: b.id, channel: 0)))
        XCTAssertEqual(Rules.check(from: PortRef(node: b.id, channel: 1), to: PortRef(node: a.id, channel: 1), graph: graph, inventory: inventory), .feedback)
        // Through hardware is not a loop: speakers don't feed back digitally.
        XCTAssertNil(Rules.check(from: PortRef(node: b.id, channel: 0), to: PortRef(node: speakers.id, channel: 0), graph: graph, inventory: inventory))
        // Duplicates and bad channels.
        XCTAssertEqual(Rules.check(from: PortRef(node: a.id, channel: 0), to: PortRef(node: b.id, channel: 0), graph: graph, inventory: inventory), .alreadyConnected)
        XCTAssertEqual(Rules.check(from: PortRef(node: a.id, channel: 5), to: PortRef(node: b.id, channel: 0), graph: graph, inventory: inventory), .noSuchPort)
        XCTAssertEqual(Rules.check(from: PortRef(node: speakers.id, channel: 0), to: PortRef(node: a.id, channel: 0), graph: graph, inventory: inventory), .noSuchPort)
    }

    func testPlannerDropsLoopsTheEditorCouldNotSee() throws {
        // Default Output is set to Stream Mix in Sound settings, and Stream Mix is routed to Default Output.
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let mix = Node(kind: .virtualDevice(Demo.streamMix.id))
        let out = Node(kind: .defaultOutput)
        graph.nodes = [mix, out]
        graph.cables = [Cable(from: PortRef(node: mix.id, channel: 0), to: PortRef(node: out.id, channel: 0))]
        var inventory = Demo.inventory
        inventory.defaultOutputUID = Demo.streamMix.uid
        let plan = Planner.plan(graph, inventory: inventory)
        XCTAssertTrue(plan.sinks.isEmpty)
        XCTAssertEqual(plan.idleCables, [graph.cables[0].id])
        XCTAssertTrue(plan.issues[out.id]?.first?.contains("feed its own audio back") ?? false)
    }

    func testBusCables() {
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let mic = Node(kind: .defaultInput)
        let interface = Node(kind: .device(Demo.interface.ref))
        let mix = Node(kind: .virtualDevice(Demo.streamMix.id))
        graph.nodes = [mic, interface, mix]
        let mono = Rules.busCables(from: mic.id, to: mix.id, graph: graph, inventory: Demo.inventory)
        XCTAssertEqual(mono.map(\.from.channel), [0, 0], "a mono source goes to both sides")
        XCTAssertEqual(mono.map(\.to.channel), [0, 1])
        let stereo = Rules.busCables(from: interface.id, to: mix.id, graph: graph, inventory: Demo.inventory)
        XCTAssertEqual(stereo.map(\.from.channel), [0, 1])
        graph.cables = stereo
        XCTAssertTrue(Rules.busCables(from: interface.id, to: mix.id, graph: graph, inventory: Demo.inventory).isEmpty)
    }

    func testPortsFollowTheSystem() {
        let graph = Graph(virtualDevices: [Demo.streamMix])
        let info = NodeInfo(graph: graph, inventory: Demo.inventory)
        XCTAssertEqual(info.ports(Node(kind: .defaultInput)), PortCounts(inputs: 0, outputs: 1))
        XCTAssertEqual(info.ports(Node(kind: .defaultOutput)), PortCounts(inputs: 2, outputs: 0))
        XCTAssertEqual(info.ports(Node(kind: .virtualDevice(Demo.streamMix.id))), PortCounts(inputs: 2, outputs: 2))
        XCTAssertEqual(info.ports(Node(kind: .systemAudio(excluding: []))), PortCounts(inputs: 0, outputs: 2))
        // An unplugged device keeps its remembered shape.
        let gone = Node(kind: .device(DeviceRef(uid: "Gone", name: "Headset", inputChannels: 1, outputChannels: 2)))
        XCTAssertEqual(info.ports(gone), PortCounts(inputs: 2, outputs: 1))
        XCTAssertEqual(info.subtitle(gone), "Not connected")
    }

    func testDriverConfigurationListsEnabledDevices() {
        var off = Demo.chat
        off.isEnabled = false
        let config = DriverClient.configuration(for: [Demo.streamMix, off])
        XCTAssertEqual(config.count, 1)
        XCTAssertEqual(config[0]["uid"] as? String, Demo.streamMix.uid)
        XCTAssertEqual(config[0]["channels"] as? Int, 2)
        XCTAssertEqual(config[0]["sampleRate"] as? Double, 48000)
    }

    func testStoreRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        XCTAssertNil(store.load())
        var graph = Graph()
        Templates.streamWithoutChat(&graph, excluding: [Demo.discord])
        graph.nodes.append(Node(kind: .device(Demo.interface.ref), x: 12.5, y: -4, gainDB: -3, isMuted: true))
        try store.save(graph)
        XCTAssertEqual(store.load(), graph)
        try Data("not json".utf8).write(to: store.graphURL)
        XCTAssertNil(store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("graph.json.unreadable").path))
    }

    func testGainText() {
        XCTAssertEqual(Gain.text(0), "0 dB")
        XCTAssertEqual(Gain.text(-6.02), "−6.0 dB")
        XCTAssertEqual(Gain.text(3), "+3.0 dB")
        XCTAssertEqual(Gain.text(-60), "−∞ dB")
        XCTAssertEqual(Gain.linear(-60), 0)
        XCTAssertEqual(Gain.linear(0), 1)
    }
}
