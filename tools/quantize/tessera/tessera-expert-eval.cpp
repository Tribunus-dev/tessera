//
// tessera-expert-eval.cpp
//
// See tessera-expert-eval.h for the contract. This file implements the
// three tiers (PROXY / REAL / KERNEL_DIRECT) for every expert.
//

#include "tessera-expert-eval.h"

#include "tessera-quant.h"        // ts_quantize_mse_streaming
#include "tessera-vec.h"          // ts_vec_dotpr
#include "tessera-regime.h"       // ts_expert_default_profile, ts_expert_name
#include "tessera-dartquant.h"
#include "tessera-flrq.h"
#include "tessera-champq.h"
#include "tessera-septq.h"
#include "tessera-l1-fitness.h"   // ts_l1_load_sidecar, ts_l1_kernel_direct_t2_tail
#include "tessera-quantize-db.h"  // ts_tessera_db_read/write_eval_cache (phase 2)

#include "ggml-quants.h"          // dequantize_row_tessera_t640_with_meta,
                                   // ts_decode_per_row_meta,
                                   // ts_apply_outlier_addback,
                                   // ts_t640_*_accel_wins,
                                   // ggml_tessera_t640_accel_enabled

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

// ---------------------------------------------------------------------------
// Phase 2 "Layer A": frob2 read-back
// ---------------------------------------------------------------------------
//
// frob2 (||W||_F^2) is needed by every tier below and was previously
// recomputed via a full ts_vec_dotpr pass on every single call -- cheap
// once, but this seam is invoked many times per tensor across a GA/
// acceptance sweep. When the caller wired ctx.db/model_hash/name (the
// same eligibility the eval_cache check in ts_expert_eval uses), the
// dispatch's GA-prep walk has already computed and stored frob2 in
// tensor_stats (see tools/quantize/tessera/tessera-quantize-db.h) -- read
// it back instead of recomputing. Falls back to a fresh pass whenever no
// cache is wired, the row is missing, or the row predates Layer A
// (stats_version mismatch) -- always correct, just sometimes not free.
static float ts_eval_frob2(const ts_eval_tensor_ctx & ctx) {
    const int64_t n = ctx.out_dim * ctx.in_dim;
    if (ctx.db != nullptr && !ctx.model_hash.empty() && ctx.name != nullptr) {
        ts_tessera_db_tensor_stat stat;
        bool hit = false;
        std::string err;
        if (ts_tessera_db_read_tensor_stat(ctx.db, ctx.model_hash, ctx.model_role,
                ctx.name, &stat, &hit, &err) == 0 &&
            hit && stat.stats_version == TS_TENSOR_STATS_VERSION && stat.frob2 > 0.0) {
            return (float) stat.frob2;
        }
    }
    return ts_vec_dotpr(ctx.weights, ctx.weights, n);
}

// ---------------------------------------------------------------------------
// PROXY tier: bit-for-bit ts_dispatch_forced_t2 (profile alpha/clip scaling
// into the T640-core streaming MSE). Every REAL-tier fallback routes back
// through this same helper so a failed real algorithm still returns a
// usable, correctly-labeled score.
// ---------------------------------------------------------------------------

static void ts_eval_proxy_score(ts_expert_id expert,
                                const ts_eval_tensor_ctx & ctx,
                                const ts_eval_opts & opts,
                                ts_eval_result * out) {
    ts_expert_profile prof = ts_expert_default_profile(expert);

    const float resolved_alpha = opts.alpha * prof.alpha_scale;
    const float resolved_clip  = opts.clip  * prof.clip_scale;

    const float mse = ts_quantize_mse_streaming(
        ctx.weights, ctx.act_scales, resolved_alpha, resolved_clip,
        ctx.out_dim, ctx.in_dim);
    if (mse < 0.0f) {
        out->t2  = 1.0f;  // worst case, matches ts_dispatch_forced_t2
        out->mse = 0.0f;
        return;
    }

    const int64_t n = ctx.out_dim * ctx.in_dim;
    const float frob2 = ts_eval_frob2(ctx);
    out->mse = mse;
    out->t2  = (frob2 > 0.0f) ? (mse * (float)n / frob2) : mse;
}

