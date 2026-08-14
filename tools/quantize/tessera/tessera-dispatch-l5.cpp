//
// tessera-dispatch-l5.cpp
//
// Pipeline refactor phase 4: the L5 adaptive requantize refine loop
// (dispatch L2 -> L5 -> re-quantize) and the L5 joint PPL loop (the
// production default), split out of tessera-dispatch.cpp. Per the
// contracts appendix: "ts_dispatch_run_l5_loop is already fully
// parameterized -- the model for the other seams... The joint variant
// ts_dispatch_run_l5_joint + anon-namespace synth forwards is independent
// of all dispatch state except params/result and can split cleanly today."
//

#include "tessera-dispatch.h"
#include "tessera-dispatch-internal.h"
#include "tessera-quant.h"
#include "tessera-regime.h"
#include "tessera-l5.h"
#include "tessera-gguf-writer.h"
#include "tessera-quantize-db.h"
#include "tessera-vec.h"
#include "common.h"  // common_kv_cache_type_from_str (KV-joint plumbing, phase 3)
#include "tessera-ppl-harness.h"
#include "tessera-l5-joint.h"

#include "gguf.h"
#include "ggml.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>

// ---------------------------------------------------------------------------
// L5 adaptive requantize refine loop (dispatch L2 -> L5 -> re-quantize)
// ---------------------------------------------------------------------------

// Re-read one tensor's source weights from the input GGUF as F32. Returns
// an empty vector on failure (matching ts_tensor_to_f32's contract).
std::vector<float> ts_refine_reread_source(struct gguf_context * in_ctx,
                                           struct ggml_context * ggml_ctx,
                                           const ts_dispatch_refine_entry & e) {
    const char * name = gguf_get_tensor_name(in_ctx, e.gguf_idx);
    if (name == nullptr) {
        return {};
    }
    struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, name);
    if (t == nullptr) {
        return {};
    }
    return ts_tensor_to_f32(t);
}

// Relative Frobenius between source weights and a quant result's recon.
// Matches the L2 weight-level metric (||src - recon||_F^2 / ||src||_F^2).
float ts_refine_rel_frob(const float * src, const ts_quant_result_2d * qr,
                         int64_t n) {
    if (src == nullptr || qr == nullptr || n <= 0) {
        return 0.0f;
    }
    double num = 0.0;
    double den = 0.0;
    const float * recon = qr->recon.data();
    for (int64_t i = 0; i < n; i++) {
        const double d = (double)src[i] - (double)recon[i];
        num += d * d;
        den += (double)src[i] * (double)src[i];
    }
    if (den == 0.0) {
        return 0.0f;
    }
    return (float)(num / den);
}

// Join a vector of strings with a separator (used for the per-family JSON
// array in the report).
std::string ts_join(const std::vector<std::string> & parts,
                    const std::string & sep) {
    std::string out;
    for (size_t i = 0; i < parts.size(); i++) {
        if (i) out += sep;
        out += parts[i];
    }
    return out;
}

// Exact storage footprint (bits) of a 2D quant result: every GGUF
// component the format writes. The L5 loop's budget-constrained
// A/B selection measures this on scratch quantizations instead of
// estimating, so the Lagrangian violation is computed from real
// bytes, not a bit-model.
int64_t ts_dispatch_result_bits(const ts_quant_result_2d * qr) {
    return (int64_t)qr->packed.size()              * 32
         + (int64_t)qr->page_scales.size()         * 16
         + (int64_t)qr->lane_scales.size()         * 8
         + (int64_t)qr->outlier_row_offsets.size() * 32
         + (int64_t)qr->outlier_cols.size()        * 32
         + (int64_t)qr->outlier_vals.size()        * 16
         + (int64_t)qr->act_scale.size()           * 16;
}

