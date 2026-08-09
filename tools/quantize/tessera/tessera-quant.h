#pragma once

//
// tessera-quant.h
//
// Tile640 quantization primitives: ternarization, packing, scale
// computation, AWQ scale search, and the top-level quantize_2d /
// quantize_3d entry points. Ports tools/tile640/quantize_v3.py.
//

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <optional>

// forward declarations (full definitions in ggml-common.h / tessera-ternary.h)
struct ts_quant_params;
struct ts_tile_config;
struct ts_ternary_tensor;

// Ternarize weights with optional activation-aware scaling.
// weights: (out_dim x in_dim) row-major.
// act_scales: (in_dim,) per-channel activation magnitudes, or nullptr.
// alpha: AWQ exponent (0 = no AWQ scaling).
// clip: outlier clip threshold (0 = no clip).
// ternary_out: (out_dim x in_dim) int8 {-1, 0, +1}, pre-allocated.
// Returns the global scale factor.
float ts_ternarize_with_acts(const float * weights, const float * act_scales,
                             float alpha, float clip,
                             int8_t * ternary_out,
                             int64_t out_dim, int64_t in_dim);

// Fused scale-clip-ternarize: writes ws[r,c] = W[r,c] * wscale[c], optionally
// clips per row, computes the mean-of-abs threshold, and produces the ternary
// pattern - all in a single streaming pass over W. Replaces the unfused
// sequence ts_mat_scale_cols -> copy -> clip -> ts_ternarize_with_acts ->
// ts_vec_meanabs, cutting ~5 full-tensor passes down to 2 (one for threshold,
// one for ternarize; unavoidable because threshold needs a full reduction
// before ternary can be assigned).
//
// ws_out: (out_dim x in_dim) pre-allocated, receives the scaled (+ optionally
//         clipped) weights so downstream passes (outlier selection, MSE) can
//         reuse them without re-scaling.
// core_out: (out_dim x in_dim) pre-allocated, receives the clipped ws (same as
//           ws when clip is disabled). Needed by ts_compute_scales which
//           expects the clipped weights.
// ternary_out: (out_dim x in_dim) pre-allocated int8.
// Returns the global_amp (mean of abs of ws).
float ts_scale_clip_ternarize_fused(const float * weights,
                                    const float * wscale,
                                    float clip,
                                    float * ws_out,
                                    float * core_out,
                                    int8_t * ternary_out,
                                    int64_t out_dim, int64_t in_dim);

// Pack ternary row into Tile640 wire format.
// ternary_flat: (out_dim x in_dim) int8 {-1,0,+1}.
// packed_out: pre-allocated int32 buffer, size = out_dim * pages_per_row * 32.
// page_scales_out: (out_dim x pages_per_row) float16 (stored as uint16).
// lane_scales_out: (out_dim x pages_per_row * 32) int8.
void ts_pack_tile640(const int8_t * ternary_flat,
                     uint32_t * packed_out,
                     uint16_t * page_scales_out,
                     int8_t * lane_scales_out,
                     int64_t out_dim, int64_t in_dim);

// Tile-config-parameterized packer: groups trits into radix-243 words (T640)
// per the page/lane geometry in `config`. page_scales_placeholder and
// lane_scales_placeholder receive ts_pack_tile's placeholder scales (unit page
// scale, per-lane 127/1 activity flag); callers that want the fitted scales
// run ts_compute_scales afterwards (see ts_pack_ternary_to_tile).
// Only TS_PACK_RADIX243 is implemented; TS_PACK_2BIT asserts (T512/T1024 path).
void ts_pack_tile(const int8_t * ternary, const ts_tile_config * config,
                  uint32_t * packed, uint16_t * page_scales_placeholder,
                  int8_t * lane_scales_placeholder,
                  int64_t out_dim, int64_t in_dim);

// Compute page and lane scales from weights and ternary encoding.
// Writes into page_scales and lane_scales (pre-allocated).
void ts_compute_scales(const float * weights, const int8_t * ternary_flat,
                       uint16_t * page_scales, int8_t * lane_scales,
                       int64_t out_dim, int64_t in_dim);

// Tile-config-parameterized scale fit: reads |core[idx]| at every non-zero
// trit and fits per-page (f16) + per-lane (int8) scales for the geometry in
// `config`. `core` is the clipped AWQ-scaled weight buffer (the same one the
// ternary step produced).
void ts_compute_scales(const float * core, const int8_t * ternary_flat,
                       const ts_tile_config * config,
                       uint16_t * page_scales, int8_t * lane_scales,
                       int64_t out_dim, int64_t in_dim);

// Select repair residuals (outlier columns) for a quantized tensor.
// Returns indices of selected outlier columns.
std::vector<int32_t> ts_select_repair_residuals(
    const float * weights, const int8_t * ternary_flat,
    float page_scale, int64_t out_dim, int64_t in_dim,
    int64_t max_outliers, float threshold);

// Normalized AWQ scale: s_j = (|act_j|^alpha) / mean(|act|^alpha).
void ts_normalized_awq_scale(const float * act_scales, float alpha,
                             float * scale_out, int64_t in_dim);

