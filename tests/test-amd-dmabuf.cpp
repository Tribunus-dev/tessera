// test-amd-dmabuf.cpp
//
// Test dma-buf allocation and fence (pure logic, no hardware).
//
// What this exercises:
//  1. ggml_amd_allocation_create() with each domain
//  2. fd ownership semantics (OWNED, DUPLICATED, BORROWED)
//  3. fence creation for each kind (HOST, SYNC_FILE, HIP_EVENT, etc.)
//  4. fence ordering check (ggml_amd_fence_check_ordering)
//  5. allocation release and ref counting
//
// Linux-specific tests are gated with #ifdef __linux__.
// Hardware-dependent tests are gated with #ifdef GGML_AMD_HIP etc.

#include "ggml-amd-internal.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

#ifdef __linux__
#include <cerrno>
#include <fcntl.h>
#include <sys/eventfd.h>
#include <dirent.h>
#include <unistd.h>
#endif

// Internal API declarations (not in public header)
struct ggml_amd_allocation * ggml_amd_allocation_create(
    enum ggml_amd_memory_domain domain,
    size_t size,
    size_t alignment,
    enum ggml_amd_coherency coherency);

void * ggml_amd_allocation_map_cpu(struct ggml_amd_allocation * alloc);
void ggml_amd_allocation_unmap_cpu(struct ggml_amd_allocation * alloc);
int ggml_amd_allocation_dup_fd(struct ggml_amd_allocation * alloc);
void ggml_amd_allocation_record_writer(struct ggml_amd_allocation * alloc, struct ggml_amd_fence * fence);

struct ggml_amd_fence ggml_amd_fence_create_host(void);
struct ggml_amd_fence ggml_amd_fence_create_sync_file(int fd);
struct ggml_amd_fence ggml_amd_fence_create_hip_event(void * event);
struct ggml_amd_fence ggml_amd_fence_create_vulkan_timeline(uint64_t value);
struct ggml_amd_fence ggml_amd_fence_create_xrt(void * xrt_fence);
void ggml_amd_fence_release(struct ggml_amd_fence * fence);
int ggml_amd_fence_wait(struct ggml_amd_fence * fence, int timeout_ms);
int ggml_amd_fence_check_ordering(struct ggml_amd_fence * waiter, struct ggml_amd_fence * writer);

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

#ifdef __linux__
static int count_open_fds(void) {
    DIR * dir = opendir("/proc/self/fd");
    if (!dir) {
        return -1;
    }

    int count = 0;
    while (readdir(dir)) {
        ++count;
    }
    closedir(dir);
    return count - 2;
}
#endif

static void test_allocation_create_shared_system(void) {
    // SHARED_SYSTEM requires /dev/dma_heap/system which may not exist
    // On non-Linux or without dma-heap, this returns nullptr
    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_SHARED_SYSTEM,
        4096,
        4096,
        GGML_AMD_COHERENCY_SHARED);

#ifdef __linux__
    // May be nullptr if /dev/dma_heap/system doesn't exist
    if (alloc) {
        CHECK(true, "SHARED_SYSTEM allocation succeeds");
        ggml_amd_allocation_release(alloc);
    } else {
        std::fprintf(stdout, "     SHARED_SYSTEM allocation skipped (no dma-heap)\n");
    }
#else
    CHECK(alloc == nullptr, "SHARED_SYSTEM returns nullptr on non-Linux");
#endif
}

static void test_allocation_create_gpu_local(void) {
    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_GPU_LOCAL_EXPORTABLE,
        8192,
        64,
        GGML_AMD_COHERENCY_GPU_ONLY);

    CHECK(alloc != nullptr, "GPU_LOCAL_EXPORTABLE allocation succeeds");
    if (alloc) {
        ggml_amd_allocation_release(alloc);
    }
}

static void test_allocation_create_provider_private(void) {
    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_PROVIDER_PRIVATE,
        1024,
        32,
        GGML_AMD_COHERENCY_CPU_ONLY);

    CHECK(alloc != nullptr, "PROVIDER_PRIVATE allocation succeeds");
    if (alloc) {
        ggml_amd_allocation_release(alloc);
    }
}