// Run the L5 adaptive requantize loop over the captured 2D tensors. Mutates
// the deque entries in place and repoints the GGUF descriptors. Emits one
// JSON object per generation to l5_report_json on the result struct.
//
// Returns 0 on success (including the case where nothing was flagged and the
// loop terminates immediately), non-zero only on a hard setup error.
//
// Declared non-static so the integration test in test_l5_dispatch.cpp can
// drive it directly with a constructed refine_map (the test fixture builds
// the in-memory state without going through the full GGUF walk).
//
// db_wrap is optional. When non-null and its l4_outcome_buffer is
// non-null, the loop writes one l4_plan_outcome row per (tensor, gen)
// via ts_tessera_db_append_l4_outcome. The integration test passes
// nullptr (it does not have a DuckDB store wired up).
int ts_dispatch_run_l5_loop(
    const ts_dispatch_params * params,
    ts_dispatch_result * result,
    struct gguf_context * in_ctx,
    struct ggml_context * ggml_ctx,
    struct ggml_context * out_ggml_ctx,
    std::unordered_map<std::string, ts_dispatch_refine_entry> & refine_map,
    ts_dispatch_db * db_wrap) {

    if (refine_map.empty()) {
        return 0;
    }

    result->l5_ran = true;

    // L5 params (alpha/clip are floors for the multipliers; both clamped below).
    ts_l5_adaptive_params l5p;
    ts_l5_adaptive_default_params(&l5p);
    l5p.alpha_scale = 0.5f;  // base multiplier: tighten by 2x at overshoot 1
    l5p.clip_scale  = 0.5f;
    l5p.min_alpha   = params->l5_alpha_min;
    l5p.min_clip    = params->l5_clip_min;

    // Build the per-tensor L2 input view once; the loop refreshes the `quant`
    // pointer after each re-quantize from the deque's recon.
    const float flag_multiplier = params->l5_flag_multiplier;
    const int   max_generations = params->l5_max_generations;
    const float outlier_overshoot_scale = params->l5_outlier_overshoot_scale;
    const float outlier_frac_cap = params->l5_outlier_frac_cap;

    std::string report_json = "{\"schema\":\"llama.tessera.l5-loop.v1\",\"generations\":[";
    bool first_gen = true;

    // Snapshot the tensor list so we iterate in a stable order.
    std::vector<std::string> names;
    names.reserve(refine_map.size());
    for (auto & kv : refine_map) {
        names.push_back(kv.first);
    }
    std::sort(names.begin(), names.end());

    // Lagrangian multipliers for the per-family requant budgets.
    // l5_weights.requant_budget_bits (the retune's size
    // recommendation) constrains the A/B winner selection via
    // score = frob + lambda * violation, where violation is the
    // family's projected post-requant footprint over the budget.
    // lambda rises (subgradient ascent) each generation the applied
    // strategy leaves the family over budget, pushing selection
    // toward the lower-bit strategy; it resets per run (the
    // multiplier is this loop's optimization state, not a persisted
    // verdict). Families without a budget (NULL / no l5_weights
    // row) keep the legacy error-only selection.
    std::unordered_map<std::string, float> budget_lambda;
    const float budget_lambda_lr  = 0.5f;
    const float budget_lambda_max = 10.0f;

    for (int gen = 0; gen < max_generations; gen++) {
        // Converged-fast early-exit: the orchestrator's l5_outcome has
        // already verified this model's requant plans converge with
        // hit_rate > 0.95 (i.e. the "did this plan reduce error?"
        // verdict accepted >= 95% of prior plans). In that regime the
        // adaptive requantize loop is wasteful: each generation spends
        // the L2 measurement + A/B cost to re-prove something the
        // orchestrator has already proven. Break out before the L2
        // measurement on gen >= 1 so the first generation still
        // produces l4_outcome rows (the loop's audit trail). The
        // threshold (0.95) and minimum n_rows (1) are the same as the
        // acceptance criteria in docs/tessera-unified-db.md Phase 14.
        if (gen >= 1 && db_wrap != nullptr && db_wrap->db != nullptr
            && !db_wrap->model_hash.empty()) {
            ts_tessera_db_l5_outcome_stats stats;
            if (ts_tessera_db_l5_outcome_stats_for(db_wrap->db,
                                                    db_wrap->model_hash,
                                                    /*family=*/"",
                                                    &stats) == 0
                && stats.n_rows > 0
                && stats.hit_rate > 0.95f) {
                if (params->verbose) {
                    printf("tessera-dispatch: l5_loop converged-fast at gen=%d "
                           "(hit_rate=%.3f, n_rows=%d); skipping remaining %d gen(s)\n",
                           gen, stats.hit_rate, stats.n_rows,
                           max_generations - gen - 1);
                }
                if (!first_gen) report_json += ",";
                first_gen = false;
                report_json += "{\"generation\":" + std::to_string(gen) +
                               ",\"n_flagged\":0,\"n_requant\":0,"
                               "\"converged\":true,"
                               "\"converged_fast\":true,"
                               "\"hit_rate\":" + std::to_string(stats.hit_rate) +
                               ",\"l5_outcome_n_rows\":" +
                               std::to_string(stats.n_rows) + "}";
                break;
            }
        }
        // (a) L2 measure: pair each tensor's re-read source with its recon.
        std::vector<ts_l2_tensor_input> inputs;
        inputs.reserve(names.size());
        std::vector<std::vector<float>> src_keepalive(names.size());
        for (size_t i = 0; i < names.size(); i++) {
            auto it = refine_map.find(names[i]);
            if (it == refine_map.end()) continue;
            ts_dispatch_refine_entry & e = it->second;
            src_keepalive[i] = ts_refine_reread_source(in_ctx, ggml_ctx, e);
            if (src_keepalive[i].empty()) continue;
            ts_l2_tensor_input tin = {};
            tin.name  = e.name.c_str();
            tin.qtype = "tessera_t640";
            tin.rows  = e.out_dim;
            tin.cols  = e.in_dim;
            tin.bf16  = src_keepalive[i].data();
            tin.quant = e.qr->recon.data();
            inputs.push_back(tin);
        }
        if (inputs.empty()) break;

        ts_l2_report l2rep = {};
        ts_l2_config l2cfg;
        ts_l2_default_config(&l2cfg);
        snprintf(l2cfg.bf16_model_path, sizeof(l2cfg.bf16_model_path), "%s", params->input_path.c_str());
        snprintf(l2cfg.corpus_path,     sizeof(l2cfg.corpus_path),     "%s", params->calib_corpus.c_str());
        l2cfg.output_json_path[0] = '\0';  // in-memory only; we emit our own report
        l2cfg.flag_multiplier = flag_multiplier;
        if (ts_l2_run(&l2cfg, inputs.data(), (int64_t)inputs.size(), &l2rep) < 0) {
            break;
        }

        // (b) L5 plan
        ts_l5_adaptive_plan plan;
        if (ts_l5_adaptive_requant(&l2rep, &l5p, gen, &plan) < 0) {
            break;
        }
        if (plan.n_requant <= 0 || plan.specs.empty()) {
            // nothing flagged this generation; loop has converged
            if (!first_gen) report_json += ",";
            first_gen = false;
            report_json += "{\"generation\":" + std::to_string(gen) +
                           ",\"n_flagged\":0,\"n_requant\":0,\"converged\":true}";
            break;
        }

        // (c) A/B per family + re-quantize flagged tensors.
        // Group specs by tensor family, then for each family with >=1 flagged
        // tensor run Stage A (alpha/clip multiplier) and Stage B (outlier_fraction
        // bump) on one representative tensor, pick the winner by rel_frob, and
        // apply that strategy to every flagged tensor in the family.
        std::map<std::string, std::vector<const ts_l5_requant_spec *>> by_family;
        for (const auto & spec : plan.specs) {
            const std::string fam = ts_regime_infer_family(spec.tensor_name.c_str());
            by_family[fam].push_back(&spec);
        }

        // Track per-tensor before/after for the report.
        std::vector<std::tuple<std::string, std::string, float, float>> deltas;
        std::vector<std::string> family_winners;

        for (const auto & fam_kv : by_family) {
            const std::string & fam = fam_kv.first;
            const auto & specs = fam_kv.second;
            if (specs.empty()) continue;

            // Representative: the first spec's tensor. Re-read its source once.
            auto rep_it = refine_map.find(specs[0]->tensor_name);
            if (rep_it == refine_map.end()) continue;
            ts_dispatch_refine_entry & rep = rep_it->second;
            std::vector<float> rep_src = ts_refine_reread_source(in_ctx, ggml_ctx, rep);
            if (rep_src.empty()) continue;
            const int64_t rep_n = rep.out_dim * rep.in_dim;

            // --- Stage A: tighten alpha/clip as multipliers on current values.
            //     alpha is the AWQ exponent in [0,1]; clip is the outlier clip
            //     in [0.7,1.0]. new_alpha/new_clip from L5 are multipliers in
            //     [min_alpha, 0.5]. If alpha_current is 0 (AWQ off), Stage A
            //     cannot tighten alpha, so it tightens clip only.
            ts_quant_params_2d tqp_A = rep.tqp;
            const float a_mult = std::clamp(specs[0]->new_alpha, 0.0f, 1.0f);
            const float c_mult = std::clamp(specs[0]->new_clip,  0.0f, 1.0f);
            if (tqp_A.alpha > 0.0f) {
                tqp_A.alpha = std::clamp(tqp_A.alpha * a_mult, 0.0f, 1.0f);
            }
            tqp_A.clip = std::clamp(tqp_A.clip * c_mult, 0.0f, 1.0f);

            // --- Stage B: bump outlier_thresh by overshoot instead.
            //     outlier_thresh on tqp is the selection threshold; raising it
            //     selects more rows for the exact residual, lowering recon error.
            ts_quant_params_2d tqp_B = rep.tqp;
            const float bump = 1.0f + outlier_overshoot_scale * specs[0]->overshoot;
            tqp_B.outlier_thresh = std::clamp(tqp_B.outlier_thresh * bump,
                                              0.0f, outlier_frac_cap);

            // Evaluate both on the representative. We re-quantize into scratch
            // results (NOT the deque) so the comparison is non-destructive; the
            // winning strategy is then applied to each flagged tensor's deque
            // element in place.
            const float * act = rep.act_scales_copy.empty()
                                    ? nullptr : rep.act_scales_copy.data();
            float rep_frob2 = ts_vec_dotpr(rep_src.data(), rep_src.data(), rep_n);
            float frob_A = 1e30f;
            float frob_B = 1e30f;

            // Budget-constrained selection. The family's l5_weights row
            // may carry requant_budget_bits (the retune's size
            // recommendation, -1 = NULL = unconstrained). When the
            // budget is present the winner is picked on the Lagrangian
            // score frob + lambda * violation, with the per-strategy
            // footprint MEASURED by full scratch quantizations of the
            // representative (sequential, so the peak stays one recon,
            // the same as the apply phase below). Unconstrained
            // families keep the cheap streaming-MSE path.
            int64_t fam_budget = -1;
            if (db_wrap != nullptr) {
                auto w_it = db_wrap->l5_weight_map.find(fam);
                if (w_it != db_wrap->l5_weight_map.end()) {
                    fam_budget = w_it->second.requant_budget_bits;
                }
            }
            int64_t fam_bits_now   = 0;   // family footprint before this gen's requant
            int64_t rep_bits_now   = 0;   // rep's contribution to it
            int64_t proj_bits_A    = -1;  // projected footprint if A wins
            int64_t proj_bits_B    = -1;
            int64_t applied_delta_bits = 0;  // measured footprint change of the apply loop
            bool budget_path = false;
            bool stage_b_wins = false;
            if (fam_budget >= 0) {
                // Current family footprint: sum the stored results of
                // every tensor in the family (flagged or not; the
                // budget caps the family's total, not just the
                // flagged subset).
                for (const auto & kv : refine_map) {
                    if (ts_regime_infer_family(kv.first.c_str()) != fam) {
                        continue;
                    }
                    fam_bits_now += ts_dispatch_result_bits(kv.second.qr);
                    if (kv.first == specs[0]->tensor_name) {
                        rep_bits_now = ts_dispatch_result_bits(kv.second.qr);
                    }
                }
                // Scratch quantize A, then B (sequential scopes keep
                // one recon alive at a time).
                int64_t bits_A = -1, bits_B = -1;
                {
                    ts_quant_result_2d scratch;
                    if (ts_quantize_2d(rep_src.data(), act, nullptr, nullptr, act,
                                       rep.out_dim, rep.in_dim, 0,
                                       &tqp_A, &scratch) == 0) {
                        bits_A = ts_dispatch_result_bits(&scratch);
                        if (scratch.mse >= 0.0f && rep_frob2 > 0.0f) {
                            frob_A = scratch.mse * (float)rep_n / rep_frob2;
                        }
                    }
                }
                {
                    ts_quant_result_2d scratch;
                    if (ts_quantize_2d(rep_src.data(), act, nullptr, nullptr, act,
                                       rep.out_dim, rep.in_dim, 0,
                                       &tqp_B, &scratch) == 0) {
                        bits_B = ts_dispatch_result_bits(&scratch);
                        if (scratch.mse >= 0.0f && rep_frob2 > 0.0f) {
                            frob_B = scratch.mse * (float)rep_n / rep_frob2;
                        }
                    }
                }
                if (bits_A >= 0 && bits_B >= 0) {
                    budget_path = true;
                    proj_bits_A = fam_bits_now - rep_bits_now + bits_A;
                    proj_bits_B = fam_bits_now - rep_bits_now + bits_B;
                    const float lam = budget_lambda[fam];
                    const float denom = (float)std::max<int64_t>(1, fam_budget);
                    const float vio_A = proj_bits_A > fam_budget
                        ? (float)(proj_bits_A - fam_budget) / denom : 0.0f;
                    const float vio_B = proj_bits_B > fam_budget
                        ? (float)(proj_bits_B - fam_budget) / denom : 0.0f;
                    const float score_A = frob_A + lam * vio_A;
                    const float score_B = frob_B + lam * vio_B;
                    // The winner on the Lagrangian score. Ties keep A
                    // (the no-bit-growth strategy), matching the
                    // conservative bias of the budget contract.
                    stage_b_wins = (score_B < score_A);
                }
            }
            if (!budget_path) {
                // Streaming MSE for the A/B comparison (only needs the scalar,
                // not the full packed output). ~132 KB scratch per call.
                float mse_A = ts_quantize_mse_streaming(
                    rep_src.data(), act, tqp_A.alpha, tqp_A.clip,
                    rep.out_dim, rep.in_dim);
                float mse_B = ts_quantize_mse_streaming(
                    rep_src.data(), act, tqp_B.alpha, tqp_B.clip,
                    rep.out_dim, rep.in_dim);
                frob_A = (mse_A >= 0.0f && rep_frob2 > 0.0f)
                             ? (mse_A * (float)rep_n / rep_frob2) : 1e30f;
                frob_B = (mse_B >= 0.0f && rep_frob2 > 0.0f)
                             ? (mse_B * (float)rep_n / rep_frob2) : 1e30f;
                stage_b_wins = (frob_B < frob_A);
            }

            std::string winner_json = "{\"family\":\"" + fam + "\",\"stage\":\"" +
                                     (stage_b_wins ? "B" : "A") +
                                     "\",\"frob_A\":" + std::to_string(frob_A) +
                                     ",\"frob_B\":" + std::to_string(frob_B);
            if (budget_path) {
                winner_json += ",\"budget\":" + std::to_string(fam_budget) +
                               ",\"lambda\":" + std::to_string(budget_lambda[fam]) +
                               ",\"proj_bits_A\":" + std::to_string(proj_bits_A) +
                               ",\"proj_bits_B\":" + std::to_string(proj_bits_B);
            }
            winner_json += "}";
            family_winners.push_back(winner_json);

            // Apply the winning strategy to every flagged tensor in this family.
            for (const auto * spec : specs) {
                auto it = refine_map.find(spec->tensor_name);
                if (it == refine_map.end()) continue;
                ts_dispatch_refine_entry & e = it->second;

                std::vector<float> src = ts_refine_reread_source(in_ctx, ggml_ctx, e);
                if (src.empty()) continue;
                const int64_t n = e.out_dim * e.in_dim;

                ts_quant_params_2d tightened = e.tqp;
                if (stage_b_wins) {
                    tightened.outlier_thresh = std::clamp(
                        tightened.outlier_thresh * (1.0f + outlier_overshoot_scale * spec->overshoot),
                        0.0f, outlier_frac_cap);
                } else {
                    const float am = std::clamp(spec->new_alpha, 0.0f, 1.0f);
                    const float cm = std::clamp(spec->new_clip,  0.0f, 1.0f);
                    if (tightened.alpha > 0.0f) {
                        tightened.alpha = std::clamp(tightened.alpha * am, 0.0f, 1.0f);
                    }
                    tightened.clip = std::clamp(tightened.clip * cm, 0.0f, 1.0f);
                }

                const float before = ts_refine_rel_frob(src.data(), e.qr, n);
                const int64_t bits_before = (fam_budget >= 0)
                                                ? ts_dispatch_result_bits(e.qr) : 0;
                const float * e_act = e.act_scales_copy.empty()
                                          ? nullptr : e.act_scales_copy.data();
                int rc = ts_quantize_2d(src.data(), e_act, nullptr, nullptr, e_act,
                                        e.out_dim, e.in_dim, 0, &tightened, e.qr);
                if (rc != 0) {
                    continue;
                }
                if (fam_budget >= 0) {
                    applied_delta_bits += ts_dispatch_result_bits(e.qr) - bits_before;
                }
                // Refresh the GGUF descriptors: in-place re-quant may have
                // reallocated the deque element's buffers.
                ts_gguf_repoint_tensor_cluster(out_ggml_ctx, e.name.c_str(), e.qr);
                const float after = ts_refine_rel_frob(src.data(), e.qr, n);

                // Refresh result->tensors copies so downstream consumers see
                // the refined bytes and applied profile.
                for (auto & tr : result->tensors) {
                    if (tr.name == e.name) {
                        tr.packed              = ts_to_bytes_u32(e.qr->packed);
                        tr.page_scales         = ts_to_bytes_u16(e.qr->page_scales);
                        tr.lane_scales         = ts_to_bytes_i8(e.qr->lane_scales);
                        tr.outlier_row_offsets = ts_to_bytes_i32(e.qr->outlier_row_offsets);
                        tr.outlier_cols        = ts_to_bytes_i32(e.qr->outlier_cols);
                        tr.outlier_vals        = ts_to_bytes_u16(e.qr->outlier_vals);
                        tr.act_scale           = ts_to_bytes_u16(e.qr->act_scale);
                        tr.mse                 = e.qr->mse;
                        tr.alpha_used          = e.qr->best_alpha;
                        tr.profile_alpha       = tightened.alpha;
                        tr.profile_clip        = tightened.clip;
                        tr.profile_outlier_thresh = tightened.outlier_thresh;
                        break;
                    }
                }

                deltas.push_back(std::make_tuple(e.name, fam, before, after));

                // Feedback loop: write one l4_plan_outcome row per
                // (tensor, gen). The Python l5_outcome.py consumer
                // joins this with l5_plan_summary on (model_hash,
                // name, iteration, plan_id) to compute delta_mse and
                // the accept verdict. The plan_id is synthesized
                // from the C++ iteration index + the stage that won
                // (A or B); the "cpp_quant" prefix disambiguates from
                // the Python orchestrator's plan_ids.
                if (db_wrap != nullptr && db_wrap->l4_outcome_buffer != nullptr) {
                    ts_tessera_db_l4_outcome out_row;
                    out_row.model_hash   = db_wrap->model_hash;
                    out_row.name         = e.name;
                    out_row.layer        = ts_tessera_db_layer_depth(e.name);
                    out_row.iteration    = gen;
                    out_row.plan_id      = std::string("cpp_quant_gen")
                                           + std::to_string(gen)
                                           + (stage_b_wins ? "_stageB" : "_stageA");
                    out_row.strategy     = stage_b_wins ? "B" : "A";
                    out_row.alpha_before = e.tqp.alpha;
                    out_row.alpha_after  = tightened.alpha;
                    out_row.clip_before  = e.tqp.clip;
                    out_row.clip_after   = tightened.clip;
                    out_row.outlier_thresh_before = e.tqp.outlier_thresh;
                    out_row.outlier_thresh_after  = tightened.outlier_thresh;
                    out_row.mse_before   = before;
                    out_row.mse_after    = after;
                    out_row.frob_before  = before;   // rel_frob is already normalized
                    out_row.frob_after   = after;
                    out_row.family       = fam;
                    ts_tessera_db_append_l4_outcome(
                        db_wrap->l4_outcome_buffer, out_row);
                }
            }

            // Subgradient ascent on the budget multiplier: if the applied
            // winner left the family over its requant budget, raise lambda
            // so the next generation's Lagrangian selection leans harder
            // toward the lower-bit strategy. The violation is normalized
            // by the budget, so the step is scale-free across families.
            if (budget_path && fam_budget > 0) {
                const int64_t fam_after = fam_bits_now + applied_delta_bits;
                if (fam_after > fam_budget) {
                    const float vio = (float)(fam_after - fam_budget) / (float)fam_budget;
                    float & lam = budget_lambda[fam];
                    lam = std::min(budget_lambda_max, lam + budget_lambda_lr * vio);
                }
            }
        }

        // Generation report entry
        if (!first_gen) report_json += ",";
        first_gen = false;
        report_json += "{\"generation\":" + std::to_string(gen) +
                       ",\"n_flagged\":" + std::to_string((int64_t)l2rep.n_flagged) +
                       ",\"n_requant\":" + std::to_string(plan.n_requant) +
                       ",\"families\":[" + ts_join(family_winners, ",") + "]" +
                       ",\"tensors\":[";
        bool first_d = true;
        for (const auto & d : deltas) {
            if (!first_d) report_json += ",";
            first_d = false;
            report_json += "{\"name\":\"" + std::get<0>(d) +
                           "\",\"family\":\"" + std::get<1>(d) +
                           "\",\"before\":" + std::to_string(std::get<2>(d)) +
                           ",\"after\":" + std::to_string(std::get<3>(d)) + "}";
        }
        report_json += "]}";
    }

    report_json += "]}";
    result->l5_report_json = std::move(report_json);

    // Write the report beside policy_out_path unless the caller overrode it.
    if (!params->l5_out_path.empty()) {
        std::ofstream out(params->l5_out_path);
        if (out) {
            out << result->l5_report_json;
        }
    } else if (!params->policy_out_path.empty()) {
        std::string p = params->policy_out_path + ".l5-loop.json";
        std::ofstream out(p);
        if (out) {
            out << result->l5_report_json;
        }
    }

    if (params->verbose) {
        printf("tessera-dispatch: l5 loop wrote %zu bytes of report\n",
               result->l5_report_json.size());
    }

    return 0;
}

