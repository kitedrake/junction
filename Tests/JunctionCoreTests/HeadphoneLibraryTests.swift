import Foundation
import XCTest
@testable import JunctionCore

// The headphone library: reading OPRA's JSON Lines (a made-up fixture, and the bundled copy by path), search, and
// presets turned into credited profiles that survive graph.json.

final class HeadphoneLibraryTests: XCTestCase {
    /// Made-up brands, models and authors covering every band type, unknown entries and band types, unreadable lines
    /// and missing brands and models.
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/headphone-library.jsonl")
    /// The copy Junction.app carries.
    static let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/HeadphoneLibrary/database_v1.jsonl.lzma")

    private func fixtureLibrary() throws -> HeadphoneLibrary {
        HeadphoneLibrary(jsonl: try Data(contentsOf: Self.fixture), source: .bundled, date: HeadphoneLibrary.bundledDate)
    }

    // MARK: Reading

    func testFixtureIsReadWithWhatItCantUseCounted() throws {
        let library = try fixtureLibrary()
        let summary = library.summary
        XCTAssertEqual(summary.source, .bundled)
        XCTAssertEqual(summary.date, HeadphoneLibrary.bundledDate)
        XCTAssertEqual(summary.brands, 2)
        XCTAssertEqual(summary.products, 5)
        XCTAssertEqual(summary.presets, 6)
        XCTAssertEqual(summary.unavailablePresets, 3)
        // A cut-off line, a line that isn't an object and a brand without a name; the blank line and the unknown entry
        // type aren't counted.
        XCTAssertEqual(summary.unreadableLines, 3)
        XCTAssertEqual(summary.droppedProducts, 1, "a model whose brand is missing")
        XCTAssertEqual(summary.droppedPresets, 2, "a preset for that model, and one whose model is missing")
        XCTAssertNil(library.model(id: "ghost::phantom"))

        // Brands with accents, a CRLF line, and models in brand and model order.
        XCTAssertEqual(library.models.map(\.name),
                       ["Acmé Audio Studio Bud", "Acmé Audio Studio One", "Zenith Earphone 7", "Zenith One",
                        "Zenith Studio Tribute"])

        // Every band type, with unknown fields ignored.
        let one = try XCTUnwrap(library.model(id: "acme::studio_one"))
        XCTAssertEqual(one.brand, "Acmé Audio")
        XCTAssertEqual(one.model, "Studio One")
        XCTAssertEqual(one.style, HeadphoneStyle(type: "headphones", subtype: "over_the_ear"))
        let preset = try XCTUnwrap(one.presets.first)
        XCTAssertEqual(preset.id, "acme:studio_one::tuner_one_flat")
        XCTAssertEqual(preset.author, "Tuner One")
        XCTAssertEqual(preset.details, "Measured by Bench A")
        XCTAssertEqual(preset.link, "https://example.com/studio-one")
        XCTAssertEqual(preset.preamp, -6.5)
        XCTAssertNil(preset.problem)
        XCTAssertEqual(preset.filters, [CalibrationFilter(.peaking, frequency: 170, gain: -1.9, q: 1.47),
                                        CalibrationFilter(.lowShelf, frequency: 105, gain: 5.5, q: 0.7),
                                        CalibrationFilter(.highShelf, frequency: 10_000, gain: -2.2, q: 0.6),
                                        CalibrationFilter(.lowPass, frequency: 15_000, gain: 0)])
        // A shelf without a Q gets 0.707, as a preset file's would.
        XCTAssertEqual(library.model(id: "zenith::one")?.presets.first?.filters.last,
                       CalibrationFilter(.highShelf, frequency: 8000, gain: 2))
        XCTAssertEqual(library.model(id: "zenith::studio_tribute")?.presets, [], "a model without presets is listed")
    }

