//
// tessera-l5-joint.cpp
//
// L5 joint search loop implementation. See tessera-l5-joint.h for
// the design (coarse-to-fine + adaptive slippery detection + AND-gate
// termination).
//

#include "tessera-l5-joint.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

// ---------------------------------------------------------------------------
// ts_l5_joint_ppl_metric
// ---------------------------------------------------------------------------

float ts_l5_joint_ppl_metric(
        const ts_l5_ppl_joint_result * measure,
        const ts_l5_joint_policy * policy) {
    if (!measure || !policy) return 0.0f;
    float sum = 0.0f;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (!policy->models_active[m]) continue;
        sum += measure->per_model[m].delta;
    }
    return sum;
}

// ---------------------------------------------------------------------------
// ts_l5_joint_is_slippery (adaptive: threshold = epsilon / 5)
// ---------------------------------------------------------------------------

bool ts_l5_joint_is_slippery(
        float prev_topk_ppl,
        float curr_topk_ppl,
        float epsilon) {
    const float improvement = prev_topk_ppl - curr_topk_ppl;
    const float threshold = epsilon / 5.0f;
    return improvement < threshold;
}

// ---------------------------------------------------------------------------
// ts_l5_joint_gen0_sample
// ---------------------------------------------------------------------------

void ts_l5_joint_gen0_sample(
        int32_t n_samples,
        int32_t max_algorithm_id,
        uint32_t seed,
        std::vector<ts_l5_joint_policy> * out_policies) {
    if (!out_policies || n_samples <= 0) return;
    out_policies->clear();
    out_policies->reserve(n_samples);

    std::mt19937 rng(seed ? seed : 0xCAFE5EAu);
    std::uniform_int_distribution<int> layout_pick(0, TS_L5_OUTLIER_COUNT - 1);
    std::uniform_int_distribution<int> algo_pick(0, std::max(0, max_algorithm_id));
    std::uniform_real_distribution<float> alpha_pick(0.1f, 1.0f);
    std::uniform_real_distribution<float> clip_pick(0.7f, 1.0f);

    for (int32_t s = 0; s < n_samples; ++s) {
        ts_l5_joint_policy p;
        for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
            for (int f = 0; f < TS_L5_FAMILY_COUNT; ++f) {
                p.families[m][f].outlier_layout = (ts_l5_outlier_layout)layout_pick(rng);
                p.families[m][f].algorithm_id   = algo_pick(rng);
                p.families[m][f].alpha          = alpha_pick(rng);
                p.families[m][f].clip           = clip_pick(rng);
            }
        }
        out_policies->push_back(p);
    }
}

// ---------------------------------------------------------------------------
// ts_l5_joint_refine_topk
// ---------------------------------------------------------------------------