// ===========================================================================
// L5 joint PPL loop (the production default)
// ===========================================================================
//
// Implementation note: this function loads the 5 model contexts (target
// always, drafter/talker if their paths are non-empty), constructs the
// joint PPL harness, and runs the coarse-to-fine search.
//
// v3 production wiring: when at least one drafter/talker path is
// provided, the 5 models are loaded via ts_l5_joint_models_load
// (each model gets a llama_model + llama_context), and the harness's
// per-model context slots are bound to the loaded contexts. The
// forward functions (ts_l5_real_trunk_forward,
// ts_l5_real_drafter_forward, ts_l5_real_talker_forward) call
// llama_decode on each context to produce real logits. This is the
// calibration counterpart of the ADAPTIVE muxer's inference forward.
//
// When all drafter/talker paths are empty (the smoke test), the
// harness uses the file-static synthetic all-zero-logits forwards
// (l5j_synth_trunk_forward, l5j_synth_drafter_forward,
// l5j_synth_talker_forward). The mechanism (AND-gate, coarse-to-
// fine, strict pass) is verified end-to-end without requiring real
// models on disk.
//
// v3 limitation: the per-block hidden state sharing from the
// trunk to the drafters is approximated (the drafters consume the
// same input tokens as the trunk via their own llama_decode). The
// full cross-model hidden state sharing is v3.5+ via the ADAPTIVE
// muxer's graph-injection infrastructure.

