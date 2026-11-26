import Foundation
import XCTest
@testable import JunctionCore

// The Choose Headphones sheet's model: search, choosing headphones, comparing presets, Use as one undo step (adding
// the Calibration effect when the output has none), reopening on the preset in use, the library's update states
// through the fake transport, and the licences Settings shows.

/// Stands in for the app: loads presets into a graph through the undo history.
@MainActor
final class HeadphonePickerTestHost: HeadphonePickerHost {
    var graph: Graph
    lazy var history = EditHistory(read: { [unowned self] in graph }, write: { [unowned self] in graph = $0 })
    private(set) var uses = 0

    init(graph: Graph) { self.graph = graph }

    func use(_ profile: CalibrationProfile, node: UUID, effect: UUID?) {
        uses += 1
        history.perform("Use Headphone Preset") { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == node }) else { return }
            graph.nodes[index].setCalibration(profile, effect: effect)
        }
    }
}

@MainActor
final class HeadphonePickerTests: XCTestCase {
    /// Made-up brands, models and authors: Studio 40 has two presets that load and one that doesn't.
    nonisolated static let jsonl = Data("""
    {"type":"vendor","id":"ash","data":{"name":"Ashgrove"}}
    {"type":"vendor","id":"north","data":{"name":"Northwind"}}
    {"type":"product","id":"ash::studio_40","data":{"name":"Studio 40","type":"headphones","subtype":"over_the_ear","vendor_id":"ash"}}
    {"type":"product","id":"ash::buds","data":{"name":"Buds","type":"headphones","subtype":"in_ear","vendor_id":"ash"}}
    {"type":"product","id":"north::studio_monitor","data":{"name":"Studio Monitor","type":"headphones","subtype":"over_the_ear","vendor_id":"north"}}
    {"type":"eq","id":"ash:studio_40::bench","data":{"author":"Bench Lab","details":"Measured by Bench Lab","link":"https://example.com/s40","type":"parametric_eq","parameters":{"gain_db":-5,"bands":[{"type":"low_shelf","frequency":105,"gain_db":4.5,"q":0.7},{"type":"peak_dip","frequency":3000,"gain_db":-3,"q":2}]},"product_id":"ash::studio_40"}}
    {"type":"eq","id":"ash:studio_40::quiet","data":{"author":"Quiet Room","details":"Toward a warmer target","type":"parametric_eq","parameters":{"gain_db":-7,"bands":[{"type":"low_shelf","frequency":105,"gain_db":6.5,"q":0.7}]},"product_id":"ash::studio_40"}}
    {"type":"eq","id":"ash:studio_40::band","data":{"author":"Field Notes","details":"Target C","type":"parametric_eq","parameters":{"gain_db":-2,"bands":[{"type":"band_pass","frequency":1000,"q":1}]},"product_id":"ash::studio_40"}}
    {"type":"eq","id":"ash:buds::field","data":{"author":"Field Notes","details":"In-ear target","type":"parametric_eq","parameters":{"gain_db":-3,"bands":[{"type":"peak_dip","frequency":6000,"gain_db":-3,"q":4}]},"product_id":"ash::buds"}}
    {"type":"eq","id":"north:studio_monitor::bench","data":{"author":"Bench Lab","details":"Measured by Bench Lab","type":"parametric_eq","parameters":{"gain_db":-1,"bands":[{"type":"peak_dip","frequency":200,"gain_db":-1,"q":1}]},"product_id":"north::studio_monitor"}}

    """.utf8)

