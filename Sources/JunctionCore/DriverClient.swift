import CoreAudio
import Foundation

/// Talks to the Junction driver inside coreaudiod through the custom properties on its plug-in object.
public enum DriverClient {
    public static let bundleID = "com.kitedrake.junction.driver"
    public static let installPath = "/Library/Audio/Plug-Ins/HAL/JunctionDriver.driver"
    static let configSelector: AudioObjectPropertySelector = 0x6A63_6667  // 'jcfg'
    static let versionSelector: AudioObjectPropertySelector = 0x6A76_6572 // 'jver'
    static let clientsSelector: AudioObjectPropertySelector = 0x6A63_6C69 // 'jcli'

    /// The plug-in object, when coreaudiod has loaded the driver.
    static func plugIn() -> AudioObjectID? {
        var address = HAL.address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var key = bundleID as CFString
        var plugIn = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &key) { keyPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), keyPointer, &size, &plugIn)
        }
        return status == noErr && plugIn != kAudioObjectUnknown ? plugIn : nil
    }

    public static func status() -> DriverStatus {
        guard let plugIn = plugIn() else { return .notInstalled }
        return .installed(version: HAL.string(plugIn, versionSelector) ?? "?")
    }

    /// The devices the driver publishes, as it reports them.
    public static func publishedConfiguration() -> [[String: Any]]? {
        guard let plugIn = plugIn() else { return nil }
        var address = HAL.address(configSelector)
        var result: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(plugIn, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as? [[String: Any]]
    }

    /// The apps' processes the driver captures, as it lists them (pid, bundle ID, device UID, channels). Empty when
    /// the driver isn't loaded.
    public static func capturedClients() -> [[String: Any]] {
        guard let plugIn = plugIn() else { return [] }
        var address = HAL.address(clientsSelector)
        var result: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(plugIn, &address, 0, nil, &size, &result) == noErr, let result else { return [] }
        return result.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// Reads the driver's client list, naming each client's app with `appOf` (pid and bundle ID to the app).
    static func deviceClients(from list: [[String: Any]], appOf: (Int32, String) -> AppRef) -> [DeviceClient] {
        list.compactMap { entry in
            guard let pid = (entry["pid"] as? NSNumber)?.int32Value, let bundleID = entry["bundleID"] as? String,
                  let uid = entry["deviceUID"] as? String
            else { return nil }
            let channels = (entry["channels"] as? NSNumber)?.intValue ?? 2
            return DeviceClient(pid: pid, bundleID: bundleID, deviceUID: uid, channels: channels, app: appOf(pid, bundleID))
        }
    }

    /// The published devices as VirtualDevice values (all enabled), or nil when the driver isn't loaded.
    public static func publishedDevices() -> [VirtualDevice]? {
        publishedConfiguration().map(devices(from:))
    }

    /// Reads the driver's list. Driver 0.1 reports only uid, name, channels and sample rate; the other settings then
    /// keep their defaults.
    static func devices(from configuration: [[String: Any]]) -> [VirtualDevice] {
        configuration.compactMap { entry in
            guard let uid = entry["uid"] as? String, uid.hasPrefix("junction."),
                  let id = UUID(uuidString: String(uid.dropFirst("junction.".count)))
            else { return nil }
            func number(_ key: String, _ fallback: Double) -> Double { (entry[key] as? NSNumber)?.doubleValue ?? fallback }
            func flag(_ key: String) -> Bool { (entry[key] as? NSNumber)?.boolValue ?? false }
            return VirtualDevice(id: id, name: entry["name"] as? String ?? "Virtual Device",
                                 channels: Int(number("channels", 2)), sampleRate: number("sampleRate", 48000),
                                 direction: (entry["direction"] as? String).flatMap(DeviceDirection.init(rawValue:)) ?? .both,
                                 channelNames: entry["channelNames"] as? [String] ?? [],
                                 icon: (entry["icon"] as? String).flatMap(DeviceIcon.init(rawValue:)) ?? .junction,
                                 isHidden: flag("hidden"), outputVolume: number("outputVolume", 1), outputMuted: flag("outputMute"),
                                 inputVolume: number("inputVolume", 1), inputMuted: flag("inputMute"))
        }
    }

    /// The configuration the driver should publish: the enabled virtual devices, in order, in the form the driver
    /// reports back (so an unchanged list isn't sent again).
    public static func configuration(for devices: [VirtualDevice]) -> [[String: Any]] {
        devices.filter(\.isEnabled).prefix(VirtualDevice.maximumCount).map { device in
            var names = Array(device.channelNames.prefix(device.channels))
            while names.last?.isEmpty == true { names.removeLast() }
            return [
                "uid": device.uid, "name": device.name, "channels": device.channels, "sampleRate": device.sampleRate,
                "direction": device.direction.rawValue, "channelNames": names, "icon": device.icon.rawValue,
                "hidden": device.isHidden, "outputVolume": min(max(device.outputVolume, 0), 1),
                "outputMute": device.outputMuted, "inputVolume": min(max(device.inputVolume, 0), 1),
                "inputMute": device.inputMuted,
            ]
        }
    }

    /// Calls `handler` on `queue` when the driver reports that its list changed by itself (a volume or mute set in
    /// Sound settings, a sample rate set elsewhere), or that an app started or stopped playing into one of its
    /// devices. Keep the returned object alive; make a new one after Core Audio restarts.
    public final class ConfigWatcher: @unchecked Sendable {
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private let plugIn: AudioObjectID
        private static let selectors = [configSelector, clientsSelector]

        public init?(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
            guard let plugIn = DriverClient.plugIn() else { return nil }
            self.plugIn = plugIn
            self.queue = queue
            block = { _, _ in handler() }
            var address = HAL.address(configSelector)
            guard AudioObjectAddPropertyListenerBlock(plugIn, &address, queue, block) == noErr else { return nil }
            address = HAL.address(clientsSelector)
            AudioObjectAddPropertyListenerBlock(plugIn, &address, queue, block)  // drivers before 0.2.0 have no list
        }

        deinit {
            for selector in Self.selectors {
                var address = HAL.address(selector)
                AudioObjectRemovePropertyListenerBlock(plugIn, &address, queue, block)
            }
        }
    }

    public enum PublishError: Error, LocalizedError {
        case notInstalled
        case refused(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "The Junction driver isn't installed."
            case .refused(let status): "The driver refused the device list (\(HAL.describe(status)))."
            }
        }
    }

    /// Makes the driver publish exactly the enabled devices. It saves the list itself, so they stay after a restart.
    public static func publish(_ devices: [VirtualDevice]) throws {
        guard let plugIn = plugIn() else { throw PublishError.notInstalled }
        let wanted = configuration(for: devices)
        if let current = publishedConfiguration(), NSArray(array: current).isEqual(to: wanted) { return }
        var address = HAL.address(configSelector)
        let plist = wanted as CFArray
        // The property's data is a CFPropertyListRef: pass a pointer to the reference.
        var reference = Unmanaged.passUnretained(plist).toOpaque()
        let status = withExtendedLifetime(plist) {
            AudioObjectSetPropertyData(plugIn, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
        }
        if status != noErr { throw PublishError.refused(status) }
    }

    /// The driver bundle shipped inside the app.
    public static var bundledDriverURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("JunctionDriver.driver")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Version of the bundled driver, to offer an update when the installed one differs.
    public static var bundledVersion: String? {
        // Read the Info.plist directly: once Core Audio has looked at the installed driver (same bundle identifier),
        // `Bundle(url:)` for the bundled copy can come back without its version.
        bundledDriverURL.flatMap {
            NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        }
    }
}
