//
// tessera-dispatch.cpp
//
// Top-level Tessera pipeline orchestrator. Loads the input GGUF, walks
// every tensor, routes quantizable weights through the regime classifier,
// quantizes via ts_quantize_2d / ts_quantize_3d, and writes the output
// GGUF with tessera metadata and policy JSON.
//

#include "tessera-dispatch.h"
#include "tessera-debug.h"
#include "tessera-quant.h"
#include "tessera-awq.h"
#include "tessera-awq-fitness.h"
#include "tessera-regime.h"
#include "tessera-gguf-writer.h"
#include "tessera-higgs.h"
#include "tessera-higgs-cache.h"
#include "tessera-search.h"
#include "tessera-imatrix.h"
#include "tessera-corpus.h"
#include "tessera-l1-fitness.h"
#include "tessera-l2-diff.h"
#include "tessera-l5.h"
#include "tessera-ab-harness.h"
#include "tessera-mm-imatrix.h"
#include "tessera-mm-fitness.h"
#include "tessera-mm-awq.h"
#include "tessera-w4a4.h"
#include "tessera-acceptance.h"
#include "tessera-expert-eval.h"
#include "tessera-policy.h"
#include "tessera-progress.h"
#include "tessera-sharded-map.h"
#include "tessera-quantize-db.h"
#include "tessera-db-buffer.h"
#include "tessera-vec.h"

#include "gguf.h"
#include "ggml.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <deque>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <atomic>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <fstream>
#include <sstream>

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
//
// Pipeline refactor phase 4: ts_to_bytes_*/ts_is_quantizable/ts_tensor_to_f32/
// ts_dispatch_act_scales/ts_dispatch_mm_resolve/ts_dispatch_mm_awq moved to
// tessera-dispatch-common.cpp (declared in tessera-dispatch-internal.h) so
// every dispatch module can call them without duplicating the logic.
#include "tessera-dispatch-internal.h"

// Fixed quantization knobs shared across all GA candidate evaluations, plus
// the S5 kernel-direct fitness state. sidecar_cache holds the kernel dequant
// per tensor (loaded once; an empty vector means no sidecar is present) so the
// evaluator does not re-read disk per candidate. best_t2 / best_pair track,
// per tensor, the best-scoring candidate's blended t_l^2 and its
// (offline, kernel-direct) components, to feed the A/B harness after evolution.
//
// The caches are sharded concurrent maps (ts_sharded_map). The GA fans
// per-tensor work across threads; each tensor is written by exactly one
// worker, but a plain unordered_map would race on rehash across different
// keys. Sharding by key hash gives lock-free operation for the common case
// (two threads touching different keys land in different shards) and a
// fine-grained lock for the rare same-shard collision. The `mode_prints`
// counter is the only remaining shared mutable state; it uses a relaxed
// atomic since the exact count does not matter (just a log-rate cap).
struct ts_dispatch_eval_ctx {
    float    outlier_thresh;
    uint32_t seed;
    ts_l1_fitness_config l1;
    bool     verbose;
    std::atomic<int> mode_prints{0};   // tensors whose fitness mode has been logged
    ts_sharded_map<std::string, std::vector<float>>      sidecar_cache;
    ts_sharded_map<std::string, float>                   best_t2;
    ts_sharded_map<std::string, std::pair<float, float>> best_pair;
    const std::unordered_map<std::string, int> * modality = nullptr;  // per-tensor operative modality (read-only)
};

