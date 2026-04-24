#import "./include/just_audio/MultiTapEchoTap.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

// Parameters match android/MultiTapEchoProcessor.java.
#define kMaxChannels 8
static const float kInputGain = 0.8f;
static const float kOutputGain = 0.7f;
static const int kNumTaps = 3;
static const int kDelayMs[3] = {60, 120, 180};
static const float kDecays[3] = {0.4f, 0.3f, 0.2f};

typedef struct {
    // Shared flag owned by AudioPlayer, read on every process pass.
    atomic_bool *enabledFlag;
    bool wasEnabled;

    // One circular delay line per channel.
    float *delayLines[kMaxChannels];
    int delayLineLength;
    int tapSampleOffsets[3];
    int writeIndex;

    UInt32 channelCount;
    Float64 sampleRate;
    bool isNonInterleaved;
    bool prepared;
} MultiTapEchoState;

static inline float clampf(float v) {
    if (v > 1.0f) return 1.0f;
    if (v < -1.0f) return -1.0f;
    return v;
}

static void multi_tap_echo_zero_delay_lines(MultiTapEchoState *s) {
    UInt32 ch = s->channelCount;
    if (ch > kMaxChannels) ch = kMaxChannels;
    for (UInt32 c = 0; c < ch; c++) {
        if (s->delayLines[c]) {
            memset(s->delayLines[c], 0, sizeof(float) * (size_t)s->delayLineLength);
        }
    }
    s->writeIndex = 0;
}

static void multi_tap_echo_free_delay_lines(MultiTapEchoState *s) {
    for (int c = 0; c < kMaxChannels; c++) {
        if (s->delayLines[c]) {
            free(s->delayLines[c]);
            s->delayLines[c] = NULL;
        }
    }
}

static void multi_tap_echo_init_cb(MTAudioProcessingTapRef tap,
                                   void *clientInfo,
                                   void **tapStorageOut) {
    MultiTapEchoState *s = (MultiTapEchoState *)calloc(1, sizeof(MultiTapEchoState));
    if (!s) {
        *tapStorageOut = NULL;
        return;
    }
    s->enabledFlag = (atomic_bool *)clientInfo;
    s->wasEnabled = false;
    s->prepared = false;
    *tapStorageOut = s;
}

static void multi_tap_echo_finalize_cb(MTAudioProcessingTapRef tap) {
    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    multi_tap_echo_free_delay_lines(s);
    free(s);
}

