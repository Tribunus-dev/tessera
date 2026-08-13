#pragma once

//
// tessera-l5-joint.h
//
// L5 joint search loop API. The harness types (ts_l5_ppl_harness,
// ts_l5_joint_policy, ts_l5_joint_params, etc.) live in
// tessera-ppl-harness.h; this header adds the search-loop API on top.
//
// Search architecture (locked, see plan):
//   Gen 0:  sample N joint policies from a coarse grid of
//           (outlier_layout, algorithm) per family; alpha/clip seeded.
//   Gen 1+: refine top-K with continuous alpha/clip search around
//           the winning (outlier_layout, algorithm) per family.
//   Slippery detection: if per-gen PPL improvement < epsilon/5,
//           switch that model to evolutionary (1-2 gens of mutation
//           + crossover on the (outlier_layout, algorithm, alpha, clip)
//           tuple).
//   Termination: AND-gate across all active models' deltas, AND
//           velocity gate: winning joint_ppl flat for velocity_window
//           generations (see tessera-convergence.h).
//
// Per-model sequential: at v2, only the target model is active. v3
// activates the 3 drafters + talker. The search resolves models
// sequentially; each model's resolution includes a cross-model PPL
// gate to prevent local optima.
//

#include "tessera-ppl-harness.h"

#include <cstdint>
#include <vector>

// --- Top-K entry in the search history ---
//
// A top-K entry holds the policy that was evaluated, the resulting
// per-model deltas, the joint PPL metric (the configured metric over
// the active models' deltas), and the worst-case delta (always tracked
// so the report can show the worst per-model delta without recomputing).
//
// The search keeps the top-K entries by ascending joint_ppl. With the
// MAX metric (the default), joint_ppl == max_per_model_delta; with
// SUM, joint_ppl is the sum; with MEAN, joint_ppl is the mean.
//
// The MAX default ensures every active model - including the 3
// drafters and the talker - gets full optimization when it is the
// worst case. SUM shades the smaller-delta models (often the
// drafters) under the larger-delta model (often the target). MEAN
// is a softer version of SUM normalized by the active-model count.
//
// Note: ts_l5_joint_metric is defined in tessera-ppl-harness.h
// (alongside ts_l5_joint_params, which holds the metric field).

struct ts_l5_joint_topk_entry {
    ts_l5_joint_policy    policy;
    ts_l5_ppl_joint_result measure;
    float                 joint_ppl;          // metric(per_model.delta) for active models
    float                 max_per_model_delta; // worst active delta (always tracked)
};

// --- Generation result ---
//
// The result of one generation of the search: the N sampled policies,
// their measurements, and the top-K (subset).

struct ts_l5_joint_gen_result {
    int32_t generation;
    bool    and_gate_passed;             // AND-gate met this generation
    bool    converged;                   // velocity gate fired this generation
    bool    switched_to_evolutionary;    // slippery escape fired this generation
    std::vector<ts_l5_joint_topk_entry> all_entries;  // N entries (or N_evo for evolutionary)
    std::vector<ts_l5_joint_topk_entry> top_k;        // top-K by joint_ppl
};

// --- Final search result ---
//
// The cumulative result across all generations. The winning policy
// is top_k[0] of the LAST generation (lowest joint_ppl). The status
// tells the caller whether the search converged, was forced
// terminated (max_generations hit), or fell back to best-effort.

struct ts_l5_joint_search_result {
    std::vector<ts_l5_joint_gen_result> generations;
    ts_l5_joint_topk_entry winning_entry;
    enum class Status : int32_t {
        CONVERGED          = 0,  // AND-gate + top-K convergence
        FORCED_TERMINATION = 1,  // max_generations hit
        BEST_EFFORT        = 2,  // evolutionary escape did not converge; report achieved delta
    } status = Status::CONVERGED;
    int32_t n_generations_run = 0;
    // Worst per-model delta in the winning entry. Always tracked so the
    // report can show "the worst model in the winning policy" without
    // recomputing. With the MAX metric, this equals winning_entry.joint_ppl.
    float winning_max_per_model_delta = 0.0f;
};

