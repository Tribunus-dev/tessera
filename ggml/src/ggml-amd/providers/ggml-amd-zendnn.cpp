#include "../ggml-amd-internal.h"
#include "../ggml-amd-provider.h"
#include "ggml.h"

#include <cstring>

#ifdef GGML_AMD_ZENDNN

struct ggml_amd_zendnn_context {
    bool initialized;
};

static bool ggml_amd_zendnn_probe_impl(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    auto ctx = new ggml_amd_zendnn_context();
    ctx->initialized = false;

    provider->context = ctx;

    if (result) {
        result->provider_name = "zendnn";
        result->device_name = "AMD ZenDNN";
        result->device_arch = "zen4";
        result->pci_domain = 0;
        result->pci_bus = 0;
        result->pci_device = 0;
        result->pci_function = 0;
        result->memory_total = 0;
        result->memory_free = 0;
        result->supports_external_memory = 0;
        result->supports_dma_buf_import = 0;
    }

    return false;
}

static bool ggml_amd_zendnn_supports_op_impl(struct ggml_amd_provider * provider, const struct ggml_tensor * op) {
    (void)provider;
    (void)op;
    return false;
}

static bool ggml_amd_zendnn_supports_import_impl(struct ggml_amd_provider * provider, struct ggml_amd_allocation * alloc) {
    (void)provider;
    (void)alloc;
    return false;
}

static ggml_status ggml_amd_zendnn_import_allocation_impl(
    struct ggml_amd_provider * provider,
    struct ggml_amd_allocation * alloc,
    struct ggml_amd_import ** out_import) {
    (void)provider;
    (void)alloc;
    (void)out_import;
    return GGML_STATUS_FAILED;
}

static void ggml_amd_zendnn_release_import_impl(struct ggml_amd_provider * provider, struct ggml_amd_import * import) {
    (void)provider;
    if (import) {
        delete import;
    }
}

static ggml_status ggml_amd_zendnn_submit_region_impl(
    struct ggml_amd_provider * provider,
    struct ggml_amd_region * region,
    struct ggml_amd_fence * fence) {
    (void)provider;
    (void)region;
    (void)fence;
    return GGML_STATUS_FAILED;
}

static ggml_status ggml_amd_zendnn_wait_fence_impl(struct ggml_amd_provider * provider, struct ggml_amd_fence * fence) {
    (void)provider;
    (void)fence;
    return GGML_STATUS_FAILED;
}

static void ggml_amd_zendnn_query_memory_impl(struct ggml_amd_provider * provider, struct ggml_amd_memory_info * info) {
    (void)provider;
    if (info) {
        info->total_bytes = 0;
        info->free_bytes = 0;
        info->resident_bytes = 0;
        info->imported_bytes = 0;
    }
}

static const struct ggml_amd_provider_i ggml_amd_zendnn_provider_i = {
    .name = "zendnn",
    .probe = ggml_amd_zendnn_probe_impl,
    .supports_op = ggml_amd_zendnn_supports_op_impl,
    .supports_import = ggml_amd_zendnn_supports_import_impl,
    .import_allocation = ggml_amd_zendnn_import_allocation_impl,
    .release_import = ggml_amd_zendnn_release_import_impl,
    .submit_region = ggml_amd_zendnn_submit_region_impl,
    .wait_fence = ggml_amd_zendnn_wait_fence_impl,
    .query_memory = ggml_amd_zendnn_query_memory_impl,
};

bool ggml_amd_zendnn_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    provider->iface = &ggml_amd_zendnn_provider_i;
    return ggml_amd_zendnn_probe_impl(provider, result);
}

#else

bool ggml_amd_zendnn_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}

#endif
