// cllama_shim.c - runtime-loaded bridge to libllama (see cllama_shim.h).
//
// Every llama.cpp symbol is resolved with dlsym after a dlopen, so this
// translation unit has NO link-time dependency on libllama: the SwiftPM
// package builds and runs without the native library and reports
// unavailable instead. llama.h is included only for its type definitions
// (structs / enums / function signatures); no llama symbol is referenced
// directly, so nothing here forces a link against the dylib.
//
// When the package is built outside a llama.cpp checkout (no llama.h), the
// build defines CLLAMA_NO_HEADERS and this file compiles to a stub that
// always reports unavailable, so `swift build` still succeeds.

#include "include/cllama_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: - Error reporting (thread-local, always compiled)

static _Thread_local char g_error[512];

static void set_error(const char *msg) {
    snprintf(g_error, sizeof(g_error), "%s", msg);
}

const char *cllama_last_error(void) {
    return g_error;
}

#ifndef CLLAMA_NO_HEADERS

#include <llama.h>
#include <tessera-runtime.h>

#include <dlfcn.h>
#include <pthread.h>

// MARK: - Resolved symbol table
//
// typeof(<declared function>) * guarantees each pointer's type matches the
// real llama.h signature exactly, so by-value struct arguments (params,
// batches) use the correct ABI without hand-written typedefs.

static struct {
    typeof(llama_backend_init)               * backend_init;
    typeof(llama_model_default_params)       * model_default_params;
    typeof(llama_context_default_params)     * context_default_params;
    typeof(llama_sampler_chain_default_params) * sampler_chain_default_params;
    typeof(llama_model_load_from_file)       * model_load_from_file;
    typeof(llama_model_free)                 * model_free;
    typeof(llama_init_from_model)            * init_from_model;
    typeof(llama_free)                       * free_ctx;
    typeof(llama_model_get_vocab)            * model_get_vocab;
    typeof(llama_n_batch)                    * n_batch;
    typeof(llama_tokenize)                   * tokenize;
    typeof(llama_token_to_piece)             * token_to_piece;
    typeof(llama_detokenize)                 * detokenize;
    typeof(llama_vocab_n_tokens)             * vocab_n_tokens;
    typeof(llama_vocab_is_eog)               * vocab_is_eog;
    typeof(llama_batch_get_one)              * batch_get_one;
    typeof(llama_decode)                     * decode;
    typeof(llama_sampler_chain_init)         * sampler_chain_init;
    typeof(llama_sampler_chain_add)          * sampler_chain_add;
    typeof(llama_sampler_init_greedy)        * sampler_init_greedy;
    typeof(llama_sampler_sample)             * sampler_sample;
    typeof(llama_sampler_accept)             * sampler_accept;
    typeof(llama_sampler_free)               * sampler_free;
    // Continuous-batching surface (Part A). These are present in libllama but
    // were not resolved by the original single-sequence shim.
    typeof(llama_batch_init)                 * batch_init;
    typeof(llama_batch_free)                 * batch_free;
    typeof(llama_get_memory)                 * get_memory;
    typeof(llama_memory_clear)               * memory_clear;
    typeof(llama_memory_seq_rm)              * memory_seq_rm;
    typeof(llama_memory_seq_cp)              * memory_seq_cp;
    typeof(llama_memory_seq_keep)            * memory_seq_keep;
    typeof(llama_memory_seq_pos_min)         * memory_seq_pos_min;
    typeof(llama_memory_seq_pos_max)         * memory_seq_pos_max;
    typeof(llama_memory_can_shift)           * memory_can_shift;
    typeof(llama_synchronize)                * synchronize;
    typeof(llama_get_logits)                 * get_logits;
    typeof(llama_get_logits_ith)             * get_logits_ith;
    typeof(llama_n_batch)                    * n_batch_ctx;
} g_llama;

static void *g_handle = NULL;
static int   g_backend_initialized = 0;
static pthread_mutex_t g_load_mutex = PTHREAD_MUTEX_INITIALIZER;

// the candidate that successfully loaded libllama, kept so the spec library
// loader can look for libllama-common.dylib next to it (pairing pattern:
// both ship from the same build)
static char g_llama_path[1024];

// Resolved tessera_rt_* symbols from libllama-common.dylib.
static struct {
    typeof(tessera_rt_load)       * rt_load;
    typeof(tessera_rt_generate)   * rt_generate;
    typeof(tessera_rt_free)       * rt_free;
    typeof(tessera_rt_last_error) * rt_last_error;
} g_spec;

static void *g_spec_handle = NULL;

int cllama_is_available(void) {
    return g_handle != NULL;
}

static void set_error_dl(const char *prefix) {
    const char *reason = dlerror();
    snprintf(g_error, sizeof(g_error), "%s: %s", prefix, reason ? reason : "unknown dlopen error");
}

