#include "tessera-regime.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

// ---------------------------------------------------------------------------
// Shared static helpers (used by ts_regime_compute_descriptor_impl and
// ts_regime_fit_thresholds). Defined once here so both code paths share the
// same implementations.
// ---------------------------------------------------------------------------

// Excess kurtosis: 4th moment / variance^2 - 3.  Gaussian = 0.
// Uses the single-pass Welford-style shifted algorithm for numerical stability.
static float ts_regime_kurtosis(const float * data, int64_t n) {
    if (n < 4) return 0.0f;
    float mean = 0.0f;
    for (int64_t i = 0; i < n; i++) mean += data[i];
    mean /= (float)n;

    float m2 = 0.0f, m4 = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        float d = data[i] - mean;
        float d2 = d * d;
        m2 += d2;
        m4 += d2 * d2;
    }
    m2 /= (float)n;
    m4 /= (float)n;
    float var = m2;
    if (var < 1e-12f) return 0.0f;
    return (m4 / (var * var)) - 3.0f;  // excess kurtosis
}

// Effective rank: exp(H(p)) where H is Shannon entropy of the normalized
// singular-value distribution. Measures how uniformly the matrix "uses" its
// dimensions. Compact (low-rank) matrices have eff_rank << min(out,in).
// Implemented via the weight column magnitudes as a proxy for singular values.
static float ts_regime_eff_rank(const float * data, int64_t n) {
    if (n < 2) return 0.0f;
    float sum = 0.0f;
    for (int64_t i = 0; i < n; i++) sum += std::fabsf(data[i]);
    if (sum < 1e-12f) return 0.0f;
    float entropy = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        float p = std::fabsf(data[i]) / sum;
        if (p > 1e-12f) entropy -= p * std::logf(p);
    }
    return std::expf(entropy);
}

// Linear-time p-th percentile using the selection algorithm (introselect).
// The caller passes a pointer; this function makes a local copy so nth_element's
// in-place mutation doesn't bleed back to the caller's data. p is in [0, 1].
static float ts_regime_percentile(const float * data, int64_t n, float p) {
    if (n <= 0) return 0.0f;
    if (n == 1) return data[0];
    if (p <= 0.0f) return data[0];
    if (p >= 1.0f) return data[n - 1];
    int64_t k = (int64_t)(p * (float)(n - 1));
    if (k < 0) k = 0;
    if (k >= n) k = n - 1;
    // Copy: nth_element mutates in-place; we don't want to affect the caller's data.
    std::vector<float> tmp(data, data + n);
    std::nth_element(tmp.begin(), tmp.begin() + k, tmp.end());
    return tmp[(size_t)k];
}

// ---------------------------------------------------------------------------
// Tier 1a: Family inference (extended with MoE variants)
// ---------------------------------------------------------------------------

