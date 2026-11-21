import XCTest
@testable import JunctionCore

final class MixerTests: XCTestCase {
    static let phones = DeviceInfo(uid: "Headphones", name: "Headphones", inputChannels: 0, outputChannels: 2)

    /// Stream Mix with the mic (mono, to both sides at −3 dB) and Discord (stereo) as sources, played on the speakers
    /// and the interface.
    private struct Setup {
        var graph: Graph
        var inventory: Inventory
        var device: Node
        var mic: Node
        var discord: Node
        var speakers: Node
        var interface: Node
    }

    private func setup() -> Setup {
        let id = Demo.streamMix.id
        let device = Node(kind: .virtualDevice(id), x: CanvasColumn.device, y: 60, canvas: id)
        let mic = Node(kind: .device(Demo.mic.ref), x: CanvasColumn.sources, y: 200, canvas: id)
        let discord = Node(kind: .application(Demo.discord), x: CanvasColumn.sources, y: 40, canvas: id)
        let speakers = Node(kind: .device(Demo.speakers.ref), x: CanvasColumn.outputs, y: 40, canvas: id)
        let interface = Node(kind: .device(Demo.interface.ref), x: CanvasColumn.outputs, y: 200, canvas: id)
        func cable(_ a: Node, _ ac: Int, _ b: Node, _ bc: Int, _ dB: Double = 0) -> Cable {
            Cable(from: PortRef(node: a.id, channel: ac), to: PortRef(node: b.id, channel: bc), gainDB: dB)
        }
        var graph = Graph(virtualDevices: [Demo.streamMix], nodes: [device, mic, discord, speakers, interface])
        graph.cables = [cable(mic, 0, device, 0, -3), cable(mic, 0, device, 1, -3),
                        cable(discord, 0, device, 0), cable(discord, 1, device, 1),
                        cable(device, 0, speakers, 0), cable(device, 1, speakers, 1),
                        cable(device, 0, interface, 0, -6)]
        var inventory = Demo.inventory
        inventory.devices.append(Self.phones)
        return Setup(graph: graph, inventory: inventory, device: device, mic: mic, discord: discord, speakers: speakers,
                     interface: interface)
    }

    private var phonesOutput: MonitorOutput { .device(Self.phones.ref) }

    func testStripsFollowTheCanvas() {
        var s = setup()
        let strips = Mixer.strips(on: Demo.streamMix.id, graph: s.graph, inventory: s.inventory)
        // Sources top to bottom, the device, outputs top to bottom.
        XCTAssertEqual(strips.map(\.node), [s.discord.id, s.mic.id, s.device.id, s.speakers.id, s.interface.id])
        XCTAssertEqual(strips.map(\.role), [.source, .source, .device, .output, .output])
        // Pan where there is a left and a right: not on the device, nor on the interface (only its channel 1 is fed).
        XCTAssertEqual(strips.map(\.hasPan), [true, true, false, true, false])
        // Solo/listen ports: a source's and the device's outputs, an output's inputs.
        XCTAssertEqual(strips[1].ports, [PortRef(node: s.mic.id, channel: 0)])
        XCTAssertEqual(strips[3].ports.map(\.channel), [0, 1])

        // A node added on the canvas is a new strip; no new node kind is involved.
        let system = Node(kind: .systemAudio(excluding: []), x: CanvasColumn.sources, y: 400, canvas: Demo.streamMix.id)
        s.graph.nodes.append(system)
        let more = Mixer.strips(on: Demo.streamMix.id, graph: s.graph, inventory: s.inventory)
        XCTAssertEqual(more.map(\.node), [s.discord.id, s.mic.id, system.id, s.device.id, s.speakers.id, s.interface.id])
        XCTAssertFalse(more[2].hasPan, "not wired yet")
    }

    func testMixerAndCanvasEditTheSameGraph() throws {
        let s = setup()
        // Panning the mic in the mixer sets the levels of its cables: the louder side keeps its level.
        var mixer = s.graph
        Mixer.setPan(-0.5, of: s.mic.id, in: &mixer)
        let (left, right) = try XCTUnwrap(Mixer.panCables(s.mic.id, graph: mixer))
        XCTAssertEqual(left.map(\.gainDB), [-3])
        XCTAssertEqual(right[0].gainDB, -3 + 20 * log10(0.5), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Mixer.pan(s.mic.id, graph: mixer)), -0.5, accuracy: 1e-9)
        XCTAssertEqual(mixer.nodes, s.graph.nodes, "panning changes cables only")

