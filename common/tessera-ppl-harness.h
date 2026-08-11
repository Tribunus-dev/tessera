#pragma once

//
// tessera-ppl-harness.h
//
// Joint perplexity harness for L5 adaptive requantization across the
// target model + 3 spec drafters (DFlash, DSPark, MTP) + talker.
//
// One forward pass captures all 5 models' logits. Per-model PPL is
// extracted via the existing ts_ppl_perplexity. The per-model
// normalized delta is the metric; the AND-gate across all 5 deltas
// is the termination criterion.
//
// Phase rollout: see .zcode/plans/plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d.md
//   v1 - this file + tessera-ppl-harness.cpp + test_ppl_harness.cpp
//   v2 - L5 joint policy struct + coarse-to-fine search loop (target alone)
//   v3 - full 5-model joint L5 (talker integration into ADAPTIVE muxer)
//   v4 - --tessera-l5-strict mode + acceptance gate
//

#include <cstdint>
#include <string>
#include <vector>

// --- Family taxonomy (locked, see plan section "Search axes per family") ---

enum ts_l5_family : int32_t {
    TS_L5_FAMILY_ATTN_Q    = 0,
    TS_L5_FAMILY_ATTN_K    = 1,
    TS_L5_FAMILY_ATTN_V    = 2,
    TS_L5_FAMILY_ATTN_OUT  = 3,
    TS_L5_FAMILY_FFN_GATE  = 4,
    TS_L5_FAMILY_FFN_UP    = 5,
    TS_L5_FAMILY_FFN_DOWN  = 6,
    TS_L5_FAMILY_COUNT     = 7,
};

// --- Outlier layout (3 options) ---

enum ts_l5_outlier_layout : int32_t {
    TS_L5_OUTLIER_PER_ROW    = 0,   // current T640 default
    TS_L5_OUTLIER_PER_BLOCK  = 1,
    TS_L5_OUTLIER_PER_TENSOR = 2,
    TS_L5_OUTLIER_COUNT      = 3,
};

// --- Model identity (5 models in the joint forward pass) ---

enum ts_l5_model : int32_t {
    TS_L5_MODEL_TARGET = 0,
    TS_L5_MODEL_DFLASH = 1,
    TS_L5_MODEL_DSPARK = 2,
    TS_L5_MODEL_MTP    = 3,
    TS_L5_MODEL_TALKER = 4,
    TS_L5_MODEL_COUNT  = 5,
};

// --- Per-family policy: outlier_layout, algorithm_id, alpha, clip ---
//
// qtype is pinned at ternary+outliers (no qtype dimension in the search).
// algorithm_id is an index into a model-specific set of fused interleaved
// kernel options. The actual kernel enum is per-model and lives in the
// model-specific code; L5 just uses the integer id.

struct ts_l5_family_policy {
    ts_l5_outlier_layout outlier_layout = TS_L5_OUTLIER_PER_ROW;
    int32_t              algorithm_id   = 0;
    float                alpha          = 0.5f;
    float                clip           = 0.95f;
};

// --- Joint policy across all 5 models x 7 families ---
//
// Per model, a 7-tuple of ts_l5_family_policy. Per the locked design,
// the search is joint across the 7 families within a model (not
// sequential greedy) because per-family greedy misses cross-layer error
// amplification.
//
// `models_active[i] = false` means the i-th model's policy is fixed at
// FP baseline (its delta_i is 0 by construction; the AND-gate skips it).
// v1: all 5 models inactive (FP baseline only). v2: target active only.
// v3: all 5 active.

struct ts_l5_joint_policy {
    ts_l5_family_policy families[TS_L5_MODEL_COUNT][TS_L5_FAMILY_COUNT];
    bool                models_active[TS_L5_MODEL_COUNT] = {false, false, false, false, false};
};

// --- Search parameters ---

struct ts_l5_joint_params {
    float epsilon          = 0.0099f;  // per-model AND-gate threshold (0.99% default)
    int32_t top_k          = 4;        // number of top policies kept across generations
    int32_t max_generations = 5;       // coarse-to-fine max gens before forced termination
    int32_t n_gen0_samples = 32;       // N joint policies sampled in gen 0
    int32_t n_evo_pop      = 16;       // evolutionary population size
    int32_t n_evo_gens     = 2;        // evolutionary generations when escape fires
    float delta_converged  = 0.001f;   // top-K PPL convergence: max-min < this
    uint32_t rng_seed      = 0x5EED5u; // search RNG seed (deterministic by default)
    bool   verbose         = false;
};

// --- Harness: the joint forward pass + per-model PPL extraction ---
//
// A harness instance holds the 5 model contexts + their vocab sizes
// + the layer at which each drafter consumes the trunk's hidden state.
// The forward functions are model-specific (DFlash consumes at one
// target_layer_id, MTP at another); v1 uses synthetic uniform-random
// forward functions for the test; v3 replaces with the real ADAPTIVE
// muxer forward.

