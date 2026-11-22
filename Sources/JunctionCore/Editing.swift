import Foundation

// Canvas editing that doesn't depend on the window: what is selected, copying and pasting nodes with their cables,
// removing a selection, tidying a canvas, and undo and redo of every edit.

/// What is selected on the shown canvas: one node, several nodes, or a cable.
public enum CanvasSelection: Hashable, Sendable {
    case node(UUID)
    /// Two or more nodes (a drag box, or ⇧-clicks).
    case nodes(Set<UUID>)
    case cable(UUID)

    /// One node as `.node`, several as `.nodes`, none as nil.
    public static func of(_ nodes: Set<UUID>) -> CanvasSelection? {
        switch nodes.count {
        case 0: nil
        case 1: .node(nodes.first!)
        default: .nodes(nodes)
        }
    }

    /// The selected nodes (none for a cable).
    public var nodeIDs: Set<UUID> {
        switch self {
        case .node(let id): [id]
        case .nodes(let ids): ids
        case .cable: []
        }
    }

    public func contains(node id: UUID) -> Bool { nodeIDs.contains(id) }

    /// ⇧-click: adds a node to the selection, or takes it out if it was in. A selected cable is replaced.
    public static func toggling(_ node: UUID, in selection: CanvasSelection?) -> CanvasSelection? {
        var ids = selection?.nodeIDs ?? []
        if ids.remove(node) == nil { ids.insert(node) }
        return of(ids)
    }

    /// A drag box: the nodes it touches, added to the nodes already selected when `extending` (⇧ held).
    public static func boxed(_ nodes: Set<UUID>, extending selection: CanvasSelection?) -> CanvasSelection? {
        of(nodes.union(selection?.nodeIDs ?? []))
    }

    /// The same selection without the nodes and cables that are gone from `graph`.
    public func pruned(to graph: Graph) -> CanvasSelection? {
        switch self {
        case .cable(let id): graph.cables.contains { $0.id == id } ? self : nil
        default: CanvasSelection.of(nodeIDs.filter { graph.node($0) != nil })
        }
    }
}

/// Node geometry on a canvas, shared by the window (drawing, hit-testing) and by tidying up.
public enum CanvasMetrics {
    public static let nodeWidth = 236.0
    public static let header = 54.0
    public static let row = 24.0
    public static let topPadding = 6.0
    public static let bottomPadding = 10.0
    /// The row of effect labels under the channels, on nodes that have effects.
    public static let effectsRow = 24.0
    /// Space left between nodes stacked in a column.
    public static let gap = 30.0
    /// Where the first node of a column starts.
    public static let top = 40.0

    public static func rows(_ ports: PortCounts) -> Int { max(1, max(ports.inputs, ports.outputs)) }

    public static func height(_ node: Node, _ ports: PortCounts) -> Double {
        header + topPadding + Double(rows(ports)) * row + bottomPadding + (node.effects.isEmpty ? 0 : effectsRow)
    }

    public static func frame(_ node: Node, _ ports: PortCounts) -> CGRect {
        CGRect(x: node.x, y: node.y, width: nodeWidth, height: height(node, ports))
    }
}

/// Nodes and the cables between them, copied off a canvas. The canvas's own virtual device is never copied: cables
/// into or out of it are kept, and plug into the device of the canvas they are pasted onto.
public struct Clipboard: Codable, Equatable, Sendable {
    public var nodes: [Node]
    public var cables: [Cable]
    /// The device node the cables to and from the canvas's device used.
    public var device: UUID?

    public static let pasteboardType = "local.junction.nodes"

    public init(nodes: [Node], cables: [Cable], device: UUID?) {
        self.nodes = nodes
        self.cables = cables
        self.device = device
    }
}

public enum Editing {
    /// How far each paste moves from nodes that are already in the same place.
    public static let pasteStep = 30.0

    /// Whether a node is the virtual device its canvas stands for (it can't be copied or removed from the canvas).
    public static func isDeviceNode(_ node: Node) -> Bool {
        if case .virtualDevice = node.kind { return true }
        return false
    }

