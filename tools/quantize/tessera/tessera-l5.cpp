#include "tessera-l5.h"

#include "tessera-septq.h"  // ts_septq_build_hessian, ts_septq_banded_cholesky

#include <algorithm>
#include <cmath>
#include <cstring>
#include <numeric>

// ladder ordered low -> high precision
static const char * TS_L5_LADDER[] = {
    "q2_k", "q3_k", "q4_k", "q5_k", "q6_k", "tessera_t640", "q8_0",
};
static const int TS_L5_LADDER_LEN = 7;

// --- Sensitivity metrics ---

ts_score_map ts_l5_imatrix_magnitude(const float * imatrix_vals,
                                     const char ** tensor_names,
                                     const int64_t * tensor_dims,
                                     int64_t n_tensors) {
    ts_score_map out;
    if (n_tensors <= 0) {
        return out;
    }

    float peak = 0.0f;
    for (int64_t i = 0; i < n_tensors; i++) {
        int64_t dim = tensor_dims[i];
        float sum = 0.0f;
        const float * base = imatrix_vals;
        int64_t offset = 0;
        for (int64_t j = 0; j < i; j++) {
            offset += tensor_dims[j];
        }
        for (int64_t k = 0; k < dim; k++) {
            sum += fabsf(base[offset + k]);
        }
        float mean = (dim > 0) ? sum / (float)dim : 0.0f;
        mean = std::max(0.0f, mean);
        out[tensor_names[i]] = mean;
        if (mean > peak) {
            peak = mean;
        }
    }

    if (peak > 0.0f) {
        for (auto & kv : out) {
            kv.second /= peak;
        }
    }
    return out;
}

ts_score_map ts_l5_gradient_proxy(const float * output_sensitivity,
                                  const char ** tensor_names,
                                  int64_t n_tensors) {
    ts_score_map out;
    if (n_tensors <= 0) {
        return out;
    }

    float peak = 0.0f;
    for (int64_t i = 0; i < n_tensors; i++) {
        float v = std::max(0.0f, output_sensitivity[i]);
        out[tensor_names[i]] = v;
        if (v > peak) {
            peak = v;
        }
    }

    if (peak > 0.0f) {
        for (auto & kv : out) {
            kv.second /= peak;
        }
    }
    return out;
}

ts_score_map ts_l5_layer_position_prior(const char ** tensor_names,
                                        int64_t n_tensors,
                                        int64_t n_layers_total) {
    ts_score_map out;
    if (n_tensors <= 0) {
        return out;
    }

    if (n_layers_total < 1) {
        for (int64_t i = 0; i < n_tensors; i++) {
            out[tensor_names[i]] = 0.5f;
        }
        return out;
    }

    for (int64_t i = 0; i < n_tensors; i++) {
        std::string name(tensor_names[i]);
        int idx = -1;

        // parse "blk.<i>." pattern
        if (name.size() > 4 && name.compare(0, 4, "blk.") == 0) {
            size_t dot = name.find('.', 4);
            if (dot != std::string::npos) {
                std::string num = name.substr(4, dot - 4);
                bool valid = !num.empty();
                for (char c : num) {
                    if (c < '0' || c > '9') { valid = false; break; }
                }
                if (valid) {
                    idx = std::stoi(num);
                }
            }
        }

        if (idx < 0 || idx >= n_layers_total) {
            out[name] = 0.5f;
        } else if (n_layers_total == 1) {
            out[name] = 1.0f;
        } else {
            float frac = (float)idx / (float)(n_layers_total - 1);
            out[name] = frac;
        }
    }
    return out;
}

