import Foundation
import XCTest
@testable import JunctionCore

/// Stands in for the app: measures in a simulated room, saves into a graph through the undo history, and records
/// what the output was given to play.
@MainActor
final class CalibrationTestHost: SpeakerCalibrationHost {
    var graph: Graph
    lazy var history = EditHistory(read: { [unowned self] in graph }, write: { [unowned self] in graph = $0 })
    let device: SimulatedMeasurementDevice
    var allowsMicrophone = true
    private(set) var engines = 0
    /// Everything `audition` was given, in order.
    private(set) var auditions: [CalibrationProfile?] = []

    init(graph: Graph, device: SimulatedMeasurementDevice) {
        self.graph = graph
        self.device = device
    }

    func makeMeasurement(_ configuration: MeasurementEngine.Configuration) -> MeasurementEngine {
        engines += 1
        var configuration = configuration
        (configuration.sweepDuration, configuration.leadSilence, configuration.tail) = (1.5, 0.2, 0.6)
        return MeasurementEngine(configuration: configuration, plan: RoutingPlan(), device: device, routing: nil)
    }

    func requestMicrophone() async -> Bool { allowsMicrophone }

    func audition(_ profile: CalibrationProfile?, node: UUID, effect: UUID) { auditions.append(profile) }

    func save(_ profile: CalibrationProfile, node: UUID, effect: UUID) {
        history.perform("Calibrate Speakers") { graph in
            guard let index = graph.nodes.firstIndex(where: { $0.id == node }) else { return }
            graph.nodes[index].setCalibration(profile, effect: effect)
        }
    }

    var savedProfile: CalibrationProfile? { graph.nodes.first?.calibrationEffect?.calibration }
}

@MainActor
final class SpeakerCalibrationTests: XCTestCase {
    private let rate = 48_000.0

    /// Two speakers 48 samples and 3 dB apart, each with a room mode that changes a little between positions.
    private func room() -> SimulatedMeasurementDevice {
        func left(_ gain: Double, moved: Int) -> SimulatedMeasurementDevice.Speaker {
            .init(filters: [CalibrationFilter(.peaking, frequency: 70, gain: gain, q: 4)], level: -10, delay: 300 + moved)
        }
        func right(_ gain: Double, moved: Int) -> SimulatedMeasurementDevice.Speaker {
            .init(filters: [CalibrationFilter(.peaking, frequency: 90, gain: gain, q: 3),
                            CalibrationFilter(.highShelf, frequency: 6000, gain: -3)], level: -13, delay: 348 + moved)
        }
        return SimulatedMeasurementDevice(rooms: [[left(7, moved: 0), right(5, moved: 0)],
                                                  [left(5, moved: 20), right(6, moved: 9)],
                                                  [left(8, moved: 35), right(4, moved: 17)]])
    }

    /// An output node whose Calibration effect was just added (as Calibrate Speakers… does), the host and the sheet.
    private func setUpSheet() -> (SpeakerCalibration, CalibrationTestHost) {
        var node = Node(kind: .device(DeviceRef(uid: MeasuringSetup.speakers.uid, name: "Desk Speakers", inputChannels: 0,
                                                outputChannels: 2)), canvas: Demo.streamMix.id)
        let effect = node.setCalibration(nil)
        let host = CalibrationTestHost(graph: Graph(virtualDevices: [Demo.streamMix], nodes: [node]), device: room())
        let sheet = SpeakerCalibration(node: node.id, effect: effect, outputUID: MeasuringSetup.speakers.uid,
                                       outputName: "Desk Speakers", channelNames: ["Left", "Right"],
                                       microphones: [.init(uid: "Webcam", name: "Webcam", channels: 1),
                                                     .init(uid: MeasuringSetup.mic.uid, name: "Measuring Mic", channels: 2)],
                                       defaultMicUID: MeasuringSetup.mic.uid, host: host)
        return (sheet, host)
    }

    /// Measures three positions and shows the results.
    private func measuredSheet() async throws -> (SpeakerCalibration, CalibrationTestHost) {
        let (sheet, host) = setUpSheet()
        sheet.micChannel = 1
        sheet.positionCount = 3
        await sheet.startMeasuring()
        XCTAssertNil(sheet.problem)
        for position in 0..<3 {
            host.device.position = position
            await sheet.measureNextPosition()
            XCTAssertNil(sheet.problem)
        }
        sheet.showResults()
        XCTAssertEqual(sheet.page, .results)
        return (sheet, host)
    }

