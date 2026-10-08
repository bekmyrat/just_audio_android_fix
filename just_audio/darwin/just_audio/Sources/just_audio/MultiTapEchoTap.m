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

struct MultiTapEcho {
    bool wasEnabled;

    // One circular delay line per channel.
    float *delayLines[kMaxChannels];
    UInt32 lineCount;
    int delayLineLength;
    int tapSampleOffsets[3];
    int writeIndex;
};

static inline float clampf(float v) {
    if (v > 1.0f) return 1.0f;
    if (v < -1.0f) return -1.0f;
    return v;
}

static void multi_tap_echo_zero_delay_lines(MultiTapEcho *e) {
    for (UInt32 c = 0; c < e->lineCount; c++) {
        if (e->delayLines[c]) {
            memset(e->delayLines[c], 0, sizeof(float) * (size_t)e->delayLineLength);
        }
    }
    e->writeIndex = 0;
}

static void multi_tap_echo_free_delay_lines(MultiTapEcho *e) {
    for (int c = 0; c < kMaxChannels; c++) {
        if (e->delayLines[c]) {
            free(e->delayLines[c]);
            e->delayLines[c] = NULL;
        }
    }
    e->lineCount = 0;
}

MultiTapEcho *multi_tap_echo_new(void) {
    return (MultiTapEcho *)calloc(1, sizeof(MultiTapEcho));
}

void multi_tap_echo_free(MultiTapEcho *e) {
    if (!e) return;
    multi_tap_echo_free_delay_lines(e);
    free(e);
}

void multi_tap_echo_prepare(MultiTapEcho *e, UInt32 channels, Float64 sampleRate, CMItemCount maxFrames) {
    // Reset any prior allocations (e.g. if prepare is called again after unprepare).
    multi_tap_echo_free_delay_lines(e);

    int maxDelaySamples = 0;
    for (int i = 0; i < kNumTaps; i++) {
        e->tapSampleOffsets[i] = (int)((kDelayMs[i] * sampleRate) / 1000.0);
        if (e->tapSampleOffsets[i] > maxDelaySamples) {
            maxDelaySamples = e->tapSampleOffsets[i];
        }
    }
    e->delayLineLength = maxDelaySamples + (int)maxFrames + 1024;
    e->writeIndex = 0;
    e->wasEnabled = false;

    e->lineCount = channels > kMaxChannels ? kMaxChannels : channels;
    for (UInt32 c = 0; c < e->lineCount; c++) {
        e->delayLines[c] = (float *)calloc((size_t)e->delayLineLength, sizeof(float));
    }
}

void multi_tap_echo_unprepare(MultiTapEcho *e) {
    multi_tap_echo_free_delay_lines(e);
}