static void multi_tap_echo_prepare_cb(MTAudioProcessingTapRef tap,
                                      CMItemCount maxFrames,
                                      const AudioStreamBasicDescription *processingFormat) {
    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;

    // Reset any prior allocations (e.g. if prepare is called again after unprepare).
    multi_tap_echo_free_delay_lines(s);

    s->channelCount = processingFormat->mChannelsPerFrame;
    s->sampleRate = processingFormat->mSampleRate;
    s->isNonInterleaved = (processingFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    int maxDelaySamples = 0;
    for (int i = 0; i < kNumTaps; i++) {
        s->tapSampleOffsets[i] = (int)((kDelayMs[i] * s->sampleRate) / 1000.0);
        if (s->tapSampleOffsets[i] > maxDelaySamples) {
            maxDelaySamples = s->tapSampleOffsets[i];
        }
    }
    s->delayLineLength = maxDelaySamples + (int)maxFrames + 1024;
    s->writeIndex = 0;
    s->wasEnabled = false;

    UInt32 channels = s->channelCount > kMaxChannels ? kMaxChannels : s->channelCount;
    for (UInt32 c = 0; c < channels; c++) {
        s->delayLines[c] = (float *)calloc((size_t)s->delayLineLength, sizeof(float));
    }
    // Only mark as prepared if the format is float PCM; otherwise the process
    // callback will treat this as passthrough to avoid corrupting non-float audio.
    bool isFloat = (processingFormat->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    s->prepared = isFloat;

    NSLog(@"MultiTapEchoTap prepared: ch=%u rate=%.0f nonInterleaved=%d float=%d frames=%d",
          (unsigned)s->channelCount, s->sampleRate,
          s->isNonInterleaved ? 1 : 0, isFloat ? 1 : 0, s->delayLineLength);
}

static void multi_tap_echo_unprepare_cb(MTAudioProcessingTapRef tap) {
    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    multi_tap_echo_free_delay_lines(s);
    s->prepared = false;
}

static void multi_tap_echo_process_cb(MTAudioProcessingTapRef tap,
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

    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s || !s->prepared || !s->enabledFlag) {
        return;
    }

    bool enabled = atomic_load_explicit(s->enabledFlag, memory_order_relaxed);
    if (enabled != s->wasEnabled) {
        multi_tap_echo_zero_delay_lines(s);
        s->wasEnabled = enabled;
    }
    if (!enabled) {
        // Passthrough; source audio is already sitting in bufferListInOut.
        return;
    }

    int numFrames = (int)(*numberFramesOut);
    if (numFrames <= 0) return;
    int dlen = s->delayLineLength;
    if (dlen <= 0) return;

    if (s->isNonInterleaved) {
        UInt32 bufCount = bufferListInOut->mNumberBuffers;
        if (bufCount > kMaxChannels) bufCount = kMaxChannels;
        int lastW = s->writeIndex;
        for (UInt32 b = 0; b < bufCount; b++) {
            float *samples = (float *)bufferListInOut->mBuffers[b].mData;
            float *delay = s->delayLines[b];
            if (!samples || !delay) continue;
            int w = s->writeIndex;
            for (int n = 0; n < numFrames; n++) {
                float inSample = samples[n];
                delay[w] = inSample;
                float mixed = inSample * kInputGain;
                for (int i = 0; i < kNumTaps; i++) {
                    int readIdx = w - s->tapSampleOffsets[i];
                    if (readIdx < 0) readIdx += dlen;
                    mixed += delay[readIdx] * kDecays[i];
                }
                samples[n] = clampf(mixed * kOutputGain);
                w++;
                if (w >= dlen) w = 0;
            }
            lastW = w;
        }
        s->writeIndex = lastW;
    } else {
        if (bufferListInOut->mNumberBuffers < 1) return;
        float *samples = (float *)bufferListInOut->mBuffers[0].mData;
        if (!samples) return;
        UInt32 ch = s->channelCount;
        if (ch == 0) return;
        if (ch > kMaxChannels) ch = kMaxChannels;
        int w = s->writeIndex;
        for (int n = 0; n < numFrames; n++) {
            for (UInt32 c = 0; c < ch; c++) {
                float *delay = s->delayLines[c];
                if (!delay) continue;
                int idx = n * (int)ch + (int)c;
                float inSample = samples[idx];
                delay[w] = inSample;
                float mixed = inSample * kInputGain;
                for (int i = 0; i < kNumTaps; i++) {
                    int readIdx = w - s->tapSampleOffsets[i];
                    if (readIdx < 0) readIdx += dlen;
                    mixed += delay[readIdx] * kDecays[i];
                }
                samples[idx] = clampf(mixed * kOutputGain);
            }
            w++;
            if (w >= dlen) w = 0;
        }
        s->writeIndex = w;
    }
}

MTAudioProcessingTapRef multi_tap_echo_create(atomic_bool *enabled_flag) {
    MTAudioProcessingTapCallbacks callbacks = {
        .version = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = enabled_flag,
        .init = multi_tap_echo_init_cb,
        .finalize = multi_tap_echo_finalize_cb,
        .prepare = multi_tap_echo_prepare_cb,
        .unprepare = multi_tap_echo_unprepare_cb,
        .process = multi_tap_echo_process_cb,
    };
    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault,
                                                 &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PreEffects,
                                                 &tap);
    if (status != noErr) {
        NSLog(@"MTAudioProcessingTapCreate failed with OSStatus %d", (int)status);
        return NULL;
    }
    return tap;
}