static int ts_eval_run_proxy(ts_expert_id expert,
                             const ts_eval_tensor_ctx & ctx,
                             const ts_eval_opts & opts,
                             ts_eval_result * out) {
    ts_eval_proxy_score(expert, ctx, opts, out);
    out->from_cache = false;
    std::snprintf(out->aux, sizeof(out->aux),
                 "{\"expert\":\"%s\",\"tier\":\"proxy\"}",
                 ts_expert_name(expert));
    return 0;
}

// A REAL (or KERNEL_DIRECT) request whose underlying algorithm could not
// produce a measurement still gets a usable t2 -- the proxy -- but the
// fallback is counted in aux rather than silently returned as if it were
// real. Phase-1 known issue: a silent proxy fallback on a REAL-tier call
// is exactly what produced the "rot came back EXACTLY equal to awq"
// ambiguity; this is the seam's structural fix (docs/tessera-refactor-
// implementation-spec.md section 1).
static int ts_eval_fallback_to_proxy(ts_expert_id expert,
                                     const ts_eval_tensor_ctx & ctx,
                                     const ts_eval_opts & opts,
                                     ts_eval_result * out,
                                     const char * reason) {
    ts_eval_proxy_score(expert, ctx, opts, out);
    out->from_cache = false;
    std::snprintf(out->aux, sizeof(out->aux),
                 "{\"expert\":\"%s\",\"tier\":\"proxy\",\"fallback\":\"%s\"}",
                 ts_expert_name(expert), reason);
    return 0;
}

// ---------------------------------------------------------------------------
// REAL tier: DARTQUANT (migrated verbatim from ts_dispatch_tier2_t2).
// ---------------------------------------------------------------------------

static int ts_eval_real_dartquant(const ts_eval_tensor_ctx & ctx,
                                  const ts_eval_opts & opts,
                                  ts_eval_result * out) {
    const int64_t n = ctx.out_dim * ctx.in_dim;
    const float frob2 = ts_eval_frob2(ctx);
    if (frob2 <= 0.0f) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_DARTQUANT, ctx, opts, out,
                                         "frob2_nonpositive");
    }

    int64_t K = 0;
    for (int64_t cand : {(int64_t)128, (int64_t)64, (int64_t)32,
                         (int64_t)16, (int64_t)8}) {
        if (ctx.in_dim % cand == 0) { K = cand; break; }
    }
    if (K == 0) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_DARTQUANT, ctx, opts, out,
                                         "no_block_size");
    }

    ts_dartquant_params dp;
    dp.block_size  = K;
    dp.max_iters   = 30;   // panel budget: enough to leave identity,
                           // bounded so the full 5-expert x holdout panel
                           // stays minutes, not hours
    dp.lr          = 1.0e-2f;
    dp.whip_weight = 0.1f;
    dp.seed        = opts.seed;

    ts_dartquant_result dr;
    if (ts_dartquant_qr_orth(ctx.weights, ctx.out_dim, ctx.in_dim, &dp, &dr) != 0) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_DARTQUANT, ctx, opts, out,
                                         "qr_orth_failed");
    }

    std::vector<float> wrot((size_t)n);
    ts_dartquant_apply(ctx.weights, dr.R.data(), wrot.data(),
                       ctx.out_dim, ctx.in_dim, K);

    const float mse = ts_quantize_mse_streaming(
        wrot.data(), ctx.act_scales, opts.alpha, opts.clip,
        ctx.out_dim, ctx.in_dim);
    if (mse < 0.0f) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_DARTQUANT, ctx, opts, out,
                                         "streaming_mse_failed");
    }

    // Orthogonal invariance: score in the rotated space, normalize against
    // the ORIGINAL frob2 (rotation preserves the Frobenius norm exactly).
    out->mse = mse;
    out->t2  = mse * (float)n / frob2;
    out->from_cache = false;
    std::snprintf(out->aux, sizeof(out->aux),
                 "{\"expert\":\"dartquant\",\"tier\":\"real\",\"block_size\":%lld}",
                 (long long)K);
    return 0;
}

// ---------------------------------------------------------------------------
// REAL tier: FLRQ -- CORRECTED RECIPE. The prior ts_dispatch_tier2_t2 FLRQ
// arm wrongly treated ts_train_lrq's U,V as an additive factorization; that
// module actually trains a MULTIPLICATIVE scale field (S = U@V, loss =
// mean((ternarize_recon(W*S) - W)^2)). This adapter uses ts_train_flrq
// instead: genuinely additive (residual = W - U@V), returns
// reconstruction_mse directly in the original weight domain.
// ---------------------------------------------------------------------------

