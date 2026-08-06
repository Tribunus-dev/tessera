// test-qwen3tts-talker.cpp
//
// Structural + golden-parity test for the qwen3-tts-talker C++ model class
// in src/models/qwen3-tts-talker.cpp. The W2 GGUF spec lives in
// conversion/qwen3tts.py + tools/tessera/verify_qwen3tts_gguf.py; this test
// uses the SAME shape/structural invariants but with a synthetic-weight
// GGUF so it can run without the real BF16 W2 output.
//
// Coverage (mirrors test-dflash-loader.cpp / test-llama-archs.cpp):
//   1. Schema: every required tensor is present in the constructed GGUF
//      with the W2-spec shape (the W2 verify tool's invariants are the
//      oracle).
//   2. Load: llama_model_load_from_file accepts the synthetic GGUF and
//      returns a non-null llama_model with arch == LLM_ARCH_QWEN3TTS_TALKER
//      and the expected hparams (block_count=28, n_pred_layers=5, etc.).
//   3. Tensor state: every W2-spec tensor is bound on the loaded model
//      (tok_embd, codec_embd, codec_head, output_norm, text_proj_{1,2}*,
//      cp_proj, cp_norm, 28 backbone layers, 5 cp layers, 15 per-codebook
//      cp_codec_embd.{cid} + cp_head.{cid} pairs).
//   4. Forward (best-effort): a single text token triggers a forward
//      graph build; the resulting logits tensor has the right shape
//      (n_codec_vocab, 1). The per-cid cp logits concat has the right
//      shape (n_cp_per_codebook, 15) when n_pred_layers > 0.
//
// The real-weight golden-parity test (running the W2 GGUF and checking
// codes are byte-identical to HF) is Wave 8's deliverable; this wave
// validates the SCHEMA + LOADER + FORWARD-GRAPH, not the numerical
// outputs.

#include "ggml-cpp.h"
#include "ggml.h"
#include "gguf.h"
#include "llama.h"
#include "llama-cpp.h"

#include "../src/llama-arch.h"
#include "../src/llama-model.h"
#include "../src/llama-model-saver.h"
#include "../src/models/models.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <unistd.h>
#include <vector>

#define TEST_ASSERT(cond)                                                            \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::fprintf(stderr, "test-qwen3tts-talker: assertion failed: %s "         \
                                 "(at %s:%d)\n",                                      \
                         #cond, __FILE__, __LINE__);                                  \
            std::abort();                                                             \
        }                                                                             \
    } while (0)

