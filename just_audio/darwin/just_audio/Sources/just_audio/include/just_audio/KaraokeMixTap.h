#ifndef KARAOKE_MIX_TAP_H
#define KARAOKE_MIX_TAP_H

#import <Foundation/Foundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Mix state shared between the plugin and the realtime audio thread.
///
/// Heap-allocated and owned by `AudioPlayer`, which hands the pointer to every
/// `UriAudioSource` it builds; the taps those sources install read it on every
/// process callback. The pointer must outlive every tap that was given it.
typedef struct {
    /// Whether the user's gains apply. When false a four-channel source is
    /// still folded down to stereo — it has to be — but at unity on both
    /// stems, which reproduces the original mix.
    atomic_bool enabled;
    _Atomic float vocalGain;
    _Atomic float instrumentalGain;
    /// Set by the tap once it knows the source format: true when the asset
    /// really did arrive with four channels and the downmix is running. Lets
    /// the app tell "the slider does nothing" apart from "the slider is at
    /// zero" instead of leaving the user to wonder.
    atomic_bool active;
} KaraokeMixParams;

KaraokeMixParams *_Nullable karaoke_mix_params_create(void);
void karaoke_mix_params_free(KaraokeMixParams *_Nullable params);

/// Creates a tap that folds a four-channel karaoke source — vocal stem on
/// channels 0/1, instrumental stem on channels 2/3 — down to stereo with an
/// independent gain per stem, reading `params` on every pass:
///
///     out_L = vocalGain * ch0 + instrumentalGain * ch2
///     out_R = vocalGain * ch1 + instrumentalGain * ch3
///
/// The mix is written back over channels 0/1 and the stem channels are zeroed,
/// so whatever downmix the system applies on the way to a stereo device passes
/// the result through rather than summing the stems a second time.
///
/// Anything with fewer than four channels is passed through untouched. The tap
/// does not take ownership of `params`.
MTAudioProcessingTapRef _Nullable karaoke_mix_create(KaraokeMixParams *_Nonnull params);

#ifdef __cplusplus
}
#endif

#endif /* KARAOKE_MIX_TAP_H */
