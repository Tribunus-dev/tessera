//
// test_ppl_harness.cpp
//
// FP-only sanity test for ts_l5_ppl_joint_measure. Five synthetic
// models (target + DFlash + DSPark + MTP + talker) with uniform random
// logits. The expected PPL of uniform random logits over a vocab of
// size V is V (each token has probability 1/V, so PPL = exp(-log(1/V)) = V).
//
// Gate: each model's FP PPL is within 5% of its vocab size (the
// tolerance accommodates the finite-sample variance over 256 random
// tokens), and the AND-gate passes trivially (all models inactive in
// the policy).
//
// Phase: v1 of plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d.md.
//

#include "tessera-ppl-harness.h"
#include "tessera-ppl.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

static int g_fail = 0;

static void check(const char * name, bool ok, const char * detail = nullptr) {
    std::printf("%s %s%s%s\n",
            ok ? "ok  " : "FAIL",
            name,
            detail ? " - " : "",
            detail ? detail : "");
    if (!ok) ++g_fail;
}

// --- Synthetic model context: holds the RNG state per model ---

struct synth_ctx {
    std::mt19937 rng;
    int32_t vocab_size;
};

// --- Synthetic trunk forward: all-zero logits -> softmax = 1/V, PPL = V exactly ---

static void synth_trunk_forward(
        const int32_t * tokens,
        int32_t n_tokens,
        float * trunk_logits_out,
        float * trunk_final_output_out,
        void * ctx) {
    (void)tokens;
    auto * c = static_cast<synth_ctx *>(ctx);
    const size_t n_logits = (size_t)n_tokens * (size_t)c->vocab_size;
    for (size_t i = 0; i < n_logits; ++i) {
        trunk_logits_out[i] = 0.0f;
    }
    // Trunk final output: all-zero (v1 simplification; the synthetic
    // drafter/talker forwards ignore this anyway).
    const size_t n_hidden = (size_t)n_tokens * (size_t)c->vocab_size;
    for (size_t i = 0; i < n_hidden; ++i) {
        trunk_final_output_out[i] = 0.0f;
    }
}

// --- Synthetic drafter forward: all-zero logits, ignores the hidden state ---

static void synth_drafter_forward(
        const float * hidden_state_in,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * drafter_logits_out,
        void * ctx) {
    (void)hidden_state_in;
    (void)hidden_dim;
    auto * c = static_cast<synth_ctx *>(ctx);
    const size_t n_logits = (size_t)n_tokens * (size_t)c->vocab_size;
    for (size_t i = 0; i < n_logits; ++i) {
        drafter_logits_out[i] = 0.0f;
    }
}

// --- Synthetic talker forward: all-zero audio logits, ignores the trunk output ---

static void synth_talker_forward(
        const float * trunk_final_output,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * talker_logits_out,
        void * ctx) {
    (void)trunk_final_output;
    (void)hidden_dim;
    auto * c = static_cast<synth_ctx *>(ctx);
    const size_t n_logits = (size_t)n_tokens * (size_t)c->vocab_size;
    for (size_t i = 0; i < n_logits; ++i) {
        talker_logits_out[i] = 0.0f;
    }
}