// ordered by specificity: longer fragments first to avoid prefix collisions.
// MoE patterns listed first so e.g. "ffn_gate_exps" matches before
// "ffn_gate" hits the substring match.
//
// G3 fix (tessera-moe-calibration-design.md §3.3): routed expert tensors
// now map to the "routed_expert" family instead of the base ffn family.
// This lets the regime classifier distinguish MoE expert routing from dense FFN
// and apply the sparsity-aware cascade (Q4 middle, DartQuant edge) correctly.
// Shared expert (_shexp) keeps "ffn_gate/up/down" so the existing
// "always DartQuant + Q8 minimum" rule fires on it unconditionally.
static const struct ts_family_pattern {
    const char * fragment;
    const char * family;
} ts_family_patterns[] = {
    // ---- Nemotron-3.5-Lightning (NEMOTRON_H_MOE) ----
    // SSM / Mamba-2 layers: "ssm" family — sequential state-space, distinct from dense FFN
    { "ssm_in",      "ssm"     },
    { "ssm_x",       "ssm"     },
    { "ssm_conv1d",  "ssm"     },
    { "ssm_dt",      "ssm"     },
    { "ssm_a",       "ssm"     },
    { "ssm_d",       "ssm"     },
    { "ssm_norm",    "ssm"     },
    { "ssm_out",     "ssm"     },
    { "ssm_b_norm",  "ssm"     },
    { "ssm_c_norm",  "ssm"     },
    // LatentMoE gate projection: separate from routed_expert, smaller intermediate dim
    { "ffn_latent_up",   "moe_gate" },
    { "ffn_latent_down", "moe_gate" },
    // MoE routed expert variants: map to "routed_expert" (sparsity-aware regime)
    { "ffn_gate_exps",   "routed_expert" },
    { "ffn_up_exps",     "routed_expert" },
    { "ffn_down_exps",   "routed_expert" },
    { "ffn_gate_exps_s",    "routed_expert" },
    { "ffn_up_exps_s",      "routed_expert" },
    { "ffn_down_exps_s",    "routed_expert" },
    { "ffn_gate_exps_in_s", "routed_expert" },
    { "ffn_up_exps_in_s",   "routed_expert" },
    { "ffn_down_exps_in_s", "routed_expert" },
    // MoE shared expert: stays in the base family so the "always DartQuant + Q8"
    // rule fires unconditionally (APEX: kurtosis ~13 for shared, ~3.41 for routed)
    { "ffn_gate_shexp",  "ffn_gate"  },
    { "ffn_up_shexp",    "ffn_up"    },
    { "ffn_down_shexp",  "ffn_down"  },
    { "ffn_gate_shexp_s",   "ffn_gate"  },
    { "ffn_up_shexp_s",     "ffn_up"    },
    { "ffn_down_shexp_s",   "ffn_down"  },
    // Standard dense FFN
    { "ffn_gate",    "ffn_gate"  },
    { "ffn_up",      "ffn_up"    },
    { "ffn_down",    "ffn_down"  },
    // Attention
    { "attn_output", "attn_out"  },
    { "attn_out",    "attn_out"  },
    { "attn_q",      "attn_q"    },
    { "attn_k",      "attn_k"    },
    { "attn_v",      "attn_v"    },
};

