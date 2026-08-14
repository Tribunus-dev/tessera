#ifndef GGML_AMD_PROVIDER_H
#define GGML_AMD_PROVIDER_H

#include "ggml-amd-types.h"
#include "ggml.h"

#ifdef __cplusplus
extern "C" {
#endif

struct ggml_amd_probe_result {
    const char * provider_name;
    const char * device_name;
    const char * device_arch;
    int pci_domain;
    int pci_bus;
    int pci_device;
    int pci_function;
    size_t memory_total;
    size_t memory_free;
    int supports_external_memory;
    int supports_dma_buf_import;
};

struct ggml_amd_memory_info {
    size_t total_bytes;
    size_t free_bytes;
    size_t resident_bytes;
    size_t imported_bytes;
};

struct ggml_amd_provider_i {
    const char * name;
    bool (*probe)(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result);
    bool (*supports_op)(struct ggml_amd_provider * provider, const struct ggml_tensor * op);
    bool (*supports_import)(struct ggml_amd_provider * provider, struct ggml_amd_allocation * alloc);
    ggml_status (*import_allocation)(struct ggml_amd_provider * provider, struct ggml_amd_allocation * alloc, struct ggml_amd_import ** out_import);
    void (*release_import)(struct ggml_amd_provider * provider, struct ggml_amd_import * import);
    ggml_status (*submit_region)(struct ggml_amd_provider * provider, struct ggml_amd_region * region, struct ggml_amd_fence * fence);
    ggml_status (*wait_fence)(struct ggml_amd_provider * provider, struct ggml_amd_fence * fence);
    void (*query_memory)(struct ggml_amd_provider * provider, struct ggml_amd_memory_info * info);
};

struct ggml_amd_provider {
    const struct ggml_amd_provider_i * iface;
    void * context;
    int device_index;
    enum ggml_amd_device_type device_type;
};

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_PROVIDER_H