        // The same change made on the canvas (the cable's level in the inspector) is the same graph, plans the same,
        // and the mixer shows it.
        var canvas = s.graph
        let rightCable = try XCTUnwrap(canvas.cables.firstIndex { $0.from.node == s.mic.id && $0.to.channel == 1 })
        canvas.cables[rightCable].gainDB = -3 + 20 * log10(0.5)
        XCTAssertEqual(canvas, mixer)
        XCTAssertEqual(Planner.plan(canvas, inventory: s.inventory), Planner.plan(mixer, inventory: s.inventory))

        // A fader and a mute are the node's level and mute, as on the canvas.
        var faded = s.graph
        let micIndex = try XCTUnwrap(faded.nodes.firstIndex { $0.id == s.mic.id })
        faded.nodes[micIndex].gainDB = -12
        let route = try XCTUnwrap(Planner.plan(faded, inventory: s.inventory).sinks.first { $0.sinkNode == s.device.id }?
            .routes.first { $0.source.node == s.mic.id })
        XCTAssertEqual(route.gain, Gain.linear(-12) * Gain.linear(-3), accuracy: 1e-6)

        // Hard left: the right side is silent; back to the middle: both sides at the louder level.
        Mixer.setPan(-1, of: s.mic.id, in: &mixer)
        XCTAssertEqual(Mixer.panCables(s.mic.id, graph: mixer)?.right.map(\.gainDB), [Gain.floorDB])
        XCTAssertEqual(Mixer.pan(s.mic.id, graph: mixer), -1)
        Mixer.setPan(0, of: s.mic.id, in: &mixer)
        XCTAssertEqual(mixer, s.graph)
        // An output pans its own channels: the speakers' right cable goes down.
        Mixer.setPan(0.25, of: s.speakers.id, in: &mixer)
        XCTAssertEqual(try XCTUnwrap(Mixer.pan(s.speakers.id, graph: mixer)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Mixer.panCables(s.speakers.id, graph: mixer)?.right.map(\.gainDB), [0])
        // Without a left and a right there is nothing to pan.
        let before = mixer
        Mixer.setPan(0.5, of: s.interface.id, in: &mixer)
        Mixer.setPan(0.5, of: s.device.id, in: &mixer)
        XCTAssertEqual(mixer, before)
        XCTAssertNil(Mixer.pan(s.interface.id, graph: mixer))
        XCTAssertEqual(Mixer.panText(0), "C")
        XCTAssertEqual(Mixer.panText(-0.3), "L 30")
        XCTAssertEqual(Mixer.panText(1), "R 100")
    }

