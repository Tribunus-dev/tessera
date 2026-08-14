//
// tessera-dispatch-gaprep.cpp
//
// Pipeline refactor phase 4: the GA-prep walk (steps 5b HIGGS estimation
// + 5c the evolutionary per-tensor alpha search), extracted verbatim from
// ts_dispatch_run's body. Per the contracts appendix's ga-prep module
// notes: depends on the shared helpers (moved to tessera-dispatch-
// common.cpp), the ts_ga_weight_loader struct (function-local, unchanged),
// and ts_dispatch_awq_eval (the GA callback -- stays in tessera-
// dispatch.cpp since it is not itself part of the walk/gaprep/acceptance
// split and every module can already call it via the internal header).
// Outputs consumed later: ga_alpha (-> walk's per-tensor alpha priority),
// mm_awq (-> walk's multimodal branch, which also extends this same map
// for tensors gaprep did not resolve -- hence the non-const reference
// out-param rather than a return-by-value). mm_modality and the MAP-
// Elites archive stay fully internal: mm_modality only feeds this
// function's own eval_ctx, and result->archive_json is written directly
// here (step 10's "was archive populated" check in ts_dispatch_run now
// reads !result->archive_json.empty() instead of a separate have_archive
// out-param -- ts_archive_to_json always returns non-empty JSON once
// ts_archive_init has run, so this is an exact substitution).
//
// Pure code motion: every line of logic below the "gaprep body" marker
// is unchanged from the original inline block, only wrapped in a
// function and given an explicit parameter list. ga_alpha and mm_awq are
// declared by the extracted body itself (matching the original), not
// pre-declared here, so the footer just moves them into the out-params.
// Runs unconditionally (matching the original: step 5b's HIGGS
// estimation always ran; step 5c's real work was already gated by an
// inline `if (need_ga)`, which stays as an inline check here, re-derived
// from params exactly as tessera-dispatch-walk.cpp does).
//

#include "tessera-dispatch.h"
#include "tessera-dispatch-internal.h"
#include "tessera-quant.h"
#include "tessera-regime.h"
#include "tessera-imatrix.h"
#include "tessera-mm-imatrix.h"
#include "tessera-mm-awq.h"
#include "tessera-mm-fitness.h"
#include "tessera-awq.h"
#include "tessera-awq-fitness.h"
#include "tessera-higgs.h"
#include "tessera-higgs-cache.h"
#include "tessera-search.h"
#include "tessera-archive.h"
#include "tessera-ab-harness.h"
#include "tessera-l1-fitness.h"
#include "tessera-quantize-db.h"
#include "tessera-progress.h"
#include "tessera-vec.h"
#include "tessera-activation-sidecar.h"
#include "tessera-kv-migrate.h"

