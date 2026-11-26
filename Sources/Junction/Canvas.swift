import AppKit
import JunctionCore
import SwiftUI

/// Node geometry, shared by drawing and hit-testing so cables meet the ports exactly.
enum NodeLayout {
    static let width = CGFloat(CanvasMetrics.nodeWidth)
    static let header = CGFloat(CanvasMetrics.header)
    static let row = CGFloat(CanvasMetrics.row)
    static let topPadding = CGFloat(CanvasMetrics.topPadding)
    static let bottomPadding = CGFloat(CanvasMetrics.bottomPadding)
    static let effectsRow = CGFloat(CanvasMetrics.effectsRow)
    static let portRadius: CGFloat = 6

    static func rows(_ ports: PortCounts) -> Int { CanvasMetrics.rows(ports) }

    static func height(_ node: Node, _ ports: PortCounts) -> CGFloat { CGFloat(CanvasMetrics.height(node, ports)) }

    static func origin(_ node: Node) -> CGPoint { CGPoint(x: node.x, y: node.y) }

    static func inputPoint(_ node: Node, _ channel: Int) -> CGPoint { CanvasGeometry.inputPoint(node, channel) }

    static func outputPoint(_ node: Node, _ channel: Int) -> CGPoint { CanvasGeometry.outputPoint(node, channel) }

    static func point(_ end: PortEnd, _ node: Node) -> CGPoint {
        end.isOutput ? outputPoint(node, end.port.channel) : inputPoint(node, end.port.channel)
    }

    /// The "all channels" handles beside the header.
    static func busOutputPoint(_ node: Node) -> CGPoint { CGPoint(x: node.x + width, y: node.y + header / 2) }
    static func busInputPoint(_ node: Node) -> CGPoint { CGPoint(x: node.x, y: node.y + header / 2) }

    static func frame(_ node: Node, _ ports: PortCounts) -> CGRect { CanvasMetrics.frame(node, ports) }
}

/// What the user is dragging out of a port.
struct PendingWire: Equatable {
    enum Start: Equatable {
        case output(PortRef)
        case input(PortRef)
        case busOutput(UUID)
        case busInput(UUID)
        /// A cable picked up by its input end: drop it on another input to move it, anywhere empty to remove it.
        case moving(Cable)
    }

    var start: Start
    var location: CGPoint
}

/// A sidebar row being dragged onto the canvas. It travels as text (prefixed, so other text isn't taken for one).
struct PaletteItem: Codable, Transferable {
    var kind: NodeKind
    var role: NodeRole?

    private static let prefix = "junction-node:"

    var text: String { Self.prefix + ((try? JSONEncoder().encode(self)).map { $0.base64EncodedString() } ?? "") }

    init(kind: NodeKind, role: NodeRole?) {
        self.kind = kind
        self.role = role
    }

    init(text: String) throws {
        guard text.hasPrefix(Self.prefix), let data = Data(base64Encoded: String(text.dropFirst(Self.prefix.count))) else {
            throw CocoaError(.coderReadCorrupt)
        }
        self = try JSONDecoder().decode(PaletteItem.self, from: data)
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text, importing: { try PaletteItem(text: $0) })
    }
}

/// The canvas: nodes and cables, zoomed and panned (scroll, pinch, ⌘+ and ⌘−, dragging empty canvas), with a minimap.
/// Everything inside the zoomed layer works in canvas coordinates (the "canvas" coordinate space); the background and
/// the window's events are in view coordinates and go through the viewport.
struct CanvasView: View {
    @Environment(AppModel.self) private var model
    @State private var wire: PendingWire?
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @State private var refusal: String?
    @State private var refusalTask: Task<Void, Never>?
    /// The drag box being drawn on empty canvas, in canvas coordinates.
    @State private var box: (start: CGPoint, end: CGPoint)?
    /// A drag on empty canvas: panning from where the view was, or drawing a box (⇧ or ⌘ held when it started).
    @State private var emptyDrag: EmptyDrag?
    /// Where the pointer last was over the canvas (canvas coordinates), for the right-click menu. Not observed:
    /// hovering mustn't redraw.
    @State private var pointer = PointerSpot()
    /// The port whose "connect to" list is open.
    @State private var connecting: PortEnd?
    @FocusState private var focused: Bool
    @FocusState private var focusedPort: PortEnd?

    private enum EmptyDrag {
        case pan(CanvasViewport)
        case box
    }

