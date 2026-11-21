import AppKit
import CoreAudio
import Darwin
import Foundation

/// Thin wrappers over the Core Audio object API (the "HAL").
public enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var address = address(selector, scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        return status == noErr ? result : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of type: T.Type) -> [T] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// Total channels in one direction, from the device's stream configuration.
    static func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var key = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &key) { keyPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), keyPointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Sets a device's nominal sample rate, as Audio MIDI Setup does.
    @discardableResult
    public static func setNominalSampleRate(uid: String, _ rate: Double) -> Bool {
        guard let device = deviceID(forUID: uid) else { return false }
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// Readable text for an OSStatus (many Core Audio errors are four-character codes).
    public static func describe(_ status: OSStatus) -> String {
        let known: [OSStatus: String] = [
            kAudioHardwareNotRunningError: "Core Audio isn't running",
            kAudioHardwareUnspecifiedError: "unspecified Core Audio error",
            kAudioHardwareBadObjectError: "the device went away",
            kAudioHardwareBadDeviceError: "the device went away",
            kAudioHardwareIllegalOperationError: "Core Audio refused the request",
            kAudioDevicePermissionsError: "permission denied",
            kAudioHardwareUnsupportedOperationError: "not supported",
        ]
        if let text = known[status] { return text }
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "error '\(String(decoding: bytes, as: UTF8.self))'" }
        return "error \(status)"
    }

    // MARK: Inventory

    static let junctionModelUID = "local.junction.virtual-device"
    static let aggregateUIDPrefix = "local.junction.aggregate."

    static func deviceInfo(_ id: AudioObjectID, uid: String) -> DeviceInfo {
        DeviceInfo(
            uid: uid, objectID: id, name: string(id, kAudioObjectPropertyName) ?? uid,
            inputChannels: channelCount(id, kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, kAudioObjectPropertyScopeOutput),
            sampleRate: value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
            isJunction: string(id, kAudioDevicePropertyModelUID) == junctionModelUID,
            clockDomain: value(id, kAudioDevicePropertyClockDomain, default: UInt32(0)))
    }

    /// Reads devices, defaults and audio apps. Hidden devices are left out, except Junction's own (a virtual device
    /// set to hidden, and the companions of one-sided devices): apps don't list them, Junction still routes them.
    public static func readInventory() -> Inventory {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices: [DeviceInfo] = []
        for id in array(system, kAudioHardwarePropertyDevices, of: AudioObjectID.self) {
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(aggregateUIDPrefix) else { continue }
            let info = deviceInfo(id, uid: uid)
            if value(id, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0, !info.isJunction { continue }
            devices.append(info)
        }
        // Hidden devices are only found by their UID.
        for entry in DriverClient.publishedConfiguration() ?? [] {
            guard let uid = entry["uid"] as? String else { continue }
            for candidate in [uid, uid + VirtualDevice.companionSuffix] where !devices.contains(where: { $0.uid == candidate }) {
                guard let id = deviceID(forUID: candidate) else { continue }
                let info = deviceInfo(id, uid: candidate)
                if info.isJunction { devices.append(info) }
            }
        }
        let defaultOutput = value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        let defaultInput = value(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(kAudioObjectUnknown))
        return Inventory(
            devices: devices,
            apps: audioApps(),
            defaultOutputUID: devices.first { $0.objectID == defaultOutput }?.uid,
            defaultInputUID: devices.first { $0.objectID == defaultInput }?.uid,
            driver: DriverClient.status(),
            deviceClients: DriverClient.deviceClients(from: DriverClient.capturedClients()) { pid, bundleID in
                let owner = owningApp(pid: pid)
                let appID = owner?.bundleID ?? bundleID
                return AppRef(bundleID: appID, name: owner?.name ?? displayName(forBundleID: appID))
            })
    }

    // MARK: Processes

    /// A process Core Audio knows about, with the app it belongs to (helpers belong to the app that contains them).
    public struct AudioProcess: Hashable, Sendable {
        public var objectID: AudioObjectID
        public var pid: pid_t
        public var bundleID: String
        public var appBundleID: String
        public var appName: String
        /// The .app bundle the process lives in, if any.
        public var appPath: String?
        public var isPlaying: Bool
    }

    public static func audioProcesses() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return array(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self).compactMap { id in
            let pid = value(id, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0 else { return nil }
            let bundleID = string(id, kAudioProcessPropertyBundleID) ?? ""
            let owner = owningApp(pid: pid)
            let appBundleID = owner?.bundleID ?? bundleID
            guard !appBundleID.isEmpty else { return nil }
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, appBundleID: appBundleID,
                                appName: owner?.name ?? displayName(forBundleID: appBundleID), appPath: owner?.path,
                                isPlaying: value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }

    /// Apps with audio processes, one entry per app, without Junction itself and without system services.
    static func audioApps() -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        for process in audioProcesses() where !ownBundleIDs.contains(process.appBundleID) && process.pid != getpid() {
            // Real apps only: background services and system UI (Control Center, Siri…) aren't useful sources.
            let isWebKit = process.bundleID.hasPrefix("com.apple.WebKit")
            guard isWebKit || (process.appPath.map { !$0.hasPrefix("/System/Library/") } ?? false) else { continue }
            var app = apps[process.appBundleID] ?? AudioApp(bundleID: process.appBundleID, name: process.appName)
            app.isPlaying = app.isPlaying || process.isPlaying
            apps[process.appBundleID] = app
        }
        return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Junction itself: this process's bundle, the app and its routing helper (which lives inside the app, so its
    /// processes belong to the app).
    public static var ownBundleIDs: Set<String> {
        Set([Bundle.main.bundleIdentifier, RoutingXPC.appBundleIdentifier, RoutingXPC.helperBundleIdentifier].compactMap { $0 })
    }

    /// The outermost .app bundle containing the process's executable, if any.
    static func owningApp(pid: pid_t) -> (bundleID: String, name: String, path: String)? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<range.lowerBound]) + ".app"
        guard let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        return (id, name, appPath)
    }

    static func displayName(forBundleID bundleID: String) -> String {
        if bundleID.hasPrefix("com.apple.WebKit") { return "Safari & Web Views" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: Listeners

    /// Calls `handler` on `queue` when the sample rate or channel layout of any of the given devices changes. Keep
    /// the returned object alive; dropping it removes the listeners. Device IDs are looked up once, so make a new
    /// watcher after Core Audio restarts.
    public final class DeviceWatcher: @unchecked Sendable {
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var registered: [(AudioObjectID, AudioObjectPropertyAddress)] = []

        public init(uids: Set<String>, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
            self.queue = queue
            block = { _, _ in handler() }
            let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
                (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
                (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            ]
            for uid in uids.sorted() {
                guard let device = HAL.deviceID(forUID: uid) else { continue }
                for (selector, scope) in properties {
                    var address = HAL.address(selector, scope)
                    if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                        registered.append((device, address))
                    }
                }
            }
        }

        deinit {
            for (device, address) in registered {
                var address = address
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
        }
    }

    /// Calls `handler` on `queue` when any of the given system-object properties change (by default: devices,
    /// defaults, audio processes). Keep the returned object alive; dropping it removes the listeners.
    public final class SystemWatcher: @unchecked Sendable {
        /// What the inventory depends on: devices, defaults, processes playing audio.
        public static let inventorySelectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList,
        ]

        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private let selectors: [AudioObjectPropertySelector]

        public init(selectors: [AudioObjectPropertySelector] = inventorySelectors, queue: DispatchQueue,
                    handler: @escaping @Sendable () -> Void) {
            self.selectors = selectors
            self.queue = queue
            block = { _, _ in handler() }
            for selector in selectors {
                var address = HAL.address(selector)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
        }

        deinit {
            for selector in selectors {
                var address = HAL.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
        }
    }
}
