// test-amd-packing-cache.cpp
//
// Test packing cache (pure logic, no hardware).
//
// What this exercises:
//  1. ggml_amd_packing_cache_create() with size limit
//  2. insert and lookup
//  3. LRU eviction when cache is full
//  4. cache invalidation
//  5. cache stats (hits/misses)
//  6. key matching (all fields must match)

#include "ggml.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

// Internal API declarations (from ggml-amd-cache.cpp)
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

    bool operator==(const ggml_amd_packing_key & other) const;
};

struct ggml_amd_packing_cache;

struct ggml_amd_packing_cache * ggml_amd_packing_cache_create(size_t max_size_bytes);
void ggml_amd_packing_cache_destroy(struct ggml_amd_packing_cache * cache);

bool ggml_amd_packing_cache_lookup(
    struct ggml_amd_packing_cache * cache,
    const struct ggml_amd_packing_key * key,
    std::vector<uint8_t> * out_data);

void ggml_amd_packing_cache_insert(
    struct ggml_amd_packing_cache * cache,
    const struct ggml_amd_packing_key * key,
    const std::vector<uint8_t> & data);

void ggml_amd_packing_cache_invalidate(
    struct ggml_amd_packing_cache * cache,
    const struct ggml_amd_packing_key * key);

void ggml_amd_packing_cache_get_stats(
    struct ggml_amd_packing_cache * cache,
    size_t * out_hits,
    size_t * out_misses,
    size_t * out_current_size);

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

static struct ggml_amd_packing_key make_test_key(const char * tensor_name, int version) {
    struct ggml_amd_packing_key key;
    key.model_content_hash = "test-hash";
    key.tensor_namespace = "test-namespace";
    key.tensor_name = tensor_name;
    key.neutral_schema_version = version;
    key.provider_name = "test-provider";
    key.provider_abi = "test-abi";
    key.device_architecture = "test-arch";
    key.packing_algorithm_version = "v1";
    key.compiler_version = "gcc-11";
    return key;
}

static void test_cache_create_destroy(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    CHECK(cache != nullptr, "cache create succeeds");
    ggml_amd_packing_cache_destroy(cache);
    CHECK(true, "cache destroy succeeds");
}

