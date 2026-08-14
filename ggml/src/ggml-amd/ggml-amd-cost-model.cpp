#include "ggml-amd-internal.h"
#include "ggml.h"

#include <unordered_map>
#include <string>
#include <mutex>
#include <chrono>

struct ggml_amd_cost_key {
    std::string device_fingerprint;
    std::string provider_abi;
    std::string region_signature;
    std::string shape_bucket;
    std::string datatype_signature;
    std::string packing_version;
    enum ggml_amd_phase phase;
};

struct ggml_amd_cost_entry {
    double execution_time_us;
    double queue_time_us;
    double fence_time_us;
    double import_time_us;
    double copy_time_us;
    double compile_time_us;
    double packing_time_us;
    double eviction_time_us;
    int sample_count;
};

struct ggml_amd_cost_model {
    std::unordered_map<std::string, ggml_amd_cost_entry> cache;
    std::mutex mutex;
};

static std::string ggml_amd_cost_key_to_string(const struct ggml_amd_cost_key * key) {
    std::string result;
    result += key->device_fingerprint + "|";
    result += key->provider_abi + "|";
    result += key->region_signature + "|";
    result += key->shape_bucket + "|";
    result += key->datatype_signature + "|";
    result += key->packing_version + "|";
    result += std::to_string((int)key->phase);
    return result;
}

struct ggml_amd_cost_model * ggml_amd_cost_model_create(void) {
    return new ggml_amd_cost_model();
}

void ggml_amd_cost_model_destroy(struct ggml_amd_cost_model * model) {
    delete model;
}

double ggml_amd_cost_model_estimate(struct ggml_amd_cost_model * model, const struct ggml_amd_cost_key * key) {
    if (!model || !key) {
        return 1e9;
    }

    std::lock_guard<std::mutex> lock(model->mutex);
    std::string key_str = ggml_amd_cost_key_to_string(key);

    auto it = model->cache.find(key_str);
    if (it == model->cache.end()) {
        return 1e9;
    }

    const auto & entry = it->second;
    double total = entry.execution_time_us +
                   entry.queue_time_us +
                   entry.fence_time_us +
                   entry.import_time_us +
                   entry.copy_time_us +
                   entry.compile_time_us +
                   entry.packing_time_us +
                   entry.eviction_time_us;

    return total;
}

void ggml_amd_cost_model_update(struct ggml_amd_cost_model * model, const struct ggml_amd_cost_key * key,
                                double execution_us, double queue_us, double fence_us,
                                double import_us, double copy_us, double compile_us,
                                double packing_us, double eviction_us) {
    if (!model || !key) {
        return;
    }

    std::lock_guard<std::mutex> lock(model->mutex);
    std::string key_str = ggml_amd_cost_key_to_string(key);

    auto it = model->cache.find(key_str);
    if (it == model->cache.end()) {
        ggml_amd_cost_entry entry;
        entry.execution_time_us = execution_us;
        entry.queue_time_us = queue_us;
        entry.fence_time_us = fence_us;
        entry.import_time_us = import_us;
        entry.copy_time_us = copy_us;
        entry.compile_time_us = compile_us;
        entry.packing_time_us = packing_us;
        entry.eviction_time_us = eviction_us;
        entry.sample_count = 1;
        model->cache[key_str] = entry;
    } else {
        auto & entry = it->second;
        entry.sample_count++;
        double alpha = 1.0 / entry.sample_count;
        entry.execution_time_us = (1.0 - alpha) * entry.execution_time_us + alpha * execution_us;
        entry.queue_time_us = (1.0 - alpha) * entry.queue_time_us + alpha * queue_us;
        entry.fence_time_us = (1.0 - alpha) * entry.fence_time_us + alpha * fence_us;
        entry.import_time_us = (1.0 - alpha) * entry.import_time_us + alpha * import_us;
        entry.copy_time_us = (1.0 - alpha) * entry.copy_time_us + alpha * copy_us;
        entry.compile_time_us = (1.0 - alpha) * entry.compile_time_us + alpha * compile_us;
        entry.packing_time_us = (1.0 - alpha) * entry.packing_time_us + alpha * packing_us;
        entry.eviction_time_us = (1.0 - alpha) * entry.eviction_time_us + alpha * eviction_us;
    }
}
