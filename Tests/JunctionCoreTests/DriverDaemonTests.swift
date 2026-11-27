import XCTest
@testable import JunctionCore

/// Stands in for the daemon's root actions: records what it was asked to do, touches nothing.
final class FakeActions: PrivilegedActions, @unchecked Sendable {
    var versions: [String: String] = [:]
    var signatures: [String: CodeSignature] = [:]
    var own = CodeSignature(isValid: true, identifier: DriverDaemon.label, teamID: "TEAM123456")
    var stageError: Error?
    var installedExists = true
    private(set) var log: [String] = []
    let stagingURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/.JunctionDriver.installing")

    func driverVersion(at url: URL) -> String? { versions[url.path] }

    func stage(_ source: URL) throws -> URL {
        log.append("stage \(source.path)")
        if let stageError { throw stageError }
        versions[stagingURL.path] = versions[source.path]
        return stagingURL
    }

    func signature(of url: URL) -> CodeSignature {
        log.append("check \(url.path)")
        return signatures[url.path] ?? .unsigned
    }

    func ownSignature() -> CodeSignature { own }
    func commit(_ staged: URL) throws { log.append("commit \(staged.path)") }
    func discard(_ staged: URL) { log.append("discard \(staged.path)") }

    func removeInstalled() throws -> Bool {
        log.append("remove")
        return installedExists
    }

    func restartCoreAudio() { log.append("restart") }
}

final class DriverDaemonTests: XCTestCase {
    let app = URL(fileURLWithPath: "/Applications/Junction.app", isDirectory: true)
    var bundled: URL { app.appendingPathComponent("Contents/Resources/JunctionDriver.driver") }
    let goodDriver = CodeSignature(isValid: true, identifier: DriverClient.bundleID, teamID: "TEAM123456")

    private func service(_ actions: FakeActions) -> DriverDaemonService {
        DriverDaemonService(app: app, actions: actions, clientRequirement: nil, checksClients: false)
    }

    private func actions(bundled version: String? = "0.3.0", installed: String? = "0.2.0") -> FakeActions {
        let actions = FakeActions()
        actions.versions[bundled.path] = version
        actions.versions[DriverClient.installPath] = installed
        actions.signatures[actions.stagingURL.path] = goodDriver
        return actions
    }

    func testFindsItsAppAndOnlyThatAppsDriver() {
        let executable = app.appendingPathComponent(DriverDaemon.executablePath)
        XCTAssertEqual(DriverDaemon.appBundle(containingExecutable: executable)?.path, app.path)
        XCTAssertEqual(DriverDaemon.bundledDriver(inApp: app).path, bundled.path)
        // Anywhere else, it doesn't know which app it belongs to and doesn't start.
        XCTAssertNil(DriverDaemon.appBundle(containingExecutable: URL(fileURLWithPath: "/tmp/JunctionDriverDaemon")))
        XCTAssertNil(DriverDaemon.appBundle(containingExecutable: URL(fileURLWithPath: "/tmp/Junction/" + DriverDaemon.executablePath)))
    }

    func testInstallsTheBundledCopyAfterCheckingTheStagedCopy() {
        let actions = actions()
        XCTAssertEqual(service(actions).perform(.installDriver(allowOlder: false)), .installed(version: "0.3.0"))
        // It copies first, checks the copy (not the original the user can still change), then installs and restarts.
        XCTAssertEqual(actions.log, ["stage \(bundled.path)", "check \(actions.stagingURL.path)",
                                     "commit \(actions.stagingURL.path)", "restart"])
    }

    func testVersionDecisions() {
        XCTAssertEqual(DriverInstallPolicy.decide(bundled: "0.3.0", installed: nil, allowOlder: false), .install(version: "0.3.0"))
        XCTAssertEqual(DriverInstallPolicy.decide(bundled: "0.3.0", installed: "0.2.0", allowOlder: false), .install(version: "0.3.0"))
        XCTAssertEqual(DriverInstallPolicy.decide(bundled: "0.3.0", installed: "0.3.0", allowOlder: false), .install(version: "0.3.0"),
                       "Reinstall Driver… installs the same version again")
        XCTAssertEqual(DriverInstallPolicy.decide(bundled: "0.3.0", installed: "0.2.10", allowOlder: false), .install(version: "0.3.0"))
        if case .refuse = DriverInstallPolicy.decide(bundled: "0.3.0", installed: "0.10.0", allowOlder: false) {} else {
            XCTFail("a newer installed driver is kept unless the user asks")
        }
        XCTAssertEqual(DriverInstallPolicy.decide(bundled: "0.3.0", installed: "0.10.0", allowOlder: true), .install(version: "0.3.0"))
        XCTAssertEqual(DriverInstallPolicy.decide(bundled: "0.3.0", installed: "?", allowOlder: false), .install(version: "0.3.0"),
                       "an unreadable installed version is replaced")
        if case .refuse = DriverInstallPolicy.decide(bundled: nil, installed: nil, allowOlder: true) {} else {
            XCTFail("nothing bundled, nothing to install")
        }
    }

