// Loads a built JunctionDriver.driver into this process with a stand-in host (no coreaudiod, nothing installed)
// and checks what the HAL would see: the device list follows the app's configuration, names/formats/UIDs are
// right, changes are announced and saved, a fresh load restores the saved devices, and audio written to a
// device's output comes back out of its input.
//
// Usage: harness <path to JunctionDriver.driver> [expected version]

#include <CoreAudio/AudioServerPlugIn.h>
#include <copyfile.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { kSelectorConfig = 'jcfg', kSelectorVersion = 'jver', kRingFrames = 16384 };

static int gFailures = 0;
#define CHECK(condition, ...)                                                                                          \
    do {                                                                                                               \
        if (!(condition)) {                                                                                            \
            gFailures++;                                                                                               \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                                       \
            fprintf(stderr, __VA_ARGS__);                                                                              \
            fprintf(stderr, "\n");                                                                                     \
        }                                                                                                              \
    } while (0)

#pragma mark - Stand-in host

static CFMutableDictionaryRef gStorage;
static volatile int gDeviceListChanges, gNameChanges, gConfigRequests, gStorageWrites;
static AudioObjectID gRequestedDevice;
static AudioServerPlugInDriverRef gDriver;

static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID objectID, UInt32 count,
                                      const AudioObjectPropertyAddress *addresses) {
    (void)host;
    for (UInt32 i = 0; i < count; i++) {
        if (objectID == kAudioObjectPlugInObject && addresses[i].mSelector == kAudioPlugInPropertyDeviceList)
            __sync_fetch_and_add(&gDeviceListChanges, 1);
        if (addresses[i].mSelector == kAudioObjectPropertyName) __sync_fetch_and_add(&gNameChanges, 1);
    }
    return noErr;
}

static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *out) {
    (void)host;
    CFPropertyListRef value = CFDictionaryGetValue(gStorage, key);
    *out = value ? CFPropertyListCreateDeepCopy(NULL, value, kCFPropertyListImmutable) : NULL;
    return value ? noErr : kAudioHardwareUnknownPropertyError;
}

static OSStatus HostWriteToStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef data) {
    (void)host;
    CFPropertyListRef copy = CFPropertyListCreateDeepCopy(NULL, data, kCFPropertyListImmutable);
    CFDictionarySetValue(gStorage, key, copy);
    CFRelease(copy);
    __sync_fetch_and_add(&gStorageWrites, 1);
    return noErr;
}

static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) {
    (void)host;
    CFDictionaryRemoveValue(gStorage, key);
    return noErr;
}

static OSStatus HostRequestConfigurationChange(AudioServerPlugInHostRef host, AudioObjectID deviceID, UInt64 action,
                                               void *info) {
    (void)host;
    gRequestedDevice = deviceID;
    __sync_fetch_and_add(&gConfigRequests, 1);
    // A real host stops IO, then performs the change.
    return (*gDriver)->PerformDeviceConfigurationChange(gDriver, deviceID, action, info);
}

static AudioServerPlugInHostInterface gHostInterface = {
    HostPropertiesChanged, HostCopyFromStorage, HostWriteToStorage, HostDeleteFromStorage, HostRequestConfigurationChange,
};

static void WaitFor(volatile int *counter, int atLeast) {
    for (int i = 0; i < 200 && *counter < atLeast; i++) usleep(10000);
}

#pragma mark - Driver access

static AudioServerPlugInDriverRef Load(const char *bundlePath, const char *copyName) {
    // A copy of the binary under a new name loads as a separate image, with fresh globals: a "restart".
    char source[2048], target[2048];
    snprintf(source, sizeof source, "%s/Contents/MacOS/JunctionDriver", bundlePath);
    snprintf(target, sizeof target, "%s/%s", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", copyName);
    unlink(target);
    if (copyfile(source, target, NULL, COPYFILE_ALL) != 0) {
        fprintf(stderr, "Can't copy %s\n", source);
        exit(2);
    }
    void *image = dlopen(target, RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        exit(2);
    }
    typedef void *(*Factory)(CFAllocatorRef, CFUUIDRef);
    Factory factory = (Factory)dlsym(image, "JunctionDriver_Create");
    if (!factory) {
        fprintf(stderr, "No JunctionDriver_Create in %s\n", target);
        exit(2);
    }
    AudioServerPlugInDriverRef driver = factory(NULL, kAudioServerPlugInTypeUUID);
    CHECK(driver != NULL, "factory returned NULL");
    CHECK(factory(NULL, CFUUIDGetConstantUUIDWithBytes(NULL, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)) == NULL,
          "factory accepted an unknown type");
    void *queried = NULL;
    CHECK((*driver)->QueryInterface(driver, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &queried) == S_OK &&
              queried == driver,
          "QueryInterface for the driver interface failed");
    unlink(target);
    return driver;
}

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}

