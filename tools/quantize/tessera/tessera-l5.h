#pragma once

//
// tessera-l5.h
//
// L5 sensitivity scoring and iterative requantization orchestrator.
// Ports tools/tessera/l5_metrics.py and l5_orchestrator.py.
//

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <map>

#include "tessera-l2-diff.h"    // ts_l2_report (adaptive requant input)

// --- Sensitivity metrics (l5_metrics.py) ---

// Per-component score map: tensor_name -> score.
using ts_score_map = std::map<std::string, float>;

// Imatrix magnitude scorer: score = mean(|act|) per tensor.
ts_score_map ts_l5_imatrix_magnitude(const float * imatrix_vals,
                                     const char ** tensor_names,
                                     const int64_t * tensor_dims,
                                     int64_t n_tensors);

// Gradient proxy: score ~ ||dL/dW|| estimated from output sensitivity.
ts_score_map ts_l5_gradient_proxy(const float * output_sensitivity,
                                  const char ** tensor_names,
                                  int64_t n_tensors);

// Layer position prior: earlier/later layers get different priors.
ts_score_map ts_l5_layer_position_prior(const char ** tensor_names,
                                        int64_t n_tensors,
                                        int64_t n_layers_total);

// Combine multiple scorers with weights.
ts_score_map ts_l5_combine(const ts_score_map ** scorers,
                           const float * weights,
                           int64_t n_scorers);

// Momentum EMA tracker for streaming sensitivity updates.
struct ts_l5_ema {
    ts_score_map state;
    float        beta;      // EMA decay, default 0.9
};

void ts_l5_ema_init(ts_l5_ema * ema, float beta);
void ts_l5_ema_update(ts_l5_ema * ema, const ts_score_map * new_scores);

// Percentile rank normalization: scores -> [0, 1] percentile.
ts_score_map ts_l5_percentile_rank(const ts_score_map * scores);

// Pick top fraction of tensors by score.
std::vector<std::string> ts_l5_pick_top(const ts_score_map * scores,
                                        float fraction);

// Expected MSE delta from requantizing a tensor.
float ts_l5_expected_mse_delta(const char * tensor_name,
                               float current_score, float target_score);

// Quantization ladder stepping.
int         ts_l5_ladder_index(const char * qtype);
const char * ts_l5_step_up(const char * qtype);    // higher precision
const char * ts_l5_step_down(const char * qtype);  // lower precision

// --- Orchestrator (l5_orchestrator.py) ---

enum ts_requant_action_type {
    TS_REQUANT_NONE     = 0,
    TS_REQUANT_STEP_UP  = 1,    // increase precision
    TS_REQUANT_STEP_DOWN = 2,   // decrease precision
};

struct ts_requant_action {
    std::string tensor_name;
    ts_requant_action_type type;
    std::string from_qtype;
    std::string to_qtype;
    float expected_delta;
};

struct ts_requant_plan {
    std::vector<ts_requant_action> actions;
    float total_expected_delta;
    int64_t generation;
};

struct ts_orchestrator_params {
    int64_t max_generations;    // default 10
    float     top_fraction;     // fraction of tensors to consider, default 0.1
    float     delta_threshold;  // minimum expected delta to act, default 0.01
    float     ema_beta;         // EMA decay for streaming scores
    bool      verbose;
};

// Run one orchestrator generation: score, plan, return actions.
int ts_l5_orchestrate_step(const ts_score_map * sensitivity,
                           const char ** current_qtypes,
                           int64_t n_tensors,
                           int64_t generation,
                           const ts_orchestrator_params * params,
                           ts_requant_plan * plan);

// --- Adaptive requantization (L5 closes the L2 loop) ---
//
// L2 flags tensors whose divergence overshoots their type baseline; this
// turns those flags into tightened requantization params. The worse the
// overshoot, the more alpha/clip are reduced. Applying the plan
// (re-quantize + GGUF rewrite) goes through the existing quantize /
// GGUF-writer path, matching ts_l5_orchestrate_step which also emits a
// plan for downstream application.

// --- Hessian sensitivity scoring (v3.1 spec §9) ---
//
// The shipped imatrix / gradient / layer-position scorers are
// *first-order* signals. The Hessian-based scorer is the
// *second-order* signal: it answers "which weights actually matter
// under a calibration forward" via the OBQ criterion
// (Frantar & Alistarh 2022, arXiv:2208.11580):
//
//   omega_ij = (w_ij - quant(w_ij))^2 / [H^{-1}]_ii
//
// where H = 2 X X^T is the calibration Hessian (X is the imatrix
// corpus) and [H^{-1}]_ii is the i-th diagonal of the Hessian
// inverse. The per-tensor sensitivity is the mean over (i, j) of
// omega_ij. This is the same criterion GPTQ (Frantar 2023,
// arXiv:2210.17323) uses for the per-weight rounding, and SpQR
// (Dettmers 2023, arXiv:2306.03078) uses for outlier selection.
//
// The struct-based API is the v1/v2 swap point (spec §9.3 risk 3):
//   v1 = TS_L5_SOI_IN_CORE: full Cholesky factor in memory
//   v2 = TS_L5_SOI_NYSTROM: low-rank Nystrom approximation
//   v2+= TS_L5_SOI_STREAMING: out-of-core Cholesky streaming
// The v1 path computes the Cholesky once per in_dim and reuses it
// across all tensors sharing that in_dim (the 12B case is one
// factor per in_dim = 4096, ~10 s on M-series Metal). The v2 path
// is an internal implementation change with no caller updates.