    var body: some View {
        let info = model.info
        let size = model.canvasContentSize
        let viewport = model.viewport
        GridBackground(viewport: viewport)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let point = viewport.contentPoint(location)
                // The same few points on screen at any zoom.
                if let cable = CanvasGeometry.cable(at: point, among: model.canvasCables, graph: model.graph,
                                                    tolerance: CanvasGeometry.clickTolerance / viewport.scale) {
                    model.selection = .cable(cable)
                } else if !NSEvent.modifierFlags.contains(.shift) {
                    model.selection = nil
                }
                focused = true
            }
            .gesture(emptyDragGesture)
            .onContinuousHover { phase in
                if case .active(let location) = phase { pointer.location = model.viewport.contentPoint(location) }
            }
            .contextMenu {
                // New nodes go where the menu was opened, header under the pointer.
                AddMenuItems(spot: { [pointer] in pointer.location.map(CanvasGeometry.dropOrigin) })
                Divider()
                Button("Paste") { model.paste() }
                    .disabled(!model.canPaste)
                Button("Select All") { model.selectAll() }
                Button("Tidy Up") { model.tidyUp() }
                Divider()
                Button("Zoom to Fit") { model.zoomToFit() }
                Button("Actual Size") { model.zoomToActualSize() }
            }
            .overlay(alignment: .topLeading) {
                content(info: info)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .coordinateSpace(.named("canvas"))
                    .scaleEffect(viewport.scale, anchor: .topLeading)
                    .offset(x: -viewport.origin.x * viewport.scale, y: -viewport.origin.y * viewport.scale)
            }
            .background {
                CanvasEventCatcher(
                    onPan: { delta in model.viewport = model.viewport.panned(by: delta) },
                    onZoom: { factor, location in model.viewport = model.viewport.zoomed(by: factor, about: location) })
            }
            .dropDestination(for: PaletteItem.self) { items, location in
                guard let item = items.first else { return false }
                if let problem = model.drop(item.kind, as: item.role, at: model.viewport.contentPoint(location)) { refuse(problem) }
                focused = true
                return true
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                model.canvasViewSize = size
                model.viewport = model.viewport  // stays within reach of the new size
            }
            .overlay(alignment: .bottomTrailing) {
                if model.showMinimap, model.canvasNodes.count > 1 {
                    MinimapView()
                        .padding(14)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onDeleteCommand { model.deleteSelection() }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .return]) { press in
                // From a selected node into its ports: → or Return its outputs, ← its inputs.
                guard focused, case .node(let id) = model.selection, let node = model.node(id),
                      let port = KeyboardConnect.firstPort(of: node, ports: model.info.ports(node),
                                                           preferOutputs: press.key != .leftArrow) else { return .ignored }
                focusedPort = port
                return .handled
            }
            .onKeyPress(characters: ["="]) { press in
                // ⌘= zooms in too, as ⌘+ does without ⇧.
                guard press.modifiers == .command else { return .ignored }
                model.zoom(in: true)
                return .handled
            }
            .onChange(of: model.selection) { _, selection in
                if selection != nil, focusedPort == nil { focused = true }
            }
            .onChange(of: model.canvas) { _, _ in
                connecting = nil
                focusedPort = nil
            }
            .overlay(alignment: .bottom) {
                if let refusal {
                    Text(refusal)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: refusal)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.canvasDevice.map { "\($0.name) canvas" } ?? "Canvas")
            .accessibilityValue("Zoom \(viewport.percentText)")
    }

    /// The zoomed layer: cables, nodes and the drag box, in canvas coordinates.
    private func content(info: NodeInfo) -> some View {
        ZStack(alignment: .topLeading) {
            CableLayer(wire: wire)
                .allowsHitTesting(false)
            CableAccessibilityLayer()
            ForEach(model.canvasNodes) { node in
                NodeCard(node: node, wire: $wire, focusedPort: $focusedPort, connecting: $connecting,
                         onWireEnd: finishWire, onConnected: { problem in
                             if let problem { refuse(problem.message) }
                         }, onMove: { translation in
                    // Dragging a selected node moves the whole selection.
                    if dragOrigins.isEmpty {
                        let moving = model.isSelected(node.id) ? model.selectedNodes : [node.id]
                        for other in model.canvasNodes where moving.contains(other.id) {
                            dragOrigins[other.id] = CGPoint(x: other.x, y: other.y)
                        }
                    }
                    model.dragNodes(from: dragOrigins, by: translation)
                }, onMoveEnd: {
                    let moved = model.endNodeDrag()
                    dragOrigins = [:]
                    // One unwired node let go over a cable goes onto it.
                    if moved.count == 1, let id = moved.first, let problem = model.insertOnCable(id) { refuse(problem) }
                }, onEscape: {
                    focusedPort = nil
                    focused = true
                })
                .modifier(NodePlacement(node: node))
            }
            if let box {
                let frame = rect(box.start, box.end)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1 / model.viewport.scale)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Dragging empty canvas pans it; with ⇧ (adding to the selection) or ⌘ it draws a selection box.
    private var emptyDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if emptyDrag == nil {
                    let flags = NSEvent.modifierFlags
                    emptyDrag = flags.contains(.shift) || flags.contains(.command) ? .box : .pan(model.viewport)
                }
                switch emptyDrag {
                case .pan(let start)?:
                    model.viewport = start.panned(by: value.translation)
                case .box?:
                    let viewport = model.viewport
                    box = (viewport.contentPoint(value.startLocation), viewport.contentPoint(value.location))
                case nil:
                    break
                }
            }
            .onEnded { value in
                if case .box? = emptyDrag {
                    let viewport = model.viewport
                    model.selectNodes(in: rect(viewport.contentPoint(value.startLocation), viewport.contentPoint(value.location)),
                                      extending: NSEvent.modifierFlags.contains(.shift))
                }
                box = nil
                emptyDrag = nil
                focused = true
            }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Shows why something wasn't done at the bottom of the canvas for a moment.
    private func refuse(_ message: String) {
        refusal = message
        refusalTask?.cancel()
        refusalTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            refusal = nil
        }
    }

    /// Ends a wire drag: connects to the port (or node) under the pointer.
    private func finishWire(_ wire: PendingWire) {
        let info = model.info
        let point = wire.location
        func nearest(inputs: Bool) -> PortRef? {
            var best: (PortRef, CGFloat)?
            for node in model.canvasNodes {
                let ports = info.ports(node)
                for channel in 0..<(inputs ? ports.inputs : ports.outputs) {
                    let p = inputs ? NodeLayout.inputPoint(node, channel) : NodeLayout.outputPoint(node, channel)
                    let distance = hypot(p.x - point.x, p.y - point.y)
                    if distance < 16, distance < (best?.1 ?? .infinity) { best = (PortRef(node: node.id, channel: channel), distance) }
                }
            }
            return best?.0
        }
        func nodeUnderPointer() -> Node? {
            model.canvasNodes.last { NodeLayout.frame($0, info.ports($0)).insetBy(dx: -12, dy: -6).contains(point) }
        }
        var problem: Rules.Problem?
        var attempted = true
        switch wire.start {
        case .output(let from):
            if let to = nearest(inputs: true) {
                problem = model.connect(from: from, to: to)
            } else if let target = nodeUnderPointer(), target.id != from.node {
                let inputs = info.ports(target).inputs
                if inputs > 0 { problem = model.connect(from: from, to: PortRef(node: target.id, channel: min(from.channel, inputs - 1))) }
                else { problem = .noSuchPort }
            } else { attempted = false }
        case .input(let to):
            if let from = nearest(inputs: false) {
                problem = model.connect(from: from, to: to)
            } else if let source = nodeUnderPointer(), source.id != to.node {
                let outputs = info.ports(source).outputs
                if outputs > 0 { problem = model.connect(from: PortRef(node: source.id, channel: min(to.channel, outputs - 1)), to: to) }
                else { problem = .noSuchPort }
            } else { attempted = false }
        case .busOutput(let source):
            if let target = nodeUnderPointer(), target.id != source { problem = model.connectAll(from: source, to: target.id) }
            else if let to = nearest(inputs: true) { problem = model.connectAll(from: source, to: to.node) }
            else { attempted = false }
        case .busInput(let target):
            if let source = nodeUnderPointer(), source.id != target { problem = model.connectAll(from: source.id, to: target) }
            else if let from = nearest(inputs: false) { problem = model.connectAll(from: from.node, to: target) }
            else { attempted = false }
        case .moving(let cable):
            if let to = nearest(inputs: true) {
                if to != cable.to { problem = model.moveCable(cable.id, to: to) }
            } else if let target = nodeUnderPointer() {
                // Dropped on a node: its matching channel; back on either end node, nothing changes.
                if target.id != cable.to.node, target.id != cable.from.node {
                    let inputs = info.ports(target).inputs
                    problem = inputs > 0
                        ? model.moveCable(cable.id, to: PortRef(node: target.id, channel: min(cable.to.channel, inputs - 1)))
                        : .noSuchPort
                }
            } else {
                model.removeCable(cable.id)  // dropped on empty canvas
            }
        }
        if attempted, let problem {
            refuse(problem == .noSuchPort ? "Connect a channel on the right of one node to a channel on the left of another." : problem.message)
        }
    }
}

