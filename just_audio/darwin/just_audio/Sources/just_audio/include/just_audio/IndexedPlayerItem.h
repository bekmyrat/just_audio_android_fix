#import <AVFoundation/AVFoundation.h>

@class IndexedAudioSource;

@interface IndexedPlayerItem : AVPlayerItem

@property (readwrite, nonatomic, weak) IndexedAudioSource *audioSource;
@property (readwrite, nonatomic) BOOL echoTapAttached;
@property (readwrite, nonatomic) BOOL karaokeTapAttached;
/// The item's audio turned out to be four-channel and the karaoke tap is on it.
@property (readwrite, nonatomic) BOOL karaokeMixing;
/// The item's audio turned out not to be four-channel; no need to look again.
@property (readwrite, nonatomic) BOOL karaokeNotApplicable;

@end
