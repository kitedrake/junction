import AudioToolbox
import CoreAudio
import JunctionKernel
import XCTest
@testable import JunctionCore

/// A fake effect that holds up the audio thread for 4 ms (three 64-frame buffers' worth at 48 kHz).
private let slowEffect: JKEffectProcess = { _, _, _, _ in usleep(4000) }

/// Apple's AUDelay, standing in for a third-party plugin.
private let delayPlugin = PluginInfo(subtype: "dely", manufacturer: "appl", name: "AUDelay", vendor: "Apple")

final class PluginTests: XCTestCase {
    typealias Buffers = KernelTests.Buffers

    private func temporaryStore() -> Store {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-plugins-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return Store(folder: folder)
    }

    private func render(_ renderer: OpaquePointer, frames: Int, cycles: Int) {
        let input = Buffers(streams: [2], frames: frames), output = Buffers(streams: [2], frames: frames)
        var time = AudioTimeStamp()
        for _ in 0..<cycles {
            _ = jk_renderer_ioproc(0, &time, input.list.unsafePointer, &time, output.list.unsafeMutablePointer, &time,
                                   UnsafeMutableRawPointer(renderer))
        }
    }

    // MARK: The picker

    func testListsTheInstalledEffectUnits() throws {
        let plugins = PluginCatalog.installed()
        let delay = try XCTUnwrap(plugins.first { $0.subtype == "dely" && $0.manufacturer == "appl" },
                                  "Apple's AUDelay is on every Mac")
        XCTAssertEqual(delay.type, "aufx")
        XCTAssertEqual(delay.vendor, "Apple")
        XCTAssertFalse(delay.name.isEmpty)
        XCTAssertTrue(plugins.allSatisfy { $0.type == "aufx" }, "effects only")
        XCTAssertEqual(Set(plugins.map(\.id)).count, plugins.count, "each component once")
        XCTAssertEqual(plugins, PluginCatalog.sorted(plugins), "by maker, then name")
        XCTAssertTrue(PluginCatalog.isInstalled(Effect(plugin: delay)))
        XCTAssertTrue(PluginCatalog.search(plugins, for: "apple delay").contains(delay))
    }

    func testSearchMatchesEveryWordOfTheNameOrMaker() {
        let plugins = PluginCatalog.sorted([
            PluginInfo(subtype: "sprv", manufacturer: "Exmp", name: "Space Reverb", vendor: "Example Audio"),
            PluginInfo(subtype: "dsrs", manufacturer: "Exmp", name: "De-Esser", vendor: "Example Audio"),
            PluginInfo(subtype: "clip", manufacturer: "Nwnd", name: "Soft Clipper", vendor: "Northwind Sound"),
            PluginInfo(subtype: "dely", manufacturer: "appl", name: "AUDelay", vendor: "Apple"),
            PluginInfo(subtype: "rvrb", manufacturer: "Crme", name: "Réverbe Crème", vendor: "Atelier"),
        ])
        XCTAssertEqual(plugins.map(\.vendor), ["Apple", "Atelier", "Example Audio", "Example Audio", "Northwind Sound"])
        XCTAssertEqual(plugins.filter { $0.vendor == "Example Audio" }.map(\.name), ["De-Esser", "Space Reverb"])
        func names(_ query: String) -> [String] { PluginCatalog.search(plugins, for: query).map(\.name) }
        XCTAssertEqual(names(""), plugins.map(\.name), "an empty search lists everything")
        XCTAssertEqual(names("  "), plugins.map(\.name))
        XCTAssertEqual(names("reverb"), ["Réverbe Crème", "Space Reverb"], "any case, any accents")
        XCTAssertEqual(names("example"), ["De-Esser", "Space Reverb"], "the maker counts")
        XCTAssertEqual(names("example reverb"), ["Space Reverb"], "every word must match")
        XCTAssertEqual(names("northwind delay"), [])
    }

    func testFourCharacterCodesSurviveAsText() {
        for code: OSType in [0x6175_6678, 0x2020_2020, 0x0000_0001, 0xFF41_4243] {
            XCTAssertEqual(fourCC(fourCCText(code)), code)
        }
        XCTAssertEqual(fourCCText(0x6175_6678), "aufx")
        XCTAssertEqual(fourCCText(0x0000_0001), "0x00000001", "bytes that aren't printable are written in hex")
        let odd = Effect(type: "aufx", subtype: fourCCText(0xFF41_4243), manufacturer: "Exmp", name: "Odd")
        XCTAssertEqual(odd.component?.componentSubType, 0xFF41_4243)
    }

    // MARK: Saved state

