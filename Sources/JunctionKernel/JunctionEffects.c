// Effect chains for the renderer: the built-in effects (gain, pan, mono, noise gate, correction) and Audio Units,
// processed in place on non-interleaved channels. Everything a chain needs on the audio thread is made when it is built; while it
// runs only atomics change (bypass, parameters). Each stage's rendering is timed, so an effect that holds up the audio
// thread can be found (see jk_chain_stage_timing).
#include "JunctionKernel.h"
#include "JunctionTiming.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct Correction Correction;

typedef struct {
    JKEffectKind kind;
    JKEffectProcess process;         // custom stages and units
    void *context;
    Correction *correction;          // a correction stage's state (made with the stage)
    _Atomic uint32_t bypass;
    _Atomic uint32_t parameters[JK_EFFECT_MAX_PARAMETERS];  // float bit patterns
    // Audio thread only.
    int primed;                      // `current` holds the value last applied (gain, pan)
    float current;
    float envelope;                  // the gate's gain, 0…1
    uint32_t hold;                   // frames the gate stays open after the level drops
    // Timing, written by the audio thread, read by any.
    _Atomic uint64_t busyTicks;
    _Atomic uint64_t frames;
    _Atomic uint64_t stalls;         // renders that took more than JK_STALL_LOAD of their buffer's duration
    _Atomic uint32_t peakLoad;       // float bits
} Stage;

struct JKChain {
    uint32_t channels;
    double sampleRate;
    double secondsPerTick;
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
    chain->secondsPerTick = jk_seconds_per_tick();
    chain->capacity = capacity;
    return chain;
}

static void CorrectionFree(Correction *state);