    /// Copies the selected nodes (their canvas's virtual device left out) with the cables between them and to or from
    /// that device. Nil when nothing copyable is selected.
    public static func copy(_ ids: Set<UUID>, from graph: Graph) -> Clipboard? {
        let nodes = graph.nodes.filter { ids.contains($0.id) && !isDeviceNode($0) }
        guard let canvas = nodes.first?.canvas else { return nil }
        let picked = nodes.filter { $0.canvas == canvas }
        let device = graph.deviceNode(canvas)?.id
        let kept = Set(picked.map(\.id)).union(device.map { [$0] } ?? [])
        let cables = graph.cables.filter { kept.contains($0.from.node) && kept.contains($0.to.node) }
        return Clipboard(nodes: picked, cables: cables, device: device)
    }

    /// Pastes onto a canvas: every node and cable gets a new ID, cables to the copied device go to this canvas's
    /// device, and cables that Rules.check refuses here (a missing channel, a loop) are dropped. The nodes move down
    /// and right while they would land exactly on nodes already there. Returns the new nodes' IDs.
    @discardableResult
    public static func paste(_ clipboard: Clipboard, into graph: inout Graph, canvas: UUID, inventory: Inventory) -> Set<UUID> {
        guard let device = graph.deviceNode(canvas), !clipboard.nodes.isEmpty else { return [] }
        let existing = graph.nodes(on: canvas)
        func occupied(_ offset: Double) -> Bool {
            clipboard.nodes.contains { node in
                existing.contains { abs($0.x - (node.x + offset)) < 1 && abs($0.y - (node.y + offset)) < 1 }
            }
        }
        var offset = 0.0
        while occupied(offset) { offset += pasteStep }
        var ids: [UUID: UUID] = [:]
        if let copied = clipboard.device { ids[copied] = device.id }
        for node in clipboard.nodes {
            var copy = node
            copy.id = UUID()
            copy.canvas = canvas
            copy.x = max(0, node.x + offset)
            copy.y = max(0, node.y + offset)
            for index in copy.effects.indices { copy.effects[index].id = UUID() }  // its own units, not the original's
            ids[node.id] = copy.id
            graph.nodes.append(copy)
        }
        for cable in clipboard.cables {
            guard let from = ids[cable.from.node], let to = ids[cable.to.node] else { continue }
            let pasted = Cable(from: PortRef(node: from, channel: cable.from.channel),
                               to: PortRef(node: to, channel: cable.to.channel), gainDB: cable.gainDB)
            guard Rules.check(from: pasted.from, to: pasted.to, graph: graph, inventory: inventory) == nil else { continue }
            graph.cables.append(pasted)
        }
        return Set(clipboard.nodes.compactMap { ids[$0.id] })
    }

    /// Removes the selected nodes and their cables, with their MIDI mappings; a canvas's virtual device stays (deleting
    /// it is a separate, confirmed step). Returns whether anything went.
    @discardableResult
    public static func remove(_ ids: Set<UUID>, from graph: inout Graph) -> Bool {
        let gone = Set(graph.nodes.filter { ids.contains($0.id) && !isDeviceNode($0) }.map(\.id))
        guard !gone.isEmpty else { return false }
        graph.nodes.removeAll { gone.contains($0.id) }
        graph.cables.removeAll { gone.contains($0.from.node) || gone.contains($0.to.node) }
        graph.pruneMIDI()
        return true
    }