static void test_cache_insert_lookup(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    if (!cache) return;

    struct ggml_amd_packing_key key = make_test_key("tensor.a", 1);
    std::vector<uint8_t> data = {1, 2, 3, 4, 5};

    ggml_amd_packing_cache_insert(cache, &key, data);

    std::vector<uint8_t> out_data;
    bool found = ggml_amd_packing_cache_lookup(cache, &key, &out_data);
    CHECK(found, "lookup finds inserted key");
    CHECK(out_data == data, "lookup returns correct data");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_lookup_miss(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    if (!cache) return;

    struct ggml_amd_packing_key key = make_test_key("tensor.missing", 1);
    std::vector<uint8_t> out_data;
    bool found = ggml_amd_packing_cache_lookup(cache, &key, &out_data);
    CHECK(!found, "lookup misses on non-existent key");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_lru_eviction(void) {
    // Small cache: 100 bytes max
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(100);
    if (!cache) return;

    // Insert 3 entries of 40 bytes each (total 120 > 100)
    struct ggml_amd_packing_key key1 = make_test_key("tensor.1", 1);
    std::vector<uint8_t> data1(40, 1);
    ggml_amd_packing_cache_insert(cache, &key1, data1);

    struct ggml_amd_packing_key key2 = make_test_key("tensor.2", 1);
    std::vector<uint8_t> data2(40, 2);
    ggml_amd_packing_cache_insert(cache, &key2, data2);

    struct ggml_amd_packing_key key3 = make_test_key("tensor.3", 1);
    std::vector<uint8_t> data3(40, 3);
    ggml_amd_packing_cache_insert(cache, &key3, data3);

    // First entry should be evicted (LRU)
    std::vector<uint8_t> out_data;
    bool found1 = ggml_amd_packing_cache_lookup(cache, &key1, &out_data);
    CHECK(!found1, "first entry evicted (LRU)");

    // Second and third should still be present
    bool found2 = ggml_amd_packing_cache_lookup(cache, &key2, &out_data);
    CHECK(found2, "second entry still present");

    bool found3 = ggml_amd_packing_cache_lookup(cache, &key3, &out_data);
    CHECK(found3, "third entry still present");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_invalidate(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    if (!cache) return;

    struct ggml_amd_packing_key key = make_test_key("tensor.invalidate", 1);
    std::vector<uint8_t> data = {10, 20, 30};
    ggml_amd_packing_cache_insert(cache, &key, data);

    // Verify it's there
    std::vector<uint8_t> out_data;
    bool found = ggml_amd_packing_cache_lookup(cache, &key, &out_data);
    CHECK(found, "entry present before invalidation");

    // Invalidate
    ggml_amd_packing_cache_invalidate(cache, &key);

    // Verify it's gone
    found = ggml_amd_packing_cache_lookup(cache, &key, &out_data);
    CHECK(!found, "entry gone after invalidation");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_stats(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    if (!cache) return;

    struct ggml_amd_packing_key key = make_test_key("tensor.stats", 1);
    std::vector<uint8_t> data = {1, 2, 3};

    // Initial stats
    size_t hits, misses, size;
    ggml_amd_packing_cache_get_stats(cache, &hits, &misses, &size);
    CHECK(hits == 0, "initial hits is 0");
    CHECK(misses == 0, "initial misses is 0");
    CHECK(size == 0, "initial size is 0");

    // Insert
    ggml_amd_packing_cache_insert(cache, &key, data);
    ggml_amd_packing_cache_get_stats(cache, &hits, &misses, &size);
    CHECK(size == 3, "size is 3 after insert");

    // Lookup hit
    std::vector<uint8_t> out_data;
    ggml_amd_packing_cache_lookup(cache, &key, &out_data);
    ggml_amd_packing_cache_get_stats(cache, &hits, &misses, &size);
    CHECK(hits == 1, "hits is 1 after lookup hit");

    // Lookup miss
    struct ggml_amd_packing_key key2 = make_test_key("tensor.missing", 1);
    ggml_amd_packing_cache_lookup(cache, &key2, &out_data);
    ggml_amd_packing_cache_get_stats(cache, &hits, &misses, &size);
    CHECK(misses == 1, "misses is 1 after lookup miss");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_key_matching(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    if (!cache) return;

    // Insert with specific key
    struct ggml_amd_packing_key key1 = make_test_key("tensor.match", 1);
    std::vector<uint8_t> data1 = {1, 1, 1};
    ggml_amd_packing_cache_insert(cache, &key1, data1);

    // Lookup with same key
    struct ggml_amd_packing_key key2 = make_test_key("tensor.match", 1);
    std::vector<uint8_t> out_data;
    bool found = ggml_amd_packing_cache_lookup(cache, &key2, &out_data);
    CHECK(found, "lookup with matching key succeeds");

    // Lookup with different tensor_name
    struct ggml_amd_packing_key key3 = make_test_key("tensor.different", 1);
    found = ggml_amd_packing_cache_lookup(cache, &key3, &out_data);
    CHECK(!found, "lookup with different tensor_name misses");

    // Lookup with different version
    struct ggml_amd_packing_key key4 = make_test_key("tensor.match", 2);
    found = ggml_amd_packing_cache_lookup(cache, &key4, &out_data);
    CHECK(!found, "lookup with different version misses");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_update_existing(void) {
    struct ggml_amd_packing_cache * cache = ggml_amd_packing_cache_create(1024 * 1024);
    if (!cache) return;

    struct ggml_amd_packing_key key = make_test_key("tensor.update", 1);
    std::vector<uint8_t> data1 = {1, 2, 3};
    ggml_amd_packing_cache_insert(cache, &key, data1);

    // Update with new data
    std::vector<uint8_t> data2 = {10, 20, 30, 40};
    ggml_amd_packing_cache_insert(cache, &key, data2);

    // Lookup should return new data
    std::vector<uint8_t> out_data;
    bool found = ggml_amd_packing_cache_lookup(cache, &key, &out_data);
    CHECK(found, "lookup finds updated key");
    CHECK(out_data == data2, "lookup returns updated data");

    size_t hits, misses, size;
    ggml_amd_packing_cache_get_stats(cache, &hits, &misses, &size);
    CHECK(size == 4, "size reflects updated data");

    ggml_amd_packing_cache_destroy(cache);
}

static void test_cache_null_handling(void) {
    // Destroy null
    ggml_amd_packing_cache_destroy(nullptr);
    CHECK(true, "destroy(nullptr) does not crash");

    // Lookup with null cache
    struct ggml_amd_packing_key key = make_test_key("tensor.null", 1);
    std::vector<uint8_t> out_data;
    bool found = ggml_amd_packing_cache_lookup(nullptr, &key, &out_data);
    CHECK(!found, "lookup with null cache returns false");

    // Insert with null cache
    std::vector<uint8_t> data = {1, 2, 3};
    ggml_amd_packing_cache_insert(nullptr, &key, data);
    CHECK(true, "insert with null cache does not crash");

    // Invalidate with null cache
    ggml_amd_packing_cache_invalidate(nullptr, &key);
    CHECK(true, "invalidate with null cache does not crash");

    // Stats with null cache
    size_t hits, misses, size;
    ggml_amd_packing_cache_get_stats(nullptr, &hits, &misses, &size);
    CHECK(true, "get_stats with null cache does not crash");
}

int main(void) {
    std::fprintf(stdout, "=== test-amd-packing-cache ===\n");

    test_cache_create_destroy();
    test_cache_insert_lookup();
    test_cache_lookup_miss();
    test_cache_lru_eviction();
    test_cache_invalidate();
    test_cache_stats();
    test_cache_key_matching();
    test_cache_update_existing();
    test_cache_null_handling();

    std::fprintf(stdout, "\n");
    if (g_failures == 0) {
        std::fprintf(stdout, "PASS: all tests passed\n");
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: %d test(s) failed\n", g_failures);
        return 1;
    }
}