ts_score_map ts_l5_combine(const ts_score_map ** scorers,
                           const float * weights,
                           int64_t n_scorers) {
    ts_score_map out;
    if (n_scorers <= 0) {
        return out;
    }

    // collect union of keys
    for (int64_t s = 0; s < n_scorers; s++) {
        for (const auto & kv : *scorers[s]) {
            if (out.find(kv.first) == out.end()) {
                out[kv.first] = 0.0f;
            }
        }
    }

    for (auto & kv : out) {
        float sum = 0.0f;
        for (int64_t s = 0; s < n_scorers; s++) {
            auto it = scorers[s]->find(kv.first);
            float val = (it != scorers[s]->end()) ? it->second : 0.0f;
            sum += weights[s] * val;
        }
        kv.second = sum;
    }
    return out;
}

// --- EMA ---

void ts_l5_ema_init(ts_l5_ema * ema, float beta) {
    ema->state.clear();
    ema->beta = beta;
}

void ts_l5_ema_update(ts_l5_ema * ema, const ts_score_map * new_scores) {
    for (const auto & kv : *new_scores) {
        auto it = ema->state.find(kv.first);
        if (it == ema->state.end()) {
            ema->state[kv.first] = kv.second;
        } else {
            it->second = ema->beta * it->second + (1.0f - ema->beta) * kv.second;
        }
    }
}

// --- Percentile ---

ts_score_map ts_l5_percentile_rank(const ts_score_map * scores) {
    ts_score_map out;
    int64_t n = (int64_t)scores->size();
    if (n == 0) {
        return out;
    }
    if (n == 1) {
        out[scores->begin()->first] = 0.5f;
        return out;
    }

    // sort by value ascending
    std::vector<std::pair<std::string, float>> items(scores->begin(), scores->end());
    std::sort(items.begin(), items.end(),
              [](const auto & a, const auto & b) { return a.second < b.second; });

    int64_t i = 0;
    while (i < n) {
        int64_t j = i;
        while (j + 1 < n && items[j + 1].second == items[i].second) {
            j++;
        }
        float avg = 0.5f * (float)(i + j) / (float)(n - 1);
        for (int64_t k = i; k <= j; k++) {
            out[items[k].first] = avg;
        }
        i = j + 1;
    }
    return out;
}

// --- Pick top ---

std::vector<std::string> ts_l5_pick_top(const ts_score_map * scores,
                                        float fraction) {
    std::vector<std::string> out;
    if (fraction <= 0.0f || scores->empty()) {
        return out;
    }
    if (fraction >= 1.0f) {
        for (const auto & kv : *scores) {
            out.push_back(kv.first);
        }
        return out;
    }

    // sort descending by score
    std::vector<std::pair<std::string, float>> items(scores->begin(), scores->end());
    std::sort(items.begin(), items.end(),
              [](const auto & a, const auto & b) { return a.second > b.second; });

    int64_t count = std::max((int64_t)1, (int64_t)std::round(fraction * (float)items.size()));
    count = std::min(count, (int64_t)items.size());
    for (int64_t i = 0; i < count; i++) {
        out.push_back(items[i].first);
    }
    return out;
}

// --- Expected MSE delta ---

float ts_l5_expected_mse_delta(const char * tensor_name,
                               float current_score, float target_score) {
    (void)tensor_name;
    float delta = current_score - target_score;
    return std::max(0.0f, delta);
}

// --- Ladder ---

int ts_l5_ladder_index(const char * qtype) {
    for (int i = 0; i < TS_L5_LADDER_LEN; i++) {
        if (strcmp(qtype, TS_L5_LADDER[i]) == 0) {
            return i;
        }
    }
    return -1;
}

const char * ts_l5_step_up(const char * qtype) {
    int idx = ts_l5_ladder_index(qtype);
    if (idx < 0 || idx + 1 >= TS_L5_LADDER_LEN) {
        return nullptr;
    }
    return TS_L5_LADDER[idx + 1];
}

const char * ts_l5_step_down(const char * qtype) {
    int idx = ts_l5_ladder_index(qtype);
    if (idx <= 0) {
        return nullptr;
    }
    return TS_L5_LADDER[idx - 1];
}

// --- Orchestrator ---

