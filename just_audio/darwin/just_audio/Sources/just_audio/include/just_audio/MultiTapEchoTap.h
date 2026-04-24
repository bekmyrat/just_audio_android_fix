#ifndef MULTI_TAP_ECHO_TAP_H
#define MULTI_TAP_ECHO_TAP_H

#import <Foundation/Foundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>

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

#ifdef __cplusplus
}
#endif

#endif /* MULTI_TAP_ECHO_TAP_H */
