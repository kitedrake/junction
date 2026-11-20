// The real-time part of Junction's router, in C so the audio thread never touches Swift reference counting,
// locks or allocation. One renderer serves one sink: it reads the private aggregate device's input buffers
// (every source's channels, side by side) and mixes them into the sink's output channels.
#ifndef JUNCTION_KERNEL_H
#define JUNCTION_KERNEL_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JKRenderer JKRenderer;

/// Creates a renderer. `inputChannels` is how many channels the aggregate's input buffers should hold in total,
/// `outputChannels` how many of the first output channels belong to the sink (later ones belong to other
/// sub-devices and get silence). Route i adds input channel `sources[i]` to output channel `destinations[i]`
/// at linear gain `gains[i]`. Returns NULL if memory runs out.
JKRenderer *_Nullable jk_renderer_create(uint32_t inputChannels, uint32_t outputChannels, uint32_t routeCount,
                                         const uint32_t *_Nullable sources, const uint32_t *_Nullable destinations,
                                         const float *_Nullable gains);

/// Frees the renderer. Only call once the IOProc using it has been destroyed.
void jk_renderer_destroy(JKRenderer *_Nonnull renderer);

/// Changes a route's gain; the audio thread glides to it over one buffer.
void jk_renderer_set_route_gain(JKRenderer *_Nonnull renderer, uint32_t route, float gain);

/// Gain applied to everything the sink receives (the sink node's fader and mute).
void jk_renderer_set_master_gain(JKRenderer *_Nonnull renderer, float gain);

/// Highest absolute sample value on an input / output channel since the last call (then resets it).
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
