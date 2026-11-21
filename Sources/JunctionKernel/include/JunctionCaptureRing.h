// Per-app capture: the layout of the shared memory region in which Junction's driver keeps what each app plays into
// one of its virtual devices, before the device mixes it with everything else. Shared by the driver (the writer,
// inside coreaudiod), the render kernel and the Swift code (readers, in Junction or Junction Helper) and the driver
// harness, so it is plain C with no dependencies beyond the standard headers.
//
// The region is one block of memory: a header with JCAP_SLOTS client slots, then one ring per slot. A slot belongs to
// one client of one device (an app's process, as the host reports it in AddDeviceClient) while that client exists.
// Its ring is indexed by the device's sample time, so the rings of several clients of one device line up frame for
// frame. Each ring has one writer (the driver's IO thread, in ProcessOutput) and any number of readers, which never
// write: a reader keeps its own position, and checks after copying that the writer didn't overwrite what it copied
// (a seqlock on the frames: `writing` is raised before the frames change, `end` after).
//
// Nothing here locks or allocates, so readers can run on an audio thread.
#ifndef JUNCTION_CAPTURE_RING_H
#define JUNCTION_CAPTURE_RING_H

#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JCAP_MAGIC 0x4A434150u            // 'JCAP'
#define JCAP_LAYOUT 1                     // bumped when the layout changes
#define JCAP_SLOTS 32                     // clients captured at once (further clients aren't)
#define JCAP_FRAMES 8192                  // frames per ring (170 ms at 48 kHz)
#define JCAP_MAX_CHANNELS 8               // a client's first channels on the device, at most this many
#define JCAP_TEXT 128                     // bytes for a bundle ID or device UID, with the terminating zero
#define JCAP_NONE UINT64_MAX              // `start` before the client has written anything

/// One client slot. `sequence` is a seqlock over the descriptive fields: odd while the driver changes them. A live
/// slot's sequence identifies the client: it changes when the client goes and another takes the slot.
typedef struct {
    uint32_t sequence;
    uint32_t live;                        // 1 while a client owns the slot
    int32_t pid;
    uint32_t channels;                    // channels kept per frame (the device's first ones)
    char bundleID[JCAP_TEXT];             // the client process's bundle ID
    char deviceUID[JCAP_TEXT];            // the virtual device it plays into (not its hidden companion)
    // Device sample times, written by the IO thread.
    uint64_t start;                       // first frame kept since the frames before it were lost (JCAP_NONE: none yet)
    uint64_t end;                         // just past the last frame written
    uint64_t writing;                     // just past the frames being written (raised before they change)
    uint64_t overruns;                    // IO cycles longer than the ring, of which only the end was kept
    uint8_t reserved[192];
} JCapSlot;

typedef struct {
    uint32_t magic;
    uint32_t layout;
    uint32_t slotCount;
    uint32_t frames;
    uint32_t maxChannels;
    uint32_t reserved0;
    uint64_t session;                     // a new value each time the driver loads: a region from before is stale
    uint64_t hostAnchor;                  // host time at which every device's sample time was 0 (the shared clock)
    uint8_t reserved[88];
    JCapSlot slots[JCAP_SLOTS];
} JCapHeader;

#define JCAP_RING_BYTES ((uint64_t)JCAP_FRAMES * JCAP_MAX_CHANNELS * sizeof(float))
/// The header rounded up to 16 KiB pages, then the rings.
#define JCAP_AUDIO_OFFSET ((((uint64_t)sizeof(JCapHeader)) + 16383u) & ~(uint64_t)16383u)
#define JCAP_REGION_BYTES (JCAP_AUDIO_OFFSET + (uint64_t)JCAP_SLOTS * JCAP_RING_BYTES)

/// The same, for Swift (which doesn't import the macro).
static inline uint64_t jcap_region_bytes(void) { return JCAP_REGION_BYTES; }

static inline JCapHeader *jcap_header(void *region) { return (JCapHeader *)region; }
static inline float *jcap_ring(void *region, uint32_t slot) {
    return (float *)((uint8_t *)region + JCAP_AUDIO_OFFSET + (uint64_t)slot * JCAP_RING_BYTES);
}
static inline uint64_t jcap_load(const uint64_t *value) { return __atomic_load_n(value, __ATOMIC_ACQUIRE); }
static inline uint32_t jcap_load32(const uint32_t *value) { return __atomic_load_n(value, __ATOMIC_ACQUIRE); }

/// Whether `region` (of `size` bytes) is a capture region this code understands.
static inline int jcap_valid(const void *region, uint64_t size) {
    if (!region || size < JCAP_REGION_BYTES) return 0;
    const JCapHeader *h = (const JCapHeader *)region;
    return h->magic == JCAP_MAGIC && h->layout == JCAP_LAYOUT && h->slotCount == JCAP_SLOTS &&
           h->frames == JCAP_FRAMES && h->maxChannels == JCAP_MAX_CHANNELS;
}

