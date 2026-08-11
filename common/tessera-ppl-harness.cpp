//
// tessera-ppl-harness.cpp
//
// Joint perplexity harness implementation. See tessera-ppl-harness.h
// for the design (joint forward pass across target + 3 drafters + talker,
// per-model PPL extraction, AND-gate evaluation).
//
// v1: FP-only sanity. The quant path is skipped when all
// models_active[i] = false; the result is the FP PPL per model, all
// deltas are 0, the AND-gate is trivially satisfied.
//
// The harness does NOT own the model contexts. It is a driver: it
// allocates the per-pass logit + hidden-state buffers, calls the
// forward callbacks in the right order, and computes PPL via the
// existing ts_ppl_perplexity helper in tessera-ppl.h.
//

#include "tessera-ppl-harness.h"
#include "tessera-ppl.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// ---------------------------------------------------------------------------
// ts_l5_ppl_per_model_compute: thin wrapper around ts_ppl_perplexity
// ---------------------------------------------------------------------------

float ts_l5_ppl_per_model_compute(
        const float * logits,
        const int32_t * targets,
        int32_t n_tokens,
        int32_t vocab_size) {
    if (!logits || !targets || n_tokens <= 0 || vocab_size <= 0) {
        return -1.0f;
    }
    return ts_ppl_perplexity(logits, targets,
                             (int64_t)n_tokens, (int64_t)vocab_size);
}

// ---------------------------------------------------------------------------
// ts_l5_joint_and_gate
// ---------------------------------------------------------------------------