#define RESOLVE(field, name)                                              \
    do {                                                                  \
        *(void **)(&g_llama.field) = dlsym(g_handle, name);               \
        if (g_llama.field == NULL) {                                      \
            set_error("cllama: missing symbol " name);                    \
            dlclose(g_handle);                                            \
            g_handle = NULL;                                              \
            return 0;                                                     \
        }                                                                 \
    } while (0)

// Optional resolve: for symbols that may be absent in older libllama builds
// (the continuous-batching surface). Leaves the pointer NULL when absent; the
// batch-decode entry point checks and reports unsupported. The core
// single-sequence path still works without these.
#define RESOLVE_OPTIONAL(field, name)                                     \
    do {                                                                  \
        *(void **)(&g_llama.field) = dlsym(g_handle, name);               \
    } while (0)

int cllama_load_library(const char *dylib_path_override) {
    pthread_mutex_lock(&g_load_mutex);
    if (g_handle != NULL) {
        pthread_mutex_unlock(&g_load_mutex);
        return 1;
    }

    // Candidate paths: explicit override, env var, then the default loader
    // search (DYLD_FALLBACK_LIBRARY_PATH, @rpath, standard dirs).
    const char *candidates[3];
    int n_candidates = 0;
    if (dylib_path_override != NULL && dylib_path_override[0] != '\0') {
        candidates[n_candidates++] = dylib_path_override;
    }
    const char *env_path = getenv("TESSERA_LLAMA_DYLIB");
    if (env_path != NULL && env_path[0] != '\0') {
        candidates[n_candidates++] = env_path;
    }
    candidates[n_candidates++] = "libllama.dylib";

    for (int i = 0; i < n_candidates; ++i) {
        g_handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (g_handle != NULL) {
            snprintf(g_llama_path, sizeof(g_llama_path), "%s", candidates[i]);
            break;
        }
    }

    if (g_handle == NULL) {
        set_error_dl("cllama: could not load libllama.dylib");
        pthread_mutex_unlock(&g_load_mutex);
        return 0;
    }

    RESOLVE(backend_init,               "llama_backend_init");
    RESOLVE(model_default_params,       "llama_model_default_params");
    RESOLVE(context_default_params,     "llama_context_default_params");
    RESOLVE(sampler_chain_default_params, "llama_sampler_chain_default_params");
    RESOLVE(model_load_from_file,       "llama_model_load_from_file");
    RESOLVE(model_free,                 "llama_model_free");
    RESOLVE(init_from_model,            "llama_init_from_model");
    RESOLVE(free_ctx,                   "llama_free");
    RESOLVE(model_get_vocab,            "llama_model_get_vocab");
    RESOLVE(n_batch,                    "llama_n_batch");
    RESOLVE(tokenize,                   "llama_tokenize");
    RESOLVE(token_to_piece,             "llama_token_to_piece");
    RESOLVE(detokenize,                 "llama_detokenize");
    RESOLVE(vocab_n_tokens,             "llama_vocab_n_tokens");
    RESOLVE(vocab_is_eog,               "llama_vocab_is_eog");
    RESOLVE(batch_get_one,              "llama_batch_get_one");
    RESOLVE(decode,                     "llama_decode");
    RESOLVE(sampler_chain_init,         "llama_sampler_chain_init");
    RESOLVE(sampler_chain_add,          "llama_sampler_chain_add");
    RESOLVE(sampler_init_greedy,        "llama_sampler_init_greedy");
    RESOLVE(sampler_sample,             "llama_sampler_sample");
    RESOLVE(sampler_accept,             "llama_sampler_accept");
    RESOLVE(sampler_free,               "llama_sampler_free");

    // Continuous-batching surface (Part A). Optional: older libllama builds
    // may not export these. cllama_is_batch_available() reports whether the
    // full set resolved; batch_decode returns -2 ("unsupported") otherwise.
    RESOLVE_OPTIONAL(batch_init,         "llama_batch_init");
    RESOLVE_OPTIONAL(batch_free,         "llama_batch_free");
    RESOLVE_OPTIONAL(get_memory,         "llama_get_memory");
    RESOLVE_OPTIONAL(memory_clear,       "llama_memory_clear");
    RESOLVE_OPTIONAL(memory_seq_rm,      "llama_memory_seq_rm");
    RESOLVE_OPTIONAL(memory_seq_cp,      "llama_memory_seq_cp");
    RESOLVE_OPTIONAL(memory_seq_keep,    "llama_memory_seq_keep");
    RESOLVE_OPTIONAL(memory_seq_pos_min, "llama_memory_seq_pos_min");
    RESOLVE_OPTIONAL(memory_seq_pos_max, "llama_memory_seq_pos_max");
    RESOLVE_OPTIONAL(memory_can_shift,   "llama_memory_can_shift");
    RESOLVE_OPTIONAL(synchronize,        "llama_synchronize");
    RESOLVE_OPTIONAL(get_logits,         "llama_get_logits");
    RESOLVE_OPTIONAL(get_logits_ith,     "llama_get_logits_ith");
    RESOLVE_OPTIONAL(n_batch_ctx,        "llama_n_batch");

    if (!g_backend_initialized) {
        g_llama.backend_init();
        g_backend_initialized = 1;
    }

    g_error[0] = '\0';
    pthread_mutex_unlock(&g_load_mutex);
    return 1;
}

