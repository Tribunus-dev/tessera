#pragma once

//
// tessera-regime.h
//
// Operative regime router: connects ts_route_expert to real imatrix
// data and tensor metadata. Infers tensor families from names, computes
// regime descriptors from activation statistics, and routes each tensor
// to its best expert (AWQ, LRQ, DartQuant, FLRQ, CHAMP-Q, SEPTQ).
//
// Architecture (4-tier dynamic routing):
//   Tier 1 - Zero-cost: tensor role + layer position -> precision budget
//             (before any forward pass; static information only)
//   Tier 2 - Activation stats: imatrix kurtosis/eff_rank -> rotation vs. linear
//             (per-family thresholds from DuckDB learned priors)
//   Tier 3 - Per-expert search: MoE each expert gets its own regime
//             (GA runs once per expert, not once per flattened tensor)
//   Tier 4 - L5 feedback: outcome log -> threshold refit per family
//             (DuckDB l5_outcome feeds OLS -> updated thresholds)
//

#include <string>
#include <vector>
#include <cstdint>
#include <cstring>   // for memset

#include "tessera-search.h"

// ---------------------------------------------------------------------------
// Tier 1: Zero-cost tensor role + layer position
// ---------------------------------------------------------------------------

// Tensor structural role — drives precision budget assignment.
// Inferred from tensor name without any forward pass.
enum ts_regime_role {
    TS_ROLE_OTHER        = 0,  // everything else
    TS_ROLE_ATTENTION    = 1,  // attn_q, attn_k, attn_v, attn_out
    TS_ROLE_ROUTED_EXPERT = 2, // ffn_gate_exps, ffn_up_exps, ffn_down_exps
                                // (MoE per-expert weights, sparsity means
                                // aggressive quantization is tolerated)
    TS_ROLE_SHARED_EXPERT = 3,  // ffn_gate_shexp, ffn_up_shexp, ffn_down_shexp
                                // (always-active, heavy-tailed, kurtosis ~13,
                                // needs rotation expert or higher precision)
};

// Layer position in the transformer stack — drives how aggressive
// the precision budget can be. Edge layers (embed alignment + logit
// generation) are significantly more sensitive than middle layers.
enum ts_regime_position {
    TS_POS_MIDDLE    = 0,  // middle transformer layers: redundant, compress hard
    TS_POS_NEAR_EDGE = 1,  // ~10% from each end: medium sensitivity
    TS_POS_EDGE      = 2,  // first/last ~5 layers: highest sensitivity
};

// Precision tier enum (maps to nominal GGUF bits).
// The concrete qtype (Q4_K_S vs Q4_K_M etc.) is decided by the
// quantization dispatch; this enum only carries the budget signal.
enum ts_regime_precision_tier {
    TS_TIER_Q4  = 0,  // aggressive (4-bit)
    TS_TIER_Q5  = 1,  // medium (5-bit)
    TS_TIER_Q6  = 2,  // protective (6-bit)
    TS_TIER_Q8  = 3,  // high-fidelity (8-bit, shared expert default)
};

// Default precision tier per (role, position). Rationale:
//   - Shared expert (always active, kurtosis ~13): Q8 minimum.
//     APEX shows Q8_0 on shared experts is required to avoid
//     catastrophic quality degradation.
//   - Routed expert: sparsity means inactive expert weights never
//     contribute error; middle layers can go to Q4. Edge routed
//     experts still need Q5-Q6 for the few that activate.
//   - Attention: dense; edge/attention overlap -> edge Q6, rest Q5.
//   These defaults apply when imatrix data is absent. When imatrix
//   is available, Tier 2 overrides via learned thresholds.
static inline ts_regime_precision_tier ts_regime_default_tier(
        ts_regime_role role, ts_regime_position pos) {
    if (role == TS_ROLE_SHARED_EXPERT) {
        return TS_TIER_Q8;  // always-on + heavy tail = no compromise
    }
    if (role == TS_ROLE_ROUTED_EXPERT) {
        if (pos == TS_POS_MIDDLE)    return TS_TIER_Q4;
        if (pos == TS_POS_NEAR_EDGE) return TS_TIER_Q5;
        return TS_TIER_Q6;
    }
    if (role == TS_ROLE_ATTENTION) {
        if (pos == TS_POS_MIDDLE)    return TS_TIER_Q5;
        if (pos == TS_POS_NEAR_EDGE) return TS_TIER_Q5;
        return TS_TIER_Q6;
    }
    return TS_TIER_Q5;  // other (norms, embeddings): conservative
}