// Bump on every change to the Hessian scorer's math, damping, or
// Cholesky block size. Used as the DuckDB cache key suffix so stale
// cache entries invalidate silently rather than producing wrong
// scores (spec §13 risk 2).
#define TS_L5_HESSIAN_SCORER_VERSION 1

// Source of the second-order info (spec §9.3).
enum ts_l5_soi_source {
    TS_L5_SOI_IN_CORE   = 0,  // v1: full Cholesky in memory
    TS_L5_SOI_NYSTROM   = 1,  // v2: low-rank Nystrom (deferred)
    TS_L5_SOI_STREAMING = 2,  // v2+: out-of-core streaming (deferred)
};

// Second-order info. The v1 (in-core Cholesky), v2 (Nystrom), and
// v2+ (streaming) paths share a single dispatch through
// ts_l5_hessian_sensitivity; exactly one of the source-specific
// fields is populated per `source` value.
struct ts_l5_second_order_info {
    ts_l5_soi_source source;
    int64_t          in_dim;

    // IN_CORE: lower-triangular Cholesky factor of (1/2) * H, stored
    // as a flat (in_dim, in_dim) row-major buffer. Only the diagonal
    // L_ii is consumed (since [H^{-1}]_ii = L_ii^2 for a lower
    // triangular factor). Caller-owned; not freed by the scorer.
    const float * L_in_core;

    // NYSTROM: rank-k approximation. nystrom_U is (in_dim, nystrom_k)
    // and nystrom_W_inv is (nystrom_k, nystrom_k). v2 is deferred;
    // calling with this source returns an empty map.
    int64_t       nystrom_k;
    const float * nystrom_U;
    const float * nystrom_W_inv;

    // STREAMING: caller advances streaming_row between calls. v2+ is
    // deferred; calling with this source returns an empty map.
    int64_t       streaming_row;
};

// Hessian-based per-tensor sensitivity (OBQ / GPTQ / SpQR criterion,
// spec §9.3).
//
// weights_bf16 / weights_quant: concatenated (in_dim, out_dim)
// row-major weight matrices per tensor, one tensor after another.
// The offset of tensor i's matrix is
//   sum over k < i of (tensor_in_dims[k] * tensor_out_dims[k]).
// When weights_quant is nullptr, the scorer treats it as identical
// to weights_bf16 (zero quantization error -> zero sensitivity);
// this is the "weight-only diagnostic" mode used to validate the
// formula on a known tensor.
//
// Returns a map tensor_name -> sensitivity normalized to [0, 1]
// (peak tensor = 1.0). Returns an empty map on n_tensors <= 0 or
// any null required pointer. NYSTROM and STREAMING sources return
// an empty map in v1 (deferred to v2).
ts_score_map ts_l5_hessian_sensitivity(
    const float * weights_bf16,
    const float * weights_quant,
    const int64_t * tensor_in_dims,
    const int64_t * tensor_out_dims,
    const ts_l5_second_order_info * soi,
    const char ** tensor_names,
    int64_t n_tensors);

struct ts_l5_adaptive_params {
    float alpha_scale;    // base alpha multiplier (< 1 tightens), default 0.5
    float clip_scale;     // base clip multiplier (< 1 tightens), default 0.5
    float min_alpha;      // alpha floor, default 0.1
    float min_clip;       // clip floor, default 0.1
};

// Tightened requantization spec for one flagged tensor.
struct ts_l5_requant_spec {
    std::string tensor_name;
    std::string qtype;
    float divergence;    // observed relative_frobenius (from L2)
    float expected;      // type baseline
    float overshoot;     // divergence / expected (>= 1)
    float new_alpha;
    float new_clip;
};

struct ts_l5_adaptive_plan {
    std::vector<ts_l5_requant_spec> specs;
    int64_t n_requant;
    int64_t generation;
};

void ts_l5_adaptive_default_params(ts_l5_adaptive_params * p);

// Identify flagged tensors in an L2 report and compute tightened
// requantization params for each. params == nullptr uses defaults.
// Returns the number of specs (>= 0), or -1 on invalid plan.
int ts_l5_adaptive_requant(const ts_l2_report * report,
                           const ts_l5_adaptive_params * params,
                           int64_t generation,
                           ts_l5_adaptive_plan * plan);