// --- Strict-mode result (v4 acceptance gate) ---
//
// The strict pass takes a winning policy from the standard pass
// (epsilon=0.99% by default) and re-evaluates it against the strict
// threshold (epsilon=0.25% by default). The result is either:
//   STRICT_CONVERGED: all per-model deltas < 0.25% (or whatever the
//                     strict threshold is)
//   STRICT_BEST_EFFORT: at least one per-model delta >= 0.25% (the
//                       policy is "good but not lossless")
//
// The per-model deltas in the strict result are the same measurements
// as in the standard pass (re-evaluated under the strict threshold);
// the status is the only new information.

struct ts_l5_joint_strict_result {
    ts_l5_ppl_joint_result measure;
    float max_per_model_delta;        // worst delta across all active models
    float strict_epsilon;             // 0.25% (or whatever was passed)
    enum class Status : int32_t {
        STRICT_CONVERGED  = 0,
        STRICT_BEST_EFFORT = 1,
    } status = Status::STRICT_CONVERGED;
};

// --- Forward callbacks (re-declared here so the search API is self-contained) ---

// See tessera-ppl-harness.h for the full typedefs. Re-declared as
// pointers-to-arrays here for the search-loop signature.
typedef ts_l5_drafter_forward_fn ts_l5_drafter_fns_t[TS_L5_MODEL_COUNT];

// --- Callback: called after each completed generation ---
//
// Allows the caller to persist checkpoints at gen boundaries. The search
// calls on_gen_done(generation, &gr) after pushing each generation result.
// Pass nullptr to disable (the default - no callback, no overhead).
typedef void (*ts_l5_gen_callback)(int32_t generation,
                                   const struct ts_l5_joint_gen_result * gr,
                                   void * ctx);

// --- Main search entry point ---
//
// Runs the joint search loop. Starts from the coarse grid (gen 0),
// refines top-K each generation, switches to evolutionary on slippery
// detection, terminates on AND-gate + top-K convergence.
//
// The search respects models_active[i]: inactive models skip the
// evaluation entirely (delta = 0 by construction). For v2, only the
// target is active; the search is effectively a 7D optimization over
// the target's 7-family policy.
//
// When gen_callback is non-null, it is called after each completed
// generation (before the termination check), enabling gen-boundary
// checkpointing without duplicating the generation loop.
//
// Returns 0 on success, -1 on invalid args.
int ts_l5_joint_search(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_params * params,
        ts_l5_joint_search_result * result,
        ts_l5_gen_callback gen_callback = nullptr,
        void * gen_callback_ctx = nullptr);

// --- Checkpoint-wrapped search (production: with DuckDB persistence) ---
//
// Wraps ts_l5_joint_search. At the end of each completed generation,
// serializes the gen_result to JSON and writes a checkpoint to the
// DuckDB l5_search_state table via ts_tessera_db_write_l5_gen_checkpoint.
// Requires params->run_id and params->model_hash to be set.
//
// The db pointer must be a ts_tessera_db* opened with ts_tessera_db_open.
// On db==nullptr, delegates to ts_l5_joint_search (no checkpoint).
// ts_tessera_db and ts_l5_joint_gen_checkpoint are defined in
// tools/quantize/tessera/tessera-quantize-db.h. This include is
// safe: tessera-quantize-db.h only includes standard headers and has
// no dependency on tessera-l5-joint.h.
#include "../tools/quantize/tessera/tessera-quantize-db.h"

int ts_l5_joint_search_with_checkpoint(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_params * params,
        ts_l5_joint_search_result * result,
        struct ts_tessera_db * db);