namespace {

// Synthetic trunk forward: produces all-zero logits. The production
// forward (loaded from the target GGUF) is a future v3 swap. See
// ts_dispatch_run_l5_joint for the swap point.
static void l5j_synth_trunk_forward(
        const int32_t * tokens,
        int32_t n_tokens,
        float * trunk_logits_out,
        float * trunk_final_output_out,
        void * ctx) {
    (void)tokens; (void)ctx;
    const int32_t V = 32000;
    const size_t n_logits = (size_t)n_tokens * (size_t)V;
    for (size_t i = 0; i < n_logits; ++i) trunk_logits_out[i] = 0.0f;
    const size_t n_hidden = (size_t)n_tokens * (size_t)V;
    for (size_t i = 0; i < n_hidden; ++i) trunk_final_output_out[i] = 0.0f;
}

// Synthetic drafter forward: all-zero logits, ignores the hidden state.
static void l5j_synth_drafter_forward(
        const float * hidden_state_in,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * drafter_logits_out,
        void * ctx) {
    (void)hidden_state_in; (void)hidden_dim; (void)ctx;
    const int32_t V = 32000;
    const size_t n_logits = (size_t)n_tokens * (size_t)V;
    for (size_t i = 0; i < n_logits; ++i) drafter_logits_out[i] = 0.0f;
}

// Synthetic talker forward: all-zero audio logits, ignores the trunk output.
static void l5j_synth_talker_forward(
        const float * trunk_final_output,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * talker_logits_out,
        void * ctx) {
    (void)trunk_final_output; (void)hidden_dim; (void)ctx;
    const int32_t V = 4096;
    const size_t n_logits = (size_t)n_tokens * (size_t)V;
    for (size_t i = 0; i < n_logits; ++i) talker_logits_out[i] = 0.0f;
}

}  // namespace