/// Scrolling and pinching over the canvas, which SwiftUI doesn't report: a plain scroll pans, ⌘-scroll and a pinch
/// zoom about the pointer. Watches the window's events while the canvas is in it; events elsewhere pass on.
struct CanvasEventCatcher: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onZoom: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPan = onPan
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
    }

    final class CatcherView: NSView {
        var onPan: (CGSize) -> Void = { _ in }
        var onZoom: (Double, CGPoint) -> Void = { _, _ in }
        private var monitor: Any?

        override var isFlipped: Bool { true }  // top-left origin, as in SwiftUI

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                if event.type == .magnify {
                    self.onZoom(1 + Double(event.magnification), location)
                } else if event.modifierFlags.contains(.command) {
                    let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
                    self.onZoom(exp(Double(event.scrollingDeltaY) * step), location)
                } else {
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    self.onPan(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
                }
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

/// The whole canvas at a glance, with a frame for the part in view: click or drag in it to move there. Below it, the
/// zoom buttons.
struct MinimapView: View {
    @Environment(AppModel.self) private var model
    /// What the map covered when a drag in it started: kept until it ends, so the map holds still under the pointer.
    @State private var dragWorld: CGRect?
    static let size = CGSize(width: 180, height: 112)

    var body: some View {
        let info = model.info
        let drag = model.nodeDrag
        let nodes = model.canvasNodes.map(drag.placed)  // dragged nodes where the drag has them
        let frames = nodes.map { NodeLayout.frame($0, info.ports($0)) }
        let viewport = model.viewport
        let visible = viewport.visibleRect(model.canvasViewSize)
        let map = Minimap(world: dragWorld ?? Minimap.world(nodes: frames, visible: visible), size: Self.size)
        let graph = drag.origins.isEmpty ? model.graph : drag.moved(model.graph)
        let cables = model.canvasCables
        VStack(spacing: 6) {
            Canvas { context, _ in
                for cable in cables {
                    guard let (a, b) = CanvasGeometry.ends(of: cable, in: graph) else { continue }
                    var line = Path()
                    line.move(to: map.mapPoint(a))
                    line.addLine(to: map.mapPoint(b))
                    context.stroke(line, with: .color(.secondary.opacity(0.5)), lineWidth: 0.75)
                }
                for (node, frame) in zip(nodes, frames) {
                    let tint = NodeStyle.tint(node.kind)
                    let rect = map.mapRect(frame)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint.opacity(model.isSelected(node.id) ? 1 : 0.6)))
                }
                let shown = map.mapRect(visible)
                context.fill(Path(roundedRect: shown, cornerRadius: 3), with: .color(.accentColor.opacity(0.1)))
                context.stroke(Path(roundedRect: shown, cornerRadius: 3), with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let world = dragWorld ?? map.world
                        dragWorld = world
                        let target = Minimap(world: world, size: Self.size).contentPoint(value.location)
                        model.viewport = model.viewport.centered(on: target, viewSize: model.canvasViewSize)
                    }
                    .onEnded { _ in dragWorld = nil }
            )
            .help("Click or drag to move around the canvas")
            .accessibilityElement()
            .accessibilityLabel("Minimap")
            .accessibilityValue("\(nodes.count) nodes, zoom \(viewport.percentText)")
            HStack(spacing: 2) {
                Button { model.zoom(in: false) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                    .accessibilityLabel("Zoom Out")
                Button(viewport.percentText) { model.zoomToActualSize() }
                    .monospacedDigit()
                    .frame(minWidth: 52)
                    .help("Actual Size (⌘0)")
                    .accessibilityLabel("Actual Size")
                    .accessibilityValue(viewport.percentText)
                Button { model.zoom(in: true) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
                    .accessibilityLabel("Zoom In")
                Spacer(minLength: 0)
                Button { model.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zoom to Fit (⌥⌘0)")
                    .accessibilityLabel("Zoom to Fit")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .frame(width: Self.size.width)
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// VoiceOver's view of the cables, which are drawn in one picture: an element at the middle of each.
struct CableAccessibilityLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.info
        let graph = model.graph
        let idle = model.plan.idleCables
        ZStack(alignment: .topLeading) {
            ForEach(model.canvasCables) { cable in
                if let (a, b) = CanvasGeometry.ends(of: cable, in: graph) {
                    let selected = model.selection == .cable(cable.id)
                    Color.clear
                        .frame(width: 14, height: 14)
                        .position(CanvasGeometry.point(a, b, t: 0.5))
                        .accessibilityElement()
                        .accessibilityLabel(CanvasAccessibility.cableLabel(cable, info: info))
                        .accessibilityValue(CanvasAccessibility.cableValue(cable, idle: idle.contains(cable.id)))
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { model.selection = .cable(cable.id) }
                        .accessibilityAction(named: "Disconnect") { model.removeCable(cable.id) }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

enum CableGeometry {
    static func path(_ a: CGPoint, _ b: CGPoint) -> Path {
        let (c1, c2) = CanvasGeometry.controls(a, b)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: c1, control2: c2)
        return path
    }
}

/// Puts a node at its place on the canvas, or where it is being dragged to. Only this redraws while it is dragged, not
/// the node itself.
private struct NodePlacement: ViewModifier {
    @Environment(AppModel.self) private var model
    let node: Node

    func body(content: Content) -> some View {
        let placed = model.nodeDrag.placed(node)
        content.offset(x: placed.x, y: placed.y)
    }
}

/// All cables, plus the one being dragged.
struct CableLayer: View {
    @Environment(AppModel.self) private var model
    let wire: PendingWire?

    var body: some View {
        let drag = model.nodeDrag
        // Dragged nodes are where the drag has them; the graph gets those places when it ends.
        let graph = drag.origins.isEmpty ? model.graph : drag.moved(model.graph)
        let moving: UUID? = if case .moving(let cable) = wire?.start { cable.id } else { nil }
        let cables = model.canvasCables.filter { $0.id != moving }
        let nodes = model.canvasNodes
        let info = model.info
        let plan = model.plan
        let selected: UUID? = if case .cable(let id) = model.selection { id } else { nil }
        let meters = model.meters
        Canvas { context, _ in
            for cable in cables {
                guard let from = graph.node(cable.from.node), let to = graph.node(cable.to.node) else { continue }
                let a = NodeLayout.outputPoint(from, cable.from.channel)
                let b = NodeLayout.inputPoint(to, cable.to.channel)
                let path = CableGeometry.path(a, b)
                let idle = plan.idleCables.contains(cable.id)
                let tint = NodeStyle.tint(from.kind)
                let level = idle ? 0 : CGFloat(meters[PortKey(node: from.id, isOutput: true, channel: cable.from.channel)] ?? 0)
                    * CGFloat(Gain.linear(cable.gainDB))
                if cable.id == selected {
                    context.stroke(path, with: .color(Color.accentColor.opacity(0.35)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                }
                if idle {
                    context.stroke(path, with: .color(.secondary.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                } else {
                    let glow = min(1, sqrt(level) * 1.4)
                    if glow > 0.02 {
                        context.stroke(path, with: .color(tint.opacity(0.25 * glow)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    }
                    context.stroke(path, with: .color(tint.opacity(0.7 + 0.3 * glow)),
                                   style: StrokeStyle(lineWidth: cable.gainDB <= Gain.floorDB ? 1.5 : 2.5, lineCap: .round))
                }
            }
            if let wire, let anchor = anchor(of: wire.start, graph: graph) {
                let reversed: Bool = switch wire.start {
                case .input, .busInput: true
                default: false
                }
                let path = reversed ? CableGeometry.path(wire.location, anchor) : CableGeometry.path(anchor, wire.location)
                // A picked-up cable over empty canvas turns red: letting go there removes it.
                let removing = moving != nil && !nodes.contains {
                    NodeLayout.frame($0, info.ports($0)).insetBy(dx: -12, dy: -6).contains(wire.location)
                }
                context.stroke(path, with: .color(removing ? .red.opacity(0.8) : .accentColor),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
            }
        }
    }

    private func anchor(of start: PendingWire.Start, graph: Graph) -> CGPoint? {
        switch start {
        case .output(let port): graph.node(port.node).map { NodeLayout.outputPoint($0, port.channel) }
        case .input(let port): graph.node(port.node).map { NodeLayout.inputPoint($0, port.channel) }
        case .busOutput(let id): graph.node(id).map(NodeLayout.busOutputPoint)
        case .busInput(let id): graph.node(id).map(NodeLayout.busInputPoint)
        case .moving(let cable): graph.node(cable.from.node).map { NodeLayout.outputPoint($0, cable.from.channel) }
        }
    }
}

final class PointerSpot {
    var location: CGPoint?
}

/// The dot grid, drawn in view coordinates so it covers the whole area at any zoom and follows the viewport.
struct GridBackground: View {
    let viewport: CanvasViewport

    var body: some View {
        Canvas { context, size in
            var spacing: CGFloat = 24
            while spacing * viewport.scale < 12 { spacing *= 2 }  // zoomed far out: fewer dots
            let step = spacing * viewport.scale
            let radius = max(0.6, min(1.2, 0.9 * viewport.scale))
            var dots = Path()
            let first = viewport.viewPoint(CGPoint(x: (viewport.origin.x / spacing).rounded(.down) * spacing,
                                                   y: (viewport.origin.y / spacing).rounded(.down) * spacing))
            var y = first.y
            while y < size.height {
                var x = first.x
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(.secondary.opacity(0.22)))
        }
        .accessibilityHidden(true)
    }
}

enum NodeStyle {
    static func tint(_ kind: NodeKind) -> Color {
        switch kind {
        case .virtualDevice: Color(red: 0.49, green: 0.36, blue: 0.95)
        case .device: Color(red: 0.16, green: 0.52, blue: 0.95)
        case .defaultOutput, .defaultInput: Color(red: 0.05, green: 0.65, blue: 0.68)
        case .application, .appThroughDevice: Color(red: 0.96, green: 0.55, blue: 0.13)
        case .systemAudio: Color(red: 0.92, green: 0.29, blue: 0.48)
        }
    }

    static func symbol(_ kind: NodeKind, ports: PortCounts) -> String {
        switch kind {
        case .virtualDevice: "point.3.filled.connected.trianglepath.dotted"
        case .device: ports.inputs > 0 && ports.outputs > 0 ? "slider.vertical.3" : (ports.inputs > 0 ? "hifispeaker.fill" : "mic.fill")
        case .defaultOutput: "speaker.wave.2.fill"
        case .defaultInput: "mic.fill"
        case .application: "app.fill"
        case .appThroughDevice: "app.connected.to.app.below.fill"
        case .systemAudio: "macwindow.on.rectangle"
        }
    }

    /// The app an App or "<app> through <device>" node stands for.
    static func app(_ kind: NodeKind) -> AppRef? {
        switch kind {
        case .application(let app), .appThroughDevice(let app, _): app
        default: nil
        }
    }

    @MainActor static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct NodeIcon: View {
    let kind: NodeKind
    let ports: PortCounts
    var size: CGFloat = 30

    var body: some View {
        if let app = NodeStyle.app(kind), let icon = NodeStyle.appIcon(app.bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size + 4, height: size + 4)
        } else {
            let tint = NodeStyle.tint(kind)
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: NodeStyle.symbol(kind, ports: ports))
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}

struct NodeCard: View {
    @Environment(AppModel.self) private var model
    let node: Node
    @Binding var wire: PendingWire?
    var focusedPort: FocusState<PortEnd?>.Binding
    @Binding var connecting: PortEnd?
    let onWireEnd: (PendingWire) -> Void
    /// A cable made from the keyboard, or why not.
    let onConnected: (Rules.Problem?) -> Void
    let onMove: (CGSize) -> Void
    let onMoveEnd: () -> Void
    /// Escape on a port: back to the canvas.
    let onEscape: () -> Void

    var body: some View {
        let info = model.info
        let ports = info.ports(node)
        let labels = (inputs: info.channelLabels(node, outputs: false), outputs: info.channelLabels(node, outputs: true))
        let selected = model.isSelected(node.id)
        let tint = NodeStyle.tint(node.kind)
        let issues = model.issues(for: node.id)
        let failing = model.isFailing(node.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NodeIcon(kind: node.kind, ports: ports)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title(node))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // The device's rate goes after the subtitle where it fits; a conversion gets a line of its own.
                    ViewThatFits(in: .horizontal) {
                        if model.plan.conversions[node.id] == nil, let rate = info.sampleRate(node) {
                            Text(info.subtitle(node) + " · " + formatSampleRate(rate))
                        }
                        Text(info.subtitle(node))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let conversion = model.plan.conversions[node.id] {
                        ViewThatFits(in: .horizontal) {
                            Text(conversion.text)
                            Text(conversion.shortText)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                        .help(conversion.text)
                    }
                }
                Spacer(minLength: 0)
                if failing || !issues.isEmpty {
                    Image(systemName: failing ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failing ? .red : .yellow)
                        .help(issues.joined(separator: "\n"))
                } else if model.isRunning(node.id) {
                    Circle().fill(.green).frame(width: 7, height: 7).help("Running")
                }
                Button {
                    model.updateNode(node.id, node.isMuted ? "Unmute" : "Mute") { $0.isMuted.toggle() }
                } label: {
                    Image(systemName: node.isMuted ? "speaker.slash.fill" : "speaker.wave.1")
                        .foregroundStyle(node.isMuted ? .red : .secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(node.isMuted ? "Unmute" : "Mute")
            }
            .padding(.horizontal, 12)
            .frame(height: NodeLayout.header)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                    .onChanged { onMove($0.translation) }
                    .onEnded { _ in onMoveEnd() }
            )
            .simultaneousGesture(TapGesture().onEnded {
                model.click(node.id, extending: NSEvent.modifierFlags.contains(.shift))
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CanvasAccessibility.nodeLabel(node, info: info))
            .accessibilityValue(CanvasAccessibility.nodeValue(node, info: info, isRunning: model.isRunning(node.id),
                                                              isFailing: failing, issues: issues.count))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.click(node.id, extending: false) }
            .accessibilityAction(named: node.isMuted ? "Unmute" : "Mute") {
                model.updateNode(node.id, node.isMuted ? "Unmute" : "Mute") { $0.isMuted.toggle() }
            }

            Rectangle().fill(.separator).frame(height: 0.5).padding(.horizontal, 10)

            VStack(spacing: 0) {
                ForEach(0..<NodeLayout.rows(ports), id: \.self) { row in
                    HStack(spacing: 6) {
                        if row < ports.inputs {
                            Text(labels.inputs[row])
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 56, alignment: .leading)
                                .accessibilityHidden(true)  // the meter says it
                            LevelBar(level: model.level(node.id, output: false, channel: row), tint: tint,
                                     label: CanvasAccessibility.meterLabel(PortEnd(node: node.id, channel: row, isOutput: false), info: info))
                        }
                        Spacer(minLength: 0)
                        if row < ports.outputs {
                            LevelBar(level: model.level(node.id, output: true, channel: row), tint: tint,
                                     label: CanvasAccessibility.meterLabel(PortEnd(node: node.id, channel: row, isOutput: true), info: info))
                            Text(labels.outputs[row])
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 56, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: NodeLayout.row)
                }
            }
            .padding(.top, NodeLayout.topPadding)
            .padding(.bottom, NodeLayout.bottomPadding)

            if !node.effects.isEmpty {
                EffectLabels(node: node)
                    .padding(.horizontal, 12)
                    .frame(height: NodeLayout.effectsRow, alignment: .top)
            }
        }
        .frame(width: NodeLayout.width, height: NodeLayout.height(node, ports), alignment: .top)
        .glassEffect(.regular.tint(tint.opacity(0.06)), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? Color.accentColor : (failing ? .red.opacity(0.7) : .clear), lineWidth: 2)
        }
        .opacity(isDisabledDevice ? 0.6 : 1)
        .overlay(alignment: .topLeading) { portOverlay(ports, tint: tint) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.title(node))
        .contextMenu {
            Button(node.isMuted ? "Unmute" : "Mute") {
                model.updateNode(node.id, node.isMuted ? "Unmute" : "Mute") { $0.isMuted.toggle() }
            }
            let linked = model.linkedNodes(node.id)
            if model.isDeviceNode(node), !linked.isEmpty {
                Menu("Disconnect") {
                    ForEach(linked) { other in
                        Button(model.info.title(other)) { model.disconnect(node.id, other.id) }
                    }
                    Divider()
                    Button("Everything") { model.disconnectAll(node.id) }
                }
            } else {
                Button("Disconnect") { model.disconnectAll(node.id) }
                    .disabled(linked.isEmpty)
            }
            if model.isOutputNode(node) {
                Button("Calibrate Speakers…") { model.calibrateSpeakers(node.id) }
                    .disabled(model.currentDevice(node) == nil)
                Button("Choose Headphones…") { model.chooseHeadphones(node.id) }
            }
            Divider()
            if !model.isDeviceNode(node) {
                // On a node outside the selection these act on that node alone.
                Button("Copy") { selectForMenu(); model.copySelection() }
                Button("Duplicate") { selectForMenu(); model.duplicateSelection() }
            }
            Button("Tidy Up") { model.tidyUp() }
            Divider()
            if case .virtualDevice(let device) = node.kind {
                Button("Delete Virtual Device…", role: .destructive) { model.deviceToDelete = device }
            } else if model.isSelected(node.id), model.selectedNodes.count > 1 {
                Button("Remove \(model.selectedNodes.count) Nodes from Canvas", role: .destructive) { model.deleteSelection() }
            } else {
                Button("Remove from Canvas", role: .destructive) { model.removeNode(node.id) }
            }
        }
    }

    private func selectForMenu() {
        if !model.isSelected(node.id) { model.selection = .node(node.id) }
    }

    private var isDisabledDevice: Bool {
        if case .virtualDevice(let id) = node.kind { return !(model.graph.virtualDevice(id)?.isEnabled ?? false) }
        return false
    }

    /// Port dots on both edges, plus the "all channels" handles beside the header.
    @ViewBuilder private func portOverlay(_ ports: PortCounts, tint: Color) -> some View {
        let connectedOut = Set(model.graph.cables.filter { $0.from.node == node.id }.map(\.from.channel))
        // The newest cable into each input: dragging a connected input picks it up.
        let arriving = Dictionary(model.graph.cables.filter { $0.to.node == node.id }.map { ($0.to.channel, $0) },
                                  uniquingKeysWith: { _, newer in newer })
        let info = model.info
        ZStack(alignment: .topLeading) {
            ForEach(0..<ports.inputs, id: \.self) { channel in
                let end = PortEnd(node: node.id, channel: channel, isOutput: false)
                port(end, filled: arriving[channel] != nil, tint: tint, ports: ports, info: info)
                    .gesture(wireGesture(arriving[channel].map { .moving($0) } ?? .input(end.port)))
                    .help(arriving[channel] == nil
                          ? "Input \(channel + 1): drag to a channel on the right side of another node, or press Return to pick one"
                          : "Input \(channel + 1): drag its cable to another input to move it, or onto empty canvas to remove it")
                    .position(local(NodeLayout.inputPoint(node, channel)))
            }
            ForEach(0..<ports.outputs, id: \.self) { channel in
                let end = PortEnd(node: node.id, channel: channel, isOutput: true)
                port(end, filled: connectedOut.contains(channel), tint: tint, ports: ports, info: info)
                    .gesture(wireGesture(.output(end.port)))
                    .help("Output \(channel + 1): drag to a channel on the left side of another node, or press Return to pick one")
                    .position(local(NodeLayout.outputPoint(node, channel)))
            }
            if ports.outputs > 1 {
                BusHandle(tint: tint, pointsRight: true)
                    .gesture(wireGesture(.busOutput(node.id)))
                    .help("Drag onto another node to connect all channels in order")
                    .accessibilityHidden(true)
                    .position(local(NodeLayout.busOutputPoint(node)))
            }
            if ports.inputs > 1 {
                BusHandle(tint: tint, pointsRight: true)
                    .gesture(wireGesture(.busInput(node.id)))
                    .help("Drag onto another node to connect all of its channels here")
                    .accessibilityHidden(true)
                    .position(local(NodeLayout.busInputPoint(node)))
            }
        }
        .frame(width: NodeLayout.width, height: NodeLayout.height(node, ports), alignment: .topLeading)
    }

    /// A channel dot that the keyboard and VoiceOver can reach: Return (or VoiceOver's action) opens a list of the
    /// ports it may connect to; the arrow keys move between ports, Escape goes back to the canvas.
    private func port(_ end: PortEnd, filled: Bool, tint: Color, ports: PortCounts, info: NodeInfo) -> some View {
        PortDot(filled: filled, tint: tint, focused: focusedPort.wrappedValue == end)
            .focusable()
            .focused(focusedPort, equals: end)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                connecting = end
                return .handled
            }
            .onKeyPress(.escape) {
                onEscape()
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                let next = switch press.key {
                case .upArrow: KeyboardConnect.neighbour(of: end, ports: ports, up: true)
                case .downArrow: KeyboardConnect.neighbour(of: end, ports: ports, up: false)
                case .leftArrow: KeyboardConnect.neighbour(of: end, ports: ports, toOutputs: false)
                default: KeyboardConnect.neighbour(of: end, ports: ports, toOutputs: true)
                }
                if let next { focusedPort.wrappedValue = next }
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CanvasAccessibility.portLabel(end, info: info))
            .accessibilityValue(CanvasAccessibility.portValue(end, info: info))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens a list of the channels it can connect to")
            .accessibilityAction { connecting = end }
            .accessibilityAction(named: model.isListening(to: end.port) ? "Stop Listening" : "Listen on Monitor") {
                model.toggleListening(end.port)
            }
            .contextMenu {
                Button(model.isListening(to: end.port) ? "Stop Listening" : "Listen on Monitor") { model.toggleListening(end.port) }
                    .disabled(!model.hasMonitorOutput)
                if !model.hasMonitorOutput { Text("Choose a monitor output in the mixer first") }
            }
            .popover(isPresented: Binding(get: { connecting == end }, set: { if !$0, connecting == end { connecting = nil } }),
                     arrowEdge: end.isOutput ? .trailing : .leading) {
                ConnectChooser(end: end) { problem in
                    connecting = nil
                    focusedPort.wrappedValue = end
                    onConnected(problem)
                }
                .environment(model)
            }
    }

    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - node.x, y: point.y - node.y) }

    private func wireGesture(_ start: PendingWire.Start) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in wire = PendingWire(start: start, location: value.location) }
            .onEnded { value in
                let finished = PendingWire(start: start, location: value.location)
                wire = nil
                onWireEnd(finished)
            }
    }
}

/// A node's effects as small labels under its channels, in chain order: a green dot when on, struck through when
/// bypassed. Clicking one bypasses it or turns it back on (the inspector edits their settings). When they don't all fit,
/// short titles are used, then the first ones and "+2", then "4 effects"; those select the node to show the rest.
struct EffectLabels: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        let effects = node.effects
        ViewThatFits(in: .horizontal) {
            row(effects, short: false)
            row(effects, short: true)
            if effects.count > 2 { row(Array(effects.prefix(2)), short: true, more: effects.count - 2) }
            if effects.count > 1 { row(Array(effects.prefix(1)), short: true, more: effects.count - 1) }
            summary(effects)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ shown: [Effect], short: Bool, more: Int = 0) -> some View {
        HStack(spacing: 4) {
            ForEach(shown) { chip($0, short: short) }
            if more > 0 {
                Button { model.selection = .node(node.id) } label: { capsule(Text("+\(more)")) }
                    .buttonStyle(.plain)
                    .help(node.effects.suffix(more).map(\.title).joined(separator: ", ") + ": select the item to see them")
                    .accessibilityLabel("\(more) more effects")
            }
        }
        .fixedSize()
    }

    private func summary(_ effects: [Effect]) -> some View {
        Button { model.selection = .node(node.id) } label: {
            capsule(Text(effects.count == 1 ? "1 effect" : "\(effects.count) effects"))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(effects.map(\.title).joined(separator: ", ") + ": select the item to see them")
    }

    private func chip(_ effect: Effect, short: Bool) -> some View {
        Button {
            model.setEffectBypass(effect.id, in: node.id, !effect.bypass)
        } label: {
            capsule(HStack(spacing: 4) {
                Circle().fill(effect.bypass ? Color.secondary.opacity(0.4) : .green).frame(width: 5, height: 5)
                Text(short ? effect.shortTitle : effect.title)
                    .strikethrough(effect.bypass)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }, dimmed: effect.bypass)
        }
        .buttonStyle(.plain)
        .help(effect.bypass ? "\(effect.title) is bypassed: click to turn it on" : "Click to bypass \(effect.title)")
        .accessibilityLabel(effect.title)
        .accessibilityValue(effect.bypass ? "Bypassed" : "On")
        .accessibilityHint(effect.bypass ? "Turns it on" : "Bypasses it")
    }

    private func capsule(_ content: some View, dimmed: Bool = false) -> some View {
        content
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(dimmed ? .tertiary : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
            .contentShape(Capsule())
    }
}

struct PortDot: View {
    let filled: Bool
    let tint: Color
    var focused = false
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(filled ? tint : Color(nsColor: .windowBackgroundColor))
            .overlay(Circle().strokeBorder(tint, lineWidth: 2))
            .frame(width: NodeLayout.portRadius * 2, height: NodeLayout.portRadius * 2)
            .background {
                if focused { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: 20, height: 20) }
            }
            .scaleEffect(hovering || focused ? 1.35 : 1)
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct BusHandle: View {
    let tint: Color
    let pointsRight: Bool
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(tint.opacity(hovering ? 1 : 0.85))
            .frame(width: 10, height: 22)
            .overlay {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(90))
            }
            .frame(width: 24, height: 30)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct LevelBar: View {
    let level: Float
    let tint: Color
    var label = "Level"

    var body: some View {
        let dB = level > 0 ? 20 * log10(Double(level)) : -90
        let fraction = max(0, min(1, (dB + 60) / 60))
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule()
                .fill(level >= 1 ? Color.red : (dB > -6 ? Color.yellow : tint))
                .frame(width: 44 * fraction)
        }
        .frame(width: 44, height: 4)
        .opacity(level > 0 ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(CanvasAccessibility.meterValue(level))
    }
}

/// The keyboard's way to make a cable: the ports a focused port may connect to. ↑/↓ pick one, Return connects, Escape
/// closes the list.
struct ConnectChooser: View {
    @Environment(AppModel.self) private var model
    let end: PortEnd
    /// Called after connecting (with the reason when it couldn't) or with nil when cancelled.
    let onDone: (Rules.Problem?) -> Void
    @State private var picked: PortEnd?
    @FocusState private var listFocused: Bool

    var body: some View {
        let info = model.info
        let choices = KeyboardConnect.choices(for: end, graph: model.graph, inventory: model.inventory)
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect \(CanvasAccessibility.portLabel(end, info: info)) to")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if choices.isEmpty {
                Text(end.isOutput ? "No input on this canvas can take this channel." : "No output on this canvas can feed this channel.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List(choices, id: \.self, selection: $picked) { choice in
                    Text(CanvasAccessibility.portLabel(choice, info: info))
                        .lineLimit(1)
                }
                .frame(height: min(240, CGFloat(choices.count) * 26 + 12))
                .focused($listFocused)
                .accessibilityLabel("Channels to connect to")
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            picked = choices.first
            listFocused = true
        }
    }

    private func connect() {
        guard let picked, let (from, to) = KeyboardConnect.cable(end, picked) else { return }
        onDone(model.connect(from: from, to: to))
    }
}
