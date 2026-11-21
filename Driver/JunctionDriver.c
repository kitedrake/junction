// JunctionDriver: Junction's virtual audio devices.
//
// An AudioServerPlugIn (a Core Audio HAL plug-in, loaded by coreaudiod from /Library/Audio/Plug-Ins/HAL)
// that publishes up to kMaxDevices loopback devices. Which devices exist, and their names, channel counts, sample
// rates, directions, channel names, icons, visibility, volumes and mutes, is set by the Junction app through a custom
// property on the plug-in object ('jcfg': an array of dictionaries, see ParseConfig). The driver saves that list in
// the host's storage, so the devices come back after a restart even when the app is not running.
//
// Every device is a loopback: what is played to its output side comes out of its input side. Junction's router
// plays its mixes into the output side; apps such as OBS or Discord record from the input side. Apps can also
// play into a device (pick it as their output) and Junction can pick that audio up from the input side.
//
// A device can show apps only one side: "input" (a microphone only) or "output" (a speaker only). The other side
// then belongs to a hidden companion device ("<uid>.routing") that only Junction uses, so it can still feed or record
// the device. Every device and companion runs on one shared clock: they report the same clock domain and derive
// their zero time stamps from the same anchor, so Junction combines them without drift compensation.
//
// Each device has a volume and a mute control per side it shows apps. Output volume scales what is played into the
// device, input volume what is recorded from it; DoIOOperation applies both with a short ramp.
//
// Per-app capture: what each app plays into a device is also kept on its own, before the device mixes it with
// everything else, in a ring per client in one shared memory region (layout: JunctionCaptureRing.h). AddDeviceClient
// gives each client a slot (Junction's own processes get none), DoIOOperation's ProcessOutput copies the client's
// output into it, and RemoveDeviceClient frees it. The plug-in's 'jcli' property lists the clients being captured.
// The driver hands the region to Junction Driver Installer (the privileged daemon, Mach service
// kCaptureService, allowed by AudioServerPlugIn_MachServices in Info.plist), which gives it only to Junction's own
// processes, signed by its team.
//
// Threading: gStateMutex guards the device list and each slot's name/uid/format/settings; a slot's ioMutex guards
// its ring buffer and the gains being ramped. Lock order is always state, then io. gClientMutex guards the capture
// slots' bookkeeping and is never held together with the others. The IO path (GetZeroTimeStamp, DoIOOperation) never
// blocks: it only try-locks and reads atomics.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "../Sources/JunctionKernel/include/JunctionCaptureRing.h"

#pragma mark - Constants

#define kDriverVersion "0.2.0"
#define kBundleID "local.junction.driver"
#define kManufacturer "omso"
#define kModelUID "local.junction.virtual-device"
#define kConfigurationApp "local.junction.app"
#define kStorageKey "devices"
#define kCompanionSuffix ".routing"
#define kDefaultIcon "junction"
/// Junction Driver Installer's service that takes the capture region (see the daemon's launchd plist).
#define kCaptureService "local.junction.driverd.capture"
/// Clients whose bundle ID starts with this are Junction's own and are never captured.
#define kOwnBundlePrefix "local.junction."

enum {
    kMaxDevices = 32,
    kMaxChannels = 64,
    kRingFrames = 16384,
    kZeroTimeStampPeriod = 16384,
    kFirstDeviceObjectID = 16,
    kObjectsPerDevice = 8,
    kSelectorConfig = 'jcfg',
    kSelectorVersion = 'jver',
    kSelectorClients = 'jcli',
    kClockDomain = 'jnct',   // shared by every device: one clock, no drift between them
    kRampFrames = 256,       // a volume or mute change glides over this many frames
};

/// Which sides of a device apps see. The other side (if any) belongs to the device's hidden companion.
enum { kDirectionBoth = 0, kDirectionInput = 1, kDirectionOutput = 2 };
/// Index of a side in the per-side settings.
enum { kSideOutput = 0, kSideInput = 1 };

static const Float64 kSampleRates[] = {44100, 48000, 88200, 96000, 176400, 192000};
static const UInt32 kSampleRateCount = sizeof(kSampleRates) / sizeof(kSampleRates[0]);
/// The volume controls' range: scalar 0 is silence, 1 is 0 dB, and in between the level is linear in decibels.
static const Float32 kMinDecibels = -64;
/// The icons bundled in the driver (Contents/Resources/<name>.icns).
static const char *const kIcons[] = {"junction", "microphone", "speaker", "headphones", "stream"};
static const UInt32 kIconCount = sizeof(kIcons) / sizeof(kIcons[0]);

#pragma mark - State

typedef struct {
    // Guarded by gStateMutex.
    bool active;              // published in the device list
    bool everUsed;
    CFStringRef uid;          // retained; kept after deactivation so a re-enabled device gets its old object IDs
    CFStringRef companionUID; // retained: uid + kCompanionSuffix
    CFStringRef name;         // retained
    CFArrayRef channelNames;  // retained, may be NULL; strings, "" for a channel without a name
    CFStringRef icon;         // retained; one of kIcons
    bool hidden;
    UInt32 channels;
    Float64 sampleRate;
    UInt32 direction;
    Float64 volume[2];        // scalar 0…1 per side
    bool mute[2];
    bool hasPending;          // a format or direction change waits for PerformDeviceConfigurationChange
    UInt32 pendingChannels;
    Float64 pendingSampleRate;
    UInt32 pendingDirection;
    UInt64 deactivatedAt;     // generation counter, to reuse the longest-unused slot first

    // Written under gStateMutex, read by the IO path without locking.
    _Atomic(Float32) targetGain[2];  // linear gain per side, from volume, mute and direction
    _Atomic(Float64) ticksPerFrame;  // host ticks per frame at the current rate

    // Guarded by ioMutex.
    pthread_mutex_t ioMutex;
    UInt32 ioClients;
    Float32 *ring;            // kRingFrames * ringChannels, interleaved
    UInt32 ringChannels;
    Float32 gain[2];          // the gain being applied per side, ramping towards targetGain
} Slot;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static Slot gSlots[kMaxDevices];
static CFArrayRef gConfig;    // normalized copy of the current configuration (retained)
static UInt64 gGeneration;
static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount;
static Float64 gHostTicksPerSecond;
/// The one clock: every device's zero time stamps count periods from this host time.
static UInt64 gAnchorHostTime;
static dispatch_queue_t gNotifyQueue;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

/// A capture slot: which client of which device owns ring `index` of the shared region.
typedef struct {
    // Guarded by gClientMutex.
    bool used;
    UInt32 clientID;
    UInt32 device;            // the device's slot in gSlots
    pid_t pid;
    char bundleID[JCAP_TEXT];
    char deviceUID[JCAP_TEXT];
    UInt64 releasedAt;        // generation counter, to reuse the longest-free slot first

    // Read by the IO path.
    _Atomic(bool) live;
    _Atomic(UInt32) ioClientID;
    _Atomic(UInt32) ioDevice;
    _Atomic(UInt32) writers;  // IO threads writing the ring right now
} Capture;

