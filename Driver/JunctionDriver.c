// JunctionDriver: Junction's virtual audio devices.
//
// An AudioServerPlugIn (a Core Audio HAL plug-in, loaded by coreaudiod from /Library/Audio/Plug-Ins/HAL)
// that publishes up to kMaxDevices loopback devices. Which devices exist, and their names, channel counts and
// sample rates, is set by the Junction app through a custom property on the plug-in object ('jcfg': an array of
// dictionaries, see ParseConfig). The driver saves that list in the host's storage, so the devices come back
// after a restart even when the app is not running.
//
// Every device is a loopback: what is played to its output side comes out of its input side. Junction's router
// plays its mixes into the output side; apps such as OBS or Discord record from the input side. Apps can also
// play into a device (pick it as their output) and Junction can pick that audio up from the input side.
//
// Threading: gStateMutex guards the device list and each slot's name/uid/format; a slot's ioMutex guards its ring
// buffer and clock. Lock order is always state, then io. The IO path only ever try-locks.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Constants

#define kDriverVersion "0.1.1"
#define kManufacturer "omso"
#define kModelUID "local.junction.virtual-device"
#define kConfigurationApp "local.junction.app"
#define kStorageKey "devices"

enum {
    kMaxDevices = 32,
    kMaxChannels = 64,
    kRingFrames = 16384,
    kZeroTimeStampPeriod = 16384,
    kFirstDeviceObjectID = 16,
    kObjectsPerDevice = 4,
    kSelectorConfig = 'jcfg',
    kSelectorVersion = 'jver',
};

static const Float64 kSampleRates[] = {44100, 48000, 88200, 96000, 176400, 192000};
static const UInt32 kSampleRateCount = sizeof(kSampleRates) / sizeof(kSampleRates[0]);

#pragma mark - State

typedef struct {
    // Guarded by gStateMutex.
    bool active;              // published in the device list
    bool everUsed;
    CFStringRef uid;          // retained; kept after deactivation so a re-enabled device gets its old object IDs
    CFStringRef name;         // retained
    UInt32 channels;
    Float64 sampleRate;
    bool hasPending;          // a format change waits for PerformDeviceConfigurationChange
    UInt32 pendingChannels;
    Float64 pendingSampleRate;
    UInt64 deactivatedAt;     // generation counter, to reuse the longest-unused slot first

    // Guarded by ioMutex.
    pthread_mutex_t ioMutex;
    UInt32 ioClients;
    Float32 *ring;            // kRingFrames * ringChannels, interleaved
    UInt32 ringChannels;
    Float64 ioSampleRate;
    Float64 hostTicksPerFrame;
    UInt64 anchorHostTime;
    UInt64 timeStampCount;
} Slot;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static Slot gSlots[kMaxDevices];
static CFArrayRef gConfig;    // normalized copy of the current configuration (retained)
static UInt64 gGeneration;
static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount;
static Float64 gHostTicksPerSecond;
static dispatch_queue_t gNotifyQueue;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

static void OneTimeSetup(void) {
    for (UInt32 i = 0; i < kMaxDevices; i++) pthread_mutex_init(&gSlots[i].ioMutex, NULL);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerSecond = 1.0e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gNotifyQueue = dispatch_queue_create("local.junction.driver.notify", DISPATCH_QUEUE_SERIAL);
}

#pragma mark - Object IDs

typedef enum { kKindNone, kKindDevice, kKindInputStream, kKindOutputStream } ObjectKind;

static inline AudioObjectID DeviceID(UInt32 slot) { return kFirstDeviceObjectID + slot * kObjectsPerDevice; }
static inline AudioObjectID InputStreamID(UInt32 slot) { return DeviceID(slot) + 1; }
static inline AudioObjectID OutputStreamID(UInt32 slot) { return DeviceID(slot) + 2; }

static ObjectKind Resolve(AudioObjectID objectID, UInt32 *outSlot) {
    if (objectID < kFirstDeviceObjectID) return kKindNone;
    UInt32 relative = objectID - kFirstDeviceObjectID;
    UInt32 slot = relative / kObjectsPerDevice;
    if (slot >= kMaxDevices) return kKindNone;
    *outSlot = slot;
    switch (relative % kObjectsPerDevice) {
    case 0: return kKindDevice;
    case 1: return kKindInputStream;
    case 2: return kKindOutputStream;
    default: return kKindNone;
    }
}

