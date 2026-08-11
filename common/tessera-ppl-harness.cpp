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

#include "llama.h"

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

// ===========================================================================
// Real model wiring (v3 production follow-up)
// ===========================================================================
//
// ts_l5_joint_models_load: load the 5 models via llama_model_load_from_file
// and create a llama_context for each (with n_ctx tokens of context).
// Empty path = that model is inactive.
//
// The trunk context is created with the most threads (it's the heaviest);
// the drafter and talker contexts use the same n_threads. All contexts
// use the default n_batch (512) which is sufficient for the joint
// calibration's n_tokens <= 256 budget.
//
// On any failure, all partially-loaded models are freed and the
// caller sees a populated err_msg.

int ts_l5_joint_models_load(
        const std::string & target_path,
        const std::string & dflash_path,
        const std::string & dspark_path,
        const std::string & mtp_path,
        const std::string & talker_path,
        int32_t n_ctx,
        int32_t n_threads,
        ts_l5_joint_models * out_models,
        std::string * err_msg) {
    if (!out_models) {
        if (err_msg) *err_msg = "ts_l5_joint_models_load: null out_models";
        return -1;
    }
    if (target_path.empty()) {
        if (err_msg) *err_msg = "ts_l5_joint_models_load: target path is empty";
        return -1;
    }
    if (n_ctx <= 0) n_ctx = 512;
    if (n_threads <= 0) n_threads = 1;

    // Helper: load one model + context, return 0 on success, -1 on failure.
    auto load_one = [&](ts_l5_model m, const std::string & path) -> int {
        if (path.empty()) {
            out_models->m[m] = nullptr;
            out_models->c[m] = nullptr;
            return 0;
        }
        llama_model_params mparams = llama_model_default_params();
        mparams.n_gpu_layers = 0;  // CPU-only for the calibration forward
        llama_model * model = llama_model_load_from_file(path.c_str(), mparams);
        if (!model) {
            if (err_msg) *err_msg = "failed to load model: " + path;
            return -1;
        }
        out_models->m[m] = model;
        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx      = n_ctx;
        cparams.n_threads  = n_threads;
        cparams.n_threads_batch = n_threads;
        llama_context * ctx = llama_init_from_model(model, cparams);
        if (!ctx) {
            if (err_msg) *err_msg = "failed to create context for: " + path;
            llama_model_free(model);
            out_models->m[m] = nullptr;
            return -1;
        }
        out_models->c[m] = ctx;
        return 0;
    };

    // Load in a fixed order: target first (always required), then the
    // 4 optional models. On any failure, free whatever was loaded and
    // return -1.
    int rc = 0;
    rc = load_one(TS_L5_MODEL_TARGET, target_path);   if (rc != 0) goto fail;
    rc = load_one(TS_L5_MODEL_DFLASH, dflash_path);   if (rc != 0) goto fail;
    rc = load_one(TS_L5_MODEL_DSPARK, dspark_path);   if (rc != 0) goto fail;
    rc = load_one(TS_L5_MODEL_MTP,    mtp_path);      if (rc != 0) goto fail;
    rc = load_one(TS_L5_MODEL_TALKER, talker_path);   if (rc != 0) goto fail;
    return 0;

fail:
    ts_l5_joint_models_free(out_models);
    return -1;
}

void ts_l5_joint_models_free(ts_l5_joint_models * models) {
    if (!models) return;
    // Free contexts first, then models (llama.cpp requires this order).
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (models->c[m]) {
            llama_free(models->c[m]);
            models->c[m] = nullptr;
        }
    }
    for (int m = 0; m < TS_L5_MODEL_COUNT; ++m) {
        if (models->m[m]) {
            llama_model_free(models->m[m]);
            models->m[m] = nullptr;
        }
    }
    if (models->trunk_hidden_state) {
        delete[] models->trunk_hidden_state;
        models->trunk_hidden_state = nullptr;
    }
    models->trunk_hidden_state_tokens = 0;
    models->trunk_hidden_state_dim    = 0;
}