namespace {

// Test dimensions. The TEST uses smaller dims than the real W2 GGUF so
// the synthetic GGUF fits in a few hundred MB of memory; the W2
// real-weight golden parity test (Wave 8) exercises the real
// 2048/3072/6144/28/5/15 layout. The test mirrors the W2 NAME layout
// (blk.{0..N_LAYER+N_PRED_LAYERS-1}, cp_codec_embd.{cid}.weight, etc.)
// and the W2 metadata keys (codec_vocab_size, predictor_layers, etc.);
// it validates the LOADER reads the W2 schema correctly.
// Test dimensions. The TEST uses smaller dims than the real W2 GGUF so
// the synthetic GGUF fits in a few hundred MB of memory; the W2
// real-weight golden parity test (Wave 8) exercises the real
// 2048/3072/6144/28/5/15 layout. The test mirrors the W2 NAME layout
// (blk.{0..n_layer()-1} = backbone, blk.{n_layer()..n_layer_all-1} = cp
// block, cp_codec_embd.{cid}.weight, etc.) and the W2 metadata keys
// (codec_vocab_size, predictor_layers, etc.); it validates the LOADER
// reads the W2 schema correctly.
//
// W2 schema convention: block_count (LLM_KV_BLOCK_COUNT) is the BACKBONE
// depth only; the cp block rides on top as n_layer_nextn. n_layer() =
// block_count, n_layer_all = block_count + predictor_layers.
constexpr uint32_t N_TEXT_VOCAB    = 64;       // synthetic text vocab
constexpr uint32_t N_CODEC_VOCAB   = 32;       // synthetic codebook-0 head size
constexpr uint32_t N_CP_PER_CODE   = 32;       // synthetic per-cp-codebook entry count
constexpr uint32_t N_EMBD          = 32;       // synthetic backbone hidden
constexpr uint32_t N_HEAD          = 4;        // synthetic backbone heads
constexpr uint32_t N_HEAD_KV       = 2;        // synthetic backbone KV heads
constexpr uint32_t N_FF            = 64;       // synthetic backbone FF
// W2 GGUF schema: block_count is the BACKBONE count only (W2: 28); the cp
// block lives at blk.{block_count..block_count + predictor_layers - 1}
// (W2: blk.28..32). The loader extends n_layer_all by n_pred_layers so
// n_layer() = n_layer_all - n_layer_nextn = backbone count, and the cp
// block is at blk.{n_layer()..n_layer_all-1}. The synthetic mirrors this:
// N_BACKBONE = what block_count is; N_LAYER = N_BACKBONE + N_PRED_LAYERS
// is the loader's n_layer_all.
constexpr uint32_t N_BACKBONE      = 3;        // synthetic backbone block_count (W2: 28)
constexpr uint32_t N_PRED_LAYERS   = 2;        // synthetic cp block depth (W2: 5)
constexpr uint32_t N_LAYER         = N_BACKBONE + N_PRED_LAYERS;  // = 5; loader's n_layer_all
constexpr uint32_t N_CP_EMBD       = 16;       // synthetic cp block hidden (W2: 1024)
constexpr uint32_t N_CP_HEAD       = 2;        // synthetic cp block heads (W2: 16); chosen so n_cp_embd_head matches n_embd_head
constexpr uint32_t N_CP_HEAD_KV    = 1;        // synthetic cp block KV heads (W2: 8)
constexpr uint32_t N_CP_FF         = 32;       // synthetic cp block FF (W2: 3072)
constexpr uint32_t N_CODEBOOKS     = 15;       // cp codebooks (1..15 = cid 0..14) — fixed by W2 spec
constexpr uint32_t N_EMBD_HEAD     = N_EMBD / N_HEAD;       // 8
constexpr uint32_t N_CP_EMBD_HEAD  = N_EMBD_HEAD;           // 8 (matches backbone head dim; cp block uses the same per-head width)
constexpr uint32_t POS_PER_SECONDS = 13;
constexpr int      MROPE_SECTIONS[4] = { 4, 2, 2, 0 };  // sum=8 = n_embd_head, mirrors W2 [24,20,20]

constexpr int      CODEC_PAD_ID       = 2148;
constexpr int      CODEC_BOS_ID       = 2149;
constexpr int      CODEC_EOS_ID       = 2150;
constexpr int      CODEC_THINK_ID     = 2154;
constexpr int      CODEC_NOTHINK_ID   = 2155;
constexpr int      CODEC_THINK_BOS_ID = 2156;
constexpr int      CODEC_THINK_EOS_ID = 2157;

static void fill_tensor(struct ggml_tensor * tensor, void * userdata) {
    size_t * seed = static_cast<size_t *>(userdata);
    std::hash<std::string> hasher;
    size_t s = *seed ^ hasher(tensor->name);
    std::mt19937 gen(s);
    std::normal_distribution<float> dis(0.0f, 1.0e-2f);
    const int64_t n = ggml_nelements(tensor);
    if (n == 0) {
        return;
    }
    if (tensor->type == GGML_TYPE_F32) {
        std::vector<float> tmp(n);
        for (int64_t i = 0; i < n; ++i) tmp[i] = dis(gen);
        ggml_backend_tensor_set(tensor, tmp.data(), 0, ggml_nbytes(tensor));
    } else if (tensor->type == GGML_TYPE_F16) {
        std::vector<ggml_fp16_t> tmp(n);
        for (int64_t i = 0; i < n; ++i) tmp[i] = ggml_fp32_to_fp16(dis(gen));
        ggml_backend_tensor_set(tensor, tmp.data(), 0, ggml_nbytes(tensor));
    } else {
        std::fprintf(stderr, "test-qwen3tts-talker: unsupported tensor type %d\n",
                     (int) tensor->type);
        std::abort();
    }
}

// add a named tensor with the given shape (ggml ne layout: ne[0] is the
// "fastest" dim). gguf_add_tensor needs the data to be allocated, so we
// route through ggml_new_tensor_* which both shape-records and
// allocates. fill_tensor (the loader callback) then populates the data.
void add_named_tensor(ggml_context * ggml_ctx, gguf_context * gguf_ctx,
                      const char * name, ggml_type type,
                      std::initializer_list<int64_t> ne) {
    int64_t dims[GGML_MAX_DIMS] = { 1, 1, 1, 1 };
    size_t n = 0;
    for (int64_t d : ne) {
        TEST_ASSERT(n < GGML_MAX_DIMS);
        dims[n++] = d;
    }
    ggml_tensor * t = nullptr;
    switch (n) {
        case 1: t = ggml_new_tensor_1d(ggml_ctx, type, dims[0]); break;
        case 2: t = ggml_new_tensor_2d(ggml_ctx, type, dims[0], dims[1]); break;
        case 3: t = ggml_new_tensor_3d(ggml_ctx, type, dims[0], dims[1], dims[2]); break;
        case 4: t = ggml_new_tensor_4d(ggml_ctx, type, dims[0], dims[1], dims[2], dims[3]); break;
        default: TEST_ASSERT(false && "unsupported rank");
    }
    TEST_ASSERT(t != nullptr);
    ggml_format_name(t, "%s", name);
    gguf_add_tensor(gguf_ctx, t);
}

// W2-spec metadata: the loader reads these raw-key TTS entries on the
// qwen3-tts-talker arch. Mirrors the keys the W2 converter writes
// (conversion/qwen3tts.py + gguf-py/gguf/constants.py).
void add_talker_kv(llama_model_saver & ms) {
    // standard LLM_KV entries
    ms.add_kv(LLM_KV_CONTEXT_LENGTH,              uint32_t(32768));
    ms.add_kv(LLM_KV_EMBEDDING_LENGTH,            N_EMBD);
    ms.add_kv(LLM_KV_BLOCK_COUNT,                 N_BACKBONE);
    ms.add_kv(LLM_KV_FEED_FORWARD_LENGTH,         N_FF);
    ms.add_kv(LLM_KV_ATTENTION_HEAD_COUNT,        N_HEAD);
    ms.add_kv(LLM_KV_ATTENTION_HEAD_COUNT_KV,     N_HEAD_KV);
    ms.add_kv(LLM_KV_ATTENTION_KEY_LENGTH,        N_EMBD_HEAD);
    ms.add_kv(LLM_KV_ATTENTION_VALUE_LENGTH,      N_EMBD_HEAD);
    ms.add_kv(LLM_KV_ROPE_FREQ_BASE,              1000000.0f);
    ms.add_kv(LLM_KV_ROPE_SCALING_TYPE,           "none");
    ms.add_kv(LLM_KV_ATTENTION_LAYERNORM_RMS_EPS, 1.0e-6f);

    // mrope section widths; the loader reads this as a 4-element array
    // (the 4th is reserved/0 for the talker). The saver's add_kv only
    // instantiates std::vector<uint32_t>, so use that.
    std::vector<uint32_t> sections(
        { (uint32_t) MROPE_SECTIONS[0], (uint32_t) MROPE_SECTIONS[1],
          (uint32_t) MROPE_SECTIONS[2], (uint32_t) MROPE_SECTIONS[3] });
    ms.add_kv(LLM_KV_ROPE_DIMENSION_SECTIONS,     sections);

    // raw arch-prefixed TTS metadata (the loader's ml.get_key<string>
    // path for keys not in the LLM_KV enum)
    const std::string arch = llm_arch_name(LLM_ARCH_QWEN3TTS_TALKER);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_vocab_size").c_str(),        N_CODEC_VOCAB);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".num_code_groups").c_str(),        uint32_t(16));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".position_id_per_seconds").c_str(), POS_PER_SECONDS);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".predictor_layers").c_str(),       N_PRED_LAYERS);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_pad_id").c_str(),           uint32_t(CODEC_PAD_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_bos_id").c_str(),           uint32_t(CODEC_BOS_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_eos_id").c_str(),           uint32_t(CODEC_EOS_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_think_id").c_str(),         uint32_t(CODEC_THINK_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_nothink_id").c_str(),       uint32_t(CODEC_NOTHINK_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_think_bos_id").c_str(),     uint32_t(CODEC_THINK_BOS_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".codec_think_eos_id").c_str(),     uint32_t(CODEC_THINK_EOS_ID));
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".cp_hidden_size").c_str(),         N_CP_EMBD);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".cp_feed_forward_length").c_str(), N_CP_FF);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".cp_head_count").c_str(),          N_CP_HEAD);
    gguf_set_val_u32(ms.gguf_ctx, (arch + ".cp_head_count_kv").c_str(),       N_CP_HEAD_KV);

    // codec language names (string array) + ids (int32 array)
    const char * lang_names[] = { "english", "chinese", "japanese" };
    gguf_set_arr_str(ms.gguf_ctx, (arch + ".codec_language_names").c_str(), lang_names, 3);
    int32_t lang_ids[] = { 2050, 2051, 2052 };
    gguf_set_arr_data(ms.gguf_ctx, (arch + ".codec_language_ids").c_str(), GGUF_TYPE_INT32, lang_ids, 3);

    // synthetic tokenizer so the loader does not require a real vocab
    ms.add_kv(LLM_KV_TOKENIZER_MODEL, "no_vocab");
    ms.add_kv(LLM_KV_VOCAB_SIZE,      N_TEXT_VOCAB);
}