// ---------------------------------------------------------------------------
// Regime descriptor — full tensor characterization
// ---------------------------------------------------------------------------

struct ts_regime_descriptor {
    std::string tensor_name;
    std::string family;         // "attn_q", "attn_k", "attn_v", "attn_out",
                                // "ffn_gate", "ffn_up", "ffn_down",
                                // "ssm_in", "ssm_out", "ssm_conv", "ssm_norm",
                                // "ffn_gate_inp", "routed_expert", "moe_gate",
                                // "unknown"
    float       kurtosis;       // activation kurtosis from imatrix
    float       eff_rank;       // effective rank (spectral entropy)
    float       mean_magnitude; // mean |activation|
    float       p99;            // 99th percentile
    int64_t     out_dim;
    int64_t     in_dim;
    int32_t     modality;        // 0=text, 1=image, 2=audio (default 0)

    // Per-channel max-outlier concentration, derived from the imatrix
    // .in_maxabs field when available: ratio of the largest per-channel
    // max|activation| to the median across channels. 1.0 means outliers are
    // spread evenly (no single channel dominates); large values mean a small
    // set of channels carry the heavy tail and the rotation/permutation
    // experts should grow their per-row repair budget accordingly. 0.0 when
    // no per-channel max is available (legacy .npz, or producer run that did
    // not collect max) - experts then keep their default outlier budget.
    float       max_outlier_ratio;

    // --- Tier 1 fields: zero-cost (from name + layer index only) ---
    ts_regime_role      role;         // structural role (attention / routed / shared / other)
    ts_regime_position  position;      // EDGE / NEAR_EDGE / MIDDLE
    ts_regime_precision_tier default_tier;  // precision budget signal
    int32_t             layer_depth;   // block index (0 for non-block tensors), -1 if N/A

    // --- Tier 2 fields: from DuckDB learned thresholds (null = use builtin) ---
    float  learned_kurt_heavy;   // kurtosis threshold: above this -> rotation expert
    float  learned_kurt_light;    // kurtosis threshold: above this -> permutation expert
    float  learned_er_compact;   // eff_rank threshold: below this -> low-rank expert
    float  learned_er_sparse;    // eff_rank threshold: below this -> factored low-rank
};

// ---------------------------------------------------------------------------
// Regime routing result
// ---------------------------------------------------------------------------

struct ts_regime_routing {
    std::string  tensor_name;
    ts_expert_id expert;
    std::string  reason;         // human-readable routing reason
    float        confidence;      // routing confidence [0, 1]
    // Tier 1 signals for audit trail
    ts_regime_role         role;
    ts_regime_position     position;
    ts_regime_precision_tier precision_tier;
    // Tier 2 source: "static" = builtin cascade, "learned" = from DuckDB prior
    std::string  threshold_source;
};

// ---------------------------------------------------------------------------
// Tier 2: Learned per-family threshold struct
//
// Populated by the caller from DuckDB (ts_tessera_db_list_regime_thresholds).
// When all fields are zero/NULL, ts_regime_classify uses the builtin cascade.
// ---------------------------------------------------------------------------

struct ts_regime_family_thresholds {
    std::string model_hash;
    std::string model_role;   // "trunk" / "dflash" / "dspark" / "mtp_nextn" / "shared_embd"
    std::string family;        // "attn_q", "ffn_gate", etc.
    float        kurt_heavy;   // kurt > kurt_heavy -> DartQuant (0 = use builtin)
    float        kurt_light;    // kurt > kurt_light -> CHAMPQ
    float        er_compact;    // er < er_compact -> LRQ
    float        er_sparse;     // er < er_sparse -> FLRQ
    int32_t      n_samples;     // number of l5_outcome rows that informed this
    bool         valid;         // false when no prior exists for this (model, family)
};