#undef RESOLVE

// MARK: - Spec library (libllama-common.dylib, tessera_rt_* entry points)

int cllama_is_spec_available(void) {
    return g_spec_handle != NULL;
}

int cllama_load_spec_library(const char *dylib_path_override) {
    pthread_mutex_lock(&g_load_mutex);
    if (g_spec_handle != NULL) {
        pthread_mutex_unlock(&g_load_mutex);
        return 1;
    }

    // Sibling of the resolved libllama.dylib, when it was loaded from an
    // explicit path (bare-name loads fall through to the default search).
    char sibling[1024];
    sibling[0] = '\0';
    {
        const char *slash = strrchr(g_llama_path, '/');
        if (slash != NULL && (size_t)(slash - g_llama_path) + 1 < sizeof(sibling)) {
            snprintf(sibling, sizeof(sibling), "%.*slibllama-common.dylib",
                     (int)(slash - g_llama_path + 1), g_llama_path);
        }
    }

    // Candidates: explicit override, env var, sibling of libllama, default
    // loader search.
    const char *candidates[4];
    int n_candidates = 0;
    if (dylib_path_override != NULL && dylib_path_override[0] != '\0') {
        candidates[n_candidates++] = dylib_path_override;
    }
    const char *env_path = getenv("TESSERA_LLAMA_COMMON_DYLIB");
    if (env_path != NULL && env_path[0] != '\0') {
        candidates[n_candidates++] = env_path;
    }
    if (sibling[0] != '\0') {
        candidates[n_candidates++] = sibling;
    }
    candidates[n_candidates++] = "libllama-common.dylib";

    for (int i = 0; i < n_candidates; ++i) {
        g_spec_handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (g_spec_handle != NULL) {
            break;
        }
    }

    if (g_spec_handle == NULL) {
        set_error_dl("cllama: could not load libllama-common.dylib");
        pthread_mutex_unlock(&g_load_mutex);
        return 0;
    }

#define RESOLVE_SPEC(field, name)                                           \
    do {                                                                    \
        *(void **)(&g_spec.field) = dlsym(g_spec_handle, name);             \
        if (g_spec.field == NULL) {                                         \
            set_error("cllama: missing symbol " name);                      \
            dlclose(g_spec_handle);                                         \
            g_spec_handle = NULL;                                           \
            pthread_mutex_unlock(&g_load_mutex);                            \
            return 0;                                                       \
        }                                                                   \
    } while (0)

    RESOLVE_SPEC(rt_load,       "tessera_rt_load");
    RESOLVE_SPEC(rt_generate,   "tessera_rt_generate");
    RESOLVE_SPEC(rt_free,       "tessera_rt_free");
    RESOLVE_SPEC(rt_last_error, "tessera_rt_last_error");

#undef RESOLVE_SPEC

    g_error[0] = '\0';
    pthread_mutex_unlock(&g_load_mutex);
    return 1;
}

// The spec engine handle is the opaque tessera_rt pointer; the Swift side
// only ever passes it back into the shim.
struct cllama_spec_engine;

cllama_spec_engine *cllama_engine_load_spec(const char *trunk_path,
                                            const char *draft_path,
                                            uint32_t n_ctx,
                                            int32_t n_threads,
                                            int32_t n_gpu_layers,
                                            int32_t draft_max) {
    if (!cllama_is_spec_available()) {
        set_error("cllama: spec library not loaded; call cllama_load_spec_library first");
        return NULL;
    }

    tessera_rt *rt = g_spec.rt_load(trunk_path, draft_path, n_ctx,
                                    n_threads, n_gpu_layers, draft_max);
    if (rt == NULL) {
        const char *reason = g_spec.rt_last_error();
        snprintf(g_error, sizeof(g_error), "cllama: spec load failed: %s",
                 (reason != NULL && reason[0] != '\0') ? reason : "unknown error");
        return NULL;
    }

    g_error[0] = '\0';
    return (cllama_spec_engine *)rt;
}