static pthread_mutex_t gClientMutex = PTHREAD_MUTEX_INITIALIZER;
static Capture gCaptures[JCAP_SLOTS];
static UInt64 gCaptureGeneration;
/// The shared region (JCAP_REGION_BYTES, allocated once; NULL if that failed: nothing is captured).
static void *gCaptureRegion;
static dispatch_queue_t gCaptureQueue;
static xpc_connection_t gBroker;   // gCaptureQueue only

static void OneTimeSetup(void) {
    for (UInt32 i = 0; i < kMaxDevices; i++) pthread_mutex_init(&gSlots[i].ioMutex, NULL);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerSecond = 1.0e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gAnchorHostTime = mach_absolute_time();
    gNotifyQueue = dispatch_queue_create("local.junction.driver.notify", DISPATCH_QUEUE_SERIAL);
    gCaptureQueue = dispatch_queue_create("local.junction.driver.capture", DISPATCH_QUEUE_SERIAL);
    mach_vm_address_t address = 0;
    if (mach_vm_allocate(mach_task_self(), &address, JCAP_REGION_BYTES, VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
        gCaptureRegion = (void *)address;
        jcap_init(gCaptureRegion, gAnchorHostTime ^ ((UInt64)getpid() << 32), gAnchorHostTime);
    }
}

#pragma mark - Object IDs

typedef enum {
    kKindNone,
    kKindDevice,
    kKindInputStream,
    kKindOutputStream,
    kKindOutputVolume,
    kKindOutputMute,
    kKindInputVolume,
    kKindInputMute,
    kKindCompanion,
} ObjectKind;

static inline AudioObjectID DeviceID(UInt32 slot) { return kFirstDeviceObjectID + slot * kObjectsPerDevice; }
static inline AudioObjectID InputStreamID(UInt32 slot) { return DeviceID(slot) + 1; }
static inline AudioObjectID OutputStreamID(UInt32 slot) { return DeviceID(slot) + 2; }
static inline AudioObjectID VolumeID(UInt32 slot, int side) { return DeviceID(slot) + (side == kSideOutput ? 3 : 5); }
static inline AudioObjectID MuteID(UInt32 slot, int side) { return DeviceID(slot) + (side == kSideOutput ? 4 : 6); }
static inline AudioObjectID CompanionID(UInt32 slot) { return DeviceID(slot) + 7; }

static ObjectKind Resolve(AudioObjectID objectID, UInt32 *outSlot) {
    if (objectID < kFirstDeviceObjectID) return kKindNone;
    UInt32 relative = objectID - kFirstDeviceObjectID;
    UInt32 slot = relative / kObjectsPerDevice;
    if (slot >= kMaxDevices) return kKindNone;
    *outSlot = slot;
    static const ObjectKind kinds[kObjectsPerDevice] = {
        kKindDevice, kKindInputStream, kKindOutputStream, kKindOutputVolume,
        kKindOutputMute, kKindInputVolume, kKindInputMute, kKindCompanion,
    };
    return kinds[relative % kObjectsPerDevice];
}

static inline bool IsDeviceKind(ObjectKind kind) { return kind == kKindDevice || kind == kKindCompanion; }

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

/// Whether apps see the device's input side (it records) / output side (it plays) on the device itself.
static inline bool ShowsInput(UInt32 direction) { return direction != kDirectionOutput; }
static inline bool ShowsOutput(UInt32 direction) { return direction != kDirectionInput; }
static inline bool ShowsSide(UInt32 direction, int side) {
    return side == kSideInput ? ShowsInput(direction) : ShowsOutput(direction);
}
static inline bool HasCompanion(UInt32 direction) { return direction != kDirectionBoth; }

static Float32 ScalarToDecibels(Float32 scalar) {
    if (!(scalar > 0)) scalar = 0;
    if (scalar > 1) scalar = 1;
    return kMinDecibels * (1 - scalar);
}

static Float32 DecibelsToScalar(Float32 decibels) {
    if (!(decibels > kMinDecibels)) return 0;
    if (decibels > 0) return 1;
    return 1 - decibels / kMinDecibels;
}

/// The linear gain a side's volume and mute give. A side apps don't see on the device has no controls: unity.
static Float32 SideGain(const Slot *s, int side) {
    if (!ShowsSide(s->direction, side)) return 1;
    if (s->mute[side] || !(s->volume[side] > 0)) return 0;
    return powf(10, ScalarToDecibels((Float32)s->volume[side]) / 20);
}

/// Call with gStateMutex held after changing volume, mute or direction.
static void UpdateTargetGains(Slot *s) {
    atomic_store_explicit(&s->targetGain[kSideOutput], SideGain(s, kSideOutput), memory_order_relaxed);
    atomic_store_explicit(&s->targetGain[kSideInput], SideGain(s, kSideInput), memory_order_relaxed);
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

static void NotifyOne(AudioObjectID objectID, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementWildcard};
    NotifyAsync(objectID, 1, &address);
}

static void NotifyDeviceList(void) {
    AudioObjectPropertyAddress addresses[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    NotifyAsync(kAudioObjectPlugInObject, 2, addresses);
}

/// A side's controls changed value: tells listeners on the volume and mute objects.
static void NotifyControls(UInt32 slot, int side) {
    AudioObjectPropertyAddress volume[] = {
        {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    AudioObjectPropertyAddress mute = {kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    NotifyAsync(VolumeID(slot, side), 2, volume);
    NotifyAsync(MuteID(slot, side), 1, &mute);
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

/// The URL of a bundled icon. Inside coreaudiod the driver is a loaded bundle; a test harness that loads only the
/// binary gets a relative URL with the right file name.
static CFURLRef CopyIconURL(CFStringRef icon) {
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(kBundleID));
    if (bundle) {
        CFURLRef url = CFBundleCopyResourceURL(bundle, icon, CFSTR("icns"), NULL);
        if (url) return url;
    }
    CFStringRef file = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@.icns"), icon);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, file, kCFURLPOSIXPathStyle, false);
    CFRelease(file);
    return url;
}

#pragma mark - Configuration

typedef struct {
    CFStringRef uid;          // borrowed from the parsed list
    CFStringRef name;         // borrowed
    CFArrayRef channelNames;  // owned (FreeEntries), may be NULL
    CFStringRef icon;         // borrowed, or a constant (the default)
    UInt32 channels;
    Float64 sampleRate;
    UInt32 direction;
    bool hidden;
    Float64 volume[2];
    bool mute[2];
} Entry;

static bool NumberValue(CFDictionaryRef dict, CFStringRef key, Float64 *out) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, out);
}

static bool BoolValue(CFDictionaryRef dict, CFStringRef key, bool fallback) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue(value);
    Float64 number;
    if (NumberValue(dict, key, &number)) return number != 0;
    return fallback;
}

static Float64 VolumeValue(CFDictionaryRef dict, CFStringRef key) {
    Float64 volume = 1;
    NumberValue(dict, key, &volume);
    if (!(volume >= 0)) volume = 0;
    if (volume > 1) volume = 1;
    return volume;
}

static UInt32 DirectionValue(CFDictionaryRef dict) {
    CFTypeRef value = CFDictionaryGetValue(dict, CFSTR("direction"));
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        if (CFEqual(value, CFSTR("input"))) return kDirectionInput;
        if (CFEqual(value, CFSTR("output"))) return kDirectionOutput;
    }
    return kDirectionBoth;
}

static CFStringRef DirectionString(UInt32 direction) {
    switch (direction) {
    case kDirectionInput: return CFSTR("input");
    case kDirectionOutput: return CFSTR("output");
    default: return CFSTR("both");
    }
}

static CFStringRef IconValue(CFDictionaryRef dict) {
    CFTypeRef value = CFDictionaryGetValue(dict, CFSTR("icon"));
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        char name[32];
        if (CFStringGetCString(value, name, sizeof name, kCFStringEncodingUTF8)) {
            for (UInt32 i = 1; i < kIconCount; i++) {
                if (strcmp(name, kIcons[i]) == 0) return value;
            }
        }
    }
    return CFSTR(kDefaultIcon);
}