std::string ts_regime_infer_family(const char * tensor_name) {
    if (!tensor_name) {
        return "unknown";
    }
    for (const auto & p : ts_family_patterns) {
        if (std::strstr(tensor_name, p.fragment)) {
            return p.family;
        }
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Tier 1a: MoE role inference
// ---------------------------------------------------------------------------

ts_regime_role ts_regime_infer_role(const char * tensor_name) {
    if (!tensor_name) {
        return TS_ROLE_OTHER;
    }
    // MoE routed expert: _exps suffix (expert-specific weights)
    if (std::strstr(tensor_name, "_exps")) {
        return TS_ROLE_ROUTED_EXPERT;
    }
    // MoE shared expert: _shexp suffix (always-active, heavy-tailed)
    if (std::strstr(tensor_name, "_shexp")) {
        return TS_ROLE_SHARED_EXPERT;
    }
    // Attention projections
    if (std::strstr(tensor_name, "attn_q")  ||
        std::strstr(tensor_name, "attn_k")  ||
        std::strstr(tensor_name, "attn_v")  ||
        std::strstr(tensor_name, "attn_out")) {
        return TS_ROLE_ATTENTION;
    }
    return TS_ROLE_OTHER;
}

// ---------------------------------------------------------------------------
// Tier 1a: Layer index extraction from "blk.N." prefix
// ---------------------------------------------------------------------------

int32_t ts_regime_extract_layer(const char * tensor_name) {
    if (!tensor_name) return -1;
    // look for "blk."
    const char * p = std::strstr(tensor_name, "blk.");
    if (!p) return -1;
    p += 4;  // skip "blk."
    char * end = nullptr;
    long layer = std::strtol(p, &end, 10);
    if (end == p) return -1;  // no digits found
    return (int32_t)layer;
}

// ---------------------------------------------------------------------------
// Tier 1a: Layer position inference (EDGE / NEAR_EDGE / MIDDLE)
// ---------------------------------------------------------------------------

ts_regime_position ts_regime_infer_position(const char * tensor_name, int32_t n_layers_total) {
    int32_t layer = ts_regime_extract_layer(tensor_name);
    if (layer < 0 || n_layers_total <= 0) {
        return TS_POS_MIDDLE;
    }
    if (n_layers_total < 10) {
        // Tiny model: all layers are edge-equivalent
        return TS_POS_EDGE;
    }
    // Fractional thresholds. 5/40 = 12.5% edge on a 40-layer model.
    // These are the APEX-derived values: first/last ~5 layers are EDGE.
    float edge_frac  = 0.125f;   // 12.5% each end  = EDGE
    float near_frac   = 0.10f;   // 10% each side  = NEAR_EDGE
    // Everything else is MIDDLE.
    float edge_n  = n_layers_total * edge_frac;
    float near_n  = n_layers_total * near_frac;
    float near_lo = edge_n;
    float near_hi = (float)n_layers_total - edge_n;

    if ((float)layer < edge_n)                         return TS_POS_EDGE;
    if ((float)layer >= near_lo && (float)layer < near_hi) return TS_POS_NEAR_EDGE;
    return TS_POS_MIDDLE;
}

// ---------------------------------------------------------------------------
// Tier 1a: Modality inference
// ---------------------------------------------------------------------------

int ts_regime_infer_modality(const char * tensor_name) {
    if (!tensor_name) {
        return 0;
    }
    if (tensor_name[0] == '\0') {
        return 0;
    }

    // First pass: explicit role prefixes (M0b style)
    // Real mmproj GGUFs use "v." for vision, "a." for audio.
    if (tensor_name[0] == 'v' && tensor_name[1] == '.') return 1;
    if (tensor_name[0] == 'a' && tensor_name[1] == '.') return 2;

    // Second pass: legacy fragment-based detection
    static const char * image_fragments[] = {
        "vision", "image", "vit", "patch", "pixel", "img",
    };
    for (const char * f : image_fragments) {
        if (std::strstr(tensor_name, f)) return 1;
    }
    static const char * audio_fragments[] = {
        "audio", "acoustic", "speech", "wav",
    };
    for (const char * f : audio_fragments) {
        if (std::strstr(tensor_name, f)) return 2;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Helper: check if family string contains a substring
// ---------------------------------------------------------------------------

static bool ts_family_contains(const std::string & family, const char * sub) {
    return family.find(sub) != std::string::npos;
}

// ---------------------------------------------------------------------------
// Tier 2 + Tier 3: Regime classification
// ---------------------------------------------------------------------------

ts_regime_routing ts_regime_classify(const ts_regime_descriptor * desc,
                                     const ts_regime_family_thresholds * thresholds) {
    ts_regime_routing r;
    if (!desc) return r;
    r.tensor_name = desc->tensor_name;
    r.role      = desc->role;
    r.position = desc->position;
    r.precision_tier = desc->default_tier;

    const float kurt = desc->kurtosis;
    const float er   = desc->eff_rank;
    const std::string & fam = desc->family;
    const int modality = desc->modality;

    // Determine which thresholds to use: learned from DuckDB (Tier 2)
    // or builtin cascade.
    bool use_learned = (thresholds && thresholds->valid);
    float kurt_heavy_thresh = use_learned ? thresholds->kurt_heavy : 10.0f;
    float kurt_light_thresh = use_learned ? thresholds->kurt_light : 5.0f;
    float er_compact_thresh = use_learned ? thresholds->er_compact : 0.15f;
    float er_sparse_thresh  = use_learned ? thresholds->er_sparse  : 0.30f;
    r.threshold_source = use_learned ? "learned" : "static";

    // Confidence: lower when using static thresholds (less certainty about cutoff)
    float static_confidence_penalty = use_learned ? 0.0f : -0.05f;

    // Tier 1 override: shared expert ALWAYS needs rotation or high precision.
    // APEX empirically shows kurtosis ~13 for shared experts. The rotation
    // threshold is met unconditionally; only precision tier is tunable.
    if (desc->role == TS_ROLE_SHARED_EXPERT) {
        r.expert     = TS_EXPERT_DARTQUANT;
        r.reason     = "shared expert (always-on, kurtosis ~13): rotation handles heavy tail";
        r.confidence = 0.97f + static_confidence_penalty;
        r.precision_tier = TS_TIER_Q8;  // shared = highest precision tier
        return r;
    }

    // Tier 1 override: routed expert in MIDDLE position can be very aggressive.
    // The sparsity (only 8 of 256 active per token) means quantization
    // error on inactive experts never reaches the output. But we still
    // need to protect the 8 that activate. Layer position is already in
    // the precision tier; the regime classification still applies.
    // Skip to modality-specific rules.

    // Modality-specific regimes. Text (modality 0) falls through to the
    // generic cascade unchanged.
    if (modality == 2 && kurt > kurt_light_thresh) {
        // audio activations are heavy-tailed; factored low-rank residual
        // handles long tails better than rotation/permutation experts
        r.expert     = TS_EXPERT_FLRQ;
        r.reason     = "audio + kurtosis > threshold: heavy-tailed acoustic, factored low-rank";
        r.confidence = 0.85f + static_confidence_penalty;
        return r;
    }
    if (modality == 1 && er < er_compact_thresh) {
        // vision activations are spatially low-rank
        r.expert     = TS_EXPERT_LRQ;
        r.reason     = "image + eff_rank < threshold: spatially low-rank vision";
        r.confidence = 0.82f + static_confidence_penalty;
        return r;
    }

    // Generic heavy-tail cascade (using learned or static thresholds)
    // Massive outliers in down_proj (DuQuant observation)
    if (kurt > kurt_heavy_thresh && ts_family_contains(fam, "down")) {
        r.expert     = TS_EXPERT_DARTQUANT;
        r.reason     = "kurtosis > threshold in down_proj: rotation handles massive outliers";
        r.confidence = 0.95f + static_confidence_penalty;
        return r;
    }
    if (kurt > kurt_heavy_thresh) {
        r.expert     = TS_EXPERT_DARTQUANT;
        r.reason     = "kurtosis > threshold: distribution-aware rotation";
        r.confidence = 0.85f + static_confidence_penalty;
        return r;
    }
    if (kurt > kurt_light_thresh) {
        r.expert     = TS_EXPERT_CHAMPQ;
        r.reason     = "kurtosis > threshold: channel permutation smooths heavy tails";
        r.confidence = 0.75f + static_confidence_penalty;
        return r;
    }

    // Spectrally compact: low-rank residual helps
    if (er < er_compact_thresh) {
        r.expert     = TS_EXPERT_FLRQ;
        r.reason     = "eff_rank < threshold: highly compact spectrum, factored low-rank";
        r.confidence = 0.85f + static_confidence_penalty;
        return r;
    }
    if (er < er_sparse_thresh) {
        r.expert     = TS_EXPERT_LRQ;
        r.reason     = "eff_rank < threshold: low-rank residual captures structure";
        r.confidence = 0.80f + static_confidence_penalty;
        return r;
    }

    // Attention K/V projections are typically well-behaved
    if (fam == "attn_k" || fam == "attn_v") {
        r.expert     = TS_EXPERT_AWQ;
        r.reason     = "attention K/V: well-behaved, diagonal scaling sufficient";
        r.confidence = 0.85f + static_confidence_penalty;
        return r;
    }

    // Well-conditioned, light tails
    if (er > 0.7f && kurt < 3.0f) {
        r.expert     = TS_EXPERT_AWQ;
        r.reason     = "well-conditioned (eff_rank > 0.7, kurtosis < 3): plain AWQ";
        r.confidence = 0.90f + static_confidence_penalty;
        return r;
    }

    r.expert     = TS_EXPERT_AWQ;
    r.reason     = "default regime: AWQ diagonal scaling";
    r.confidence = 0.50f + static_confidence_penalty;
    return r;
}

std::vector<ts_regime_routing> ts_regime_route_all(
    const ts_regime_descriptor * descs,
    int64_t n_tensors,
    const ts_regime_family_thresholds * thresholds) {
    std::vector<ts_regime_routing> routings;
    routings.reserve(n_tensors);
    for (int64_t i = 0; i < n_tensors; i++) {
        routings.push_back(ts_regime_classify(&descs[i], thresholds));
    }
    return routings;
}

// ---------------------------------------------------------------------------
// Tier 1c + Tier 2: Descriptor computation
// ---------------------------------------------------------------------------

static ts_regime_descriptor ts_regime_compute_descriptor_impl(
    const char * tensor_name,
    const float * weights, int64_t out_dim, int64_t in_dim,
    const float * imatrix_data, int64_t imatrix_dim,
    const float * imatrix_max_abs, int64_t imatrix_max_abs_dim,
    int32_t n_layers_total,
    bool has_max_abs) {

    ts_regime_descriptor desc;
    desc.tensor_name       = tensor_name ? tensor_name : "";
    desc.family            = ts_regime_infer_family(tensor_name);
    desc.role              = ts_regime_infer_role(tensor_name);
    desc.layer_depth       = ts_regime_extract_layer(tensor_name);
    desc.position          = ts_regime_infer_position(tensor_name, n_layers_total);
    desc.default_tier      = ts_regime_default_tier(desc.role, desc.position);
    desc.out_dim          = out_dim;
    desc.in_dim           = in_dim;
    desc.modality         = ts_regime_infer_modality(tensor_name);
    desc.kurtosis         = 3.0f;
    desc.eff_rank         = 0.5f;
    desc.mean_magnitude    = 0.0f;
    desc.p99              = 0.0f;
    desc.max_outlier_ratio = 0.0f;
    // Tier 2 learned thresholds: zero = not set
    desc.learned_kurt_heavy = 0.0f;
    desc.learned_kurt_light = 0.0f;
    desc.learned_er_compact = 0.0f;
    desc.learned_er_sparse  = 0.0f;

    if (imatrix_data && imatrix_dim > 0) {
        desc.kurtosis       = ts_regime_kurtosis(imatrix_data, imatrix_dim);
        desc.eff_rank       = ts_regime_eff_rank(imatrix_data, imatrix_dim);
        desc.p99            = ts_regime_percentile(imatrix_data, imatrix_dim, 0.99f);
        float sum = 0.0f;
        for (int64_t i = 0; i < imatrix_dim; i++) sum += std::fabsf(imatrix_data[i]);
        desc.mean_magnitude = sum / (float)imatrix_dim;
    } else if (weights && out_dim > 0 && in_dim > 0) {
        // fallback: weight-based stats
        std::vector<float> col_mag((size_t)in_dim, 0.0f);
        for (int64_t j = 0; j < in_dim; j++) {
            float s = 0.0f;
            for (int64_t i = 0; i < out_dim; i++) {
                s += std::fabsf(weights[i * in_dim + j]);
            }
            col_mag[(size_t)j] = s / (float)out_dim;
        }
        desc.kurtosis       = ts_regime_kurtosis(col_mag.data(), in_dim);
        desc.eff_rank       = ts_regime_eff_rank(col_mag.data(), in_dim);
        desc.p99            = ts_regime_percentile(col_mag.data(), in_dim, 0.99f);
        float sum = 0.0f;
        for (int64_t j = 0; j < in_dim; j++) sum += col_mag[(size_t)j];
        desc.mean_magnitude = sum / (float)in_dim;
    }

    // Per-channel max outlier ratio
    if (has_max_abs && imatrix_max_abs && imatrix_max_abs_dim > 1) {
        std::vector<float> mags((size_t)imatrix_max_abs_dim);
        float max_abs = 0.0f;
        for (int64_t i = 0; i < imatrix_max_abs_dim; i++) {
            float v = std::fabsf(imatrix_max_abs[i]);
            mags[(size_t)i] = v;
            if (v > max_abs) max_abs = v;
        }
        if (max_abs > 1e-30f) {
            float med = ts_regime_percentile(mags.data(), imatrix_max_abs_dim, 0.5f);
            if (med > 1e-30f) {
                desc.max_outlier_ratio = max_abs / med;
            }
        }
    }

    return desc;
}

ts_regime_descriptor ts_regime_compute_descriptor(
    const char * tensor_name,
    const float * weights, int64_t out_dim, int64_t in_dim,
    const float * imatrix_data, int64_t imatrix_dim,
    int32_t n_layers_total) {
    return ts_regime_compute_descriptor_impl(
        tensor_name, weights, out_dim, in_dim,
        imatrix_data, imatrix_dim,
        nullptr, 0, n_layers_total, false);
}

ts_regime_descriptor ts_regime_compute_descriptor(
    const char * tensor_name,
    const float * weights, int64_t out_dim, int64_t in_dim,
    const float * imatrix_data, int64_t imatrix_dim,
    const float * imatrix_max_abs, int64_t imatrix_max_abs_dim,
    int32_t n_layers_total) {
    return ts_regime_compute_descriptor_impl(
        tensor_name, weights, out_dim, in_dim,
        imatrix_data, imatrix_dim,
        imatrix_max_abs, imatrix_max_abs_dim, n_layers_total, true);
}

// ---------------------------------------------------------------------------
// Tier 3: Per-expert descriptor for MoE
//
// For expert_idx >= 0, the caller provides per-expert slices of the
// weight matrix and imatrix data. This function produces a descriptor for
// that one expert, using the expert's own activation statistics.
// For non-MoE tensors (expert_idx < 0), delegates to the standard impl.
// ---------------------------------------------------------------------------

ts_regime_descriptor ts_regime_compute_descriptor_for_expert(
    const char * tensor_name,
    const float * expert_weights,
    int64_t out_dim, int64_t in_dim,
    int32_t expert_idx,
    const float * expert_imatrix_data,
    int64_t imatrix_n_tokens,
    const float * expert_imatrix_max_abs,
    int32_t n_layers_total,
    const ts_regime_family_thresholds * thresholds) {
    if (expert_idx < 0) {
        // Non-MoE: use standard path
        ts_regime_descriptor d = ts_regime_compute_descriptor(
            tensor_name, expert_weights, out_dim, in_dim,
            expert_imatrix_data, imatrix_n_tokens,
            expert_imatrix_max_abs, in_dim,
            n_layers_total);
        if (thresholds && thresholds->valid) {
            d.learned_kurt_heavy = thresholds->kurt_heavy;
            d.learned_kurt_light = thresholds->kurt_light;
            d.learned_er_compact = thresholds->er_compact;
            d.learned_er_sparse  = thresholds->er_sparse;
        }
        return d;
    }
    // MoE per-expert: compute stats from this expert's data only.
    // The role stays as ROUTED_EXPERT (per-expert regime is still rotation
    // vs linear; shared expert is already handled above in ts_regime_classify).
    ts_regime_descriptor d = ts_regime_compute_descriptor_impl(
        tensor_name, expert_weights, out_dim, in_dim,
        expert_imatrix_data, imatrix_n_tokens,
        expert_imatrix_max_abs, in_dim,
        n_layers_total, expert_imatrix_max_abs != nullptr);
    // Layer position and role come from the tensor name (same for all experts in a layer)
    d.role         = TS_ROLE_ROUTED_EXPERT;
    d.position     = ts_regime_infer_position(tensor_name, n_layers_total);
    d.default_tier = ts_regime_default_tier(d.role, d.position);
    if (thresholds && thresholds->valid) {
        d.learned_kurt_heavy = thresholds->kurt_heavy;
        d.learned_kurt_light = thresholds->kurt_light;
        d.learned_er_compact = thresholds->er_compact;
        d.learned_er_sparse  = thresholds->er_sparse;
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tier 4: Threshold fitting from outcome data
//
// Fits a simple OLS model of delta_mse on (kurtosis, eff_rank) per family.
// Uses only kurtosis as the primary predictor (SOTA: kurtosis is the dominant
// signal; eff_rank is secondary and used as a tiebreaker).
// ---------------------------------------------------------------------------

static float ts_regime_mean(const float * x, int32_t n) {
    if (n <= 0) return 0.0f;
    float s = 0.0f;
    for (int32_t i = 0; i < n; i++) s += x[i];
    return s / (float)n;
}

ts_regime_threshold_fit ts_regime_fit_thresholds(
    int32_t n_samples,
    const float * kurtosis_vals,
    const float * eff_rank_vals,
    const float * delta_mse_vals,
    const float * awq_mse_vals,
    const std::string & family) {
    ts_regime_threshold_fit fit;
    fit.family     = family;
    fit.valid      = false;
    fit.r2         = 0.0f;
    fit.n_samples  = n_samples;

    if (n_samples < 8) return fit;  // need enough data for OLS

    // Compute relative delta (fractional MSE increase vs AWQ baseline)
    // delta_rel = (expert_mse - awq_mse) / awq_mse
    // A negative delta_rel means the rotation expert beats AWQ.
    // The crossover kurtosis is where delta_rel crosses zero.
    std::vector<float> delta_rel((size_t)n_samples);
    for (int32_t i = 0; i < n_samples; i++) {
        float base = awq_mse_vals ? awq_mse_vals[i] : 1.0f;
        if (base > 1e-12f) {
            delta_rel[(size_t)i] = delta_mse_vals[i] / base;
        } else {
            delta_rel[(size_t)i] = 0.0f;
        }
    }

    // Simple linear regression: delta_rel = a * kurtosis + b
    float k_mean = ts_regime_mean(kurtosis_vals, n_samples);
    float d_mean = ts_regime_mean(delta_rel.data(), n_samples);
    float num = 0.0f, den = 0.0f;
    for (int32_t i = 0; i < n_samples; i++) {
        float dk = kurtosis_vals[i] - k_mean;
        float dd = delta_rel[(size_t)i] - d_mean;
        num += dk * dd;
        den += dk * dk;
    }
    float slope = (den > 1e-12f) ? (num / den) : 0.0f;
    float intercept = d_mean - slope * k_mean;

    // R^2: fraction of variance explained
    float ss_res = 0.0f, ss_tot = 0.0f;
    for (int32_t i = 0; i < n_samples; i++) {
        float pred = slope * kurtosis_vals[i] + intercept;
        float resid = delta_rel[(size_t)i] - pred;
        ss_res += resid * resid;
        float devi = delta_rel[(size_t)i] - d_mean;
        ss_tot += devi * devi;
    }
    fit.r2 = (ss_tot > 1e-12f) ? (1.0f - ss_res / ss_tot) : 0.0f;

    // Crossover kurtosis: delta_rel = 0 => kurt = -intercept / slope
    // Positive slope means delta_rel increases with kurtosis (AWQ gets worse
    // relative to rotation as kurtosis rises). The crossover is where rotation
    // starts beating AWQ.
    if (std::fabsf(slope) > 1e-6f) {
        float crossover = -intercept / slope;
        // Clamp to a reasonable range [0, 100]
        crossover = std::max(0.0f, std::min(100.0f, crossover));
        fit.kurt_crossover = crossover;
        // eff_rank crossover: simple median split of eff_rank where
        // delta_rel < 0 (rotation wins). This is approximate.
        fit.er_crossover = 0.25f;  // conservative default
        // Refine eff_rank crossover from data
        std::vector<float> er_winning;
        for (int32_t i = 0; i < n_samples; i++) {
            if (delta_rel[(size_t)i] < 0.0f) {
                er_winning.push_back(eff_rank_vals[i]);
            }
        }
        if (!er_winning.empty()) {
            std::vector<float> sorted = er_winning;
            std::sort(sorted.begin(), sorted.end());
            fit.er_crossover = sorted[sorted.size() / 2];
        }
    } else {
        // Flat slope: no strong kurtosis trend
        fit.kurt_crossover = k_mean;
        fit.er_crossover = 0.25f;
    }

    fit.valid = (fit.r2 > 0.05f);  // need some explanatory power
    return fit;
}

ts_regime_family_thresholds ts_regime_thresholds_from_fit(
    const char * model_hash,
    const char * model_role,
    const char * family,
    const ts_regime_threshold_fit * fit) {
    ts_regime_family_thresholds t;
    t.model_hash  = model_hash ? model_hash : "";
    t.model_role  = model_role ? model_role : "trunk";
    t.family      = family ? family : "";
    t.valid       = false;
    t.n_samples   = 0;

    if (!fit || !fit->valid) return t;

    // Derived thresholds from the fit:
    // - kurt_heavy: DartQuant vs CHAMPQ crossover (delta_rel < -0.1)
    //   Use kurt_crossover + margin as the rotation threshold
    float margin = 2.0f;
    t.kurt_heavy  = std::max(1.0f, fit->kurt_crossover + margin);
    // - kurt_light: CHAMPQ vs AWQ crossover (delta_rel ~ 0)
    t.kurt_light  = std::max(1.0f, fit->kurt_crossover);
    // - er_compact: FLRQ vs LRQ crossover
    t.er_compact  = std::max(0.01f, fit->er_crossover * 0.5f);
    // - er_sparse: LRQ vs AWQ crossover
    t.er_sparse   = std::max(t.er_compact, fit->er_crossover);

    t.n_samples = fit->n_samples;
    t.valid     = true;
    return t;
}

// ---------------------------------------------------------------------------
// Expert profiles (extended with precision tier)
// ---------------------------------------------------------------------------

const char * ts_expert_name(ts_expert_id expert) {
    switch (expert) {
        case TS_EXPERT_AWQ:       return "AWQ";
        case TS_EXPERT_LRQ:       return "LRQ";
        case TS_EXPERT_DARTQUANT: return "DartQuant";
        case TS_EXPERT_FLRQ:      return "FLRQ";
        case TS_EXPERT_CHAMPQ:    return "CHAMP-Q";
        case TS_EXPERT_SEPTQ:     return "SEPTQ";
        default:                  return "unknown";
    }
}

ts_expert_profile ts_expert_default_profile(ts_expert_id expert,
                                            int modality_id,
                                            ts_regime_precision_tier tier) {
    ts_expert_profile p;
    p.alpha_scale    = 1.0f;
    p.clip_scale     = 1.0f;
    p.use_septq      = false;
    p.awq_grid      = 20;
    p.max_outliers  = 0;
    p.outlier_thresh = 1.0f;
    p.precision_tier = tier;

    switch (expert) {
        case TS_EXPERT_AWQ:
            break;
        case TS_EXPERT_DARTQUANT:
            // rotation expert for massive outliers: tighter selection, larger repair
            p.outlier_thresh = 0.8f;
            p.max_outliers   = 12;
            break;
        case TS_EXPERT_CHAMPQ:
            // permutation expert: finer alpha search, slightly stronger scaling
            p.awq_grid    = 40;
            p.alpha_scale = 1.1f;
            break;
        case TS_EXPERT_FLRQ:
            // factored low-rank: Hessian proxy, gentler clip
            p.use_septq  = true;
            p.clip_scale = 0.9f;
            break;
        case TS_EXPERT_LRQ:
            // aggressive low-rank: Hessian proxy, reduced alpha and clip
            p.use_septq    = true;
            p.alpha_scale = 0.9f;
            p.clip_scale   = 0.85f;
            break;
        case TS_EXPERT_SEPTQ:
            // Hessian compensation expert: SEPTQ on, finer grid
            p.use_septq = true;
            p.awq_grid  = 30;
            break;
        default:
            break;
    }

    // Per-modality adjustments
    if (modality_id == 2) {
        p.clip_scale *= 0.8f;   // audio: tighter clip
    } else if (modality_id == 1) {
        p.max_outliers += 4;      // image: wider outlier budget
    }

    // Precision tier drives max_outliers for rotation experts.
    // Q4 tier (most aggressive) needs the largest outlier budget.
    // Q8 tier can afford a tighter budget (less compression pressure).
    if (expert == TS_EXPERT_DARTQUANT || expert == TS_EXPERT_CHAMPQ) {
        switch (tier) {
            case TS_TIER_Q4: p.max_outliers = std::max(p.max_outliers, 16); break;
            case TS_TIER_Q5: p.max_outliers = std::max(p.max_outliers, 12); break;
            case TS_TIER_Q6: p.max_outliers = std::max(p.max_outliers,  8); break;
            case TS_TIER_Q8: p.max_outliers = std::max(p.max_outliers,  4); break;
        }
    }

    return p;
}

// ---------------------------------------------------------------------------
// Summary (extended with Tier 1 breakdown)
// ---------------------------------------------------------------------------

ts_regime_summary ts_regime_summarize(const std::vector<ts_regime_routing> * routings,
                                      const ts_regime_descriptor * descs,
                                      int64_t n_tensors) {
    ts_regime_summary s;
    std::memset(&s, 0, sizeof(s));
    s.mean_kurtosis = 0.0f;
    s.mean_eff_rank = 0.0f;

    if (routings) {
        for (const auto & r : *routings) {
            if (r.expert >= 0 && r.expert < TS_EXPERT_COUNT) {
                s.count_per_expert[r.expert]++;
            }
            int ri = static_cast<int>(r.role);
            int pi = static_cast<int>(r.position);
            if (ri >= 0 && ri < 4) s.count_by_role[ri]++;
            if (pi >= 0 && pi < 3) s.count_by_position[pi]++;
        }
    }

    if (descs && n_tensors > 0) {
        for (int64_t i = 0; i < n_tensors; i++) {
            s.mean_kurtosis += descs[i].kurtosis;
            s.mean_eff_rank += descs[i].eff_rank;
        }
        s.mean_kurtosis  /= (float)n_tensors;
        s.mean_eff_rank /= (float)n_tensors;
    }

    return s;
}