static int ts_eval_real_flrq(const ts_eval_tensor_ctx & ctx,
                             const ts_eval_opts & opts,
                             ts_eval_result * out) {
    const int64_t n = ctx.out_dim * ctx.in_dim;
    const float frob2 = ts_eval_frob2(ctx);
    if (frob2 <= 0.0f) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_FLRQ, ctx, opts, out,
                                         "frob2_nonpositive");
    }

    // Zero-init triggers every documented runtime default: rank_candidates
    // -> {4,8,16,32,64}, n_projections -> 32, blc_iters -> 4, qbits -> 4,
    // mse_threshold -> 1e-3 (tessera-flrq.h / the contracts appendix).
    // FLRQ is calibration-free (no act_scales/alpha/clip parameter exists
    // on ts_train_flrq); opts.seed feeds the sketch RNG (0 -> 1 internally).
    ts_flrq_params fp = {};
    fp.seed = opts.seed;

    ts_flrq_bcl_result fr;
    int64_t chosen_rank = -1;
    if (ts_train_flrq(ctx.weights, ctx.out_dim, ctx.in_dim, &fp, &fr,
                      &chosen_rank) != 0 || chosen_rank < 0) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_FLRQ, ctx, opts, out,
                                         "train_flrq_failed");
    }

    // reconstruction_mse is already mean((W - (U@V + residual_q))^2) in the
    // original weight domain -- no further quantize/dequant pass needed.
    out->mse = fr.reconstruction_mse;
    out->t2  = fr.reconstruction_mse * (float)n / frob2;
    out->from_cache = false;
    std::snprintf(out->aux, sizeof(out->aux),
                 "{\"expert\":\"flrq\",\"tier\":\"real\",\"rank\":%lld}",
                 (long long)chosen_rank);
    return 0;
}

// ---------------------------------------------------------------------------
// REAL tier: CHAMP-Q (new). Permute -> quantize -> score; permutation
// preserves the Frobenius norm, so t2 normalizes against the ORIGINAL
// frob2. act_scales rides the same column gather as the weights.
// ---------------------------------------------------------------------------

static int ts_eval_real_champq(const ts_eval_tensor_ctx & ctx,
                               const ts_eval_opts & opts,
                               ts_eval_result * out) {
    const int64_t n = ctx.out_dim * ctx.in_dim;
    const float frob2 = ts_eval_frob2(ctx);
    if (frob2 <= 0.0f) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_CHAMPQ, ctx, opts, out,
                                         "frob2_nonpositive");
    }

    ts_champq_params cp;
    // Panel budget (matching the DartQuant real-tier arm's bounded max_iters
    // 30 vs. the library's own unrestrained defaults): CHAMP-Q's cost is
    // O(max_iters x evals_per_iter x out_dim x in_dim^2) with no bound on
    // in_dim the way DartQuant caps its block size or FLRQ caps its rank
    // candidates -- on a real 3072x3072 attention tensor the header
    // defaults (max_iters=100, sinkhorn_iters=25) measured ~4.4 minutes per
    // tensor (clean, single-process timing); across the acceptance panel's
    // ~20% held-out set that is hours, not minutes, and is what stalled the
    // first phase-1 Orpheus gate run. max_iters=20/sinkhorn_iters=15
    // measured ~40s on the same tensor -- still genuine L-BFGS refinement,
    // not the init-only bypass, just bounded.
    cp.max_iters      = 20;
    cp.sinkhorn_iters = 15;
    cp.use_lbfgs      = true;
    cp.seed           = opts.seed;
    cp.act_scales     = ctx.act_scales;
    // ts_champq_compute uses the RAW (value-initialized) binariness, which
    // is 0 (penalty disabled) unless set explicitly -- the header's
    // "default 1e-3" comment describes the Python CLI default, not a C++
    // struct default. Set it explicitly for Python parity (contracts
    // appendix, section A gotchas).
    cp.binariness     = 1.0e-3f;
    cp.history        = 8;     // header default
    cp.projection     = 0;     // hungarian (silently -> greedy when K>512)
    cp.init           = 0;     // l2rank

    ts_champq_result cr;
    if (ts_champq_compute(ctx.weights, ctx.out_dim, ctx.in_dim, &cp, &cr) != 0) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_CHAMPQ, ctx, opts, out,
                                         "champq_compute_failed");
    }
    if ((int64_t)cr.perm.size() != ctx.in_dim) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_CHAMPQ, ctx, opts, out,
                                         "perm_size_mismatch");
    }

    std::vector<float> wperm((size_t)n);
    ts_champq_apply(ctx.weights, cr.perm.data(), wperm.data(),
                    ctx.out_dim, ctx.in_dim);

    // act_scales rides the same gather as the weight columns:
    // W_perm[:, j] = W[:, perm[j]]  =>  act_perm[j] = act_scales[perm[j]].
    std::vector<float> act_perm;
    const float * act_for_score = nullptr;
    if (ctx.act_scales != nullptr) {
        act_perm.resize((size_t)ctx.in_dim);
        for (int64_t j = 0; j < ctx.in_dim; j++) {
            act_perm[(size_t)j] = ctx.act_scales[cr.perm[(size_t)j]];
        }
        act_for_score = act_perm.data();
    }

    const float mse = ts_quantize_mse_streaming(
        wperm.data(), act_for_score, opts.alpha, opts.clip,
        ctx.out_dim, ctx.in_dim);
    if (mse < 0.0f) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_CHAMPQ, ctx, opts, out,
                                         "streaming_mse_failed");
    }

    out->mse = mse;
    out->t2  = mse * (float)n / frob2;  // permutation-invariant norm
    out->from_cache = false;
    std::snprintf(out->aux, sizeof(out->aux),
                 "{\"expert\":\"champq\",\"tier\":\"real\",\"mse_improvement\":%.6g}",
                 (double)cr.mse_improvement);
    return 0;
}

