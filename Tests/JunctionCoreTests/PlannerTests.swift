import CoreAudio
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
        XCTAssertEqual(graph.nodes(on: device.id).count, 2, "both nodes on the device's canvas")
        var tidy = graph
        tidy.tidyCanvases()
        XCTAssertEqual(tidy, graph, "the template makes a consistent canvas")
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
        // Conversion off: the 44.1 kHz interface joins the aggregate as it is (see testConvertsDevicesAtOtherRates).
        let sink = Node(kind: .virtualDevice(Demo.streamMix.id), rateConversion: .off)
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
        XCTAssertTrue(plan.issues[interface.id]?.first?.contains("Set both to the same rate") ?? false)
        XCTAssertTrue(s.converted.isEmpty)
        XCTAssertTrue(plan.conversions.isEmpty)
    }

    func testConvertsDevicesAtOtherRates() throws {
        // The same graph with conversion on (the default): the 44.1 kHz interface leaves the aggregate.
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let sink = Node(kind: .virtualDevice(Demo.streamMix.id))
        let mic = Node(kind: .defaultInput)
        let interface = Node(kind: .device(Demo.interface.ref))
        let discord = Node(kind: .application(Demo.discord))
        graph.nodes = [sink, mic, interface, discord]
        graph.cables = [
            Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: sink.id, channel: 0)),
            Cable(from: PortRef(node: interface.id, channel: 1), to: PortRef(node: sink.id, channel: 1)),
            Cable(from: PortRef(node: interface.id, channel: 0), to: PortRef(node: sink.id, channel: 0)),
            Cable(from: PortRef(node: discord.id, channel: 0), to: PortRef(node: sink.id, channel: 0)),
        ]
        XCTAssertEqual(sink.rateConversion, .automatic, "conversion is on by default")
        let plan = Planner.plan(graph, inventory: Demo.inventory)
        let s = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(s.subDevices.map(\.uid), [Demo.streamMix.uid, Demo.mic.uid], "the 48 kHz devices share the aggregate")
        XCTAssertEqual(s.converted.map(\.uid), [Demo.interface.uid])
        XCTAssertEqual(s.converted.first?.sampleRate, 44100)
        XCTAssertEqual(s.sampleRate, 48000)
        // Stream Mix (2) + mic (1) = 3, the Discord tap at 3–4, then the converted interface at 5–6.
        XCTAssertEqual(s.inputChannels, 5)
        XCTAssertEqual(s.outputChannels, 2)
        XCTAssertEqual(s.routes.map(\.input), [2, 6, 5, 3])
        XCTAssertNil(plan.issues[interface.id], "no warning: the rates are converted")
        XCTAssertEqual(plan.conversions[interface.id]?.text, "44.1 kHz, converted to 48 kHz")
        XCTAssertEqual(plan.conversions[interface.id]?.shortText, "44.1 → 48 kHz")
        XCTAssertNil(plan.conversions[mic.id])
        let info = NodeInfo(graph: graph, inventory: Demo.inventory)
        XCTAssertEqual(info.rateText(interface, plan: plan), "44.1 kHz, converted to 48 kHz")
        XCTAssertEqual(info.rateText(mic, plan: plan), "48 kHz")
        XCTAssertNil(info.rateText(discord, plan: plan))

        // Turning conversion off, or the interface switching to 48 kHz, changes which devices are converted: the
        // sink is rebuilt.
        var off = graph
        off.nodes[0].rateConversion = .off
        let offPlan = try XCTUnwrap(Planner.plan(off, inventory: Demo.inventory).sinks.first)
        XCTAssertTrue(offPlan.converted.isEmpty)
        XCTAssertNotEqual(offPlan.structureKey, s.structureKey)
        var matching = Demo.inventory
        let index = try XCTUnwrap(matching.devices.firstIndex { $0.uid == Demo.interface.uid })
        matching.devices[index].sampleRate = 48000
        let matchingPlan = Planner.plan(graph, inventory: matching)
        let m = try XCTUnwrap(matchingPlan.sinks.first)
        XCTAssertTrue(m.converted.isEmpty)
        XCTAssertEqual(m.subDevices.map(\.uid), [Demo.streamMix.uid, Demo.mic.uid, Demo.interface.uid])
        XCTAssertNotEqual(m.structureKey, s.structureKey)
        XCTAssertTrue(matchingPlan.conversions.isEmpty)
        // Gains alone still don't rebuild a converting sink.
        var louder = graph
        louder.cables[1].gainDB = -6
        XCTAssertEqual(try XCTUnwrap(Planner.plan(louder, inventory: Demo.inventory).sinks.first).structureKey, s.structureKey)
    }

    func testOutputsAtAnotherRateReceiveConvertedAudio() throws {
        // Stream Mix (48 kHz) plays on the interface, which runs at 44.1 kHz.
        let canvas = Demo.streamMix.id
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let mix = Node(kind: .virtualDevice(canvas), canvas: canvas)
        let interface = Node(kind: .device(Demo.interface.ref), canvas: canvas)
        let speakers = Node(kind: .defaultOutput, canvas: canvas)
        graph.nodes = [mix, interface, speakers]
        graph.cables = Rules.busCables(from: mix.id, to: interface.id, graph: graph, inventory: Demo.inventory)
            + Rules.busCables(from: mix.id, to: speakers.id, graph: graph, inventory: Demo.inventory)
        let plan = Planner.plan(graph, inventory: Demo.inventory)
        XCTAssertEqual(plan.sinks.count, 2)
        let toInterface = try XCTUnwrap(plan.sinks.first { $0.sinkNode == interface.id })
        XCTAssertEqual(toInterface.subDevices.map(\.uid), [Demo.interface.uid], "the interface is the clock")
        XCTAssertEqual(toInterface.converted.map(\.uid), [Demo.streamMix.uid], "Stream Mix runs on its own IOProc")
        XCTAssertEqual(toInterface.sampleRate, 44100)
        // The interface's own inputs (2) are the aggregate's; Stream Mix's channels follow them.
        XCTAssertEqual(toInterface.routes.map(\.input), [2, 3])
        XCTAssertEqual(plan.conversions[interface.id]?.text, "44.1 kHz, converted from 48 kHz")
        XCTAssertNil(plan.conversions[mix.id], "Stream Mix feeds other outputs at its own rate")
        let toSpeakers = try XCTUnwrap(plan.sinks.first { $0.sinkNode == speakers.id })
        XCTAssertTrue(toSpeakers.converted.isEmpty, "the speakers run at 48 kHz like Stream Mix")
        XCTAssertEqual(toSpeakers.subDevices.map(\.uid), [Demo.speakers.uid, Demo.streamMix.uid])
        XCTAssertNil(plan.conversions[speakers.id])

        // With conversion off on the interface, Stream Mix joins its aggregate and the old note comes back.
        let index = try XCTUnwrap(graph.nodes.firstIndex { $0.id == interface.id })
        graph.nodes[index].rateConversion = .off
        let off = Planner.plan(graph, inventory: Demo.inventory)
        let offSink = try XCTUnwrap(off.sinks.first { $0.sinkNode == interface.id })
        XCTAssertEqual(offSink.subDevices.map(\.uid), [Demo.interface.uid, Demo.streamMix.uid])
        XCTAssertNil(off.conversions[interface.id])
        XCTAssertTrue(off.issues[mix.id]?.first?.contains("conversion is off") ?? false)
    }

    func testSchema3FilesTurnOnConversion() throws {
        // A schema 3 file has no rateConversion: it loads as Automatic and is saved as schema 4.
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let sinkIndex = try XCTUnwrap(graph.nodes.firstIndex { $0.kind == .virtualDevice(device.id) })
        graph.nodes[sinkIndex].bufferFrames = 256
        graph.schema = 3
        let data = try JSONEncoder().encode(graph)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["nodes"] = (object["nodes"] as? [[String: Any]])?.map { node in
            var node = node
            node["rateConversion"] = nil
            node["effects"] = nil
            return node
        }
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("rateConversion"))
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("effects"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-schema4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try old.write(to: store.graphURL)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schema, 4)
        XCTAssertTrue(loaded.nodes.allSatisfy { $0.rateConversion == .automatic })
        XCTAssertEqual(loaded.nodes[sinkIndex].bufferFrames, 256, "schema 3 settings are kept")
        XCTAssertEqual(loaded.cables, graph.cables)
        // Devices from before the device options show apps both sides, under the Junction icon, at full volume.
        let loadedDevice = try XCTUnwrap(loaded.virtualDevice(device.id))
        XCTAssertEqual(loadedDevice.direction, .both)
        XCTAssertEqual(loadedDevice.icon, .junction)
        XCTAssertEqual(loadedDevice.channelNames, [])
        XCTAssertFalse(loadedDevice.isHidden)
        XCTAssertEqual(loadedDevice.outputVolume, 1)
        XCTAssertEqual(loadedDevice.inputVolume, 1)
        XCTAssertFalse(loadedDevice.outputMuted || loadedDevice.inputMuted)
        XCTAssertEqual(loadedDevice.name, device.name)
        XCTAssertEqual(loaded.scenes, [], "schema 3 files have no scenes")
        XCTAssertTrue(loaded.nodes.allSatisfy(\.effects.isEmpty), "schema 3 files have no effects")
        XCTAssertEqual(loaded.midi, [], "schema 3 files have no MIDI mappings")
        // A schema 3 file half written by a development build that had effects or MIDI mappings loses them, like its
        // scenes.
        var halfWritten = graph
        halfWritten.nodes[sinkIndex].effects = [Effect(.limiter)]
        halfWritten.midi = [MIDIMapping(target: .nodeMute(graph.nodes[sinkIndex].id), trigger: .note(channel: 0, number: 36))]
        halfWritten.upgrade()
        XCTAssertEqual(halfWritten.nodes[sinkIndex].effects, [])
        XCTAssertEqual(halfWritten.midi, [])

        // Schema 4 keeps the choice.
        var changed = loaded
        changed.nodes[sinkIndex].rateConversion = .off
        try store.save(changed)
        XCTAssertTrue(try String(contentsOf: store.graphURL, encoding: .utf8).contains("\"rateConversion\" : \"off\""))
        XCTAssertEqual(store.load()?.nodes[sinkIndex].rateConversion, .off)
        var again = changed
        again.upgrade()
        XCTAssertEqual(again, changed, "a schema 4 graph isn't converted again")

        // …and the device options.
        var dressed = changed
        dressed.virtualDevices[0].direction = .outputOnly
        dressed.virtualDevices[0].channelNames = ["Voice", "Music"]
        dressed.virtualDevices[0].icon = .stream
        dressed.virtualDevices[0].isHidden = true
        dressed.virtualDevices[0].outputVolume = 0.25
        dressed.virtualDevices[0].inputMuted = true
        // …and effects: component codes, bypass, parameters and an Audio Unit's state.
        var limiter = Effect(.limiter)
        limiter.bypass = true
        limiter.parameters["2"] = -6
        limiter.state = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])
        var gate = Effect(.gate)
        gate.set(EffectKind.gate.parameters[0], -50)
        dressed.nodes[sinkIndex].effects = [gate, limiter]
        // …and scenes.
        dressed.scenes = [RoutingScene(name: "Dressed", capturing: dressed)]
        try store.save(dressed)
        XCTAssertEqual(store.load(), dressed)
        let saved = try String(contentsOf: store.graphURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"name\" : \"Dressed\""))
        for text in ["\"type\" : \"aufx\"", "\"subtype\" : \"lmtr\"", "\"manufacturer\" : \"appl\"", "\"bypass\" : true",
                     "\"state\" : \"YnBsaXN0\""] {
            XCTAssertTrue(saved.contains(text), "saved with \(text)")
        }
        XCTAssertEqual(store.load()?.nodes[sinkIndex].effects.map(\.kind), [.gate, .limiter])
        XCTAssertEqual(store.load()?.scenes.first?.nodes[sinkIndex].effects, [gate, limiter], "scenes keep effects")
    }

    func testDeviceOptionsInTheDriverConfiguration() throws {
        var device = Demo.streamMix
        device.direction = .inputOnly
        device.channelNames = ["Voice", "", "extra"]
        device.icon = .microphone
        device.isHidden = true
        device.outputVolume = 1.5
        device.inputVolume = 0.5
        device.inputMuted = true
        let entry = try XCTUnwrap(DriverClient.configuration(for: [device]).first)
        XCTAssertEqual(entry["direction"] as? String, "input")
        XCTAssertEqual(entry["channelNames"] as? [String], ["Voice"], "names past the channels and empty ones at the end go")
        XCTAssertEqual(entry["icon"] as? String, "microphone")
        XCTAssertEqual(entry["hidden"] as? Bool, true)
        XCTAssertEqual(entry["outputVolume"] as? Double, 1, "volumes stay within 0…1")
        XCTAssertEqual(entry["inputVolume"] as? Double, 0.5)
        XCTAssertEqual(entry["inputMute"] as? Bool, true)
        XCTAssertEqual(entry["outputMute"] as? Bool, false)
        // What the driver reports back reads as the same device.
        let read = try XCTUnwrap(DriverClient.devices(from: [entry]).first)
        XCTAssertEqual(read.direction, .inputOnly)
        XCTAssertEqual(read.channelNames, ["Voice"])
        XCTAssertEqual(read.icon, .microphone)
        XCTAssertTrue(read.isHidden)
        XCTAssertEqual(read.inputVolume, 0.5)
        XCTAssertTrue(read.inputMuted)
        // Driver 0.1 reports only the format: the rest takes the defaults.
        let old = try XCTUnwrap(DriverClient.devices(from: [["uid": Demo.chat.uid, "name": "Chat", "channels": 4,
                                                             "sampleRate": 44100.0]]).first)
        XCTAssertEqual(old.channels, 4)
        XCTAssertEqual(old.sampleRate, 44100)
        XCTAssertEqual(old.direction, .both)
        XCTAssertEqual(old.icon, .junction)
        XCTAssertFalse(old.isHidden)
        XCTAssertEqual(old.outputVolume, 1)
        XCTAssertFalse(old.outputMuted)
        // Channel names label the device node's ports.
        var graph = Graph(virtualDevices: [device])
        let node = Node(kind: .virtualDevice(device.id), canvas: device.id)
        graph.nodes = [node]
        let info = NodeInfo(graph: graph, inventory: Demo.inventory)
        XCTAssertEqual(info.channelLabels(node, outputs: true), ["Voice", "R"])
        XCTAssertEqual(info.subtitle(node), "Virtual input · hidden")
    }

    func testOneSidedDevicesRouteThroughTheirCompanions() throws {
        // Chat is a microphone only: Junction plays into its companion. Stream Mix is a speaker only: Junction
        // records it from its companion.
        var chat = Demo.chat, mix = Demo.streamMix
        chat.direction = .inputOnly
        mix.direction = .outputOnly
        var inventory = Demo.inventory
        inventory.devices.removeAll { $0.isJunction }
        inventory.devices += [
            DeviceInfo(uid: chat.uid, name: chat.name, inputChannels: 2, outputChannels: 0, isJunction: true),
            DeviceInfo(uid: chat.companionUID, name: "Chat (Junction routing)", inputChannels: 0, outputChannels: 2, isJunction: true),
            DeviceInfo(uid: mix.uid, name: mix.name, inputChannels: 0, outputChannels: 2, isJunction: true),
            DeviceInfo(uid: mix.companionUID, name: "Stream Mix (Junction routing)", inputChannels: 2, outputChannels: 0,
                       isJunction: true),
        ]
        var graph = Graph(virtualDevices: [mix, chat])
        let mixNode = Node(kind: .virtualDevice(mix.id), canvas: mix.id)
        let chatNode = Node(kind: .virtualDevice(chat.id), canvas: chat.id)
        let mixSource = Node(kind: .device(DeviceRef(uid: mix.uid, name: mix.name, inputChannels: 0, outputChannels: 2)),
                             canvas: chat.id)
        graph.nodes = [mixNode, chatNode, mixSource]
        // The virtual device node keeps both sides on the canvas.
        XCTAssertEqual(NodeInfo(graph: graph, inventory: inventory).ports(chatNode), PortCounts(inputs: 2, outputs: 2))
        let speakers = Node(kind: .device(Demo.speakers.ref), canvas: mix.id)
        let micOnChat = Node(kind: .defaultInput, canvas: chat.id)
        graph.nodes += [speakers, micOnChat]
        graph.cables = [
            Cable(from: PortRef(node: micOnChat.id, channel: 0), to: PortRef(node: chatNode.id, channel: 0)),
            Cable(from: PortRef(node: mixNode.id, channel: 0), to: PortRef(node: speakers.id, channel: 0)),
        ]
        let plan = Planner.plan(graph, inventory: inventory)
        let intoChat = try XCTUnwrap(plan.sinks.first { $0.sinkNode == chatNode.id })
        XCTAssertEqual(intoChat.sinkUID, chat.companionUID, "an input-only device is fed through its companion")
        let fromMix = try XCTUnwrap(plan.sinks.first { $0.sinkNode == speakers.id })
        XCTAssertEqual(fromMix.subDevices.map(\.uid), [Demo.speakers.uid, mix.companionUID],
                       "an output-only device is recorded through its companion")

        // A companion missing (an older driver) leaves the node unavailable rather than routing the wrong side.
        var older = inventory
        older.devices.removeAll { $0.uid == chat.companionUID }
        let olderPlan = Planner.plan(graph, inventory: older)
        XCTAssertNil(olderPlan.sinks.first { $0.sinkNode == chatNode.id })
        XCTAssertFalse(olderPlan.issues[chatNode.id, default: []].isEmpty)
    }

    func testTheLoopGuardCountsACompanionAsItsDevice() throws {
        // Stream Mix → Chat (Chat fed through its companion) and Chat → Stream Mix would ring: one of them is refused.
        var chat = Demo.chat
        chat.direction = .inputOnly
        var inventory = Demo.inventory
        inventory.devices.removeAll { $0.uid == chat.uid }
        inventory.devices += [
            DeviceInfo(uid: chat.uid, name: chat.name, inputChannels: 2, outputChannels: 0, isJunction: true),
            DeviceInfo(uid: chat.companionUID, name: "Chat (Junction routing)", inputChannels: 0, outputChannels: 2, isJunction: true),
        ]
        var graph = Graph(virtualDevices: [Demo.streamMix, chat])
        let mixNode = Node(kind: .virtualDevice(Demo.streamMix.id), canvas: Demo.streamMix.id)
        let chatNode = Node(kind: .virtualDevice(chat.id), canvas: chat.id)
        let chatOnMix = Node(kind: .device(DeviceRef(uid: chat.uid, name: "Chat", inputChannels: 2, outputChannels: 0)),
                             canvas: Demo.streamMix.id)
        let mixOnChat = Node(kind: .device(DeviceRef(uid: Demo.streamMix.uid, name: "Stream Mix", inputChannels: 2,
                                                     outputChannels: 2)), canvas: chat.id)
        graph.nodes = [mixNode, chatNode, chatOnMix, mixOnChat]
        graph.cables = [
            Cable(from: PortRef(node: chatOnMix.id, channel: 0), to: PortRef(node: mixNode.id, channel: 0)),
            Cable(from: PortRef(node: mixOnChat.id, channel: 0), to: PortRef(node: chatNode.id, channel: 0)),
        ]
        let plan = Planner.plan(graph, inventory: inventory)
        XCTAssertEqual(plan.sinks.count, 1, "only one direction of the loop is routed")
        XCTAssertEqual(plan.idleCables.count, 1)
    }

    func testDevicesOnTheSinksClockSkipDriftCompensation() throws {
        // Junction's devices share one clock domain; the interface has its own and the mic reports none.
        var inventory = Demo.inventory
        for index in inventory.devices.indices where inventory.devices[index].isJunction {
            inventory.devices[index].clockDomain = 0x6A6E_6374
        }
        if let index = inventory.devices.firstIndex(where: { $0.uid == Demo.interface.uid }) {
            inventory.devices[index].clockDomain = 7
            inventory.devices[index].sampleRate = 48000
        }
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat])
        let sink = Node(kind: .virtualDevice(Demo.streamMix.id), canvas: Demo.streamMix.id)
        let chat = Node(kind: .device(DeviceRef(uid: Demo.chat.uid, name: "Chat", inputChannels: 2, outputChannels: 2)),
                        canvas: Demo.streamMix.id)
        let interface = Node(kind: .device(Demo.interface.ref), canvas: Demo.streamMix.id)
        let mic = Node(kind: .defaultInput, canvas: Demo.streamMix.id)
        graph.nodes = [sink, chat, interface, mic]
        graph.cables = [chat, interface, mic].map { Cable(from: PortRef(node: $0.id, channel: 0), to: PortRef(node: sink.id, channel: 0)) }
        let plan = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        XCTAssertEqual(plan.subDevices.map(\.uid), [Demo.streamMix.uid, Demo.chat.uid, Demo.interface.uid, Demo.mic.uid])
        XCTAssertEqual(plan.subDevices.map(\.sameClock), [true, true, false, false])
        let list = SinkRunner.subDeviceList(plan)
        XCTAssertNil(list[0][kAudioSubDeviceDriftCompensationKey], "the sink is the clock")
        XCTAssertEqual(list[1][kAudioSubDeviceDriftCompensationKey] as? Int, 0, "no drift compensation on the same clock")
        XCTAssertEqual(list[2][kAudioSubDeviceDriftCompensationKey] as? Int, 1)
        XCTAssertEqual(list[3][kAudioSubDeviceDriftCompensationKey] as? Int, 1, "an unknown domain is compensated")

        // A Junction device at another rate is converted as being on the same clock.
        var otherRate = inventory
        if let index = otherRate.devices.firstIndex(where: { $0.uid == Demo.chat.uid }) { otherRate.devices[index].sampleRate = 44100 }
        let converting = try XCTUnwrap(Planner.plan(graph, inventory: otherRate).sinks.first)
        XCTAssertEqual(converting.converted.map(\.uid), [Demo.chat.uid])
        XCTAssertEqual(converting.converted.first?.sameClock, true)
        XCTAssertNotEqual(converting.structureKey, plan.structureKey)
        // Losing the shared domain rebuilds the sink with compensation.
        var separate = inventory
        if let index = separate.devices.firstIndex(where: { $0.uid == Demo.chat.uid }) { separate.devices[index].clockDomain = 0 }
        let compensated = try XCTUnwrap(Planner.plan(graph, inventory: separate).sinks.first)
        XCTAssertEqual(compensated.subDevices[1].sameClock, false)
        XCTAssertNotEqual(compensated.structureKey, plan.structureKey)
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

    func testRateChangesRebuildOnlyTheSinksUsingTheDevice() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let other = Demo.chat
        graph.virtualDevices.append(other)
        let otherNode = Node(kind: .virtualDevice(other.id), x: 330, y: 60, canvas: other.id)
        let mic = Node(kind: .device(Demo.mic.ref), x: 40, y: 60, canvas: other.id)
        graph.nodes += [otherNode, mic]
        graph.cables.append(Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: otherNode.id, channel: 0)))
        var inventory = Demo.inventory
        inventory.devices.append(DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2,
                                            isJunction: true))
        let before = Planner.plan(graph, inventory: inventory).sinks
        XCTAssertEqual(before.count, 2)
        let index = try XCTUnwrap(inventory.devices.firstIndex { $0.uid == Demo.mic.uid })
        inventory.devices[index].sampleRate = 96_000
        let after = Planner.plan(graph, inventory: inventory).sinks
        func key(_ sinks: [SinkPlan], _ name: String) -> String? { sinks.first { $0.name == name }?.structureKey }
        XCTAssertNotEqual(key(before, other.name), key(after, other.name), "the mic's sink is rebuilt")
        XCTAssertEqual(key(before, device.name), key(after, device.name), "a sink without the mic keeps running")
    }

    func testBufferSizeIsSavedAndRebuildsTheSink() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        var inventory = Demo.inventory
        inventory.devices.append(DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2,
                                            isJunction: true))
        let sinkNode = try XCTUnwrap(graph.deviceNode(device.id))
        let before = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        XCTAssertNil(before.bufferFrames)
        let index = try XCTUnwrap(graph.nodes.firstIndex { $0.id == sinkNode.id })
        graph.nodes[index].bufferFrames = 128
        let after = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first)
        XCTAssertEqual(after.bufferFrames, 128)
        XCTAssertNotEqual(before.structureKey, after.structureKey)

        // Schema 2 files have no buffer sizes: they load as macOS's default and are saved as the current schema.
        graph.nodes[index].bufferFrames = nil
        graph.schema = 2
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(graph), encoding: .utf8))
        XCTAssertFalse(json.contains("bufferFrames"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-schema3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try Data(json.utf8).write(to: store.graphURL)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schema, Graph.currentSchema)
        XCTAssertTrue(loaded.nodes.allSatisfy { $0.bufferFrames == nil })
        XCTAssertEqual(loaded.cables, graph.cables)
    }

    func testRetriesWaitLongerEachTime() {
        XCTAssertEqual((1...8).map(Router.retryDelay(attempt:)), [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(Router.retryDelay(attempt: 0), 2)
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

    func testCablesRunIntoOrOutOfTheCanvasDevice() {
        let mix = Demo.streamMix.id, chat = Demo.chat.id
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat])
        let a = Node(kind: .virtualDevice(mix), canvas: mix)
        let b = Node(kind: .virtualDevice(chat), canvas: chat)
        let mic = Node(kind: .defaultInput, canvas: mix)
        let speakers = Node(kind: .defaultOutput, canvas: mix)
        let otherSpeakers = Node(kind: .defaultOutput, canvas: chat)
        graph.nodes = [a, b, mic, speakers, otherSpeakers]
        let inventory = Demo.inventory
        func check(_ from: Node, _ fc: Int, _ to: Node, _ tc: Int) -> Rules.Problem? {
            Rules.check(from: PortRef(node: from.id, channel: fc), to: PortRef(node: to.id, channel: tc), graph: graph, inventory: inventory)
        }
        XCTAssertNil(check(mic, 0, a, 0), "a source into its canvas's device")
        XCTAssertNil(check(a, 0, speakers, 0), "the device out to an output; speakers don't feed back digitally")
        XCTAssertEqual(check(a, 0, a, 0), .feedback, "a device into itself")
        XCTAssertEqual(check(mic, 0, speakers, 0), .bypassesDevice, "straight past the device")
        XCTAssertEqual(check(a, 0, b, 0), .bypassesDevice, "virtual devices don't feed each other")
        XCTAssertEqual(check(a, 0, otherSpeakers, 0), .bypassesDevice, "a node on another canvas")
        graph.cables.append(Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: a.id, channel: 0)))
        XCTAssertEqual(check(mic, 0, a, 0), .alreadyConnected)
        XCTAssertEqual(check(a, 5, speakers, 0), .noSuchPort)
        XCTAssertEqual(check(speakers, 0, a, 0), .noSuchPort)
    }

    func testMovingACableKeepsItsLevelAndFollowsTheRules() {
        let mix = Demo.streamMix.id
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let device = Node(kind: .virtualDevice(mix), canvas: mix)
        let mic = Node(kind: .defaultInput, canvas: mix)
        let speakers = Node(kind: .defaultOutput, canvas: mix)
        graph.nodes = [device, mic, speakers]
        let cable = Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: device.id, channel: 0), gainDB: -6)
        let other = Cable(from: PortRef(node: device.id, channel: 0), to: PortRef(node: speakers.id, channel: 0))
        graph.cables = [cable, other]
        XCTAssertNil(Rules.move(cable.id, to: PortRef(node: device.id, channel: 1), in: &graph, inventory: Demo.inventory))
        XCTAssertEqual(graph.cables[0].to, PortRef(node: device.id, channel: 1))
        XCTAssertEqual(graph.cables[0].gainDB, -6)
        XCTAssertEqual(graph.cables[0].id, cable.id)
        // Moving the mic's cable onto the speakers would bypass the device: refused, nothing changes.
        let before = graph
        XCTAssertEqual(Rules.move(cable.id, to: PortRef(node: speakers.id, channel: 1), in: &graph, inventory: Demo.inventory),
                       .bypassesDevice)
        XCTAssertEqual(graph, before)
        XCTAssertEqual(Rules.move(UUID(), to: PortRef(node: device.id, channel: 0), in: &graph, inventory: Demo.inventory), .noSuchPort)
    }

    func testLoopsThroughSoundSettingsAreRefused() {
        let mix = Demo.streamMix.id
        var graph = Graph(virtualDevices: [Demo.streamMix])
        let device = Node(kind: .virtualDevice(mix), canvas: mix)
        let out = Node(kind: .defaultOutput, canvas: mix)
        let input = Node(kind: .defaultInput, canvas: mix)
        graph.nodes = [device, out, input]
        var inventory = Demo.inventory
        // Sound settings play everything through Stream Mix: sending Stream Mix to Default Output feeds it back in.
        inventory.defaultOutputUID = Demo.streamMix.uid
        XCTAssertEqual(Rules.check(from: PortRef(node: device.id, channel: 0), to: PortRef(node: out.id, channel: 0),
                                   graph: graph, inventory: inventory), .feedback)
        XCTAssertTrue(Rules.busCables(from: device.id, to: out.id, graph: graph, inventory: inventory).isEmpty)
        // Stream Mix as the Mac's microphone: Default Input into Stream Mix is the same loop.
        inventory.defaultInputUID = Demo.streamMix.uid
        XCTAssertEqual(Rules.check(from: PortRef(node: input.id, channel: 0), to: PortRef(node: device.id, channel: 0),
                                   graph: graph, inventory: inventory), .feedback)
        // With real devices chosen in Sound settings both are fine.
        XCTAssertNil(Rules.check(from: PortRef(node: device.id, channel: 0), to: PortRef(node: out.id, channel: 0),
                                 graph: graph, inventory: Demo.inventory))
        XCTAssertNil(Rules.check(from: PortRef(node: input.id, channel: 0), to: PortRef(node: device.id, channel: 0),
                                 graph: graph, inventory: Demo.inventory))
    }

    func testSharedCanvasGraphsMoveToDeviceCanvases() throws {
        // Schema 1: one canvas. The mic feeds both devices, Stream Mix feeds Chat, Stream Mix plays on the speakers,
        // the mic also goes straight to the speakers, and an interface sits unwired.
        let a = Node(kind: .virtualDevice(Demo.streamMix.id))
        let b = Node(kind: .virtualDevice(Demo.chat.id))
        let mic = Node(kind: .defaultInput)
        let speakers = Node(kind: .defaultOutput)
        let interface = Node(kind: .device(Demo.interface.ref))
        func cable(_ x: Node, _ y: Node) -> Cable { Cable(from: PortRef(node: x.id, channel: 0), to: PortRef(node: y.id, channel: 0)) }
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat], nodes: [a, b, mic, speakers, interface],
                          cables: [cable(mic, a), cable(mic, b), cable(a, b), cable(a, speakers), cable(mic, speakers)])
        graph.schema = 1
        let data = try JSONEncoder().encode(graph)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try data.write(to: store.graphURL)
        let upgraded = try XCTUnwrap(store.load())

        XCTAssertEqual(upgraded.schema, Graph.currentSchema)
        let onMix = upgraded.nodes(on: Demo.streamMix.id), onChat = upgraded.nodes(on: Demo.chat.id)
        XCTAssertEqual(onMix.map(\.kind), [a.kind, mic.kind, speakers.kind, interface.kind], "unwired: the first canvas")
        XCTAssertEqual(onChat.map(\.kind), [b.kind, mic.kind], "the mic is copied onto the second canvas")
        XCTAssertEqual(onMix.first { $0.kind == .defaultInput }?.id, mic.id, "the first copy keeps its identity")
        XCTAssertEqual(upgraded.cables(on: Demo.streamMix.id).count, 2, "mic → Stream Mix, Stream Mix → speakers")
        XCTAssertEqual(upgraded.cables(on: Demo.chat.id).count, 1, "mic copy → Chat")
        XCTAssertEqual(upgraded.cables.count, 3, "device to device and past-the-device cables are gone")
        var again = upgraded
        again.upgrade()
        XCTAssertEqual(again, upgraded, "upgrading twice changes nothing")
    }

    func testTidyCanvasesKeepsOneDeviceNodePerCanvas() {
        let mix = Demo.streamMix.id
        var graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat])
        let stray = Node(kind: .virtualDevice(Demo.chat.id), canvas: mix)  // another device on Stream Mix's canvas
        let orphan = Node(kind: .defaultInput, canvas: UUID())               // a canvas that no longer exists
        graph.nodes = [stray, orphan]
        graph.tidyCanvases()
        XCTAssertNotNil(graph.deviceNode(mix))
        XCTAssertNotNil(graph.deviceNode(Demo.chat.id))
        XCTAssertEqual(graph.nodes.count, 2)
        graph.removeVirtualDevice(mix)
        XCTAssertEqual(graph.nodes.map(\.canvas), [Demo.chat.id])
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
        let canvas = Demo.streamMix.id
        let mic = Node(kind: .defaultInput, canvas: canvas)
        let interface = Node(kind: .device(Demo.interface.ref), canvas: canvas)
        let mix = Node(kind: .virtualDevice(Demo.streamMix.id), canvas: canvas)
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
        let device = Templates.streamWithoutChat(&graph, excluding: [Demo.discord])
        graph.nodes.append(Node(kind: .device(Demo.interface.ref), x: 12.5, y: -4, gainDB: -3, isMuted: true, canvas: device.id))
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