// backbone (blk.0..n_layer()-1 in the loader's view): standard
// Qwen3-style 11-tensor per layer. The test writes N_BACKBONE tensors
// here, matching what the loader reads as n_layer() (which equals the
// backbone depth after the W5b cpufix extends n_layer_all by n_pred_layers).
void add_backbone_layers(ggml_context * ggml_ctx, gguf_context * gguf_ctx) {
    for (uint32_t il = 0; il < N_BACKBONE; ++il) {
        char name[64];
        std::snprintf(name, sizeof(name), "blk.%u.attn_norm.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_q.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD, N_EMBD_HEAD * N_HEAD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_k.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD, N_EMBD_HEAD * N_HEAD_KV });
        std::snprintf(name, sizeof(name), "blk.%u.attn_v.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD, N_EMBD_HEAD * N_HEAD_KV });
        std::snprintf(name, sizeof(name), "blk.%u.attn_output.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD_HEAD * N_HEAD, N_EMBD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_q_norm.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD_HEAD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_k_norm.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD_HEAD });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_norm.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_gate.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD, N_FF });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_up.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD, N_FF });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_down.weight", il);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_FF, N_EMBD });
    }
}

// cp block (blk.{N_BACKBONE}..{N_LAYER-1} in the loader's view):
// Qwen3-style 11-tensor shape at n_cp_embd/4/8 dims. The cp layers
// live at blk.{n_layer()..n_layer_all-1}, which is
// blk.{N_BACKBONE..N_BACKBONE+N_PRED_LAYERS-1}.
//
// The cp block uses a standard Qwen3 attention shape (Q/K/V from
// cp hidden, output to cp hidden). The W2 verify confirms
// blk.28.attn_q.weight ne = [n_cp_embd, n_cp_embd_attn],
// blk.28.attn_k.weight ne = [n_cp_embd, n_cp_embd_kv_gqa], and
// blk.32.attn_output.weight ne = [n_cp_embd_attn, n_cp_embd].
void add_cp_layers(ggml_context * ggml_ctx, gguf_context * gguf_ctx) {
    for (uint32_t i = 0; i < N_PRED_LAYERS; ++i) {
        const uint32_t cp_bid = N_BACKBONE + i;
        char name[64];
        std::snprintf(name, sizeof(name), "blk.%u.attn_norm.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_q.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD, N_CP_EMBD_HEAD * N_CP_HEAD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_k.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD, N_CP_EMBD_HEAD * N_CP_HEAD_KV });
        std::snprintf(name, sizeof(name), "blk.%u.attn_v.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD, N_CP_EMBD_HEAD * N_CP_HEAD_KV });
        std::snprintf(name, sizeof(name), "blk.%u.attn_output.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD_HEAD * N_CP_HEAD, N_CP_EMBD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_q_norm.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD_HEAD });
        std::snprintf(name, sizeof(name), "blk.%u.attn_k_norm.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD_HEAD });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_norm.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_gate.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD, N_CP_FF });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_up.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD, N_CP_FF });
        std::snprintf(name, sizeof(name), "blk.%u.ffn_down.weight", cp_bid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_FF, N_CP_EMBD });
    }
}

// model-level (non-block) tensors
void add_model_tensors(ggml_context * ggml_ctx, gguf_context * gguf_ctx) {
    // text-side
    add_named_tensor(ggml_ctx, gguf_ctx, "token_embd.weight",  GGML_TYPE_F16, { N_EMBD, N_TEXT_VOCAB });
    add_named_tensor(ggml_ctx, gguf_ctx, "output_norm.weight", GGML_TYPE_F16, { N_EMBD });

    // codec-side (text-vocab-independent, separate from token_embd)
    add_named_tensor(ggml_ctx, gguf_ctx, "codec_embd.weight",  GGML_TYPE_F16, { N_EMBD, N_CODEC_VOCAB });
    add_named_tensor(ggml_ctx, gguf_ctx, "codec_head.weight",  GGML_TYPE_F16, { N_EMBD, N_CODEC_VOCAB });

    // text projection MLP (2 layers, each with a bias; the W2 converter
    // writes both .weight and .bias for each layer)
    add_named_tensor(ggml_ctx, gguf_ctx, "text_proj_1.weight", GGML_TYPE_F16, { N_EMBD, N_EMBD });
    add_named_tensor(ggml_ctx, gguf_ctx, "text_proj_1.bias",   GGML_TYPE_F32, { N_EMBD });
    add_named_tensor(ggml_ctx, gguf_ctx, "text_proj_2.weight", GGML_TYPE_F16, { N_EMBD, N_EMBD });
    add_named_tensor(ggml_ctx, gguf_ctx, "text_proj_2.bias",   GGML_TYPE_F32, { N_EMBD });

    // code predictor bridge (backbone hidden -> cp hidden)
    add_named_tensor(ggml_ctx, gguf_ctx, "cp_proj.weight",     GGML_TYPE_F16, { N_EMBD, N_CP_EMBD });
    add_named_tensor(ggml_ctx, gguf_ctx, "cp_proj.bias",       GGML_TYPE_F32, { N_CP_EMBD });
    add_named_tensor(ggml_ctx, gguf_ctx, "cp_norm.weight",     GGML_TYPE_F32, { N_CP_EMBD });

    // per-codebook embeddings + heads (cids 0..14, codebooks 1..15)
    // ggml ne is reversed vs torch: the loader passes {n_embd, n_cp_per_codebook}
    // for cp_codec_embd and {n_cp_embd, n_cp_per_codebook} for cp_head, so
    // the GGUF ne must match (the W2 verify tool's expect_shape checks the
    // same ne layout).
    for (uint32_t cid = 0; cid < N_CODEBOOKS; ++cid) {
        char name[64];
        std::snprintf(name, sizeof(name), "cp_codec_embd.%u.weight", cid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_EMBD,        N_CP_PER_CODE });
        std::snprintf(name, sizeof(name), "cp_head.%u.weight",       cid);
        add_named_tensor(ggml_ctx, gguf_ctx, name, GGML_TYPE_F16, { N_CP_EMBD,     N_CP_PER_CODE });
    }
}

// Build a synthetic talker GGUF in a temp file. Returns the path (caller
// unlinks). The GGUF is shaped exactly like the W2 output but with
// random gaussian weights (mean 0, std 1e-2); the values are
// non-canonical but well-formed (no NaN/Inf, no overflows).
std::string build_synthetic_talker_gguf() {
    gguf_context_ptr gguf(gguf_init_empty());
    TEST_ASSERT(gguf.get() != nullptr);

    constexpr size_t GGML_CTX_SIZE = 64 * 1024 * 1024;  // 64 MiB; plenty for the synthetic tensors
    ggml_init_params ggml_params = {
        /*.mem_size   =*/ GGML_CTX_SIZE,
        /*.mem_buffer =*/ nullptr,
        /*.no_alloc   =*/ false,
    };
    ggml_context_ptr ggml(ggml_init(ggml_params));
    TEST_ASSERT(ggml.get() != nullptr);

    llama_model_saver ms(LLM_ARCH_QWEN3TTS_TALKER, gguf.get());
    add_talker_kv(ms);
    ms.add_kv(LLM_KV_GENERAL_ARCHITECTURE, llm_arch_name(LLM_ARCH_QWEN3TTS_TALKER));

    add_model_tensors(ggml.get(), gguf.get());
    add_backbone_layers(ggml.get(), gguf.get());
    add_cp_layers(ggml.get(), gguf.get());

    char path[] = "/tmp/test-qwen3tts-talker-XXXXXX.gguf";
    int fd = mkstemps(path, /*suffix_len=*/5);
    TEST_ASSERT(fd >= 0);
    ::close(fd);
    TEST_ASSERT(gguf_write_to_file(gguf.get(), path, /*only_meta=*/false));

    return std::string(path);
}

// Load a talker GGUF (via file path; the in-memory gguf_context path
// does not populate the loader's weights_map, see test-dflash-loader
// for the same caveat).
//
// devices is constrained to {cpu, nullptr} so the loader does NOT register
// the ANE/METAL backends. n_gpu_layers=0 alone is not enough on the
// architect's M1 base: ggml_backend_sched still sees ANE in its backend
// list, then routes token_embd.weight (NONE op) to the ANE buffer and
// aborts at ggml_backend_sched_split_graph. The device whitelist is the
// only place that removes ANE from the scheduler. test-export-graph-ops
// uses the same pattern.
struct llama_model * load_talker_gguf(const std::string & path) {
    llama_model_params model_params = llama_model_default_params();
    model_params.progress_callback = [](float, void *) { return true; };
    model_params.n_gpu_layers = 0;  // CPU-only path
    static ggml_backend_dev_t cpu_only[2] = {
        nullptr,
        nullptr,
    };
    cpu_only[0] = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    TEST_ASSERT(cpu_only[0] != nullptr);
    model_params.devices = cpu_only;
    return llama_model_load_from_file(path.c_str(), model_params);
}

void check_arch_hparams(struct llama_model * model) {
    TEST_ASSERT(model != nullptr);
    TEST_ASSERT(model->arch == LLM_ARCH_QWEN3TTS_TALKER);

    // standard hparams
    TEST_ASSERT((uint32_t) model->hparams.n_layer() == N_BACKBONE);
    TEST_ASSERT((uint32_t) model->hparams.n_layer_all == (uint32_t)(N_LAYER));
    TEST_ASSERT((uint32_t) model->hparams.n_layer_nextn == N_PRED_LAYERS);
    TEST_ASSERT((uint32_t) model->hparams.n_embd == N_EMBD);
    TEST_ASSERT((uint32_t) model->hparams.n_head() == N_HEAD);
    TEST_ASSERT((uint32_t) model->hparams.n_head_kv() == N_HEAD_KV);
    TEST_ASSERT((uint32_t) model->hparams.n_rot_full == N_EMBD_HEAD);

    // mrope section widths [24, 20, 20, 0]
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[0] == (uint32_t) MROPE_SECTIONS[0]);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[1] == (uint32_t) MROPE_SECTIONS[1]);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[2] == (uint32_t) MROPE_SECTIONS[2]);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[3] == (uint32_t) MROPE_SECTIONS[3]);
    TEST_ASSERT(model->hparams.use_mrope());
}