static UInt32 DeviceList(AudioObjectID *ids, UInt32 max) {
    AudioObjectPropertyAddress address = Address(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    (*gDriver)->GetPropertyDataSize(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, &size);
    UInt32 used = 0;
    if (size > max * sizeof(AudioObjectID)) size = max * sizeof(AudioObjectID);
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, size, &used, ids);
    return used / sizeof(AudioObjectID);
}

static CFStringRef CopyString(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 size = 0;
    if ((*gDriver)->GetPropertyData(gDriver, objectID, 0, &address, 0, NULL, sizeof value, &size, &value) != noErr) return NULL;
    return value;
}

static bool StringIs(AudioObjectID objectID, AudioObjectPropertySelector selector, const char *expected) {
    CFStringRef value = CopyString(objectID, selector);
    if (!value) return false;
    char buffer[512];
    CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    CFRelease(value);
    return strcmp(buffer, expected) == 0;
}

static AudioObjectID DeviceForUID(const char *uid) {
    AudioObjectPropertyAddress address = Address(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    CFStringRef key = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, sizeof key, &key, sizeof device, &size, &device);
    CFRelease(key);
    return device;
}

static AudioObjectID Stream(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = Address(kAudioDevicePropertyStreams, scope);
    AudioObjectID stream = kAudioObjectUnknown;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, device, 0, &address, 0, NULL, sizeof stream, &size, &stream);
    return size == sizeof stream ? stream : kAudioObjectUnknown;
}

static AudioStreamBasicDescription StreamFormat(AudioObjectID stream) {
    AudioObjectPropertyAddress address = Address(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription format = {0};
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, stream, 0, &address, 0, NULL, sizeof format, &size, &format);
    return format;
}

static CFDictionaryRef DeviceEntry(const char *uid, const char *name, int channels, double rate) {
    CFStringRef uidString = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    CFStringRef nameString = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CFNumberRef channelsNumber = CFNumberCreate(NULL, kCFNumberIntType, &channels);
    CFNumberRef rateNumber = CFNumberCreate(NULL, kCFNumberDoubleType, &rate);
    const void *keys[] = {CFSTR("uid"), CFSTR("name"), CFSTR("channels"), CFSTR("sampleRate")};
    const void *values[] = {uidString, nameString, channelsNumber, rateNumber};
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFRelease(uidString);
    CFRelease(nameString);
    CFRelease(channelsNumber);
    CFRelease(rateNumber);
    return dict;
}

/// The sample rate the driver's configuration reports for a device (what the app reads back).
static Float64 ConfigRate(const char *uid) {
    AudioObjectPropertyAddress address = Address(kSelectorConfig, kAudioObjectPropertyScopeGlobal);
    CFArrayRef config = NULL;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof config, &size, &config);
    Float64 rate = 0;
    CFStringRef key = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    for (CFIndex i = 0; config && i < CFArrayGetCount(config); i++) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(config, i);
        if (!CFEqual(CFDictionaryGetValue(entry, CFSTR("uid")), key)) continue;
        CFNumberGetValue(CFDictionaryGetValue(entry, CFSTR("sampleRate")), kCFNumberFloat64Type, &rate);
    }
    CFRelease(key);
    if (config) CFRelease(config);
    return rate;
}

static OSStatus SetConfig(CFPropertyListRef config) {
    AudioObjectPropertyAddress address = Address(kSelectorConfig, kAudioObjectPropertyScopeGlobal);
    return (*gDriver)->SetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof config, &config);
}

static OSStatus SetDevices(CFDictionaryRef *entries, CFIndex count) {
    CFArrayRef array = CFArrayCreate(NULL, (const void **)entries, count, &kCFTypeArrayCallBacks);
    OSStatus status = SetConfig(array);
    CFRelease(array);
    return status;
}

static OSStatus DoIO(AudioObjectID device, UInt32 operation, Float64 sampleTime, Float32 *buffer, UInt32 frames) {
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof cycle);
    cycle.mNominalIOBufferFrameSize = frames;
    cycle.mInputTime.mSampleTime = sampleTime;
    cycle.mOutputTime.mSampleTime = sampleTime;
    AudioObjectID stream = Stream(device, operation == kAudioServerPlugInIOOperationReadInput ? kAudioObjectPropertyScopeInput
                                                                                            : kAudioObjectPropertyScopeOutput);
    return (*gDriver)->DoIOOperation(gDriver, device, stream, 1, operation, frames, &cycle, buffer, NULL);
}