int ts_l5_orchestrate_step(const ts_score_map * sensitivity,
                           const char ** current_qtypes,
                           int64_t n_tensors,
                           int64_t generation,
                           const ts_orchestrator_params * params,
                           ts_requant_plan * plan) {
    plan->actions.clear();
    plan->total_expected_delta = 0.0f;
    plan->generation = generation;

    if (n_tensors <= 0 || sensitivity->empty()) {
        return 0;
    }

    // build name list aligned with current_qtypes
    std::vector<std::string> names;
    names.reserve(n_tensors);
    for (const auto & kv : *sensitivity) {
        names.push_back(kv.first);
    }

    // pick top fraction
    std::vector<std::string> top = ts_l5_pick_top(sensitivity, params->top_fraction);

    // for each top tensor, compute expected delta and maybe generate action
    for (const auto & name : top) {
        auto it = sensitivity->find(name);
        if (it == sensitivity->end()) {
            continue;
        }
        float score = it->second;

        // find this tensor's index to get its qtype
        int64_t tidx = -1;
        for (int64_t i = 0; i < n_tensors; i++) {
            if (names[i] == name) {
                tidx = i;
                break;
            }
        }
        if (tidx < 0) {
            continue;
        }

        const char * cur_qtype = current_qtypes[tidx];
        const char * next = ts_l5_step_up(cur_qtype);
        if (next == nullptr) {
            continue;
        }

        // target score: stepping up reduces sensitivity impact
        float target_score = score * 0.5f;
        float delta = ts_l5_expected_mse_delta(name.c_str(), score, target_score);

        if (delta > params->delta_threshold) {
            ts_requant_action action;
            action.tensor_name = name;
            action.type = TS_REQUANT_STEP_UP;
            action.from_qtype = cur_qtype;
            action.to_qtype = next;
            action.expected_delta = delta;
            plan->actions.push_back(action);
            plan->total_expected_delta += delta;
        }
    }

    return (int)plan->actions.size();
}

// --- Adaptive requantization ---

void ts_l5_adaptive_default_params(ts_l5_adaptive_params * p) {
    if (p == nullptr) {
        return;
    }
    p->alpha_scale = 0.5f;
    p->clip_scale  = 0.5f;
    p->min_alpha   = 0.1f;
    p->min_clip    = 0.1f;
}

int ts_l5_adaptive_requant(const ts_l2_report * report,
                           const ts_l5_adaptive_params * params,
                           int64_t generation,
                           ts_l5_adaptive_plan * plan) {
    if (plan == nullptr) {
        return -1;
    }
    plan->specs.clear();
    plan->n_requant  = 0;
    plan->generation = generation;
    if (report == nullptr) {
        return 0;
    }

    ts_l5_adaptive_params p;
    if (params != nullptr) {
        p = *params;
    } else {
        ts_l5_adaptive_default_params(&p);
    }

    for (const auto & t : report->tensors) {
        if (!t.flagged) {
            continue;
        }

        // how far the observed divergence overshoots the type baseline
        float overshoot = (t.expected_frob > 0.0f)
                              ? t.divergence.relative_frobenius / t.expected_frob
                              : 1.0f;
        if (overshoot < 1.0f) {
            overshoot = 1.0f;
        }

        // tighten proportionally: worse tensors get smaller alpha/clip
        float new_alpha = p.alpha_scale / overshoot;
        float new_clip  = p.clip_scale  / overshoot;
        if (new_alpha < p.min_alpha) {
            new_alpha = p.min_alpha;
        }
        if (new_clip < p.min_clip) {
            new_clip = p.min_clip;
        }

        ts_l5_requant_spec s;
        s.tensor_name = t.tensor_name;
        s.qtype       = t.qtype;
        s.divergence  = t.divergence.relative_frobenius;
        s.expected    = t.expected_frob;
        s.overshoot   = overshoot;
        s.new_alpha   = new_alpha;
        s.new_clip    = new_clip;
        plan->specs.push_back(s);
        plan->n_requant++;
    }

    return (int)plan->n_requant;
}