// ---------------------------------------------------------------------------
// REAL tier: SEPTQ (new). Quantize with the SEPTQ packed convention, then
// dequant-score via the exact production kernel path (dequantize_row_
// tessera_t640_with_meta) so the score reflects exactly what inference
// sees. Phase-1 panel defaults below are fixed constants (not gene-driven)
// -- the same convention DartQuant/FLRQ's real arms already use for their
// panel-budget knobs (max_iters, rank formula). Gene-driven septq_ratio /
// ternary_threshold mapping (contracts appendix section A refactor notes)
// lands once the seam carries the full ts_policy_genes payload (GA
// conversion, phase 2+).
// ---------------------------------------------------------------------------

static int ts_eval_real_septq(const ts_eval_tensor_ctx & ctx,
                              const ts_eval_opts & opts,
                              ts_eval_result * out) {
    const int64_t n = ctx.out_dim * ctx.in_dim;
    const float frob2 = ts_eval_frob2(ctx);
    if (frob2 <= 0.0f) {
        return ts_eval_fallback_to_proxy(TS_EXPERT_SEPTQ, ctx, opts, out,
                                         "frob2_nonpositive");
    }

    ts_septq_params sp;
    sp.septq_ratio       = 0.98f;  // matches outlier_fraction's documented
                                   // [0.0001,0.05] range (tessera-policy.h)
    sp.septq_iterations  = 1;      // C++ port is single-pass regardless
                                   // (validated, never re-read)
    sp.ternary_threshold = 1.0f;   // ts_policy_genes default (legacy)
    sp.hessian_mode       = TS_SEPTQ_HESSIAN_BANDED;  // silently downgrades
                                   // to diagonal without activations
    sp.hessian_bandwidth  = std::min<int64_t>(64, ctx.in_dim - 1);
    sp.importance_weight  = TS_SEPTQ_IMP_QUANT_ERROR_H;
    sp.importance_lambda  = 0.0f;
    sp.ridge_fraction     = 1.0e-4f;

    ts_septq_result res;
    // No calibration corpus threaded through ts_eval_tensor_ctx yet (phase
    // 1 scope); activations=nullptr downgrades the Hessian mode to
    // diagonal, same fallback every other calibration-free call site uses.
    const int rc = ts_septq_quantize_2d(ctx.weights, ctx.out_dim, ctx.in_dim,
                                        /*activations=*/nullptr, /*n_tokens=*/0,
                                        ctx.act_scales, &sp, &res);
    if (rc != 0) {
        char reason[64];
        std::snprintf(reason, sizeof(reason), "septq_quantize_2d_rc_%d", rc);
        return ts_eval_fallback_to_proxy(TS_EXPERT_SEPTQ, ctx, opts, out, reason);
    }

    // SEPTQ Tier-2 dequant-scoring adapter (contracts appendix section A):
    // decode meta once per tile, dequantize every row via the production
    // T640 kernel, scatter the outlier CSR back in. Y is now exactly the
    // inference-visible reconstruction of ctx.weights -- do not recompute
    // scales from anything; packed/page_scales/lane_scales/outliers are
    // used as-is.
    const int64_t pages_per_row = (ctx.in_dim + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE;
    std::vector<float> page_max((size_t)(ctx.out_dim * pages_per_row));
    std::vector<float> lane_scale((size_t)(ctx.out_dim * pages_per_row * TILE640_LANES_PER_PAGE));

    const bool accel_meta = ts_t640_meta_accel_wins(ctx.out_dim, pages_per_row)
                            && ggml_tessera_t640_accel_enabled();
    ts_decode_per_row_meta(res.page_scales.data(), res.lane_scales.data(),
                           ctx.out_dim, pages_per_row,
                           page_max.data(), lane_scale.data(), accel_meta);

    std::vector<float> Y((size_t)n);
    for (int64_t r = 0; r < ctx.out_dim; r++) {
        dequantize_row_tessera_t640_with_meta(
            &res.packed[(size_t)r * pages_per_row * TILE640_WORDS_PER_PAGE],
            &page_max[(size_t)r * pages_per_row],
            &lane_scale[(size_t)r * pages_per_row * TILE640_LANES_PER_PAGE],
            ctx.in_dim, &Y[(size_t)r * ctx.in_dim]);
    }

    const int64_t n_outliers = res.outlier_row_offsets.empty()
        ? 0 : res.outlier_row_offsets[(size_t)ctx.out_dim];
    const bool accel_outlier = ts_t640_outlier_accel_wins(n_outliers)
                               && ggml_tessera_t640_accel_enabled();
    ts_apply_outlier_addback(Y.data(), ctx.in_dim, ctx.out_dim,
                             res.outlier_row_offsets.data(),
                             res.outlier_cols.data(),
                             res.outlier_vals.data(), accel_outlier);

    double sse = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const double d = (double)Y[(size_t)i] - (double)ctx.weights[i];
        sse += d * d;
    }
    const float mse = (float)(sse / (double)n);

    out->mse = mse;
    out->t2  = mse * (float)n / frob2;
    out->from_cache = false;
    std::snprintf(out->aux, sizeof(out->aux),
                 "{\"expert\":\"septq\",\"tier\":\"real\",\"septq_ratio\":%.4f,"
                 "\"bandwidth\":%lld,\"n_outliers\":%lld}",
                 (double)sp.septq_ratio, (long long)sp.hessian_bandwidth,
                 (long long)n_outliers);
    return 0;
}

