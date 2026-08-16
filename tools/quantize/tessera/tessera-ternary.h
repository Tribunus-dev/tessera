// tessera-ternary.h - Tessera tile-neutral safetensors artifact definitions.
//
// The tile-neutral safetensors format is the tile-AGNOSTIC ternary
// representation of a model's weight matrices. It carries the ternary
// decisions (-1/0/+1 per element), the CSR outlier corrections, the AWQ
// per-channel scales, and the global amplitude threshold. These are the
// expensive, imatrix-driven outputs that are computed once on the build
// server.
//
// The tile-SPECIFIC packing (grouping trits into pages/lanes, computing
// per-page/lane scales, packing radix-243 or 2-bit words) is derived from
// the tile-neutral safetensors directory on the client at download time for
// the detected GPU's optimal tile geometry (T640 for Apple Silicon,
// T512/T1024 for Intel, future variants). Packing is cheap O(n) regrouping
// with no quality loss (the trits don't change; only the page/lane scales
// are recomputed per the new grouping).
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

// Fixed lane granularity for the cheap row_scale/lane_scale magnitude
// hints shipped in the tile-neutral safetensors transport (see
// ts_ternary_tensor::lane_scale below) - matches AMD RDNA3's own native
// tile lane size (docs/amd-tile-format-spec.md 3.4) exactly, so the
// host-amd pack path uses it with no re-binning; other tile geometries
// (T640's 20-element lanes) re-bin by averaging.
#define TS_TRANSPORT_LANE_SIZE 8

// Ceiling on the DartQuant rotation block size K shippable in the
// tile-neutral safetensors transport (ts_ternary_tensor::dartquant_rotation
// below). K x K f16 costs K*K*2 bytes regardless of tensor size; 128 keeps
// that at 32 KiB/tensor even though ts_dartquant_qr_orth (tessera-dartquant.h)
// itself accepts any K dividing in_dim.
#define TS_DARTQUANT_MAX_BLOCK 128

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

    // Clipped AWQ-scaled weight magnitudes [out_dim * in_dim] as f16, needed by
    // the tile packer's scale-fitting step (ts_compute_scales reads |core[idx]|
    // at every non-zero trit). Stored as f16 (2 bytes/elem) to halve transport
    // size vs f32; the precision loss is negligible for mean(|core|) per lane.
    // NOT shipped in the tile-neutral safetensors transport (ttt-writer.cpp) -
    // row_scale/lane_scale below are the shipped, cheap substitute.
    std::vector<uint16_t> core;

    // row_scale/lane_scale: mean(|w|) over nonzero-trit positions, at two
    // granularities cheap enough to actually ship in the tile-neutral
    // safetensors transport (unlike core above, which is the same size as
    // the tensor itself). Both are f16 bit patterns. Measured on a real
    // tensor (blk.0.attn_q.weight, Granite 4.1 3B): global-scalar
    // reconstruction cosine=0.840; row_scale alone reaches 0.873 at 0.02%
    // of the tensor's byte size; row_scale+lane_scale together reach
    // further still (see the lane-fallback comment below) at ~6% - a real,
    // deliberate tradeoff point between global_amp's near-zero cost and
    // core's 50%+ cost for the oracle ceiling of ~0.95. When empty (a
    // tile-neutral safetensors file written before this field existed, or
    // a computation path that hasn't populated them), the packer falls
    // back to global_amp exactly as before - purely additive, backward
    // compatible.
    //
    // row_scale: [out_dim] - one value per output row, the coarse level of
    // the hierarchy (fitting granularity a "row" is agnostic to any tile
    // geometry's own page/lane sizing).
    std::vector<uint16_t> row_scale;
    // lane_scale: [out_dim * ceil(in_dim / TS_TRANSPORT_LANE_SIZE)] - the
    // fine level, at a FIXED 8-element granularity (TS_TRANSPORT_LANE_SIZE,
    // tessera-quant.h) chosen to match the AMD RDNA3 tile format's own
    // native lane size exactly (docs/amd-tile-format-spec.md 3.4); T640's
    // packer (20-element lanes) re-bins by averaging the 8-element values
    // that fall within each of its own lanes - an approximation there,
    // exact for RDNA3.
    std::vector<uint16_t> lane_scale;

    // dartquant_rotation: R^T, the TRANSPOSE of the learned K x K
    // orthogonal rotation ts_dartquant_qr_orth returns (f16, row-major),
    // applied block-diagonally along in_dim (the same block repeated
    // across every in_dim/K column block - tessera-dartquant.h). Trits are
    // decided on `weights @ blockdiag(R)` (ts_dartquant_apply's own
    // convention), so reconstructing `W @ X` from the shipped Wrot
    // requires rotating activations by blockdiag(R)^T first: Wrot @ (R^T @
    // X) == (W @ R) @ (R^T @ X) == W @ X for orthogonal R. Storing the
    // TRANSPOSE here (not R itself) lets the consumer compute that via a
    // single ggml_mul_mat(dartquant_rotation, activations) with no runtime
    // transpose op - see llama-graph.cpp's DartQuant wiring, verified
    // numerically against ggml_mul_mat's actual index convention (easy to
    // get backwards silently) before relying on it. Unlike row_scale/
    // lane_scale (pure reconstruction hints, discarded after informing the
    // trit pattern), this changes the matmul's BASIS and so must travel
    // with the tensor. Empty dartquant_rotation (the common case) means no
    // rotation - backward compatible with every tensor shipped before this
    // field existed. Cheap to ship: K <= 128 regardless of tensor size
    // (see TS_DARTQUANT_MAX_BLOCK), unlike the full in_dim x in_dim R the
    // Python research reference (per_tensor_calibrate.py) uses - that
    // full-size R costs as much as the tensor itself and was never meant
    // as a shippable transport artifact.
    int64_t               dartquant_block_size = 0;
    std::vector<uint16_t> dartquant_rotation;

    int64_t n_elements() const { return out_dim * in_dim; }
    int64_t n_outliers() const { return (int64_t) outlier_cols.size(); }
};

// Full model in tile-neutral form: a collection of ternary tensors + the
// metadata needed to reconstruct the GGUF header on the client side.
struct ts_ternary_model {
    std::string arch;                 // e.g. "qwen35moe"
    std::map<std::string, std::string> hparams;  // KV metadata (n_layer, n_embd, n_vocab, ...)
    std::map<std::string, ts_ternary_tensor> tensors;  // keyed by GGUF tensor name

    // Tokenizer + chat template travel as separate files in the safetensors
    // directory, not in this struct. The writer/reader copy them verbatim.
};