static void test_allocation_create_imported_external(void) {
    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_IMPORTED_EXTERNAL,
        2048,
        16,
        GGML_AMD_COHERENCY_SHARED);

    CHECK(alloc != nullptr, "IMPORTED_EXTERNAL allocation succeeds");
    if (alloc) {
        ggml_amd_allocation_release(alloc);
    }
}

static void test_fence_create_host(void) {
    struct ggml_amd_fence fence = ggml_amd_fence_create_host();
    CHECK(fence.kind == GGML_AMD_FENCE_HOST, "fence kind is HOST");
    CHECK(fence.sequence > 0, "fence sequence is positive");

    uint64_t seq1 = fence.sequence;
    struct ggml_amd_fence fence2 = ggml_amd_fence_create_host();
    CHECK(fence2.sequence > seq1, "fence sequences are monotonically increasing");

    ggml_amd_fence_release(&fence);
    ggml_amd_fence_release(&fence2);
}

static void test_fence_create_sync_file(void) {
#ifdef __linux__
    int fd = eventfd(1, EFD_CLOEXEC);
    CHECK(fd >= 0, "eventfd for sync-file fence is created");
    if (fd < 0) {
        return;
    }
    struct ggml_amd_fence fence = ggml_amd_fence_create_sync_file(fd);
    CHECK(fence.kind == GGML_AMD_FENCE_SYNC_FILE, "fence kind is SYNC_FILE");
    CHECK(fence.sync_file_fd == fd, "fence sync_file_fd matches");
    CHECK(fence.sequence > 0, "fence sequence is positive");

    CHECK(ggml_amd_fence_wait(&fence, 0) == 0, "signaled sync-file fence waits successfully");
    ggml_amd_fence_release(&fence);
    CHECK(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "sync-file fence release closes owned fd");
#else
    std::fprintf(stdout, "     SYNC_FILE fence test skipped (non-Linux)\n");
#endif
}

static void test_fence_create_hip_event(void) {
    void * dummy_event = (void *)0x12345678;
    struct ggml_amd_fence fence = ggml_amd_fence_create_hip_event(dummy_event);
    CHECK(fence.kind == GGML_AMD_FENCE_HIP_EVENT, "fence kind is HIP_EVENT");
    CHECK(fence.hip_event == dummy_event, "fence hip_event matches");
    CHECK(fence.sequence > 0, "fence sequence is positive");

    ggml_amd_fence_release(&fence);
}

static void test_fence_create_vulkan_timeline(void) {
    uint64_t timeline_value = 12345;
    struct ggml_amd_fence fence = ggml_amd_fence_create_vulkan_timeline(timeline_value);
    CHECK(fence.kind == GGML_AMD_FENCE_VULKAN_TIMELINE, "fence kind is VULKAN_TIMELINE");
    CHECK(fence.vulkan_timeline_value == timeline_value, "fence vulkan_timeline_value matches");
    CHECK(fence.sequence > 0, "fence sequence is positive");

    ggml_amd_fence_release(&fence);
}

static void test_fence_create_xrt(void) {
    void * dummy_xrt = (void *)0xABCDEF00;
    struct ggml_amd_fence fence = ggml_amd_fence_create_xrt(dummy_xrt);
    CHECK(fence.kind == GGML_AMD_FENCE_XRT, "fence kind is XRT");
    CHECK(fence.xrt_fence == dummy_xrt, "fence xrt_fence matches");
    CHECK(fence.sequence > 0, "fence sequence is positive");

    ggml_amd_fence_release(&fence);
}

static void test_fence_check_ordering(void) {
    struct ggml_amd_fence waiter = ggml_amd_fence_create_host();
    struct ggml_amd_fence writer = ggml_amd_fence_create_host();

    // waiter.sequence < writer.sequence (waiter created first)
    int result = ggml_amd_fence_check_ordering(&waiter, &writer);
    CHECK(result == 0, "fence ordering check passes when waiter < writer");

    // Reverse: waiter.sequence > writer.sequence
    result = ggml_amd_fence_check_ordering(&writer, &waiter);
    CHECK(result == -1, "fence ordering check fails when waiter > writer");

    // Same sequence
    result = ggml_amd_fence_check_ordering(&waiter, &waiter);
    CHECK(result == -1, "fence ordering check fails when waiter == writer");

    // Null pointers
    result = ggml_amd_fence_check_ordering(nullptr, &writer);
    CHECK(result == -1, "fence ordering check fails with null waiter");

    result = ggml_amd_fence_check_ordering(&waiter, nullptr);
    CHECK(result == -1, "fence ordering check fails with null writer");

    ggml_amd_fence_release(&waiter);
    ggml_amd_fence_release(&writer);
}