// ---------------------------------------------------------------------------
// REAL tier dispatcher.
// ---------------------------------------------------------------------------

static int ts_eval_run_real(ts_expert_id expert,
                            const ts_eval_tensor_ctx & ctx,
                            const ts_eval_opts & opts,
                            ts_eval_result * out) {
    switch (expert) {
        case TS_EXPERT_AWQ: {
            // Identical to PROXY by construction: the T640 core with the
            // actual alpha/clip IS the real AWQ-family evaluation.
            ts_eval_proxy_score(TS_EXPERT_AWQ, ctx, opts, out);
            out->from_cache = false;
            std::snprintf(out->aux, sizeof(out->aux),
                         "{\"expert\":\"awq\",\"tier\":\"real\"}");
            return 0;
        }
        case TS_EXPERT_DARTQUANT:
            return ts_eval_real_dartquant(ctx, opts, out);
        case TS_EXPERT_FLRQ:
            return ts_eval_real_flrq(ctx, opts, out);
        case TS_EXPERT_CHAMPQ:
            return ts_eval_real_champq(ctx, opts, out);
        case TS_EXPERT_SEPTQ:
            return ts_eval_real_septq(ctx, opts, out);
        case TS_EXPERT_LRQ:
        default:
            // No distinct REAL recipe is named for LRQ in phase 1 (only
            // AWQ/DARTQUANT/FLRQ/SEPTQ/CHAMPQ have one) -- fall back openly
            // rather than silently borrowing another expert's algorithm.
            return ts_eval_fallback_to_proxy(expert, ctx, opts, out,
                                             "no_real_recipe_phase1");
    }
}

