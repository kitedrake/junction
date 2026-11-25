// Calibration measurements: one IOProc plays a test signal (a sweep, pink noise or silence) on one output channel and
// records one microphone channel in the same IO cycles, so the recording starts as the signal does and the devices'
// latency shows up as delay in it. A control thread starts a take, waits for it to finish and reads the recording; it
// can stop a take at any time, and the next IO buffer fades it out. The take's buffers belong to the control thread
// whenever no take is playing or fading out: the state hands them over with release and acquire. No locks or
// allocation after creation.
#include "JunctionKernel.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { kIdle = 0, kPlaying = 1, kStopping = 2, kDone = 3 };

struct JKMeasure {
    uint32_t micChannel;
    uint32_t capacity;
    float *signal;               // capacity frames
    float *recording;            // capacity frames
    JKConverter *converter;      // not owned
    float *scratch;              // converter channels × JK_MAX_FRAMES, when there is a converter
    // The take: written by the control thread while idle or done, read by the IOProc while playing or stopping.
    uint32_t frames;
    uint32_t channel;
    uint32_t position;           // frames played so far
    uint32_t fadeLeft;           // frames left in a stop's fade
    int fading;
    // IOProc only.
    double nextSample;
    int timed;
    // Shared.
    _Atomic uint32_t state;
    _Atomic uint32_t recorded;
    _Atomic uint64_t cycles;
    _Atomic uint64_t gaps;
};

JKMeasure *jk_measure_create(uint32_t micChannel, uint32_t capacity) {
    if (capacity == 0 || capacity > (1u << 28)) return NULL;
    JKMeasure *m = calloc(1, sizeof(JKMeasure));
    if (!m) return NULL;
    m->micChannel = micChannel;
    m->capacity = capacity;
    m->signal = calloc(capacity, sizeof(float));
    m->recording = calloc(capacity, sizeof(float));
    if (!m->signal || !m->recording) {
        jk_measure_destroy(m);
        return NULL;
    }
    atomic_init(&m->state, kIdle);
    return m;
}

void jk_measure_destroy(JKMeasure *m) {
    free(m->signal);
    free(m->recording);
    free(m->scratch);
    free(m);
}

void jk_measure_set_converter(JKMeasure *m, JKConverter *converter) {
    free(m->scratch);
    m->scratch = NULL;
    m->converter = NULL;
    if (!converter) return;
    m->scratch = calloc((size_t)jk_converter_channels(converter) * JK_MAX_FRAMES, sizeof(float));
    if (m->scratch) m->converter = converter;
}

int jk_measure_start(JKMeasure *m, const float *signal, uint32_t frames, uint32_t channel) {
    uint32_t state = atomic_load_explicit(&m->state, memory_order_acquire);
    if ((state != kIdle && state != kDone) || frames == 0 || frames > m->capacity) return 0;
    memcpy(m->signal, signal, sizeof(float) * frames);
    m->frames = frames;
    m->channel = channel;
    m->position = 0;
    m->fadeLeft = 0;
    m->fading = 0;
    atomic_store_explicit(&m->recorded, 0, memory_order_relaxed);
    atomic_store_explicit(&m->state, kPlaying, memory_order_release);
    return 1;
}

void jk_measure_stop(JKMeasure *m) {
    uint32_t expected = kPlaying;
    atomic_compare_exchange_strong_explicit(&m->state, &expected, kStopping, memory_order_acq_rel, memory_order_acquire);
}

void jk_measure_reset(JKMeasure *m) {
    atomic_store_explicit(&m->state, kIdle, memory_order_release);
}

int jk_measure_is_done(const JKMeasure *m) {
    return atomic_load_explicit((_Atomic uint32_t *)&m->state, memory_order_acquire) == kDone;
}

uint32_t jk_measure_recorded(const JKMeasure *m) {
    return atomic_load_explicit((_Atomic uint32_t *)&m->recorded, memory_order_acquire);
}

const float *jk_measure_recording(const JKMeasure *m) { return m->recording; }

uint64_t jk_measure_cycles(const JKMeasure *m) {
    return atomic_load_explicit((_Atomic uint64_t *)&m->cycles, memory_order_acquire);
}

uint64_t jk_measure_dropouts(const JKMeasure *m) {
    uint64_t gaps = atomic_load_explicit((_Atomic uint64_t *)&m->gaps, memory_order_relaxed);
    if (m->converter) gaps += jk_converter_underrun_count(m->converter) + jk_converter_overrun_count(m->converter);
    return gaps;
}

