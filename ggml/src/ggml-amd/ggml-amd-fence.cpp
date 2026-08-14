#include "ggml-amd-internal.h"
#include "ggml.h"

#include <atomic>
#include <chrono>
#include <cstring>

#ifdef __linux__
#include <unistd.h>
#include <sys/eventfd.h>
#include <poll.h>
#endif

static std::atomic<uint64_t> g_fence_sequence{1};

struct ggml_amd_fence ggml_amd_fence_create_host(void) {
    struct ggml_amd_fence fence;
    memset(&fence, 0, sizeof(fence));
    fence.kind = GGML_AMD_FENCE_HOST;
    fence.sequence = g_fence_sequence.fetch_add(1);
    return fence;
}

struct ggml_amd_fence ggml_amd_fence_create_sync_file(int fd) {
    struct ggml_amd_fence fence;
    memset(&fence, 0, sizeof(fence));
    fence.kind = GGML_AMD_FENCE_SYNC_FILE;
    fence.sequence = g_fence_sequence.fetch_add(1);
    fence.sync_file_fd = fd;
    return fence;
}

struct ggml_amd_fence ggml_amd_fence_create_hip_event(void * event) {
    struct ggml_amd_fence fence;
    memset(&fence, 0, sizeof(fence));
    fence.kind = GGML_AMD_FENCE_HIP_EVENT;
    fence.sequence = g_fence_sequence.fetch_add(1);
    fence.hip_event = event;
    return fence;
}

struct ggml_amd_fence ggml_amd_fence_create_vulkan_timeline(uint64_t value) {
    struct ggml_amd_fence fence;
    memset(&fence, 0, sizeof(fence));
    fence.kind = GGML_AMD_FENCE_VULKAN_TIMELINE;
    fence.sequence = g_fence_sequence.fetch_add(1);
    fence.vulkan_timeline_value = value;
    return fence;
}

struct ggml_amd_fence ggml_amd_fence_create_xrt(void * xrt_fence) {
    struct ggml_amd_fence fence;
    memset(&fence, 0, sizeof(fence));
    fence.kind = GGML_AMD_FENCE_XRT;
    fence.sequence = g_fence_sequence.fetch_add(1);
    fence.xrt_fence = xrt_fence;
    return fence;
}

void ggml_amd_fence_release(struct ggml_amd_fence * fence) {
    if (!fence) {
        return;
    }

    if (fence->kind == GGML_AMD_FENCE_SYNC_FILE && fence->sync_file_fd >= 0) {
#ifdef __linux__
        close(fence->sync_file_fd);
#endif
    }

    fence->kind = GGML_AMD_FENCE_NONE;
    fence->sequence = 0;
}

int ggml_amd_fence_wait(struct ggml_amd_fence * fence, int timeout_ms) {
    if (!fence || fence->kind == GGML_AMD_FENCE_NONE) {
        return 0;
    }

    switch (fence->kind) {
        case GGML_AMD_FENCE_HOST:
            return 0;

        case GGML_AMD_FENCE_SYNC_FILE: {
#ifdef __linux__
            if (fence->sync_file_fd < 0) {
                return 0;
            }
            struct pollfd pfd = {};
            pfd.fd = fence->sync_file_fd;
            pfd.events = POLLIN;
            int ret = poll(&pfd, 1, timeout_ms);
            if (ret < 0) {
                return -1;
            }
            if (ret == 0) {
                return 1;
            }
            return 0;
#else
            (void)timeout_ms;
            return -1;
#endif
        }

        case GGML_AMD_FENCE_HIP_EVENT:
            return -1;

        case GGML_AMD_FENCE_VULKAN_TIMELINE:
            return -1;

        case GGML_AMD_FENCE_XRT:
            return -1;

        default:
            return -1;
    }
}

int ggml_amd_fence_check_ordering(struct ggml_amd_fence * waiter, struct ggml_amd_fence * writer) {
    if (!waiter || !writer) {
        return -1;
    }

    if (waiter->sequence >= writer->sequence) {
        return -1;
    }

    return 0;
}

void ggml_amd_allocation_record_writer(struct ggml_amd_allocation * alloc, struct ggml_amd_fence * fence) {
    if (!alloc || !fence) {
        return;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);
    alloc->last_writer = *fence;
    alloc->generation++;
}