// --- Helper: compute the joint PPL metric ---
//
// Collapses the active models' per-model deltas to one scalar using
// the metric selected by params->metric (MAX by default). The metric
// drives the search's ranking, slippery detection, and convergence
// check; the AND-gate is enforced independently.
//
// Only ACTIVE models (models_active[i] = true) are counted. Inactive
// models contribute 0 by construction (their FP and quant PPL are
// equal, so their delta is 0 - but they are also skipped entirely
// for clarity).
//
// MAX (default): the worst active model drives the ranking. This
//                guarantees every active model gets full optimization
//                when it is the worst case; under SUM, the model with
//                the largest delta dominates the gradient and the
//                smaller-delta models are shaded.
// SUM:           sum of active deltas. Smooth gradient, but a single
//                model with a large delta can mask other models that
//                are above epsilon.
// MEAN:          average of active deltas. Like SUM but normalized by
//                the count of active models.
float ts_l5_joint_ppl_metric(
        const ts_l5_ppl_joint_result * measure,
        const ts_l5_joint_policy * policy,
        ts_l5_joint_metric metric);

// --- Helper: compute the worst per-model delta (always tracked) ---
//
// Returns the maximum per_model.delta across all ACTIVE models. This
// is always computed (regardless of the search metric) so the report
// can show the worst per-model delta without recomputing. Inactive
// models are skipped.
float ts_l5_joint_ppl_max_delta(
        const ts_l5_ppl_joint_result * measure,
        const ts_l5_joint_policy * policy);

// --- Helper: detect slippery surface ---
//
// Returns true if the per-generation PPL improvement is less than
// epsilon / 5. The threshold is adaptive: at epsilon=0.99% the
// threshold is 0.198% improvement per generation; at epsilon=0.25%
// (strict mode) it's 0.05% per generation. Below this, coarse-to-fine
// is wasting compute and the evolutionary escape is justified.
bool ts_l5_joint_is_slippery(
        float prev_topk_ppl,
        float curr_topk_ppl,
        float epsilon);

// --- Helper: generate gen 0 policy samples ---
//
// Samples N joint policies from the (outlier_layout, algorithm) grid,
// with alpha/clip initialized from a uniform distribution in
// [0.1, 1.0] for alpha and [0.7, 1.0] for clip. algorithm_id is
// sampled from [0, max_algorithm_id] (model-specific; for v2 the test
// uses 0 since the synthetic model has only one algorithm).
//
// The sampled policies are stored in `out_policies`. The caller is
// responsible for sizing the vector (must be at least n_samples).
void ts_l5_joint_gen0_sample(
        int32_t n_samples,
        int32_t max_algorithm_id,
        uint32_t seed,
        std::vector<ts_l5_joint_policy> * out_policies);

// --- Helper: refine top-K with continuous alpha/clip search ---
//
// For each of the top-K entries, sample a small neighborhood of
// (alpha, clip) variations and pick the best. The (outlier_layout,
// algorithm) axes are fixed (the coarse grid chose them); only
// alpha/clip vary.
//
// The neighborhood size is 8 per entry (4 alpha variations x 2 clip
// variations). The total cost is top_k * 8 evaluations per generation.
void ts_l5_joint_refine_topk(
        const std::vector<ts_l5_joint_topk_entry> & top_k,
        int32_t n_neighbors,
        uint32_t seed,
        std::vector<ts_l5_joint_policy> * out_policies);

// --- Strict-mode entry point (v4 acceptance gate) ---
//
// Re-evaluates the winning policy from the standard pass against the
// strict threshold. The winning policy's activity (which models are
// active) is preserved. The strict pass does NOT re-run the search;
// it just re-measures PPL with the strict threshold applied. This is
// the "fast path" for the acceptance gate; the slow path is a full
// re-search with the strict threshold, which is what the caller can
// do by calling ts_l5_joint_search with epsilon = 0.25% (and a
// separate search_result).
//
// Returns 0 on success, -1 on invalid args.
int ts_l5_joint_strict_pass(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_policy * winning_policy,
        float strict_epsilon,           // default 0.0025f (0.25%)
        ts_l5_joint_params * params,    // for verbose + rng_seed
        ts_l5_joint_strict_result * result);
