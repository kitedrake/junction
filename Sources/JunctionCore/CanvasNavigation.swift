import CoreGraphics
import Foundation

// Finding your way around a canvas without the window: where ports and cables are, which cable a point is on, zooming
// and panning, the minimap, connecting from the keyboard, and what VoiceOver says about nodes, ports, cables and meters.

/// Where ports and cables sit on a canvas, shared by drawing, hit-testing and the minimap.
public enum CanvasGeometry {
    /// How close a click has to be to a cable to select it.
    public static let clickTolerance = 7.0
    /// How close a node dropped from the sidebar has to land to a cable to go onto it.
    public static let dropTolerance = 18.0

    public static func inputPoint(_ node: Node, _ channel: Int) -> CGPoint {
        CGPoint(x: node.x, y: node.y + CanvasMetrics.header + CanvasMetrics.topPadding + CanvasMetrics.row * (Double(channel) + 0.5))
    }

    public static func outputPoint(_ node: Node, _ channel: Int) -> CGPoint {
        CGPoint(x: node.x + CanvasMetrics.nodeWidth,
                y: node.y + CanvasMetrics.header + CanvasMetrics.topPadding + CanvasMetrics.row * (Double(channel) + 0.5))
    }

    /// A cable's two Bézier control points: it leaves to the right and arrives from the left.
    public static func controls(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(50, abs(b.x - a.x) * 0.5)
        return (CGPoint(x: a.x + dx, y: a.y), CGPoint(x: b.x - dx, y: b.y))
    }

    /// The point a fraction `t` (0…1) along a cable from `a` to `b`.
    public static func point(_ a: CGPoint, _ b: CGPoint, t: Double) -> CGPoint {
        let (c1, c2) = controls(a, b)
        let u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
        let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
        return CGPoint(x: x, y: y)
    }

    /// Where a cable starts and ends, if both its nodes exist.
    public static func ends(of cable: Cable, in graph: Graph) -> (CGPoint, CGPoint)? {
        guard let from = graph.node(cable.from.node), let to = graph.node(cable.to.node) else { return nil }
        return (outputPoint(from, cable.from.channel), inputPoint(to, cable.to.channel))
    }

