import Foundation
@testable import JunctionCore
import XCTest

final class HeadphoneAdjustmentTests: XCTestCase {
    private let preset = ParametricPreset(preamp: -4.5, filters: [
        CalibrationFilter(.lowShelf, frequency: 105, gain: 4.5, q: 0.7),
        CalibrationFilter(.peaking, frequency: 210, gain: -2.4, q: 0.9),
        CalibrationFilter(.peaking, frequency: 3_200, gain: -4.1, q: 3.5),
        CalibrationFilter(.highShelf, frequency: 9_500, gain: -3, q: 0.7),
    ])
    private let adjustment = CalibrationTarget(tilt: -0.8, lowShelf: .init(frequency: 80, gain: 4),
                                               highShelf: .init(frequency: 10_000, gain: -2))

    private var profile: CalibrationProfile {
        CalibrationProfile(name: "Studio Cans", preset: preset)
    }

    private func assertClose(_ a: [Double], _ b: [Double], within tolerance: Double, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: tolerance, message, file: file, line: line) }
    }

    func testAdjustmentAddsTheTargetCurveOnTopOfThePreset() {
        let adjusted = profile.adjusted(adjustment)
        XCTAssertEqual(adjusted.channels, profile.channels, "the preset's own filters stay as they are")
        XCTAssertEqual(adjusted.preamp, profile.preamp)
        XCTAssertEqual(adjusted.adjustmentFilters.count, CalibrationTarget.maximumSections)
        XCTAssertEqual(adjusted.playedFilters(channel: 0), preset.filters + adjusted.adjustmentFilters)

        // The added filters follow the speaker sheet's target: the tilt's slope about 1 kHz and its shelves.
        let frequencies = CalibrationGrid.frequencies.filter { (20...16_000).contains($0) }
        let added = CalibrationFilter.response(of: adjusted.adjustmentFilters, sampleRate: 96_000, at: frequencies)
        assertClose(added, frequencies.map(adjustment.level(at:)), within: 0.35)
        let tiltOnly = CalibrationTarget(tilt: 1.5)
        let tilt = CalibrationFilter.response(of: tiltOnly.filters, sampleRate: 48_000, at: frequencies)
        assertClose(tilt, frequencies.map { 1.5 * log2($0 / 1000) }, within: 0.5, "a straight slope about 1 kHz")
        XCTAssertEqual(CalibrationFilter.response(of: tiltOnly.filters, sampleRate: 48_000, at: [1000])[0], 0, accuracy: 0.05)

        // Preset plus adjustment is the total, and the preamp keeps the total at or below 0 dB.
        let total = adjusted.curve(channel: 0, sampleRate: 48_000)
        let sum = zip(adjusted.presetCurve(channel: 0, sampleRate: 48_000), adjusted.adjustmentCurve(sampleRate: 48_000)).map(+)
        assertClose(total, sum, within: 1e-9)
        XCTAssertLessThan(adjusted.playedPreamp, adjusted.preamp, "the bass boost needs more room than the preset left")
        XCTAssertLessThanOrEqual(CalibrationFilter.peak(of: adjusted.playedFilters(channel: 0), sampleRate: 48_000)
                                     + adjusted.playedPreamp, 0.001)

        // A cut needs no more room: the preset's preamp stays.
        let cut = profile.adjusted(CalibrationTarget(highShelf: .init(frequency: 8_000, gain: -3)))
        XCTAssertEqual(cut.playedPreamp, profile.preamp)
        XCTAssertEqual(cut.adjustmentFilters, [CalibrationFilter(.highShelf, frequency: 8_000, gain: -3)])
    }

    func testOnlyHeadphoneProfilesAreAdjusted() {
        var speakers = profile.adjusted(adjustment)
        speakers.kind = .speakers
        XCTAssertFalse(speakers.isAdjustable)
        XCTAssertEqual(speakers.adjustmentFilters, [])
        XCTAssertEqual(speakers.curve(channel: 0, sampleRate: 48_000), profile.curve(channel: 0, sampleRate: 48_000))
    }

    func testPresetAndAdjustmentStayWithinTheSectionLimit() {
        let limit = CalibrationLimits.maximumFilters
        let room = limit - CalibrationTarget.maximumSections
        func preset(_ count: Int, switchedOff: Int = 0) -> CalibrationProfile {
            let filters = (0..<count).map {
                CalibrationFilter(.peaking, frequency: 40 * pow(1.2, Double($0)), gain: -1, q: 2, isOn: $0 >= switchedOff)
            }
            return CalibrationProfile(name: "Many", preset: ParametricPreset(preamp: 0, filters: filters)).adjusted(adjustment)
        }
        let fits = preset(room)
        XCTAssertTrue(fits.adjustmentFits)
        XCTAssertEqual(fits.playedFilters(channel: 0).count, limit)
        XCTAssertEqual(fits.coefficients(channel: 0, sampleRate: 48_000).count, limit)

        // One more filter in the preset: the adjustment isn't played (the inspector says why), the preset is whole.
        let full = preset(room + 1)
        XCTAssertFalse(full.adjustmentFits)
        XCTAssertEqual(full.adjustmentFilters, [])
        XCTAssertEqual(full.coefficients(channel: 0, sampleRate: 48_000).count, room + 1)
        XCTAssertEqual(full.playedPreamp, full.preamp)
        // A smaller adjustment still fits beside it.
        let shelfOnly = full.adjusted(CalibrationTarget(lowShelf: .init(frequency: 105, gain: 2)))
        XCTAssertEqual(shelfOnly.adjustmentFilters.count, 1)
        // Switched-off filters take no sections.
        XCTAssertTrue(preset(room + 3, switchedOff: 3).adjustmentFits)

        for count in [0, 10, room, room + 1, limit] {
            let profile = preset(count)
            XCTAssertLessThanOrEqual(profile.coefficients(channel: 0, sampleRate: 44_100).count, limit)
        }
    }

    func testAdjustmentIsSavedAndLoaded() throws {
        var output = Node(kind: .defaultOutput)
        output.setCalibration(profile.adjusted(adjustment))
        var graph = Graph()
        graph.nodes.append(output)
        let data = try JSONEncoder().encode(graph)
        let loaded = try JSONDecoder().decode(Graph.self, from: data)
        XCTAssertEqual(loaded.nodes.first?.calibrationEffect?.calibration?.adjustment, adjustment)
        XCTAssertEqual(loaded, graph)

        // A profile without one saves no adjustment at all.
        let plain = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("adjustment"))
        XCTAssertNil(try JSONDecoder().decode(CalibrationProfile.self, from: plain).adjustment)
    }

    func testExportedPresetHasTheAdjustmentAndImportsToTheSameCurve() throws {
        let adjusted = profile.adjusted(adjustment)
        let exported = adjusted.preset()
        XCTAssertEqual(exported.filters.count, preset.filters.count + CalibrationTarget.maximumSections)
        XCTAssertEqual(Array(exported.filters.prefix(preset.filters.count)), preset.filters)
        XCTAssertEqual(exported.preamp, adjusted.playedPreamp)

        let imported = CalibrationProfile(name: "Imported", preset: try ParametricPreset(text: exported.text, name: "x.txt"))
        XCTAssertNil(imported.adjustment, "the adjustment comes back as the preset's own filters")
        // The text keeps gains to 0.1 dB and Q to 0.01.
        assertClose(imported.curve(channel: 0, sampleRate: 48_000), adjusted.curve(channel: 0, sampleRate: 48_000),
                    within: 0.25)

        // Without an adjustment, the export is the preset as it came.
        XCTAssertEqual(profile.preset(), ParametricPreset(preamp: preset.preamp, filters: preset.filters))
    }

    func testResetRestoresThePresetExactly() {
        let original = profile
        let adjusted = original.adjusted(adjustment).adjusted(CalibrationTarget(tilt: 0.4))
        XCTAssertNotEqual(adjusted, original)
        XCTAssertEqual(adjusted.adjusted(nil), original)
        // Adjusting back to nothing is a reset too.
        XCTAssertEqual(adjusted.adjusted(.flat), original)
        XCTAssertEqual(adjusted.adjusted(CalibrationTarget(lowShelf: .init(frequency: 80, gain: 0))), original)
        XCTAssertEqual(adjusted.adjusted(nil).curve(channel: 0, sampleRate: 48_000), original.curve(channel: 0, sampleRate: 48_000))
        XCTAssertEqual(adjusted.adjusted(nil).preset(), original.preset())
    }

    func testAmountScalesPresetAndAdjustment() {
        let adjusted = profile.adjusted(adjustment)
        XCTAssertEqual(adjusted.scaled(by: 1), adjusted)

        let half = adjusted.scaled(by: 0.5)
        XCTAssertEqual(half.adjustment, adjustment.scaled(by: 0.5))
        XCTAssertEqual(half.adjustmentFilters.map(\.gain), adjusted.adjustmentFilters.map { $0.gain * 0.5 })
        XCTAssertEqual(half.channels[0].filters.map(\.gain), preset.filters.map { $0.gain * 0.5 })
        let frequencies = CalibrationGrid.frequencies.filter { (20...16_000).contains($0) }
        let added = CalibrationFilter.response(of: half.adjustmentFilters, sampleRate: 96_000, at: frequencies)
        assertClose(added, frequencies.map { adjustment.level(at: $0) * 0.5 }, within: 0.25)

        let none = adjusted.scaled(by: 0)
        XCTAssertTrue(none.curve(channel: 0, sampleRate: 48_000).allSatisfy { abs($0) < 1e-9 }, "Amount 0 plays nothing")
        XCTAssertEqual(none.playedPreamp, 0)
    }

    func testComparisonLeavesTheAdjustmentOut() {
        let before = profile.adjusted(adjustment).comparison()
        XCTAssertNil(before.adjustment)
        XCTAssertEqual(before.coefficients(channel: 0, sampleRate: 48_000).count, 0)
    }
}
