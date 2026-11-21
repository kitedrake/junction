// Per-app capture: reads what an app played into one of Junction's devices from the driver's shared rings and feeds
// it to a converter, which the renderer then reads like any converted device. Runs on the sink's audio thread: no
// locks, no allocation after jk_capture_create.
#include "JunctionKernel.h"
#include "JunctionCaptureRing.h"

#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct JKCapture {
    const void *region;
    uint32_t slotCount;
    uint32_t slots[JK_CAPTURE_MAX_SLOTS];
    uint32_t sequences[JK_CAPTURE_MAX_SLOTS];
    uint32_t channels;
    JKConverter *converter;
    double ticksPerFrame;            // host ticks per device frame: the driver's clock is the host clock
    uint64_t hostAnchor;             // host time of the devices' sample time 0
    float *mix;                      // JK_MAX_FRAMES * channels, interleaved
    float *scratch;
    uint64_t position;               // device sample time of the next frame to pass on (audio thread only)
    int started;
    _Atomic uint64_t frames;
    _Atomic uint64_t overruns;
};

JKCapture *jk_capture_create(const void *region, uint64_t regionSize, const uint32_t *slots, const uint32_t *sequences,
                             uint32_t slotCount, uint32_t channels, double sampleRate, JKConverter *converter) {
    if (!jcap_valid(region, regionSize) || !slots || !sequences || slotCount == 0 || slotCount > JK_CAPTURE_MAX_SLOTS ||
        channels == 0 || channels > JCAP_MAX_CHANNELS || !(sampleRate > 0) || !converter ||
        jk_converter_channels(converter) != channels)
        return NULL;
    for (uint32_t i = 0; i < slotCount; i++) if (slots[i] >= JCAP_SLOTS) return NULL;
    JKCapture *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->mix = calloc((size_t)JK_MAX_FRAMES * channels, sizeof(float));
    c->scratch = calloc((size_t)JK_MAX_FRAMES * channels, sizeof(float));
    if (!c->mix || !c->scratch) {
        jk_capture_destroy(c);
        return NULL;
    }
    c->region = region;
    c->slotCount = slotCount;
    memcpy(c->slots, slots, slotCount * sizeof *slots);
    memcpy(c->sequences, sequences, slotCount * sizeof *sequences);
    c->channels = channels;
    c->converter = converter;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double ticksPerSecond = timebase.numer ? 1e9 * timebase.denom / timebase.numer : 1e9;
    c->ticksPerFrame = ticksPerSecond / sampleRate;
    c->hostAnchor = ((const JCapHeader *)region)->hostAnchor;
    return c;
}

void jk_capture_destroy(JKCapture *c) {
    free(c->mix);
    free(c->scratch);
    free(c);
}

void jk_capture_pump(JKCapture *c) {
    uint64_t latest = 0;
    int any = 0;
    for (uint32_t i = 0; i < c->slotCount; i++) {
        uint64_t end;
        if (!jcap_slot_end(c->region, c->slots[i], c->sequences[i], &end)) continue;
        any = 1;
        if (end > latest) latest = end;
    }
    if (!any || latest == 0) return;  // every client gone or silent so far: the converter fades to silence
    if (!c->started || latest + JCAP_FRAMES < c->position) {
        c->position = latest;  // start at the newest frame (also after the driver's time went back)
        c->started = 1;
        return;
    }
    if (latest <= c->position) return;
    if (latest - c->position > JCAP_FRAMES - JK_MAX_FRAMES) {
        // Fell behind by most of the ring: skip ahead rather than read what is being overwritten.
        c->position = latest - JCAP_FRAMES / 2;
        atomic_fetch_add_explicit(&c->overruns, 1, memory_order_relaxed);
    }
    while (c->position < latest) {
        uint64_t left = latest - c->position;
        uint32_t chunk = left < JK_MAX_FRAMES ? (uint32_t)left : JK_MAX_FRAMES;
        size_t samples = (size_t)chunk * c->channels;
        memset(c->mix, 0, samples * sizeof(float));
        for (uint32_t i = 0; i < c->slotCount; i++) {
            int64_t lost = jcap_read(c->region, c->slots[i], c->sequences[i], c->position, chunk, c->scratch, c->channels);
            if (lost == JCAP_READ_GONE) continue;
            if (lost > 0) atomic_fetch_add_explicit(&c->overruns, 1, memory_order_relaxed);
            for (size_t s = 0; s < samples; s++) c->mix[s] += c->scratch[s];
        }
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = c->channels;
        list.mBuffers[0].mDataByteSize = (UInt32)(samples * sizeof(float));
        list.mBuffers[0].mData = c->mix;
        AudioTimeStamp time;
        memset(&time, 0, sizeof time);
        time.mSampleTime = (Float64)c->position;
        time.mHostTime = c->hostAnchor + (UInt64)((double)c->position * c->ticksPerFrame);
        time.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
        jk_converter_write(c->converter, &list, &time);
        c->position += chunk;
        atomic_fetch_add_explicit(&c->frames, chunk, memory_order_relaxed);
    }
}

uint64_t jk_capture_frame_count(const JKCapture *c) { return atomic_load_explicit(&c->frames, memory_order_relaxed); }
uint64_t jk_capture_overrun_count(const JKCapture *c) { return atomic_load_explicit(&c->overruns, memory_order_relaxed); }
