import Foundation

/// A named setup to switch to: which virtual devices are on, their volumes and mutes, and each one's canvas (its
/// nodes with their levels and mutes, and its cables). Virtual devices themselves (name, channels, rate, direction)
/// aren't part of it, so switching never re-publishes a device in another format.
///
/// Switching leaves virtual devices the scene doesn't know (made after it) as they are; parts of the scene for
/// devices deleted since are dropped (`Graph.removeVirtualDevice`, `Graph.upgrade`).
public struct RoutingScene: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var devices: [SceneDevice]
    public var nodes: [Node]
    public var cables: [Cable]

    public init(id: UUID = UUID(), name: String, devices: [SceneDevice] = [], nodes: [Node] = [], cables: [Cable] = []) {
        self.id = id
        self.name = name
        self.devices = devices
        self.nodes = nodes
        self.cables = cables
    }

    /// The setup as it is now.
    public init(id: UUID = UUID(), name: String, capturing graph: Graph) {
        self.init(id: id, name: name, devices: graph.virtualDevices.map(SceneDevice.init), nodes: graph.nodes,
                  cables: graph.cables)
    }

    public func device(_ id: UUID) -> SceneDevice? { devices.first { $0.id == id } }

    /// Forgets everything about virtual devices that aren't in `kept`.
    mutating func keepOnly(_ kept: Set<UUID>) {
        devices.removeAll { !kept.contains($0.id) }
        nodes.removeAll { node in node.canvas.map { !kept.contains($0) } ?? true }
        let ids = Set(nodes.map(\.id))
        cables.removeAll { !ids.contains($0.from.node) || !ids.contains($0.to.node) }
    }
}

/// What a scene remembers of one virtual device.
public struct SceneDevice: Codable, Hashable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var outputVolume: Double
    public var outputMuted: Bool
    public var inputVolume: Double
    public var inputMuted: Bool

    public init(_ device: VirtualDevice) {
        id = device.id
        isEnabled = device.isEnabled
        outputVolume = device.outputVolume
        outputMuted = device.outputMuted
        inputVolume = device.inputVolume
        inputMuted = device.inputMuted
    }

    func apply(to device: inout VirtualDevice) {
        device.isEnabled = isEnabled
        device.outputVolume = outputVolume
        device.outputMuted = outputMuted
        device.inputVolume = inputVolume
        device.inputMuted = inputMuted
    }
}

public enum Scenes {
    /// A name no scene has yet: `base`, then "`base` 2", "`base` 3"…
    public static func newName(in graph: Graph, base: String = "Scene") -> String {
        var candidate = base, number = 2
        while graph.scenes.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// Switches to a scene. Canvases that already look the way the scene has them aren't touched, so the sinks on
    /// them keep running; the router rebuilds (and cross-fades) only the sinks whose structure changed, and gives the
    /// others their new levels.
    public static func apply(_ scene: RoutingScene, to graph: inout Graph, inventory: Inventory) {
        for index in graph.virtualDevices.indices {
            scene.device(graph.virtualDevices[index].id)?.apply(to: &graph.virtualDevices[index])
        }
        for device in changedCanvases(scene, in: graph) {
            let wanted = canvas(device, of: scene, in: graph)
            let gone = Set(graph.nodes(on: device).map(\.id))
            graph.nodes.removeAll { gone.contains($0.id) }
            graph.cables.removeAll { gone.contains($0.from.node) || gone.contains($0.to.node) }
            graph.nodes += wanted.nodes
            graph.cables += wanted.cables
        }
        let info = NodeInfo(graph: graph, inventory: inventory)
        graph.pruneCables { info.ports($0) }
        graph.tidyCanvases()
    }

    /// Whether the setup is the scene's: switching to it would change nothing.
    public static func isCurrent(_ scene: RoutingScene, in graph: Graph) -> Bool {
        let covered = graph.virtualDevices.filter { scene.device($0.id) != nil }
        guard !covered.isEmpty else { return false }
        return covered.allSatisfy { scene.device($0.id) == SceneDevice($0) } && changedCanvases(scene, in: graph).isEmpty
    }

    /// The virtual devices whose canvas the scene has differently.
    public static func changedCanvases(_ scene: RoutingScene, in graph: Graph) -> [UUID] {
        graph.virtualDevices.map(\.id).filter { device in
            guard scene.device(device) != nil else { return false }
            let wanted = canvas(device, of: scene, in: graph)
            return Set(wanted.nodes) != Set(graph.nodes(on: device)) || Set(wanted.cables) != Set(graph.cables(on: device))
        }
    }

    /// The scene's canvas for a device, with its device node taking the ID the device node has now (so the sink it
    /// stands for keeps its identity).
    static func canvas(_ device: UUID, of scene: RoutingScene, in graph: Graph) -> (nodes: [Node], cables: [Cable]) {
        var nodes = scene.nodes.filter { $0.canvas == device }
        let ids = Set(nodes.map(\.id))
        var cables = scene.cables.filter { ids.contains($0.from.node) && ids.contains($0.to.node) }
        if let current = graph.deviceNode(device),
           let index = nodes.firstIndex(where: { $0.kind == .virtualDevice(device) }), nodes[index].id != current.id {
            let old = nodes[index].id
            nodes[index].id = current.id
            for i in cables.indices {
                if cables[i].from.node == old { cables[i].from.node = current.id }
                if cables[i].to.node == old { cables[i].to.node = current.id }
            }
        }
        return (nodes, cables)
    }
}
