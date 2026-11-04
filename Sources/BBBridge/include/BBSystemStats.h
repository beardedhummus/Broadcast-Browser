//
//  BBSystemStats.h
//  Small C helpers for the dashboard (process/system CPU, memory, GPU,
//  network throughput).
//

#ifndef BBSystemStats_h
#define BBSystemStats_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Total CPU time (user + system) in nanoseconds and physical footprint in bytes.
bool BBProcessStats(int pid, uint64_t *_Nonnull cpuNanos, uint64_t *_Nonnull footprintBytes);
/// Aggregate host CPU ticks.
bool BBHostCPUTicks(uint64_t *_Nonnull busy, uint64_t *_Nonnull total);
/// Memory used (app + wired + compressed, like Activity Monitor) and total, in bytes.
bool BBHostMemory(uint64_t *_Nonnull usedBytes, uint64_t *_Nonnull totalBytes);
/// Total bytes received/sent on all non-loopback interfaces.
bool BBNetworkBytes(uint64_t *_Nonnull inBytes, uint64_t *_Nonnull outBytes);
/// GPU "Device Utilization %" from IOKit, or -1 when unavailable.
int BBGPUUtilization(void);

#ifdef __cplusplus
}
#endif

#endif /* BBSystemStats_h */
