#ifndef GGML_AMD_TYPES_H
#define GGML_AMD_TYPES_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum ggml_amd_memory_domain {
    GGML_AMD_DOMAIN_SHARED_SYSTEM,
    GGML_AMD_DOMAIN_GPU_LOCAL_EXPORTABLE,
    GGML_AMD_DOMAIN_PROVIDER_PRIVATE,
    GGML_AMD_DOMAIN_IMPORTED_EXTERNAL,
};

enum ggml_amd_external_handle_kind {
    GGML_AMD_EXTERNAL_HANDLE_KIND_NONE,
    GGML_AMD_EXTERNAL_HANDLE_KIND_UNKNOWN,
    GGML_AMD_EXTERNAL_HANDLE_KIND_VULKAN_OPAQUE_FD,
};

enum ggml_amd_coherency {
    GGML_AMD_COHERENCY_CPU_ONLY,
    GGML_AMD_COHERENCY_GPU_ONLY,
    GGML_AMD_COHERENCY_SHARED,
};

enum ggml_amd_fd_ownership {
    GGML_AMD_FD_OWNERSHIP_OWNED,
    GGML_AMD_FD_OWNERSHIP_DUPLICATED,
    GGML_AMD_FD_OWNERSHIP_BORROWED,
};

enum ggml_amd_fence_kind {
    GGML_AMD_FENCE_NONE,
    GGML_AMD_FENCE_HOST,
    GGML_AMD_FENCE_SYNC_FILE,
    GGML_AMD_FENCE_HIP_EVENT,
    GGML_AMD_FENCE_VULKAN_TIMELINE,
    GGML_AMD_FENCE_XRT,
};

enum ggml_amd_device_type {
    GGML_AMD_DEVICE_CPU,
    GGML_AMD_DEVICE_IGPU,
    GGML_AMD_DEVICE_DGPU,
    GGML_AMD_DEVICE_NPU,
    GGML_AMD_DEVICE_HETERO,
};

enum ggml_amd_scheduler_mode {
    GGML_AMD_SCHEDULER_DETERMINISTIC,
    GGML_AMD_SCHEDULER_ADAPTIVE,
    GGML_AMD_SCHEDULER_DIAGNOSTIC,
    GGML_AMD_SCHEDULER_SINGLE_PROVIDER,
};

enum ggml_amd_phase {
    GGML_AMD_PHASE_PREFILL,
    GGML_AMD_PHASE_DECODE,
};

struct ggml_amd_fence {
    enum ggml_amd_fence_kind kind;
    uint64_t sequence;
    union {
        int sync_file_fd;
        void * hip_event;
        uint64_t vulkan_timeline_value;
        void * xrt_fence;
    };
};

struct ggml_amd_allocation;
struct ggml_amd_import;
struct ggml_amd_region;
struct ggml_amd_provider;

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_TYPES_H
