#include "JunctionKernel.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct JKRenderer {
    uint32_t inputChannels;
    uint32_t outputChannels;
    uint32_t routeCount;
    uint32_t *sources;
    uint32_t *destinations;
    _Atomic uint32_t *targetGains;   // float bit patterns, written by any thread
    float *currentGains;             // audio thread only
    _Atomic uint32_t targetMaster;
    float currentMaster;
    _Atomic uint32_t *inputPeaks;    // float bit patterns of non-negative values: they order like the integers
    _Atomic uint32_t *outputPeaks;
    _Atomic uint64_t cycles;
    _Atomic uint64_t mismatches;
    // Fade applied to everything the sink receives, for cross-fading a rebuilt sink with its replacement.
    _Atomic uint32_t fadeTarget;     // float bits, 0…1
    _Atomic uint32_t fadeFrames;     // frames for a full 0 → 1 ramp
    _Atomic uint32_t fadeLevel;      // float bits: where the fade stood after the last cycle
    float fade;                      // audio thread only
    // Per-cycle channel tables (audio thread only), sized for the expected layout.
    const float **inputs;
    uint32_t *inputStrides;
    float **outputs;
    uint32_t *outputStrides;
};

static inline uint32_t Bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}

static inline float Float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

JKRenderer *jk_renderer_create(uint32_t inputChannels, uint32_t outputChannels, uint32_t routeCount,
                               const uint32_t *sources, const uint32_t *destinations, const float *gains) {
    JKRenderer *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->inputChannels = inputChannels;
    r->outputChannels = outputChannels;
    r->routeCount = routeCount;
    size_t routes = routeCount ? routeCount : 1, ins = inputChannels ? inputChannels : 1,
           outs = outputChannels ? outputChannels : 1;
    r->sources = calloc(routes, sizeof *r->sources);
    r->destinations = calloc(routes, sizeof *r->destinations);
    r->targetGains = calloc(routes, sizeof *r->targetGains);
    r->currentGains = calloc(routes, sizeof *r->currentGains);
    r->inputPeaks = calloc(ins, sizeof *r->inputPeaks);
    r->outputPeaks = calloc(outs, sizeof *r->outputPeaks);
    r->inputs = calloc(ins, sizeof *r->inputs);
    r->inputStrides = calloc(ins, sizeof *r->inputStrides);
    r->outputs = calloc(outs, sizeof *r->outputs);
    r->outputStrides = calloc(outs, sizeof *r->outputStrides);
    if (!r->sources || !r->destinations || !r->targetGains || !r->currentGains || !r->inputPeaks || !r->outputPeaks ||
        !r->inputs || !r->inputStrides || !r->outputs || !r->outputStrides) {
        jk_renderer_destroy(r);
        return NULL;
    }
    for (uint32_t i = 0; i < routeCount; i++) {
        r->sources[i] = sources ? sources[i] : 0;
        r->destinations[i] = destinations ? destinations[i] : 0;
        float gain = gains ? gains[i] : 1.0f;
        atomic_init(&r->targetGains[i], Bits(gain));
        r->currentGains[i] = gain;  // start at the target: no fade-in from silence on (re)build
    }
    atomic_init(&r->targetMaster, Bits(1.0f));
    r->currentMaster = 1.0f;
    atomic_init(&r->fadeTarget, Bits(1.0f));
    atomic_init(&r->fadeFrames, 1);
    atomic_init(&r->fadeLevel, Bits(1.0f));
    r->fade = 1.0f;
    return r;
}

void jk_renderer_destroy(JKRenderer *r) {
    if (!r) return;
    free(r->sources);
    free(r->destinations);
    free((void *)r->targetGains);
    free(r->currentGains);
    free((void *)r->inputPeaks);
    free((void *)r->outputPeaks);
    free((void *)r->inputs);
    free(r->inputStrides);
    free(r->outputs);
    free(r->outputStrides);
    free(r);
}

void jk_renderer_set_route_gain(JKRenderer *r, uint32_t route, float gain) {
    if (route < r->routeCount && isfinite(gain)) atomic_store_explicit(&r->targetGains[route], Bits(gain), memory_order_relaxed);
}

