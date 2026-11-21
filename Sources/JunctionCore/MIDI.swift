import Foundation

// MIDI control: any controller's knobs, faders, encoders, pads and program changes can drive a cable's level, a node's
// mute, an effect's bypass, a virtual device's on/off switch, or switch scenes. The mappings are saved in graph.json
// (`Graph.midi`); MIDI input runs wherever routing runs (Junction Helper, or Junction itself), so it works while the
// app is closed. `MIDIControl` turns each message into changes to the graph (`MIDIAction`); levels change through the
// router's gain setters, like a fader in the inspector, so no sink is rebuilt.

/// A MIDI 1.0 channel message Junction responds to.
public enum MIDIMessage: Equatable, Sendable {
    case controlChange(channel: Int, controller: Int, value: Int)
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int)
    case programChange(channel: Int, program: Int)

    /// Reads MIDI 1.0 bytes as they come over the wire: running status is followed, real-time bytes and system
    /// messages (SysEx included) are skipped, and so are messages Junction doesn't use. A note-on with velocity 0 is a
    /// note-off.
    public static func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        var status: UInt8 = 0
        var data: [UInt8] = []
        var inSysEx = false
        for byte in bytes {
            if byte >= 0xF8 { continue }  // real time: may come anywhere
            if byte >= 0x80 {
                data = []
                if byte == 0xF0 { inSysEx = true; status = 0; continue }
                inSysEx = false
                status = byte < 0xF0 ? byte : 0  // system common messages cancel running status
                continue
            }
            guard !inSysEx, status != 0 else { continue }
            data.append(byte)
            let needed = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            guard data.count == needed else { continue }
            if let message = message(status: status, data) { messages.append(message) }
            data = []
        }
        return messages
    }

    /// One word of a Universal MIDI Packet, as CoreMIDI delivers MIDI 1.0 (message type 2: a MIDI 1.0 channel voice
    /// message); other words give nil.
    public static func parse(umpWord word: UInt32) -> MIDIMessage? {
        guard word >> 28 == 0x2 else { return nil }
        let status = UInt8((word >> 16) & 0xFF)
        return message(status: status, [UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)])
    }

    /// How many 32-bit words a Universal MIDI Packet of this message type takes.
    public static func umpWordCount(_ word: UInt32) -> Int {
        [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(word >> 28)]
    }

    private static func message(status: UInt8, _ data: [UInt8]) -> MIDIMessage? {
        let channel = Int(status & 0x0F)
        switch status & 0xF0 {
        case 0x80: return .noteOff(channel: channel, note: Int(data[0]))
        case 0x90:
            return data[1] == 0 ? .noteOff(channel: channel, note: Int(data[0]))
                : .noteOn(channel: channel, note: Int(data[0]), velocity: Int(data[1]))
        case 0xB0:
            // 120–127 are channel mode messages (all notes off…), not controls.
            return data[0] < 120 ? .controlChange(channel: channel, controller: Int(data[0]), value: Int(data[1])) : nil
        case 0xC0: return .programChange(channel: channel, program: Int(data[0]))
        default: return nil
        }
    }
}

/// What a mapping listens to. Channels count from 0 (shown from 1).
public enum MIDITrigger: Codable, Hashable, Sendable {
    case controller(channel: Int, number: Int)
    case note(channel: Int, number: Int)
    case program(channel: Int, number: Int)

    /// "CC 7, channel 1", "Note C3, channel 10", "Program 5, channel 1".
    public var title: String {
        switch self {
        case .controller(let channel, let number): "CC \(number), channel \(channel + 1)"
        case .note(let channel, let number): "Note \(Self.noteName(number)), channel \(channel + 1)"
        case .program(let channel, let number): "Program \(number + 1), channel \(channel + 1)"
        }
    }

    public var isController: Bool {
        if case .controller = self { true } else { false }
    }

    /// Middle C (60) is C3, as most controllers and DAWs on the Mac name it.
    static func noteName(_ note: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[note % 12])\(note / 12 - 2)"
    }

    /// The trigger a message sets off when it is learned (note-offs set off nothing).
    init?(_ message: MIDIMessage) {
        switch message {
        case .controlChange(let channel, let controller, _): self = .controller(channel: channel, number: controller)
        case .noteOn(let channel, let note, _): self = .note(channel: channel, number: note)
        case .programChange(let channel, let program): self = .program(channel: channel, number: program)
        case .noteOff: return nil
        }
    }
}

/// How a controller's values are read.
public enum MIDIControlMode: String, Codable, CaseIterable, Sendable {
    /// A knob or fader: its value is the position (a level picks it up first, so it doesn't jump).
    case absolute
    /// A button: each press (a value of 64 or more after a lower one) flips a switch or switches a scene.
    case toggle
    /// An endless encoder sending 1…63 for up and 127…65 for down (two's complement).
    case relative
    /// An endless encoder sending 65… for up and 63… for down (offset by 64).
    case relativeOffset
    /// An endless encoder sending 1…63 for up and 65…127 for down (sign bit).
    case relativeSigned

