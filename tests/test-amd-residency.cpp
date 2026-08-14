// test-amd-residency.cpp
//
// Test residency manager (pure logic, no hardware).
//
// What this exercises:
//  1. ggml_amd_residency_manager_create()
//  2. register, mark_used, suggest_evictions
//  3. pin/unpin
//  4. eviction respects idle threshold
//  5. pinned entries are not evicted

#include "ggml.h"
#include "ggml-amd-internal.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

// Internal API declarations (from ggml-amd-residency.cpp)
struct ggml_amd_allocation;
struct ggml_amd_provider;

struct ggml_amd_residency_suggestion {
    std::string tensor_name;
    struct ggml_amd_allocation * allocation;
    struct ggml_amd_provider * provider;
    size_t size_bytes;
};

struct ggml_amd_residency_manager;

struct ggml_amd_residency_manager * ggml_amd_residency_manager_create(size_t max_resident_bytes);
void ggml_amd_residency_manager_destroy(struct ggml_amd_residency_manager * mgr);

void ggml_amd_residency_manager_register(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name,
    struct ggml_amd_allocation * allocation,
    struct ggml_amd_provider * provider,
    size_t size_bytes);

void ggml_amd_residency_manager_mark_used(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name,
    int64_t iter);

std::vector<ggml_amd_residency_suggestion> ggml_amd_residency_manager_suggest_evictions(
    struct ggml_amd_residency_manager * mgr,
    int64_t current_iter,
    int64_t idle_threshold);

void ggml_amd_residency_manager_evict(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name);

void ggml_amd_residency_manager_pin(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name);

void ggml_amd_residency_manager_unpin(
    struct ggml_amd_residency_manager * mgr,
    const char * tensor_name);

size_t ggml_amd_residency_manager_get_resident_bytes(struct ggml_amd_residency_manager * mgr);

struct ggml_amd_allocation * ggml_amd_allocation_create(
    enum ggml_amd_memory_domain domain,
    size_t size,
    size_t alignment,
    enum ggml_amd_coherency coherency);

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

static void test_residency_create_destroy(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    CHECK(mgr != nullptr, "residency manager create succeeds");
    ggml_amd_residency_manager_destroy(mgr);
    CHECK(true, "residency manager destroy succeeds");
}

static void test_residency_register(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    struct ggml_amd_allocation * alloc = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_PROVIDER_PRIVATE, 1024, 64, GGML_AMD_COHERENCY_CPU_ONLY);
    struct ggml_amd_provider * provider = nullptr;  // dummy
    CHECK(alloc != nullptr, "residency allocation creates");
    if (!alloc) {
        ggml_amd_residency_manager_destroy(mgr);
        return;
    }

    ggml_amd_residency_manager_register(mgr, "tensor.a", alloc, provider, 1024);
    size_t bytes = ggml_amd_residency_manager_get_resident_bytes(mgr);
    CHECK(bytes == 1024, "resident bytes is 1024 after register");

    ggml_amd_residency_manager_destroy(mgr);
    ggml_amd_allocation_release(alloc);
}

