import AppKit
import JunctionCore
import SwiftUI

/// Node geometry, shared by drawing and hit-testing so cables meet the ports exactly.
enum NodeLayout {
    static let width: CGFloat = 236
    static let header: CGFloat = 54
    static let row: CGFloat = 24
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 10
    static let portRadius: CGFloat = 6

    static func rows(_ ports: PortCounts) -> Int { max(1, max(ports.inputs, ports.outputs)) }

    static func height(for ports: PortCounts) -> CGFloat {
        header + topPadding + CGFloat(rows(ports)) * row + bottomPadding
    }

    static func origin(_ node: Node) -> CGPoint { CGPoint(x: node.x, y: node.y) }

    static func inputPoint(_ node: Node, _ channel: Int) -> CGPoint {
        CGPoint(x: node.x, y: node.y + header + topPadding + row * (CGFloat(channel) + 0.5))
    }

    static func outputPoint(_ node: Node, _ channel: Int) -> CGPoint {
        CGPoint(x: node.x + width, y: node.y + header + topPadding + row * (CGFloat(channel) + 0.5))
    }

    /// The "all channels" handles beside the header.
    static func busOutputPoint(_ node: Node) -> CGPoint { CGPoint(x: node.x + width, y: node.y + header / 2) }
    static func busInputPoint(_ node: Node) -> CGPoint { CGPoint(x: node.x, y: node.y + header / 2) }

    static func frame(_ node: Node, _ ports: PortCounts) -> CGRect {
        CGRect(x: node.x, y: node.y, width: width, height: height(for: ports))
    }
}

/// What the user is dragging out of a port.
struct PendingWire: Equatable {
    enum Start: Equatable {
        case output(PortRef)
        case input(PortRef)
        case busOutput(UUID)
        case busInput(UUID)
    }

    var start: Start
    var location: CGPoint
}

struct CanvasView: View {
    @Environment(AppModel.self) private var model
    @State private var wire: PendingWire?
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @State private var refusal: String?
    @FocusState private var focused: Bool