int32_t cllama_engine_generate_spec(cllama_spec_engine *eng,
                                    const char *prompt,
                                    int32_t max_tokens,
                                    int32_t telemetry_topk,
                                    cllama_token_callback on_token,
                                    cllama_trace_callback on_trace,
                                    void *user_data) {
    if (!cllama_is_spec_available()) {
        set_error("cllama: spec library not loaded; call cllama_load_spec_library first");
        return -1;
    }
    if (eng == NULL) {
        set_error("cllama: null spec engine");
        return -1;
    }

    // cllama_token_callback and tessera_rt_token_cb have identical
    // signatures; same for cllama_trace_callback / tessera_rt_trace_cb
    const int32_t n = g_spec.rt_generate(
            (tessera_rt *)eng, prompt, max_tokens, telemetry_topk,
            (tessera_rt_token_cb)on_token, (tessera_rt_trace_cb)on_trace,
            user_data);
    if (n < 0) {
        const char *reason = g_spec.rt_last_error();
        snprintf(g_error, sizeof(g_error), "cllama: spec generate failed: %s",
                 (reason != NULL && reason[0] != '\0') ? reason : "unknown error");
        return -1;
    }

    g_error[0] = '\0';
    return n;
}

void cllama_engine_free_spec(cllama_spec_engine *eng) {
    if (eng == NULL || !cllama_is_spec_available()) {
        return;
    }
    g_spec.rt_free((tessera_rt *)eng);
}

// MARK: - Engine

struct cllama_engine {
    struct llama_model   * model;
    struct llama_context * ctx;
    const struct llama_vocab * vocab;
    struct llama_sampler * sampler;
};

cllama_engine *cllama_engine_load(const char *model_path,
                                  uint32_t n_ctx,
                                  int32_t n_threads,
                                  int32_t n_gpu_layers) {
    if (!cllama_is_available()) {
        set_error("cllama: library not loaded; call cllama_load_library first");
        return NULL;
    }
    if (model_path == NULL || model_path[0] == '\0') {
        set_error("cllama: model_path is empty");
        return NULL;
    }

    struct llama_model_params mparams = g_llama.model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;

    struct llama_model *model = g_llama.model_load_from_file(model_path, mparams);
    if (model == NULL) {
        set_error("cllama: failed to load model");
        return NULL;
    }

    struct llama_context_params cparams = g_llama.context_default_params();
    if (n_ctx > 0) {
        cparams.n_ctx = n_ctx;
    }
    if (n_threads > 0) {
        cparams.n_threads = n_threads;
        cparams.n_threads_batch = n_threads;
    }

    struct llama_context *ctx = g_llama.init_from_model(model, cparams);
    if (ctx == NULL) {
        set_error("cllama: failed to create context");
        g_llama.model_free(model);
        return NULL;
    }

    struct llama_sampler_chain_params sparams = g_llama.sampler_chain_default_params();
    struct llama_sampler *sampler = g_llama.sampler_chain_init(sparams);
    g_llama.sampler_chain_add(sampler, g_llama.sampler_init_greedy());

    cllama_engine *eng = (cllama_engine *)calloc(1, sizeof(cllama_engine));
    if (eng == NULL) {
        set_error("cllama: out of memory");
        g_llama.sampler_free(sampler);
        g_llama.free_ctx(ctx);
        g_llama.model_free(model);
        return NULL;
    }
    eng->model   = model;
    eng->ctx     = ctx;
    eng->vocab   = g_llama.model_get_vocab(model);
    eng->sampler = sampler;

    g_error[0] = '\0';
    return eng;
}

// Tokenize `text` into a freshly malloc'd buffer. Returns the token count and
// sets *out_tokens (caller frees), or returns -1 on error.
static int32_t tokenize_alloc(const struct llama_vocab *vocab,
                              const char *text,
                              llama_token **out_tokens) {
    const int32_t text_len = (int32_t)strlen(text);
    const int32_t n = -g_llama.tokenize(vocab, text, text_len, NULL, 0, true, true);
    if (n <= 0) {
        set_error("cllama: failed to size prompt tokens");
        return -1;
    }
    llama_token *tokens = (llama_token *)malloc(sizeof(llama_token) * (size_t)n);
    if (tokens == NULL) {
        set_error("cllama: out of memory tokenizing");
        return -1;
    }
    if (g_llama.tokenize(vocab, text, text_len, tokens, n, true, true) < 0) {
        set_error("cllama: failed to tokenize prompt");
        free(tokens);
        return -1;
    }
    *out_tokens = tokens;
    return n;
}

