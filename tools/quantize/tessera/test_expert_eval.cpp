//
// test_expert_eval.cpp
//
// Correctness tests for the ts_expert_eval seam (pipeline refactor phase 1,
// see tessera-expert-eval.h and docs/tessera-refactor-implementation-spec.md
// section 1):
//   1. PROXY tier matches ts_dispatch_forced_t2's exact algorithm (profile
//      alpha/clip -> streaming MSE -> mse*n/frob2), recomputed here via the
//      same public primitives forced_t2 used (dispatch.cpp:444-465 @
//      703a62475) since forced_t2 itself is a file-local static.
//   2. REAL tier per expert (AWQ/DARTQUANT/FLRQ/CHAMPQ/SEPTQ) returns a
//      finite, non-negative t2 on a deterministic fixture with no silent
//      proxy fallback; LRQ (no phase-1 recipe) falls back openly.
//   3. SEPTQ REAL matches a hand-computed dequant reconstruction error
//      within 1e-6.
//   4. DARTQUANT/CHAMPQ invariance sanity: an EXPLICIT identity
//      rotation/permutation leaves the frob2-normalized streaming MSE
//      unchanged, validating the "score in the transformed space, normalize
//      against the ORIGINAL frob2" assumption both real-tier adapters make.
//   5. KERNEL_DIRECT falls back to REAL when no sidecar is configured.
//

#include "tessera-expert-eval.h"

#include "tessera-quant.h"
#include "tessera-vec.h"
#include "tessera-regime.h"
#include "tessera-dartquant.h"
#include "tessera-champq.h"
#include "tessera-septq.h"

#include "ggml-quants.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int g_failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__);     \
            g_failures++;                                                   \
        }                                                                   \
    } while (0)

// Deterministic xorshift RNG (matches the convention test_septq.cpp uses).
static std::vector<float> make_fixture(int64_t out_dim, int64_t in_dim, uint32_t seed) {
    std::vector<float> w((size_t)(out_dim * in_dim));
    uint32_t s = seed ? seed : 1;
    for (auto & v : w) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        v = ((float)(s >> 8) * (1.0f / 16777216.0f)) * 2.0f - 1.0f;
    }
    return w;
}

static const char * tier_of(const char * aux) {
    if (std::strstr(aux, "\"tier\":\"real\"") != nullptr) return "real";
    if (std::strstr(aux, "\"tier\":\"kernel_direct\"") != nullptr) return "kernel_direct";
    return "proxy";
}

static bool has_fallback(const char * aux) {
    return std::strstr(aux, "\"fallback\"") != nullptr;
}