void jk_chain_destroy(JKChain *chain) {
    if (!chain) return;
    for (uint32_t s = 0; s < chain->count; s++) CorrectionFree(chain->stages[s].correction);
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
    atomic_init(&stage->busyTicks, 0);
    atomic_init(&stage->frames, 0);
    atomic_init(&stage->stalls, 0);
    atomic_init(&stage->peakLoad, 0);
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

static Correction *CorrectionMake(uint32_t channels, double sampleRate);

int jk_chain_add(JKChain *chain, JKEffectKind kind) {
    if (kind < JK_EFFECT_GAIN || kind > JK_EFFECT_CORRECTION) return -1;
    if (kind != JK_EFFECT_CORRECTION) return Append(chain, kind, NULL, NULL);
    if (chain->count >= chain->capacity) return -1;
    Correction *state = CorrectionMake(chain->channels, chain->sampleRate);
    if (!state) return -1;
    int stage = Append(chain, kind, NULL, NULL);
    chain->stages[stage].correction = state;
    return stage;
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

static void Correct(Correction *state, float *const *channels, uint32_t count, uint32_t frames);
static void CorrectionBypassed(Correction *state);

void jk_chain_process(JKChain *chain, float *const *channels, uint32_t channelCount, uint32_t frames) {
    if (!chain || frames == 0 || frames > JK_MAX_FRAMES) return;
    uint32_t count = channelCount < chain->channels ? channelCount : chain->channels;
    if (count == 0) return;
    for (uint32_t s = 0; s < chain->count; s++) {
        Stage *stage = &chain->stages[s];
        if (atomic_load_explicit(&stage->bypass, memory_order_relaxed)) {
            stage->primed = 0;  // after a bypass, gain and pan start where they are set rather than gliding back
            if (stage->correction) CorrectionBypassed(stage->correction);
            continue;
        }
        uint64_t start = mach_absolute_time();
        switch (stage->kind) {
        case JK_EFFECT_GAIN: Gain(stage, channels, count, frames); break;
        case JK_EFFECT_PAN: Pan(stage, channels, count, frames); break;
        case JK_EFFECT_MONO: Mono(channels, count, frames); break;
        case JK_EFFECT_GATE: Gate(stage, chain->sampleRate, channels, count, frames); break;
        case JK_EFFECT_CORRECTION: Correct(stage->correction, channels, count, frames); break;
        case JK_EFFECT_CUSTOM: stage->process(stage->context, channels, count, frames); break;
        }
        uint64_t ticks = mach_absolute_time() - start;
        float load = jk_load(ticks, chain->secondsPerTick, frames, chain->sampleRate);
        atomic_fetch_add_explicit(&stage->busyTicks, ticks, memory_order_relaxed);
        atomic_fetch_add_explicit(&stage->frames, frames, memory_order_relaxed);
        if (load > JK_STALL_LOAD) atomic_fetch_add_explicit(&stage->stalls, 1, memory_order_relaxed);
        jk_raise_load(&stage->peakLoad, load);
    }
}

void jk_chain_stage_timing(JKChain *chain, uint32_t stage, JKTiming *timing, int takePeak) {
    memset(timing, 0, sizeof *timing);
    if (stage >= chain->count) return;
    Stage *s = &chain->stages[stage];
    timing->frames = atomic_load_explicit(&s->frames, memory_order_relaxed);
    timing->seconds = (double)atomic_load_explicit(&s->busyTicks, memory_order_relaxed) * chain->secondsPerTick;
    timing->late = atomic_load_explicit(&s->stalls, memory_order_relaxed);
    uint32_t bits = takePeak ? atomic_exchange_explicit(&s->peakLoad, 0, memory_order_relaxed)
                             : atomic_load_explicit(&s->peakLoad, memory_order_relaxed);
    timing->peakLoad = Float(bits);
}

// MARK: Correction

typedef struct {
    uint32_t sections;
    uint32_t delay;                  // frames
    float level;                     // linear
    double coefficients[JK_CORRECTION_MAX_SECTIONS][5];  // b0, b1, b2, a1, a2
} CorrectionChannel;

struct JKCorrection {
    uint32_t channels;
    float preamp;
    CorrectionChannel channel[];
};

/// A channel's cascade in direct form I: every signal's last two samples, newest first. [0] is the cascade's input,
/// [k] the output of section k (so also the input of section k + 1). Holding signals rather than a transposed form's
/// partial sums lets new coefficients pick up where the old ones were.
typedef struct {
    double h[JK_CORRECTION_MAX_SECTIONS + 1][2];
} History;

struct Correction {
    _Atomic(JKCorrection *) pending; // the settings in place (owned by the chain)
    _Atomic uint64_t begun;          // process calls begun and finished (see jk_chain_swap_correction)
    _Atomic uint64_t finished;
    uint32_t channels;
    uint32_t lineLength;             // frames per delay line: the longest delay + 1
    // Audio thread only.
    JKCorrection *active;            // the settings last applied
    int primed;                      // the histories and delay lines hold the audio so far (cleared by bypass)
    uint32_t bank;                   // which of a channel's two histories the active settings use
    uint32_t write;                  // where the next frame goes in every delay line
    History *histories;              // two per channel: the active settings' and, while cross-fading, the new ones'
    float *lines;                    // per channel: the cascade's output, `lineLength` frames, written at `write`
};

static Correction *CorrectionMake(uint32_t channels, double sampleRate) {
    Correction *state = calloc(1, sizeof *state);
    if (!state) return NULL;
    state->channels = channels;
    state->lineLength = (uint32_t)ceil(JK_CORRECTION_MAX_DELAY * sampleRate) + 1;
    state->histories = calloc((size_t)channels * 2, sizeof *state->histories);
    state->lines = calloc((size_t)channels * state->lineLength, sizeof *state->lines);
    if (!state->histories || !state->lines) {
        free(state->histories);
        free(state->lines);
        free(state);
        return NULL;
    }
    atomic_init(&state->pending, NULL);
    atomic_init(&state->begun, 0);
    atomic_init(&state->finished, 0);
    return state;
}

static void CorrectionFree(Correction *state) {
    if (!state) return;
    JKCorrection *pending = atomic_load(&state->pending);
    if (pending) jk_correction_destroy(pending);
    free(state->histories);
    free(state->lines);
    free(state);
}

JKCorrection *jk_correction_create(uint32_t channels) {
    if (channels == 0 || channels > 1024) return NULL;
    JKCorrection *correction = calloc(1, sizeof *correction + sizeof(CorrectionChannel) * channels);
    if (!correction) return NULL;
    correction->channels = channels;
    correction->preamp = 1;
    for (uint32_t c = 0; c < channels; c++) correction->channel[c].level = 1;
    return correction;
}

void jk_correction_destroy(JKCorrection *correction) { free(correction); }

uint32_t jk_correction_channels(const JKCorrection *correction) { return correction->channels; }

int jk_correction_set_channel(JKCorrection *correction, uint32_t channel, const double *coefficients, uint32_t sections,
                              uint32_t delayFrames, float level) {
    if (channel >= correction->channels || sections > JK_CORRECTION_MAX_SECTIONS || (sections > 0 && !coefficients)
        || !isfinite(level)) return 0;
    for (uint32_t i = 0; i < sections * 5; i++) if (!isfinite(coefficients[i])) return 0;
    CorrectionChannel *settings = &correction->channel[channel];
    settings->sections = sections;
    if (sections) memcpy(settings->coefficients, coefficients, sizeof(double) * 5 * sections);
    settings->delay = delayFrames;
    settings->level = level;
    return 1;
}

void jk_correction_set_preamp(JKCorrection *correction, float gain) {
    if (isfinite(gain)) correction->preamp = gain;
}

static Correction *CorrectionStage(const JKChain *chain, uint32_t stage) {
    return stage < chain->count ? chain->stages[stage].correction : NULL;
}

JKCorrection *jk_chain_swap_correction(JKChain *chain, uint32_t stage, JKCorrection *correction, uint64_t *ticket) {
    Correction *state = CorrectionStage(chain, stage);
    *ticket = 0;
    if (!state) return correction;
    JKCorrection *old = atomic_exchange(&state->pending, correction);
    // Process calls begun from here on load the new block (both sides are sequentially consistent). The one running
    // now may still use the old block, and so may the next (it cross-fades from the old one): once that one has
    // finished, nothing reaches the old block any more.
    *ticket = atomic_load(&state->begun) + 1;
    return old;
}

int jk_chain_is_done_with_correction(const JKChain *chain, uint32_t stage, uint64_t ticket) {
    Correction *state = CorrectionStage(chain, stage);
    return !state || atomic_load(&state->finished) >= ticket;
}

uint32_t jk_chain_correction_max_delay(const JKChain *chain, uint32_t stage) {
    Correction *state = CorrectionStage(chain, stage);
    return state ? state->lineLength - 1 : 0;
}

/// While bypassed the stage takes up new settings straight away (so swapped-out blocks can be freed) and starts
/// afresh when it is turned back on.
static void CorrectionBypassed(Correction *state) {
    atomic_fetch_add(&state->begun, 1);
    state->active = atomic_load(&state->pending);
    state->primed = 0;
    atomic_fetch_add_explicit(&state->finished, 1, memory_order_release);
}

/// A channel's settings in a block, or NULL when it passes through.
static inline const CorrectionChannel *Settings(const JKCorrection *block, uint32_t channel) {
    return block && channel < block->channels ? &block->channel[channel] : NULL;
}

/// Runs one sample through a cascade, updating its history.
static inline double Cascade(const CorrectionChannel *settings, History *history, double x) {
    uint32_t sections = settings ? settings->sections : 0;
    double v = x;
    for (uint32_t k = 0; k < sections; k++) {
        const double *b = settings->coefficients[k];
        double *in = history->h[k], *out = history->h[k + 1];
        double y = b[0] * v + b[1] * in[0] + b[2] * in[1] - b[3] * out[0] - b[4] * out[1];
        in[1] = in[0];
        in[0] = v;
        v = y;
    }
    double *last = history->h[sections];
    last[1] = last[0];
    last[0] = v;
    return v;
}

/// Gives new settings a history to start from: the same input, and the old cascade's signals for its sections (its
/// last section's output for the new last section).
static void HandOver(const History *from, uint32_t fromSections, History *to, uint32_t toSections) {
    to->h[0][0] = from->h[0][0];
    to->h[0][1] = from->h[0][1];
    for (uint32_t k = 1; k <= toSections; k++) {
        uint32_t source = k == toSections ? fromSections : (k < fromSections ? k : fromSections);
        to->h[k][0] = from->h[source][0];
        to->h[k][1] = from->h[source][1];
    }
}

/// Keeps decaying histories out of subnormal numbers.
static void Flush(History *history, uint32_t sections) {
    for (uint32_t k = 0; k <= sections; k++) {
        for (int i = 0; i < 2; i++) if (fabs(history->h[k][i]) < 1e-30) history->h[k][i] = 0;
    }
}

static void Correct(Correction *state, float *const *channels, uint32_t count, uint32_t frames) {
    atomic_fetch_add(&state->begun, 1);  // sequentially consistent: see jk_chain_swap_correction
    JKCorrection *next = atomic_load(&state->pending);
    JKCorrection *previous = state->active;
    int fading = 0;
    if (!state->primed) {
        memset(state->histories, 0, sizeof *state->histories * (size_t)state->channels * 2);
        memset(state->lines, 0, sizeof *state->lines * (size_t)state->channels * state->lineLength);
        state->write = 0;
        state->primed = 1;
        previous = next;
    } else if (next != previous) {
        fading = 1;
    }
    uint32_t length = state->lineLength, maxDelay = length - 1;
    uint32_t oldBank = state->bank, newBank = fading ? 1 - state->bank : state->bank;
    float oldPreamp = previous ? previous->preamp : 1, newPreamp = next ? next->preamp : 1;
    float step = 1.0f / (float)frames;
    for (uint32_t c = 0; c < count; c++) {
        const CorrectionChannel *from = Settings(previous, c), *to = Settings(next, c);
        History *oldHistory = &state->histories[c * 2 + oldBank], *newHistory = &state->histories[c * 2 + newBank];
        float *line = state->lines + (size_t)c * length;
        float *samples = channels[c];
        uint32_t write = state->write;
        if (!from && !to) {
            // Passes through untouched; the input is kept so settings that come later start from it.
            if (fading) *newHistory = *oldHistory;
            for (uint32_t f = 0; f < frames; f++) {
                float x = samples[f];
                newHistory->h[0][1] = newHistory->h[0][0];
                newHistory->h[0][0] = x;
                line[write] = x;
                write = write + 1 == length ? 0 : write + 1;
            }
            continue;
        }
        uint32_t newDelay = to ? (to->delay < maxDelay ? to->delay : maxDelay) : 0;
        float newGain = to ? to->level * newPreamp : 1;
        if (!fading) {
            for (uint32_t f = 0; f < frames; f++) {
                line[write] = (float)Cascade(to, newHistory, samples[f]);
                uint32_t read = write >= newDelay ? write - newDelay : write + length - newDelay;
                samples[f] = line[read] * newGain;
                write = write + 1 == length ? 0 : write + 1;
            }
            Flush(newHistory, to ? to->sections : 0);
            continue;
        }
        // Cross-fade over this buffer: both cascades run, their blend goes into the delay line, and the line is read
        // at both delays and gains, blended the same way.
        uint32_t oldDelay = from ? (from->delay < maxDelay ? from->delay : maxDelay) : 0;
        float oldGain = from ? from->level * oldPreamp : 1;
        HandOver(oldHistory, from ? from->sections : 0, newHistory, to ? to->sections : 0);
        for (uint32_t f = 0; f < frames; f++) {
            float weight = (float)(f + 1) * step;
            double x = samples[f];
            double a = Cascade(from, oldHistory, x), b = Cascade(to, newHistory, x);
            line[write] = (float)(a + (b - a) * weight);
            uint32_t oldRead = write >= oldDelay ? write - oldDelay : write + length - oldDelay;
            uint32_t newRead = write >= newDelay ? write - newDelay : write + length - newDelay;
            float before = line[oldRead] * oldGain, after = line[newRead] * newGain;
            samples[f] = before + (after - before) * weight;
            write = write + 1 == length ? 0 : write + 1;
        }
        Flush(newHistory, to ? to->sections : 0);
    }
    state->write = (uint32_t)(((uint64_t)state->write + frames) % length);
    if (fading) {
        // Channels the chain has but wasn't given this time keep their history across the bank switch.
        for (uint32_t c = count; c < state->channels; c++) state->histories[c * 2 + newBank] = state->histories[c * 2 + oldBank];
    }
    state->bank = newBank;
    state->active = next;
    atomic_fetch_add_explicit(&state->finished, 1, memory_order_release);
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
