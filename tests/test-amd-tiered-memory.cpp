// test-amd-tiered-memory.cpp
//
// Test tiered memory (pure logic, no hardware).
//
// What this exercises:
//  1. ggml_amd_tiered_memory_create()
//  2. tier selection for hot weights, KV cache, cold tensors
//  3. budget setting
//  4. prefetch and eviction decisions

#include "ggml.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>

// Internal API declarations (from ggml-amd-tiered-memory.cpp)
enum ggml_amd_tier {
    GGML_AMD_TIER_SYSTEM,
    GGML_AMD_TIER_VRAM,
    GGML_AMD_TIER_NPU,
};

struct ggml_amd_tiered_memory_manager;

struct ggml_amd_tiered_memory_manager * ggml_amd_tiered_memory_create(void);
void ggml_amd_tiered_memory_destroy(struct ggml_amd_tiered_memory_manager * mgr);

enum ggml_amd_tier ggml_amd_tiered_memory_select_tier(
    struct ggml_amd_tiered_memory_manager * mgr,
    const char * tensor_name,
    size_t size_bytes,
    bool is_hot_weight,
    bool is_kv_cache);

void ggml_amd_tiered_memory_set_budget(
    struct ggml_amd_tiered_memory_manager * mgr,
    enum ggml_amd_tier tier,
    size_t budget_bytes);

bool ggml_amd_tiered_memory_should_prefetch(
    struct ggml_amd_tiered_memory_manager * mgr,
    const char * tensor_name);

bool ggml_amd_tiered_memory_should_evict(
    struct ggml_amd_tiered_memory_manager * mgr,
    const char * tensor_name,
    size_t current_vram_usage);

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

static void test_tiered_memory_create_destroy(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    CHECK(mgr != nullptr, "tiered memory create succeeds");
    ggml_amd_tiered_memory_destroy(mgr);
    CHECK(true, "tiered memory destroy succeeds");
}