    func testPresetsJunctionCantPlayAreListedWithTheReasonAndNeverHalfLoaded() throws {
        let library = try fixtureLibrary()
        let bud = try XCTUnwrap(library.model(id: "acme::studio_bud"))
        XCTAssertEqual(bud.presets.map(\.details), ["Target B", "Target A", "Target C", "Target D"])
        let (bandPass, fine, steep, graphic) = (bud.presets[0], bud.presets[1], bud.presets[2], bud.presets[3])
        XCTAssertEqual(bandPass.problem, "band 2 is a band-pass filter, which Junction doesn't have")
        XCTAssertEqual(steep.problem, "band 1 is a 24 dB/octave low-pass; Junction's have 12 dB/octave")
        XCTAssertEqual(graphic.problem, "it is a graphic eq, not a parametric EQ")
        for preset in [bandPass, steep, graphic] {
            XCTAssertFalse(preset.isAvailable)
            XCTAssertEqual(preset.filters, [], "nothing of an unavailable preset is kept")
            XCTAssertThrowsError(try CalibrationProfile.headphones(bud, preset: preset)) {
                XCTAssertEqual($0 as? HeadphoneLibraryError, .unavailable(preset.problem!))
                XCTAssertFalse(($0 as? LocalizedError)?.errorDescription?.isEmpty ?? true)
            }
        }
        XCTAssertTrue(fine.isAvailable)
        XCTAssertEqual(fine.filters, [CalibrationFilter(.peaking, frequency: 3000, gain: -4, q: 2),
                                      CalibrationFilter(.lowPass, frequency: 12_000, gain: 0, q: 0.5)])
        // A band that can't be read, or lacks what its type needs, makes the preset unavailable too.
        func problem(_ band: Any) -> String? {
            HeadphoneLibrary.preset(id: "x", ["parameters": ["gain_db": 0, "bands": [band]] as [String: Any]]).problem
        }
        XCTAssertEqual(problem("peak"), "band 1 can't be read")
        XCTAssertEqual(problem(["type": "peak_dip", "frequency": 100, "gain_db": 1] as [String: Any]), "band 1 has no usable Q")
        XCTAssertEqual(problem(["type": "low_shelf", "frequency": 100] as [String: Any]), "band 1 has no gain")
        XCTAssertEqual(problem(["type": "low_pass", "frequency": true] as [String: Any]), "band 1 has no frequency")
        XCTAssertEqual(HeadphoneLibrary.preset(id: "x", ["type": "parametric_eq"]).problem, "it has no bands")
    }

    func testStylesAreTheDataOwn() throws {
        let library = try fixtureLibrary()
        XCTAssertEqual(Set(library.styles.map(\.name)), ["Over-ear", "In-ear", "Earbuds", "On-ear", "Neckband"])
        XCTAssertEqual(HeadphoneStyle(type: "headphones", subtype: "").name, "Headphones")
    }

    // MARK: Search

    func testSearchRanksPrefixMatchesFirst() throws {
        let library = try fixtureLibrary()
        // The model starts with it, then a word does, then it's inside a word.
        XCTAssertEqual(library.search("one").map(\.name), ["Zenith One", "Acmé Audio Studio One", "Zenith Earphone 7"])
        XCTAssertEqual(library.search("studio").map(\.name),
                       ["Acmé Audio Studio Bud", "Acmé Audio Studio One", "Zenith Studio Tribute"])
        // Brand and model together, in any order, with or without spaces.
        XCTAssertEqual(library.search("acme studio on").map(\.name), ["Acmé Audio Studio One"])
        XCTAssertEqual(library.search("one studio").map(\.name), ["Acmé Audio Studio One"])
        XCTAssertEqual(library.search("studioone").map(\.name), ["Acmé Audio Studio One"])
        XCTAssertEqual(library.search("Earphone-7").map(\.name), ["Zenith Earphone 7"])
        XCTAssertTrue(library.search("zz top").isEmpty)
        XCTAssertEqual(library.search("").count, library.models.count)
        XCTAssertEqual(library.search("  ").map(\.id), library.models.map(\.id))
    }

    func testSearchIgnoresCaseAndAccents() throws {
        let library = try fixtureLibrary()
        let acme = ["Acmé Audio Studio Bud", "Acmé Audio Studio One"]
        for query in ["acme", "ACME", "Acmé", "ACMÉ", "acmè", "ａｃｍｅ"] {
            XCTAssertEqual(library.search(query).map(\.name), acme, query)
        }
        XCTAssertEqual(library.search("ZENITH ONE").map(\.name), ["Zenith One", "Zenith Earphone 7"])
    }

    func testSearchFiltersByStyle() throws {
        let library = try fixtureLibrary()
        let overEar = HeadphoneStyle(type: "headphones", subtype: "over_the_ear")
        XCTAssertEqual(library.search("studio", style: overEar).map(\.name), ["Acmé Audio Studio One"])
        XCTAssertEqual(library.search("", style: HeadphoneStyle(type: "headphones", subtype: "in_ear")).map(\.name),
                       ["Acmé Audio Studio Bud"])
        XCTAssertEqual(library.search("", style: HeadphoneStyle(type: "headphones", subtype: "neckband")).map(\.name),
                       ["Zenith Earphone 7"])
        XCTAssertEqual(library.search("one", style: HeadphoneStyle(type: "headphones", subtype: "earbuds")).map(\.name),
                       ["Zenith One"])
        XCTAssertTrue(library.search("", style: HeadphoneStyle(type: "speakers", subtype: "")).isEmpty)
    }

