//
// test-lora-mm-activation-capture.cpp
//
// Regression test for pipeline refactor stage 4: llm_graph_context::
// build_lora_mm's dense-path activation-capture extension
// (src/llama-graph.cpp). When cparams.imatrix_activation_capture is set,
// build_lora_mm now calls build_imatrix_observer_cast_dense instead of
// the stats-only build_imatrix_observer_dense, discarding its return
// value (the F16 activation view) rather than feeding it into the
// matmul -- the actual matmul must keep running on the true F32 `cur`.
//
// build_tile640_lora_mm's OWN use of build_imatrix_observer_cast_dense
// reassigns `cur` to the returned F16 view before its matmul, which is
// safe there only because that path casts to F16 regardless a few lines
// later. build_lora_mm's dense path has no such cast, so if a future
// edit accidentally copied that reassignment pattern, every dense
// matmul -- including this context's own logit computation -- would
// silently run on F16-downgraded activations whenever
// imatrix_activation_capture is on.
//
// This is the one correctness-sensitive change in the whole activation-
// capture feature (see /Users/user/.claude/plans/
// flickering-meandering-quasar.md, stage 4), so it gets a real,
// integration-level regression test rather than relying only on source
// review: build a tiny synthetic LLM_ARCH_LLAMA model (random weights,
// no real GGUF needed -- llama_model_init_from_user builds directly from
// an in-memory gguf_context, the same mechanism tests/test-llama-archs.cpp
// uses to generate its multi-architecture fixture matrix), decode the
// same tokens through two contexts built from the SAME model -- one with
// imatrix_observers+imatrix_activation_capture off (control), one with
// both on -- and assert the logits are bit-for-bit identical. Any
// reassignment of `cur` in the dense path would make this fail (the
// matmul would run on F16-rounded, not F32, activations).
//
// set_tensor_data/get_tokens/get_gguf_ctx/get_model_and_ctx/get_logits
// below are copied verbatim from tests/test-llama-archs.cpp (lines
// 42-322 as of this commit), specialized to a single LLM_ARCH_LLAMA,
// non-MoE configuration and extended with an activation_capture toggle
// on get_model_and_ctx's ctx_params. Kept as a local copy rather than a
// shared header since the source functions are file-static there and
// this test's scope (one architecture, one correctness property) does
// not warrant refactoring that file's shared fixture surface.
//

#include "common.h"
#include "log.h"
#include "ggml-backend.h"
#include "ggml.h"
#include "gguf.h"
#include "ggml-cpp.h"
#include "llama.h"
#include "llama-cpp.h"

#include "../src/llama-arch.h"
#include "../src/llama-model-saver.h"

#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

static void set_tensor_data(struct ggml_tensor * tensor, void * userdata) {
    size_t seed = *(const size_t *) userdata;
    std::hash<std::string> hasher;
    seed ^= hasher(tensor->name);
    std::mt19937 gen(seed);
    std::normal_distribution<float> dis(0.0f, 1.0e-2f);

    const int64_t ne = ggml_nelements(tensor);
    if (tensor->type == GGML_TYPE_F32) {
        std::vector<float> tmp(ne);
        for (int64_t i = 0; i < ne; i++) {
            tmp[i] = dis(gen);
        }
        ggml_backend_tensor_set(tensor, tmp.data(), 0, ggml_nbytes(tensor));
    } else if (tensor->type == GGML_TYPE_F16) {
        std::vector<ggml_fp16_t> tmp(ne);
        for (int64_t i = 0; i < ne; i++) {
            tmp[i] = ggml_fp32_to_fp16(dis(gen));
        }
        ggml_backend_tensor_set(tensor, tmp.data(), 0, ggml_nbytes(tensor));
    } else {
        GGML_ABORT("fatal error");
    }
}

static std::vector<llama_token> get_tokens(const uint32_t n_tokens, const uint32_t n_vocab, const size_t seed) {
    std::mt19937 gen(seed);
    std::uniform_int_distribution<> dis(0, n_vocab - 1);
    std::vector<llama_token> ret;
    ret.reserve(n_tokens);
    for (uint32_t i = 0; i < n_tokens; i++) {
        ret.push_back(dis(gen));
    }
    return ret;
}