int main() {
    // ---- Set up the harness with 5 synthetic models ----

    ts_l5_ppl_harness h;
    h.vocab_size[TS_L5_MODEL_TARGET] = 32000;  // LLaMA-style vocab
    h.vocab_size[TS_L5_MODEL_DFLASH] = 32000;
    h.vocab_size[TS_L5_MODEL_DSPARK] = 32000;
    h.vocab_size[TS_L5_MODEL_MTP]    = 32000;
    h.vocab_size[TS_L5_MODEL_TALKER] = 4096;   // audio codec vocab
    h.n_tokens = 256;
    h.rng_seed = 42;

    synth_ctx target_ctx  { std::mt19937(0xC0FFEEu), h.vocab_size[TS_L5_MODEL_TARGET] };
    synth_ctx dflash_ctx  { std::mt19937(0xDF1A50u), h.vocab_size[TS_L5_MODEL_DFLASH] };
    synth_ctx dspark_ctx  { std::mt19937(0xD5A12Cu), h.vocab_size[TS_L5_MODEL_DSPARK] };
    synth_ctx mtp_ctx     { std::mt19937(0x71F1234u), h.vocab_size[TS_L5_MODEL_MTP] };
    synth_ctx talker_ctx  { std::mt19937(0x7A1CE12u), h.vocab_size[TS_L5_MODEL_TALKER] };

    h.model_ctx[TS_L5_MODEL_TARGET] = &target_ctx;
    h.model_ctx[TS_L5_MODEL_DFLASH] = &dflash_ctx;
    h.model_ctx[TS_L5_MODEL_DSPARK] = &dspark_ctx;
    h.model_ctx[TS_L5_MODEL_MTP]    = &mtp_ctx;
    h.model_ctx[TS_L5_MODEL_TALKER] = &talker_ctx;

    ts_l5_drafter_forward_fn drafter_fns[TS_L5_MODEL_COUNT] = {
        nullptr,            // target: not a drafter
        synth_drafter_forward,  // DFlash
        synth_drafter_forward,  // DSPark
        synth_drafter_forward,  // MTP
        nullptr,            // talker: not a drafter
    };

    // ---- Policy: all inactive (FP-only, v1 sanity) ----

    ts_l5_joint_policy policy;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        policy.models_active[m] = false;
        for (int f = 0; f < TS_L5_FAMILY_COUNT; ++f) {
            policy.families[m][f] = ts_l5_family_policy{};
        }
    }

    ts_l5_joint_params params;
    params.epsilon = 0.0099f;  // 0.99%
    params.verbose  = true;

    // ---- Run the joint measurement ----

    ts_l5_ppl_joint_result result;
    int rc = ts_l5_ppl_joint_measure(
            &h,
            synth_trunk_forward,
            drafter_fns,
            synth_talker_forward,
            &policy,
            &params,
            &result);

    check("ts_l5_ppl_joint_measure returns 0", rc == 0, rc == 0 ? nullptr : "non-zero return code");
    if (rc != 0) {
        std::printf("\nFAIL (harness error)\n");
        return 1;
    }

    // ---- Assertions ----

    // (1) n_tokens_used matches the harness config
    check("n_tokens_used = 256", result.n_tokens_used == 256);

    // (2) per-model PPL is exactly the vocab size (all-zero logits ->
    //     softmax is 1/V, PPL = exp(-log(1/V)) = V exactly).
    const float tolerance = 0.001f;  // 0.1% relative tolerance (numerical FP noise)
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        const float expected = (float)h.vocab_size[m];
        const float actual   = result.per_model[m].ppl_fp;
        const float rel_err  = std::fabs(actual - expected) / expected;
        char detail[128];
        std::snprintf(detail, sizeof(detail),
                "model=%d expected=%.0f actual=%.4f rel_err=%.6f",
                m, expected, actual, rel_err);
        check("per-model FP PPL = vocab size", rel_err < tolerance, detail);
    }

    // (3) all_pass is true (all inactive models, no deltas)
    check("all_pass (no active models)", result.all_pass);

    // (4) per-model deltas are 0 (inactive = FP = FP, delta=0)
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        char detail[128];
        std::snprintf(detail, sizeof(detail), "model=%d delta=%.6f", m, result.per_model[m].delta);
        check("per-model delta = 0 (inactive)", result.per_model[m].delta == 0.0f, detail);
    }

    // (5) AND-gate: passes for any epsilon > 0 when all models are
    //     inactive. (Tests the AND-gate helper directly.)
    check("AND-gate (inactive models) passes for epsilon=0.01",
          ts_l5_joint_and_gate(&result, &policy, 0.01f));
    check("AND-gate (inactive models) passes for epsilon=0.0",
          ts_l5_joint_and_gate(&result, &policy, 0.0f));

    // ---- Summary ----

    std::printf("\nper-model FP PPL:\n");
    const char * model_names[TS_L5_MODEL_COUNT] = {
        "target", "dflash", "dspark", "mtp", "talker"
    };
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        std::printf("  %-8s  ppl_fp=%.2f  (vocab=%d)\n",
                model_names[m],
                result.per_model[m].ppl_fp,
                h.vocab_size[m]);
    }

    if (g_fail == 0) {
        std::printf("\nALL OK\n");
        return 0;
    } else {
        std::printf("\nFAIL (%d checks failed)\n", g_fail);
        return 1;
    }
}