    /// The shortest distance from a point to a cable's curve (followed in 48 straight pieces).
    public static func distance(from point: CGPoint, toCableFrom a: CGPoint, to b: CGPoint) -> Double {
        var best = Double.infinity
        var previous = a
        for step in 1...48 {
            let next = self.point(a, b, t: Double(step) / 48)
            best = min(best, distance(from: point, toSegment: previous, next))
            previous = next
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// The cable nearest to a point among `cables`, if one is within `tolerance`.
    public static func cable(at point: CGPoint, among cables: [Cable], graph: Graph, tolerance: Double = clickTolerance) -> UUID? {
        var best: (UUID, Double)?
        for cable in cables {
            guard let (a, b) = ends(of: cable, in: graph) else { continue }
            let distance = distance(from: point, toCableFrom: a, to: b)
            if distance <= tolerance, distance < (best?.1 ?? .infinity) { best = (cable.id, distance) }
        }
        return best?.0
    }

    /// Where a node dropped at a point goes: its title under the pointer.
    public static func dropOrigin(_ point: CGPoint) -> CGPoint {
        CGPoint(x: max(0, point.x - 30), y: max(0, point.y - CanvasMetrics.header / 2))
    }

    /// The area the nodes take up, nil for none.
    public static func bounds(of nodes: [Node], info: NodeInfo) -> CGRect? {
        nodes.map { CanvasMetrics.frame($0, info.ports($0)) }.reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// The size of a canvas's drawing area: at least 1800 × 1200, with room to the right of and below the nodes.
    public static func contentSize(of nodes: [Node], info: NodeInfo) -> CGSize {
        let used = bounds(of: nodes, info: info) ?? .zero
        return CGSize(width: max(1800, used.maxX + 400), height: max(1200, used.maxY + 300))
    }
}

/// The part of a canvas the window shows: how far it is zoomed and which canvas point is at the top-left corner.
public struct CanvasViewport: Equatable, Sendable {
    public static let minScale = 0.25
    public static let maxScale = 3.0
    /// The sizes ⌘+ and ⌘− step through.
    public static let steps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    public var scale: Double
    /// The canvas point at the view's top-left corner.
    public var origin: CGPoint

    public init(scale: Double = 1, origin: CGPoint = .zero) {
        self.scale = min(Self.maxScale, max(Self.minScale, scale))
        self.origin = origin
    }

    /// Where a canvas point shows in the view.
    public func viewPoint(_ content: CGPoint) -> CGPoint {
        CGPoint(x: (content.x - origin.x) * scale, y: (content.y - origin.y) * scale)
    }

    /// The canvas point shown at a point in the view.
    public func contentPoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: view.x / scale + origin.x, y: view.y / scale + origin.y)
    }

    /// The part of the canvas a view of this size shows.
    public func visibleRect(_ viewSize: CGSize) -> CGRect {
        CGRect(origin: origin, size: CGSize(width: viewSize.width / scale, height: viewSize.height / scale))
    }

    /// Zoomed to `scale` (kept within the limits), with the canvas point under `viewPoint` staying where it is.
    public func zoomed(to scale: Double, about viewPoint: CGPoint) -> CanvasViewport {
        let fixed = contentPoint(viewPoint)
        var result = CanvasViewport(scale: scale, origin: origin)
        result.origin = CGPoint(x: fixed.x - viewPoint.x / result.scale, y: fixed.y - viewPoint.y / result.scale)
        return result
    }

    /// Zoomed by a factor (a pinch, ⌘-scroll) about a view point.
    public func zoomed(by factor: Double, about viewPoint: CGPoint) -> CanvasViewport {
        zoomed(to: scale * factor, about: viewPoint)
    }

    /// One step in (⌘+) or out (⌘−) about a view point.
    public func stepped(in zoomIn: Bool, about viewPoint: CGPoint) -> CanvasViewport {
        let next = zoomIn ? Self.steps.first { $0 > scale + 0.001 } : Self.steps.last { $0 < scale - 0.001 }
        return zoomed(to: next ?? scale, about: viewPoint)
    }

    /// Moved by a distance in the view (scrolling, dragging empty canvas): the canvas follows the pointer.
    public func panned(by viewDelta: CGSize) -> CanvasViewport {
        CanvasViewport(scale: scale, origin: CGPoint(x: origin.x - viewDelta.width / scale, y: origin.y - viewDelta.height / scale))
    }

    /// Showing a canvas point in the middle of a view.
    public func centered(on content: CGPoint, viewSize: CGSize) -> CanvasViewport {
        CanvasViewport(scale: scale, origin: CGPoint(x: content.x - viewSize.width / 2 / scale,
                                                     y: content.y - viewSize.height / 2 / scale))
    }

    /// Kept near the canvas: at most `margin` points of empty space beyond the drawing area on any side. When the whole
    /// canvas fits in the view it can sit anywhere inside it.
    public func clamped(content: CGSize, viewSize: CGSize, margin: Double = 120) -> CanvasViewport {
        func clamp(_ value: Double, _ content: Double, _ view: Double) -> Double {
            let low = -margin, high = content + margin - view / scale
            return high >= low ? min(high, max(low, value)) : min(low, max(high, value))
        }
        return CanvasViewport(scale: scale, origin: CGPoint(x: clamp(origin.x, content.width, viewSize.width),
                                                            y: clamp(origin.y, content.height, viewSize.height)))
    }

    /// Zoom to Fit: the whole rectangle in view with a margin, centred, never larger than actual size.
    public static func fitting(_ rect: CGRect, in viewSize: CGSize, margin: Double = 40) -> CanvasViewport {
        guard rect.width > 0, rect.height > 0, viewSize.width > 2 * margin, viewSize.height > 2 * margin else {
            return CanvasViewport(origin: rect.origin)
        }
        let scale = min(1, (viewSize.width - 2 * margin) / rect.width, (viewSize.height - 2 * margin) / rect.height)
        return CanvasViewport(scale: scale).centered(on: CGPoint(x: rect.midX, y: rect.midY), viewSize: viewSize)
    }

    /// "150 %".
    public var percentText: String { "\(Int((scale * 100).rounded())) %" }
}

/// A small map of the whole canvas: the nodes, and a frame for the part the window shows.
public struct Minimap: Equatable, Sendable {
    /// The canvas area the map covers.
    public var world: CGRect
    /// The map's size on screen.
    public var size: CGSize

