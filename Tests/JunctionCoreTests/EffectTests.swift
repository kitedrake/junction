import AudioToolbox
import CoreAudio
import JunctionKernel
import XCTest
@testable import JunctionCore

// The fake effects loop with `while`: a debug build's `for … in` over a range can allocate, and these run on the
// audio thread in the allocation test.

/// A fake effect: adds the Float its context points at to every sample.
private let addEffect: JKEffectProcess = { context, channels, count, frames in
    let amount = context!.assumingMemoryBound(to: Float.self).pointee
    var c = 0
    while c < Int(count) {
        var f = 0
        while f < Int(frames) { channels[c][f] += amount; f += 1 }
        c += 1
    }
}

/// Another: doubles every sample (so the order of the two shows in the result).
private let doubleEffect: JKEffectProcess = { _, channels, count, frames in
    var c = 0
    while c < Int(count) {
        var f = 0
        while f < Int(frames) { channels[c][f] *= 2; f += 1 }
        c += 1
    }
}

// Allocations on one thread, counted through libmalloc's logging hook.
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private var watchedThread: pthread_t?
private var allocations = 0
private let countAllocations: MallocLogger = { type, _, _, _, _, _ in
    guard type & 2 != 0, let watched = watchedThread, pthread_equal(pthread_self(), watched) != 0 else { return }
    allocations += 1
}

final class EffectTests: XCTestCase {
    typealias Buffers = KernelTests.Buffers

    private func render(_ renderer: OpaquePointer, _ input: Buffers, _ output: Buffers) {
        var time = AudioTimeStamp()
        _ = jk_renderer_ioproc(0, &time, input.list.unsafePointer, &time, output.list.unsafeMutablePointer, &time,
                               UnsafeMutableRawPointer(renderer))
    }

    private func amount(_ value: Float) -> UnsafeMutablePointer<Float> {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        pointer.initialize(to: value)
        addTeardownBlock { pointer.deallocate() }
        return pointer
    }

    /// A stereo source on aggregate channels 0–1 through one slot (lanes 2–3) into a stereo sink.
    private func stereoRenderer() throws -> OpaquePointer {
        try XCTUnwrap(jk_renderer_create_slots(2, 2, 2, [2, 3], [0, 1], [1, 1], nil, 0, 1, [2], [0, 1]))
    }

    private func swap(_ renderer: OpaquePointer, _ slot: UInt32, _ chain: OpaquePointer?) -> OpaquePointer? {
        var ticket: UInt64 = 0
        return jk_renderer_swap_chain(renderer, slot, chain, &ticket)
    }

    // MARK: Kernel