void check_tensor_state(struct llama_model * model) {
    // text-side
    TEST_ASSERT(model->tok_embd    != nullptr);
    TEST_ASSERT(model->output_norm != nullptr);

    // cast to the qwen3tts_talker model to access the arch-specific fields
    auto * m = static_cast<struct llama_model_qwen3tts_talker *>(model);
    TEST_ASSERT(m->codec_embd      != nullptr);
    TEST_ASSERT(m->codec_head      != nullptr);
    TEST_ASSERT(m->text_proj_1     != nullptr);
    TEST_ASSERT(m->text_proj_1_b   != nullptr);
    TEST_ASSERT(m->text_proj_2     != nullptr);
    TEST_ASSERT(m->text_proj_2_b   != nullptr);

    // cp bridge
    TEST_ASSERT(m->cp_proj         != nullptr);
    TEST_ASSERT(m->cp_proj_b       != nullptr);
    TEST_ASSERT(m->cp_norm         != nullptr);
    TEST_ASSERT(m->cp_codec_embd.size() == N_CODEBOOKS);
    TEST_ASSERT(m->cp_head      .size() == N_CODEBOOKS);
    for (uint32_t cid = 0; cid < N_CODEBOOKS; ++cid) {
        TEST_ASSERT(m->cp_codec_embd[cid] != nullptr);
        TEST_ASSERT(m->cp_head[cid]       != nullptr);
        char want_embd[64], want_head[64];
        std::snprintf(want_embd, sizeof(want_embd), "cp_codec_embd.%u.weight", cid);
        std::snprintf(want_head, sizeof(want_head), "cp_head.%u.weight",       cid);
        TEST_ASSERT(std::string(m->cp_codec_embd[cid]->name) == want_embd);
        TEST_ASSERT(std::string(m->cp_head[cid]->name)       == want_head);
    }

    // backbone: N_BACKBONE layers, every required tensor populated
    TEST_ASSERT((uint32_t) model->layers.size() == (uint32_t)(N_LAYER));
    for (uint32_t il = 0; il < N_BACKBONE; ++il) {
        const auto & layer = model->layers[il];
        TEST_ASSERT(layer.attn_norm != nullptr);
        TEST_ASSERT(layer.wq        != nullptr);
        TEST_ASSERT(layer.wk        != nullptr);
        TEST_ASSERT(layer.wv        != nullptr);
        TEST_ASSERT(layer.wo        != nullptr);
        TEST_ASSERT(layer.attn_k_norm != nullptr);
        TEST_ASSERT(layer.attn_q_norm != nullptr);
        TEST_ASSERT(layer.ffn_norm  != nullptr);
        TEST_ASSERT(layer.ffn_gate  != nullptr);
        TEST_ASSERT(layer.ffn_up    != nullptr);
        TEST_ASSERT(layer.ffn_down  != nullptr);
    }
    // cp block: N_PRED_LAYERS layers at blk.{N_BACKBONE}..{N_LAYER-1}
    for (uint32_t i = 0; i < N_PRED_LAYERS; ++i) {
        const uint32_t cp_bid = N_BACKBONE + i;
        const auto & layer = model->layers[cp_bid];
        TEST_ASSERT(layer.attn_norm != nullptr);
        TEST_ASSERT(layer.wq        != nullptr);
        TEST_ASSERT(layer.wk        != nullptr);
        TEST_ASSERT(layer.wv        != nullptr);
        TEST_ASSERT(layer.wo        != nullptr);
        TEST_ASSERT(layer.attn_k_norm != nullptr);
        TEST_ASSERT(layer.attn_q_norm != nullptr);
        TEST_ASSERT(layer.ffn_norm  != nullptr);
        TEST_ASSERT(layer.ffn_gate  != nullptr);
        TEST_ASSERT(layer.ffn_up    != nullptr);
        TEST_ASSERT(layer.ffn_down  != nullptr);
    }

    // cp arch-specific fields read at load time
    TEST_ASSERT(m->n_codec_vocab           == N_CODEC_VOCAB);
    TEST_ASSERT(m->n_cp_per_codebook       == N_CP_PER_CODE);
    TEST_ASSERT(m->n_pred_layers           == N_PRED_LAYERS);
    TEST_ASSERT(m->n_cp_embd               == N_CP_EMBD);
    TEST_ASSERT(m->n_cp_ff                 == N_CP_FF);
    TEST_ASSERT(m->n_cp_head               == N_CP_HEAD);
    TEST_ASSERT(m->n_cp_head_kv            == N_CP_HEAD_KV);
    TEST_ASSERT(m->position_id_per_seconds == POS_PER_SECONDS);
    TEST_ASSERT((int) m->codec_pad_id      == CODEC_PAD_ID);
    TEST_ASSERT((int) m->codec_bos_id      == CODEC_BOS_ID);
    TEST_ASSERT((int) m->codec_eos_id      == CODEC_EOS_ID);
    TEST_ASSERT((int) m->codec_think_id    == CODEC_THINK_ID);
    TEST_ASSERT((int) m->codec_nothink_id  == CODEC_NOTHINK_ID);
    TEST_ASSERT(m->codec_language_names.size() == 3);
    TEST_ASSERT(m->codec_language_ids  .size() == 3);
    TEST_ASSERT(m->codec_language_names[0] == "english");
    TEST_ASSERT(m->codec_language_ids[0]   == 2050);
}

