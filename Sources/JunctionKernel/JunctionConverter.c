// Sample-rate conversion between two devices with their own clocks. The source device's IOProc writes into a
// single-producer, single-consumer ring; the sink's IOProc reads it through a polyphase windowed-sinc resampler.
// The resampling ratio follows the two clocks' measured rates and is nudged slowly so the ring stays at its target
// fill; two devices on one clock (the same clock domain) keep the nominal ratio. Underruns and overruns fade out and
// back in instead of clicking. No locks or allocation after creation.
#include "JunctionKernel.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum {
    kTaps = JK_CONVERTER_TAPS,
    kPhases = 256,       // filter phases between two input frames; coefficients in between are interpolated
    kFadeFrames = 64,    // output frames for a fade in or out (1.3 ms at 48 kHz)
};

/// Seconds of measurement between rate updates, and how far a measured rate may stray from the nominal one before
/// it counts as a jump in the clock (an overload, a restart) rather than drift.
static const double kMeterInterval = 0.25, kMeterTolerance = 0.02;
/// The fill correction: seconds of audio above the target are worked off over this many seconds, at most this
/// fraction faster or slower than the measured ratio (0.25 %, about 4 cents).
static const double kSteerSeconds = 8, kSteerLimit = 0.0025;

/// A clock's real rate, from the sample and host times in its IO time stamps.
typedef struct {
    double nominal;
    double rate;      // measured frames per second; 0 until measured
    double sample0;
    uint64_t host0;
    int primed;
} RateMeter;

struct JKConverter {
    uint32_t channels;
    uint32_t capacity;              // frames per channel, a power of two
    uint32_t mask;
    float *ring;                    // per channel 2 × capacity: each frame is stored twice so a window never wraps
    float *filter;                  // (kPhases + 1) rows of kTaps coefficients
    double inputRate, outputRate;   // nominal
    int sameClock;                  // one clock: keep the nominal ratio
    double ticksPerSecond;
    // Shared between the two sides.
    _Atomic uint64_t written;       // frames written so far (producer)
    _Atomic uint64_t released;      // frames the reader no longer needs (consumer)
    _Atomic uint32_t full;          // set by the producer when the ring overflowed, cleared by the consumer
    _Atomic uint32_t producerBlock; // largest write so far
    _Atomic uint32_t lastBlock;     // the latest write's length…
    _Atomic uint64_t lastHost;      // …and the host time of its first frame (0: unknown)
    _Atomic uint64_t producerRate;  // double bits of the input meter's rate; 0 until measured
    _Atomic uint64_t writes, underruns, overruns;
    _Atomic uint64_t fillBits, targetBits, ratioBits;
    // Producer only.
    RateMeter inputMeter;
    // Consumer only.
    RateMeter outputMeter;
    uint64_t position;              // first input frame of the filter window
    double frac;                    // 0…1: how far the output frame lies past the window's centre frame
    double ratio;                   // input frames per output frame
    double averageFill;             // of the captured fill (see CapturedFill)
    uint32_t consumerBlock;         // largest read so far
    int playing;                    // 0: waiting for the ring to fill (silent)
    float gain;                     // fade in / out
};

static inline uint64_t Bits64(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}

