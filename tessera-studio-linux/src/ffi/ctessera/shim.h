#pragma once
#include <string>

// Thin dlopen wrapper for libllama / libtessera-ffi
// Mirrors Sources/CLlama/cllama_shim.c + ffi/tessera_ffi.cpp
// Resolves symbols via dlsym so the Linux build works without link-time libllama.

namespace tessera {

bool llama_shim_load(const std::string &lib_path = "");
void llama_shim_unload();
bool llama_shim_is_loaded();
void* llama_shim_handle();

// Opaque llama types without including llama.h
struct LlamaModelOpaque;
struct LlamaContextOpaque;
struct LlamaSamplerOpaque;

// Minimal llama_batch for correct ABI — matches llama.h: tokens + n_tokens
struct LlamaBatch {
    int32_t n_tokens = 0;
    int32_t *token = nullptr;
    float *embd = nullptr;
    int32_t *pos = nullptr;
    int32_t *seq_id = nullptr;
    int8_t *logits = nullptr;
};

// Function pointer table resolved via dlsym
struct LlamaApi {
    // model
    void* (*model_load_from_file)(const char *path, int n_gpu_layers) = nullptr;
    void (*model_free)(void *model) = nullptr;
    // context
    void* (*new_context_with_model)(void *model, int n_ctx, int n_batch, int n_threads, int n_threads_batch) = nullptr;
    void (*free_context)(void *ctx) = nullptr;
    // tokenize / detokenize
    int (*tokenize)(void *model, const char *text, int text_len, int *tokens, int n_tokens_max, bool add_special, bool parse_special) = nullptr;
    int (*token_to_piece)(void *model, int token, char *buf, int length, int lstrip, bool special) = nullptr;
    // decode — correct ABI: int llama_decode(ctx, batch)
    int (*decode)(void *ctx, LlamaBatch batch) = nullptr;
    // batch helper (optional, for single-token batches)
    LlamaBatch (*batch_get_one)(int32_t *token, int32_t n_tokens) = nullptr;
    float* (*get_logits)(void *ctx) = nullptr;
    float* (*get_logits_ith)(void *ctx, int i) = nullptr;
    // kv cache
    void (*kv_cache_clear)(void *ctx) = nullptr;
    // sampler (new chain API or legacy)
    void* (*sampler_chain_init)(int params) = nullptr;
    void (*sampler_chain_add_greedy)(void *chain) = nullptr;
    int (*sampler_sample)(void *chain, void *ctx, int idx) = nullptr;
    void (*sampler_free)(void *chain) = nullptr;
    // legacy sampler fallback
    int (*sample_token_greedy)(void *ctx, int idx) = nullptr;
};

const LlamaApi* llama_api();
std::string llama_shim_last_error();

bool tess_ffi_load(const std::string &lib_path = "");
void tess_ffi_unload();

} // namespace tessera