// MARK: Writer (the driver)

/// Fills in a new region's header. The memory must be zeroed.
static inline void jcap_init(void *region, uint64_t session, uint64_t hostAnchor) {
    JCapHeader *h = jcap_header(region);
    h->layout = JCAP_LAYOUT;
    h->slotCount = JCAP_SLOTS;
    h->frames = JCAP_FRAMES;
    h->maxChannels = JCAP_MAX_CHANNELS;
    h->session = session;
    h->hostAnchor = hostAnchor;
    __atomic_store_n(&h->magic, JCAP_MAGIC, __ATOMIC_RELEASE);
}

static inline void jcap_copy_text(char *out, const char *text) {
    size_t n = text ? strlen(text) : 0;
    if (n >= JCAP_TEXT) n = JCAP_TEXT - 1;
    if (n) memcpy(out, text, n);
    memset(out + n, 0, JCAP_TEXT - n);
}

/// Gives a slot to a client (call only when no IO thread writes the slot). Returns the slot's new sequence.
static inline uint32_t jcap_claim(void *region, uint32_t slot, int32_t pid, const char *bundleID, const char *deviceUID,
                                  uint32_t channels) {
    JCapSlot *s = &jcap_header(region)->slots[slot];
    uint32_t sequence = s->sequence | 1u;
    __atomic_store_n(&s->sequence, sequence, __ATOMIC_RELAXED);  // odd: changing
    __atomic_thread_fence(__ATOMIC_RELEASE);
    s->pid = pid;
    s->channels = channels > JCAP_MAX_CHANNELS ? JCAP_MAX_CHANNELS : (channels ? channels : 1);
    jcap_copy_text(s->bundleID, bundleID);
    jcap_copy_text(s->deviceUID, deviceUID);
    __atomic_store_n(&s->start, JCAP_NONE, __ATOMIC_RELAXED);
    __atomic_store_n(&s->end, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&s->writing, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&s->overruns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&s->live, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&s->sequence, sequence + 1, __ATOMIC_RELEASE);  // even: stable
    return sequence + 1;
}

/// Takes a slot back from its client (call only when no IO thread writes the slot).
static inline void jcap_release(void *region, uint32_t slot) {
    JCapSlot *s = &jcap_header(region)->slots[slot];
    uint32_t sequence = s->sequence | 1u;
    __atomic_store_n(&s->sequence, sequence, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&s->live, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&s->sequence, sequence + 1, __ATOMIC_RELEASE);
}

/// Stores one IO cycle of a client's output: `frames` interleaved frames of `deviceChannels` channels whose first
/// frame is at device sample time `time`. A gap since the last cycle is filled with silence; a cycle longer than the
/// ring keeps only its end (counted in `overruns`). Real-time safe: no locks, no allocation, bounded work.
static inline void jcap_write(void *region, uint32_t slot, const float *samples, uint32_t deviceChannels,
                              uint32_t frames, uint64_t time) {
    JCapSlot *s = &jcap_header(region)->slots[slot];
    if (!samples || frames == 0 || deviceChannels == 0) return;
    if (frames > JCAP_FRAMES) {
        samples += (size_t)(frames - JCAP_FRAMES) * deviceChannels;
        time += frames - JCAP_FRAMES;
        frames = JCAP_FRAMES;
        __atomic_store_n(&s->overruns, s->overruns + 1, __ATOMIC_RELAXED);
    }
    uint32_t channels = s->channels;
    uint32_t copied = channels < deviceChannels ? channels : deviceChannels;
    float *ring = jcap_ring(region, slot);
    uint64_t start = s->start, end = s->end;
    uint64_t blockEnd = time + frames;
    // Where the frames to write begin: earlier for a short gap (filled with silence).
    uint64_t from = time;
    int reset = start == JCAP_NONE || time >= end + JCAP_FRAMES || blockEnd + JCAP_FRAMES <= end;
    if (reset) {
        start = time;  // nothing usable before this cycle (the first one, a long pause, or time went back)
        end = blockEnd;
    } else {
        if (time > end) from = end;
        if (blockEnd > end) end = blockEnd;
    }
    if (blockEnd - from > JCAP_FRAMES) from = blockEnd - JCAP_FRAMES;  // older frames would be overwritten anyway
    __atomic_store_n(&s->writing, end, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    for (uint64_t t = from; t < blockEnd; t++) {
        float *frame = ring + (size_t)(t % JCAP_FRAMES) * channels;
        if (t < time) {
            memset(frame, 0, (size_t)channels * sizeof(float));
            continue;
        }
        const float *in = samples + (size_t)(t - time) * deviceChannels;
        for (uint32_t c = 0; c < copied; c++) frame[c] = in[c];
        for (uint32_t c = copied; c < channels; c++) frame[c] = 0;
    }
    if (start != s->start) __atomic_store_n(&s->start, start, __ATOMIC_RELEASE);
    __atomic_store_n(&s->end, end, __ATOMIC_RELEASE);
}

// MARK: Readers

/// A slot's client as a reader sees it.
typedef struct {
    uint32_t sequence;
    uint32_t live;
    int32_t pid;
    uint32_t channels;
    char bundleID[JCAP_TEXT];
    char deviceUID[JCAP_TEXT];
    uint64_t end;
    uint64_t overruns;
} JCapClient;

/// Reads a slot's description consistently. Returns 0 if the driver kept changing it (try again later).
static inline int jcap_client(const void *region, uint32_t slot, JCapClient *out) {
    const JCapSlot *s = &((const JCapHeader *)region)->slots[slot];
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t before = jcap_load32(&s->sequence);
        if (before & 1u) continue;
        out->sequence = before;
        out->live = s->live;
        out->pid = s->pid;
        out->channels = s->channels;
        memcpy(out->bundleID, s->bundleID, JCAP_TEXT);
        memcpy(out->deviceUID, s->deviceUID, JCAP_TEXT);
        out->bundleID[JCAP_TEXT - 1] = 0;
        out->deviceUID[JCAP_TEXT - 1] = 0;
        out->end = jcap_load(&s->end);
        out->overruns = jcap_load(&s->overruns);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&s->sequence, __ATOMIC_RELAXED) == before) return 1;
    }
    return 0;
}