    /// Puts a node onto a cable it was dropped on. The cable stands for its whole run: every cable between the same two
    /// nodes (a stereo pair). Where Rules.check allows each half, the node goes into the run's path (A → node → B, the
    /// run removed). Otherwise it joins the run on the device's side: a node dropped on cables into the device feeds
    /// the same device channels, one dropped on cables out of it plays the same channels. Cables that are already
    /// there are skipped; any other refusal (a missing side, a feedback loop) leaves the graph unchanged and is
    /// returned.
    @discardableResult
    public static func insert(_ node: UUID, onto cable: UUID, graph: inout Graph, inventory: Inventory) -> Rules.Problem? {
        guard let hit = graph.cables.first(where: { $0.id == cable }), let dropped = graph.node(node),
              let canvas = dropped.canvas, graph.node(hit.from.node)?.canvas == canvas
        else { return .noSuchPort }
        let a = hit.from.node, b = hit.to.node
        if node == a || node == b { return .alreadyConnected }
        let run = graph.cables.filter { $0.from.node == a && $0.to.node == b }
        let ports = NodeInfo(graph: graph, inventory: inventory).ports(dropped)

        /// Adds cables one at a time, each checked against the ones before; all or nothing.
        func adding(_ pairs: [(from: PortRef, to: PortRef, gainDB: Double)], to start: Graph) -> (Graph?, Rules.Problem?) {
            var working = start
            var added = false
            for pair in pairs {
                switch Rules.check(from: pair.from, to: pair.to, graph: working, inventory: inventory) {
                case nil:
                    working.cables.append(Cable(from: pair.from, to: pair.to, gainDB: pair.gainDB))
                    added = true
                case .alreadyConnected?: continue
                case let problem?: return (nil, problem)
                }
            }
            return added ? (working, nil) : (nil, .alreadyConnected)
        }

        // Into the path: A → node → B, with the run's levels kept on the first half.
        var spliceProblem: Rules.Problem = .noSuchPort
        if ports.inputs > 0, ports.outputs > 0 {
            var without = graph
            without.cables.removeAll { run.map(\.id).contains($0.id) }
            var pairs: [(from: PortRef, to: PortRef, gainDB: Double)] = []
            for cable in run {
                let input = min(cable.to.channel, ports.inputs - 1), output = min(cable.to.channel, ports.outputs - 1)
                pairs.append((cable.from, PortRef(node: node, channel: input), cable.gainDB))
                pairs.append((PortRef(node: node, channel: output), cable.to, 0))
            }
            let (spliced, problem) = adding(pairs, to: without)
            if let spliced {
                graph = spliced
                return nil
            }
            spliceProblem = problem ?? .noSuchPort
        }

        // Alongside, on the device's side of the run.
        guard let device = graph.deviceNode(canvas)?.id, a == device || b == device else { return spliceProblem }
        var pairs: [(from: PortRef, to: PortRef, gainDB: Double)] = []
        if b == device {
            guard ports.outputs > 0 else { return .noSuchPort }
            pairs = run.map { (PortRef(node: node, channel: min($0.from.channel, ports.outputs - 1)), $0.to, 0) }
        } else {
            guard ports.inputs > 0 else { return .noSuchPort }
            pairs = run.map { ($0.from, PortRef(node: node, channel: min($0.to.channel, ports.inputs - 1)), 0) }
        }
        let (joined, problem) = adding(pairs, to: graph)
        guard let joined else { return problem }
        graph = joined
        return nil
    }

    /// The nodes on a canvas whose frames touch a rectangle (a drag box).
    public static func nodes(in rect: CGRect, canvas: UUID, graph: Graph, inventory: Inventory) -> Set<UUID> {
        let info = NodeInfo(graph: graph, inventory: inventory)
        return Set(graph.nodes(on: canvas).filter { CanvasMetrics.frame($0, info.ports($0)).intersects(rect) }.map(\.id))
    }

    /// Tidy Up: sources (what feeds the device, or unwired nodes that only provide audio) in a column on the left, the
    /// virtual device in the middle, outputs on the right. Each column keeps its top-to-bottom order and its nodes
    /// sit one under the other, so nothing overlaps.
    public static func tidyUp(_ graph: inout Graph, canvas: UUID, inventory: Inventory) {
        guard let device = graph.deviceNode(canvas) else { return }
        let info = NodeInfo(graph: graph, inventory: inventory)
        var sources: [Node] = [], outputs: [Node] = []
        for node in graph.nodes(on: canvas) where node.id != device.id {
            let feeds = graph.cables.contains { $0.from.node == node.id && $0.to.node == device.id }
            let plays = graph.cables.contains { $0.from.node == device.id && $0.to.node == node.id }
            let ports = info.ports(node)
            if feeds || (!plays && ports.inputs == 0 && ports.outputs > 0) { sources.append(node) } else { outputs.append(node) }
        }
        var positions: [UUID: (Double, Double)] = [:]
        func stack(_ column: [Node], x: Double) -> Double {
            var y = CanvasMetrics.top
            for node in column.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                positions[node.id] = (x, y)
                y += CanvasMetrics.height(node, info.ports(node)) + CanvasMetrics.gap
            }
            return y - CanvasMetrics.gap - CanvasMetrics.top
        }
        let tallest = max(stack(sources, x: CanvasColumn.sources), stack(outputs, x: CanvasColumn.outputs))
        let deviceHeight = CanvasMetrics.height(device, info.ports(device))
        positions[device.id] = (CanvasColumn.device, CanvasMetrics.top + max(0, (tallest - deviceHeight) / 2).rounded())
        for index in graph.nodes.indices {
            guard let (x, y) = positions[graph.nodes[index].id] else { continue }
            graph.nodes[index].x = x
            graph.nodes[index].y = y
        }
    }
}

