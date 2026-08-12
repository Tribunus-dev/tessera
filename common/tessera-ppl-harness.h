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
// Production wiring (v3 follow-up): ts_l5_joint_models holds the
// real llama_model + llama_context pointers for all 5 models. The
// 5 forward functions (trunk + 3 drafters + talker) use llama_decode
// to run the actual model and extract logits. The harness slots
// are wired with these real forwards via the dispatch.

#include <cstdint>
#include <string>
#include <vector>

// Forward-declare llama types to keep this header light. The
// .cpp file (tessera-ppl-harness.cpp) is the only consumer that
// needs the full llama.h; tests and search code don't.
struct llama_model;
struct llama_context;
struct llama_vocab;

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

// --- Search metric (how the per-model deltas collapse to one scalar) ---
//
// MAX (default): worst active delta drives the search. This guarantees
//                that every active model - including the 3 drafters and
//                the talker - gets full optimization when it is the
//                worst case. Without MAX, the SUM metric is dominated
//                by the model with the largest normalized delta and
//                the drafters are shaded by the target's own deltas.
// SUM:           sum of active deltas. Earlier design; kept for
//                comparison + for the case where the user wants a
//                smoother gradient (sum is differentiable, max is not).
// MEAN:          average of active deltas. Like SUM but normalized by
//                count; useful when the active-model count varies.
//
// The AND-gate (all active deltas < epsilon) is always enforced
// independently of the metric - it's the binary termination criterion.
// The metric only drives the ranking, the slippery detection, and the
// top-K convergence check.

enum class ts_l5_joint_metric : int32_t {
    MAX  = 0,
    SUM  = 1,
    MEAN = 2,
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
    ts_l5_joint_metric metric = ts_l5_joint_metric::MAX; // default MAX so drafters get full optimization
    bool   verbose         = false;
    // Checkpoint keys. Set by the caller before passing params to ts_l5_joint_search.
    // run_id groups all generations of one L5 search session.
    // model_hash ties the checkpoint to the specific model+quantization.
    std::string run_id;
    std::string model_hash;
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

// ===========================================================================
// Real model wiring (v3 production follow-up)
// ===========================================================================
//
// ts_l5_joint_models holds the 5 llama_model + llama_context pairs.
// The forward functions take a context pointer and use llama_decode
// to run the real model, extracting logits via llama_get_logits_ith.
// The forward functions are bound to the harness via the
// ts_l5_drafter_forward_fn / ts_l5_talker_forward_fn /
// ts_l5_trunk_forward_fn slots.
//
// The model load is best-effort: any of the 5 paths may be empty,
// in which case the corresponding slot is inactive (delta = 0 by
// construction; the AND-gate skips it).
//
// The trunk forward produces per-token logits + a per-block hidden
// state buffer (allocated by the forward, freed by the next forward
// call or by ts_l5_joint_models_free). For v3, the drafter forwards
// consume the same input tokens (not the per-block hidden state);
// the cross-model hidden state sharing is a v3.5+ piece that uses
// the ADAPTIVE muxer's graph-injection infrastructure.

struct ts_l5_joint_models {
    llama_model  * m[TS_L5_MODEL_COUNT] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    llama_context* c[TS_L5_MODEL_COUNT] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    // Per-block hidden state buffer (allocated by the trunk forward
    // for v3.5+ cross-model sharing; nullptr at v3).
    float * trunk_hidden_state = nullptr;
    int32_t trunk_hidden_state_tokens = 0;
    int32_t trunk_hidden_state_dim    = 0;
};

// Load the 5 models. Empty path for a model = that slot is inactive.
// On success, the 5 contexts are created with n_ctx tokens of context.
// Returns 0 on success, -1 on any failure (caller should call
// ts_l5_joint_models_free to release whatever was loaded before
// the failure).
int ts_l5_joint_models_load(
        const std::string & target_path,
        const std::string & dflash_path,
        const std::string & dspark_path,
        const std::string & mtp_path,
        const std::string & talker_path,
        int32_t n_ctx,
        int32_t n_threads,
        ts_l5_joint_models * out_models,
        std::string * err_msg);

// Free the 5 models. Safe to call on a partially-loaded models
// struct (any nullptr slot is skipped).
void ts_l5_joint_models_free(ts_l5_joint_models * models);

// --- Real forward functions (v3 production wiring) ---

// Trunk forward: tokenize the calibration text + run llama_decode on
// the target context + extract per-token logits to trunk_logits_out.
// For v3, the per-block hidden state is not exposed; the drafter
// forwards will see the same input tokens (the cross-model hidden
// state sharing is v3.5+ via the ADAPTIVE muxer).
void ts_l5_real_trunk_forward(
        const int32_t * tokens,
        int32_t n_tokens,
        float * trunk_logits_out,
        float * trunk_final_output_out,
        void * ctx);

// Drafter forward: run llama_decode on the drafter context with the
// same input tokens, extract logits to drafter_logits_out. The
// hidden_state_in is the trunk's per-block hidden state (v3.5+ wire
// up; for v3 it's used as a context reference only).
void ts_l5_real_drafter_forward(
        const float * hidden_state_in,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * drafter_logits_out,
        void * ctx);

// Talker forward: take the trunk's last token argmax as input,
// run llama_decode on the talker context, extract audio logits to
// talker_logits_out. The trunk_final_output is the trunk's last
// hidden state (v3.5+ consume; for v3 we use the trunk's argmax
// token as the talker's seed).
void ts_l5_real_talker_forward(
        const float * trunk_final_output,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * talker_logits_out,
        void * ctx);