// --- Hessian sensitivity scoring (v3.1 spec §9) ---
//
// Per-tensor OBQ criterion (Frantar & Alistarh 2022,
// arXiv:2208.11580):
//   omega_ij = (w_ij - quant(w_ij))^2 / [H^{-1}]_ii
//   sensitivity[T] = mean over (i, j) of omega_ij
//
// where [H^{-1}]_ii is the i-th diagonal of H^{-1} (H is the
// calibration Hessian = 2 X X^T for the imatrix corpus X).
//
// For a lower-triangular Cholesky factor L of H^{-1} (L L^T =
// H^{-1}), [H^{-1}]_ii = ||L[i, :]||^2 (the squared 2-norm of
// row i of L), NOT just L[i, i]^2. The "L_ii^2 approximation"
// from the spec is only valid when L is diagonal (i.e., the
// activations are uncorrelated, H is diagonal). For a real
// imatrix corpus with correlated activations, the off-diagonal
// entries of L are non-negligible and the per-row squared 2-norm
// is the right quantity. The OBQ paper (Frantar 2022, eq. 3)
// uses the full [H^{-1}]_ii.
//
// In v1 the scorer takes H_inv_diag (the precomputed diagonal of
// H^{-1}) directly via ts_l5_second_order_info. The v2 paths
// (Nystrom, streaming) can populate H_inv_diag from the
// approximation; the interface is the same.
//
// The scorer is O(n_tensors * in_dim * out_dim) per tensor; the
// diagonal of H^{-1} is computed once per in_dim and shared
// across all tensors with the same in_dim. For the v1 (in-core)
// path the Cholesky pipeline (ts_l5_hessian_factorize /
// ts_l5_hessian_factorize_inverse) produces H_inv_diag from the
// imatrix corpus.
//
// The NYSTROM and STREAMING sources return an empty map in v1; the
// v2 swap is an internal change with no caller updates (per the
// spec's struct-based API).

