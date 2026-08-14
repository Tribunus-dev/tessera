#include "../ggml-amd-internal.h"
#include "../ggml-amd-provider.h"
#include "ggml-amd-hip.h"
#include "ggml-impl.h"
#include "ggml.h"

#include <cstring>

#if defined(__linux__)
#include <unistd.h>
#endif

#ifdef GGML_AMD_HIP

#ifdef __HIP_PLATFORM_AMD__
#include <hip/hip_runtime.h>
#include <hip/hip_runtime_api.h>
#include "../tile/ggml-amd-tile-hip.h"
#include "../tile/ggml-amd-tile-dump-dequant.h"
#endif

struct ggml_amd_hip_context {
#ifdef __HIP_PLATFORM_AMD__
    int device_id;
    hipDeviceProp_t props;
    hipStream_t stream;
#endif
    bool initialized;
};

extern struct ggml_amd_fence ggml_amd_fence_create_host(void);

static ggml_amd_hip_context * ggml_amd_hip_context_get(struct ggml_amd_provider * provider) {
#ifdef __HIP_PLATFORM_AMD__
    if (!provider || !provider->context) {
        return nullptr;
    }

    auto ctx = (ggml_amd_hip_context *)provider->context;
    return ctx->initialized ? ctx : nullptr;
#else
    (void)provider;
    return nullptr;
#endif
}

bool ggml_amd_hip_is_provider(const struct ggml_amd_provider * provider) {
    return provider && provider->iface && provider->iface->name && strcmp(provider->iface->name, "hip") == 0;
}

void * ggml_amd_hip_alloc(struct ggml_amd_provider * provider, size_t size) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    void * ptr = nullptr;
    if (!ctx || hipSetDevice(ctx->device_id) != hipSuccess || hipMalloc(&ptr, size) != hipSuccess) {
        return nullptr;
    }
    return ptr;
#else
    (void)provider;
    (void)size;
    return nullptr;
#endif
}

void ggml_amd_hip_free(struct ggml_amd_provider * provider, void * ptr) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    if (ctx && ptr && hipSetDevice(ctx->device_id) == hipSuccess) {
        (void)hipFree(ptr);
    }
#else
    (void)provider;
    (void)ptr;
#endif
}

bool ggml_amd_hip_set(struct ggml_amd_provider * provider, void * dst, const void * src, size_t size) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    return ctx && hipSetDevice(ctx->device_id) == hipSuccess && hipMemcpy(dst, src, size, hipMemcpyHostToDevice) == hipSuccess;
#else
    (void)provider;
    (void)dst;
    (void)src;
    (void)size;
    return false;
#endif
}

bool ggml_amd_hip_get(struct ggml_amd_provider * provider, void * dst, const void * src, size_t size) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    return ctx && hipSetDevice(ctx->device_id) == hipSuccess && hipMemcpy(dst, src, size, hipMemcpyDeviceToHost) == hipSuccess;
#else
    (void)provider;
    (void)dst;
    (void)src;
    (void)size;
    return false;
#endif
}

bool ggml_amd_hip_copy(struct ggml_amd_provider * provider, void * dst, const void * src, size_t size) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    return ctx && hipSetDevice(ctx->device_id) == hipSuccess && hipMemcpy(dst, src, size, hipMemcpyDeviceToDevice) == hipSuccess;
#else
    (void)provider;
    (void)dst;
    (void)src;
    (void)size;
    return false;
#endif
}

bool ggml_amd_hip_memset(struct ggml_amd_provider * provider, void * dst, uint8_t value, size_t size) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    return ctx && hipSetDevice(ctx->device_id) == hipSuccess && hipMemset(dst, value, size) == hipSuccess;
#else
    (void)provider;
    (void)dst;
    (void)value;
    (void)size;
    return false;
#endif
}

bool ggml_amd_hip_synchronize(struct ggml_amd_provider * provider) {
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    return ctx && hipSetDevice(ctx->device_id) == hipSuccess && hipStreamSynchronize(ctx->stream) == hipSuccess;
#else
    (void)provider;
    return false;
#endif
}

