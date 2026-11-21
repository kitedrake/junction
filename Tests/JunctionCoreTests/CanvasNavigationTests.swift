import CoreGraphics
import XCTest
@testable import JunctionCore

final class CanvasNavigationTests: XCTestCase {
    private func assertEqual(_ a: CGPoint, _ b: CGPoint, accuracy: Double = 1e-9, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// Stream Mix's canvas: System Audio and the mic feed the device, the speakers play it.
    private func sample() -> (graph: Graph, device: Node, system: Node, mic: Node, speakers: Node) {
        let a = Demo.streamMix.id
        let device = Node(kind: .virtualDevice(a), x: CanvasColumn.device, y: 60, canvas: a)
        let system = Node(kind: .systemAudio(excluding: []), x: 40, y: 40, canvas: a)
        let mic = Node(kind: .device(Demo.mic.ref), x: 40, y: 260, canvas: a)
        let speakers = Node(kind: .device(Demo.speakers.ref), x: 620, y: 60, canvas: a)
        func cable(_ x: Node, _ xc: Int, _ y: Node, _ yc: Int, _ dB: Double = 0) -> Cable {
            Cable(from: PortRef(node: x.id, channel: xc), to: PortRef(node: y.id, channel: yc), gainDB: dB)
        }
        let graph = Graph(virtualDevices: [Demo.streamMix], nodes: [device, system, mic, speakers],
                          cables: [cable(system, 0, device, 0), cable(system, 1, device, 1, -6),
                                   cable(mic, 0, device, 0), cable(mic, 0, device, 1),
                                   cable(device, 0, speakers, 0), cable(device, 1, speakers, 1)])
        return (graph, device, system, mic, speakers)
    }

    // MARK: Zoom and pan

    func testZoomKeepsThePointUnderThePointerInPlace() {
        let start = CanvasViewport(scale: 1, origin: CGPoint(x: 100, y: 50))
        let pointer = CGPoint(x: 300, y: 200)
        let under = start.contentPoint(pointer)
        assertEqual(under, CGPoint(x: 400, y: 250))
        for factor in [2.0, 0.5, 1.37] {
            let zoomed = start.zoomed(by: factor, about: pointer)
            XCTAssertEqual(zoomed.scale, factor, accuracy: 1e-12)
            assertEqual(zoomed.viewPoint(under), pointer, "the canvas point under the pointer stays under it")
            assertEqual(zoomed.contentPoint(pointer), under)
        }
        // Limits hold, and the point still stays put at the limit.
        let tiny = start.zoomed(to: 0.01, about: pointer)
        XCTAssertEqual(tiny.scale, CanvasViewport.minScale)
        assertEqual(tiny.viewPoint(under), pointer)
        XCTAssertEqual(start.zoomed(to: 50, about: pointer).scale, CanvasViewport.maxScale)
        // Round trip between view and canvas coordinates.
        let view = CGPoint(x: 17, y: 923)
        let some = CanvasViewport(scale: 1.75, origin: CGPoint(x: -40, y: 310))
        assertEqual(some.viewPoint(some.contentPoint(view)), view, accuracy: 1e-9)
    }

    func testZoomStepsAndActualSize() {
        let center = CGPoint(x: 400, y: 300)
        var viewport = CanvasViewport()
        viewport = viewport.stepped(in: true, about: center)
        XCTAssertEqual(viewport.scale, 1.1)
        viewport = viewport.stepped(in: false, about: center).stepped(in: false, about: center)
        XCTAssertEqual(viewport.scale, 0.9)
        // Between two steps, ⌘+ goes to the next one up.
        XCTAssertEqual(CanvasViewport(scale: 1.2).stepped(in: true, about: center).scale, 1.25)
        XCTAssertEqual(CanvasViewport(scale: 3).stepped(in: true, about: center).scale, 3, "already at the largest")
        XCTAssertEqual(CanvasViewport(scale: 0.25).stepped(in: false, about: center).scale, 0.25)
        XCTAssertEqual(CanvasViewport(scale: 1.5).percentText, "150 %")
    }

    func testPanningFollowsThePointerAtAnyZoom() {
        let viewport = CanvasViewport(scale: 2, origin: CGPoint(x: 100, y: 100))
        let grabbed = viewport.contentPoint(CGPoint(x: 50, y: 50))
        let moved = viewport.panned(by: CGSize(width: 30, height: -20))
        assertEqual(moved.viewPoint(grabbed), CGPoint(x: 80, y: 30), "the canvas moves with the drag")
        XCTAssertEqual(moved.scale, 2)
    }

    func testClampingKeepsTheCanvasInReach() {
        let content = CGSize(width: 1800, height: 1200), view = CGSize(width: 800, height: 600)
        let far = CanvasViewport(origin: CGPoint(x: -5000, y: 9000)).clamped(content: content, viewSize: view)
        assertEqual(far.origin, CGPoint(x: -120, y: 1200 + 120 - 600))
        // Zoomed far out the whole canvas fits: it may sit anywhere inside the view, so zooming out doesn't jump.
        let out = CanvasViewport(scale: 0.25, origin: CGPoint(x: -500, y: -300))
        let clamped = out.clamped(content: content, viewSize: view)
        assertEqual(clamped.origin, out.origin)
        let tooFar = CanvasViewport(scale: 0.25, origin: CGPoint(x: -3000, y: 0)).clamped(content: content, viewSize: view)
        XCTAssertEqual(tooFar.origin.x, 1800 + 120 - 800 / 0.25)
    }

    func testZoomToFitShowsEveryNode() {
        let rect = CGRect(x: 40, y: 40, width: 2000, height: 600)
        let view = CGSize(width: 1000, height: 700)
        let fit = CanvasViewport.fitting(rect, in: view)
        XCTAssertLessThan(fit.scale, 1)
        let visible = fit.visibleRect(view)
        XCTAssertTrue(visible.contains(rect), "\(visible) holds \(rect)")
        assertEqual(CGPoint(x: visible.midX, y: visible.midY), CGPoint(x: rect.midX, y: rect.midY), accuracy: 1e-6)
        // A small canvas isn't blown up past actual size.
        XCTAssertEqual(CanvasViewport.fitting(CGRect(x: 0, y: 0, width: 100, height: 100), in: view).scale, 1)
    }

    // MARK: Minimap

    func testMinimapMapsBothWays() {
        let world = CGRect(x: -60, y: -20, width: 1200, height: 400)  // wider than the map's proportions
        let map = Minimap(world: world, size: CGSize(width: 180, height: 120))
        XCTAssertEqual(map.scale, 0.15, accuracy: 1e-12)
        // Centred vertically: 400 × 0.15 = 60 points tall in a 120-point map.
        assertEqual(map.mapPoint(CGPoint(x: -60, y: -20)), CGPoint(x: 0, y: 30))
        assertEqual(map.mapPoint(CGPoint(x: 1140, y: 380)), CGPoint(x: 180, y: 90))
        let point = CGPoint(x: 512, y: 77)
        assertEqual(map.contentPoint(map.mapPoint(point)), point, accuracy: 1e-9)
        let rect = map.mapRect(CGRect(x: 240, y: 80, width: 400, height: 200))
        XCTAssertEqual(rect.width, 60, accuracy: 1e-9)
        assertEqual(rect.origin, map.mapPoint(CGPoint(x: 240, y: 80)))
    }

    func testMinimapCoversTheNodesAndTheVisiblePart() {
        let nodes = [CGRect(x: 40, y: 40, width: 236, height: 100), CGRect(x: 620, y: 300, width: 236, height: 100)]
        let visible = CGRect(x: 1000, y: 0, width: 400, height: 300)
        let world = Minimap.world(nodes: nodes, visible: visible, padding: 60)
        XCTAssertEqual(world, CGRect(x: -20, y: -20, width: 1420, height: 480))
        XCTAssertEqual(Minimap.world(nodes: [], visible: visible), visible)
        // Clicking the map centres the view on that canvas point.
        let map = Minimap(world: world, size: CGSize(width: 180, height: 120))
        let target = map.contentPoint(CGPoint(x: 90, y: 60))
        let viewport = CanvasViewport(scale: 0.5).centered(on: target, viewSize: CGSize(width: 800, height: 600))
        let shown = viewport.visibleRect(CGSize(width: 800, height: 600))
        assertEqual(CGPoint(x: shown.midX, y: shown.midY), target, accuracy: 1e-9)
    }

    // MARK: Cables under the pointer

    func testWhichCableAPointOrDropHits() throws {
        let (graph, device, system, mic, speakers) = sample()
        let cables = graph.cables
        let out = try XCTUnwrap(cables.first { $0.from.node == device.id && $0.to.channel == 1 })
        let (a, b) = try XCTUnwrap(CanvasGeometry.ends(of: out, in: graph))
        assertEqual(a, CanvasGeometry.outputPoint(device, 1))
        assertEqual(b, CanvasGeometry.inputPoint(speakers, 1))
        let middle = CanvasGeometry.point(a, b, t: 0.5)
        XCTAssertEqual(CanvasGeometry.cable(at: middle, among: cables, graph: graph), out.id)
        // A drop counts from further away than a click.
        let near = CGPoint(x: middle.x, y: middle.y + 13)
        XCTAssertNil(CanvasGeometry.cable(at: near, among: cables, graph: graph))
        XCTAssertEqual(CanvasGeometry.cable(at: near, among: cables, graph: graph, tolerance: CanvasGeometry.dropTolerance), out.id)
        // Empty canvas far from any cable.
        XCTAssertNil(CanvasGeometry.cable(at: CGPoint(x: 1500, y: 1000), among: cables, graph: graph,
                                          tolerance: CanvasGeometry.dropTolerance))
        // Between two parallel cables the nearer one wins: the mic's ends at the device's input 0 and 1.
        let micToLeft = try XCTUnwrap(cables.first { $0.from.node == mic.id && $0.to.channel == 0 })
        let (ma, mb) = try XCTUnwrap(CanvasGeometry.ends(of: micToLeft, in: graph))
        let onMic = CanvasGeometry.point(ma, mb, t: 0.2)
        XCTAssertEqual(CanvasGeometry.cable(at: onMic, among: cables, graph: graph), micToLeft.id)
        XCTAssertEqual(CanvasGeometry.distance(from: ma, toCableFrom: ma, to: mb), 0, accuracy: 1e-9)
        // Only the cables given are considered (the canvas passes its own).
        XCTAssertNil(CanvasGeometry.cable(at: middle, among: cables.filter { $0.from.node == system.id }, graph: graph))
    }

    func testDropPutsTheTitleUnderThePointer() {
        assertEqual(CanvasGeometry.dropOrigin(CGPoint(x: 500, y: 300)), CGPoint(x: 470, y: 300 - CanvasMetrics.header / 2))
        assertEqual(CanvasGeometry.dropOrigin(CGPoint(x: 5, y: 5)), .zero, "never off the top-left edge")
        let info = NodeInfo(graph: sample().graph, inventory: Demo.inventory)
        XCTAssertEqual(CanvasGeometry.contentSize(of: [], info: info), CGSize(width: 1800, height: 1200))
        let far = Node(kind: .defaultOutput, x: 2000, y: 1500, canvas: Demo.streamMix.id)
        let size = CanvasGeometry.contentSize(of: [far], info: info)
        XCTAssertEqual(size.width, 2000 + CanvasMetrics.nodeWidth + 400)
    }

    // MARK: Dropping a node onto a cable

    func testASourceDroppedOnACableIntoTheDeviceFeedsTheSameChannels() throws {
        var (graph, device, system, _, _) = sample()
        let music = Node(kind: .application(AppRef(bundleID: "com.apple.Music", name: "Music")), x: 100, y: 500,
                         canvas: Demo.streamMix.id)
        graph.nodes.append(music)
        let before = graph
        let hit = try XCTUnwrap(graph.cables.first { $0.from.node == system.id && $0.to.channel == 1 })
        XCTAssertNil(Editing.insert(music.id, onto: hit.id, graph: &graph, inventory: Demo.inventory))
        // A → node → B would run past the device, so the node joins the stereo run instead: L → L, R → R.
        XCTAssertTrue(before.cables.allSatisfy { graph.cables.contains($0) }, "the cables already there stay, levels and all")
        let added = graph.cables.filter { $0.from.node == music.id }
        XCTAssertEqual(added.map(\.from.channel).sorted(), [0, 1])
        XCTAssertEqual(Set(added.map(\.to)), [PortRef(node: device.id, channel: 0), PortRef(node: device.id, channel: 1)])
        // Again: everything is already there.
        XCTAssertEqual(Editing.insert(music.id, onto: hit.id, graph: &graph, inventory: Demo.inventory), .alreadyConnected)
    }

    func testAnOutputDroppedOnACableOutOfTheDevicePlaysTheSameChannels() throws {
        var (graph, device, _, mic, speakers) = sample()
        let interface = Node(kind: .device(Demo.interface.ref), x: 620, y: 300, canvas: Demo.streamMix.id)
        graph.nodes.append(interface)
        let hit = try XCTUnwrap(graph.cables.first { $0.to.node == speakers.id })
        XCTAssertNil(Editing.insert(interface.id, onto: hit.id, graph: &graph, inventory: Demo.inventory))
        let added = graph.cables.filter { $0.to.node == interface.id }
        XCTAssertEqual(added.map(\.from).sorted { $0.channel < $1.channel },
                       [PortRef(node: device.id, channel: 0), PortRef(node: device.id, channel: 1)])
        XCTAssertEqual(added.map(\.to.channel).sorted(), [0, 1])
        // A mono run (the mic into both device channels) and a node with nothing on the needed side.
        let speakers2 = Node(kind: .defaultOutput, x: 620, y: 500, canvas: Demo.streamMix.id)
        graph.nodes.append(speakers2)
        let micCable = try XCTUnwrap(graph.cables.first { $0.from.node == mic.id })
        let before = graph
        XCTAssertEqual(Editing.insert(speakers2.id, onto: micCable.id, graph: &graph, inventory: Demo.inventory), .noSuchPort,
                       "an output has nothing to feed the device with")
        XCTAssertEqual(graph, before)
        XCTAssertEqual(Editing.insert(mic.id, onto: micCable.id, graph: &graph, inventory: Demo.inventory), .alreadyConnected,
                       "a cable's own end")
        XCTAssertEqual(Editing.insert(speakers2.id, onto: UUID(), graph: &graph, inventory: Demo.inventory), .noSuchPort)
    }

    func testInsertingOntoACableObeysTheLoopGuard() throws {
        var (graph, _, _, mic, speakers) = sample()
        let out = Node(kind: .defaultOutput, x: 620, y: 300, canvas: Demo.streamMix.id)
        let input = Node(kind: .defaultInput, x: 40, y: 500, canvas: Demo.streamMix.id)
        graph.nodes += [out, input]
        var inventory = Demo.inventory
        // Sound settings play through Stream Mix and record from it: either drop would feed the device back into itself.
        inventory.defaultOutputUID = Demo.streamMix.uid
        inventory.defaultInputUID = Demo.streamMix.uid
        let before = graph
        let outgoing = try XCTUnwrap(graph.cables.first { $0.to.node == speakers.id })
        XCTAssertEqual(Editing.insert(out.id, onto: outgoing.id, graph: &graph, inventory: inventory), .feedback)
        let incoming = try XCTUnwrap(graph.cables.first { $0.from.node == mic.id })
        XCTAssertEqual(Editing.insert(input.id, onto: incoming.id, graph: &graph, inventory: inventory), .feedback)
        XCTAssertEqual(graph, before, "a refused drop changes nothing")
        // With real devices in Sound settings the same drops are fine.
        XCTAssertNil(Editing.insert(out.id, onto: outgoing.id, graph: &graph, inventory: Demo.inventory))
        XCTAssertNil(Editing.insert(input.id, onto: incoming.id, graph: &graph, inventory: Demo.inventory))
    }

    func testANodeFromAnotherCanvasIsNotInserted() throws {
        var (graph, _, system, _, _) = sample()
        let chatDevice = Node(kind: .virtualDevice(Demo.chat.id), canvas: Demo.chat.id)
        let elsewhere = Node(kind: .defaultInput, canvas: Demo.chat.id)
        graph.virtualDevices.append(Demo.chat)
        graph.nodes += [chatDevice, elsewhere]
        let hit = try XCTUnwrap(graph.cables.first { $0.from.node == system.id })
        let before = graph
        XCTAssertEqual(Editing.insert(elsewhere.id, onto: hit.id, graph: &graph, inventory: Demo.inventory), .noSuchPort)
        XCTAssertEqual(graph, before)
    }

    // MARK: Keyboard connecting

    func testKeyboardChoicesAreThePortsRulesAllow() throws {
        var (graph, device, system, mic, speakers) = sample()
        let music = Node(kind: .application(AppRef(bundleID: "com.apple.Music", name: "Music")), canvas: Demo.streamMix.id)
        graph.nodes.append(music)
        // From Music's left output: only the device's inputs (a source can't go straight to the speakers).
        let start = PortEnd(node: music.id, channel: 0, isOutput: true)
        let choices = KeyboardConnect.choices(for: start, graph: graph, inventory: Demo.inventory)
        XCTAssertEqual(choices, [PortEnd(node: device.id, channel: 0, isOutput: false), PortEnd(node: device.id, channel: 1, isOutput: false)])
        // From the device's input 0: outputs of sources not yet connected there (System Audio's L and the mic are).
        let deviceIn = KeyboardConnect.choices(for: PortEnd(node: device.id, channel: 0, isOutput: false), graph: graph,
                                               inventory: Demo.inventory)
        XCTAssertEqual(deviceIn, [PortEnd(node: system.id, channel: 1, isOutput: true),
                                  PortEnd(node: music.id, channel: 0, isOutput: true), PortEnd(node: music.id, channel: 1, isOutput: true)])
        XCTAssertFalse(deviceIn.contains { $0.port.node == mic.id || $0.port.node == speakers.id })
        // Connecting the picked one makes the cable from the output end to the input end.
        let (from, to) = try XCTUnwrap(KeyboardConnect.cable(choices[1], start))
        XCTAssertEqual(from, start.port)
        XCTAssertEqual(to, PortRef(node: device.id, channel: 1))
        XCTAssertNil(KeyboardConnect.cable(start, start))
        // With Sound settings playing through Stream Mix, Default Output isn't offered from the device.
        let out = Node(kind: .defaultOutput, canvas: Demo.streamMix.id)
        graph.nodes.append(out)
        var looped = Demo.inventory
        looped.defaultOutputUID = Demo.streamMix.uid
        let deviceOut = PortEnd(node: device.id, channel: 0, isOutput: true)
        XCTAssertTrue(KeyboardConnect.choices(for: deviceOut, graph: graph, inventory: Demo.inventory).contains { $0.port.node == out.id })
        XCTAssertFalse(KeyboardConnect.choices(for: deviceOut, graph: graph, inventory: looped).contains { $0.port.node == out.id })
    }

    func testArrowKeysMoveBetweenPorts() {
        let node = UUID()
        let ports = PortCounts(inputs: 2, outputs: 1)
        let input1 = PortEnd(node: node, channel: 1, isOutput: false)
        XCTAssertEqual(KeyboardConnect.neighbour(of: input1, ports: ports, up: true), PortEnd(node: node, channel: 0, isOutput: false))
        XCTAssertNil(KeyboardConnect.neighbour(of: input1, ports: ports, up: false), "the last input")
        XCTAssertEqual(KeyboardConnect.neighbour(of: input1, ports: ports, toOutputs: true), PortEnd(node: node, channel: 0, isOutput: true))
        XCTAssertNil(KeyboardConnect.neighbour(of: input1, ports: ports, toOutputs: false), "already on the inputs")
        XCTAssertNil(KeyboardConnect.neighbour(of: input1, ports: PortCounts(inputs: 2, outputs: 0), toOutputs: true))
        let source = Node(kind: .defaultInput)
        XCTAssertEqual(KeyboardConnect.firstPort(of: source, ports: PortCounts(inputs: 0, outputs: 2)),
                       PortEnd(node: source.id, channel: 0, isOutput: true))
        XCTAssertEqual(KeyboardConnect.firstPort(of: source, ports: PortCounts(inputs: 2, outputs: 2), preferOutputs: false),
                       PortEnd(node: source.id, channel: 0, isOutput: false))
        XCTAssertNil(KeyboardConnect.firstPort(of: source, ports: PortCounts(inputs: 0, outputs: 0)))
    }

    // MARK: VoiceOver

    func testAccessibilityLabelsAndValues() throws {
        var (graph, device, system, mic, speakers) = sample()
        var stream = Demo.streamMix
        stream.channelNames = ["Voice", ""]
        graph.virtualDevices = [stream]
        graph.nodes[graph.nodes.firstIndex { $0.id == mic.id }!].isMuted = true
        let info = NodeInfo(graph: graph, inventory: Demo.inventory)
        let mutedMic = try XCTUnwrap(graph.node(mic.id))

        XCTAssertEqual(CanvasAccessibility.nodeLabel(system, info: info), "System Audio, All apps")
        XCTAssertEqual(CanvasAccessibility.nodeLabel(mutedMic, info: info), "MacBook Pro Microphone, Audio device")
        XCTAssertEqual(CanvasAccessibility.nodeValue(system, info: info, isRunning: false, isFailing: false), "2 outputs, 2 cables")
        XCTAssertEqual(CanvasAccessibility.nodeValue(mutedMic, info: info, isRunning: false, isFailing: false, issues: 1),
                       "Muted, 1 output, 2 cables, 1 problem")
        XCTAssertEqual(CanvasAccessibility.nodeValue(device, info: info, isRunning: true, isFailing: false),
                       "2 inputs, 2 outputs, 6 cables, running")
        XCTAssertEqual(CanvasAccessibility.nodeValue(speakers, info: info, isRunning: true, isFailing: true),
                       "2 inputs, 2 cables, not working")

        // Ports: the device's own channel names, L/R for stereo, numbers otherwise.
        let deviceIn0 = PortEnd(node: device.id, channel: 0, isOutput: false)
        XCTAssertEqual(CanvasAccessibility.portLabel(deviceIn0, info: info), "Stream Mix, input 1 (Voice)")
        XCTAssertEqual(CanvasAccessibility.portLabel(PortEnd(node: device.id, channel: 1, isOutput: false), info: info),
                       "Stream Mix, input 2 (R)", "an empty name falls back to L/R")
        let systemL = PortEnd(node: system.id, channel: 0, isOutput: true)
        XCTAssertEqual(CanvasAccessibility.portLabel(systemL, info: info), "System Audio, output 1 (L)")
        XCTAssertEqual(CanvasAccessibility.portLabel(PortEnd(node: mic.id, channel: 0, isOutput: true), info: info),
                       "MacBook Pro Microphone, output 1")
        XCTAssertEqual(CanvasAccessibility.portValue(systemL, info: info), "Connected to Stream Mix, input 1 (Voice)")
        XCTAssertEqual(CanvasAccessibility.portValue(deviceIn0, info: info),
                       "Connected to System Audio, output 1 (L); MacBook Pro Microphone, output 1")
        graph.nodes.append(Node(kind: .defaultOutput, canvas: stream.id))
        let lonely = PortEnd(node: graph.nodes.last!.id, channel: 0, isOutput: false)
        XCTAssertEqual(CanvasAccessibility.portValue(lonely, info: NodeInfo(graph: graph, inventory: Demo.inventory)), "Not connected")

        // Cables and meters.
        let quiet = try XCTUnwrap(graph.cables.first { $0.gainDB == -6 })
        XCTAssertEqual(CanvasAccessibility.cableLabel(quiet, info: info), "Cable from System Audio, output 2 (R) to Stream Mix, input 2 (R)")
        XCTAssertEqual(CanvasAccessibility.cableValue(quiet, idle: false), "−6.0 dB")
        XCTAssertEqual(CanvasAccessibility.cableValue(quiet, idle: true), "−6.0 dB, not playing")
        XCTAssertEqual(CanvasAccessibility.meterLabel(systemL, info: info), "Output 1 (L) level")
        XCTAssertEqual(CanvasAccessibility.meterValue(0), "Silent")
        XCTAssertEqual(CanvasAccessibility.meterValue(0.0001), "Silent")
        XCTAssertEqual(CanvasAccessibility.meterValue(0.25), "−12 dB")
        XCTAssertEqual(CanvasAccessibility.meterValue(0.99), "0 dB")
        XCTAssertEqual(CanvasAccessibility.meterValue(1.2), "Clipping")
    }
}
