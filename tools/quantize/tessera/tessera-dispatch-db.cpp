//
// tessera-dispatch-db.cpp
//
// Pipeline refactor phase 4: DuckDB store plumbing, split out of
// tessera-dispatch.cpp. Owns struct ts_dispatch_db's lifecycle (open/close)
// and the three GA hooks that read/write it (eval_recorder,
// family_seed_lookup, layer_skip). struct ts_dispatch_db itself lives in
// tessera-dispatch-internal.h since tessera-dispatch.h forward-declares it
// for ts_dispatch_run_l5_loop's signature.
//

#include "tessera-dispatch-internal.h"
#include "tessera-dispatch.h"
#include "tessera-awq.h"

#include <cstdio>

// Open the store and begin a run. Returns a heap-allocated ts_dispatch_db
// (owned by the caller via unique_ptr) or nullptr on failure / when the path
// is empty. model_path is hashed to fingerprint this run for warm-start.
ts_dispatch_db * ts_dispatch_db_open(
    const ts_dispatch_params * params, bool verbose)
{
    if (params->tessera_db_path.empty()) {
        return nullptr;
    }
    ts_dispatch_db * wrap = new (std::nothrow) ts_dispatch_db();
    if (wrap == nullptr) return nullptr;
    std::string err;
    wrap->db = ts_tessera_db_open(params->tessera_db_path, &err);
    if (wrap->db == nullptr) {
        fprintf(stderr, "tessera-dispatch: warning: --tessera-db open '%s' "
                        "failed: %s (continuing without DB)\n",
                params->tessera_db_path.c_str(), err.c_str());
        return nullptr;
    }
    wrap->model_hash = ts_tessera_db_hash_gguf(params->input_path);
    // config_json: a compact summary of the knobs that affect GA output. This
    // is informational; warm-start keying uses model_hash only (config drift
    // across runs is acceptable for the family-seed query, which ranks by
    // best_composite rather than filtering by config).
    std::string config = "{\"evolve_iters\":" + std::to_string(params->evolve_iters)
        + ",\"evolve_islands\":" + std::to_string(params->evolve_islands)
        + ",\"evolve_population\":" + std::to_string(params->evolve_population)
        + ",\"outlier_frac\":" + std::to_string(params->outlier_frac)
        + ",\"awq_clip\":" + std::to_string(params->awq_clip)
        + ",\"awq_alpha\":\"" + params->awq_alpha + "\"}";
    wrap->run_id = ts_tessera_db_begin_run(wrap->db, params->input_path,
                                            wrap->model_hash,
                                            "tessera-dev", config, &err);
    if (wrap->run_id.empty()) {
        fprintf(stderr, "tessera-dispatch: warning: begin_run failed: %s "
                        "(continuing without DB)\n", err.c_str());
        return nullptr;
    }
    // Resume: pull the list of tensors that already converged for this
    // model_hash in prior runs (or this run, if it crashed mid-way). We look
    // across all runs of the same model so a re-launch after a crash
    // continues from the last checkpoint. force_requantize skips this.
    if (!params->force_requantize && !wrap->model_hash.empty()) {
        // Find any run_id for this model_hash with completed tensors. Goes
        // through the public list_converged_for_model helper so the dispatch
        // does not reach into the duckdb::Connection (which would require
        // pulling duckdb.hpp into every translation unit that includes the
        // dispatch).
        std::vector<std::string> done;
        if (ts_tessera_db_list_converged_for_model(wrap->db,
                                                    wrap->model_hash,
                                                    &done) == 0) {
            wrap->converged.insert(done.begin(), done.end());
        }
    }
    // GA-prep warm-start: pre-load l5_weights for this model. The
    // family_seed_lookup hook consults this map first; entries
    // here bias the GA's (alpha, clip) initial population per
    // family based on the orchestrator's retune. Empty when
    // --tessera-db is unset, when force_requantize is set, or when
    // the model has no l5_weights rows yet (first run).
    if (!params->force_requantize && !wrap->model_hash.empty()) {
        ts_tessera_db_l5_weight_list l5_list;
        if (ts_tessera_db_list_l5_weights(wrap->db, wrap->model_hash, "",
                                           &l5_list) == 0) {
            for (auto & e : l5_list.entries) {
                wrap->l5_weight_map[e.family] = std::move(e);
            }
            if (verbose && !wrap->l5_weight_map.empty()) {
                printf("tessera-dispatch: --tessera-db loaded %zu "
                       "l5_weight entries (families: ",
                       wrap->l5_weight_map.size());
                bool first = true;
                for (const auto & kv : wrap->l5_weight_map) {
                    printf("%s%s(%.3f)", first ? "" : ", ",
                           kv.first.c_str(), kv.second.hit_rate);
                    first = false;
                }
                printf(")\n");
            }
        }
    }
    // Tier 2 regime thresholds: pre-load learned kurtosis/eff_rank cutoffs per
    // family. The dispatch's ts_regime_classify calls look up thresholds from
    // this map and pass them to ts_regime_classify so the regime cascade uses
    // learned priors instead of static defaults. Empty when --tessera-db is
    // unset or when no regime_thresholds rows exist for this model yet (the
    // first run always uses the static cascade; subsequent runs benefit once
    // the Tier 4 OLS fitter has produced priors).
    if (!wrap->model_hash.empty()) {
        ts_tessera_db_regime_threshold_list rt_list;
        if (ts_tessera_db_list_regime_thresholds(wrap->db, wrap->model_hash,
                                                  "trunk", "", &rt_list) == 0) {
            for (auto & e : rt_list.entries) {
                // Only use priors with meaningful fit quality (r2 > 0.05 = not noise)
                if (e.r2_score < 0.05f || e.n_samples < 8) continue;
                ts_regime_family_thresholds t;
                t.model_hash  = e.model_hash;
                t.model_role  = e.model_role;
                t.family      = e.family;
                t.kurt_heavy  = e.kurt_heavy;
                t.kurt_light  = e.kurt_light;
                t.er_compact  = e.er_compact;
                t.er_sparse   = e.er_sparse;
                t.n_samples   = e.n_samples;
                t.valid       = true;
                wrap->regime_threshold_map[e.family] = std::move(t);
            }
            if (verbose && !wrap->regime_threshold_map.empty()) {
                printf("tessera-dispatch: regime thresholds loaded for %zu families: ",
                       wrap->regime_threshold_map.size());
                bool first = true;
                for (const auto & kv : wrap->regime_threshold_map) {
                    printf("%s%s(kurt_heavy=%.1f,n=%d)",
                           first ? "" : ", ", kv.first.c_str(),
                           kv.second.kurt_heavy, kv.second.n_samples);
                    first = false;
                }
                printf("\n");
            }
        }
    }
    if (verbose) {
        printf("tessera-dispatch: --tessera-db opened '%s' (run_id=%s, "
               "model_hash=%s, %zu converged tensors)\n",
               params->tessera_db_path.c_str(), wrap->run_id.c_str(),
               wrap->model_hash.empty() ? "(hash failed)" : wrap->model_hash.c_str(),
               wrap->converged.size());
    }
    // Open the per-table write buffer for ga_evaluations. 65536-row
    // batches match the evidence-store row_group_size convention; 1
    // second time flush keeps the table visible in DuckDB without
    // flooding on small writes. Best-effort: if the buffer fails to
    // open (allocation, invalid arg), the dispatch runs without DB
    // eval logging but keeps the run_lifecycle / warm-start / resume
    // path alive. That matches the existing --quantize-db failure
    // mode (warn-and-continue).
    {
        std::vector<std::string> ga_cols = {
            "run_id", "tensor_name", "generation", "island", "candidate_idx",
            "alpha", "clip", "composite", "mse", "relative_frob", "evaluated_at",
        };
        // Schema-owner check (phase 2): converts a future l4_cols-class
        // drift on THIS table into a loud, specific failure instead of a
        // silent one (see the l4_plan_outcome block below for the
        // historical incident this class of bug caused).
        std::string mismatch;
        if (!ts_tessera_db_check_buffer_columns(wrap->db, "ga_evaluations", ga_cols, &mismatch)) {
            fprintf(stderr, "tessera-dispatch: ERROR: %s -- refusing to open the "
                            "ga_evaluations buffer (eval logging disabled; "
                            "run_lifecycle still works)\n", mismatch.c_str());
        } else {
            wrap->eval_buffer = ts_db_buffer_open(
                wrap->db, "ga_evaluations", ga_cols,
                /*flush_threshold=*/65536,
                std::chrono::milliseconds(1000));
            if (wrap->eval_buffer == nullptr) {
                fprintf(stderr, "tessera-dispatch: warning: eval buffer open failed "
                                "(eval logging disabled; run_lifecycle still works)\n");
            }
        }
    }
    // Open the l4_plan_outcome buffer (the L5 feedback loop). Same
    // shape as the eval buffer but with a smaller threshold (1024
    // rows): the L5 loop writes at most one row per (tensor, gen),
    // and max_generations is typically 3-5 with ~100 flagged tensors
    // per gen, so the total is ~1500 rows. A 1-second time flush
    // keeps the outcome visible to the Python l5_outcome.py consumer
    // while the dispatch is still running (the Python side can read
    // the partial table mid-dispatch if needed).
    {
        // Column list MUST match both the l4_plan_outcome CREATE TABLE and
        // the 19 values ts_tessera_db_append_l4_outcome pushes, in order.
        // Phase 16 added model_role to the struct, the append helper, and
        // the table -- but not here: every flush became INSERT(18 cols)
        // VALUES(19 values) and failed, silently dropping the ENTIRE L5
        // feedback record of the run (observed: 90/90 rows dropped on the
        // first default-on Orpheus pass, l4_plan_outcome left empty).
        std::vector<std::string> l4_cols = {
            "model_hash", "model_role", "name", "layer", "iteration",
            "plan_id", "strategy",
            "alpha_before", "alpha_after", "clip_before", "clip_after",
            "outlier_thresh_before", "outlier_thresh_after",
            "mse_before", "mse_after", "frob_before", "frob_after",
            "family", "updated_at",
        };
        // Schema-owner check (phase 2): this is exactly the historical
        // incident above, made structurally impossible to repeat silently
        // -- a future drift between this list and the live table refuses
        // to open the buffer with a specific diagnosis instead of flushing
        // INSERT(N cols) VALUES(N+1 values) into silence.
        std::string mismatch;
        if (!ts_tessera_db_check_buffer_columns(wrap->db, "l4_plan_outcome", l4_cols, &mismatch)) {
            fprintf(stderr, "tessera-dispatch: ERROR: %s -- refusing to open the "
                            "l4_plan_outcome buffer (feedback loop disabled; "
                            "run_lifecycle still works)\n", mismatch.c_str());
        } else {
            wrap->l4_outcome_buffer = ts_db_buffer_open(
                wrap->db, "l4_plan_outcome", l4_cols,
                /*flush_threshold=*/1024,
                std::chrono::milliseconds(1000));
            if (wrap->l4_outcome_buffer == nullptr) {
                fprintf(stderr, "tessera-dispatch: warning: l4_outcome buffer open failed "
                                "(feedback loop disabled; run_lifecycle still works)\n");
            }
        }
    }
    return wrap;
}

