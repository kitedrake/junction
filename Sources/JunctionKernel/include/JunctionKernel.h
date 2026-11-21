// The real-time part of Junction's router, in C so the audio thread never touches Swift reference counting,
// locks or allocation. One renderer serves one sink: it reads the private aggregate device's input buffers
// (every source's channels, side by side) and mixes them into the sink's output channels. A source device running
// at another sample rate stays outside the aggregate: its own IOProc feeds a converter (a lock-free ring and a
// resampler), and the renderer reads the converted audio after the aggregate's channels. Per-app capture works the
// same way: the renderer's IOProc pumps what an app played into one of Junction's devices from the driver's shared
// ring (JunctionCaptureRing.h) into a converter of its own. Effect chains (built-in effects and Audio Units) process
// each source's channels before the mix (on lanes of their own) and the sink's channels after it; a chain is swapped
// in with one atomic pointer store and freed once the audio thread can no longer be using it.
#ifndef JUNCTION_KERNEL_H
#define JUNCTION_KERNEL_H

#include <AudioToolbox/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

// The driver's per-app capture region: SwiftPM makes this file the module's umbrella header, so Swift sees the ring
// layout and its reader functions through it.
#include "JunctionCaptureRing.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JKRenderer JKRenderer;
typedef struct JKConverter JKConverter;
typedef struct JKCapture JKCapture;

/// The largest IO buffer, in frames, that converted audio is delivered for in one cycle (longer cycles get silence
/// on converted channels and count as a layout mismatch).
#define JK_MAX_FRAMES 4096
/// Taps of the resampler's windowed-sinc filter: it delays the audio by half as many input frames.
#define JK_CONVERTER_TAPS 64

// MARK: Sample-rate converter

/// Creates a converter for `channels` channels from a device running at `inputRate` to a sink at `outputRate`.
/// One thread writes (the source device's IOProc), another reads (the sink's IOProc); neither locks or allocates.
/// Returns NULL if memory runs out or an argument is out of range.
JKConverter *_Nullable jk_converter_create(uint32_t channels, double inputRate, double outputRate);

/// Marks the two devices as running on one clock (the same Core Audio clock domain, such as two of Junction's own
/// devices): the ratio stays at exactly inputRate / outputRate instead of following measured rates and the ring's
/// fill. Only call before either IOProc starts.
void jk_converter_set_same_clock(JKConverter *_Nonnull converter, int sameClock);
int jk_converter_same_clock(const JKConverter *_Nonnull converter);

/// Frees the converter. Only call once neither IOProc uses it any more.
void jk_converter_destroy(JKConverter *_Nonnull converter);

uint32_t jk_converter_channels(const JKConverter *_Nonnull converter);

/// Producer side: appends one IO cycle of the source device's input (interleaved buffers, channels side by side;
/// missing channels are written as silence). `time` is the input time stamp (sample and host time measure the
/// device's real rate). When the ring is full the block is dropped and the reader fades out and starts again.
void jk_converter_write(JKConverter *_Nonnull converter, const AudioBufferList *_Nullable input,
                        const AudioTimeStamp *_Nullable time);

/// The source device's AudioDeviceIOProc: writes its input to the converter (the client data) and outputs silence.
OSStatus jk_converter_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                             const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
                             AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime,
                             void *_Nullable clientData);

/// Consumer side: renders `frames` frames at the output rate into `output`, channel c starting at
/// `output + c * stride`. `time` is the sink's output time stamp. Gives silence (faded, never a click) while the ring
/// fills after a start, an underrun or an overrun. At most JK_MAX_FRAMES frames are rendered; the rest is silence.
void jk_converter_read(JKConverter *_Nonnull converter, float *_Nonnull output, uint32_t stride, uint32_t frames,
                       const AudioTimeStamp *_Nullable time);

/// Input frames waiting in the ring (including the filter's window) as of the last read, plus what the source device
/// has captured since its last write (so the level doesn't saw up and down with each write).
double jk_converter_fill(const JKConverter *_Nonnull converter);
/// The fill the converter steers towards (it grows to fit the largest buffers seen on either side).
double jk_converter_target_fill(const JKConverter *_Nonnull converter);
/// Input frames per output frame right now (nominally inputRate / outputRate).
double jk_converter_ratio(const JKConverter *_Nonnull converter);
/// The delay the converter adds, in seconds: the ring's buffering plus the filter's delay.
double jk_converter_delay(const JKConverter *_Nonnull converter);
/// The same, before any audio has run, for IO buffers of `outputFrames` (the sink) and `inputFrames` (the source).
double jk_converter_expected_delay(const JKConverter *_Nonnull converter, uint32_t outputFrames, uint32_t inputFrames);
/// Reads that ran out of input / writes that found the ring full.
uint64_t jk_converter_underrun_count(const JKConverter *_Nonnull converter);
uint64_t jk_converter_overrun_count(const JKConverter *_Nonnull converter);
/// IO cycles the producer has written so far (to tell whether the source device is still running).
uint64_t jk_converter_write_count(const JKConverter *_Nonnull converter);