static bool ggml_amd_hip_probe_impl(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
#ifdef GGML_AMD_HIP
#ifdef __HIP_PLATFORM_AMD__
    auto ctx = new ggml_amd_hip_context();
    ctx->initialized = false;

    int device_count = 0;
    if (hipGetDeviceCount(&device_count) != hipSuccess || device_count == 0) {
        delete ctx;
        return false;
    }

    ctx->device_id = 0;
    if (hipGetDeviceProperties(&ctx->props, ctx->device_id) != hipSuccess) {
        delete ctx;
        return false;
    }

    if (hipStreamCreate(&ctx->stream) != hipSuccess) {
        delete ctx;
        return false;
    }

    ctx->initialized = true;
    provider->context = ctx;

    if (result) {
        result->provider_name = "hip";
        result->device_name = ctx->props.name;
        result->device_arch = ctx->props.gcnArchName;
        result->pci_domain = ctx->props.pciDomainID;
        result->pci_bus = ctx->props.pciBusID;
        result->pci_device = ctx->props.pciDeviceID;
        result->pci_function = 0;
        result->memory_total = ctx->props.totalGlobalMem;
        result->memory_free = ctx->props.totalGlobalMem;
        // Import is currently brokered for Vulkan-exported OPAQUE_FD handles.
        result->supports_external_memory = 1;
        result->supports_dma_buf_import = 1;
    }

    return true;
#else
    (void)provider;
    (void)result;
    return false;
#endif
#else
    (void)provider;
    (void)result;
    return false;
#endif
}

static bool ggml_amd_hip_supports_op_impl(struct ggml_amd_provider * provider, const struct ggml_tensor * op) {
    (void)provider;
    if (!op) return false;

    // T640 operations are supported by the HIP backend.
    switch (op->op) {
        case GGML_OP_TILE640_MATMUL:
        case GGML_OP_TILE640_MATMUL_ID:
        case GGML_OP_TILE640_GET_ROWS:
        case GGML_OP_TILE640_DEQUANT:
            return true;
        default:
            break;
    }

    // Other ops: not yet implemented.
    return false;
}

static bool ggml_amd_hip_supports_import_impl(struct ggml_amd_provider * provider, struct ggml_amd_allocation * alloc) {
    (void)provider;
    if (!alloc || alloc->dma_buf_fd < 0) {
        return false;
    }
    if (alloc->domain != GGML_AMD_DOMAIN_IMPORTED_EXTERNAL) {
        return false;
    }
    return alloc->external_handle_kind == GGML_AMD_EXTERNAL_HANDLE_KIND_VULKAN_OPAQUE_FD;
}

static ggml_status ggml_amd_hip_import_allocation_impl(
    struct ggml_amd_provider * provider,
    struct ggml_amd_allocation * alloc,
    struct ggml_amd_import ** out_import) {

#ifdef GGML_AMD_HIP
#ifdef __HIP_PLATFORM_AMD__
    if (!provider || !alloc || !out_import) {
        return GGML_STATUS_FAILED;
    }
    *out_import = nullptr;

    if (alloc->external_handle_kind != GGML_AMD_EXTERNAL_HANDLE_KIND_VULKAN_OPAQUE_FD) {
        return GGML_STATUS_FAILED;
    }
    if (alloc->domain != GGML_AMD_DOMAIN_IMPORTED_EXTERNAL) {
        return GGML_STATUS_FAILED;
    }

    auto ctx = (ggml_amd_hip_context *)provider->context;
    if (!ctx || !ctx->initialized) {
        return GGML_STATUS_FAILED;
    }

    int dup_fd = ggml_amd_allocation_dup_fd(alloc);
    if (dup_fd < 0) {
        return GGML_STATUS_FAILED;
    }

    if (hipSetDevice(ctx->device_id) != hipSuccess) {
        close(dup_fd);
        return GGML_STATUS_FAILED;
    }

    hipExternalMemoryHandleDesc handle_desc = {};
    handle_desc.type = hipExternalMemoryHandleTypeOpaqueFd;
    handle_desc.handle.fd = dup_fd;
    handle_desc.size = alloc->size;

    hipExternalMemory_t external_memory = nullptr;
    if (hipImportExternalMemory(&external_memory, &handle_desc) != hipSuccess) {
        close(dup_fd);
        return GGML_STATUS_FAILED;
    }

    hipExternalMemoryBufferDesc mapped_buffer_desc = {};
    mapped_buffer_desc.size = alloc->size;
    mapped_buffer_desc.offset = 0;
    mapped_buffer_desc.flags = 0;

    void * mapped_ptr = nullptr;
    if (hipExternalMemoryGetMappedBuffer(&mapped_ptr, external_memory, &mapped_buffer_desc) != hipSuccess) {
        (void)hipDestroyExternalMemory(external_memory);
        close(dup_fd);
        return GGML_STATUS_FAILED;
    }
    (void)mapped_ptr;
    close(dup_fd);

    auto import = new ggml_amd_import();
    import->allocation = alloc;
    import->provider = provider;
    import->native_handle = external_memory;
    import->ref_count = 1;
    ggml_amd_allocation_retain(alloc);

    *out_import = import;
    return GGML_STATUS_SUCCESS;
#else
    (void)provider;
    (void)alloc;
    (void)out_import;
    return GGML_STATUS_FAILED;
#endif
#else
    (void)provider;
    (void)alloc;
    (void)out_import;
    return GGML_STATUS_FAILED;
#endif
}

