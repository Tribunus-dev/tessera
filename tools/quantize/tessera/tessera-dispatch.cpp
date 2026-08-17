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
// L5 adaptive requantize refine loop (dispatch L2 -> L5 -> re-quantize)
// ---------------------------------------------------------------------------

#include "tessera-dispatch-internal.h"

// Re-read one tensor's source weights from the input GGUF as F32. Returns
// an empty vector on failure (matching ts_tensor_to_f32's contract).
static std::vector<float> ts_refine_reread_source(struct gguf_context * in_ctx,
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
static float ts_refine_rel_frob(const float * src, const ts_quant_result_2d * qr,
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
static std::string ts_join(const std::vector<std::string> & parts,
                           const std::string & sep) {
    std::string out;
    for (size_t i = 0; i < parts.size(); i++) {
        if (i) out += sep;
        out += parts[i];
    }
    return out;
}

// ---------------------------------------------------------------------------
// DuckDB store plumbing
//
// ts_dispatch_db is the per-run state threaded through the GA hooks. It owns
// the open ts_tessera_db plus per-table write buffers. The buffers replace
// the previous per-tensor DuckDB Appender sharded map: each one is a single
// MPSC queue with a dedicated flusher thread, 65536-row batches, 1-second
// time flush, and sync-on-exit via the unique_ptr deleter. See
// tessera-db-buffer.h.
//
// Two buffers are owned:
//   eval_buffer       — ga_evaluations (the GA hot path; ~1.6M rows per run).
//   l4_outcome_buffer — l4_plan_outcome (the L5 feedback loop; one row per
//                       (tensor, iteration) in the adaptive_requantize loop).
//
// All DB calls are best-effort: a failure logs a one-line warning and the
// pipeline continues. The DB is a recording/warm-start aid, not a correctness
// requirement, so a corrupt file or full disk must never block quantization.
struct ts_dispatch_db {
    ts_tessera_db * db = nullptr;     // owned; null when --quantize-db is unset
    std::string      run_id;           // empty until begin_run succeeds
    std::string      model_hash;       // empty when hashing failed
    // Resume set: tensor names with a converged result for this run_id.
    // Populated at startup; the layer_skip_lookup callback checks membership.
    std::unordered_set<std::string> converged;
    // GA-prep warm-start registry. Populated at open time from
    // l5_weights (the orchestrator's retune output); the
    // family_seed_lookup hook prefers entries here over the
    // legacy ga_results-based seed lookup because l5_weights is
    // the more recent + orchestrator-scored signal. Keyed by
    // family; empty when --tessera-db is unset or the model has
    // no l5_weights rows yet.
    std::unordered_map<std::string, ts_tessera_db_l5_weight_list_entry>
        l5_weight_map;
    // Per-table write buffers. Both null when --quantize-db is unset.
    ts_db_buffer *   eval_buffer       = nullptr;
    ts_db_buffer *   l4_outcome_buffer = nullptr;
    // Tier 2 regime thresholds: learned kurtosis/eff_rank cutoffs per family.
    // Populated at open time from regime_thresholds DuckDB table.
    // Keyed by family string ("attn_q", "ffn_gate", etc.); empty when
    // no prior exists (the static cascade is used instead).
    std::unordered_map<std::string, ts_regime_family_thresholds>
        regime_threshold_map;
};

// Open the store and begin a run. Returns a heap-allocated ts_dispatch_db
// (owned by the caller via unique_ptr) or nullptr on failure / when the path
// is empty. model_path is hashed to fingerprint this run for warm-start.
static ts_dispatch_db * ts_dispatch_db_open(
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
        wrap->eval_buffer = ts_db_buffer_open(
            wrap->db, "ga_evaluations", ga_cols,
            /*flush_threshold=*/65536,
            std::chrono::milliseconds(1000));
        if (wrap->eval_buffer == nullptr) {
            fprintf(stderr, "tessera-dispatch: warning: eval buffer open failed "
                            "(eval logging disabled; run_lifecycle still works)\n");
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
        wrap->l4_outcome_buffer = ts_db_buffer_open(
            wrap->db, "l4_plan_outcome", l4_cols,
            /*flush_threshold=*/1024,
            std::chrono::milliseconds(1000));
        if (wrap->l4_outcome_buffer == nullptr) {
            fprintf(stderr, "tessera-dispatch: warning: l4_outcome buffer open failed "
                            "(feedback loop disabled; run_lifecycle still works)\n");
        }
    }
    return wrap;
}

// Finalize: mark the run complete (or failed) and close any appenders left
// open by an early-return path. Called from the unique_ptr deleter so every
// exit from ts_dispatch_run cleans up.
static void ts_dispatch_db_close(ts_dispatch_db * wrap, const char * status) {
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
static void ts_dispatch_eval_recorder(const ts_awq_layer * layer,
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
static bool ts_dispatch_family_seed_lookup(const char * family,
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
static bool ts_dispatch_layer_skip(const ts_awq_layer * layer,
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
// Exact storage footprint (bits) of a 2D quant result: every GGUF
// component the format writes. The L5 loop's budget-constrained
// A/B selection measures this on scratch quantizations instead of
// estimating, so the Lagrangian violation is computed from real
// bytes, not a bit-model.
static int64_t ts_dispatch_result_bits(const ts_quant_result_2d * qr) {
    return (int64_t)qr->packed.size()              * 32
         + (int64_t)qr->page_scales.size()         * 16
         + (int64_t)qr->lane_scales.size()         * 8
         + (int64_t)qr->outlier_row_offsets.size() * 32
         + (int64_t)qr->outlier_cols.size()        * 32
         + (int64_t)qr->outlier_vals.size()        * 16
         + (int64_t)qr->act_scale.size()           * 16;
}

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