// MARK: Per-app capture

/// Clients of one app (its processes playing into one device) a capture reads together.
#define JK_CAPTURE_MAX_SLOTS 8

/// Creates a reader of the driver's capture region (`regionSize` bytes, mapped by the caller and kept mapped until
/// the capture is destroyed) that mixes the given client slots, each still owned by the client with the matching
/// sequence, and passes `channels` channels on to `converter` (not owned), whose input rate is the device's,
/// `sampleRate`. Returns NULL for a region it doesn't understand, an argument out of range or no memory.
JKCapture *_Nullable jk_capture_create(const void *_Nonnull region, uint64_t regionSize, const uint32_t *_Nonnull slots,
                                       const uint32_t *_Nonnull sequences, uint32_t slotCount, uint32_t channels,
                                       double sampleRate, JKConverter *_Nonnull converter);
/// Frees the capture. Only call once the renderer using it has been destroyed.
void jk_capture_destroy(JKCapture *_Nonnull capture);
/// Audio thread: moves the frames the clients have written since the last call into the converter, with time stamps
/// on the driver's clock. Starts at the newest frame; a reader that fell behind by most of the ring skips ahead.
void jk_capture_pump(JKCapture *_Nonnull capture);
/// Frames passed on so far (to tell whether the clients still play), and times the reader skipped ahead or found
/// frames already overwritten.
uint64_t jk_capture_frame_count(const JKCapture *_Nonnull capture);
uint64_t jk_capture_overrun_count(const JKCapture *_Nonnull capture);

// MARK: Effects

/// An ordered effect chain for a fixed number of channels: built and given its stages off the audio thread, then
/// handed to a renderer (`jk_renderer_swap_chain`), which processes it in place every IO cycle. Bypass and the
/// built-in effects' parameters change through atomics while it runs; anything else means building a new chain and
/// swapping it in.
typedef struct JKChain JKChain;
/// An Audio Unit prepared for a chain: its input callback, buffers and time stamps (the unit itself isn't owned).
typedef struct JKUnit JKUnit;

/// Effects built into the kernel. Parameters:
/// - gain: 0 = linear gain (glides over one buffer).
/// - pan: 0 = position, -1 (left) … 1 (right); even channels count as left, odd ones as right (a balance).
/// - mono: none; every channel gets the average of all of them.
/// - gate: 0 = threshold (linear peak level), 1 = release in seconds. Opens in 1 ms and holds for 50 ms.
typedef enum {
    JK_EFFECT_CUSTOM = 0,
    JK_EFFECT_GAIN = 1,
    JK_EFFECT_PAN = 2,
    JK_EFFECT_MONO = 3,
    JK_EFFECT_GATE = 4,
} JKEffectKind;

#define JK_EFFECT_MAX_PARAMETERS 4
/// Which chain `jk_renderer_swap_chain` replaces: a source slot's (0…), or the one after the mix.
#define JK_OUTPUT_CHAIN UINT32_MAX

/// Processes `frames` frames (at most JK_MAX_FRAMES) of `channelCount` non-interleaved channels in place. Runs on the
/// audio thread: no locks, no allocation.
typedef void (*JKEffectProcess)(void *_Nullable context, float *_Nonnull const *_Nonnull channels, uint32_t channelCount,
                                uint32_t frames);

