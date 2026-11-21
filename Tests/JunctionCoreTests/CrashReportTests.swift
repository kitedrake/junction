import XCTest
@testable import JunctionCore

final class CrashReportTests: XCTestCase {
    /// A crash log as macOS writes it for Junction (made up: no real Mac's paths or names).
    static let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Junction-2026-11-20-101502.ips")

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-crashes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ contents: String, modified: Date = Date()) throws {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testReadsTheSampleCrashLog() throws {
        let contents = try String(contentsOf: Self.sample, encoding: .utf8)
        let crash = try XCTUnwrap(CrashReports.parse(contents, file: Self.sample, modified: Date()))
        XCTAssertEqual(crash.process, "Junction")
        XCTAssertEqual(crash.appVersion, "0.9.0")
        XCTAssertEqual(crash.date, CrashReports.ipsDate("2026-11-20 09:15:02.00 +0000"))
        XCTAssertEqual(crash.contents, contents)
    }

    func testFindsOnlyNewCrashesOfJunction() throws {
        let sample = try String(contentsOf: Self.sample, encoding: .utf8)
        let lastLook = CrashReports.ipsDate("2026-11-19 00:00:00.00 +0000")!
        try FileManager.default.copyItem(at: Self.sample, to: folder.appendingPathComponent(Self.sample.lastPathComponent))
        // Junction Helper crashed too.
        try write("JunctionHelper-2026-11-20-120000.ips", sample
            .replacingOccurrences(of: "\"app_name\":\"Junction\"", with: "\"app_name\":\"JunctionHelper\"")
            .replacingOccurrences(of: "\"name\":\"Junction\"", with: "\"name\":\"JunctionHelper\"")
            .replacingOccurrences(of: "local.junction.app", with: "local.junction.helper")
            .replacingOccurrences(of: "10:15:02.00 +0100", with: "12:00:00.00 +0100"))
        // Already offered: before the last look.
        try write("Junction-2026-11-10-080000.ips", sample.replacingOccurrences(of: "2026-11-20 10:15:02.00", with: "2026-11-10 08:00:00.00"),
                  modified: CrashReports.ipsDate("2026-11-10 08:00:00.00 +0100")!)
        // Not a crash: a hang report.
        try write("Junction-2026-11-20-110000.ips", sample.replacingOccurrences(of: "\"bug_type\":\"309\"", with: "\"bug_type\":\"298\""))
        // Another app whose name starts the same way.
        try write("JunctionBox-2026-11-20-110000.ips", sample.replacingOccurrences(of: "\"app_name\":\"Junction\"", with: "\"app_name\":\"JunctionBox\"")
            .replacingOccurrences(of: "\"name\":\"Junction\"", with: "\"name\":\"JunctionBox\"")
            .replacingOccurrences(of: "local.junction.app", with: "com.example.box"))
        try write("Junction-notes.txt", "not a crash log")
        // An older text crash log of the helper, written after the sample.
        try write("JunctionHelper_2026-11-20-130000_Mac.crash", "Process:               JunctionHelper [812]\nVersion:               0.9.0 (0.9.0)\n",
                  modified: CrashReports.ipsDate("2026-11-20 13:00:00.00 +0100")!)

        let found = CrashReports.find(in: folder, since: lastLook)
        XCTAssertEqual(found.map(\.process), ["Junction", "JunctionHelper", "JunctionHelper"])
        XCTAssertEqual(found.last?.file.pathExtension, "crash")
        XCTAssertEqual(found.first?.file.lastPathComponent, Self.sample.lastPathComponent)
        XCTAssertTrue(CrashReports.find(in: folder, since: found.last!.date).isEmpty, "once offered, never again")
        XCTAssertTrue(CrashReports.find(in: folder.appendingPathComponent("missing"), since: lastLook).isEmpty)
    }

    func testReadsOlderCrashTextFiles() throws {
        let text = """
        Process:               JunctionHelper [812]
        Path:                  /Applications/Junction.app/Contents/Library/LoginItems/JunctionHelper.app/Contents/MacOS/JunctionHelper
        Identifier:            local.junction.helper
        Version:               0.9.0 (0.9.0)
        Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
        """
        let file = URL(fileURLWithPath: "/tmp/JunctionHelper_2026-11-20-101502.crash")
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let crash = try XCTUnwrap(CrashReports.parse(text, file: file, modified: modified))
        XCTAssertEqual(crash.process, "JunctionHelper")
        XCTAssertEqual(crash.appVersion, "0.9.0")
        XCTAssertEqual(crash.date, modified)
        XCTAssertNil(CrashReports.parse(text.replacingOccurrences(of: "JunctionHelper [812]", with: "Other [1]"), file: file, modified: modified))
    }

    func testReportHasTheDiagnosticReportAndTheWholeCrashLog() throws {
        let contents = try String(contentsOf: Self.sample, encoding: .utf8)
        let crash = try XCTUnwrap(CrashReports.parse(contents, file: Self.sample, modified: Date()))
        var graph = Graph()
        _ = Templates.streamWithoutChat(&graph, excluding: [])
        let diagnostic = Diagnostics.report(graph: graph, inventory: Inventory(), plan: RoutingPlan(), statuses: nil,
                                            events: ["2026-11-20 10:15:00  error  Stream Mix: failed"], appVersion: "0.9.0",
                                            bundledDriver: "0.2.0")
        let report = CrashReports.compose(diagnostic: diagnostic, crashes: [crash])
        XCTAssertTrue(report.hasPrefix("Junction crash report\nCrashes: Junction 0.9.0 at "), report)
        XCTAssertTrue(report.contains(diagnostic.trimmingCharacters(in: .newlines)), "the diagnostic report, whole")
        XCTAssertTrue(report.contains("==== Crash log: \(Self.sample.lastPathComponent) ===="))
        XCTAssertTrue(report.contains(contents), "the crash log, whole")
        XCTAssertTrue(report.contains("Stream Mix: failed"))
        XCTAssertLessThan(report.range(of: "Junction diagnostic report")!.lowerBound, report.range(of: "==== Crash log")!.lowerBound)
    }

    func testBuildsWithAndWithoutACrashReportAddress() {
        // A plain build: no address, so the offer is Copy Report only.
        XCTAssertNil(CrashReports.destination(info: [:]))
        XCTAssertNil(CrashReports.destination(info: [CrashReports.urlKey: ""]))
        let plain = CrashOffer(report: "r", crashes: [], destination: CrashReports.destination(info: ["CFBundleVersion": "1"]))
        XCTAssertEqual(plain.actions, [.copy])
        // A release build with CRASH_REPORT_URL.
        let url = URL(string: "https://example.com/junction/crash")!
        XCTAssertEqual(CrashReports.destination(info: [CrashReports.urlKey: url.absoluteString]), url)
        let release = CrashOffer(report: "r", crashes: [], destination: CrashReports.destination(info: [CrashReports.urlKey: url.absoluteString]))
        XCTAssertEqual(release.actions, [.send(url), .copy])
        // Only https.
        XCTAssertNil(CrashReports.destination(info: [CrashReports.urlKey: "http://example.com/crash"]))
        XCTAssertNil(CrashReports.destination(info: [CrashReports.urlKey: "not a url"]))
    }

    func testSendsTheReportAsShown() {
        let url = URL(string: "https://example.com/junction/crash")!
        let request = CrashReports.request(sending: "the report\nas shown", to: url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(request.httpBody, Data("the report\nas shown".utf8))
    }

    func testOfferMarksItsCrashesAsOffered() throws {
        let contents = try String(contentsOf: Self.sample, encoding: .utf8)
        let crash = try XCTUnwrap(CrashReports.parse(contents, file: Self.sample, modified: Date()))
        var later = crash
        later.date = crash.date.addingTimeInterval(60)
        XCTAssertEqual(CrashOffer(report: "", crashes: [later, crash], destination: nil).offeredUntil, later.date)
    }

    func testCleanUninstallOrder() {
        XCTAssertEqual(CleanUninstall.steps(driverInstalled: true, removeSettings: false),
                       [.removeDriver, .stopRouting, .unregisterRoutingHelper, .unregisterDriverInstaller, .unregisterLoginItem, .quit])
        XCTAssertEqual(CleanUninstall.steps(driverInstalled: false, removeSettings: true),
                       [.stopRouting, .unregisterRoutingHelper, .unregisterDriverInstaller, .unregisterLoginItem,
                        .removeSavedSetup, .removePreferences, .quit])
        XCTAssertEqual(CleanUninstall.preferenceDomains, ["local.junction.app", "local.junction.helper"])
    }
}
