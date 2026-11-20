import CoreAudio
import Foundation

/// Talks to the Junction driver inside coreaudiod through the custom properties on its plug-in object.
public enum DriverClient {
    public static let bundleID = "local.junction.driver"
    public static let installPath = "/Library/Audio/Plug-Ins/HAL/JunctionDriver.driver"
    static let configSelector: AudioObjectPropertySelector = 0x6A63_6667  // 'jcfg'
    static let versionSelector: AudioObjectPropertySelector = 0x6A76_6572 // 'jver'

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

    /// The configuration the driver should publish: the enabled virtual devices, in order.
    public static func configuration(for devices: [VirtualDevice]) -> [[String: Any]] {
        devices.filter(\.isEnabled).prefix(VirtualDevice.maximumCount).map {
            ["uid": $0.uid, "name": $0.name, "channels": $0.channels, "sampleRate": $0.sampleRate]
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
        bundledDriverURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    }
}