/// Whether a slot still belongs to the client that had `sequence`, and if so how far it has written.
static inline int jcap_slot_end(const void *region, uint32_t slot, uint32_t sequence, uint64_t *end) {
    const JCapSlot *s = &((const JCapHeader *)region)->slots[slot];
    if (jcap_load32(&s->sequence) != sequence || !jcap_load32(&s->live)) return 0;
    *end = jcap_load(&s->end);
    return 1;
}

/// Result of `jcap_read`.
enum { JCAP_READ_GONE = -1 };

/// Copies frames [time, time + frames) of a slot into `out` (interleaved, `outChannels` per frame; channels the client
/// doesn't have are silent). Frames the client hasn't written, or whose audio was lost, are silent. Returns how many
/// frames were overwritten by the writer before they could be read (they are silent too), or JCAP_READ_GONE when the
/// slot no longer belongs to the client with `sequence`.
static inline int64_t jcap_read(const void *region, uint32_t slot, uint32_t sequence, uint64_t time, uint32_t frames,
                                float *out, uint32_t outChannels) {
    const JCapSlot *s = &((const JCapHeader *)region)->slots[slot];
    memset(out, 0, (size_t)frames * outChannels * sizeof(float));
    if (jcap_load32(&s->sequence) != sequence || !jcap_load32(&s->live)) return JCAP_READ_GONE;
    uint32_t channels = s->channels;
    uint32_t copied = channels < outChannels ? channels : outChannels;
    uint64_t start = jcap_load(&s->start), end = jcap_load(&s->end);
    if (start == JCAP_NONE) return 0;
    uint64_t from = time > start ? time : start;
    if (end > JCAP_FRAMES && from < end - JCAP_FRAMES) from = end - JCAP_FRAMES;
    uint64_t to = time + frames < end ? time + frames : end;
    const float *ring = jcap_ring((void *)region, slot);
    for (uint64_t t = from; t < to; t++) {
        const float *frame = ring + (size_t)(t % JCAP_FRAMES) * channels;
        float *o = out + (size_t)(t - time) * outChannels;
        for (uint32_t c = 0; c < copied; c++) o[c] = frame[c];
    }
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (__atomic_load_n(&s->sequence, __ATOMIC_RELAXED) != sequence) {
        memset(out, 0, (size_t)frames * outChannels * sizeof(float));
        return JCAP_READ_GONE;
    }
    // Frames the writer has started to overwrite since: silence instead of a mix of two laps.
    uint64_t writing = __atomic_load_n(&s->writing, __ATOMIC_RELAXED);
    int64_t lost = 0;
    if (from < to && writing > JCAP_FRAMES && from < writing - JCAP_FRAMES) {
        uint64_t bad = writing - JCAP_FRAMES < to ? writing - JCAP_FRAMES : to;
        lost = (int64_t)(bad - from);
        memset(out + (size_t)(from - time) * outChannels, 0, (size_t)lost * outChannels * sizeof(float));
    }
    return lost;
}

#ifdef __cplusplus
}
#endif

#endif