// ---------------------------------------------------------------------------
// Tier 4: OLS result for threshold refitting
//
// Fits a simple model of delta_mse on (kurtosis, eff_rank) per family
// from l5_outcome rows. Used to update ts_regime_family_thresholds
// for the next dispatch run.
// ---------------------------------------------------------------------------

struct ts_regime_threshold_fit {
    std::string family;
    float        kurt_crossover;   // kurtosis at which error switches from AWQ-optimal to rotation-optimal
    float        er_crossover;     // eff_rank below which LRQ beats AWQ
    float        r2;              // coefficient of determination (0-1, 0 = no fit)
    int32_t      n_samples;
    bool         valid;
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Infer tensor family from name (e.g. "blk.0.attn_q.weight" -> "attn_q").
// MoE variants are also handled: "blk.0.ffn_gate_exps.weight" -> "ffn_gate".
std::string ts_regime_infer_family(const char * tensor_name);

// Infer structural role (attention / routed expert / shared expert / other).
ts_regime_role ts_regime_infer_role(const char * tensor_name);

// Infer modality from tensor name patterns (0=text, 1=image, 2=audio).
// Vision/audio embedder tensors map to their modality; everything else
// (the shared LM blocks) defaults to text.
int ts_regime_infer_modality(const char * tensor_name);

// Infer layer position from tensor name.
// Extracts the block index from "blk.N." prefix and maps it to
// EDGE / NEAR_EDGE / MIDDLE using the given n_layers_total.
// Returns TS_POS_MIDDLE if no block index is found.
ts_regime_position ts_regime_infer_position(const char * tensor_name, int32_t n_layers_total);

// Extract layer depth from "blk.N." prefix. Returns -1 if not found.
int32_t ts_regime_extract_layer(const char * tensor_name);

// Classify a tensor's regime from its descriptors.
// The descriptor carries Tier 1 (role, position) and Tier 2 (imatrix stats)
// signals. thresholds (may be null) provides per-family learned priors.
// Returns the routing decision with reason + confidence.
ts_regime_routing ts_regime_classify(const ts_regime_descriptor * desc,
                                     const ts_regime_family_thresholds * thresholds = nullptr);

// Route all tensors in a model. Returns one routing per tensor.
std::vector<ts_regime_routing> ts_regime_route_all(
    const ts_regime_descriptor * descs,
    int64_t n_tensors,
    const ts_regime_family_thresholds * thresholds);

// Compute regime descriptors from imatrix data + weight matrix.
// Fills kurtosis, eff_rank, mean_magnitude, p99 from activation stats.
// max_outlier_ratio is left at 0 (no per-channel max supplied).
// Tier 1 fields (role, position, default_tier, layer_depth) are always filled
// from the tensor name, independent of imatrix availability.
ts_regime_descriptor ts_regime_compute_descriptor(
    const char * tensor_name,
    const float * weights, int64_t out_dim, int64_t in_dim,
    const float * imatrix_data, int64_t imatrix_dim,
    int32_t n_layers_total = 0);

// As above, but also fills max_outlier_ratio from the per-channel max|act|
// vector (the imatrix .in_maxabs field, in_dim floats). imatrix_max_abs may
// be null / imatrix_max_abs_dim 0 to signal "no per-channel max available";
// the descriptor then keeps max_outlier_ratio = 0 and the experts fall back
// to their default outlier budget.
ts_regime_descriptor ts_regime_compute_descriptor(
    const char * tensor_name,
    const float * weights, int64_t out_dim, int64_t in_dim,
    const float * imatrix_data, int64_t imatrix_dim,
    const float * imatrix_max_abs, int64_t imatrix_max_abs_dim,
    int32_t n_layers_total = 0);

// ---------------------------------------------------------------------------
// Tier 3: Per-expert regime computation for MoE
//
// ts_quantize_3d runs one GA per expert over the flattened 3D weight
// (n_experts x out_dim x in_dim). Before the GA, the regime classifier
// needs a descriptor per expert, not one per flattened tensor. This function
// computes that per-expert descriptor from the full 3D weight + per-expert
// imatrix data.
//
// For non-MoE tensors (expert_idx < 0), calls through to the standard
// ts_regime_compute_descriptor above.
ts_regime_descriptor ts_regime_compute_descriptor_for_expert(
    const char * tensor_name,
    const float * expert_weights,    // (out_dim x in_dim) slice for this expert
    int64_t out_dim, int64_t in_dim,
    int32_t expert_idx,             // -1 for non-MoE
    const float * expert_imatrix_data,    // (n_tokens x in_dim) or nullptr
    int64_t imatrix_n_tokens,
    const float * expert_imatrix_max_abs, // (in_dim,) or nullptr
    int32_t n_layers_total,
    const ts_regime_family_thresholds * thresholds);

// ---------------------------------------------------------------------------
// Tier 4: Threshold fitting from DuckDB l5_outcome rows
//
// Fits a simple OLS model of (kurtosis, eff_rank) -> regime-switch delta_mse
// for one (model_hash, family) from accumulated outcome rows.
// The fit returns the crossover points where AWQ vs rotation experts trade off.
// Returns an invalid fit when n_samples < 8 (insufficient data).
ts_regime_threshold_fit ts_regime_fit_thresholds(
    int32_t n_samples,
    const float * kurtosis_vals,    // [n_samples]
    const float * eff_rank_vals,     // [n_samples]
    const float * delta_mse_vals,    // [n_samples] rel MSE delta vs AWQ baseline
    const float * awq_mse_vals,      // [n_samples] baseline AWQ MSE
    const std::string & family);

// ---------------------------------------------------------------------------
// Tier 4: Build thresholds struct from a threshold fit
//
// Converts a ts_regime_threshold_fit into a ts_regime_family_thresholds
// with defaults applied. The fit's crossover points become the learned
// thresholds; missing fields fall back to the builtin cascade values.
ts_regime_family_thresholds ts_regime_thresholds_from_fit(
    const char * model_hash,
    const char * model_role,
    const char * family,
    const ts_regime_threshold_fit * fit);

// ---------------------------------------------------------------------------
// Per-expert quantization parameter profile
// ---------------------------------------------------------------------------

struct ts_expert_profile {
    float alpha_scale;       // multiplier on AWQ alpha (1.0 = no change)
    float clip_scale;       // multiplier on AWQ clip
    bool  use_septq;        // enable SEPTQ Hessian compensation
    int   awq_grid;        // AWQ grid search resolution
    int   max_outliers;     // outlier budget (per row)
    float outlier_thresh;   // outlier threshold multiplier
    // Tier 1: precision tier drives the profile
    ts_regime_precision_tier precision_tier;
};

// Return the default parameter profile for a routed expert. The optional
// modality_id (0=text, 1=image, 2=audio) layers per-modality adjustments
// on top of the expert baseline: audio tightens the clip, image widens the
// outlier budget, text is unchanged. The 2-arg overload infers the precision
// tier from the expert type (AWQ/LRQ -> Q5, DartQuant/CHAMPQ -> Q6, FLRQ -> Q4).
ts_expert_profile ts_expert_default_profile(ts_expert_id expert,
                                            int modality_id = 0,
                                            ts_regime_precision_tier tier = TS_TIER_Q5);

// Human-readable expert name ("AWQ", "LRQ", "DartQuant", ...).
const char * ts_expert_name(ts_expert_id expert);

// Summary statistics for a routing plan.
struct ts_regime_summary {
    int64_t count_per_expert[TS_EXPERT_COUNT];
    float   mean_kurtosis;
    float   mean_eff_rank;
    // Tier 1 breakdown
    int64_t count_by_role[4];
    int64_t count_by_position[3];
};

ts_regime_summary ts_regime_summarize(const std::vector<ts_regime_routing> * routings,
                                      const ts_regime_descriptor * descs,
                                      int64_t n_tensors);
