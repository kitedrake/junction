import CoreAudio
import Foundation
import JunctionCore

extension CommandLineTool {
    /// Checks that Core Audio follows the driver's device list: a temporary device appears, runs at its configured
    /// rate, is renamed and reshaped (through coreaudiod's configuration-change path) while keeping its object ID,
    /// reports a rate set from outside back to Junction, disappears and comes back under the same UID. Opens no audio,
    /// so it needs no permission. Puts the device list back afterwards.
    static func deviceTest() -> Int32 {
        guard DriverClient.status().isInstalled, let existing = DriverClient.publishedDevices() else {
            print("The Junction driver isn't installed (or coreaudiod hasn't loaded it).")
            return 1
        }
        var test = VirtualDevice(id: UUID(uuidString: "4A554E43-5445-5354-0000-000000000002")!, name: "Junction Device Test")
        let others = existing.filter { $0.uid != test.uid }
        defer { try? DriverClient.publish(others) }
        final class Tally { var failures = 0 }
        let tally = Tally()
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "ok   " : "FAIL ") + message)
            if !condition { tally.failures += 1 }
        }
        func live() -> DeviceInfo? { HAL.readInventory().device(test.uid) }
        func reportedRate() -> Double? { DriverClient.publishedDevices()?.first { $0.uid == test.uid }?.sampleRate }

        /// Runs an action, then waits up to three seconds for Core Audio to show the expected state.
        func step(_ title: String, _ action: () throws -> Void, until condition: (DeviceInfo?) -> Bool) -> DeviceInfo? {
            let start = Date()
            do {
                try action()
            } catch {
                check(false, "\(title): \(error.localizedDescription)")
                return nil
            }
            var state = live()
            while !condition(state), Date().timeIntervalSince(start) < 3 {
                Thread.sleep(forTimeInterval: 0.05)
                state = live()
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let seen = state.map { "“\($0.name)”, in \($0.inputChannels), out \($0.outputChannels), \(Int($0.sampleRate)) Hz" } ?? "no device"
            check(condition(state), condition(state) ? "\(title) (\(elapsed) ms)" : "\(title): after 3 s Core Audio shows \(seen)")
            return state
        }

        let created = step("appears with 2 channels", { try DriverClient.publish(others + [test]) }) {
            $0?.name == test.name && $0?.inputChannels == 2 && $0?.outputChannels == 2 && $0?.isJunction == true
        }
        guard let created else {
            print("Device test: \(tally.failures) failure(s).")
            return 1
        }
        let objectID = created.objectID
        Thread.sleep(forTimeInterval: 0.5)  // Core Audio may now restore a rate it remembers for this UID
        let arrivalRate = live()?.sampleRate ?? 0
        print("     Core Audio runs it at \(Int(arrivalRate)) Hz after arrival (configured 48000)")
        // Junction's app insists on its own rate right after creating a device, the way Audio MIDI Setup sets it.
        _ = step("runs at the configured 48 kHz", { HAL.setNominalSampleRate(uid: test.uid, 48000) }) { $0?.sampleRate == 48000 }
        check(reportedRate() == 48000, "driver reports 48 kHz back (\(Int(reportedRate() ?? 0)))")

        test.name = "Junction Device Test (renamed)"
        let renamed = step("renamed", { try DriverClient.publish(others + [test]) }) { $0?.name == test.name }
        check(renamed?.objectID == objectID, "keeps its object ID when renamed")

        test.channels = 8
        let wider = step("8 channels", { try DriverClient.publish(others + [test]) }) {
            $0?.inputChannels == 8 && $0?.outputChannels == 8
        }
        check(wider?.objectID == objectID, "keeps its object ID when its channels change")

        test.sampleRate = 96000
        _ = step("96 kHz", { try DriverClient.publish(others + [test]) }) { $0?.sampleRate == 96000 && $0?.inputChannels == 8 }

        _ = step("rate changed from outside (as in Audio MIDI Setup) to 44.1 kHz", {
            HAL.setNominalSampleRate(uid: test.uid, 44100)
        }) { $0?.sampleRate == 44100 }
        check(reportedRate() == 44100, "driver reports the outside change back (\(Int(reportedRate() ?? 0)))")
        test.sampleRate = 44100

        _ = step("turned off: disappears", { try DriverClient.publish(others) }) { $0 == nil }
        check(HAL.deviceID(forUID: test.uid) == nil, "its UID no longer resolves")

        let back = step("turned on again: same name, 8 channels, 44.1 kHz", { try DriverClient.publish(others + [test]) }) {
            $0?.name == test.name && $0?.inputChannels == 8 && $0?.sampleRate == 44100
        }
        // Core Audio numbers objects itself: a device that went away gets a new number when it returns. Apps find it
        // again by its UID.
        check(back != nil && HAL.deviceID(forUID: test.uid) == back?.objectID, "comes back under the same UID")

        _ = step("removed again", { try DriverClient.publish(others) }) { $0 == nil }
        check(DriverClient.publishedDevices().map { $0.map(\.uid) } == others.map(\.uid),
              "the other virtual devices are as they were")

        print(tally.failures == 0 ? "Device test passed." : "Device test: \(tally.failures) failure(s).")
        return tally.failures == 0 ? 0 : 1
    }
}
