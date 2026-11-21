import XCTest
@testable import JunctionCore

final class DriverUpdateTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertEqual(DriverUpdate.compare("0.1.0", "0.1.1"), .orderedAscending)
        XCTAssertEqual(DriverUpdate.compare("0.1.10", "0.1.9"), .orderedDescending)
        XCTAssertEqual(DriverUpdate.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(DriverUpdate.compare("0.2", "0.1.9"), .orderedDescending)
        XCTAssertNil(DriverUpdate.compare("?", "0.1.1"))
        XCTAssertNil(DriverUpdate.compare("0.1.1-beta", "0.1.1"))
        XCTAssertNil(DriverUpdate.compare("", "0.1.1"))
    }

    func testOffersOnlyNewerDrivers() {
        XCTAssertEqual(DriverUpdate(installed: .notInstalled, bundled: "0.1.1"), .notInstalled)
        XCTAssertEqual(DriverUpdate(installed: .notInstalled, bundled: nil), .notInstalled)
        XCTAssertEqual(DriverUpdate(installed: .installed(version: "0.1.1"), bundled: "0.1.1"), .upToDate)
        XCTAssertEqual(DriverUpdate(installed: .installed(version: "0.1.1"), bundled: nil), .upToDate)
        XCTAssertEqual(DriverUpdate(installed: .installed(version: "0.1.0"), bundled: "0.1.1"),
                       .available(installed: "0.1.0", bundled: "0.1.1"))
        XCTAssertEqual(DriverUpdate(installed: .installed(version: "0.2.0"), bundled: "0.1.1"),
                       .appIsOlder(installed: "0.2.0", bundled: "0.1.1"))
        // A driver that doesn't report a readable version is replaced.
        XCTAssertEqual(DriverUpdate(installed: .installed(version: "?"), bundled: "0.1.1"),
                       .available(installed: "?", bundled: "0.1.1"))
    }
}

final class EventLogTests: XCTestCase {
    func testKeepsTheLatestEventsAndSavesThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.log")
        let log = EventLog(file: file)
        for index in 0..<(EventLog.limit + 5) { log.add(index == 0 ? .error : .info, "event \(index)") }
        XCTAssertEqual(log.recent.count, EventLog.limit)
        XCTAssertEqual(log.recent.last?.message, "event \(EventLog.limit + 4)")
        let saved = EventLog.savedLines(at: file, count: 3)
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.last?.hasSuffix("info   event \(EventLog.limit + 4)") ?? false, saved.last ?? "")
        XCTAssertTrue(EventLog.savedLines(at: file).count <= EventLog.limit * 2)
        log.clear()
        XCTAssertTrue(log.recent.isEmpty)
        XCTAssertFalse(EventLog.savedLines(at: file).isEmpty, "clearing the window keeps the file for --diagnose")
    }

    func testReportNamesTheSetupAndEvents() {
        var graph = Graph()
        _ = Templates.streamWithoutChat(&graph, excluding: [])
        let report = Diagnostics.report(graph: graph, inventory: Inventory(), plan: RoutingPlan(), statuses: nil,
                                        events: ["2026-11-21 10:00:00  error  Stream Mix: failed"], appVersion: "1.0",
                                        bundledDriver: "0.1.1")
        XCTAssertTrue(report.contains("Junction: 1.0; bundled driver: 0.1.1"))
        XCTAssertTrue(report.contains("Stream Mix: 2 ch, 48000 Hz"))
        XCTAssertTrue(report.contains("Stream Mix: failed"))
        XCTAssertTrue(report.contains("\"schema\" : \(Graph.currentSchema)"))
    }
}