int32_t cllama_engine_generate(cllama_engine *eng,
                               const char *prompt,
                               int32_t max_tokens,
                               cllama_token_callback on_token,
                               void *user_data) {
    if (eng == NULL || prompt == NULL) {
        set_error("cllama: null engine or prompt");
        return -1;
    }

    llama_token *prompt_tokens = NULL;
    const int32_t n_prompt = tokenize_alloc(eng->vocab, prompt, &prompt_tokens);
    if (n_prompt < 0) {
        return -1;
    }

    // Evaluate the prompt in chunks no larger than the context batch size.
    const int32_t batch_limit = (int32_t)g_llama.n_batch(eng->ctx);
    const int32_t chunk = batch_limit > 0 ? batch_limit : n_prompt;
    for (int32_t i = 0; i < n_prompt; i += chunk) {
        const int32_t n = (n_prompt - i) < chunk ? (n_prompt - i) : chunk;
        struct llama_batch batch = g_llama.batch_get_one(prompt_tokens + i, n);
        if (g_llama.decode(eng->ctx, batch) != 0) {
            set_error("cllama: failed to decode prompt");
            free(prompt_tokens);
            return -1;
        }
    }
    free(prompt_tokens);

    int32_t n_decode = 0;
    for (int32_t i = 0; i < max_tokens; ++i) {
        const llama_token new_token_id = g_llama.sampler_sample(eng->sampler, eng->ctx, -1);
        g_llama.sampler_accept(eng->sampler, new_token_id);

        if (g_llama.vocab_is_eog(eng->vocab, new_token_id)) {
            break;
        }

        char buf[256];
        const int32_t n = g_llama.token_to_piece(eng->vocab, new_token_id, buf, (int32_t)sizeof(buf) - 1, 0, true);
        if (n < 0) {
            set_error("cllama: failed to convert token to piece");
            return -1;
        }
        buf[n] = '\0';
        if (on_token != NULL) {
            on_token(buf, new_token_id, user_data);
        }
        n_decode += 1;

        llama_token next = new_token_id;
        struct llama_batch batch = g_llama.batch_get_one(&next, 1);
        if (g_llama.decode(eng->ctx, batch) != 0) {
            set_error("cllama: decode failed during generation");
            return -1;
        }
    }

    g_error[0] = '\0';
    return n_decode;
}

void cllama_engine_free(cllama_engine *eng) {
    if (eng == NULL) {
        return;
    }
    if (eng->sampler != NULL) {
        g_llama.sampler_free(eng->sampler);
    }
    if (eng->ctx != NULL) {
        g_llama.free_ctx(eng->ctx);
    }
    if (eng->model != NULL) {
        g_llama.model_free(eng->model);
    }
    free(eng);
}

int32_t cllama_engine_n_vocab(const cllama_engine *eng) {
    if (!cllama_is_available()) {
        set_error("cllama: library not loaded; call cllama_load_library first");
        return -1;
    }
    if (eng == NULL || eng->vocab == NULL) {
        set_error("cllama: null engine");
        return -1;
    }

    const int32_t n = g_llama.vocab_n_tokens(eng->vocab);
    g_error[0] = '\0';
    return n;
}

// MARK: - Continuous-batching surface (Part A)

// Non-zero when the full batch + memory symbol set resolved at load time.
int cllama_is_batch_available(void) {
    return g_llama.batch_init != NULL
        && g_llama.batch_free != NULL
        && g_llama.get_memory != NULL
        && g_llama.memory_seq_rm != NULL
        && g_llama.memory_seq_cp != NULL
        && g_llama.memory_seq_pos_max != NULL
        && g_llama.decode != NULL;
}

// Decode one token for each of `n_slots` ready sequences in a single
// llama_decode call. Each slot contributes (seq_id, token, position). After
// the call, per-slot logits are written to `logits_out` at
// `logits_out + slot * logits_stride`. Returns the number of slots decoded
// (== n_slots) on success, -2 if the batch surface is unavailable, -1 on
// other errors. The caller samples each slot's logits row to pick the next
// token.
int32_t cllama_engine_batch_decode(cllama_engine *eng,
                                   const int32_t *seq_ids,
                                   const int32_t *tokens,
                                   const int32_t *positions,
                                   int32_t n_slots,
                                   float *logits_out,
                                   int32_t logits_stride) {
    if (!cllama_is_available()) {
        set_error("cllama: library not loaded");
        return -1;
    }
    if (eng == NULL || eng->ctx == NULL) {
        set_error("cllama: null engine");
        return -1;
    }
    if (!cllama_is_batch_available()) {
        set_error("cllama: batch surface not available in this libllama build");
        return -2;
    }
    if (n_slots <= 0 || seq_ids == NULL || tokens == NULL || positions == NULL) {
        set_error("cllama: batch_decode invalid slot arrays");
        return -1;
    }

    // Cap on slots per batch: n_batch is the logical max tokens per decode.
    const int32_t batch_limit = (int32_t) g_llama.n_batch(eng->ctx);
    const int32_t n = n_slots > batch_limit ? batch_limit : n_slots;

    // Build the batch by filling the struct fields directly (this llama.h has
    // no llama_batch_add helper). llama_batch_init(n_tokens, embd, n_seq_max)
    // allocates the per-token arrays; we populate them per slot.
    struct llama_batch batch = g_llama.batch_init(n, 0, 1);
    for (int32_t i = 0; i < n; ++i) {
        batch.token[i]    = tokens[i];
        batch.pos[i]      = positions[i];
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = seq_ids[i];
        batch.logits[i]   = 1;   // request logits for every slot
    }
    batch.n_tokens = n;

    const int32_t rc = g_llama.decode(eng->ctx, batch);
    g_llama.batch_free(batch);
    if (rc != 0) {
        set_error("cllama: batch decode failed");
        return -1;
    }

    // Wait for any async compute to land before we read logits.
    if (g_llama.synchronize != NULL) {
        g_llama.synchronize(eng->ctx);
    }

    // llama_decode populates logits for every token where logits[i] != 0.
    // We set logits=true above, so all n rows are available. The logit row
    // for slot i starts at logits + i * n_vocab. n_vocab = vocab size.
    const int32_t n_vocab = g_llama.vocab_n_tokens(eng->vocab);
    if (n_vocab <= 0) {
        set_error("cllama: invalid vocab size");
        return -1;
    }
    const float *logits = g_llama.get_logits(eng->ctx);
    if (logits == NULL) {
        set_error("cllama: no logits after decode");
        return -1;
    }
    // logits_stride_bytes is the byte stride between slot rows in the caller's
    // buffer. 0 means packed (n_vocab * sizeof(float)).
    const size_t stride = logits_stride > 0
        ? (size_t)logits_stride
        : (size_t)n_vocab * sizeof(float);
    for (int32_t i = 0; i < n; ++i) {
        memcpy((uint8_t *)logits_out + (size_t)i * stride,
               logits + (size_t)i * n_vocab,
               (size_t)n_vocab * sizeof(float));
    }

    g_error[0] = '\0';
    return n;
}

