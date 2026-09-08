#import "./include/just_audio/KaraokeMixTap.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

// Mirrors android/KaraokeMixProcessor.java.
static const int kVocalLeft = 0;
static const int kVocalRight = 1;
static const int kInstrumentalLeft = 2;
static const int kInstrumentalRight = 3;
static const int kRequiredChannelCount = 4;

/// Compensates for the matrix the system applies when folding a multichannel
/// asset onto a stereo device. With the stem channels zeroed the usual matrix
/// passes channels 0/1 through at unity, so this is 1.0; raise it only if a
/// measured karaoke file comes out quieter than the same mix as plain stereo.
static const float kOutputMakeupGain = 1.0f;

typedef struct {
    KaraokeMixParams *params; // Owned by AudioPlayer, not by the tap.
    UInt32 channelCount;
    bool isNonInterleaved;
    bool prepared; // Four-channel float PCM; otherwise this tap passes through.
} KaraokeMixState;

static inline float karaoke_clampf(float v) {
    if (v > 1.0f) return 1.0f;
    if (v < -1.0f) return -1.0f;
    return v;
}

KaraokeMixParams *karaoke_mix_params_create(void) {
    KaraokeMixParams *params = (KaraokeMixParams *)calloc(1, sizeof(KaraokeMixParams));
    if (!params) return NULL;
    atomic_init(&params->enabled, false);
    atomic_init(&params->vocalGain, 1.0f);
    atomic_init(&params->instrumentalGain, 1.0f);
    atomic_init(&params->active, false);
    return params;
}

void karaoke_mix_params_free(KaraokeMixParams *params) {
    if (params) free(params);
}

static void karaoke_mix_init_cb(MTAudioProcessingTapRef tap,
                                void *clientInfo,
                                void **tapStorageOut) {
    KaraokeMixState *s = (KaraokeMixState *)calloc(1, sizeof(KaraokeMixState));
    if (!s) {
        *tapStorageOut = NULL;
        return;
    }
    s->params = (KaraokeMixParams *)clientInfo;
    s->prepared = false;
    *tapStorageOut = s;
}