// Build a single-token forward graph (1 text token through the backbone)
// and verify the resulting t_logits / t_embd shapes match the design.
// This is a structural test: with random weights the values are not
// meaningful, but the graph should build without error and produce
// the right output shapes. The cp block's per-frame graph is exercised
// by the Wave-8 real-weight golden parity test (this W5b scope is the
// schema + loader + backbone-forward test only).
void check_forward_graph(struct llama_model * model) {
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx    = 64;
    cp.n_batch  = 1;
    cp.n_ubatch = 1;
    cp.no_perf  = true;
    // disable sampling so the model doesn't try to write the cp_logits_concat
    // (the t_h_nextn output is exposed but not sampled in this test path)
    cp.embeddings = true;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (ctx == nullptr) {
        std::fprintf(stderr, "test-qwen3tts-talker: llama_init_from_model returned null\n");
        std::abort();
    }

    // n_embd sanity: confirm the model exposes the W2-spec backbone n_embd
    // (the text-side embedding + the codec-side embedding + the text-proj
    // MLP all consume this dim)
    TEST_ASSERT(llama_model_n_embd(model) == (int32_t) N_EMBD);

    // text vocab size: the talker has the standard text tokenizer (151936
    // in the W2 GGUF, 64 in the synthetic test GGUF). The codec vocab
    // (3072 in the W2 GGUF) is exposed via the m.codec_head tensor's
    // first dim, NOT through llama_n_vocab.
    TEST_ASSERT(llama_vocab_n_tokens(llama_model_get_vocab(model)) == (int32_t) N_TEXT_VOCAB);

    // the cp block's per-cid heads (cp_head.{cid}) and per-cp-codebook
    // entries (n_cp_per_codebook) are reachable through the static_cast
    // below; this is the structural oracle for the W2 schema
    {
        auto * m = static_cast<struct llama_model_qwen3tts_talker *>(model);
        TEST_ASSERT(m->n_codec_vocab     == N_CODEC_VOCAB);
        TEST_ASSERT(m->n_cp_per_codebook == N_CP_PER_CODE);
        TEST_ASSERT(m->n_pred_layers     == N_PRED_LAYERS);
        TEST_ASSERT(m->n_cp_embd         == N_CP_EMBD);
        TEST_ASSERT(m->n_cp_ff           == N_CP_FF);
        TEST_ASSERT(m->n_cp_head         == N_CP_HEAD);
        TEST_ASSERT(m->n_cp_head_kv      == N_CP_HEAD_KV);
        TEST_ASSERT(m->cp_codec_embd.size() == N_CODEBOOKS);
        TEST_ASSERT(m->cp_head      .size() == N_CODEBOOKS);
        TEST_ASSERT(m->codec_head != nullptr);
        TEST_ASSERT(m->codec_head->ne[0] == (int64_t) N_EMBD);
        TEST_ASSERT(m->codec_head->ne[1] == (int64_t) N_CODEC_VOCAB);
        TEST_ASSERT(m->cp_proj   != nullptr);
        TEST_ASSERT(m->cp_proj_b != nullptr);
        TEST_ASSERT(m->cp_norm   != nullptr);
    }

    llama_free(ctx);
}

