#include "../ggml-amd-internal.h"
#include "ggml.h"
#include "ggml-amd-xdna-ir.h"

#include <vector>
#include <string>

bool ggml_amd_xdna_translate_region(
    struct ggml_amd_region * region,
    struct ggml_amd_xdna_ir * out_ir) {

    if (!region || !out_ir) {
        return false;
    }

    out_ir->name = "region_" + std::to_string(region->node_start) + "_" + std::to_string(region->node_end);
    out_ir->shape.clear();
    out_ir->dtype = "f32";

    return false;
}
