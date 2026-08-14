#include "ggml-amd-internal.h"
#include "ggml.h"

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>

enum ggml_amd_tier {
    GGML_AMD_TIER_SYSTEM,
    GGML_AMD_TIER_VRAM,
    GGML_AMD_TIER_NPU,
};

struct ggml_amd_tiered_memory_policy {
    enum ggml_amd_tier preferred_tier;
    size_t vram_budget_bytes;
    size_t system_budget_bytes;
    bool allow_eviction;
    bool async_prefetch;
};

struct ggml_amd_tiered_memory_manager {
    struct ggml_amd_tiered_memory_policy uma_policy;
    struct ggml_amd_tiered_memory_policy discrete_policy;
    struct ggml_amd_tiered_memory_policy npu_policy;
    std::unordered_map<std::string, enum ggml_amd_tier> tensor_tier;
    std::mutex mutex;
};

struct ggml_amd_tiered_memory_manager * ggml_amd_tiered_memory_create(void) {
    auto mgr = new ggml_amd_tiered_memory_manager();

    mgr->uma_policy.preferred_tier = GGML_AMD_TIER_SYSTEM;
    mgr->uma_policy.vram_budget_bytes = 0;
    mgr->uma_policy.system_budget_bytes = SIZE_MAX;
    mgr->uma_policy.allow_eviction = false;
    mgr->uma_policy.async_prefetch = false;

    mgr->discrete_policy.preferred_tier = GGML_AMD_TIER_VRAM;
    mgr->discrete_policy.vram_budget_bytes = 0;
    mgr->discrete_policy.system_budget_bytes = SIZE_MAX;
    mgr->discrete_policy.allow_eviction = true;
    mgr->discrete_policy.async_prefetch = true;

    mgr->npu_policy.preferred_tier = GGML_AMD_TIER_NPU;
    mgr->npu_policy.vram_budget_bytes = 0;
    mgr->npu_policy.system_budget_bytes = 0;
    mgr->npu_policy.allow_eviction = false;
    mgr->npu_policy.async_prefetch = false;

    return mgr;
}

void ggml_amd_tiered_memory_destroy(struct ggml_amd_tiered_memory_manager * mgr) {
    delete mgr;
}

enum ggml_amd_tier ggml_amd_tiered_memory_select_tier(
    struct ggml_amd_tiered_memory_manager * mgr,
    const char * tensor_name,
    size_t size_bytes,
    bool is_hot_weight,
    bool is_kv_cache) {

    if (!mgr || !tensor_name) {
        return GGML_AMD_TIER_SYSTEM;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);

    auto it = mgr->tensor_tier.find(tensor_name);
    if (it != mgr->tensor_tier.end()) {
        return it->second;
    }

    enum ggml_amd_tier tier;
    if (is_kv_cache) {
        tier = GGML_AMD_TIER_VRAM;
    } else if (is_hot_weight) {
        tier = GGML_AMD_TIER_VRAM;
    } else {
        tier = GGML_AMD_TIER_SYSTEM;
    }

    mgr->tensor_tier[tensor_name] = tier;
    return tier;
}

void ggml_amd_tiered_memory_set_budget(
    struct ggml_amd_tiered_memory_manager * mgr,
    enum ggml_amd_tier tier,
    size_t budget_bytes) {

    if (!mgr) {
        return;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);

    switch (tier) {
        case GGML_AMD_TIER_SYSTEM:
            mgr->discrete_policy.system_budget_bytes = budget_bytes;
            break;
        case GGML_AMD_TIER_VRAM:
            mgr->discrete_policy.vram_budget_bytes = budget_bytes;
            break;
        case GGML_AMD_TIER_NPU:
            mgr->npu_policy.vram_budget_bytes = budget_bytes;
            break;
    }
}

bool ggml_amd_tiered_memory_should_prefetch(
    struct ggml_amd_tiered_memory_manager * mgr,
    const char * tensor_name) {

    if (!mgr || !tensor_name) {
        return false;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);

    auto it = mgr->tensor_tier.find(tensor_name);
    if (it == mgr->tensor_tier.end()) {
        return false;
    }

    return mgr->discrete_policy.async_prefetch && it->second == GGML_AMD_TIER_VRAM;
}

bool ggml_amd_tiered_memory_should_evict(
    struct ggml_amd_tiered_memory_manager * mgr,
    const char * tensor_name,
    size_t current_vram_usage) {

    if (!mgr || !tensor_name) {
        return false;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);

    if (!mgr->discrete_policy.allow_eviction) {
        return false;
    }

    if (current_vram_usage > mgr->discrete_policy.vram_budget_bytes) {
        return true;
    }

    return false;
}