#pragma mark - Tests

static void TestLoopback(AudioObjectID device, UInt32 channels, Float64 at, UInt32 frames) {
    Float32 *written = malloc(sizeof(Float32) * frames * channels);
    Float32 *read = malloc(sizeof(Float32) * frames * channels);
    for (UInt32 i = 0; i < frames * channels; i++) written[i] = (Float32)((i * 7919) % 2001) / 1000.0f - 1.0f;
    CHECK(DoIO(device, kAudioServerPlugInIOOperationWriteMix, at, written, frames) == noErr, "WriteMix failed");
    memset(read, 0xff, sizeof(Float32) * frames * channels);
    CHECK(DoIO(device, kAudioServerPlugInIOOperationReadInput, at, read, frames) == noErr, "ReadInput failed");
    CHECK(memcmp(written, read, sizeof(Float32) * frames * channels) == 0, "loopback at %.0f returned different samples", at);
    DoIO(device, kAudioServerPlugInIOOperationReadInput, at, read, frames);
    bool silent = true;
    for (UInt32 i = 0; i < frames * channels; i++) if (read[i] != 0) silent = false;
    CHECK(silent, "samples at %.0f were read twice (should be consumed)", at);
    free(written);
    free(read);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s JunctionDriver.driver [version]\n", argv[0]);
        return 2;
    }
    gStorage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    gDriver = Load(argv[1], "junction-harness-1");
    CHECK((*gDriver)->Initialize(gDriver, &gHostInterface) == noErr, "Initialize failed");

    AudioObjectID ids[64];
    CHECK(DeviceList(ids, 64) == 0, "a fresh driver should publish no devices");
    if (argc > 2) CHECK(StringIs(kAudioObjectPlugInObject, kSelectorVersion, argv[2]), "version property should be %s", argv[2]);

    // Plug-in advertises its custom properties so the HAL forwards them.
    {
        AudioObjectPropertyAddress address = Address(kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal);
        AudioServerPlugInCustomPropertyInfo info[4];
        UInt32 size = 0;
        (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof info, &size, info);
        CHECK(size == 2 * sizeof info[0] && info[0].mSelector == kSelectorConfig &&
                  info[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
              "custom property info list");
        Boolean settable = false;
        AudioObjectPropertyAddress config = Address(kSelectorConfig, kAudioObjectPropertyScopeGlobal);
        (*gDriver)->IsPropertySettable(gDriver, kAudioObjectPlugInObject, 0, &config, &settable);
        CHECK(settable, "configuration property should be settable");
    }

    // Two devices.
    CFDictionaryRef stream = DeviceEntry("junction.test.stream", "Stream Mix", 2, 48000);
    CFDictionaryRef chat = DeviceEntry("junction.test.chat", "Chat", 8, 44100);
    CFDictionaryRef both[] = {stream, chat};
    CHECK(SetDevices(both, 2) == noErr, "setting two devices failed");
    WaitFor(&gDeviceListChanges, 1);
    WaitFor(&gStorageWrites, 1);
    CHECK(gDeviceListChanges >= 1, "device list change not announced");
    CHECK(gStorageWrites >= 1, "configuration not saved");
    CHECK(DeviceList(ids, 64) == 2, "expected two devices, got %u", DeviceList(ids, 64));
    AudioObjectID streamDevice = DeviceForUID("junction.test.stream");
    AudioObjectID chatDevice = DeviceForUID("junction.test.chat");
    CHECK(streamDevice != kAudioObjectUnknown && chatDevice != kAudioObjectUnknown && streamDevice != chatDevice,
          "UID lookup");
    CHECK(DeviceForUID("junction.test.missing") == kAudioObjectUnknown, "unknown UID should not resolve");
    CHECK(StringIs(streamDevice, kAudioObjectPropertyName, "Stream Mix"), "device name");
    CHECK(StringIs(chatDevice, kAudioDevicePropertyDeviceUID, "junction.test.chat"), "device UID");
    AudioStreamBasicDescription chatFormat = StreamFormat(Stream(chatDevice, kAudioObjectPropertyScopeInput));
    CHECK(chatFormat.mChannelsPerFrame == 8 && chatFormat.mSampleRate == 44100 && chatFormat.mBitsPerChannel == 32,
          "chat format %u ch %.0f Hz", chatFormat.mChannelsPerFrame, chatFormat.mSampleRate);
    CHECK(Stream(streamDevice, kAudioObjectPropertyScopeInput) != Stream(streamDevice, kAudioObjectPropertyScopeOutput),
          "input and output streams should differ");
    {
        AudioObjectPropertyAddress transport = Address(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
        UInt32 value = 0, size = 0;
        (*gDriver)->GetPropertyData(gDriver, streamDevice, 0, &transport, 0, NULL, sizeof value, &size, &value);
        CHECK(value == kAudioDeviceTransportTypeVirtual, "transport type should be virtual");
        AudioObjectPropertyAddress rates = Address(kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal);
        (*gDriver)->GetPropertyDataSize(gDriver, streamDevice, 0, &rates, 0, NULL, &size);
        CHECK(size == 6 * sizeof(AudioValueRange), "six sample rates");
        AudioObjectPropertyAddress layout = Address(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput);
        (*gDriver)->GetPropertyDataSize(gDriver, chatDevice, 0, &layout, 0, NULL, &size);
        CHECK(size == offsetof(AudioChannelLayout, mChannelDescriptions) + 8 * sizeof(AudioChannelDescription),
              "channel layout size for 8 channels");
    }
    // The stored copy reads back.
    {
        AudioObjectPropertyAddress address = Address(kSelectorConfig, kAudioObjectPropertyScopeGlobal);
        CFArrayRef config = NULL;
        UInt32 size = 0;
        (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof config, &size, &config);
        CHECK(config && CFArrayGetCount(config) == 2, "configuration should read back with two entries");
        if (config) CFRelease(config);
    }

    // Audio played to the output comes out of the input, including across the ring's end.
    CHECK((*gDriver)->StartIO(gDriver, streamDevice, 1) == noErr, "StartIO");
    {
        Boolean willDo = false, inPlace = false;
        (*gDriver)->WillDoIOOperation(gDriver, streamDevice, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace);
        CHECK(willDo, "driver should handle WriteMix");
        Float64 sampleTime = 0;
        UInt64 hostTime = 0, seed = 0;
        CHECK((*gDriver)->GetZeroTimeStamp(gDriver, streamDevice, 1, &sampleTime, &hostTime, &seed) == noErr && hostTime > 0,
              "zero time stamp");
    }
    TestLoopback(streamDevice, 2, 1000, 512);
    TestLoopback(streamDevice, 2, kRingFrames - 100, 512);
    TestLoopback(streamDevice, 2, 5 * kRingFrames + 7, 4096);
    CHECK((*gDriver)->StopIO(gDriver, streamDevice, 1) == noErr, "StopIO");

    // Rename: announced, no new device.
    int names = gNameChanges;
    CFDictionaryRef renamed = DeviceEntry("junction.test.stream", "OBS Feed", 2, 48000);
    CFDictionaryRef afterRename[] = {renamed, chat};
    CHECK(SetDevices(afterRename, 2) == noErr, "rename");
    WaitFor(&gNameChanges, names + 1);
    CHECK(gNameChanges > names, "name change not announced");
    CHECK(StringIs(streamDevice, kAudioObjectPropertyName, "OBS Feed"), "renamed device name");
    CHECK(DeviceForUID("junction.test.stream") == streamDevice, "rename should keep the object ID");

    // Channel count change goes through the host's configuration-change path.
    int requests = gConfigRequests;
    CFDictionaryRef wider = DeviceEntry("junction.test.chat", "Chat", 4, 48000);
    CFDictionaryRef afterWiden[] = {renamed, wider};
    CHECK(SetDevices(afterWiden, 2) == noErr, "channel change");
    WaitFor(&gConfigRequests, requests + 1);
    CHECK(gConfigRequests > requests && gRequestedDevice == chatDevice, "configuration change not requested");
    chatFormat = StreamFormat(Stream(chatDevice, kAudioObjectPropertyScopeOutput));
    CHECK(chatFormat.mChannelsPerFrame == 4 && chatFormat.mSampleRate == 48000, "chat should now be 4 ch at 48 kHz");
    CHECK((*gDriver)->StartIO(gDriver, chatDevice, 1) == noErr, "StartIO after change");
    TestLoopback(chatDevice, 4, 333, 256);
    (*gDriver)->StopIO(gDriver, chatDevice, 1);

    // Sample rate set the way Audio MIDI Setup does it.
    {
        requests = gConfigRequests;
        AudioObjectPropertyAddress address = Address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
        Float64 rate = 96000;
        CHECK((*gDriver)->SetPropertyData(gDriver, chatDevice, 0, &address, 0, NULL, sizeof rate, &rate) == noErr, "set rate");
        WaitFor(&gConfigRequests, requests + 1);
        Float64 now = 0;
        UInt32 size = 0;
        (*gDriver)->GetPropertyData(gDriver, chatDevice, 0, &address, 0, NULL, sizeof now, &size, &now);
        CHECK(now == 96000, "rate should be 96 kHz, is %.0f", now);
        // A change from outside the app (Core Audio restoring a remembered rate, Audio MIDI Setup) shows in the
        // configuration the app reads back, and is saved.
        CHECK(ConfigRate("junction.test.chat") == 96000, "configuration should report 96 kHz, reports %.0f",
              ConfigRate("junction.test.chat"));
        usleep(100000);
        CFArrayRef stored = CFDictionaryGetValue(gStorage, CFSTR("devices"));
        bool storedRate = false;
        for (CFIndex i = 0; stored && i < CFArrayGetCount(stored); i++) {
            CFDictionaryRef entry = CFArrayGetValueAtIndex(stored, i);
            Float64 value = 0;
            CFNumberRef number = CFDictionaryGetValue(entry, CFSTR("sampleRate"));
            if (CFEqual(CFDictionaryGetValue(entry, CFSTR("uid")), CFSTR("junction.test.chat")) && number &&
                CFNumberGetValue(number, kCFNumberFloat64Type, &value))
                storedRate = value == 96000;
        }
        CHECK(storedRate, "saved configuration should hold 96 kHz");
        rate = 12345;
        CHECK((*gDriver)->SetPropertyData(gDriver, chatDevice, 0, &address, 0, NULL, sizeof rate, &rate) != noErr,
              "unsupported rate should be refused");
    }

    // Removing a device.
    int listChanges = gDeviceListChanges;
    CFDictionaryRef onlyStream[] = {renamed};
    CHECK(SetDevices(onlyStream, 1) == noErr, "remove");
    WaitFor(&gDeviceListChanges, listChanges + 1);
    CHECK(DeviceList(ids, 64) == 1 && ids[0] == streamDevice, "only the stream device should remain");
    CHECK(DeviceForUID("junction.test.chat") == kAudioObjectUnknown, "removed device should not resolve");
    {
        UInt32 size = 0;
        AudioObjectPropertyAddress address = Address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
        CHECK((*gDriver)->GetPropertyDataSize(gDriver, chatDevice, 0, &address, 0, NULL, &size) == kAudioHardwareBadObjectError,
              "removed device should be a bad object");
    }
    // Re-enabling it brings back the same object ID.
    CFDictionaryRef again[] = {renamed, wider};
    SetDevices(again, 2);
    CHECK(DeviceForUID("junction.test.chat") == chatDevice, "re-enabled device should reuse its object ID");

    // Bad input is refused and changes nothing.
    CHECK(SetConfig(CFSTR("not an array")) != noErr, "a non-array configuration should be refused");
    CHECK(DeviceList(ids, 64) == 2, "refused configuration changed the list");

    // More than 32 devices: the first 32 are published.
    {
        CFDictionaryRef many[40];
        for (int i = 0; i < 40; i++) {
            char uid[64], name[64];
            snprintf(uid, sizeof uid, "junction.test.many.%d", i);
            snprintf(name, sizeof name, "Many %d", i);
            many[i] = DeviceEntry(uid, name, 2, 48000);
        }
        SetDevices(many, 40);
        CHECK(DeviceList(ids, 64) == 32, "expected 32 devices, got %u", DeviceList(ids, 64));
        for (int i = 0; i < 40; i++) CFRelease(many[i]);
    }

    // Restart: a fresh copy of the driver with the same storage publishes the saved devices.
    SetDevices(again, 2);
    usleep(200000);
    gDriver = Load(argv[1], "junction-harness-2");
    CHECK((*gDriver)->Initialize(gDriver, &gHostInterface) == noErr, "second Initialize failed");
    CHECK(DeviceList(ids, 64) == 2, "restored driver should publish 2 devices, got %u", DeviceList(ids, 64));
    AudioObjectID restored = DeviceForUID("junction.test.stream");
    CHECK(restored != kAudioObjectUnknown && StringIs(restored, kAudioObjectPropertyName, "OBS Feed"),
          "restored device name");
    AudioStreamBasicDescription restoredChat = StreamFormat(Stream(DeviceForUID("junction.test.chat"), kAudioObjectPropertyScopeInput));
    CHECK(restoredChat.mChannelsPerFrame == 4, "restored chat device should have 4 channels");

    CFRelease(stream);
    CFRelease(chat);
    CFRelease(renamed);
    CFRelease(wider);
    if (gFailures) {
        fprintf(stderr, "Driver harness: %d failure(s)\n", gFailures);
        return 1;
    }
    printf("Driver harness: all checks passed\n");
    return 0;
}
