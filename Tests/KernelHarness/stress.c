// Stress test for the render kernel's sample-rate converter, built with address and undefined-behaviour sanitizers
// by test.sh: random buffer sizes on both sides, stalls of either side, odd buffer layouts and every pair of common
// rates, through a renderer that mixes converted channels. Any out-of-bounds access stops the run; the output must
// stay finite and bounded. Then effect chains are swapped in and out from one thread while another renders through
// them: a chain freed too early is a use-after-free the address sanitizer reports.
#include "JunctionKernel.h"

#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
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

// MARK: Chains swapped while rendering

typedef struct {
    JKRenderer *renderer;
    _Atomic int stop;
    _Atomic uint64_t rendered;
    int finite;
} ChainRun;

static void *RenderLoop(void *argument) {
    ChainRun *run = argument;
    static float input[(JK_MAX_FRAMES + 512) * 2], output[(JK_MAX_FRAMES + 512) * 2];
    uint64_t seed = 0x2545F4914F6CDD1Dull;
    while (!atomic_load(&run->stop)) {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        uint32_t frames = 1 + (uint32_t)(seed % (JK_MAX_FRAMES + 300));  // now and then longer than chains take
        for (uint32_t i = 0; i < frames * 2; i++) input[i] = 0.25f * (float)((i * 7919) % 200) / 100.0f - 0.25f;
        AudioBufferList in = {1, {{2, frames * 8, input}}};
        AudioBufferList out = {1, {{2, frames * 8, output}}};
        AudioTimeStamp time = {0};
        jk_renderer_ioproc(0, &time, &in, &time, &out, &time, run->renderer);
        for (uint32_t i = 0; i < frames * 2; i++) if (!isfinite(output[i])) run->finite = 0;
        atomic_fetch_add(&run->rendered, 1);
    }
    return NULL;
}

static JKChain *RandomChain(uint32_t channels) {
    JKChain *chain = jk_chain_create(channels, 48000, 6);
    if (!chain) return NULL;
    uint32_t stages = Random(6);
    for (uint32_t i = 0; i < stages; i++) {
        int stage = jk_chain_add(chain, (JKEffectKind)(JK_EFFECT_GAIN + Random(4)));
        jk_chain_set_parameter(chain, (uint32_t)stage, 0, (float)Random(100) / 50.0f);
        jk_chain_set_bypass(chain, (uint32_t)stage, Random(4) == 0);
    }
    return chain;
}

static void StressChains(void) {
    // Two stereo sources on lanes (slots 0 and 1), mixed into a stereo sink with a chain after the mix.
    uint32_t slotChannels[] = {2, 2}, laneSources[] = {0, 1, 1, 0};
    uint32_t sources[] = {2, 3, 4, 5}, destinations[] = {0, 1, 0, 1};
    float gains[] = {0.5f, 0.5f, 0.5f, 0.5f};
    ChainRun run = {.renderer = jk_renderer_create_slots(2, 2, 4, sources, destinations, gains, NULL, 0, 2, slotChannels,
                                                         laneSources),
                    .finite = 1};
    CHECK(run.renderer != NULL, "renderer with slots");
    if (!run.renderer) return;
    enum { Pending = 64 };
    struct { JKChain *chain; uint64_t ticket; } retired[Pending];
    int retiredCount = 0;
    uint64_t swaps = 0, handedBackWrong = 0;
    JKChain *live[3] = {NULL, NULL, NULL};
    pthread_t thread;
    pthread_create(&thread, NULL, RenderLoop, &run);
    uint64_t start = mach_absolute_time();
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    while ((double)(mach_absolute_time() - start) * timebase.numer / timebase.denom < 1.5e9) {
        uint32_t which = Random(3), slot = which == 2 ? JK_OUTPUT_CHAIN : which;
        uint64_t ticket;
        JKChain *chain = Random(5) == 0 ? NULL : RandomChain(2);
        JKChain *old = jk_renderer_swap_chain(run.renderer, slot, chain, &ticket);
        if (old != live[which]) handedBackWrong++;
        live[which] = chain;
        swaps++;
        if (old) {
            if (retiredCount == Pending) {  // wait for the oldest, as the router would on its next pass
                while (!jk_renderer_is_done_with(run.renderer, retired[0].ticket)) {}
                jk_chain_destroy(retired[0].chain);
                memmove(retired, retired + 1, sizeof retired[0] * (Pending - 1));
                retiredCount--;
            }
            retired[retiredCount].chain = old;
            retired[retiredCount].ticket = ticket;
            retiredCount++;
        }
        for (int i = 0; i < retiredCount;) {
            if (jk_renderer_is_done_with(run.renderer, retired[i].ticket)) {
                jk_chain_destroy(retired[i].chain);
                retired[i] = retired[--retiredCount];
            } else {
                i++;
            }
        }
        // Parameters and bypass change on the live chains while they render: atomics only.
        for (int i = 0; i < 3; i++) {
            if (!live[i] || !jk_chain_count(live[i])) continue;
            jk_chain_set_parameter(live[i], 0, 0, (float)Random(100) / 100.0f);
            jk_chain_set_bypass(live[i], jk_chain_count(live[i]) - 1, (int)Random(2));
        }
    }
    atomic_store(&run.stop, 1);
    pthread_join(thread, NULL);
    for (int i = 0; i < retiredCount; i++) jk_chain_destroy(retired[i].chain);
    for (uint32_t slot = 0; slot < 3; slot++) {
        uint64_t ticket;
        JKChain *last = jk_renderer_swap_chain(run.renderer, slot == 2 ? JK_OUTPUT_CHAIN : slot, NULL, &ticket);
        if (last) jk_chain_destroy(last);
    }
    CHECK(run.finite, "chains: output is finite");
    CHECK(handedBackWrong == 0, "chains: swaps hand back the chain that was there");
    CHECK(atomic_load(&run.rendered) > 100, "chains: rendered while swapping");
    printf("ok   chains: %llu swaps over %llu IO cycles\n", (unsigned long long)swaps,
           (unsigned long long)atomic_load(&run.rendered));
    jk_renderer_destroy(run.renderer);
}

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
    StressChains();
    printf(failures ? "Kernel stress test: %d failure(s).\n" : "Kernel stress test passed.\n", failures);
    return failures ? 1 : 0;
}
