import XCTest
@testable import JunctionCore

/// MIDI control, fed with messages as a controller sends them (raw bytes, recorded).
final class MIDITests: XCTestCase {
    /// Chat (the mic, through a gate, into both channels; out to the speakers), with a scene where Chat is off.
    private struct Setup {
        var graph: Graph
        let inventory = Demo.inventory
        let chatNode: Node
        let mic: Node
        let speakers: Node
        let gate: Effect
        var micLeft: Cable { graph.cables[0] }
    }

    private func setup() -> Setup {
        let gate = Effect(.gate)
        let chatNode = Node(kind: .virtualDevice(Demo.chat.id), x: CanvasColumn.device, y: 60, canvas: Demo.chat.id)
        let mic = Node(kind: .device(Demo.mic.ref), x: CanvasColumn.sources, y: 60, canvas: Demo.chat.id, effects: [gate])
        let speakers = Node(kind: .device(Demo.speakers.ref), x: CanvasColumn.outputs, y: 60, canvas: Demo.chat.id)
        var graph = Graph(virtualDevices: [Demo.chat], nodes: [chatNode, mic, speakers])
        graph.cables = [
            Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: chatNode.id, channel: 0), gainDB: 0),
            Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: chatNode.id, channel: 1), gainDB: 0),
            Cable(from: PortRef(node: chatNode.id, channel: 0), to: PortRef(node: speakers.id, channel: 0)),
        ]
        var quiet = graph
        quiet.virtualDevices[0].isEnabled = false
        graph.scenes = [RoutingScene(name: "Everything", capturing: graph), RoutingScene(name: "Quiet", capturing: quiet)]
        return Setup(graph: graph, chatNode: chatNode, mic: mic, speakers: speakers, gate: gate)
    }

    /// Feeds recorded bytes through a control: applies what they do, returns the actions.
    @discardableResult
    private func play(_ bytes: [UInt8], _ control: inout MIDIControl, _ setup: inout Setup) -> [MIDIAction] {
        var actions: [MIDIAction] = []
        for message in MIDIMessage.parse(bytes) {
            for action in control.handle(message, from: "Test Controller", graph: setup.graph)
            where action.apply(to: &setup.graph, inventory: setup.inventory) {
                actions.append(action)
            }
        }
        return actions
    }

    private func level(_ setup: Setup) -> Double { setup.micLeft.gainDB }

    // MARK: Messages

    func testParsesRecordedMessages() {
        // CC 7 = 100 on channel 1, then 90 under running status with a clock byte in between; a SysEx message (ignored,
        // and its data bytes don't count); a note on and its note-off as a zero-velocity note on (running status); a
        // program change on channel 10; channel mode "all notes off" (ignored); a note-off; a stray data byte.
        let bytes: [UInt8] = [0xB0, 0x07, 0x64, 0xF8, 0x07, 0x5A,
                              0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7,
                              0x90, 0x24, 0x7F, 0x24, 0x00,
                              0xC9, 0x04,
                              0xB0, 0x7B, 0x00,
                              0x81, 0x30, 0x40,
                              0x11]
        XCTAssertEqual(MIDIMessage.parse(bytes), [
            .controlChange(channel: 0, controller: 7, value: 100),
            .controlChange(channel: 0, controller: 7, value: 90),
            .noteOn(channel: 0, note: 36, velocity: 127),
            .noteOff(channel: 0, note: 36),
            .programChange(channel: 9, program: 4),
            .noteOff(channel: 1, note: 48),
        ])
        // CoreMIDI's Universal MIDI Packets (MIDI 1.0 channel voice: message type 2, group 0).
        XCTAssertEqual(MIDIMessage.parse(umpWord: 0x20B0_0764), .controlChange(channel: 0, controller: 7, value: 100))
        XCTAssertEqual(MIDIMessage.parse(umpWord: 0x20C9_0400), .programChange(channel: 9, program: 4))
        XCTAssertNil(MIDIMessage.parse(umpWord: 0x10F8_0000), "system real time")
        XCTAssertEqual(MIDIMessage.umpWordCount(0x3000_0000), 2, "SysEx packets take two words")
        XCTAssertEqual(MIDIMessage.umpWordCount(0x4000_0000), 2, "MIDI 2.0 channel voice takes two words")
        XCTAssertEqual(MIDITrigger.controller(channel: 0, number: 7).title, "CC 7, channel 1")
        XCTAssertEqual(MIDITrigger.note(channel: 9, number: 60).title, "Note C3, channel 10")
        XCTAssertEqual(MIDITrigger.program(channel: 0, number: 4).title, "Program 5, channel 1")
    }

    // MARK: Levels

    func testFaderCurve() {
        XCTAssertEqual(MIDIFader.dB(0), Gain.floorDB, "the bottom is silence")
        XCTAssertEqual(MIDIFader.dB(100.0 / 127), 0, "100 is 0 dB")
        XCTAssertEqual(MIDIFader.dB(1), Gain.ceilingDB)
        for value in 0...127 {
            let dB = MIDIFader.dB(Double(value) / 127)
            XCTAssertEqual(MIDIFader.position(dB), Double(value) / 127, accuracy: 0.5 / 127, "value \(value)")
        }
    }

    func testAbsoluteLevelPicksUpBeforeMoving() {
        var setup = setup()
        var control = MIDIControl()
        let mapping = MIDIMapping(target: .cableLevel(setup.micLeft.id), trigger: .controller(channel: 0, number: 7))
        XCTAssertEqual(mapping.mode, .absolute, "a level is read as a knob or fader")
        setup.graph.midi = [mapping]
        // The fader sits at the bottom while the level is 0 dB (100): moving it up to 60 doesn't touch the level…
        XCTAssertEqual(play([0xB0, 0x07, 0x00, 0x07, 0x14, 0x07, 0x3C], &control, &setup), [])
        XCTAssertEqual(level(setup), 0)
        // …another controller's CC 7, or another channel's, does nothing either…
        XCTAssertEqual(play([0xB1, 0x07, 0x64, 0xB0, 0x08, 0x64], &control, &setup), [])
        // …until it passes the level (60 → 110 jumps over 100): from there it drives it.
        XCTAssertEqual(play([0xB0, 0x07, 0x6E], &control, &setup), [.cableLevel(setup.micLeft.id, dB: MIDIFader.dB(110.0 / 127))])
        XCTAssertEqual(play([0xB0, 0x07, 0x50], &control, &setup).count, 1)
        XCTAssertEqual(level(setup), MIDIFader.dB(80.0 / 127))
        XCTAssertEqual(play([0xB0, 0x07, 0x00], &control, &setup).count, 1)
        XCTAssertEqual(level(setup), Gain.floorDB, "all the way down is silence")
        XCTAssertEqual(play([0xB0, 0x07, 0x00], &control, &setup), [], "the same value changes nothing")

        // Someone sets the level in the inspector (−12 dB): the fader has to pick it up again.
        setup.graph.cables[0].gainDB = -12
        XCTAssertEqual(play([0xB0, 0x07, 0x10], &control, &setup), [], "far below the new level")
        XCTAssertEqual(level(setup), -12)
        let near = Int((MIDIFader.position(-12) * 127).rounded()) + 1  // a step above it
        XCTAssertEqual(play([0xB0, 0x07, UInt8(near)], &control, &setup).count, 1, "coming close takes it over")
        XCTAssertEqual(level(setup), MIDIFader.dB(Double(near) / 127))
        XCTAssertEqual(level(setup), -12, accuracy: 1)
        XCTAssertEqual(play([0xB0, 0x07, 0x64], &control, &setup).count, 1)
        XCTAssertEqual(level(setup), 0)
        XCTAssertEqual(setup.graph.cables[1].gainDB, 0, "the other cable is left alone")
    }

    func testRelativeEncoders() {
        let cases: [(MIDIControlMode, up: UInt8, down: UInt8, twoDown: UInt8)] = [
            (.relative, 0x01, 0x7F, 0x7E),        // two's complement
            (.relativeOffset, 0x41, 0x3F, 0x3E),  // offset by 64
            (.relativeSigned, 0x01, 0x41, 0x42),  // sign bit
        ]
        for (mode, up, down, twoDown) in cases {
            var setup = setup()
            var control = MIDIControl()
            setup.graph.midi = [MIDIMapping(target: .cableLevel(setup.micLeft.id), trigger: .controller(channel: 0, number: 16),
                                            mode: mode)]
            // No pick-up: an encoder has no position, it nudges the level from wherever it is.
            play([0xB0, 0x10, up], &control, &setup)
            XCTAssertEqual(level(setup), MIDIFader.stepDB, "\(mode)")
            play([0xB0, 0x10, down, 0x10, twoDown], &control, &setup)
            XCTAssertEqual(level(setup), -2 * MIDIFader.stepDB, "\(mode)")
            setup.graph.cables[0].gainDB = Gain.ceilingDB - 0.2
            play([0xB0, 0x10, up, 0x10, up], &control, &setup)
            XCTAssertEqual(level(setup), Gain.ceilingDB, "\(mode) stops at the top")
            setup.graph.cables[0].gainDB = Gain.floorDB
            XCTAssertEqual(play([0xB0, 0x10, down], &control, &setup), [], "\(mode) can't go below silence")
            play([0xB0, 0x10, up], &control, &setup)
            XCTAssertEqual(level(setup), Gain.floorDB + MIDIFader.stepDB, "\(mode) comes up from silence")
        }
        XCTAssertEqual(MIDIControlMode.relative.steps(64), 0)
        XCTAssertEqual(MIDIControlMode.relativeOffset.steps(64), 0)
        XCTAssertEqual(MIDIControlMode.relativeSigned.steps(0x45), -5)
    }

    // MARK: Switches and scenes

    func testSwitchesFromButtonsKnobsEncodersNotesAndProgramChanges() {
        var setup = setup()
        var control = MIDIControl()
        let mute = MIDIMapping(target: .nodeMute(setup.mic.id), trigger: .controller(channel: 0, number: 20))
        XCTAssertEqual(mute.mode, .toggle, "a switch is read as a button")
        let bypass = MIDIMapping(target: .effectBypass(setup.gate.id), trigger: .note(channel: 9, number: 36))
        let device = MIDIMapping(target: .deviceEnabled(Demo.chat.id), trigger: .program(channel: 0, number: 7))
        setup.graph.midi = [mute, bypass, device]
        func muted() -> Bool { setup.graph.node(setup.mic.id)!.isMuted }
        func bypassed() -> Bool { setup.graph.node(setup.mic.id)!.effects[0].bypass }
        func enabled() -> Bool { setup.graph.virtualDevice(Demo.chat.id)!.isEnabled }

        // A button: press (127) flips, release (0) doesn't; press again flips back.
        play([0xB0, 0x14, 0x7F], &control, &setup)
        XCTAssertTrue(muted())
        play([0xB0, 0x14, 0x00], &control, &setup)
        XCTAssertTrue(muted(), "letting go doesn't unmute")
        play([0xB0, 0x14, 0x7F, 0x14, 0x00], &control, &setup)
        XCTAssertFalse(muted())

        // Read as a knob (absolute): the top half is on, the bottom half off.
        setup.graph.midi[0].mode = .absolute
        play([0xB0, 0x14, 0x50], &control, &setup)
        XCTAssertTrue(muted())
        XCTAssertEqual(play([0xB0, 0x14, 0x70], &control, &setup), [], "still on: nothing to change")
        play([0xB0, 0x14, 0x10], &control, &setup)
        XCTAssertFalse(muted())
        // As an encoder: up is on, down is off.
        setup.graph.midi[0].mode = .relative
        play([0xB0, 0x14, 0x01], &control, &setup)
        XCTAssertTrue(muted())
        play([0xB0, 0x14, 0x7F], &control, &setup)
        XCTAssertFalse(muted())

        // A pad (note): each hit flips the bypass; its note-off does nothing, nor does another note or channel.
        play([0x99, 0x24, 0x64, 0x89, 0x24, 0x00], &control, &setup)
        XCTAssertTrue(bypassed())
        play([0x99, 0x25, 0x64, 0x90, 0x24, 0x64], &control, &setup)
        XCTAssertTrue(bypassed())
        play([0x99, 0x24, 0x40], &control, &setup)
        XCTAssertFalse(bypassed())

        // A program change flips the device.
        play([0xC0, 0x07], &control, &setup)
        XCTAssertFalse(enabled())
        play([0xC0, 0x06], &control, &setup)
        XCTAssertFalse(enabled(), "another program")
        play([0xC0, 0x07], &control, &setup)
        XCTAssertTrue(enabled())
    }

    func testScenesSwitchFromProgramChangesAndButtons() throws {
        var setup = setup()
        var control = MIDIControl()
        let everything = setup.graph.scenes[0], quiet = setup.graph.scenes[1]
        setup.graph.midi = [
            MIDIMapping(target: .scene(everything.id), trigger: .program(channel: 0, number: 0)),
            MIDIMapping(target: .scene(quiet.id), trigger: .program(channel: 0, number: 1)),
            MIDIMapping(target: .scene(everything.id), trigger: .controller(channel: 0, number: 80)),
        ]
        XCTAssertEqual(play([0xC0, 0x01], &control, &setup), [.scene(quiet.id)])
        XCTAssertTrue(Scenes.isCurrent(quiet, in: setup.graph))
        XCTAssertFalse(try XCTUnwrap(setup.graph.virtualDevice(Demo.chat.id)).isEnabled)
        // A button switches on its press only.
        XCTAssertEqual(play([0xB0, 0x50, 0x7F], &control, &setup), [.scene(everything.id)])
        XCTAssertTrue(Scenes.isCurrent(everything, in: setup.graph))
        play([0xC0, 0x01], &control, &setup)
        XCTAssertEqual(play([0xB0, 0x50, 0x00], &control, &setup), [], "letting go doesn't switch")
        XCTAssertTrue(Scenes.isCurrent(quiet, in: setup.graph))
        play([0xC0, 0x00], &control, &setup)
        XCTAssertTrue(Scenes.isCurrent(everything, in: setup.graph))
    }

    // MARK: Learn

    func testLearnTakesTheNextSuitableControl() throws {
        var setup = setup()
        var control = MIDIControl()
        // A level only learns knobs, faders and encoders: a note or program change while learning is passed over.
        control.learn(.cableLevel(setup.micLeft.id))
        XCTAssertEqual(play([0x90, 0x3C, 0x7F, 0xC0, 0x02], &control, &setup), [])
        XCTAssertEqual(control.learning, .cableLevel(setup.micLeft.id))
        let learned = play([0xB2, 0x15, 0x64], &control, &setup)
        XCTAssertEqual(learned.count, 1)
        XCTAssertNil(control.learning, "learning ends with the control it heard")
        let mapping = try XCTUnwrap(setup.graph.midi.first)
        XCTAssertEqual(learned, [.learned(mapping)])
        XCTAssertEqual(mapping.trigger, .controller(channel: 2, number: 21))
        XCTAssertEqual(mapping.mode, .absolute)
        XCTAssertEqual(mapping.controller, "Test Controller")
        XCTAssertEqual(level(setup), 0, "the message it learned from moves nothing")
        // The knob was where it was learned (100, the level): it drives the level straight away.
        play([0xB2, 0x15, 0x5A], &control, &setup)
        XCTAssertEqual(level(setup), MIDIFader.dB(90.0 / 127))

        // A switch learns a pad; learning again replaces the target's mapping, and other targets keep theirs.
        control.learn(.nodeMute(setup.mic.id))
        play([0x99, 0x24, 0x7F], &control, &setup)
        XCTAssertEqual(setup.graph.midi.count, 2)
        XCTAssertFalse(setup.graph.node(setup.mic.id)!.isMuted)
        control.learn(.nodeMute(setup.mic.id))
        play([0x90, 0x30, 0x7F], &control, &setup)
        XCTAssertEqual(setup.graph.midi.count, 2)
        XCTAssertEqual(setup.graph.midiMapping(for: .nodeMute(setup.mic.id))?.trigger, .note(channel: 0, number: 48))
        play([0x99, 0x24, 0x7F], &control, &setup)
        XCTAssertFalse(setup.graph.node(setup.mic.id)!.isMuted, "the old pad doesn't drive it any more")
        play([0x90, 0x30, 0x7F], &control, &setup)
        XCTAssertTrue(setup.graph.node(setup.mic.id)!.isMuted)

        // A scene learns a program change; learning can be stopped.
        control.learn(.scene(setup.graph.scenes[1].id))
        play([0xC0, 0x05], &control, &setup)
        XCTAssertEqual(setup.graph.midiMapping(for: .scene(setup.graph.scenes[1].id))?.trigger, .program(channel: 0, number: 5))
        control.learn(.deviceEnabled(Demo.chat.id))
        control.learn(nil)
        XCTAssertEqual(play([0xC0, 0x09], &control, &setup), [])
        XCTAssertNil(setup.graph.midiMapping(for: .deviceEnabled(Demo.chat.id)))
        XCTAssertEqual(setup.graph.describe(.nodeMute(setup.mic.id), inventory: setup.inventory), "MacBook Pro Microphone · Mute")
        XCTAssertEqual(setup.graph.describe(.scene(setup.graph.scenes[1].id), inventory: setup.inventory), "Scene Quiet")
    }

    // MARK: Saving and cleaning up

    func testMappingsAreSavedWithTheGraph() throws {
        var setup = setup()
        setup.graph.midi = [
            MIDIMapping(target: .cableLevel(setup.micLeft.id), trigger: .controller(channel: 0, number: 7), mode: .relativeOffset,
                        controller: "Desk"),
            MIDIMapping(target: .nodeMute(setup.mic.id), trigger: .note(channel: 9, number: 36)),
            MIDIMapping(target: .effectBypass(setup.gate.id), trigger: .controller(channel: 0, number: 64), mode: .absolute),
            MIDIMapping(target: .deviceEnabled(Demo.chat.id), trigger: .program(channel: 3, number: 2)),
            MIDIMapping(target: .scene(setup.graph.scenes[0].id), trigger: .program(channel: 0, number: 0)),
        ]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-midi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try store.save(setup.graph)
        let text = try String(contentsOf: store.graphURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"midi\""))
        XCTAssertTrue(text.contains("\"schema\" : 4"))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.midi, setup.graph.midi)
        XCTAssertEqual(loaded, setup.graph)

        // A schema 4 file from before MIDI control has no "midi": it loads with none.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup.graph)) as? [String: Any])
        object["midi"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: store.graphURL)
        XCTAssertEqual(store.load()?.midi, [])
    }

    func testMappingsGoWithWhatTheyDrive() {
        var setup = setup()
        let mute = MIDIMapping(target: .nodeMute(setup.mic.id), trigger: .note(channel: 0, number: 36))
        let level = MIDIMapping(target: .cableLevel(setup.micLeft.id), trigger: .controller(channel: 0, number: 7))
        let bypass = MIDIMapping(target: .effectBypass(setup.gate.id), trigger: .controller(channel: 0, number: 64))
        let speakers = MIDIMapping(target: .nodeMute(setup.speakers.id), trigger: .note(channel: 0, number: 37))
        let device = MIDIMapping(target: .deviceEnabled(Demo.chat.id), trigger: .program(channel: 0, number: 2))
        let scene = MIDIMapping(target: .scene(setup.graph.scenes[1].id), trigger: .program(channel: 0, number: 1))
        setup.graph.midi = [mute, level, bypass, speakers, device, scene]
        setup.graph.scenes = [setup.graph.scenes[1]]  // only Quiet, which holds every node and cable

        // Deleted from the canvas but kept by a scene: the mapping stays, for when the scene comes back.
        var graph = setup.graph
        Editing.remove([setup.mic.id], from: &graph)
        XCTAssertEqual(graph.midi, setup.graph.midi)

        // Without the scene, deleting a node takes its mute, its cables' levels and its effects' bypasses with it.
        graph = setup.graph
        graph.scenes = []
        graph.pruneMIDI()
        XCTAssertEqual(graph.midi, [mute, level, bypass, speakers, device], "the deleted scene's mapping went")
        Editing.remove([setup.mic.id], from: &graph)
        XCTAssertEqual(graph.midi, [speakers, device])
        graph.removeNode(setup.speakers.id)
        XCTAssertEqual(graph.midi, [device])
        // A cable disconnected, an effect removed: gone on the next prune (the app prunes after every edit).
        graph = setup.graph
        graph.scenes = []
        graph.cables.removeAll { $0.id == setup.micLeft.id }
        if let index = graph.nodes.firstIndex(where: { $0.id == setup.mic.id }) { graph.nodes[index].effects = [] }
        graph.pruneMIDI()
        XCTAssertEqual(graph.midi, [mute, speakers, device])
        // Deleting the virtual device takes its canvas, and every mapping on it, also from the scenes.
        graph = setup.graph
        graph.removeVirtualDevice(Demo.chat.id)
        XCTAssertEqual(graph.midi, [scene])
        // Loading drops mappings whose target is gone (a file edited by hand, or written by an older build).
        var loaded = setup.graph
        loaded.midi.append(MIDIMapping(target: .nodeMute(UUID()), trigger: .note(channel: 0, number: 1)))
        loaded.upgrade()
        XCTAssertEqual(loaded.midi, setup.graph.midi)
    }
}
