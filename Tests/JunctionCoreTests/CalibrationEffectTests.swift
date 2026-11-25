import Foundation
import JunctionKernel
import XCTest
@testable import JunctionCore

// The Calibration effect: the kernel's correction stage against the profile's computed curves, its delay and level,
// Amount, settings changing while it renders, and the profile in graph.json.

final class CalibrationEffectTests: XCTestCase {
    /// A made-up headphone preset: shelves and peaks that settle within a few thousand frames.
    private func headphones() -> CalibrationProfile {
        CalibrationProfile(name: "Studio Cans", kind: .headphones,
                           date: Date(timeIntervalSinceReferenceDate: 800_000_000), deviceUID: "demo.headphones",
                           deviceName: "Headphones",
                           channels: [CalibrationChannel(filters: [
                               CalibrationFilter(.lowShelf, frequency: 105, gain: 5.5, q: 0.7),
                               CalibrationFilter(.peaking, frequency: 180, gain: -3.2, q: 1.4),
                               CalibrationFilter(.peaking, frequency: 1_200, gain: 2.1, q: 2),
                               CalibrationFilter(.peaking, frequency: 3_100, gain: -5, q: 4),
                               CalibrationFilter(.peaking, frequency: 6_000, gain: 1.5, q: 0.9, isOn: false),
                               CalibrationFilter(.highShelf, frequency: 9_000, gain: -2.5, q: 0.7),
                               CalibrationFilter(.peaking, frequency: 15_000, gain: 3, q: 2),
                           ])],
                           preamp: -6)
    }

    /// Two speakers with their own filters, delays and levels.
    private func speakers() -> CalibrationProfile {
        CalibrationProfile(name: "Desk", kind: .speakers, date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                           deviceUID: "demo.speakers", deviceName: "Speakers",
                           channels: [CalibrationChannel(filters: [CalibrationFilter(.peaking, frequency: 60, gain: -8, q: 3),
                                                                   CalibrationFilter(.peaking, frequency: 2_500, gain: 2, q: 1.2)],
                                                         delay: 0.0004, level: 0),
                                      CalibrationChannel(filters: [CalibrationFilter(.lowShelf, frequency: 90, gain: -4, q: 0.7),
                                                                   CalibrationFilter(.peaking, frequency: 450, gain: -6, q: 5)],
                                                         delay: 0, level: -1.5)],
                           preamp: -2, measurements: [CalibrationMeasurement(channel: 0, position: nil,
                                                                             curve: CalibrationCurve(levels: CalibrationGrid.frequencies.map { 3 * sin(log2($0)) }))])
    }

    private func calibration(_ profile: CalibrationProfile?, amount: Double = 100) -> Effect {
        var effect = Effect(.calibration)
        effect.calibration = profile
        effect.set(EffectKind.calibration.parameters[0], amount)
        return effect
    }

    /// Non-interleaved channels the tests fill and read.
    private final class Channels {
        let pointers: [UnsafeMutablePointer<Float>]
        let frames: Int

        init(_ count: Int, frames: Int) {
            self.frames = frames
            pointers = (0..<count).map { _ in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                pointer.initialize(repeating: 0, count: frames)
                return pointer
            }
        }

        deinit { pointers.forEach { $0.deallocate() } }

        func process(_ chain: LiveChain, frames: Int? = nil) {
            pointers.withUnsafeBufferPointer {
                jk_chain_process(chain.pointer, $0.baseAddress!, UInt32(pointers.count), UInt32(frames ?? self.frames))
            }
        }
    }

    /// The chain's impulse response per channel, `length` frames, rendered in buffers of 512.
    private func impulseResponse(_ chain: LiveChain, channels: Int, length: Int) -> [[Double]] {
        let buffer = Channels(channels, frames: 512)
        var response = [[Double]](repeating: [], count: channels)
        var rendered = 0
        while rendered < length {
            for c in 0..<channels {
                for f in 0..<512 { buffer.pointers[c][f] = rendered + f == 0 ? 1 : 0 }
            }
            buffer.process(chain)
            for c in 0..<channels { response[c] += (0..<512).map { Double(buffer.pointers[c][$0]) } }
            rendered += 512
        }
        return response
    }