    // MARK: The bundled copy

    func testBundledLibraryLoadsOffTheMainThreadWithEveryPresetAccountedFor() async throws {
        let library = try await HeadphoneLibrary.load(contentsOf: Self.bundled, source: .bundled,
                                                      date: HeadphoneLibrary.bundledDate)
        XCTAssertFalse(library.indexedOnMainThread)
        let summary = library.summary
        XCTAssertEqual(summary.source, .bundled)
        XCTAssertEqual(summary.date, HeadphoneLibrary.bundledDate)
        XCTAssertEqual(summary.brands, 714)
        XCTAssertEqual(summary.products, 6_230)
        XCTAssertEqual(summary.presets, 12_594)
        XCTAssertEqual(summary.unreadableLines, 0)
        XCTAssertEqual(summary.droppedProducts, 0)
        XCTAssertEqual(summary.droppedPresets, 0)
        let presets = library.models.flatMap(\.presets)
        XCTAssertEqual(presets.count, 12_594)
        XCTAssertEqual(summary.unavailablePresets, presets.filter { !$0.isAvailable }.count)
        for preset in presets {
            if let problem = preset.problem {
                XCTAssertFalse(problem.isEmpty, preset.id)
                XCTAssertEqual(preset.filters, [], preset.id)
            } else {
                XCTAssertFalse(preset.filters.isEmpty, preset.id)
                XCTAssertFalse(preset.author.isEmpty, preset.id)
            }
        }
        // Its low-passes (12 dB per octave) load.
        let lowPassed = presets.filter { $0.filters.contains { $0.kind == .lowPass } }
        XCTAssertEqual(lowPassed.count, 5)
        XCTAssertTrue(lowPassed.allSatisfy(\.isAvailable))
        XCTAssertTrue(lowPassed.flatMap(\.filters).filter { $0.kind == .lowPass }.allSatisfy { abs($0.q - 1 / 2.0.squareRoot()) < 1e-12 })
        // Every style the data has is offered.
        XCTAssertEqual(Set(library.styles.map(\.name)), ["Over-ear", "On-ear", "In-ear", "Earbuds"])
    }