/// Creates an empty chain for `channels` channels at `sampleRate`, with room for `capacity` stages.
JKChain *_Nullable jk_chain_create(uint32_t channels, double sampleRate, uint32_t capacity);
/// Frees the chain (not the units in it). Only once no renderer can still be processing it.
void jk_chain_destroy(JKChain *_Nonnull chain);
uint32_t jk_chain_channels(const JKChain *_Nonnull chain);
uint32_t jk_chain_count(const JKChain *_Nonnull chain);
/// Appends a built-in effect, a callback or a unit; returns its stage index, or -1 when the chain is full or the kind
/// unknown. Only before the chain is handed to a renderer.
int jk_chain_add(JKChain *_Nonnull chain, JKEffectKind kind);
int jk_chain_add_custom(JKChain *_Nonnull chain, JKEffectProcess _Nonnull process, void *_Nullable context);
int jk_chain_add_unit(JKChain *_Nonnull chain, JKUnit *_Nonnull unit);
/// A bypassed stage leaves the audio as it is. Any thread.
void jk_chain_set_bypass(JKChain *_Nonnull chain, uint32_t stage, int bypass);
int jk_chain_bypassed(const JKChain *_Nonnull chain, uint32_t stage);
/// A built-in effect's parameter (see JKEffectKind). Any thread.
void jk_chain_set_parameter(JKChain *_Nonnull chain, uint32_t stage, uint32_t parameter, float value);
float jk_chain_parameter(const JKChain *_Nonnull chain, uint32_t stage, uint32_t parameter);
/// Runs every stage that isn't bypassed, in order, on `channelCount` channels (at most the chain's). Audio thread.
void jk_chain_process(JKChain *_Nonnull chain, float *_Nonnull const *_Nonnull channels, uint32_t channelCount,
                      uint32_t frames);

// MARK: Timing

/// A stage taking more than this share of its buffer's duration counts as a stall (see jk_chain_stage_timing).
#define JK_STALL_LOAD 0.5f
/// A renderer IO cycle taking more than this share of its buffer's duration counts as an overload: with Core Audio's
/// own work on the same thread, the audio can't have been ready in time.
#define JK_OVERLOAD_LOAD 0.9f

/// How long rendering took so far. `late`: a chain stage's stalls, or a renderer's overloads. `peakLoad`: the largest
/// share of a buffer's duration one render took (since the last time it was taken).
typedef struct {
    uint64_t frames;
    double seconds;
    uint64_t late;
    float peakLoad;
} JKTiming;

/// A stage's timing. Bypassed renders don't count. Any thread; `takePeak` resets the peak.
void jk_chain_stage_timing(JKChain *_Nonnull chain, uint32_t stage, JKTiming *_Nonnull timing, int takePeak);

/// Prepares `unit` (an initialised effect whose input and output stream formats are `channels` non-interleaved float
/// channels, and whose MaximumFramesPerSlice is at least JK_MAX_FRAMES) for chains: sets its input callback and makes
/// its buffers. Off the audio thread. Returns NULL if the callback can't be set or memory runs out.
JKUnit *_Nullable jk_unit_create(AudioUnit _Nonnull unit, uint32_t channels);
/// Removes the input callback and frees the buffers (the unit stays). Only once no chain can still render it.
void jk_unit_destroy(JKUnit *_Nonnull unit);
/// Renders `frames` frames of `channels` through the unit (AudioUnitRender) in place. A unit another thread is
/// rendering at that moment (two sinks overlap while one replaces the other), a channel count other than the unit's,
/// or a render error leaves the audio as it is. Audio thread; also the JKEffectProcess of a unit stage.
void jk_unit_process(void *_Nullable unit, float *_Nonnull const *_Nonnull channels, uint32_t channelCount,
                     uint32_t frames);
/// Renders that failed (the audio passed through unchanged).
uint64_t jk_unit_error_count(const JKUnit *_Nonnull unit);

// MARK: Renderer

/// Creates a renderer. `inputChannels` is how many channels the aggregate's input buffers should hold in total,
/// `outputChannels` how many of the first output channels belong to the sink (later ones belong to other
/// sub-devices and get silence). Route i adds input channel `sources[i]` to output channel `destinations[i]`
/// at linear gain `gains[i]`. Returns NULL if memory runs out.
JKRenderer *_Nullable jk_renderer_create(uint32_t inputChannels, uint32_t outputChannels, uint32_t routeCount,
                                         const uint32_t *_Nullable sources, const uint32_t *_Nullable destinations,
                                         const float *_Nullable gains);

/// Like `jk_renderer_create`, and also reads converted audio: input channels from `inputChannels` on are the
/// converters' channels, one converter after another. The renderer doesn't own the converters; free them after it.
JKRenderer *_Nullable jk_renderer_create_converting(uint32_t inputChannels, uint32_t outputChannels, uint32_t routeCount,
                                                    const uint32_t *_Nullable sources,
                                                    const uint32_t *_Nullable destinations,
                                                    const float *_Nullable gains,
                                                    JKConverter *_Nonnull const *_Nullable converters,
                                                    uint32_t converterCount);