#pragma mark - Helpers

static bool IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) if (kSampleRates[i] == rate) return true;
    return false;
}

static AudioStreamBasicDescription Format(Float64 rate, UInt32 channels) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 4 * channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4 * channels;
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    return format;
}

static void NotifyAsync(AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    if (count == 0) return;
    AudioObjectPropertyAddress *copy = malloc(sizeof(*copy) * count);
    if (!copy) return;
    memcpy(copy, addresses, sizeof(*copy) * count);
    dispatch_async(gNotifyQueue, ^{
        AudioServerPlugInHostRef host = gHost;
        if (host) host->PropertiesChanged(host, objectID, count, copy);
        free(copy);
    });
}

static void RequestConfigurationChangeAsync(AudioObjectID deviceID) {
    dispatch_async(gNotifyQueue, ^{
        AudioServerPlugInHostRef host = gHost;
        if (host) host->RequestDeviceConfigurationChange(host, deviceID, 0, NULL);
    });
}

static UInt64 RingPosition(Float64 sampleTime) {
    SInt64 t = (SInt64)sampleTime;
    SInt64 m = t % kRingFrames;
    return (UInt64)(m < 0 ? m + kRingFrames : m);
}

#pragma mark - Configuration

typedef struct {
    CFStringRef uid;
    CFStringRef name;
    UInt32 channels;
    Float64 sampleRate;
} Entry;

static bool NumberValue(CFDictionaryRef dict, CFStringRef key, Float64 *out) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, out);
}

/// Reads the app's configuration: an array of dictionaries with "uid" (string, required, unique), "name" (string),
/// "channels" (1...64, default 2) and "sampleRate" (one of kSampleRates, default 48000). Entries past kMaxDevices
/// and entries without a usable uid are skipped. Returns false if the value isn't an array.
static bool ParseConfig(CFPropertyListRef plist, Entry *entries, UInt32 *outCount) {
    *outCount = 0;
    if (!plist || CFGetTypeID(plist) != CFArrayGetTypeID()) return false;
    CFArrayRef array = (CFArrayRef)plist;
    CFIndex n = CFArrayGetCount(array);
    for (CFIndex i = 0; i < n && *outCount < kMaxDevices; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(array, i);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef dict = (CFDictionaryRef)item;
        CFTypeRef uid = CFDictionaryGetValue(dict, CFSTR("uid"));
        if (!uid || CFGetTypeID(uid) != CFStringGetTypeID() || CFStringGetLength(uid) == 0) continue;
        bool duplicate = false;
        for (UInt32 j = 0; j < *outCount; j++) if (CFEqual(entries[j].uid, uid)) duplicate = true;
        if (duplicate) continue;
        CFTypeRef name = CFDictionaryGetValue(dict, CFSTR("name"));
        if (!name || CFGetTypeID(name) != CFStringGetTypeID() || CFStringGetLength(name) == 0) name = CFSTR("Junction Device");
        Float64 channels = 2, rate = 48000;
        NumberValue(dict, CFSTR("channels"), &channels);
        NumberValue(dict, CFSTR("sampleRate"), &rate);
        if (channels < 1) channels = 1;
        if (channels > kMaxChannels) channels = kMaxChannels;
        if (!IsSupportedRate(rate)) rate = 48000;
        entries[*outCount] = (Entry){(CFStringRef)uid, (CFStringRef)name, (UInt32)channels, rate};
        (*outCount)++;
    }
    return true;
}

static CFArrayRef CreateNormalizedConfig(const Entry *entries, UInt32 count) {
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (UInt32 i = 0; i < count; i++) {
        SInt32 channels = (SInt32)entries[i].channels;
        CFNumberRef channelsNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &channels);
        CFNumberRef rateNumber = CFNumberCreate(NULL, kCFNumberFloat64Type, &entries[i].sampleRate);
        const void *keys[] = {CFSTR("uid"), CFSTR("name"), CFSTR("channels"), CFSTR("sampleRate")};
        const void *values[] = {entries[i].uid, entries[i].name, channelsNumber, rateNumber};
        CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(array, dict);
        CFRelease(dict);
        CFRelease(channelsNumber);
        CFRelease(rateNumber);
    }
    return array;
}

