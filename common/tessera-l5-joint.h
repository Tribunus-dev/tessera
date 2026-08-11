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
//           top-K PPL deltas within delta_converged of each other.
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
// per-model deltas, and the joint PPL metric (sum of normalized
// per-model deltas). The search keeps the top-K entries by ascending
// joint_ppl.

struct ts_l5_joint_topk_entry {
    ts_l5_joint_policy    policy;
    ts_l5_ppl_joint_result measure;
    float                 joint_ppl;     // sum of normalized per-model deltas (active only)
};

// --- Generation result ---
//
// The result of one generation of the search: the N sampled policies,
// their measurements, and the top-K (subset).

struct ts_l5_joint_gen_result {
    int32_t generation;
    bool    and_gate_passed;             // AND-gate met this generation
    bool    converged;                   // top-K within delta_converged
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
// Returns 0 on success, -1 on invalid args.
int ts_l5_joint_search(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_params * params,
        ts_l5_joint_search_result * result);

// --- Helper: compute the joint PPL metric (sum of normalized per-model deltas) ---
//
// Only counts ACTIVE models (models_active[i] = true). Inactive models
// contribute 0 by construction. The metric is the sum, not the mean,
// so the search gradient scales with the number of active models.
float ts_l5_joint_ppl_metric(
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