    // MARK: Pages

    func testSetupChoosesTheMicrophoneChannelsAndPositions() throws {
        let (sheet, _) = setUpSheet()
        XCTAssertEqual(sheet.page, .setup)
        XCTAssertEqual(sheet.micUID, MeasuringSetup.mic.uid, "the default input when it can measure")
        XCTAssertEqual(sheet.channelCount, 2)
        XCTAssertEqual(sheet.positionCount, 7)
        XCTAssertEqual(sheet.channelName(0), "Left")
        XCTAssertEqual(sheet.channelName(2), "3")
        sheet.positionCount = 0
        XCTAssertEqual(sheet.positionCount, 1)
        sheet.positionCount = 12
        XCTAssertEqual(sheet.positionCount, 9)
        sheet.channelCount = 5
        XCTAssertEqual(sheet.channelCount, 2, "no more than the output has")
        sheet.micChannel = 1
        sheet.micUID = "Webcam"
        XCTAssertEqual(sheet.micChannel, 0, "the webcam has one channel")
        XCTAssertNil(sheet.micCalibration)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "\"Sens Factor =-1.4dB\"\n20 -2.1\n1000 0\n20000 1.5\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        sheet.loadMicCalibration(file)
        XCTAssertNotNil(sheet.micCalibration)
        XCTAssertNil(sheet.problem)
        XCTAssertEqual(sheet.micCalibration?.name, file.deletingPathExtension().lastPathComponent)
    }

    func testWithoutMicrophonePermissionTheSheetStaysOnSetup() async {
        let (sheet, host) = setUpSheet()
        host.allowsMicrophone = false
        await sheet.startMeasuring()
        XCTAssertEqual(sheet.page, .setup)
        XCTAssertEqual(sheet.problem, MeasurementError.microphoneDenied.localizedDescription)
        XCTAssertEqual(host.engines, 0)
    }