bool ts_l5_joint_and_gate(
        const ts_l5_ppl_joint_result * result,
        const ts_l5_joint_policy * policy,
        float epsilon) {
    if (!result || !policy) return false;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (!policy->models_active[m]) continue;  // inactive = FP baseline, skip
        if (!result->per_model[m].pass) return false;  // delta >= epsilon
        if (result->per_model[m].delta >= epsilon) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Token generation (data-free HIGGS-style probe, used when no calibration
// set is provided)
// ---------------------------------------------------------------------------

static uint32_t ts_l5_xorshift32(uint32_t * state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static void ts_l5_gen_tokens(int32_t * tokens, int32_t n_tokens,
                              int32_t vocab_size, uint32_t seed) {
    uint32_t rng = seed ? seed : 42;
    for (int32_t i = 0; i < n_tokens; ++i) {
        tokens[i] = (int32_t)(ts_l5_xorshift32(&rng) % (uint32_t)vocab_size);
    }
}

// ---------------------------------------------------------------------------
// ts_l5_ppl_joint_measure
// ---------------------------------------------------------------------------

int ts_l5_ppl_joint_measure(
        const ts_l5_ppl_harness * harness,
        ts_l5_trunk_forward_fn  trunk_forward,
        ts_l5_drafter_forward_fn drafter_forwards[TS_L5_MODEL_COUNT],
        ts_l5_talker_forward_fn talker_forward,
        const ts_l5_joint_policy * policy,
        const ts_l5_joint_params * params,
        ts_l5_ppl_joint_result * result) {
    if (!harness || !trunk_forward || !drafter_forwards || !talker_forward
            || !policy || !params || !result) {
        return -1;
    }

    const int32_t n_tokens = harness->n_tokens > 0 ? harness->n_tokens : 256;
    const int32_t v_target = harness->vocab_size[TS_L5_MODEL_TARGET];
    const int32_t v_talker = harness->vocab_size[TS_L5_MODEL_TALKER];

    // Hidden dim is approximated as the trunk's vocab size for v1's
    // synthetic models. Real hidden dim is set by the harness caller
    // at v3 when the ADAPTIVE muxer integration lands. For v1, the
    // synthetic forward callbacks just consume the first hidden_dim
    // floats; the test passes the same value for FP and quant so the
    // policy doesn't matter.
    const int32_t hidden_dim = v_target;  // v1 approximation

    // ---- Allocate buffers ----

    std::vector<int32_t> tokens(n_tokens);
    ts_l5_gen_tokens(tokens.data(), n_tokens, v_target, harness->rng_seed);

    // Talker targets: in the talker's audio vocab. v1's synthetic test
    // uses the same RNG with a different seed offset; v3 wires the
    // real text-to-audio target mapping. The targets are independent
    // of the text tokens because the talker is a different model with
    // a different output space.
    std::vector<int32_t> talker_targets(n_tokens);
    ts_l5_gen_tokens(talker_targets.data(), n_tokens, v_talker,
                     harness->rng_seed ^ 0xA110C0DEu);

    const size_t trunk_logits_bytes = (size_t)n_tokens * (size_t)v_target * sizeof(float);
    const size_t talker_logits_bytes = (size_t)n_tokens * (size_t)v_talker * sizeof(float);
    const size_t hidden_bytes = (size_t)n_tokens * (size_t)hidden_dim * sizeof(float);

    // FP path buffers
    std::vector<float> trunk_logits_fp(trunk_logits_bytes / sizeof(float));
    std::vector<float> trunk_final_fp(hidden_bytes / sizeof(float));
    std::vector<float> drafter_logits_fp[TS_L5_MODEL_COUNT];
    std::vector<float> talker_logits_fp(talker_logits_bytes / sizeof(float));

    // Quant path buffers (only used if any model is active)
    std::vector<float> trunk_logits_q;
    std::vector<float> trunk_final_q;
    std::vector<float> drafter_logits_q[TS_L5_MODEL_COUNT];
    std::vector<float> talker_logits_q;

    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (m == TS_L5_MODEL_TARGET || m == TS_L5_MODEL_TALKER) continue;
        const int32_t v = harness->vocab_size[m];
        drafter_logits_fp[m].resize((size_t)n_tokens * (size_t)v);
    }

    // ---- FP path: trunk -> drafters -> talker ----

    // Trunk forward. The trunk callback is responsible for filling
    // trunk_logits_fp and trunk_final_fp (for the talker). v1's
    // synthetic trunk just produces uniform random logits; the
    // trunk_final_fp is also uniform random (the synthetic test does
    // not depend on the trunk->drafter hidden state relationship).
    trunk_forward(
            tokens.data(), n_tokens,
            trunk_logits_fp.data(),
            trunk_final_fp.data(),
            harness->model_ctx[TS_L5_MODEL_TARGET]);

    // Drafter forwards: each drafter consumes trunk_final_fp as its
    // "hidden state" (v1 simplification; v3 wires the real per-block
    // hidden state via the drafter_target_layer index).
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (m == TS_L5_MODEL_TARGET || m == TS_L5_MODEL_TALKER) continue;
        if (!drafter_forwards[m]) continue;
        drafter_forwards[m](
                trunk_final_fp.data(), n_tokens, hidden_dim,
                drafter_logits_fp[m].data(),
                harness->model_ctx[m]);
    }

    // Talker forward: consumes the trunk's final output.
    if (talker_forward) {
        talker_forward(
                trunk_final_fp.data(), n_tokens, hidden_dim,
                talker_logits_fp.data(),
                harness->model_ctx[TS_L5_MODEL_TALKER]);
    }

    // ---- Quant path: only if any model is active ----

    bool any_active = false;
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (policy->models_active[m]) { any_active = true; break; }
    }

    if (any_active) {
        trunk_logits_q.resize(trunk_logits_bytes / sizeof(float));
        trunk_final_q.resize(hidden_bytes / sizeof(float));
        talker_logits_q.resize(talker_logits_bytes / sizeof(float));
        for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
            if (m == TS_L5_MODEL_TARGET || m == TS_L5_MODEL_TALKER) continue;
            const int32_t v = harness->vocab_size[m];
            drafter_logits_q[m].resize((size_t)n_tokens * (size_t)v);
        }

        // Trunk forward (quant). The trunk callback is responsible
        // for applying the policy's family 0..6 (target families) to
        // the trunk's weights. For v1 with synthetic models, the
        // trunk's quant forward is identical to the FP forward, so
        // the deltas will be 0. v2+ will have a real quant path.
        trunk_forward(
                tokens.data(), n_tokens,
                trunk_logits_q.data(),
                trunk_final_q.data(),
                harness->model_ctx[TS_L5_MODEL_TARGET]);

        // Drafter forwards (quant). Each drafter callback applies the
        // policy for its model (families 0..6 for that model).
        for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
            if (m == TS_L5_MODEL_TARGET || m == TS_L5_MODEL_TALKER) continue;
            if (!drafter_forwards[m]) continue;
            drafter_forwards[m](
                    trunk_final_q.data(), n_tokens, hidden_dim,
                    drafter_logits_q[m].data(),
                    harness->model_ctx[m]);
        }

        if (talker_forward) {
            talker_forward(
                    trunk_final_q.data(), n_tokens, hidden_dim,
                    talker_logits_q.data(),
                    harness->model_ctx[TS_L5_MODEL_TALKER]);
        }
    }

    // ---- Per-model PPL extraction ----

    result->n_tokens_used = n_tokens;
    result->all_pass      = true;

    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        ts_l5_ppl_per_model * pm = &result->per_model[m];

        // FP PPL
        if (m == TS_L5_MODEL_TARGET) {
            pm->ppl_fp = ts_l5_ppl_per_model_compute(
                    trunk_logits_fp.data(), tokens.data(),
                    n_tokens, v_target);
        } else if (m == TS_L5_MODEL_TALKER) {
            // Talker uses audio-vocab targets (see talker_targets above).
            pm->ppl_fp = ts_l5_ppl_per_model_compute(
                    talker_logits_fp.data(), talker_targets.data(),
                    n_tokens, v_talker);
        } else {
            pm->ppl_fp = ts_l5_ppl_per_model_compute(
                    drafter_logits_fp[m].data(), tokens.data(),
                    n_tokens, harness->vocab_size[m]);
        }

        if (pm->ppl_fp <= 0.0f) {
            // FP forward failed; mark delta as huge and bail.
            pm->ppl_quant = pm->ppl_fp;
            pm->delta     = 1.0e9f;
            pm->pass      = false;
            result->all_pass = false;
            continue;
        }

        // Quant PPL
        if (any_active && policy->models_active[m]) {
            if (m == TS_L5_MODEL_TARGET) {
                pm->ppl_quant = ts_l5_ppl_per_model_compute(
                        trunk_logits_q.data(), tokens.data(),
                        n_tokens, v_target);
            } else if (m == TS_L5_MODEL_TALKER) {
                pm->ppl_quant = ts_l5_ppl_per_model_compute(
                        talker_logits_q.data(), talker_targets.data(),
                        n_tokens, v_talker);
            } else {
                pm->ppl_quant = ts_l5_ppl_per_model_compute(
                        drafter_logits_q[m].data(), tokens.data(),
                        n_tokens, harness->vocab_size[m]);
            }
        } else {
            // Model inactive: quant == FP, delta = 0.
            pm->ppl_quant = pm->ppl_fp;
        }

        // Delta = (ppl_quant - ppl_fp) / ppl_fp
        pm->delta = (pm->ppl_quant - pm->ppl_fp) / pm->ppl_fp;
        pm->pass  = (pm->delta < params->epsilon);

        if (policy->models_active[m] && !pm->pass) {
            result->all_pass = false;
        }

        if (params->verbose) {
            std::fprintf(stderr,
                    "  [v1 harness] model=%d ppl_fp=%.4f ppl_quant=%.4f delta=%.6f pass=%d\n",
                    m, pm->ppl_fp, pm->ppl_quant, pm->delta, (int)pm->pass);
        }
    }

    return 0;
}
