// test-amd-scheduler.cpp
//
// Test region formation and cost model (pure logic, no hardware).
//
// What this exercises:
//  1. ggml_amd_form_regions() with a mock graph
//  2. region boundaries are correct
//  3. ggml_amd_cost_model_create() and ggml_amd_cost_model_estimate()
//  4. cost model update and exponential moving average
//  5. scheduler modes (deterministic, adaptive)
//  6. ggml_amd_scheduler_plan() and ggml_amd_scheduler_execute()

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-amd-types.h"
#include "ggml-amd-provider.h"
#include "ggml-amd-internal.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#include <memory>

// Internal API declarations
struct ggml_amd_cost_model;
struct ggml_amd_cost_key {
    std::string device_fingerprint;
    std::string provider_abi;
    std::string region_signature;
    std::string shape_bucket;
    std::string datatype_signature;
    std::string packing_version;
    enum ggml_amd_phase phase;
};

struct ggml_amd_cost_model * ggml_amd_cost_model_create(void);
void ggml_amd_cost_model_destroy(struct ggml_amd_cost_model * model);
double ggml_amd_cost_model_estimate(struct ggml_amd_cost_model * model, const struct ggml_amd_cost_key * key);
void ggml_amd_cost_model_update(struct ggml_amd_cost_model * model, const struct ggml_amd_cost_key * key,
                                double execution_us, double queue_us, double fence_us,
                                double import_us, double copy_us, double compile_us,
                                double packing_us, double eviction_us);

std::vector<struct ggml_amd_region *> ggml_amd_form_regions(
    struct ggml_amd_provider ** providers,
    int n_providers,
    struct ggml_cgraph * graph);

void ggml_amd_regions_free(std::vector<struct ggml_amd_region *> & regions);

// Scheduler API (from ggml-amd-scheduler.cpp)
struct ggml_amd_scheduler;
struct ggml_amd_scheduler * ggml_amd_scheduler_create(struct ggml_amd_reg_context * reg_ctx);
void ggml_amd_scheduler_destroy(struct ggml_amd_scheduler * sched);
int ggml_amd_scheduler_plan(struct ggml_amd_scheduler * sched, struct ggml_cgraph * graph, enum ggml_amd_phase phase);
int ggml_amd_scheduler_execute(struct ggml_amd_scheduler * sched);
int ggml_amd_scheduler_get_region_count(struct ggml_amd_scheduler * sched);
struct ggml_amd_region * ggml_amd_scheduler_get_region(struct ggml_amd_scheduler * sched, int index);

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

// Mock provider interface
static bool mock_supports_op(struct ggml_amd_provider * provider, const struct ggml_tensor * op) {
    (void)provider;
    (void)op;
    return true;  // Support all ops
}

static bool mock_supports_no_ops(struct ggml_amd_provider * provider, const struct ggml_tensor * op) {
    (void)provider;
    (void)op;
    return false;
}

static ggml_status mock_submit_region(struct ggml_amd_provider * provider, struct ggml_amd_region * region, struct ggml_amd_fence * fence) {
    (void)provider;
    (void)region;
    (void)fence;
    return GGML_STATUS_SUCCESS;
}

static struct ggml_amd_provider_i mock_provider_i = {
    .name = "mock-provider",
    .probe = nullptr,
    .supports_op = mock_supports_op,
    .supports_import = nullptr,
    .import_allocation = nullptr,
    .release_import = nullptr,
    .submit_region = mock_submit_region,
    .wait_fence = nullptr,
    .query_memory = nullptr,
};

static struct ggml_amd_provider_i mock_unsupported_provider_i = {
    .name = "mock-unsupported-provider",
    .probe = nullptr,
    .supports_op = mock_supports_no_ops,
    .supports_import = nullptr,
    .import_allocation = nullptr,
    .release_import = nullptr,
    .submit_region = mock_submit_region,
    .wait_fence = nullptr,
    .query_memory = nullptr,
};

static void test_cost_model_create_destroy(void) {
    struct ggml_amd_cost_model * model = ggml_amd_cost_model_create();
    CHECK(model != nullptr, "cost model create succeeds");
    ggml_amd_cost_model_destroy(model);
    CHECK(true, "cost model destroy succeeds");
}