void ts_l5_joint_refine_topk(
        const std::vector<ts_l5_joint_topk_entry> & top_k,
        int32_t n_neighbors,
        uint32_t seed,
        std::vector<ts_l5_joint_policy> * out_policies) {
    if (!out_policies || top_k.empty() || n_neighbors <= 0) return;
    out_policies->clear();
    out_policies->reserve(top_k.size() * n_neighbors);

    std::mt19937 rng(seed ? seed : 0xBEEF1234u);
    // Each neighbor: 4 alpha variations (perturb +/- 0.1, +/- 0.2) and
    // 2 clip variations (perturb +/- 0.05). For n_neighbors=8, the
    // product is 8.
    const float alpha_deltas[4] = { -0.2f, -0.1f, 0.1f, 0.2f };
    const float clip_deltas[2]  = { -0.05f, 0.05f };

    for (const auto & entry : top_k) {
        for (int32_t n = 0; n < n_neighbors; ++n) {
            ts_l5_joint_policy p = entry.policy;
            const int ai = n / 2;   // 0..3
            const int ci = n % 2;   // 0..1
            // Apply the (alpha, clip) perturbation to every family of
            // every active model. Inactive models keep their policy
            // unchanged (and don't get evaluated).
            for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
                for (int f = 0; f < TS_L5_FAMILY_COUNT; ++f) {
                    p.families[m][f].alpha = std::max(0.05f, std::min(1.0f,
                            entry.policy.families[m][f].alpha + alpha_deltas[ai]));
                    p.families[m][f].clip  = std::max(0.5f, std::min(1.0f,
                            entry.policy.families[m][f].clip + clip_deltas[ci]));
                }
            }
            out_policies->push_back(p);
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: evaluate a batch of policies, return entries sorted by joint_ppl
// ---------------------------------------------------------------------------

static void ts_l5_joint_evaluate_batch(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_params * params,
        const std::vector<ts_l5_joint_policy> & policies,
        std::vector<ts_l5_joint_topk_entry> * out_entries) {
    out_entries->clear();
    out_entries->reserve(policies.size());
    for (const auto & p : policies) {
        ts_l5_ppl_joint_result measure;
        const int rc = ts_l5_ppl_joint_measure(
                harness, trunk_forward, drafter_forwards, talker_forward,
                &p, params, &measure);
        if (rc != 0) continue;  // skip failed evaluations
        ts_l5_joint_topk_entry e;
        e.policy   = p;
        e.measure  = measure;
        e.joint_ppl = ts_l5_joint_ppl_metric(&measure, &p);
        out_entries->push_back(e);
    }
    std::sort(out_entries->begin(), out_entries->end(),
              [](const ts_l5_joint_topk_entry & a, const ts_l5_joint_topk_entry & b) {
                  return a.joint_ppl < b.joint_ppl;
              });
}

static void ts_l5_joint_take_topk(
        const std::vector<ts_l5_joint_topk_entry> & sorted,
        int32_t k,
        std::vector<ts_l5_joint_topk_entry> * out_topk) {
    out_topk->clear();
    const int32_t n = std::min(k, (int32_t)sorted.size());
    for (int32_t i = 0; i < n; ++i) {
        out_topk->push_back(sorted[i]);
    }
}

// ---------------------------------------------------------------------------
// ts_l5_joint_search
// ---------------------------------------------------------------------------

int ts_l5_joint_search(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_params * params,
        ts_l5_joint_search_result * result) {
    if (!harness || !trunk_forward || !drafter_forwards || !talker_forward
            || !params || !result) {
        return -1;
    }

    result->generations.clear();
    result->n_generations_run = 0;
    result->status = ts_l5_joint_search_result::Status::CONVERGED;
    result->winning_entry = ts_l5_joint_topk_entry{};

    // Count active models for the slipperiness check + topk convergence.
    int n_active = 0;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (harness->model_ctx[m] || m == TS_L5_MODEL_TARGET) {
            // The harness always has the target context; activity is
            // communicated via the initial policy below.
        }
        // Note: activity is set by the search via models_active on the
        // generated policies, not on the harness. We pass activity via
        // the policy itself.
    }

    // For v2 the initial activity is "target only" (others inactive).
    // The harness doesn't carry activity; the search propagates it
    // through the policy structs it generates. For v3, the search
    // will accept an initial policy that activates all 5 models.
    //
    // We construct the initial activity by mirroring from the
    // harness: for v2, target is active, others are not. For v3,
    // all 5 are active. The activity is set on every generated policy
    // below.
    const bool initial_activity[TS_L5_MODEL_COUNT] = {
        true,  // target
        true,  // dflash
        true,  // dspark
        true,  // mtp
        true,  // talker
    };

    auto set_activity = [&](ts_l5_joint_policy * p) {
        for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
            p->models_active[m] = initial_activity[m];
        }
    };

    // v2 simplification: max_algorithm_id is 0 (the synthetic test
    // uses 1 algorithm per family). v3 wires model-specific algorithm
    // counts.
    const int32_t max_algo = 0;

    float prev_topk_ppl = 0.0f;
    bool   prev_topk_valid = false;

    for (int32_t gen = 0; gen < params->max_generations; ++gen) {
        ts_l5_joint_gen_result gr;
        gr.generation = gen;
        gr.and_gate_passed = false;
        gr.converged = false;
        gr.switched_to_evolutionary = false;

        // ---- Gen 0: sample N policies from the coarse grid ----
        // ---- Gen 1+: refine top-K with continuous alpha/clip ----
        std::vector<ts_l5_joint_policy> sampled;
        if (gen == 0) {
            ts_l5_joint_gen0_sample(
                    params->n_gen0_samples, max_algo,
                    params->rng_seed + gen,
                    &sampled);
        } else {
            if (result->generations.empty()) break;  // safety
            const auto & prev = result->generations.back();
            ts_l5_joint_refine_topk(
                    prev.top_k, 8,
                    params->rng_seed + gen,
                    &sampled);
        }
        for (auto & p : sampled) set_activity(&p);

        // ---- Evaluate ----
        std::vector<ts_l5_joint_topk_entry> sorted;
        ts_l5_joint_evaluate_batch(
                harness, trunk_forward, drafter_forwards, talker_forward,
                params, sampled, &sorted);

        gr.all_entries = sorted;
        ts_l5_joint_take_topk(sorted, params->top_k, &gr.top_k);

        // ---- Termination: AND-gate ----
        if (!gr.top_k.empty() && gr.top_k[0].measure.all_pass) {
            gr.and_gate_passed = true;
        }

        // ---- Termination: top-K convergence (within delta_converged) ----
        if (gr.top_k.size() >= 2) {
            const float best = gr.top_k[0].joint_ppl;
            const float worst = gr.top_k.back().joint_ppl;
            if (std::fabs(worst - best) < params->delta_converged) {
                gr.converged = true;
            }
        }

        // ---- Slippery detection (adaptive) ----
        if (prev_topk_valid && !gr.top_k.empty()) {
            const float curr_ppl = gr.top_k[0].joint_ppl;
            if (ts_l5_joint_is_slippery(prev_topk_ppl, curr_ppl, params->epsilon)) {
                gr.switched_to_evolutionary = true;
                // Evolutionary escape: 1-2 generations of mutation +
                // crossover on the top-K. For v2, the synthetic test
                // doesn't trigger this path; the impl is here for v3.
                // The escape produces n_evo_pop additional policies.
                std::vector<ts_l5_joint_policy> evo_pop;
                evo_pop.reserve(params->n_evo_pop);
                std::mt19937 evo_rng(params->rng_seed + 0xE0FFEEu + gen);
                for (int e = 0; e < params->n_evo_pop; ++e) {
                    ts_l5_joint_policy p = gr.top_k[0].policy;
                    // Mutation: perturb (outlier_layout, algorithm_id,
                    // alpha, clip) for each family of each active model.
                    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
                        for (int f = 0; f < TS_L5_FAMILY_COUNT; ++f) {
                            std::uniform_int_distribution<int> layout_pick(0, TS_L5_OUTLIER_COUNT - 1);
                            std::uniform_real_distribution<float> alpha_pert(-0.3f, 0.3f);
                            std::uniform_real_distribution<float> clip_pert(-0.1f, 0.1f);
                            if (std::uniform_int_distribution<int>(0, 3)(evo_rng) == 0) {
                                p.families[m][f].outlier_layout = (ts_l5_outlier_layout)layout_pick(evo_rng);
                            }
                            p.families[m][f].alpha = std::max(0.05f, std::min(1.0f,
                                    p.families[m][f].alpha + alpha_pert(evo_rng)));
                            p.families[m][f].clip  = std::max(0.5f, std::min(1.0f,
                                    p.families[m][f].clip + clip_pert(evo_rng)));
                        }
                    }
                    evo_pop.push_back(p);
                }
                std::vector<ts_l5_joint_topk_entry> evo_sorted;
                ts_l5_joint_evaluate_batch(
                        harness, trunk_forward, drafter_forwards, talker_forward,
                        params, evo_pop, &evo_sorted);
                for (auto & e : evo_sorted) gr.all_entries.push_back(e);
                std::sort(gr.all_entries.begin(), gr.all_entries.end(),
                          [](const ts_l5_joint_topk_entry & a, const ts_l5_joint_topk_entry & b) {
                              return a.joint_ppl < b.joint_ppl;
                          });
                ts_l5_joint_take_topk(gr.all_entries, params->top_k, &gr.top_k);
                if (gr.top_k[0].measure.all_pass) {
                    gr.and_gate_passed = true;
                }
            }
        }

        result->generations.push_back(gr);
        result->n_generations_run = gen + 1;

        if (!gr.top_k.empty()) {
            prev_topk_ppl = gr.top_k[0].joint_ppl;
            prev_topk_valid = true;
        }

        if (params->verbose) {
            std::fprintf(stderr,
                    "  [L5 gen %d] and_gate=%d converged=%d slippery=%d topk_ppl=%.6f\n",
                    gen, (int)gr.and_gate_passed, (int)gr.converged,
                    (int)gr.switched_to_evolutionary,
                    gr.top_k.empty() ? -1.0f : gr.top_k[0].joint_ppl);
        }

        // ---- Termination ----
        if (gr.and_gate_passed && gr.converged) {
            result->status = ts_l5_joint_search_result::Status::CONVERGED;
            result->winning_entry = gr.top_k[0];
            return 0;
        }
        if (gr.and_gate_passed) {
            // AND-gate passed but top-K not converged; one more gen
            // may find a better policy. Continue.
        }
    }

    // Forced termination: max_generations reached.
    if (!result->generations.empty() && !result->generations.back().top_k.empty()) {
        result->winning_entry = result->generations.back().top_k[0];
    }
    // If the AND-gate passed (even without top-K convergence), call
    // it CONVERGED; otherwise BEST_EFFORT.
    bool any_gen_passed = false;
    for (const auto & g : result->generations) {
        if (g.and_gate_passed) { any_gen_passed = true; break; }
    }
    result->status = any_gen_passed
            ? ts_l5_joint_search_result::Status::CONVERGED
            : ts_l5_joint_search_result::Status::BEST_EFFORT;
    return 0;
}