#include "gguf.h"
#include "ggml.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// See the file header above for the parameter-naming rationale. Returns
// 0 on success; 4 on a HIGGS cache-only miss, 5 on ts_awq_evolve_all
// failure -- matching ts_dispatch_run's original return codes for these
// paths exactly (both error paths, preserved verbatim below, already
// free in_ctx/ggml_ctx before returning, so a non-zero return here means
// the caller must NOT free them again).
int ts_dispatch_run_gaprep(
        const ts_dispatch_params * params,
        ts_dispatch_result * result,
        std::string * err_msg,
        struct gguf_context * in_ctx,
        struct ggml_context * ggml_ctx,
        int64_t n_tensors,
        bool have_imatrix, const ts_imatrix & imatrix,
        bool have_mm_imatrix, const ts_mm_imatrix & mm_imatrix,
        const std::vector<float> & calib_X, int64_t calib_in_dim, int64_t calib_n_tokens,
        ts_dispatch_db * db_wrap,
        ts_progress * prog,
        std::unordered_map<std::string, float> * ga_alpha_out,
        std::unordered_map<std::string, ts_mm_awq_result> * mm_awq_out) {
    const bool verbose = params->verbose;
    const bool need_ga = params->policy_path.empty();

    // --- step 3: GA configuration (moved from tessera-dispatch.cpp;
    // evolve_params has no reader outside gaprep) ---
    ts_awq_evolve_params evolve_params;
    evolve_params.population         = params->evolve_population > 0 ? params->evolve_population : 32;
    evolve_params.generations        = params->evolve_iters > 0 ? params->evolve_iters : 100;
    evolve_params.islands            = params->evolve_islands > 0 ? params->evolve_islands : 4;
    evolve_params.migration_interval = 10;
    evolve_params.mutation_sigma     = 0.1f;
    evolve_params.crossover_rate     = 0.7f;
    evolve_params.heldout_weight     = 2.0f;
    evolve_params.seed               = (uint32_t)params->evolve_seed;
    evolve_params.verbose            = verbose;
    // Early termination: stop a tensor's GA after `stagnation_limit`
    // consecutive flat generations (velocity gate, see
    // tessera-convergence.h). The window MUST be smaller than the
    // generation budget or the gate can never fire: the previous default
    // (10) on the production 8-generation budget was mathematically
    // unreachable, and the exit path papered over it by marking tensors
    // converged anyway. Measured consequence on the talker run: every
    // tensor's best was found at initialization and 8 generations of
    // evolution bought zero improvement, at full cost. A window of 2
    // stops after two flat transitions (patience-2); a tensor that is
    // genuinely climbing keeps its full budget. NOTE also
    // seed_accept_ratio below: the talker run averaged 2,112 evals/tensor
    // with every tensor warm-started, so the one-shot accept apparently
    // never fired -- audit its ratio test against negative composites.
    evolve_params.stagnation_limit   = 2;
    evolve_params.velocity_threshold     = 1e-5f;
    evolve_params.acceleration_threshold = 2e-5f;
    // One-shot family hypothesis test: accept a family seed if this tensor's
    // eval scores within 95% of the seed's original composite. This skips the
    // GA entirely for tensors that share the family optimum (most of them in a
    // transformer), costing 1 eval instead of 640+.
    evolve_params.seed_accept_ratio = 0.95f;
    evolve_params.seed_composite    = 0.0f;  // populated per-layer by evolve_all
    // TESSERA_STAGNATION_LIMIT overrides the default early-termination window
    // (flat generations before the velocity gate fires). Useful for tests that
    // need to force convergence on small fixtures, and for users who want to
    // tune the GA's exploration/exploitation trade-off.
    {
        const char * env = std::getenv("TESSERA_STAGNATION_LIMIT");
        if (env != nullptr && env[0] != '\0') {
            int parsed = std::atoi(env);
            if (parsed > 0) evolve_params.stagnation_limit = parsed;
        }
    }
    evolve_params.seed_candidate     = nullptr;  // set per-layer by evolve_all
    // Threading model: "serial layers, parallel candidates". One layer is
    // loaded at a time (180 MB weight buffer shared read-only); all threads
    // evaluate different candidates from the GA population in parallel. This
    // keeps peak memory at 1 weight buffer + n_threads scratch buffers
    // instead of n_threads x (weight + scratch), which is critical on memory-
    // constrained systems (16 GB M1 with an 8 GB model).
    //
    // TESSERA_QUANTIZE_THREADS controls both the layer-parallel thread count
    // (n_threads, used by evolve_all's work queue) and the candidate-parallel
    // thread count (n_eval_threads, used inside each ts_awq_evolve call).
    // On memory-constrained systems, set n_threads=1 so only one layer is
    // loaded at a time, and let n_eval_threads parallelize the candidates.
    {
        int32_t n_threads = 0;
        const char * env = std::getenv("TESSERA_QUANTIZE_THREADS");
        if (env != nullptr && env[0] != '\0') {
            int parsed = std::atoi(env);
            if (parsed > 0) {
                n_threads = parsed;
            } else if (parsed == 0) {
                n_threads = 1;  // explicit "0" disables threading
            }
        }
        if (n_threads == 0) {
            unsigned int hw = std::thread::hardware_concurrency();
            n_threads = hw > 0 ? (int32_t)hw : 1;
            if (n_threads > 8) {
                n_threads = 8;
            }
        }
        // On systems with limited memory, prefer serial layers + parallel
        // candidates. The TESSERA_QUANTIZE_LAYERS env var overrides: set to
        // >1 to enable layer-level parallelism (uses more memory).
        int32_t n_layer_threads = 1;  // serial by default (one layer at a time)
        const char * lenv = std::getenv("TESSERA_QUANTIZE_LAYERS");
        if (lenv != nullptr && lenv[0] != '\0') {
            int parsed = std::atoi(lenv);
            if (parsed > 0) n_layer_threads = parsed;
        }
        evolve_params.n_threads      = n_layer_threads;
        evolve_params.n_eval_threads = n_threads;
    }

    if (need_ga) {
        if (verbose) {
            printf("tessera-dispatch: GA configured (seed=%llu iters=%d islands=%d pop=%d layer_threads=%d eval_threads=%d)\n",
                   (unsigned long long)params->evolve_seed,
                   params->evolve_iters,
                   params->evolve_islands,
                   params->evolve_population,
                   evolve_params.n_threads,
                   evolve_params.n_eval_threads);
        }
    }

    // --- step 5b: HIGGS alpha_l estimation / cache lookup ---
    std::string higgs_mode = params->higgs_alpha_mode.empty() ? "uniform" : params->higgs_alpha_mode;
    std::vector<float> higgs_alphas;   // empty = uniform
    bool higgs_active = false;

    if (higgs_mode != "uniform") {
        // collect quantizable tensor weights for cache key
        std::vector<const float *> higgs_wptrs;
        std::vector<int64_t> higgs_outs, higgs_ins;
        std::vector<std::vector<float>> higgs_wbufs;

        ts_progress_set_phase(prog, ts_progress_phase::HIGGS, n_tensors,
                              "alpha_l estimation");
        for (int64_t i = 0; i < n_tensors; i++) {
            const char * name = gguf_get_tensor_name(in_ctx, i);
            const enum ggml_type type = gguf_get_tensor_type(in_ctx, i);
            const int64_t * ne = gguf_get_tensor_ne(in_ctx, i);
            int nd = GGML_MAX_DIMS;
            while (nd > 1 && ne[nd - 1] == 1) nd--;

            if (!ts_is_quantizable(name, type, nd)) continue;

            struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, name);
            if (!t) continue;

            higgs_wbufs.push_back(ts_tensor_to_f32(t));
            if (higgs_wbufs.back().empty()) {
                higgs_wbufs.pop_back();
                continue;
            }
            higgs_wptrs.push_back(higgs_wbufs.back().data());
            higgs_outs.push_back(ne[1]);
            higgs_ins.push_back(ne[0]);
            ts_progress_inc(prog, 1, name);
        }
        ts_progress_inc(prog, n_tensors - (int64_t)higgs_wptrs.size(), nullptr);

        if (!higgs_wptrs.empty()) {
            ts_higgs_cache_key ckey = ts_higgs_cache_compute_key(
                higgs_wptrs.data(), higgs_outs.data(), higgs_ins.data(),
                (int64_t)higgs_wptrs.size());

            const std::string * cdir = params->higgs_cache_dir.empty()
                ? nullptr : &params->higgs_cache_dir;

            auto cached = ts_higgs_cache_load(&ckey, cdir);
            if (cached.has_value()) {
                higgs_alphas = std::move(cached.value());
                higgs_active = true;
                if (verbose) {
                    printf("tessera-dispatch: HIGGS cache hit (%lld layers, hash=%s...)\n",
                           (long long)higgs_alphas.size(), ckey.hex.substr(0, 12).c_str());
                }
            } else if (higgs_mode == "cache-only") {
                if (err_msg) {
                    *err_msg = "HIGGS cache miss and mode is cache-only (hash=" + ckey.hex + ")";
                }
                gguf_free(in_ctx);
                ggml_free(ggml_ctx);
                return 4;
            } else {
                // mode == "auto": estimation requires a model forward-pass
                // callback (metric_fn) not available in the standalone
                // dispatch. The offline harness (alpha_calibrate.py) produces
                // the cache artifact; log and fall back to uniform.
                if (verbose) {
                    printf("tessera-dispatch: HIGGS cache miss, falling back to uniform "
                           "(run alpha_calibrate.py to populate cache, hash=%s...)\n",
                           ckey.hex.substr(0, 12).c_str());
                }
            }
        }
    }

    // build search config for the GA
    ts_search_config search_cfg;
    search_cfg.layer_alpha = higgs_active ? higgs_alphas.data() : nullptr;
    search_cfg.n_layers    = higgs_active ? (int64_t)higgs_alphas.size() : 0;

    // --- step 5c: evolutionary per-tensor alpha search (GA) ---
    // Runs the real AWQ/GA search over the 2D quantizable tensors to produce a
    // per-tensor alpha. The evaluator quantizes each candidate via
    // ts_quantize_2d; the HIGGS alpha_l weights (search_cfg) score the
    // cross-layer composite via ts_search_fitness when the layer counts match.
    std::unordered_map<std::string, float> ga_alpha;

    // per-tensor multimodal state (populated when an MM imatrix is present):
    // the per-modality AWQ result (alpha + mse) and the operative modality.
    // mm_awq is shared with the quantize loop so the alpha search runs once.
    std::unordered_map<std::string, ts_mm_awq_result> mm_awq;
    std::unordered_map<std::string, int>              mm_modality;

    // MAP-Elites archive: best policy per regime cell, populated from the GA
    // results below and persisted to a sidecar JSON alongside the policy.
    ts_map_elites_archive archive;

    if (need_ga) {
        std::vector<std::string>           ga_names;
        std::vector<std::vector<float>>    ga_wbufs;     // legacy: stays empty with streaming load
        std::vector<std::vector<float>>    ga_actbufs;   // corpus-derived act_scales storage
        // Per-layer weight loader state: holds the ggml tensor pointer (from
        // the mmap'd context) and the per-call f32 buffer. The GA worker
        // populates buf on load, clears it on release, so only ~8 layers'
        // f32 data is alive at once (one per worker thread).
        struct ts_ga_weight_loader {
            struct ggml_tensor * tensor;
            std::vector<float>   buf;
            // KV-joint reconstruction item 5 (scale migration): the fold
            // needs a DB handle to look up kv_stats, captured here (not in
            // the captureless weights_load_fn lambda's environment) since a
            // raw C function pointer cannot close over anything. Null
            // kv_db means "no --tessera-db", a safe no-op inside the fold.
            ts_tessera_db * kv_db = nullptr;
            std::string     kv_model_hash;
            std::string     kv_model_role;
        };
        std::vector<ts_ga_weight_loader>   ga_weight_loaders;
        // Streaming activation loader state (real per-tensor activation
        // capture): holds the tensor name + expected in_dim (for the
        // sidecar's shape-mismatch check) and the buffers
        // ts_activation_sidecar_load fills on demand. Same
        // reserve-before-loop discipline as ga_weight_loaders below --
        // layer.activations_user_data stores a raw pointer to
        // ga_activation_loaders.back(), so a mid-loop reallocation would
        // dangle every prior pointer.
        struct ts_ga_activation_loader {
            std::string         tensor_name;
            std::string         sidecar_dir;
            int64_t             expected_in_dim = 0;
            std::vector<float>  train_buf;
            std::vector<float>  heldout_buf;
        };
        std::vector<ts_ga_activation_loader> ga_activation_loaders;
        std::vector<ts_awq_layer>          ga_layers;
        std::vector<ts_regime_descriptor>  ga_descs;     // regime descriptor per layer (archive axes)

        ts_progress_set_phase(prog, ts_progress_phase::GA_PREP, n_tensors,
                              "collect GA layers");
        ga_weight_loaders.reserve((size_t)n_tensors);  // prevent realloc (raw ptrs stored)
        if (!params->activation_capture_dir.empty()) {
            ga_activation_loaders.reserve((size_t)n_tensors);  // same realloc hazard
        }
        ga_layers.reserve((size_t)n_tensors);
        ga_names.reserve((size_t)n_tensors);
        ga_descs.reserve((size_t)n_tensors);
        for (int64_t i = 0; i < n_tensors; i++) {
            const char * name = gguf_get_tensor_name(in_ctx, i);
            const enum ggml_type type = gguf_get_tensor_type(in_ctx, i);
            const int64_t * ne = gguf_get_tensor_ne(in_ctx, i);
            int nd = GGML_MAX_DIMS;
            while (nd > 1 && ne[nd - 1] == 1) nd--;

            // the GA evolves 2D weight matrices; 3D MoE tensors fall back to
            // default_alpha in the quantize loop below.
            if (nd != 2 || !ts_is_quantizable(name, type, nd)) continue;

            struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, name);
            if (!t) continue;

            std::vector<float> w = ts_tensor_to_f32(t);
            if (w.empty()) continue;

            const int64_t in_dim  = ne[0];
            const int64_t out_dim = ne[1];

            // KV-joint reconstruction item 5 (scale migration): fold the
            // same D/E correction the walk (production write) applies, so
            // the GA's fitness search sees the weight it will actually
            // ship. No-op when no --tessera-db is open or no kv_stats row
            // exists yet -- see tessera-kv-migrate.h.
            if (db_wrap != nullptr && db_wrap->db != nullptr) {
                ts_kv_migrate_apply_to_tensor(
                    db_wrap->db, db_wrap->model_hash, params->model_role,
                    name, w.data(), out_dim, in_dim,
                    ts_kv_migrate_params{}, nullptr);
            }

            // resolve per-channel activation scales (imatrix, else corpus);
            // a corpus-derived buffer is moved into ga_actbufs to keep the
            // pointer valid for the whole evolution.
            std::vector<float> act_scratch;
            const float * act = ts_dispatch_act_scales(
                have_imatrix ? &imatrix : nullptr, name, in_dim,
                calib_X.empty() ? nullptr : calib_X.data(), calib_in_dim, calib_n_tokens,
                &act_scratch);
            if (act != nullptr && act == act_scratch.data()) {
                ga_actbufs.push_back(std::move(act_scratch));
                act = ga_actbufs.back().data();
            }

            // regime descriptors (kurtosis / eff_rank) feed the GA archive cell
            const float * imdata = nullptr;
            int64_t       imdim  = 0;
            const float * imdata_max_abs = nullptr;
            int64_t       imdim_max_abs  = 0;
            if (have_imatrix) {
                imdata = ts_imatrix_lookup(&imatrix, name, &imdim);
                // Per-channel max |activation| (.in_maxabs) - the localized
                // outlier signal that kurtosis (a global scalar) cannot see.
                imdata_max_abs = ts_imatrix_lookup_max_abs(&imatrix, name, &imdim_max_abs);
            }
            ts_regime_descriptor desc = ts_regime_compute_descriptor(
                name, w.data(), out_dim, in_dim, imdata, imdata ? imdim : 0,
                imdata_max_abs, imdata_max_abs ? imdim_max_abs : 0);

            // Phase 2 "Layer A": frob2 + an approximate |W| quantile sketch,
            // computed once here from the same full f32 buffer the regime
            // descriptor above already scans, then reused by every later
            // consumer (the GA hot path's ts_dispatch_awq_eval below, and
            // the ts_expert_eval seam via a tensor_stats read-back) instead
            // of each redoing its own full pass. See
            // tools/quantize/tessera/tessera-quantize-db.h for why the
            // sketch is a bounded sample, not an exact sort.
            const float tensor_frob2 = ts_vec_dotpr(w.data(), w.data(), out_dim * in_dim);
            std::vector<float> tensor_absq_sketch;
            ts_tensor_stats_build_absq_sketch(w.data(), out_dim * in_dim, &tensor_absq_sketch);

            // multimodal: resolve the operative modality (drives routing + the
            // archive axis) and run the per-modality AWQ alpha search (drives
            // the modality-weighted fitness below).
            if (have_mm_imatrix) {
                int mod = desc.modality;
                const ts_mm_imatrix_entry * en =
                    ts_dispatch_mm_resolve(&mm_imatrix, name, desc.modality, &mod);
                desc.modality = mod;
                if (en != nullptr) {
                    mm_modality[name] = mod;
                    ts_mm_awq_result mres;
                    if (ts_dispatch_mm_awq(&mm_imatrix, name, w.data(), out_dim, in_dim, &mres) == 0) {
                        mm_awq[name] = std::move(mres);
                    }
                }
            }

            ga_names.push_back(name);
            // NOTE: weights are NOT stored in ga_wbufs. The f32 conversion is
            // needed only for the regime descriptor above; the GA loads weights
            // on demand via weights_load_fn to avoid holding all 254 layers'
            // f32 data in memory (~32 GB for an 8B model - fatal on 16 GB).
            // ga_wbufs is kept for API compatibility but stays empty here.

            ts_awq_layer layer;
            layer.name        = ga_names.back();
            layer.family      = desc.family;
            layer.weights     = nullptr;  // loaded on demand by the GA worker
            layer.act_scales  = act;
            layer.calib_X     = nullptr;
            layer.ref_output  = nullptr;
            layer.imatrix     = act;
            // B2 fitness: when the imatrix provides per-channel E[x^2] for
            // this tensor, expose it as second_moment so the GA evaluator can
            // run the Python parity fitness (ts_awq_evaluate_layer). The
            // fourth_moment / max_abs fields stay null and the evaluator
            // falls back to second^2 / sqrt(second), matching Python's
            // Layer.from_npz fallback when in_sum4 / in_maxabs are absent.
            // train/heldout activations: populated on demand below when
            // params->activation_capture_dir is set (a real sidecar
            // written by llama-imatrix --activation-capture); otherwise
            // left null, in which case ts_awq_evaluate_layer falls back to
            // the diagonal second-moment loss for train_error and treats
            // heldout == train, exactly as Python does when
            // train_activations is None.
            layer.second_moment       = (imdata && imdim == in_dim) ? imdata : nullptr;
            layer.fourth_moment       = nullptr;
            layer.max_abs             = nullptr;
            layer.train_activations   = nullptr;
            layer.heldout_activations = nullptr;
            layer.ref_train_output    = nullptr;
            layer.ref_heldout_output  = nullptr;
            // Streaming activation loader: must always be explicitly set
            // (even to null) rather than left to whatever
            // `ts_awq_layer layer;`'s uninitialized stack memory happens to
            // contain -- a garbage-nonzero activations_load_fn gets called
            // as a real function pointer by ts_awq_evolve_all's
            // `if (layers[i].activations_load_fn)` guard, which crashed the
            // GA worker threads (SIGSEGV) the first time this field existed.
            layer.activations_load_fn    = nullptr;
            layer.activations_release_fn = nullptr;
            layer.activations_user_data  = nullptr;
            if (!params->activation_capture_dir.empty()) {
                ga_activation_loaders.push_back(
                    {ga_names.back(), params->activation_capture_dir, in_dim, {}, {}});
                layer.activations_load_fn = [](void * ud,
                                               const float ** out_train, int64_t * out_n_tokens,
                                               const float ** out_heldout, int64_t * out_n_tokens_h,
                                               const float ** out_ref_train,
                                               const float ** out_ref_heldout) -> bool {
                    auto * al = static_cast<ts_ga_activation_loader *>(ud);
                    int64_t rows = 0, cols = 0;
                    if (ts_activation_sidecar_load(al->sidecar_dir.c_str(), al->tensor_name.c_str(),
                                                   ".act_train.f16", &al->train_buf, &rows, &cols) != 0) {
                        return false;  // no capture data for this tensor
                    }
                    if (cols != al->expected_in_dim) {
                        fprintf(stderr,
                                "tessera-dispatch: activation capture sidecar for '%s' has "
                                "in_dim=%lld, expected %lld -- ignoring (falling back to "
                                "the diagonal weight-space error for this tensor)\n",
                                al->tensor_name.c_str(), (long long)cols,
                                (long long)al->expected_in_dim);
                        al->train_buf.clear();
                        al->train_buf.shrink_to_fit();
                        return false;
                    }
                    *out_train    = al->train_buf.data();
                    *out_n_tokens = rows;

                    // Heldout is optional: a missing or mismatched heldout
                    // sidecar still lets the train-only path run (matching
                    // ts_awq_evaluate_layer's own "heldout falls back to
                    // train when absent" behavior).
                    int64_t h_rows = 0, h_cols = 0;
                    if (ts_activation_sidecar_load(al->sidecar_dir.c_str(), al->tensor_name.c_str(),
                                                   ".act_heldout.f16", &al->heldout_buf,
                                                   &h_rows, &h_cols) == 0 &&
                        h_cols == al->expected_in_dim) {
                        *out_heldout    = al->heldout_buf.data();
                        *out_n_tokens_h = h_rows;
                    } else {
                        al->heldout_buf.clear();
                        al->heldout_buf.shrink_to_fit();
                        *out_heldout    = nullptr;
                        *out_n_tokens_h = 0;
                    }
                    // ref_train_output/ref_heldout_output: not precomputed
                    // at capture time yet (a pure optimization, deferred --
                    // see the plan's stage 6); ts_awq_relative_output_error
                    // already recomputes activations @ original_weight^T on
                    // the fly when these are null.
                    *out_ref_train   = nullptr;
                    *out_ref_heldout = nullptr;
                    return true;
                };
                layer.activations_release_fn = [](void * ud) {
                    auto * al = static_cast<ts_ga_activation_loader *>(ud);
                    al->train_buf.clear();   al->train_buf.shrink_to_fit();
                    al->heldout_buf.clear(); al->heldout_buf.shrink_to_fit();
                };
                layer.activations_user_data = &ga_activation_loaders.back();
            }
            layer.out_dim     = out_dim;
            layer.in_dim      = in_dim;
            layer.n_tokens    = 0;
            layer.n_tokens_h  = 0;
            layer.kurtosis    = desc.kurtosis;
            layer.eff_rank    = desc.eff_rank;
            layer.frob2       = tensor_frob2;
            // Streaming weight loader: each GA worker calls this to fetch the
            // layer's f32 weights on demand from the mmap'd ggml context.
            // The buffer is owned per-call and freed by weights_release_fn
            // after the layer's GA completes. This keeps peak memory at
            // ~8 concurrent layers (one per worker) instead of all 254.
            layer.weights_load_fn = [](void * ud) -> const float * {
                auto * ml = static_cast<struct ts_ga_weight_loader *>(ud);
                ml->buf = ts_tensor_to_f32(ml->tensor);
                if (ml->buf.empty()) {
                    return nullptr;
                }
                // KV-joint reconstruction item 5: fold D/E so the GA's
                // fitness search sees the same weight the walk (production
                // write) ships. No-op when kv_db is null or no kv_stats row
                // exists yet -- see tessera-kv-migrate.h.
                if (ml->kv_db != nullptr) {
                    ts_kv_migrate_apply_to_tensor(
                        ml->kv_db, ml->kv_model_hash, ml->kv_model_role,
                        ggml_get_name(ml->tensor), ml->buf.data(),
                        ml->tensor->ne[1], ml->tensor->ne[0],
                        ts_kv_migrate_params{}, nullptr);
                }
                return ml->buf.data();
            };
            layer.weights_release_fn = [](void * ud, const float *) {
                auto * ml = static_cast<struct ts_ga_weight_loader *>(ud);
                ml->buf.clear();
                ml->buf.shrink_to_fit();
            };
            // NOTE: ga_weight_loaders MUST be reserved before the loop so the
            // vector never reallocates. layer.weights_user_data stores a raw
            // pointer to ga_weight_loaders.back(); a reallocation would dangle
            // every prior pointer and crash the GA workers (SIGSEGV in
            // ggml_nelements via the loader callback).
            ga_weight_loaders.push_back(ts_ga_weight_loader{});
            ga_weight_loaders.back().tensor = ggml_get_tensor(ggml_ctx, name);
            if (db_wrap != nullptr && db_wrap->db != nullptr) {
                ga_weight_loaders.back().kv_db         = db_wrap->db;
                ga_weight_loaders.back().kv_model_hash = db_wrap->model_hash;
                ga_weight_loaders.back().kv_model_role = params->model_role;
            }
            layer.weights_user_data = &ga_weight_loaders.back();
            layer.layer_depth = ts_tessera_db_layer_depth(name);
            ga_layers.push_back(layer);
            ga_descs.push_back(desc);
            // Record the tensor in the persistent registry. One row per
            // quantizable weight, with the regime descriptors (kurtosis /
            // eff_rank) computed above. Best-effort: a failure here only
            // loses metadata, never blocks quantization.
            if (db_wrap != nullptr) {
                ts_tessera_db_tensor trec;
                trec.run_id      = db_wrap->run_id;
                trec.name        = name;
                trec.family      = desc.family;
                trec.layer_depth = layer.layer_depth;
                trec.out_dim     = out_dim;
                trec.in_dim      = in_dim;
                trec.n_elements  = out_dim * in_dim;
                trec.kurtosis    = desc.kurtosis;
                trec.eff_rank    = desc.eff_rank;
                trec.source_type = ggml_type_name(type);
                std::string terr;
                if (ts_tessera_db_insert_tensor(db_wrap->db, trec, &terr) != 0
                    && !terr.empty()) {
                    fprintf(stderr, "tessera-dispatch: warning: "
                                    "insert_tensor('%s') failed: %s\n",
                            name, terr.c_str());
                }
                // Also upsert into the cross-pipeline tensor_stats
                // table (model_hash + name key). The C++ side writes
                // the kurtosis / eff_rank / dtype fields; the Python
                // calibration pipeline writes rms / mean_abs /
                // tail_ratio via the same helper. PRIMARY KEY +
                // ON CONFLICT DO UPDATE makes this safe to call
                // from both sides in any order. rms / mean_abs /
                // tail_ratio are left at 0 here (the C++ side
                // doesn't compute them); the Python side fills them
                // in on a subsequent write.
                ts_tessera_db_tensor_stat tstat;
                tstat.model_hash = db_wrap->model_hash;
                tstat.model_role = params->model_role;
                tstat.name       = name;
                tstat.family     = desc.family;
                tstat.layer_depth = layer.layer_depth;
                tstat.out_dim     = out_dim;
                tstat.in_dim      = in_dim;
                tstat.n_elements  = (int64_t)out_dim * (int64_t)in_dim;
                tstat.dtype       = ggml_type_name(type);
                tstat.kurtosis    = desc.kurtosis;
                tstat.eff_rank    = desc.eff_rank;
                tstat.rms         = 0.0;
                tstat.mean_abs    = 0.0;
                tstat.tail_ratio  = 0.0;
                tstat.source      = "cpp_quant";
                tstat.frob2         = tensor_frob2;
                tstat.absq_sketch   = tensor_absq_sketch;
                tstat.stats_version = TS_TENSOR_STATS_VERSION;
                std::string uerr;
                if (ts_tessera_db_upsert_tensor_stat(db_wrap->db, tstat, &uerr) != 0
                    && !uerr.empty()) {
                    fprintf(stderr, "tessera-dispatch: warning: "
                                    "upsert_tensor_stat('%s') failed: %s\n",
                            name, uerr.c_str());
                }
            }
            ts_progress_inc(prog, 1, name);
        }
        // Charge any filtered iterations so the bar completes.
        ts_progress_inc(prog, n_tensors - (int64_t)ga_layers.size(), nullptr);

        if (!ga_layers.empty()) {
            ts_dispatch_eval_ctx eval_ctx;
            eval_ctx.outlier_thresh = params->outlier_frac;
            eval_ctx.seed           = (uint32_t)params->evolve_seed;
            eval_ctx.verbose        = verbose;
            eval_ctx.mode_prints.store(0, std::memory_order_relaxed);
            eval_ctx.modality       = &mm_modality;

            // S5 kernel-direct fitness config. The sidecar directory defaults
            // to the runtime hook's dump dir ($LLAMA_TILE640_DEBUG_DEQUANT_DIR).
            ts_l1_fitness_default_config(&eval_ctx.l1);
            eval_ctx.l1.use_kernel_direct = params->kernel_fitness;
            eval_ctx.l1.blend_factor      = params->kernel_fitness_blend;
            std::string kf_dir = params->kernel_fitness_dir;
            if (kf_dir.empty()) {
                const char * env = std::getenv("LLAMA_TILE640_DEBUG_DEQUANT_DIR");
                if (env != nullptr) {
                    kf_dir = env;
                }
            }
            if (!kf_dir.empty()) {
                snprintf(eval_ctx.l1.sidecar_dir, sizeof(eval_ctx.l1.sidecar_dir),
                         "%s", kf_dir.c_str());
            }
            if (params->kernel_fitness && verbose) {
                printf("tessera-dispatch: kernel-fitness: enabled (blend=%.2f dir='%s')\n",
                       (double)eval_ctx.l1.blend_factor, eval_ctx.l1.sidecar_dir);
            }

            std::vector<ts_awq_evolve_result> ga_results;
            // Refine the GA progress total now that the quantizable 2D layer
            // count is known (smaller than n_tensors: excludes norms, embeds,
            // 1D/3D tensors). evolve_all will call on_phase_change when it
            // enters screening vs main evolution so the UI can distinguish
            // them; on_layer_done fires per completed layer in each phase.
            evolve_params.on_layer_done = [](int64_t, int64_t,
                                             const char * name, void * user) {
                ts_progress * p = static_cast<ts_progress *>(user);
                ts_progress_inc(p, 1, name);
            };
            evolve_params.on_layer_done_user = prog;
            evolve_params.on_phase_change = [](const char * phase,
                                               int64_t n_layers,
                                               void * user) {
                ts_progress * p = static_cast<ts_progress *>(user);
                ts_progress_set_phase(p, ts_progress_phase::GA_SCREEN,
                                      n_layers, phase);
                // The main evolution is reported as GA_EVOLVE so the UI shows
                // the right label; screen stays GA_SCREEN.
                if (std::string(phase) == "evolve") {
                    ts_progress_set_phase(p, ts_progress_phase::GA_EVOLVE,
                                          n_layers, "per-tensor alpha search");
                }
            };
            evolve_params.on_phase_change_user = prog;
            // DB hooks: per-evaluation appender, family warm-start lookup,
            // and resume skip. All three no-op when db_wrap is null.
            if (db_wrap != nullptr) {
                evolve_params.eval_recorder           = ts_dispatch_eval_recorder;
                evolve_params.eval_recorder_user      = db_wrap;
                evolve_params.family_seed_lookup      = ts_dispatch_family_seed_lookup;
                evolve_params.family_seed_lookup_user = db_wrap;
                evolve_params.layer_skip_lookup       = ts_dispatch_layer_skip;
                evolve_params.layer_skip_lookup_user  = db_wrap;
            }
            // Dynamic memory-bounded layer parallelism. The serial default
            // exists to bound peak memory (one dequant buffer resident at a
            // time), but the bound should come from the actual tensors, not
            // a constant: per-tensor GAs are independent, and pipelining
            // layers is what keeps the eval threads fed now that a
            // generation only scores its new children. Budget ~1.5 GiB of
            // concurrent F32 dequant buffers: layers in flight =
            // clamp(budget / largest_tensor_bytes, 1..4), at most half the
            // cores, never more than the layer count; per-layer eval
            // threads are rebalanced so the total stays at the requested
            // thread count. A MoE expert grid whose flattened tensor is
            // huge naturally auto-sizes back to serial.
            // TESSERA_QUANTIZE_LAYERS still overrides explicitly (applied
            // above); auto-sizing fills only the unset case. Known cost of
            // parallel layers: same-family warm-start seeds propagate less
            // often, since later tensors may start before an earlier
            // sibling finishes -- the one-shot accept still fires on
            // whatever has completed.
            if (std::getenv("TESSERA_QUANTIZE_LAYERS") == nullptr) {
                // Size from REALISTIC co-residency, not the global max: the
                // first version divided the budget by the largest tensor,
                // and one ~1.9 GiB embedding-class outlier vetoed pipelining
                // for the other 196 tensors (p90 ~100 MiB) -- run 3 stayed
                // serial and saved nothing. Realistic peak with k layers in
                // flight is ONE giant plus (k-1) typical tensors, so:
                //   k = 1 + (budget - top1) / p90   (1 when top1 > budget)
                // clamped to [1, 4] and half the cores. p90 (not max) is the
                // "typical" size; the transient where two giants co-schedule
                // is bounded by them being rare by construction (p90 cap).
                std::vector<int64_t> sizes;
                sizes.reserve(ga_layers.size());
                for (const auto & gl : ga_layers) {
                    sizes.push_back(gl.out_dim * gl.in_dim * (int64_t)sizeof(float));
                }
                std::sort(sizes.begin(), sizes.end());
                const int64_t top1 = sizes.empty() ? 1 : sizes.back();
                const int64_t p90  = sizes.empty() ? 1
                    : std::max<int64_t>(1, sizes[(size_t)((double)0.90 * (double)(sizes.size() - 1))]);
                const int64_t budget = (int64_t)3 * 1024 * 1024 * 1024;
                int32_t auto_layers = 1;
                if (top1 < budget) {
                    auto_layers = (int32_t)std::min<int64_t>(4, 1 + (budget - top1) / p90);
                }
                const unsigned int hw = std::thread::hardware_concurrency();
                const int32_t half_cores = hw > 1 ? (int32_t)(hw / 2) : 1;
                auto_layers = std::min(auto_layers, half_cores);
                auto_layers = std::min(auto_layers, (int32_t)std::max((int64_t)1, (int64_t)ga_layers.size()));
                if (auto_layers > 1) {
                    evolve_params.n_threads      = auto_layers;
                    evolve_params.n_eval_threads = std::max(1, evolve_params.n_eval_threads / auto_layers);
                    printf("tessera-dispatch: layer parallelism auto-sized to %d "
                           "(top tensor %lld MiB, p90 %lld MiB, %d eval threads per layer; "
                           "TESSERA_QUANTIZE_LAYERS overrides)\n",
                           auto_layers, (long long)(top1 >> 20), (long long)(p90 >> 20),
                           evolve_params.n_eval_threads);
                }
            }
            int rc = ts_awq_evolve_all(ga_layers.data(), (int64_t)ga_layers.size(),
                                       ts_dispatch_awq_eval, &eval_ctx,
                                       &evolve_params, &ga_results);
            if (rc != 0) {
                if (err_msg) {
                    *err_msg = "ts_awq_evolve_all failed";
                }
                gguf_free(in_ctx);
                ggml_free(ggml_ctx);
                return 5;
            }

            // per-tensor alpha + per-layer relative Frobenius error
            std::vector<float> t2(ga_results.size());
            for (size_t l = 0; l < ga_results.size(); l++) {
                ga_alpha[ga_names[l]] = ga_results[l].best.genes.alpha;
                t2[l]                 = ga_results[l].best_score.relative_frob;
            }

            // Persist GA results. The eval buffer is shared across all
            // tensors (one MPSC queue + one flusher thread), so there is
            // no per-tensor appender to close here. A periodic
            // ts_db_buffer_flush_now() at the end of every layer's GA
            // is unnecessary: the buffer's count + time triggers will
            // have already drained the eval rows. Sync-on-exit is
            // handled by the destructor when ts_dispatch_db_close
            // runs at the end of the run.
            if (db_wrap != nullptr) {
                for (size_t l = 0; l < ga_results.size(); l++) {
                    ts_tessera_db_ga_result gr;
                    gr.run_id          = db_wrap->run_id;
                    gr.tensor_name     = ga_names[l];
                    gr.family          = ga_layers[l].family;
                    gr.best_alpha      = ga_results[l].best.genes.alpha;
                    gr.best_clip       = ga_results[l].best.genes.clip;
                    gr.best_composite  = ga_results[l].best_score.composite;
                    gr.best_mse        = ga_results[l].best_score.mse;
                    gr.generations_run = (int32_t)ga_results[l].generations_run;
                    gr.n_evaluations   = ga_results[l].evaluations;
                    gr.converged       = ga_results[l].converged;
                    gr.warm_started    = ga_results[l].warm_started;
                    std::string gerr;
                    if (ts_tessera_db_insert_ga_result(db_wrap->db, gr, &gerr) != 0
                        && !gerr.empty()) {
                        fprintf(stderr, "tessera-dispatch: warning: "
                                        "insert_ga_result('%s') failed: %s\n",
                                ga_names[l].c_str(), gerr.c_str());
                    }
                }
            }

            // HIGGS-weighted pipeline composite (uniform when layer counts differ)
            ts_search_config fit_cfg;
            fit_cfg.layer_alpha = (search_cfg.n_layers == (int64_t)t2.size())
                                      ? search_cfg.layer_alpha : nullptr;
            fit_cfg.n_layers    = (int64_t)t2.size();

            // modality-weighted composite (M1) when multimodal data exists:
            // per-modality per-layer t_l^2 from the per-modality AWQ reconstruction
            // error, combined with the 0.5/0.3/0.2 weights via ts_mm_fitness_compute.
            // Missing modalities carry the text fallback (M8), so all three slots
            // are populated for every layer that has an MM AWQ result.
            float composite;
            const bool mm_composite = have_mm_imatrix && !mm_awq.empty();
            if (mm_composite) {
                const int64_t n_layers = (int64_t)t2.size();
                std::vector<float> t2_text(n_layers, 0.0f);
                std::vector<float> t2_image(n_layers, 0.0f);
                std::vector<float> t2_audio(n_layers, 0.0f);
                for (size_t l = 0; l < ga_results.size(); l++) {
                    auto it = mm_awq.find(ga_names[l]);
                    if (it != mm_awq.end()) {
                        t2_text[l]  = it->second.mse_per_modality[0];
                        t2_image[l] = it->second.mse_per_modality[1];
                        t2_audio[l] = it->second.mse_per_modality[2];
                    } else {
                        t2_text[l]  = t2[l];
                        t2_image[l] = t2[l];
                        t2_audio[l] = t2[l];
                    }
                }
                const float * t2_mm[3] = { t2_text.data(), t2_image.data(), t2_audio.data() };
                const bool present[3]  = { true, true, true };
                ts_mm_fitness_params fp = ts_mm_fitness_default_params();
                ts_mm_fitness_score fs = ts_mm_fitness_compute(
                    t2_mm, fit_cfg.layer_alpha, present, n_layers, &fp);
                composite = fit_cfg.layer_alpha ? fs.alpha_weighted : fs.composite;
            } else {
                composite = ts_search_fitness(t2.data(), &fit_cfg);
            }

            if (verbose) {
                printf("tessera-dispatch: GA done (%lld layers, composite=%.6f, higgs_weighted=%d, mm_weighted=%d)\n",
                       (long long)ga_layers.size(), composite, fit_cfg.layer_alpha != nullptr, (int)mm_composite);
            }

            // feed the GA outcomes into the MAP-Elites archive: one elite per
            // regime cell, keyed by each layer's descriptor. Fitness is the
            // HIGGS-weighted per-layer t_l^2 (lower is better).
            ts_archive_init(&archive, 5, 5, 8, 3);
            for (size_t l = 0; l < ga_results.size(); l++) {
                const float w_l     = fit_cfg.layer_alpha ? fit_cfg.layer_alpha[l] : 1.0f;
                const float fitness = w_l * t2[l];
                ts_archive_insert(&archive, &ga_descs[l], fitness,
                                  ga_results[l].best.genes.alpha, ga_results[l].best.genes.clip,
                                  ga_names[l].c_str());
            }

            ts_archive_summary as = ts_archive_summarize(&archive);
            result->archive_json = ts_archive_to_json(&archive);
            if (verbose) {
                printf("tessera-dispatch: MAP-Elites archive (%d/%d cells occupied, "
                       "mean_fitness=%.6f best=%.6f)\n",
                       as.occupied_cells, as.total_cells, as.mean_fitness, as.best_fitness);
            }

            // S5: A/B comparison of the offline proxy vs kernel-direct t_l^2,
            // reported side by side (per-tensor scores + alpha-weighted
            // composites + ranking agreement).
            if (params->kernel_fitness) {
                std::vector<ts_ab_tensor_scores> ab_scores;
                ab_scores.reserve(ga_names.size());
                for (size_t l = 0; l < ga_names.size(); l++) {
                    std::pair<float, float> pair_val;
                    if (!eval_ctx.best_pair.find_copy(ga_names[l], pair_val)) {
                        continue;
                    }
                    ts_ab_tensor_scores s;
                    s.name              = ga_names[l];
                    s.offline_proxy_mse = pair_val.first;
                    s.kernel_direct_t2  = pair_val.second;
                    s.alpha_l           = (fit_cfg.layer_alpha != nullptr)
                                              ? fit_cfg.layer_alpha[l] : 1.0f;
                    ab_scores.push_back(std::move(s));
                }
                if (!ab_scores.empty()) {
                    ts_ab_harness_params ab_params;
                    ab_params.n_heldout       = 0;   // score all tensors
                    ab_params.measure_ranking = true;
                    ab_params.verbose         = false;
                    ts_ab_harness_result ab_result;
                    if (ts_ab_run(&ab_scores, &ab_params, &ab_result) == 0 && verbose) {
                        printf("tessera-dispatch: A/B harness: %s\n", ab_result.report.c_str());
                    }
                }
            }
        }
    }

    *ga_alpha_out = std::move(ga_alpha);
    *mm_awq_out = std::move(mm_awq);
    return 0;
}