static void ggml_amd_hip_release_import_impl(struct ggml_amd_provider * provider, struct ggml_amd_import * import) {
    if (!import) {
        return;
    }

#ifdef __HIP_PLATFORM_AMD__
    auto ctx = ggml_amd_hip_context_get(provider);
    if (ctx && import->native_handle && hipSetDevice(ctx->device_id) == hipSuccess) {
        (void)hipDestroyExternalMemory((hipExternalMemory_t)import->native_handle);
    }
#else
    (void)provider;
#endif

    ggml_amd_allocation_release(import->allocation);
    delete import;
}

static ggml_status ggml_amd_hip_submit_region_impl(
    struct ggml_amd_provider * provider,
    struct ggml_amd_region * region,
    struct ggml_amd_fence * fence) {

#ifdef GGML_AMD_HIP
#ifdef __HIP_PLATFORM_AMD__
    if (!provider || !region || !fence) {
        return GGML_STATUS_FAILED;
    }

    auto ctx = (ggml_amd_hip_context *)provider->context;
    if (!ctx || !ctx->initialized) {
        return GGML_STATUS_FAILED;
    }

    if (!region->graph || region->node_start < 0 || region->node_end < region->node_start || region->node_end >= region->graph->n_nodes) {
        return GGML_STATUS_FAILED;
    }

    for (int i = region->node_start; i <= region->node_end; ++i) {
        const struct ggml_tensor * node = region->graph->nodes[i];
        if (!node || !ggml_amd_hip_supports_op_impl(provider, node)) {
            return GGML_STATUS_FAILED;
        }
    }

    auto region_graph = ggml_graph_view(region->graph, region->node_start, region->node_end + 1);
    ggml_status status = ggml_amd_hip_graph_compute(provider, &region_graph);
    if (status != GGML_STATUS_SUCCESS) {
        return GGML_STATUS_FAILED;
    }

    if (fence) {
        *fence = ggml_amd_fence_create_host();
    }

    return GGML_STATUS_SUCCESS;
#else
    (void)provider;
    (void)region;
    (void)fence;
    return GGML_STATUS_FAILED;
#endif
#else
    (void)provider;
    (void)region;
    (void)fence;
    return GGML_STATUS_FAILED;
#endif
}

static ggml_status ggml_amd_hip_wait_fence_impl(struct ggml_amd_provider * provider, struct ggml_amd_fence * fence) {
#ifdef GGML_AMD_HIP
#ifdef __HIP_PLATFORM_AMD__
    if (!fence || fence->kind != GGML_AMD_FENCE_HIP_EVENT) {
        return GGML_STATUS_FAILED;
    }

    hipEvent_t event = (hipEvent_t)fence->hip_event;
    if (!event) {
        return GGML_STATUS_FAILED;
    }

    if (hipEventSynchronize(event) != hipSuccess) {
        return GGML_STATUS_FAILED;
    }

    (void)hipEventDestroy(event);
    fence->kind = GGML_AMD_FENCE_NONE;
    return GGML_STATUS_SUCCESS;
#else
    (void)provider;
    (void)fence;
    return GGML_STATUS_FAILED;
#endif
#else
    (void)provider;
    (void)fence;
    return GGML_STATUS_FAILED;
#endif
}

static void ggml_amd_hip_query_memory_impl(struct ggml_amd_provider * provider, struct ggml_amd_memory_info * info) {
#ifdef GGML_AMD_HIP
#ifdef __HIP_PLATFORM_AMD__
    if (!provider || !info) {
        return;
    }

    auto ctx = (ggml_amd_hip_context *)provider->context;
    if (!ctx || !ctx->initialized) {
        return;
    }

    size_t free_mem, total_mem;
    if (hipMemGetInfo(&free_mem, &total_mem) == hipSuccess) {
        info->total_bytes = total_mem;
        info->free_bytes = free_mem;
        info->resident_bytes = 0;
        info->imported_bytes = 0;
    }
#else
    (void)provider;
    (void)info;
#endif
#else
    (void)provider;
    (void)info;
#endif
}