void jk_renderer_set_master_gain(JKRenderer *r, float gain) {
    if (isfinite(gain)) atomic_store_explicit(&r->targetMaster, Bits(gain), memory_order_relaxed);
}

static inline float Clamp01(float value) {
    return value < 0 ? 0 : (value > 1 ? 1 : value);
}

void jk_renderer_fade(JKRenderer *r, float target, uint32_t frames) {
    if (!isfinite(target)) return;
    atomic_store_explicit(&r->fadeFrames, frames ? frames : 1, memory_order_relaxed);
    atomic_store_explicit(&r->fadeTarget, Bits(Clamp01(target)), memory_order_release);
}

void jk_renderer_set_fade_now(JKRenderer *r, float level) {
    if (!isfinite(level)) return;
    float value = Clamp01(level);
    r->fade = value;
    atomic_store_explicit(&r->fadeLevel, Bits(value), memory_order_relaxed);
    atomic_store_explicit(&r->fadeTarget, Bits(value), memory_order_release);
}

float jk_renderer_fade_level(const JKRenderer *r) {
    return Float(atomic_load_explicit((_Atomic uint32_t *)&r->fadeLevel, memory_order_relaxed));
}

float jk_renderer_take_input_peak(JKRenderer *r, uint32_t channel) {
    if (channel >= r->inputChannels) return 0;
    return Float(atomic_exchange_explicit(&r->inputPeaks[channel], 0, memory_order_relaxed));
}

float jk_renderer_take_output_peak(JKRenderer *r, uint32_t channel) {
    if (channel >= r->outputChannels) return 0;
    return Float(atomic_exchange_explicit(&r->outputPeaks[channel], 0, memory_order_relaxed));
}

uint64_t jk_renderer_cycle_count(const JKRenderer *r) {
    return atomic_load_explicit((_Atomic uint64_t *)&r->cycles, memory_order_relaxed);
}

uint64_t jk_renderer_layout_mismatch_count(const JKRenderer *r) {
    return atomic_load_explicit((_Atomic uint64_t *)&r->mismatches, memory_order_relaxed);
}

static inline void RaisePeak(_Atomic uint32_t *slot, float peak) {
    uint32_t bits = Bits(peak);
    uint32_t old = atomic_load_explicit(slot, memory_order_relaxed);
    while (bits > old && !atomic_compare_exchange_weak_explicit(slot, &old, bits, memory_order_relaxed,
                                                                 memory_order_relaxed)) {
    }
}

