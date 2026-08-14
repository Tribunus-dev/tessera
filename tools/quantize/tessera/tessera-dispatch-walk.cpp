//
// tessera-dispatch-walk.cpp
//
// Pipeline refactor phase 4: the dispatch walk (steps 6-7a-legacy),
// extracted verbatim from ts_dispatch_run's body. Per the contracts
// appendix's dispatch-walk module notes: owns out_ctx/out_ggml_ctx
// (created here, step 6), the cluster_results/moe_results deques (moved
// out via out-params since gguf_write_to_file at step 9 reads through
// pointers into their elements -- std::deque's move preserves element
// addresses, so the pointers GGUF descriptors hold remain valid after the
// move), refine_map (fully internal: built and consumed entirely within
// this function via the step 7a-legacy call to ts_dispatch_run_l5_loop,
// never exposed), and the L5 scorer collectors (combine runs after the
// walk, still within this function).
//
// Pure code motion: every line of logic below the "walk body" marker is
// unchanged from the original inline block in tessera-dispatch.cpp, only
// wrapped in a function and given an explicit parameter list instead of
// implicit closure capture. have_imatrix/imatrix, have_mm_imatrix/
// mm_imatrix, have_policy/policy, ga_alpha, mm_awq, calib_X/calib_in_dim/
// calib_n_tokens, default_alpha, db_wrap, prog, in_ctx, ggml_ctx,
// n_tensors, params, result, err_msg all keep their original names as
// parameters so the body needed zero edits; verbose and need_ga are
// cheap pure derivations from params, re-computed here rather than
// threaded in.
//

#include "tessera-dispatch.h"
#include "tessera-dispatch-internal.h"
#include "tessera-quant.h"
#include "tessera-regime.h"
#include "tessera-gguf-writer.h"
#include "tessera-imatrix.h"
#include "tessera-l5.h"
#include "tessera-mm-imatrix.h"
#include "tessera-mm-awq.h"
#include "tessera-w4a4.h"
#include "tessera-policy.h"
#include "tessera-progress.h"
#include "tessera-quantize-db.h"

#include "gguf.h"
#include "ggml.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

