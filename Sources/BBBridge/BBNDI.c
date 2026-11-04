//
//  BBNDI.c
//  Dynamically loaded NDI sender. Struct layouts mirror the public NDI SDK
//  (Processing.NDI.structs.h / Processing.NDI.Send.h, v3+ "v2" frames), which
//  has been ABI-stable since NDI 3.
//

#include "BBNDI.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *p_ndi_name;
    const char *p_groups;
    bool clock_video;
    bool clock_audio;
} bb_ndi_send_create_t;

typedef struct {
    int xres, yres;
    uint32_t FourCC;            // NDIlib_FourCC_video_type_e (32-bit enum)
    int frame_rate_N, frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;      // NDIlib_frame_format_type_e
    int64_t timecode;
    uint8_t *p_data;
    union {
        int line_stride_in_bytes;
        int data_size_in_bytes;
    };
    const char *p_metadata;
    int64_t timestamp;
} bb_ndi_video_frame_v2_t;

typedef struct {
    int sample_rate;
    int no_channels;
    int no_samples;
    int64_t timecode;
    float *p_data;
    int channel_stride_in_bytes;
    const char *p_metadata;
    int64_t timestamp;
} bb_ndi_audio_frame_v2_t;

typedef struct {
    bool on_program;
    bool on_preview;
} bb_ndi_tally_t;

typedef struct {
    bool show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} bb_ndi_find_create_t;

typedef struct {
    const char *p_ndi_name;
    const char *p_url_address;
} bb_ndi_source_t;

static const int64_t kNDITimecodeSynthesize = INT64_MAX;
static const int kNDIFrameFormatProgressive = 1;

typedef bool (*fn_initialize)(void);
typedef bool (*fn_is_supported_cpu)(void);
typedef const char *(*fn_version)(void);
typedef void *(*fn_send_create)(const bb_ndi_send_create_t *);
typedef void (*fn_send_destroy)(void *);
typedef void (*fn_send_video)(void *, const bb_ndi_video_frame_v2_t *);
typedef void (*fn_send_audio)(void *, const bb_ndi_audio_frame_v2_t *);
typedef int (*fn_get_no_connections)(void *, uint32_t);
typedef bool (*fn_get_tally)(void *, bb_ndi_tally_t *, uint32_t);
typedef void *(*fn_find_create)(const bb_ndi_find_create_t *);
typedef bool (*fn_find_wait)(void *, uint32_t);
typedef const bb_ndi_source_t *(*fn_find_sources)(void *, uint32_t *);
typedef void (*fn_find_destroy)(void *);

static struct {
    void *handle;
    char path[1024];
    fn_initialize initialize;
    fn_is_supported_cpu is_supported_cpu;
    fn_version version;
    fn_send_create send_create;
    fn_send_destroy send_destroy;
    fn_send_video send_video_v2;
    fn_send_video send_video_async_v2;
    fn_send_audio send_audio_v2;
    fn_get_no_connections get_no_connections;
    fn_get_tally get_tally;
    fn_find_create find_create;
    fn_find_wait find_wait;
    fn_find_sources find_sources;
    fn_find_destroy find_destroy;
    bool initialized;
} gNDI;

static pthread_mutex_t gNDILock = PTHREAD_MUTEX_INITIALIZER;

static void bb_set_error(char *buf, int len, const char *msg) {
    if (buf && len > 0) {
        snprintf(buf, (size_t)len, "%s", msg);
    }
}

static bool bb_try_open(const char *path) {
    if (!path || !*path) return false;
    void *h = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!h) return false;
    if (!dlsym(h, "NDIlib_send_create")) {
        dlclose(h);
        return false;
    }
    gNDI.handle = h;
    snprintf(gNDI.path, sizeof(gNDI.path), "%s", path);
    return true;
}

static bool bb_try_dir(const char *dir) {
    if (!dir || !*dir) return false;
    char buf[1024];
    snprintf(buf, sizeof(buf), "%s/libndi.dylib", dir);
    return bb_try_open(buf);
}

