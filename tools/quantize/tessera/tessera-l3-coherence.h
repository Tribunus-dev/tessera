#pragma once

//
// tessera-l3-coherence.h
//
// L3 per-token (per-row) coherence (Layer 3 of the runtime-aware
// pipeline, see docs/runtime-aware-pipeline.md). The spec's L3 tracks
// per-token distribution divergence across a forward pass; at the
// quantize tool's weight level the equivalent is per-row coherence:
// for each tensor that has both an L1 kernel-dequant sidecar and an
// L1.5 reference sidecar, compute the cosine similarity between the
// kernel's reconstructed row and the reference row. Rows below the
// threshold are tokens where the kernel reconstruction diverges
// significantly from reference.
//
// Sidecar layout (written by common/tessera-debug):
//   L1   : <sidecar_dir>/<tensor>.dequant.f32
//   L1.5 : <reference_dir>/<tensor>.act.dequant.f32
//

#include <cstdint>
#include <string>
#include <vector>

struct ts_l3_config {
    char  sidecar_dir[1024];    // L1 kernel-dequant sidecars
    char  reference_dir[1024];  // L1.5 (FP16/BF16) reference sidecars
    float threshold;            // row cosine floor, default 0.99
};

// Per-tensor coherence summary plus the flagged row indices.
struct ts_l3_tensor_result {
    std::string tensor_name;
    int64_t     rows;
    int64_t     cols;
    float       mean_cosine;
    float       min_cosine;
    int64_t     n_flagged;
    std::vector<int64_t> flagged_rows;
};

struct ts_l3_report {
    std::vector<ts_l3_tensor_result> tensors;
    int64_t n_tensors;
    int64_t n_flagged_rows;     // sum across tensors
};

void ts_l3_default_config(ts_l3_config * cfg);

// Attribution enum for the four-forward drift framework (v3.1 spec §6).
// The four forwards are: A = BF16/BF16 (reference), B = T640/T640
// (deployed), C = T640/BF16 (weight-isolated), D = BF16/T640
// (KV-isolated). kl_joint = D_KL(A || B), kl_weight = D_KL(A || C),
// kl_kv = D_KL(A || D). The attribution depends on the relative
// magnitude of these three scalars:
//   - COMPOUNDING: kl_joint >> max(kl_weight, kl_kv) (cross-coupled)
//   - WEIGHT:     kl_joint ~ max(kl_weight, kl_kv) and kl_weight > eps
//   - KV:         kl_joint ~ max(kl_weight, kl_kv) and kl_kv > eps
//   - NUMERICAL:  kl_joint > eps and both components are < eps
//                 (FP rounding, layout mismatch, etc.)
//   - OK:         all three are below the joint epsilon
enum ts_l3_attribution {
    TS_L3_ATTR_OK          = 0,
    TS_L3_ATTR_COMPOUNDING = 1,
    TS_L3_ATTR_WEIGHT      = 2,
    TS_L3_ATTR_KV          = 3,
    TS_L3_ATTR_NUMERICAL   = 4,
};

// Attribution summary for one L3 calibration run (v3.1 spec §6d).
struct ts_l3_attribution_summary {
    float mean_kl_first_50_joint;   // D_KL(A || B), positions 1..50
    float mean_kl_all_joint;        // D_KL(A || B), all positions
    float mean_kl_first_50_weight;  // D_KL(A || C), positions 1..50
    float mean_kl_first_50_kv;      // D_KL(A || D), positions 1..50
    float coupling_ratio;           // mean_kl_first_50_joint / max(weight, kv, eps)
    int   compounding_layer;        // first layer where joint > 2 * max(weight, kv);
                                    // -1 when no divergence detected
    ts_l3_attribution attribution;  // the classification
};

// Cosine similarity between two vectors of n elements. Returns 1.0 when
// both norms are zero (identical zero rows), 0.0 when exactly one is zero.
float ts_l3_row_cosine(const float * a, const float * b, int64_t n);

// Compute D_KL(P || Q) where P and Q are (vocab_size) probability
// distributions (sum to 1, all >= 0). The KL divergence is the
// natural-log form: D_KL(P || Q) = sum_i P[i] * log(P[i] / Q[i]).
// Smoothing: a small epsilon is added to Q to avoid log(0); the
// standard practice is eps = 1e-10. Returns 0 when P is all-zero
// (degenerate; nothing to compare). Returns +infinity when Q is
// all-zero and P is non-zero (the standard convention; the caller
// should treat this as a flag condition).
//
// p_log_q_out (optional, may be nullptr) receives per-position
// P[i] * log(P[i] / Q[i]) for callers that want the per-token
// breakdown (the spec's KL curves are per-position).
float ts_l3_kl_divergence(const float * p, const float * q, int64_t n,
                          float eps = 1e-10f,
                          float * p_log_q_out = nullptr);

// Classify the drift attribution given the three per-position KL
// curves (joint, weight, kv) and the joint epsilon. The curves are
// (n_layers) float arrays; the function takes the per-layer mean
// (curve[i] is the mean KL at layer i, or 0 if no measurement).
// Returns the populated summary struct. The coupling_ratio is
// joint / max(weight, kv, eps), so a coupling_ratio close to 1.0
// means the components explain the joint error and a coupling_ratio
// > 2.0 means there is compounding. compounding_layer is the
// first layer where joint > 2 * max(weight, kv), or -1 if no such
// layer exists.
//
// Attribution logic (from spec §6.3b):
//   - if joint < eps: OK
//   - else if max(weight, kv) < eps: NUMERICAL
//   - else if joint / max(weight, kv) > 2.0: COMPOUNDING
//   - else if weight > kv: WEIGHT
//   - else: KV
ts_l3_attribution_summary ts_l3_attribute_drift(
    const float * kl_joint_curve, const float * kl_weight_curve,
    const float * kl_kv_curve, int64_t n_layers,
    float joint_eps = 0.1f);

// Per-row coherence for one tensor. l1 and ref are (rows x cols) row-major.
// Flags rows whose cosine falls below threshold. Returns 0 on success,
// -1 on invalid args or shape mismatch.
int ts_l3_tensor_coherence(const float * l1, const float * ref,
                           int64_t rows, int64_t cols,
                           float threshold,
                           ts_l3_tensor_result * out);

// Run over all candidate tensors that have BOTH an L1 sidecar (in
// sidecar_dir) and an L1.5 reference sidecar (in reference_dir). Tensors
// missing either sidecar are skipped. Returns the number of tensors
// processed (>= 0), or -1 on invalid args.
int ts_l3_run(const ts_l3_config * cfg,
              const char * const * tensor_names,
              int64_t n_tensors,
              ts_l3_report * report);