static void karaoke_mix_finalize_cb(MTAudioProcessingTapRef tap) {
    KaraokeMixState *s = (KaraokeMixState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    // `params` outlives the tap and is freed by AudioPlayer.
    free(s);
}

static void karaoke_mix_prepare_cb(MTAudioProcessingTapRef tap,
                                   CMItemCount maxFrames,
                                   const AudioStreamBasicDescription *processingFormat) {
    KaraokeMixState *s = (KaraokeMixState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;

    s->channelCount = processingFormat->mChannelsPerFrame;
    s->isNonInterleaved = (processingFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    bool isFloat = (processingFormat->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    s->prepared = isFloat && s->channelCount >= kRequiredChannelCount;

    if (s->params) {
        atomic_store_explicit(&s->params->active, s->prepared, memory_order_relaxed);
    }

    // Whether the four channels survive as far as the tap is the one thing
    // about this path that can't be settled by reading the code, so say what
    // arrived rather than failing quietly.
    NSLog(@"KaraokeMixTap prepared: ch=%u rate=%.0f nonInterleaved=%d float=%d -> %@",
          (unsigned)s->channelCount, processingFormat->mSampleRate,
          s->isNonInterleaved ? 1 : 0, isFloat ? 1 : 0,
          s->prepared ? @"mixing" : @"passthrough (source is not 4-channel float PCM)");
}

static void karaoke_mix_unprepare_cb(MTAudioProcessingTapRef tap) {
    KaraokeMixState *s = (KaraokeMixState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    s->prepared = false;
    if (s->params) {
        atomic_store_explicit(&s->params->active, false, memory_order_relaxed);
    }
}

static void karaoke_mix_process_cb(MTAudioProcessingTapRef tap,
                                   CMItemCount numberFrames,
                                   MTAudioProcessingTapFlags flags,
                                   AudioBufferList *bufferListInOut,
                                   CMItemCount *numberFramesOut,
                                   MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap,
                                                         numberFrames,
                                                         bufferListInOut,
                                                         flagsOut,
                                                         NULL,
                                                         numberFramesOut);
    if (status != noErr) {
        return;
    }

    KaraokeMixState *s = (KaraokeMixState *)MTAudioProcessingTapGetStorage(tap);
    if (!s || !s->prepared || !s->params) {
        return;
    }

    int numFrames = (int)(*numberFramesOut);
    if (numFrames <= 0) return;

    // Disabled means "play it as it was mixed", not "mute a stem" — the fold to
    // stereo still has to happen either way.
    bool enabled = atomic_load_explicit(&s->params->enabled, memory_order_relaxed);
    float vocal = enabled
        ? atomic_load_explicit(&s->params->vocalGain, memory_order_relaxed) : 1.0f;
    float instrumental = enabled
        ? atomic_load_explicit(&s->params->instrumentalGain, memory_order_relaxed) : 1.0f;
    vocal *= kOutputMakeupGain;
    instrumental *= kOutputMakeupGain;

    if (s->isNonInterleaved) {
        if (bufferListInOut->mNumberBuffers < (UInt32)kRequiredChannelCount) return;
        float *vocalL = (float *)bufferListInOut->mBuffers[kVocalLeft].mData;
        float *vocalR = (float *)bufferListInOut->mBuffers[kVocalRight].mData;
        float *instrL = (float *)bufferListInOut->mBuffers[kInstrumentalLeft].mData;
        float *instrR = (float *)bufferListInOut->mBuffers[kInstrumentalRight].mData;
        if (!vocalL || !vocalR || !instrL || !instrR) return;

        for (int n = 0; n < numFrames; n++) {
            float left = vocalL[n] * vocal + instrL[n] * instrumental;
            float right = vocalR[n] * vocal + instrR[n] * instrumental;
            vocalL[n] = karaoke_clampf(left);
            vocalR[n] = karaoke_clampf(right);
        }
        // Silence the stem channels so the system's fold to a stereo device
        // doesn't sum them back in on top of the mix we just wrote.
        for (UInt32 b = kInstrumentalLeft; b < bufferListInOut->mNumberBuffers; b++) {
            float *samples = (float *)bufferListInOut->mBuffers[b].mData;
            if (samples) memset(samples, 0, sizeof(float) * (size_t)numFrames);
        }
    } else {
        if (bufferListInOut->mNumberBuffers < 1) return;
        float *samples = (float *)bufferListInOut->mBuffers[0].mData;
        if (!samples) return;
        int channels = (int)s->channelCount;
        if (channels < kRequiredChannelCount) return;

        for (int n = 0; n < numFrames; n++) {
            int base = n * channels;
            float left = samples[base + kVocalLeft] * vocal
                       + samples[base + kInstrumentalLeft] * instrumental;
            float right = samples[base + kVocalRight] * vocal
                        + samples[base + kInstrumentalRight] * instrumental;
            samples[base + kVocalLeft] = karaoke_clampf(left);
            samples[base + kVocalRight] = karaoke_clampf(right);
            for (int c = kInstrumentalLeft; c < channels; c++) {
                samples[base + c] = 0.0f;
            }
        }
    }
}

MTAudioProcessingTapRef karaoke_mix_create(KaraokeMixParams *params) {
    MTAudioProcessingTapCallbacks callbacks = {
        .version = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = params,
        .init = karaoke_mix_init_cb,
        .finalize = karaoke_mix_finalize_cb,
        .prepare = karaoke_mix_prepare_cb,
        .unprepare = karaoke_mix_unprepare_cb,
        .process = karaoke_mix_process_cb,
    };
    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault,
                                                 &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PreEffects,
                                                 &tap);
    if (status != noErr) {
        NSLog(@"MTAudioProcessingTapCreate (karaoke) failed with OSStatus %d", (int)status);
        return NULL;
    }
    return tap;
}
