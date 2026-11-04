//
//  BBDeckLink.mm
//

#import "BBDeckLink.h"

@implementation BBDeckLinkDisplayMode
- (instancetype)initWithModeID:(uint32_t)modeID
                          name:(NSString *)name
                         width:(int32_t)width
                        height:(int32_t)height
                 frameDuration:(int64_t)frameDuration
                     timeScale:(int64_t)timeScale
                    interlaced:(BOOL)interlaced {
    if ((self = [super init])) {
        _modeID = modeID;
        _name = [name copy];
        _width = width;
        _height = height;
        _frameDuration = frameDuration;
        _timeScale = timeScale;
        _interlaced = interlaced;
    }
    return self;
}
@end

@implementation BBDeckLinkDevice
- (instancetype)initWithIndex:(NSInteger)index
                  displayName:(NSString *)displayName
                    modelName:(NSString *)modelName
                 persistentID:(int64_t)persistentID
             supportsPlayback:(BOOL)supportsPlayback
                 displayModes:(NSArray<BBDeckLinkDisplayMode *> *)displayModes {
    if ((self = [super init])) {
        _index = index;
        _displayName = [displayName copy];
        _modelName = [modelName copy];
        _persistentID = persistentID;
        _supportsPlayback = supportsPlayback;
        _displayModes = [displayModes copy];
    }
    return self;
}
@end

static NSError *BBDLError(NSString *message) {
    return [NSError errorWithDomain:@"BBDeckLink" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

#if defined(BB_HAVE_DECKLINK_SDK) && BB_HAVE_DECKLINK_SDK

#include "DeckLinkAPI.h"
#include "DeckLinkAPIDispatch.cpp"
#include <atomic>
#include <vector>

// Desktop Video SDK 14.3 replaced IDeckLinkVideoFrame::GetBytes with the
// IDeckLinkVideoBuffer interface.
#if defined(BLACKMAGIC_DECKLINK_API_VERSION) && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
#define BB_DECKLINK_VIDEO_BUFFER_API 1
#else
#define BB_DECKLINK_VIDEO_BUFFER_API 0
#endif

static NSString *BBDLString(CFStringRef value) {
    return value ? (__bridge_transfer NSString *)value : @"";
}

static IDeckLink *BBDLCopyDevice(NSInteger index) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) return NULL;
    IDeckLink *deckLink = NULL;
    IDeckLink *found = NULL;
    NSInteger i = 0;
    while (iterator->Next(&deckLink) == S_OK) {
        if (i == index) {
            found = deckLink;
            break;
        }
        deckLink->Release();
        i++;
    }
    iterator->Release();
    return found;
}

@interface BBDeckLinkOutput ()
- (void)frameCompleted:(IDeckLinkVideoFrame *)frame result:(BMDOutputFrameCompletionResult)result;
@end

class BBDeckLinkCallback : public IDeckLinkVideoOutputCallback {
public:
    explicit BBDeckLinkCallback(BBDeckLinkOutput *owner) : mOwner(owner), mRefCount(1) {}

    HRESULT STDMETHODCALLTYPE ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame,
                                                      BMDOutputFrameCompletionResult result) override {
        BBDeckLinkOutput *owner = mOwner;
        [owner frameCompleted:completedFrame result:result];
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE ScheduledPlaybackHasStopped() override { return S_OK; }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, LPVOID *ppv) override {
        CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0 ||
            memcmp(&iid, &IID_IDeckLinkVideoOutputCallback, sizeof(REFIID)) == 0) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++mRefCount; }

    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = --mRefCount;
        if (count == 0) delete this;
        return count;
    }

    void detach() { mOwner = nil; }

private:
    __weak BBDeckLinkOutput *mOwner;
    std::atomic<ULONG> mRefCount;
};

@implementation BBDeckLinkOutput {
    IDeckLink *_deckLink;
    IDeckLinkOutput *_output;
    BBDeckLinkCallback *_callback;
    std::vector<IDeckLinkMutableVideoFrame *> _frames;
    BBDeckLinkFrameFiller _filler;
    BBDeckLinkAudioFiller _audioFiller;
    uint32_t _audioChannels;
    std::vector<int32_t> _audioBuffer;
    BMDTimeValue _frameDuration;
    BMDTimeScale _timeScale;
    int32_t _width;
    int32_t _height;
    int32_t _rowBytes;
    std::atomic<int64_t> _scheduledIndex;
    std::atomic<bool> _running;
    std::atomic<uint64_t> _completed;
    std::atomic<uint64_t> _late;
    std::atomic<uint64_t> _dropped;
}