// Specialized to LLM_ARCH_LLAMA, non-MoE: the arch-specific branches in
// test-llama-archs.cpp's version never match LLAMA, so this is that
// function's unconditional/default path only.
static gguf_context_ptr get_gguf_ctx() {
    const llm_arch arch = LLM_ARCH_LLAMA;
    gguf_context_ptr ret(gguf_init_empty());
    llama_model_saver ms(arch, ret.get());
    const uint32_t n_ctx = 128;

    const uint32_t n_vocab = 128;
    const uint32_t n_embd  = 256;
    const uint32_t n_head  = 2;
    const uint32_t n_ff    = 384;
    const uint32_t n_layer = 2;
    const uint32_t n_embd_head = n_embd / n_head;

    ms.add_kv(LLM_KV_GENERAL_ARCHITECTURE,      llm_arch_name(arch));
    ms.add_kv(LLM_KV_VOCAB_SIZE,                n_vocab);
    ms.add_kv(LLM_KV_CONTEXT_LENGTH,            n_ctx);
    ms.add_kv(LLM_KV_EMBEDDING_LENGTH,          n_embd);
    ms.add_kv(LLM_KV_FEATURES_LENGTH,           n_embd);
    ms.add_kv(LLM_KV_BLOCK_COUNT,               n_layer);
    ms.add_kv(LLM_KV_LEADING_DENSE_BLOCK_COUNT, uint32_t(1));
    ms.add_kv(LLM_KV_FEED_FORWARD_LENGTH,       n_ff);

    ms.add_kv(LLM_KV_USE_PARALLEL_RESIDUAL,   false);
    ms.add_kv(LLM_KV_LOGIT_SCALE,             1.0f);
    ms.add_kv(LLM_KV_TIME_MIX_EXTRA_DIM,      uint32_t(64));
    ms.add_kv(LLM_KV_TIME_DECAY_EXTRA_DIM,    uint32_t(128));
    ms.add_kv(LLM_KV_FULL_ATTENTION_INTERVAL, uint32_t(2));

    ms.add_kv(LLM_KV_ATTENTION_HEAD_COUNT,    n_head);
    ms.add_kv(LLM_KV_ATTENTION_HEAD_COUNT_KV, n_head);

    ms.add_kv(LLM_KV_ATTENTION_MAX_ALIBI_BIAS, 8.0f);
    ms.add_kv(LLM_KV_ATTENTION_CLAMP_KQV,              1.0f);
    ms.add_kv(LLM_KV_ATTENTION_LAYERNORM_EPS,          1e-5f);
    ms.add_kv(LLM_KV_ATTENTION_LAYERNORM_RMS_EPS,      1e-5f);
    ms.add_kv(LLM_KV_ATTENTION_GROUPNORM_EPS,          1e-5f);
    ms.add_kv(LLM_KV_ATTENTION_GROUPNORM_GROUPS,       uint32_t(8));
    ms.add_kv(LLM_KV_ATTENTION_Q_LORA_RANK,            uint32_t(512));
    ms.add_kv(LLM_KV_ATTENTION_KV_LORA_RANK,           uint32_t(512));
    ms.add_kv(LLM_KV_ATTENTION_RELATIVE_BUCKETS_COUNT, uint32_t(8));
    ms.add_kv(LLM_KV_ATTENTION_SLIDING_WINDOW,         n_ctx/8);
    ms.add_kv(LLM_KV_ATTENTION_SLIDING_WINDOW_PATTERN, uint32_t(2));

    ms.add_kv(LLM_KV_ATTENTION_INDEXER_HEAD_COUNT, uint32_t(1));
    ms.add_kv(LLM_KV_ATTENTION_INDEXER_KEY_LENGTH, uint32_t(64));
    ms.add_kv(LLM_KV_ATTENTION_INDEXER_TOP_K,      uint32_t(8));
    ms.add_kv(LLM_KV_ROPE_DIMENSION_SECTIONS, std::vector<uint32_t>({n_embd_head/4, n_embd_head/4, n_embd_head/4, n_embd_head/4}));
    ms.add_kv(LLM_KV_TOKENIZER_MODEL,         "no_vocab");

    ms.add_kv(LLM_KV_POSNET_EMBEDDING_LENGTH,   n_embd);
    ms.add_kv(LLM_KV_POSNET_BLOCK_COUNT,        n_layer);
    ms.add_kv(LLM_KV_CONVNEXT_EMBEDDING_LENGTH, n_embd);
    ms.add_kv(LLM_KV_CONVNEXT_BLOCK_COUNT,      n_layer);
    ms.add_kv(LLM_KV_XIELU_ALPHA_N,             1.0f);
    ms.add_kv(LLM_KV_XIELU_ALPHA_P,             1.0f);
    ms.add_kv(LLM_KV_XIELU_BETA,                1.0f);
    ms.add_kv(LLM_KV_XIELU_EPS,                 1.0e-7f);
    ms.add_kv(LLM_KV_SSM_INNER_SIZE,            2*n_embd);
    ms.add_kv(LLM_KV_SSM_CONV_KERNEL,           uint32_t(4));
    ms.add_kv(LLM_KV_SSM_STATE_SIZE,            uint32_t(128));
    ms.add_kv(LLM_KV_SSM_TIME_STEP_RANK,        n_head);
    ms.add_kv(LLM_KV_SSM_GROUP_COUNT,           uint32_t(2));
    ms.add_kv(LLM_KV_KDA_HEAD_DIM,              uint32_t(128));
    ms.add_kv(LLM_KV_WKV_HEAD_SIZE,             n_embd/n_head);
    ms.add_kv(LLM_KV_SHORTCONV_L_CACHE,         uint32_t(3));

    for (uint32_t il = 0; il < n_layer; il++) {
        ggml_tensor t;
        memset(&t, 0, sizeof(ggml_tensor));
        t.type = GGML_TYPE_F16;
        ggml_format_name(&t, "conv%" PRIu32 "d.weight", il);
        gguf_add_tensor(ms.gguf_ctx, &t);
        ggml_format_name(&t, "posnet.%" PRIu32 ".conv1.weight", il);
        gguf_add_tensor(ms.gguf_ctx, &t);
        ggml_format_name(&t, "posnet.%" PRIu32 ".conv2.weight", il);
        gguf_add_tensor(ms.gguf_ctx, &t);
        ggml_format_name(&t, "convnext.%" PRIu32 ".dw.weight", il);
        gguf_add_tensor(ms.gguf_ctx, &t);
    }
    return ret;
}

