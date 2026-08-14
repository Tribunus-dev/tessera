#include "ggml-amd-internal.h"
#include "ggml.h"
#include "ggml-backend.h"

#include <vector>
#include <cstring>

extern std::vector<struct ggml_amd_region *> ggml_amd_form_regions(
    struct ggml_amd_provider ** providers,
    int n_providers,
    struct ggml_cgraph * graph);

extern void ggml_amd_regions_free(std::vector<struct ggml_amd_region *> & regions);
extern struct ggml_amd_cost_model * ggml_amd_cost_model_create(void);
extern void ggml_amd_cost_model_destroy(struct ggml_amd_cost_model * model);

struct ggml_amd_scheduler {
    struct ggml_amd_reg_context * reg_ctx;
    enum ggml_amd_scheduler_mode mode;
    struct ggml_amd_cost_model * cost_model;
    std::vector<struct ggml_amd_region *> current_regions;
};

struct ggml_amd_scheduler * ggml_amd_scheduler_create(struct ggml_amd_reg_context * reg_ctx) {
    if (!reg_ctx) {
        return nullptr;
    }

    auto sched = new ggml_amd_scheduler();
    sched->reg_ctx = reg_ctx;
    sched->mode = reg_ctx->scheduler_mode;
    sched->cost_model = ggml_amd_cost_model_create();
    return sched;
}

void ggml_amd_scheduler_destroy(struct ggml_amd_scheduler * sched) {
    if (!sched) {
        return;
    }
    ggml_amd_regions_free(sched->current_regions);
    ggml_amd_cost_model_destroy(sched->cost_model);
    delete sched;
}

static int ggml_amd_scheduler_plan_deterministic(
    struct ggml_amd_scheduler * sched,
    struct ggml_cgraph * graph) {

    std::vector<ggml_amd_provider *> providers;
    for (auto & prov : sched->reg_ctx->providers) {
        providers.push_back(prov.get());
    }

    sched->current_regions = ggml_amd_form_regions(providers.data(), (int)providers.size(), graph);
    return (int)sched->current_regions.size();
}

static int ggml_amd_scheduler_plan_adaptive(
    struct ggml_amd_scheduler * sched,
    struct ggml_cgraph * graph) {

    return ggml_amd_scheduler_plan_deterministic(sched, graph);
}

int ggml_amd_scheduler_plan(
    struct ggml_amd_scheduler * sched,
    struct ggml_cgraph * graph,
    enum ggml_amd_phase phase) {

    if (!sched || !graph) {
        return -1;
    }

    ggml_amd_regions_free(sched->current_regions);

    switch (sched->mode) {
        case GGML_AMD_SCHEDULER_DETERMINISTIC:
            return ggml_amd_scheduler_plan_deterministic(sched, graph);
        case GGML_AMD_SCHEDULER_ADAPTIVE:
            return ggml_amd_scheduler_plan_adaptive(sched, graph);
        case GGML_AMD_SCHEDULER_DIAGNOSTIC:
            return ggml_amd_scheduler_plan_deterministic(sched, graph);
        case GGML_AMD_SCHEDULER_SINGLE_PROVIDER:
            return ggml_amd_scheduler_plan_deterministic(sched, graph);
        default:
            return -1;
    }
}

int ggml_amd_scheduler_execute(struct ggml_amd_scheduler * sched) {
    if (!sched) {
        return -1;
    }

    for (auto region : sched->current_regions) {
        if (!region->provider || !region->provider->iface || !region->provider->iface->submit_region) {
            continue;
        }

        struct ggml_amd_fence fence;
        memset(&fence, 0, sizeof(fence));
        fence.kind = GGML_AMD_FENCE_HOST;

        ggml_status status = region->provider->iface->submit_region(region->provider, region, &fence);
        if (status != GGML_STATUS_SUCCESS) {
            return -1;
        }
    }

    return 0;
}

// Accessor for integration layer
int ggml_amd_scheduler_get_region_count(struct ggml_amd_scheduler * sched) {
    if (!sched) {
        return 0;
    }
    return (int)sched->current_regions.size();
}

struct ggml_amd_region * ggml_amd_scheduler_get_region(struct ggml_amd_scheduler * sched, int index) {
    if (!sched || index < 0 || index >= (int)sched->current_regions.size()) {
        return nullptr;
    }
    return sched->current_regions[index];
}