// Finalize: mark the run complete (or failed) and close any appenders left
// open by an early-return path. Called from the unique_ptr deleter so every
// exit from ts_dispatch_run cleans up.
void ts_dispatch_db_close(ts_dispatch_db * wrap, const char * status) {
    if (wrap == nullptr || wrap->db == nullptr) return;
    if (!wrap->run_id.empty()) {
        std::string err;
        if (ts_tessera_db_complete_run(wrap->db, wrap->run_id, status, &err) != 0
            && !err.empty()) {
            fprintf(stderr, "tessera-dispatch: warning: complete_run(%s) "
                            "failed: %s\n", status, err.c_str());
        }
    }
    // Close the GA-eval buffer. ts_db_buffer_close drains the pending
    // queue (sync-on-exit) and nulls the handle, so a subsequent
    // eval_recorder call (e.g. an early-return path) is a no-op.
    if (wrap->eval_buffer != nullptr) {
        ts_db_buffer_stats s = ts_db_buffer_stats_get(wrap->eval_buffer);
        ts_db_buffer_close(&wrap->eval_buffer);
        if (s.rows_dropped > 0) {
            fprintf(stderr, "tessera-dispatch: warning: %llu GA eval rows dropped "
                            "(DB buffer flush failures)\n",
                    (unsigned long long)s.rows_dropped);
        }
    }
    // Close the L4-outcome buffer. Same sync-on-exit contract; the
    // L5 feedback loop's per-iteration rows land before the run is
    // marked complete.
    if (wrap->l4_outcome_buffer != nullptr) {
        ts_db_buffer_stats s = ts_db_buffer_stats_get(wrap->l4_outcome_buffer);
        ts_db_buffer_close(&wrap->l4_outcome_buffer);
        if (s.rows_dropped > 0) {
            fprintf(stderr, "tessera-dispatch: warning: %llu L4 outcome rows dropped "
                            "(DB buffer flush failures)\n",
                    (unsigned long long)s.rows_dropped);
        }
    }
    delete wrap->db;
    wrap->db = nullptr;
}

