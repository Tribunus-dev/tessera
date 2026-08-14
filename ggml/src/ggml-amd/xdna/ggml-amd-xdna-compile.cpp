#include "../ggml-amd-internal.h"
#include "ggml.h"
#include "ggml-amd-xdna-ir.h"

#include <vector>
#include <string>

bool ggml_amd_xdna_compile_region(
    const struct ggml_amd_xdna_ir * ir,
    struct ggml_amd_xdna_compiled_region * out_compiled) {

    if (!ir || !out_compiled) {
        return false;
    }

    out_compiled->name = ir->name;
    out_compiled->binary.clear();
    out_compiled->valid = false;

    return false;
}