// Clear (evict) a sequence's KV cells. After this the slot is empty and can
// be reused for prefill.
void cllama_slot_clear(cllama_engine *eng, int32_t seq_id) {
    if (!cllama_is_batch_available() || eng == NULL || eng->ctx == NULL) return;
    llama_memory_t mem = g_llama.get_memory(eng->ctx);
    if (mem == NULL) return;
    g_llama.memory_seq_rm(mem, seq_id, -1, -1);
    g_error[0] = '\0';
}

// Copy (fork) a sequence's KV cells to a new sequence id - for branching
// agents that diverge from a shared prefix.
void cllama_slot_copy(cllama_engine *eng, int32_t src, int32_t dst) {
    if (!cllama_is_batch_available() || eng == NULL || eng->ctx == NULL) return;
    llama_memory_t mem = g_llama.get_memory(eng->ctx);
    if (mem == NULL) return;
    g_llama.memory_seq_cp(mem, src, dst, -1, -1);
    g_error[0] = '\0';
}

// Largest position present in the sequence's KV - the slot's occupancy for
// preemption decisions. -1 if empty.
int32_t cllama_slot_pos_max(cllama_engine *eng, int32_t seq_id) {
    if (!cllama_is_batch_available() || eng == NULL || eng->ctx == NULL) return -1;
    llama_memory_t mem = g_llama.get_memory(eng->ctx);
    if (mem == NULL) return -1;
    return (int32_t) g_llama.memory_seq_pos_max(mem, seq_id);
}

// Decode a batch of n tokens with per-token logits flags (for mixed
// prefill+decode batches where intermediate prefill tokens set logits=0).
// Each token i gets (seq_ids[i], tokens[i], positions[i], logits_flags[i]).
// Does NOT copy logits out — the caller reads them via cllama_get_logits_ith
// for whichever batch positions had logits=1. Returns 0 on success, the
// llama_decode return code (1=no KV slot, 2=aborted) otherwise, -2 if the
// batch surface is unavailable, -1 on other errors.
int32_t cllama_engine_batch_decode_ext(cllama_engine *eng,
                                       const int32_t *tokens,
                                       const int32_t *seq_ids,
                                       const int32_t *positions,
                                       const int8_t  *logits_flags,
                                       int32_t n) {
    if (!cllama_is_available()) {
        set_error("cllama: library not loaded");
        return -1;
    }
    if (eng == NULL || eng->ctx == NULL) {
        set_error("cllama: null engine");
        return -1;
    }
    if (!cllama_is_batch_available()) {
        set_error("cllama: batch surface not available");
        return -2;
    }
    if (n <= 0 || tokens == NULL || seq_ids == NULL || positions == NULL || logits_flags == NULL) {
        set_error("cllama: batch_decode_ext invalid arrays");
        return -1;
    }

    const int32_t batch_limit = (g_llama.n_batch_ctx != NULL)
        ? (int32_t) g_llama.n_batch_ctx(eng->ctx) : 512;
    const int32_t nn = n > batch_limit ? batch_limit : n;

    struct llama_batch batch = g_llama.batch_init(nn, 0, 1);
    for (int32_t i = 0; i < nn; ++i) {
        batch.token[i]     = tokens[i];
        batch.pos[i]       = positions[i];
        batch.n_seq_id[i]  = 1;
        batch.seq_id[i][0] = seq_ids[i];
        batch.logits[i]    = logits_flags[i];
    }
    batch.n_tokens = nn;

    const int32_t rc = g_llama.decode(eng->ctx, batch);
    g_llama.batch_free(batch);

    if (g_llama.synchronize != NULL) {
        g_llama.synchronize(eng->ctx);
    }

    g_error[0] = '\0';
    return rc;
}