// Per-evaluation callback: formats one row and pushes it into the
// shared ga_evaluations buffer. The buffer's MPSC queue serializes the
// SQL writes on a single flusher thread, so this callback is hot-path
// cheap: a vector copy under the buffer's mutex + maybe a cv signal.
// DuckDB never sees the GA worker threads directly.
void ts_dispatch_eval_recorder(const ts_awq_layer * layer,
                               int32_t generation, int32_t island,
                               int32_t candidate_idx,
                               const ts_awq_candidate * cand,
                               const ts_awq_score    * score,
                               void * user) {
    auto * wrap = static_cast<ts_dispatch_db *>(user);
    if (wrap == nullptr || wrap->db == nullptr || wrap->eval_buffer == nullptr
        || layer == nullptr) {
        return;
    }
    // Format the row. Numeric columns are emitted without quotes (the
    // buffer's looks_like_int / looks_like_float pass-through skips the
    // quote path); text columns are pre-escaped via sql_escape. NULL
    // is the special token the buffer recognizes. The order matches
    // the ga_evaluations CREATE TABLE column list.
    const float alpha         = cand  ? cand->genes.alpha      : 0.0f;
    const float clip          = cand  ? cand->genes.clip       : 0.0f;
    const float composite     = score ? score->composite      : 0.0f;
    const float mse           = score ? score->mse            : 0.0f;
    const float relative_frob = score ? score->relative_frob  : 0.0f;

    std::vector<std::string> row = {
        ts_db_sql_escape(wrap->run_id),
        ts_db_sql_escape(layer->name),
        std::to_string(generation),
        std::to_string(island),
        std::to_string(candidate_idx),
        std::to_string(alpha),
        std::to_string(clip),
        std::to_string(composite),
        std::to_string(mse),
        std::to_string(relative_frob),
        "NULL",   // evaluated_at: left NULL per row, like the Appender path
    };
    ts_db_buffer_append(wrap->eval_buffer, row);
}