// See the file header above for the parameter-naming rationale. Returns
// 0 on success; 1 on output-context init failure, 2 on a quantize
// failure -- matching ts_dispatch_run's original return codes for these
// paths exactly (both error paths, preserved verbatim below, already
// free out_ctx/out_ggml_ctx/in_ctx/ggml_ctx themselves before returning,
// so a non-zero return here means the caller must NOT free them again).
int ts_dispatch_run_walk(
        const ts_dispatch_params * params,
        ts_dispatch_result * result,
        std::string * err_msg,
        struct gguf_context * in_ctx,
        struct ggml_context * ggml_ctx,
        int64_t n_tensors,
        bool have_imatrix, const ts_imatrix & imatrix,
        bool have_mm_imatrix, const ts_mm_imatrix & mm_imatrix,
        const std::vector<float> & calib_X, int64_t calib_in_dim, int64_t calib_n_tokens,
        float default_alpha,
        bool have_policy, const ts_policy & policy,
        const std::unordered_map<std::string, float> & ga_alpha,
        std::unordered_map<std::string, ts_mm_awq_result> & mm_awq,
        ts_dispatch_db * db_wrap,
        ts_progress * prog,
        struct gguf_context ** out_ctx_out,
        struct ggml_context ** out_ggml_ctx_out,
        std::deque<ts_quant_result_2d> * cluster_results_out,
        std::deque<std::vector<ts_quant_result_2d>> * moe_results_out,
        float * total_mse_out,
        int64_t * n_quantized_out,
        int64_t * n_skipped_out,
        std::string * policy_json_out) {
    const bool verbose = params->verbose;
    const bool need_ga = params->policy_path.empty();

    // --- step 6: prepare output GGUF ---
    struct gguf_context * out_ctx = gguf_init_empty();
    gguf_set_kv(out_ctx, in_ctx);

    // The cluster descriptors are allocated from a caller-owned context so the
    // writer stays allocation-free. Size it from the input metadata: each
    // quantizable tensor emits one cluster (ne[2] clusters for a 3D MoE
    // weight), up to 7 descriptors each. Over-counting only wastes a little
    // RAM; under-counting aborts ggml_init's fixed pool, so budget generously.
    int64_t n_cluster_tensors = 0;
    for (int64_t i = 0; i < n_tensors; i++) {
        const enum ggml_type type_i = gguf_get_tensor_type(in_ctx, i);
        const int64_t * ne_i = gguf_get_tensor_ne(in_ctx, i);
        int nd_i = GGML_MAX_DIMS;
        while (nd_i > 1 && ne_i[nd_i - 1] == 1) nd_i--;
        if (!ts_is_quantizable(gguf_get_tensor_name(in_ctx, i), type_i, nd_i)) continue;
        n_cluster_tensors += ((nd_i == 3) ? ne_i[2] : 1) * 7;
    }
    struct ggml_init_params out_init = {
        /*mem_size   =*/ (size_t)n_cluster_tensors * 512 + 64 * 1024,
        /*mem_buffer =*/ nullptr,
        /*no_alloc   =*/ true,
    };
    struct ggml_context * out_ggml_ctx = ggml_init(out_init);
    if (!out_ggml_ctx) {
        if (err_msg) {
            *err_msg = "ggml_init failed for output tensor context";
        }
        gguf_free(out_ctx);
        gguf_free(in_ctx);
        ggml_free(ggml_ctx);
        return 1;
    }

    // Quant-result buffers are referenced by the GGUF tensor descriptors by
    // data pointer, and gguf_write_to_file reads through those pointers after
    // the walk below completes. The results must therefore outlive the write,
    // so they are kept in function-scope deques (stable element addresses)
    // rather than as per-iteration locals.
    std::deque<ts_quant_result_2d>              cluster_results; // 2D weights
    std::deque<std::vector<ts_quant_result_2d>> moe_results;     // 3D MoE weights

    // L5 adaptive requantize: per-tensor metadata captured during step 7 so the
    // refine loop can target 2D tensors by name without re-walking the GGUF.
    // Only 2D tensors are eligible; 3D MoE re-quantize is deferred.
    std::unordered_map<std::string, ts_dispatch_refine_entry> refine_map;

    // --- step 7: walk tensors, quantize or copy through ---
    ts_quant_params_2d qparams;
    qparams.alpha          = default_alpha;
    qparams.clip           = params->awq_clip;
    qparams.max_outliers   = 0;
    qparams.outlier_thresh = params->outlier_frac;
    qparams.use_imatrix    = false;
    qparams.use_septq      = false;
    qparams.awq_grid       = 20;
    qparams.seed           = (uint32_t)params->evolve_seed;

    // S9 W4A4 activation quantization config. The weight-only contract is
    // unchanged when w4a4 is false; when true the per-tensor activation scales
    // and LLM.int8 outlier decomposition are computed from the calibration
    // activations and recorded as sidecar metadata.
    ts_w4a4_config wcfg = ts_w4a4_default_config();
    wcfg.enable         = params->w4a4;
    wcfg.outlier_thresh = params->w4a4_outlier_thresh > 0.0f
                              ? params->w4a4_outlier_thresh : wcfg.outlier_thresh;
    if (params->w4a4 && verbose) {
        printf("tessera-dispatch: W4A4 enabled (bits=%d scale_mode=%s outlier_thresh=%.2f)\n",
               wcfg.activation_bits, ts_w4a4_scale_mode_str(wcfg.scale_mode).c_str(),
               wcfg.outlier_thresh);
    }

    float total_mse = 0.0f;
    int64_t n_quantized = 0;
    int64_t n_skipped   = 0;

    // policy JSON accumulator
    std::string policy_json = "{\n  \"tensors\": [\n";
    bool first_policy_entry = true;

    // ---- L5 scorer combine collectors (Phase C, spec §9.4) ----
    // The l5_scorer spec ("hessian:0.5,imatrix:0.3,grad:0.2") is joined via
    // ts_l5_combine AFTER the quantize walk. The per-tensor inputs are
    // collected during the walk, where the source weights AND the quantized
    // reconstruction coexist (the OBQ omega denominator needs both). Only
    // 2D tensors participate: the MoE branch produces per-expert
    // reconstructions, not a single w_hat, so it stays out of the map
    // (absent tensors contribute 0 to the combined score, matching the
    // shipped scorers' missing-data fallback).
    const bool l5_scorer_enabled = !params->l5_scorer.empty();
    std::vector<std::string>  l5_names;          // 2D quantized tensor names
    std::vector<float>        l5_imatrix_mean;   // mean |act| per tensor
    std::vector<float>        l5_hessian_raw;    // OBQ mean omega per tensor
    int32_t l5_hessian_n_scored     = 0;
    int32_t l5_hessian_n_cached     = 0;   // H_inv_diag read from the DB cache
    int32_t l5_hessian_n_factorized = 0;   // Cholesky factorizes this run
    int32_t l5_hessian_n_skipped    = 0;   // 2D tensors without calibration data
    // Run-local memo: with the dispatch-level corpus, every tensor sharing
    // (X, in_dim) has the SAME H = X^T X / n, so factorize once per in_dim
    // per run and store the diagonal under each tensor name (the cache key
    // is per-name for the future per-layer activation capture).
    std::map<int64_t, std::vector<float>> l5_hinv_memo;

    // The quantize-write loop is the second long phase. Bump progress per
    // tensor written (quantized or copied through).
    ts_progress_set_phase(prog, ts_progress_phase::QUANTIZE, n_tensors,
                          "write quantized tensors");

    for (int64_t i = 0; i < n_tensors; i++) {
        const char * name = gguf_get_tensor_name(in_ctx, i);
        const enum ggml_type type = gguf_get_tensor_type(in_ctx, i);
        const int64_t * ne = gguf_get_tensor_ne(in_ctx, i);

        // count dimensions (ne[d] == 1 for d >= n_dims)
        int n_dims = GGML_MAX_DIMS;
        while (n_dims > 1 && ne[n_dims - 1] == 1) {
            n_dims--;
        }

        struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, name);
        if (t == nullptr) {
            fprintf(stderr, "tessera-dispatch: warning: tensor '%s' not found in ggml context, skipping\n", name);
            n_skipped++;
            ts_progress_inc(prog, 1, name);
            continue;
        }

        if (!ts_is_quantizable(name, type, n_dims)) {
            // copy through unchanged
            gguf_add_tensor(out_ctx, t);
            n_skipped++;
            if (verbose) {
                printf("tessera-dispatch: copy-through %s (%s)\n", name, ggml_type_name(type));
            }
            ts_progress_inc(prog, 1, name);
            continue;
        }

        // quantizable weight matrix
        const std::string family = ts_regime_infer_family(name);
        const int64_t in_dim  = ne[0];
        const int64_t out_dim = ne[1];

        // convert to F32
        std::vector<float> weights = ts_tensor_to_f32(t);
        if (weights.empty()) {
            fprintf(stderr, "tessera-dispatch: warning: unsupported type for '%s', copying through\n", name);
            gguf_add_tensor(out_ctx, t);
            n_skipped++;
            ts_progress_inc(prog, 1, name);
            continue;
        }

        // resolve per-channel AWQ activation scales (imatrix, else corpus)
        std::vector<float> act_scratch;
        const float * act_scales = ts_dispatch_act_scales(
            have_imatrix ? &imatrix : nullptr, name, in_dim,
            calib_X.empty() ? nullptr : calib_X.data(), calib_in_dim, calib_n_tokens,
            &act_scratch);

        // imatrix regime stats for the descriptor (nullptr when unavailable)
        const float * imdata = nullptr;
        int64_t       imdim  = 0;
        if (have_imatrix) {
            imdata = ts_imatrix_lookup(&imatrix, name, &imdim);
        }

        // compute regime descriptor and route
        ts_regime_descriptor desc = ts_regime_compute_descriptor(
            name, weights.data(), out_dim, in_dim,
            imdata, imdata ? imdim : 0);

        // Tier 2: look up learned per-family thresholds from DuckDB.
        // db_wrap is null when --tessera-db is unset or open failed;
        // the map is empty when no regime_thresholds rows exist for this model
        // yet (the static cascade is used as fallback).
        const ts_regime_family_thresholds * regime_thresholds = nullptr;
        if (db_wrap != nullptr && !family.empty()) {
            auto it = db_wrap->regime_threshold_map.find(family);
            if (it != db_wrap->regime_threshold_map.end()) {
                regime_thresholds = &it->second;
            }
        }

        // multimodal: resolve the operative modality, the per-modality AWQ
        // alpha, and the per-modality activation scales for this tensor.
        int   mm_mod        = desc.modality;
        float mm_alpha[3]   = { 0.0f, 0.0f, 0.0f };
        bool  have_mm       = false;
        bool  have_mm_alpha = false;
        if (have_mm_imatrix) {
            const ts_mm_imatrix_entry * en =
                ts_dispatch_mm_resolve(&mm_imatrix, name, desc.modality, &mm_mod);
            desc.modality = mm_mod;
            if (en != nullptr) {
                have_mm = true;
                auto it = mm_awq.find(name);
                if (it == mm_awq.end()) {
                    ts_mm_awq_result mres;
                    if (ts_dispatch_mm_awq(&mm_imatrix, name, weights.data(),
                                           out_dim, in_dim, &mres) == 0) {
                        it = mm_awq.emplace(name, std::move(mres)).first;
                    }
                }
                if (it != mm_awq.end()) {
                    for (int m = 0; m < 3; m++) {
                        mm_alpha[m] = it->second.best_alpha[m];
                    }
                    have_mm_alpha = true;
                }
                // per-modality act_scales for the operative modality override the
                // text rollup so the quantizer's act_scale field is modality-specific
                int64_t ad = 0;
                const float * ma = ts_mm_imatrix_act_scales(
                    &mm_imatrix, name, (ts_modality)mm_mod, &ad);
                if (ma != nullptr && ad == in_dim) {
                    act_scales = ma;
                }
            }
        }

        ts_regime_routing routing = ts_regime_classify(&desc, regime_thresholds);

        // per-tensor alpha: per-modality MM alpha > GA result > default
        float tensor_alpha;
        if (have_mm && have_mm_alpha) {
            tensor_alpha = mm_alpha[mm_mod];
        } else if (need_ga && ga_alpha.count(name)) {
            // .at(), not operator[]: ga_alpha is now a const& (walk never
            // inserts into it), and the .count() guard above already
            // proves the key exists, so this is behaviorally identical to
            // the original operator[] access -- never a fresh insertion.
            tensor_alpha = ga_alpha.at(name);
        } else {
            tensor_alpha = default_alpha;
        }

        // apply the routed expert's profile to a per-tensor copy of the base
        // params (qparams is shared across the loop, so never mutate it here)
        ts_expert_profile  profile = ts_expert_default_profile(routing.expert, desc.modality);
        ts_quant_params_2d tqp     = qparams;
        tqp.alpha           = tensor_alpha * profile.alpha_scale;
        tqp.clip           *= profile.clip_scale;
        tqp.use_septq       = profile.use_septq;
        tqp.awq_grid        = profile.awq_grid;
        tqp.max_outliers    = profile.max_outliers;
        tqp.outlier_thresh *= profile.outlier_thresh;

        // Apply the calibration policy when one was loaded. The matched
        // family's AWQ + Tessera genes override the routed profile so the
        // runtime consumes Python's output natively (no Python pre-step).
        // moment_mix / tail_guard / ternary_threshold are surfaced via the
        // result for the candidate evaluator; the fields that map onto
        // ts_quant_params_2d (alpha/clip/outlier_thresh) are applied here.
        const ts_policy_tensor * pfam = have_policy
            ? ts_policy_select(policy.tensors, name) : nullptr;
        if (pfam != nullptr) {
            tqp.alpha         = pfam->genes.alpha;
            tqp.clip          = pfam->genes.clip;
            // dispatch already treats outlier_frac as the selection threshold
            // (params->outlier_frac -> qparams.outlier_thresh above), so the
            // policy's outlier_fraction gene maps onto the same knob here.
            tqp.outlier_thresh = pfam->genes.outlier_fraction;
            if (verbose) {
                printf("tessera-dispatch: %s matched policy family '%s' "
                       "(exact=%d alpha=%.3f clip=%.3f frac=%.4f thresh=%.3f mix=%.3f tail=%.3f)\n",
                       name, pfam->family.c_str(), (int)pfam->exact,
                       pfam->genes.alpha, pfam->genes.clip, pfam->genes.outlier_fraction,
                       pfam->genes.ternary_threshold, pfam->genes.moment_mix,
                       pfam->genes.tail_guard);
            }
        }

        if (verbose) {
            printf("tessera-dispatch: %s family=%s modality=%d expert=%s reason='%s' "
                   "alpha=%.3f clip=%.3f grid=%d outliers=%d septq=%d\n",
                   name, family.c_str(), (int)desc.modality, ts_expert_name(routing.expert),
                   routing.reason.c_str(), tqp.alpha, tqp.clip,
                   (int)tqp.awq_grid, (int)tqp.max_outliers, (int)tqp.use_septq);
        }

        // stamp the routed expert + applied profile onto the per-tensor result
        auto fill_expert_meta = [&](ts_dispatch_tensor_result & out) {
            out.expert_id              = (int)routing.expert;
            out.expert_name            = ts_expert_name(routing.expert);
            out.profile_alpha          = tqp.alpha;
            out.profile_clip           = tqp.clip;
            out.profile_awq_grid       = (int)tqp.awq_grid;
            out.profile_max_outliers   = (int)tqp.max_outliers;
            out.profile_outlier_thresh = tqp.outlier_thresh;
            out.profile_use_septq      = tqp.use_septq;
            out.modality_id            = (int)desc.modality;
            for (int m = 0; m < 3; m++) {
                out.modality_alpha[m] = mm_alpha[m];
            }
        };

        // S9 W4A4 sidecar for this tensor (populated in the 2D branch when
        // params->w4a4 is set; MoE 3D W4A4 is deferred). w4a4_policy_json is
        // appended to the per-tensor policy / receipt entry below.
        ts_w4a4_sidecar w4a4_sc = {};
        std::string     w4a4_policy_json;

        if (n_dims == 3) {
            // MoE expert tensor: (n_experts x out_dim x in_dim)
            // Tier 3: per-expert regime routing. Each expert is a dense sub-tensor
            // with its own activation statistics; it deserves its own regime
            // routing decision (DyMoE/DynaExq SOTA: hot experts need higher precision,
            // cold experts can tolerate aggressive quantization). The routed expert for
            // expert e may differ from expert f (one expert's gate may be DartQuant
            // while its sibling is plain AWQ).
            const int64_t n_experts = ne[2];
            const int64_t stride = out_dim * in_dim;

            // Build per-expert params + store per-expert regime routing.
            // Expert 0 uses the main-loop routing (already computed above).
            // Experts 1..N compute per-slice regime from weight statistics.
            // moe_routing[i] holds (expert_idx, routing) for expert i.
            // Stored in a vector so the data survives past the regime loop scope.
            std::vector<const ts_quant_params_2d *> expert_qparams;
            expert_qparams.reserve((size_t)n_experts);
            std::vector<std::pair<int64_t, ts_regime_routing>> moe_routing;
            moe_routing.reserve((size_t)n_experts);
            std::vector<ts_regime_descriptor> moe_descs;
            moe_descs.reserve((size_t)n_experts);

            // Expert 0: already routed above from the tensor-level descriptor
            ts_quant_params_2d qp0 = tqp;  // copy (tqp is the shared loop copy)
            expert_qparams.push_back(&qp0);
            moe_routing.emplace_back(0, routing);  // main routing for expert 0
            moe_descs.push_back(desc);

            // Experts 1..N: per-slice regime from weight statistics
            for (int64_t e = 1; e < n_experts; e++) {
                const float * expert_w = weights.data() + e * stride;
                // Per-expert regime descriptor: uses weight-column kurtosis/eff_rank
                // as the activation proxy. This is the Tier 3 fallback when the
                // imatrix does not have per-expert activation slices.
                ts_regime_descriptor ed = ts_regime_compute_descriptor_for_expert(
                    name, expert_w, out_dim, in_dim,
                    (int32_t)e,          // expert_idx >= 0 → MoE path
                    nullptr, 0,          // no per-expert imatrix data yet
                    nullptr,             // no per-expert max_abs
                    0,                   // n_layers_total: MoE per-expert routing uses
                                          // weight stats (expert-level) not layer position
                    regime_thresholds);
                ts_regime_routing er = ts_regime_classify(&ed, regime_thresholds);
                ts_expert_profile ep = ts_expert_default_profile(er.expert, ed.modality);
                ts_quant_params_2d * eqp = new (std::nothrow) ts_quant_params_2d(tqp);
                if (eqp) {
                    eqp->alpha           = tqp.alpha * ep.alpha_scale;
                    eqp->clip           = tqp.clip * ep.clip_scale;
                    eqp->use_septq       = ep.use_septq;
                    eqp->awq_grid        = ep.awq_grid;
                    eqp->max_outliers   = ep.max_outliers;
                    eqp->outlier_thresh = tqp.outlier_thresh * ep.outlier_thresh;
                }
                expert_qparams.push_back(eqp);
                moe_routing.emplace_back(e, er);
                moe_descs.push_back(ed);
            }

            std::vector<ts_quant_result_2d> qresults;
            // ts_quantize_3d overload (2): per-expert params.
            // Pass &expert_qparams[0] as the array pointer (std::vector guarantees
            // contiguous storage). nullptr fallback for expert e means ts_quantize_3d
            // uses the unified tqp for that expert.
            int rc = ts_quantize_3d(weights.data(),
                                    act_scales, nullptr, nullptr, act_scales,
                                    n_experts, out_dim, in_dim, 0,
                                    &tqp, expert_qparams.data(), &qresults);
            // free the heap-allocated per-expert params
            for (int64_t e = 1; e < n_experts; e++) {
                delete expert_qparams[(size_t)e];
            }
            if (rc != 0) {
                if (err_msg) {
                    *err_msg = "ts_quantize_3d failed for " + std::string(name);
                }
                ggml_free(out_ggml_ctx);
                gguf_free(out_ctx);
                gguf_free(in_ctx);
                ggml_free(ggml_ctx);
                return 2;
            }

            // keep the expert results alive until after gguf_write_to_file
            moe_results.push_back(std::move(qresults));
            const std::vector<ts_quant_result_2d> & qr_keep = moe_results.back();

            // write per-expert clusters + Tier 4 regime routing per expert
            for (int64_t e = 0; e < n_experts; e++) {
                char exp_name[GGML_MAX_NAME];
                snprintf(exp_name, sizeof(exp_name), "%s.%lld", name, (long long)e);
                ts_gguf_write_tensor_cluster(out_ctx, out_ggml_ctx, exp_name, &qr_keep[(size_t)e], out_dim, in_dim);
                total_mse += qr_keep[(size_t)e].mse;

                // Tier 4: per-expert regime routing for DuckDB feedback loop.
                // Uses moe_routing / moe_descs vectors populated during the regime
                // loop above so the per-expert routing data stays in scope.
                if (db_wrap != nullptr && db_wrap->db != nullptr && !db_wrap->model_hash.empty()) {
                    const ts_regime_routing & er = moe_routing[(size_t)e].second;
                    const ts_regime_descriptor & ed = moe_descs[(size_t)e];

                    ts_tessera_db_regime_routing_row rr;
                    rr.model_hash          = db_wrap->model_hash;
                    rr.model_role          = params->model_role;
                    rr.name                = exp_name;
                    rr.family              = family;
                    rr.layer_depth         = ts_tessera_db_layer_depth(name);
                    rr.kurtosis            = ed.kurtosis;
                    rr.eff_rank            = ed.eff_rank;
                    rr.layer_position      = (int)ed.position;
                    rr.routed_expert       = (int)er.expert;
                    rr.expert_name         = ts_expert_name(er.expert);
                    rr.routing_confidence  = er.confidence;
                    rr.threshold_source    = er.threshold_source;
                    rr.routing_reason      = er.reason;
                    rr.modality            = (int)ed.modality;
                    rr.default_tier        = (int)ed.default_tier;
                    ts_tessera_db_upsert_regime_routing(db_wrap->db, rr, nullptr);
                }
            }

            ts_dispatch_tensor_result tr;
            tr.name    = name;
            tr.family  = family;
            tr.out_dim = out_dim;
            tr.in_dim  = in_dim;
            fill_expert_meta(tr);
            // aggregate first expert's blobs for the result struct
            if (!qr_keep.empty()) {
                tr.packed              = ts_to_bytes_u32(qr_keep[0].packed);
                tr.page_scales         = ts_to_bytes_u16(qr_keep[0].page_scales);
                tr.lane_scales         = ts_to_bytes_i8(qr_keep[0].lane_scales);
                tr.outlier_row_offsets = ts_to_bytes_i32(qr_keep[0].outlier_row_offsets);
                tr.outlier_cols        = ts_to_bytes_i32(qr_keep[0].outlier_cols);
                tr.outlier_vals        = ts_to_bytes_u16(qr_keep[0].outlier_vals);
                tr.act_scale           = ts_to_bytes_u16(qr_keep[0].act_scale);
                tr.mse                 = qr_keep[0].mse;
                tr.alpha_used          = qr_keep[0].best_alpha;
            }
            result->tensors.push_back(std::move(tr));
            n_quantized++;
            ts_progress_inc(prog, 1, name);

            if (verbose) {
                printf("tessera-dispatch: quantized %s (3D, %lld experts)\n",
                       name, (long long)n_experts);
            }
        } else {
            // standard 2D weight. The result lives in cluster_results (function
            // scope) so the buffers referenced by the GGUF descriptors stay
            // valid until gguf_write_to_file runs after the walk completes.
            ts_quant_result_2d &  qr = cluster_results.emplace_back();
            ts_w4a4_weight_result wres;
            wres.base = &qr;

            // W4A4 routes through the activation-aware wrapper when the
            // calibration width matches this tensor; otherwise the existing
            // weight-only path runs and (when w4a4 is on) the activation
            // metadata is still recorded from any width-matching calibration.
            const bool calib_match = params->w4a4 && !calib_X.empty() &&
                                     calib_in_dim == in_dim && calib_n_tokens > 0;
            int rc;
            if (calib_match) {
                rc = ts_w4a4_quantize_weights(weights.data(), calib_X.data(),
                                              out_dim, in_dim, calib_n_tokens,
                                              &tqp, &wcfg, &qr, &wres);
            } else {
                rc = ts_quantize_2d(weights.data(),
                                    act_scales,   // act_scales
                                    nullptr,      // calib_X
                                    nullptr,      // ref_output
                                    act_scales,   // imatrix
                                    out_dim, in_dim, 0,
                                    &tqp, &qr);
                if (rc == 0 && params->w4a4) {
                    const float * cx = (!calib_X.empty() && calib_in_dim == in_dim)
                                           ? calib_X.data() : nullptr;
                    const int64_t ct = (cx != nullptr) ? calib_n_tokens : 0;
                    ts_w4a4_detect_outliers(cx, ct, in_dim, &wcfg, &wres.outliers);
                    ts_w4a4_compute_act_scales(cx, ct, in_dim, &wcfg, &wres.scales);
                }
            }
            if (rc != 0) {
                if (err_msg) {
                    *err_msg = "ts_quantize_2d failed for " + std::string(name);
                }
                ggml_free(out_ggml_ctx);
                gguf_free(out_ctx);
                gguf_free(in_ctx);
                ggml_free(ggml_ctx);
                return 2;
            }

            ts_gguf_write_tensor_cluster(out_ctx, out_ggml_ctx, name, &qr, out_dim, in_dim);

            ts_dispatch_tensor_result tr;
            tr.name                = name;
            tr.family              = family;
            tr.out_dim             = out_dim;
            tr.in_dim              = in_dim;
            fill_expert_meta(tr);

            // Tier 4: write per-tensor regime routing for the DuckDB feedback loop.
            // One row per tensor (non-MoE). Read by Python l5_outcome.py to join
            // with l4_plan_outcome for Tier 4 OLS threshold refitting.
            if (db_wrap != nullptr && db_wrap->db != nullptr && !db_wrap->model_hash.empty()) {
                ts_tessera_db_regime_routing_row rr;
                rr.model_hash         = db_wrap->model_hash;
                rr.model_role         = params->model_role;
                rr.name               = name;
                rr.family             = family;
                rr.layer_depth        = ts_tessera_db_layer_depth(name);
                rr.kurtosis           = desc.kurtosis;
                rr.eff_rank           = desc.eff_rank;
                rr.layer_position     = (int)desc.position;
                rr.routed_expert      = (int)routing.expert;
                rr.expert_name        = ts_expert_name(routing.expert);
                rr.routing_confidence = routing.confidence;
                rr.threshold_source   = routing.threshold_source;
                rr.routing_reason     = routing.reason;
                rr.modality           = (int)desc.modality;
                rr.default_tier       = (int)desc.default_tier;
                ts_tessera_db_upsert_regime_routing(db_wrap->db, rr, nullptr);
            }

            tr.packed              = ts_to_bytes_u32(qr.packed);
            tr.page_scales         = ts_to_bytes_u16(qr.page_scales);
            tr.lane_scales         = ts_to_bytes_i8(qr.lane_scales);
            tr.outlier_row_offsets = ts_to_bytes_i32(qr.outlier_row_offsets);
            tr.outlier_cols        = ts_to_bytes_i32(qr.outlier_cols);
            tr.outlier_vals        = ts_to_bytes_u16(qr.outlier_vals);
            tr.act_scale           = ts_to_bytes_u16(qr.act_scale);
            tr.mse                 = qr.mse;
            tr.alpha_used          = qr.best_alpha;

            // S9 W4A4 sidecar metadata + per-tensor receipt entry
            if (params->w4a4) {
                tr.w4a4_enabled          = true;
                tr.w4a4_activation_bits  = wcfg.activation_bits;
                tr.w4a4_scale_mode       = ts_w4a4_scale_mode_str(wcfg.scale_mode);
                tr.w4a4_outlier_frac     = wres.outliers.frac;
                tr.w4a4_act_scale_static = wres.scales.per_tensor;
                tr.w4a4_outlier_channels = wres.outliers.channels;

                w4a4_sc.enabled          = true;
                w4a4_sc.activation_bits  = wcfg.activation_bits;
                w4a4_sc.scale_mode       = wcfg.scale_mode;
                w4a4_sc.outlier_frac     = wres.outliers.frac;
                w4a4_sc.act_scale_static = wres.scales.per_tensor;
                w4a4_sc.outlier_channels = wres.outliers.channels;
                w4a4_policy_json         = ", " + ts_w4a4_sidecar_json(&w4a4_sc);

                if (verbose) {
                    printf("tessera-dispatch: %s w4a4 outliers=%zu frac=%.5f eff_bits=%.3f\n",
                           name, wres.outliers.channels.size(), wres.outliers.frac,
                           wres.effective_bits);
                }
            }

            total_mse += qr.mse;
            result->tensors.push_back(std::move(tr));
            n_quantized++;
            ts_progress_inc(prog, 1, name);

            // Capture for the L5 refine loop (gated by params->adaptive_requantize;
            // cheap when the loop is off, since it only fires then).
            if (params->adaptive_requantize) {
                ts_dispatch_refine_entry entry;
                entry.name     = name;
                entry.family   = family;
                entry.gguf_idx = i;
                entry.out_dim  = out_dim;
                entry.in_dim   = in_dim;
                entry.qr       = &qr;  // stable: cluster_results deque element
                entry.tqp      = tqp;
                if (act_scales != nullptr) {
                    entry.act_scales_copy.assign(act_scales, act_scales + in_dim);
                }
                refine_map.emplace(name, std::move(entry));
            }

            if (verbose) {
                printf("tessera-dispatch: quantized %s (mse=%.6f alpha=%.3f)\n",
                       name, qr.mse, qr.best_alpha);
            }

            // ---- L5 scorer collection (Phase C) ----
            if (l5_scorer_enabled) {
                l5_names.push_back(name);
                // imatrix magnitude: mean |act| per tensor. act_scales is
                // the per-channel mean |activation| (imatrix, else corpus-
                // derived); the map is peak-normalized after the walk,
                // mirroring ts_l5_imatrix_magnitude's normalization.
                if (act_scales != nullptr && in_dim > 0) {
                    double s = 0.0;
                    for (int64_t c = 0; c < in_dim; c++) {
                        s += (double) std::fabs(act_scales[c]);
                    }
                    l5_imatrix_mean.push_back((float) (s / (double) in_dim));
                } else {
                    l5_imatrix_mean.push_back(0.0f);
                }
                // hessian: OBQ sensitivity of the ACTUAL quantized
                // reconstruction against the diagonal of H^{-1}. Needs a
                // calibration corpus whose width matches this tensor (the
                // same gate the pipeline uses for corpus-derived act_scales
                // and the w4a4 path). Tensors without matching data are
                // absent from the hessian map (0 contribution in combine).
                float hessian_raw = 0.0f;
                if (!calib_X.empty() && calib_in_dim == in_dim &&
                    calib_n_tokens > 0 && qr.recon.size() == (size_t) (out_dim * in_dim)) {
                    const double ridge = 1e-4;   // SEPTQ Hessian ridge default
                    const std::string h_model =
                        (db_wrap != nullptr) ? db_wrap->model_hash : std::string();
                    std::vector<float> hinv;
                    bool hit = false;
                    std::string herr;
                    if (ts_tessera_db_read_hessian_cache(
                            (db_wrap != nullptr) ? db_wrap->db : nullptr,
                            h_model, params->model_role, name, in_dim,
                            TS_L5_HESSIAN_SCORER_VERSION,
                            calib_n_tokens, ridge, &hinv, &hit, &herr) != 0) {
                        if (verbose) {
                            fprintf(stderr, "tessera-dispatch: warning: "
                                    "hessian cache read: %s\n", herr.c_str());
                        }
                    }
                    if (!hit) {
                        // Miss: factorize once per (X, in_dim) this run.
                        auto mit = l5_hinv_memo.find(in_dim);
                        if (mit != l5_hinv_memo.end()) {
                            hinv = mit->second;
                        } else {
                            std::vector<float> scratch((size_t) in_dim * in_dim, 0.0f);
                            std::vector<float> L((size_t) in_dim * in_dim, 0.0f);
                            std::vector<float> hinv_new((size_t) in_dim, 0.0f);
                            if (ts_l5_hessian_factorize_inverse(
                                    in_dim, calib_X.data(), calib_n_tokens,
                                    (float) ridge, hinv_new.data(),
                                    L.data(), scratch.data()) == 0) {
                                hinv = hinv_new;
                                l5_hinv_memo[in_dim] = hinv;
                                ts_tessera_db_append_hessian_ledger(
                                    (db_wrap != nullptr) ? db_wrap->db : nullptr,
                                    "cache_compute", h_model, params->model_role,
                                    name, in_dim, TS_L5_HESSIAN_SCORER_VERSION,
                                    calib_n_tokens, ridge, nullptr);
                                l5_hessian_n_factorized++;
                            } else {
                                // Degenerate Hessian (non-PD even with the
                                // ridge): skip the tensor, never a stale hit.
                                l5_hessian_n_skipped++;
                            }
                        }
                    } else {
                        l5_hessian_n_cached++;
                    }
                    if (!hinv.empty()) {
                        // Forward-only store under the per-name key. The
                        // first row for the key is permanent; a conflict
                        // (different corpus, earlier run) keeps the stored
                        // row and is fine — the read validated the corpus
                        // before we got here.
                        ts_tessera_db_hessian_entry he;
                        he.model_hash     = h_model;
                        he.model_role     = params->model_role;
                        he.name           = name;
                        he.in_dim         = in_dim;
                        he.scorer_version = TS_L5_HESSIAN_SCORER_VERSION;
                        he.h_inv_diag     = hinv;
                        he.n_samples      = calib_n_tokens;
                        he.ridge_fraction = ridge;
                        bool stored = false;
                        std::string werr;
                        if (ts_tessera_db_write_hessian_cache(
                                (db_wrap != nullptr) ? db_wrap->db : nullptr,
                                he, &stored, &werr) != 0 && verbose) {
                            fprintf(stderr, "tessera-dispatch: warning: "
                                    "hessian cache write: %s\n", werr.c_str());
                        }
                        // OBQ omega: mean over input rows i of
                        //   sum_j (w_ij - w_hat_ij)^2 / [H^{-1}]_ii
                        // (the same criterion ts_l5_hessian_sensitivity
                        // computes; w_hat here is the tensor's real
                        // quantized reconstruction, qr.recon).
                        double sum_omega = 0.0;
                        int64_t n_rows = 0;
                        for (int64_t r = 0; r < in_dim; r++) {
                            const float hii = hinv[(size_t) r];
                            if (hii <= 0.0f) continue;
                            const float * wrow  = weights.data() + (size_t) r * out_dim;
                            const float * wqrow = qr.recon.data() + (size_t) r * out_dim;
                            double err_i = 0.0;
                            for (int64_t c = 0; c < out_dim; c++) {
                                const float d = wrow[c] - wqrow[c];
                                err_i += (double) d * (double) d;
                            }
                            sum_omega += err_i / (double) hii;
                            n_rows++;
                        }
                        if (n_rows > 0) {
                            hessian_raw = (float) (sum_omega / (double) in_dim);
                            l5_hessian_n_scored++;
                        } else {
                            l5_hessian_n_skipped++;
                        }
                    }
                } else {
                    // No matching calibration corpus (or no reconstruction)
                    // for this tensor: absent from the hessian map.
                    l5_hessian_n_skipped++;
                }
                l5_hessian_raw.push_back(hessian_raw);
            }
        }

        // accumulate policy entry
        if (!first_policy_entry) {
            policy_json += ",\n";
        }
        first_policy_entry = false;
        policy_json += "    {\"name\": \"" + std::string(name) + "\", "
                     + "\"family\": \"" + family + "\", "
                     + "\"modality\": " + std::to_string((int)desc.modality) + ", "
                     + "\"modality_alpha\": [" + std::to_string(mm_alpha[0]) + ", "
                     + std::to_string(mm_alpha[1]) + ", "
                     + std::to_string(mm_alpha[2]) + "], "
                     + "\"expert\": " + std::to_string((int)routing.expert) + ", "
                     + "\"expert_name\": \"" + ts_expert_name(routing.expert) + "\", "
                     + "\"alpha\": " + std::to_string(tensor_alpha) + ", "
                     + "\"profile\": {"
                     + "\"alpha\": " + std::to_string(tqp.alpha) + ", "
                     + "\"clip\": " + std::to_string(tqp.clip) + ", "
                     + "\"awq_grid\": " + std::to_string(tqp.awq_grid) + ", "
                     + "\"max_outliers\": " + std::to_string(tqp.max_outliers) + ", "
                     + "\"outlier_thresh\": " + std::to_string(tqp.outlier_thresh) + ", "
                     + "\"use_septq\": " + (tqp.use_septq ? "true" : "false")
                     + "}" + w4a4_policy_json + "}";
    }

    policy_json += "\n  ]\n}";

    // ---- L5 scorer combine (Phase C, spec §9.4) ----
    // Join the per-scorer maps via ts_l5_combine per the parsed l5_scorer
    // spec, after the whole walk so the hessian map can be peak-normalized
    // over the full roster. The grad map is always empty here (the dispatch
    // does not capture output_sensitivity); the combine treats an absent
    // scorer entry as a 0 contribution, matching the shipped missing-data
    // fallback. The result lands in the l5_scorer_report_json (schema
    // llama.tessera.l5-scorer.v1) + the l5_hessian_* counters.
    if (l5_scorer_enabled && !l5_names.empty()) {
        std::vector<ts_l5_scorer_entry> spec_entries;
        std::string spec_err;
        if (ts_l5_parse_scorer_spec(params->l5_scorer, spec_entries, spec_err)) {
            // imatrix map: peak-normalized mean |act| (mirrors
            // ts_l5_imatrix_magnitude's normalization).
            ts_score_map imap;
            {
                float peak = 0.0f;
                for (size_t i = 0; i < l5_names.size(); i++) {
                    imap[l5_names[i]] = std::max(0.0f, l5_imatrix_mean[i]);
                    peak = std::max(peak, imap[l5_names[i]]);
                }
                if (peak > 0.0f) {
                    for (auto & kv : imap) kv.second /= peak;
                }
            }
            // hessian map: peak-normalized OBQ omega over the tensors that
            // got a score (zero tensors stay at zero).
            ts_score_map hmap;
            {
                float peak = 0.0f;
                for (size_t i = 0; i < l5_names.size(); i++) {
                    hmap[l5_names[i]] = std::max(0.0f, l5_hessian_raw[i]);
                    peak = std::max(peak, hmap[l5_names[i]]);
                }
                if (peak > 0.0f) {
                    for (auto & kv : hmap) kv.second /= peak;
                }
            }
            // layer map: position prior from the tensor names. The dispatch
            // has no block count, so the helper's uniform 0.5 prior applies.
            std::vector<const char *> name_ptrs;
            name_ptrs.reserve(l5_names.size());
            for (const auto & n : l5_names) name_ptrs.push_back(n.c_str());
            ts_score_map lmap = ts_l5_layer_position_prior(
                name_ptrs.data(), (int64_t) name_ptrs.size(), 0);
            ts_score_map gmap;   // grad: empty (no output_sensitivity)

            // A scorer that is empty (grad: the dispatch captures no
            // output_sensitivity) or constant across the roster (layer:
            // ts_l5_layer_position_prior returns a uniform 0.5 when the
            // block count is 0, as it is here) carries no ranking signal.
            // Including it in the normalization would spend part of the
            // weight budget on nothing and make the reported weights a lie
            // about which signals actually drove the result, so drop it and
            // renormalize over what is left. Ranking is unaffected either
            // way -- a constant is an affine shift -- but the receipt now
            // says which signals were real.
            auto is_degenerate = [](const ts_score_map & m) {
                if (m.empty()) return true;
                const float first = m.begin()->second;
                for (const auto & kv : m) {
                    if (std::fabs(kv.second - first) > 1e-12f) return false;
                }
                return true;
            };

            const ts_score_map * scorers[4];
            float weights[4];
            int n_s = 0;
            float wsum = 0.0f;
            std::vector<std::string> dropped;
            for (const auto & e : spec_entries) {
                const ts_score_map * m = nullptr;
                if (e.name == "hessian")      m = &hmap;
                else if (e.name == "imatrix") m = &imap;
                else if (e.name == "layer")   m = &lmap;
                else if (e.name == "grad")    m = &gmap;
                if (m == nullptr) continue;
                if (is_degenerate(*m)) {
                    dropped.push_back(e.name);
                    continue;
                }
                scorers[n_s] = m;
                weights[n_s] = e.weight;
                wsum += e.weight;
                n_s++;
            }
            if (wsum <= 0.0f) wsum = 1.0f;
            for (int i = 0; i < n_s; i++) weights[i] /= wsum;

            if (!dropped.empty()) {
                std::string names;
                for (size_t i = 0; i < dropped.size(); i++) {
                    if (i > 0) names += ", ";
                    names += dropped[i];
                }
                std::fprintf(stderr, "tessera-dispatch: l5-scorer: dropped %zu "
                             "scorer(s) carrying no signal (%s); weights "
                             "renormalized over the remaining %d\n",
                             dropped.size(), names.c_str(), n_s);
            }

            ts_score_map combined;
            if (n_s > 0) {
                combined = ts_l5_combine(scorers, weights, n_s);
            }

            // Report (schema llama.tessera.l5-scorer.v1): spec echo,
            // per-scorer weights, hessian counters, and the per-tensor
            // combined + per-scorer scores.
            result->l5_scorer_ran = true;
            result->l5_hessian_n_scored     = l5_hessian_n_scored;
            result->l5_hessian_n_cached     = l5_hessian_n_cached;
            result->l5_hessian_n_factorized = l5_hessian_n_factorized;
            result->l5_hessian_n_skipped    = l5_hessian_n_skipped;
            std::ostringstream rep;
            rep << "{\n"
                << "  \"schema\": \"llama.tessera.l5-scorer.v1\",\n"
                << "  \"spec\": \"" << params->l5_scorer << "\",\n"
                << "  \"weights\": {";
            {
                // Effective weights: degenerate scorers are 0 and the rest
                // are renormalized, so this echoes what actually ran.
                bool first_w = true;
                for (const auto & e : spec_entries) {
                    const bool was_dropped =
                        std::find(dropped.begin(), dropped.end(), e.name) != dropped.end();
                    if (!first_w) rep << ", ";
                    first_w = false;
                    rep << "\"" << e.name << "\": "
                        << (was_dropped ? 0.0f : e.weight / wsum);
                }
            }
            rep << "},\n"
                << "  \"dropped_scorers\": [";
            for (size_t i = 0; i < dropped.size(); i++) {
                if (i > 0) rep << ", ";
                rep << "\"" << dropped[i] << "\"";
            }
            rep << "],\n"
                << "  \"hessian\": {\"n_scored\": " << l5_hessian_n_scored
                << ", \"n_cached\": " << l5_hessian_n_cached
                << ", \"n_factorized\": " << l5_hessian_n_factorized
                << ", \"n_skipped\": " << l5_hessian_n_skipped << "},\n"
                << "  \"scores\": [";
            for (size_t i = 0; i < l5_names.size(); i++) {
                if (i > 0) rep << ",\n";
                auto c_it = combined.find(l5_names[i]);
                auto h_it = hmap.find(l5_names[i]);
                auto im_it = imap.find(l5_names[i]);
                auto l_it = lmap.find(l5_names[i]);
                rep << "    {\"name\": \"" << l5_names[i]
                    << "\", \"combined\": "
                    << (c_it != combined.end() ? c_it->second : 0.0f)
                    << ", \"hessian\": "
                    << (h_it != hmap.end() ? h_it->second : 0.0f)
                    << ", \"imatrix\": "
                    << (im_it != imap.end() ? im_it->second : 0.0f)
                    << ", \"layer\": "
                    << (l_it != lmap.end() ? l_it->second : 0.0f) << "}";
            }
            rep << "\n  ]\n}\n";
            result->l5_scorer_report_json = rep.str();
            if (verbose) {
                printf("tessera-dispatch: l5 scorer combine (spec=%s) "
                       "hessian scored=%d cached=%d factorized=%d skipped=%d\n",
                       params->l5_scorer.c_str(), l5_hessian_n_scored,
                       l5_hessian_n_cached, l5_hessian_n_factorized,
                       l5_hessian_n_skipped);
            }
        } else if (verbose) {
            fprintf(stderr, "tessera-dispatch: warning: l5_scorer spec "
                            "rejected late: %s\n", spec_err.c_str());
        }
    }

    // --- step 7a: L5 joint PPL loop (the production default) ---
    //
    // Joint forward pass across target + 3 spec drafters (DFlash,
    // DSPark, MTP) + talker, measured by per-model normalized PPL
    // delta with a per-model AND-gate at params->l5_joint_epsilon.
    // Coarse-to-fine search with adaptive slippery detection. Strict
    // mode (--tessera-l5-strict) re-evaluates the winning policy at
    // 0.25% and reports STRICT_CONVERGED or STRICT_BEST_EFFORT.
    //
    // When l5_joint_mode is true (the default), this is the active
    // L5 path. The legacy weights-only ts_dispatch_run_l5_loop is
    // retained as a fallback (--no-tessera-l5-joint); both can run
    // in the same dispatch (l5_ran for legacy, l5_joint_ran for the
    // joint path) for the transition period.
    if (params->l5_joint_mode) {
        std::string l5j_err;
        const int l5j_rc = ts_dispatch_run_l5_joint(params, result, &l5j_err);
        if (l5j_rc != 0) {
            // The joint path is the production default. If it fails,
            // log and continue; the legacy weights-only path (if
            // also enabled) is the fallback. We do not abort the
            // dispatch because L5 is a fixup layer; the underlying
            // quantization has already happened.
            if (err_msg) {
                *err_msg = std::string("L5 joint PPL: ") + l5j_err;
            }
            if (params->verbose) {
                std::fprintf(stderr, "warning: L5 joint PPL failed: %s\n",
                        l5j_err.c_str());
            }
        }
    }

    // --- step 7a-legacy: L5 adaptive requantize loop (weights-only) ---
    //
    // The fallback for when the joint PPL path did no real work.
    // Re-quantizes flagged tensors in place (refreshing the GGUF
    // descriptors via ts_gguf_repoint_tensor_cluster) and emits an
    // l5-loop.json report.
    //
    // The gate used to be `adaptive_requantize && !l5_joint_mode`,
    // which contradicted the comment above calling this the fallback:
    // l5_joint_mode is on by default, so this never ran. That mattered
    // because the joint path does NOT need models to "succeed" -- with
    // no drafter/talker paths the harness substitutes synthetic
    // all-zero-logits forwards and the search converges on nothing
    // while still setting l5_joint_ran and emitting a receipt. So an
    // ordinary quantize run (no spec-decoder GGUFs on the command
    // line, the common case) got no L5 fixup at all while reporting
    // that L5 had run.
    //
    // Now the weights-only loop runs whenever the joint path did not
    // optimize against real forwards -- because it was disabled,
    // because it failed, or because it fell back to synthetic ones.
    const bool joint_did_real_work =
        params->l5_joint_mode && result->l5_joint_ran && result->l5_joint_real_forwards;
    if (params->adaptive_requantize && !joint_did_real_work) {
        if (params->verbose && params->l5_joint_mode && !joint_did_real_work) {
            std::fprintf(stderr, "tessera-dispatch: L5 joint had no real forwards; "
                         "running the weights-only loop\n");
        }
        ts_dispatch_run_l5_loop(params, result, in_ctx, ggml_ctx, out_ggml_ctx, refine_map,
                                 db_wrap);
    }

    *out_ctx_out = out_ctx;
    *out_ggml_ctx_out = out_ggml_ctx;
    *cluster_results_out = std::move(cluster_results);
    *moe_results_out = std::move(moe_results);
    *total_mse_out = total_mse;
    *n_quantized_out = n_quantized;
    *n_skipped_out = n_skipped;
    *policy_json_out = std::move(policy_json);
    return 0;
}