static inline double Double(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static double BesselI0(double x) {
    double sum = 1, term = 1, quarter = x * x / 4;
    for (int k = 1; k < 64 && term > sum * 1e-15; k++) {
        term *= quarter / ((double)k * k);
        sum += term;
    }
    return sum;
}

/// Row p holds the taps for an output frame p / kPhases of an input frame past the window's centre frame
/// (input frame kTaps/2 - 1): a low-pass sinc at `cutoff` (cycles per input frame) under a Kaiser window, scaled to
/// unity gain at DC.
static void MakeFilter(float *filter, double cutoff) {
    const double beta = 8.6, half = kTaps / 2.0, norm = BesselI0(beta);
    for (int p = 0; p <= kPhases; p++) {
        double row[kTaps], sum = 0;
        for (int k = 0; k < kTaps; k++) {
            double x = k - (half - 1) - (double)p / kPhases;
            double sinc = x == 0 ? 2 * cutoff : sin(2 * M_PI * cutoff * x) / (M_PI * x);
            double r = x / half;
            double window = fabs(r) >= 1 ? 0 : BesselI0(beta * sqrt(1 - r * r)) / norm;
            row[k] = sinc * window;
            sum += row[k];
        }
        for (int k = 0; k < kTaps; k++) filter[p * kTaps + k] = (float)(row[k] / sum);
    }
}

/// The fill the reader steers towards, in input frames: the filter's window, one read and one write (they arrive at
/// their own times), a fade-out's worth kept back for underruns, and 1 ms of slack. It is a target for the captured
/// fill (see CapturedFill): the ring itself holds up to one write less, depending on when the last one came.
static double TargetFill(const JKConverter *c, uint32_t readFrames, uint32_t writeFrames) {
    double ratio = c->inputRate / c->outputRate * 1.01;
    return kTaps + ceil(readFrames * ratio) + writeFrames + ceil(kFadeFrames * ratio) + ceil(0.001 * c->inputRate);
}

/// The delay for a given target: what sits in the ring beyond the filter's window, plus the filter's own delay.
static double DelaySeconds(const JKConverter *c, double target) {
    double buffering = target - kTaps, filterDelay = kTaps / 2.0;
    return (buffering + filterDelay) / c->inputRate;
}

JKConverter *jk_converter_create(uint32_t channels, double inputRate, double outputRate) {
    if (channels == 0 || channels > 1024 || !(inputRate >= 1000 && inputRate <= 1e6) ||
        !(outputRate >= 1000 && outputRate <= 1e6))
        return NULL;
    JKConverter *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->channels = channels;
    c->inputRate = inputRate;
    c->outputRate = outputRate;
    // Room for three times the largest target, so a slow reader can be caught before the ring overflows.
    double largest = TargetFill(c, JK_MAX_FRAMES, JK_MAX_FRAMES);
    uint32_t capacity = 1024;
    while (capacity < 3 * largest) capacity <<= 1;
    c->capacity = capacity;
    c->mask = capacity - 1;
    c->ring = calloc((size_t)channels * 2 * capacity, sizeof *c->ring);
    c->filter = calloc((size_t)(kPhases + 1) * kTaps, sizeof *c->filter);
    if (!c->ring || !c->filter) {
        jk_converter_destroy(c);
        return NULL;
    }
    // Pass up to 91 % of the lower Nyquist frequency (20 kHz between 44.1 and 48 kHz).
    MakeFilter(c->filter, 0.5 * fmin(1.0, outputRate / inputRate) * 0.91);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    c->ticksPerSecond = timebase.numer ? 1e9 * timebase.denom / timebase.numer : 0;
    c->inputMeter.nominal = inputRate;
    c->outputMeter.nominal = outputRate;
    c->ratio = inputRate / outputRate;
    atomic_init(&c->ratioBits, Bits64(c->ratio));
    atomic_init(&c->targetBits, Bits64(TargetFill(c, 0, 0)));
    return c;
}

void jk_converter_destroy(JKConverter *c) {
    if (!c) return;
    free(c->ring);
    free(c->filter);
    free(c);
}

uint32_t jk_converter_channels(const JKConverter *c) { return c->channels; }

void jk_converter_set_same_clock(JKConverter *c, int sameClock) { c->sameClock = sameClock != 0; }

int jk_converter_same_clock(const JKConverter *c) { return c->sameClock; }

/// Updates a meter from one IO cycle's time stamp; returns 1 when the measured rate changed.
static int Measure(RateMeter *m, const AudioTimeStamp *time, double ticksPerSecond) {
    const UInt32 needed = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    if (!time || (time->mFlags & needed) != needed || ticksPerSecond <= 0) return 0;
    if (!m->primed || time->mHostTime <= m->host0) {
        m->sample0 = time->mSampleTime;
        m->host0 = time->mHostTime;
        m->primed = 1;
        return 0;
    }
    double seconds = (double)(time->mHostTime - m->host0) / ticksPerSecond;
    if (seconds < kMeterInterval) return 0;
    double rate = (time->mSampleTime - m->sample0) / seconds;
    m->sample0 = time->mSampleTime;
    m->host0 = time->mHostTime;
    if (!(fabs(rate / m->nominal - 1) < kMeterTolerance)) return 0;
    m->rate = m->rate > 0 ? m->rate + 0.2 * (rate - m->rate) : rate;
    return 1;
}

void jk_converter_write(JKConverter *c, const AudioBufferList *input, const AudioTimeStamp *time) {
    if (!input) return;
    uint32_t frames = UINT32_MAX;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (!buffer->mData || buffer->mNumberChannels == 0) continue;
        uint32_t bufferFrames = buffer->mDataByteSize / (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (bufferFrames < frames) frames = bufferFrames;
    }
    if (frames == UINT32_MAX || frames == 0) return;
    atomic_fetch_add_explicit(&c->writes, 1, memory_order_relaxed);
    if (Measure(&c->inputMeter, time, c->ticksPerSecond))
        atomic_store_explicit(&c->producerRate, Bits64(c->inputMeter.rate), memory_order_relaxed);
    if (frames > atomic_load_explicit(&c->producerBlock, memory_order_relaxed))
        atomic_store_explicit(&c->producerBlock, frames, memory_order_relaxed);
    int timed = time && (time->mFlags & kAudioTimeStampHostTimeValid);
    atomic_store_explicit(&c->lastHost, timed ? time->mHostTime : 0, memory_order_relaxed);
    atomic_store_explicit(&c->lastBlock, frames, memory_order_relaxed);
    // After an overflow, drop everything until the reader has faded out and started again: what is in the ring
    // stays one unbroken stretch of audio.
    if (atomic_load_explicit(&c->full, memory_order_acquire)) return;
    uint64_t start = atomic_load_explicit(&c->written, memory_order_relaxed);
    uint64_t released = atomic_load_explicit(&c->released, memory_order_acquire);
    if (start - released + frames > c->capacity) {
        atomic_fetch_add_explicit(&c->overruns, 1, memory_order_relaxed);
        atomic_store_explicit(&c->full, 1, memory_order_release);
        return;
    }
    uint32_t channel = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && channel < c->channels; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        uint32_t stride = buffer->mNumberChannels;
        for (uint32_t i = 0; i < stride && channel < c->channels; i++, channel++) {
            float *ring = c->ring + (size_t)channel * 2 * c->capacity;
            const float *samples = buffer->mData ? (const float *)buffer->mData + i : NULL;
            for (uint32_t f = 0; f < frames; f++) {
                float value = samples ? samples[(size_t)f * stride] : 0;
                size_t slot = (start + f) & c->mask;
                ring[slot] = value;
                ring[slot + c->capacity] = value;
            }
        }
    }
    for (; channel < c->channels; channel++) {
        float *ring = c->ring + (size_t)channel * 2 * c->capacity;
        for (uint32_t f = 0; f < frames; f++) {
            size_t slot = (start + f) & c->mask;
            ring[slot] = 0;
            ring[slot + c->capacity] = 0;
        }
    }
    atomic_store_explicit(&c->written, start + frames, memory_order_release);
}

