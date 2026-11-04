//
//  BBSystemStats.c
//

#include "BBSystemStats.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/route.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

static mach_port_t bb_host(void) {
    static mach_port_t host = MACH_PORT_NULL;
    if (host == MACH_PORT_NULL) host = mach_host_self();
    return host;
}

bool BBProcessStats(int pid, uint64_t *cpuNanos, uint64_t *footprintBytes) {
    struct rusage_info_v4 info;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return false;
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    // rusage CPU times are reported in mach absolute time units.
    uint64_t ticks = info.ri_user_time + info.ri_system_time;
    *cpuNanos = (uint64_t)((double)ticks * (double)timebase.numer / (double)timebase.denom);
    *footprintBytes = info.ri_phys_footprint;
    return true;
}

bool BBHostCPUTicks(uint64_t *busy, uint64_t *total) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(bb_host(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return false;
    uint64_t user = info.cpu_ticks[CPU_STATE_USER];
    uint64_t sys = info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t nice = info.cpu_ticks[CPU_STATE_NICE];
    uint64_t idle = info.cpu_ticks[CPU_STATE_IDLE];
    *busy = user + sys + nice;
    *total = user + sys + nice + idle;
    return true;
}

bool BBHostMemory(uint64_t *usedBytes, uint64_t *totalBytes) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(bb_host(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return false;
    vm_size_t pageSize = 0;
    host_page_size(bb_host(), &pageSize);
    uint64_t appPages = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
    *usedBytes = (appPages + vm.wire_count + vm.compressor_page_count) * (uint64_t)pageSize;

    uint64_t memsize = 0;
    size_t len = sizeof(memsize);
    int mib[2] = {CTL_HW, HW_MEMSIZE};
    sysctl(mib, 2, &memsize, &len, NULL, 0);
    *totalBytes = memsize;
    return true;
}

bool BBNetworkBytes(uint64_t *inBytes, uint64_t *outBytes) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) return false;
    char *buf = malloc(len);
    if (!buf) return false;
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) {
        free(buf);
        return false;
    }
    uint64_t totalIn = 0, totalOut = 0;
    char *next = buf;
    char *end = buf + len;
    while (next < end) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        if (ifm->ifm_msglen == 0) break;
        if (ifm->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *if2 = (struct if_msghdr2 *)ifm;
            if (!(if2->ifm_flags & IFF_LOOPBACK)) {
                totalIn += if2->ifm_data.ifi_ibytes;
                totalOut += if2->ifm_data.ifi_obytes;
            }
        }
        next += ifm->ifm_msglen;
    }
    free(buf);
    *inBytes = totalIn;
    *outBytes = totalOut;
    return true;
}

int BBGPUUtilization(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS) {
        return -1;
    }
    int result = -1;
    io_object_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFTypeRef perf = CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
            if (perf && CFGetTypeID(perf) == CFDictionaryGetTypeID()) {
                CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)perf, CFSTR("Device Utilization %"));
                if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                    int v = 0;
                    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &v);
                    if (v > result) result = v;
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return result;
}