static bool silent_model_load_progress(float /*progress*/, void * /*user_data*/) {
    return true;
}

// Extended from test-llama-archs.cpp's version with an activation_capture
// toggle: when true, sets BOTH ctx_params.imatrix_observers (the outer
// gate build_lora_mm's imatrix_observer_enabled() checks) and
// ctx_params.imatrix_activation_capture (the new stage-4 flag) so the
// build_imatrix_observer_cast_dense branch under test actually fires.
static std::pair<llama_model_ptr, llama_context_ptr> get_model_and_ctx(
        struct gguf_context * gguf_ctx, const size_t seed, bool activation_capture) {
    llama_model_params model_params = llama_model_default_params();
    model_params.progress_callback = silent_model_load_progress;
    std::vector<ggml_backend_dev_t> devs_copy = { nullptr };
    model_params.devices = devs_copy.data();

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx         = 0;
    ctx_params.n_threads     = 4;
    ctx_params.n_threads_batch = 4;
    ctx_params.n_ubatch      = 64;
    ctx_params.imatrix_observers          = activation_capture;
    ctx_params.imatrix_activation_capture = activation_capture;

    size_t tmp = seed;
    llama_model_ptr model(llama_model_init_from_user(gguf_ctx, set_tensor_data, &tmp, model_params));
    if (!model) {
        throw std::runtime_error("failed to create llama model");
    }
    llama_context_ptr lctx(llama_init_from_model(model.get(), ctx_params));
    if (!lctx) {
        throw std::runtime_error("failed to create llama context");
    }
    return std::make_pair(std::move(model), std::move(lctx));
}

