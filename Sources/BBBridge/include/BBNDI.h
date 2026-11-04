//
//  BBNDI.h
//  Minimal NDI® sender bridge. The NDI runtime (libndi.dylib) is loaded at
//  runtime with dlopen, so the app builds and runs without the NDI SDK and
//  lights up NDI output when a runtime is found (NDI Tools, NDI SDK for Apple,
//  or a libndi.dylib placed in the app bundle's Frameworks folder).
//
//  NDI® is a registered trademark of Vizrt NDI AB.
//

#ifndef BBNDI_h
#define BBNDI_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the NDI runtime. `customPath` may be NULL/empty to auto-detect.
/// Returns true when the library is loaded and initialized.
bool BBNDILoad(const char *_Nullable customPath, char *_Nullable errorBuffer, int errorBufferLength);
bool BBNDIIsLoaded(void);
const char *_Nullable BBNDILibraryPath(void);
const char *_Nullable BBNDIVersionString(void);

/// Creates a sender. Returns NULL on failure.
void *_Nullable BBNDISenderCreate(const char *_Nonnull name, const char *_Nullable groups, bool clockVideo);
void BBNDISenderDestroy(void *_Nonnull sender);

/// Sends one progressive video frame. When `async` is true the data must stay
/// valid until the next send/flush call on the same sender.
void BBNDISenderSendVideo(void *_Nonnull sender, int width, int height, uint32_t fourCC,
                          int frameRateN, int frameRateD, const void *_Nonnull data,
                          int lineStride, bool async);
/// Sends planar 32-bit float audio (each channel `channelStrideBytes` apart).
void BBNDISenderSendAudio(void *_Nonnull sender, int sampleRate, int channels, int samples,
                          const float *_Nonnull planar, int channelStrideBytes);
/// Waits for any pending async frame to be released.
void BBNDISenderFlushAsync(void *_Nonnull sender);
int BBNDISenderConnectionCount(void *_Nonnull sender, uint32_t timeoutMs);
bool BBNDISenderGetTally(void *_Nonnull sender, bool *_Nonnull onProgram, bool *_Nonnull onPreview);

/// Discovers NDI sources on the network. Writes newline separated names into
/// `buffer` and returns the number of sources found (or -1 on error).
int BBNDIFindSources(char *_Nonnull buffer, int bufferLength, uint32_t waitMs);

#ifdef __cplusplus
}
#endif

#endif /* BBNDI_h */
