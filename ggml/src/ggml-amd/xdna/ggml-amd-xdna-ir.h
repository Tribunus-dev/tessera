#ifndef GGML_AMD_XDNA_IR_H
#define GGML_AMD_XDNA_IR_H

#include <vector>
#include <string>

struct ggml_amd_xdna_ir {
    std::string name;
    std::vector<int> shape;
    std::string dtype;
};

struct ggml_amd_xdna_compiled_region {
    std::string name;
    std::vector<uint8_t> binary;
    bool valid;
};

#endif // GGML_AMD_XDNA_IR_H