static void test_tiered_memory_select_hot_weight(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    enum ggml_amd_tier tier = ggml_amd_tiered_memory_select_tier(
        mgr, "model.layer.0.weight", 1024 * 1024, true, false);
    CHECK(tier == GGML_AMD_TIER_VRAM, "hot weight selects VRAM tier");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_select_kv_cache(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    enum ggml_amd_tier tier = ggml_amd_tiered_memory_select_tier(
        mgr, "kv_cache.layer.0", 2048 * 1024, false, true);
    CHECK(tier == GGML_AMD_TIER_VRAM, "KV cache selects VRAM tier");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_select_cold_tensor(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    enum ggml_amd_tier tier = ggml_amd_tiered_memory_select_tier(
        mgr, "model.layer.10.activation", 512, false, false);
    CHECK(tier == GGML_AMD_TIER_SYSTEM, "cold tensor selects SYSTEM tier");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_select_cached(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    // First selection
    enum ggml_amd_tier tier1 = ggml_amd_tiered_memory_select_tier(
        mgr, "tensor.cached", 1024, true, false);
    CHECK(tier1 == GGML_AMD_TIER_VRAM, "first selection is VRAM");

    // Second selection (should be cached)
    enum ggml_amd_tier tier2 = ggml_amd_tiered_memory_select_tier(
        mgr, "tensor.cached", 1024, false, false);  // different flags
    CHECK(tier2 == GGML_AMD_TIER_VRAM, "cached selection returns same tier");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_set_budget(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    // Set VRAM budget
    ggml_amd_tiered_memory_set_budget(mgr, GGML_AMD_TIER_VRAM, 8 * 1024 * 1024 * 1024ULL);

    // Budget setting should not crash
    CHECK(true, "set_budget does not crash");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_should_prefetch(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    // Select tier for a hot weight (VRAM)
    ggml_amd_tiered_memory_select_tier(mgr, "tensor.prefetch", 1024, true, false);

    // Should prefetch VRAM tensors
    bool should_prefetch = ggml_amd_tiered_memory_should_prefetch(mgr, "tensor.prefetch");
    CHECK(should_prefetch, "should_prefetch returns true for VRAM tensor");

    // Unknown tensor should not prefetch
    should_prefetch = ggml_amd_tiered_memory_should_prefetch(mgr, "tensor.unknown");
    CHECK(!should_prefetch, "should_prefetch returns false for unknown tensor");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_should_evict(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    // Set VRAM budget to 1 GB
    ggml_amd_tiered_memory_set_budget(mgr, GGML_AMD_TIER_VRAM, 1024 * 1024 * 1024);

    // Select tier for a tensor
    ggml_amd_tiered_memory_select_tier(mgr, "tensor.evict", 1024, true, false);

    // Under budget: should not evict
    bool should_evict = ggml_amd_tiered_memory_should_evict(mgr, "tensor.evict", 512 * 1024 * 1024);
    CHECK(!should_evict, "should_evict returns false when under budget");

    // Over budget: should evict
    should_evict = ggml_amd_tiered_memory_should_evict(mgr, "tensor.evict", 2 * 1024 * 1024 * 1024ULL);
    CHECK(should_evict, "should_evict returns true when over budget");

    ggml_amd_tiered_memory_destroy(mgr);
}

static void test_tiered_memory_null_handling(void) {
    // Destroy null
    ggml_amd_tiered_memory_destroy(nullptr);
    CHECK(true, "destroy(nullptr) does not crash");

    // Select tier with null mgr
    enum ggml_amd_tier tier = ggml_amd_tiered_memory_select_tier(nullptr, "tensor.null", 1024, true, false);
    CHECK(tier == GGML_AMD_TIER_SYSTEM, "select_tier with null mgr returns SYSTEM");

    // Set budget with null mgr
    ggml_amd_tiered_memory_set_budget(nullptr, GGML_AMD_TIER_VRAM, 1024);
    CHECK(true, "set_budget with null mgr does not crash");

    // Should prefetch with null mgr
    bool should_prefetch = ggml_amd_tiered_memory_should_prefetch(nullptr, "tensor.null");
    CHECK(!should_prefetch, "should_prefetch with null mgr returns false");

    // Should evict with null mgr
    bool should_evict = ggml_amd_tiered_memory_should_evict(nullptr, "tensor.null", 1024);
    CHECK(!should_evict, "should_evict with null mgr returns false");
}

static void test_tiered_memory_null_tensor_name(void) {
    struct ggml_amd_tiered_memory_manager * mgr = ggml_amd_tiered_memory_create();
    if (!mgr) return;

    // Select tier with null tensor name
    enum ggml_amd_tier tier = ggml_amd_tiered_memory_select_tier(mgr, nullptr, 1024, true, false);
    CHECK(tier == GGML_AMD_TIER_SYSTEM, "select_tier with null name returns SYSTEM");

    // Should prefetch with null tensor name
    bool should_prefetch = ggml_amd_tiered_memory_should_prefetch(mgr, nullptr);
    CHECK(!should_prefetch, "should_prefetch with null name returns false");

    // Should evict with null tensor name
    bool should_evict = ggml_amd_tiered_memory_should_evict(mgr, nullptr, 1024);
    CHECK(!should_evict, "should_evict with null name returns false");

    ggml_amd_tiered_memory_destroy(mgr);
}

int main(void) {
    std::fprintf(stdout, "=== test-amd-tiered-memory ===\n");

    test_tiered_memory_create_destroy();
    test_tiered_memory_select_hot_weight();
    test_tiered_memory_select_kv_cache();
    test_tiered_memory_select_cold_tensor();
    test_tiered_memory_select_cached();
    test_tiered_memory_set_budget();
    test_tiered_memory_should_prefetch();
    test_tiered_memory_should_evict();
    test_tiered_memory_null_handling();
    test_tiered_memory_null_tensor_name();

    std::fprintf(stdout, "\n");
    if (g_failures == 0) {
        std::fprintf(stdout, "PASS: all tests passed\n");
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: %d test(s) failed\n", g_failures);
        return 1;
    }
}
