// tessera-ternary.h - Tessera Ternary Transport (`.ttt`) artifact definitions.
//
// The `.ttt` format is the tile-AGNOSTIC ternary representation of a model's
// weight matrices. It carries the ternary decisions (-1/0/+1 per element),
// the CSR outlier corrections, the AWQ per-channel scales, and the global
// amplitude threshold. These are the expensive, imatrix-driven outputs that
// are computed once on the build server.
//
// The tile-SPECIFIC packing (grouping trits into pages/lanes, computing
// per-page/lane scales, packing radix-243 or 2-bit words) is derived from a
// `.ttt` on the client at download time for the detected GPU's optimal tile
// geometry (T640 for Apple Silicon, T512/T1024 for Intel, future variants).
// Packing is cheap O(n) regrouping with no quality loss (the trits don't
// change; only the page/lane scales are recomputed per the new grouping).
//
// See docs/tile-neutral-export-design.md for the full architecture.

#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// ggml-common.h only emits its C++ definitions when GGML_COMMON_DECL_CPP is
// defined before the include; without it the header is a no-op and ts_tile_config
// would be left undefined. Match the pattern used by ggml-cpu/ops.cpp etc.
#ifndef GGML_COMMON_DECL_CPP
#  define GGML_COMMON_DECL_CPP
#  include "ggml-common.h"
#else
#  include "ggml-common.h"
#endif

// One 2D weight matrix in tile-agnostic ternary form.
struct ts_ternary_tensor {
    std::vector<int8_t>   trits;                 // [out_dim * in_dim], -1/0/+1 (outlier positions zeroed)
    std::vector<int32_t>  outlier_row_offsets;   // [out_dim + 1], CSR row pointers (prefix sum)
    std::vector<int32_t>  outlier_cols;          // [nnz], absolute column indices within each row
    std::vector<uint16_t> outlier_vals;          // [nnz], f16 AWQ-scaled weight at each outlier
    std::vector<float>    awq_scale;             // [in_dim], per-input-channel AWQ scale (wscale[c])
    std::vector<float>    awq_input_scale;       // [in_dim], AWQ input scale (for activation quant)
    std::vector<uint16_t> act_scale;             // [in_dim], f16 per-channel activation scale (empty if alpha==0)
    float                 global_amp = 0.0f;     // whole-tensor mean(|ws|) — the ternary threshold
    float                 best_alpha = 0.0f;     // resolved AWQ alpha (search result); 0 = no AWQ
    int64_t               out_dim = 0;
    int64_t               in_dim  = 0;

    // Clipped AWQ-scaled weights [out_dim * in_dim] needed by the tile packer's
    // scale-fitting step (ts_compute_scales reads |core[idx]| at every non-zero
    // trit). This is derived from the original weights + wscale + clip, which
    // are not otherwise reconstructable from the ternary decisions alone; it is
    // carried alongside the trits so the client-side packer can refit page/lane
    // scales for any tile geometry without the raw weights.
    std::vector<float>    core;

    int64_t n_elements() const { return out_dim * in_dim; }
    int64_t n_outliers() const { return (int64_t) outlier_cols.size(); }
};

// Full model in `.ttt` form: a collection of ternary tensors + the metadata
// needed to reconstruct the GGUF header on the client side.
struct ts_ternary_model {
    std::string arch;                 // e.g. "qwen35moe"
    std::map<std::string, std::string> hparams;  // KV metadata (n_layer, n_embd, n_vocab, ...)
    std::map<std::string, ts_ternary_tensor> tensors;  // keyed by GGUF tensor name

    // Tokenizer + chat template travel as separate files in the .ttt directory,
    // not in this struct. The writer/reader copy them verbatim.
};