// ---------------------------------------------------------------------------
// KERNEL_DIRECT tier: migrated from ts_dispatch_kernel_direct_t2. Falls
// back to REAL (per the enum contract) when no sidecar is available or it
// is malformed/shape-mismatched.
// ---------------------------------------------------------------------------

static int ts_eval_run_kernel_direct(ts_expert_id expert,
                                     const ts_eval_tensor_ctx & ctx,
                                     const ts_eval_opts & opts,
                                     ts_eval_result * out) {
    if (ctx.sidecar_dir != nullptr && ctx.sidecar_dir[0] != '\0' &&
        ctx.name != nullptr && ctx.weights != nullptr) {
        const int64_t n = ctx.out_dim * ctx.in_dim;
        std::vector<float> kdeq;
        int64_t rows = 0, cols = 0;
        if (ts_l1_load_sidecar(ctx.sidecar_dir, ctx.name, &kdeq, &rows, &cols) == 0 &&
            (int64_t)kdeq.size() == n) {
            // ts_l1_kernel_direct_t2_tail measures ||w_hat - dequant_kernel||^2
            // / ||w_original||^2; the caller has the source but no separate
            // w_hat, so both arguments are ctx.weights (matches
            // ts_dispatch_kernel_direct_t2's contract exactly).
            out->t2  = ts_l1_kernel_direct_t2_tail(ctx.weights, ctx.weights,
                                                   kdeq.data(), n,
                                                   opts.l6_tail_tau,
                                                   opts.l6_tail_weight);
            out->mse = 0.0f;  // tail-weighted metric, not a plain MSE
            out->from_cache = false;
            std::snprintf(out->aux, sizeof(out->aux),
                         "{\"expert\":\"%s\",\"tier\":\"kernel_direct\"}",
                         ts_expert_name(expert));
            return 0;
        }
    }
    // No sidecar / malformed / shape mismatch: fall back to REAL. The
    // caller distinguishes "kernel_direct requested, real delivered" by
    // the tier string inside aux not reading "kernel_direct".
    return ts_eval_run_real(expert, ctx, opts, out);
}

// ---------------------------------------------------------------------------
// Eval-cache digest helpers (phase 2). None of these touch the DB -- pure
// string/hash functions of the call's own inputs, so the seam's
// determinism/purity contract is unaffected by whether caching is active.
// ---------------------------------------------------------------------------

static const char * ts_eval_tier_name(ts_eval_tier tier) {
    switch (tier) {
        case TS_EVAL_REAL:           return "real";
        case TS_EVAL_KERNEL_DIRECT:  return "kernel_direct";
        case TS_EVAL_PROXY:
        default:                     return "proxy";
    }
}

// "expert:<Name>:<tier>" -- distinguishes PROXY/REAL/KERNEL_DIRECT
// measurements of the same expert so they never collide in the cache.
static std::string ts_eval_digest_evaluator(ts_expert_id expert, ts_eval_tier tier) {
    std::string s = "expert:";
    s += ts_expert_name(expert);
    s += ":";
    s += ts_eval_tier_name(tier);
    return s;
}

// Grid-quantizes the continuous knobs to 1e-4 so near-duplicate candidates
// (once the GA converts to the seam) collapse onto the same cache row
// instead of missing on floating-point noise -- matches the "genes grid-
// quantized at 1e-4" adoption-order note in the implementation spec.
static std::string ts_eval_digest_params(const ts_eval_opts & opts) {
    auto q = [](float v) -> int64_t {
        return (int64_t)std::lround((double)v * 1.0e4);
    };
    char buf[192];
    std::snprintf(buf, sizeof(buf),
                 "a=%lld,c=%lld,s=%u,tt=%lld,tw=%lld",
                 (long long)q(opts.alpha), (long long)q(opts.clip),
                 (unsigned)opts.seed, (long long)q(opts.l6_tail_tau),
                 (long long)q(opts.l6_tail_weight));
    std::string digest = buf;
    if (!opts.kv_codec_digest.empty()) {
        digest += ",kv=";
        digest += opts.kv_codec_digest;
    }
    return digest;
}