    func testMonitorGainsAreIndependent() throws {
        var s = setup()
        let base = Planner.plan(s.graph, inventory: s.inventory)
        s.graph.updateMonitor(for: Demo.streamMix.id) { monitor in
            monitor.output = phonesOutput
            monitor.gainDB = -6
            monitor.setSend(MonitorSend(node: s.mic.id, gainDB: -10))
        }
        let monitor = try XCTUnwrap(s.graph.monitor(for: Demo.streamMix.id))
        let plan = Planner.plan(s.graph, inventory: s.inventory)
        // The device's sinks are as they were; the monitor is one more.
        XCTAssertEqual(plan.sinks.filter { $0.sinkNode != monitor.id }, base.sinks)
        let sink = try XCTUnwrap(plan.sinks.first { $0.sinkNode == monitor.id })
        XCTAssertEqual(sink.sinkUID, Self.phones.uid)
        XCTAssertEqual(sink.name, "Stream Mix monitor")
        XCTAssertEqual(sink.masterGain, Gain.linear(-6))
        XCTAssertTrue(sink.slots.allSatisfy(\.effects.isEmpty), "effects run in the device's sink only")
        func gains(_ plan: RoutingPlan, _ node: UUID) -> [Float] {
            plan.sinks.first { $0.sinkNode == monitor.id }?.routes.filter { $0.source.node == node }.map(\.gain) ?? []
        }
        // Each source as it is cabled into the device (its pan), at the monitor's level for it.
        XCTAssertEqual(gains(plan, s.mic.id), [Gain.linear(-13), Gain.linear(-13)])
        XCTAssertEqual(gains(plan, s.discord.id), [1, 1])
        XCTAssertEqual(sink.routes.map(\.output).sorted(), [0, 0, 1, 1])
        XCTAssertTrue(plan.idleCables.isSubset(of: Set(s.graph.cables.map(\.id))), "the monitor's cables aren't the graph's")
        XCTAssertEqual(Planner.plan(s.graph, inventory: s.inventory), plan, "the same graph plans the same")

        // The mic's fader and mute change the stream, not the monitor.
        var faded = s.graph
        let micIndex = try XCTUnwrap(faded.nodes.firstIndex { $0.id == s.mic.id })
        faded.nodes[micIndex].gainDB = -20
        faded.nodes[micIndex].isMuted = true
        let fadedPlan = Planner.plan(faded, inventory: s.inventory)
        XCTAssertNotEqual(fadedPlan.sinks.first { $0.sinkNode == s.device.id }, plan.sinks.first { $0.sinkNode == s.device.id })
        XCTAssertEqual(fadedPlan.sinks.first { $0.sinkNode == monitor.id }, sink)

        // The monitor's levels change the monitor, not the stream or its outputs.
        var sent = s.graph
        sent.updateMonitor(for: Demo.streamMix.id) {
            $0.setSend(MonitorSend(node: s.mic.id, gainDB: 0))
            $0.setSend(MonitorSend(node: s.discord.id, isOn: false))
            $0.isMuted = true
        }
        let sentPlan = Planner.plan(sent, inventory: s.inventory)
        XCTAssertEqual(sentPlan.sinks.filter { $0.sinkNode != monitor.id }, base.sinks)
        XCTAssertEqual(gains(sentPlan, s.mic.id), [Gain.linear(-3), Gain.linear(-3)])
        XCTAssertEqual(gains(sentPlan, s.discord.id), [], "turned off")
        XCTAssertEqual(sentPlan.sinks.first { $0.sinkNode == monitor.id }?.masterGain, 0)

        // Nowhere to play: nothing planned.
        var nowhere = s.graph
        nowhere.updateMonitor(for: Demo.streamMix.id) { $0.output = nil }
        XCTAssertEqual(Planner.plan(nowhere, inventory: s.inventory), base)
    }

    func testSoloListensWithoutChangingTheMix() throws {
        var s = setup()
        s.graph.updateMonitor(for: Demo.streamMix.id) {
            $0.output = phonesOutput
            $0.setSend(MonitorSend(node: s.mic.id, gainDB: -10))
        }
        let base = Planner.plan(s.graph, inventory: s.inventory)
        let monitorID = try XCTUnwrap(s.graph.monitor(for: Demo.streamMix.id)).id
        let strips = Mixer.strips(on: Demo.streamMix.id, graph: s.graph, inventory: s.inventory)

        func listening(_ change: (inout MonitorMix) -> Void) throws -> SinkPlan {
            var graph = s.graph
            graph.updateMonitor(for: Demo.streamMix.id, change)
            let plan = Planner.plan(graph, inventory: s.inventory)
            XCTAssertEqual(plan.sinks.filter { $0.sinkNode != monitorID }, base.sinks.filter { $0.sinkNode != monitorID },
                           "solo/listen leaves the device's mix and other sinks alone")
            XCTAssertEqual(graph.nodes, s.graph.nodes)
            XCTAssertEqual(graph.cables, s.graph.cables)
            return try XCTUnwrap(plan.sinks.first { $0.sinkNode == monitorID })
        }

        // The mono mic on both sides, at 0 dB: not its send, not its cables' level.
        let mic = try listening { Mixer.toggleSolo(strips[1], in: &$0) }
        XCTAssertEqual(mic.routes.map(\.source), [PortRef(node: s.mic.id, channel: 0), PortRef(node: s.mic.id, channel: 0)])
        XCTAssertEqual(mic.routes.map(\.output), [0, 1])
        XCTAssertEqual(mic.routes.map(\.gain), [1, 1])
        // Discord's right channel alone, from the canvas's port menu.
        let right = try listening { $0.toggleListening(PortRef(node: s.discord.id, channel: 1)) }
        XCTAssertEqual(right.routes.map(\.source.channel), [1, 1])
        // The stream itself: the device's outputs, left and right.
        let stream = try listening { Mixer.toggleSolo(strips[2], in: &$0) }
        XCTAssertEqual(stream.routes.map(\.source), [PortRef(node: s.device.id, channel: 0), PortRef(node: s.device.id, channel: 1)])
        XCTAssertEqual(stream.routes.map(\.output), [0, 1])
        // An output: what arrives at it, at its cables' and its own level.
        let interface = try listening { Mixer.toggleSolo(strips[4], in: &$0) }
        XCTAssertEqual(interface.routes.map(\.source), [PortRef(node: s.device.id, channel: 0), PortRef(node: s.device.id, channel: 0)])
        XCTAssertEqual(interface.routes.map(\.gain), [Gain.linear(-6), Gain.linear(-6)])
        // Solo again turns it off: the monitor mix is back.
        var monitor = try XCTUnwrap(s.graph.monitor(for: Demo.streamMix.id))
        Mixer.toggleSolo(strips[1], in: &monitor)
        XCTAssertTrue(monitor.isListening(to: s.mic.id))
        Mixer.toggleSolo(strips[1], in: &monitor)
        XCTAssertEqual(monitor.listening, [])

        // Removing a soloed node stops listening to it, and its monitor level goes with it.
        var removed = s.graph
        removed.updateMonitor(for: Demo.streamMix.id) { Mixer.toggleSolo(strips[1], in: &$0) }
        removed.removeNode(s.mic.id)
        XCTAssertEqual(removed.monitor(for: Demo.streamMix.id)?.listening, [])
        XCTAssertEqual(removed.monitor(for: Demo.streamMix.id)?.sends, [])
        XCTAssertNotNil(Planner.plan(removed, inventory: s.inventory).sinks.first { $0.sinkNode == monitorID },
                        "back to the monitor's mix")
    }

