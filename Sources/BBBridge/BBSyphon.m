//
//  BBSyphon.m
//

#import "BBSyphon.h"
#import <AppKit/AppKit.h>
#import "SyphonBuiltIn.h"

// Mirrors the public interface of SyphonMetalServer (Syphon 5+).
@protocol BBSyphonMetalServerAPI <NSObject>
- (id)initWithName:(NSString *)serverName device:(id<MTLDevice>)theDevice options:(NSDictionary *)options;
- (void)publishFrameTexture:(id<MTLTexture>)textureToPublish
            onCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                imageRegion:(NSRect)region
                    flipped:(BOOL)isFlipped;
- (BOOL)hasClients;
- (void)stop;
@end

static NSString *gSyphonPath = nil;

@implementation BBSyphonServer {
    id<BBSyphonMetalServerAPI> _server;
}

+ (BOOL)loadFrameworkWithCustomPath:(NSString *)path error:(NSError **)error {
    @synchronized(self) {
        // Syphon is compiled into the app; an external framework is only a fallback.
        SyphonBuiltInLink();
        if (NSClassFromString(@"SyphonMetalServer") != nil) {
            if (!gSyphonPath) gSyphonPath = @"built in";
            return YES;
        }
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        if (path.length > 0) [candidates addObject:path];
        NSString *privateFrameworks = NSBundle.mainBundle.privateFrameworksPath;
        if (privateFrameworks) [candidates addObject:[privateFrameworks stringByAppendingPathComponent:@"Syphon.framework"]];
        [candidates addObject:@"/Library/Frameworks/Syphon.framework"];
        [candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Frameworks/Syphon.framework"]];

        NSString *lastProblem = @"Syphon.framework was not found.";
        for (NSString *candidate in candidates) {
            if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) continue;
            NSBundle *bundle = [NSBundle bundleWithPath:candidate];
            NSError *loadError = nil;
            if (bundle && [bundle loadAndReturnError:&loadError]) {
                if (NSClassFromString(@"SyphonMetalServer") != nil) {
                    gSyphonPath = candidate;
                    return YES;
                }
                lastProblem = @"Syphon.framework loaded but has no SyphonMetalServer (Syphon 5 or newer is required).";
            } else if (loadError) {
                lastProblem = loadError.localizedDescription;
            }
        }
        if (error) {
            *error = [NSError errorWithDomain:@"BBSyphon"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : lastProblem}];
        }
        return NO;
    }
}

+ (BOOL)isAvailable {
    SyphonBuiltInLink();
    return NSClassFromString(@"SyphonMetalServer") != nil;
}

+ (NSArray<NSString *> *)visibleServerNames {
    Class directoryClass = NSClassFromString(@"SyphonServerDirectory");
    if (!directoryClass) return @[];
    id directory = [directoryClass performSelector:NSSelectorFromString(@"sharedDirectory")];
    NSArray *servers = [directory valueForKey:@"servers"];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *server in servers) {
        NSString *app = server[@"SyphonServerDescriptionAppNameKey"] ?: @"";
        NSString *name = server[@"SyphonServerDescriptionNameKey"] ?: @"";
        [names addObject:[NSString stringWithFormat:@"%@ — %@", app, name]];
    }
    return names;
}

+ (NSString *)loadedFrameworkPath {
    return gSyphonPath;
}

- (instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device {
    Class cls = NSClassFromString(@"SyphonMetalServer");
    if (!cls) return nil;
    self = [super init];
    if (self) {
        id<BBSyphonMetalServerAPI> server = [(id<BBSyphonMetalServerAPI>)[cls alloc] initWithName:name device:device options:nil];
        if (!server) return nil;
        _server = server;
    }
    return self;
}

- (void)publishTexture:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)commandBuffer flipped:(BOOL)flipped {
    NSRect region = NSMakeRect(0, 0, texture.width, texture.height);
    [_server publishFrameTexture:texture onCommandBuffer:commandBuffer imageRegion:region flipped:flipped];
}

- (BOOL)hasClients {
    return [_server hasClients];
}

- (void)stop {
    [_server stop];
    _server = nil;
}

- (void)dealloc {
    [_server stop];
}

@end