/// Channel `channel` counted across a buffer list's buffers: its first sample, the stride between frames and the
/// frames the buffer holds. NULL when the list doesn't have that channel.
static float *FindChannel(const AudioBufferList *list, uint32_t channel, uint32_t *stride, uint32_t *frames) {
    if (!list) return NULL;
    uint32_t base = 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        uint32_t channels = buffer->mNumberChannels;
        if (channel < base + channels) {
            if (!buffer->mData) return NULL;
            *stride = channels;
            *frames = buffer->mDataByteSize / (uint32_t)(sizeof(float) * channels);
            return (float *)buffer->mData + (channel - base);
        }
        base += channels;
    }
    return NULL;
}

OSStatus jk_measure_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                           const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                           void *clientData) {
    (void)device; (void)now; (void)inputTime;
    JKMeasure *m = clientData;
    uint32_t frames = 0;
    if (output) {
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            AudioBuffer *buffer = &output->mBuffers[b];
            if (!buffer->mData) continue;
            memset(buffer->mData, 0, buffer->mDataByteSize);
            if (!frames && buffer->mNumberChannels)
                frames = buffer->mDataByteSize / (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        }
    }
    if (!m) return noErr;

    // The microphone: one of the input channels, or the converter's output for a microphone at another rate.
    const float *mic = NULL;
    uint32_t micStride = 1, micFrames = 0;
    if (m->converter) {
        uint32_t count = frames > JK_MAX_FRAMES ? JK_MAX_FRAMES : frames;
        jk_converter_read(m->converter, m->scratch, JK_MAX_FRAMES, count, outputTime);
        if (m->micChannel < jk_converter_channels(m->converter)) {
            mic = m->scratch + (size_t)m->micChannel * JK_MAX_FRAMES;
            micFrames = count;
        }
    } else {
        mic = FindChannel(input, m->micChannel, &micStride, &micFrames);
        if (!frames) frames = micFrames;
    }

    // A jump in the output's sample time means IO cycles were lost.
    if (outputTime && (outputTime->mFlags & kAudioTimeStampSampleTimeValid)) {
        if (m->timed && fabs(outputTime->mSampleTime - m->nextSample) > 0.5)
            atomic_fetch_add_explicit(&m->gaps, 1, memory_order_relaxed);
        m->nextSample = outputTime->mSampleTime + frames;
        m->timed = 1;
    }

    uint32_t state = atomic_load_explicit(&m->state, memory_order_acquire);
    if (state == kPlaying || state == kStopping) {
        uint32_t outStride = 1, outFrames = 0;
        float *out = FindChannel(output, m->channel, &outStride, &outFrames);
        uint32_t recorded = atomic_load_explicit(&m->recorded, memory_order_relaxed);
        if (state == kStopping && !m->fading) {
            m->fading = 1;
            m->fadeLeft = JK_MEASURE_FADE_FRAMES;
        }
        for (uint32_t i = 0; i < frames; i++) {
            float sample = m->position < m->frames ? m->signal[m->position] : 0;
            if (state == kStopping) {
                if (m->fadeLeft == 0) break;
                sample *= (float)m->fadeLeft / JK_MEASURE_FADE_FRAMES;
                m->fadeLeft--;
            } else if (recorded < m->frames) {
                m->recording[recorded++] = mic && i < micFrames ? mic[(size_t)i * micStride] : 0;
            }
            if (out && i < outFrames) out[(size_t)i * outStride] = sample;
            m->position++;
            if (state == kPlaying && recorded >= m->frames) break;
        }
        if (state == kPlaying) {
            atomic_store_explicit(&m->recorded, recorded, memory_order_release);
            if (recorded >= m->frames) {
                uint32_t expected = kPlaying;
                if (!atomic_compare_exchange_strong_explicit(&m->state, &expected, kDone, memory_order_acq_rel,
                                                             memory_order_acquire)) {
                    atomic_store_explicit(&m->state, kIdle, memory_order_release);  // stopped as it finished
                }
            }
        } else if (m->fadeLeft == 0) {
            atomic_store_explicit(&m->state, kIdle, memory_order_release);
        }
    }
    atomic_fetch_add_explicit(&m->cycles, 1, memory_order_release);
    return noErr;
}
