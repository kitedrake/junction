import XCTest
@testable import JunctionCore

final class EditingTests: XCTestCase {
    /// Stream Mix's canvas: System Audio and the mic feed it, the speakers play it. Chat's canvas: just its device.
    private func sample() -> (graph: Graph, system: Node, mic: Node, speakers: Node) {
        let a = Demo.streamMix.id, b = Demo.chat.id
        let device = Node(kind: .virtualDevice(a), x: CanvasColumn.device, y: 60, canvas: a)
        let system = Node(kind: .systemAudio(excluding: [Demo.discord]), x: 40, y: 40, canvas: a)
        let mic = Node(kind: .device(Demo.mic.ref), x: 40, y: 220, canvas: a)
        let speakers = Node(kind: .device(Demo.speakers.ref), x: 620, y: 60, canvas: a)
        let chatDevice = Node(kind: .virtualDevice(b), x: CanvasColumn.device, y: 60, canvas: b)
        func cable(_ x: Node, _ xc: Int, _ y: Node, _ yc: Int, _ dB: Double = 0) -> Cable {
            Cable(from: PortRef(node: x.id, channel: xc), to: PortRef(node: y.id, channel: yc), gainDB: dB)
        }
        let graph = Graph(virtualDevices: [Demo.streamMix, Demo.chat], nodes: [device, system, mic, speakers, chatDevice],
                          cables: [cable(system, 0, device, 0), cable(system, 1, device, 1, -6),
                                   cable(mic, 0, device, 0), cable(mic, 0, device, 1),
                                   cable(device, 0, speakers, 0), cable(device, 1, speakers, 1)])
        return (graph, system, mic, speakers)
    }

    /// A graph held the way the app holds it, edited through the history.
    private final class Holder {
        var graph: Graph
        lazy var history = EditHistory(read: { [unowned self] in graph }, write: { [unowned self] in graph = $0 })
        init(_ graph: Graph) { self.graph = graph }
    }

    func testUndoRestoresTheExactGraphAndRedoRepeats() {
        let start = sample()
        let holder = Holder(start.graph)
        let history = holder.history
        XCTAssertFalse(history.canUndo)
        history.perform("Remove") { Editing.remove([start.mic.id, start.speakers.id], from: &$0) }
        let removed = holder.graph
        history.perform("Tidy Up") { Editing.tidyUp(&$0, canvas: Demo.streamMix.id, inventory: Demo.inventory) }
        let tidied = holder.graph
        XCTAssertNotEqual(removed, tidied)
        XCTAssertEqual(history.undoName, "Tidy Up")

        history.undo()
        XCTAssertEqual(holder.graph, removed)
        history.undo()
        XCTAssertEqual(holder.graph, start.graph, "undo puts back every node, cable, ID and position")
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redoName, "Remove")
        history.redo()
        XCTAssertEqual(holder.graph, removed)
        history.redo()
        XCTAssertEqual(holder.graph, tidied)
        XCTAssertFalse(history.canRedo)