    /// The magnitude in dB of a response at a frequency (its DFT there).
    private func magnitude(_ response: [Double], at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        var (re, im) = (0.0, 0.0)
        for (n, value) in response.enumerated() where value != 0 {
            re += value * cos(w * Double(n))
            im -= value * sin(w * Double(n))
        }
        return 10 * log10(re * re + im * im)
    }

    /// Grid frequencies a rate carries (below 0.45 × the rate).
    private func frequencies(_ sampleRate: Double) -> [Double] {
        CalibrationGrid.frequencies.enumerated().filter { $0.offset % 6 == 0 && $0.element < 0.45 * sampleRate }.map(\.element)
    }

    private func assertMatchesCurve(_ profile: CalibrationProfile, amount: Double, sampleRate: Double, length: Int,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let channels = profile.channels.count
        let chain = try XCTUnwrap(LiveChain([calibration(profile, amount: amount)], position: .mix, channels: channels,
                                            sampleRate: sampleRate, pool: EffectPool()))
        let responses = impulseResponse(chain, channels: channels, length: length)
        let expected = profile.scaled(by: amount / 100)
        let grid = frequencies(sampleRate)
        for c in 0..<channels {
            let curve = expected.curve(channel: c, sampleRate: sampleRate, at: grid)
            for (frequency, level) in zip(grid, curve) {
                let measured = magnitude(responses[c], at: frequency, sampleRate: sampleRate)
                XCTAssertEqual(measured, level, accuracy: 0.1,
                               "channel \(c + 1) at \(Int(frequency)) Hz, \(Int(sampleRate)) Hz, amount \(Int(amount)) %",
                               file: file, line: line)
            }
        }
    }

    // MARK: The kernel against the computed curves

    func testResponseMatchesTheComputedCurve() throws {
        for sampleRate in [44_100.0, 48_000, 96_000] {
            try assertMatchesCurve(headphones(), amount: 100, sampleRate: sampleRate, length: 16_384)
            try assertMatchesCurve(speakers(), amount: 100, sampleRate: sampleRate, length: 32_768)
        }
    }

    func testAmountScalesTheFiltersGains() throws {
        let profile = headphones()
        let half = profile.scaled(by: 0.5)
        XCTAssertEqual(half.channels[0].filters.map(\.gain), profile.channels[0].filters.map { $0.gain / 2 })
        XCTAssertEqual(half.preamp, -3)
        XCTAssertEqual(half.channels[0].filters.map(\.q), profile.channels[0].filters.map(\.q))
        XCTAssertEqual(profile.scaled(by: 1), profile)
        XCTAssertTrue(profile.scaled(by: 0).curve(channel: 0, sampleRate: 48_000).allSatisfy { abs($0) < 1e-9 })
        // Speakers keep their delays and levels at any amount.
        XCTAssertEqual(speakers().scaled(by: 0.25).channels.map(\.level), speakers().channels.map(\.level))
        XCTAssertEqual(speakers().scaled(by: 0.25).channels.map(\.delay), speakers().channels.map(\.delay))
        for amount in [0.0, 35, 50] {
            try assertMatchesCurve(profile, amount: amount, sampleRate: 48_000, length: 16_384)
        }
        try assertMatchesCurve(speakers(), amount: 60, sampleRate: 44_100, length: 32_768)
    }

