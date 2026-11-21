// Effect chains for the renderer: the built-in effects (gain, pan, mono, noise gate) and Audio Units, processed in
// place on non-interleaved channels. Everything a chain needs on the audio thread is made when it is built; while it
// runs only atomics change (bypass, parameters).
#include "JunctionKernel.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    JKEffectKind kind;
    JKEffectProcess process;         // custom stages and units
    void *context;
    _Atomic uint32_t bypass;
    _Atomic uint32_t parameters[JK_EFFECT_MAX_PARAMETERS];  // float bit patterns
    // Audio thread only.
    int primed;                      // `current` holds the value last applied (gain, pan)
    float current;
    float envelope;                  // the gate's gain, 0…1
    uint32_t hold;                   // frames the gate stays open after the level drops
} Stage;

struct JKChain {
    uint32_t channels;
    double sampleRate;
    uint32_t count;
    uint32_t capacity;
    Stage *stages;
};

struct JKUnit {
    AudioUnit unit;
    uint32_t channels;
    AudioBufferList *list;           // the unit renders into these (or into buffers of its own)
    float *storage;                  // JK_MAX_FRAMES per channel
    // The audio the input callback hands the unit during one render.
    float *const *input;
    uint32_t inputFrames;
    Float64 sampleTime;
    atomic_flag busy;
    _Atomic uint64_t errors;
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

// MARK: Chains

JKChain *jk_chain_create(uint32_t channels, double sampleRate, uint32_t capacity) {
    if (channels == 0 || !(sampleRate > 0)) return NULL;
    JKChain *chain = calloc(1, sizeof *chain);
    if (!chain) return NULL;
    chain->stages = calloc(capacity ? capacity : 1, sizeof *chain->stages);
    if (!chain->stages) {
        free(chain);
        return NULL;
    }
    chain->channels = channels;
    chain->sampleRate = sampleRate;
    chain->capacity = capacity;
    return chain;
}

void jk_chain_destroy(JKChain *chain) {
    if (!chain) return;
    free(chain->stages);
    free(chain);
}

uint32_t jk_chain_channels(const JKChain *chain) { return chain->channels; }
uint32_t jk_chain_count(const JKChain *chain) { return chain->count; }

static int Append(JKChain *chain, JKEffectKind kind, JKEffectProcess process, void *context) {
    if (chain->count >= chain->capacity) return -1;
    Stage *stage = &chain->stages[chain->count];
    memset(stage, 0, sizeof *stage);
    stage->kind = kind;
    stage->process = process;
    stage->context = context;
    atomic_init(&stage->bypass, 0);
    for (int p = 0; p < JK_EFFECT_MAX_PARAMETERS; p++) atomic_init(&stage->parameters[p], Bits(0));
    switch (kind) {
    case JK_EFFECT_GAIN: atomic_store(&stage->parameters[0], Bits(1)); break;
    case JK_EFFECT_GATE:
        atomic_store(&stage->parameters[0], Bits(0.01f));  // -40 dBFS
        atomic_store(&stage->parameters[1], Bits(0.15f));
        break;
    default: break;
    }
    return (int)chain->count++;
}

int jk_chain_add(JKChain *chain, JKEffectKind kind) {
    if (kind < JK_EFFECT_GAIN || kind > JK_EFFECT_GATE) return -1;
    return Append(chain, kind, NULL, NULL);
}

int jk_chain_add_custom(JKChain *chain, JKEffectProcess process, void *context) {
    if (!process) return -1;
    return Append(chain, JK_EFFECT_CUSTOM, process, context);
}

int jk_chain_add_unit(JKChain *chain, JKUnit *unit) {
    return Append(chain, JK_EFFECT_CUSTOM, jk_unit_process, unit);
}

void jk_chain_set_bypass(JKChain *chain, uint32_t stage, int bypass) {
    if (stage < chain->count) atomic_store_explicit(&chain->stages[stage].bypass, bypass ? 1 : 0, memory_order_relaxed);
}

int jk_chain_bypassed(const JKChain *chain, uint32_t stage) {
    if (stage >= chain->count) return 0;
    return (int)atomic_load_explicit((_Atomic uint32_t *)&chain->stages[stage].bypass, memory_order_relaxed);
}

void jk_chain_set_parameter(JKChain *chain, uint32_t stage, uint32_t parameter, float value) {
    if (stage >= chain->count || parameter >= JK_EFFECT_MAX_PARAMETERS || !isfinite(value)) return;
    atomic_store_explicit(&chain->stages[stage].parameters[parameter], Bits(value), memory_order_relaxed);
}

float jk_chain_parameter(const JKChain *chain, uint32_t stage, uint32_t parameter) {
    if (stage >= chain->count || parameter >= JK_EFFECT_MAX_PARAMETERS) return 0;
    return Float(atomic_load_explicit((_Atomic uint32_t *)&chain->stages[stage].parameters[parameter],
                                      memory_order_relaxed));
}

static inline float Parameter(Stage *stage, int parameter) {
    return Float(atomic_load_explicit(&stage->parameters[parameter], memory_order_relaxed));
}

/// Moves from the value last applied to the new one over the buffer, so changes don't click.
static void Glide(Stage *stage, float target, float *start, float *step, uint32_t frames) {
    if (!stage->primed) {
        stage->current = target;
        stage->primed = 1;
    }
    *start = stage->current;
    *step = (target - stage->current) / (float)frames;
    stage->current = target;
}

static void Gain(Stage *stage, float *const *channels, uint32_t count, uint32_t frames) {
    float start, step;
    Glide(stage, Parameter(stage, 0), &start, &step, frames);
    for (uint32_t c = 0; c < count; c++) {
        float *samples = channels[c];
        if (step == 0) {
            if (start == 1) continue;
            for (uint32_t f = 0; f < frames; f++) samples[f] *= start;
        } else {
            float gain = start;
            for (uint32_t f = 0; f < frames; f++) {
                gain += step;
                samples[f] *= gain;
            }
        }
    }
}

/// A balance: moving right turns the left channels down, and the other way round.
static void Pan(Stage *stage, float *const *channels, uint32_t count, uint32_t frames) {
    float target = Parameter(stage, 0);
    target = target < -1 ? -1 : (target > 1 ? 1 : target);
    float start, step;
    Glide(stage, target, &start, &step, frames);
    if (count < 2 || (start == 0 && step == 0)) return;
    for (uint32_t c = 0; c < count; c++) {
        float *samples = channels[c];
        int left = (c % 2) == 0;
        float position = start;
        for (uint32_t f = 0; f < frames; f++) {
            position += step;
            float gain = left ? (position > 0 ? 1 - position : 1) : (position < 0 ? 1 + position : 1);
            samples[f] *= gain;
        }
    }
}

static void Mono(float *const *channels, uint32_t count, uint32_t frames) {
    if (count < 2) return;
    float scale = 1.0f / (float)count;
    for (uint32_t f = 0; f < frames; f++) {
        float sum = 0;
        for (uint32_t c = 0; c < count; c++) sum += channels[c][f];
        sum *= scale;
        for (uint32_t c = 0; c < count; c++) channels[c][f] = sum;
    }
}

static void Gate(Stage *stage, double sampleRate, float *const *channels, uint32_t count, uint32_t frames) {
    float threshold = Parameter(stage, 0);
    float release = Parameter(stage, 1);
    if (!(release > 0.001f)) release = 0.001f;
    float attackCoefficient = 1.0f - expf(-1.0f / (float)(0.001 * sampleRate));
    float releaseCoefficient = 1.0f - expf(-1.0f / (float)(release * sampleRate));
    uint32_t holdFrames = (uint32_t)(0.05 * sampleRate);
    float envelope = stage->envelope;
    uint32_t hold = stage->hold;
    for (uint32_t f = 0; f < frames; f++) {
        float peak = 0;
        for (uint32_t c = 0; c < count; c++) {
            float v = fabsf(channels[c][f]);
            if (v > peak) peak = v;
        }
        float target;
        if (peak >= threshold) {
            hold = holdFrames;
            target = 1;
        } else if (hold > 0) {
            hold--;
            target = 1;
        } else {
            target = 0;
        }
        envelope += (target - envelope) * (target > envelope ? attackCoefficient : releaseCoefficient);
        if (envelope < 1e-6f) envelope = 0;  // no denormals while closed
        for (uint32_t c = 0; c < count; c++) channels[c][f] *= envelope;
    }
    stage->envelope = envelope;
    stage->hold = hold;
}

void jk_chain_process(JKChain *chain, float *const *channels, uint32_t channelCount, uint32_t frames) {
    if (!chain || frames == 0 || frames > JK_MAX_FRAMES) return;
    uint32_t count = channelCount < chain->channels ? channelCount : chain->channels;
    if (count == 0) return;
    for (uint32_t s = 0; s < chain->count; s++) {
        Stage *stage = &chain->stages[s];
        if (atomic_load_explicit(&stage->bypass, memory_order_relaxed)) {
            stage->primed = 0;  // after a bypass, gain and pan start where they are set rather than gliding back
            continue;
        }
        switch (stage->kind) {
        case JK_EFFECT_GAIN: Gain(stage, channels, count, frames); break;
        case JK_EFFECT_PAN: Pan(stage, channels, count, frames); break;
        case JK_EFFECT_MONO: Mono(channels, count, frames); break;
        case JK_EFFECT_GATE: Gate(stage, chain->sampleRate, channels, count, frames); break;
        case JK_EFFECT_CUSTOM: stage->process(stage->context, channels, count, frames); break;
        }
    }
}

// MARK: Audio Units

/// The unit's input: the channels being processed.
static OSStatus UnitInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus,
                          UInt32 frames, AudioBufferList *data) {
    (void)flags; (void)time; (void)bus;
    JKUnit *unit = refCon;
    if (!data) return noErr;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        AudioBuffer *buffer = &data->mBuffers[b];
        int available = unit->input && b < unit->channels && frames <= unit->inputFrames;
        if (!buffer->mData) {
            // The unit wants our buffers (it didn't allocate its own): hand over the channel itself, or silence.
            buffer->mData = available ? unit->input[b] : unit->storage + (size_t)b * JK_MAX_FRAMES;
            buffer->mDataByteSize = frames * (UInt32)sizeof(float);
            if (!available) memset(buffer->mData, 0, buffer->mDataByteSize);
            continue;
        }
        UInt32 bytes = frames * (UInt32)sizeof(float);
        if (bytes > buffer->mDataByteSize) bytes = buffer->mDataByteSize;
        if (available) memcpy(buffer->mData, unit->input[b], bytes);
        else memset(buffer->mData, 0, bytes);
    }
    return noErr;
}