void multi_tap_echo_process(MultiTapEcho *e,
                            bool enabled,
                            AudioBufferList *bufferList,
                            int numFrames,
                            bool nonInterleaved,
                            UInt32 stride,
                            UInt32 channels) {
    if (enabled != e->wasEnabled) {
        multi_tap_echo_zero_delay_lines(e);
        e->wasEnabled = enabled;
    }
    if (!enabled) {
        // Passthrough; the audio is already sitting in bufferList.
        return;
    }

    if (numFrames <= 0) return;
    int dlen = e->delayLineLength;
    if (dlen <= 0) return;

    if (nonInterleaved) {
        UInt32 bufCount = bufferList->mNumberBuffers;
        if (bufCount > channels) bufCount = channels;
        if (bufCount > kMaxChannels) bufCount = kMaxChannels;
        int lastW = e->writeIndex;
        for (UInt32 b = 0; b < bufCount; b++) {
            float *samples = (float *)bufferList->mBuffers[b].mData;
            float *delay = e->delayLines[b];
            if (!samples || !delay) continue;
            int w = e->writeIndex;
            for (int n = 0; n < numFrames; n++) {
                float inSample = samples[n];
                delay[w] = inSample;
                float mixed = inSample * kInputGain;
                for (int i = 0; i < kNumTaps; i++) {
                    int readIdx = w - e->tapSampleOffsets[i];
                    if (readIdx < 0) readIdx += dlen;
                    mixed += delay[readIdx] * kDecays[i];
                }
                samples[n] = clampf(mixed * kOutputGain);
                w++;
                if (w >= dlen) w = 0;
            }
            lastW = w;
        }
        e->writeIndex = lastW;
    } else {
        if (bufferList->mNumberBuffers < 1) return;
        float *samples = (float *)bufferList->mBuffers[0].mData;
        if (!samples) return;
        UInt32 ch = channels;
        if (ch == 0) return;
        if (ch > kMaxChannels) ch = kMaxChannels;
        if (stride < ch) return;
        int w = e->writeIndex;
        for (int n = 0; n < numFrames; n++) {
            for (UInt32 c = 0; c < ch; c++) {
                float *delay = e->delayLines[c];
                if (!delay) continue;
                int idx = n * (int)stride + (int)c;
                float inSample = samples[idx];
                delay[w] = inSample;
                float mixed = inSample * kInputGain;
                for (int i = 0; i < kNumTaps; i++) {
                    int readIdx = w - e->tapSampleOffsets[i];
                    if (readIdx < 0) readIdx += dlen;
                    mixed += delay[readIdx] * kDecays[i];
                }
                samples[idx] = clampf(mixed * kOutputGain);
            }
            w++;
            if (w >= dlen) w = 0;
        }
        e->writeIndex = w;
    }
}

// The standalone echo tap: the engine above over every channel of the item.

typedef struct {
    // Shared flag owned by AudioPlayer, read on every process pass.
    atomic_bool *enabledFlag;
    MultiTapEcho *echo;

    UInt32 channelCount;
    bool isNonInterleaved;
    bool prepared;
} MultiTapEchoState;

static void multi_tap_echo_init_cb(MTAudioProcessingTapRef tap,
                                   void *clientInfo,
                                   void **tapStorageOut) {
    MultiTapEchoState *s = (MultiTapEchoState *)calloc(1, sizeof(MultiTapEchoState));
    if (s) {
        s->echo = multi_tap_echo_new();
        if (!s->echo) {
            free(s);
            s = NULL;
        }
    }
    if (!s) {
        *tapStorageOut = NULL;
        return;
    }
    s->enabledFlag = (atomic_bool *)clientInfo;
    s->prepared = false;
    *tapStorageOut = s;
}

static void multi_tap_echo_finalize_cb(MTAudioProcessingTapRef tap) {
    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    multi_tap_echo_free(s->echo);
    free(s);
}

static void multi_tap_echo_prepare_cb(MTAudioProcessingTapRef tap,
                                      CMItemCount maxFrames,
                                      const AudioStreamBasicDescription *processingFormat) {
    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;

    s->channelCount = processingFormat->mChannelsPerFrame;
    s->isNonInterleaved = (processingFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    multi_tap_echo_prepare(s->echo, s->channelCount, processingFormat->mSampleRate, maxFrames);

    // Only mark as prepared if the format is float PCM; otherwise the process
    // callback will treat this as passthrough to avoid corrupting non-float audio.
    bool isFloat = (processingFormat->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    s->prepared = isFloat;

    NSLog(@"MultiTapEchoTap prepared: ch=%u rate=%.0f nonInterleaved=%d float=%d frames=%d",
          (unsigned)s->channelCount, processingFormat->mSampleRate,
          s->isNonInterleaved ? 1 : 0, isFloat ? 1 : 0, s->echo->delayLineLength);
}

static void multi_tap_echo_unprepare_cb(MTAudioProcessingTapRef tap) {
    MultiTapEchoState *s = (MultiTapEchoState *)MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    multi_tap_echo_unprepare(s->echo);
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
    UInt32 stride = s->channelCount > kMaxChannels ? kMaxChannels : s->channelCount;
    multi_tap_echo_process(s->echo, enabled, bufferListInOut, (int)(*numberFramesOut),
                           s->isNonInterleaved, stride, s->channelCount);
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