static void test_cost_model_estimate_empty(void) {
    struct ggml_amd_cost_model * model = ggml_amd_cost_model_create();
    struct ggml_amd_cost_key key;
    key.device_fingerprint = "test-device";
    key.provider_abi = "test-abi";
    key.region_signature = "test-region";
    key.shape_bucket = "test-shape";
    key.datatype_signature = "test-dtype";
    key.packing_version = "v1";
    key.phase = GGML_AMD_PHASE_DECODE;

    double estimate = ggml_amd_cost_model_estimate(model, &key);
    CHECK(estimate == 1e9, "empty cost model returns 1e9 (infinity)");

    ggml_amd_cost_model_destroy(model);
}

static void test_cost_model_update_estimate(void) {
    struct ggml_amd_cost_model * model = ggml_amd_cost_model_create();
    struct ggml_amd_cost_key key;
    key.device_fingerprint = "test-device";
    key.provider_abi = "test-abi";
    key.region_signature = "test-region";
    key.shape_bucket = "test-shape";
    key.datatype_signature = "test-dtype";
    key.packing_version = "v1";
    key.phase = GGML_AMD_PHASE_DECODE;

    // Update with known values
    ggml_amd_cost_model_update(model, &key, 100.0, 10.0, 5.0, 20.0, 15.0, 30.0, 25.0, 8.0);

    double estimate = ggml_amd_cost_model_estimate(model, &key);
    // Total = 100 + 10 + 5 + 20 + 15 + 30 + 25 + 8 = 213
    CHECK(estimate == 213.0, "cost model estimate matches sum of components");

    ggml_amd_cost_model_destroy(model);
}