/// Channel names as given, at most kMaxChannels; anything that isn't a string becomes "". NULL when there are none.
static CFArrayRef CreateChannelNames(CFDictionaryRef dict) {
    CFTypeRef value = CFDictionaryGetValue(dict, CFSTR("channelNames"));
    if (!value || CFGetTypeID(value) != CFArrayGetTypeID()) return NULL;
    CFIndex n = CFArrayGetCount(value);
    if (n > kMaxChannels) n = kMaxChannels;
    if (n == 0) return NULL;
    CFMutableArrayRef names = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef name = CFArrayGetValueAtIndex(value, i);
        CFArrayAppendValue(names, name && CFGetTypeID(name) == CFStringGetTypeID() ? name : CFSTR(""));
    }
    return names;
}

static void FreeEntries(Entry *entries, UInt32 count) {
    for (UInt32 i = 0; i < count; i++) {
        if (entries[i].channelNames) CFRelease(entries[i].channelNames);
        entries[i].channelNames = NULL;
    }
}

/// Reads the app's configuration: an array of dictionaries with "uid" (string, required, unique), "name" (string),
/// "channels" (1...64, default 2), "sampleRate" (one of kSampleRates, default 48000), "direction" ("both", "input" or
/// "output", default "both"), "channelNames" (array of strings), "icon" (one of kIcons, default "junction"), "hidden"
/// (default false), "outputVolume" and "inputVolume" (0…1, default 1) and "outputMute" and "inputMute" (default
/// false). Lists saved by driver 0.1 have only the first four keys; the rest take their defaults. Entries past
/// kMaxDevices and entries without a usable uid are skipped. Returns false if the value isn't an array. Release the
/// entries with FreeEntries.
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
        if (!(channels >= 1)) channels = 1;
        if (channels > kMaxChannels) channels = kMaxChannels;
        if (!IsSupportedRate(rate)) rate = 48000;
        Entry *e = &entries[*outCount];
        memset(e, 0, sizeof *e);
        e->uid = (CFStringRef)uid;
        e->name = (CFStringRef)name;
        e->channels = (UInt32)channels;
        e->sampleRate = rate;
        e->direction = DirectionValue(dict);
        e->channelNames = CreateChannelNames(dict);
        e->icon = IconValue(dict);
        e->hidden = BoolValue(dict, CFSTR("hidden"), false);
        e->volume[kSideOutput] = VolumeValue(dict, CFSTR("outputVolume"));
        e->volume[kSideInput] = VolumeValue(dict, CFSTR("inputVolume"));
        e->mute[kSideOutput] = BoolValue(dict, CFSTR("outputMute"), false);
        e->mute[kSideInput] = BoolValue(dict, CFSTR("inputMute"), false);
        (*outCount)++;
    }
    return true;
}

static CFDictionaryRef CreateEntryDictionary(const Entry *e) {
    SInt32 channels = (SInt32)e->channels;
    CFNumberRef channelsNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &channels);
    CFNumberRef rateNumber = CFNumberCreate(NULL, kCFNumberFloat64Type, &e->sampleRate);
    CFNumberRef outputVolume = CFNumberCreate(NULL, kCFNumberFloat64Type, &e->volume[kSideOutput]);
    CFNumberRef inputVolume = CFNumberCreate(NULL, kCFNumberFloat64Type, &e->volume[kSideInput]);
    CFArrayRef names = e->channelNames ? CFRetain(e->channelNames) : CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    const void *keys[] = {
        CFSTR("uid"), CFSTR("name"), CFSTR("channels"), CFSTR("sampleRate"), CFSTR("direction"), CFSTR("channelNames"),
        CFSTR("icon"), CFSTR("hidden"), CFSTR("outputVolume"), CFSTR("outputMute"), CFSTR("inputVolume"),
        CFSTR("inputMute"),
    };
    const void *values[] = {
        e->uid, e->name, channelsNumber, rateNumber, DirectionString(e->direction), names, e->icon,
        e->hidden ? kCFBooleanTrue : kCFBooleanFalse, outputVolume,
        e->mute[kSideOutput] ? kCFBooleanTrue : kCFBooleanFalse, inputVolume,
        e->mute[kSideInput] ? kCFBooleanTrue : kCFBooleanFalse,
    };
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, values, sizeof keys / sizeof keys[0],
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(channelsNumber);
    CFRelease(rateNumber);
    CFRelease(outputVolume);
    CFRelease(inputVolume);
    CFRelease(names);
    return dict;
}

static CFArrayRef CreateNormalizedConfig(const Entry *entries, UInt32 count) {
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (UInt32 i = 0; i < count; i++) {
        CFDictionaryRef dict = CreateEntryDictionary(&entries[i]);
        CFArrayAppendValue(array, dict);
        CFRelease(dict);
    }
    return array;
}

static void SetCF(CFTypeRef *slot, CFTypeRef value) {
    if (*slot == value) return;
    if (value) CFRetain(value);
    if (*slot) CFRelease(*slot);
    *slot = value;
}