ts_score_map ts_l5_hessian_sensitivity(
    const float * weights_bf16,
    const float * weights_quant,
    const int64_t * tensor_in_dims,
    const int64_t * tensor_out_dims,
    const ts_l5_second_order_info * soi,
    const char ** tensor_names,
    int64_t n_tensors) {
    ts_score_map out;
    if (n_tensors <= 0 || weights_bf16 == nullptr || tensor_in_dims == nullptr ||
        tensor_out_dims == nullptr || tensor_names == nullptr || soi == nullptr) {
        return out;
    }
    if (soi->in_dim <= 0) {
        return out;
    }

    // Source dispatch. v1 supports IN_CORE only.
    if (soi->source != TS_L5_SOI_IN_CORE) {
        // NYSTROM and STREAMING are deferred to v2. The function
        // returns an empty map rather than a partial result so the
        // caller's combine() treats the missing scorer as a 0
        // contribution (the same fallback the imatrix / gradient
        // scorers use for missing-data tensors).
        return out;
    }
    if (soi->H_inv_diag == nullptr) {
        return out;
    }

    // Per-tensor walk. Compute the offset of each tensor's weight
    // block in the concatenated arrays, then for each row i in the
    // tensor's in_dim:
    //   1. compute sum_j (w_ij - quant(w_ij))^2  -- call it err_i
    //   2. read H_inv_diag[i] (the OBQ denominator)
    //   3. omega_i = err_i / H_inv_diag[i]
    // sensitivity[T] = mean over i of omega_i
    std::vector<float> sensitivities;
    sensitivities.reserve((size_t) n_tensors);

    int64_t offset = 0;
    for (int64_t t = 0; t < n_tensors; t++) {
        const int64_t in_dim  = tensor_in_dims[t];
        const int64_t out_dim = tensor_out_dims[t];
        if (in_dim <= 0 || out_dim <= 0) {
            return out;  // invalid dims -- fail-closed on the whole call
        }
        if (in_dim != soi->in_dim) {
            // Mismatched in_dim: the Cholesky factor was computed
            // for a different in_dim. The caller is responsible for
            // either re-running Cholesky or grouping tensors by
            // in_dim; we return empty on the whole call.
            return out;
        }

        const float * W  = weights_bf16  + offset;
        const float * Wq = (weights_quant != nullptr) ? (weights_quant + offset)
                                                      : weights_bf16 + offset;
        const int64_t n_elem = in_dim * out_dim;

        double sum_omega = 0.0;
        for (int64_t i = 0; i < in_dim; i++) {
            // Row i's quantization error sum over the out_dim axis.
            double err_i = 0.0;
            const float * row_w  = W  + i * out_dim;
            const float * row_wq = Wq + i * out_dim;
            for (int64_t j = 0; j < out_dim; j++) {
                const float d = row_w[j] - row_wq[j];
                err_i += (double) d * (double) d;
            }
            // H_inv_diag[i] is the OBQ denominator. Non-positive
            // means the Hessian is singular at row i (shouldn't
            // happen with the ridge added in ts_septq_build_hessian);
            // skip the row in that case to avoid division by zero.
            const float H_inv_ii = soi->H_inv_diag[i];
            if (H_inv_ii <= 0.0f) {
                continue;
            }
            sum_omega += err_i / (double) H_inv_ii;
        }
        // mean over i; if all rows were skipped (H_inv_diag <= 0
        // for every i), the sensitivity is zero.
        const double mean_omega = (in_dim > 0) ? (sum_omega / (double) in_dim) : 0.0;
        sensitivities.push_back((float) mean_omega);
        offset += n_elem;
    }

    // Normalize to [0, 1] (peak tensor = 1.0). The peak is over
    // tensors whose sensitivity is positive; tensors with zero
    // sensitivity stay at zero. This matches the normalization the
    // imatrix / gradient scorers use so the combine() weights
    // compose cleanly.
    float peak = 0.0f;
    for (float s : sensitivities) {
        if (s > peak) {
            peak = s;
        }
    }
    if (peak > 0.0f) {
        for (int64_t t = 0; t < n_tensors; t++) {
            out[tensor_names[t]] = sensitivities[(size_t) t] / peak;
        }
    } else {
        // All-zero sensitivities (every tensor's quantization error
        // is zero, or every H_inv_diag entry is degenerate). Return
        // the raw zeros; the caller can decide whether to skip the
        // scorer or zero-weight it in the combine().
        for (int64_t t = 0; t < n_tensors; t++) {
            out[tensor_names[t]] = 0.0f;
        }
    }
    return out;
}

// --- Hessian factorization (v3.1 spec §9) ---
//
// Build the calibration Hessian H from the imatrix corpus and
// factorize it. The pipeline is H = X^T X / n + ridge, then
// L_forward = chol(H) (lower triangular). For the OBQ criterion
// (per the Hessian scorer above) the caller additionally needs
// L_inv = inv(L_forward) and H_inv_diag = ||L_inv[i, :]||^2 --
// see ts_l5_hessian_factorize_inverse below.
//
// The Cholesky itself is delegated to the SEPTQ module
// (ts_septq_banded_cholesky with bandwidth = in_dim, which
// degenerates to a full Cholesky) for code reuse: the SEPTQ
// banded path is the one exercised in production for SEPTQ, and
// the L5 scorer doesn't benefit from the banded restriction.