// Tokenize a prompt string into token ids. Writes up to n_out tokens into
// out_tokens; returns the number written, or the negative required count if
// the buffer is too small, or -1 on error. add_bos controls whether a
// beginning-of-sequence token is prepended.
int32_t cllama_engine_tokenize(const cllama_engine *eng,
                               const char *text,
                               int32_t add_bos,
                               int32_t *out_tokens,
                               int32_t n_out) {
    if (!cllama_is_available() || eng == NULL || eng->vocab == NULL || text == NULL || out_tokens == NULL) {
        set_error("cllama: tokenize invalid args");
        return -1;
    }
    int32_t n = g_llama.tokenize(eng->vocab, text, (int32_t)strlen(text),
                                 out_tokens, n_out, add_bos, false);
    if (n < 0) {
        // Negative return = required size (llama_tokenize convention).
        g_error[0] = '\0';
        return n;
    }
    g_error[0] = '\0';
    return n;
}

// Non-zero if token_id is an end-of-generation token for this engine's vocab.
int cllama_token_is_eog(const cllama_engine *eng, int32_t token_id) {
    if (!cllama_is_available() || eng == NULL || eng->vocab == NULL) return 0;
    return g_llama.vocab_is_eog(eng->vocab, token_id);
}

// The logical maximum batch size for this engine's context (n_batch). The
// scheduler uses this to cap how many tokens (across prefill + decode for
// all slots) fit in a single llama_decode call.
int32_t cllama_engine_n_batch(const cllama_engine *eng) {
    if (!cllama_is_available() || eng == NULL || eng->ctx == NULL) return 512;
    if (g_llama.n_batch_ctx == NULL) return 512;
    return (int32_t) g_llama.n_batch_ctx(eng->ctx);
}

// Copy the logits row for batch position `i` (0-indexed within the last
// batch_decode call) into out_buf. The row has n_vocab floats. This is the
// safe accessor: when a batch mixes prefill tokens (logits=false) with decode
// tokens (logits=true), the flat logits buffer is NOT indexed by batch
// position — llama_get_logits_ith resolves the correct row. Returns 0 on
// success, -1 if unavailable or out of range.
int32_t cllama_get_logits_ith(const cllama_engine *eng,
                              int32_t i,
                              float *out_buf,
                              int32_t n_vocab) {
    if (!cllama_is_available() || eng == NULL || eng->ctx == NULL || out_buf == NULL) {
        return -1;
    }
    if (g_llama.get_logits_ith == NULL) {
        // Fallback: assume flat indexing (only correct when every batch token
        // requested logits).
        if (g_llama.get_logits == NULL) return -1;
        const float *logits = g_llama.get_logits(eng->ctx);
        if (logits == NULL) return -1;
        memcpy(out_buf, logits + (size_t)i * n_vocab, (size_t)n_vocab * sizeof(float));
        return 0;
    }
    const float *row = g_llama.get_logits_ith(eng->ctx, i);
    if (row == NULL) return -1;
    memcpy(out_buf, row, (size_t)n_vocab * sizeof(float));
    return 0;
}

// Detokenize a single token into UTF-8 text. Writes up to out_len-1 bytes
// into out_buf (NUL-terminated). Returns bytes written excluding NUL, or
// negative required size if too small.
int32_t cllama_token_to_piece_str(const cllama_engine *eng,
                                  int32_t token_id,
                                  char *out_buf,
                                  int32_t out_len) {
    if (!cllama_is_available() || eng == NULL || out_buf == NULL || out_len <= 0) return -1;
    int32_t n = g_llama.token_to_piece(eng->vocab, token_id, out_buf, out_len, 0, true);
    return n;
}

int32_t cllama_detokenize(const cllama_engine *eng,
                          const int32_t *tokens,
                          int32_t n_tokens,
                          char *out_buf,
                          int32_t out_len) {
    if (!cllama_is_available()) {
        set_error("cllama: library not loaded; call cllama_load_library first");
        return -1;
    }
    if (eng == NULL || tokens == NULL || out_buf == NULL || n_tokens < 0 || out_len <= 0) {
        set_error("cllama: invalid detokenize arguments");
        return -1;
    }

    const int32_t n = g_llama.detokenize(
            eng->vocab, tokens, n_tokens, out_buf, out_len,
            /*remove_special=*/false, /*unparse_special=*/false);
    if (n < 0) {
        // negative = required buffer size; pass it through to the caller
        return n;
    }
    if (n < out_len) {
        out_buf[n] = '\0';
    }

    g_error[0] = '\0';
    return n;
}

#else // CLLAMA_NO_HEADERS - stub used when built without the llama.cpp headers