bool BBNDILoad(const char *customPath, char *errorBuffer, int errorBufferLength) {
    pthread_mutex_lock(&gNDILock);
    if (gNDI.initialized) {
        pthread_mutex_unlock(&gNDILock);
        return true;
    }

    bool opened = false;
    if (customPath && *customPath) {
        opened = bb_try_open(customPath) || bb_try_dir(customPath);
    }
    if (!opened) opened = bb_try_dir(getenv("NDI_RUNTIME_DIR_V6"));
    if (!opened) opened = bb_try_dir(getenv("NDI_RUNTIME_DIR_V5"));
    if (!opened) {
        static const char *candidates[] = {
            "@executable_path/../Frameworks/libndi.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            "/Library/NDI 6 SDK for Apple/lib/macOS/libndi.dylib",
            "/usr/local/lib/libndi.dylib",
            "/usr/local/lib/libndi.6.dylib",
            "/usr/local/lib/libndi.5.dylib",
            "/opt/homebrew/lib/libndi.dylib",
            "/Applications/NDI Scan Converter.app/Contents/Frameworks/libndi.dylib",
            "/Applications/NDI Router.app/Contents/Frameworks/NTFramework.framework/Versions/A/Frameworks/libndi.dylib",
            "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi.dylib",
            "/Applications/NDI Test Patterns.app/Contents/Frameworks/libndi.dylib",
            "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi_advanced.dylib",
            "/Applications/NDI Test Patterns.app/Contents/Frameworks/libndi_advanced.dylib",
            NULL,
        };
        for (int i = 0; candidates[i] && !opened; i++) {
            opened = bb_try_open(candidates[i]);
        }
    }
    if (!opened) {
        bb_set_error(errorBuffer, errorBufferLength,
                     "NDI runtime not found. Install NDI Tools or the NDI SDK for Apple, or set the library path in Preferences.");
        pthread_mutex_unlock(&gNDILock);
        return false;
    }

#define BB_LOAD(field, sym) gNDI.field = (__typeof__(gNDI.field))dlsym(gNDI.handle, sym)
    BB_LOAD(initialize, "NDIlib_initialize");
    BB_LOAD(is_supported_cpu, "NDIlib_is_supported_CPU");
    BB_LOAD(version, "NDIlib_version");
    BB_LOAD(send_create, "NDIlib_send_create");
    BB_LOAD(send_destroy, "NDIlib_send_destroy");
    BB_LOAD(send_video_v2, "NDIlib_send_send_video_v2");
    BB_LOAD(send_video_async_v2, "NDIlib_send_send_video_async_v2");
    BB_LOAD(send_audio_v2, "NDIlib_send_send_audio_v2");
    BB_LOAD(get_no_connections, "NDIlib_send_get_no_connections");
    BB_LOAD(get_tally, "NDIlib_send_get_tally");
    BB_LOAD(find_create, "NDIlib_find_create_v2");
    BB_LOAD(find_wait, "NDIlib_find_wait_for_sources");
    BB_LOAD(find_sources, "NDIlib_find_get_current_sources");
    BB_LOAD(find_destroy, "NDIlib_find_destroy");
#undef BB_LOAD

    if (!gNDI.initialize || !gNDI.send_create || !gNDI.send_destroy || !gNDI.send_video_v2) {
        bb_set_error(errorBuffer, errorBufferLength, "The NDI library is missing required functions.");
        dlclose(gNDI.handle);
        memset(&gNDI, 0, sizeof(gNDI));
        pthread_mutex_unlock(&gNDILock);
        return false;
    }
    if (gNDI.is_supported_cpu && !gNDI.is_supported_cpu()) {
        bb_set_error(errorBuffer, errorBufferLength, "This CPU is not supported by NDI.");
        pthread_mutex_unlock(&gNDILock);
        return false;
    }
    if (!gNDI.initialize()) {
        bb_set_error(errorBuffer, errorBufferLength, "NDIlib_initialize() failed.");
        pthread_mutex_unlock(&gNDILock);
        return false;
    }
    gNDI.initialized = true;
    pthread_mutex_unlock(&gNDILock);
    return true;
}

bool BBNDIIsLoaded(void) { return gNDI.initialized; }

const char *BBNDILibraryPath(void) { return gNDI.handle ? gNDI.path : NULL; }