        // A new edit after an undo drops what could have been redone.
        history.undo()
        history.perform("Mute") { $0.nodes[1].isMuted = true }
        XCTAssertFalse(history.canRedo)
        history.undo()
        XCTAssertEqual(holder.graph, removed)
    }

    func testEditsThatChangeNothingAreNotRecorded() {
        let holder = Holder(sample().graph)
        XCTAssertFalse(holder.history.perform("Nothing") { _ in })
        XCTAssertFalse(holder.history.canUndo)
    }

    func testADragIsOneUndoStep() {
        let start = sample()
        let holder = Holder(start.graph)
        let history = holder.history
        let now = Date()
        for step in 1...20 {
            history.perform("Move", coalescing: "move", now: now.addingTimeInterval(Double(step) * 0.02)) {
                $0.nodes[1].x = 40 + Double(step)
            }
        }
        history.endCoalescing()
        history.perform("Move", coalescing: "move", now: now.addingTimeInterval(0.5)) { $0.nodes[1].y = 400 }
        history.undo()
        XCTAssertEqual(holder.graph.nodes[1].x, 60, "the second drag is its own step")
        history.undo()
        XCTAssertEqual(holder.graph, start.graph, "the whole first drag undoes at once")

        // A pause longer than the window starts a new step even with the same key.
        history.perform("Level", coalescing: "gain", now: now) { $0.cables[0].gainDB = -1 }
        history.perform("Level", coalescing: "gain", now: now.addingTimeInterval(EditHistory.coalescingWindow + 1)) {
            $0.cables[0].gainDB = -2
        }
        history.undo()
        XCTAssertEqual(holder.graph.cables[0].gainDB, -1)
    }

    func testCopyAndPasteOnTheSameCanvasRemapsIDs() throws {
        let start = sample()
        var graph = start.graph
        let canvas = Demo.streamMix.id
        let device = try XCTUnwrap(graph.deviceNode(canvas))
        // The device is selected too but never copied.
        let clipboard = try XCTUnwrap(Editing.copy([start.system.id, start.mic.id, device.id], from: graph))
        XCTAssertEqual(Set(clipboard.nodes.map(\.id)), [start.system.id, start.mic.id])
        XCTAssertEqual(clipboard.cables.count, 4, "the cables into the device come along")

        let pasted = Editing.paste(clipboard, into: &graph, canvas: canvas, inventory: Demo.inventory)
        XCTAssertEqual(pasted.count, 2)
        XCTAssertTrue(pasted.isDisjoint(with: Set(start.graph.nodes.map(\.id))), "pasted nodes get new IDs")
        let newCables = graph.cables.filter { pasted.contains($0.from.node) }
        XCTAssertEqual(newCables.count, 4)
        XCTAssertTrue(newCables.allSatisfy { $0.to.node == device.id }, "they still run into the canvas's device")
        XCTAssertTrue(Set(newCables.map(\.id)).isDisjoint(with: Set(start.graph.cables.map(\.id))))
        XCTAssertEqual(newCables.map(\.gainDB).sorted(), [-6, 0, 0, 0], "levels are kept")
        let copy = try XCTUnwrap(graph.nodes.first { pasted.contains($0.id) && $0.kind == start.system.kind })
        XCTAssertEqual(copy.x, start.system.x + Editing.pasteStep, "moved off the original")
        XCTAssertEqual(copy.canvas, canvas)

        // Pasting again moves further, so no two copies sit on top of each other.
        let again = Editing.paste(clipboard, into: &graph, canvas: canvas, inventory: Demo.inventory)
        let second = try XCTUnwrap(graph.nodes.first { again.contains($0.id) && $0.kind == start.system.kind })
        XCTAssertEqual(second.x, start.system.x + 2 * Editing.pasteStep)
        var tidy = graph
        tidy.tidyCanvases()
        XCTAssertEqual(tidy, graph, "the canvas stays consistent")
    }

    func testPasteOntoAnotherCanvasPlugsIntoThatDevice() throws {
        let start = sample()
        var graph = start.graph
        let clipboard = try XCTUnwrap(Editing.copy([start.system.id, start.speakers.id], from: graph))
        let chat = Demo.chat.id
        let pasted = Editing.paste(clipboard, into: &graph, canvas: chat, inventory: Demo.inventory)
        let chatDevice = try XCTUnwrap(graph.deviceNode(chat))
        XCTAssertEqual(graph.nodes(on: chat).count, 3)
        let cables = graph.cables(on: chat)
        XCTAssertEqual(cables.count, 4)
        XCTAssertTrue(cables.allSatisfy { ($0.from.node == chatDevice.id) != ($0.to.node == chatDevice.id) })
        XCTAssertTrue(cables.allSatisfy { pasted.contains($0.from.node) || pasted.contains($0.to.node) })
        XCTAssertEqual(graph.nodes(on: chat).first { $0.kind == start.system.kind }?.x, start.system.x, "nothing in the way")
        XCTAssertEqual(graph.cables(on: Demo.streamMix.id).count, 6, "the original canvas is untouched")
    }

    func testPasteDropsCablesThatBreakTheRulesOrLoop() throws {
        // On Stream Mix's canvas, a node standing for Chat (as a device) feeds Stream Mix: allowed there. Pasted onto
        // Chat's own canvas it would feed Chat into itself.
        let a = Demo.streamMix.id, b = Demo.chat.id
        let inventory = Demo.inventory
        let chatInfo = try XCTUnwrap(inventory.device(Demo.chat.uid))
        let wide = VirtualDevice(id: a, name: "Stream Mix", channels: 4)
        let device = Node(kind: .virtualDevice(a), x: CanvasColumn.device, y: 60, canvas: a)
        let chatNode = Node(kind: .device(chatInfo.ref), x: 40, y: 40, canvas: a)
        let interface = Node(kind: .device(Demo.interface.ref), x: 40, y: 220, canvas: a)
        let chatDevice = Node(kind: .virtualDevice(b), x: CanvasColumn.device, y: 60, canvas: b)
        var graph = Graph(virtualDevices: [wide, Demo.chat], nodes: [device, chatNode, interface, chatDevice])
        graph.cables = [
            Cable(from: PortRef(node: chatNode.id, channel: 0), to: PortRef(node: device.id, channel: 0)),
            Cable(from: PortRef(node: chatNode.id, channel: 1), to: PortRef(node: device.id, channel: 1)),
            // Channel 3 exists on Stream Mix (4 channels) but not on Chat (2).
            Cable(from: PortRef(node: interface.id, channel: 0), to: PortRef(node: device.id, channel: 3)),
            Cable(from: PortRef(node: interface.id, channel: 1), to: PortRef(node: device.id, channel: 1)),
        ]
        for cable in graph.cables {
            var without = graph
            without.cables.removeAll { $0.id == cable.id }
            XCTAssertNil(Rules.check(from: cable.from, to: cable.to, graph: without, inventory: inventory))
        }
        let clipboard = try XCTUnwrap(Editing.copy([chatNode.id, interface.id], from: graph))
        let pasted = Editing.paste(clipboard, into: &graph, canvas: b, inventory: inventory)
        XCTAssertEqual(pasted.count, 2, "the nodes come along")
        let cables = graph.cables(on: b)
        XCTAssertEqual(cables.count, 1, "Chat into itself (a loop) and the missing channel 4 are dropped")
        XCTAssertEqual(cables.first?.to, PortRef(node: chatDevice.id, channel: 1))
        for cable in cables {
            var without = graph
            without.cables.removeAll { $0.id == cable.id }
            XCTAssertNil(Rules.check(from: cable.from, to: cable.to, graph: without, inventory: inventory))
        }
    }

    func testCopyLeavesOutCablesToNodesNotSelected() throws {
        let start = sample()
        let clipboard = try XCTUnwrap(Editing.copy([start.speakers.id], from: start.graph))
        XCTAssertEqual(clipboard.nodes.count, 1)
        XCTAssertEqual(clipboard.cables.count, 2, "only the device's cables to the speakers")
        XCTAssertNil(Editing.copy([], from: start.graph))
        let device = try XCTUnwrap(start.graph.deviceNode(Demo.streamMix.id))
        XCTAssertNil(Editing.copy([device.id], from: start.graph), "a canvas's device can't be copied")
        // Survives the pasteboard.
        let data = try JSONEncoder().encode(clipboard)
        XCTAssertEqual(try JSONDecoder().decode(Clipboard.self, from: data), clipboard)
    }

    func testRemovingASelectionKeepsTheDevice() throws {
        let start = sample()
        var graph = start.graph
        let device = try XCTUnwrap(graph.deviceNode(Demo.streamMix.id))
        XCTAssertTrue(Editing.remove([start.system.id, start.mic.id, device.id], from: &graph))
        XCTAssertNotNil(graph.node(device.id))
        XCTAssertNil(graph.node(start.system.id))
        XCTAssertEqual(graph.cables.count, 2, "only the speakers' cables are left")
        XCTAssertFalse(Editing.remove([device.id], from: &graph))
    }

    func testTidyUpLeavesNoOverlap() throws {
        var graph = sample().graph
        let canvas = Demo.streamMix.id
        let otherCanvas = graph.nodes(on: Demo.chat.id)
        // Pile everything up in one spot, with an unwired source and an unwired output.
        graph.nodes.append(Node(kind: .application(Demo.discord), canvas: canvas))
        graph.nodes.append(Node(kind: .defaultOutput, canvas: canvas))
        graph.nodes.append(Node(kind: .device(Demo.interface.ref), canvas: canvas))
        for index in graph.nodes.indices where graph.nodes[index].canvas == canvas {
            graph.nodes[index].x = 200
            graph.nodes[index].y = 200
        }
        Editing.tidyUp(&graph, canvas: canvas, inventory: Demo.inventory)
        let info = NodeInfo(graph: graph, inventory: Demo.inventory)
        let nodes = graph.nodes(on: canvas)
        let frames = nodes.map { CanvasMetrics.frame($0, info.ports($0)) }
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertFalse(frames[i].intersects(frames[j]), "\(info.title(nodes[i])) overlaps \(info.title(nodes[j]))")
            }
        }
        func column(_ kind: NodeKind) -> Double? { nodes.first { $0.kind == kind }?.x }
        XCTAssertEqual(column(.virtualDevice(canvas)), CanvasColumn.device)
        XCTAssertEqual(column(.systemAudio(excluding: [Demo.discord])), CanvasColumn.sources)
        XCTAssertEqual(column(.application(Demo.discord)), CanvasColumn.sources, "an unwired app is a source")
        XCTAssertEqual(column(.device(Demo.mic.ref)), CanvasColumn.sources)
        XCTAssertEqual(column(.device(Demo.speakers.ref)), CanvasColumn.outputs)
        XCTAssertEqual(column(.defaultOutput), CanvasColumn.outputs)
        XCTAssertEqual(column(.device(Demo.interface.ref)), CanvasColumn.outputs, "an unwired interface can be played")
        XCTAssertEqual(graph.nodes(on: Demo.chat.id), otherCanvas, "other canvases stay")

        var again = graph
        Editing.tidyUp(&again, canvas: canvas, inventory: Demo.inventory)
        XCTAssertEqual(again, graph, "tidying a tidy canvas changes nothing")
    }

    func testEffectLabelsMakeANodeTallerAndTidyUpLeavesRoomForThem() throws {
        var (graph, system, mic, _) = sample()
        let canvas = Demo.streamMix.id
        let info = NodeInfo(graph: graph, inventory: Demo.inventory)
        let plain = CanvasMetrics.height(system, info.ports(system))
        let index = try XCTUnwrap(graph.nodes.firstIndex { $0.id == system.id })
        graph.nodes[index].effects = [Effect(.highPass), Effect(.gate)]
        let withEffects = graph.nodes[index]
        XCTAssertEqual(CanvasMetrics.height(withEffects, info.ports(withEffects)), plain + CanvasMetrics.effectsRow)
        XCTAssertEqual(CanvasMetrics.frame(withEffects, info.ports(withEffects)).height, plain + CanvasMetrics.effectsRow)
        let micPorts = info.ports(mic)
        XCTAssertEqual(CanvasMetrics.height(mic, micPorts),
                       CanvasMetrics.header + CanvasMetrics.topPadding + Double(CanvasMetrics.rows(micPorts)) * CanvasMetrics.row
                           + CanvasMetrics.bottomPadding, "a node without effects has no label row")

        Editing.tidyUp(&graph, canvas: canvas, inventory: Demo.inventory)
        let tidied = try XCTUnwrap(graph.nodes.first { $0.id == system.id })
        let below = try XCTUnwrap(graph.nodes.first { $0.id == mic.id })
        XCTAssertEqual(below.y, tidied.y + plain + CanvasMetrics.effectsRow + CanvasMetrics.gap,
                       "the next node in the column starts below the labels")
    }

    func testFaderMovesAreHeardBeforeTheGraphChangesAndKeepTheLatestPerFader() throws {
        let (graph, system, mic, _) = sample()
        let cable = try XCTUnwrap(graph.cables.first { $0.from.node == mic.id })
        var moves = FaderMoves()
        func level(_ id: UUID, _ dB: Double) -> (inout Graph) -> Void {
            { graph in if let index = graph.nodes.firstIndex(where: { $0.id == id }) { graph.nodes[index].gainDB = dB } }
        }
        moves.record("level mic", "Change Level", level(mic.id, -3))
        moves.record("cable", "Change Level", undoable: false) { graph in
            if let index = graph.cables.firstIndex(where: { $0.id == cable.id }) { graph.cables[index].gainDB = -12 }
        }
        moves.record("level system", "Change Level", level(system.id, -6))
        moves.record("level mic", "Change Level", level(mic.id, -9))  // the same fader again: replaces its first move

        XCTAssertEqual(moves.moves.map(\.key), ["level mic", "cable", "level system"], "one move per fader, in the order they started")
        XCTAssertEqual(moves.moves.map(\.undoable), [true, false, true])
        let heard = moves.applied(to: graph)
        XCTAssertEqual(heard.node(mic.id)?.gainDB, -9)
        XCTAssertEqual(heard.node(system.id)?.gainDB, -6)
        XCTAssertEqual(heard.cables.first { $0.id == cable.id }?.gainDB, -12)
        XCTAssertEqual(graph.node(mic.id)?.gainDB, 0, "the graph itself waits")

        let taken = moves.take()
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(moves.applied(to: graph), graph)
        var written = graph
        for move in taken { move.change(&written) }
        XCTAssertEqual(written, heard, "writing the moves gives what was heard")
    }

    func testSelection() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertNil(CanvasSelection.of([]))
        XCTAssertEqual(CanvasSelection.of([a]), .node(a))
        XCTAssertEqual(CanvasSelection.toggling(b, in: .node(a)), .nodes([a, b]))
        XCTAssertEqual(CanvasSelection.toggling(b, in: .nodes([a, b])), .node(a))
        XCTAssertNil(CanvasSelection.toggling(a, in: .node(a)))
        XCTAssertEqual(CanvasSelection.toggling(a, in: .cable(c)), .node(a), "⇧-click replaces a selected cable")
        XCTAssertEqual(CanvasSelection.boxed([b, c], extending: .node(a)), .nodes([a, b, c]))
        XCTAssertEqual(CanvasSelection.boxed([b], extending: nil), .node(b))

        let start = sample()
        XCTAssertEqual(CanvasSelection.nodes([start.system.id, a]).pruned(to: start.graph), .node(start.system.id))
        XCTAssertNil(CanvasSelection.cable(a).pruned(to: start.graph))
        let box = CGRect(x: 0, y: 0, width: 100, height: 400)
        XCTAssertEqual(Editing.nodes(in: box, canvas: Demo.streamMix.id, graph: start.graph, inventory: Demo.inventory),
                       [start.system.id, start.mic.id])
    }
}