struct ts_l5_ppl_harness {
    // Per-model vocab size. Trunk and drafters typically share the
    // text vocab; talker has its own audio vocab.
    int32_t vocab_size[TS_L5_MODEL_COUNT] = {32000, 32000, 32000, 32000, 4096};

    // Per-drafter target_layer_id (the trunk layer at which the drafter
    // consumes the hidden state). Unused for target (the trunk IS the
    // target) and talker (talker consumes the trunk's final output).
    int32_t drafter_target_layer[TS_L5_MODEL_COUNT] = {-1, 8, 12, 16, -1};

    // Token-budget for the joint forward pass. 256 by default; the
    // calibration set provides the actual tokens at v2+; v1 uses
    // random tokens (HIGGS-style data-free probe).
    int32_t n_tokens         = 256;
    uint32_t rng_seed        = 42;

    // User-owned model contexts (per-model opaque pointers). The
    // forward callbacks take these.
    void * model_ctx[TS_L5_MODEL_COUNT] = {nullptr, nullptr, nullptr, nullptr, nullptr};
};

// --- Forward callback for the trunk ---
//
// Runs the trunk forward on the input tokens, fills `trunk_logits_out`
// (n_tokens x vocab_size[TS_L5_MODEL_TARGET]), and returns the per-block
// hidden states via the optional `hidden_states_out` and
// trunk_final_output_out (for the talker). For v1's synthetic test, the
// forward just produces uniform random logits; v3's real forward uses
// the ADAPTIVE muxer.

struct ts_l5_ppl_joint_buffers;

using ts_l5_trunk_forward_fn = void (*)(
        const int32_t * tokens,
        int32_t n_tokens,
        float * trunk_logits_out,        // n_tokens x vocab_size[TARGET]
        float * trunk_final_output_out,  // n_tokens x hidden_dim (for talker)
        void * ctx);

using ts_l5_drafter_forward_fn = void (*)(
        const float * hidden_state_in,   // n_tokens x hidden_dim
        int32_t n_tokens,
        int32_t hidden_dim,
        float * drafter_logits_out,      // n_tokens x vocab_size[model]
        void * ctx);

using ts_l5_talker_forward_fn = void (*)(
        const float * trunk_final_output, // n_tokens x hidden_dim
        int32_t n_tokens,
        int32_t hidden_dim,
        float * talker_logits_out,        // n_tokens x vocab_size[TALKER]
        void * ctx);

// --- Per-model PPL extraction result ---

struct ts_l5_ppl_per_model {
    float ppl_fp;     // FP baseline PPL (no requantization)
    float ppl_quant;  // PPL with the current policy applied
    float delta;      // (ppl_quant - ppl_fp) / ppl_fp  (the per-model normalized delta)
    bool  pass;       // delta < params.epsilon
};

// --- Joint measurement result ---

struct ts_l5_ppl_joint_result {
    ts_l5_ppl_per_model per_model[TS_L5_MODEL_COUNT];
    bool all_pass;                  // AND-gate: all active models' delta < epsilon
    int64_t n_tokens_used;
};

// --- Entry point: run the joint forward pass + extract per-model PPL ---

// Runs the joint forward pass for both FP and the supplied joint
// policy, computes per-model PPL, and returns per-model delta. The
// harness holds the model contexts and the forward functions.
//
// For v1 (FP-only sanity), pass policy with all `models_active[i] = false`.
// The quant path is skipped; the result is the FP PPL per model, all
// deltas are 0, all_pass is trivially true.
//
// For v2+, the quant path runs the trunk forward with the policy
// applied, the 3 drafter forwards with their respective policies, and
// the talker forward with its policy. The forward functions are
// responsible for applying the policy (outlier_layout, algorithm_id,
// alpha, clip) to their model.
//
// Returns 0 on success, -1 on invalid args.
int ts_l5_ppl_joint_measure(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT], // index by ts_l5_model
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_policy * policy,
        const ts_l5_joint_params * params,
        ts_l5_ppl_joint_result * result);

// --- Utility: evaluate the AND-gate ---

// Returns true iff all ACTIVE models satisfy delta < epsilon.
// Inactive models (models_active[i] = false) are skipped.
bool ts_l5_joint_and_gate(
        const ts_l5_ppl_joint_result * result,
        const ts_l5_joint_policy * policy,
        float epsilon);

// --- Utility: per-model PPL from logits + tokens (wraps ts_ppl_perplexity) ---

// Each call computes PPL for one model. logit buffer is n_tokens x vocab_size.
// Returns the PPL value, or -1.0 on invalid args.
float ts_l5_ppl_per_model_compute(
        const float * logits,
        const int32_t * targets,
        int32_t n_tokens,
        int32_t vocab_size);
