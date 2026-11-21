import XCTest
@testable import JunctionCore

final class SceneTests: XCTestCase {
    /// Stream Mix (system audio without Discord) and Chat (the mic) published, as the driver would.
    private func setup() -> (Graph, Inventory, chatNode: Node, mic: Node) {
        var graph = Graph()
        Templates.streamWithoutChat(&graph, excluding: [Demo.discord])
        let mixID = graph.virtualDevices[0].id
        graph.virtualDevices.append(Demo.chat)
        let chatNode = Node(kind: .virtualDevice(Demo.chat.id), x: CanvasColumn.device, y: 60, canvas: Demo.chat.id)
        let mic = Node(kind: .device(Demo.mic.ref), x: CanvasColumn.sources, y: 60, canvas: Demo.chat.id)
        graph.nodes += [chatNode, mic]
        graph.cables.append(Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: chatNode.id, channel: 0)))
        var inventory = Demo.inventory
        inventory.devices.append(DeviceInfo(uid: VirtualDevice(id: mixID, name: "").uid, name: "Stream Mix",
                                            inputChannels: 2, outputChannels: 2, isJunction: true))
        return (graph, inventory, chatNode, mic)
    }

    private func keys(_ graph: Graph, _ inventory: Inventory) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: Planner.plan(graph, inventory: inventory).sinks.map { ($0.sinkNode, $0.structureKey) })
    }

    func testSwitchingGivesTheScenesGraphAndRebuildsOnlyChangedSinks() throws {
        var (graph, inventory, chatNode, mic) = setup()
        let mix = graph.virtualDevices[0]
        let mixNode = try XCTUnwrap(graph.deviceNode(mix.id))
        let talk = RoutingScene(name: "Talk", capturing: graph)
        XCTAssertTrue(Scenes.isCurrent(talk, in: graph))
        let talkGraph = graph
        let talkKeys = keys(graph, inventory)
        XCTAssertEqual(talkKeys.count, 2)

        // "Music": Chat also gets the interface, the mic is quieter, Stream Mix's own cables are louder and muted.
        let interface = Node(kind: .device(Demo.interface.ref), x: CanvasColumn.sources, y: 230, canvas: Demo.chat.id)
        graph.nodes.append(interface)
        graph.cables.append(Cable(from: PortRef(node: interface.id, channel: 0), to: PortRef(node: chatNode.id, channel: 1)))
        let micIndex = try XCTUnwrap(graph.nodes.firstIndex { $0.id == mic.id })
        graph.nodes[micIndex].gainDB = -6
        let mixCable = try XCTUnwrap(graph.cables.firstIndex { $0.to.node == mixNode.id })
        graph.cables[mixCable].gainDB = -12
        graph.virtualDevices[0].outputMuted = true
        graph.virtualDevices[0].inputVolume = 0.5
        let music = RoutingScene(name: "Music", capturing: graph)
        XCTAssertFalse(Scenes.isCurrent(talk, in: graph))
        XCTAssertTrue(Scenes.isCurrent(music, in: graph))
        let musicKeys = keys(graph, inventory)

        // Back to Talk: exactly Talk's devices, nodes and cables.
        var switched = graph
        Scenes.apply(talk, to: &switched, inventory: inventory)
        XCTAssertEqual(switched.virtualDevices, talkGraph.virtualDevices)
        XCTAssertEqual(Set(switched.nodes), Set(talkGraph.nodes))
        XCTAssertEqual(Set(switched.cables), Set(talkGraph.cables))
        XCTAssertTrue(Scenes.isCurrent(talk, in: switched))
        XCTAssertEqual(Planner.plan(switched, inventory: inventory), Planner.plan(talkGraph, inventory: inventory))
        // Only Chat's sink changes structure; Stream Mix only gets its level back (the router updates its gains).
        XCTAssertEqual(Scenes.changedCanvases(talk, in: graph), [mix.id, Demo.chat.id])
        let switchedKeys = keys(switched, inventory)
        XCTAssertEqual(switchedKeys[mixNode.id], musicKeys[mixNode.id], "Stream Mix keeps running")
        XCTAssertNotEqual(switchedKeys[chatNode.id], musicKeys[chatNode.id], "Chat is rebuilt")
        XCTAssertEqual(switchedKeys, talkKeys)
        // The mix canvas whose levels didn't change between the scenes isn't touched at all.
        var levelsOnly = graph
        levelsOnly.cables[mixCable].gainDB = 0
        var again = levelsOnly
        Scenes.apply(music, to: &again, inventory: inventory)
        XCTAssertEqual(again.nodes.filter { $0.canvas == mix.id }, graph.nodes.filter { $0.canvas == mix.id })
        XCTAssertEqual(again.cables(on: mix.id), graph.cables(on: mix.id))

        // A scene with a device off: its sink goes, the other is left alone.
        var quiet = switched
        quiet.virtualDevices[1].isEnabled = false
        let off = RoutingScene(name: "Quiet", capturing: quiet)
        var offGraph = switched
        Scenes.apply(off, to: &offGraph, inventory: inventory)
        XCTAssertFalse(try XCTUnwrap(offGraph.virtualDevice(Demo.chat.id)).isEnabled)
        let offKeys = keys(offGraph, inventory)
        XCTAssertNil(offKeys[chatNode.id])
        XCTAssertEqual(offKeys[mixNode.id], talkKeys[mixNode.id])
        XCTAssertEqual(Scenes.changedCanvases(off, in: switched), [], "turning a device off doesn't touch its canvas")
    }

    func testDevicesTheSceneDoesNotKnowAreLeftAlone() throws {
        var (graph, inventory, _, _) = setup()
        let before = RoutingScene(name: "Before", capturing: graph)
        // A device made after the scene, and a device deleted since.
        let later = VirtualDevice(name: "Later")
        graph.virtualDevices.append(later)
        graph.tidyCanvases()
        graph.scenes = [before]
        graph.removeVirtualDevice(Demo.chat.id)
        XCTAssertNil(graph.scenes[0].device(Demo.chat.id), "the deleted device leaves the scene too")
        XCTAssertFalse(graph.scenes[0].nodes.contains { $0.canvas == Demo.chat.id })
        let laterNode = try XCTUnwrap(graph.deviceNode(later.id))
        graph.virtualDevices[0].isEnabled = false
        Scenes.apply(graph.scenes[0], to: &graph, inventory: inventory)
        XCTAssertTrue(graph.virtualDevices[0].isEnabled)
        XCTAssertNil(graph.virtualDevice(Demo.chat.id), "a deleted device isn't brought back")
        XCTAssertEqual(graph.deviceNode(later.id), laterNode)
        inventory.devices.removeAll { $0.uid == Demo.chat.uid }
        XCTAssertEqual(Planner.plan(graph, inventory: inventory).sinks.count, 1)
    }

    func testTheDeviceNodeKeepsItsIdentity() throws {
        // A scene whose device node has another ID (the canvas was rebuilt since): the current one is kept.
        let (graph, inventory, chatNode, mic) = setup()
        var scene = RoutingScene(name: "Old", capturing: graph)
        let oldID = UUID()
        for index in scene.nodes.indices where scene.nodes[index].id == chatNode.id { scene.nodes[index].id = oldID }
        for index in scene.cables.indices where scene.cables[index].to.node == chatNode.id { scene.cables[index].to.node = oldID }
        XCTAssertTrue(Scenes.isCurrent(scene, in: graph))
        var switched = graph
        Scenes.apply(scene, to: &switched, inventory: inventory)
        XCTAssertEqual(switched, graph)
        XCTAssertEqual(switched.cables(on: Demo.chat.id).first?.from.node, mic.id)
    }

    func testScenesAreSavedInSchema4AndOlderFilesHaveNone() throws {
        var (graph, _, _, _) = setup()
        graph.scenes = [RoutingScene(name: Scenes.newName(in: graph), capturing: graph)]
        XCTAssertEqual(graph.scenes[0].name, "Scene")
        XCTAssertEqual(Scenes.newName(in: graph), "Scene 2")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-scenes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try store.save(graph)
        XCTAssertEqual(store.load(), graph)

        // A schema 4 file written before scenes has no "scenes" key.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(graph)) as? [String: Any])
        object["scenes"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: store.graphURL)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.scenes, [])
        XCTAssertEqual(loaded.cables, graph.cables)

        // A scene naming a device that is gone (edited by hand) loses that part on load.
        var stale = graph
        stale.virtualDevices.removeAll { $0.id == Demo.chat.id }
        try store.save(stale)
        let cleaned = try XCTUnwrap(store.load())
        XCTAssertNil(cleaned.scenes[0].device(Demo.chat.id))
        XCTAssertFalse(cleaned.scenes[0].nodes.contains { $0.canvas == Demo.chat.id })
    }

    // MARK: Templates (as `testStreamWithoutChatTemplate`)

    /// The inventory with a template's device published as an input only, with its companion.
    private func publishing(_ device: VirtualDevice, in inventory: Inventory = Demo.inventory) -> Inventory {
        var inventory = inventory
        inventory.devices += [
            DeviceInfo(uid: device.uid, name: device.name, inputChannels: device.channels, outputChannels: 0, isJunction: true),
            DeviceInfo(uid: device.companionUID, name: device.name + " (Junction routing)", inputChannels: 0,
                       outputChannels: device.channels, isJunction: true),
        ]
        return inventory
    }

    func testPodcastTemplate() throws {
        let zoom = AppRef(bundleID: "us.zoom.xos", name: "zoom.us")
        let microphones = Templates.podcastMicrophones(Demo.inventory)
        XCTAssertEqual(microphones.map { $0.title(Demo.inventory) }, ["MacBook Pro Microphone", "Scarlett 2i2, input 1"])
        XCTAssertEqual(Templates.microphones(Demo.inventory).count, 4, "default input, the mic, two interface inputs")
        var graph = Graph()
        let device = Templates.podcast(&graph, microphones: microphones, call: zoom)
        XCTAssertEqual(graph.virtualDevices.count, 1)
        XCTAssertEqual(device.channels, 6)
        XCTAssertEqual(device.direction, .inputOnly)
        XCTAssertEqual(device.channelNames, ["Mic 1", "Mic 1", "Mic 2", "Mic 2", "Call L", "Call R"])
        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(graph.cables.count, 6)
        XCTAssertEqual(graph.nodes(on: device.id).count, 4, "every node on the device's canvas")
        var tidy = graph
        tidy.tidyCanvases()
        XCTAssertEqual(tidy, graph, "the template makes a consistent canvas")
        let plan = Planner.plan(graph, inventory: publishing(device))
        XCTAssertEqual(plan.sinks.count, 1)
        let sink = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(sink.sinkUID, device.companionUID, "fed through its companion")
        XCTAssertEqual(sink.taps.map(\.mode), [.only(["us.zoom.xos"])])
        // Each source on its own pair of the recorder's channels.
        XCTAssertEqual(sink.routes.map(\.output).sorted(), [0, 1, 2, 3, 4, 5])
        func outputs(_ input: Int) -> [Int] { sink.routes.filter { $0.input == input }.map(\.output).sorted() }
        XCTAssertEqual(Set(sink.routes.map(\.input)).count, 4, "the mic, one interface input and the call's two")
        XCTAssertTrue(plan.idleCables.isEmpty)
        let micInput = try XCTUnwrap(sink.routes.first { $0.output == 0 }?.input)
        XCTAssertEqual(outputs(micInput), [0, 1])
        let interfaceInput = try XCTUnwrap(sink.routes.first { $0.output == 2 }?.input)
        XCTAssertEqual(outputs(interfaceInput), [2, 3])
        XCTAssertEqual(sink.routes.filter { $0.output >= 4 }.count, 2)

        // Two inputs of one interface share its node.
        var shared = Graph()
        let interface = Templates.Microphone(kind: .device(Demo.interface.ref), channel: 0)
        Templates.podcast(&shared, microphones: [interface, Templates.Microphone(kind: interface.kind, channel: 1)], call: nil)
        XCTAssertEqual(shared.nodes.count, 2)
        XCTAssertEqual(shared.virtualDevices[0].channels, 4)
        XCTAssertEqual(shared.cables.map(\.from.channel), [0, 0, 1, 1])
        XCTAssertEqual(shared.cables.map(\.to.channel), [0, 1, 2, 3])
    }

    func testDAWIntoCallTemplate() throws {
        let logic = Templates.dawApps[0]
        var graph = Graph()
        let device = Templates.dawIntoCall(&graph, daw: logic, microphone: Templates.Microphone(kind: .defaultInput))
        XCTAssertEqual(device.name, "DAW to Call")
        XCTAssertEqual(device.channels, 2)
        XCTAssertEqual(device.direction, .inputOnly)
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.cables.count, 4)
        XCTAssertEqual(graph.nodes(on: device.id).count, 3)
        var tidy = graph
        tidy.tidyCanvases()
        XCTAssertEqual(tidy, graph)
        let plan = Planner.plan(graph, inventory: publishing(device))
        let sink = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(sink.sinkUID, device.companionUID)
        XCTAssertEqual(sink.taps.map(\.mode), [.only([logic.bundleID])])
        XCTAssertEqual(sink.routes.map(\.output).sorted(), [0, 0, 1, 1], "the music and the mic on both channels")
        XCTAssertTrue(plan.idleCables.isEmpty)

        // Again, without a mic, onto the same device: it's reused and turned on.
        graph.virtualDevices[0].isEnabled = false
        let again = Templates.dawIntoCall(&graph, daw: logic, microphone: nil)
        XCTAssertEqual(again.id, device.id)
        XCTAssertTrue(graph.virtualDevices[0].isEnabled)
        XCTAssertEqual(graph.virtualDevices.count, 1)
        XCTAssertEqual(graph.nodes(on: device.id).count, 4)
    }

    func testCallIntoDAWTemplate() throws {
        var graph = Graph()
        let device = Templates.callIntoDAW(&graph, call: Demo.discord)
        XCTAssertEqual(device.name, "Call to DAW")
        XCTAssertEqual(device.channelNames, ["Call L", "Call R"])
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.cables.count, 2)
        XCTAssertEqual(graph.nodes(on: device.id).count, 2)
        var tidy = graph
        tidy.tidyCanvases()
        XCTAssertEqual(tidy, graph)
        let plan = Planner.plan(graph, inventory: publishing(device))
        let sink = try XCTUnwrap(plan.sinks.first)
        XCTAssertEqual(sink.taps.map(\.mode), [.only(["com.hnc.Discord"])])
        // The companion's own inputs come first, then the tap: L and R land on its channels 1 and 2.
        XCTAssertEqual(sink.routes.map(\.output), [0, 1])
        XCTAssertEqual(sink.routes.map(\.input), [sink.inputChannels - 2, sink.inputChannels - 1])
        XCTAssertTrue(plan.idleCables.isEmpty)
    }

    func testTemplateAppChoices() {
        let logic = Templates.dawApps[0]
        let music = AppRef(bundleID: "com.apple.Music", name: "Music")
        let candidates = Templates.appCandidates(usingAudio: [music], installed: [logic])
        XCTAssertEqual(candidates.map(\.name), ["Music", "Logic Pro"])
        XCTAssertEqual(Templates.likelyApp(in: candidates, known: Templates.dawApps), logic)
        XCTAssertEqual(Templates.likelyApp(in: [music], known: Templates.dawApps), music)
        XCTAssertNil(Templates.likelyApp(in: [], known: Templates.chatApps))
    }
}
