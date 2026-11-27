import Foundation
import JunctionCore

// Junction Driver Installer: a launch daemon inside Junction.app (Contents/Library/HelperTools), registered by the app
// with SMAppService.daemon once a build is made for it (build.sh's DRIVER_DAEMON). It runs as root, started by launchd
// when Junction connects to `com.kitedrake.junction.driverd`, installs or removes the driver inside its own Junction.app after
// checking its signature (see DriverDaemonService), restarts Core Audio, and quits after a minute without requests.
// It also keeps the driver's per-app capture region and hands it to Junction (CaptureBroker, Mach service
// `com.kitedrake.junction.driverd.capture`); while it holds one it stays, since the driver sends it only when it loads or
// when the daemon goes away.

let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
guard let app = DriverDaemon.appBundle(containingExecutable: executable) else {
    FileHandle.standardError.write(Data("\(DriverDaemon.displayName) must run from Junction.app/\(DriverDaemon.executablePath).\n".utf8))
    exit(1)
}
let actions = SystemPrivilegedActions()
let service = DriverDaemonService(app: app, actions: actions,
                                  clientRequirement: DriverDaemon.clientRequirement(teamID: actions.ownSignature().teamID))
if service.clientRequirement == nil {
    FileHandle.standardError.write(Data("\(DriverDaemon.displayName) has no signing team, so it accepts no connections.\n".utf8))
}
let listener = NSXPCListener(machServiceName: DriverDaemon.machServiceName)
listener.delegate = service
listener.resume()
let broker = CaptureBroker()
let captureListener = broker.listen(teamID: actions.ownSignature().teamID)

/// launchd starts the daemon again on the next connection.
let idleLimit: TimeInterval = 60
let idleTimer = DispatchSource.makeTimerSource(queue: service.queue)
idleTimer.schedule(deadline: .now() + idleLimit, repeating: 10)
idleTimer.setEventHandler {
    if Date().timeIntervalSince(service.lastActivity) > idleLimit, !broker.holdsRegion { exit(0) }
}
idleTimer.resume()
dispatchMain()