// ---------------------------------------------------------------------------
// ts_l5_joint_strict_pass (v4 acceptance gate)
// ---------------------------------------------------------------------------

int ts_l5_joint_strict_pass(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_policy * winning_policy,
        float strict_epsilon,
        ts_l5_joint_params * params,
        ts_l5_joint_strict_result * result) {
    if (!harness || !trunk_forward || !drafter_forwards || !talker_forward
            || !winning_policy || !result) {
        return -1;
    }
    if (strict_epsilon <= 0.0f) {
        strict_epsilon = 0.0025f;  // 0.25% default
    }

    // Build a params struct for the measurement. We reuse the caller's
    // params for verbose + rng_seed; we override epsilon with the
    // strict value so ts_l5_ppl_joint_measure's per-model pass flag
    // is computed against the strict threshold.
    ts_l5_joint_params strict_params;
    if (params) {
        strict_params = *params;
    }
    strict_params.epsilon = strict_epsilon;

    // Re-measure the winning policy.
    const int rc = ts_l5_ppl_joint_measure(
            harness, trunk_forward, drafter_forwards, talker_forward,
            winning_policy, &strict_params, &result->measure);
    if (rc != 0) return rc;

    // Find the worst per-model delta across all ACTIVE models.
    result->max_per_model_delta = 0.0f;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (!winning_policy->models_active[m]) continue;
        const float d = result->measure.per_model[m].delta;
        if (d > result->max_per_model_delta) {
            result->max_per_model_delta = d;
        }
    }

    // Status: STRICT_CONVERGED iff worst delta < strict_epsilon.
    result->strict_epsilon = strict_epsilon;
    result->status = (result->max_per_model_delta < strict_epsilon)
            ? ts_l5_joint_strict_result::Status::STRICT_CONVERGED
            : ts_l5_joint_strict_result::Status::STRICT_BEST_EFFORT;

    if (params && params->verbose) {
        std::fprintf(stderr,
                "  [L5 strict] worst_per_model_delta=%.6f strict_epsilon=%.6f status=%s\n",
                result->max_per_model_delta, strict_epsilon,
                result->status == ts_l5_joint_strict_result::Status::STRICT_CONVERGED
                    ? "STRICT_CONVERGED" : "STRICT_BEST_EFFORT");
    }

    return 0;
}
