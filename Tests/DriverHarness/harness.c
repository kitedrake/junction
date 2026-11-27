// Loads a built JunctionDriver.driver into this process with a stand-in host (no coreaudiod, nothing installed)
// and checks what the HAL would see: the device list follows the app's configuration, names/formats/UIDs are
// right, changes are announced and saved, a fresh load restores the saved devices (also a list saved by driver
// 0.1), and audio written to a device's output comes back out of its input. Driver 0.2 adds volume and mute
// controls (with their ramp), directions and the hidden companion devices, channel names, icons, hidden devices
// and the shared clock. Per-app capture: each client's output lands in its own ring in the shared region, clients come
// and go, Junction's own processes aren't captured, and overruns are handled.
//
// Usage: harness <path to JunctionDriver.driver> [expected version]

#include <CoreAudio/AudioServerPlugIn.h>
#include <copyfile.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../../Sources/JunctionKernel/include/JunctionCaptureRing.h"

enum {
    kSelectorConfig = 'jcfg',
    kSelectorVersion = 'jver',
    kSelectorClients = 'jcli',
    kRingFrames = 16384,
    kZeroTimeStampPeriod = 16384,
    kRampFrames = 256,
};

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
static void *gImage;  // the loaded copy of the driver binary

/// Every announced property change, counted by selector.
enum { kMaxSelectors = 64 };
static pthread_mutex_t gSeenMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioObjectPropertySelector gSeenSelectors[kMaxSelectors];
static int gSeenCounts[kMaxSelectors], gSeenUsed;

static int Announced(AudioObjectPropertySelector selector) {
    int count = 0;
    pthread_mutex_lock(&gSeenMutex);
    for (int i = 0; i < gSeenUsed; i++) if (gSeenSelectors[i] == selector) count = gSeenCounts[i];
    pthread_mutex_unlock(&gSeenMutex);
    return count;
}

static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID objectID, UInt32 count,
                                      const AudioObjectPropertyAddress *addresses) {
    (void)host;
    for (UInt32 i = 0; i < count; i++) {
        if (objectID == kAudioObjectPlugInObject && addresses[i].mSelector == kAudioPlugInPropertyDeviceList)
            __sync_fetch_and_add(&gDeviceListChanges, 1);
        if (addresses[i].mSelector == kAudioObjectPropertyName) __sync_fetch_and_add(&gNameChanges, 1);
        pthread_mutex_lock(&gSeenMutex);
        int found = -1;
        for (int j = 0; j < gSeenUsed; j++) if (gSeenSelectors[j] == addresses[i].mSelector) found = j;
        if (found < 0 && gSeenUsed < kMaxSelectors) {
            found = gSeenUsed++;
            gSeenSelectors[found] = addresses[i].mSelector;
        }
        if (found >= 0) gSeenCounts[found]++;
        pthread_mutex_unlock(&gSeenMutex);
    }
    return noErr;
}

/// Waits until a selector has been announced more than `before` times; returns whether it was.
static bool WaitForAnnouncement(AudioObjectPropertySelector selector, int before) {
    for (int i = 0; i < 200 && Announced(selector) <= before; i++) usleep(10000);
    return Announced(selector) > before;
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
    // A real host stops IO, then performs the change. Counted once it is done, so waiting for the count waits for it.
    OSStatus status = (*gDriver)->PerformDeviceConfigurationChange(gDriver, deviceID, action, info);
    __sync_fetch_and_add(&gConfigRequests, 1);
    return status;
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
    gImage = image;
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

static OSStatus GetScalar(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope,
                          AudioObjectPropertyElement element, void *value, UInt32 size) {
    AudioObjectPropertyAddress address = {selector, scope, element};
    UInt32 used = 0;
    return (*gDriver)->GetPropertyData(gDriver, object, 0, &address, 0, NULL, size, &used, value);
}

static UInt32 U32(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    UInt32 value = 0xFFFFFFFF;
    GetScalar(object, selector, scope, kAudioObjectPropertyElementMain, &value, sizeof value);
    return value;
}

static Float32 F32(AudioObjectID object, AudioObjectPropertySelector selector) {
    Float32 value = NAN;
    GetScalar(object, selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, &value, sizeof value);
    return value;
}

static OSStatus SetValue(AudioObjectID object, AudioObjectPropertySelector selector, const void *value, UInt32 size) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    return (*gDriver)->SetPropertyData(gDriver, object, 0, &address, 0, NULL, size, value);
}

/// How many objects an ID-list property returns.
static UInt32 CountIDs(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = Address(selector, scope);
    UInt32 size = 0;
    if ((*gDriver)->GetPropertyDataSize(gDriver, object, 0, &address, 0, NULL, &size) != noErr) return 0;
    return size / sizeof(AudioObjectID);
}

/// The device's control of a class (volume or mute) in a scope, or kAudioObjectUnknown.
static AudioObjectID Control(AudioObjectID device, AudioClassID classID, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = Address(kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal);
    AudioObjectID ids[16];
    UInt32 size = 0;
    if ((*gDriver)->GetPropertyData(gDriver, device, 0, &address, 0, NULL, sizeof ids, &size, ids) != noErr) return 0;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        if (U32(ids[i], kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == classID &&
            U32(ids[i], kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal) == scope)
            return ids[i];
    }
    return kAudioObjectUnknown;
}

/// A channel's name as the device reports it ("" when it has none).
static bool ElementNameIs(AudioObjectID device, AudioObjectPropertyScope scope, UInt32 element, const char *expected) {
    CFStringRef value = NULL;
    OSStatus status = GetScalar(device, kAudioObjectPropertyElementName, scope, element, &value, sizeof value);
    if (status != noErr || !value) return expected[0] == 0;
    char buffer[256];
    CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    CFRelease(value);
    return strcmp(buffer, expected) == 0;
}

/// Adds keys to a device entry: pairs of a key (C string) and a CF value, ending with NULL.
static CFDictionaryRef WithKeys(CFDictionaryRef entry, ...) {
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, entry);
    va_list list;
    va_start(list, entry);
    for (const char *key = va_arg(list, const char *); key; key = va_arg(list, const char *)) {
        CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
        CFDictionarySetValue(copy, name, va_arg(list, CFTypeRef));
        CFRelease(name);
    }
    va_end(list);
    return copy;
}

