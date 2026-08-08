#include "shim.h"
#include <dlfcn.h>

namespace tessera {

static void *g_llama = nullptr;
static void *g_ffi = nullptr;
static LlamaApi g_api{};
static std::string g_last_error;

static void resolve_api() {
    if (!g_llama) return;
    auto sym = [&](const char *name) -> void* { return dlsym(g_llama, name); };
    // model
    g_api.model_load_from_file = reinterpret_cast<decltype(g_api.model_load_from_file)>(sym("llama_model_load_from_file"));
    if (!g_api.model_load_from_file) g_api.model_load_from_file = reinterpret_cast<decltype(g_api.model_load_from_file)>(sym("llama_load_model_from_file"));
    g_api.model_free = reinterpret_cast<decltype(g_api.model_free)>(sym("llama_free_model"));
    if (!g_api.model_free) g_api.model_free = reinterpret_cast<decltype(g_api.model_free)>(sym("llama_model_free"));
    // context
    g_api.new_context_with_model = reinterpret_cast<decltype(g_api.new_context_with_model)>(sym("llama_new_context_with_model"));
    g_api.free_context = reinterpret_cast<decltype(g_api.free_context)>(sym("llama_free"));
    if (!g_api.free_context) g_api.free_context = reinterpret_cast<decltype(g_api.free_context)>(sym("llama_free_context"));
    // tokenize
    g_api.tokenize = reinterpret_cast<decltype(g_api.tokenize)>(sym("llama_tokenize"));
    g_api.token_to_piece = reinterpret_cast<decltype(g_api.token_to_piece)>(sym("llama_token_to_piece"));
    // decode
    g_api.decode = reinterpret_cast<decltype(g_api.decode)>(sym("llama_decode"));
    g_api.batch_get_one = reinterpret_cast<decltype(g_api.batch_get_one)>(sym("llama_batch_get_one"));
    g_api.get_logits = reinterpret_cast<decltype(g_api.get_logits)>(sym("llama_get_logits"));
    g_api.get_logits_ith = reinterpret_cast<decltype(g_api.get_logits_ith)>(sym("llama_get_logits_ith"));
    // kv
    g_api.kv_cache_clear = reinterpret_cast<decltype(g_api.kv_cache_clear)>(sym("llama_kv_cache_clear"));
    if (!g_api.kv_cache_clear) g_api.kv_cache_clear = reinterpret_cast<decltype(g_api.kv_cache_clear)>(sym("llama_kv_cache_seq_rm"));
    // sampler new chain
    g_api.sampler_chain_init = reinterpret_cast<decltype(g_api.sampler_chain_init)>(sym("llama_sampler_chain_init"));
    g_api.sampler_chain_add_greedy = reinterpret_cast<decltype(g_api.sampler_chain_add_greedy)>(sym("llama_sampler_chain_add_greedy"));
    g_api.sampler_sample = reinterpret_cast<decltype(g_api.sampler_sample)>(sym("llama_sampler_sample"));
    g_api.sampler_free = reinterpret_cast<decltype(g_api.sampler_free)>(sym("llama_sampler_free"));
    // legacy
    g_api.sample_token_greedy = reinterpret_cast<decltype(g_api.sample_token_greedy)>(sym("llama_sample_token_greedy"));
    if (!g_api.sample_token_greedy) g_api.sample_token_greedy = reinterpret_cast<decltype(g_api.sample_token_greedy)>(sym("llama_sampling_sample_and_accept_n"));
}

bool llama_shim_load(const std::string &lib_path) {
    std::string p = lib_path.empty() ? "libllama.so" : lib_path;
    // also try versioned and build paths
    const char* candidates[] = {p.c_str(), "libllama.so.0", "./build/src/libllama.so", "./build-linux/_deps/llama.cpp-build/src/libllama.so", nullptr};
    for (int i=0; candidates[i]; ++i) {
        g_llama = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (g_llama) break;
    }
    if (!g_llama) {
        g_last_error = dlerror() ? dlerror() : "dlopen failed";
        return false;
    }
    resolve_api();
    // at minimum we need model_load and new_context
    if (!g_api.model_load_from_file || !g_api.new_context_with_model) {
        g_last_error = "required llama symbols missing";
        // keep handle but report incomplete — caller will fallback
    }
    return g_llama != nullptr;
}
void llama_shim_unload() {
    if (g_llama) { dlclose(g_llama); g_llama = nullptr; }
    g_api = LlamaApi{};
    g_last_error.clear();
}
bool llama_shim_is_loaded() { return g_llama != nullptr; }
void* llama_shim_handle() { return g_llama; }
const LlamaApi* llama_api() { return &g_api; }
std::string llama_shim_last_error() { return g_last_error; }

bool tess_ffi_load(const std::string &lib_path) {
    std::string p = lib_path.empty() ? "libtessera-ffi.so" : lib_path;
    g_ffi = dlopen(p.c_str(), RTLD_NOW | RTLD_LOCAL);
    return g_ffi != nullptr;
}
void tess_ffi_unload() { if (g_ffi) { dlclose(g_ffi); g_ffi = nullptr; } }

} // namespace tessera