static const struct ggml_amd_provider_i ggml_amd_hip_provider_i = {
    .name = "hip",
    .probe = ggml_amd_hip_probe_impl,
    .supports_op = ggml_amd_hip_supports_op_impl,
    .supports_import = ggml_amd_hip_supports_import_impl,
    .import_allocation = ggml_amd_hip_import_allocation_impl,
    .release_import = ggml_amd_hip_release_import_impl,
    .submit_region = ggml_amd_hip_submit_region_impl,
    .wait_fence = ggml_amd_hip_wait_fence_impl,
    .query_memory = ggml_amd_hip_query_memory_impl,
};

bool ggml_amd_hip_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    provider->iface = &ggml_amd_hip_provider_i;
    return ggml_amd_hip_probe_impl(provider, result);
}

// ============================================================================
// T640 op dispatch (standalone, for testing and future integration)
// ============================================================================
//
// These functions dispatch a single T640 operation on the HIP stream.
// They are intended for testing the kernel implementations and for future
// integration with the ggml_backend compute path.
//

#ifdef __HIP_PLATFORM_AMD__

static ggml_amd_hip_context * ggml_amd_hip_get_context(struct ggml_amd_provider * provider) {
    if (!provider || !provider->context) return nullptr;
    auto ctx = (ggml_amd_hip_context *) provider->context;
    return ctx->initialized ? ctx : nullptr;
}

ggml_status ggml_amd_hip_compute_tile640_dequant(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst) {

    auto ctx = ggml_amd_hip_get_context(provider);
    if (!ctx) return GGML_STATUS_FAILED;

    // src[0..5] = packed, page_scales, lane_scales, outlier_row_offsets, outlier_cols, outlier_vals
    const int64_t row_width = dst->ne[0];
    const int64_t n_rows = ggml_nelements(dst) / row_width;

    ggml_amd_hip_tile640_dequant(
        ctx->stream,
        dst->src[0]->data,
        dst->src[1]->data,
        dst->src[2]->data,
        dst->src[3]->data,
        dst->src[4]->data,
        dst->src[5]->data,
        dst->data,
        (int) row_width,
        (int) n_rows);

    // Tessera Layer 1: dump the dequantized weight to the sidecar.
    ggml_amd_hip_dump_dequant_tile640(ctx->stream, dst, row_width, n_rows,
                                       dst->src[0] ? dst->src[0]->name : "tile640_dequant");

    return GGML_STATUS_SUCCESS;
}

ggml_status ggml_amd_hip_compute_tile640_matmul(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst) {

    auto ctx = ggml_amd_hip_get_context(provider);
    if (!ctx) return GGML_STATUS_FAILED;

    // src[0..5] = A components, src[6] = B
    const int32_t out_dim = ggml_get_op_params_i32(dst, 0);
    const int64_t in_dim  = dst->src[6]->ne[0];
    const int64_t n_tokens = dst->src[6]->ne[1];
    const int64_t n_batch  = dst->src[6]->ne[2];
    const int64_t n_seqs   = dst->src[6]->ne[3];

    // Tessera Layer 1: dump the dequantized weight before the matmul.
    ggml_amd_hip_dump_dequant_tile640(ctx->stream, dst, in_dim, out_dim,
                                       dst->src[0] ? dst->src[0]->name : "tile640_matmul");

    ggml_amd_hip_tile640_matmul(
        ctx->stream,
        dst->src[0]->data,
        dst->src[1]->data,
        dst->src[2]->data,
        dst->src[3]->data,
        dst->src[4]->data,
        dst->src[5]->data,
        dst->src[6]->data,
        dst->data,
        out_dim, (int) in_dim, (int) n_tokens, (int) n_batch, (int) n_seqs);

    return GGML_STATUS_SUCCESS;
}