    func testLowFrequencyHighQFiltersStayStable() throws {
        let profile = CalibrationProfile(name: "Room Modes", kind: .speakers, channels: [CalibrationChannel(filters: [
            CalibrationFilter(.peaking, frequency: 20, gain: 6, q: 10),
            CalibrationFilter(.peaking, frequency: 27, gain: -15, q: 8),
            CalibrationFilter(.lowShelf, frequency: 22, gain: -10, q: 2),
            CalibrationFilter(.peaking, frequency: 41, gain: -12, q: 12),
        ])], preamp: -6)
        // At 96 kHz the poles sit closest to 1: the response still matches once it has rung out (about 2 s).
        try assertMatchesCurve(profile, amount: 100, sampleRate: 96_000, length: 196_608)
        // Loud low notes with Amount moving: finite, bounded, and silent again after the input stops.
        let chain = try XCTUnwrap(LiveChain([calibration(profile)], position: .mix, channels: 1, sampleRate: 96_000,
                                            pool: EffectPool()))
        let buffer = Channels(1, frames: 256)
        var phase = 0.0, peak: Float = 0
        for block in 0..<3_000 {
            for f in 0..<256 {
                buffer.pointers[0][f] = block < 2_000 ? Float(0.9 * sin(phase)) : 0
                phase += 2 * .pi * (20 + Double(block % 400) / 20) / 96_000
            }
            if block % 37 == 0 { chain.update([calibration(profile, amount: Double(block % 101))], pool: nil, position: .mix) }
            buffer.process(chain)
            for f in 0..<256 {
                XCTAssertTrue(buffer.pointers[0][f].isFinite)
                peak = max(peak, abs(buffer.pointers[0][f]))
            }
        }
        XCTAssertLessThan(peak, 4)
        XCTAssertLessThan(abs(buffer.pointers[0][255]), 1e-3, "rings out after the input stops")
    }

    // MARK: Delay, level, extra channels