// Look up a family warm-start seed in the persistent store. Used as the
// family_seed_lookup hook so the first layer of each family can warm-start
// from prior runs when the in-memory cache is empty.
//
// The dispatch consults two stores in order of preference:
//   1. l5_weights (the orchestrator's per-(model, family) retune). This is
//      the "did this plan reduce error?" feedback loop's consumer; the
//      retune is the more recent + scored signal, so the dispatch uses it
//      as the primary warm-start source when the family has a row. The
//      seed is biased by hit_rate: families with hit_rate > 0.5 get
//      alpha 25% higher and clip 20% higher than the 0.5/0.7 base
//      (the orchestrator's verdict that this family has headroom).
//   2. ga_results (the legacy per-run GA result). The first layer of
//      each family that did NOT show up in l5_weights falls back to
//      the best-known (alpha, clip) from any prior run. This keeps
//      cold-start models (no l5_weights yet) and orphan families
//      (e.g. routed experts) on the existing warm-start path.
bool ts_dispatch_family_seed_lookup(const char * family,
                                    ts_awq_candidate * out,
                                    float * out_composite,
                                    void * user) {
    auto * wrap = static_cast<ts_dispatch_db *>(user);
    if (wrap == nullptr || wrap->db == nullptr || family == nullptr ||
        out == nullptr) {
        return false;
    }
    // 1. Try l5_weights first (pre-loaded at ts_dispatch_db_open).
    auto l5_it = wrap->l5_weight_map.find(family);
    if (l5_it != wrap->l5_weight_map.end()) {
        const auto & rec = l5_it->second;
        // Bias rule from the design: hit_rate > 0.5 -> alpha/clip
        // get a hit_rate-weighted bump; otherwise the base. The base
        // is the existing 0.5 / 0.7 center of the GA's [lo,hi] box;
        // hit_rate=1.0 -> alpha=0.75, clip=0.9 (a tight, aggressive
        // seed for a well-characterized family).
        const float base_alpha = 0.5f;
        const float base_clip  = 0.7f;
        const float center_alpha = (rec.hit_rate > 0.5f)
            ? base_alpha + 0.25f * rec.hit_rate
            : base_alpha;
        const float center_clip  = (rec.hit_rate > 0.5f)
            ? base_clip  + 0.20f * rec.hit_rate
            : base_clip;
        out->genes.alpha = center_alpha;
        out->genes.clip  = center_clip;
        out->expert_hint = -1;
        // hit_rate is the best-effort "composite" signal we have for
        // the l5_weight seed; the GA uses out_composite to weight the
        // seed in the initial population.
        if (out_composite) *out_composite = (float) rec.hit_rate;
        return true;
    }
    // 2. Fall back to the legacy ga_results-based seed.
    ts_tessera_db_family_seed seed;
    if (!ts_tessera_db_lookup_family_seed(wrap->db, family, wrap->run_id,
                                           &seed)) {
        return false;
    }
    out->genes.alpha = seed.best_alpha;
    out->genes.clip  = seed.best_clip;
    out->expert_hint = -1;
    if (out_composite) *out_composite = seed.best_composite;
    return true;
}