    nonisolated static var library: HeadphoneLibrary {
        HeadphoneLibrary(jsonl: jsonl, source: .bundled, date: HeadphoneLibrary.bundledDate)
    }

    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    /// A store that reads `library` and updates through `transport` into a temporary folder.
    private func store(_ transport: HeadphoneLibraryUpdateTests.FakeTransport = .init(.fail(URLError(.notConnectedToInternet))),
                       library: HeadphoneLibrary = library) -> (HeadphoneLibraryStore, HeadphoneLibraryCache) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-picker-\(UUID().uuidString)")
        folders.append(folder)
        let cache = HeadphoneLibraryCache(folder: folder)
        let relaxed = HeadphoneLibraryCache.Requirements(minimumSize: 0, minimumProducts: 1, minimumPresets: 1)
        let store = HeadphoneLibraryStore(loader: { library },
                                          updater: { try await cache.update(transport: transport, requirements: relaxed) })
        return (store, cache)
    }

    /// An output on the headphones, with a Calibration effect or (`withEffect: false`) none, the host and a sheet on it.
    private func setUp(withEffect: Bool = true, store: HeadphoneLibraryStore? = nil)
        async -> (HeadphonePicker, HeadphonePickerTestHost, Node) {
        var node = Node(kind: .device(DeviceRef(uid: "phones", name: "Desk Phones", inputChannels: 0, outputChannels: 2)),
                        canvas: Demo.streamMix.id)
        if withEffect { node.setCalibration(nil) }
        let host = HeadphonePickerTestHost(graph: Graph(virtualDevices: [Demo.streamMix], nodes: [node]))
        let picker = HeadphonePicker(node: node.id, effect: node.calibrationEffect?.id, deviceUID: "phones",
                                     deviceName: "Desk Phones", store: store ?? self.store().0, host: host)
        await picker.load()
        return (picker, host, node)
    }

    /// Reopens the sheet as the app does: on the effect's current library preset.
    private func reopen(_ host: HeadphonePickerHost, graph: Graph, node: UUID, store: HeadphoneLibraryStore) -> HeadphonePicker {
        let effect = graph.node(node)?.calibrationEffect
        return HeadphonePicker(node: node, effect: effect?.id, deviceUID: "phones", deviceName: "Desk Phones",
                               presetInUse: effect?.calibration?.library?.presetID, store: store, host: host)
    }

    // MARK: Browsing

    func testSearchAndTheStyleFilterNarrowTheResults() async {
        let (picker, _, _) = await setUp()
        XCTAssertEqual(picker.results.map(\.name), ["Ashgrove Buds", "Ashgrove Studio 40", "Northwind Studio Monitor"],
                       "an empty search lists every model")
        picker.query = "studio"
        XCTAssertEqual(picker.results.map(\.name), ["Ashgrove Studio 40", "Northwind Studio Monitor"])
        picker.query = "studio40"
        XCTAssertEqual(picker.results.map(\.id), ["ash::studio_40"], "spacing doesn't matter")
        picker.query = ""
        XCTAssertEqual(picker.styles.map(\.name), ["Over-ear", "In-ear"])
        picker.style = HeadphoneStyle(type: "headphones", subtype: "in_ear")
        XCTAssertEqual(picker.results.map(\.id), ["ash::buds"])
        picker.query = "monitor"
        XCTAssertTrue(picker.results.isEmpty)
        picker.style = nil
        XCTAssertEqual(picker.results.map(\.id), ["north::studio_monitor"])
    }

    func testNothingIsListedUntilTheLibraryIsRead() async {
        let (store, _) = store()
        let host = HeadphonePickerTestHost(graph: Graph())
        let picker = HeadphonePicker(node: UUID(), effect: nil, presetInUse: "ash:studio_40::quiet", store: store, host: host)
        XCTAssertTrue(picker.results.isEmpty)
        XCTAssertNil(picker.chosen)
        XCTAssertEqual(store.status, "Reading the headphone library…")
        await picker.load()
        XCTAssertEqual(picker.results.count, 3)
        XCTAssertEqual(picker.chosenID, "ash::studio_40", "once read, the sheet shows the preset in use")
        XCTAssertEqual(picker.selectedPresetID, "ash:studio_40::quiet")
    }

    func testChoosingHeadphonesSelectsTheirFirstPresetThatLoads() async {
        let (picker, _, _) = await setUp()
        XCTAssertNil(picker.chosen)
        XCTAssertFalse(picker.canUse)
        picker.chosenID = "ash::studio_40"
        XCTAssertEqual(picker.chosen?.name, "Ashgrove Studio 40")
        XCTAssertEqual(picker.chosen?.presets.map(\.author), ["Bench Lab", "Quiet Room", "Field Notes"])
        XCTAssertEqual(picker.selectedPresetID, "ash:studio_40::bench")
        XCTAssertEqual(picker.compared, ["ash:studio_40::bench"], "the selected preset is drawn")
        XCTAssertTrue(picker.canUse)
        // Other headphones start over.
        picker.setCompared("ash:studio_40::quiet", true)
        picker.chosenID = "ash::buds"
        XCTAssertEqual(picker.selectedPresetID, "ash:buds::field")
        XCTAssertEqual(picker.compared, ["ash:buds::field"])
    }

    func testPresetsAreComparedAsTheirCorrections() async throws {
        let (picker, _, _) = await setUp()
        picker.chosenID = "ash::studio_40"
        picker.setCompared("ash:studio_40::quiet", true)
        picker.setCompared("ash:studio_40::band", true)
        XCTAssertEqual(picker.comparedPresets.map(\.id), ["ash:studio_40::bench", "ash:studio_40::quiet"],
                       "in the headphones' order, without the one that can't be loaded")
        // The selected preset can't be hidden; another can.
        picker.setCompared("ash:studio_40::bench", false)
        XCTAssertTrue(picker.compared.contains("ash:studio_40::bench"))
        picker.selectedPresetID = "ash:studio_40::quiet"
        picker.setCompared("ash:studio_40::bench", false)
        XCTAssertEqual(picker.comparedPresets.map(\.id), ["ash:studio_40::quiet"])

        // A curve is the correction as it would run: filters and preamp, on the calibration grid.
        let headphones = try XCTUnwrap(picker.chosen)
        let quiet = headphones.presets[1]
        let curve = try XCTUnwrap(picker.curve(quiet))
        XCTAssertEqual(curve.count, CalibrationGrid.frequencies.count)
        XCTAssertEqual(curve, try CalibrationProfile.headphones(headphones, preset: quiet).curve(channel: 0, sampleRate: 48_000))
        XCTAssertEqual(curve.first ?? 0, -0.5, accuracy: 0.3, "6.5 dB of bass shelf under a 7 dB preamp")
        XCTAssertEqual(curve.last ?? 0, -7, accuracy: 0.3)
        XCTAssertNil(picker.curve(headphones.presets[2]), "nothing to draw for a preset that can't be loaded")
    }

    // MARK: Use

    func testUseLoadsTheCreditedPresetAsOneUndoStep() async throws {
        let (picker, host, node) = await setUp()
        picker.chosenID = "ash::studio_40"
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertTrue(picker.use(date: date))
        XCTAssertEqual(host.uses, 1)
        let profile = try XCTUnwrap(host.graph.node(node.id)?.calibrationEffect?.calibration)
        XCTAssertEqual(profile.name, "Ashgrove Studio 40")
        XCTAssertEqual(profile.kind, .headphones)
        XCTAssertEqual(profile.date, date)
        XCTAssertEqual(profile.deviceUID, "phones")
        XCTAssertEqual(profile.deviceName, "Desk Phones")
        XCTAssertEqual(profile.preamp, -5)
        XCTAssertEqual(profile.channels, [CalibrationChannel(filters: [CalibrationFilter(.lowShelf, frequency: 105, gain: 4.5, q: 0.7),
                                                                       CalibrationFilter(.peaking, frequency: 3_000, gain: -3, q: 2)])])
        XCTAssertEqual(profile.library, HeadphoneLibraryCredit(presetID: "ash:studio_40::bench", author: "Bench Lab",
                                                               details: "Measured by Bench Lab", link: "https://example.com/s40"))
        XCTAssertEqual(host.graph.node(node.id)?.effects.count, 1, "into the effect the output has")
        XCTAssertEqual(host.history.undoName, "Use Headphone Preset")

        host.history.undo()
        XCTAssertNil(host.graph.node(node.id)?.calibrationEffect?.calibration, "Undo takes the preset back out")
        XCTAssertFalse(host.history.canUndo, "it was one step")
        host.history.redo()
        XCTAssertEqual(host.graph.node(node.id)?.calibrationEffect?.calibration?.library?.presetID, "ash:studio_40::bench")
    }

    func testUseAddsTheCalibrationEffectWhenTheOutputHasNone() async throws {
        let (picker, host, node) = await setUp(withEffect: false)
        XCTAssertNil(picker.effect)
        picker.chosenID = "ash::buds"
        XCTAssertTrue(picker.use())
        let effect = try XCTUnwrap(host.graph.node(node.id)?.calibrationEffect)
        XCTAssertEqual(effect.calibration?.library?.presetID, "ash:buds::field")
        host.history.undo()
        XCTAssertEqual(host.graph.node(node.id)?.effects, [], "the effect and the preset go in one undo step")
        XCTAssertFalse(host.history.canUndo)
    }

    func testAPresetThatCantBeLoadedIsntUsed() async {
        let (picker, host, node) = await setUp()
        picker.chosenID = "ash::studio_40"
        picker.selectedPresetID = "ash:studio_40::band"
        XCTAssertFalse(picker.canUse)
        XCTAssertFalse(picker.use())
        XCTAssertEqual(picker.problem, "Junction can't load this preset: band 1 is a band-pass filter, which Junction doesn't have.")
        XCTAssertEqual(host.uses, 0)
        XCTAssertNil(host.graph.node(node.id)?.calibrationEffect?.calibration)
        XCTAssertFalse(host.history.canUndo)
        picker.selectedPresetID = "ash:studio_40::quiet"
        XCTAssertNil(picker.problem, "picking another preset clears it")
    }

    func testTheSheetReopensOnThePresetInUse() async {
        let (store, _) = store()
        let (picker, host, node) = await setUp(store: store)
        picker.chosenID = "ash::studio_40"
        picker.selectedPresetID = "ash:studio_40::quiet"
        picker.use()

        let again = reopen(host, graph: host.graph, node: node.id, store: store)
        XCTAssertEqual(again.presetInUse, "ash:studio_40::quiet")
        XCTAssertEqual(again.chosenID, "ash::studio_40", "the library is read already: the sheet opens on it at once")
        XCTAssertEqual(again.selectedPresetID, "ash:studio_40::quiet")
        XCTAssertEqual(again.compared, ["ash:studio_40::quiet"])
        XCTAssertEqual(again.query, "")

        // After Undo there's nothing in use: the sheet opens on nothing.
        host.history.undo()
        let empty = reopen(host, graph: host.graph, node: node.id, store: store)
        XCTAssertNil(empty.presetInUse)
        XCTAssertNil(empty.chosenID)

        // A preset that isn't in the library (any more) leaves the sheet on nothing.
        let gone = HeadphonePicker(node: node.id, effect: nil, presetInUse: "ash:gone::bench", store: store, host: host)
        XCTAssertNil(gone.chosenID)
    }

    // MARK: The library

    func testStatusSaysWhichCopyWithItsDateAndCounts() async {
        let (store, _) = store()
        await store.load()
        let date = HeadphoneLibrary.bundledDate.formatted(date: .abbreviated, time: .omitted)
        XCTAssertEqual(store.status, "Bundled with Junction, from \(date) · 3 headphone models · 5 presets")
        // The sheet's two lines: which copy, then the counts.
        XCTAssertEqual(store.statusLines, ["Bundled with Junction, from \(date)", "3 headphone models · 5 presets"])
        var summary = Self.library.summary
        summary.source = .downloaded
        summary.date = nil
        summary.products = 1
        summary.presets = 1_234
        XCTAssertEqual(HeadphoneLibraryStore.status(summary), "Downloaded · 1 headphone model · \(1_234.formatted()) presets")

        let failing = HeadphoneLibraryStore(loader: { throw HeadphoneLibraryError.missing("database_v1.jsonl.lzma") },
                                            updater: { Self.library })
        await failing.load()
        XCTAssertNil(failing.library)
        XCTAssertEqual(failing.status, "The headphone library “database_v1.jsonl.lzma” isn't there.")
        XCTAssertEqual(failing.statusLines, ["The headphone library “database_v1.jsonl.lzma” isn't there."])
    }

    /// A made-up download with `count` models.
    private func download(_ count: Int) -> Data {
        var lines = [#"{"type":"vendor","id":"tide","data":{"name":"Tidewater"}}"#]
        for index in 0..<count {
            lines.append(#"{"type":"product","id":"tide::m\#(index)","data":{"name":"Model \#(index)","type":"headphones","subtype":"over_the_ear","vendor_id":"tide"}}"#)
            lines.append(#"{"type":"eq","id":"tide:m\#(index)::bench","data":{"author":"Bench Lab","details":"Target","type":"parametric_eq","parameters":{"gain_db":-2,"bands":[{"type":"peak_dip","frequency":1000,"gain_db":-2,"q":1}]},"product_id":"tide::m\#(index)"}}"#)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func testAnUpdateReplacesTheLibraryTheSheetShows() async throws {
        let (store, cache) = store(.init(.serve(download(4))))
        let (picker, _, _) = await setUp(store: store)
        XCTAssertEqual(store.library?.summary.source, .bundled)
        XCTAssertEqual(store.updateState, .idle)
        store.update()
        XCTAssertEqual(store.updateState, .updating)
        XCTAssertTrue(store.isUpdating)
        await store.waitForUpdate()
        XCTAssertEqual(store.updateState, .updated)
        XCTAssertEqual(store.library?.summary.source, .downloaded)
        XCTAssertEqual(store.library?.summary.products, 4)
        XCTAssertTrue(store.status.hasPrefix("Downloaded "), store.status)
        XCTAssertNotNil(cache.record, "the download is the cached copy now")
        XCTAssertEqual(picker.results.count, 4, "the sheet lists the new library at once")
    }

    func testAFailedUpdateKeepsTheLibraryAndSaysWhy() async throws {
        let (store, cache) = store(.init(.fail(URLError(.notConnectedToInternet))))
        await store.load()
        store.update()
        await store.waitForUpdate()
        guard case .failed(let reason) = store.updateState else { return XCTFail("\(store.updateState)") }
        XCTAssertTrue(reason.hasPrefix("The headphone library couldn't be downloaded:"), reason)
        XCTAssertTrue(reason.hasSuffix("The current headphone library is kept."), reason)
        XCTAssertEqual(store.library?.summary.source, .bundled)
        XCTAssertEqual(store.library?.summary.products, 3)
        XCTAssertNil(cache.record)

        // A download that isn't a library fails its checks the same way.
        let (invalid, _) = self.store(.init(.serve(Data("<html>Not found</html>\n".utf8))))
        await invalid.load()
        invalid.update()
        await invalid.waitForUpdate()
        guard case .failed(let check) = invalid.updateState else { return XCTFail("\(invalid.updateState)") }
        XCTAssertTrue(check.hasPrefix("The downloaded file isn't a usable headphone library"), check)
        XCTAssertEqual(invalid.library?.summary.products, 3)
    }

    func testAnUpdateCanBeCancelled() async throws {
        let transport = HeadphoneLibraryUpdateTests.FakeTransport(.hang(download(4).prefix(100)))
        let (store, cache) = store(transport)
        await store.load()
        store.update()
        store.update()  // a second click while one runs does nothing
        while transport.requested.isEmpty, store.isUpdating { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(transport.requested.count, 1)
        store.cancelUpdate()
        await store.waitForUpdate()
        XCTAssertEqual(store.updateState, .failed(HeadphoneLibraryUpdateError.cancelled.localizedDescription))
        XCTAssertEqual(store.library?.summary.source, .bundled)
        XCTAssertNil(cache.record)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: cache.folder.path)) ?? [], [],
                       "the partial download is gone")
    }

    func testSnapshotModesLibraryNeverDownloads() async {
        let store = HeadphoneLibraryStore(library: Self.library, updateProblem: "snapshot mode doesn't download.")
        XCTAssertNotNil(store.library, "read at once")
        store.update()
        await store.waitForUpdate()
        XCTAssertEqual(store.updateState, .failed(HeadphoneLibraryUpdateError.network("snapshot mode doesn't download.")
                                                    .localizedDescription))
        XCTAssertEqual(store.library?.summary.products, 3)
    }

    // MARK: Acknowledgements

    func testTheBundledLicencesAreShown() {
        let folder = HeadphoneLibraryTests.bundled.deletingLastPathComponent()
        let licences = HeadphoneLibraryLicence.bundled(in: folder)
        XCTAssertEqual(licences.map(\.title), ["OPRA", "AutoEQ"])
        XCTAssertTrue(licences[0].text.contains("Attribution-ShareAlike 4.0 International"), "the data's licence")
        XCTAssertTrue(licences[0].text.contains("MIT License"), "the code's licence")
        XCTAssertTrue(licences[0].summary.contains("CC BY-SA 4.0"))
        XCTAssertTrue(licences[1].text.contains("MIT License"))
        XCTAssertTrue(licences[1].text.contains("AutoEQ"))
        XCTAssertEqual(HeadphoneLibraryLicence.bundled(in: folder.appendingPathComponent("missing")), [])
        XCTAssertEqual(HeadphoneLibraryLicence.bundled(in: nil), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("opra_logo.png").path),
                      "the logo the credit shows")
    }
}