static void test_cost_model_ema(void) {
    struct ggml_amd_cost_model * model = ggml_amd_cost_model_create();
    struct ggml_amd_cost_key key;
    key.device_fingerprint = "test-device";
    key.provider_abi = "test-abi";
    key.region_signature = "test-region";
    key.shape_bucket = "test-shape";
    key.datatype_signature = "test-dtype";
    key.packing_version = "v1";
    key.phase = GGML_AMD_PHASE_DECODE;

    // First update: execution_us = 100
    ggml_amd_cost_model_update(model, &key, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    double est1 = ggml_amd_cost_model_estimate(model, &key);
    CHECK(est1 == 100.0, "first update: estimate is 100");

    // Second update: execution_us = 200
    // EMA: (1 - 1/2) * 100 + (1/2) * 200 = 50 + 100 = 150
    ggml_amd_cost_model_update(model, &key, 200.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    double est2 = ggml_amd_cost_model_estimate(model, &key);
    CHECK(est2 == 150.0, "second update: EMA is 150");

    // Third update: execution_us = 300
    // EMA: (1 - 1/3) * 150 + (1/3) * 300 = 100 + 100 = 200
    ggml_amd_cost_model_update(model, &key, 300.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    double est3 = ggml_amd_cost_model_estimate(model, &key);
    CHECK(est3 == 200.0, "third update: EMA is 200");

    ggml_amd_cost_model_destroy(model);
}

static void test_cost_model_null_handling(void) {
    double est = ggml_amd_cost_model_estimate(nullptr, nullptr);
    CHECK(est == 1e9, "estimate with null model returns 1e9");

    struct ggml_amd_cost_model * model = ggml_amd_cost_model_create();
    est = ggml_amd_cost_model_estimate(model, nullptr);
    CHECK(est == 1e9, "estimate with null key returns 1e9");

    ggml_amd_cost_model_update(nullptr, nullptr, 0, 0, 0, 0, 0, 0, 0, 0);
    CHECK(true, "update with null args does not crash");

    ggml_amd_cost_model_destroy(model);
}

static void test_form_regions_empty_graph(void) {
    std::vector<struct ggml_amd_provider *> providers;
    struct ggml_cgraph * graph = nullptr;

    auto regions = ggml_amd_form_regions(providers.data(), (int)providers.size(), graph);
    CHECK(regions.empty(), "empty graph produces no regions");
}

static void test_form_regions_single_provider(void) {
    auto provider = std::make_unique<struct ggml_amd_provider>();
    provider->iface = &mock_provider_i;
    provider->context = nullptr;
    provider->device_index = 0;
    provider->device_type = GGML_AMD_DEVICE_CPU;

    std::vector<struct ggml_amd_provider *> providers;
    providers.push_back(provider.get());

    // Create a small graph with 3 executable nodes.
    struct ggml_context * ctx = ggml_init({1024 * 1024, nullptr, false});
    struct ggml_tensor * a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * b = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * c = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * d = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * t1 = ggml_add(ctx, a, b);
    struct ggml_tensor * t2 = ggml_add(ctx, t1, c);
    struct ggml_tensor * t3 = ggml_add(ctx, t2, d);

    struct ggml_cgraph * graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, t3);

    auto regions = ggml_amd_form_regions(providers.data(), (int)providers.size(), graph);
    CHECK(regions.size() == 1, "single provider produces one region");
    if (regions.size() == 1) {
        CHECK(regions[0]->node_start == 0, "region starts at node 0");
        CHECK(regions[0]->node_end == 2, "region ends at node 2");
        CHECK(regions[0]->provider == provider.get(), "region provider matches");
        CHECK(regions[0]->graph == graph, "region retains its graph");
    }

    ggml_amd_regions_free(regions);
    ggml_free(ctx);
}

static void test_form_regions_unsupported_falls_back(void) {
    auto provider = std::make_unique<struct ggml_amd_provider>();
    provider->iface = &mock_unsupported_provider_i;
    provider->context = nullptr;
    provider->device_index = 0;
    provider->device_type = GGML_AMD_DEVICE_CPU;

    std::vector<struct ggml_amd_provider *> providers;
    providers.push_back(provider.get());

    struct ggml_context * ctx = ggml_init({1024 * 1024, nullptr, false});
    struct ggml_tensor * a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * b = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * tensor = ggml_add(ctx, a, b);
    struct ggml_cgraph * graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, tensor);

    auto regions = ggml_amd_form_regions(providers.data(), (int)providers.size(), graph);
    CHECK(regions.size() == 1, "unsupported graph produces one fallback region");
    if (regions.size() == 1) {
        CHECK(regions[0]->provider == nullptr, "unsupported region has no AMD provider");
    }

    ggml_amd_regions_free(regions);
    ggml_free(ctx);
}

static void test_scheduler_create_destroy(void) {
    auto reg_ctx = std::make_unique<struct ggml_amd_reg_context>();
    reg_ctx->scheduler_mode = GGML_AMD_SCHEDULER_DETERMINISTIC;
    reg_ctx->initialized = true;

    auto sched = ggml_amd_scheduler_create(reg_ctx.get());
    CHECK(sched != nullptr, "scheduler create succeeds");

    ggml_amd_scheduler_destroy(sched);
    CHECK(true, "scheduler destroy succeeds");
}

static void test_scheduler_create_null(void) {
    auto sched = ggml_amd_scheduler_create(nullptr);
    CHECK(sched == nullptr, "scheduler create with null reg_ctx returns nullptr");
}

static void test_scheduler_plan_empty_graph(void) {
    auto reg_ctx = std::make_unique<struct ggml_amd_reg_context>();
    reg_ctx->scheduler_mode = GGML_AMD_SCHEDULER_DETERMINISTIC;
    reg_ctx->initialized = true;

    auto sched = ggml_amd_scheduler_create(reg_ctx.get());
    if (sched) {
        int result = ggml_amd_scheduler_plan(sched, nullptr, GGML_AMD_PHASE_DECODE);
        CHECK(result == -1, "plan with null graph returns -1");

        ggml_amd_scheduler_destroy(sched);
    }
}

static void test_scheduler_plan_carries_phase(void) {
    auto reg_ctx = std::make_unique<struct ggml_amd_reg_context>();
    reg_ctx->scheduler_mode = GGML_AMD_SCHEDULER_DETERMINISTIC;
    reg_ctx->initialized = true;

    auto provider = std::make_unique<struct ggml_amd_provider>();
    provider->iface = &mock_provider_i;
    provider->context = nullptr;
    provider->device_index = 0;
    provider->device_type = GGML_AMD_DEVICE_CPU;
    reg_ctx->providers.push_back(std::move(provider));

    struct ggml_context * ctx = ggml_init({1024 * 1024, nullptr, false});
    struct ggml_tensor * a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * b = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * tensor = ggml_add(ctx, a, b);
    struct ggml_cgraph * graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, tensor);

    auto sched = ggml_amd_scheduler_create(reg_ctx.get());
    int n_regions = ggml_amd_scheduler_plan(sched, graph, GGML_AMD_PHASE_PREFILL);
    CHECK(n_regions == 1, "scheduler plans the supported graph");
    struct ggml_amd_region * region = ggml_amd_scheduler_get_region(sched, 0);
    CHECK(region != nullptr && region->phase == GGML_AMD_PHASE_PREFILL, "scheduler carries prefill phase to its region");

    ggml_amd_scheduler_destroy(sched);
    ggml_free(ctx);
}