    var body: some View {
        let info = model.info
        let bounds = contentBounds(info)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                GridBackground()
                    .frame(width: bounds.width, height: bounds.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .named("canvas")) { location in
                        model.selection = hitCable(at: location, info: info).map { .cable($0) }
                        focused = true
                    }
                CableLayer(wire: wire)
                    .frame(width: bounds.width, height: bounds.height)
                    .allowsHitTesting(false)
                ForEach(model.graph.nodes) { node in
                    NodeCard(node: node, wire: $wire, onWireEnd: finishWire, onMove: { translation in
                        let origin = dragOrigins[node.id] ?? CGPoint(x: node.x, y: node.y)
                        dragOrigins[node.id] = origin
                        model.moveNode(node.id, to: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
                    }, onMoveEnd: { dragOrigins[node.id] = nil })
                    .offset(x: node.x, y: node.y)
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .coordinateSpace(.named("canvas"))
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { model.deleteSelection() }
        .onChange(of: model.selection) { _, selection in
            if selection != nil { focused = true }
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
    }

    private func contentBounds(_ info: NodeInfo) -> CGSize {
        var width: CGFloat = 1800, height: CGFloat = 1200
        for node in model.graph.nodes {
            let frame = NodeLayout.frame(node, info.ports(node))
            width = max(width, frame.maxX + 400)
            height = max(height, frame.maxY + 300)
        }
        return CGSize(width: width, height: height)
    }

    /// The cable closest to a point, if one is within a few points.
    private func hitCable(at point: CGPoint, info: NodeInfo) -> UUID? {
        var best: (UUID, CGFloat)?
        for cable in model.graph.cables {
            guard let from = model.graph.node(cable.from.node), let to = model.graph.node(cable.to.node) else { continue }
            let a = NodeLayout.outputPoint(from, cable.from.channel), b = NodeLayout.inputPoint(to, cable.to.channel)
            for step in 0...40 {
                let p = CableGeometry.point(a, b, t: CGFloat(step) / 40)
                let distance = hypot(p.x - point.x, p.y - point.y)
                if distance < 7, distance < (best?.1 ?? .infinity) { best = (cable.id, distance) }
            }
        }
        return best?.0
    }

    /// Ends a wire drag: connects to the port (or node) under the pointer.
    private func finishWire(_ wire: PendingWire) {
        let info = model.info
        let point = wire.location
        func nearest(inputs: Bool) -> PortRef? {
            var best: (PortRef, CGFloat)?
            for node in model.graph.nodes {
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
            model.graph.nodes.last { NodeLayout.frame($0, info.ports($0)).insetBy(dx: -12, dy: -6).contains(point) }
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
        }
        if attempted, let problem {
            refusal = problem == .noSuchPort ? "Connect a channel on the right of one node to a channel on the left of another." : problem.message
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                refusal = nil
            }
        }
    }
}

enum CableGeometry {
    static func controls(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(50, abs(b.x - a.x) * 0.5)
        return (CGPoint(x: a.x + dx, y: a.y), CGPoint(x: b.x - dx, y: b.y))
    }

    static func path(_ a: CGPoint, _ b: CGPoint) -> Path {
        let (c1, c2) = controls(a, b)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: c1, control2: c2)
        return path
    }

    static func point(_ a: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        let (c1, c2) = controls(a, b)
        let u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
        let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
        return CGPoint(x: x, y: y)
    }
}

/// All cables, plus the one being dragged.
struct CableLayer: View {
    @Environment(AppModel.self) private var model
    let wire: PendingWire?

    var body: some View {
        let graph = model.graph
        let plan = model.plan
        let selected: UUID? = if case .cable(let id) = model.selection { id } else { nil }
        let meters = model.meters
        Canvas { context, _ in
            for cable in graph.cables {
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
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
            }
        }
    }

    private func anchor(of start: PendingWire.Start, graph: Graph) -> CGPoint? {
        switch start {
        case .output(let port): graph.node(port.node).map { NodeLayout.outputPoint($0, port.channel) }
        case .input(let port): graph.node(port.node).map { NodeLayout.inputPoint($0, port.channel) }
        case .busOutput(let id): graph.node(id).map(NodeLayout.busOutputPoint)
        case .busInput(let id): graph.node(id).map(NodeLayout.busInputPoint)
        }
    }
}

struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var dots = Path()
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.secondary.opacity(0.22)))
        }
    }
}