int main() {
    // out_dim/in_dim chosen so every rank candidate FLRQ tries (up to 64) is
    // well below min(out_dim,in_dim) -- a fixture where the max candidate
    // rank equals out_dim lets low-rank factorization reconstruct exactly,
    // which would mask a genuine bug behind a trivially-zero t2.
    const int64_t out_dim = 96, in_dim = 512;
    std::vector<float> W = make_fixture(out_dim, in_dim, 12345);
    const int64_t n = out_dim * in_dim;

    ts_eval_tensor_ctx ctx;
    ctx.name      = "test.tensor";
    ctx.weights   = W.data();
    ctx.act_scales = nullptr;
    ctx.out_dim   = out_dim;
    ctx.in_dim    = in_dim;

    // ---- 1. PROXY tier: matches forced_t2's exact algorithm ----
    for (int e = 0; e < TS_EXPERT_COUNT; e++) {
        ts_expert_id expert = (ts_expert_id)e;
        ts_eval_opts opts;
        opts.tier  = TS_EVAL_PROXY;
        opts.alpha = 0.5f;
        opts.clip  = 0.95f;
        opts.seed  = 7;

        ts_eval_result out;
        int rc = ts_expert_eval(expert, ctx, opts, &out);
        CHECK(rc == 0, "proxy: rc == 0");

        ts_expert_profile prof = ts_expert_default_profile(expert);
        const float expected_mse = ts_quantize_mse_streaming(
            W.data(), nullptr, opts.alpha * prof.alpha_scale, opts.clip * prof.clip_scale,
            out_dim, in_dim);
        const float frob2 = ts_vec_dotpr(W.data(), W.data(), n);
        const float expected_t2 = (frob2 > 0.0f) ? (expected_mse * (float)n / frob2) : expected_mse;

        char msg[128];
        std::snprintf(msg, sizeof(msg), "proxy: expert %d t2 matches forced_t2's algorithm", e);
        CHECK(std::fabs(out.t2 - expected_t2) < 1e-12f, msg);
        CHECK(std::strstr(out.aux, "\"tier\":\"proxy\"") != nullptr, "proxy: aux tags tier=proxy");
    }
    std::printf("PROXY tier: %d experts checked\n", TS_EXPERT_COUNT);

    // ---- 2. REAL tier per expert: finite, non-negative, no silent fallback ----
    {
        const ts_expert_id real_experts[] = { TS_EXPERT_AWQ, TS_EXPERT_DARTQUANT,
                                              TS_EXPERT_FLRQ, TS_EXPERT_CHAMPQ, TS_EXPERT_SEPTQ };
        for (ts_expert_id expert : real_experts) {
            ts_eval_opts opts;
            opts.tier  = TS_EVAL_REAL;
            opts.alpha = 0.5f;
            opts.clip  = 0.95f;
            opts.seed  = 7;

            ts_eval_result out;
            int rc = ts_expert_eval(expert, ctx, opts, &out);
            CHECK(rc == 0, "real: rc == 0");
            CHECK(std::isfinite(out.t2) && out.t2 >= 0.0f, "real: t2 finite and non-negative");
            CHECK(!has_fallback(out.aux), "real: no silent proxy fallback");
            CHECK(std::strcmp(tier_of(out.aux), "real") == 0, "real: aux tags tier=real");
            std::printf("  expert=%-10s t2=%.6f aux=%s\n",
                       ts_expert_name(expert), (double)out.t2, out.aux);
        }
    }

    // ---- 2b. CHAMPQ with non-null act_scales: gather-direction regression ----
    // The shared fixture above always passes act_scales=nullptr, which would
    // leave the act_scales permutation gather in ts_eval_real_champq with
    // zero coverage -- a wrong gather direction silently corrupts every
    // activation-weighted score without ever failing a test. Build a
    // distinguishing act_scales vector and check against an independently
    // hand-computed reference using the correct (documented) gather
    // direction, then confirm the WRONG direction would have scored
    // differently (proves this case actually discriminates).
    {
        std::vector<float> act((size_t)in_dim);
        {
            uint32_t s = 999;
            for (auto & v : act) {
                s ^= s << 13; s ^= s >> 17; s ^= s << 5;
                v = 0.1f + ((float)(s >> 8) * (1.0f / 16777216.0f));  // positive, distinguishing
            }
        }
        ts_eval_tensor_ctx act_ctx = ctx;
        act_ctx.act_scales = act.data();

        ts_eval_opts opts;
        opts.tier = TS_EVAL_REAL; opts.alpha = 0.5f; opts.clip = 0.95f; opts.seed = 7;
        ts_eval_result out;
        int rc = ts_expert_eval(TS_EXPERT_CHAMPQ, act_ctx, opts, &out);
        CHECK(rc == 0, "champq+act_scales: rc == 0");
        CHECK(!has_fallback(out.aux), "champq+act_scales: no silent proxy fallback");

        ts_champq_params cp;
        cp.max_iters = 100; cp.sinkhorn_iters = 25; cp.use_lbfgs = true;
        cp.seed = 7; cp.act_scales = act.data(); cp.binariness = 1.0e-3f;
        cp.history = 8; cp.projection = 0; cp.init = 0;
        ts_champq_result cr;
        const int crc = ts_champq_compute(W.data(), out_dim, in_dim, &cp, &cr);
        CHECK(crc == 0, "champq+act_scales: hand-recompute succeeded");

        std::vector<float> wperm((size_t)n);
        ts_champq_apply(W.data(), cr.perm.data(), wperm.data(), out_dim, in_dim);
        std::vector<float> act_perm((size_t)in_dim);
        for (int64_t j = 0; j < in_dim; j++) act_perm[(size_t)j] = act[(size_t)cr.perm[(size_t)j]];

        const float hand_mse = ts_quantize_mse_streaming(wperm.data(), act_perm.data(), 0.5f, 0.95f, out_dim, in_dim);
        const float frob2 = ts_vec_dotpr(W.data(), W.data(), n);
        const float hand_t2 = hand_mse * (float)n / frob2;

        char msg[160];
        std::snprintf(msg, sizeof(msg),
                     "champq+act_scales: t2 matches correct-gather hand-computation (adapter=%.9f hand=%.9f)",
                     (double)out.t2, (double)hand_t2);
        CHECK(std::fabs(out.t2 - hand_t2) < 1e-6f, msg);

        std::vector<int32_t> inv((size_t)in_dim);
        ts_champq_invert(cr.perm.data(), inv.data(), in_dim);
        std::vector<float> act_perm_wrong((size_t)in_dim);
        for (int64_t j = 0; j < in_dim; j++) act_perm_wrong[(size_t)j] = act[(size_t)inv[(size_t)j]];
        const float wrong_mse = ts_quantize_mse_streaming(wperm.data(), act_perm_wrong.data(), 0.5f, 0.95f, out_dim, in_dim);
        CHECK(std::fabs(wrong_mse - hand_mse) > 1e-9f,
              "champq+act_scales: sanity -- wrong gather direction gives a measurably different score");
    }

    // LRQ has no phase-1 REAL recipe: must fall back openly, not silently.
    {
        ts_eval_opts opts;
        opts.tier = TS_EVAL_REAL;
        opts.alpha = 0.5f; opts.clip = 0.95f; opts.seed = 7;
        ts_eval_result out;
        int rc = ts_expert_eval(TS_EXPERT_LRQ, ctx, opts, &out);
        CHECK(rc == 0, "lrq real: rc == 0");
        CHECK(has_fallback(out.aux), "lrq real: falls back openly (no phase-1 recipe)");
    }

    // ---- 3. SEPTQ REAL: hand-computed dequant error within 1e-6 ----
    {
        ts_eval_opts opts;
        opts.tier = TS_EVAL_REAL; opts.seed = 7;
        ts_eval_result out;
        int rc = ts_expert_eval(TS_EXPERT_SEPTQ, ctx, opts, &out);
        CHECK(rc == 0, "septq: rc == 0");
        CHECK(!has_fallback(out.aux), "septq: no silent proxy fallback");

        // Hand-reproduce the exact recipe the adapter uses.
        ts_septq_params sp;
        sp.septq_ratio        = 0.98f;
        sp.septq_iterations   = 1;
        sp.ternary_threshold  = 1.0f;
        sp.hessian_mode        = TS_SEPTQ_HESSIAN_BANDED;
        sp.hessian_bandwidth   = std::min<int64_t>(64, in_dim - 1);
        sp.importance_weight   = TS_SEPTQ_IMP_QUANT_ERROR_H;
        sp.importance_lambda   = 0.0f;
        sp.ridge_fraction      = 1e-4f;

        ts_septq_result res;
        const int src_rc = ts_septq_quantize_2d(W.data(), out_dim, in_dim,
                                                nullptr, 0, nullptr, &sp, &res);
        CHECK(src_rc == 0, "septq: hand-recompute quantize succeeded");

        const int64_t pages_per_row = (in_dim + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE;
        std::vector<float> page_max((size_t)(out_dim * pages_per_row));
        std::vector<float> lane_scale((size_t)(out_dim * pages_per_row * TILE640_LANES_PER_PAGE));
        ts_decode_per_row_meta(res.page_scales.data(), res.lane_scales.data(),
                              out_dim, pages_per_row, page_max.data(), lane_scale.data(), false);

        std::vector<float> Y((size_t)n);
        for (int64_t r = 0; r < out_dim; r++) {
            dequantize_row_tessera_t640_with_meta(
                &res.packed[(size_t)r * pages_per_row * TILE640_WORDS_PER_PAGE],
                &page_max[(size_t)r * pages_per_row],
                &lane_scale[(size_t)r * pages_per_row * TILE640_LANES_PER_PAGE],
                in_dim, &Y[(size_t)r * in_dim]);
        }
        const int64_t n_out = res.outlier_row_offsets.empty()
            ? 0 : res.outlier_row_offsets[(size_t)out_dim];
        ts_apply_outlier_addback(Y.data(), in_dim, out_dim,
                                 res.outlier_row_offsets.data(), res.outlier_cols.data(),
                                 res.outlier_vals.data(), ts_t640_outlier_accel_wins(n_out));

        double sse = 0.0;
        for (int64_t i = 0; i < n; i++) {
            const double d = (double)Y[(size_t)i] - (double)W[(size_t)i];
            sse += d * d;
        }
        const float hand_mse = (float)(sse / (double)n);
        const float frob2 = ts_vec_dotpr(W.data(), W.data(), n);
        const float hand_t2 = hand_mse * (float)n / frob2;

        char msg[160];
        std::snprintf(msg, sizeof(msg),
                     "septq: t2 matches hand-computed dequant (adapter=%.9f hand=%.9f)",
                     (double)out.t2, (double)hand_t2);
        CHECK(std::fabs(out.t2 - hand_t2) < 1e-6f, msg);
    }

    // ---- 4. DARTQUANT invariance: identity rotation preserves streaming MSE ----
    {
        const int64_t K = 64;  // divides in_dim = 128
        std::vector<float> Iden((size_t)(K * K), 0.0f);
        for (int64_t i = 0; i < K; i++) Iden[(size_t)(i * K + i)] = 1.0f;

        std::vector<float> Wrot((size_t)n);
        ts_dartquant_apply(W.data(), Iden.data(), Wrot.data(), out_dim, in_dim, K);

        const float mse_orig = ts_quantize_mse_streaming(W.data(), nullptr, 0.5f, 0.95f, out_dim, in_dim);
        const float mse_rot  = ts_quantize_mse_streaming(Wrot.data(), nullptr, 0.5f, 0.95f, out_dim, in_dim);
        char msg[160];
        std::snprintf(msg, sizeof(msg),
                     "dartquant: identity rotation leaves streaming MSE unchanged (orig=%.9f rot=%.9f)",
                     (double)mse_orig, (double)mse_rot);
        CHECK(std::fabs(mse_orig - mse_rot) < 1e-5f, msg);
    }

    // ---- 5. CHAMPQ invariance: identity permutation preserves streaming MSE ----
    {
        std::vector<int32_t> perm((size_t)in_dim);
        for (int64_t j = 0; j < in_dim; j++) perm[(size_t)j] = (int32_t)j;

        std::vector<float> Wperm((size_t)n);
        ts_champq_apply(W.data(), perm.data(), Wperm.data(), out_dim, in_dim);

        const float mse_orig = ts_quantize_mse_streaming(W.data(), nullptr, 0.5f, 0.95f, out_dim, in_dim);
        const float mse_perm = ts_quantize_mse_streaming(Wperm.data(), nullptr, 0.5f, 0.95f, out_dim, in_dim);
        char msg[160];
        std::snprintf(msg, sizeof(msg),
                     "champq: identity permutation leaves streaming MSE unchanged (orig=%.9f perm=%.9f)",
                     (double)mse_orig, (double)mse_perm);
        CHECK(std::fabs(mse_orig - mse_perm) < 1e-6f, msg);
    }

    // ---- 6. KERNEL_DIRECT: no sidecar -> falls back to REAL ----
    {
        ts_eval_opts opts;
        opts.tier = TS_EVAL_KERNEL_DIRECT;
        opts.alpha = 0.5f; opts.clip = 0.95f; opts.seed = 7;
        opts.l6_tail_tau = 1.0f; opts.l6_tail_weight = 0.1f;
        ts_eval_result out;
        const int rc = ts_expert_eval(TS_EXPERT_DARTQUANT, ctx, opts, &out);
        CHECK(rc == 0, "kernel_direct: rc == 0");
        CHECK(std::strcmp(tier_of(out.aux), "real") == 0,
              "kernel_direct: falls back to real when no sidecar_dir set");
    }

    // ---- 7. Invalid args: rc != 0 ----
    {
        ts_eval_tensor_ctx bad_ctx;
        bad_ctx.weights = nullptr;
        ts_eval_opts opts;
        ts_eval_result out;
        const int rc = ts_expert_eval(TS_EXPERT_AWQ, bad_ctx, opts, &out);
        CHECK(rc != 0, "invalid ctx: rc != 0");
    }

    std::printf("\n%s (%d failures)\n", g_failures == 0 ? "PASS" : "FAIL", g_failures);
    return g_failures == 0 ? 0 : 1;
}
