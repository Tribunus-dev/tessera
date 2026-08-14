#include "ggml-amd-internal.h"
#include "ggml.h"

#include <unordered_map>
#include <string>
#include <vector>
#include <list>
#include <mutex>
#include <cstdio>
#include <cstring>

struct ggml_amd_packing_key {
    std::string model_content_hash;
    std::string tensor_namespace;
    std::string tensor_name;
    int neutral_schema_version;
    std::string provider_name;
    std::string provider_abi;
    std::string device_architecture;
    std::string packing_algorithm_version;
    std::string compiler_version;

    bool operator==(const ggml_amd_packing_key & other) const {
        return model_content_hash == other.model_content_hash &&
               tensor_namespace == other.tensor_namespace &&
               tensor_name == other.tensor_name &&
               neutral_schema_version == other.neutral_schema_version &&
               provider_name == other.provider_name &&
               provider_abi == other.provider_abi &&
               device_architecture == other.device_architecture &&
               packing_algorithm_version == other.packing_algorithm_version &&
               compiler_version == other.compiler_version;
    }
};

struct ggml_amd_packing_key_hash {
    size_t operator()(const ggml_amd_packing_key & key) const {
        size_t h = 0;
        h ^= std::hash<std::string>{}(key.model_content_hash) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.tensor_namespace) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.tensor_name) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<int>{}(key.neutral_schema_version) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.provider_name) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.provider_abi) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.device_architecture) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.packing_algorithm_version) + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= std::hash<std::string>{}(key.compiler_version) + 0x9e3779b9 + (h << 6) + (h >> 2);
        return h;
    }
};

struct ggml_amd_packing_entry {
    ggml_amd_packing_key key;
    std::vector<uint8_t> packed_data;
    size_t size_bytes;
    int64_t last_access_time;
    bool valid;
};

struct ggml_amd_packing_cache {
    std::unordered_map<ggml_amd_packing_key, std::list<ggml_amd_packing_entry>::iterator, ggml_amd_packing_key_hash> index;
    std::list<ggml_amd_packing_entry> lru_list;
    std::mutex mutex;
    size_t max_size_bytes;
    size_t current_size_bytes;
    int64_t access_counter;
    size_t hits;
    size_t misses;
};

struct ggml_amd_packing_cache * ggml_amd_packing_cache_create(size_t max_size_bytes) {
    auto cache = new ggml_amd_packing_cache();
    cache->max_size_bytes = max_size_bytes;
    cache->current_size_bytes = 0;
    cache->access_counter = 0;
    cache->hits = 0;
    cache->misses = 0;
    return cache;
}

void ggml_amd_packing_cache_destroy(struct ggml_amd_packing_cache * cache) {
    delete cache;
}

static void ggml_amd_packing_cache_evict_lru(struct ggml_amd_packing_cache * cache) {
    if (cache->lru_list.empty()) {
        return;
    }

    auto & oldest = cache->lru_list.back();
    cache->index.erase(oldest.key);
    cache->current_size_bytes -= oldest.size_bytes;
    cache->lru_list.pop_back();
}

bool ggml_amd_packing_cache_lookup(
    struct ggml_amd_packing_cache * cache,
    const struct ggml_amd_packing_key * key,
    std::vector<uint8_t> * out_data) {

    if (!cache || !key || !out_data) {
        return false;
    }

    std::lock_guard<std::mutex> lock(cache->mutex);

    auto it = cache->index.find(*key);
    if (it == cache->index.end()) {
        cache->misses++;
        return false;
    }

    auto list_it = it->second;
    if (!list_it->valid) {
        cache->misses++;
        return false;
    }

    *out_data = list_it->packed_data;
    list_it->last_access_time = cache->access_counter++;

    cache->lru_list.splice(cache->lru_list.begin(), cache->lru_list, list_it);
    cache->hits++;

    return true;
}

void ggml_amd_packing_cache_insert(
    struct ggml_amd_packing_cache * cache,
    const struct ggml_amd_packing_key * key,
    const std::vector<uint8_t> & data) {

    if (!cache || !key) {
        return;
    }

    std::lock_guard<std::mutex> lock(cache->mutex);

    auto it = cache->index.find(*key);
    if (it != cache->index.end()) {
        auto list_it = it->second;
        cache->current_size_bytes -= list_it->size_bytes;
        cache->lru_list.erase(list_it);
        cache->index.erase(it);
    }

    while (cache->current_size_bytes + data.size() > cache->max_size_bytes && !cache->lru_list.empty()) {
        ggml_amd_packing_cache_evict_lru(cache);
    }

    ggml_amd_packing_entry entry;
    entry.key = *key;
    entry.packed_data = data;
    entry.size_bytes = data.size();
    entry.last_access_time = cache->access_counter++;
    entry.valid = true;

    cache->lru_list.push_front(entry);
    cache->index[*key] = cache->lru_list.begin();
    cache->current_size_bytes += data.size();
}

void ggml_amd_packing_cache_invalidate(
    struct ggml_amd_packing_cache * cache,
    const struct ggml_amd_packing_key * key) {

    if (!cache || !key) {
        return;
    }

    std::lock_guard<std::mutex> lock(cache->mutex);

    auto it = cache->index.find(*key);
    if (it != cache->index.end()) {
        auto list_it = it->second;
        cache->current_size_bytes -= list_it->size_bytes;
        cache->lru_list.erase(list_it);
        cache->index.erase(it);
    }
}

void ggml_amd_packing_cache_get_stats(
    struct ggml_amd_packing_cache * cache,
    size_t * out_hits,
    size_t * out_misses,
    size_t * out_current_size) {

    if (!cache) {
        return;
    }

    std::lock_guard<std::mutex> lock(cache->mutex);
    if (out_hits) *out_hits = cache->hits;
    if (out_misses) *out_misses = cache->misses;
    if (out_current_size) *out_current_size = cache->current_size_bytes;
}
