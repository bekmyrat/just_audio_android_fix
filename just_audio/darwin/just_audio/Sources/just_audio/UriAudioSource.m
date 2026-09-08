#import "./include/just_audio/UriAudioSource.h"
#import "./include/just_audio/IndexedAudioSource.h"
#import "./include/just_audio/IndexedPlayerItem.h"
#import "./include/just_audio/LoadControl.h"
#import "./include/just_audio/MultiTapEchoTap.h"
#import "./include/just_audio/KaraokeMixTap.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>

@implementation UriAudioSource {
    NSString *_uri;
    IndexedPlayerItem *_playerItem;
    IndexedPlayerItem *_playerItem2;
    /* CMTime _duration; */
    LoadControl *_loadControl;
    NSMutableDictionary *_headers;
    NSDictionary *_options;
    atomic_bool *_echoEnabled;
    KaraokeMixParams *_karaokeParams;
}

- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options {
    return [self initWithId:sid uri:uri loadControl:loadControl headers:headers options:options echoEnabled:NULL];
}

- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options echoEnabled:(atomic_bool *)echoEnabled {
    return [self initWithId:sid uri:uri loadControl:loadControl headers:headers options:options echoEnabled:echoEnabled karaokeParams:NULL];
}

- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options echoEnabled:(atomic_bool *)echoEnabled karaokeParams:(KaraokeMixParams *)karaokeParams {
    self = [super initWithId:sid];
    NSAssert(self, @"super init cannot be nil");
    _uri = uri;
    _loadControl = loadControl;
    _headers = headers != (id)[NSNull null] ? [headers mutableCopy] : nil;
    _options = options;
    _echoEnabled = echoEnabled;
    _karaokeParams = karaokeParams;
    _playerItem = [self createPlayerItem:uri];
    _playerItem2 = nil;
    return self;
}

- (NSString *)uri {
    return _uri;
}

- (IndexedPlayerItem *)createPlayerItem:(NSString *)uri {
    IndexedPlayerItem *item;
    NSMutableDictionary *assetOptions = [[NSMutableDictionary alloc] init];
    
    if (_options != (id)[NSNull null]) {
        NSDictionary *darwinOptions = _options[@"darwinAssetOptions"];
        if (darwinOptions != (id)[NSNull null]) {
            assetOptions[AVURLAssetPreferPreciseDurationAndTimingKey] = darwinOptions[@"preferPreciseDurationAndTiming"];
        }
    }
    
    if ([uri hasPrefix:@"file://"]) {
        NSURL *fileURL = [NSURL fileURLWithPath:[[uri stringByRemovingPercentEncoding] substringFromIndex:7]];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:assetOptions];
        item = [[IndexedPlayerItem alloc] initWithAsset:asset];
    } else {
        if (_headers) {
            // Use user-agent key if it is the only header and the API is supported.
            if ([_headers count] == 1) {
                if (@available(macOS 13.0, iOS 16.0, *)) {
                    NSString *userAgent = _headers[@"User-Agent"];
                    if (userAgent) {
                        [_headers removeObjectForKey:@"User-Agent"];
                    } else {
                        userAgent = _headers[@"user-agent"];
                        if (userAgent) {
                            [_headers removeObjectForKey:@"user-agent"];
                        }
                    }
                    if (userAgent) {
                        assetOptions[AVURLAssetHTTPUserAgentKey] = userAgent;
                    }
                }
            }
            if ([_headers count] > 0) {
                assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = _headers;
            }
        }
        
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:uri] options:assetOptions];
        item = [[IndexedPlayerItem alloc] initWithAsset:asset];
    }
    if (@available(macOS 10.13, iOS 11.0, *)) {
        // This does the best at reducing distortion on voice with speeds below 1.0
        item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
    }
    if (@available(macOS 10.12, iOS 10.0, *)) {
        if (_loadControl.preferredForwardBufferDuration != (id)[NSNull null]) {
            item.preferredForwardBufferDuration = (double)([_loadControl.preferredForwardBufferDuration longLongValue]/1000) / 1000.0;
        }
    }
    if (@available(iOS 9.0, macOS 10.11, *)) {
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused;
    }
    if (@available(iOS 8.0, macOS 10.10, *)) {
        if (_loadControl.preferredPeakBitRate != (id)[NSNull null]) {
            item.preferredPeakBitRate = [_loadControl.preferredPeakBitRate doubleValue];
        }
    }

    // The echo processing tap is attached lazily (see -applyEchoTapIfEnabled),
    // only to the item that is actually becoming current and only when echo is
    // enabled. Attaching here for every source would force a per-asset
    // `loadValuesAsynchronouslyForKeys` (a network header fetch for remote URLs)
    // for the whole queue, which stalls playback on large playlists.

    return item;
}

