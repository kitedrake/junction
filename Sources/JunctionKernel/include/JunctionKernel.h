// The real-time part of Junction's router, in C so the audio thread never touches Swift reference counting,
// locks or allocation. One renderer serves one sink: it reads the private aggregate device's input buffers
// (every source's channels, side by side) and mixes them into the sink's output channels. A source device running
// at another sample rate stays outside the aggregate: its own IOProc feeds a converter (a lock-free ring and a
// resampler), and the renderer reads the converted audio after the aggregate's channels.
#ifndef JUNCTION_KERNEL_H
#define JUNCTION_KERNEL_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JKRenderer JKRenderer;
typedef struct JKConverter JKConverter;

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