static std::vector<float> get_logits(
        llama_model * model, llama_context * lctx, const std::vector<llama_token> & tokens) {
    const uint32_t n_vocab  = llama_vocab_n_tokens(llama_model_get_vocab(model));
    const uint32_t n_ctx    = llama_n_ctx(lctx);
    const uint32_t n_tokens = tokens.size();
    llama_batch batch = llama_batch_init(n_ctx, 0, 1);
    GGML_ASSERT(n_tokens <= n_ctx);
    for (uint32_t pos = 0; pos < n_tokens; pos++) {
        common_batch_add(batch, tokens[pos], pos, {0}, true);
    }
    batch.n_tokens = n_tokens;
    if (llama_decode(lctx, batch)) {
        llama_batch_free(batch);
        throw std::runtime_error("failed to decode batch");
    }

    std::vector<float> ret;
    ret.reserve(n_tokens*n_vocab);
    for (uint32_t i = 0; i < n_tokens; i++) {
        const float * logits_ith = llama_get_logits_ith(lctx, i);
        for (uint32_t j = 0; j < n_vocab; j++) {
            ret.push_back(logits_ith[j]);
        }
    }
    llama_batch_free(batch);
    return ret;
}

int main() {
    llama_backend_init();

    const size_t seed = 12345;
    int rc = 0;
    try {
        gguf_context_ptr gguf_ctx = get_gguf_ctx();

        // Control: imatrix_observers/imatrix_activation_capture both off
        // (the pre-stage-4 default behavior).
        auto [model_ctrl, lctx_ctrl] = get_model_and_ctx(gguf_ctx.get(), seed, /*activation_capture=*/false);
        const uint32_t n_vocab = llama_vocab_n_tokens(llama_model_get_vocab(model_ctrl.get()));
        const std::vector<llama_token> tokens = get_tokens(16, n_vocab, seed + 1);
        const std::vector<float> logits_ctrl = get_logits(model_ctrl.get(), lctx_ctrl.get(), tokens);

        // Capture-enabled: same model weights (same seed), same tokens,
        // but every dense matmul's build_lora_mm call now takes the
        // build_imatrix_observer_cast_dense branch under test.
        auto [model_cap, lctx_cap] = get_model_and_ctx(gguf_ctx.get(), seed, /*activation_capture=*/true);
        const std::vector<float> logits_cap = get_logits(model_cap.get(), lctx_cap.get(), tokens);

        if (logits_ctrl.size() != logits_cap.size()) {
            std::printf("FAIL logits size mismatch: ctrl=%zu cap=%zu\n",
                        logits_ctrl.size(), logits_cap.size());
            rc = 1;
        } else {
            size_t n_diff = 0;
            float max_abs_diff = 0.0f;
            for (size_t i = 0; i < logits_ctrl.size(); i++) {
                const float d = std::fabs(logits_ctrl[i] - logits_cap[i]);
                if (d != 0.0f) {
                    n_diff++;
                    if (d > max_abs_diff) max_abs_diff = d;
                }
            }
            std::printf("logits compared: %zu values, %zu differing, max_abs_diff=%.3e\n",
                        logits_ctrl.size(), n_diff, (double)max_abs_diff);
            if (n_diff != 0) {
                std::printf("FAIL logits differ between control and activation-capture runs "
                            "-- build_lora_mm's dense path is not computing res from the "
                            "true F32 cur (see this file's header comment)\n");
                rc = 1;
            } else {
                std::printf("ok   logits bit-identical: build_lora_mm's dense matmul is "
                            "unaffected by imatrix_activation_capture\n");
            }
        }
    } catch (const std::exception & e) {
        std::printf("FAIL exception: %s\n", e.what());
        rc = 1;
    }

    llama_backend_free();

    if (rc == 0) {
        std::printf("PASS\n");
    } else {
        std::printf("FAIL\n");
    }
    return rc;
}