    func testDelayAndLevelAreExact() throws {
        let profile = CalibrationProfile(name: "Aligned", kind: .speakers,
                                         channels: [CalibrationChannel(filters: [], delay: 0, level: 0),
                                                    CalibrationChannel(filters: [], delay: 0.01, level: -6)],
                                         preamp: -3)
        let chain = try XCTUnwrap(LiveChain([calibration(profile)], position: .mix, channels: 2, sampleRate: 48_000,
                                            pool: EffectPool()))
        XCTAssertEqual(chain.latency, 0, "the stage adds no delay of its own")
        XCTAssertEqual(jk_chain_correction_max_delay(chain.pointer, 0), 2_400)
        let preamp = Float(pow(10, -3.0 / 20)), level = Float(pow(10, -6.0 / 20))
        var input: [Float] = []
        var output: [[Float]] = [[], []]
        let buffer = Channels(2, frames: 300)
        var seed: UInt32 = 1
        for _ in 0..<8 {
            for f in 0..<300 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let value = Float(seed >> 8) / Float(1 << 24) - 0.5
                input.append(value)
                buffer.pointers[0][f] = value
                buffer.pointers[1][f] = value
            }
            buffer.process(chain)
            for c in 0..<2 { output[c] += (0..<300).map { buffer.pointers[c][$0] } }
        }
        for n in input.indices {
            XCTAssertEqual(output[0][n], input[n] * (1 * preamp), "channel 1, frame \(n)")
            XCTAssertEqual(output[1][n], n >= 480 ? input[n - 480] * (level * preamp) : 0, "channel 2, frame \(n)")
        }
    }

    func testExtraChannelsPassThroughUntouched() throws {
        // Two speakers' corrections on a four-channel output: channels 3 and 4 are left exactly as they are, also
        // while the settings change.
        let chain = try XCTUnwrap(LiveChain([calibration(speakers())], position: .mix, channels: 4, sampleRate: 48_000,
                                            pool: EffectPool()))
        let buffer = Channels(4, frames: 512)
        for block in 0..<40 {
            var expected: [[Float]] = []
            for c in 0..<4 {
                for f in 0..<512 { buffer.pointers[c][f] = Float(sin(Double(block * 512 + f) * 0.01 * Double(c + 1))) * 0.7 }
                expected.append((0..<512).map { buffer.pointers[c][$0] })
            }
            if block % 3 == 0 { chain.update([calibration(speakers(), amount: Double(block * 2))], pool: nil, position: .mix) }
            buffer.process(chain)
            for c in 2..<4 { XCTAssertEqual((0..<512).map { buffer.pointers[c][$0] }, expected[c], "channel \(c + 1)") }
            XCTAssertNotEqual((0..<512).map { buffer.pointers[1][$0] }, expected[1], "channel 2 is corrected")
        }
        // A single entry (a headphone preset) corrects every channel.
        XCTAssertEqual(headphones().correctedChannels(of: 4), 4)
        XCTAssertEqual(speakers().correctedChannels(of: 4), 2)
        XCTAssertEqual(speakers().correctedChannels(of: 1), 1)
    }

    func testWithoutAProfileTheAudioPassesThrough() throws {
        let chain = try XCTUnwrap(LiveChain([calibration(nil)], position: .mix, channels: 2, sampleRate: 48_000,
                                            pool: EffectPool()))
        let buffer = Channels(2, frames: 256)
        for f in 0..<256 { buffer.pointers[0][f] = Float(f) / 256; buffer.pointers[1][f] = -Float(f) / 512 }
        buffer.process(chain)
        XCTAssertEqual((0..<256).map { buffer.pointers[0][$0] }, (0..<256).map { Float($0) / 256 })
        XCTAssertEqual((0..<256).map { buffer.pointers[1][$0] }, (0..<256).map { -Float($0) / 512 })
    }

    // MARK: Changing settings while rendering

    func testSettingsChangesWhileRenderingDoNotStep() throws {
        // A deep cut at the tone's frequency switched fully on and off every buffer, then delays and filters swapped:
        // without the cross-fade the output would jump by about a third of full scale.
        let cut = CalibrationProfile(name: "Cut", kind: .headphones,
                                     channels: [CalibrationChannel(filters: [CalibrationFilter(.peaking, frequency: 200, gain: -12, q: 1)])],
                                     preamp: 0)
        var moved = cut
        moved.channels = [CalibrationChannel(filters: [CalibrationFilter(.peaking, frequency: 250, gain: -9, q: 2),
                                                       CalibrationFilter(.highShelf, frequency: 4_000, gain: -3, q: 0.7)],
                                             delay: 0.002, level: -2)]
        let chain = try XCTUnwrap(LiveChain([calibration(cut)], position: .mix, channels: 1, sampleRate: 48_000,
                                            pool: EffectPool()))
        let frames = 512
        let buffer = Channels(1, frames: frames)
        let amplitude = 0.5, step = 2 * Double.pi * 200 / 48_000
        var phase = 0.0, previous: Float?, largestStep: Float = 0
        for block in 0..<200 {
            for f in 0..<frames {
                buffer.pointers[0][f] = Float(amplitude * sin(phase))
                phase += step
            }
            let profile = block < 100 ? cut : (block % 2 == 0 ? cut : moved)
            chain.update([calibration(profile, amount: block < 100 ? Double(block % 2) * 100 : 100)], pool: nil, position: .mix)
            buffer.process(chain)
            guard block >= 10 else { continue }  // settled
            for f in 0..<frames {
                let value = buffer.pointers[0][f]
                if let previous { largestStep = max(largestStep, abs(value - previous)) }
                previous = value
            }
            XCTAssertLessThanOrEqual(chain.retiredCorrectionCount, 1, "blocks are freed once the stage is past them")
        }
        // The tone itself moves by at most amplitude × step (0.013) per frame.
        XCTAssertLessThan(largestStep, 0.03, "no step beyond the tone's own slope plus the fade")
    }

    func testSwappingBlocksHandsBackTheRightOnesAndFreesThem() throws {
        let chain = try XCTUnwrap(jk_chain_create(2, 48_000, 2))
        defer { jk_chain_destroy(chain) }
        let gain = jk_chain_add(chain, JK_EFFECT_GAIN), stage = UInt32(jk_chain_add(chain, JK_EFFECT_CORRECTION))
        var ticket: UInt64 = 0
        let first = try XCTUnwrap(jk_correction_create(2)), second = try XCTUnwrap(jk_correction_create(1))
        XCTAssertEqual(jk_chain_swap_correction(chain, UInt32(gain), first, &ticket), first, "not a correction stage")
        XCTAssertNil(jk_chain_swap_correction(chain, stage, first, &ticket))
        XCTAssertEqual(jk_chain_swap_correction(chain, stage, second, &ticket), first)
        XCTAssertEqual(jk_chain_is_done_with_correction(chain, stage, ticket), 0, "the next cycle may still fade from it")
        let buffer = Channels(2, frames: 64)
        buffer.pointers.withUnsafeBufferPointer { jk_chain_process(chain, $0.baseAddress!, 2, 64) }
        XCTAssertEqual(jk_chain_is_done_with_correction(chain, stage, ticket), 1)
        jk_correction_destroy(first)
        // Out of range settings are refused; the block in place goes with the chain.
        XCTAssertEqual(jk_correction_set_channel(second, 1, nil, 0, 0, 1), 0)
        XCTAssertEqual(jk_correction_set_channel(second, 0, [1, 0, 0, 0, .nan], 1, 0, 1), 0)
        XCTAssertNil(jk_correction_create(0))
    }

    // MARK: The effect and graph.json

    func testTheEffectKind() throws {
        let effect = Effect(.calibration)
        XCTAssertEqual(effect.kind, .calibration)
        XCTAssertEqual(effect.title, "Calibration")
        XCTAssertEqual(effect.shortTitle, "Cal")
        XCTAssertEqual([effect.type, effect.subtype, effect.manufacturer], ["aufx", "cali", "Jnct"])
        XCTAssertFalse(effect.isPlugin)
        XCTAssertTrue(EffectKind.calibration.isBuiltIn)
        XCTAssertNil(effect.component)
        XCTAssertNil(effect.calibration)
        let amount = try XCTUnwrap(EffectKind.calibration.parameters.first)
        XCTAssertEqual(EffectKind.calibration.parameters.count, 1)
        XCTAssertEqual(amount.name, "Amount")
        XCTAssertEqual(amount.range, 0...100)
        XCTAssertEqual(effect.value(amount), 100)
        XCTAssertEqual(amount.text(75), "75 %")
        XCTAssertFalse(EffectKind.calibration.isOffered(onOutput: false))
        XCTAssertTrue(EffectKind.calibration.isOffered(onOutput: true))
        XCTAssertTrue(EffectKind.allCases.filter { $0 != .calibration }.allSatisfy { $0.isOffered(onOutput: false) })
        // A profile is tied to its device; one without a device fits any.
        XCTAssertTrue(headphones().isForAnotherDevice(than: "demo.speakers"))
        XCTAssertFalse(headphones().isForAnotherDevice(than: "demo.headphones"))
        var loose = headphones()
        loose.deviceUID = nil
        XCTAssertFalse(loose.isForAnotherDevice(than: nil))
    }

    func testProfileRoundTripsThroughGraphJSON() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let profile = speakers()
        let output = Node(kind: .defaultOutput, canvas: device.id,
                          effects: [calibration(profile, amount: 80), calibration(nil), Effect(.gain)])
        graph.nodes.append(output)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-calibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        try store.save(graph)
        let text = try String(contentsOf: store.graphURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"schema\" : 5"))
        XCTAssertTrue(text.contains("\"calibration\""))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.node(output.id)?.effects, output.effects)
        XCTAssertEqual(loaded.node(output.id)?.effects.first?.calibration, profile)
        XCTAssertEqual(loaded, graph)
    }

    func testSchema4FilesLoadUnchanged() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let output = Node(kind: .defaultOutput, canvas: device.id, effects: [Effect(.limiter), Effect(.gain)])
        graph.nodes.append(output)
        graph.scenes = [RoutingScene(name: "Streaming", capturing: graph)]
        graph.schema = 4
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let old = try encoder.encode(graph)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("calibration"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-schema5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try old.write(to: store.graphURL)
        var loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schema, 5)
        loaded.schema = 4
        XCTAssertEqual(loaded, graph, "nothing else changes")
        XCTAssertEqual(try encoder.encode(loaded), old)

        // A schema 4 file from a development build that had profiles keeps the effect, without its profile.
        var development = graph
        development.nodes[development.nodes.count - 1].effects.append(calibration(headphones(), amount: 40))
        development.scenes = [RoutingScene(name: "Streaming", capturing: development)]
        development.upgrade()
        let effect = try XCTUnwrap(development.node(output.id)?.effects.last)
        XCTAssertEqual(effect.kind, .calibration)
        XCTAssertNil(effect.calibration)
        XCTAssertEqual(effect.value(EffectKind.calibration.parameters[0]), 40)
        XCTAssertTrue(development.scenes[0].nodes.flatMap(\.effects).allSatisfy { $0.calibration == nil })
        XCTAssertEqual(development.schema, 5)
    }

    func testRunnerRebuildsCoefficientsWithoutRebuildingTheSink() throws {
        var inventory = Demo.inventory
        inventory.devices[2].sampleRate = 48_000
        let canvas = Demo.streamMix.id
        let mic = Node(kind: .device(DeviceRef(uid: Demo.interface.uid, name: "Scarlett", inputChannels: 2, outputChannels: 2)),
                       canvas: canvas)
        let device = Node(kind: .virtualDevice(canvas), canvas: canvas)
        let speakers = Node(kind: .defaultOutput, canvas: canvas, effects: [calibration(headphones())])
        var graph = Graph(virtualDevices: [Demo.streamMix], nodes: [mic, device, speakers])
        graph.cables = [Cable(from: PortRef(node: mic.id, channel: 0), to: PortRef(node: device.id, channel: 0)),
                        Cable(from: PortRef(node: device.id, channel: 0), to: PortRef(node: speakers.id, channel: 0)),
                        Cable(from: PortRef(node: device.id, channel: 1), to: PortRef(node: speakers.id, channel: 1))]
        let plan = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first { $0.sinkNode == speakers.id })
        XCTAssertEqual(plan.effects.map(\.kind), [.calibration])
        let pool = EffectPool()
        let runner = try XCTUnwrap(SinkRunner(plan: plan, pool: pool))
        let chains = runner.chainPointers
        let mixChain = try XCTUnwrap(chains.last ?? nil)
        XCTAssertEqual(runner.effectLatencies[speakers.id], 0)

        // Amount and another profile: the same sink and chain, new coefficients.
        var edited = graph
        edited.nodes[2].effects[0].set(EffectKind.calibration.parameters[0], 30)
        edited.nodes[2].effects[0].calibration = self.speakers()
        let replanned = try XCTUnwrap(Planner.plan(edited, inventory: inventory).sinks.first { $0.sinkNode == speakers.id })
        XCTAssertEqual(replanned.structureKey, plan.structureKey)
        var ticket: UInt64 = 0
        let probe = try XCTUnwrap(jk_correction_create(1))
        let before = try XCTUnwrap(jk_chain_swap_correction(mixChain, 0, probe, &ticket))
        XCTAssertNotNil(jk_chain_swap_correction(mixChain, 0, before, &ticket))  // put back; frees nothing it owns
        jk_correction_destroy(probe)
        runner.update(replanned, pool: pool)
        XCTAssertEqual(runner.chainPointers, chains)
        let after = try XCTUnwrap(jk_chain_swap_correction(mixChain, 0, nil, &ticket))
        XCTAssertNotEqual(after, before, "a new block for the new settings")
        XCTAssertEqual(jk_correction_channels(after), 2, "two speakers on a stereo output")
        jk_correction_destroy(after)
    }
}