    func testMonitorsNeverFeedALoop() throws {
        let s = setup()
        let base = Planner.plan(s.graph, inventory: s.inventory)
        var outputs: [MonitorOutput] = [phonesOutput, .defaultOutput, .device(Demo.speakers.ref), .device(Demo.interface.ref),
                                        .device(DeviceRef(uid: Demo.chat.uid, name: "Chat", inputChannels: 2, outputChannels: 2)),
                                        .device(DeviceRef(uid: Demo.streamMix.uid, name: "Stream Mix", inputChannels: 2, outputChannels: 2))]
        outputs.append(.device(DeviceRef(uid: "junction.unplugged", name: "Gone", inputChannels: 2, outputChannels: 2)))
        var junctionDefault = s.inventory
        junctionDefault.defaultOutputUID = Demo.chat.uid  // Sound settings point at one of Junction's devices
        let strips = Mixer.strips(on: Demo.streamMix.id, graph: s.graph, inventory: s.inventory)
        // Every output, with the monitor's mix and with solo/listen on every strip.
        var listens: [[PortRef]] = [[]] + strips.map(\.ports)
        listens.append(strips.flatMap(\.ports))
        for inventory in [s.inventory, junctionDefault] {
            for output in outputs {
                for listening in listens {
                    var graph = s.graph
                    graph.updateMonitor(for: Demo.streamMix.id) {
                        $0.output = output
                        $0.listening = listening
                    }
                    let monitor = try XCTUnwrap(graph.monitor(for: Demo.streamMix.id))
                    let plan = Planner.plan(graph, inventory: inventory)
                    let expected = Planner.plan(s.graph, inventory: inventory)
                    XCTAssertEqual(plan.sinks.filter { $0.sinkNode != monitor.id }, expected.sinks, "other sinks are left alone")
                    let problem = Rules.monitorProblem(output, inventory: inventory)
                    let sink = plan.sinks.first { $0.sinkNode == monitor.id }
                    // The editor's rule and the planner agree: a monitor never plays into a loopback device.
                    if problem != nil {
                        XCTAssertNil(sink, "\(output) is refused")
                        XCTAssertEqual(plan.issues[monitor.id], [Rules.Problem.monitorFeedback.message])
                    } else {
                        let into = try XCTUnwrap(sink, "\(output) is planned")
                        XCTAssertFalse(inventory.device(into.sinkUID)?.isJunction ?? true)
                        XCTAssertNil(plan.issues[monitor.id])
                    }
                    for issue in plan.issues.values.joined() { XCTAssertFalse(issue.contains("feed its own audio back")) }
                }
            }
        }
        XCTAssertNil(Rules.monitorProblem(phonesOutput, inventory: s.inventory))
        XCTAssertEqual(Rules.monitorProblem(.defaultOutput, inventory: junctionDefault), .monitorFeedback)
        XCTAssertEqual(Rules.monitorProblem(.device(DeviceRef(uid: Demo.chat.uid, name: "Chat", inputChannels: 2,
                                                              outputChannels: 2)), inventory: s.inventory), .monitorFeedback)
        XCTAssertEqual(base, Planner.plan(s.graph, inventory: s.inventory))
    }
}