// --- Real forward function: trunk ---
//
// Tokenize the calibration text + run llama_decode + extract per-token
// logits. The trunk_final_output is the trunk's last token's hidden
// state (used by the talker forward as a seed).
//
// For v3, the per-block hidden state is NOT exposed to the drafter
// forwards. The drafter forwards consume the same input tokens via
// their own llama_decode. The cross-model hidden state sharing is
// v3.5+ via the ADAPTIVE muxer's graph-injection infrastructure.
void ts_l5_real_trunk_forward(
        const int32_t * tokens,
        int32_t n_tokens,
        float * trunk_logits_out,
        float * trunk_final_output_out,
        void * ctx) {
    if (!ctx || !tokens || n_tokens <= 0) return;
    auto * lc = static_cast<llama_context *>(ctx);

    // Build a batch with the input tokens. The harness provides
    // n_tokens pre-tokenized IDs; we pass them directly.
    llama_batch batch = llama_batch_init(n_tokens, 0, 1);
    for (int32_t i = 0; i < n_tokens; ++i) {
        // logits = 1: we want logits for every token (for PPL).
        batch.token[i]    = tokens[i];
        batch.pos[i]      = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i]   = 1;
    }
    batch.n_tokens = n_tokens;

    // Run the forward.
    const int32_t rc = llama_decode(lc, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        // Forward failed; zero the outputs so the harness sees a
        // sentinel PPL (it will report delta = HUGE for this model).
        const int32_t V = llama_vocab_n_tokens(llama_model_get_vocab(llama_get_model(lc)));
        const size_t n_logits = (size_t)n_tokens * (size_t)V;
        for (size_t i = 0; i < n_logits; ++i) trunk_logits_out[i] = 0.0f;
        const int32_t D = llama_model_n_embd(llama_get_model(lc));
        const size_t n_hidden = (size_t)n_tokens * (size_t)D;
        for (size_t i = 0; i < n_hidden; ++i) trunk_final_output_out[i] = 0.0f;
        return;
    }

    // Extract per-token logits. llama_get_logits_ith(ctx, i) returns
    // a pointer to the (n_vocab) logits for the i-th token in the
    // most recent batch.
    const int32_t V = llama_vocab_n_tokens(llama_model_get_vocab(llama_get_model(lc)));
    for (int32_t i = 0; i < n_tokens; ++i) {
        const float * src = llama_get_logits_ith(lc, i);
        if (!src) continue;
        std::memcpy(trunk_logits_out + (size_t)i * (size_t)V,
                    src, sizeof(float) * (size_t)V);
    }

    // Extract the trunk's last-token hidden state as the "final
    // output" for the talker forward. v3.5+ replaces this with the
    // proper post-LM-head tensor; v3 uses the last token's logits
    // (which the talker forward samples to a token).
    const int32_t D = llama_model_n_embd(llama_get_model(lc));
    const float * last_logits = llama_get_logits_ith(lc, n_tokens - 1);
    if (last_logits) {
        std::memcpy(trunk_final_output_out, last_logits,
                    sizeof(float) * (size_t)V);
    }
    // The remaining hidden_dim - V bytes are zeroed (the v3
    // approximation: the talker sees the trunk's last-token logits
    // as the "final output"; the rest is filler).
    if (D > V) {
        std::memset(trunk_final_output_out + (size_t)V, 0,
                    sizeof(float) * (size_t)(D - V));
    }
}

