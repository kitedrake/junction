import CoreAudio
import Foundation
import JunctionKernel

/// The real devices for a measurement, in the app's own process. The output device is the clock. A microphone on the
/// same device is read from its own input; one at the same rate joins the output in a private aggregate device with
/// drift compensation; one at another rate runs its own IOProc into the kernel's sample-rate converter, which the
/// output's IOProc reads. No device's rate, buffer size or other settings are changed. Starting IO on the microphone
/// needs macOS's Microphone permission for Junction: ask for it (the usual prompt) before measuring.
public final class CoreAudioMeasurementDevice: MeasurementDevice, @unchecked Sendable {
    public let outputUID: String
    public let outputName: String
    public let micUID: String
    public let micName: String
    public let micChannel: Int

    private var output = AudioObjectID(kAudioObjectUnknown)
    private var microphone = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    /// The device the measurement's IOProc runs on: the aggregate, or the output itself.
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var converter: OpaquePointer?
    private var procID: AudioDeviceIOProcID?
    private var micProcID: AudioDeviceIOProcID?

    public init(outputUID: String, outputName: String, micUID: String, micName: String, micChannel: Int) {
        self.outputUID = outputUID
        self.outputName = outputName
        self.micUID = micUID
        self.micName = micName
        self.micChannel = micChannel
    }

    deinit { close() }

    public func open() throws -> MeasurementFormat {
        guard let output = HAL.deviceID(forUID: outputUID) else { throw MeasurementError.deviceDisappeared(outputName) }
        guard let microphone = HAL.deviceID(forUID: micUID) else { throw MeasurementError.deviceDisappeared(micName) }
        self.output = output
        self.microphone = microphone
        let outputChannels = HAL.channelCount(output, kAudioObjectPropertyScopeOutput)
        let micChannels = HAL.channelCount(microphone, kAudioObjectPropertyScopeInput)
        guard outputChannels > 0 else { throw MeasurementError.unusable("“\(outputName)” has no output channels.") }
        guard micChannel < micChannels else {
            throw MeasurementError.unusable("“\(micName)” has no input channel \(micChannel + 1).")
        }
        let rate = HAL.value(output, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
        let micRate = HAL.value(microphone, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
        guard rate > 0, micRate > 0 else { throw MeasurementError.unusable("Couldn't read the devices' sample rates.") }

        var channel = micChannel
        if micUID == outputUID {
            device = output
        } else if micRate == rate {
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Junction · Measuring",
                kAudioAggregateDeviceUIDKey: HAL.aggregateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceIsStackedKey: 0,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                    [kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1],
                ],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
            guard status == noErr, aggregate != kAudioObjectUnknown else {
                throw MeasurementError.unusable("Couldn't combine the output and the microphone (\(HAL.describe(status))).")
            }
            self.aggregate = aggregate
            device = aggregate
            // The aggregate's inputs: the output device's, then the microphone's. It fills them in shortly.
            let before = HAL.channelCount(output, kAudioObjectPropertyScopeInput)
            for _ in 0..<25 {
                if HAL.channelCount(aggregate, kAudioObjectPropertyScopeInput) >= before + micChannels { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            channel = before + micChannel
        } else {
            guard let converter = jk_converter_create(UInt32(micChannels), micRate, rate) else {
                throw MeasurementError.unusable("Out of memory.")
            }
            self.converter = converter
            device = output
        }
        let buffer = HAL.value(device, kAudioDevicePropertyBufferFrameSize, default: UInt32(512))
        return MeasurementFormat(sampleRate: rate, outputChannels: outputChannels, micChannel: channel,
                                 bufferFrames: Int(buffer))
    }

    public func start(_ measure: OpaquePointer) throws {
        if let converter {
            jk_measure_set_converter(measure, converter)
            var proc: AudioDeviceIOProcID?
            var status = AudioDeviceCreateIOProcID(microphone, jk_converter_ioproc, UnsafeMutableRawPointer(converter), &proc)
            guard status == noErr, let proc else { throw Self.error(status) }
            micProcID = proc
            status = AudioDeviceStart(microphone, proc)
            guard status == noErr else { throw Self.error(status) }
        }
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(device, jk_measure_ioproc, UnsafeMutableRawPointer(measure), &proc)
        guard status == noErr, let proc else { throw Self.error(status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw Self.error(status) }
    }

    public func close() {
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
        if let micProcID {
            AudioDeviceStop(microphone, micProcID)
            AudioDeviceDestroyIOProcID(microphone, micProcID)
            self.micProcID = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if let converter {
            jk_converter_destroy(converter)
            self.converter = nil
        }
    }

    public func missingDevice() -> String? {
        for (uid, name) in [(outputUID, outputName), (micUID, micName)] {
            guard let id = HAL.deviceID(forUID: uid), HAL.value(id, kAudioDevicePropertyDeviceIsAlive, default: UInt32(1)) != 0
            else { return name }
        }
        return nil
    }

    private static func error(_ status: OSStatus) -> MeasurementError {
        status == kAudioDevicePermissionsError
            ? .microphoneDenied : .unusable("Couldn't start the devices for measuring (\(HAL.describe(status))).")
    }
}