    func testNewerInstalledDriverIsKeptWithoutTouchingFiles() {
        let actions = actions(bundled: "0.2.0", installed: "0.3.0")
        guard case .refused = service(actions).perform(.installDriver(allowOlder: false)) else { return XCTFail() }
        XCTAssertEqual(actions.log, [])
        XCTAssertEqual(service(actions).perform(.installDriver(allowOlder: true)), .installed(version: "0.2.0"))
    }

    func testSignatureVerdicts() {
        let own = CodeSignature(isValid: true, identifier: DriverDaemon.label, teamID: "TEAM123456")
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: goodDriver, own: own), .matches)
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: CodeSignature(isValid: false, identifier: DriverClient.bundleID, teamID: "TEAM123456"),
                                                   own: own), .invalid)
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: .unsigned, own: own), .invalid)
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: CodeSignature(isValid: true, identifier: DriverClient.bundleID, teamID: "OTHERTEAM1"),
                                                   own: own), .otherTeam("OTHERTEAM1"))
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: CodeSignature(isValid: true, identifier: DriverClient.bundleID, teamID: nil),
                                                   own: own), .otherTeam(nil))
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: CodeSignature(isValid: true, identifier: "com.example.other", teamID: "TEAM123456"),
                                                   own: own), .wrongIdentifier("com.example.other"))
        // An ad-hoc signed daemon (no team) vouches for nothing, even a matching ad-hoc driver.
        let adHoc = CodeSignature(isValid: true, identifier: DriverDaemon.label, teamID: nil)
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: CodeSignature(isValid: true, identifier: DriverClient.bundleID, teamID: nil),
                                                   own: adHoc), .adHoc)
        XCTAssertEqual(DriverInstallPolicy.verdict(driver: goodDriver, own: CodeSignature(isValid: false, identifier: nil, teamID: "TEAM123456")), .adHoc)
        XCTAssertNil(SignatureVerdict.matches.problem)
        XCTAssertNotNil(SignatureVerdict.otherTeam("X").problem)
    }

    func testRefusesAndDiscardsADriverSignedByAnotherTeam() {
        for signature in [CodeSignature(isValid: true, identifier: DriverClient.bundleID, teamID: "OTHERTEAM1"), .unsigned,
                          CodeSignature(isValid: false, identifier: DriverClient.bundleID, teamID: "TEAM123456")] {
            let actions = actions()
            actions.signatures[actions.stagingURL.path] = signature
            guard case .refused = service(actions).perform(.installDriver(allowOlder: false)) else { return XCTFail("\(signature)") }
            XCTAssertEqual(actions.log.last, "discard \(actions.stagingURL.path)")
            XCTAssertFalse(actions.log.contains { $0.hasPrefix("commit") || $0 == "restart" }, "\(actions.log)")
        }
        let adHoc = actions()
        adHoc.own = CodeSignature(isValid: true, identifier: DriverDaemon.label, teamID: nil)
        guard case .refused = service(adHoc).perform(.installDriver(allowOlder: false)) else { return XCTFail() }
        XCTAssertFalse(adHoc.log.contains("restart"))
    }

    func testReportsACopyThatFails() {
        let actions = actions()
        actions.stageError = CocoaError(.fileWriteNoPermission)
        guard case .failed = service(actions).perform(.installDriver(allowOlder: false)) else { return XCTFail() }
        XCTAssertFalse(actions.log.contains("restart"))
    }

    func testRemovesAndRestartsOnlyWhenThereIsADriver() {
        let actions = actions()
        XCTAssertEqual(service(actions).perform(.removeDriver), .removed)
        XCTAssertEqual(actions.log, ["remove", "restart"])
        let none = self.actions()
        none.installedExists = false
        XCTAssertEqual(service(none).perform(.removeDriver), .notInstalled)
        XCTAssertEqual(none.log, ["remove"])
    }

    func testHelloChecksTheProtocolVersion() {
        let service = service(actions())
        XCTAssertEqual(service.perform(.hello(protocolVersion: DriverDaemon.protocolVersion)),
                       .welcome(protocolVersion: DriverDaemon.protocolVersion))
        guard case .refused = service.perform(.hello(protocolVersion: 99)) else { return XCTFail() }
    }

    func testCallersMustBeJunctionFromTheSameTeam() {
        XCTAssertNil(DriverDaemon.clientRequirement(teamID: nil), "an ad-hoc signed daemon accepts nobody")
        XCTAssertNil(DriverDaemon.clientRequirement(teamID: ""))
        let requirement = DriverDaemon.clientRequirement(teamID: "TEAM123456") ?? ""
        XCTAssertTrue(requirement.contains("identifier \"com.kitedrake.junction\""), requirement)
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"TEAM123456\""), requirement)
        XCTAssertTrue(requirement.contains("anchor apple generic"), requirement)
        XCTAssertEqual(DriverDaemon.daemonRequirement(teamID: nil), "identifier \"com.kitedrake.junction.driverd\"")
    }

    // MARK: Over XPC

    private func roundTrip(_ service: DriverDaemonService, _ request: DaemonRequest) -> DriverDaemonClient.Outcome? {
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let answered = expectation(description: "answer")
        nonisolated(unsafe) var outcome: DriverDaemonClient.Outcome?
        DriverDaemonClient(endpoint: listener.endpoint).send(request, timeout: 5, queue: DispatchQueue(label: "test")) {
            outcome = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        return outcome
    }

    func testInstallsOverXPC() {
        XCTAssertEqual(roundTrip(service(actions()), .installDriver(allowOlder: false)), .reply(.installed(version: "0.3.0")))
    }

    func testAnAdHocDaemonAcceptsNoConnections() {
        let refusing = DriverDaemonService(app: app, actions: actions(), clientRequirement: nil, checksClients: true)
        guard case .unreachable? = roundTrip(refusing, .removeDriver) else { return XCTFail() }
    }

    func testACallerSignedOtherwiseIsTurnedAway() {
        // This test process isn't Junction signed by that team.
        let requirement = DriverDaemon.clientRequirement(teamID: "TEAM123456")
        let actions = actions()
        let strict = DriverDaemonService(app: app, actions: actions, clientRequirement: requirement, checksClients: true)
        guard case .unreachable? = roundTrip(strict, .removeDriver) else { return XCTFail() }
        XCTAssertEqual(actions.log, [], "nothing was done for it")
    }

    // MARK: The app's choices

    func testInstallRoute() {
        XCTAssertEqual(DriverInstallRoute.choose(buildUsesDaemon: true, daemonBundled: true, approval: .approved), .daemon)
        for approval: DaemonApproval in [.requiresApproval, .notRegistered, .notFound, .failed("x")] {
            guard case .administratorPrompt = DriverInstallRoute.choose(buildUsesDaemon: true, daemonBundled: true, approval: approval)
            else { return XCTFail("\(approval)") }
        }
        guard case .administratorPrompt = DriverInstallRoute.choose(buildUsesDaemon: false, daemonBundled: true, approval: .approved),
              case .administratorPrompt = DriverInstallRoute.choose(buildUsesDaemon: true, daemonBundled: false, approval: .approved)
        else { return XCTFail() }
    }

    func testWhatTheAppDoesWithTheAnswer() {
        guard case .done = DriverInstallRoute.next(after: .reply(.installed(version: "0.3.0"))),
              case .done = DriverInstallRoute.next(after: .reply(.removed)),
              case .done = DriverInstallRoute.next(after: .reply(.notInstalled)) else { return XCTFail() }
        // A refusal (a signature that doesn't check out) isn't gone around with the password prompt.
        XCTAssertEqual(DriverInstallRoute.next(after: .reply(.refused("signed by someone else"))), .problem("signed by someone else"))
        XCTAssertEqual(DriverInstallRoute.next(after: .reply(.failed("disk full"))), .problem("disk full"))
        // A daemon that can't be reached is: the password prompt takes over.
        XCTAssertEqual(DriverInstallRoute.next(after: .unreachable("gone")), .fallBack("gone"))
    }

    // MARK: The real file steps, in a temporary folder

    func testSystemActionsStageCommitAndRemove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("junction-daemon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Junction.app/Contents/Resources/JunctionDriver.driver")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.3.0"], format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        let hal = root.appendingPathComponent("HAL")
        let actions = SystemPrivilegedActions(halFolder: hal, setsRootOwnership: false)
        let staged = try actions.stage(source)
        XCTAssertEqual(staged.deletingLastPathComponent().path, hal.path, "staged next to the installed driver")
        XCTAssertEqual(actions.driverVersion(at: staged), "0.3.0")
        XCTAssertFalse(actions.signature(of: staged).isValid, "an unsigned copy doesn't check out")
        try actions.commit(staged)
        XCTAssertEqual(actions.driverVersion(at: hal.appendingPathComponent("JunctionDriver.driver")), "0.3.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(try actions.removeInstalled())
        XCTAssertFalse(try actions.removeInstalled())
    }
}