JKUnit *jk_unit_create(AudioUnit audioUnit, uint32_t channels) {
    if (!audioUnit || channels == 0) return NULL;
    JKUnit *unit = calloc(1, sizeof *unit);
    if (!unit) return NULL;
    unit->unit = audioUnit;
    unit->channels = channels;
    unit->list = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channels);
    unit->storage = calloc((size_t)channels * JK_MAX_FRAMES, sizeof *unit->storage);
    atomic_flag_clear(&unit->busy);
    atomic_init(&unit->errors, 0);
    if (!unit->list || !unit->storage) {
        free(unit->list);
        free(unit->storage);
        free(unit);
        return NULL;
    }
    unit->list->mNumberBuffers = channels;
    AURenderCallbackStruct callback = {UnitInput, unit};
    if (AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                             sizeof callback) != noErr) {
        free(unit->list);
        free(unit->storage);
        free(unit);
        return NULL;
    }
    return unit;
}

void jk_unit_destroy(JKUnit *unit) {
    if (!unit) return;
    AURenderCallbackStruct none = {NULL, NULL};
    AudioUnitSetProperty(unit->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, sizeof none);
    free(unit->list);
    free(unit->storage);
    free(unit);
}

uint64_t jk_unit_error_count(const JKUnit *unit) {
    return atomic_load_explicit((_Atomic uint64_t *)&unit->errors, memory_order_relaxed);
}