static void test_scheduler_execute_fallback_region(void) {
    auto reg_ctx = std::make_unique<struct ggml_amd_reg_context>();
    reg_ctx->scheduler_mode = GGML_AMD_SCHEDULER_DETERMINISTIC;
    reg_ctx->initialized = true;

    struct ggml_context * ctx = ggml_init({1024 * 1024, nullptr, false});
    struct ggml_tensor * a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * b = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 10);
    struct ggml_tensor * tensor = ggml_add(ctx, a, b);
    struct ggml_cgraph * graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, tensor);

    auto sched = ggml_amd_scheduler_create(reg_ctx.get());
    int n_regions = ggml_amd_scheduler_plan(sched, graph, GGML_AMD_PHASE_DECODE);
    CHECK(n_regions == 1, "scheduler retains an unsupported fallback region");
    struct ggml_amd_region * region = ggml_amd_scheduler_get_region(sched, 0);
    CHECK(region != nullptr && region->provider == nullptr, "fallback region is not assigned to a provider");
    CHECK(ggml_amd_scheduler_execute(sched) == 0, "scheduler does not submit a fallback region to AMD");

    ggml_amd_scheduler_destroy(sched);
    ggml_free(ctx);
}

static void test_scheduler_execute_empty(void) {
    auto reg_ctx = std::make_unique<struct ggml_amd_reg_context>();
    reg_ctx->scheduler_mode = GGML_AMD_SCHEDULER_DETERMINISTIC;
    reg_ctx->initialized = true;

    auto sched = ggml_amd_scheduler_create(reg_ctx.get());
    if (sched) {
        // Execute without planning should succeed (no regions to execute)
        int result = ggml_amd_scheduler_execute(sched);
        CHECK(result == 0, "execute with no regions returns 0");

        ggml_amd_scheduler_destroy(sched);
    }
}

static void test_scheduler_execute_null(void) {
    int result = ggml_amd_scheduler_execute(nullptr);
    CHECK(result == -1, "execute with null scheduler returns -1");
}

int main(void) {
    std::fprintf(stdout, "=== test-amd-scheduler ===\n");

    test_cost_model_create_destroy();
    test_cost_model_estimate_empty();
    test_cost_model_update_estimate();
    test_cost_model_ema();
    test_cost_model_null_handling();
    test_form_regions_empty_graph();
    test_form_regions_single_provider();
    test_form_regions_unsupported_falls_back();
    test_scheduler_create_destroy();
    test_scheduler_create_null();
    test_scheduler_plan_empty_graph();
    test_scheduler_plan_carries_phase();
    test_scheduler_execute_fallback_region();
    test_scheduler_execute_empty();
    test_scheduler_execute_null();

    std::fprintf(stdout, "\n");
    if (g_failures == 0) {
        std::fprintf(stdout, "PASS: all tests passed\n");
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: %d test(s) failed\n", g_failures);
        return 1;
    }
}