OSStatus jk_renderer_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                            const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                            void *clientData) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    JKRenderer *r = clientData;
    if (!r) return noErr;
    atomic_fetch_add_explicit(&r->cycles, 1, memory_order_relaxed);

    uint32_t frames = UINT32_MAX;
    uint32_t outputCount = 0;
    if (output) {
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            AudioBuffer *buffer = &output->mBuffers[b];
            if (!buffer->mData || buffer->mNumberChannels == 0) continue;
            memset(buffer->mData, 0, buffer->mDataByteSize);  // other sub-devices' outputs stay silent
            uint32_t channels = buffer->mNumberChannels;
            uint32_t bufferFrames = buffer->mDataByteSize / (uint32_t)(sizeof(float) * channels);
            if (bufferFrames < frames) frames = bufferFrames;
            for (uint32_t c = 0; c < channels; c++, outputCount++) {
                if (outputCount < r->outputChannels) {
                    r->outputs[outputCount] = (float *)buffer->mData + c;
                    r->outputStrides[outputCount] = channels;
                }
            }
        }
    }
    uint32_t inputCount = 0;
    if (input) {
        for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &input->mBuffers[b];
            uint32_t channels = buffer->mNumberChannels;
            if (channels == 0) continue;
            uint32_t bufferFrames = buffer->mData ? buffer->mDataByteSize / (uint32_t)(sizeof(float) * channels) : 0;
            if (buffer->mData && bufferFrames < frames) frames = bufferFrames;
            for (uint32_t c = 0; c < channels; c++, inputCount++) {
                if (inputCount < r->inputChannels) {
                    r->inputs[inputCount] = buffer->mData ? (const float *)buffer->mData + c : NULL;
                    r->inputStrides[inputCount] = channels;
                }
            }
        }
    }
    if (inputCount != r->inputChannels || outputCount < r->outputChannels)
        atomic_fetch_add_explicit(&r->mismatches, 1, memory_order_relaxed);
    if (frames == UINT32_MAX || frames == 0) return noErr;
    uint32_t availableInputs = inputCount < r->inputChannels ? inputCount : r->inputChannels;
    uint32_t availableOutputs = outputCount < r->outputChannels ? outputCount : r->outputChannels;

    for (uint32_t c = 0; c < availableInputs; c++) {
        const float *samples = r->inputs[c];
        if (!samples) continue;
        uint32_t stride = r->inputStrides[c];
        float peak = 0;
        for (uint32_t f = 0; f < frames; f++) {
            float v = fabsf(samples[(size_t)f * stride]);
            if (v > peak) peak = v;
        }
        if (peak > 0 && isfinite(peak)) RaisePeak(&r->inputPeaks[c], peak);
    }

    float fadeTarget = Float(atomic_load_explicit(&r->fadeTarget, memory_order_acquire));
    float fadeStart = r->fade;
    int silent = fadeStart == 0 && fadeTarget == 0;  // faded out: outputs stay zeroed

    float masterStart = r->currentMaster;
    float masterEnd = Float(atomic_load_explicit(&r->targetMaster, memory_order_relaxed));
    float step = 1.0f / (float)frames;
    for (uint32_t i = 0; i < r->routeCount; i++) {
        uint32_t s = r->sources[i], d = r->destinations[i];
        float target = Float(atomic_load_explicit(&r->targetGains[i], memory_order_relaxed));
        float start = r->currentGains[i] * masterStart;
        float end = target * masterEnd;
        r->currentGains[i] = target;
        if (silent || s >= availableInputs || d >= availableOutputs || !r->inputs[s]) continue;
        if (start == 0 && end == 0) continue;
        const float *in = r->inputs[s];
        float *out = r->outputs[d];
        uint32_t inStride = r->inputStrides[s], outStride = r->outputStrides[d];
        if (start == end) {
            for (uint32_t f = 0; f < frames; f++) out[(size_t)f * outStride] += in[(size_t)f * inStride] * end;
        } else {
            float delta = (end - start) * step;
            float gain = start;
            for (uint32_t f = 0; f < frames; f++) {
                gain += delta;
                out[(size_t)f * outStride] += in[(size_t)f * inStride] * gain;
            }
        }
    }
    r->currentMaster = masterEnd;

    if (!silent && !(fadeStart == 1 && fadeTarget == 1)) {
        float rampFrames = (float)atomic_load_explicit(&r->fadeFrames, memory_order_relaxed);
        float fadeStep = 1.0f / (rampFrames > 0 ? rampFrames : 1.0f);
        for (uint32_t c = 0; c < availableOutputs; c++) {
            float *samples = r->outputs[c];
            uint32_t stride = r->outputStrides[c];
            float gain = fadeStart;
            for (uint32_t f = 0; f < frames; f++) {
                if (gain < fadeTarget) {
                    gain += fadeStep;
                    if (gain > fadeTarget) gain = fadeTarget;
                } else if (gain > fadeTarget) {
                    gain -= fadeStep;
                    if (gain < fadeTarget) gain = fadeTarget;
                }
                samples[(size_t)f * stride] *= gain;
            }
        }
        float travel = fadeStep * (float)frames, distance = fadeTarget - fadeStart;
        r->fade = fabsf(distance) <= travel ? fadeTarget : fadeStart + (distance > 0 ? travel : -travel);
        atomic_store_explicit(&r->fadeLevel, Bits(r->fade), memory_order_relaxed);
    }

    for (uint32_t c = 0; c < availableOutputs; c++) {
        const float *samples = r->outputs[c];
        uint32_t stride = r->outputStrides[c];
        float peak = 0;
        for (uint32_t f = 0; f < frames; f++) {
            float v = fabsf(samples[(size_t)f * stride]);
            if (v > peak) peak = v;
        }
        if (peak > 0 && isfinite(peak)) RaisePeak(&r->outputPeaks[c], peak);
    }
    return noErr;
}