    func testSearchOverTheBundledLibraryRunsWithinAFrame() throws {
        let library = try HeadphoneLibrary(contentsOf: Self.bundled, source: .bundled, date: HeadphoneLibrary.bundledDate)
        // Queries from the data itself: a model's brand, the start of it, a model, and nothing.
        let sample = library.models[library.models.count / 2]
        let queries = ["", "a", "e", String(sample.brand.prefix(3)), sample.brand, sample.name, sample.model, "2", "zzqx",
                       "pro 2"]
        let overEar = HeadphoneStyle(type: "headphones", subtype: "over_the_ear")
        XCTAssertTrue(library.search(sample.name).contains { $0.id == sample.id })
        XCTAssertEqual(library.search(sample.brand.uppercased()).first?.brand, sample.brand)
        // Typing in the search box stays smooth while a query over all 6,230 models takes under a frame (1/60 s), even in
        // a debug build on a slow Mac: typically under 4 ms, about twice that on GitHub's Mac runners. Each query counts
        // with the median of five runs, so a run that the machine happened to slow down doesn't fail the test.
        var slowest = (seconds: 0.0, query: 0)
        for (number, query) in queries.enumerated() {
            for style in [nil, overEar] {
                var times: [Double] = []
                for _ in 0..<5 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = library.search(query, style: style)
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                }
                let median = times.sorted()[times.count / 2]
                if median > slowest.seconds { slowest = (median, number) }
            }
        }
        XCTAssertLessThan(slowest.seconds, 1.0 / 60, "slowest query (number \(slowest.query)): \(slowest.seconds * 1000) ms")
    }

    // MARK: Profiles

    func testAPresetBecomesACreditedHeadphoneProfile() throws {
        let library = try fixtureLibrary()
        let one = try XCTUnwrap(library.model(id: "acme::studio_one"))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let profile = try CalibrationProfile.headphones(one, preset: one.presets[0], date: date)
        XCTAssertEqual(profile.name, "Acmé Audio Studio One")
        XCTAssertEqual(profile.kind, .headphones)
        XCTAssertEqual(profile.date, date)
        XCTAssertNil(profile.deviceUID)
        XCTAssertEqual(profile.preamp, -6.5)
        XCTAssertEqual(profile.channels, [CalibrationChannel(filters: one.presets[0].filters)])
        XCTAssertEqual(profile.library, HeadphoneLibraryCredit(presetID: "acme:studio_one::tuner_one_flat", author: "Tuner One",
                                                               details: "Measured by Bench A",
                                                               link: "https://example.com/studio-one"))
        // A preset with a positive gain is kept at or below 0 dB, like a preset file.
        let bud = try XCTUnwrap(library.model(id: "acme::studio_bud"))
        XCTAssertEqual(try CalibrationProfile.headphones(bud, preset: bud.presets[1]).preamp, 0)
        // Its low-pass is in the curve: 12 dB per octave above 15 kHz at 48 kHz.
        let curve = profile.curve(channel: 0, sampleRate: 48_000, at: [1_000, 15_000, 22_000])
        let withoutLowPass = CalibrationFilter.response(of: Array(one.presets[0].filters.prefix(3)), preamp: -6.5,
                                                        sampleRate: 48_000, at: [1_000, 15_000, 22_000])
        XCTAssertEqual(curve[0], withoutLowPass[0], accuracy: 0.01)
        XCTAssertEqual(curve[1] - withoutLowPass[1], 20 * log10(1 / 2.0.squareRoot()), accuracy: 1e-6)
        XCTAssertLessThan(curve[2] - withoutLowPass[2], -12)
    }

    func testCreditsSurviveGraphJSON() throws {
        let library = try fixtureLibrary()
        let one = try XCTUnwrap(library.model(id: "acme::studio_one"))
        let profile = try CalibrationProfile.headphones(one, preset: one.presets[0],
                                                        date: Date(timeIntervalSinceReferenceDate: 800_000_000))
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        var output = Node(kind: .defaultOutput, canvas: device.id)
        output.setCalibration(profile)
        graph.nodes.append(output)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(graph)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains(#""library":{"author":"Tuner One","details":"Measured by Bench A","#))
        XCTAssertTrue(text.contains(#""kind":"lowPass""#))
        var decoded = try JSONDecoder().decode(Graph.self, from: json)
        decoded.upgrade()
        XCTAssertEqual(decoded.node(output.id)?.calibrationEffect?.calibration, profile)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(folder: folder)
        try store.save(graph)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.node(output.id)?.calibrationEffect?.calibration?.library, profile.library)
        XCTAssertEqual(loaded, graph)
    }

    func testSchema5FilesLoadUnchanged() throws {
        var graph = Graph()
        let device = Templates.streamWithoutChat(&graph, excluding: [])
        let profile = CalibrationProfile(name: "Studio Cans", kind: .headphones,
                                         date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                         channels: [CalibrationChannel(filters: [CalibrationFilter(.peaking, frequency: 180,
                                                                                                   gain: -3.2, q: 1.4)])],
                                         preamp: -2)
        var output = Node(kind: .defaultOutput, canvas: device.id, effects: [Effect(.limiter)])
        output.setCalibration(profile)
        graph.nodes.append(output)
        graph.scenes = [RoutingScene(name: "Streaming", capturing: graph)]
        graph.schema = 5
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let old = try encoder.encode(graph)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("library"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-schema6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)
        try old.write(to: store.graphURL)
        var loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.schema, 6)
        XCTAssertEqual(Graph.currentSchema, 6)
        loaded.schema = 5
        XCTAssertEqual(loaded, graph, "nothing else changes")
        XCTAssertEqual(try encoder.encode(loaded), old)

        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("adjustment"))

        // A schema 5 file from a development build with library credits and adjustments keeps its profiles, without
        // them.
        var development = graph
        let credit = HeadphoneLibraryCredit(presetID: "acme:studio_one::tuner_one_flat", author: "Tuner One",
                                            details: "Target A")
        let adjustment = CalibrationTarget(tilt: -0.5, lowShelf: .init(frequency: 105, gain: 3))
        let last = development.nodes.count - 1
        development.nodes[last].effects[1].calibration?.library = credit
        development.nodes[last].effects[1].calibration?.adjustment = adjustment
        development.scenes = [RoutingScene(name: "Streaming", capturing: development)]
        XCTAssertEqual(development.scenes[0].nodes.last?.effects[1].calibration?.library, credit)
        XCTAssertEqual(development.scenes[0].nodes.last?.effects[1].calibration?.adjustment, adjustment)
        development.upgrade()
        XCTAssertEqual(development.schema, 6)
        XCTAssertEqual(development.node(output.id)?.calibrationEffect?.calibration, profile)
        XCTAssertTrue(development.scenes[0].nodes.flatMap(\.effects).allSatisfy { $0.calibration?.library == nil })
        XCTAssertTrue(development.scenes[0].nodes.flatMap(\.effects).allSatisfy { $0.calibration?.adjustment == nil })
        XCTAssertEqual(development.scenes[0].nodes.last?.effects[1].calibration, profile)
    }
}