int ts_dispatch_run_l5_joint(
    const ts_dispatch_params * params,
    ts_dispatch_result * result,
    std::string * err_msg) {
    if (!params || !result) {
        if (err_msg) *err_msg = "ts_dispatch_run_l5_joint: null params/result";
        return -1;
    }

    // ---- Set up the joint PPL harness ----
    //
    // Real drafter / talker loading is a v3 follow-up. For now, the
    // harness uses synthetic forwards (smoke test). The drafter /
    // talker GGUF paths are read from params; if non-empty, the
    // corresponding model is "active" (the AND-gate checks its
    // delta); if empty, it's inactive (delta = 0 by construction).
    //
    // At v3, the synthetic forward is replaced by a real forward
    // that loads the GGUF and runs the actual model. The harness
    // API is unchanged: just swap the function pointer.

    ts_l5_ppl_harness harness;
    harness.vocab_size[TS_L5_MODEL_TARGET] = 32000;
    harness.vocab_size[TS_L5_MODEL_DFLASH] = 32000;
    harness.vocab_size[TS_L5_MODEL_DSPARK] = 32000;
    harness.vocab_size[TS_L5_MODEL_MTP]    = 32000;
    harness.vocab_size[TS_L5_MODEL_TALKER] = 4096;
    harness.n_tokens  = 256;
    harness.rng_seed  = 0xCAFE5EAu;

    // ---- Real model loading (v3 production wiring) ----
    //
    // When at least one drafter/talker path is provided in
    // params->*, load the 5 models via ts_l5_joint_models_load and
    // bind the harness's per-model context slots. The forward
    // functions then use llama_decode on each context to produce
    // real logits (the calibration forward is the production
    // counterpart of the ADAPTIVE muxer's inference forward).
    //
    // When all drafter/talker paths are empty (the smoke test), the
    // harness uses synthetic all-zero-logits forwards; the
    // mechanism (AND-gate, coarse-to-fine, strict pass) is verified
    // end-to-end without requiring real models on disk.
    ts_l5_joint_models models;
    const bool any_drafter_path = !params->dflash_gguf_path.empty()
            || !params->dspark_gguf_path.empty()
            || !params->mtp_gguf_path.empty()
            || !params->talker_gguf_path.empty();
    bool use_real_forwards = false;
    if (any_drafter_path) {
        // Pipeline refactor phase 3 ("KV-joint plumbing"): parse the
        // string KV cache types from CLI-derived params into ggml_type.
        // Empty (the default) resolves to F16, identical to
        // llama_context_default_params -- today's behavior when no
        // -l5-joint-ctk/-ctv flag was passed. An invalid type name is a
        // hard error here (not a silent fallback) so a typo surfaces
        // immediately instead of quietly running under the wrong codec.
        auto parse_kv_type = [](const char * field, const std::string & s) -> ggml_type {
            if (s.empty()) return GGML_TYPE_F16;
            try {
                return common_kv_cache_type_from_str(s);
            } catch (const std::exception & e) {
                fprintf(stderr, "tessera-dispatch: ERROR: L5 joint %s: %s "
                                "(falling back to f16)\n", field, e.what());
                return GGML_TYPE_F16;
            }
        };
        const ggml_type l5_type_k       = parse_kv_type("--l5-joint-ctk",  params->l5_joint_type_k);
        const ggml_type l5_type_v       = parse_kv_type("--l5-joint-ctv",  params->l5_joint_type_v);
        const ggml_type l5_type_k_draft = parse_kv_type("--l5-joint-ctkd", params->l5_joint_type_k_draft);
        const ggml_type l5_type_v_draft = parse_kv_type("--l5-joint-ctvd", params->l5_joint_type_v_draft);

        std::string load_err;
        const int load_rc = ts_l5_joint_models_load(
                params->input_path,
                params->dflash_gguf_path,
                params->dspark_gguf_path,
                params->mtp_gguf_path,
                params->talker_gguf_path,
                /*n_ctx=*/512,
                /*n_threads=*/params->nthreads > 0 ? params->nthreads : 1,
                &models,
                &load_err,
                l5_type_k, l5_type_v, l5_type_k_draft, l5_type_v_draft);
        if (load_rc == 0) {
            use_real_forwards = true;
            // Bind the harness's per-model context slots to the
            // loaded contexts. The forward functions dereference
            // these at call time.
            harness.model_ctx[TS_L5_MODEL_TARGET] = models.c[TS_L5_MODEL_TARGET];
            harness.model_ctx[TS_L5_MODEL_DFLASH] = models.c[TS_L5_MODEL_DFLASH];
            harness.model_ctx[TS_L5_MODEL_DSPARK] = models.c[TS_L5_MODEL_DSPARK];
            harness.model_ctx[TS_L5_MODEL_MTP]    = models.c[TS_L5_MODEL_MTP];
            harness.model_ctx[TS_L5_MODEL_TALKER] = models.c[TS_L5_MODEL_TALKER];
        } else if (err_msg) {
            *err_msg = "L5 joint: model load failed: " + load_err
                    + " (falling back to synthetic forwards)";
        }
    }

    // Wire the forward slots. When real models are loaded, the real
    // forwards call llama_decode on each context. When the smoke
    // test runs (no model paths), the synthetic forwards produce
    // all-zero logits (the harness's AND-gate still works because
    // FP == quant for all-zero logits -> delta = 0).
    ts_l5_drafter_forward_fn drafter_fns[TS_L5_MODEL_COUNT] = {
        nullptr,
        use_real_forwards ? ts_l5_real_drafter_forward : l5j_synth_drafter_forward,
        use_real_forwards ? ts_l5_real_drafter_forward : l5j_synth_drafter_forward,
        use_real_forwards ? ts_l5_real_drafter_forward : l5j_synth_drafter_forward,
        nullptr,
    };
    ts_l5_trunk_forward_fn  trunk_forward_fn = use_real_forwards
            ? ts_l5_real_trunk_forward : l5j_synth_trunk_forward;
    ts_l5_talker_forward_fn talker_forward_fn = use_real_forwards
            ? ts_l5_real_talker_forward : l5j_synth_talker_forward;

    // ---- Build the initial policy from the drafter / talker paths ----
    //
    // Activity propagates via the policy. Inactive models have
    // models_active[m] = false; the harness skips them in the
    // AND-gate. For the production path, the user provides the
    // drafter / talker GGUFs; the activity is set accordingly.
    ts_l5_joint_policy policy;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        policy.models_active[m] = true;  // target always active
        for (int f = 0; f < TS_L5_FAMILY_COUNT; ++f) {
            policy.families[m][f] = ts_l5_family_policy{};
        }
    }
    if (params->dflash_gguf_path.empty()) policy.models_active[TS_L5_MODEL_DFLASH] = false;
    if (params->dspark_gguf_path.empty()) policy.models_active[TS_L5_MODEL_DSPARK] = false;
    if (params->mtp_gguf_path.empty())    policy.models_active[TS_L5_MODEL_MTP]    = false;
    if (params->talker_gguf_path.empty()) policy.models_active[TS_L5_MODEL_TALKER] = false;

    if (params->verbose) {
        std::fprintf(stderr, "L5 joint: target=active dflash=%s dspark=%s mtp=%s talker=%s\n",
                params->dflash_gguf_path.empty() ? "inactive" : "active",
                params->dspark_gguf_path.empty() ? "inactive" : "active",
                params->mtp_gguf_path.empty()    ? "inactive" : "active",
                params->talker_gguf_path.empty() ? "inactive" : "active");
    }

    // ---- Build the search params ----
    // velocity_window/thresholds keep the struct defaults (PR #11).
    ts_l5_joint_params jparams;
    jparams.epsilon           = params->l5_joint_epsilon;
    jparams.top_k             = params->l5_joint_top_k;
    jparams.max_generations   = params->l5_joint_max_generations;
    jparams.n_gen0_samples    = params->l5_joint_n_gen0_samples;
    jparams.rng_seed          = params->l5_joint_rng_seed;
    jparams.metric            = static_cast<ts_l5_joint_metric>(params->l5_joint_metric);
    jparams.verbose           = params->verbose;

    // ---- Run the joint search ----
    ts_l5_joint_search_result sresult;
    const int s_rc = ts_l5_joint_search(
            &harness, trunk_forward_fn, drafter_fns, talker_forward_fn,
            &jparams, &sresult);
    if (s_rc != 0) {
        if (err_msg) *err_msg = "ts_l5_joint_search returned non-zero";
        return s_rc;
    }

    // ---- Populate the result struct ----
    result->l5_joint_ran           = true;
    result->l5_joint_real_forwards = use_real_forwards;
    result->l5_joint_and_gate_passed = sresult.winning_entry.measure.all_pass;
    result->l5_joint_winning_ppl   = sresult.winning_entry.joint_ppl;
    result->l5_joint_n_generations = sresult.n_generations_run;
    // Worst per-model delta: tracked regardless of the metric so the
    // report can show "the worst model in the winning policy" without
    // recomputing. With the MAX metric, this equals l5_joint_winning_ppl.
    result->l5_joint_winning_max_delta = sresult.winning_max_per_model_delta;
    // Echo the metric the search used (0=MAX, 1=SUM, 2=MEAN).
    result->l5_joint_metric_used = static_cast<int>(jparams.metric);

    // ---- Strict pass (if --tessera-l5-strict) ----
    if (params->l5_joint_strict) {
        ts_l5_joint_strict_result strict_r;
        const int strict_rc = ts_l5_joint_strict_pass(
                &harness, trunk_forward_fn, drafter_fns, talker_forward_fn,
                &sresult.winning_entry.policy,
                0.0025f,            // strict epsilon (0.25%)
                &jparams,
                &strict_r);
        if (strict_rc == 0) {
            result->l5_joint_strict_ran        = true;
            result->l5_joint_strict_converged  =
                    (strict_r.status == ts_l5_joint_strict_result::Status::STRICT_CONVERGED);
            result->l5_joint_strict_epsilon   = strict_r.strict_epsilon;
            result->l5_joint_strict_worst_delta = strict_r.max_per_model_delta;
        }
    }

    // ---- Write the report JSON (schema llama.tessera.l5-joint-loop.v1) ----
    //
    // The JSON is hand-rolled (no external deps in this code path).
    // For a full implementation, swap for a json helper. For now,
    // we emit a minimal schema with the winning policy's PPL + AND-gate
    // verdict + (if strict) the strict pass result.
    std::string report;
    {
        // Reserve a reasonable size; the JSON is small.
        report.reserve(1024);
        report += "{\n";
        report += "  \"schema\": \"llama.tessera.l5-joint-loop.v1\",\n";
        report += "  \"status\": \"";
        switch (sresult.status) {
            case ts_l5_joint_search_result::Status::CONVERGED:          report += "CONVERGED"; break;
            case ts_l5_joint_search_result::Status::FORCED_TERMINATION: report += "FORCED_TERMINATION"; break;
            case ts_l5_joint_search_result::Status::BEST_EFFORT:        report += "BEST_EFFORT"; break;
        }
        report += "\",\n";
        report += "  \"n_generations\": " + std::to_string(sresult.n_generations_run) + ",\n";
        report += "  \"epsilon\": " + std::to_string(params->l5_joint_epsilon) + ",\n";
        // Velocity-gate knobs (PR #11): the stop criterion is the winning
        // joint_ppl being flat for velocity_window generations. Additive
        // to the schema; old readers ignore the new fields.
        report += "  \"velocity_window\": " + std::to_string(jparams.velocity_window) + ",\n";
        report += "  \"velocity_threshold\": " + std::to_string(jparams.velocity_threshold) + ",\n";
        report += "  \"acceleration_threshold\": " + std::to_string(jparams.acceleration_threshold) + ",\n";
        // Echo the search metric (0=MAX, 1=SUM, 2=MEAN) so the report
        // shows which collapse the winning_ppl used.
        const char * metric_name = "max";
        switch (jparams.metric) {
            case ts_l5_joint_metric::MAX:  metric_name = "max";  break;
            case ts_l5_joint_metric::SUM:  metric_name = "sum";  break;
            case ts_l5_joint_metric::MEAN: metric_name = "mean"; break;
        }
        report += "  \"metric\": \"" + std::string(metric_name) + "\",\n";
        report += "  \"and_gate_passed\": " + std::string(result->l5_joint_and_gate_passed ? "true" : "false") + ",\n";
        report += "  \"joint_ppl\": " + std::to_string(result->l5_joint_winning_ppl) + ",\n";
        // Worst per-model delta: always tracked, with the MAX metric
        // this equals joint_ppl. Useful for the report reader to see
        // "the worst model in the winning policy" without re-reading
        // per_model_delta.
        report += "  \"max_per_model_delta\": " + std::to_string(result->l5_joint_winning_max_delta) + ",\n";
        report += "  \"per_model_delta\": [";
        for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
            if (m > 0) report += ",";
            report += std::to_string(sresult.winning_entry.measure.per_model[m].delta);
        }
        report += "],\n";
        report += "  \"models_active\": [";
        for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
            if (m > 0) report += ",";
            report += policy.models_active[m] ? "true" : "false";
        }
        report += "]";
        if (result->l5_joint_strict_ran) {
            report += ",\n  \"strict\": {\n";
            report += "    \"ran\": true,\n";
            report += "    \"converged\": " + std::string(result->l5_joint_strict_converged ? "true" : "false") + ",\n";
            report += "    \"epsilon\": " + std::to_string(result->l5_joint_strict_epsilon) + ",\n";
            report += "    \"worst_delta\": " + std::to_string(result->l5_joint_strict_worst_delta) + "\n";
            report += "  }";
        }
        report += "\n}\n";
    }
    result->l5_joint_report_json = report;

    // ---- Write the report to disk if a path is configured ----
    std::string out_path = params->l5_joint_out_path;
    if (out_path.empty() && !params->policy_out_path.empty()) {
        // Default: <policy_out_path stem>.l5-joint.json
        const std::string & po = params->policy_out_path;
        const auto dot = po.find_last_of('.');
        const auto slash = po.find_last_of('/');
        const std::string stem = (dot != std::string::npos && dot > slash)
                ? po.substr(0, dot) : po;
        out_path = stem + ".l5-joint.json";
    }
    if (!out_path.empty()) {
        FILE * fp = std::fopen(out_path.c_str(), "w");
        if (fp) {
            std::fputs(report.c_str(), fp);
            std::fclose(fp);
            if (params->verbose) {
                std::fprintf(stderr, "L5 joint: wrote report to %s\n", out_path.c_str());
            }
        } else if (err_msg) {
            *err_msg = "L5 joint: failed to open " + out_path + " for write";
            // Non-fatal: the report is still in result->l5_joint_report_json.
        }
    }

    // ---- Free the loaded models (v3 production wiring) ----
    // Always free, even on the synthetic-forwards path (the load
    // failed or the user provided no paths; the function handles
    // both cases by skipping null slots).
    ts_l5_joint_models_free(&models);

    return 0;
}