// GA evaluator: quantize the layer with a candidate (alpha, clip) and score
// it. The GA maximizes `composite`, so report the negative t_l^2 (lower error
// -> higher fitness). By default t_l^2 is the offline relative Frobenius proxy
// ||W_hat - W||_F^2 / ||W||_F^2; with S5 kernel-direct fitness enabled it is
// blended with ||W_hat - dequant_kernel||_F^2 / ||W||_F^2, where
// dequant_kernel is the tensor's L1 sidecar (the kernel's real output).
//
// B2: when the layer carries per-channel second_moment telemetry (the imatrix
// E[x^2]), the evaluator additionally computes the Python parity fitness
// (ts_awq_evaluate_layer, a faithful port of awq-evolve.py:_evaluate_layer)
// and uses its train_error as the composite driver. This makes the GA
// optimize the same reconstruction-error objective Python's _evaluate_uncached
// optimizes, instead of the offline Frobenius proxy. The S5 kernel-direct
// path still runs (and still feeds the A/B harness) when use_kernel_direct is
// set, but the composite reported back to the GA is the Python fitness so
// the two stay aligned.
static ts_awq_score ts_dispatch_awq_eval(const ts_awq_candidate * cand,
                                         const ts_awq_layer * layer,
                                         void * ctx) {
    ts_dispatch_eval_ctx * ec = (ts_dispatch_eval_ctx *)ctx;

    ts_awq_score score;
    score.mse           = std::numeric_limits<float>::infinity();
    score.relative_frob = std::numeric_limits<float>::infinity();
    score.heldout_mse   = std::numeric_limits<float>::infinity();
    score.composite     = -std::numeric_limits<float>::infinity();

    // B2 Python parity path: when second_moment is present, compute the
    // awq-evolve.py fitness directly. This is the canonical "match Python"
    // objective. We still run the S5 path below to record best_t2/best_pair
    // for the A/B harness when use_kernel_direct is on.
    ts_awq_score py_score;
    bool have_py = false;
    if (layer->second_moment != nullptr) {
        if (ts_awq_evaluate_layer(*cand, *layer, &py_score) == 0) {
            have_py = true;
        }
    }

    // route the layer to its expert and apply that expert's profile so the
    // GA scores candidates under the same knobs the final quantize uses
    int mod = 0;
    if (ec->modality) {
        auto mit = ec->modality->find(layer->name);
        if (mit != ec->modality->end()) {
            mod = mit->second;
        }
    }

    ts_regime_descriptor rd = {};
    rd.tensor_name = layer->name;
    rd.family      = layer->family;
    rd.kurtosis    = layer->kurtosis;
    rd.eff_rank    = layer->eff_rank;
    rd.modality    = mod;
    ts_regime_routing  rr   = ts_regime_classify(&rd);
    ts_expert_profile  prof = ts_expert_default_profile(rr.expert, mod);

    ts_quant_params_2d qp;
    qp.alpha          = cand->genes.alpha * prof.alpha_scale;
    qp.clip           = cand->genes.clip * prof.clip_scale;
    qp.max_outliers   = prof.max_outliers;
    qp.outlier_thresh = ec->outlier_thresh * prof.outlier_thresh;
    qp.use_imatrix    = layer->imatrix != nullptr;
    qp.use_septq      = prof.use_septq;
    qp.awq_grid       = prof.awq_grid;
    qp.seed           = ec->seed;

    // Use the streaming MSE evaluator when kernel-direct fitness is OFF (the
    // default). This avoids the 700 MB per-candidate allocation of the full
    // ts_quantize_2d (ws + core + recon + packed + scales) and instead uses
    // ~132 KB of per-row scratch. The MSE is bit-identical. When kernel-direct
    // is ON, fall back to the full path because it needs qr.recon.
    const int64_t n = layer->out_dim * layer->in_dim;
    float mse_val;
    ts_quant_result_2d qr;  // only populated when kernel-direct is on
    if (!ec->l1.use_kernel_direct) {
        // Streaming path: O(in_dim) scratch per candidate.
        mse_val = ts_quantize_mse_streaming(
            layer->weights, layer->act_scales,
            qp.alpha, qp.clip,
            layer->out_dim, layer->in_dim);
        if (mse_val < 0.0f) {
            return score;  // worst possible fitness
        }
    } else {
        // Full path: needs qr.recon for kernel-direct t2.
        int rc = ts_quantize_2d(layer->weights, layer->act_scales,
                                layer->calib_X, layer->ref_output, layer->imatrix,
                                layer->out_dim, layer->in_dim, layer->n_tokens,
                                &qp, &qr);
        if (rc != 0) {
            return score;   // worst possible fitness
        }
        mse_val = qr.mse;
    }

    // mse is the mean squared reconstruction error, so
    // ||W_hat - W||_F^2 = mse * n. layer->frob2 is precomputed once by the
    // GA-prep walk (see tensor_stats.frob2); this is the GA's single
    // hottest per-candidate computation (~1.6M evals/run per the pipeline
    // refactor phase 2 notes), so reusing it instead of a fresh
    // ts_vec_dotpr full pass here is the dominant win of that work.
    // Falls back to a fresh pass for the (should not happen) case of a
    // layer that never got a precomputed value.
    float frob2 = (layer->frob2 > 0.0f)
        ? layer->frob2
        : ts_vec_dotpr(layer->weights, layer->weights, n);
    float rel_frob = (frob2 > 0.0f) ? (mse_val * (float)n / frob2) : mse_val;

    // S5: kernel-direct t_l^2 from the L1 sidecar, blended with the proxy.
    float t2    = rel_frob;
    float kd_t2 = rel_frob;   // falls back to the proxy when no sidecar exists
    if (ec->l1.use_kernel_direct) {
        // Lazy sidecar load: at most one disk read per tensor (the with_lock
        // lambda runs atomically under the shard lock, so the first caller
        // for a given tensor name populates the cache and subsequent callers
        // for the SAME tensor see the entry). Different tensors hash to
        // different shards and load concurrently with no contention.
        const std::vector<float> * kdeq_ptr = ec->sidecar_cache.with_lock(
            layer->name,
            [&](std::unordered_map<std::string, std::vector<float>> & m,
               const std::string & key) -> const std::vector<float> *
        {
            auto it = m.find(key);
            if (it != m.end()) {
                return &it->second;
            }
            std::vector<float> kdeq;
            int64_t sr = 0;
            int64_t sc = 0;
            if (ec->l1.sidecar_dir[0] != '\0' &&
                ts_l1_load_sidecar(ec->l1.sidecar_dir, key.c_str(),
                                   &kdeq, &sr, &sc) == 0 && sr * sc == n) {
                m.emplace(key, std::move(kdeq));
            } else {
                m.emplace(key, std::vector<float>());
            }
            it = m.find(key);
            if (ec->verbose && ec->mode_prints.load(std::memory_order_relaxed) < 3) {
                printf("tessera-dispatch: kernel-fitness: %s -> %s\n",
                       key.c_str(),
                       it->second.empty() ? "offline proxy (no sidecar)"
                                          : "kernel-direct (L1 sidecar)");
                ec->mode_prints.fetch_add(1, std::memory_order_relaxed);
            }
            return &it->second;
        });
        if (!kdeq_ptr->empty() && (int64_t)kdeq_ptr->size() == n &&
            (int64_t)qr.recon.size() == n) {
            kd_t2 = ts_l1_kernel_direct_t2(qr.recon.data(), layer->weights,
                                           kdeq_ptr->data(), n);
            t2    = ts_l1_blended_t2(rel_frob, kd_t2, ec->l1.blend_factor);
        }
    }

    // record the best candidate's (offline, kernel) pair for the A/B harness.
    // Two threads in the same layer can race here (same GA layer evaluated by
    // different generations within ts_awq_evolve, but ts_awq_evolve evaluates
    // candidates serially per layer), so the shard lock is sufficient.
    if (ec->l1.use_kernel_direct) {
        ec->best_t2.with_lock(layer->name,
            [&](std::unordered_map<std::string, float> & m,
               const std::string & key)
        {
            auto bit = m.find(key);
            if (bit == m.end() || t2 < bit->second) {
                m[key] = t2;
                ec->best_pair.assign(key, std::make_pair(rel_frob, kd_t2));
            }
        });
    }

    score.mse           = qr.mse;
    score.relative_frob = t2;       // t_l^2 used for fitness (blended when kernel-direct)
    score.heldout_mse   = qr.mse;   // no held-out split in standalone dispatch
    score.composite     = -t2;

    // B2: when the Python parity fitness was computed, drive the GA from it.
    // ts_awq_evaluate_layer leaves composite at 0, so derive the GA composite
    // from train_error (lower-is-better -> negate). The Python fitness is the
    // same reconstruction-error objective awq-evolve.py optimizes; using it
    // here keeps the dispatch GA aligned with the reference implementation.
    if (have_py) {
        score.mse         = py_score.mse;
        score.heldout_mse = py_score.heldout_mse;
        // relative_frob carries the kernel-direct t_l^2 above when S5 is on;
        // otherwise use the Python tail_error so the reported score still
        // reflects a meaningful reconstruction metric.
        if (!ec->l1.use_kernel_direct) {
            score.relative_frob = py_score.relative_frob;
        }
        score.composite   = -py_score.mse;
    }
    return score;
}

