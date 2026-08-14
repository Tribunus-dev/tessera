#include "ggml-amd-internal.h"
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-impl.h"

#include <vector>
#include <cstring>

struct ggml_amd_region_formation_context {
    struct ggml_amd_provider ** providers;
    int n_providers;
    struct ggml_cgraph * graph;
    std::vector<struct ggml_amd_region *> regions;
};

static bool ggml_amd_provider_supports_tensor(struct ggml_amd_provider * provider, const struct ggml_tensor * tensor) {
    if (!provider || !provider->iface || !provider->iface->supports_op) {
        return false;
    }
    return provider->iface->supports_op(provider, tensor);
}

static struct ggml_amd_provider * ggml_amd_select_provider_for_node(
    struct ggml_amd_provider ** providers,
    int n_providers,
    const struct ggml_tensor * node) {

    for (int i = 0; i < n_providers; i++) {
        if (ggml_amd_provider_supports_tensor(providers[i], node)) {
            return providers[i];
        }
    }
    return nullptr;
}

std::vector<struct ggml_amd_region *> ggml_amd_form_regions(
    struct ggml_amd_provider ** providers,
    int n_providers,
    struct ggml_cgraph * graph) {

    std::vector<struct ggml_amd_region *> regions;

    if (!graph || graph->n_nodes == 0) {
        return regions;
    }

    int region_start = 0;
    struct ggml_amd_provider * current_provider = ggml_amd_select_provider_for_node(providers, n_providers, graph->nodes[0]);

    for (int i = 1; i < graph->n_nodes; i++) {
        struct ggml_amd_provider * node_provider = ggml_amd_select_provider_for_node(providers, n_providers, graph->nodes[i]);

        if (node_provider != current_provider) {
            auto region = new ggml_amd_region();
            region->node_start = region_start;
            region->node_end = i - 1;
            region->provider = current_provider;
            region->inputs = nullptr;
            region->n_inputs = 0;
            region->outputs = nullptr;
            region->n_outputs = 0;
            region->state_tensors = nullptr;
            region->n_state_tensors = 0;
            region->phase = GGML_AMD_PHASE_DECODE;
            regions.push_back(region);

            region_start = i;
            current_provider = node_provider;
        }
    }

    if (region_start < graph->n_nodes) {
        auto region = new ggml_amd_region();
        region->node_start = region_start;
        region->node_end = graph->n_nodes - 1;
        region->provider = current_provider;
        region->inputs = nullptr;
        region->n_inputs = 0;
        region->outputs = nullptr;
        region->n_outputs = 0;
        region->state_tensors = nullptr;
        region->n_state_tensors = 0;
        region->phase = GGML_AMD_PHASE_DECODE;
        regions.push_back(region);
    }

    return regions;
}

void ggml_amd_region_free(struct ggml_amd_region * region) {
    if (!region) {
        return;
    }
    delete[] region->inputs;
    delete[] region->outputs;
    delete[] region->state_tensors;
    delete region;
}

void ggml_amd_regions_free(std::vector<struct ggml_amd_region *> & regions) {
    for (auto region : regions) {
        ggml_amd_region_free(region);
    }
    regions.clear();
}