    public init(world: CGRect, size: CGSize) {
        self.world = world
        self.size = size
    }

    /// What a map should cover: the nodes with some room around them, and the part of the canvas in view.
    public static func world(nodes: [CGRect], visible: CGRect, padding: Double = 60) -> CGRect {
        let used = nodes.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }.map { $0.insetBy(dx: -padding, dy: -padding) }
        return used?.union(visible) ?? visible
    }

    /// Map points per canvas point (the world fits inside the map with its proportions kept).
    public var scale: Double {
        guard world.width > 0, world.height > 0 else { return 1 }
        return min(size.width / world.width, size.height / world.height)
    }

    /// The world is centred in the map.
    private var inset: CGPoint {
        CGPoint(x: (size.width - world.width * scale) / 2, y: (size.height - world.height * scale) / 2)
    }

    public func mapPoint(_ content: CGPoint) -> CGPoint {
        CGPoint(x: (content.x - world.minX) * scale + inset.x, y: (content.y - world.minY) * scale + inset.y)
    }

    public func contentPoint(_ map: CGPoint) -> CGPoint {
        CGPoint(x: (map.x - inset.x) / scale + world.minX, y: (map.y - inset.y) / scale + world.minY)
    }

    public func mapRect(_ content: CGRect) -> CGRect {
        let origin = mapPoint(content.origin)
        return CGRect(x: origin.x, y: origin.y, width: content.width * scale, height: content.height * scale)
    }
}

/// One end of a cable: a channel on a node's input (left) or output (right) side.
public struct PortEnd: Hashable, Sendable {
    public var port: PortRef
    public var isOutput: Bool

    public init(_ port: PortRef, isOutput: Bool) {
        self.port = port
        self.isOutput = isOutput
    }

    public init(node: UUID, channel: Int, isOutput: Bool) {
        self.init(PortRef(node: node, channel: channel), isOutput: isOutput)
    }
}

/// Connecting from the keyboard: focus a port, press Return, pick the other end from a list.
public enum KeyboardConnect {
    /// The ports on the same canvas that a cable from `end` may go to (Rules.check allows it), in canvas order.
    public static func choices(for end: PortEnd, graph: Graph, inventory: Inventory) -> [PortEnd] {
        guard let node = graph.node(end.port.node), let canvas = node.canvas else { return [] }
        let info = NodeInfo(graph: graph, inventory: inventory)
        var result: [PortEnd] = []
        for other in graph.nodes(on: canvas) where other.id != node.id {
            let ports = info.ports(other)
            for channel in 0..<(end.isOutput ? ports.inputs : ports.outputs) {
                let candidate = PortEnd(node: other.id, channel: channel, isOutput: !end.isOutput)
                guard let (from, to) = cable(end, candidate),
                      Rules.check(from: from, to: to, graph: graph, inventory: inventory) == nil else { continue }
                result.append(candidate)
            }
        }
        return result
    }

    /// The cable between two ends: from the output one to the input one. Nil for two of the same side.
    public static func cable(_ a: PortEnd, _ b: PortEnd) -> (from: PortRef, to: PortRef)? {
        guard a.isOutput != b.isOutput else { return nil }
        return a.isOutput ? (a.port, b.port) : (b.port, a.port)
    }

    /// The port a key moves focus to from `end`: ↑/↓ through a side's channels, ←/→ to the other side. Nil at an edge.
    public static func neighbour(of end: PortEnd, ports: PortCounts, up: Bool? = nil, toOutputs: Bool? = nil) -> PortEnd? {
        if let up {
            let channel = end.port.channel + (up ? -1 : 1)
            guard channel >= 0, channel < (end.isOutput ? ports.outputs : ports.inputs) else { return nil }
            return PortEnd(node: end.port.node, channel: channel, isOutput: end.isOutput)
        }
        if let toOutputs, toOutputs != end.isOutput {
            let count = toOutputs ? ports.outputs : ports.inputs
            guard count > 0 else { return nil }
            return PortEnd(node: end.port.node, channel: min(end.port.channel, count - 1), isOutput: toOutputs)
        }
        return nil
    }