// FNV-1a: not cryptographic, just needs to distinguish "same bytes" from
// "different bytes" cheaply. Used only as a fallback when the caller has
// not supplied a more precise ctx.input_digest (e.g. an imatrix digest).
static uint64_t ts_eval_fnv1a(const void * data, size_t n) {
    const uint8_t * p = (const uint8_t *)data;
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ull;
    }
    return h;
}

static std::string ts_eval_digest_input(const ts_eval_tensor_ctx & ctx) {
    if (!ctx.input_digest.empty()) {
        return ctx.input_digest;  // caller-supplied, e.g. an imatrix digest
    }
    if (ctx.act_scales == nullptr || ctx.in_dim <= 0) {
        return "no_act_scales";
    }
    const uint64_t h = ts_eval_fnv1a(ctx.act_scales, (size_t)ctx.in_dim * sizeof(float));
    char buf[32];
    std::snprintf(buf, sizeof(buf), "act:%016llx", (unsigned long long)h);
    return buf;
}

// ---------------------------------------------------------------------------
// Public entry point.
// ---------------------------------------------------------------------------

int ts_expert_eval(ts_expert_id expert,
                   const ts_eval_tensor_ctx & ctx,
                   const ts_eval_opts & opts,
                   ts_eval_result * out) {
    if (out == nullptr || ctx.weights == nullptr ||
        ctx.out_dim <= 0 || ctx.in_dim <= 0) {
        return -1;
    }

    // Eval cache (phase 2): memoized read-through. Any of
    // db/model_hash/name missing means "run fresh, do not cache" -- the
    // same db==nullptr-is-a-safe-no-op convention every other DB helper in
    // this codebase follows.
    const bool cache_eligible = ctx.db != nullptr && !ctx.model_hash.empty()
                               && ctx.name != nullptr;
    std::string evaluator, params_digest, input_digest;
    const std::string model_role = ctx.model_role.empty() ? "trunk" : ctx.model_role;

    if (cache_eligible) {
        evaluator     = ts_eval_digest_evaluator(expert, opts.tier);
        params_digest = ts_eval_digest_params(opts);
        input_digest  = ts_eval_digest_input(ctx);

        float cached_t2 = 0.0f;
        std::string cached_aux;
        bool hit = false;
        ts_tessera_db_read_eval_cache(ctx.db, ctx.model_hash, model_role,
            ctx.name, evaluator, params_digest, input_digest,
            TS_EXPERT_EVAL_VERSION, &cached_t2, &cached_aux, &hit, nullptr);
        if (hit) {
            out->t2  = cached_t2;
            out->mse = 0.0f;  // not cached (see ts_eval_result::mse comment)
            out->from_cache = true;
            std::snprintf(out->aux, sizeof(out->aux), "%s", cached_aux.c_str());
            return 0;
        }
    }

    int rc;
    switch (opts.tier) {
        case TS_EVAL_KERNEL_DIRECT:
            rc = ts_eval_run_kernel_direct(expert, ctx, opts, out);
            break;
        case TS_EVAL_REAL:
            rc = ts_eval_run_real(expert, ctx, opts, out);
            break;
        case TS_EVAL_PROXY:
        default:
            rc = ts_eval_run_proxy(expert, ctx, opts, out);
            break;
    }

    if (rc == 0 && cache_eligible) {
        ts_tessera_db_append_eval_cache_ledger(ctx.db, "cache_compute",
            ctx.model_hash, model_role, ctx.name, evaluator,
            params_digest, input_digest, TS_EXPERT_EVAL_VERSION, nullptr);

        ts_tessera_db_eval_cache_entry e;
        e.model_hash    = ctx.model_hash;
        e.model_role    = model_role;
        e.tensor_name   = ctx.name;
        e.evaluator     = evaluator;
        e.params_digest = params_digest;
        e.input_digest  = input_digest;
        e.eval_version  = TS_EXPERT_EVAL_VERSION;
        e.t2            = out->t2;
        e.aux           = out->aux;
        bool stored = false;
        ts_tessera_db_write_eval_cache(ctx.db, e, &stored, nullptr);
    }

    return rc;
}