int cllama_load_library(const char *dylib_path_override) {
    (void)dylib_path_override;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return 0;
}

int cllama_is_available(void) {
    return 0;
}

cllama_engine *cllama_engine_load(const char *model_path,
                                  uint32_t n_ctx,
                                  int32_t n_threads,
                                  int32_t n_gpu_layers) {
    (void)model_path; (void)n_ctx; (void)n_threads; (void)n_gpu_layers;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return NULL;
}

int32_t cllama_engine_generate(cllama_engine *eng,
                               const char *prompt,
                               int32_t max_tokens,
                               cllama_token_callback on_token,
                               void *user_data) {
    (void)eng; (void)prompt; (void)max_tokens; (void)on_token; (void)user_data;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return -1;
}

void cllama_engine_free(cllama_engine *eng) {
    (void)eng;
}

int cllama_load_spec_library(const char *dylib_path_override) {
    (void)dylib_path_override;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return 0;
}

int cllama_is_spec_available(void) {
    return 0;
}

cllama_spec_engine *cllama_engine_load_spec(const char *trunk_path,
                                            const char *draft_path,
                                            uint32_t n_ctx,
                                            int32_t n_threads,
                                            int32_t n_gpu_layers,
                                            int32_t draft_max) {
    (void)trunk_path; (void)draft_path; (void)n_ctx; (void)n_threads;
    (void)n_gpu_layers; (void)draft_max;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return NULL;
}

int32_t cllama_engine_generate_spec(cllama_spec_engine *eng,
                                    const char *prompt,
                                    int32_t max_tokens,
                                    int32_t telemetry_topk,
                                    cllama_token_callback on_token,
                                    cllama_trace_callback on_trace,
                                    void *user_data) {
    (void)eng; (void)prompt; (void)max_tokens; (void)telemetry_topk;
    (void)on_token; (void)on_trace; (void)user_data;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return -1;
}

void cllama_engine_free_spec(cllama_spec_engine *eng) {
    (void)eng;
}

int32_t cllama_engine_n_vocab(const cllama_engine *eng) {
    (void)eng;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return -1;
}

int32_t cllama_detokenize(const cllama_engine *eng,
                          const int32_t *tokens,
                          int32_t n_tokens,
                          char *out_buf,
                          int32_t out_len) {
    (void)eng; (void)tokens; (void)n_tokens; (void)out_buf; (void)out_len;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return -1;
}

// Continuous-batching stubs (Part A) — no-ops when built without headers.
int cllama_is_batch_available(void) { return 0; }

int32_t cllama_engine_batch_decode(cllama_engine *eng,
                                   const int32_t *seq_ids,
                                   const int32_t *tokens,
                                   const int32_t *positions,
                                   int32_t n_slots,
                                   float *logits_out,
                                   int32_t logits_stride_bytes) {
    (void)eng; (void)seq_ids; (void)tokens; (void)positions;
    (void)n_slots; (void)logits_out; (void)logits_stride_bytes;
    set_error("cllama: built without llama.cpp headers (CLLAMA_NO_HEADERS)");
    return -2;
}

int32_t cllama_engine_batch_decode_ext(cllama_engine *eng,
                                       const int32_t *tokens,
                                       const int32_t *seq_ids,
                                       const int32_t *positions,
                                       const int8_t  *logits_flags,
                                       int32_t n) {
    (void)eng; (void)tokens; (void)seq_ids; (void)positions;
    (void)logits_flags; (void)n;
    return -2;
}

void cllama_slot_clear(cllama_engine *eng, int32_t seq_id) { (void)eng; (void)seq_id; }
void cllama_slot_copy(cllama_engine *eng, int32_t src, int32_t dst) { (void)eng; (void)src; (void)dst; }
int32_t cllama_slot_pos_max(cllama_engine *eng, int32_t seq_id) { (void)eng; (void)seq_id; return -1; }

int32_t cllama_engine_tokenize(const cllama_engine *eng, const char *text,
                               int32_t add_bos, int32_t *out_tokens, int32_t n_out) {
    (void)eng; (void)text; (void)add_bos; (void)out_tokens; (void)n_out;
    return -1;
}
int cllama_token_is_eog(const cllama_engine *eng, int32_t token_id) { (void)eng; (void)token_id; return 0; }
int32_t cllama_engine_n_batch(const cllama_engine *eng) { (void)eng; return 512; }
int32_t cllama_get_logits_ith(const cllama_engine *eng, int32_t i, float *out_buf, int32_t n_vocab) {
    (void)eng; (void)i; (void)out_buf; (void)n_vocab; return -1;
}
int32_t cllama_token_to_piece_str(const cllama_engine *eng, int32_t token_id, char *out_buf, int32_t out_len) {
    (void)eng; (void)token_id; (void)out_buf; (void)out_len; return -1;
}

#endif // CLLAMA_NO_HEADERS
