#include "../ggml-amd-internal.h"
#include "ggml.h"

#include <unordered_map>
#include <string>
#include <vector>
#include <mutex>

struct ggml_amd_xdna_cache_entry {
    std::string key;
    std::vector<uint8_t> compiled_binary;
    size_t size_bytes;
};

struct ggml_amd_xdna_cache {
    std::unordered_map<std::string, ggml_amd_xdna_cache_entry> entries;
    std::mutex mutex;
    size_t max_size_bytes;
    size_t current_size_bytes;
};

struct ggml_amd_xdna_cache * ggml_amd_xdna_cache_create(size_t max_size_bytes) {
    auto cache = new ggml_amd_xdna_cache();
    cache->max_size_bytes = max_size_bytes;
    cache->current_size_bytes = 0;
    return cache;
}

void ggml_amd_xdna_cache_destroy(struct ggml_amd_xdna_cache * cache) {
    delete cache;
}

bool ggml_amd_xdna_cache_lookup(
    struct ggml_amd_xdna_cache * cache,
    const char * key,
    std::vector<uint8_t> * out_binary) {

    if (!cache || !key || !out_binary) {
        return false;
    }

    std::lock_guard<std::mutex> lock(cache->mutex);
    auto it = cache->entries.find(key);
    if (it == cache->entries.end()) {
        return false;
    }

    *out_binary = it->second.compiled_binary;
    return true;
}

void ggml_amd_xdna_cache_insert(
    struct ggml_amd_xdna_cache * cache,
    const char * key,
    const std::vector<uint8_t> & binary) {

    if (!cache || !key) {
        return;
    }

    std::lock_guard<std::mutex> lock(cache->mutex);
    ggml_amd_xdna_cache_entry entry;
    entry.key = key;
    entry.compiled_binary = binary;
    entry.size_bytes = binary.size();

    cache->entries[key] = entry;
    cache->current_size_bytes += entry.size_bytes;
}