// AWQ scale search: grid search over alpha in [0, 1] minimizing
// layer-output MSE. Returns best alpha.
float ts_awq_scale_search(const float * weights, const float * act_scales,
                          const float * calib_activations,
                          int64_t out_dim, int64_t in_dim,
                          int64_t n_tokens, int64_t n_grid);

// AWQ scale search using layer-output reconstruction (preferred).
// calib_X: (n_tokens x in_dim) calibration activations.
// ref_output: (n_tokens x out_dim) = calib_X @ weights^T (FP16 reference).
float ts_awq_scale_search_layer_output(
    const float * weights, const float * act_scales,
    const float * calib_X, const float * ref_output,
    int64_t out_dim, int64_t in_dim,
    int64_t n_tokens, int64_t n_grid);

// Top-level 2D quantization. Produces all 6 GGUF components.
// Returns 0 on success.
struct ts_quant_result_2d {
    std::vector<uint32_t> packed;
    std::vector<uint16_t> page_scales;
    std::vector<int8_t>   lane_scales;
    std::vector<int32_t>  outlier_row_offsets;  // size out_dim + 1
    std::vector<int32_t>  outlier_cols;
    std::vector<uint16_t> outlier_vals;         // f16
    std::vector<uint16_t> act_scale;            // f16, empty if alpha == 0
    float                 best_alpha;
    float                 mse;
    std::vector<float>    recon;                // W_hat (out_dim x in_dim) in the
                                                // original weight space (AWQ scale
                                                // removed); kernel-direct fitness
};

struct ts_quant_params_2d {
    float     alpha;            // AWQ exponent (0 = auto-search)
    float     clip;             // outlier clip (0 = none)
    int64_t   max_outliers;     // max outlier columns per row
    float     outlier_thresh;   // outlier selection threshold
    bool      use_imatrix;      // use imatrix for MSE weighting
    bool      use_septq;        // use SEPTQ Hessian compensation
    int64_t   awq_grid;         // grid points for alpha search (default 20)
    uint32_t  seed;             // determinism
};

int ts_quantize_2d(const float * weights,
                   const float * act_scales,      // (in_dim,) or nullptr
                   const float * calib_X,         // (n_tokens x in_dim) or nullptr
                   const float * ref_output,      // (n_tokens x out_dim) or nullptr
                   const float * imatrix,         // (in_dim,) or nullptr
                   int64_t out_dim, int64_t in_dim, int64_t n_tokens,
                   const ts_quant_params_2d * params,
                   ts_quant_result_2d * result);

// Tile-AGNOSTIC ternary-decision step: AWQ alpha search, fused scale/clip/
// ternarize (global threshold), repair-residual outlier selection, CSR build,
// and act-scale store. Produces a ts_ternary_tensor carrying the trits
// (outlier positions zeroed), the clipped AWQ-scaled core, the outlier CSR,
// and the AWQ/act scales - everything that does not depend on a page/lane
// geometry. Does NOT pack into tile words or compute page/lane scales; pair
// with ts_pack_ternary_to_tile (or the bespoke packer for a new tile).
// Returns 0 on success.
int ts_quantize_2d_ternary(const float * weights, const float * act_scales,
                           const float * calib_X, const float * ref_output,
                           const float * imatrix,
                           int64_t out_dim, int64_t in_dim, int64_t n_tokens,
                           const ts_quant_params_2d * params,
                           ts_ternary_tensor * result);

// Tile-SPECIFIC client-side packer: takes a tile-agnostic ternary tensor and a
// tile config, packs the radix-243 words, refits the page/lane scales for the
// requested geometry, and copies the outlier CSR + act scale verbatim from the
// tensor. Returns 0 on success.
int ts_pack_ternary_to_tile(const ts_ternary_tensor & tn,
                            const ts_tile_config & config,
                            ts_quant_result_2d * result);

// Streaming MSE-only fitness: computes the same MSE as ts_quantize_2d but
// row-by-row with O(in_dim) scratch instead of O(out_dim*in_dim). Used by
// the GA evaluator to score candidates without allocating the full ws/core/
// recon/packed buffers (700 MB -> ~132 KB per call for a 4096x11008 tensor).
//
// Returns the mean squared reconstruction error, or -1.0f on error. The MSE
// matches ts_quantize_2d's: same per-row scale/clip/ternarize/dequant, and
// the error is measured against the UNCLIPPED scaled weights (the clip only
// shapes the ternary codes). Only the reduction precision may differ.
//
// When the caller needs the full ts_quant_result_2d (for the winning
// candidate), call ts_quantize_2d separately - it runs once per layer, not
// once per candidate.
float ts_quantize_mse_streaming(const float * weights,
                                const float * act_scales,
                                float alpha, float clip,
                                int64_t out_dim, int64_t in_dim);

// 3D (MoE expert) variant: flattens (n_experts x out_dim x in_dim) and
// calls quantize_2d per expert. Results concatenated.
int ts_quantize_3d(const float * weights,
                   const float * act_scales,
                   const float * calib_X,
                   const float * ref_output,
                   const float * imatrix,
                   int64_t n_experts, int64_t out_dim, int64_t in_dim,
                   int64_t n_tokens,
                   const ts_quant_params_2d * params,
                   std::vector<ts_quant_result_2d> * results);