- (void)applyEchoTapIfEnabled {
    [self attachEchoTapToItem:_playerItem];
    if (_playerItem2) {
        [self attachEchoTapToItem:_playerItem2];
    }
}

- (void)applyKaraokeTapIfEnabled {
    [self attachKaraokeTapToItem:_playerItem];
    if (_playerItem2) {
        [self attachKaraokeTapToItem:_playerItem2];
    }
}

/// Installs the karaoke downmix tap on [item].
///
/// A player item carries a single `audioMix`, so echo and karaoke cannot both
/// hold a tap on the same track. Karaoke wins: a four-channel source that
/// reached the output un-mixed would play the vocal stem out of the front pair
/// and the instrumental out of the rear, which is not a thing anyone wants to
/// hear. `attachEchoTapToItem:` stands down for items claimed here.
- (void)attachKaraokeTapToItem:(IndexedPlayerItem *)item {
    if (!_karaokeParams || !atomic_load_explicit(&_karaokeParams->enabled, memory_order_relaxed)) return;
    if (!item || item.karaokeTapAttached || item.echoTapAttached) return;
    AVAsset *asset = item.asset;
    if (!asset) return;
    item.karaokeTapAttached = YES;

    __weak IndexedPlayerItem *weakItem = item;
    KaraokeMixParams *paramsSnapshot = _karaokeParams;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
        if (status != AVKeyValueStatusLoaded) {
            NSLog(@"UriAudioSource: tracks not loaded (status=%ld, err=%@); skipping karaoke tap", (long)status, error);
            return;
        }
        NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count == 0) {
            NSLog(@"UriAudioSource: no audio tracks on asset; skipping karaoke tap");
            return;
        }
        AVAssetTrack *audioTrack = audioTracks.firstObject;
        MTAudioProcessingTapRef tap = karaoke_mix_create(paramsSnapshot);
        if (!tap) {
            return;
        }
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
        params.audioTapProcessor = tap;
        CFRelease(tap);
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[params];

        dispatch_async(dispatch_get_main_queue(), ^{
            IndexedPlayerItem *strongItem = weakItem;
            if (!strongItem) return;
            strongItem.audioMix = mix;
        });
    }];
}

- (void)attachEchoTapToItem:(IndexedPlayerItem *)item {
    if (!_echoEnabled || !atomic_load_explicit(_echoEnabled, memory_order_relaxed)) return;
    if (!item || item.echoTapAttached || item.karaokeTapAttached) return;
    AVAsset *asset = item.asset;
    if (!asset) return;
    // Guard before kicking off the async load so repeated calls (e.g. on each
    // currentItem transition) don't trigger duplicate asset loads/taps.
    item.echoTapAttached = YES;

    // Loading tracks asynchronously avoids blocking. Once available we install
    // the MTAudioProcessingTap for the first audio track on the player item.
    __weak IndexedPlayerItem *weakItem = item;
    atomic_bool *enabledFlagSnapshot = _echoEnabled;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
        if (status != AVKeyValueStatusLoaded) {
            NSLog(@"UriAudioSource: tracks not loaded (status=%ld, err=%@); skipping echo tap", (long)status, error);
            return;
        }
        NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count == 0) {
            NSLog(@"UriAudioSource: no audio tracks on asset; skipping echo tap");
            return;
        }
        AVAssetTrack *audioTrack = audioTracks.firstObject;
        MTAudioProcessingTapRef tap = multi_tap_echo_create(enabledFlagSnapshot);
        if (!tap) {
            return;
        }
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
        params.audioTapProcessor = tap;
        CFRelease(tap);
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[params];

        dispatch_async(dispatch_get_main_queue(), ^{
            IndexedPlayerItem *strongItem = weakItem;
            if (!strongItem) return;
            strongItem.audioMix = mix;
        });
    }];
}