+ (BOOL)isSDKCompiledIn {
    return YES;
}

+ (NSString *)driverVersion {
    IDeckLinkAPIInformation *info = CreateDeckLinkAPIInformationInstance();
    if (!info) return nil;
    CFStringRef version = NULL;
    NSString *result = nil;
    if (info->GetString(BMDDeckLinkAPIVersion, &version) == S_OK) {
        result = BBDLString(version);
    }
    info->Release();
    return result;
}

+ (NSArray<BBDeckLinkDevice *> *)devicesWithError:(NSError **)error {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        if (error) {
            *error = BBDLError(@"DeckLink driver not found. Install Blackmagic Desktop Video (the driver version must be the same or newer than the SDK the app was built with).");
        }
        return @[];
    }
    NSMutableArray<BBDeckLinkDevice *> *devices = [NSMutableArray array];
    IDeckLink *deckLink = NULL;
    NSInteger index = 0;
    while (iterator->Next(&deckLink) == S_OK) {
        CFStringRef displayName = NULL;
        CFStringRef modelName = NULL;
        deckLink->GetDisplayName(&displayName);
        deckLink->GetModelName(&modelName);

        int64_t persistentID = 0;
        int64_t ioSupport = 0;
        IDeckLinkProfileAttributes *attributes = NULL;
        if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attributes) == S_OK) {
            attributes->GetInt(BMDDeckLinkPersistentID, &persistentID);
            attributes->GetInt(BMDDeckLinkVideoIOSupport, &ioSupport);
            attributes->Release();
        }

        NSMutableArray<BBDeckLinkDisplayMode *> *modes = [NSMutableArray array];
        IDeckLinkOutput *output = NULL;
        if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) == S_OK) {
            IDeckLinkDisplayModeIterator *modeIterator = NULL;
            if (output->GetDisplayModeIterator(&modeIterator) == S_OK) {
                IDeckLinkDisplayMode *mode = NULL;
                while (modeIterator->Next(&mode) == S_OK) {
                    CFStringRef modeName = NULL;
                    mode->GetName(&modeName);
                    BMDTimeValue duration = 0;
                    BMDTimeScale scale = 0;
                    mode->GetFrameRate(&duration, &scale);
                    BMDFieldDominance dominance = mode->GetFieldDominance();
                    BOOL interlaced = dominance == bmdLowerFieldFirst || dominance == bmdUpperFieldFirst;
                    [modes addObject:[[BBDeckLinkDisplayMode alloc] initWithModeID:(uint32_t)mode->GetDisplayMode()
                                                                             name:BBDLString(modeName)
                                                                            width:(int32_t)mode->GetWidth()
                                                                           height:(int32_t)mode->GetHeight()
                                                                    frameDuration:duration
                                                                        timeScale:scale
                                                                       interlaced:interlaced]];
                    mode->Release();
                }
                modeIterator->Release();
            }
            output->Release();
        }

        BOOL playback = (ioSupport & bmdDeviceSupportsPlayback) != 0 || (ioSupport == 0 && modes.count > 0);
        [devices addObject:[[BBDeckLinkDevice alloc] initWithIndex:index
                                                       displayName:BBDLString(displayName)
                                                         modelName:BBDLString(modelName)
                                                      persistentID:persistentID
                                                  supportsPlayback:playback
                                                      displayModes:modes]];
        deckLink->Release();
        index++;
    }
    iterator->Release();
    return devices;
}

- (instancetype)initWithDeviceIndex:(NSInteger)index error:(NSError **)error {
    if ((self = [super init])) {
        _deckLink = BBDLCopyDevice(index);
        if (!_deckLink) {
            if (error) *error = BBDLError(@"The DeckLink device is no longer available.");
            return nil;
        }
        if (_deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&_output) != S_OK || !_output) {
            _deckLink->Release();
            _deckLink = NULL;
            if (error) *error = BBDLError(@"This DeckLink device has no video output.");
            return nil;
        }
        _scheduledIndex = 0;
        _running = false;
        _completed = 0;
        _late = 0;
        _dropped = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_output) _output->Release();
    if (_deckLink) _deckLink->Release();
}