const char *BBNDIVersionString(void) {
    return (gNDI.initialized && gNDI.version) ? gNDI.version() : NULL;
}

void *BBNDISenderCreate(const char *name, const char *groups, bool clockVideo) {
    if (!gNDI.initialized) return NULL;
    bb_ndi_send_create_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.p_ndi_name = name;
    settings.p_groups = (groups && *groups) ? groups : NULL;
    settings.clock_video = clockVideo;
    settings.clock_audio = false;
    return gNDI.send_create(&settings);
}

void BBNDISenderDestroy(void *sender) {
    if (gNDI.initialized && sender) gNDI.send_destroy(sender);
}

void BBNDISenderSendVideo(void *sender, int width, int height, uint32_t fourCC, int frameRateN,
                          int frameRateD, const void *data, int lineStride, bool async) {
    if (!gNDI.initialized || !sender || !data) return;
    bb_ndi_video_frame_v2_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.xres = width;
    frame.yres = height;
    frame.FourCC = fourCC;
    frame.frame_rate_N = frameRateN;
    frame.frame_rate_D = frameRateD;
    frame.picture_aspect_ratio = 0.0f; // square pixels
    frame.frame_format_type = kNDIFrameFormatProgressive;
    frame.timecode = kNDITimecodeSynthesize;
    frame.p_data = (uint8_t *)data;
    frame.line_stride_in_bytes = lineStride;
    if (async && gNDI.send_video_async_v2) {
        gNDI.send_video_async_v2(sender, &frame);
    } else {
        gNDI.send_video_v2(sender, &frame);
    }
}

void BBNDISenderSendAudio(void *sender, int sampleRate, int channels, int samples, const float *planar,
                          int channelStrideBytes) {
    if (!gNDI.initialized || !sender || !planar || !gNDI.send_audio_v2 || samples <= 0) return;
    bb_ndi_audio_frame_v2_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.sample_rate = sampleRate;
    frame.no_channels = channels;
    frame.no_samples = samples;
    frame.timecode = kNDITimecodeSynthesize;
    frame.p_data = (float *)planar;
    frame.channel_stride_in_bytes = channelStrideBytes;
    gNDI.send_audio_v2(sender, &frame);
}

void BBNDISenderFlushAsync(void *sender) {
    if (gNDI.initialized && sender && gNDI.send_video_async_v2) {
        gNDI.send_video_async_v2(sender, NULL);
    }
}

int BBNDISenderConnectionCount(void *sender, uint32_t timeoutMs) {
    if (!gNDI.initialized || !sender || !gNDI.get_no_connections) return -1;
    return gNDI.get_no_connections(sender, timeoutMs);
}

bool BBNDISenderGetTally(void *sender, bool *onProgram, bool *onPreview) {
    *onProgram = false;
    *onPreview = false;
    if (!gNDI.initialized || !sender || !gNDI.get_tally) return false;
    bb_ndi_tally_t tally = {false, false};
    bool ok = gNDI.get_tally(sender, &tally, 0);
    *onProgram = tally.on_program;
    *onPreview = tally.on_preview;
    return ok;
}

int BBNDIFindSources(char *buffer, int bufferLength, uint32_t waitMs) {
    if (bufferLength > 0) buffer[0] = 0;
    if (!gNDI.initialized || !gNDI.find_create || !gNDI.find_wait || !gNDI.find_sources || !gNDI.find_destroy) {
        return -1;
    }
    bb_ndi_find_create_t settings = {true, NULL, NULL};
    void *finder = gNDI.find_create(&settings);
    if (!finder) return -1;
    gNDI.find_wait(finder, waitMs);
    uint32_t count = 0;
    const bb_ndi_source_t *sources = gNDI.find_sources(finder, &count);
    int used = 0;
    for (uint32_t i = 0; i < count && sources; i++) {
        const char *name = sources[i].p_ndi_name ? sources[i].p_ndi_name : "";
        int n = snprintf(buffer + used, (size_t)(bufferLength - used), "%s\n", name);
        if (n < 0 || used + n >= bufferLength) break;
        used += n;
    }
    gNDI.find_destroy(finder);
    return (int)count;
}