static void test_residency_register_multiple(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.a", nullptr, nullptr, 1024);
    ggml_amd_residency_manager_register(mgr, "tensor.b", nullptr, nullptr, 2048);
    ggml_amd_residency_manager_register(mgr, "tensor.c", nullptr, nullptr, 512);

    size_t bytes = ggml_amd_residency_manager_get_resident_bytes(mgr);
    CHECK(bytes == 1024 + 2048 + 512, "resident bytes is sum of all registrations");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_register_duplicate(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.dup", nullptr, nullptr, 1024);
    ggml_amd_residency_manager_register(mgr, "tensor.dup", nullptr, nullptr, 2048);  // duplicate

    size_t bytes = ggml_amd_residency_manager_get_resident_bytes(mgr);
    CHECK(bytes == 1024, "duplicate registration is ignored");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_mark_used(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.used", nullptr, nullptr, 1024);
    ggml_amd_residency_manager_mark_used(mgr, "tensor.used", 100);

    // Mark used should not crash or change resident bytes
    size_t bytes = ggml_amd_residency_manager_get_resident_bytes(mgr);
    CHECK(bytes == 1024, "resident bytes unchanged after mark_used");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_suggest_evictions(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.old", nullptr, nullptr, 1024);
    ggml_amd_residency_manager_mark_used(mgr, "tensor.old", 10);

    ggml_amd_residency_manager_register(mgr, "tensor.new", nullptr, nullptr, 2048);
    ggml_amd_residency_manager_mark_used(mgr, "tensor.new", 100);

    // Suggest evictions at iter 110 with threshold 50
    // tensor.old: 110 - 10 = 100 >= 50 -> evict
    // tensor.new: 110 - 100 = 10 < 50 -> keep
    auto suggestions = ggml_amd_residency_manager_suggest_evictions(mgr, 110, 50);
    CHECK(suggestions.size() == 1, "one suggestion for idle tensor");
    if (suggestions.size() == 1) {
        CHECK(suggestions[0].tensor_name == "tensor.old", "suggestion is for tensor.old");
        CHECK(suggestions[0].size_bytes == 1024, "suggestion size matches");
    }

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_suggest_evictions_all_idle(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.a", nullptr, nullptr, 1024);
    ggml_amd_residency_manager_mark_used(mgr, "tensor.a", 0);

    ggml_amd_residency_manager_register(mgr, "tensor.b", nullptr, nullptr, 2048);
    ggml_amd_residency_manager_mark_used(mgr, "tensor.b", 0);

    // All tensors are idle (last_used_iter = 0, current_iter = 100, threshold = 50)
    auto suggestions = ggml_amd_residency_manager_suggest_evictions(mgr, 100, 50);
    CHECK(suggestions.size() == 2, "all idle tensors suggested for eviction");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_pin_unpin(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.pinned", nullptr, nullptr, 1024);
    ggml_amd_residency_manager_mark_used(mgr, "tensor.pinned", 0);

    // Pin the tensor
    ggml_amd_residency_manager_pin(mgr, "tensor.pinned");

    // Suggest evictions - pinned tensor should not be suggested
    auto suggestions = ggml_amd_residency_manager_suggest_evictions(mgr, 100, 50);
    CHECK(suggestions.empty(), "pinned tensor not suggested for eviction");

    // Unpin the tensor
    ggml_amd_residency_manager_unpin(mgr, "tensor.pinned");

    // Now it should be suggested
    suggestions = ggml_amd_residency_manager_suggest_evictions(mgr, 100, 50);
    CHECK(suggestions.size() == 1, "unpinned tensor suggested for eviction");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_evict(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.evict", nullptr, nullptr, 1024);
    size_t bytes_before = ggml_amd_residency_manager_get_resident_bytes(mgr);
    CHECK(bytes_before == 1024, "resident bytes is 1024 before eviction");

    ggml_amd_residency_manager_evict(mgr, "tensor.evict");
    size_t bytes_after = ggml_amd_residency_manager_get_resident_bytes(mgr);
    CHECK(bytes_after == 0, "resident bytes is 0 after eviction");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_evict_nonexistent(void) {
    struct ggml_amd_residency_manager * mgr = ggml_amd_residency_manager_create(1024 * 1024);
    if (!mgr) return;

    ggml_amd_residency_manager_register(mgr, "tensor.exists", nullptr, nullptr, 1024);
    size_t bytes_before = ggml_amd_residency_manager_get_resident_bytes(mgr);

    // Evict non-existent tensor
    ggml_amd_residency_manager_evict(mgr, "tensor.nonexistent");
    size_t bytes_after = ggml_amd_residency_manager_get_resident_bytes(mgr);

    CHECK(bytes_before == bytes_after, "evicting non-existent tensor does not change bytes");

    ggml_amd_residency_manager_destroy(mgr);
}

static void test_residency_null_handling(void) {
    // Destroy null
    ggml_amd_residency_manager_destroy(nullptr);
    CHECK(true, "destroy(nullptr) does not crash");

    // Register with null mgr
    ggml_amd_residency_manager_register(nullptr, "tensor.null", nullptr, nullptr, 1024);
    CHECK(true, "register with null mgr does not crash");

    // Mark used with null mgr
    ggml_amd_residency_manager_mark_used(nullptr, "tensor.null", 100);
    CHECK(true, "mark_used with null mgr does not crash");

    // Suggest evictions with null mgr
    auto suggestions = ggml_amd_residency_manager_suggest_evictions(nullptr, 100, 50);
    CHECK(suggestions.empty(), "suggest_evictions with null mgr returns empty");

    // Get resident bytes with null mgr
    size_t bytes = ggml_amd_residency_manager_get_resident_bytes(nullptr);
    CHECK(bytes == 0, "get_resident_bytes with null mgr returns 0");
}

int main(void) {
    std::fprintf(stdout, "=== test-amd-residency ===\n");

    test_residency_create_destroy();
    test_residency_register();
    test_residency_register_multiple();
    test_residency_register_duplicate();
    test_residency_mark_used();
    test_residency_suggest_evictions();
    test_residency_suggest_evictions_all_idle();
    test_residency_pin_unpin();
    test_residency_evict();
    test_residency_evict_nonexistent();
    test_residency_null_handling();

    std::fprintf(stdout, "\n");
    if (g_failures == 0) {
        std::fprintf(stdout, "PASS: all tests passed\n");
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: %d test(s) failed\n", g_failures);
        return 1;
    }
}