OSStatus jk_converter_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                             const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                             void *clientData) {
    (void)device; (void)now; (void)outputTime;
    if (output) {
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
        }
    }
    if (clientData) jk_converter_write(clientData, input, inputTime);
    return noErr;
}

/// Input frames the source device has captured since its last write, from the host times of that write and of now:
/// added to the fill, it gives a level that doesn't saw up and down with each write. At most one write's worth.
static double CapturedSinceWrite(const JKConverter *c, const AudioTimeStamp *now, double inputRate) {
    uint64_t host = atomic_load_explicit((_Atomic uint64_t *)&c->lastHost, memory_order_relaxed);
    double block = atomic_load_explicit((_Atomic uint32_t *)&c->lastBlock, memory_order_relaxed);
    if (!host || !now || !(now->mFlags & kAudioTimeStampHostTimeValid) || now->mHostTime <= host) return 0;
    // The write came once its block had been captured: count from the end of that block.
    double frames = (double)(now->mHostTime - host) / c->ticksPerSecond * inputRate - block;
    return frames < 0 ? 0 : (frames > block ? block : frames);
}

void jk_converter_read(JKConverter *c, float *output, uint32_t stride, uint32_t frames, const AudioTimeStamp *time) {
    for (uint32_t ch = 0; ch < c->channels; ch++) memset(output + (size_t)ch * stride, 0, sizeof(float) * frames);
    if (frames == 0) return;
    if (frames > JK_MAX_FRAMES) frames = JK_MAX_FRAMES;
    Measure(&c->outputMeter, time, c->ticksPerSecond);
    if (frames > c->consumerBlock) c->consumerBlock = frames;
    uint32_t producerBlock = atomic_load_explicit(&c->producerBlock, memory_order_relaxed);
    if (producerBlock > JK_MAX_FRAMES) producerBlock = JK_MAX_FRAMES;
    double target = TargetFill(c, c->consumerBlock, producerBlock);
    atomic_store_explicit(&c->targetBits, Bits64(target), memory_order_relaxed);

    uint64_t written = atomic_load_explicit(&c->written, memory_order_acquire);
    double inputRate = Double(atomic_load_explicit(&c->producerRate, memory_order_relaxed));
    if (!(inputRate > 0)) inputRate = c->inputRate;
    double captured = CapturedSinceWrite(c, time, inputRate);
    double fill = (double)(written - c->position);
    atomic_store_explicit(&c->fillBits, Bits64(fill + captured), memory_order_relaxed);
    int full = atomic_load_explicit(&c->full, memory_order_acquire) != 0;

    if (!c->playing) {
        if (full) {  // overflowed while silent: start again from what comes next
            c->position = written;
            c->frac = 0;
            atomic_store_explicit(&c->released, c->position, memory_order_release);
            atomic_store_explicit(&c->full, 0, memory_order_release);
            return;
        }
        if (fill + captured < target) return;
        // Start exactly at the target, so steering has nothing to make up.
        uint64_t behind = (uint64_t)fmax(0, round(target - captured));
        if (written - c->position > behind) c->position = written - behind;
        c->frac = 0;
        fill = (double)(written - c->position);
        c->playing = 1;
        c->gain = 0;
        c->averageFill = fill + captured;
    }

    // What happens after this cycle: keep playing, or fade out now and wait for the ring to fill (it is running
    // dry), or fade out and jump ahead (the reader fell behind, or the ring overflowed).
    enum { Keep, Refill, Skip } after = Keep;
    double reserve = ceil(kFadeFrames * c->ratio);
    double need = floor(c->frac + frames * c->ratio) + kTaps;
    double excess = fmax(ceil(c->consumerBlock * c->ratio) + producerBlock, 0.02 * c->inputRate);
    if (full || fill + captured > target + excess) after = Skip;
    else if (fill < need + reserve) after = Refill;

    uint32_t count = frames;
    if (fill < need) {
        double available = fill - kTaps - c->frac;
        count = available < 0 ? 0 : (uint32_t)fmin(frames, floor(available / c->ratio) + 1);
    }

    if (after == Keep && c->sameClock) {
        // One clock: the rates can't drift apart, so the nominal ratio is exact (measuring would only add jitter).
        c->ratio = c->inputRate / c->outputRate;
        atomic_store_explicit(&c->ratioBits, Bits64(c->ratio), memory_order_relaxed);
    } else if (after == Keep) {
        // Follow the clocks: the measured rates give the ratio, and the fill's distance from its target nudges it.
        double seconds = frames / c->outputRate;
        c->averageFill += (fill + captured - c->averageFill) * fmin(1, seconds / 0.5);
        double outputRate = c->outputMeter.rate;
        if (!(outputRate > 0)) outputRate = c->outputRate;
        double error = (c->averageFill - target) / c->inputRate;
        double correction = fmax(-kSteerLimit, fmin(kSteerLimit, error / kSteerSeconds));
        double wanted = inputRate / outputRate * (1 + correction);
        c->ratio += (wanted - c->ratio) * fmin(1, seconds / 1.0);
        atomic_store_explicit(&c->ratioBits, Bits64(c->ratio), memory_order_relaxed);
    }

    uint32_t fadeStart = after == Keep ? count : (count > kFadeFrames ? count - kFadeFrames : 0);
    float fadeOut = 0, fadeIn = 1.0f / kFadeFrames;
    float coef[kTaps];
    float gain = c->gain;
    for (uint32_t f = 0; f < count; f++) {
        if (c->position + kTaps > written) break;  // never read past what was written
        double phase = c->frac * kPhases;
        int row = (int)phase;
        if (row >= kPhases) row = kPhases - 1;
        float t = (float)(phase - row);
        const float *h0 = c->filter + (size_t)row * kTaps, *h1 = h0 + kTaps;
        for (int k = 0; k < kTaps; k++) coef[k] = h0[k] + t * (h1[k] - h0[k]);
        if (f == fadeStart) fadeOut = gain / (float)(count - fadeStart);
        if (f >= fadeStart) {
            gain -= fadeOut;
            if (gain < 0 || f + 1 == count) gain = 0;
        } else if (gain < 1) {
            gain += fadeIn;
            if (gain > 1) gain = 1;
        }
        size_t start = c->position & c->mask;
        for (uint32_t ch = 0; ch < c->channels; ch++) {
            const float *x = c->ring + (size_t)ch * 2 * c->capacity + start;
            float sum = 0;
            for (int k = 0; k < kTaps; k++) sum += x[k] * coef[k];
            output[(size_t)ch * stride + f] = sum * gain;
        }
        c->frac += c->ratio;
        uint64_t advance = (uint64_t)c->frac;
        c->position += advance;
        c->frac -= (double)advance;
    }
    c->gain = gain;

    if (after != Keep) {
        // Faded out: drop what is left (it would join the next audio with a jump) and wait for the target fill.
        // Skipping ahead keeps the newest target's worth, so playing resumes on the next cycle; but after an
        // overflow the producer dropped audio after what the ring holds, so all of it goes.
        if (after == Refill) atomic_fetch_add_explicit(&c->underruns, 1, memory_order_relaxed);
        else if (!full) atomic_fetch_add_explicit(&c->overruns, 1, memory_order_relaxed);
        uint64_t keep = after == Skip && !full ? (uint64_t)fmax(0, target - captured) : 0;
        uint64_t resume = written > keep ? written - keep : 0;
        if (resume > c->position) c->position = resume;
        c->frac = 0;
        c->playing = 0;
        c->gain = 0;
    }
    atomic_store_explicit(&c->released, c->position, memory_order_release);
    if (full) atomic_store_explicit(&c->full, 0, memory_order_release);
}

