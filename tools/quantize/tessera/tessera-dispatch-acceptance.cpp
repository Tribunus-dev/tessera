//
// tessera-dispatch-acceptance.cpp
//
// Pipeline refactor phase 4: the G6 acceptance gate (step 7b), extracted
// verbatim from ts_dispatch_run's body. Per the contracts appendix:
// "acceptance module (3577-3853): static deps ts_is_quantizable,
// ts_tensor_to_f32, ts_dispatch_act_scales + the three eval paths...
// Parameterize: default_alpha, params->awq_clip/outlier_frac/evolve_seed,
// l6_tail_tau/l6_tail_weight, kf_dir resolution... imatrix + calib corpus,
// db_wrap->regime_threshold_map, prog, acceptance_config."
//
// Pure code motion: every line of logic is unchanged from the original
// inline block in tessera-dispatch.cpp, only wrapped in a function and
// given an explicit parameter list instead of implicit closure capture.
//

#include "tessera-dispatch.h"
#include "tessera-dispatch-internal.h"
#include "tessera-regime.h"
#include "tessera-imatrix.h"
#include "tessera-expert-eval.h"
#include "tessera-acceptance.h"
#include "tessera-quantize-db.h"
#include "tessera-progress.h"

#include "gguf.h"
#include "ggml.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

