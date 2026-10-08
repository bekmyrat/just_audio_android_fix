#ifndef MULTI_TAP_ECHO_TAP_H
#define MULTI_TAP_ECHO_TAP_H

#import <Foundation/Foundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Creates a multi-tap echo MTAudioProcessingTap that reads the enabled flag
/// pointed to by `enabled_flag` on every process callback. Passthrough when
/// disabled. Mirrors the Android MultiTapEchoProcessor DSP parameters.
///
/// The pointer must remain valid for the lifetime of the tap. The tap does
/// not take ownership of the pointer.
MTAudioProcessingTapRef _Nullable multi_tap_echo_create(atomic_bool *_Nonnull enabled_flag);

/// The echo DSP on its own, for a tap that does other work as well. A player
/// item holds a single tap, so the karaoke downmix runs this itself on the
/// stereo pair it folds down to, rather than leaving echo with no way in.
typedef struct MultiTapEcho MultiTapEcho;

MultiTapEcho *_Nullable multi_tap_echo_new(void);
void multi_tap_echo_free(MultiTapEcho *_Nullable echo);

/// Sizes the delay lines for `channels` channels. Call from the owning tap's
/// prepare callback.
void multi_tap_echo_prepare(MultiTapEcho *_Nonnull echo,
                            UInt32 channels,
                            Float64 sampleRate,
                            CMItemCount maxFrames);

/// Releases the delay lines. Call from the owning tap's unprepare callback.
void multi_tap_echo_unprepare(MultiTapEcho *_Nonnull echo);

/// Echoes the first `channels` channels of the float PCM in `buffers`, in
/// place: one buffer per channel when `nonInterleaved`, otherwise one buffer
/// of `stride`-channel frames. Passthrough when `enabled` is false. The delay
/// lines are cleared whenever `enabled` changes, so switching echo on never
/// replays audio from before.
void multi_tap_echo_process(MultiTapEcho *_Nonnull echo,
                            bool enabled,
                            AudioBufferList *_Nonnull buffers,
                            int frames,
                            bool nonInterleaved,
                            UInt32 stride,
                            UInt32 channels);

#ifdef __cplusplus
}
#endif

#endif /* MULTI_TAP_ECHO_TAP_H */
