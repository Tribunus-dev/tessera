#include "ggml-amd-internal.h"
#include "ggml.h"

#include <cstring>

#ifdef GGML_AMD_HIP
extern bool ggml_amd_hip_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result);
#else
static bool ggml_amd_hip_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}
#endif

#ifdef GGML_AMD_VULKAN
extern bool ggml_amd_vulkan_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result);
#else
static bool ggml_amd_vulkan_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}
#endif

#ifdef GGML_AMD_ZENDNN
extern bool ggml_amd_zendnn_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result);
#else
static bool ggml_amd_zendnn_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}
#endif

#ifdef GGML_AMD_XDNA
extern bool ggml_amd_xdna_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result);
#else
static bool ggml_amd_xdna_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}
#endif

void ggml_amd_probe_all_providers(struct ggml_amd_reg_context * ctx) {
    struct ggml_amd_probe_result result;
    memset(&result, 0, sizeof(result));

    auto try_provider = [&](const char * name, enum ggml_amd_device_type type,
                           bool (*probe_fn)(struct ggml_amd_provider *, struct ggml_amd_probe_result *)) {
        auto provider = std::make_unique<ggml_amd_provider>();
        provider->device_type = type;
        provider->device_index = (int)ctx->providers.size();

        if (probe_fn(provider.get(), &result)) {
            ctx->providers.push_back(std::move(provider));
        }
    };

    try_provider("hip", GGML_AMD_DEVICE_IGPU, ggml_amd_hip_probe);
    try_provider("vulkan", GGML_AMD_DEVICE_IGPU, ggml_amd_vulkan_probe);
    try_provider("zendnn", GGML_AMD_DEVICE_CPU, ggml_amd_zendnn_probe);
    try_provider("xdna", GGML_AMD_DEVICE_NPU, ggml_amd_xdna_probe);
}