    /// The port focused first when the keyboard enters a node: its first output, or its first input.
    public static func firstPort(of node: Node, ports: PortCounts, preferOutputs: Bool = true) -> PortEnd? {
        let sides = preferOutputs ? [true, false] : [false, true]
        for isOutput in sides where (isOutput ? ports.outputs : ports.inputs) > 0 {
            return PortEnd(node: node.id, channel: 0, isOutput: isOutput)
        }
        return nil
    }
}

/// What VoiceOver says about the canvas.
public enum CanvasAccessibility {
    /// "System Audio, All apps except Discord".
    public static func nodeLabel(_ node: Node, info: NodeInfo) -> String {
        let subtitle = info.subtitle(node)
        return subtitle.isEmpty ? info.title(node) : "\(info.title(node)), \(subtitle)"
    }

    /// "Muted, 2 inputs, 2 outputs, 4 cables, running".
    public static func nodeValue(_ node: Node, info: NodeInfo, isRunning: Bool, isFailing: Bool, issues: Int = 0) -> String {
        let ports = info.ports(node)
        var parts: [String] = []
        if node.isMuted { parts.append("muted") }
        if ports.inputs > 0 { parts.append(count(ports.inputs, "input")) }
        if ports.outputs > 0 { parts.append(count(ports.outputs, "output")) }
        let cables = info.graph.cables.filter { $0.from.node == node.id || $0.to.node == node.id }.count
        parts.append(cables == 0 ? "not connected" : count(cables, "cable"))
        if isFailing { parts.append("not working") } else if isRunning { parts.append("running") }
        if issues > 0 { parts.append(count(issues, "problem")) }
        return parts.joined(separator: ", ").capitalizingFirst
    }

    /// "Input 1 (L)", or "Output 3" when the channel has no name of its own.
    public static func channelName(_ end: PortEnd, info: NodeInfo) -> String {
        let side = end.isOutput ? "Output" : "Input"
        let number = end.port.channel + 1
        guard let node = info.graph.node(end.port.node) else { return "\(side) \(number)" }
        let labels = info.channelLabels(node, outputs: end.isOutput)
        guard end.port.channel < labels.count, labels[end.port.channel] != "\(number)" else { return "\(side) \(number)" }
        return "\(side) \(number) (\(labels[end.port.channel]))"
    }

    /// "System Audio, output 1 (L)".
    public static func portLabel(_ end: PortEnd, info: NodeInfo) -> String {
        let title = info.graph.node(end.port.node).map(info.title) ?? "Removed node"
        return "\(title), \(channelName(end, info: info).lowercasedFirst)"
    }

    /// "Connected to Stream Mix, input 1 (L)", or "Not connected".
    public static func portValue(_ end: PortEnd, info: NodeInfo) -> String {
        let others = info.graph.cables.compactMap { cable -> PortEnd? in
            if end.isOutput, cable.from == end.port { return PortEnd(cable.to, isOutput: false) }
            if !end.isOutput, cable.to == end.port { return PortEnd(cable.from, isOutput: true) }
            return nil
        }
        guard !others.isEmpty else { return "Not connected" }
        return "Connected to " + others.map { portLabel($0, info: info) }.joined(separator: "; ")
    }

    /// "Cable from System Audio, output 1 (L) to Stream Mix, input 1 (L)".
    public static func cableLabel(_ cable: Cable, info: NodeInfo) -> String {
        "Cable from \(portLabel(PortEnd(cable.from, isOutput: true), info: info)) to \(portLabel(PortEnd(cable.to, isOutput: false), info: info))"
    }

    /// "−6.0 dB", plus "not playing" for a cable the planner doesn't use right now.
    public static func cableValue(_ cable: Cable, idle: Bool) -> String {
        idle ? "\(Gain.text(cable.gainDB)), not playing" : Gain.text(cable.gainDB)
    }

    /// "Input 1 (L) level".
    public static func meterLabel(_ end: PortEnd, info: NodeInfo) -> String {
        "\(channelName(end, info: info)) level"
    }

    /// A meter's peak: "Silent", "−12 dB", or "Clipping".
    public static func meterValue(_ level: Float) -> String {
        guard level > 0 else { return "Silent" }
        if level >= 1 { return "Clipping" }
        let dB = 20 * log10(Double(level))
        if dB < -60 { return "Silent" }
        return dB > -0.5 ? "0 dB" : "−\(Int((-dB).rounded())) dB"
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
