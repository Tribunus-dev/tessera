// ggml-amd-sched-integration.cpp
//
// Bridges the ggml-amd region scheduler into the ggml_backend_sched
// infrastructure. Called before graph_compute to pre-assign tensors
// to the AMD backend based on region formation.

#include "ggml-amd-internal.h"
#include "ggml-amd.h"
#include "ggml-backend.h"
#include "ggml.h"
#include "ggml-impl.h"

// Forward declarations from ggml-amd-scheduler.cpp
struct ggml_amd_scheduler;
extern struct ggml_amd_scheduler * ggml_amd_scheduler_create(struct ggml_amd_reg_context * reg_ctx);
extern void ggml_amd_scheduler_destroy(struct ggml_amd_scheduler * sched);
extern int ggml_amd_scheduler_plan(
    struct ggml_amd_scheduler * sched,
    struct ggml_cgraph * graph,
    enum ggml_amd_phase phase);
extern int ggml_amd_scheduler_get_region_count(struct ggml_amd_scheduler * sched);
extern struct ggml_amd_region * ggml_amd_scheduler_get_region(struct ggml_amd_scheduler * sched, int index);

// Access the reg context from an AMD backend
static struct ggml_amd_reg_context * ggml_amd_get_reg_context(ggml_backend_t backend) {
    if (!backend || !backend->device || !backend->device->reg) {
        return nullptr;
    }
    return (struct ggml_amd_reg_context *)backend->device->reg->context;
}

// Skip view ops (VIEW, RESHAPE) - they don't compute, just metadata
static bool ggml_amd_is_view_op(enum ggml_op op) {
    return op == GGML_OP_VIEW || op == GGML_OP_RESHAPE;
}

extern "C" int ggml_backend_amd_schedule_graph(
    ggml_backend_sched_t sched,
    ggml_backend_t amd_backend,
    struct ggml_cgraph * graph,
    int phase) {

    if (!sched || !amd_backend || !graph || graph->n_nodes == 0) {
        return 0;
    }

    if (phase != GGML_AMD_PHASE_PREFILL && phase != GGML_AMD_PHASE_DECODE) {
        return 0;
    }

    struct ggml_amd_reg_context * reg_ctx = ggml_amd_get_reg_context(amd_backend);
    if (!reg_ctx) {
        return 0;
    }

    // Create the AMD region scheduler
    struct ggml_amd_scheduler * amd_sched = ggml_amd_scheduler_create(reg_ctx);
    if (!amd_sched) {
        return 0;
    }

    // Plan regions
    int n_regions = ggml_amd_scheduler_plan(amd_sched, graph, (enum ggml_amd_phase) phase);
    if (n_regions <= 0) {
        ggml_amd_scheduler_destroy(amd_sched);
        return 0;
    }

    // Assign nodes to the AMD backend based on regions.
    // The AMD scheduler forms contiguous regions of nodes that should
    // run on AMD providers. We assign each node in each region to the
    // AMD backend via the public API.
    int actual_regions = ggml_amd_scheduler_get_region_count(amd_sched);
    for (int r = 0; r < actual_regions; ++r) {
        struct ggml_amd_region * region = ggml_amd_scheduler_get_region(amd_sched, r);
        if (!region || !region->provider) {
            continue;
        }
        for (int i = region->node_start; i <= region->node_end && i < graph->n_nodes; ++i) {
            struct ggml_tensor * node = graph->nodes[i];
            if (node && !ggml_amd_is_view_op(node->op)) {
                ggml_backend_sched_set_tensor_backend(sched, node, amd_backend);
            }
        }
    }

    ggml_amd_scheduler_destroy(amd_sched);
    return n_regions;
}