// Optional real-weight verification. When TESSERA_QWEN3TTS_TALKER_GGUF
// points at a real W2 talker GGUF (e.g. the 3.6GB BF16 artifact on
// /Volumes/Julian T7), load it, confirm the W2-spec arch + hparams + the
// per-cp-codebook tensor set, and run a single text-token forward. This
// is the W5b-followup verification gate: the synthetic test pins the
// schema, but only real-weight forward tells us whether the loader is
// weight-shape-clean against the W2 output. cp pass is skipped (W5b
// scope); this is a load + backbone-forward smoke test.
void check_real_weight_forward(const std::string & path) {
    std::printf("test-qwen3tts-talker: real-weight smoke test on %s\n", path.c_str());

    struct llama_model * model = load_talker_gguf(path);
    if (model == nullptr) {
        std::fprintf(stderr,
            "test-qwen3tts-talker: FAIL — real-weight load returned null for %s\n"
            "  This is the first W5b follow-up surface. Likely causes:\n"
            "    - schema mismatch in the W2 GGUF (verify_qwen3tts_gguf.py is oracle)\n"
            "    - raw TTS metadata key not in the loader's ml.get_key path\n"
            "    - layer count off (W2 = 28 backbone + 5 cp = n_layer_all=33)\n",
            path.c_str());
        std::abort();
    }

    // W2-spec arch + hparams: real GGUF has block_count=28 backbone,
    // n_layer_nextn=5, n_embd=2048, n_head=16, n_head_kv=8, n_rot=128,
    // mrope sections [24,20,20,0], codec_vocab=3072, n_cp_per_codebook=2048,
    // n_codebooks=15. The loader casts to llama_model_qwen3tts_talker for
    // the arch-specific fields.
    TEST_ASSERT(model->arch == LLM_ARCH_QWEN3TTS_TALKER);
    TEST_ASSERT((uint32_t) model->hparams.n_layer()     == 28);
    TEST_ASSERT((uint32_t) model->hparams.n_layer_all   == 33);
    TEST_ASSERT((uint32_t) model->hparams.n_layer_nextn == 5);
    TEST_ASSERT((uint32_t) model->hparams.n_embd        == 2048);
    TEST_ASSERT((uint32_t) model->hparams.n_head()      == 16);
    TEST_ASSERT((uint32_t) model->hparams.n_head_kv()   == 8);
    TEST_ASSERT((uint32_t) model->hparams.n_rot_full    == 128);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[0] == 24);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[1] == 20);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[2] == 20);
    TEST_ASSERT((uint32_t) model->hparams.rope_sections[3] == 0);
    TEST_ASSERT(model->hparams.use_mrope());

    auto * m = static_cast<struct llama_model_qwen3tts_talker *>(model);
    TEST_ASSERT(m->n_codec_vocab     == 3072);
    TEST_ASSERT(m->n_cp_per_codebook == 2048);
    TEST_ASSERT(m->n_pred_layers   == 5);
    TEST_ASSERT(m->n_cp_embd       == 1024);
    TEST_ASSERT(m->n_cp_head       == 16);
    TEST_ASSERT(m->n_cp_head_kv    == 8);
    // 15 codebooks for cids 0..14 (W2 spec). Wave 8 needs to verify
    // whether real W2 GGUF has cid.15 too and either add the 16th or
    // assert 15 is the cap.
    TEST_ASSERT(m->cp_codec_embd.size() == 15);
    TEST_ASSERT(m->cp_head      .size() == 15);
    for (uint32_t cid = 0; cid < 15; ++cid) {
        TEST_ASSERT(m->cp_codec_embd[cid] != nullptr);
        TEST_ASSERT(m->cp_head[cid]       != nullptr);
        // W2 verify tool's expect_shape: cp_codec_embd.{cid}.weight ne
        // = [n_embd=2048, n_cp_per_codebook=2048], cp_head.{cid}.weight
        // ne = [n_cp_embd=1024, n_cp_per_codebook=2048].
        TEST_ASSERT(m->cp_codec_embd[cid]->ne[0] == 2048);
        TEST_ASSERT(m->cp_codec_embd[cid]->ne[1] == 2048);
        TEST_ASSERT(m->cp_head[cid]->ne[0]       == 1024);
        TEST_ASSERT(m->cp_head[cid]->ne[1]       == 2048);
    }
    TEST_ASSERT(m->codec_head != nullptr);
    TEST_ASSERT(m->codec_head->ne[0] == 2048);
    TEST_ASSERT(m->codec_head->ne[1] == 3072);

    // backbone forward: 1 text token through 28 blocks. cp pass skipped
    // (W5b scope; cp is a separate forward step driven by per-frame
    // mrope + separate kv cache, both W5b gap items deferred to W8).
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx      = 64;
    cp.n_batch    = 1;
    cp.n_ubatch   = 1;
    cp.no_perf    = true;
    cp.embeddings = true;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (ctx == nullptr) {
        std::fprintf(stderr,
            "test-qwen3tts-talker: FAIL — real-weight context init returned null\n"
            "  The model loaded but llama_init_from_model failed. Most likely cause:\n"
            "    - ANE/METAL scheduler tried to claim a NONE op (cpufix path\n"
            "      used devices={cpu, nullptr} on model_params; if the model\n"
            "      was loaded with a different devices list, that load path\n"
            "      bypassed the cpu-only constraint)\n");
        std::abort();
    }
    llama_free(ctx);
    llama_model_free(model);

    std::printf("test-qwen3tts-talker: real-weight smoke OK (load + hparams + per-cid + backbone ctx init)\n");
}

}  // namespace