    func testPagesGoFromSetupThroughMeasuringToResults() async throws {
        let (sheet, host) = setUpSheet()
        sheet.micChannel = 1
        sheet.positionCount = 3
        XCTAssertTrue(sheet.canStart)
        await sheet.startMeasuring()
        XCTAssertEqual(sheet.page, .measuring)
        XCTAssertTrue(sheet.isLevelChecked, "the level is checked first")
        let reading = try XCTUnwrap(sheet.reading)
        XCTAssertGreaterThan(reading.snr, MeasurementEngine.minimumSNR)
        XCTAssertFalse(sheet.canShowResults)
        XCTAssertTrue(sheet.canMeasure)

        for position in 0..<3 {
            host.device.position = position
            await sheet.measureNextPosition()
            XCTAssertEqual(sheet.positions.count, position + 1)
            XCTAssertEqual(sheet.progress, Double(position + 1) / 3, accuracy: 1e-9)
        }
        XCTAssertTrue(sheet.isDoneMeasuring)
        XCTAssertFalse(sheet.canMeasure)
        XCTAssertTrue(sheet.canShowResults)
        XCTAssertEqual(sheet.positions.map(\.count), [2, 2, 2], "every channel at every position")

        // Redo last measures the last position again; dropping one leaves it out and frees its place.
        let last = sheet.positions[2]
        await sheet.redoLastPosition()
        XCTAssertEqual(sheet.positions.count, 3)
        XCTAssertNotEqual(sheet.positions[2], last, "measured again (the room's hiss differs)")
        let third = sheet.positions[2]
        sheet.dropPosition(1)
        XCTAssertEqual(sheet.positions.count, 2)
        XCTAssertEqual(sheet.positions[1], third)
        XCTAssertTrue(sheet.canMeasure)
        host.device.position = 1
        await sheet.measureNextPosition()
        XCTAssertEqual(sheet.positions.count, 3)
        XCTAssertTrue(host.device.isRunning)
        XCTAssertEqual(host.engines, 1, "one run of the devices for the whole measurement")

        sheet.showResults()
        XCTAssertEqual(sheet.page, .results)
        XCTAssertFalse(host.device.isRunning, "the devices are freed for listening")
        let result = try XCTUnwrap(sheet.result)
        XCTAssertEqual(result.kind, .speakers)
        XCTAssertEqual(result.deviceUID, MeasuringSetup.speakers.uid)
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.measurements.count, 8, "three positions and the average, per channel")
        XCTAssertEqual(result.channels[0].delay * rate, 48, accuracy: 1)
        XCTAssertEqual(result.channels[0].level, -3, accuracy: 0.3)
        XCTAssertEqual(host.auditions.last, result, "the results play while they show")
        let curves = try XCTUnwrap(sheet.curves(channel: 1))
        XCTAssertEqual(curves.positions.count, 3)
        for list in [curves.average, curves.target, curves.correction, curves.predicted] {
            XCTAssertEqual(list.count, CalibrationGrid.count)
        }
        XCTAssertNil(host.savedProfile, "nothing is saved before Save")
    }

    func testBackToSetupFreesTheDevices() async {
        let (sheet, host) = setUpSheet()
        sheet.micChannel = 1
        await sheet.startMeasuring()
        await sheet.measureNextPosition()
        sheet.back()
        XCTAssertEqual(sheet.page, .setup)
        XCTAssertTrue(sheet.positions.isEmpty)
        XCTAssertFalse(host.device.isRunning)
    }

    // MARK: Results

    func testEveryChangeRefitsFromTheSavedMeasurements() async throws {
        let (sheet, host) = try await measuredSheet()
        let first = try XCTUnwrap(sheet.result)
        let opens = host.device.opens

        sheet.settings.tilt = -0.5
        let tilted = try XCTUnwrap(sheet.result)
        XCTAssertEqual(tilted.target.tilt, -0.5)
        XCTAssertNotEqual(tilted.channels.map(\.filters), first.channels.map(\.filters))
        XCTAssertEqual(tilted.measurements, first.measurements, "the same measurements")

        sheet.settings.filterCount = 2
        XCTAssertTrue(try XCTUnwrap(sheet.result).channels.allSatisfy { $0.filters.count <= 2 })

        sheet.settings.maxBoost = 0
        for channel in 0..<2 {
            let filters = try XCTUnwrap(sheet.result).channel(channel).filters
            XCTAssertLessThanOrEqual(CalibrationFilter.peak(of: filters, sampleRate: rate), 0.05, "no boost at all")
        }

        sheet.settings.bassShelf = 4
        XCTAssertEqual(try XCTUnwrap(sheet.result).target.lowShelf?.gain, 4)
        sheet.settings.lowFrequency = 200
        sheet.settings.highFrequency = 5000
        XCTAssertEqual(try XCTUnwrap(sheet.result).limits.lowFrequency, 200)
        XCTAssertTrue(try XCTUnwrap(sheet.result).channels.flatMap(\.filters).allSatisfy { $0.frequency >= 200 / 1.5 - 1 })

        sheet.settings.alignsSpeakers = false
        XCTAssertEqual(try XCTUnwrap(sheet.result).channels.map(\.delay), [0, 0])
        XCTAssertEqual(try XCTUnwrap(sheet.result).channels.map(\.level), [0, 0])
        sheet.settings.alignsSpeakers = true
        XCTAssertEqual(try XCTUnwrap(sheet.result).channels[0].delay * rate, 48, accuracy: 1, "arrivals are kept")

        // Back to the first settings: the first fit again.
        sheet.settings = SpeakerCalibrationSettings()
        XCTAssertEqual(sheet.result, first)
        XCTAssertEqual(host.device.opens, opens, "nothing measured again")
        XCTAssertEqual(host.auditions.last, first, "each refit is heard")
    }

    func testSaveIsOneUndoStep() async throws {
        let (sheet, host) = try await measuredSheet()
        sheet.settings.tilt = -0.3
        let result = try XCTUnwrap(sheet.result)
        sheet.save()
        XCTAssertEqual(host.savedProfile, result)
        XCTAssertEqual(host.graph.nodes[0].effects.count, 1, "into the Calibration effect it was opened for")
        XCTAssertEqual(host.history.undoName, "Calibrate Speakers")
        XCTAssertEqual(host.auditions.last, .some(nil), "the saved profile plays from the setup again")

        host.history.undo()
        XCTAssertNil(host.savedProfile)
        XCTAssertEqual(host.graph.nodes[0].effects.count, 1)
        host.history.redo()
        XCTAssertEqual(host.savedProfile, result)
    }

    func testAdjustReopensResultsWithoutMeasuring() async throws {
        let (sheet, host) = try await measuredSheet()
        sheet.settings.tilt = -0.4
        sheet.settings.filterCount = 10
        sheet.save()
        let saved = try XCTUnwrap(host.savedProfile)
        let engines = host.engines, opens = host.device.opens
        let node = host.graph.nodes[0]

        let adjusting = SpeakerCalibration(adjusting: saved, node: node.id, effect: try XCTUnwrap(node.calibrationEffect).id,
                                           channelNames: ["Left", "Right"], host: host)
        XCTAssertTrue(adjusting.isAdjusting)
        XCTAssertEqual(adjusting.page, .results)
        XCTAssertEqual(adjusting.settings.tilt, -0.4)
        XCTAssertEqual(adjusting.settings.filterCount, 10)
        XCTAssertTrue(adjusting.settings.alignsSpeakers)
        XCTAssertEqual(adjusting.result, saved, "refitting with the same settings gives the saved profile")
        XCTAssertNotNil(adjusting.curves(channel: 0))

        adjusting.settings.tilt = 0
        adjusting.save()
        XCTAssertEqual(host.savedProfile?.target.tilt, 0)
        XCTAssertEqual(host.savedProfile?.measurements, saved.measurements)
        XCTAssertEqual(host.savedProfile?.id, saved.id)
        XCTAssertEqual(host.engines, engines)
        XCTAssertEqual(host.device.opens, opens, "Adjust… never measures")
        host.history.undo()
        XCTAssertEqual(host.savedProfile, saved)
    }

    func testProfilesSavedWithoutArrivalsLineUpFromTheirDelays() async throws {
        let (sheet, _) = try await measuredSheet()
        var older = try XCTUnwrap(sheet.result)
        older.alignment = nil
        let data = try JSONEncoder().encode(older)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("alignment"), "as profiles were saved before")
        XCTAssertEqual(try JSONDecoder().decode(CalibrationProfile.self, from: data), older)
        let refitted = older.refitted(target: older.target, limits: older.limits, alignsSpeakers: true)
        XCTAssertEqual(refitted.channels.map(\.delay), older.channels.map(\.delay))
        XCTAssertEqual(SpeakerCalibrationSettings(older).alignsSpeakers, true)
    }

    func testComparisonPlaysNoCorrectionAtMatchedLoudness() async throws {
        let (sheet, host) = try await measuredSheet()
        let result = try XCTUnwrap(sheet.result)
        // The correction's average level change, worked out here from its curves.
        let frequencies = CalibrationGrid.frequencies.filter { (100...10_000).contains($0) }
        let expected = (0..<2).map { channel in
            result.curve(channel: channel, sampleRate: rate, at: frequencies).reduce(0, +) / Double(frequencies.count)
        }.reduce(0, +) / 2
        XCTAssertEqual(sheet.comparisonLevel, expected, accuracy: 1e-9)
        XCTAssertLessThan(sheet.comparisonLevel, 0, "the correction makes room for its boosts")

        sheet.isComparing = true
        let before = try XCTUnwrap(host.auditions.last ?? nil)
        XCTAssertTrue(before.channels.allSatisfy { $0.filters.isEmpty && $0.delay == 0 && $0.level == 0 }, "correction off")
        XCTAssertEqual(before.preamp, expected, accuracy: 1e-9, "made up to the correction's level")
        XCTAssertEqual(before.averageLevelChange(), result.averageLevelChange(), accuracy: 1e-9, "matched loudness")

        sheet.isComparing = false
        XCTAssertEqual(host.auditions.last, result, "after: the correction, without any make-up")
        sheet.isComparing = true
        sheet.save()
        XCTAssertEqual(host.savedProfile, result, "the make-up is only for comparing")
        XCTAssertFalse(sheet.isComparing)
        XCTAssertEqual(host.auditions.last, .some(nil))
    }

    func testCancellingWhileMeasuringFreesTheDevices() async {
        let (sheet, host) = setUpSheet()
        sheet.micChannel = 1
        await sheet.startMeasuring()
        XCTAssertTrue(host.device.isRunning)
        sheet.cancel()
        XCTAssertFalse(host.device.isRunning)
        XCTAssertNil(host.savedProfile)
        XCTAssertEqual(host.auditions.last, .some(nil))
    }
}