void jk_unit_process(void *context, float *const *channels, uint32_t channelCount, uint32_t frames) {
    JKUnit *unit = context;
    if (!unit || channelCount != unit->channels || frames == 0 || frames > JK_MAX_FRAMES) return;
    if (atomic_flag_test_and_set_explicit(&unit->busy, memory_order_acquire)) return;
    unit->input = channels;
    unit->inputFrames = frames;
    for (uint32_t b = 0; b < unit->channels; b++) {
        unit->list->mBuffers[b].mNumberChannels = 1;
        unit->list->mBuffers[b].mData = unit->storage + (size_t)b * JK_MAX_FRAMES;
        unit->list->mBuffers[b].mDataByteSize = frames * (UInt32)sizeof(float);
    }
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time;
    memset(&time, 0, sizeof time);
    time.mSampleTime = unit->sampleTime;
    time.mFlags = kAudioTimeStampSampleTimeValid;
    OSStatus status = AudioUnitRender(unit->unit, &flags, &time, 0, frames, unit->list);
    unit->sampleTime += frames;
    if (status == noErr) {
        for (uint32_t b = 0; b < unit->channels; b++) {
            const AudioBuffer *buffer = &unit->list->mBuffers[b];
            if (!buffer->mData || buffer->mData == channels[b]) continue;
            uint32_t available = buffer->mDataByteSize / (uint32_t)sizeof(float);
            memcpy(channels[b], buffer->mData, (size_t)(available < frames ? available : frames) * sizeof(float));
        }
    } else {
        atomic_fetch_add_explicit(&unit->errors, 1, memory_order_relaxed);
    }
    unit->input = NULL;
    atomic_flag_clear_explicit(&unit->busy, memory_order_release);
}
