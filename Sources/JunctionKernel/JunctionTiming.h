// How long rendering takes, for the renderer's overload count and each effect stage's load. Audio-thread safe:
// mach_absolute_time and atomics only.
#ifndef JUNCTION_TIMING_H
#define JUNCTION_TIMING_H

#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

/// Seconds per mach_absolute_time tick. Off the audio thread (when a renderer or chain is made).
static inline double jk_seconds_per_tick(void) {
    mach_timebase_info_data_t base;
    if (mach_timebase_info(&base) != KERN_SUCCESS || base.denom == 0) return 1e-9;
    return (double)base.numer / (double)base.denom * 1e-9;
}

/// The share of a buffer's duration (`frames` at `sampleRate`) that `ticks` of work took.
static inline float jk_load(uint64_t ticks, double secondsPerTick, uint32_t frames, double sampleRate) {
    double duration = (double)frames / sampleRate;
    return duration > 0 ? (float)((double)ticks * secondsPerTick / duration) : 0;
}

/// Raises a peak load kept as float bits (non-negative floats order like their bit patterns).
static inline void jk_raise_load(_Atomic uint32_t *slot, float load) {
    if (!(load > 0)) return;
    uint32_t bits;
    memcpy(&bits, &load, sizeof bits);
    uint32_t old = atomic_load_explicit(slot, memory_order_relaxed);
    while (bits > old && !atomic_compare_exchange_weak_explicit(slot, &old, bits, memory_order_relaxed,
                                                                 memory_order_relaxed)) {
    }
}

#endif