enum NodeStyle {
    static func tint(_ kind: NodeKind) -> Color {
        switch kind {
        case .virtualDevice: Color(red: 0.49, green: 0.36, blue: 0.95)
        case .device: Color(red: 0.16, green: 0.52, blue: 0.95)
        case .defaultOutput, .defaultInput: Color(red: 0.05, green: 0.65, blue: 0.68)
        case .application: Color(red: 0.96, green: 0.55, blue: 0.13)
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
        case .systemAudio: "macwindow.on.rectangle"
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
        if case .application(let app) = kind, let icon = NodeStyle.appIcon(app.bundleID) {
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
    let onWireEnd: (PendingWire) -> Void
    let onMove: (CGSize) -> Void
    let onMoveEnd: () -> Void

    var body: some View {
        let info = model.info
        let ports = info.ports(node)
        let labels = (inputs: channelLabels(ports.inputs), outputs: channelLabels(ports.outputs))
        let selected = model.selection == .node(node.id)
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
                    Text(info.subtitle(node))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                    model.updateNode(node.id) { $0.isMuted.toggle() }
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
            .simultaneousGesture(TapGesture().onEnded { model.selection = .node(node.id) })

            Rectangle().fill(.separator).frame(height: 0.5).padding(.horizontal, 10)

            VStack(spacing: 0) {
                ForEach(0..<NodeLayout.rows(ports), id: \.self) { row in
                    HStack(spacing: 6) {
                        if row < ports.inputs {
                            Text(labels.inputs[row])
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                            LevelBar(level: model.level(node.id, output: false, channel: row), tint: tint)
                        }
                        Spacer(minLength: 0)
                        if row < ports.outputs {
                            LevelBar(level: model.level(node.id, output: true, channel: row), tint: tint)
                            Text(labels.outputs[row])
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: NodeLayout.row)
                }
            }
            .padding(.top, NodeLayout.topPadding)
            .padding(.bottom, NodeLayout.bottomPadding)
        }
        .frame(width: NodeLayout.width, height: NodeLayout.height(for: ports), alignment: .top)
        .glassEffect(.regular.tint(tint.opacity(0.06)), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? Color.accentColor : (failing ? .red.opacity(0.7) : .clear), lineWidth: 2)
        }
        .opacity(isDisabledDevice ? 0.6 : 1)
        .overlay(alignment: .topLeading) { portOverlay(ports, tint: tint) }
        .contextMenu {
            Button(node.isMuted ? "Unmute" : "Mute") { model.updateNode(node.id) { $0.isMuted.toggle() } }
            Button("Disconnect All") { model.disconnectAll(node.id) }
            Divider()
            Button("Remove from Canvas", role: .destructive) { model.removeNode(node.id) }
        }
    }

    private var isDisabledDevice: Bool {
        if case .virtualDevice(let id) = node.kind { return !(model.graph.virtualDevice(id)?.isEnabled ?? false) }
        return false
    }

    /// Port dots on both edges, plus the "all channels" handles beside the header.
    @ViewBuilder private func portOverlay(_ ports: PortCounts, tint: Color) -> some View {
        let connectedOut = Set(model.graph.cables.filter { $0.from.node == node.id }.map(\.from.channel))
        let connectedIn = Set(model.graph.cables.filter { $0.to.node == node.id }.map(\.to.channel))
        ZStack(alignment: .topLeading) {
            ForEach(0..<ports.inputs, id: \.self) { channel in
                PortDot(filled: connectedIn.contains(channel), tint: tint)
                    .position(local(NodeLayout.inputPoint(node, channel)))
                    .gesture(wireGesture(.input(PortRef(node: node.id, channel: channel))))
                    .help("Input \(channel + 1): drag to a channel on the right side of another node")
            }
            ForEach(0..<ports.outputs, id: \.self) { channel in
                PortDot(filled: connectedOut.contains(channel), tint: tint)
                    .position(local(NodeLayout.outputPoint(node, channel)))
                    .gesture(wireGesture(.output(PortRef(node: node.id, channel: channel))))
                    .help("Output \(channel + 1): drag to a channel on the left side of another node")
            }
            if ports.outputs > 1 {
                BusHandle(tint: tint, pointsRight: true)
                    .position(local(NodeLayout.busOutputPoint(node)))
                    .gesture(wireGesture(.busOutput(node.id)))
                    .help("Drag onto another node to connect all channels in order")
            }
            if ports.inputs > 1 {
                BusHandle(tint: tint, pointsRight: true)
                    .position(local(NodeLayout.busInputPoint(node)))
                    .gesture(wireGesture(.busInput(node.id)))
                    .help("Drag onto another node to connect all of its channels here")
            }
        }
        .frame(width: NodeLayout.width, height: NodeLayout.height(for: ports), alignment: .topLeading)
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

struct PortDot: View {
    let filled: Bool
    let tint: Color
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(filled ? tint : Color(nsColor: .windowBackgroundColor))
            .overlay(Circle().strokeBorder(tint, lineWidth: 2))
            .frame(width: NodeLayout.portRadius * 2, height: NodeLayout.portRadius * 2)
            .scaleEffect(hovering ? 1.35 : 1)
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
    }
}
