//
//  BBDeckLink.h
//  Objective-C wrapper around the Blackmagic DeckLink API for scheduled
//  (hardware-clocked) playback. The real implementation is compiled only when
//  the Desktop Video SDK headers are available (see ThirdParty/README.md);
//  otherwise every call reports that DeckLink support was not built in.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BBDeckLinkDisplayMode : NSObject
@property (nonatomic, readonly) uint32_t modeID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int32_t width;
@property (nonatomic, readonly) int32_t height;
@property (nonatomic, readonly) int64_t frameDuration;
@property (nonatomic, readonly) int64_t timeScale;
@property (nonatomic, readonly) BOOL interlaced;
- (instancetype)initWithModeID:(uint32_t)modeID
                          name:(NSString *)name
                         width:(int32_t)width
                        height:(int32_t)height
                 frameDuration:(int64_t)frameDuration
                     timeScale:(int64_t)timeScale
                    interlaced:(BOOL)interlaced;
@end

@interface BBDeckLinkDevice : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *modelName;
@property (nonatomic, readonly) int64_t persistentID;
@property (nonatomic, readonly) BOOL supportsPlayback;
@property (nonatomic, readonly, copy) NSArray<BBDeckLinkDisplayMode *> *displayModes;
- (instancetype)initWithIndex:(NSInteger)index
                  displayName:(NSString *)displayName
                    modelName:(NSString *)modelName
                 persistentID:(int64_t)persistentID
             supportsPlayback:(BOOL)supportsPlayback
                 displayModes:(NSArray<BBDeckLinkDisplayMode *> *)displayModes;
@end

/// Fills one output frame. Called on the DeckLink callback thread.
typedef BOOL (^BBDeckLinkFrameFiller)(void *bytes, NSInteger rowBytes, int32_t width, int32_t height);
/// Fills `frameCount` interleaved 32-bit integer audio frames (48 kHz) that
/// belong to the video frame just scheduled.
typedef void (^BBDeckLinkAudioFiller)(int32_t *samples, uint32_t frameCount, uint32_t channels);

@interface BBDeckLinkOutput : NSObject

/// YES when the DeckLink SDK was available at build time.
+ (BOOL)isSDKCompiledIn;
/// Installed Desktop Video API version, or nil when the driver is missing.
+ (nullable NSString *)driverVersion;
+ (nullable NSArray<BBDeckLinkDevice *> *)devicesWithError:(NSError *_Nullable *_Nullable)error;

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index error:(NSError *_Nullable *_Nullable)error;
/// Starts scheduled playback in 8-bit YUV (2vuy) or 8-bit BGRA, with optional
/// embedded audio (audioChannels 0 = no audio; 2, 8 or 16 channels otherwise).
- (BOOL)startWithModeID:(uint32_t)modeID
                    yuv:(BOOL)yuv
          audioChannels:(uint32_t)audioChannels
                 filler:(BBDeckLinkFrameFiller)filler
            audioFiller:(nullable BBDeckLinkAudioFiller)audioFiller
                  error:(NSError *_Nullable *_Nullable)error;
- (void)stop;

@property (atomic, readonly) uint64_t framesCompleted;
@property (atomic, readonly) uint64_t framesLate;
@property (atomic, readonly) uint64_t framesDropped;
@property (atomic, readonly) uint32_t bufferedFrames;

@end

NS_ASSUME_NONNULL_END