ggml_status ggml_amd_hip_compute_tile640_matmul_id(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst) {

    auto ctx = ggml_amd_hip_get_context(provider);
    if (!ctx) return GGML_STATUS_FAILED;

    // src[0..5] = A components, src[6] = B, src[7] = ids, src[8] = act_scale (optional)
    const int32_t n_experts = ggml_get_op_params_i32(dst, 0);
    const int32_t out_dim   = ggml_get_op_params_i32(dst, 1);
    const int64_t in_dim    = dst->src[6]->ne[0];
    const int64_t n_broadcast = dst->src[6]->ne[1];
    const int64_t n_tokens    = dst->src[6]->ne[2];
    const int64_t n_expert_used = dst->src[7]->ne[0];

    int act_scale_kind = 0;
    if (dst->src[8] != nullptr) {
        const int64_t n_act_el = ggml_nelements(dst->src[8]);
        if (n_act_el == in_dim) {
            act_scale_kind = 1;
        } else if (n_act_el == in_dim * n_experts) {
            act_scale_kind = 2;
        }
    }

    // Tessera Layer 1: dump the dequantized weight (all experts).
    ggml_amd_hip_dump_dequant_tile640(ctx->stream, dst, in_dim,
                                       (int64_t) n_experts * out_dim,
                                       dst->src[0] ? dst->src[0]->name : "tile640_matmul_id");

    ggml_amd_hip_tile640_matmul_id(
        ctx->stream,
        dst->src[0]->data,
        dst->src[1]->data,
        dst->src[2]->data,
        dst->src[3]->data,
        dst->src[4]->data,
        dst->src[5]->data,
        dst->src[6]->data,
        dst->src[7]->data,
        dst->src[8] ? dst->src[8]->data : nullptr,
        dst->data,
        n_experts, out_dim, (int) in_dim, (int) n_broadcast,
        (int) n_tokens, (int) n_expert_used, act_scale_kind);

    return GGML_STATUS_SUCCESS;
}

ggml_status ggml_amd_hip_compute_tile640_get_rows(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst) {

    auto ctx = ggml_amd_hip_get_context(provider);
    if (!ctx) return GGML_STATUS_FAILED;

    // src[0..5] = packed components, src[6] = ids
    const int64_t row_width = ggml_get_op_params_i32(dst, 0);
    const int64_t n_ids = ggml_nelements(dst->src[6]);
    const int64_t n_rows = dst->src[3]->ne[0] - 1; // outlier_row_offsets has n_rows + 1 elements

    ggml_amd_hip_tile640_get_rows(
        ctx->stream,
        dst->src[0]->data,
        dst->src[1]->data,
        dst->src[2]->data,
        dst->src[3]->data,
        dst->src[4]->data,
        dst->src[5]->data,
        dst->src[6]->data,
        dst->data,
        (int) row_width,
        (int) n_rows,
        (int) n_ids);

    return GGML_STATUS_SUCCESS;
}

extern bool ggml_amd_buffer_is_hip_device_tensor(const struct ggml_tensor * tensor);

ggml_status ggml_amd_hip_graph_compute(struct ggml_amd_provider * provider, struct ggml_cgraph * graph) {
    if (!ggml_amd_hip_context_get(provider) || !graph) {
        return GGML_STATUS_FAILED;
    }

    for (int i = 0; i < graph->n_nodes; ++i) {
        struct ggml_tensor * node = graph->nodes[i];
        if (!node || !ggml_amd_hip_supports_op_impl(provider, node) || !ggml_amd_buffer_is_hip_device_tensor(node)) {
            return GGML_STATUS_FAILED;
        }

        for (int j = 0; j < GGML_MAX_SRC && node->src[j]; ++j) {
            if (!ggml_amd_buffer_is_hip_device_tensor(node->src[j])) {
                return GGML_STATUS_FAILED;
            }
        }

        ggml_status status = GGML_STATUS_FAILED;
        switch (node->op) {
            case GGML_OP_TILE640_DEQUANT:
                status = ggml_amd_hip_compute_tile640_dequant(provider, node);
                break;
            case GGML_OP_TILE640_MATMUL:
                status = ggml_amd_hip_compute_tile640_matmul(provider, node);
                break;
            case GGML_OP_TILE640_MATMUL_ID:
                status = ggml_amd_hip_compute_tile640_matmul_id(provider, node);
                break;
            case GGML_OP_TILE640_GET_ROWS:
                status = ggml_amd_hip_compute_tile640_get_rows(provider, node);
                break;
            default:
                return GGML_STATUS_FAILED;
        }

        if (status != GGML_STATUS_SUCCESS || hipGetLastError() != hipSuccess) {
            return GGML_STATUS_FAILED;
        }
    }

    return ggml_amd_hip_synchronize(provider) ? GGML_STATUS_SUCCESS : GGML_STATUS_FAILED;
}

#endif // __HIP_PLATFORM_AMD__

#else

bool ggml_amd_hip_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}

ggml_status ggml_amd_hip_graph_compute(struct ggml_amd_provider * provider, struct ggml_cgraph * graph) {
    (void)provider;
    (void)graph;
    return GGML_STATUS_FAILED;
}

#endif
