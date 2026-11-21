import CoreAudio
import JunctionKernel
import XCTest

/// Drives the real IOProc with hand-made buffer lists laid out the way an aggregate device delivers them.
final class KernelTests: XCTestCase {
    /// Buffers: one interleaved buffer per stream, `frames` long.
    final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        var storage: [UnsafeMutablePointer<Float>] = []

        init(streams: [Int], frames: Int) {
            list = AudioBufferList.allocate(maximumBuffers: streams.count)
            for (index, channels) in streams.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
                data.initialize(repeating: 0, count: channels * frames)
                storage.append(data)
                list[index] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * frames * 4), mData: data)
            }
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }

        func set(stream: Int, channel: Int, frame: Int, _ value: Float) {
            let channels = Int(list[stream].mNumberChannels)
            storage[stream][frame * channels + channel] = value
        }

        func get(stream: Int, channel: Int, frame: Int) -> Float {
            let channels = Int(list[stream].mNumberChannels)
            return storage[stream][frame * channels + channel]
        }
    }

    private func render(_ renderer: OpaquePointer, _ input: Buffers, _ output: Buffers) {
        var time = AudioTimeStamp()
        _ = jk_renderer_ioproc(0, &time, input.list.unsafePointer, &time, output.list.unsafeMutablePointer, &time,
                               UnsafeMutableRawPointer(renderer))
    }

    func testMixesRoutesIntoTheSink() throws {
        let frames = 64
        // Aggregate input: sink loopback (2) + mic (1) + tap (2) = channels 0…4.
        let input = Buffers(streams: [2, 1, 2], frames: frames)
        // Aggregate output: the sink (2) then another sub-device (2) that must stay silent.
        let output = Buffers(streams: [2, 2], frames: frames)
        for f in 0..<frames {
            input.set(stream: 0, channel: 0, frame: f, 9)  // the sink's own loopback: never routed
            input.set(stream: 1, channel: 0, frame: f, 0.5)
            input.set(stream: 2, channel: 0, frame: f, 0.25)
            input.set(stream: 2, channel: 1, frame: f, -0.25)
            output.set(stream: 1, channel: 0, frame: f, 7)  // stale data
        }
        let sources: [UInt32] = [2, 2, 3, 4]
        let destinations: [UInt32] = [0, 1, 0, 1]
        let gains: [Float] = [1, 1, 0.5, 0.5]
        let renderer = try XCTUnwrap(jk_renderer_create(5, 2, 4, sources, destinations, gains))
        defer { jk_renderer_destroy(renderer) }
        render(renderer, input, output)
        for f in 0..<frames {
            XCTAssertEqual(output.get(stream: 0, channel: 0, frame: f), 0.5 + 0.125, accuracy: 1e-6)
            XCTAssertEqual(output.get(stream: 0, channel: 1, frame: f), 0.5 - 0.125, accuracy: 1e-6)
            XCTAssertEqual(output.get(stream: 1, channel: 0, frame: f), 0)
        }
        XCTAssertEqual(jk_renderer_take_input_peak(renderer, 2), 0.5)
        XCTAssertEqual(jk_renderer_take_input_peak(renderer, 2), 0, "peaks reset when read")
        XCTAssertEqual(jk_renderer_take_output_peak(renderer, 0), 0.625, accuracy: 1e-6)
        XCTAssertEqual(jk_renderer_cycle_count(renderer), 1)
        XCTAssertEqual(jk_renderer_layout_mismatch_count(renderer), 0)
    }

    func testGainChangesGlideOverOneBuffer() throws {
        let frames = 100
        let input = Buffers(streams: [1], frames: frames)
        let output = Buffers(streams: [1], frames: frames)
        for f in 0..<frames { input.set(stream: 0, channel: 0, frame: f, 1) }
        let renderer = try XCTUnwrap(jk_renderer_create(1, 1, 1, [0], [0], [1]))
        defer { jk_renderer_destroy(renderer) }
        jk_renderer_set_route_gain(renderer, 0, 0)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 0), 0.99, accuracy: 1e-5)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 49), 0.5, accuracy: 1e-5)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 99), 0, accuracy: 1e-5)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 10), 0, "settled at the new gain")
        jk_renderer_set_route_gain(renderer, 0, 1)
        jk_renderer_set_master_gain(renderer, 0.5)
        render(renderer, input, output)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 10), 0.5, accuracy: 1e-6)
    }

    func testFadesInAndOutForCrossFades() throws {
        let frames = 100
        let input = Buffers(streams: [1], frames: frames)
        let output = Buffers(streams: [1], frames: frames)
        for f in 0..<frames { input.set(stream: 0, channel: 0, frame: f, 1) }
        let renderer = try XCTUnwrap(jk_renderer_create(1, 1, 1, [0], [0], [1]))
        defer { jk_renderer_destroy(renderer) }
        XCTAssertEqual(jk_renderer_fade_level(renderer), 1, "a new renderer plays at full level")

        // A replacement sink starts silent and fades in over 200 frames: two buffers.
        jk_renderer_set_fade_now(renderer, 0)
        jk_renderer_fade(renderer, 1, 200)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 0), 0.005, accuracy: 1e-6)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 99), 0.5, accuracy: 1e-5)
        XCTAssertEqual(jk_renderer_fade_level(renderer), 0.5, accuracy: 1e-5)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 99), 1, accuracy: 1e-5)
        XCTAssertEqual(jk_renderer_fade_level(renderer), 1)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 0), 1, "settled at full level")

        // The sink it replaces fades out and then stays silent.
        jk_renderer_fade(renderer, 0, 50)
        _ = jk_renderer_take_output_peak(renderer, 0)
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 0), 0.98, accuracy: 1e-5)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 49), 0, accuracy: 1e-5)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 99), 0)
        XCTAssertEqual(jk_renderer_fade_level(renderer), 0)
        XCTAssertEqual(jk_renderer_take_output_peak(renderer, 0), 0.98, accuracy: 1e-5, "meters show the faded level")
        render(renderer, input, output)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 10), 0)
        XCTAssertEqual(jk_renderer_take_output_peak(renderer, 0), 0)
        XCTAssertEqual(jk_renderer_take_input_peak(renderer, 0), 1, "inputs are still metered while silent")
    }

    func testUnexpectedLayoutIsCountedAndStaysInBounds() throws {
        let frames = 32
        let input = Buffers(streams: [1], frames: frames)  // expected 4 channels
        let output = Buffers(streams: [2], frames: frames)
        for f in 0..<frames { input.set(stream: 0, channel: 0, frame: f, 0.3) }
        let renderer = try XCTUnwrap(jk_renderer_create(4, 2, 2, [0, 3], [0, 1], [1, 1]))
        defer { jk_renderer_destroy(renderer) }
        render(renderer, input, output)
        XCTAssertEqual(jk_renderer_layout_mismatch_count(renderer), 1)
        XCTAssertEqual(output.get(stream: 0, channel: 0, frame: 5), 0.3, accuracy: 1e-6)
        XCTAssertEqual(output.get(stream: 0, channel: 1, frame: 5), 0, "a route from a missing channel stays silent")
    }
}