static CFNumberRef Number(double value) { return CFNumberCreate(NULL, kCFNumberDoubleType, &value); }

/// One key of a device's entry in the configuration the driver reports, or NULL. Release the result.
static CFTypeRef CopyConfigValue(const char *uid, const char *key) {
    AudioObjectPropertyAddress address = Address(kSelectorConfig, kAudioObjectPropertyScopeGlobal);
    CFArrayRef config = NULL;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof config, &size, &config);
    CFTypeRef result = NULL;
    CFStringRef uidString = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    CFStringRef keyString = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    for (CFIndex i = 0; config && i < CFArrayGetCount(config); i++) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(config, i);
        if (!CFEqual(CFDictionaryGetValue(entry, CFSTR("uid")), uidString)) continue;
        result = CFDictionaryGetValue(entry, keyString);
        if (result) CFRetain(result);
    }
    CFRelease(uidString);
    CFRelease(keyString);
    if (config) CFRelease(config);
    return result;
}

static bool ConfigValueIs(const char *uid, const char *key, CFTypeRef expected) {
    CFTypeRef value = CopyConfigValue(uid, key);
    bool same = value && CFEqual(value, expected);
    if (value) CFRelease(value);
    return same;
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

/// Audio played into `writer` comes out of `reader` (the same device, or a device and its companion).
static void TestLoopbackThrough(AudioObjectID writer, AudioObjectID reader, UInt32 channels, Float64 at, UInt32 frames) {
    Float32 *written = malloc(sizeof(Float32) * frames * channels);
    Float32 *read = malloc(sizeof(Float32) * frames * channels);
    for (UInt32 i = 0; i < frames * channels; i++) written[i] = (Float32)((i * 7919) % 2001) / 1000.0f - 1.0f;
    CHECK(DoIO(writer, kAudioServerPlugInIOOperationWriteMix, at, written, frames) == noErr, "WriteMix failed");
    memset(read, 0xff, sizeof(Float32) * frames * channels);
    CHECK(DoIO(reader, kAudioServerPlugInIOOperationReadInput, at, read, frames) == noErr, "ReadInput failed");
    CHECK(memcmp(written, read, sizeof(Float32) * frames * channels) == 0, "loopback at %.0f returned different samples", at);
    DoIO(reader, kAudioServerPlugInIOOperationReadInput, at, read, frames);
    bool silent = true;
    for (UInt32 i = 0; i < frames * channels; i++) if (read[i] != 0) silent = false;
    CHECK(silent, "samples at %.0f were read twice (should be consumed)", at);
    free(written);
    free(read);
}

static void TestLoopback(AudioObjectID device, UInt32 channels, Float64 at, UInt32 frames) {
    TestLoopbackThrough(device, device, channels, at, frames);
}

/// Plays `frames` frames of full-scale 1.0 into a stereo device and records them back.
static void PlayOnes(AudioObjectID device, Float64 at, Float32 *read, UInt32 frames) {
    Float32 *ones = malloc(sizeof(Float32) * frames * 2);
    for (UInt32 i = 0; i < frames * 2; i++) ones[i] = 1;
    DoIO(device, kAudioServerPlugInIOOperationWriteMix, at, ones, frames);
    DoIO(device, kAudioServerPlugInIOOperationReadInput, at, read, frames);
    free(ones);
}

/// Checks a recorded ramp: it starts one step from `from`, moves monotonically and sits at `to` from kRampFrames on.
static void CheckRamp(const Float32 *read, UInt32 frames, Float32 from, Float32 to, const char *what) {
    float step = 1.0f / kRampFrames;
    float first = from + (to > from ? step : -step);
    if ((to > from && first > to) || (to < from && first < to)) first = to;
    CHECK(fabsf(read[0] - first) < 1e-5 && read[0] == read[1], "%s: first frame %f, expected %f", what, read[0], first);
    bool monotonic = true, settled = true;
    for (UInt32 f = 1; f < frames; f++) {
        float d = read[2 * f] - read[2 * (f - 1)];
        if ((to < from && d > 1e-6) || (to > from && d < -1e-6) || read[2 * f] != read[2 * f + 1]) monotonic = false;
        if (f >= kRampFrames && fabsf(read[2 * f] - to) > 1e-6) settled = false;
    }
    CHECK(monotonic, "%s: the ramp should move one way, on both channels alike", what);
    CHECK(settled, "%s: should sit at %f after %d frames", what, to, kRampFrames);
    if (fabsf(from - to) > 0.6f) CHECK(fabsf(read[kRampFrames] - to) > 0.1f, "%s: should still be ramping half way", what);
}

/// Volume and mute: controls per side, applied with a ramp, set from the HAL or the app, announced and saved.
static void TestVolumeAndMute(AudioObjectID device, CFDictionaryRef entry, CFDictionaryRef other) {
    AudioObjectID outVolume = Control(device, kAudioVolumeControlClassID, kAudioObjectPropertyScopeOutput);
    AudioObjectID outMute = Control(device, kAudioMuteControlClassID, kAudioObjectPropertyScopeOutput);
    AudioObjectID inVolume = Control(device, kAudioVolumeControlClassID, kAudioObjectPropertyScopeInput);
    AudioObjectID inMute = Control(device, kAudioMuteControlClassID, kAudioObjectPropertyScopeInput);
    CHECK(outVolume && outMute && inVolume && inMute, "a volume and a mute control for each side");
    CHECK(CountIDs(device, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal) == 4, "four controls");
    CHECK(U32(outVolume, kAudioObjectPropertyBaseClass, kAudioObjectPropertyScopeGlobal) == kAudioLevelControlClassID &&
              U32(outMute, kAudioObjectPropertyBaseClass, kAudioObjectPropertyScopeGlobal) == kAudioBooleanControlClassID &&
              U32(outVolume, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal) == device,
          "control classes and owner");
    CHECK(CountIDs(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal) == 6,
          "the device owns two streams and four controls");
    CHECK(F32(outVolume, kAudioLevelControlPropertyScalarValue) == 1 && F32(outVolume, kAudioLevelControlPropertyDecibelValue) == 0,
          "volume starts at full");
    CHECK(U32(outMute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal) == 0, "starts unmuted");
    {
        AudioObjectPropertyAddress address = Address(kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
        Boolean settable = false;
        (*gDriver)->IsPropertySettable(gDriver, outVolume, 0, &address, &settable);
        CHECK(settable, "volume is settable");
        Float32 value = 0.5f;
        CHECK(GetScalar(outVolume, kAudioLevelControlPropertyConvertScalarToDecibels, kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain, &value, sizeof value) == noErr && value == -32,
              "scalar 0.5 is -32 dB, got %f", value);
    }

    enum { kFrames = 1024 };
    Float32 read[kFrames * 2];
    CHECK((*gDriver)->StartIO(gDriver, device, 1) == noErr, "StartIO for volume");
    PlayOnes(device, 2000, read, kFrames);
    CHECK(read[0] == 1 && read[2 * kFrames - 1] == 1, "full volume passes audio unchanged");

    // From the HAL (Sound settings, volume keys): applied with a ramp, announced, saved where the app reads it.
    int scalarNotes = Announced(kAudioLevelControlPropertyScalarValue), configNotes = Announced(kSelectorConfig);
    int writes = gStorageWrites;
    Float32 half = 0.5f;
    CHECK(SetValue(outVolume, kAudioLevelControlPropertyScalarValue, &half, sizeof half) == noErr, "set volume");
    Float32 gain = powf(10, -32 / 20.0f);
    PlayOnes(device, 4000, read, kFrames);
    CheckRamp(read, kFrames, 1, gain, "volume down");
    CHECK(F32(outVolume, kAudioLevelControlPropertyDecibelValue) == -32, "volume reads back in dB");
    CHECK(WaitForAnnouncement(kAudioLevelControlPropertyScalarValue, scalarNotes), "volume change announced");
    CHECK(WaitForAnnouncement(kSelectorConfig, configNotes), "configuration change announced to the app");
    WaitFor(&gStorageWrites, writes + 1);
    CHECK(gStorageWrites > writes, "volume saved");
    CFNumberRef halfNumber = Number(0.5);
    CHECK(ConfigValueIs("junction.test.stream", "outputVolume", halfNumber), "the configuration reports the new volume");
    CFRelease(halfNumber);

    // Mute from the HAL: down to silence.
    int muteNotes = Announced(kAudioBooleanControlPropertyValue);
    UInt32 on = 1;
    CHECK(SetValue(outMute, kAudioBooleanControlPropertyValue, &on, sizeof on) == noErr, "set mute");
    PlayOnes(device, 6000, read, kFrames);
    CheckRamp(read, kFrames, gain, 0, "mute");
    CHECK(WaitForAnnouncement(kAudioBooleanControlPropertyValue, muteNotes), "mute announced");
    CHECK(ConfigValueIs("junction.test.stream", "outputMute", kCFBooleanTrue), "the configuration reports the mute");

    // From the app: full volume, unmuted, through the configuration; the input side muted.
    scalarNotes = Announced(kAudioLevelControlPropertyScalarValue);
    muteNotes = Announced(kAudioBooleanControlPropertyValue);
    CFNumberRef full = Number(1);
    CFDictionaryRef loud = WithKeys(entry, "outputVolume", full, "outputMute", kCFBooleanFalse, NULL);
    CFDictionaryRef list[] = {loud, other};
    CHECK(SetDevices(list, 2) == noErr, "volume from the app");
    PlayOnes(device, 8000, read, kFrames);
    CheckRamp(read, kFrames, 0, 1, "unmute");
    CHECK(F32(outVolume, kAudioLevelControlPropertyScalarValue) == 1 &&
              U32(outMute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal) == 0,
          "controls follow the app's values");
    CHECK(WaitForAnnouncement(kAudioLevelControlPropertyScalarValue, scalarNotes), "the app's volume is announced");
    CHECK(WaitForAnnouncement(kAudioBooleanControlPropertyValue, muteNotes), "the app's mute is announced");
    CFDictionaryRef quiet = WithKeys(loud, "inputMute", kCFBooleanTrue, NULL);
    CFDictionaryRef list2[] = {quiet, other};
    SetDevices(list2, 2);
    CHECK(U32(inMute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal) == 1, "input mute set");
    PlayOnes(device, 10000, read, kFrames);
    CheckRamp(read, kFrames, 1, 0, "input mute");
    // Back to normal for the tests after this one.
    SetDevices(list, 2);
    PlayOnes(device, 12000, read, kFrames);
    CHECK(read[2 * kFrames - 1] == 1, "input unmuted again");
    CHECK((*gDriver)->StopIO(gDriver, device, 1) == noErr, "StopIO after volume");
    CFRelease(full);
    CFRelease(loud);
    CFRelease(quiet);
}

/// Channel names, icon and hidden: through the configuration, announced, saved.
static void TestDeviceOptions(AudioObjectID device, CFDictionaryRef entry, CFDictionaryRef other, const char *bundle) {
    CHECK(ElementNameIs(device, kAudioObjectPropertyScopeOutput, 1, ""), "no channel names by default");
    {
        CFURLRef url = NULL;
        CHECK(GetScalar(device, kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                        &url, sizeof url) == noErr && url, "icon property");
        CFStringRef file = url ? CFURLCopyLastPathComponent(url) : NULL;
        CHECK(file && CFEqual(file, CFSTR("junction.icns")), "the default icon is junction.icns");
        if (file) CFRelease(file);
        if (url) CFRelease(url);
    }
    CHECK(U32(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "visible by default");

    int names = Announced(kAudioObjectPropertyElementName), icons = Announced(kAudioDevicePropertyIcon);
    int hidden = Announced(kAudioDevicePropertyIsHidden), lists = gDeviceListChanges, writes = gStorageWrites;
    const void *labels[] = {CFSTR("Voice"), CFSTR("Music")};
    CFArrayRef channelNames = CFArrayCreate(NULL, labels, 2, &kCFTypeArrayCallBacks);
    CFDictionaryRef dressed = WithKeys(entry, "channelNames", channelNames, "icon", CFSTR("microphone"), "hidden",
                                       kCFBooleanTrue, NULL);
    CFDictionaryRef list[] = {dressed, other};
    CHECK(SetDevices(list, 2) == noErr, "names, icon and hidden");
    CHECK(ElementNameIs(device, kAudioObjectPropertyScopeOutput, 1, "Voice") &&
              ElementNameIs(device, kAudioObjectPropertyScopeInput, 2, "Music"),
          "channel names per element, on both sides");
    CHECK(ElementNameIs(device, kAudioObjectPropertyScopeInput, 3, "") &&
              ElementNameIs(device, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain, ""),
          "no name past the last channel or for the main element");
    {
        CFURLRef url = NULL;
        GetScalar(device, kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, &url,
                  sizeof url);
        CFStringRef file = url ? CFURLCopyLastPathComponent(url) : NULL;
        CHECK(file && CFEqual(file, CFSTR("microphone.icns")), "the icon follows the configuration");
        if (file) CFRelease(file);
        if (url) CFRelease(url);
    }
    const char *bundled[] = {"junction", "microphone", "speaker", "headphones", "stream"};
    for (int i = 0; i < 5; i++) {
        char path[2048];
        struct stat info;
        snprintf(path, sizeof path, "%s/Contents/Resources/%s.icns", bundle, bundled[i]);
        CHECK(stat(path, &info) == 0 && info.st_size > 0, "the driver bundle has %s.icns", bundled[i]);
    }
    CHECK(U32(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1, "hidden");
    CHECK(U32(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0,
          "a hidden device can't be the default");
    CHECK(DeviceForUID("junction.test.stream") == device, "a hidden device is still found by its UID");
    CHECK(WaitForAnnouncement(kAudioObjectPropertyElementName, names), "channel names announced");
    CHECK(WaitForAnnouncement(kAudioDevicePropertyIcon, icons), "icon announced");
    CHECK(WaitForAnnouncement(kAudioDevicePropertyIsHidden, hidden), "hidden announced");
    WaitFor(&gDeviceListChanges, lists + 1);
    CHECK(gDeviceListChanges > lists, "hiding a device announces the device list");
    WaitFor(&gStorageWrites, writes + 1);
    CFArrayRef stored = CFDictionaryGetValue(gStorage, CFSTR("devices"));
    bool saved = false;
    for (CFIndex i = 0; stored && i < CFArrayGetCount(stored); i++) {
        CFDictionaryRef e = CFArrayGetValueAtIndex(stored, i);
        if (CFEqual(CFDictionaryGetValue(e, CFSTR("uid")), CFSTR("junction.test.stream")))
            saved = CFEqual(CFDictionaryGetValue(e, CFSTR("channelNames")), channelNames) &&
                    CFEqual(CFDictionaryGetValue(e, CFSTR("icon")), CFSTR("microphone")) &&
                    CFDictionaryGetValue(e, CFSTR("hidden")) == kCFBooleanTrue;
    }
    CHECK(saved, "names, icon and hidden are saved");

    // An unknown icon falls back to the default.
    CFDictionaryRef odd = WithKeys(entry, "icon", CFSTR("no-such-icon"), NULL);
    CFDictionaryRef list2[] = {odd, other};
    SetDevices(list2, 2);
    CHECK(ConfigValueIs("junction.test.stream", "icon", CFSTR("junction")), "an unknown icon becomes the default");
    CFDictionaryRef plain[] = {entry, other};
    SetDevices(plain, 2);
    CHECK(U32(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "visible again");
    CFRelease(channelNames);
    CFRelease(dressed);
    CFRelease(odd);
}

/// Directions: the device shows apps one side or both; the other side belongs to a hidden companion Junction uses.
static void TestDirections(AudioObjectID device, CFDictionaryRef entry, CFDictionaryRef other, UInt32 channels) {
    struct { const char *direction; UInt32 inputs, outputs; } cases[] = {{"input", 1, 0}, {"output", 0, 1}, {"both", 1, 1}};
    AudioObjectID ids[64];
    for (int c = 0; c < 3; c++) {
        int requests = gConfigRequests;
        CFStringRef direction = CFStringCreateWithCString(NULL, cases[c].direction, kCFStringEncodingUTF8);
        CFDictionaryRef changed = WithKeys(entry, "direction", direction, NULL);
        CFDictionaryRef list[] = {other, changed};
        CHECK(SetDevices(list, 2) == noErr, "direction %s", cases[c].direction);
        WaitFor(&gConfigRequests, requests + 1);
        CHECK(gConfigRequests > requests && gRequestedDevice == device, "a direction change goes through the host");
        CHECK(DeviceForUID("junction.test.chat") == device, "the device keeps its object ID (%s)", cases[c].direction);
        CHECK(StringIs(device, kAudioDevicePropertyDeviceUID, "junction.test.chat"), "the UID stays (%s)", cases[c].direction);
        UInt32 inputs = CountIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
        UInt32 outputs = CountIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
        CHECK(inputs == cases[c].inputs && outputs == cases[c].outputs, "%s: %u input and %u output streams",
              cases[c].direction, inputs, outputs);
        CHECK(CountIDs(device, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal) == 2 * (inputs + outputs),
              "%s: controls only for the sides apps see", cases[c].direction);
        CHECK(U32(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == inputs &&
                  U32(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == outputs,
              "%s: default device only for its sides", cases[c].direction);
        CHECK(ConfigValueIs("junction.test.chat", "direction", direction), "the configuration reports %s", cases[c].direction);
        AudioObjectID companion = DeviceForUID("junction.test.chat.routing");
        bool hasCompanion = inputs + outputs < 2;
        CHECK((companion != kAudioObjectUnknown) == hasCompanion, "%s: companion %s", cases[c].direction,
              hasCompanion ? "missing" : "should be gone");
        CHECK(DeviceList(ids, 64) == (hasCompanion ? 3u : 2u), "%s: the device list has the companion", cases[c].direction);
        if (companion != kAudioObjectUnknown) {
            CHECK(U32(companion, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1, "the companion is hidden");
            CHECK(U32(companion, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeGlobal) == 0,
                  "the companion can't be a default device");
            UInt32 companionInputs = CountIDs(companion, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
            UInt32 companionOutputs = CountIDs(companion, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
            CHECK(companionInputs == 1 - inputs && companionOutputs == 1 - outputs, "the companion has the other side");
            AudioObjectID stream = Stream(companion, inputs ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput);
            CHECK(U32(stream, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal) == companion,
                  "the companion owns its stream");
            CHECK(StreamFormat(stream).mChannelsPerFrame == channels, "the companion's stream has the device's channels");
            // Junction plays into the companion and apps record the device, or the other way round.
            CHECK((*gDriver)->StartIO(gDriver, device, 1) == noErr && (*gDriver)->StartIO(gDriver, companion, 2) == noErr,
                  "StartIO on a device and its companion");
            if (inputs) TestLoopbackThrough(companion, device, channels, 3000, 512);
            else TestLoopbackThrough(device, companion, channels, 3000, 512);
            (*gDriver)->StopIO(gDriver, companion, 2);
            (*gDriver)->StopIO(gDriver, device, 1);
        }
        CFRelease(direction);
        CFRelease(changed);
    }
}

typedef struct {
    Float64 sample;
    UInt64 host;
} Stamp;

static Stamp ZeroStamp(AudioObjectID device) {
    Stamp stamp = {0, 0};
    UInt64 seed = 0;
    (*gDriver)->GetZeroTimeStamp(gDriver, device, 1, &stamp.sample, &stamp.host, &seed);
    return stamp;
}

/// Over `seconds`, the two devices report the same zero time stamps (checked between two identical readings of
/// `a`, so a period boundary between the calls doesn't count). Returns how many periods `a` moved on.
static double CompareStamps(AudioObjectID a, AudioObjectID b, double seconds, const char *what) {
    Stamp first = ZeroStamp(a), last = first;
    int compared = 0, mismatches = 0;
    for (int i = 0; i < (int)(seconds * 1000); i++) {
        Stamp a1 = ZeroStamp(a), stamp = ZeroStamp(b), a2 = ZeroStamp(a);
        if (a1.sample == a2.sample && a1.host == a2.host) {
            compared++;
            if (stamp.sample != a1.sample || stamp.host != a1.host) mismatches++;
        }
        last = a2;
        usleep(1000);
    }
    CHECK(compared > 0 && mismatches == 0, "%s: %d of %d zero time stamps differ", what, mismatches, compared);
    return (last.sample - first.sample) / kZeroTimeStampPeriod;
}

/// One clock: every device reports the same clock domain and counts periods from the same anchor, also a device
/// added later and one that was reformatted.
static void TestSharedClock(void) {
    CFDictionaryRef a = DeviceEntry("junction.test.clock.a", "Clock A", 2, 192000);
    CFDictionaryRef b = DeviceEntry("junction.test.clock.b", "Clock B", 2, 192000);
    CFDictionaryRef late = DeviceEntry("junction.test.clock.c", "Clock C", 2, 192000);
    CFDictionaryRef two[] = {a, b};
    SetDevices(two, 2);
    AudioObjectID deviceA = DeviceForUID("junction.test.clock.a"), deviceB = DeviceForUID("junction.test.clock.b");
    UInt32 domain = U32(deviceA, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal);
    CHECK(domain != 0 && domain != 0xFFFFFFFF, "the clock domain is set");
    CHECK(U32(deviceB, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal) == domain, "one clock domain");
    CHECK((*gDriver)->StartIO(gDriver, deviceA, 1) == noErr && (*gDriver)->StartIO(gDriver, deviceB, 1) == noErr,
          "StartIO for the clock test");
    double periods = CompareStamps(deviceA, deviceB, 1.6, "two devices");
    CHECK(periods >= 10, "the clock test should span many periods, spanned %.0f", periods);

    // Added later: its IO starts well after the others', on the same time line.
    CFDictionaryRef three[] = {a, b, late};
    SetDevices(three, 3);
    AudioObjectID deviceC = DeviceForUID("junction.test.clock.c");
    CHECK(U32(deviceC, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal) == domain, "a later device shares it");
    CHECK((*gDriver)->StartIO(gDriver, deviceC, 1) == noErr, "StartIO for the later device");
    CompareStamps(deviceA, deviceC, 0.5, "a device added later");

    // Reformatted to half the rate: half the frames per host tick, from the same anchor; then back.
    int requests = gConfigRequests;
    CFDictionaryRef slower = DeviceEntry("junction.test.clock.b", "Clock B", 2, 96000);
    CFDictionaryRef reformatted[] = {a, slower, late};
    SetDevices(reformatted, 3);
    WaitFor(&gConfigRequests, requests + 1);
    int consistent = 0, checked = 0;
    for (int i = 0; i < 300; i++) {
        Stamp a1 = ZeroStamp(deviceA), stamp = ZeroStamp(deviceB), a2 = ZeroStamp(deviceA);
        if (a1.sample != a2.sample) continue;
        checked++;
        double difference = a1.sample - 2 * stamp.sample;  // A counts two periods for each of B's
        if ((difference == 0 && stamp.host == a1.host) || (difference == kZeroTimeStampPeriod && stamp.host < a1.host))
            consistent++;
        usleep(1000);
    }
    CHECK(checked > 0 && consistent == checked, "a device at half the rate stays on the shared time line (%d of %d)",
          consistent, checked);
    requests = gConfigRequests;
    SetDevices(three, 3);
    WaitFor(&gConfigRequests, requests + 1);
    CompareStamps(deviceA, deviceB, 0.5, "a device reformatted and back");
    for (AudioObjectID device = deviceA; device; device = device == deviceA ? deviceB : device == deviceB ? deviceC : 0)
        (*gDriver)->StopIO(gDriver, device, 1);
    CFRelease(a);
    CFRelease(b);
    CFRelease(late);
    CFRelease(slower);
}

#pragma mark - Per-app capture

static OSStatus DoClientIO(AudioObjectID device, UInt32 client, UInt32 operation, Float64 sampleTime, Float32 *buffer,
                           UInt32 frames) {
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof cycle);
    cycle.mNominalIOBufferFrameSize = frames;
    cycle.mInputTime.mSampleTime = sampleTime;
    cycle.mOutputTime.mSampleTime = sampleTime;
    return (*gDriver)->DoIOOperation(gDriver, device, Stream(device, kAudioObjectPropertyScopeOutput), client, operation,
                                     frames, &cycle, buffer, NULL);
}

static OSStatus AddClient(AudioObjectID device, UInt32 client, pid_t pid, const char *bundleID) {
    AudioServerPlugInClientInfo info = {client, pid, true, NULL};
    if (bundleID) info.mBundleID = CFStringCreateWithCString(NULL, bundleID, kCFStringEncodingUTF8);
    OSStatus status = (*gDriver)->AddDeviceClient(gDriver, device, &info);
    if (info.mBundleID) CFRelease(info.mBundleID);
    return status;
}

static OSStatus RemoveClient(AudioObjectID device, UInt32 client, pid_t pid) {
    AudioServerPlugInClientInfo info = {client, pid, true, NULL};
    return (*gDriver)->RemoveDeviceClient(gDriver, device, &info);
}

/// Each test client plays its own signal: a value for every sample time and channel, never zero, and different
/// for every client (`which`), so a ring holding anyone else's audio shows.
static Float32 Signal(int which, UInt64 time, UInt32 channel) {
    return (Float32)which * 2.0f + 0.001f + (Float32)((time * 31 + channel * 7) % 1000) / 1000.0f;
}

static void Play(AudioObjectID device, UInt32 client, int which, UInt64 time, UInt32 frames, UInt32 channels) {
    Float32 *buffer = malloc(sizeof(Float32) * frames * channels);
    for (UInt32 f = 0; f < frames; f++)
        for (UInt32 c = 0; c < channels; c++) buffer[f * channels + c] = Signal(which, time + f, c);
    CHECK(DoClientIO(device, client, kAudioServerPlugInIOOperationProcessOutput, (Float64)time, buffer, frames) == noErr,
          "ProcessOutput failed");
    free(buffer);
}

/// The slot whose client has this bundle ID, or JCAP_SLOTS.
static UInt32 SlotOf(void *region, const char *bundleID, JCapClient *client) {
    for (UInt32 i = 0; i < JCAP_SLOTS; i++) {
        if (jcap_client(region, i, client) && client->live && strcmp(client->bundleID, bundleID) == 0) return i;
    }
    return JCAP_SLOTS;
}

/// Frames [time, time + frames) of a slot hold exactly client `which`'s signal.
static bool RingHolds(void *region, UInt32 slot, UInt32 sequence, int which, UInt64 time, UInt32 frames, UInt32 channels) {
    Float32 *read = malloc(sizeof(Float32) * frames * channels);
    int64_t lost = jcap_read(region, slot, sequence, time, frames, read, channels);
    bool same = lost == 0;
    for (UInt32 f = 0; same && f < frames; f++)
        for (UInt32 c = 0; c < channels; c++) same = same && read[f * channels + c] == Signal(which, time + f, c);
    free(read);
    return same;
}

static int CountClients(void) {
    AudioObjectPropertyAddress address = Address(kSelectorClients, kAudioObjectPropertyScopeGlobal);
    CFArrayRef list = NULL;
    UInt32 size = 0;
    (*gDriver)->GetPropertyData(gDriver, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof list, &size, &list);
    int count = list ? (int)CFArrayGetCount(list) : -1;
    if (list) CFRelease(list);
    return count;
}

typedef struct {
    AudioObjectID device;
    volatile int stop;
    UInt64 time;
} Writer;

static void *WriteContinuously(void *argument) {
    Writer *writer = argument;
    Float32 buffer[256 * 2];
    while (!writer->stop) {
        for (UInt32 f = 0; f < 256; f++)
            for (UInt32 c = 0; c < 2; c++) buffer[f * 2 + c] = Signal(2, writer->time + f, c);
        DoClientIO(writer->device, 8, kAudioServerPlugInIOOperationProcessOutput, (Float64)writer->time, buffer, 256);
        __atomic_store_n(&writer->time, writer->time + 256, __ATOMIC_RELEASE);
    }
    return NULL;
}

static void TestPerAppCapture(void) {
    CFDictionaryRef entry = DeviceEntry("junction.test.capture", "Capture", 2, 48000);
    CHECK(SetDevices(&entry, 1) == noErr, "a device to capture from");
    CFRelease(entry);
    AudioObjectID device = DeviceForUID("junction.test.capture");
    typedef void *(*RegionFunction)(UInt64 *);
    RegionFunction regionFunction = (RegionFunction)dlsym(gImage, "JunctionDriver_CaptureRegion");
    UInt64 size = 0;
    void *region = regionFunction ? regionFunction(&size) : NULL;
    CHECK(region && jcap_valid(region, size), "the driver has a valid capture region");
    if (!region || !jcap_valid(region, size)) return;
    UInt32 channels = StreamFormat(Stream(device, kAudioObjectPropertyScopeOutput)).mChannelsPerFrame;
    CHECK(channels == 2, "the capture test device has 2 channels");

    int clientNotes = Announced(kSelectorClients);
    CHECK(AddClient(device, 7, 1001, "com.example.music") == noErr, "add a client");
    CHECK(AddClient(device, 8, 1002, "com.example.call") == noErr, "add a second client");
    CHECK(AddClient(device, 9, 1003, "com.kitedrake.junction.helper") == noErr, "add Junction's own client");
    CHECK(AddClient(device, 13, 1007, "com.kitedrake.junction") == noErr, "add Junction itself as a client");
    CHECK(AddClient(device, 14, 1008, "com.kitedrake.junctionist") == noErr, "add a client whose ID only starts alike");
    CHECK(AddClient(device, 10, 1004, NULL) == noErr, "add a client without a bundle ID");
    CHECK(WaitForAnnouncement(kSelectorClients, clientNotes), "new clients are announced");
    CHECK(CountClients() == 3, "three clients captured (not Junction's own, not one without a bundle ID), got %d",
          CountClients());
    JCapClient music, call, own;
    UInt32 musicSlot = SlotOf(region, "com.example.music", &music);
    UInt32 callSlot = SlotOf(region, "com.example.call", &call);
    CHECK(musicSlot < JCAP_SLOTS && callSlot < JCAP_SLOTS && musicSlot != callSlot, "each client has its own slot");
    CHECK(SlotOf(region, "com.kitedrake.junction.helper", &own) == JCAP_SLOTS
          && SlotOf(region, "com.kitedrake.junction", &own) == JCAP_SLOTS, "Junction's own processes aren't captured");
    CHECK(SlotOf(region, "com.kitedrake.junctionist", &own) < JCAP_SLOTS, "an app whose ID only starts alike is captured");
    RemoveClient(device, 13, 1007);
    CHECK(RemoveClient(device, 14, 1008) == noErr && CountClients() == 2, "back to two captured clients, got %d",
          CountClients());
    CHECK(music.pid == 1001 && strcmp(music.deviceUID, "junction.test.capture") == 0 && music.channels == 2,
          "a slot names its client's pid, device and channels");

    CHECK((*gDriver)->StartIO(gDriver, device, 1) == noErr, "StartIO for capture");
    Boolean willDo = false, inPlace = false;
    (*gDriver)->WillDoIOOperation(gDriver, device, 7, kAudioServerPlugInIOOperationProcessOutput, &willDo, &inPlace);
    CHECK(willDo, "the driver processes each client's output");

    // Two clients play different signals in the same IO cycles, then the mix is written: each ring carries only
    // its own client.
    UInt64 start = 3 * kRingFrames + 100;
    for (UInt64 t = start; t < start + 8 * 512; t += 512) {
        Play(device, 7, 1, t, 512, 2);
        Play(device, 8, 2, t, 512, 2);
        Play(device, 9, 3, t, 512, 2);
        Float32 mix[512 * 2] = {0};
        DoClientIO(device, 1, kAudioServerPlugInIOOperationWriteMix, (Float64)t, mix, 512);
    }
    UInt64 end = start + 8 * 512;
    CHECK(RingHolds(region, musicSlot, music.sequence, 1, start, (UInt32)(end - start), 2), "the first ring holds only its client");
    CHECK(RingHolds(region, callSlot, call.sequence, 2, start, (UInt32)(end - start), 2), "the second ring holds only its client");
    {
        Float32 read[64 * 2];
        jcap_read(region, musicSlot, music.sequence, end, 64, read, 2);
        bool silent = true;
        for (int i = 0; i < 128; i++) silent = silent && read[i] == 0;
        CHECK(silent, "frames not written yet read as silence");
        jcap_read(region, musicSlot, music.sequence, start - 64, 64, read, 2);
        silent = true;
        for (int i = 0; i < 128; i++) silent = silent && read[i] == 0;
        CHECK(silent, "frames from before the client started read as silence");
    }

    // A pause: the gap reads as silence, not as an old lap of the ring.
    UInt64 resume = end + 300;
    Play(device, 8, 2, resume, 512, 2);
    {
        Float32 read[300 * 2];
        jcap_read(region, callSlot, call.sequence, end, 300, read, 2);
        bool silent = true;
        for (int i = 0; i < 600; i++) silent = silent && read[i] == 0;
        CHECK(silent, "a pause between cycles reads as silence");
        CHECK(RingHolds(region, callSlot, call.sequence, 2, resume, 512, 2), "audio after a pause is kept");
    }

    // Overrun: a cycle longer than the ring keeps its end; frames the writer has gone past read as silence.
    UInt64 longStart = resume + 512;
    UInt32 longFrames = JCAP_FRAMES + 1000;
    Play(device, 7, 1, longStart, longFrames, 2);
    UInt64 longEnd = longStart + longFrames;
    CHECK(jcap_client(region, musicSlot, &music) && music.overruns == 1, "an overlong cycle is counted as an overrun");
    CHECK(RingHolds(region, musicSlot, music.sequence, 1, longEnd - JCAP_FRAMES, JCAP_FRAMES, 2),
          "an overlong cycle keeps its last %d frames", JCAP_FRAMES);
    {
        Float32 *read = malloc(sizeof(Float32) * 200 * 2);
        int64_t lost = jcap_read(region, musicSlot, music.sequence, longEnd - JCAP_FRAMES - 100, 200, read, 2);
        bool ok = read[0] == 0 && read[199] == 0 && read[200] == Signal(1, longEnd - JCAP_FRAMES, 0);
        CHECK(lost == 0 && ok, "a reader that fell behind the ring gets silence for what was overwritten");
        free(read);
    }

    // A reader racing the writer never sees a mix of two laps: every frame is the right sample or silence.
    {
        Writer writer = {device, 0, longEnd + 10 * JCAP_FRAMES};
        pthread_t thread;
        pthread_create(&thread, NULL, WriteContinuously, &writer);
        int torn = 0, reads = 0, adds = 0;
        Float32 *read = malloc(sizeof(Float32) * 1024 * 2);
        for (int i = 0; i < 4000; i++) {
            UInt64 now = __atomic_load_n(&writer.time, __ATOMIC_ACQUIRE);
            // Sometimes far behind (being overwritten right now), sometimes recent.
            UInt64 at = now > JCAP_FRAMES ? now - (i % 2 ? JCAP_FRAMES - 64 : 700) : now;
            jcap_read(region, callSlot, call.sequence, at, 1024, read, 2);
            for (UInt32 f = 0; f < 1024; f++)
                for (UInt32 c = 0; c < 2; c++) {
                    Float32 v = read[f * 2 + c];
                    if (v != 0 && v != Signal(2, at + f, c)) torn++;
                }
            reads++;
            if (i % 400 == 0) {  // other clients come and go meanwhile
                AddClient(device, 20, 2000, "com.example.other");
                RemoveClient(device, 20, 2000);
                adds++;
            }
        }
        writer.stop = 1;
        pthread_join(thread, NULL);
        free(read);
        CHECK(torn == 0, "%d samples read from a ring being written were neither right nor silent", torn);
        CHECK(reads > 0 && adds > 0, "the race ran");
    }

    // Clients come and go: a client that leaves frees its slot, readers see it's gone, and a new client's ring
    // carries only its own audio.
    clientNotes = Announced(kSelectorClients);
    CHECK(RemoveClient(device, 7, 1001) == noErr, "remove a client");
    CHECK(WaitForAnnouncement(kSelectorClients, clientNotes), "a client leaving is announced");
    CHECK(CountClients() == 1, "one client left");
    Float32 scratch[16 * 2];
    CHECK(jcap_read(region, musicSlot, music.sequence, longEnd - 16, 16, scratch, 2) == JCAP_READ_GONE,
          "a reader of a client that left is told so");
    Play(device, 7, 1, longEnd + 20 * JCAP_FRAMES, 64, 2);  // a client that left isn't captured any more
    CHECK(AddClient(device, 11, 1005, "com.example.game") == noErr, "add a third client");
    JCapClient game;
    UInt32 gameSlot = SlotOf(region, "com.example.game", &game);
    CHECK(gameSlot < JCAP_SLOTS && (gameSlot != musicSlot || game.sequence != music.sequence),
          "the new client gets a slot of its own (or the old one under a new sequence)");
    UInt64 later = longEnd + 30 * JCAP_FRAMES;
    Play(device, 11, 4, later, 512, 2);
    Play(device, 8, 2, later, 512, 2);
    CHECK(RingHolds(region, gameSlot, game.sequence, 4, later, 512, 2), "the new client's ring holds only its audio");
    CHECK(RingHolds(region, callSlot, call.sequence, 2, later, 512, 2), "the remaining client is unaffected");
    CHECK(CountClients() == 2, "two clients again");

    // More clients than slots: the extra ones aren't captured.
    for (UInt32 i = 0; i < JCAP_SLOTS + 4; i++) {
        char bundle[64];
        snprintf(bundle, sizeof bundle, "com.example.many%u", i);
        AddClient(device, 100 + i, (pid_t)(3000 + i), bundle);
    }
    CHECK(CountClients() == JCAP_SLOTS, "at most %d clients captured, got %d", JCAP_SLOTS, CountClients());
    for (UInt32 i = 0; i < JCAP_SLOTS + 4; i++) RemoveClient(device, 100 + i, (pid_t)(3000 + i));
    RemoveClient(device, 8, 1002);
    RemoveClient(device, 9, 1003);
    RemoveClient(device, 10, 1004);
    RemoveClient(device, 11, 1005);
    CHECK(CountClients() == 0, "every client gone");
    (*gDriver)->StopIO(gDriver, device, 1);
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
        CHECK(size == 3 * sizeof info[0] && info[0].mSelector == kSelectorConfig &&
                  info[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList &&
                  info[2].mSelector == kSelectorClients &&
                  info[2].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
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


    // Driver 0.2: volume and mute, channel names, icon and hidden, directions, the shared clock.
    TestVolumeAndMute(restored, renamed, wider);
    TestDeviceOptions(restored, renamed, wider, argv[1]);
    TestDirections(DeviceForUID("junction.test.chat"), wider, renamed, 4);
    TestSharedClock();
    TestPerAppCapture();

    // A list saved by driver 0.1 (uid, name, channels and sample rate only) still loads; the rest takes defaults.
    {
        CFDictionaryRef saved[] = {stream, chat};
        CFArrayRef old = CFArrayCreate(NULL, (const void **)saved, 2, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(gStorage, CFSTR("devices"), old);
        CFRelease(old);
        gDriver = Load(argv[1], "junction-harness-3");
        CHECK((*gDriver)->Initialize(gDriver, &gHostInterface) == noErr, "Initialize with a 0.1 list failed");
        CHECK(DeviceList(ids, 64) == 2, "a 0.1 list publishes its 2 devices, got %u", DeviceList(ids, 64));
        AudioObjectID device = DeviceForUID("junction.test.chat");
        CHECK(StringIs(device, kAudioObjectPropertyName, "Chat") &&
                  StreamFormat(Stream(device, kAudioObjectPropertyScopeInput)).mChannelsPerFrame == 8,
              "a 0.1 device keeps its name and format");
        CHECK(CountIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) == 1 &&
                  CountIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) == 1,
              "a 0.1 device has both sides");
        AudioObjectID volume = Control(device, kAudioVolumeControlClassID, kAudioObjectPropertyScopeOutput);
        AudioObjectID mute = Control(device, kAudioMuteControlClassID, kAudioObjectPropertyScopeInput);
        CHECK(volume && F32(volume, kAudioLevelControlPropertyScalarValue) == 1 &&
                  U32(mute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal) == 0,
              "a 0.1 device is at full volume, unmuted");
        CHECK(U32(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "a 0.1 device is visible");
        CHECK(ElementNameIs(device, kAudioObjectPropertyScopeOutput, 1, ""), "a 0.1 device has no channel names");
        CHECK(DeviceForUID("junction.test.chat.routing") == kAudioObjectUnknown, "a 0.1 device has no companion");
        CFNumberRef one = Number(1);
        CFArrayRef none = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        CHECK(ConfigValueIs("junction.test.chat", "direction", CFSTR("both")) &&
                  ConfigValueIs("junction.test.chat", "icon", CFSTR("junction")) &&
                  ConfigValueIs("junction.test.chat", "hidden", kCFBooleanFalse) &&
                  ConfigValueIs("junction.test.chat", "outputVolume", one) &&
                  ConfigValueIs("junction.test.chat", "inputMute", kCFBooleanFalse) &&
                  ConfigValueIs("junction.test.chat", "channelNames", none),
              "the configuration reports the defaults for a 0.1 device");
        CFRelease(one);
        CFRelease(none);
        CHECK((*gDriver)->StartIO(gDriver, device, 1) == noErr, "StartIO on a 0.1 device");
        TestLoopback(device, 8, 777, 256);
        (*gDriver)->StopIO(gDriver, device, 1);
    }

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