    func testChainRunsEffectsInOrder() throws {
        let renderer = try stereoRenderer()
        defer { jk_renderer_destroy(renderer) }
        let input = Buffers(streams: [2], frames: 32), output = Buffers(streams: [2], frames: 32)
        for f in 0..<32 { input.set(stream: 0, channel: 0, frame: f, 1); input.set(stream: 0, channel: 1, frame: f, 3) }
        let one = amount(1)
        let addThenDouble = try XCTUnwrap(jk_chain_create(2, 48_000, 2))
        XCTAssertEqual(jk_chain_add_custom(addThenDouble, addEffect, one), 0)
        XCTAssertEqual(jk_chain_add_custom(addThenDouble, doubleEffect, nil), 1)
        XCTAssertNil(swap(renderer, 0, addThenDouble))
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 5), 4, "(1 + 1) × 2")
        XCTAssertEqual(output.get(stream: 0, channel: 1, frame: 5), 8, "(3 + 1) × 2")
        XCTAssertEqual(jk_renderer_take_input_peak(renderer, 2), 4, "meters after the effects")
        XCTAssertEqual(input.get(stream: 0, channel: 0, frame: 5), 1, "the device's own buffer is left alone")

        let doubleThenAdd = try XCTUnwrap(jk_chain_create(2, 48_000, 2))
        jk_chain_add_custom(doubleThenAdd, doubleEffect, nil)
        jk_chain_add_custom(doubleThenAdd, addEffect, one)
        let old = try XCTUnwrap(swap(renderer, 0, doubleThenAdd))
        XCTAssertEqual(old, addThenDouble, "the swap hands back the chain it replaced")
        jk_chain_destroy(old)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 5), 3, "1 × 2 + 1")
        jk_chain_destroy(try XCTUnwrap(swap(renderer, 0, nil)))
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 5), 1, "no chain: the source passes through")
    }

    func testBypassedEffectsLeaveTheAudioAlone() throws {
        let renderer = try stereoRenderer()
        defer { jk_renderer_destroy(renderer) }
        let input = Buffers(streams: [2], frames: 16), output = Buffers(streams: [2], frames: 16)
        for f in 0..<16 { input.set(stream: 0, channel: 0, frame: f, 1) }
        let chain = try XCTUnwrap(jk_chain_create(2, 48_000, 2))
        jk_chain_add_custom(chain, addEffect, amount(1))
        jk_chain_add_custom(chain, doubleEffect, nil)
        _ = swap(renderer, 0, chain)
        jk_chain_set_bypass(chain, 1, 1)
        XCTAssertEqual(jk_chain_bypassed(chain, 1), 1)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 3), 2, "only the add runs")
        jk_chain_set_bypass(chain, 0, 1)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 3), 1, "both bypassed")
        jk_chain_set_bypass(chain, 0, 0)
        jk_chain_set_bypass(chain, 1, 0)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 3), 4)
        jk_chain_destroy(try XCTUnwrap(swap(renderer, 0, nil)))
    }

    func testChainAfterTheMixRunsBeforeTheCrossFade() throws {
        // Two mono sources, each in its own slot, mixed into a mono sink; the mix chain doubles the sum.
        let renderer = try XCTUnwrap(jk_renderer_create_slots(2, 1, 2, [2, 3], [0, 0], [1, 1], nil, 0, 2, [1, 1], [0, 1]))
        defer { jk_renderer_destroy(renderer) }
        let input = Buffers(streams: [2], frames: 100), output = Buffers(streams: [1], frames: 100)
        for f in 0..<100 { input.set(stream: 0, channel: 0, frame: f, 0.25); input.set(stream: 0, channel: 1, frame: f, 0.5) }
        let gain = try XCTUnwrap(jk_chain_create(1, 48_000, 1))
        jk_chain_add(gain, JK_EFFECT_GAIN)
        jk_chain_set_parameter(gain, 0, 0, 0)  // the first source is silenced before the mix
        _ = swap(renderer, 0, gain)
        let mix = try XCTUnwrap(jk_chain_create(1, 48_000, 1))
        jk_chain_add_custom(mix, doubleEffect, nil)
        _ = swap(renderer, JK_OUTPUT_CHAIN, mix)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 50), 1, "(0 + 0.5) × 2")
        XCTAssertEqual(jk_renderer_take_output_peak(renderer, 0), 1, "sink meters after the chain")
        // A fade-out scales what the chain made.
        jk_renderer_fade(renderer, 0, 100)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 49), 0.5, accuracy: 1e-5)
        jk_chain_destroy(try XCTUnwrap(swap(renderer, 0, nil)))
        jk_chain_destroy(try XCTUnwrap(swap(renderer, JK_OUTPUT_CHAIN, nil)))
    }

    func testBuiltInEffects() throws {
        let renderer = try stereoRenderer()
        defer { jk_renderer_destroy(renderer) }
        let frames = 480
        let input = Buffers(streams: [2], frames: frames), output = Buffers(streams: [2], frames: frames)
        for f in 0..<frames { input.set(stream: 0, channel: 0, frame: f, 0.5); input.set(stream: 0, channel: 1, frame: f, 0.1) }
        func with(_ kind: JKEffectKind, _ parameters: [Float]) throws -> OpaquePointer {
            let chain = try XCTUnwrap(jk_chain_create(2, 48_000, 1))
            XCTAssertEqual(jk_chain_add(chain, kind), 0)
            for (index, value) in parameters.enumerated() { jk_chain_set_parameter(chain, 0, UInt32(index), value) }
            if let old = swap(renderer, 0, chain) { jk_chain_destroy(old) }
            return chain
        }
        // Gain: set before the first buffer it starts there; a change glides over one buffer.
        let gain = try with(JK_EFFECT_GAIN, [0.5])
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 0), 0.25, accuracy: 1e-6)
        jk_chain_set_parameter(gain, 0, 0, 1)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: frames / 2 - 1), 0.375, accuracy: 1e-3)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: frames - 1), 0.5, accuracy: 1e-5)
        XCTAssertEqual(jk_chain_parameter(gain, 0, 0), 1)
        // Pan right: the left channel goes down, the right stays.
        _ = try with(JK_EFFECT_PAN, [0.5])
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 10), 0.25, accuracy: 1e-6)
        XCTAssertEqual(output.get(stream: 0, channel: 1, frame: 10), 0.1, accuracy: 1e-6)
        // Mono: both channels get the average.
        _ = try with(JK_EFFECT_MONO, [])
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 10), 0.3, accuracy: 1e-6)
        XCTAssertEqual(output.get(stream: 0, channel: 1, frame: 10), 0.3, accuracy: 1e-6)
        // Gate at 0.6 (above both channels): closes after its 50 ms hold and its release.
        let gate = try with(JK_EFFECT_GATE, [0.6, 0.02])
        for _ in 0..<20 { render(renderer, input, output) }  // 200 ms
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: frames - 1), 0, accuracy: 1e-4, "closed")
        jk_chain_set_parameter(gate, 0, 0, 0.3)  // now the left channel is above it
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: frames - 1), 0.5, accuracy: 1e-3, "open within 1 ms")
        XCTAssertEqual(output.get(stream: 0, channel: 1, frame: frames - 1), 0.1, accuracy: 1e-3, "both channels open together")
        jk_chain_destroy(try XCTUnwrap(swap(renderer, 0, nil)))
    }

    func testSwappingChainsWhileRendering() throws {
        let renderer = try stereoRenderer()
        defer { jk_renderer_destroy(renderer) }
        let one = amount(1), two = amount(2)
        func chain(_ value: UnsafeMutablePointer<Float>) -> OpaquePointer {
            let chain = jk_chain_create(2, 48_000, 1)!
            jk_chain_add_custom(chain, addEffect, value)
            return chain
        }
        final class Run: @unchecked Sendable {
            let stop = NSLock()
            var stopped = false
            var buffers = 0
            var mixed = 0  // buffers that weren't all one chain's
            var values = Set<Float>()
        }
        let run = Run()
        let finished = expectation(description: "rendering stopped")
        let thread = Thread {
            let input = Buffers(streams: [2], frames: 256), output = Buffers(streams: [2], frames: 256)
            while true {
                run.stop.lock()
                let stopped = run.stopped
                run.stop.unlock()
                if stopped { break }
                self.render(renderer, input, output)
                let first = output.get(stream: 0, channel: 0, frame: 0)
                if (0..<256).contains(where: { output.get(stream: 0, channel: 0, frame: $0) != first }) { run.mixed += 1 }
                run.values.insert(first)
                run.buffers += 1
            }
            finished.fulfill()
        }
        thread.start()
        var retired: [(OpaquePointer, UInt64)] = []
        var freed = 0
        for index in 0..<4000 {
            var ticket: UInt64 = 0
            if let old = jk_renderer_swap_chain(renderer, 0, chain(index % 2 == 0 ? one : two), &ticket) {
                retired.append((old, ticket))
            }
            retired.removeAll { old in
                guard jk_renderer_is_done_with(renderer, old.1) != 0 else { return false }
                jk_chain_destroy(old.0)
                freed += 1
                return true
            }
            if index % 100 == 0 { Thread.sleep(forTimeInterval: 0.001) }
        }
        run.stop.lock()
        run.stopped = true
        run.stop.unlock()
        wait(for: [finished], timeout: 10)
        retired.forEach { jk_chain_destroy($0.0) }
        if let last = swap(renderer, 0, nil) { jk_chain_destroy(last) }
        XCTAssertGreaterThan(run.buffers, 10)
        XCTAssertEqual(run.mixed, 0, "every buffer went through one whole chain")
        XCTAssertTrue(run.values.isSubset(of: [1, 2]), "\(run.values)")
        XCTAssertGreaterThan(freed, 0, "chains are freed once the audio thread is done with them")
        // With the IOProc idle, every cycle that could see a chain has finished.
        var ticket: UInt64 = 0
        _ = jk_renderer_swap_chain(renderer, 0, nil, &ticket)
        XCTAssertEqual(jk_renderer_is_done_with(renderer, ticket), 1)
    }

    func testRenderingWithEffectsDoesNotAllocate() throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
            return XCTFail("libmalloc's logging hook isn't there")
        }
        let hook = symbol.assumingMemoryBound(to: Optional<MallocLogger>.self)
        // Two stereo sources with effects, a mix chain, and a converted source.
        let converter = try XCTUnwrap(jk_converter_create(2, 44_100, 48_000))
        defer { jk_converter_destroy(converter) }
        let renderer = try XCTUnwrap(jk_renderer_create_slots(2, 2, 4, [4, 5, 6, 7], [0, 1, 0, 1], [1, 1, 0.5, 0.5],
                                                              [converter], 1, 2, [2, 2], [0, 1, 2, 3]))
        defer { jk_renderer_destroy(renderer) }
        var chains: [OpaquePointer] = []
        for slot in [UInt32(0), 1, JK_OUTPUT_CHAIN] {
            let chain = try XCTUnwrap(jk_chain_create(2, 48_000, 6))
            for kind in [JK_EFFECT_GAIN, JK_EFFECT_PAN, JK_EFFECT_MONO, JK_EFFECT_GATE] { jk_chain_add(chain, kind) }
            jk_chain_add_custom(chain, addEffect, amount(0.01))
            jk_chain_add_custom(chain, doubleEffect, nil)
            _ = swap(renderer, slot, chain)
            chains.append(chain)
        }
        defer { chains.forEach { jk_chain_destroy($0) } }
        let input = Buffers(streams: [2], frames: 512), output = Buffers(streams: [2], frames: 512)
        let time = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: 1)
        time.initialize(to: AudioTimeStamp())
        defer { time.deallocate() }
        let inList = input.list.unsafePointer, outList = output.list.unsafeMutablePointer
        let client = UnsafeMutableRawPointer(renderer)
        _ = jk_renderer_ioproc(0, time, inList, time, outList, time, client)  // warmed up

        let previous = hook.pointee
        allocations = 0
        watchedThread = pthread_self()
        let first = chains[0], last = chains[2]
        hook.pointee = countAllocations
        var cycle = 0
        while cycle < 200 {
            jk_chain_set_bypass(first, UInt32(cycle % 6), Int32(cycle % 2))
            jk_chain_set_parameter(last, 0, 0, Float(cycle % 10) / 10)
            _ = jk_renderer_ioproc(0, time, inList, time, outList, time, client)
            cycle += 1
        }
        hook.pointee = previous
        watchedThread = nil
        XCTAssertEqual(allocations, 0, "no allocation on the audio thread")
        // The hook does see allocations (so a zero above means something).
        hook.pointee = countAllocations
        watchedThread = pthread_self()
        let probe = malloc(64)
        hook.pointee = previous
        watchedThread = nil
        free(probe)
        XCTAssertGreaterThan(allocations, 0)
    }

    func testRenderingCalibrationDoesNotAllocate() throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
            return XCTFail("libmalloc's logging hook isn't there")
        }
        let hook = symbol.assumingMemoryBound(to: Optional<MallocLogger>.self)
        // A Calibration stage after the mix whose settings change every cycle (each change cross-fades): the blocks are
        // made beforehand, as the router makes them on its own queue.
        let renderer = try stereoRenderer()
        defer { jk_renderer_destroy(renderer) }
        let chain = try XCTUnwrap(jk_chain_create(2, 48_000, 1))
        defer { jk_chain_destroy(chain) }
        let stage = UInt32(jk_chain_add(chain, JK_EFFECT_CORRECTION))
        _ = swap(renderer, JK_OUTPUT_CHAIN, chain)
        defer { _ = swap(renderer, JK_OUTPUT_CHAIN, nil) }
        let profile = CalibrationProfile(name: "Desk", kind: .speakers, channels: [
            CalibrationChannel(filters: (0..<32).map { CalibrationFilter(.peaking, frequency: 40 * pow(1.2, Double($0)), gain: -3, q: 2) },
                               delay: 0.01, level: -1),
            CalibrationChannel(filters: [CalibrationFilter(.lowShelf, frequency: 80, gain: 4)], delay: 0, level: 0),
        ], preamp: -4)
        let blocks = try (0..<200).map { cycle in
            try XCTUnwrap(CalibrationKernel.block(profile, amount: Double(cycle % 3) / 2, channels: 2, sampleRate: 48_000,
                                                  maxDelayFrames: Int(jk_chain_correction_max_delay(chain, stage))))
        }
        var handedBack: [OpaquePointer] = []
        handedBack.reserveCapacity(blocks.count + 1)
        defer { handedBack.forEach { jk_correction_destroy($0) } }
        let input = Buffers(streams: [2], frames: 512), output = Buffers(streams: [2], frames: 512)
        let time = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: 1)
        time.initialize(to: AudioTimeStamp())
        defer { time.deallocate() }
        let inList = input.list.unsafePointer, outList = output.list.unsafeMutablePointer
        let client = UnsafeMutableRawPointer(renderer)
        _ = jk_renderer_ioproc(0, time, inList, time, outList, time, client)  // warmed up

        let previous = hook.pointee
        allocations = 0
        watchedThread = pthread_self()
        hook.pointee = countAllocations
        var cycle = 0, ticket: UInt64 = 0
        while cycle < blocks.count {
            if let old = jk_chain_swap_correction(chain, stage, blocks[cycle], &ticket) { handedBack.append(old) }
            jk_chain_set_bypass(chain, stage, Int32(cycle % 50 == 49 ? 1 : 0))
            _ = jk_renderer_ioproc(0, time, inList, time, outList, time, client)
            cycle += 1
        }
        hook.pointee = previous
        watchedThread = nil
        XCTAssertEqual(allocations, 0, "no allocation on the audio thread")
        XCTAssertEqual(handedBack.count, blocks.count - 1)
    }

    // MARK: Apple's units

    private func renderSine(through chain: LiveChain, frequency: Double, buffers: Int = 40) throws -> (peak: Float, finite: Bool) {
        let renderer = try XCTUnwrap(jk_renderer_create_slots(2, 2, 2, [0, 1], [0, 1], [1, 1], nil, 0, 0, nil, nil))
        defer { jk_renderer_destroy(renderer) }
        _ = swap(renderer, JK_OUTPUT_CHAIN, chain.pointer)
        defer { _ = swap(renderer, JK_OUTPUT_CHAIN, nil) }
        let frames = 512
        let input = Buffers(streams: [2], frames: frames), output = Buffers(streams: [2], frames: frames)
        var phase = 0.0, peak: Float = 0, finite = true
        for buffer in 0..<buffers {
            for f in 0..<frames {
                let value = Float(0.5 * sin(phase))
                phase += 2 * .pi * frequency / 48_000
                input.set(stream: 0, channel: 0, frame: f, value)
                input.set(stream: 0, channel: 1, frame: f, value)
            }
            render(renderer, input, output)
            guard buffer >= buffers / 2 else { continue }  // settled
            for f in 0..<frames {
                let value = output.get(stream: 0, channel: 0, frame: f)
                if !value.isFinite { finite = false }
                peak = max(peak, abs(value))
            }
        }
        return (peak, finite)
    }

    func testAppleUnitsRenderInChains() throws {
        for kind in [EffectKind.highPass, .equalizer, .dynamics, .limiter] {
            let pool = EffectPool()
            let chain = try XCTUnwrap(LiveChain([Effect(kind)], position: .mix, channels: 2, sampleRate: 48_000, pool: pool),
                                      "\(kind.title): \(pool.problems.values.first ?? "")")
            XCTAssertEqual(chain.stages, [0], kind.title)
            let unit = try XCTUnwrap(chain.units.first)
            var frames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit.unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, &size)
            XCTAssertGreaterThanOrEqual(frames, UInt32(JK_MAX_FRAMES), "\(kind.title) takes the largest buffers")
            let result = try renderSine(through: chain, frequency: 1000)
            XCTAssertTrue(result.finite, kind.title)
            XCTAssertGreaterThan(result.peak, 0.05, "\(kind.title) passes a 1 kHz tone")
            XCTAssertEqual(unit.errorCount, 0, "\(kind.title) rendered without errors")
            XCTAssertEqual(chain.latency, unit.latency, "\(kind.title): the chain's delay is its unit's")
        }
    }

    func testHighPassFilterRemovesRumble() throws {
        var effect = Effect(.highPass)
        effect.set(EffectKind.highPass.parameters[0], 1000)
        let chain = try XCTUnwrap(LiveChain([effect], position: .source, channels: 2, sampleRate: 48_000, pool: EffectPool()))
        XCTAssertEqual(chain.units.first?.parameter(AudioUnitParameterID(kHipassParam_CutoffFrequency)) ?? 0, 1000, accuracy: 0.5)
        let low = try renderSine(through: chain, frequency: 50)
        XCTAssertLessThan(low.peak, 0.05, "50 Hz is filtered out")
        // Bypassed, it passes.
        var bypassed = effect
        bypassed.bypass = true
        chain.update([bypassed], pool: nil, position: .source)
        XCTAssertGreaterThan(try renderSine(through: chain, frequency: 50).peak, 0.45)
    }

    func testUnitStateSavesAndRestores() throws {
        var effect = Effect(.dynamics)
        let threshold = EffectKind.dynamics.parameters[0]
        effect.set(threshold, -30)
        let unit = try EffectUnit(effect, channels: 2, sampleRate: 48_000)
        XCTAssertEqual(unit.parameter(threshold.id) ?? 0, -30, accuracy: 1e-3)
        let state = try XCTUnwrap(unit.state, "ClassInfo comes back as a property list")
        XCTAssertEqual(try XCTUnwrap(EffectUnit.capturedState(effect)).count, state.count)
        // A new unit made from the state alone has the same setting.
        var restored = Effect(.dynamics)
        restored.parameters = [:]
        restored.state = state
        let again = try EffectUnit(restored, channels: 2, sampleRate: 48_000)
        XCTAssertEqual(again.parameter(threshold.id) ?? 0, -30, accuracy: 1e-3)
        // Through saving the graph too.
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let index = try XCTUnwrap(graph.nodes.firstIndex { $0.kind == .virtualDevice(device.id) })
        graph.nodes[index].effects = [restored]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-effects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        try store.save(graph)
        let loaded = try XCTUnwrap(store.load()?.nodes[index].effects.first)
        XCTAssertEqual(loaded, restored)
        XCTAssertEqual(try EffectUnit(loaded, channels: 2, sampleRate: 48_000).parameter(threshold.id) ?? 0, -30, accuracy: 1e-3)
        XCTAssertNil(EffectUnit.capturedState(Effect(.gate)), "built-in effects have no unit state")
    }

    func testPoolKeepsUnitsAcrossRebuilds() throws {
        let pool = EffectPool()
        var effect = Effect(.limiter)
        let first = try XCTUnwrap(pool.unit(for: effect, position: .mix, channels: 2, sampleRate: 48_000))
        effect.set(EffectKind.limiter.parameters[0], 6)
        let same = try XCTUnwrap(pool.unit(for: effect, position: .mix, channels: 2, sampleRate: 48_000))
        XCTAssertTrue(first === same, "a rebuilt sink gets the same unit")
        XCTAssertEqual(same.parameter(EffectKind.limiter.parameters[0].id) ?? 0, 6, accuracy: 1e-3, "with new parameters")
        XCTAssertFalse(first === pool.unit(for: effect, position: .source, channels: 2, sampleRate: 48_000),
                       "before and after the mix are separate units")
        // Another format: a new unit (the old one may still render in an older chain), with the old one's state.
        effect.parameters = [:]
        let mono = try XCTUnwrap(pool.unit(for: effect, position: .mix, channels: 1, sampleRate: 48_000))
        XCTAssertFalse(mono === first)
        XCTAssertEqual(mono.channels, 1)
        XCTAssertEqual(mono.parameter(EffectKind.limiter.parameters[0].id) ?? 0, 6, accuracy: 1e-3, "settings carried over")
        pool.keep([])
        XCTAssertEqual(pool.count, 0)
        // An effect Junction doesn't know is left out and says why.
        let unknown = Effect(type: "aufx", subtype: "none", manufacturer: "Nope")
        XCTAssertNil(pool.unit(for: unknown, position: .mix, channels: 2, sampleRate: 48_000))
        XCTAssertNotNil(pool.problems[unknown.id])
    }

    // MARK: Planning and routing

    private func micIntoStreamMix(effects: [Effect], deviceEffects: [Effect] = []) -> (Graph, Node, Node, Node) {
        let canvas = Demo.streamMix.id
        let mic = Node(kind: .device(DeviceRef(uid: Demo.interface.uid, name: "Scarlett", inputChannels: 2, outputChannels: 2)),
                       canvas: canvas, effects: effects)
        let device = Node(kind: .virtualDevice(canvas), canvas: canvas, effects: deviceEffects)
        let speakers = Node(kind: .defaultOutput, canvas: canvas)
        var graph = Graph(virtualDevices: [Demo.streamMix], nodes: [mic, device, speakers])
        graph.cables = [Cable(from: PortRef(node: mic.id, channel: 1), to: PortRef(node: device.id, channel: 0)),
                        Cable(from: PortRef(node: mic.id, channel: 1), to: PortRef(node: device.id, channel: 1)),
                        Cable(from: PortRef(node: device.id, channel: 0), to: PortRef(node: speakers.id, channel: 0)),
                        Cable(from: PortRef(node: device.id, channel: 1), to: PortRef(node: speakers.id, channel: 1))]
        return (graph, mic, device, speakers)
    }

    func testPlannerGivesSourcesLanesAndChains() throws {
        var inventory = Demo.inventory
        inventory.devices[2].sampleRate = 48_000
        let gate = Effect(.gate), limiter = Effect(.limiter)
        let (graph, mic, device, speakers) = micIntoStreamMix(effects: [gate], deviceEffects: [limiter])
        let plan = Planner.plan(graph, inventory: inventory)
        let mix = try XCTUnwrap(plan.sinks.first { $0.sinkNode == device.id })
        // Stream Mix (2 in) then the interface (2 in): the interface's second channel is input 3, carried by lane 4.
        XCTAssertEqual(mix.laneBase, 4)
        XCTAssertEqual(mix.slots, [EffectSlot(node: mic.id, inputs: [3], effects: [gate])])
        XCTAssertEqual(mix.routes.map(\.input), [3, 3])
        XCTAssertEqual(mix.routes.map(\.lane), [4, 4])
        XCTAssertEqual(mix.effects, [limiter], "the device's chain runs after its mix")
        let out = try XCTUnwrap(plan.sinks.first { $0.sinkNode == speakers.id })
        XCTAssertEqual(out.slots.map(\.effects), [[]], "not again on its way out")
        XCTAssertEqual(out.slots.first?.inputs, [0, 1])

        // Changing effects changes no structure: the sink keeps running and swaps a chain.
        var edited = graph
        edited.nodes[0].effects = [limiter, gate]
        edited.nodes[0].effects[1].bypass = true
        let again = try XCTUnwrap(Planner.plan(edited, inventory: inventory).sinks.first { $0.sinkNode == device.id })
        XCTAssertEqual(again.structureKey, mix.structureKey)
        XCTAssertEqual(again.slots.first?.effects.map(\.kind), [.limiter, .gate])
    }

    func testRunnerSwapsChainsOnlyWhenTheirEffectsChange() throws {
        var inventory = Demo.inventory
        inventory.devices[2].sampleRate = 48_000
        let gate = Effect(.gate), gain = Effect(.gain)
        let (graph, mic, device, _) = micIntoStreamMix(effects: [gate, gain], deviceEffects: [Effect(.mono)])
        let pool = EffectPool()
        let plan = try XCTUnwrap(Planner.plan(graph, inventory: inventory).sinks.first { $0.sinkNode == device.id })
        let runner = try XCTUnwrap(SinkRunner(plan: plan, pool: pool))
        let chains = runner.chainPointers
        XCTAssertEqual(chains.count, 2)
        XCTAssertTrue(chains.allSatisfy { $0 != nil })
        XCTAssertEqual(Set(runner.effectLatencies.keys), [mic.id, device.id])

        // Bypass and a parameter: the same chains, new atomics.
        var tweaked = plan
        tweaked.slots[0].effects[1].bypass = true
        tweaked.slots[0].effects[1].set(EffectKind.gain.parameters[0], -6)
        runner.update(tweaked, pool: pool)
        XCTAssertEqual(runner.chainPointers, chains)
        let slotChain = try XCTUnwrap(chains[0])
        XCTAssertEqual(jk_chain_bypassed(slotChain, 1), 1)
        XCTAssertEqual(jk_chain_parameter(slotChain, 1, 0), Gain.linear(-6), accuracy: 1e-6)

        // Reordered: a new chain for the source; the device's stays.
        var reordered = tweaked
        reordered.slots[0].effects.reverse()
        runner.update(reordered, pool: pool)
        XCTAssertNotEqual(runner.chainPointers[0], chains[0])
        XCTAssertEqual(runner.chainPointers[1], chains[1])
        XCTAssertEqual(runner.retiredChainCount, 0, "not running: the old chain is freed at once")
        // Emptied: no chain at all.
        var emptied = reordered
        emptied.effects = []
        runner.update(emptied, pool: pool)
        XCTAssertNil(runner.chainPointers[1])
    }
}
