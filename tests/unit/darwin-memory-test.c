// Execute the production Darwin memory exporter with controlled host readings.
// Each invocation is a fresh process because ISH_MEM_LIMIT_MB is cached by the
// production code. This uses its existing macOS app-headroom emulation path.
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <TargetConditionals.h>
#include <stdlib.h>
#include <sys/time.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MIB (UINT64_C(1) << 20)
#define GIB (UINT64_C(1) << 30)

static uint64_t physical_memory = UINT64_C(12082675712);
static uint64_t footprints[4];
static size_t footprint_count;
static size_t footprint_index;
static int memsize_error;
static host_basic_info_data_t fixture_basic;
static vm_statistics64_data_t fixture_vm;

static kern_return_t fixture_task_info(task_name_t task, task_flavor_t flavor,
        task_info_t output, mach_msg_type_number_t *count) {
    (void) task;
    assert(flavor == TASK_VM_INFO);
    assert(*count == TASK_VM_INFO_COUNT);
    assert(footprint_index < footprint_count);
    task_vm_info_data_t *info = (task_vm_info_data_t *) output;
    memset(info, 0, sizeof(*info));
    info->phys_footprint = footprints[footprint_index++];
    return KERN_SUCCESS;
}

static kern_return_t fixture_host_info(host_t host, host_flavor_t flavor,
        host_info_t output, mach_msg_type_number_t *count) {
    (void) host;
    assert(flavor == HOST_BASIC_INFO);
    assert(*count == HOST_BASIC_INFO_COUNT);
    memcpy(output, &fixture_basic, sizeof(fixture_basic));
    return KERN_SUCCESS;
}

static kern_return_t fixture_host_statistics64(host_t host, host_flavor_t flavor,
        host_info64_t output, mach_msg_type_number_t *count) {
    (void) host;
    assert(flavor == HOST_VM_INFO64);
    assert(*count == HOST_VM_INFO64_COUNT);
    memcpy(output, &fixture_vm, sizeof(fixture_vm));
    return KERN_SUCCESS;
}

static int fixture_sysctlbyname(const char *name, void *output, size_t *size,
        void *new_value, size_t new_size) {
    assert(strcmp(name, "hw.memsize") == 0);
    assert(new_value == NULL && new_size == 0);
    assert(*size == sizeof(physical_memory));
    if (memsize_error)
        return -1;
    memcpy(output, &physical_memory, sizeof(physical_memory));
    return 0;
}

// Only host API readings are replaced. get_mem_usage(), host_memory_headroom()
// and host_memory_footprint() below are the unmodified production functions.
#define task_info fixture_task_info
#define host_info fixture_host_info
#define host_statistics64 fixture_host_statistics64
#define sysctlbyname fixture_sysctlbyname
#ifndef DARWIN_MEMORY_TEST_SOURCE
#define DARWIN_MEMORY_TEST_SOURCE "platform/darwin.c"
#endif
#include DARWIN_MEMORY_TEST_SOURCE
#undef task_info
#undef host_info
#undef host_statistics64
#undef sysctlbyname

static void set_footprints(uint64_t first, uint64_t second) {
    footprints[0] = first;
    footprints[1] = second;
    footprint_count = 2;
    footprint_index = 0;
}

static void expect_host_fields(struct mem_usage usage) {
    assert(usage.active == UINT64_C(100) * vm_page_size);
    assert(usage.inactive == UINT64_C(32) * vm_page_size);
}

static void expect_allowance(uint64_t total, uint64_t available, uint64_t used) {
    struct mem_usage usage = get_mem_usage();
    assert(usage.total == total);
    assert(usage.available == available);
    assert(usage.free == available);
    assert(usage.total - usage.available == used);
    assert(usage.cached == 0);
    assert(footprint_index == footprint_count);
    expect_host_fields(usage);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(unsetenv("ISH_MEM_LIMIT_MB") == 0);
    vm_page_size = 4096;
    fixture_basic.max_mem = 2 * MIB;
    fixture_vm.free_count = 64;
    fixture_vm.active_count = 100;
    fixture_vm.inactive_count = 32;
    fixture_vm.external_page_count = 16;
    fixture_vm.purgeable_count = 8;
    fixture_vm.speculative_count = 4;

    if (strcmp(argv[1], "quota-5g") == 0) {
        assert(setenv("ISH_MEM_LIMIT_MB", "5120", 1) == 0);
        set_footprints(512 * MIB, 512 * MIB);
        expect_allowance(5 * GIB, 4608 * MIB, 512 * MIB);
    } else if (strcmp(argv[1], "quota-12g-small") == 0) {
        assert(setenv("ISH_MEM_LIMIT_MB", "12288", 1) == 0);
        set_footprints(512 * MIB, 512 * MIB);
        expect_allowance(12 * GIB, 11776 * MIB, 512 * MIB);
    } else if (strcmp(argv[1], "quota-12g-large") == 0) {
        assert(setenv("ISH_MEM_LIMIT_MB", "12288", 1) == 0);
        set_footprints(GIB, GIB);
        expect_allowance(12 * GIB, 11 * GIB, GIB);
    } else if (strcmp(argv[1], "tiny-headroom") == 0) {
        assert(setenv("ISH_MEM_LIMIT_MB", "12288", 1) == 0);
        set_footprints(12 * GIB - 1, 12 * GIB - 1);
        expect_allowance(12 * GIB, 1, 12 * GIB - 1);
    } else if (strcmp(argv[1], "host-fallback") == 0) {
        struct mem_usage usage = get_mem_usage();
        assert(usage.total == physical_memory);
        assert(usage.free == 64 * UINT64_C(4096));
        assert(usage.available == 108 * UINT64_C(4096));
        assert(usage.cached == 16 * UINT64_C(4096));
        assert(footprint_index == 0);
        expect_host_fields(usage);
    } else if (strcmp(argv[1], "host-clamp") == 0) {
        // Preserve both the host-total fallback and its available-only clamp.
        memsize_error = 1;
        fixture_vm.free_count = 2048;
        struct mem_usage usage = get_mem_usage();
        assert(usage.total == 2 * MIB);
        assert(usage.available == 2 * MIB);
        assert(usage.free == 8 * MIB);
        assert(usage.cached == 16 * UINT64_C(4096));
        assert(footprint_index == 0);
        expect_host_fields(usage);
    } else if (strcmp(argv[1], "overflow") == 0) {
        // Largest whole-MiB limit representable in uint64_t. Separate live
        // readings deliberately make footprint + headroom overflow by 1 byte.
        assert(setenv("ISH_MEM_LIMIT_MB", "17592186044415", 1) == 0);
        set_footprints(0, MIB);
        expect_allowance(UINT64_MAX, UINT64_MAX - MIB + 1, MIB - 1);
    } else if (strcmp(argv[1], "live-footprint") == 0) {
        assert(setenv("ISH_MEM_LIMIT_MB", "12288", 1) == 0);
        set_footprints(512 * MIB, 512 * MIB);
        expect_allowance(12 * GIB, 11776 * MIB, 512 * MIB);
        set_footprints(GIB, GIB);
        expect_allowance(12 * GIB, 11 * GIB, GIB);
    } else {
        fprintf(stderr, "unknown fixture: %s\n", argv[1]);
        return 1;
    }
    printf("Darwin memory exporter %s: passed\n", argv[1]);
    return 0;
}
