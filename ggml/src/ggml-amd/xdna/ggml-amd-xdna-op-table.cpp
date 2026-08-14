#include "../ggml-amd-internal.h"
#include "ggml.h"

#include <unordered_map>
#include <string>

struct ggml_amd_xdna_op_entry {
    const char * op_name;
    bool supported;
    int max_batch;
    int max_seq;
};

static std::unordered_map<std::string, ggml_amd_xdna_op_entry> g_xdna_op_table = {
    {"GGML_OP_MUL_MAT", {"GGML_OP_MUL_MAT", false, 0, 0}},
    {"GGML_OP_ADD", {"GGML_OP_ADD", false, 0, 0}},
    {"GGML_OP_RELU", {"GGML_OP_RELU", false, 0, 0}},
    {"GGML_OP_GELU", {"GGML_OP_GELU", false, 0, 0}},
    {"GGML_OP_SOFTMAX", {"GGML_OP_SOFTMAX", false, 0, 0}},
    {"GGML_OP_ROPE", {"GGML_OP_ROPE", false, 0, 0}},
};

bool ggml_amd_xdna_op_supported(const char * op_name) {
    if (!op_name) {
        return false;
    }
    auto it = g_xdna_op_table.find(op_name);
    if (it == g_xdna_op_table.end()) {
        return false;
    }
    return it->second.supported;
}