    public var title: String {
        switch self {
        case .absolute: "Knob or fader"
        case .toggle: "Button"
        case .relative: "Encoder (127 = down)"
        case .relativeOffset: "Encoder (64 = still)"
        case .relativeSigned: "Encoder (65 = down)"
        }
    }

    public var isRelative: Bool { self == .relative || self == .relativeOffset || self == .relativeSigned }

    /// Steps an endless encoder turned (negative: down), or nil for other modes.
    public func steps(_ value: Int) -> Int? {
        switch self {
        case .absolute, .toggle: nil
        case .relative: value == 0 || value == 64 ? 0 : (value < 64 ? value : value - 128)
        case .relativeOffset: value - 64
        case .relativeSigned: value & 0x40 != 0 ? -(value & 0x3F) : value & 0x3F
        }
    }

    /// The modes that make sense for a target: no buttons for levels.
    public static func choices(for target: MIDITarget) -> [MIDIControlMode] {
        target.isLevel ? [.absolute, .relative, .relativeOffset, .relativeSigned] : allCases
    }
}

/// What a mapping controls.
public enum MIDITarget: Codable, Hashable, Sendable {
    /// A cable's level.
    case cableLevel(UUID)
    /// A node's mute (on: muted).
    case nodeMute(UUID)
    /// An effect's bypass (on: bypassed), wherever its node is.
    case effectBypass(UUID)
    /// Whether a virtual device is available to apps (on: available).
    case deviceEnabled(UUID)
    /// Switches to a scene.
    case scene(UUID)

    public var isLevel: Bool {
        if case .cableLevel = self { true } else { false }
    }

    /// Levels take knobs, faders and encoders only; switches and scenes also take notes and program changes.
    func accepts(_ trigger: MIDITrigger) -> Bool { !isLevel || trigger.isController }
}

/// One control on a controller and what it drives. `controller` names the MIDI source it was learned from (any
/// connected controller sending the same message drives it).
public struct MIDIMapping: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var target: MIDITarget
    public var trigger: MIDITrigger
    public var mode: MIDIControlMode
    public var controller: String?

    public init(id: UUID = UUID(), target: MIDITarget, trigger: MIDITrigger, mode: MIDIControlMode? = nil,
                controller: String? = nil) {
        self.id = id
        self.target = target
        self.trigger = trigger
        // A level is most likely a knob or fader; anything else on a controller is most likely a button.
        self.mode = mode ?? (target.isLevel ? .absolute : .toggle)
        self.controller = controller
    }
}

/// A change MIDI makes to the graph. The process that routes makes it, and tells the app, which makes it too.
public enum MIDIAction: Codable, Equatable, Sendable {
    case cableLevel(UUID, dB: Double)
    case nodeMute(UUID, Bool)
    case effectBypass(UUID, Bool)
    case deviceEnabled(UUID, Bool)
    case scene(UUID)
    /// MIDI learn heard a control: the new mapping (it replaces the target's earlier one).
    case learned(MIDIMapping)

    /// Makes the change; returns whether the graph changed.
    @discardableResult
    public func apply(to graph: inout Graph, inventory: Inventory) -> Bool {
        let before = graph
        switch self {
        case .cableLevel(let id, let dB):
            if let index = graph.cables.firstIndex(where: { $0.id == id }) { graph.cables[index].gainDB = dB }
        case .nodeMute(let id, let muted):
            if let index = graph.nodes.firstIndex(where: { $0.id == id }) { graph.nodes[index].isMuted = muted }
        case .effectBypass(let id, let bypass):
            for node in graph.nodes.indices {
                guard let index = graph.nodes[node].effects.firstIndex(where: { $0.id == id }) else { continue }
                graph.nodes[node].effects[index].bypass = bypass
            }
        case .deviceEnabled(let id, let enabled):
            if let index = graph.virtualDevices.firstIndex(where: { $0.id == id }) { graph.virtualDevices[index].isEnabled = enabled }
        case .scene(let id):
            if let scene = graph.scenes.first(where: { $0.id == id }) { Scenes.apply(scene, to: &graph, inventory: inventory) }
        case .learned(let mapping):
            graph.midi.removeAll { $0.target == mapping.target }
            graph.midi.append(mapping)
        }
        return graph != before
    }
}

/// Where a level sits on a controller's travel (0…1): the bottom is silence, 100 of 127 is 0 dB, the top is
/// `Gain.ceilingDB`. Linear in dB on each side of 0 dB, rounded to 0.1 dB.
public enum MIDIFader {
    static let unity = 100.0 / 127