/// Undo and redo for the graph. Every edit runs through `perform`, which registers the graph as it was with an
/// `UndoManager`; undoing puts that graph back and registers the one it replaced for redo.
///
/// A stream of edits with the same coalescing key (a node being dragged, a fader moving) makes one undo step, until
/// `endCoalescing` is called or `coalescingWindow` passes without an edit.
public final class EditHistory {
    public let undoManager = UndoManager()
    public static let coalescingWindow: TimeInterval = 1.5
    private let read: () -> Graph
    private let write: (Graph) -> Void
    private var lastKey: String?
    private var lastTime = Date.distantPast

    /// `read` gives the current graph; `write` replaces it (on undo and redo).
    public init(read: @escaping () -> Graph, write: @escaping (Graph) -> Void) {
        self.read = read
        self.write = write
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 200
    }

    /// Applies an edit. Nothing is registered when it changes nothing. Returns whether the graph changed.
    @discardableResult
    public func perform(_ name: String, coalescing key: String? = nil, now: Date = Date(), _ change: (inout Graph) -> Void) -> Bool {
        let before = read()
        var after = before
        change(&after)
        guard after != before else { return false }
        if key == nil || key != lastKey || now.timeIntervalSince(lastTime) > Self.coalescingWindow || !undoManager.canUndo {
            register(name, restoring: before)
        }
        lastKey = key
        lastTime = now
        write(after)
        return true
    }

    /// The next edit starts a new undo step even if it has the same key (a drag or a fader let go).
    public func endCoalescing() { lastKey = nil }

    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }
    public var undoName: String { undoManager.undoActionName }
    public var redoName: String { undoManager.redoActionName }

    public func undo() {
        guard canUndo else { return }
        lastKey = nil
        undoManager.undo()
    }

    public func redo() {
        guard canRedo else { return }
        lastKey = nil
        undoManager.redo()
    }

    /// Forgets every step (a different graph was loaded).
    public func clear() {
        undoManager.removeAllActions()
        lastKey = nil
    }

    private func register(_ name: String, restoring graph: Graph) {
        // While undoing or redoing the manager has a group open already (for the opposite stack).
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { history in
            let current = history.read()
            history.register(name, restoring: current)
            history.write(graph)
        }
        undoManager.setActionName(name)
        if grouping { undoManager.endUndoGrouping() }
    }
}

/// Fader moves not written to the graph yet: while a fader moves, the app plays and shows its value at once and writes
/// the graph only when it is let go, because changing the graph redraws most of the window. Keeps the latest move of
/// each fader, in the order the faders started moving.
public struct FaderMoves {
    public struct Move {
        /// Which fader (a second move of the same fader replaces the first).
        public let key: String
        /// The undo step's name.
        public let name: String
        /// A move from a MIDI controller isn't an undo step: the controller still shows where it is.
        public let undoable: Bool
        public let change: (inout Graph) -> Void
    }

    public private(set) var moves: [Move] = []

    public init() {}

    public var isEmpty: Bool { moves.isEmpty }

    public mutating func record(_ key: String, _ name: String, undoable: Bool = true, _ change: @escaping (inout Graph) -> Void) {
        let move = Move(key: key, name: name, undoable: undoable, change: change)
        if let index = moves.firstIndex(where: { $0.key == key }) {
            moves[index] = move
        } else {
            moves.append(move)
        }
    }

    /// The graph as it is heard: `graph` with every move.
    public func applied(to graph: Graph) -> Graph {
        var heard = graph
        for move in moves { move.change(&heard) }
        return heard
    }

    /// Hands over the moves to write them to the graph, and forgets them.
    public mutating func take() -> [Move] {
        defer { moves = [] }
        return moves
    }
}