static void SetString(CFStringRef *slot, CFStringRef value) {
    if (*slot == value) return;
    if (value) CFRetain(value);
    if (*slot) CFRelease(*slot);
    *slot = value;
}

/// Picks a slot for a device that isn't published: the slot it had before (same uid) when that is idle, else a
/// never-used slot, else the idle slot that has been unused the longest. Returns kMaxDevices if all are busy.
static UInt32 FindFreeSlot(CFStringRef uid) {
    UInt32 best = kMaxDevices;
    for (UInt32 i = 0; i < kMaxDevices; i++) {
        Slot *s = &gSlots[i];
        if (!s->active && s->uid && CFEqual(s->uid, uid) && s->ioClients == 0) return i;
    }
    for (UInt32 i = 0; i < kMaxDevices; i++) if (!gSlots[i].everUsed) return i;
    for (UInt32 i = 0; i < kMaxDevices; i++) {
        Slot *s = &gSlots[i];
        if (s->active || s->ioClients != 0) continue;
        if (best == kMaxDevices || s->deactivatedAt < gSlots[best].deactivatedAt) best = i;
    }
    return best;
}

/// Makes the published devices match the entries, then tells the host what changed.
static void ApplyConfig(const Entry *entries, UInt32 count, bool notify) {
    bool listChanged = false;
    AudioObjectID renamed[kMaxDevices];
    AudioObjectID reconfigured[kMaxDevices];
    UInt32 renamedCount = 0, reconfiguredCount = 0;

    pthread_mutex_lock(&gStateMutex);
    for (UInt32 i = 0; i < kMaxDevices; i++) {
        Slot *s = &gSlots[i];
        if (!s->active) continue;
        bool keep = false;
        for (UInt32 j = 0; j < count; j++) if (CFEqual(s->uid, entries[j].uid)) keep = true;
        if (keep) continue;
        s->active = false;
        s->hasPending = false;
        s->deactivatedAt = ++gGeneration;
        listChanged = true;
    }
    for (UInt32 j = 0; j < count; j++) {
        const Entry *e = &entries[j];
        UInt32 found = kMaxDevices;
        for (UInt32 i = 0; i < kMaxDevices; i++) if (gSlots[i].active && CFEqual(gSlots[i].uid, e->uid)) found = i;
        if (found < kMaxDevices) {
            Slot *s = &gSlots[found];
            if (!CFEqual(s->name, e->name)) {
                SetString(&s->name, e->name);
                renamed[renamedCount++] = DeviceID(found);
            }
            UInt32 wantChannels = e->channels;
            Float64 wantRate = e->sampleRate;
            UInt32 currentChannels = s->hasPending ? s->pendingChannels : s->channels;
            Float64 currentRate = s->hasPending ? s->pendingSampleRate : s->sampleRate;
            if (wantChannels != currentChannels || wantRate != currentRate) {
                if (wantChannels == s->channels && wantRate == s->sampleRate) {
                    s->hasPending = false;  // back to what it is; nothing to change
                } else {
                    s->hasPending = true;
                    s->pendingChannels = wantChannels;
                    s->pendingSampleRate = wantRate;
                    reconfigured[reconfiguredCount++] = DeviceID(found);
                }
            }
            continue;
        }
        UInt32 slot = FindFreeSlot(e->uid);
        if (slot == kMaxDevices) continue;
        Slot *s = &gSlots[slot];
        SetString(&s->uid, e->uid);
        SetString(&s->name, e->name);
        s->channels = e->channels;
        s->sampleRate = e->sampleRate;
        s->hasPending = false;
        s->active = true;
        s->everUsed = true;
        listChanged = true;
    }
    CFArrayRef normalized = CreateNormalizedConfig(entries, count);
    if (gConfig) CFRelease(gConfig);
    gConfig = normalized;
    pthread_mutex_unlock(&gStateMutex);

    if (!notify) return;
    if (listChanged) {
        AudioObjectPropertyAddress addresses[] = {
            {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        };
        NotifyAsync(kAudioObjectPlugInObject, 2, addresses);
    }
    for (UInt32 i = 0; i < renamedCount; i++) {
        AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        NotifyAsync(renamed[i], 1, &address);
    }
    for (UInt32 i = 0; i < reconfiguredCount; i++) RequestConfigurationChangeAsync(reconfigured[i]);
}

/// Makes the saved configuration match a device's current format. The format can change from outside the app: Core
/// Audio puts back the rate it remembers for a device UID when the device appears, and Audio MIDI Setup or a DAW can
/// set it. The app reads the configuration back to see the real state. Call with gStateMutex held; returns true if the
/// entry changed.
static bool RecordSlotFormat(const Slot *s) {
    if (!gConfig || !s->uid) return false;
    CFIndex n = CFArrayGetCount(gConfig);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(gConfig, i);
        CFTypeRef uid = CFDictionaryGetValue(entry, CFSTR("uid"));
        if (!uid || !CFEqual(uid, s->uid)) continue;
        Float64 channels = 0, rate = 0;
        NumberValue(entry, CFSTR("channels"), &channels);
        NumberValue(entry, CFSTR("sampleRate"), &rate);
        if ((UInt32)channels == s->channels && rate == s->sampleRate) return false;
        CFMutableDictionaryRef updated = CFDictionaryCreateMutableCopy(NULL, 0, entry);
        SInt32 newChannels = (SInt32)s->channels;
        CFNumberRef channelsNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &newChannels);
        CFNumberRef rateNumber = CFNumberCreate(NULL, kCFNumberFloat64Type, &s->sampleRate);
        CFDictionarySetValue(updated, CFSTR("channels"), channelsNumber);
        CFDictionarySetValue(updated, CFSTR("sampleRate"), rateNumber);
        CFMutableArrayRef config = CFArrayCreateMutableCopy(NULL, 0, gConfig);
        CFArraySetValueAtIndex(config, i, updated);
        CFRelease(gConfig);
        gConfig = config;
        CFRelease(updated);
        CFRelease(channelsNumber);
        CFRelease(rateNumber);
        return true;
    }
    return false;
}

