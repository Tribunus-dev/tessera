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

// W3 task 3.5 (host-amd-implementation-plan.md; master-plan criteria
// 18-19): resolves `pack --quant=host-amd` to a `--tile` string by probing
// this host's AMD GPU arch (ts_detect_amd_arch). Only meant to be called
// when the user passed --quant but not an explicit --tile - "explicit
// --tile wins" is the caller's responsibility (quantize.cpp's ts_cli_pack),
// not this function's.
//
// Returns "tile-amd-rdna35" on a detected RDNA 3.5 iGPU (gfx1103/1150/
// 1151), "tile-amd-rdna3" on a detected discrete RDNA3 card, or "t640" as
// the safe fallback on any other host (GCN/RDNA1/RDNA2/RDNA4/CDNA*/unknown
// - matches the existing ts_detect_tile_config() Apple/Intel probe's "safe
// T640 default" convention). Prints exactly one stderr diagnostic line
// either way; never aborts - detection failure must not brick
// quantization.
std::string ts_resolve_host_amd_quant_tile();

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

// Computes ts_ternary_tensor::row_scale/lane_scale (see tessera-ternary.h
// for the full rationale): mean(|magnitude_source|) over nonzero-trit
// positions, at row granularity and TS_TRANSPORT_LANE_SIZE-element lane
// granularity, f16-encoded. Falls back to global_amp for any row/lane with
// no nonzero trits.
void ts_compute_row_lane_scale(const float * magnitude_source, const int8_t * ternary_flat,
                               int64_t out_dim, int64_t in_dim, float global_amp,
                               std::vector<uint16_t> & row_scale,
                               std::vector<uint16_t> & lane_scale);

// Synthesizes a full out_dim*in_dim per-element magnitude array from the
// best-available source in `tn`: core > lane_scale > row_scale >
// global_amp. Shared by every ts_pack_ternary_to_tile packer branch. See
// tessera-quant.cpp for the full fallback-tier rationale.
std::vector<float> ts_ternary_synth_magnitude(const ts_ternary_tensor & tn);

// Select repair residuals (outlier columns) for a quantized tensor.
// Returns indices of selected outlier columns.
std::vector<int32_t> ts_select_repair_residuals(
    const float * weights, const int8_t * ternary_flat,
    float page_scale, int64_t out_dim, int64_t in_dim,
    int64_t max_outliers, float threshold);

// Normalized AWQ scale: s_j = (|act_j|^alpha) / mean(|act|^alpha).
void ts_normalized_awq_scale(const float * act_scales, float alpha,
                             float * scale_out, int64_t in_dim);

// Runs the REAL AWQ or SEPTQ path (via ts_quantize_2d_ternary, not a
// cheap proxy) and returns the true relative Frobenius t2 = ||recon -
// weights||^2 / ||weights||^2, where recon is reassembled from the
// resulting trits + row/lane-scale magnitude hints (ts_ternary_synth_
// magnitude) plus the outlier CSR corrections - the same reconstruction
// the packer itself uses, so this is the actual shippable fidelity, not
// an approximation. Exists because ts_dispatch_forced_t2 (tessera-
// dispatch.cpp) routes both AWQ and SEPTQ through ts_quantize_mse_
// streaming, which has no use_septq awareness at all - it only reads
// alpha_scale/clip_scale from the expert profile, both of which are
// identical between AWQ's and SEPTQ's default profiles, so forced_t2
// mathematically cannot distinguish the two (verified: identical output
// for every tensor in a live run). Returns -1.0f on failure.
// calib_X/n_tokens: optional real per-token calibration activations
// (row-major [n_tokens][in_dim], from llama-imatrix's --calib-tokens via
// ts_imatrix_lookup_calib_x). When use_septq is set and calib_X is non-null,
// SEPTQ measures its true banded-Hessian output instead of the diagonal
// fallback - so live algorithm selection compares what would actually ship,
// not a mismatched proxy. ref_output: optional (n_tokens x out_dim) =
// calib_X @ weights^T (see ts_awq_compute_ref_output). When both calib_X and
// ref_output are non-null, the internal AWQ alpha resolve (which every path
// here runs, not just the AWQ candidate) uses the true layer-output-MSE
// search (ts_awq_scale_search_layer_output) instead of the coarser
// weight-magnitude proxy (ts_awq_scale_search) - so the AWQ candidate's own
// measurement, and the alpha pre-scale SEPTQ's measurement builds on top of,
// both reflect what would actually ship. nullptr/0 reproduces prior behavior
// exactly.
float ts_measure_true_t2(const float * weights, const float * act_scales,
                         int64_t out_dim, int64_t in_dim,
                         bool use_septq, float alpha, float clip,
                         float outlier_thresh, uint32_t seed,
                         const float * calib_X = nullptr, int64_t n_tokens = 0,
                         const float * ref_output = nullptr);