// Resume hook: short-circuit the GA for tensors that already converged for
// this model in a prior run. Reconstructs a minimal result from the stored
// ga_results row so the downstream per-tensor quantize step still has alpha.
bool ts_dispatch_layer_skip(const ts_awq_layer * layer,
                            ts_awq_evolve_result * out_result,
                            void * user) {
    auto * wrap = static_cast<ts_dispatch_db *>(user);
    if (wrap == nullptr || wrap->db == nullptr || layer == nullptr ||
        out_result == nullptr) {
        return false;
    }
    if (wrap->converged.find(layer->name) == wrap->converged.end()) {
        return false;
    }
    // Look up by model_hash across all runs of this model (the resume set
    // was built cross-run, so the matching ga_result row usually lives
    // under a different run_id than this one).
    ts_tessera_db_ga_result gr;
    if (!ts_tessera_db_load_ga_result_for_model(wrap->db, wrap->model_hash,
                                                 layer->name, &gr)) {
        return false;
    }
    out_result->best.genes.alpha = gr.best_alpha;
    out_result->best.genes.clip  = gr.best_clip;
    out_result->best.expert_hint = -1;
    out_result->best_score.composite     = gr.best_composite;
    out_result->best_score.mse           = gr.best_mse;
    out_result->best_score.relative_frob = gr.best_mse;
    out_result->best_score.heldout_mse   = gr.best_mse;
    out_result->generations_run = 0;
    out_result->evaluations     = 0;
    out_result->converged       = true;
    out_result->warm_started    = true;   // resume == strongest warm-start
    return true;
}