- (BOOL)startWithModeID:(uint32_t)modeID
                    yuv:(BOOL)yuv
          audioChannels:(uint32_t)audioChannels
                 filler:(BBDeckLinkFrameFiller)filler
            audioFiller:(BBDeckLinkAudioFiller)audioFiller
                  error:(NSError **)error {
    if (_running) return YES;

    // Look up mode geometry and timing.
    IDeckLinkDisplayModeIterator *modeIterator = NULL;
    BOOL foundMode = NO;
    if (_output->GetDisplayModeIterator(&modeIterator) == S_OK) {
        IDeckLinkDisplayMode *mode = NULL;
        while (modeIterator->Next(&mode) == S_OK) {
            if ((uint32_t)mode->GetDisplayMode() == modeID) {
                _width = (int32_t)mode->GetWidth();
                _height = (int32_t)mode->GetHeight();
                mode->GetFrameRate(&_frameDuration, &_timeScale);
                foundMode = YES;
            }
            mode->Release();
            if (foundMode) break;
        }
        modeIterator->Release();
    }
    if (!foundMode) {
        if (error) *error = BBDLError(@"The selected video mode is not supported by this DeckLink device.");
        return NO;
    }

    BMDPixelFormat pixelFormat = yuv ? bmdFormat8BitYUV : bmdFormat8BitBGRA;
    _rowBytes = yuv ? _width * 2 : _width * 4;

    if (_output->EnableVideoOutput((BMDDisplayMode)modeID, bmdVideoOutputFlagDefault) != S_OK) {
        if (error) *error = BBDLError(@"Could not enable DeckLink video output. The device may be in use by another application or output.");
        return NO;
    }

    _audioChannels = 0;
    if (audioChannels > 0 && audioFiller) {
        if (_output->EnableAudioOutput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, audioChannels,
                                       bmdAudioOutputStreamTimestamped) == S_OK) {
            _audioChannels = audioChannels;
            _audioFiller = [audioFiller copy];
        }
    }

    const int frameCount = 4;
    for (int i = 0; i < frameCount; i++) {
        IDeckLinkMutableVideoFrame *frame = NULL;
        if (_output->CreateVideoFrame(_width, _height, _rowBytes, pixelFormat, bmdFrameFlagDefault, &frame) != S_OK || !frame) {
            [self releaseFrames];
            if (_audioChannels > 0) _output->DisableAudioOutput();
            _output->DisableVideoOutput();
            if (error) *error = BBDLError(@"Could not allocate DeckLink video frames.");
            return NO;
        }
        _frames.push_back(frame);
    }

    _filler = [filler copy];
    _callback = new BBDeckLinkCallback(self);
    _output->SetScheduledFrameCompletionCallback(_callback);

    _scheduledIndex = 0;
    _completed = 0;
    _late = 0;
    _dropped = 0;
    _running = true;

    // Pre-roll every frame, then start the hardware clock.
    for (IDeckLinkMutableVideoFrame *frame : _frames) {
        [self fillAndSchedule:frame];
    }
    if (_output->StartScheduledPlayback(0, _timeScale, 1.0) != S_OK) {
        [self stop];
        if (error) *error = BBDLError(@"DeckLink scheduled playback failed to start.");
        return NO;
    }
    return YES;
}

- (void)fillAndSchedule:(IDeckLinkVideoFrame *)frame {
    void *bytes = NULL;
#if BB_DECKLINK_VIDEO_BUFFER_API
    IDeckLinkVideoBuffer *buffer = NULL;
    if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) == S_OK && buffer) {
        if (buffer->StartAccess(bmdBufferAccessWrite) == S_OK) {
            if (buffer->GetBytes(&bytes) == S_OK && bytes && _filler) {
                _filler(bytes, _rowBytes, _width, _height);
            }
            buffer->EndAccess(bmdBufferAccessWrite);
        }
        buffer->Release();
    }
#else
    if (frame->GetBytes(&bytes) == S_OK && bytes && _filler) {
        _filler(bytes, _rowBytes, _width, _height);
    }