// Reconstructs a ts_ternary_tensor back to a dense [out_dim, in_dim] float
// array in ORIGINAL weight space (not AWQ column-scaled space) - trits *
// ts_ternary_synth_magnitude, unscaled by awq_input_scale when present, then
// the outlier CSR overrides those positions with their exact original value.
// Same reconstruction ts_measure_true_t2 and the real packer both use, so
// this is the actual shippable fidelity, not an approximation. recon_out
// must have room for out_dim*in_dim floats.
void ts_ternary_tensor_reconstruct(const ts_ternary_tensor & tn,
                                   int64_t out_dim, int64_t in_dim,
                                   float * recon_out);

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

// Computes ref_output (n_tokens x out_dim) = calib_X @ weights^T, the
// reference input to ts_awq_scale_search_layer_output / the layer_output_
// search branch inside ts_quantize_2d_ternary. BLAS-accelerated when
// available (TS_HAS_CBLAS), scalar fallback otherwise. No-op (leaves
// ref_output_out untouched) if any required input is missing.
void ts_awq_compute_ref_output(const float * weights, const float * calib_X,
                               int64_t out_dim, int64_t in_dim,
                               int64_t n_tokens, float * ref_output_out);

// Top-level 2D quantization. Produces all 6 GGUF components.
// Returns 0 on success.
struct ts_quant_result_2d {
    std::vector<uint32_t> packed;
    // AMD RDNA3 packing only (TS_PACK_AMD_RDNA3): the WMMA-native packed
    // element is a real signed int8 magnitude (symmetric linear quant), not
    // a radix-243 word - see quantize_row_tessera_t_rdna3_ref in
    // ggml-quants.c, the reference this mirrors. `packed` above (T640/
    // TS_PACK_RADIX243) and `packed_i8` here are mutually exclusive; exactly
    // one is populated depending on the tile config's packing kind.
    std::vector<int8_t>   packed_i8;
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

    // FLRQ (low-rank multiplicative pre-scale, tessera-lrq.h) and DartQuant
    // (learned block-diagonal rotation, tessera-dartquant.h) regime
    // experts. Mutually exclusive with use_septq and each other -
    // ts_quantize_2d_ternary checks them in a fixed priority order (septq
    // > flrq > dartquant > AWQ), documented at the dispatch sites.
    bool      use_flrq;
    int64_t   flrq_rank;        // 0 -> default (32)
    int64_t   flrq_iters;       // 0 -> default (50)
    bool      use_dartquant;
    int64_t   dartquant_block;  // 0 -> default (128, clamped to a divisor of in_dim)
    int64_t   dartquant_iters;  // 0 -> default (30)
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
//
// Overload (1): unified params — all experts use the same ts_quant_params_2d.
// Overload (2): per_expert_params != nullptr — expert e uses params[e].
//                 This is the Tier 3 per-expert regime routing path. The caller
//                 is responsible for allocating `per_expert_params` with at least
//                 `n_experts` entries; when `per_expert_params[e]` is null the
//                 unified `params` fallback is used for that expert.
int ts_quantize_3d(const float * weights,
                   const float * act_scales,
                   const float * calib_X,
                   const float * ref_output,
                   const float * imatrix,
                   int64_t n_experts, int64_t out_dim, int64_t in_dim,
                   int64_t n_tokens,
                   const ts_quant_params_2d * params,
                   std::vector<ts_quant_result_2d> * results);
int ts_quantize_3d(const float * weights,
                   const float * act_scales,
                   const float * calib_X,
                   const float * ref_output,
                   const float * imatrix,
                   int64_t n_experts, int64_t out_dim, int64_t in_dim,
                   int64_t n_tokens,
                   const ts_quant_params_2d * params,          // unified fallback
                   const ts_quant_params_2d * const * per_expert_params,  // [n_experts]
                   std::vector<ts_quant_result_2d> * results);