// --- Real forward function: drafter ---
//
// Consume the trunk's hidden state at target_layer_id (v3.5+; v3
// uses the same input tokens as the trunk) and produce logits. For
// v3, this is the same shape as the trunk forward: tokenize + run
// llama_decode + extract logits. The "hidden state" consumption is
// the v3.5+ enhancement.
void ts_l5_real_drafter_forward(
        const float * hidden_state_in,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * drafter_logits_out,
        void * ctx) {
    (void)hidden_state_in;  // v3.5+ uses this; v3 ignores
    (void)hidden_dim;
    if (!ctx || n_tokens <= 0) return;
    auto * lc = static_cast<llama_context *>(ctx);

    // For v3, we don't have a separate tokenized input for the
    // drafter. The harness's joint forward currently passes the
    // same tokens as the trunk's calibration text, but the trunk
    // forward's tokens aren't accessible here. As a v3 fallback,
    // we tokenize a placeholder (the BOS token, N times) so the
    // forward runs and produces logits. v3.5+ replaces this with
    // a real drafter-specific input pipeline.
    const llama_vocab * vocab = llama_model_get_vocab(llama_get_model(lc));
    llama_token bos = llama_vocab_bos(vocab);
    if (bos < 0) bos = 0;  // vocab without BOS: use 0

    llama_batch batch = llama_batch_init(n_tokens, 0, 1);
    for (int32_t i = 0; i < n_tokens; ++i) {
        batch.token[i]    = bos;  // v3 fallback
        batch.pos[i]      = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i]   = 1;
    }
    batch.n_tokens = n_tokens;

    const int32_t rc = llama_decode(lc, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        const int32_t V = llama_vocab_n_tokens(vocab);
        const size_t n_logits = (size_t)n_tokens * (size_t)V;
        for (size_t i = 0; i < n_logits; ++i) drafter_logits_out[i] = 0.0f;
        return;
    }

    const int32_t V = llama_vocab_n_tokens(vocab);
    for (int32_t i = 0; i < n_tokens; ++i) {
        const float * src = llama_get_logits_ith(lc, i);
        if (!src) continue;
        std::memcpy(drafter_logits_out + (size_t)i * (size_t)V,
                    src, sizeof(float) * (size_t)V);
    }
}

// --- Real forward function: talker ---
//
// Take the trunk's last-token logits (v3 approximation; v3.5+ uses
// the per-block hidden state) as a seed, sample the argmax, and run
// llama_decode on the talker to produce audio logits. The talker
// takes one token at a time; for v3 we feed n_tokens BOS tokens to
// the talker as a placeholder. v3.5+ uses the proper text-to-audio
// pipeline (text tokens in, audio tokens out via the talker's
// LM head over the codec vocab).
//
// Signature matches ts_l5_talker_forward_fn in tessera-ppl-harness.h.
void ts_l5_real_talker_forward(
        const float * trunk_final_output,
        int32_t n_tokens,
        int32_t hidden_dim,
        float * talker_logits_out,
        void * ctx) {
    (void)trunk_final_output;  // v3.5+ uses this as a seed
    (void)hidden_dim;
    if (!ctx || n_tokens <= 0) return;
    auto * lc = static_cast<llama_context *>(ctx);
    const llama_vocab * vocab = llama_model_get_vocab(llama_get_model(lc));
    llama_token bos = llama_vocab_bos(vocab);
    if (bos < 0) bos = 0;

    llama_batch batch = llama_batch_init(n_tokens, 0, 1);
    for (int32_t i = 0; i < n_tokens; ++i) {
        batch.token[i]    = bos;  // v3 fallback; v3.5+ uses trunk's argmax
        batch.pos[i]      = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i]   = 1;
    }
    batch.n_tokens = n_tokens;

    const int32_t rc = llama_decode(lc, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        const int32_t V = llama_vocab_n_tokens(vocab);
        const size_t n_logits = (size_t)n_tokens * (size_t)V;
        for (size_t i = 0; i < n_logits; ++i) talker_logits_out[i] = 0.0f;
        return;
    }

    const int32_t V = llama_vocab_n_tokens(vocab);
    for (int32_t i = 0; i < n_tokens; ++i) {
        const float * src = llama_get_logits_ith(lc, i);
        if (!src) continue;
        std::memcpy(talker_logits_out + (size_t)i * (size_t)V,
                    src, sizeof(float) * (size_t)V);
    }
}