    public static func dB(_ position: Double) -> Double {
        let position = min(max(position, 0), 1)
        let value = position <= unity
            ? Gain.floorDB * (1 - position / unity)
            : Gain.ceilingDB * (position - unity) / (1 - unity)
        return (value * 10).rounded() / 10
    }

    public static func position(_ dB: Double) -> Double {
        let dB = min(max(dB, Gain.floorDB), Gain.ceilingDB)
        return dB <= 0 ? unity * (1 - dB / Gain.floorDB) : unity + (1 - unity) * dB / Gain.ceilingDB
    }

    /// An encoder step.
    public static let stepDB = 0.5
    /// How close (in controller steps) a knob must come to the level before it takes it over.
    static let pickUpSteps = 1.5
}

/// Turns MIDI messages into changes, and learns new mappings. Keeps, per mapping, what pick-up and buttons need to
/// know between messages. Not thread-safe: use it from one queue.
public struct MIDIControl: Sendable {
    /// The target MIDI learn waits for a control for (nil: not learning).
    public private(set) var learning: MIDITarget?
    private var states: [UUID: State] = [:]

    struct State: Sendable {
        /// The controller's last value (0…127).
        var lastValue: Int?
        /// The knob has caught up with the level: its moves set the level.
        var engaged = false
        /// The level the knob last set; any other level means it was moved elsewhere, and must be picked up again.
        var setDB: Double?
    }

    public init() {}

    /// Starts MIDI learn for a target (nil stops it). The next suitable message makes its mapping.
    public mutating func learn(_ target: MIDITarget?) {
        learning = target
    }

    /// The changes one message makes. While learning, a suitable message only makes the mapping.
    public mutating func handle(_ message: MIDIMessage, from controller: String? = nil, graph: Graph) -> [MIDIAction] {
        if let target = learning {
            guard let trigger = MIDITrigger(message), target.accepts(trigger) else { return [] }
            learning = nil
            let mapping = MIDIMapping(target: target, trigger: trigger, controller: controller)
            if case .controlChange(_, _, let value) = message { states[mapping.id] = State(lastValue: value) }
            return [.learned(mapping)]
        }
        var actions: [MIDIAction] = []
        for mapping in graph.midi {
            if let action = handle(message, mapping, graph: graph) { actions.append(action) }
        }
        states = states.filter { id, _ in graph.midi.contains { $0.id == id } }
        return actions
    }

    private mutating func handle(_ message: MIDIMessage, _ mapping: MIDIMapping, graph: Graph) -> MIDIAction? {
        switch (message, mapping.trigger) {
        case (.controlChange(let channel, let number, let value), .controller(let wanted, let wantedNumber)):
            guard channel == wanted, number == wantedNumber else { return nil }
            var state = states[mapping.id] ?? State()
            let action = controlChange(value, mapping, &state, graph: graph)
            state.lastValue = value
            states[mapping.id] = state
            return action
        case (.noteOn(let channel, let number, _), .note(let wanted, let wantedNumber)),
             (.programChange(let channel, let number), .program(let wanted, let wantedNumber)):
            guard channel == wanted, number == wantedNumber else { return nil }
            return press(mapping.target, graph: graph)
        default:
            return nil
        }
    }

    private func controlChange(_ value: Int, _ mapping: MIDIMapping, _ state: inout State, graph: Graph) -> MIDIAction? {
        let target = mapping.target
        if case .cableLevel(let id) = target {
            guard let cable = graph.cables.first(where: { $0.id == id }) else { return nil }
            let current = cable.gainDB
            if let steps = mapping.mode.steps(value) {
                guard steps != 0 else { return nil }
                let from = max(current, Gain.floorDB)
                let dB = min(max(from + Double(steps) * MIDIFader.stepDB, Gain.floorDB), Gain.ceilingDB)
                return dB == current ? nil : .cableLevel(id, dB: dB)
            }
            // Pick-up: a knob that isn't where the level is takes it over only once it reaches it (or passes it).
            if let set = state.setDB, set != current { state.engaged = false }
            let position = Double(value) / 127, level = MIDIFader.position(current)
            if !state.engaged {
                let close = abs(position - level) <= MIDIFader.pickUpSteps / 127
                let crossed = state.lastValue.map { (Double($0) / 127 - level) * (position - level) <= 0 } ?? false
                guard close || crossed else { return nil }
                state.engaged = true
            }
            let dB = MIDIFader.dB(position)
            state.setDB = dB
            return dB == current ? nil : .cableLevel(id, dB: dB)
        }
        switch mapping.mode {
        case .absolute:
            if case .scene = target { return rising(value, state) ? press(target, graph: graph) : nil }
            return set(target, value >= 64, graph: graph)
        case .toggle:
            return rising(value, state) ? press(target, graph: graph) : nil
        case .relative, .relativeOffset, .relativeSigned:
            let steps = mapping.mode.steps(value) ?? 0
            guard steps != 0 else { return nil }
            if case .scene = target { return press(target, graph: graph) }
            return set(target, steps > 0, graph: graph)
        }
    }