    func testPluginStateSurvivesSavingTheGraph() throws {
        var effect = Effect(plugin: delayPlugin)
        XCTAssertTrue(effect.isPlugin)
        XCTAssertNil(effect.kind, "not one of Junction's own effects")
        XCTAssertEqual(effect.title, "AUDelay")
        let started = Date()
        let unit = try EffectUnit(effect, channels: 2, sampleRate: 48_000)
        let loading = Date().timeIntervalSince(started)
        let delayTime = AudioUnitParameterID(kDelayParam_DelayTime)
        // As if changed in the plugin's own window: straight on the unit, not through Junction's parameters. Out of
        // process the change reaches the plugin's process with its next render, so render as a running unit does.
        XCTAssertEqual(AudioUnitSetParameter(unit.unit, delayTime, kAudioUnitScope_Global, 0, 0.3, 0), noErr)
        let silence = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
        defer { silence.forEach { $0.deallocate() } }
        for _ in 0..<20 {
            silence.forEach { $0.initialize(repeating: 0, count: 512) }
            unit.process(silence, frames: 512)
        }
        XCTAssertEqual(unit.parameter(delayTime) ?? 0, 0.3, accuracy: 1e-4)
        effect.state = try XCTUnwrap(unit.state)
        XCTAssertTrue(effect.parameters.isEmpty)

        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let index = try XCTUnwrap(graph.nodes.firstIndex { $0.kind == .virtualDevice(device.id) })
        graph.nodes[index].effects = [effect]
        let store = temporaryStore()
        try store.save(graph)
        let loaded = try XCTUnwrap(store.load()?.nodes[index].effects.first)
        XCTAssertEqual(loaded, effect, "name, maker and state come back")
        XCTAssertEqual(loaded.vendor, "Apple")
        let again = try EffectUnit(loaded, channels: 2, sampleRate: 48_000)
        XCTAssertEqual(again.parameter(delayTime) ?? 0, 0.3, accuracy: 1e-4, "the setting made in its window is back")
        XCTAssertNil(EffectUnit.capturedState(loaded), "a plugin's state comes from its running unit, not a copy")

        // It renders in a chain, out of process where macOS allows it. What that costs, for the README.
        let pool = EffectPool()
        let chain = try XCTUnwrap(LiveChain([loaded], position: .mix, channels: 2, sampleRate: 48_000, pool: pool))
        XCTAssertEqual(chain.stages, [0])
        let frames = 256
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames), right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 0.25, count: frames)
        right.initialize(repeating: 0.25, count: frames)
        let channels = [left, right]
        channels.withUnsafeBufferPointer { pointers in
            for _ in 0..<200 { jk_chain_process(chain.pointer, pointers.baseAddress!, 2, UInt32(frames)) }
        }
        let cost = EffectCost.measure(try XCTUnwrap(chain.takeTimings()[loaded.id]), since: nil, sampleRate: 48_000,
                                      latency: again.latency, outOfProcess: chain.units[0].isOutOfProcess)
        XCTAssertEqual(chain.units[0].errorCount, 0)
        XCTAssertGreaterThan(cost.load, 0)
        print(String(format: "AUDelay as a plugin: %@, loaded in %.0f ms, CPU %.2f %% at 256 frames, slowest buffer %.0f %% of its duration, latency %.1f ms",
                     cost.outOfProcess ? "out of process" : "in process", loading * 1000, cost.load * 100, cost.peak * 100,
                     cost.latency * 1000))
    }

    // MARK: Missing plugins

    func testMissingPluginIsLeftOutAndKeepsItsState() throws {
        let state = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])
        let missing = Effect(type: "aufx", subtype: "vrdr", manufacturer: "Exmp", bypass: false, state: state,
                             name: "Vocal Rider", vendor: "Example Audio")
        XCTAssertTrue(missing.isPlugin)
        XCTAssertEqual(missing.title, "Vocal Rider")
        XCTAssertFalse(PluginCatalog.isInstalled(missing))
        XCTAssertThrowsError(try EffectUnit(missing, channels: 2, sampleRate: 48_000)) { error in
            XCTAssertEqual(error as? EffectError, .notInstalled("Vocal Rider"))
        }

        // Left out of its chain with the reason; the effects around it still run.
        let pool = EffectPool()
        var gain = Effect(.gain)
        gain.set(EffectKind.gain.parameters[0], 20 * log10(0.5))
        let chain = try XCTUnwrap(LiveChain([missing, gain], position: .source, channels: 1, sampleRate: 48_000, pool: pool))
        XCTAssertEqual(chain.stages, [nil, 0])
        let problem = try XCTUnwrap(pool.problems[missing.id])
        XCTAssertTrue(problem.contains("Vocal Rider") && problem.contains("isn't installed"), problem)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { samples.deallocate() }
        samples.initialize(repeating: 0.8, count: 64)
        let channels: [UnsafeMutablePointer<Float>] = [samples]
        channels.withUnsafeBufferPointer { jk_chain_process(chain.pointer, $0.baseAddress!, 1, 64) }
        XCTAssertEqual(samples[63], 0.4, accuracy: 1e-4, "only the gain processed the audio")
        XCTAssertNil(LiveChain([missing], position: .source, channels: 1, sampleRate: 48_000, pool: EffectPool()),
                     "a chain of only missing plugins passes the audio through untouched")

        // The plan keeps it (so it comes back once installed) and the file keeps its state.
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let index = try XCTUnwrap(graph.nodes.firstIndex { $0.kind == .virtualDevice(device.id) })
        graph.nodes[index].effects = [missing, gain]
        let store = temporaryStore()
        try store.save(graph)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.nodes[index].effects, [missing, gain])
        XCTAssertEqual(loaded.nodes[index].effects.first?.state, state)
        let inventory = Inventory(devices: [DeviceInfo(uid: device.uid, name: device.name, inputChannels: 2, outputChannels: 2,
                                                       isJunction: true)])
        let sink = try XCTUnwrap(Planner.plan(loaded, inventory: inventory).sinks.first { $0.sinkNode == graph.nodes[index].id })
        XCTAssertEqual(sink.effects.map(\.id), [missing.id, gain.id])
    }

    // MARK: Overloads and stalls

    func testOverloadsAreCountedPerSinkAndStallsPerEffect() throws {
        let slow = try XCTUnwrap(jk_renderer_create_slots(2, 2, 2, [0, 1], [0, 1], [1, 1], nil, 0, 0, nil, nil))
        let fast = try XCTUnwrap(jk_renderer_create_slots(2, 2, 2, [0, 1], [0, 1], [1, 1], nil, 0, 0, nil, nil))
        let untimed = try XCTUnwrap(jk_renderer_create_slots(2, 2, 2, [0, 1], [0, 1], [1, 1], nil, 0, 0, nil, nil))
        defer { [slow, fast, untimed].forEach { jk_renderer_destroy($0) } }
        for renderer in [slow, fast] { jk_renderer_set_sample_rate(renderer, 48_000) }
        let chain = try XCTUnwrap(jk_chain_create(2, 48_000, 2))
        defer { jk_chain_destroy(chain) }
        XCTAssertEqual(jk_chain_add(chain, JK_EFFECT_GAIN), 0)
        XCTAssertEqual(jk_chain_add_custom(chain, slowEffect, nil), 1)
        var ticket: UInt64 = 0
        XCTAssertNil(jk_renderer_swap_chain(slow, JK_OUTPUT_CHAIN, chain, &ticket))
        let slowUntimed = try XCTUnwrap(jk_chain_create(2, 48_000, 1))
        defer { jk_chain_destroy(slowUntimed) }
        jk_chain_add_custom(slowUntimed, slowEffect, nil)
        _ = jk_renderer_swap_chain(untimed, JK_OUTPUT_CHAIN, slowUntimed, &ticket)

        render(slow, frames: 64, cycles: 3)          // 4 ms for 1.3 ms of audio: late every time
        render(fast, frames: 4096, cycles: 3)        // nothing to do for 85 ms of audio
        render(untimed, frames: 64, cycles: 2)
        var timing = JKTiming()
        jk_renderer_timing(slow, &timing, 0)
        XCTAssertEqual(timing.late, 3, "each late cycle is an overload of that sink")
        XCTAssertEqual(timing.frames, 192)
        XCTAssertGreaterThan(timing.peakLoad, 1)
        jk_renderer_timing(fast, &timing, 0)
        XCTAssertEqual(timing.late, 0, "another sink's overloads aren't its own")
        XCTAssertEqual(timing.frames, 3 * 4096)
        jk_renderer_timing(untimed, &timing, 0)
        XCTAssertEqual(timing.late, 0, "without a sample rate nothing is timed")

        // The stage that stalls, not the one beside it.
        var stage = JKTiming()
        jk_chain_stage_timing(chain, 1, &stage, 1)
        XCTAssertEqual(stage.late, 3)
        XCTAssertGreaterThan(stage.peakLoad, 1)
        XCTAssertGreaterThan(stage.seconds, 0.011)
        jk_chain_stage_timing(chain, 1, &stage, 0)
        XCTAssertEqual(stage.peakLoad, 0, "taking the peak resets it")
        jk_chain_stage_timing(chain, 0, &stage, 0)
        XCTAssertEqual(stage.late, 0)
        XCTAssertEqual(stage.frames, 192)
        // Bypassed, it isn't run, so it can't stall.
        jk_chain_set_bypass(chain, 1, 1)
        render(slow, frames: 64, cycles: 2)
        jk_chain_stage_timing(chain, 1, &stage, 0)
        XCTAssertEqual(stage.late, 3)
        jk_renderer_timing(slow, &timing, 0)
        XCTAssertEqual(timing.late, 3, "fast again once bypassed")
    }

    func testEffectCostComesFromTwoReadings() {
        // 4800 frames (0.1 s of audio at 48 kHz) took 5 ms: 5 % of a core.
        let first = JKTiming(frames: 4800, seconds: 0.005, late: 1, peakLoad: 0.6)
        let second = JKTiming(frames: 9600, seconds: 0.015, late: 2, peakLoad: 0.25)
        XCTAssertEqual(EffectCost.measure(first, since: nil, sampleRate: 48_000).load, 0.05, accuracy: 1e-9)
        let cost = EffectCost.measure(second, since: first, sampleRate: 48_000, latency: 0.002, outOfProcess: true)
        XCTAssertEqual(cost.load, 0.1, accuracy: 1e-9, "only what happened since the first reading")
        XCTAssertEqual(cost.peak, 0.25)
        XCTAssertEqual(cost.stalls, 2)
        XCTAssertEqual(cost, EffectCost(load: 0.1, peak: 0.25, stalls: 2, latency: 0.002, outOfProcess: true))
        // A chain built since counts from zero.
        let rebuilt = JKTiming(frames: 4800, seconds: 0.001, late: 0, peakLoad: 0.1)
        XCTAssertEqual(EffectCost.measure(rebuilt, since: second, sampleRate: 48_000).load, 0.01, accuracy: 1e-9)
    }

    func testStallingEffectsAreOfferedForBypass() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        let effect = UUID(), calm = UUID()
        var watch = StallWatch()
        watch.record(effect: effect, stalls: 0, peak: 0.2, sinkOverloads: 0, at: at(0))
        watch.record(effect: calm, stalls: 0, peak: 0.1, sinkOverloads: 0, at: at(0))
        watch.record(effect: effect, stalls: 2, peak: 0.7, sinkOverloads: 0, at: at(2))
        XCTAssertEqual(watch.offers(at: at(2)), [], "two slow buffers are a hiccup")
        watch.record(effect: effect, stalls: 3, peak: 0.6, sinkOverloads: 0, at: at(4))
        watch.record(effect: calm, stalls: 0, peak: 0.1, sinkOverloads: 0, at: at(4))
        XCTAssertEqual(watch.offers(at: at(4)), [effect], "three within ten seconds hold up the audio")
        XCTAssertEqual(watch.offers(at: at(4), bypassed: [effect]), [], "a bypassed effect isn't offered")
        // It calms down: once its stalls are older than the window, the offer goes.
        watch.record(effect: effect, stalls: 3, peak: 0.1, sinkOverloads: 0, at: at(10))
        XCTAssertEqual(watch.offers(at: at(10)), [effect])
        watch.record(effect: effect, stalls: 3, peak: 0.1, sinkOverloads: 0, at: at(14.5))
        XCTAssertEqual(watch.offers(at: at(14.5)), [])
        // Its chain was rebuilt (the count starts again from zero): its new stalls count.
        watch.record(effect: effect, stalls: 1, peak: 0.8, sinkOverloads: 0, at: at(15))
        XCTAssertEqual(watch.offers(at: at(15)), [])
        watch.record(effect: effect, stalls: 3, peak: 0.8, sinkOverloads: 0, at: at(16))
        XCTAssertEqual(watch.offers(at: at(16)), [effect])

        // One buffer longer than a whole buffer while its sink overloaded is enough.
        var once = StallWatch()
        once.record(effect: calm, stalls: 0, peak: 0, sinkOverloads: 5, at: at(0))
        once.record(effect: calm, stalls: 1, peak: 1.4, sinkOverloads: 5, at: at(2))
        XCTAssertEqual(once.offers(at: at(2)), [], "the sink didn't overload then: no offer")
        once.record(effect: calm, stalls: 2, peak: 1.2, sinkOverloads: 6, at: at(4))
        XCTAssertEqual(once.offers(at: at(4)), [calm])
        once.keep([])
        XCTAssertEqual(once.offers(at: at(4)), [], "effects that stopped running are forgotten")

        XCTAssertFalse(StallWatch.shouldOffer(stalls: 2, peak: 0.9, overloads: 4))
        XCTAssertTrue(StallWatch.shouldOffer(stalls: StallWatch.stallLimit, peak: 0, overloads: 0))
        XCTAssertTrue(StallWatch.shouldOffer(stalls: 0, peak: 1, overloads: 1))
        XCTAssertFalse(StallWatch.shouldOffer(stalls: 0, peak: 1, overloads: 0))
    }
}
