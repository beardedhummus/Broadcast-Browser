//
//  BBSyphon.h
//  Thin wrapper around SyphonMetalServer that loads Syphon.framework at
//  runtime (app bundle Frameworks, /Library/Frameworks, ~/Library/Frameworks
//  or a custom path) so the app builds without the framework present.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface BBSyphonServer : NSObject

/// Attempts to load Syphon.framework. Safe to call repeatedly.
+ (BOOL)loadFrameworkWithCustomPath:(nullable NSString *)path error:(NSError *_Nullable *_Nullable)error;
+ (BOOL)isAvailable;
+ (nullable NSString *)loadedFrameworkPath;
/// "App — Server" names of every Syphon server currently announced on this Mac.
+ (NSArray<NSString *> *)visibleServerNames;

- (nullable instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device;
- (void)publishTexture:(id<MTLTexture>)texture
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
               flipped:(BOOL)flipped;
@property (nonatomic, readonly) BOOL hasClients;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