static void SaveConfig(void) {
    pthread_mutex_lock(&gStateMutex);
    CFArrayRef config = gConfig ? CFRetain(gConfig) : NULL;
    pthread_mutex_unlock(&gStateMutex);
    if (!config) return;
    dispatch_async(gNotifyQueue, ^{
        AudioServerPlugInHostRef host = gHost;
        if (host) host->WriteToStorage(host, CFSTR(kStorageKey), config);
        CFRelease(config);
    });
}

#pragma mark - COM plumbing

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *,
                             AudioObjectID *);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *,
                                   Boolean *);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *,
                                    UInt32, const void *, UInt32 *);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *,
                                UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *,
                                UInt32, const void *, UInt32, const void *);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32,
                                 const AudioServerPlugInIOCycleInfo *);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32,
                              const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32,
                               const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient,
    RemoveDeviceClient, PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty,
    IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp,
    WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/// The CFPlugIn factory named in Info.plist.
__attribute__((visibility("default"))) void *JunctionDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return NULL;
    pthread_once(&gOnce, OneTimeSetup);
    return gDriverRef;
}

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    pthread_once(&gOnce, OneTimeSetup);
    gHost = inHost;
    CFPropertyListRef stored = NULL;
    if (inHost->CopyFromStorage(inHost, CFSTR(kStorageKey), &stored) == noErr && stored) {
        Entry entries[kMaxDevices];
        UInt32 count = 0;
        if (ParseConfig(stored, entries, &count)) ApplyConfig(entries, count, false);
        CFRelease(stored);
    }
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c,
                             AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) {
    (void)d; (void)device;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) {
    (void)d; (void)device; (void)c;
    return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                   const AudioServerPlugInClientInfo *c) {
    (void)d; (void)device; (void)c;
    return noErr;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt64 action,
                                                 void *info) {
    (void)d; (void)action; (void)info;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    Slot *s = &gSlots[slot];
    pthread_mutex_lock(&gStateMutex);
    if (s->hasPending) {
        s->channels = s->pendingChannels;
        s->sampleRate = s->pendingSampleRate;
        s->hasPending = false;
    }
    UInt32 channels = s->channels;
    Float64 rate = s->sampleRate;
    pthread_mutex_lock(&s->ioMutex);
    // The host stops IO before a configuration change. If a client is still registered, resize now so the IO path
    // never sees a ring of the wrong size; otherwise StartIO allocates.
    if (s->ring && s->ringChannels != channels) {
        free(s->ring);
        s->ring = NULL;
        s->ringChannels = 0;
        if (s->ioClients > 0) {
            s->ring = calloc((size_t)kRingFrames * channels, sizeof(Float32));
            s->ringChannels = s->ring ? channels : 0;
        }
    }
    s->ioSampleRate = rate;
    s->hostTicksPerFrame = gHostTicksPerSecond / rate;
    pthread_mutex_unlock(&s->ioMutex);
    bool changed = RecordSlotFormat(s);
    pthread_mutex_unlock(&gStateMutex);
    if (changed) SaveConfig();
    return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt64 action,
                                               void *info) {
    (void)d; (void)action; (void)info;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gSlots[slot].hasPending = false;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

#pragma mark - Properties

// One routine answers both size and data queries: with outData == NULL it only reports the size.
#define RETURN_SCALAR(type, value)                                                                                   \
    do {                                                                                                               \
        if (outData) {                                                                                                 \
            if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError;                                  \
            *(type *)outData = (value);                                                                                \
        }                                                                                                              \
        *outDataSize = sizeof(type);                                                                                   \
        return noErr;                                                                                                  \
    } while (0)

#define RETURN_CF(value)                                                                                               \
    do {                                                                                                               \
        if (outData) {                                                                                                 \
            if (inDataSize < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;                             \
            CFTypeRef retained = (value);                                                                              \
            if (retained) CFRetain(retained);                                                                          \
            *(CFTypeRef *)outData = retained;                                                                          \
        }                                                                                                              \
        *outDataSize = sizeof(CFTypeRef);                                                                              \
        return noErr;                                                                                                  \
    } while (0)

static OSStatus ReturnIDs(const AudioObjectID *ids, UInt32 count, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (!outData) {
        *outDataSize = count * (UInt32)sizeof(AudioObjectID);
        return noErr;
    }
    UInt32 fit = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (fit > count) fit = count;
    if (fit > 0) memcpy(outData, ids, fit * sizeof(AudioObjectID));
    *outDataSize = fit * (UInt32)sizeof(AudioObjectID);
    return noErr;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                               UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: RETURN_CF(CFSTR(kManufacturer));
    case kAudioPlugInPropertyResourceBundle: RETURN_CF(CFSTR(""));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[kMaxDevices];
        UInt32 count = 0;
        pthread_mutex_lock(&gStateMutex);
        for (UInt32 i = 0; i < kMaxDevices; i++) if (gSlots[i].active) ids[count++] = DeviceID(i);
        pthread_mutex_unlock(&gStateMutex);
        return ReturnIDs(ids, count, inDataSize, outDataSize, outData);
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (outData) {
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (qualifierSize < sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qualifier;
            AudioObjectID result = kAudioObjectUnknown;
            pthread_mutex_lock(&gStateMutex);
            for (UInt32 i = 0; i < kMaxDevices; i++)
                if (uid && gSlots[i].active && CFEqual(gSlots[i].uid, uid)) result = DeviceID(i);
            pthread_mutex_unlock(&gStateMutex);
            *(AudioObjectID *)outData = result;
        }
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info[2] = {
            {kSelectorConfig, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
             kAudioServerPlugInCustomPropertyDataTypeNone},
            {kSelectorVersion, kAudioServerPlugInCustomPropertyDataTypeCFString,
             kAudioServerPlugInCustomPropertyDataTypeNone},
        };
        if (!outData) {
            *outDataSize = sizeof(info);
            return noErr;
        }
        UInt32 fit = inDataSize / (UInt32)sizeof(info[0]);
        if (fit > 2) fit = 2;
        memcpy(outData, info, fit * sizeof(info[0]));
        *outDataSize = fit * (UInt32)sizeof(info[0]);
        return noErr;
    }
    case kSelectorConfig: {
        if (outData) {
            if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            CFArrayRef config = gConfig ? CFArrayCreateCopy(NULL, gConfig) : CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
            pthread_mutex_unlock(&gStateMutex);
            *(CFPropertyListRef *)outData = config;
        }
        *outDataSize = sizeof(CFPropertyListRef);
        return noErr;
    }
    case kSelectorVersion: RETURN_CF(CFSTR(kDriverVersion));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamList(UInt32 slot, AudioObjectPropertyScope scope, UInt32 inDataSize, UInt32 *outDataSize,
                           void *outData) {
    AudioObjectID ids[2];
    UInt32 count = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) ids[count++] = InputStreamID(slot);
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) ids[count++] = OutputStreamID(slot);
    return ReturnIDs(ids, count, inDataSize, outDataSize, outData);
}

static OSStatus DeviceProperty(UInt32 slot, const AudioObjectPropertyAddress *address, UInt32 inDataSize,
                               UInt32 *outDataSize, void *outData) {
    Slot *s = &gSlots[slot];
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, kAudioObjectPlugInObject);
    case kAudioObjectPropertyName: RETURN_CF(s->name);
    case kAudioObjectPropertyManufacturer: RETURN_CF(CFSTR(kManufacturer));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams: return StreamList(slot, address->mScope, inDataSize, outDataSize, outData);
    case kAudioDevicePropertyDeviceUID: RETURN_CF(s->uid);
    case kAudioDevicePropertyModelUID: RETURN_CF(CFSTR(kModelUID));
    case kAudioDevicePropertyConfigurationApplication: RETURN_CF(CFSTR(kConfigurationApp));
    case kAudioDevicePropertyTransportType: RETURN_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID self = DeviceID(slot);
        return ReturnIDs(&self, 1, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyClockDomain: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: RETURN_SCALAR(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: RETURN_SCALAR(UInt32, s->ioClients > 0 ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_SCALAR(UInt32, 1);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertyLatency: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_SCALAR(UInt32, kZeroTimeStampPeriod);
    case kAudioDevicePropertyIsHidden: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertyNominalSampleRate: RETURN_SCALAR(Float64, s->sampleRate);
    case kAudioObjectPropertyControlList: return ReturnIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        if (!outData) {
            *outDataSize = kSampleRateCount * (UInt32)sizeof(AudioValueRange);
            return noErr;
        }
        UInt32 fit = inDataSize / (UInt32)sizeof(AudioValueRange);
        if (fit > kSampleRateCount) fit = kSampleRateCount;
        AudioValueRange *ranges = outData;
        for (UInt32 i = 0; i < fit; i++) ranges[i] = (AudioValueRange){kSampleRates[i], kSampleRates[i]};
        *outDataSize = fit * (UInt32)sizeof(AudioValueRange);
        return noErr;
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (outData) {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 *channels = outData;
            channels[0] = 1;
            channels[1] = s->channels > 1 ? 2 : 1;
        }
        *outDataSize = 2 * sizeof(UInt32);
        return noErr;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 n = s->channels;
        UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + n * sizeof(AudioChannelDescription));
        if (outData) {
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = n;
            for (UInt32 i = 0; i < n; i++) {
                AudioChannelLabel label = kAudioChannelLabel_Discrete_0 | i;
                if (n == 2) label = i == 0 ? kAudioChannelLabel_Left : kAudioChannelLabel_Right;
                layout->mChannelDescriptions[i].mChannelLabel = label;
            }
        }
        *outDataSize = size;
        return noErr;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(UInt32 slot, bool isInput, const AudioObjectPropertyAddress *address, UInt32 inDataSize,
                               UInt32 *outDataSize, void *outData) {
    Slot *s = &gSlots[slot];
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, DeviceID(slot));
    case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioStreamPropertyIsActive: RETURN_SCALAR(UInt32, 1);
    case kAudioStreamPropertyDirection: RETURN_SCALAR(UInt32, isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType: RETURN_SCALAR(UInt32, kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel: RETURN_SCALAR(UInt32, 1);
    case kAudioStreamPropertyLatency: RETURN_SCALAR(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: RETURN_SCALAR(AudioStreamBasicDescription, Format(s->sampleRate, s->channels));
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        if (!outData) {
            *outDataSize = kSampleRateCount * (UInt32)sizeof(AudioStreamRangedDescription);
            return noErr;
        }
        UInt32 fit = inDataSize / (UInt32)sizeof(AudioStreamRangedDescription);
        if (fit > kSampleRateCount) fit = kSampleRateCount;
        AudioStreamRangedDescription *formats = outData;
        for (UInt32 i = 0; i < fit; i++) {
            formats[i].mFormat = Format(kSampleRates[i], s->channels);
            formats[i].mSampleRateRange = (AudioValueRange){kSampleRates[i], kSampleRates[i]};
        }
        *outDataSize = fit * (UInt32)sizeof(AudioStreamRangedDescription);
        return noErr;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Property(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                         const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (!address || !outDataSize) return kAudioHardwareIllegalOperationError;
    if (objectID == kAudioObjectPlugInObject)
        return PlugInProperty(address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
    UInt32 slot;
    ObjectKind kind = Resolve(objectID, &slot);
    if (kind == kKindNone) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus status;
    if (!gSlots[slot].active) status = kAudioHardwareBadObjectError;
    else if (kind == kKindDevice) status = DeviceProperty(slot, address, inDataSize, outDataSize, outData);
    else status = StreamProperty(slot, kind == kKindInputStream, address, inDataSize, outDataSize, outData);
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                           const AudioObjectPropertyAddress *address) {
    (void)pid;
    if (d != gDriverRef) return false;
    UInt32 size = 0;
    return Property(objectID, address, 0, NULL, 0, &size, NULL) == noErr;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                   const AudioObjectPropertyAddress *address, Boolean *outIsSettable) {
    (void)pid;
    if (d != gDriverRef || !outIsSettable) return kAudioHardwareBadObjectError;
    UInt32 size = 0;
    OSStatus status = Property(objectID, address, 0, NULL, 0, &size, NULL);
    if (status != noErr) return status;
    UInt32 slot;
    ObjectKind kind = objectID == kAudioObjectPlugInObject ? kKindNone : Resolve(objectID, &slot);
    switch (address->mSelector) {
    case kSelectorConfig: *outIsSettable = objectID == kAudioObjectPlugInObject; break;
    case kAudioDevicePropertyNominalSampleRate: *outIsSettable = kind == kKindDevice; break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: *outIsSettable = kind == kKindInputStream || kind == kKindOutputStream; break;
    default: *outIsSettable = false;
    }
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                                    const void *qualifier, UInt32 *outDataSize) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return Property(objectID, address, qualifierSize, qualifier, 0, outDataSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                                UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)pid;
    if (d != gDriverRef || !outData) return kAudioHardwareBadObjectError;
    return Property(objectID, address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
}

/// Asks the host to change a device's sample rate (keeping its channel count).
static OSStatus RequestSampleRate(UInt32 slot, Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    Slot *s = &gSlots[slot];
    bool request = false;
    if (s->active && rate != (s->hasPending ? s->pendingSampleRate : s->sampleRate)) {
        if (!s->hasPending) s->pendingChannels = s->channels;
        s->pendingSampleRate = rate;
        s->hasPending = true;
        request = true;
    }
    pthread_mutex_unlock(&gStateMutex);
    if (request) RequestConfigurationChangeAsync(DeviceID(slot));
    return noErr;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                                UInt32 inDataSize, const void *inData) {
    (void)pid; (void)qualifierSize; (void)qualifier;
    if (d != gDriverRef || !address || !inData) return kAudioHardwareBadObjectError;
    if (objectID == kAudioObjectPlugInObject) {
        if (address->mSelector != kSelectorConfig) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
        Entry entries[kMaxDevices];
        UInt32 count = 0;
        if (!ParseConfig(*(const CFPropertyListRef *)inData, entries, &count)) return kAudioHardwareIllegalOperationError;
        ApplyConfig(entries, count, true);
        SaveConfig();
        return noErr;
    }
    UInt32 slot;
    ObjectKind kind = Resolve(objectID, &slot);
    if (kind == kKindNone) return kAudioHardwareBadObjectError;
    switch (address->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (kind != kKindDevice) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return RequestSampleRate(slot, *(const Float64 *)inData);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        if (kind == kKindDevice) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *format = inData;
        pthread_mutex_lock(&gStateMutex);
        UInt32 channels = gSlots[slot].channels;
        pthread_mutex_unlock(&gStateMutex);
        if (format->mFormatID != kAudioFormatLinearPCM || format->mBitsPerChannel != 32 ||
            !(format->mFormatFlags & kAudioFormatFlagIsFloat) || format->mChannelsPerFrame != channels)
            return kAudioDeviceUnsupportedFormatError;
        return RequestSampleRate(slot, format->mSampleRate);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    Slot *s = &gSlots[slot];
    OSStatus status = noErr;
    pthread_mutex_lock(&gStateMutex);
    UInt32 channels = s->channels;
    Float64 rate = s->sampleRate;
    bool active = s->active;
    pthread_mutex_lock(&s->ioMutex);
    if (!active) {
        status = kAudioHardwareBadDeviceError;
    } else {
        if (s->ioClients == 0) {
            if (!s->ring || s->ringChannels != channels) {
                free(s->ring);
                s->ring = calloc((size_t)kRingFrames * channels, sizeof(Float32));
                s->ringChannels = s->ring ? channels : 0;
            } else {
                memset(s->ring, 0, (size_t)kRingFrames * channels * sizeof(Float32));
            }
            s->ioSampleRate = rate;
            s->hostTicksPerFrame = gHostTicksPerSecond / rate;
            s->timeStampCount = 0;
            s->anchorHostTime = mach_absolute_time();
        }
        if (!s->ring) status = kAudioHardwareUnspecifiedError;
        else s->ioClients++;
    }
    pthread_mutex_unlock(&s->ioMutex);
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    Slot *s = &gSlots[slot];
    pthread_mutex_lock(&s->ioMutex);
    if (s->ioClients > 0) s->ioClients--;
    pthread_mutex_unlock(&s->ioMutex);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    Slot *s = &gSlots[slot];
    pthread_mutex_lock(&s->ioMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = s->hostTicksPerFrame * kZeroTimeStampPeriod;
    UInt64 next = s->anchorHostTime + (UInt64)((Float64)(s->timeStampCount + 1) * ticksPerPeriod);
    if (next <= now) s->timeStampCount++;
    *outSampleTime = (Float64)(s->timeStampCount * kZeroTimeStampPeriod);
    *outHostTime = s->anchorHostTime + (UInt64)((Float64)s->timeStampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&s->ioMutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID,
                                  UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)deviceID; (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    bool willDo = operationID == kAudioServerPlugInIOOperationReadInput ||
                  operationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID,
                                 UInt32 operationID, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)deviceID; (void)clientID; (void)operationID; (void)frames; (void)cycle;
    return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID,
                               UInt32 operationID, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)deviceID; (void)clientID; (void)operationID; (void)frames; (void)cycle;
    return noErr;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, AudioObjectID streamID,
                              UInt32 clientID, UInt32 operationID, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    (void)streamID; (void)clientID; (void)secondaryBuffer;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    bool isRead = operationID == kAudioServerPlugInIOOperationReadInput;
    bool isWrite = operationID == kAudioServerPlugInIOOperationWriteMix;
    if ((!isRead && !isWrite) || !mainBuffer || !cycle || frames == 0) return noErr;
    Slot *s = &gSlots[slot];
    Float32 *buffer = mainBuffer;
    if (pthread_mutex_trylock(&s->ioMutex) != 0) {
        // A configuration change holds the ring; deliver silence for this cycle.
        if (isRead) memset(buffer, 0, (size_t)frames * s->channels * sizeof(Float32));
        return noErr;
    }
    UInt32 channels = s->ringChannels;
    Float32 *ring = s->ring;
    if (!ring || channels != s->channels) {
        if (isRead) memset(buffer, 0, (size_t)frames * s->channels * sizeof(Float32));
        pthread_mutex_unlock(&s->ioMutex);
        return noErr;
    }
    UInt64 position = RingPosition(isRead ? cycle->mInputTime.mSampleTime : cycle->mOutputTime.mSampleTime);
    UInt32 done = 0;
    while (done < frames) {
        UInt32 chunk = frames - done;
        UInt32 untilWrap = (UInt32)(kRingFrames - position);
        if (chunk > untilWrap) chunk = untilWrap;
        Float32 *ringPart = ring + position * channels;
        Float32 *bufferPart = buffer + (size_t)done * channels;
        size_t bytes = (size_t)chunk * channels * sizeof(Float32);
        if (isRead) {
            memcpy(bufferPart, ringPart, bytes);
            memset(ringPart, 0, bytes);  // consumed: if nothing is written again, the next lap reads silence
        } else {
            memcpy(ringPart, bufferPart, bytes);
        }
        done += chunk;
        position = (position + chunk) % kRingFrames;
    }
    pthread_mutex_unlock(&s->ioMutex);
    return noErr;
}