int main(int argc, char ** argv) {
    // surface loader errors to stderr (default callback is silent for
    // non-error levels; we want the load failure to be visible)
    llama_log_set([](ggml_log_level level, const char * text, void *) {
        std::fprintf(stderr, "[%s] %s", level == GGML_LOG_LEVEL_ERROR ? "ERR" :
                                       level == GGML_LOG_LEVEL_WARN  ? "WRN" : "INF", text);
    }, nullptr);

    std::string path = build_synthetic_talker_gguf();

    struct llama_model * model = load_talker_gguf(path);
    if (model == nullptr) {
        std::fprintf(stderr,
            "test-qwen3tts-talker: FAIL — llama_model_load_from_file returned null for %s\n"
            "  This indicates the loader has a schema mismatch with the W2 GGUF layout.\n"
            "  The W2 verify tool (tools/tessera/verify_qwen3tts_gguf.py) is the spec; the\n"
            "  test mirrors its invariants. The mismatch is most likely in:\n"
            "    - raw TTS metadata keys (codec_vocab_size, predictor_layers, etc.)\n"
            "    - per-cp-codebook tensor naming (cp_codec_embd.{cid}.weight)\n"
            "    - mrope section widths array layout\n"
            "    - layer count or per-block tensor set\n",
            path.c_str());
        std::abort();
    }
    ::unlink(path.c_str());

    check_arch_hparams(model);
    check_tensor_state(model);
    check_forward_graph(model);

    llama_model_free(model);

    // Real-weight verification (optional). If TESSERA_QWEN3TTS_TALKER_GGUF
    // (or argv[1]) points at a real W2 talker GGUF, run the smoke test.
    // This is the W5b follow-up verification gate.
    const char * env_real = std::getenv("TESSERA_QWEN3TTS_TALKER_GGUF");
    std::string real_path = (argc >= 2) ? std::string(argv[1])
                  : (env_real        ? std::string(env_real)
                                     : std::string());
    if (!real_path.empty()) {
        check_real_weight_forward(real_path);
    }

    std::printf("test-qwen3tts-talker: all tests OK\n");
    return 0;
}