#endif
    int64_t index = _scheduledIndex++;
    _output->ScheduleVideoFrame(frame, index * _frameDuration, _frameDuration, _timeScale);

    if (_audioChannels > 0 && _audioFiller && _timeScale > 0) {
        // Audio samples covering exactly this video frame on the 48 kHz timeline.
        int64_t start = index * 48000 * _frameDuration / _timeScale;
        int64_t end = (index + 1) * 48000 * _frameDuration / _timeScale;
        uint32_t count = (uint32_t)(end - start);
        if (count > 0) {
            if (_audioBuffer.size() < (size_t)count * _audioChannels) _audioBuffer.resize((size_t)count * _audioChannels);
            _audioFiller(_audioBuffer.data(), count, _audioChannels);
            uint32_t written = 0;
            _output->ScheduleAudioSamples(_audioBuffer.data(), count, start, 48000, &written);
        }
    }
}

- (void)frameCompleted:(IDeckLinkVideoFrame *)frame result:(BMDOutputFrameCompletionResult)result {
    if (!_running) return;
    switch (result) {
        case bmdOutputFrameDisplayedLate:
            _late++;
            break;
        case bmdOutputFrameDropped:
            _dropped++;
            break;
        case bmdOutputFrameFlushed:
            return;
        default:
            _completed++;
            break;
    }
    if (result == bmdOutputFrameDisplayedLate || result == bmdOutputFrameDropped) {
        // Re-align the schedule with the hardware clock so we stop falling behind.
        BMDTimeValue streamTime = 0;
        double speed = 0;
        if (_output->GetScheduledStreamTime(_timeScale, &streamTime, &speed) == S_OK && _frameDuration > 0) {
            int64_t current = streamTime / _frameDuration;
            if (_scheduledIndex < current + 2) _scheduledIndex = current + 2;
        }
    }
    [self fillAndSchedule:frame];
}

- (void)releaseFrames {
    for (IDeckLinkMutableVideoFrame *frame : _frames) {
        frame->Release();
    }
    _frames.clear();
}

- (void)stop {
    if (!_running) return;
    _running = false;
    _output->StopScheduledPlayback(0, NULL, 0);
    _output->SetScheduledFrameCompletionCallback(NULL);
    if (_audioChannels > 0) {
        _output->DisableAudioOutput();
        _audioChannels = 0;
    }
    _output->DisableVideoOutput();
    if (_callback) {
        _callback->detach();
        _callback->Release();
        _callback = NULL;
    }
    [self releaseFrames];
    _filler = nil;
    _audioFiller = nil;
}

- (uint64_t)framesCompleted { return _completed; }
- (uint64_t)framesLate { return _late; }
- (uint64_t)framesDropped { return _dropped; }

- (uint32_t)bufferedFrames {
    uint32_t count = 0;
    if (_output && _running) _output->GetBufferedVideoFrameCount(&count);
    return count;
}

@end

#else // DeckLink SDK not available at build time

@implementation BBDeckLinkOutput

+ (BOOL)isSDKCompiledIn {
    return NO;
}

+ (NSString *)driverVersion {
    NSString *plist = @"/Library/Frameworks/DeckLinkAPI.framework/Resources/Info.plist";
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
    return info[@"CFBundleShortVersionString"];
}

+ (NSArray<BBDeckLinkDevice *> *)devicesWithError:(NSError **)error {
    if (error) {
        *error = BBDLError(@"This build does not include DeckLink support. Add the Blackmagic Desktop Video SDK headers to ThirdParty/DeckLinkSDK/include and rebuild.");
    }
    return @[];
}

- (instancetype)initWithDeviceIndex:(NSInteger)index error:(NSError **)error {
    if (error) *error = BBDLError(@"This build does not include DeckLink support.");
    return nil;
}

- (BOOL)startWithModeID:(uint32_t)modeID
                    yuv:(BOOL)yuv
          audioChannels:(uint32_t)audioChannels
                 filler:(BBDeckLinkFrameFiller)filler
            audioFiller:(BBDeckLinkAudioFiller)audioFiller
                  error:(NSError **)error {
    if (error) *error = BBDLError(@"This build does not include DeckLink support.");
    return NO;
}

- (void)stop {}
- (uint64_t)framesCompleted { return 0; }
- (uint64_t)framesLate { return 0; }
- (uint64_t)framesDropped { return 0; }
- (uint32_t)bufferedFrames { return 0; }

@end

#endif