static void test_fence_wait_host(void) {
    struct ggml_amd_fence fence = ggml_amd_fence_create_host();
    int result = ggml_amd_fence_wait(&fence, 100);
    CHECK(result == 0, "host fence wait returns 0 (immediate success)");

    ggml_amd_fence_release(&fence);
}

static void test_fence_wait_none(void) {
    struct ggml_amd_fence fence;
    memset(&fence, 0, sizeof(fence));
    fence.kind = GGML_AMD_FENCE_NONE;

    int result = ggml_amd_fence_wait(&fence, 100);
    CHECK(result == 0, "NONE fence wait returns 0");
}

static void test_allocation_record_writer(void) {
    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_PROVIDER_PRIVATE,
        1024,
        32,
        GGML_AMD_COHERENCY_CPU_ONLY);

    if (alloc) {
        struct ggml_amd_fence fence = ggml_amd_fence_create_host();
        ggml_amd_allocation_record_writer(alloc, &fence);
        ggml_amd_fence_release(&fence);
        ggml_amd_allocation_release(alloc);
        CHECK(true, "allocation records and releases host writer");
    }
}

static void test_allocation_record_writer_duplicates_sync_file(void) {
#ifdef __linux__
    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_PROVIDER_PRIVATE,
        1024,
        32,
        GGML_AMD_COHERENCY_CPU_ONLY);
    int fd_count_before = count_open_fds();
    int fd = eventfd(1, EFD_CLOEXEC);

    CHECK(fd_count_before >= 0, "open fd count is available");
    CHECK(fd >= 0, "eventfd for allocation writer is created");
    if (!alloc || fd < 0) {
        if (alloc) {
            ggml_amd_allocation_release(alloc);
        }
        if (fd >= 0) {
            close(fd);
        }
        return;
    }

    struct ggml_amd_fence fence = ggml_amd_fence_create_sync_file(fd);
    ggml_amd_allocation_record_writer(alloc, &fence);
    CHECK(count_open_fds() == fd_count_before + 2, "allocation duplicates the sync-file fd");

    ggml_amd_fence_release(&fence);
    CHECK(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "releasing producer fence leaves allocation fence valid");
    CHECK(count_open_fds() == fd_count_before + 1, "allocation retains its owned sync-file fd");

    ggml_amd_allocation_release(alloc);
    CHECK(count_open_fds() == fd_count_before, "allocation release closes recorded sync-file fd");
#else
    std::fprintf(stdout, "     allocation writer fd duplication skipped (non-Linux)\n");
#endif
}

static void test_allocation_release_null(void) {
    // Should not crash
    ggml_amd_allocation_release(nullptr);
    CHECK(true, "release(nullptr) does not crash");
}

static void test_fence_release_null(void) {
    // Should not crash
    ggml_amd_fence_release(nullptr);
    CHECK(true, "fence_release(nullptr) does not crash");
}

int main(void) {
    std::fprintf(stdout, "=== test-amd-dmabuf ===\n");

    test_allocation_create_shared_system();
    test_allocation_create_gpu_local();
    test_allocation_create_provider_private();
    test_allocation_create_imported_external();
    test_fence_create_host();
    test_fence_create_sync_file();
    test_fence_create_hip_event();
    test_fence_create_vulkan_timeline();
    test_fence_create_xrt();
    test_fence_check_ordering();
    test_fence_wait_host();
    test_fence_wait_none();
    test_allocation_record_writer();
    test_allocation_record_writer_duplicates_sync_file();
    test_allocation_release_null();
    test_fence_release_null();

    std::fprintf(stdout, "\n");
    if (g_failures == 0) {
        std::fprintf(stdout, "PASS: all tests passed\n");
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: %d test(s) failed\n", g_failures);
        return 1;
    }
}