double jk_converter_fill(const JKConverter *c) {
    return Double(atomic_load_explicit((_Atomic uint64_t *)&c->fillBits, memory_order_relaxed));
}

double jk_converter_target_fill(const JKConverter *c) {
    return Double(atomic_load_explicit((_Atomic uint64_t *)&c->targetBits, memory_order_relaxed));
}

double jk_converter_ratio(const JKConverter *c) {
    return Double(atomic_load_explicit((_Atomic uint64_t *)&c->ratioBits, memory_order_relaxed));
}

double jk_converter_delay(const JKConverter *c) {
    return DelaySeconds(c, jk_converter_target_fill(c));
}

double jk_converter_expected_delay(const JKConverter *c, uint32_t outputFrames, uint32_t inputFrames) {
    return DelaySeconds(c, TargetFill(c, outputFrames, inputFrames));
}

uint64_t jk_converter_underrun_count(const JKConverter *c) {
    return atomic_load_explicit((_Atomic uint64_t *)&c->underruns, memory_order_relaxed);
}

uint64_t jk_converter_overrun_count(const JKConverter *c) {
    return atomic_load_explicit((_Atomic uint64_t *)&c->overruns, memory_order_relaxed);
}

uint64_t jk_converter_write_count(const JKConverter *c) {
    return atomic_load_explicit((_Atomic uint64_t *)&c->writes, memory_order_relaxed);
}