// Runs the G6 acceptance gate over every 2D quantizable tensor: a serial
// prep pass (collects tensor metadata + regime routing, single-threaded
// since it touches the ggml ctx), then a parallel scoring pass (PROXY tier
// for all 6 experts, kernel-direct when a sidecar dir is configured, and
// REAL tier on the held-out 20% for the 4 non-AWQ experts) via
// ts_expert_eval, then ts_acceptance_run over the collected panel.
// Populates result->acceptance / result->acceptance_ran and (when db_wrap
// is non-null) one ga_evaluations-adjacent acceptance row per tensor.
//
// imatrix may be nullptr (no imatrix loaded); calib_X may be nullptr (no
// calibration corpus). db_wrap and prog may be nullptr (ephemeral run /
// no progress reporting). Always returns 0 -- the original inline block
// has no error-return path (a tensor that fails to load its weights is
// skipped, not a hard failure).
int ts_dispatch_run_acceptance(
        const ts_dispatch_params * params,
        ts_dispatch_result * result,
        struct gguf_context * in_ctx,
        struct ggml_context * ggml_ctx,
        int64_t n_tensors,
        const ts_imatrix * imatrix,
        const float * calib_X, int64_t calib_in_dim, int64_t calib_n_tokens,
        float default_alpha,
        ts_dispatch_db * db_wrap,
        ts_progress * prog) {
    const bool verbose = params->verbose;
    result->acceptance_ran = false;
    if (!params->run_acceptance) {
        return 0;
    }

    // Two phases:
    //   (a) serial: load each 2D quantizable tensor's weights + act scales
    //       (touches the ggml ctx, must be single-threaded).
    //   (b) parallel: the ts_expert_eval PROXY-tier calls per tensor are
    //       CPU-bound and independent across tensors. Fan out across the
    //       same thread budget as the GA.
    // Acceptance gate work items: store only metadata + the ggml tensor
    // pointer (not the f32 weights). Each worker loads the tensor on
    // demand from the mmap'd GGUF, evaluates 6 experts, then frees.
    // Peak: n_threads x 180 MB instead of 254 x 180 MB = 45 GB.
    struct acc_work_item {
        std::string name;
        struct ggml_tensor * tensor;  // from mmap'd ggml_ctx; data valid
        std::vector<float> act_scratch;
        const float * act;
        int64_t out_dim, in_dim;
        ts_expert_id routed_expert;
    };
    std::vector<acc_work_item> work;
    work.reserve((size_t)n_tensors);

    const float alpha = default_alpha;
    const float clip  = params->awq_clip;
    const uint32_t seed = (uint32_t)params->evolve_seed;

    // Resolve the L1 sidecar dir for the kernel-direct t_l^2
    // measurement in the acceptance verdict (NEW, v3.1). Same
    // env-var fallback as the GA path (line ~2165). The
    // acceptance verdict's at.kernel_direct_t2 is the real
    // measurement now (was at.composite_t2 = offline proxy
    // before this fix; see spec section 11).
    std::string kf_dir_buf = params->kernel_fitness_dir;
    if (kf_dir_buf.empty()) {
        const char * env = std::getenv("LLAMA_TILE640_DEBUG_DEQUANT_DIR");
        if (env != nullptr) {
            kf_dir_buf = env;
        }
    }

    ts_progress_set_phase(prog, "accept-prep", n_tensors,
                          "collect tensors for acceptance gate");
    for (int64_t i = 0; i < n_tensors; i++) {
        const char * name = gguf_get_tensor_name(in_ctx, i);
        const enum ggml_type type = gguf_get_tensor_type(in_ctx, i);
        const int64_t * ne = gguf_get_tensor_ne(in_ctx, i);
        int nd = GGML_MAX_DIMS;
        while (nd > 1 && ne[nd - 1] == 1) nd--;

        if (nd != 2 || !ts_is_quantizable(name, type, nd)) {
            ts_progress_inc(prog, 1, name);
            continue;
        }

        struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, name);
        if (!t) {
            ts_progress_inc(prog, 1, name);
            continue;
        }

        acc_work_item item;
        item.name     = name;
        item.tensor   = t;
        item.out_dim  = ne[1];
        item.in_dim   = ne[0];
        item.act = ts_dispatch_act_scales(
            imatrix, name, item.in_dim,
            calib_X, calib_in_dim, calib_n_tokens,
            &item.act_scratch);

        // Regime descriptor needs the weights for kurtosis/eff_rank.
        // Load temporarily, compute, free.
        {
            std::vector<float> w = ts_tensor_to_f32(t);
            if (w.empty()) {
                ts_progress_inc(prog, 1, name);
                continue;
            }
            ts_regime_descriptor desc = ts_regime_compute_descriptor(
                name, w.data(), item.out_dim, item.in_dim, nullptr, 0);
            // Tier 2: look up learned thresholds (same pattern as the main loop)
            const std::string fam = ts_regime_infer_family(name);
            const ts_regime_family_thresholds * regime_thresholds = nullptr;
            if (db_wrap != nullptr && !fam.empty()) {
                auto it = db_wrap->regime_threshold_map.find(fam);
                if (it != db_wrap->regime_threshold_map.end()) {
                    regime_thresholds = &it->second;
                }
            }
            ts_regime_routing routing = ts_regime_classify(&desc, regime_thresholds);
            item.routed_expert = routing.expert;
        }

        work.push_back(std::move(item));
        ts_progress_inc(prog, 1, name);
    }

    std::vector<ts_acceptance_tensor> acc_tensors(work.size());

    // Fallback telemetry (phase-1 known issue): a REAL/KERNEL_DIRECT
    // request that ts_expert_eval could not deliver still returns a
    // usable proxy t2 (see tessera-expert-eval.h), but a SILENT
    // fallback in a REAL-tier call is exactly what produced the
    // ambiguous "rot came back EXACTLY equal to awq" measurement this
    // seam exists to resolve -- count and report it instead of losing
    // it. Counted across both the serial and threaded branches below
    // (only one runs per acceptance pass).
    std::atomic<int64_t> real_tier_fallbacks(0);

    // Parallel PROXY-tier re-quantize per tensor. Each worker loads the
    // tensor from the mmap'd GGUF on demand (streaming), evaluates 5
    // experts via ts_quantize_mse_streaming (132 KB scratch each), then
    // the loaded weights go out of scope. Peak: 4 x 180 MB + 4 x 132 KB.
    ts_progress_set_phase(prog, "accept-run", (int64_t)work.size(),
                          "acceptance gate (5 experts per tensor, streaming)");

    const int32_t acc_threads = std::max(1, std::min(
        (int32_t) std::thread::hardware_concurrency(),
        std::min((int32_t)8, (int32_t)work.size())));

    // Pre-mark the held-out set (trailing 20%, min 1) so the Tier-2
    // real-expert panel runs exactly on the tensors the gate means
    // over. ts_acceptance_run respects explicit held_out marks and
    // only falls back to its own trailing-fraction selection when
    // none are set.
    const int64_t acc_heldout_cutoff = (int64_t)work.size()
        - std::max<int64_t>(1, (int64_t)(0.2 * (double)work.size()));

    // Pipeline refactor phase 3 ("KV-joint plumbing"): fold the
    // panel's active KV cache codec into every eval_opts.kv_codec_digest
    // below, so a run under a non-default -l5-joint-ctk/-ctv produces
    // eval_cache rows distinct from a plain f16 run of the same
    // tensor/params (ts_eval_digest_params, tessera-expert-eval.cpp,
    // already folds this field in -- it just needs a real value here).
    // Empty when both are unset/default, matching the "" = weights-
    // only convention the seam already documents.
    std::string acc_kv_codec_digest;
    if (!params->l5_joint_type_k.empty() || !params->l5_joint_type_v.empty() ||
        !params->l5_joint_type_k_draft.empty() || !params->l5_joint_type_v_draft.empty()) {
        const std::string k = params->l5_joint_type_k.empty() ? "f16" : params->l5_joint_type_k;
        const std::string v = params->l5_joint_type_v.empty() ? "f16" : params->l5_joint_type_v;
        acc_kv_codec_digest = "ctk=" + k + ",ctv=" + v;
        if (!params->l5_joint_type_k_draft.empty() || !params->l5_joint_type_v_draft.empty()) {
            const std::string kd = params->l5_joint_type_k_draft.empty() ? "f16" : params->l5_joint_type_k_draft;
            const std::string vd = params->l5_joint_type_v_draft.empty() ? "f16" : params->l5_joint_type_v_draft;
            acc_kv_codec_digest += ",ctkd=" + kd + ",ctvd=" + vd;
        }
    }

    // Score one tensor's full panel (PROXY for all 5 experts, the
    // kernel-direct measurement, and -- for held-out tensors -- REAL
    // tier for the 4 non-AWQ experts). Shared by the serial and
    // threaded branches below so the two paths cannot drift (the
    // l4_cols drift-class bug this codebase has hit once already,
    // tessera-quantize-db.cpp gotchas, is exactly what duplicated
    // per-branch logic risks).
    auto score_one = [&](const acc_work_item & item, const float * w,
                         int64_t n_w, bool held_out) -> ts_acceptance_tensor {
        ts_acceptance_tensor at;
        memset(&at, 0, sizeof(at));
        snprintf(at.name, sizeof(at.name), "%s", item.name.c_str());

        ts_eval_tensor_ctx ectx;
        ectx.name       = item.name.c_str();
        ectx.weights    = w;
        ectx.act_scales = item.act;
        ectx.out_dim    = item.out_dim;
        ectx.in_dim     = item.in_dim;
        // Eval cache (phase 2): same null-guarded pattern every other
        // db_wrap consumer in this file uses. A re-dispatch of the
        // same model (same model_hash) reuses every PROXY/REAL score
        // instead of recomputing -- this is the panel's biggest
        // deterministic win per docs/tessera-eval-cache-design.md.
        if (db_wrap != nullptr && db_wrap->db != nullptr &&
            !db_wrap->model_hash.empty()) {
            ectx.model_hash = db_wrap->model_hash;
            ectx.model_role = params->model_role;
            ectx.db         = db_wrap->db;
        }

        ts_eval_opts popts;
        popts.tier  = TS_EVAL_PROXY;
        popts.alpha = alpha;
        popts.clip  = clip;
        popts.seed  = seed;
        popts.kv_codec_digest = acc_kv_codec_digest;

        ts_eval_result er;
        ts_expert_eval(item.routed_expert, ectx, popts, &er); at.composite_t2 = er.t2;
        ts_expert_eval(TS_EXPERT_AWQ,       ectx, popts, &er); at.awq_t2       = er.t2;
        ts_expert_eval(TS_EXPERT_DARTQUANT, ectx, popts, &er); at.rotation_t2  = er.t2;
        ts_expert_eval(TS_EXPERT_FLRQ,      ectx, popts, &er); at.lowrank_t2   = er.t2;
        ts_expert_eval(TS_EXPERT_SEPTQ,     ectx, popts, &er); at.hessian_t2   = er.t2;
        ts_expert_eval(TS_EXPERT_CHAMPQ,    ectx, popts, &er); at.champq_t2    = er.t2;
        at.offline_proxy_mse = at.composite_t2;

        // Real kernel-direct t2 from the L1 sidecar when one is
        // configured; ts_expert_eval's KERNEL_DIRECT tier falls back
        // to REAL (not the offline proxy) when a sidecar is missing or
        // malformed for a SPECIFIC tensor, which is the right behavior
        // for that rare per-tensor case -- but calling it at all when
        // no sidecar dir is configured for the whole run would turn
        // every tensor's kernel-direct measurement into an expensive
        // REAL-tier computation. Match the original cost profile: only
        // invoke KERNEL_DIRECT when a sidecar dir is actually set,
        // otherwise reuse the composite proxy directly (identical to
        // the pre-seam behavior).
        if (!kf_dir_buf.empty()) {
            ts_eval_opts kopts = popts;
            kopts.tier = TS_EVAL_KERNEL_DIRECT;
            kopts.l6_tail_tau    = params->l6_tail_tau;
            kopts.l6_tail_weight = params->l6_tail_weight;
            ts_eval_tensor_ctx kctx = ectx;
            kctx.sidecar_dir = kf_dir_buf.c_str();
            ts_eval_result kr;
            ts_expert_eval(item.routed_expert, kctx, kopts, &kr);
            at.kernel_direct_t2 = kr.t2;
        } else {
            at.kernel_direct_t2 = at.composite_t2;
        }

        at.held_out = held_out;
        // Tier-2 real panel on the held-out set: every expert but AWQ
        // (REAL == PROXY for AWQ by construction, already computed
        // above). ts_expert_eval always returns a usable t2 even when
        // the real algorithm fails (falls back to the same proxy value
        // this tensor already has), so the overwrite is unconditional;
        // the fallback is still counted via aux for the phase-1 known
        // issue on silent proxy fallbacks.
        if (held_out) {
            ts_eval_opts ropts = popts;
            ropts.tier = TS_EVAL_REAL;
            ts_eval_result rr;
            ts_expert_eval(TS_EXPERT_DARTQUANT, ectx, ropts, &rr); at.rotation_t2 = rr.t2;
            if (strstr(rr.aux, "\"fallback\"") != nullptr) real_tier_fallbacks.fetch_add(1, std::memory_order_relaxed);
            ts_expert_eval(TS_EXPERT_FLRQ,      ectx, ropts, &rr); at.lowrank_t2  = rr.t2;
            if (strstr(rr.aux, "\"fallback\"") != nullptr) real_tier_fallbacks.fetch_add(1, std::memory_order_relaxed);
            ts_expert_eval(TS_EXPERT_SEPTQ,     ectx, ropts, &rr); at.hessian_t2  = rr.t2;
            if (strstr(rr.aux, "\"fallback\"") != nullptr) real_tier_fallbacks.fetch_add(1, std::memory_order_relaxed);
            ts_expert_eval(TS_EXPERT_CHAMPQ,    ectx, ropts, &rr); at.champq_t2   = rr.t2;
            if (strstr(rr.aux, "\"fallback\"") != nullptr) real_tier_fallbacks.fetch_add(1, std::memory_order_relaxed);
        }
        (void)n_w;
        return at;
    };

    if (acc_threads <= 1 || work.size() < 2) {
        for (size_t idx = 0; idx < work.size(); idx++) {
            const auto & item = work[idx];
            std::vector<float> w = ts_tensor_to_f32(item.tensor);
            if (w.empty()) continue;
            acc_tensors[idx] = score_one(item, w.data(), (int64_t)w.size(),
                                         (int64_t)idx >= acc_heldout_cutoff);
            ts_progress_inc(prog, 1, item.name.c_str());
        }
    } else {
        std::atomic<size_t> next_idx(0);
        auto acc_worker = [&]() {
            for (;;) {
                size_t idx = next_idx.fetch_add(1, std::memory_order_relaxed);
                if (idx >= work.size()) return;
                const auto & item = work[idx];
                // Load weights from mmap'd GGUF on demand.
                std::vector<float> w = ts_tensor_to_f32(item.tensor);
                if (w.empty()) continue;
                acc_tensors[idx] = score_one(item, w.data(), (int64_t)w.size(),
                                             (int64_t)idx >= acc_heldout_cutoff);
                ts_progress_inc(prog, 1, item.name.c_str());
            }
        };
        std::vector<std::thread> pool;
        pool.reserve((size_t)acc_threads);
        for (int32_t t = 0; t < acc_threads; t++) pool.emplace_back(acc_worker);
        for (auto & th : pool) th.join();
    }
    // work is destroyed here; acc_tensors owns the results.

    if (real_tier_fallbacks.load(std::memory_order_relaxed) > 0) {
        fprintf(stderr,
               "tessera-dispatch: acceptance: %lld REAL-tier call(s) fell back to "
               "proxy scoring (see each tensor's Tier-2 aux for the reason; rerun "
               "with --verbose or inspect the acceptance report)\n",
               (long long)real_tier_fallbacks.load(std::memory_order_relaxed));
    }

    if (!acc_tensors.empty()) {
        // Margin floor (option B element): an unset/zero-initialized
        // config gets the 2% default; TESSERA_G6_MARGIN overrides
        // (0 disables the floor explicitly).
        ts_acceptance_config acfg = params->acceptance_config;
        if (acfg.margin <= 0.0f) {
            acfg.margin = 0.02f;
        }
        {
            const char * menv = std::getenv("TESSERA_G6_MARGIN");
            if (menv != nullptr && menv[0] != '\0') {
                const float m = (float)atof(menv);
                if (m >= 0.0f && m < 1.0f) {
                    acfg.margin = m;
                }
            }
        }
        ts_acceptance_run(&acfg,
                          acc_tensors.data(), (int64_t)acc_tensors.size(),
                          &result->acceptance);
        result->acceptance_ran = true;
        if (verbose) {
            printf("tessera-dispatch: acceptance: %s\n", result->acceptance.verdict);
        }
        // Persist per-tensor acceptance rows. The verdict is the same
        // string the gate emits at the run level; per-tensor verdict
        // would need an extra ts_acceptance API, so we record the t2
        // breakdown (the part useful for offline analysis).
        if (db_wrap != nullptr) {
            for (const auto & at : acc_tensors) {
                ts_tessera_db_acceptance arec;
                arec.run_id       = db_wrap->run_id;
                arec.tensor_name  = at.name;
                arec.family       = ts_regime_infer_family(at.name);
                arec.composite_t2 = at.composite_t2;
                arec.awq_t2       = at.awq_t2;
                arec.rotation_t2  = at.rotation_t2;
                arec.lowrank_t2   = at.lowrank_t2;
                arec.hessian_t2   = at.hessian_t2;
                arec.verdict      = result->acceptance.composite_wins
                                        ? "pass" : "fail";
                std::string aerr;
                if (ts_tessera_db_insert_acceptance(db_wrap->db, arec, &aerr) != 0
                    && !aerr.empty()) {
                    fprintf(stderr, "tessera-dispatch: warning: "
                                    "insert_acceptance('%s') failed: %s\n",
                            at.name, aerr.c_str());
                }
            }
        }
    }
    return 0;
}