static bool SameNames(CFArrayRef a, CFArrayRef b) {
    if (!a || !b) return a == b;
    return CFEqual(a, b);
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

/// What changed on one published device, to announce after the state lock is released.
typedef struct {
    UInt32 slot;
    bool renamed, names, icon, hidden, reconfigure;
    bool controls[2];
} SlotChanges;

/// Makes the published devices match the entries, then tells the host what changed.
static void ApplyConfig(const Entry *entries, UInt32 count, bool notify) {
    bool listChanged = false;
    SlotChanges changes[kMaxDevices];
    UInt32 changeCount = 0;

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
            SlotChanges c = {.slot = found};
            if (!CFEqual(s->name, e->name)) {
                SetCF((CFTypeRef *)&s->name, e->name);
                c.renamed = true;
            }
            if (!SameNames(s->channelNames, e->channelNames)) {
                SetCF((CFTypeRef *)&s->channelNames, e->channelNames);
                c.names = true;
            }
            if (!CFEqual(s->icon, e->icon)) {
                SetCF((CFTypeRef *)&s->icon, e->icon);
                c.icon = true;
            }
            if (s->hidden != e->hidden) {
                s->hidden = e->hidden;
                c.hidden = true;
            }
            for (int side = 0; side < 2; side++) {
                if (s->volume[side] != e->volume[side] || s->mute[side] != e->mute[side]) {
                    s->volume[side] = e->volume[side];
                    s->mute[side] = e->mute[side];
                    c.controls[side] = true;
                }
            }
            UpdateTargetGains(s);
            UInt32 currentChannels = s->hasPending ? s->pendingChannels : s->channels;
            Float64 currentRate = s->hasPending ? s->pendingSampleRate : s->sampleRate;
            UInt32 currentDirection = s->hasPending ? s->pendingDirection : s->direction;
            if (e->channels != currentChannels || e->sampleRate != currentRate || e->direction != currentDirection) {
                if (e->channels == s->channels && e->sampleRate == s->sampleRate && e->direction == s->direction) {
                    s->hasPending = false;  // back to what it is; nothing to change
                } else {
                    s->hasPending = true;
                    s->pendingChannels = e->channels;
                    s->pendingSampleRate = e->sampleRate;
                    s->pendingDirection = e->direction;
                    c.reconfigure = true;
                }
            }
            if (c.renamed || c.names || c.icon || c.hidden || c.reconfigure || c.controls[0] || c.controls[1])
                changes[changeCount++] = c;
            continue;
        }
        UInt32 slot = FindFreeSlot(e->uid);
        if (slot == kMaxDevices) continue;
        Slot *s = &gSlots[slot];
        if (!s->uid || !CFEqual(s->uid, e->uid)) {
            SetCF((CFTypeRef *)&s->uid, e->uid);
            CFStringRef companion = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@" kCompanionSuffix), e->uid);
            SetCF((CFTypeRef *)&s->companionUID, companion);
            CFRelease(companion);
        }
        SetCF((CFTypeRef *)&s->name, e->name);
        SetCF((CFTypeRef *)&s->channelNames, e->channelNames);
        SetCF((CFTypeRef *)&s->icon, e->icon);
        s->hidden = e->hidden;
        s->channels = e->channels;
        s->sampleRate = e->sampleRate;
        s->direction = e->direction;
        for (int side = 0; side < 2; side++) {
            s->volume[side] = e->volume[side];
            s->mute[side] = e->mute[side];
        }
        UpdateTargetGains(s);
        atomic_store_explicit(&s->ticksPerFrame, gHostTicksPerSecond / e->sampleRate, memory_order_relaxed);
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
    for (UInt32 i = 0; i < changeCount; i++) {
        const SlotChanges *c = &changes[i];
        AudioObjectID device = DeviceID(c->slot);
        if (c->renamed) NotifyOne(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
        if (c->names) NotifyOne(device, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeWildcard);
        if (c->icon) NotifyOne(device, kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal);
        if (c->hidden) {
            NotifyOne(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal);
            listChanged = true;  // apps' device lists leave hidden devices out
        }
        for (int side = 0; side < 2; side++) if (c->controls[side]) NotifyControls(c->slot, side);
        if (c->reconfigure) RequestConfigurationChangeAsync(device);
    }
    if (listChanged) NotifyDeviceList();
}

/// Makes the saved configuration match a device's current state where it can change from outside the app: the format
/// (Core Audio puts back the rate it remembers for a device UID when the device appears, and Audio MIDI Setup or a
/// DAW can set it) and the volume and mute (Sound settings, keyboard volume keys). The app reads the configuration
/// back to see the real state. Call with gStateMutex held; returns true if the entry changed.
static bool RecordSlotState(const Slot *s) {
    if (!gConfig || !s->uid) return false;
    CFIndex n = CFArrayGetCount(gConfig);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(gConfig, i);
        CFTypeRef uid = CFDictionaryGetValue(entry, CFSTR("uid"));
        if (!uid || !CFEqual(uid, s->uid)) continue;
        Entry e;
        memset(&e, 0, sizeof e);
        e.uid = s->uid;
        e.name = s->name;
        e.channelNames = s->channelNames;
        e.icon = s->icon;
        e.hidden = s->hidden;
        e.channels = s->channels;
        e.sampleRate = s->sampleRate;
        e.direction = s->direction;
        for (int side = 0; side < 2; side++) {
            e.volume[side] = s->volume[side];
            e.mute[side] = s->mute[side];
        }
        CFDictionaryRef updated = CreateEntryDictionary(&e);
        bool changed = !CFEqual(updated, entry);
        if (changed) {
            CFMutableArrayRef config = CFArrayCreateMutableCopy(NULL, 0, gConfig);
            CFArraySetValueAtIndex(config, i, updated);
            CFRelease(gConfig);
            gConfig = config;
        }
        CFRelease(updated);
        return changed;
    }
    return false;
}

/// Saves the configuration and tells the app (listening on 'jcfg') that it changed.
static void SaveConfig(bool announce) {
    pthread_mutex_lock(&gStateMutex);
    CFArrayRef config = gConfig ? CFRetain(gConfig) : NULL;
    pthread_mutex_unlock(&gStateMutex);
    if (!config) return;
    dispatch_async(gNotifyQueue, ^{
        AudioServerPlugInHostRef host = gHost;
        if (host) host->WriteToStorage(host, CFSTR(kStorageKey), config);
        CFRelease(config);
    });
    if (announce) NotifyOne(kAudioObjectPlugInObject, kSelectorConfig, kAudioObjectPropertyScopeGlobal);
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
static void ConnectCaptureBroker(void);

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
        FreeEntries(entries, count);
        CFRelease(stored);
    }
    dispatch_async(gCaptureQueue, ^{ ConnectCaptureBroker(); });
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

#pragma mark - Per-app capture

