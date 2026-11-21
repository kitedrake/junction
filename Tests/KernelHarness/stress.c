// Stress test for the render kernel's sample-rate converter, built with address and undefined-behaviour sanitizers
// by test.sh: random buffer sizes on both sides, stalls of either side, odd buffer layouts and every pair of common
// rates, through a renderer that mixes converted channels. Any out-of-bounds access stops the run; the output must
// stay finite and bounded.
#include "JunctionKernel.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t state = 0x9E3779B97F4A7C15ull;
static uint32_t Random(uint32_t below) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return (uint32_t)(state % below);
}

static int failures = 0;
#define CHECK(condition, ...) do { if (!(condition)) { failures++; printf("FAIL " __VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double ticks = 1e9 * timebase.denom / timebase.numer;
    const double rates[] = {44100, 48000, 88200, 96000, 192000};
    float *source = malloc(sizeof(float) * 8192 * 3);
    float *sink = malloc(sizeof(float) * (JK_MAX_FRAMES + 512) * 2);
    for (int a = 0; a < 5; a++) {
        for (int b = 0; b < 5; b++) {
            if (a == b) continue;
            double in = rates[a], out = rates[b];
            JKConverter *converter = jk_converter_create(3, in, out);
            CHECK(converter != NULL, "create %g → %g", in, out);
            if (!converter) continue;
            // Aggregate: 1 input channel; converted channels 1…3; sink: 2 outputs.
            uint32_t sources[] = {0, 1, 2, 3}, destinations[] = {0, 0, 1, 1};
            float gains[] = {1, 1, 1, 0.5f};
            JKRenderer *renderer = jk_renderer_create_converting(1, 2, 4, sources, destinations, gains, &converter, 1);
            CHECK(renderer != NULL, "renderer %g → %g", in, out);
            double now = 0, nextWrite = 0, nextRead = 0, inSample = 0, outSample = 0, phase = 0;
            uint32_t writeSize = 64 + Random(2048), readSize = 32 + Random(JK_MAX_FRAMES + 400);
            float peak = 0;
            int finite = 1;
            while (now < 20) {
                int writing = nextWrite <= nextRead;
                now = writing ? nextWrite : nextRead;
                if (Random(200) == 0) writeSize = 1 + Random(8192);    // a device changes its buffer size
                if (Random(200) == 0) readSize = 1 + Random(JK_MAX_FRAMES + 400);
                if (writing) {
                    if (Random(500) != 0 || (now > 5 && now < 5.3)) {  // and sometimes misses a cycle
                        for (uint32_t f = 0; f < writeSize; f++) {
                            float value = (float)(0.5 * sin(phase)) + (float)(Random(1000)) / 10000.0f;
                            phase += 2 * M_PI * 1000 / in;
                            for (int c = 0; c < 3; c++) source[f * 3 + c] = value;
                        }
                        AudioBufferList list = {1, {{3, writeSize * 12, source}}};
                        AudioTimeStamp time = {.mSampleTime = inSample, .mHostTime = (uint64_t)(1e6 + now * ticks),
                                               .mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid};
                        jk_converter_write(converter, (now > 5 && now < 5.3) ? NULL : &list, &time);
                    }
                    inSample += writeSize;
                    nextWrite = now + writeSize / in;
                } else {
                    if (!(now > 9 && now < 10.5) && Random(300) != 0) {  // the sink stalls, then misses cycles
                        float aggregate[JK_MAX_FRAMES + 512];
                        for (uint32_t f = 0; f < readSize; f++) aggregate[f] = 0.1f;
                        AudioBufferList input = {1, {{1, readSize * 4, aggregate}}};
                        AudioBufferList output = {1, {{2, readSize * 8, sink}}};
                        AudioTimeStamp time = {.mSampleTime = outSample, .mHostTime = (uint64_t)(1e6 + now * ticks),
                                               .mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid};
                        jk_renderer_ioproc(0, &time, &input, &time, &output, &time, renderer);
                        for (uint32_t i = 0; i < readSize * 2; i++) {
                            if (!isfinite(sink[i])) finite = 0;
                            if (fabsf(sink[i]) > peak) peak = fabsf(sink[i]);
                        }
                    }
                    outSample += readSize;
                    nextRead = now + readSize / out;
                }
            }
            CHECK(finite, "%g → %g: output is finite", in, out);
            CHECK(peak < 2.5f, "%g → %g: output stays bounded (peak %g)", in, out, peak);
            CHECK(jk_renderer_cycle_count(renderer) > 0, "%g → %g: rendered", in, out);
            printf("ok   %6g → %6g Hz: peak %.2f, %llu underruns, %llu overruns, ratio %.6f\n", in, out, peak,
                   (unsigned long long)jk_converter_underrun_count(converter),
                   (unsigned long long)jk_converter_overrun_count(converter), jk_converter_ratio(converter));
            jk_renderer_destroy(renderer);
            jk_converter_destroy(converter);
        }
    }
    free(source);
    free(sink);
    printf(failures ? "Kernel stress test: %d failure(s).\n" : "Kernel stress test passed.\n", failures);
    return failures ? 1 : 0;
}
