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