    /// A button pressed: its value went to 64 or more from below (or it is the first one heard).
    private func rising(_ value: Int, _ state: State) -> Bool {
        value >= 64 && (state.lastValue ?? 0) < 64
    }

    /// A note, a program change or a button: flips a switch, or switches to the scene.
    private func press(_ target: MIDITarget, graph: Graph) -> MIDIAction? {
        if case .scene(let id) = target { return graph.scenes.contains { $0.id == id } ? .scene(id) : nil }
        guard let current = Self.isOn(target, in: graph) else { return nil }
        return set(target, !current, graph: graph)
    }

    /// Sets a switch, if that changes it.
    private func set(_ target: MIDITarget, _ on: Bool, graph: Graph) -> MIDIAction? {
        guard let current = Self.isOn(target, in: graph), current != on else { return nil }
        switch target {
        case .nodeMute(let id): return .nodeMute(id, on)
        case .effectBypass(let id): return .effectBypass(id, on)
        case .deviceEnabled(let id): return .deviceEnabled(id, on)
        case .cableLevel, .scene: return nil
        }
    }

    /// Whether a switch is on (muted, bypassed, available), or nil when its target isn't in the graph.
    static func isOn(_ target: MIDITarget, in graph: Graph) -> Bool? {
        switch target {
        case .nodeMute(let id): graph.node(id)?.isMuted
        case .effectBypass(let id): graph.nodes.lazy.compactMap { $0.effects.first { $0.id == id }?.bypass }.first
        case .deviceEnabled(let id): graph.virtualDevice(id)?.isEnabled
        case .cableLevel, .scene: nil
        }
    }
}

extension Graph {
    /// Forgets mappings whose target is gone: a deleted node, cable, effect, virtual device or scene. Targets a scene
    /// still holds are kept, so the control works again after switching to that scene.
    public mutating func pruneMIDI() {
        guard !midi.isEmpty else { return }
        let allNodes = nodes + scenes.flatMap(\.nodes)
        let nodeIDs = Set(allNodes.map(\.id))
        let cableIDs = Set((cables + scenes.flatMap(\.cables)).map(\.id))
        let effectIDs = Set(allNodes.flatMap { $0.effects.map(\.id) })
        let deviceIDs = Set(virtualDevices.map(\.id)), sceneIDs = Set(scenes.map(\.id))
        midi.removeAll { mapping in
            switch mapping.target {
            case .cableLevel(let id): !cableIDs.contains(id)
            case .nodeMute(let id): !nodeIDs.contains(id)
            case .effectBypass(let id): !effectIDs.contains(id)
            case .deviceEnabled(let id): !deviceIDs.contains(id)
            case .scene(let id): !sceneIDs.contains(id)
            }
        }
    }

    /// The mapping that drives a target, if any.
    public func midiMapping(for target: MIDITarget) -> MIDIMapping? { midi.first { $0.target == target } }

    /// What a mapping drives, for Settings and the learn banner: "Microphone → Stream Mix L · Level".
    public func describe(_ target: MIDITarget, inventory: Inventory) -> String {
        let info = NodeInfo(graph: self, inventory: inventory)
        func title(_ id: UUID) -> String? {
            (node(id) ?? scenes.lazy.compactMap { $0.nodes.first { $0.id == id } }.first).map(info.title)
        }
        switch target {
        case .cableLevel(let id):
            guard let cable = cables.first(where: { $0.id == id }) ?? scenes.lazy.compactMap({ $0.cables.first { $0.id == id } }).first
            else { return "A deleted cable · Level" }
            func end(_ port: PortRef, outputs: Bool) -> String {
                guard let node = node(port.node) else { return title(port.node) ?? "?" }
                let labels = info.channelLabels(node, outputs: outputs)
                return "\(info.title(node)) \(port.channel < labels.count ? labels[port.channel] : "\(port.channel + 1)")"
            }
            return "\(end(cable.from, outputs: true)) → \(end(cable.to, outputs: false)) · Level"
        case .nodeMute(let id):
            return "\(title(id) ?? "A deleted node") · Mute"
        case .effectBypass(let id):
            let holder = (nodes + scenes.flatMap(\.nodes)).first { $0.effects.contains { $0.id == id } }
            let effect = holder?.effects.first { $0.id == id }
            return "\(effect?.title ?? "An effect") on \(holder.map(info.title) ?? "a deleted node") · Bypass"
        case .deviceEnabled(let id):
            return "\(virtualDevice(id)?.name ?? "A deleted device") · Available to apps"
        case .scene(let id):
            return "Scene \(scenes.first { $0.id == id }?.name ?? "?")"
        }
    }
}