// forced_t2 / kernel_direct_t2 / tier2_t2 (the pipeline refactor's phase-1
// seam extraction) are gone: every caller below routes through
// ts_expert_eval (tessera-expert-eval.h) instead. PROXY tier reproduces
// forced_t2's algorithm exactly; REAL tier replaces tier2_t2 (DARTQUANT
// migrated verbatim, FLRQ corrected to ts_train_flrq, CHAMP-Q and SEPTQ
// newly real); KERNEL_DIRECT tier replaces kernel_direct_t2 and falls back
// to REAL (not the offline proxy) when no sidecar is available -- the seam
// caller below only invokes KERNEL_DIRECT when a sidecar dir is actually
// configured, preserving the original cost profile for the common
// no-sidecar case.

int ts_dispatch_run(const ts_dispatch_params * params,
                    ts_dispatch_result * result,
                    std::string * err_msg) {
    if (params == nullptr || result == nullptr) {
        if (err_msg) {
            *err_msg = "null params or result";
        }
        return 1;
    }

    *result = {};

    // Validate l5_scorer eagerly so an invalid combine spec (e.g. unknown
    // scorer name or duplicate entry) fails fast before any heavy work is
    // done. The same validation is already performed by the CLI arg and INI
    // handlers, but direct ts_dispatch_params callers (tests, tools/cli)
    // bypass those handlers and must get the same error contract.
    if (!params->l5_scorer.empty()) {
        std::vector<ts_l5_scorer_entry> spec_entries;
        std::string spec_err;
        if (!ts_l5_parse_scorer_spec(params->l5_scorer, spec_entries, spec_err)) {
            if (err_msg) *err_msg = spec_err;
            return 1;
        }
    }

    const bool verbose = params->verbose;

    // Persistent store. Opened once; closed via the unique_ptr deleter so
    // every return path (early or normal) marks the run done. nullptr when
    // --quantize-db is not set or open failed (the pipeline runs ephemeral).
    // db_run_status defaults to "failed" and is only flipped to "completed"
    // at the successful return, so any early-return path leaves the row
    // marked failed without needing to touch every return site.
    struct ts_dispatch_db_deleter {
        std::string * status;
        void operator()(ts_dispatch_db * w) const {
            ts_dispatch_db_close(w, status ? status->c_str() : "completed");
        }
    };
    std::string db_run_status = "failed";
    std::unique_ptr<ts_dispatch_db, ts_dispatch_db_deleter>
        db_guard(ts_dispatch_db_open(params, verbose),
                 ts_dispatch_db_deleter{&db_run_status});
    ts_dispatch_db * db_wrap = db_guard.get();

    // Structured progress reporter. Lives for the whole dispatch; each phase
    // resets the counters via ts_progress_set_phase. Terminal output auto-
    // enables on TTY stderr; NDJSON writes to progress_file when set. The
    // unique_ptr calls finish + destroy on scope exit so every early-return
    // path cleans up without per-site teardown. The TESSERA_PROGRESS_FILE
    // env var is a fallback so a shell can enable UI streaming without editing
    // launch commands.
    std::string progress_file = params->progress_file;
    if (progress_file.empty()) {
        const char * env = std::getenv("TESSERA_PROGRESS_FILE");
        if (env && env[0] != '\0') {
            progress_file = env;
        }
    }
    struct ts_progress_deleter {
        void operator()(ts_progress * p) const {
            ts_progress_finish(p);
            ts_progress_destroy(p);
        }
    };
    std::unique_ptr<ts_progress, ts_progress_deleter> prog_guard(
        ts_progress_create(
            ts_progress_phase::SETUP, 0,
            progress_file.empty() ? nullptr : progress_file.c_str(),
            params->progress_force_terminal || verbose));
    ts_progress * prog = prog_guard.get();

    // --- step 1: determine which steps to run ---
    const bool need_calibration = params->imatrix_path.empty() && params->policy_path.empty();
    const bool need_ga          = params->policy_path.empty();

    // --- step 2: calibration ---
    // Load precomputed per-channel activation statistics (the AWQ calibration
    // artifact) when an imatrix is provided.
    ts_imatrix imatrix;
    bool have_imatrix = false;
    ts_mm_imatrix mm_imatrix;
    bool have_mm_imatrix = false;
    if (!params->imatrix_path.empty()) {
        // multimodal imatrix (v3, modality_breakdown). Optional: a text-only
        // v2 file simply fails this load and falls through to the text path.
        std::string mmsg;
        if (ts_mm_imatrix_load(params->imatrix_path.c_str(), &mm_imatrix, &mmsg) == 0) {
            have_mm_imatrix = true;
            if (verbose) {
                printf("tessera-dispatch: calibration: loaded multimodal imatrix '%s' (%zu tensors)\n",
                       params->imatrix_path.c_str(), mm_imatrix.data.size());
            }
        }

        std::string imsg;
        if (ts_imatrix_load_npz(params->imatrix_path.c_str(), &imatrix, &imsg) == 0) {
            have_imatrix = true;
            if (verbose) {
                printf("tessera-dispatch: calibration: loaded imatrix '%s' (%zu tensors)\n",
                       params->imatrix_path.c_str(), imatrix.data.size());
            }
        } else if (ts_imatrix_load_gguf(params->imatrix_path.c_str(), &imatrix, &imsg) == 0) {
            // GGUF imatrix (emitted by llama-imatrix) - fall back when NPZ fails.
            have_imatrix = true;
            if (verbose) {
                printf("tessera-dispatch: calibration: loaded GGUF imatrix '%s' (%zu tensors)\n",
                       params->imatrix_path.c_str(), imatrix.data.size());
            }
        } else if (!have_mm_imatrix) {
            if (err_msg) {
                *err_msg = "failed to load imatrix '" + params->imatrix_path + "': " + imsg;
            }
            return 1;
        } else if (verbose) {
            printf("tessera-dispatch: calibration: no text rollup in '%s' (multimodal only)\n",
                   params->imatrix_path.c_str());
        }
    }

    // Calibration activations. With no imatrix and no policy we use the
    // built-in mini-corpus (deterministic synthetic activations) or a
    // caller-supplied corpus directory; these feed the AWQ scale fit for any
    // tensor whose in_dim matches the corpus width.
    std::vector<float> calib_X;
    int64_t calib_n_tokens = 0;
    int64_t calib_in_dim   = 0;
    if (need_calibration) {
        if (params->calib_corpus.empty()) {
            ts_corpus_params cparams = ts_corpus_default_params();
            calib_X        = ts_corpus_generate(&cparams);
            calib_n_tokens = cparams.n_tokens;
            calib_in_dim   = cparams.in_dim;
            if (verbose) {
                printf("tessera-dispatch: calibration: built-in mini-corpus (%lld x %lld)\n",
                       (long long)calib_n_tokens, (long long)calib_in_dim);
            }
        } else {
            std::string cmsg;
            calib_X = ts_corpus_load_directory(params->calib_corpus.c_str(),
                                               &calib_n_tokens, &calib_in_dim, &cmsg);
            if (calib_X.empty()) {
                if (err_msg) {
                    *err_msg = "failed to load calib corpus '" + params->calib_corpus + "': " + cmsg;
                }
                return 1;
            }
            if (verbose) {
                printf("tessera-dispatch: calibration: loaded corpus '%s' (%lld x %lld)\n",
                       params->calib_corpus.c_str(), (long long)calib_n_tokens, (long long)calib_in_dim);
            }
        }
        // TODO(hardening): real per-layer calibration activations require a
        // model forward pass over the corpus (per-layer calib_X / ref_output).
        // ts_dispatch_params carries no tokenizer or forward callback, so the
        // corpus above is a data-free proxy; per-channel act_scales come from
        // the imatrix when one is provided.
    }

    if (params->calibrate_only) {
        if (verbose) {
            printf("tessera-dispatch: calibrate_only, returning early\n");
        }
        result->policy_json = "{}";
        db_run_status = "completed";
        return 0;
    }

    // --- step 3: GA configuration ---
    // The evolutionary search runs per-tensor once the weights are loaded
    // (step 5c); here the dispatch knobs are translated into GA params.
    float default_alpha = 0.5f;

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

    if (params->evolve_only) {
        if (verbose) {
            printf("tessera-dispatch: evolve_only, returning early\n");
        }
        result->policy_json = "{}";
        db_run_status = "completed";
        return 0;
    }

    // --- step 4: resolve alpha ---
    if (params->awq_alpha != "auto" && !params->awq_alpha.empty()) {
        default_alpha = std::stof(params->awq_alpha);
    }

    // --- step 4b: read calibration policy (if any) ---
    // ts_policy_read consumes the canonical tensor_families shape emitted by
    // tools/tessera/awq-evolve.py and the legacy top-level tensors shape. When
    // present, the per-tensor loop below resolves each tensor name to a family
    // and overrides the AWQ alpha/clip and sparse-residual threshold from the
    // policy, eliminating the Python pre-step.
    ts_policy policy;
    bool have_policy = false;
    if (!params->policy_path.empty()) {
        std::string pmsg;
        if (ts_policy_read(params->policy_path.c_str(), &policy, &pmsg) != 0) {
            if (err_msg) {
                *err_msg = "failed to load policy '" + params->policy_path + "': " + pmsg;
            }
            return 1;
        }
        have_policy = true;
        if (verbose) {
            printf("tessera-dispatch: loaded policy '%s' (%zu families, search_schema='%s')\n",
                   params->policy_path.c_str(), policy.tensors.size(),
                   policy.search_schema.c_str());
        }
    }

    // --- step 5: load input GGUF ---
    // Use no_alloc=true so ggml creates tensor metadata without allocating
    // 8+ GB of resident memory for the weights. Then mmap the GGUF file and
    // patch each tensor's data pointer into the mmap'd region. macOS lazily
    // pages in only the tensor regions actually read; clean pages are evicted
    // under memory pressure. This drops the model's RSS contribution from the
    // full file size (~8 GB for q8_0) to ~one active tensor (~180 MB).
    struct ggml_context * ggml_ctx = nullptr;
    struct gguf_init_params gparams = {
        /*no_alloc =*/ true,
        /*ctx      =*/ &ggml_ctx,
    };

    struct gguf_context * in_ctx = gguf_init_from_file(params->input_path.c_str(), gparams);
    if (in_ctx == nullptr) {
        if (err_msg) {
            *err_msg = "failed to open input GGUF: " + params->input_path;
        }
        return 1;
    }

    // Mmap the GGUF file read-only and patch tensor data pointers.
    // The gguf data section starts at gguf_get_data_offset(in_ctx); each
    // tensor's data is at data_offset + gguf_get_tensor_offset(in_ctx, i).
    {
        int fd = open(params->input_path.c_str(), O_RDONLY);
        if (fd < 0) {
            if (err_msg) *err_msg = "open failed for mmap: " + params->input_path;
            gguf_free(in_ctx);
            ggml_free(ggml_ctx);
            return 1;
        }
        struct stat st;
        if (fstat(fd, &st) != 0) {
            close(fd);
            if (err_msg) *err_msg = "fstat failed for mmap";
            gguf_free(in_ctx);
            ggml_free(ggml_ctx);
            return 1;
        }
        size_t file_size = (size_t)st.st_size;
        void * mapped = mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mapped == MAP_FAILED) {
            close(fd);
            if (err_msg) *err_msg = "mmap failed for input GGUF";
            gguf_free(in_ctx);
            ggml_free(ggml_ctx);
            return 1;
        }
        // The fd can be closed after mmap; the mapping stays valid.
        close(fd);
        // Patch each tensor's data pointer into the mmap'd region.
        const size_t data_off = gguf_get_data_offset(in_ctx);
        const int64_t n_t = gguf_get_n_tensors(in_ctx);
        for (int64_t i = 0; i < n_t; i++) {
            const char * tname = gguf_get_tensor_name(in_ctx, i);
            size_t toff = gguf_get_tensor_offset(in_ctx, i);
            struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, tname);
            if (t) {
                t->data = (char *)mapped + data_off + toff;
            }
        }
        // Hold the mapping for the lifetime of in_ctx/ggml_ctx via a
        // cleanup lambda stored in the result (or just leak it - the OS
        // reclaims on process exit, and the quantize tool is short-lived).
        // For correctness, store in a static so ts_refine_reread_source
        // and other readers that re-access tensors still work.
    }

    const int64_t n_tensors = gguf_get_n_tensors(in_ctx);
    if (verbose) {
        printf("tessera-dispatch: loaded '%s' (%lld tensors)\n",
               params->input_path.c_str(), (long long)n_tensors);
    }

    // --- step 5a: L1.5 FP16 reference capture (NEW, v3.1 spec §3) ---
    // The L1.5 sidecar is the FP16 ground truth that the kernel's
    // dequant output is compared against by L3 coherence (and v2 of
    // the L2 activation-space differential). The legacy runtime-hook
    // path produced it as F16(F32(dequant)) which collapsed L3's
    // per-row cosine to ~1.0 by construction. The dispatch's
    // calibration-time capture produces F16(original weight) — the
    // actual unquantized reference.
    //
    // The capture is a no-op unless the dequant sidecar directory is
    // configured (i.e. the runtime hook would have written a file
    // there). When w4a4 is enabled and l15_dtype is f16, the runtime
    // hook no longer writes the F16 L1.5 (it would re-introduce the
    // round-trip); the dispatch does.
    {
        // Resolve through tessera_debug so both sources reach us: the
        // env var AND `--tessera-dequant-dir` (which arrives via
        // set_dequant_dir with no env var set). Reading the env var
        // directly here silently skipped L1.5 capture on the CLI path.
        const std::string & l15_dir = tessera_debug::dequant_dir();
        if (!l15_dir.empty() && tessera_debug::dequant_w4a4_enabled() &&
            tessera_debug::l15_dtype_is_f16()) {
            std::string l15_err;
            const int l15_rc = ts_dispatch_capture_l15_references(
                in_ctx, ggml_ctx, l15_dir,
                /*stride=*/(int64_t) tessera_debug::dequant_stride(),
                &l15_err);
            if (l15_rc != 0 && verbose) {
                std::fprintf(stderr, "tessera-dispatch: warning: L1.5 capture "
                                "reported %s\n", l15_err.c_str());
            }
        }
    }

    // Seed the GA phase total with n_tensors (upper bound; refined at the
    // evolve_all call site once ga_layers.size() is known).
    ts_progress_set_phase(prog, ts_progress_phase::GA_EVOLVE, n_tensors,
                          "per-tensor alpha search");

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
    bool have_archive = false;

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
        };
        std::vector<ts_ga_weight_loader>   ga_weight_loaders;
        std::vector<ts_awq_layer>          ga_layers;
        std::vector<ts_regime_descriptor>  ga_descs;     // regime descriptor per layer (archive axes)

        ts_progress_set_phase(prog, ts_progress_phase::GA_PREP, n_tensors,
                              "collect GA layers");
        ga_weight_loaders.reserve((size_t)n_tensors);  // prevent realloc (raw ptrs stored)
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
            // train/heldout activations are not yet wired here (no calib
            // split), so the evaluator uses the diagonal second-moment loss
            // for train_error and treats heldout == train, exactly as Python
            // does when train_activations is None.
            layer.second_moment       = (imdata && imdim == in_dim) ? imdata : nullptr;
            layer.fourth_moment       = nullptr;
            layer.max_abs             = nullptr;
            layer.train_activations   = nullptr;
            layer.heldout_activations = nullptr;
            layer.ref_train_output    = nullptr;
            layer.ref_heldout_output  = nullptr;
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
                return ml->buf.empty() ? nullptr : ml->buf.data();
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
            ga_weight_loaders.push_back({ggml_get_tensor(ggml_ctx, name), {}});
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
            have_archive = true;

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
            tensor_alpha = ga_alpha[name];
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

    // --- step 7b: G6 acceptance gate ---
    result->acceptance_ran = false;
    if (params->run_acceptance) {
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
                have_imatrix ? &imatrix : nullptr, name, item.in_dim,
                calib_X.empty() ? nullptr : calib_X.data(), calib_in_dim, calib_n_tokens,
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
    }

    // --- step 8: write tessera metadata ---
    ts_gguf_writer_params wparams;
    wparams.seed           = (uint32_t)params->evolve_seed;
    wparams.alpha          = default_alpha;
    wparams.clip           = params->awq_clip;
    wparams.outlier_frac   = params->outlier_frac;
    wparams.policy_summary = policy_json;
    wparams.policy_sha256  = "";
    wparams.build_info     = "";
    wparams.main_tip       = "";
    wparams.w4a4_enabled         = params->w4a4;
    wparams.w4a4_activation_bits = wcfg.activation_bits;
    wparams.w4a4_scale_mode      = ts_w4a4_scale_mode_str(wcfg.scale_mode);
    wparams.w4a4_outlier_thresh  = wcfg.outlier_thresh;
    ts_gguf_write_metadata(out_ctx, &wparams);

    // --- step 9: write output GGUF ---
    if (!params->output_path.empty()) {
        if (!gguf_write_to_file(out_ctx, params->output_path.c_str(), false)) {
            if (err_msg) {
                *err_msg = "failed to write output GGUF: " + params->output_path;
            }
            ggml_free(out_ggml_ctx);
            gguf_free(out_ctx);
            gguf_free(in_ctx);
            ggml_free(ggml_ctx);
            return 3;
        }
        if (verbose) {
            printf("tessera-dispatch: wrote '%s'\n", params->output_path.c_str());
        }
    }

    // --- step 10: write policy JSON alongside ---
    if (!params->policy_out_path.empty()) {
        std::ofstream pf(params->policy_out_path);
        if (pf.is_open()) {
            pf << policy_json << "\n";
            if (verbose) {
                printf("tessera-dispatch: wrote policy '%s'\n", params->policy_out_path.c_str());
            }
        } else {
            fprintf(stderr, "tessera-dispatch: warning: could not write policy to '%s'\n",
                    params->policy_out_path.c_str());
        }

        // write the MAP-Elites archive sidecar alongside the policy
        if (have_archive) {
            const std::string archive_path = params->policy_out_path + ".archive.json";
            std::ofstream af(archive_path);
            if (af.is_open()) {
                af << result->archive_json << "\n";
                if (verbose) {
                    printf("tessera-dispatch: wrote archive '%s'\n", archive_path.c_str());
                }
            } else {
                fprintf(stderr, "tessera-dispatch: warning: could not write archive to '%s'\n",
                        archive_path.c_str());
            }
        }
    }

    // --- step 11: populate summary ---
    result->n_tensors_quantized = n_quantized;
    result->n_tensors_skipped   = n_skipped;
    result->total_mse           = total_mse;
    result->policy_json         = policy_json;
    result->policy_sha256       = "";

    // --- finalize progress reporting ---
    ts_progress_set_phase(prog, ts_progress_phase::FINALIZE, 0, "write GGUF");

    // --- cleanup ---
    ggml_free(out_ggml_ctx);
    gguf_free(out_ctx);
    gguf_free(in_ctx);
    ggml_free(ggml_ctx);

    // Successful return: the db_guard deleter marks this run "completed".
    // Any early-return path above leaves db_run_status at "failed".
    db_run_status = "completed";

    // prog_guard's deleter runs here: ts_progress_finish + ts_progress_destroy.
    return 0;
}

