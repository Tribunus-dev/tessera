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
ts_awq_score ts_dispatch_awq_eval(const ts_awq_candidate * cand,
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

// tessera-rocblas.cpp's device-scratch pool is explicitly single-thread
// (comment tag W1-D2: "the L1-L6 dispatch loops are single-threaded per
// candidate, so one process-global pool is sufficient" - ts_rblas_buf_get
// only catches a second concurrent thread via a debug-only assert,
// compiled out under -DNDEBUG). Both ts_dispatch_forced_t2 and
// ts_dispatch_tier2_t2 reach that pool (via ts_vec_dotpr and the
// rocBLAS-accelerated DartQuant/FLRQ trainers). The acceptance gate's own
// worker pool (up to 8 threads) and export-ternary's live per-tensor
// selection (up to hardware_concurrency threads) both call these
// concurrently - a real, previously-untriggered race where one thread's
// hipFree of a "grow" reallocation frees a buffer another thread is still
// actively writing into, producing a GPU page fault (observed directly:
// a core dump with multiple threads inside ts_rblas_buf_get, one mid
// hipFree->SyncAllStreams). Serializing entry here enforces the pool's own
// documented single-dispatcher invariant for real instead of just
// asserting it - harmless for throughput since a single GPU serializes
// actual device work regardless of caller count anyway; the CPU-side
// thread pools still parallelize everything outside this call.
static std::mutex g_rblas_dispatch_mutex;

// Quantize a tensor with a forced expert profile and return relative
// Frobenius t_l^2 = ||W_hat - W||_F^2 / ||W||_F^2.
float ts_dispatch_forced_t2(const float * weights, const float * act_scales,
                                   int64_t out_dim, int64_t in_dim,
                                   ts_expert_id expert, float base_alpha,
                                   float base_clip, float outlier_thresh,
                                   uint32_t seed) {
    std::lock_guard<std::mutex> rblas_lock(g_rblas_dispatch_mutex);
    ts_expert_profile prof = ts_expert_default_profile(expert);

    float resolved_alpha = base_alpha * prof.alpha_scale;
    float resolved_clip  = base_clip * prof.clip_scale;

    // Streaming MSE path: ~132 KB scratch instead of 700 MB.
    float mse = ts_quantize_mse_streaming(
        weights, act_scales, resolved_alpha, resolved_clip,
        out_dim, in_dim);
    if (mse < 0.0f) {
        return 1.0f;  // worst case
    }

    const int64_t n = out_dim * in_dim;
    float frob2 = ts_vec_dotpr(weights, weights, n);
    return (frob2 > 0.0f) ? (mse * (float)n / frob2) : mse;
}

// Compute the kernel-direct t_l^2 for one tensor when an L1 sidecar
// is available. Returns the tail-weighted t_l^2 (t_l^2_tail, the
// Frobenius + lambda * mean-tail-MSE form from spec section 11);
// when no sidecar is present, returns -1 as the "no measurement"
// sentinel so the caller can fall back to the offline proxy.
//
// The acceptance verdict (step 7b in the dispatch) used to hardcode
// at.kernel_direct_t2 = at.composite_t2 (the offline proxy as a
// stand-in for the kernel-direct measurement). That made the
// ranking-disagreement test in ts_acceptance_run vacuous. This
// helper is the principled replacement: the kernel-direct t2 is
// computed from the L1 sidecar when one exists, and the
// tail-weighted form is the production t_l^2 (per the
// runtime-aware-pipeline.md spec).
//
// The implementation is two-pass: pass 1 reads the sidecar and
// computes the Frobenius term; pass 2 reads the sidecar again
// and computes the tail MSE on the |W_l[i]| > tau indices. The
// sidecar is loaded once via ts_l1_load_sidecar (from
// tessera-l1-fitness.h) which copies the F32 data into a local
// std::vector, so the second pass walks the local copy, not
// the file.
//
// The acceptance verdict has the source `w` but no separate `w_hat`
// reconstruction, so both arguments of the underlying tail metric are
// the same buffer: `ts_l1_kernel_direct_t2_tail` measures
// ||w_hat - dequant_kernel||^2 / ||w_original||^2, and with
// w_hat == w_original == w that reduces to the source-vs-dequant
// Frobenius, which is the measurement we want. This helper takes one
// `w` so a call site cannot pass the two apart.
static float ts_dispatch_kernel_direct_t2(
        const char * tensor_name,
        const char * sidecar_dir,
        const float * w,
        int64_t n,
        float tau,
        float lambda_tail) {
    if (sidecar_dir == nullptr || sidecar_dir[0] == '\0' ||
        tensor_name == nullptr || w == nullptr || n <= 0) {
        return -1.0f;  // sentinel: no measurement available
    }
    std::vector<float> kdeq;
    int64_t rows = 0;
    int64_t cols = 0;
    if (ts_l1_load_sidecar(sidecar_dir, tensor_name, &kdeq, &rows, &cols) != 0) {
        return -1.0f;  // sentinel: sidecar absent or malformed
    }
    if ((int64_t)kdeq.size() != n) {
        return -1.0f;  // sentinel: shape mismatch
    }
    return ts_l1_kernel_direct_t2_tail(w, w, kdeq.data(),
                                       n, tau, lambda_tail);
}

// Tier-2 REAL per-expert evaluation for the G6 panel. ts_dispatch_forced_t2
// only scales alpha/clip through the same T640 core -- the rotation never
// rotates, the low-rank never factorizes -- so the per-method scores could
// not disagree (measured: rotation and Hessian bit-identical to AWQ on
// 197/197 Orpheus tensors) and the novelty prong was structurally null.
// This helper runs the expert's ACTUAL algorithm and scores the full
// reconstruction against the original weights in t2 units (mse * n /
// ||W||_F^2), matching forced_t2's convention:
//   DARTQUANT: fit the block rotation (QR-Orth), rotate, quantize the
//     rotated weights with the T640 core. Orthogonality makes the rotated-
//     space error equal the original-space error, and ||W|| invariant.
//   FLRQ/low-rank: fit U,V (LRQ), quantize the residual W - UV with the
//     T640 core; the reconstruction is UV (carried high-precision) +
//     Q(residual), so the residual's MSE is the reconstruction error.
//   AWQ needs no Tier-2 path: forced_t2 with the AWQ profile IS the real
//     AWQ-core measurement (actual alpha/clip through the actual core).
//   SEPTQ scoring is not yet plumbed (needs a dequant of its packed
//     output); its slot keeps the proxy and the verdict labels it.
// Returns -1 on any failure so the caller keeps the proxy value.
float ts_dispatch_tier2_t2(ts_expert_id expert, const float * w,
                                  const float * act_scales,
                                  int64_t out_dim, int64_t in_dim,
                                  float alpha, float clip, uint32_t seed,
                                  const float * calib_X, int64_t n_tokens) {
    std::lock_guard<std::mutex> rblas_lock(g_rblas_dispatch_mutex);
    const int64_t n = out_dim * in_dim;
    if (w == nullptr || n <= 0) return -1.0f;
    const float frob2 = ts_vec_dotpr(w, w, n);
    if (frob2 <= 0.0f) return -1.0f;

    switch (expert) {
        case TS_EXPERT_DARTQUANT: {
            int64_t K = 0;
            for (int64_t cand : {(int64_t)128, (int64_t)64, (int64_t)32,
                                 (int64_t)16, (int64_t)8}) {
                if (in_dim % cand == 0) { K = cand; break; }
            }
            if (K == 0) return -1.0f;
            ts_dartquant_params dp;
            dp.block_size  = K;
            dp.max_iters   = 30;   // panel budget: enough to leave identity,
                                   // bounded so 4 experts x holdout stays
                                   // minutes, not hours
            dp.lr          = 1.0e-2f;
            dp.whip_weight = 0.1f;
            dp.seed        = seed;
            ts_dartquant_result dr;
            if (ts_dartquant_qr_orth(w, out_dim, in_dim, calib_X, n_tokens,
                                     nullptr, &dp, &dr) != 0) {
                return -1.0f;
            }
            std::vector<float> wrot((size_t)n);
            ts_dartquant_apply(w, dr.R.data(), wrot.data(), out_dim, in_dim, K);
            const float mse = ts_quantize_mse_streaming(
                wrot.data(), act_scales, alpha, clip, out_dim, in_dim);
            if (mse < 0.0f) return -1.0f;
            return mse * (float)n / frob2;
        }
        case TS_EXPERT_FLRQ: {
            ts_lrq_params lp;
            lp.rank      = std::max<int64_t>(1,
                std::min<int64_t>(32, std::min(out_dim, in_dim) / 8));
            lp.max_iters = 50;
            lp.lr        = 1.0e-3f;
            lp.tol       = 1.0e-6f;
            lp.seed      = seed;
            ts_lrq_result lres;
            if (ts_train_lrq(w, out_dim, in_dim, &lp, &lres, calib_X, n_tokens) != 0) {
                return -1.0f;
            }
            const int64_t r = lres.rank;
            if (r <= 0 || (int64_t)lres.U.size() < out_dim * r ||
                (int64_t)lres.V.size() < r * in_dim) {
                return -1.0f;
            }
            // FLRQ trains U/V as a MULTIPLICATIVE pre-scale (S = U@V, warm-
            // started near identity so W*S stays close to W - see
            // tessera-lrq.h and per_tensor_calibrate.py:624-724), not an
            // additive low-rank residual. `scaled = W * S` is the same
            // proxy convention TS_EXPERT_DARTQUANT above already uses for
            // `wrot`: a self-referential ternarize-round-trip MSE of the
            // transformed weight, normalized by the ORIGINAL W's frob2 -
            // not a true W-vs-reconstruction comparison, but consistent
            // with how the sibling expert is scored and with what
            // ts_train_lrq's own training loss actually optimizes.
            std::vector<float> S((size_t)n), scaled((size_t)n);
            ts_lrq_reconstruct_scale(&lres, out_dim, in_dim, S.data());
            for (int64_t i = 0; i < n; i++) {
                scaled[(size_t)i] = w[(size_t)i] * S[(size_t)i];
            }
            const float mse = ts_quantize_mse_streaming(
                scaled.data(), act_scales, alpha, clip, out_dim, in_dim);
            if (mse < 0.0f) return -1.0f;
            return mse * (float)n / frob2;
        }
        default:
            return -1.0f;
    }
}

// ---------------------------------------------------------------------------
// L5 adaptive requantize refine loop (dispatch L2 -> L5 -> re-quantize):
// ts_refine_reread_source/ts_refine_rel_frob/ts_join/ts_dispatch_db/
// ts_dispatch_run_l5_loop and friends now live in tessera-dispatch-l5.cpp
// and tessera-dispatch-db.cpp (declared in tessera-dispatch.h /
// tessera-dispatch-internal.h) - this file no longer duplicates them.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// dispatch
// ---------------------------------------------------------------------------

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
    // need_ga is now derived independently inside tessera-dispatch-gaprep.cpp
    // (the only remaining reader after the GA-configuration block moved there).
    const bool need_calibration = params->imatrix_path.empty() && params->policy_path.empty();

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
    // (step 5c); the full evolve_params construction (and its diagnostic
    // printf) moved into tessera-dispatch-gaprep.cpp along with step 5c,
    // since evolve_params has no other reader. Only default_alpha and the
    // evolve_only early-return (neither needs evolve_params) stay here.
    float default_alpha = 0.5f;

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

    // --- steps 5b-5c: GA-prep (HIGGS estimation + evolutionary search) ---
    std::unordered_map<std::string, float>            ga_alpha;
    std::unordered_map<std::string, ts_mm_awq_result>  mm_awq;
    {
        const int gaprep_rc = ts_dispatch_run_gaprep(
            params, result, err_msg,
            in_ctx, ggml_ctx, n_tensors,
            have_imatrix, imatrix,
            have_mm_imatrix, mm_imatrix,
            calib_X, calib_in_dim, calib_n_tokens,
            db_wrap, prog,
            &ga_alpha, &mm_awq);
        // ts_dispatch_run_gaprep already freed in_ctx/ggml_ctx on any
        // non-zero return, matching this block's original inline
        // behavior exactly -- do not free them again here.
        if (gaprep_rc != 0) {
            return gaprep_rc;
        }
    }

    // --- steps 6 through 7a-legacy: dispatch walk ---
    struct gguf_context * out_ctx = nullptr;
    struct ggml_context * out_ggml_ctx = nullptr;
    std::deque<ts_quant_result_2d>              cluster_results;
    std::deque<std::vector<ts_quant_result_2d>> moe_results;
    float   total_mse    = 0.0f;
    int64_t n_quantized  = 0;
    int64_t n_skipped    = 0;
    std::string policy_json;
    {
        const int walk_rc = ts_dispatch_run_walk(
            params, result, err_msg,
            in_ctx, ggml_ctx, n_tensors,
            have_imatrix, imatrix,
            have_mm_imatrix, mm_imatrix,
            calib_X, calib_in_dim, calib_n_tokens,
            default_alpha,
            have_policy, policy,
            ga_alpha, mm_awq,
            db_wrap, prog,
            &out_ctx, &out_ggml_ctx,
            &cluster_results, &moe_results,
            &total_mse, &n_quantized, &n_skipped, &policy_json);
        // ts_dispatch_run_walk already freed in_ctx/ggml_ctx/out_ctx/
        // out_ggml_ctx (whichever it had created) on any non-zero return,
        // matching this block's original inline behavior exactly -- do
        // not free them again here.
        if (walk_rc != 0) {
            return walk_rc;
        }
    }

    // --- step 7b: G6 acceptance gate ---
    ts_dispatch_run_acceptance(
        params, result, in_ctx, ggml_ctx, n_tensors,
        have_imatrix ? &imatrix : nullptr,
        calib_X.empty() ? nullptr : calib_X.data(), calib_in_dim, calib_n_tokens,
        default_alpha, db_wrap, prog);

    // --- step 8: write tessera metadata ---
    // wcfg: re-derived here rather than threaded out of ts_dispatch_run_walk
    // -- it is a pure function of params (set once, never mutated anywhere
    // in the walk body: grep confirms the only two field writes are
    // .enable/.outlier_thresh, both below, identical to walk's own
    // construction), so recomputing it is behaviorally exact, not a
    // logic change.
    ts_w4a4_config wcfg = ts_w4a4_default_config();
    wcfg.enable         = params->w4a4;
    wcfg.outlier_thresh = params->w4a4_outlier_thresh > 0.0f
                              ? params->w4a4_outlier_thresh : wcfg.outlier_thresh;

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

        // write the MAP-Elites archive sidecar alongside the policy.
        // have_archive was a gaprep-internal local (now fully inside
        // ts_dispatch_run_gaprep); !archive_json.empty() is an exact
        // substitute -- ts_archive_to_json always returns non-empty JSON
        // once ts_archive_init has run, and result->archive_json is only
        // ever set right after that call.
        if (!result->archive_json.empty()) {
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