/// Sends the capture region to Junction Driver Installer. Call on gCaptureQueue.
static void SendCaptureRegion(xpc_connection_t connection) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "op", "publish");
    xpc_dictionary_set_uint64(message, "layout", JCAP_LAYOUT);
    xpc_object_t region = xpc_shmem_create(gCaptureRegion, (size_t)JCAP_REGION_BYTES);
    if (region) {
        xpc_dictionary_set_value(message, "region", region);
        xpc_connection_send_message(connection, message);
        xpc_release(region);
    }
    xpc_release(message);
}

/// Opens the connection to Junction Driver Installer and gives it the region. launchd starts the daemon for the
/// message; when it quits or restarts the region is sent again. Without the daemon (not installed or not allowed)
/// the driver tries again every minute. Call on gCaptureQueue.
static void ConnectCaptureBroker(void) {
    if (!gCaptureRegion || gBroker) return;
    xpc_connection_t connection =
        xpc_connection_create_mach_service(kCaptureService, gCaptureQueue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!connection) return;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
            SendCaptureRegion(connection);
        } else if (event == XPC_ERROR_CONNECTION_INVALID) {
            if (gBroker == connection) {
                gBroker = NULL;
                xpc_release(connection);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), gCaptureQueue, ^{ ConnectCaptureBroker(); });
        }
    });
    gBroker = connection;
    xpc_connection_resume(connection);
    SendCaptureRegion(connection);
}

/// Waits (briefly; never on the IO path) until no IO thread writes a capture slot's ring.
static void WaitForCaptureWriters(Capture *c) {
    for (int i = 0; i < 2000 && atomic_load(&c->writers) != 0; i++) usleep(50);
}

static bool CStringFrom(CFStringRef string, char *out, size_t size) {
    out[0] = 0;
    return string && CFStringGetCString(string, out, (CFIndex)size, kCFStringEncodingUTF8);
}

/// Gives a new client of a device a capture slot: the longest-free one. Clients without a bundle ID, Junction's own
/// processes and clients past JCAP_SLOTS aren't captured.
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *c) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (!c || !gCaptureRegion || !IsDeviceKind(Resolve(device, &slot))) return noErr;
    char bundleID[JCAP_TEXT], deviceUID[JCAP_TEXT];
    if (!CStringFrom(c->mBundleID, bundleID, sizeof bundleID) || bundleID[0] == 0) return noErr;
    if (strncmp(bundleID, kOwnBundlePrefix, strlen(kOwnBundlePrefix)) == 0) return noErr;
    pthread_mutex_lock(&gStateMutex);
    bool named = gSlots[slot].uid && CStringFrom(gSlots[slot].uid, deviceUID, sizeof deviceUID);
    UInt32 channels = gSlots[slot].channels;
    pthread_mutex_unlock(&gStateMutex);
    if (!named) return noErr;

    pthread_mutex_lock(&gClientMutex);
    UInt32 best = JCAP_SLOTS;
    bool known = false;
    for (UInt32 i = 0; i < JCAP_SLOTS; i++) {
        Capture *capture = &gCaptures[i];
        if (capture->used && capture->clientID == c->mClientID && capture->device == slot) known = true;
        if (capture->used) continue;
        if (best == JCAP_SLOTS || capture->releasedAt < gCaptures[best].releasedAt) best = i;
    }
    bool added = !known && best < JCAP_SLOTS;
    if (added) {
        Capture *capture = &gCaptures[best];
        WaitForCaptureWriters(capture);
        capture->used = true;
        capture->clientID = c->mClientID;
        capture->device = slot;
        capture->pid = c->mProcessID;
        memcpy(capture->bundleID, bundleID, sizeof bundleID);
        memcpy(capture->deviceUID, deviceUID, sizeof deviceUID);
        jcap_claim(gCaptureRegion, best, c->mProcessID, bundleID, deviceUID, channels);
        atomic_store(&capture->ioClientID, c->mClientID);
        atomic_store(&capture->ioDevice, slot);
        atomic_store(&capture->live, true);
    }
    pthread_mutex_unlock(&gClientMutex);
    if (added) NotifyOne(kAudioObjectPlugInObject, kSelectorClients, kAudioObjectPropertyScopeGlobal);
    return noErr;
}

/// Frees the client's capture slot once no IO thread writes it any more.
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                   const AudioServerPlugInClientInfo *c) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (!c || !gCaptureRegion || !IsDeviceKind(Resolve(device, &slot))) return noErr;
    bool removed = false;
    pthread_mutex_lock(&gClientMutex);
    for (UInt32 i = 0; i < JCAP_SLOTS; i++) {
        Capture *capture = &gCaptures[i];
        if (!capture->used || capture->clientID != c->mClientID || capture->device != slot) continue;
        atomic_store(&capture->live, false);
        WaitForCaptureWriters(capture);
        jcap_release(gCaptureRegion, i);
        capture->used = false;
        capture->releasedAt = ++gCaptureGeneration;
        removed = true;
    }
    pthread_mutex_unlock(&gClientMutex);
    if (removed) NotifyOne(kAudioObjectPlugInObject, kSelectorClients, kAudioObjectPropertyScopeGlobal);
    return noErr;
}

/// The 'jcli' property: the clients being captured, as an array of dictionaries ("pid", "bundleID", "deviceUID",
/// "channels"), in slot order.
static CFArrayRef CopyCapturedClients(void) {
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    pthread_mutex_lock(&gClientMutex);
    for (UInt32 i = 0; i < JCAP_SLOTS; i++) {
        const Capture *capture = &gCaptures[i];
        if (!capture->used) continue;
        SInt32 pid = capture->pid, slotIndex = (SInt32)i;
        SInt32 channels = (SInt32)jcap_header(gCaptureRegion)->slots[i].channels;
        CFNumberRef pidNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
        CFNumberRef slotNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &slotIndex);
        CFNumberRef channelsNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &channels);
        CFStringRef bundleID = CFStringCreateWithCString(NULL, capture->bundleID, kCFStringEncodingUTF8);
        CFStringRef deviceUID = CFStringCreateWithCString(NULL, capture->deviceUID, kCFStringEncodingUTF8);
        if (bundleID && deviceUID) {
            const void *keys[] = {CFSTR("pid"), CFSTR("bundleID"), CFSTR("deviceUID"), CFSTR("channels"), CFSTR("slot")};
            const void *values[] = {pidNumber, bundleID, deviceUID, channelsNumber, slotNumber};
            CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            CFArrayAppendValue(list, entry);
            CFRelease(entry);
        }
        if (bundleID) CFRelease(bundleID);
        if (deviceUID) CFRelease(deviceUID);
        CFRelease(pidNumber);
        CFRelease(slotNumber);
        CFRelease(channelsNumber);
    }
    pthread_mutex_unlock(&gClientMutex);
    return list;
}