/// Like `jk_renderer_create_converting`, with effect slots for sources: slot s has `slotChannels[s]` lanes, and lane
/// l (counting through all slots) carries input channel `laneSources[l]` (the aggregate's and the converters' channels
/// as above). Lanes are numbered after those channels, so route sources from there on read lanes. A lane passes its
/// channel through untouched while its slot has no chain (or an empty one); otherwise the slot's chain processes a
/// copy of its channels before the mix. Input peaks are taken on the lanes (after the effects) when there are any.
JKRenderer *_Nullable jk_renderer_create_slots(uint32_t inputChannels, uint32_t outputChannels, uint32_t routeCount,
                                               const uint32_t *_Nullable sources, const uint32_t *_Nullable destinations,
                                               const float *_Nullable gains,
                                               JKConverter *_Nonnull const *_Nullable converters, uint32_t converterCount,
                                               uint32_t slotCount, const uint32_t *_Nullable slotChannels,
                                               const uint32_t *_Nullable laneSources);

/// Puts `chain` (or NULL for none) in a source slot, or after the mix with JK_OUTPUT_CHAIN, with one atomic swap, and
/// returns the chain it replaces (NULL if none). The audio thread may still be processing that one: free it once
/// `jk_renderer_is_done_with(renderer, *ticket)` says so, or once the IOProc is gone. The chain after the mix runs
/// after the routes' gains and before the cross-fade, on the sink's channels. Any thread but the audio thread.
JKChain *_Nullable jk_renderer_swap_chain(JKRenderer *_Nonnull renderer, uint32_t slot, JKChain *_Nullable chain,
                                          uint64_t *_Nonnull ticket);
/// Whether every IO cycle that could have seen the chain swapped out with `ticket` has finished.
int jk_renderer_is_done_with(const JKRenderer *_Nonnull renderer, uint64_t ticket);
uint32_t jk_renderer_slot_count(const JKRenderer *_Nonnull renderer);

/// Has the renderer pump these captures (not owned) at the start of every IO cycle, before it reads the converters
/// they feed. Only call before the IOProc starts. Returns 0 if memory runs out.
int jk_renderer_set_captures(JKRenderer *_Nonnull renderer, JKCapture *_Nonnull const *_Nullable captures, uint32_t count);

/// The sink's sample rate, so the IOProc can tell how long it may take. Only call before the IOProc starts. Without
/// one (or with 0) nothing is timed.
void jk_renderer_set_sample_rate(JKRenderer *_Nonnull renderer, double sampleRate);
/// How long the IOProc's rendering took so far; `late` counts its overloads. Any thread; `takePeak` resets the peak.
void jk_renderer_timing(JKRenderer *_Nonnull renderer, JKTiming *_Nonnull timing, int takePeak);

/// Frees the renderer. Only call once the IOProc using it has been destroyed.
void jk_renderer_destroy(JKRenderer *_Nonnull renderer);

/// Changes a route's gain; the audio thread glides to it over one buffer.
void jk_renderer_set_route_gain(JKRenderer *_Nonnull renderer, uint32_t route, float gain);

/// Gain applied to everything the sink receives (the sink node's fader and mute).
void jk_renderer_set_master_gain(JKRenderer *_Nonnull renderer, float gain);

/// Fades everything the sink receives to `target` (0…1) at a rate of one full 0 → 1 ramp per `frames` frames, on top
/// of the route and master gains. Used to cross-fade a rebuilt sink with its replacement.
void jk_renderer_fade(JKRenderer *_Nonnull renderer, float target, uint32_t frames);

/// Sets the fade at once (e.g. 0 so a new sink can fade in). Only call before the IOProc starts.
void jk_renderer_set_fade_now(JKRenderer *_Nonnull renderer, float level);

/// Where the fade stood after the last IO cycle (0 = silent, 1 = full).
float jk_renderer_fade_level(const JKRenderer *_Nonnull renderer);

/// Highest absolute sample value on an input / output channel since the last call (then resets it). Input channels
/// count the converters' channels after the aggregate's.
float jk_renderer_take_input_peak(JKRenderer *_Nonnull renderer, uint32_t channel);
float jk_renderer_take_output_peak(JKRenderer *_Nonnull renderer, uint32_t channel);

/// Number of IO cycles rendered so far, and how many of them had a buffer layout other than expected.
uint64_t jk_renderer_cycle_count(const JKRenderer *_Nonnull renderer);
uint64_t jk_renderer_layout_mismatch_count(const JKRenderer *_Nonnull renderer);

/// The AudioDeviceIOProc. Pass the renderer as client data.
OSStatus jk_renderer_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                            const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
                            AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime,
                            void *_Nullable clientData);

#ifdef __cplusplus
}
#endif

#endif