// Not used. XXX: Remove?
- (void)applyPreferredForwardBufferDuration {
    if (@available(macOS 10.12, iOS 10.0, *)) {
        if (_loadControl.preferredForwardBufferDuration != (id)[NSNull null]) {
            double value = (double)([_loadControl.preferredForwardBufferDuration longLongValue]/1000) / 1000.0;
            _playerItem.preferredForwardBufferDuration = value;
            if (_playerItem2) {
                _playerItem2.preferredForwardBufferDuration = value;
            }
        }
    }
}

- (void)applyCanUseNetworkResourcesForLiveStreamingWhilePaused {
    if (@available(iOS 9.0, macOS 10.11, *)) {
        _playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused;
        if (_playerItem2) {
            _playerItem2.canUseNetworkResourcesForLiveStreamingWhilePaused = _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused;
        }
    }
}

- (void)applyPreferredPeakBitRate {
    if (@available(iOS 8.0, macOS 10.10, *)) {
        if (_loadControl.preferredPeakBitRate != (id)[NSNull null]) {
            double value = [_loadControl.preferredPeakBitRate doubleValue];
            _playerItem.preferredPeakBitRate = value;
            if (_playerItem2) {
                _playerItem2.preferredPeakBitRate = value;
            }
        }
    }
}

- (IndexedPlayerItem *)playerItem {
    return _playerItem;
}

- (IndexedPlayerItem *)playerItem2 {
    return _playerItem2;
}

- (NSArray<NSNumber *> *)getShuffleIndices {
    return @[@(0)];
}

- (void)play:(AVQueuePlayer *)player {
}

- (void)pause:(AVQueuePlayer *)player {
}

- (void)stop:(AVQueuePlayer *)player {
}

- (void)seek:(CMTime)position completionHandler:(void (^)(BOOL))completionHandler {
    if (!completionHandler || (_playerItem.status == AVPlayerItemStatusReadyToPlay)) {
        NSValue *seekableRange = _playerItem.seekableTimeRanges.lastObject;
        if (seekableRange) {
            CMTimeRange range = [seekableRange CMTimeRangeValue];
            position = CMTimeAdd(position, range.start);
        }
        [_playerItem seekToTime:position toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completionHandler];
    } else {
        [super seek:position completionHandler:completionHandler];
    }
}

- (void)flip {
    IndexedPlayerItem *temp = _playerItem;
    _playerItem = _playerItem2;
    _playerItem2 = temp;
}

- (void)preparePlayerItem2 {
    if (!_playerItem2) {
        _playerItem2 = [self createPlayerItem:_uri];
        _playerItem2.audioSource = _playerItem.audioSource;
    }
}

- (CMTime)duration {
    NSValue *seekableRange = _playerItem.seekableTimeRanges.lastObject;
    if (seekableRange) {
        CMTimeRange seekableDuration = [seekableRange CMTimeRangeValue];
        return seekableDuration.duration;
    }
    else {
        return _playerItem.duration;
    }
    return kCMTimeInvalid;
}

- (void)setDuration:(CMTime)duration {
}

- (CMTime)position {
    NSValue *seekableRange = _playerItem.seekableTimeRanges.lastObject;
    if (seekableRange) {
        CMTimeRange range = [seekableRange CMTimeRangeValue];
        return CMTimeSubtract(_playerItem.currentTime, range.start);
    } else {
        return _playerItem.currentTime;
    }
    
}

- (CMTime)bufferedPosition {
    NSValue *last = _playerItem.loadedTimeRanges.lastObject;
    if (last) {
        CMTimeRange timeRange = [last CMTimeRangeValue];
        return CMTimeAdd(timeRange.start, timeRange.duration);
    } else {
        return _playerItem.currentTime;
    }
    return kCMTimeInvalid;
}

@end