/// ProcessOutput: copies one client's output into its ring. Lock-free: finds the slot by scanning the atomics, and
/// counts itself as a writer so RemoveDeviceClient never frees a ring being written.
static void CaptureClientOutput(UInt32 device, UInt32 clientID, const Float32 *samples, UInt32 channels, UInt32 frames,
                                Float64 sampleTime) {
    if (!gCaptureRegion || !(sampleTime >= 0)) return;
    for (UInt32 i = 0; i < JCAP_SLOTS; i++) {
        Capture *capture = &gCaptures[i];
        if (!atomic_load(&capture->live) || atomic_load(&capture->ioClientID) != clientID ||
            atomic_load(&capture->ioDevice) != device)
            continue;
        atomic_fetch_add(&capture->writers, 1);
        // Checked again now that RemoveDeviceClient would wait for this writer.
        if (atomic_load(&capture->live) && atomic_load(&capture->ioClientID) == clientID)
            jcap_write(gCaptureRegion, i, samples, channels, frames, (UInt64)sampleTime);
        atomic_fetch_sub(&capture->writers, 1);
        return;
    }
}

/// For the driver harness, which has no daemon to ask: the capture region and its size. coreaudiod never calls it.
__attribute__((visibility("default"))) void *JunctionDriver_CaptureRegion(UInt64 *outSize) {
    if (outSize) *outSize = gCaptureRegion ? JCAP_REGION_BYTES : 0;
    return gCaptureRegion;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt64 action,
                                                 void *info) {
    (void)d; (void)action; (void)info;
    UInt32 slot;
    if (Resolve(deviceID, &slot) != kKindDevice) return kAudioHardwareBadObjectError;
    Slot *s = &gSlots[slot];
    pthread_mutex_lock(&gStateMutex);
    bool companionChanged = false;
    if (s->hasPending) {
        companionChanged = HasCompanion(s->direction) != HasCompanion(s->pendingDirection);
        s->channels = s->pendingChannels;
        s->sampleRate = s->pendingSampleRate;
        s->direction = s->pendingDirection;
        s->hasPending = false;
        UpdateTargetGains(s);
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
    for (int side = 0; side < 2; side++)
        s->gain[side] = atomic_load_explicit(&s->targetGain[side], memory_order_relaxed);
    atomic_store_explicit(&s->ticksPerFrame, gHostTicksPerSecond / rate, memory_order_relaxed);
    pthread_mutex_unlock(&s->ioMutex);
    bool changed = RecordSlotState(s);
    pthread_mutex_unlock(&gStateMutex);
    if (companionChanged) NotifyDeviceList();
    if (changed) SaveConfig(true);
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
        AudioObjectID ids[2 * kMaxDevices];
        UInt32 count = 0;
        pthread_mutex_lock(&gStateMutex);
        for (UInt32 i = 0; i < kMaxDevices; i++) {
            if (!gSlots[i].active) continue;
            ids[count++] = DeviceID(i);
            if (HasCompanion(gSlots[i].direction)) ids[count++] = CompanionID(i);
        }
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
            for (UInt32 i = 0; i < kMaxDevices && uid; i++) {
                Slot *s = &gSlots[i];
                if (!s->active) continue;
                if (CFEqual(s->uid, uid)) result = DeviceID(i);
                else if (HasCompanion(s->direction) && CFEqual(s->companionUID, uid)) result = CompanionID(i);
            }
            pthread_mutex_unlock(&gStateMutex);
            *(AudioObjectID *)outData = result;
        }
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info[3] = {
            {kSelectorConfig, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
             kAudioServerPlugInCustomPropertyDataTypeNone},
            {kSelectorVersion, kAudioServerPlugInCustomPropertyDataTypeCFString,
             kAudioServerPlugInCustomPropertyDataTypeNone},
            {kSelectorClients, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
             kAudioServerPlugInCustomPropertyDataTypeNone},
        };
        if (!outData) {
            *outDataSize = sizeof(info);
            return noErr;
        }
        UInt32 fit = inDataSize / (UInt32)sizeof(info[0]);
        if (fit > 3) fit = 3;
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
    case kSelectorClients: {
        if (outData) {
            if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            *(CFPropertyListRef *)outData = CopyCapturedClients();
        }
        *outDataSize = sizeof(CFPropertyListRef);
        return noErr;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

/// The streams a device object owns in a scope: the device shows apps the sides its direction allows; its companion
/// owns the rest.
static UInt32 OwnedStreams(UInt32 slot, bool companion, AudioObjectPropertyScope scope, AudioObjectID *ids) {
    const Slot *s = &gSlots[slot];
    UInt32 count = 0;
    bool global = scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeWildcard;
    if ((global || scope == kAudioObjectPropertyScopeInput) && ShowsInput(s->direction) != companion)
        ids[count++] = InputStreamID(slot);
    if ((global || scope == kAudioObjectPropertyScopeOutput) && ShowsOutput(s->direction) != companion)
        ids[count++] = OutputStreamID(slot);
    return count;
}

/// The device's controls in a scope: a volume and a mute for each side apps see.
static UInt32 Controls(UInt32 slot, AudioObjectPropertyScope scope, AudioObjectID *ids) {
    const Slot *s = &gSlots[slot];
    UInt32 count = 0;
    bool global = scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeWildcard;
    if ((global || scope == kAudioObjectPropertyScopeOutput) && ShowsOutput(s->direction)) {
        ids[count++] = VolumeID(slot, kSideOutput);
        ids[count++] = MuteID(slot, kSideOutput);
    }
    if ((global || scope == kAudioObjectPropertyScopeInput) && ShowsInput(s->direction)) {
        ids[count++] = VolumeID(slot, kSideInput);
        ids[count++] = MuteID(slot, kSideInput);
    }
    return count;
}

/// Properties of a device and of its companion (`companion`): the same audio, with the companion hidden and
/// reachable only through its UID.
static OSStatus DeviceProperty(UInt32 slot, bool companion, const AudioObjectPropertyAddress *address,
                               UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    Slot *s = &gSlots[slot];
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, kAudioObjectPlugInObject);
    case kAudioObjectPropertyName: {
        if (!companion) RETURN_CF(s->name);
        if (outData) {
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (Junction routing)"), s->name);
        }
        *outDataSize = sizeof(CFStringRef);
        return noErr;
    }
    case kAudioObjectPropertyManufacturer: RETURN_CF(CFSTR(kManufacturer));
    case kAudioObjectPropertyElementName: {
        if (companion || address->mElement < 1 || address->mElement > s->channels || !s->channelNames ||
            (CFIndex)address->mElement > CFArrayGetCount(s->channelNames))
            return kAudioHardwareUnknownPropertyError;
        CFStringRef name = CFArrayGetValueAtIndex(s->channelNames, address->mElement - 1);
        if (CFStringGetLength(name) == 0) return kAudioHardwareUnknownPropertyError;
        RETURN_CF(name);
    }
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID ids[6];
        UInt32 count = OwnedStreams(slot, companion, address->mScope, ids);
        if (!companion) count += Controls(slot, address->mScope, ids + count);
        return ReturnIDs(ids, count, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyStreams: {
        AudioObjectID ids[2];
        return ReturnIDs(ids, OwnedStreams(slot, companion, address->mScope, ids), inDataSize, outDataSize, outData);
    }
    case kAudioObjectPropertyControlList: {
        AudioObjectID ids[4];
        UInt32 count = companion ? 0 : Controls(slot, kAudioObjectPropertyScopeGlobal, ids);
        return ReturnIDs(ids, count, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyDeviceUID: RETURN_CF(companion ? s->companionUID : s->uid);
    case kAudioDevicePropertyModelUID: RETURN_CF(CFSTR(kModelUID));
    case kAudioDevicePropertyConfigurationApplication: RETURN_CF(CFSTR(kConfigurationApp));
    case kAudioDevicePropertyTransportType: RETURN_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID ids[2] = {DeviceID(slot), CompanionID(slot)};
        return ReturnIDs(ids, HasCompanion(s->direction) ? 2 : 1, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyClockDomain: RETURN_SCALAR(UInt32, kClockDomain);
    case kAudioDevicePropertyDeviceIsAlive: RETURN_SCALAR(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: RETURN_SCALAR(UInt32, s->ioClients > 0 ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: {
        bool can = !companion && !s->hidden;
        if (address->mScope == kAudioObjectPropertyScopeInput) can = can && ShowsInput(s->direction);
        if (address->mScope == kAudioObjectPropertyScopeOutput) can = can && ShowsOutput(s->direction);
        RETURN_SCALAR(UInt32, can ? 1 : 0);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertyLatency: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: RETURN_SCALAR(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_SCALAR(UInt32, kZeroTimeStampPeriod);
    case kAudioDevicePropertyIsHidden: RETURN_SCALAR(UInt32, companion || s->hidden ? 1 : 0);
    case kAudioDevicePropertyIcon: {
        if (companion) return kAudioHardwareUnknownPropertyError;
        if (outData) {
            if (inDataSize < sizeof(CFURLRef)) return kAudioHardwareBadPropertySizeError;
            *(CFURLRef *)outData = CopyIconURL(s->icon);
        }
        *outDataSize = sizeof(CFURLRef);
        return noErr;
    }
    case kAudioDevicePropertyNominalSampleRate: RETURN_SCALAR(Float64, s->sampleRate);
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
    case kAudioObjectPropertyOwner: {
        bool onDevice = isInput ? ShowsInput(s->direction) : ShowsOutput(s->direction);
        RETURN_SCALAR(AudioObjectID, onDevice ? DeviceID(slot) : CompanionID(slot));
    }
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

/// Properties of a volume (`isVolume`) or mute control on one side of a device.
static OSStatus ControlProperty(UInt32 slot, int side, bool isVolume, const AudioObjectPropertyAddress *address,
                                UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    Slot *s = &gSlots[slot];
    AudioObjectPropertyScope scope = side == kSideOutput ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        RETURN_SCALAR(AudioClassID, isVolume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, isVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, DeviceID(slot));
    case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioControlPropertyScope: RETURN_SCALAR(AudioObjectPropertyScope, scope);
    case kAudioControlPropertyElement: RETURN_SCALAR(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    default: break;
    }
    if (!isVolume) {
        if (address->mSelector == kAudioBooleanControlPropertyValue) RETURN_SCALAR(UInt32, s->mute[side] ? 1 : 0);
        return kAudioHardwareUnknownPropertyError;
    }
    switch (address->mSelector) {
    case kAudioLevelControlPropertyScalarValue: RETURN_SCALAR(Float32, (Float32)s->volume[side]);
    case kAudioLevelControlPropertyDecibelValue: RETURN_SCALAR(Float32, ScalarToDecibels((Float32)s->volume[side]));
    case kAudioLevelControlPropertyDecibelRange: RETURN_SCALAR(AudioValueRange, ((AudioValueRange){kMinDecibels, 0}));
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar: {
        // The value to convert comes in the data buffer and is converted in place.
        if (outData) {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 *value = outData;
            *value = address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ? ScalarToDecibels(*value)
                                                                                             : DecibelsToScalar(*value);
        }
        *outDataSize = sizeof(Float32);
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
    const Slot *s = &gSlots[slot];
    OSStatus status;
    if (!s->active) {
        status = kAudioHardwareBadObjectError;
    } else {
        switch (kind) {
        case kKindDevice: status = DeviceProperty(slot, false, address, inDataSize, outDataSize, outData); break;
        case kKindCompanion:
            status = HasCompanion(s->direction) ? DeviceProperty(slot, true, address, inDataSize, outDataSize, outData)
                                                : kAudioHardwareBadObjectError;
            break;
        case kKindInputStream:
        case kKindOutputStream:
            status = StreamProperty(slot, kind == kKindInputStream, address, inDataSize, outDataSize, outData);
            break;
        default: {
            int side = kind == kKindOutputVolume || kind == kKindOutputMute ? kSideOutput : kSideInput;
            bool isVolume = kind == kKindOutputVolume || kind == kKindInputVolume;
            status = ShowsSide(s->direction, side) ? ControlProperty(slot, side, isVolume, address, inDataSize, outDataSize, outData)
                                                   : kAudioHardwareBadObjectError;
        }
        }
    }
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
    case kAudioDevicePropertyNominalSampleRate: *outIsSettable = IsDeviceKind(kind); break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: *outIsSettable = kind == kKindInputStream || kind == kKindOutputStream; break;
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue: *outIsSettable = kind == kKindOutputVolume || kind == kKindInputVolume; break;
    case kAudioBooleanControlPropertyValue: *outIsSettable = kind == kKindOutputMute || kind == kKindInputMute; break;
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

/// Asks the host to change a device's sample rate (keeping its channel count and direction).
static OSStatus RequestSampleRate(UInt32 slot, Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    Slot *s = &gSlots[slot];
    bool request = false;
    if (s->active && rate != (s->hasPending ? s->pendingSampleRate : s->sampleRate)) {
        if (!s->hasPending) {
            s->pendingChannels = s->channels;
            s->pendingDirection = s->direction;
        }
        s->pendingSampleRate = rate;
        s->hasPending = true;
        request = true;
    }
    pthread_mutex_unlock(&gStateMutex);
    if (request) RequestConfigurationChangeAsync(DeviceID(slot));
    return noErr;
}

/// A volume or mute set from outside the app (Sound settings, the volume keys, another app): applied, announced,
/// and saved in the configuration so the app sees it.
static OSStatus SetControl(UInt32 slot, int side, bool isVolume, const AudioObjectPropertyAddress *address,
                           UInt32 inDataSize, const void *inData) {
    Float64 volume = 0;
    bool mute = false;
    if (isVolume) {
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)inData;
        if (address->mSelector == kAudioLevelControlPropertyDecibelValue) value = DecibelsToScalar(value);
        else if (address->mSelector != kAudioLevelControlPropertyScalarValue) return kAudioHardwareUnknownPropertyError;
        if (!(value >= 0)) value = 0;
        if (value > 1) value = 1;
        volume = value;
    } else {
        if (address->mSelector != kAudioBooleanControlPropertyValue) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        mute = *(const UInt32 *)inData != 0;
    }
    pthread_mutex_lock(&gStateMutex);
    Slot *s = &gSlots[slot];
    if (!s->active || !ShowsSide(s->direction, side)) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareBadObjectError;
    }
    bool changed;
    if (isVolume) {
        changed = s->volume[side] != volume;
        s->volume[side] = volume;
    } else {
        changed = s->mute[side] != mute;
        s->mute[side] = mute;
    }
    UpdateTargetGains(s);
    bool recorded = changed && RecordSlotState(s);
    pthread_mutex_unlock(&gStateMutex);
    if (changed) NotifyControls(slot, side);
    if (recorded) SaveConfig(true);
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
        FreeEntries(entries, count);
        SaveConfig(false);
        return noErr;
    }
    UInt32 slot;
    ObjectKind kind = Resolve(objectID, &slot);
    switch (kind) {
    case kKindNone: return kAudioHardwareBadObjectError;
    case kKindOutputVolume: return SetControl(slot, kSideOutput, true, address, inDataSize, inData);
    case kKindOutputMute: return SetControl(slot, kSideOutput, false, address, inDataSize, inData);
    case kKindInputVolume: return SetControl(slot, kSideInput, true, address, inDataSize, inData);
    case kKindInputMute: return SetControl(slot, kSideInput, false, address, inDataSize, inData);
    default: break;
    }
    switch (address->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (!IsDeviceKind(kind)) return kAudioHardwareUnknownPropertyError;
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return RequestSampleRate(slot, *(const Float64 *)inData);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        if (IsDeviceKind(kind)) return kAudioHardwareUnknownPropertyError;
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

/// Resolves a device or companion for IO.
static bool IODevice(AudioObjectID deviceID, UInt32 *slot) {
    return IsDeviceKind(Resolve(deviceID, slot));
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (!IODevice(deviceID, &slot)) return kAudioHardwareBadObjectError;
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
            atomic_store_explicit(&s->ticksPerFrame, gHostTicksPerSecond / rate, memory_order_relaxed);
            for (int side = 0; side < 2; side++)  // start at the right level, without a ramp
                s->gain[side] = atomic_load_explicit(&s->targetGain[side], memory_order_relaxed);
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
    if (!IODevice(deviceID, &slot)) return kAudioHardwareBadObjectError;
    Slot *s = &gSlots[slot];
    pthread_mutex_lock(&s->ioMutex);
    if (s->ioClients > 0) s->ioClients--;
    pthread_mutex_unlock(&s->ioMutex);
    return noErr;
}

/// Every device counts whole periods from the same anchor on the host clock, so devices at the same rate have the
/// same time stamps whenever they started, and devices at other rates stay in a fixed ratio: one clock domain.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (!IODevice(deviceID, &slot)) return kAudioHardwareBadObjectError;
    Float64 ticksPerFrame = atomic_load_explicit(&gSlots[slot].ticksPerFrame, memory_order_relaxed);
    if (!(ticksPerFrame > 0)) ticksPerFrame = gHostTicksPerSecond / 48000;
    Float64 ticksPerPeriod = ticksPerFrame * kZeroTimeStampPeriod;
    UInt64 now = mach_absolute_time();
    UInt64 count = now > gAnchorHostTime ? (UInt64)((Float64)(now - gAnchorHostTime) / ticksPerPeriod) : 0;
    *outSampleTime = (Float64)count * kZeroTimeStampPeriod;
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)count * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID,
                                  UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)deviceID; (void)clientID;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    bool willDo = operationID == kAudioServerPlugInIOOperationReadInput ||
                  operationID == kAudioServerPlugInIOOperationWriteMix ||
                  (operationID == kAudioServerPlugInIOOperationProcessOutput && gCaptureRegion);
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

/// Scales interleaved samples by a gain that moves from `*gain` towards `target` by at most 1/kRampFrames per
/// frame, and leaves `*gain` where it got to.
static void ApplyGain(Float32 *samples, UInt32 frames, UInt32 channels, Float32 *gain, Float32 target) {
    Float32 g = *gain;
    if (g == target) {
        if (g == 1) return;
        if (g == 0) {
            memset(samples, 0, (size_t)frames * channels * sizeof(Float32));
            return;
        }
        for (size_t i = 0; i < (size_t)frames * channels; i++) samples[i] *= g;
        return;
    }
    const Float32 step = 1.0f / kRampFrames;
    for (UInt32 f = 0; f < frames; f++) {
        if (g < target) g = g + step > target ? target : g + step;
        else if (g > target) g = g - step < target ? target : g - step;
        Float32 *frame = samples + (size_t)f * channels;
        for (UInt32 c = 0; c < channels; c++) frame[c] *= g;
    }
    *gain = g;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, AudioObjectID streamID,
                              UInt32 clientID, UInt32 operationID, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    (void)streamID; (void)secondaryBuffer;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 slot;
    if (!IODevice(deviceID, &slot)) return kAudioHardwareBadObjectError;
    bool isRead = operationID == kAudioServerPlugInIOOperationReadInput;
    bool isWrite = operationID == kAudioServerPlugInIOOperationWriteMix;
    bool isProcess = operationID == kAudioServerPlugInIOOperationProcessOutput;
    if ((!isRead && !isWrite && !isProcess) || !mainBuffer || !cycle || frames == 0) return noErr;
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
    if (isProcess) {
        // One client's output before the mix, as it played it (the device's output volume isn't applied).
        CaptureClientOutput(slot, clientID, buffer, channels, frames, cycle->mOutputTime.mSampleTime);
        pthread_mutex_unlock(&s->ioMutex);
        return noErr;
    }
    int side = isRead ? kSideInput : kSideOutput;
    Float32 target = atomic_load_explicit(&s->targetGain[side], memory_order_relaxed);
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
            ApplyGain(bufferPart, chunk, channels, &s->gain[side], target);
        } else {
            memcpy(ringPart, bufferPart, bytes);
            ApplyGain(ringPart, chunk, channels, &s->gain[side], target);
        }
        done += chunk;
        position = (position + chunk) % kRingFrames;
    }
    pthread_mutex_unlock(&s->ioMutex);
    return noErr;
}
