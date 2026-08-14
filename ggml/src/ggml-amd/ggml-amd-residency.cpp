#include "ggml-amd-internal.h"
#include "ggml.h"

#include <unordered_map>
#include <string>
#include <vector>
#include <mutex>

struct ggml_amd_residency_entry {
    struct ggml_amd_allocation * allocation;
    struct ggml_amd_provider * provider;
    int64_t last_used_iter;
    size_t size_bytes;
    bool is_pinned;
};

struct ggml_amd_residency_manager {
    std::unordered_map<std::string, ggml_amd_residency_entry> entries;
    std::mutex mutex;
    size_t total_resident_bytes;
    size_t max_resident_bytes;
};

struct ggml_amd_residency_manager * ggml_amd_residency_manager_create(size_t max_resident_bytes) {
    auto mgr = new ggml_amd_residency_manager();
    mgr->total_resident_bytes = 0;
    mgr->max_resident_bytes = max_resident_bytes;
    return mgr;
}

void ggml_amd_residency_manager_destroy(struct ggml_amd_residency_manager * mgr) {
    delete mgr;
}

void ggml_amd_residency_manager_register(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name,
    struct ggml_amd_allocation * allocation,
    struct ggml_amd_provider * provider,
    size_t size_bytes) {

    if (!mgr || !tensor_name || !allocation) {
        return;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);
    std::string key(tensor_name);

    if (mgr->entries.find(key) != mgr->entries.end()) {
        return;
    }

    ggml_amd_residency_entry entry;
    entry.allocation = allocation;
    entry.provider = provider;
    entry.last_used_iter = 0;
    entry.size_bytes = size_bytes;
    entry.is_pinned = false;

    mgr->entries[key] = entry;
    mgr->total_resident_bytes += size_bytes;
}

void ggml_amd_residency_manager_mark_used(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name,
    int64_t iter) {

    if (!mgr || !tensor_name) {
        return;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);
    std::string key(tensor_name);

    auto it = mgr->entries.find(key);
    if (it != mgr->entries.end()) {
        it->second.last_used_iter = iter;
    }
}

struct ggml_amd_residency_suggestion {
    std::string tensor_name;
    struct ggml_amd_allocation * allocation;
    struct ggml_amd_provider * provider;
    size_t size_bytes;
};

std::vector<ggml_amd_residency_suggestion> ggml_amd_residency_manager_suggest_evictions(
    struct ggml_amd_residency_manager * mgr,
    int64_t current_iter,
    int64_t idle_threshold) {

    std::vector<ggml_amd_residency_suggestion> suggestions;

    if (!mgr) {
        return suggestions;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);

    for (const auto & pair : mgr->entries) {
        const auto & entry = pair.second;
        if (entry.is_pinned) {
            continue;
        }
        if (current_iter - entry.last_used_iter >= idle_threshold) {
            ggml_amd_residency_suggestion suggestion;
            suggestion.tensor_name = pair.first;
            suggestion.allocation = entry.allocation;
            suggestion.provider = entry.provider;
            suggestion.size_bytes = entry.size_bytes;
            suggestions.push_back(suggestion);
        }
    }

    return suggestions;
}

void ggml_amd_residency_manager_evict(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name) {

    if (!mgr || !tensor_name) {
        return;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);
    std::string key(tensor_name);

    auto it = mgr->entries.find(key);
    if (it != mgr->entries.end()) {
        mgr->total_resident_bytes -= it->second.size_bytes;
        mgr->entries.erase(it);
    }
}

void ggml_amd_residency_manager_pin(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name) {

    if (!mgr || !tensor_name) {
        return;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);
    std::string key(tensor_name);

    auto it = mgr->entries.find(key);
    if (it != mgr->entries.end()) {
        it->second.is_pinned = true;
    }
}

void ggml_amd_residency_manager_unpin(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name) {

    if (!mgr || !tensor_name) {
        return;
    }

    std::lock_guard<std::mutex> lock(mgr->mutex);
    std::string key(tensor_name);

    auto it = mgr->entries.find(key);
    if (it != mgr->entries.end()) {
        it->second.is_pinned = false;
    }
}

size_t ggml_amd_residency_manager_get_resident_bytes(struct ggml_amd_residency_manager * mgr) {
    if (!mgr) {
        return 0;
    }
    std::lock_guard<std::mutex> lock(mgr->mutex);
    return mgr->total_resident_bytes;
}