int ts_l5_hessian_factorize(int64_t in_dim,
                            const float * X, int64_t n_samples,
                            float ridge_fraction,
                            float * L_out,
                            float * H_scratch) {
    if (in_dim <= 0 || X == nullptr || n_samples <= 0 || L_out == nullptr ||
        H_scratch == nullptr) {
        return -1;
    }
    if (ridge_fraction < 0.0f) {
        ridge_fraction = 0.0f;
    }
    // H = X^T X / n + ridge (SEPTQ convention; the 1/n scaling is
    // irrelevant for the OBQ criterion because the per-tensor
    // sensitivity is normalized to peak=1.0 in the scorer).
    ts_septq_build_hessian(in_dim, /*act_scales=*/nullptr, X, n_samples,
                           ridge_fraction, H_scratch);
    // L_forward = chol(H) lower triangular; bandwidth = in_dim is
    // the "full Cholesky" degenerate case.
    ts_septq_banded_cholesky(H_scratch, in_dim, in_dim, L_out);
    return 0;
}

int ts_l5_hessian_factorize_inverse(int64_t in_dim,
                                    const float * X, int64_t n_samples,
                                    float ridge_fraction,
                                    float * H_inv_diag_out,
                                    float * L_forward,
                                    float * H_scratch) {
    if (in_dim <= 0 || X == nullptr || n_samples <= 0 ||
        H_inv_diag_out == nullptr || H_scratch == nullptr) {
        return -1;
    }
    if (ridge_fraction < 0.0f) {
        ridge_fraction = 0.0f;
    }

    // Working buffer for the forward Cholesky. When the caller
    // passes a non-null L_forward, we use it directly (in-place
    // inverse overwrites L_forward with L_inv; the caller should
    // copy first if they need to preserve L_forward). When the
    // caller passes nullptr, we use a local buffer sized for the
    // Cholesky output.
    std::vector<float> L_local;
    float * L = nullptr;
    if (L_forward != nullptr) {
        L = L_forward;
    } else {
        L_local.assign((size_t)(in_dim * in_dim), 0.0f);
        L = L_local.data();
    }
    if (ts_l5_hessian_factorize(in_dim, X, n_samples, ridge_fraction,
                                L, H_scratch) != 0) {
        return -1;
    }

    // In-place triangular inverse: L_inv[i, j] such that
    //   L @ L_inv = I  (column by column)
    // For each column j:
    //   L_inv[j, j] = 1 / L[j, j]
    //   L_inv[i, j] = -sum_{k=j}^{i-1} L[i, k] * L_inv[k, j] / L[i, i]
    // The squared 2-norm of row i of L_inv is the OBQ denominator.
    for (int64_t j = 0; j < in_dim; j++) {
        const float L_jj = L[(size_t)(j * in_dim + j)];
        if (L_jj <= 0.0f) {
            return -1;  // degenerate
        }
        std::vector<float> col_inv((size_t) in_dim, 0.0f);
        col_inv[(size_t) j] = 1.0f / L_jj;
        for (int64_t i = j + 1; i < in_dim; i++) {
            double acc = 0.0;
            for (int64_t k = j; k < i; k++) {
                acc -= (double) L[(size_t)(i * in_dim + k)] *
                       (double) col_inv[(size_t) k];
            }
            const float L_ii = L[(size_t)(i * in_dim + i)];
            if (L_ii <= 0.0f) {
                return -1;  // degenerate
            }
            col_inv[(size_t) i] = (float)(acc / (double) L_ii);
        }
        for (int64_t i = j; i < in_dim; i++) {
            L[(size_t)(i * in_dim + j)] = col_inv[(size_t) i];
        }
    }
    // H_inv_diag[i] = sum_k L_inv[i, k]^2 (squared 2-norm of row i).
    // NOT just L_inv[i, i]^2 (the spec's L_ii^2 approximation is
    // only valid when the activations are uncorrelated, i.e., H
    // is diagonal).
    for (int64_t i = 0; i < in_dim; i++) {
        double row_sq = 0.0;
        for (int64_t k = 0; k <= i; k++) {
            const float v = L[(size_t)(i * in_dim + k)];
            row_sq += (double) v * (double) v;
        }
        H_inv_diag_out[i] = (float) row_sq;
    }
    return 0;
}
