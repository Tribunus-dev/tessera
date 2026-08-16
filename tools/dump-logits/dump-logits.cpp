// dump-logits: loads a GGUF model, runs one fixed prompt through it, and
// writes the final token's logit vector to a raw binary file.
//
// W3 task 3.9 (master-plan criterion 21: "cosine >= 0.999 AND
// Frobenius_rel <= 0.01 vs the bf16 reference"). This tool produces the
// raw material for that comparison; scripts/compare-cosine.py does the
// actual numerical comparison between two dumps. Kept deliberately
// minimal (single prompt, single forward pass, last-token logits only)
// rather than a general-purpose eval harness - that is what
// tools/perplexity already covers for a different question (perplexity
// over a corpus, not weight-only parity between two builds of the same
// model).
//
// Output format: 4-byte magic "TSLG", u32 n_vocab, then n_vocab float32
// logits, all little-endian (matches this host's and every supported
// target's native byte order - no serialization concerns here).
//
// Usage: dump-logits -m MODEL.gguf -p "prompt text" -o out.bin [-ngl N]

#include "llama.h"
#include "common.h"
#include "ggml.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static void print_usage(const char * argv0) {
    fprintf(stderr,
        "usage: %s -m MODEL.gguf -p \"prompt text\" -o out.bin [-ngl N] [-cache-q8_0]\n"
        "  -m PATH      model GGUF path (required)\n"
        "  -p TEXT      prompt to run (required)\n"
        "  -o PATH      output .bin path for the logit dump (required)\n"
        "  -ngl N       number of layers to offload to GPU (default: 0)\n"
        "  -cache-q8_0  quantize the KV cache to q8_0 (both K and V) instead of\n"
        "               the default f16 - W3 task 3.9's q8_0-cache validation leg\n",
        argv0);
}

int main(int argc, char ** argv) {
    std::string model_path;
    std::string prompt;
    std::string out_path;
    int32_t n_gpu_layers = 0;
    bool cache_q8_0 = false;

    for (int i = 1; i < argc; i++) {
        const std::string arg = argv[i];
        if (arg == "-m" && i + 1 < argc) {
            model_path = argv[++i];
        } else if (arg == "-p" && i + 1 < argc) {
            prompt = argv[++i];
        } else if (arg == "-o" && i + 1 < argc) {
            out_path = argv[++i];
        } else if (arg == "-ngl" && i + 1 < argc) {
            n_gpu_layers = atoi(argv[++i]);
        } else if (arg == "-cache-q8_0") {
            cache_q8_0 = true;
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }
    if (model_path.empty() || prompt.empty() || out_path.empty()) {
        print_usage(argv[0]);
        return 1;
    }

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    llama_model * model = llama_model_load_from_file(model_path.c_str(), mparams);
    if (model == nullptr) {
        fprintf(stderr, "dump-logits: failed to load model %s\n", model_path.c_str());
        return 1;
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    const int32_t n_vocab = llama_vocab_n_tokens(vocab);

    std::vector<llama_token> tokens(prompt.size() + 16);
    const int32_t n_tokens = llama_tokenize(vocab, prompt.c_str(), (int32_t) prompt.size(),
                                             tokens.data(), (int32_t) tokens.size(),
                                             /* add_special */ true, /* parse_special */ true);
    if (n_tokens < 0) {
        fprintf(stderr, "dump-logits: tokenization failed (buffer too small)\n");
        llama_model_free(model);
        return 1;
    }
    tokens.resize(n_tokens);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx   = (uint32_t) std::max<int32_t>(n_tokens + 8, 512);
    cparams.n_batch = (uint32_t) std::max<int32_t>(n_tokens, 512);
    if (cache_q8_0) {
        cparams.type_k = GGML_TYPE_Q8_0;
        cparams.type_v = GGML_TYPE_Q8_0;
    }
    llama_context * ctx = llama_init_from_model(model, cparams);
    if (ctx == nullptr) {
        fprintf(stderr, "dump-logits: failed to create context\n");
        llama_model_free(model);
        return 1;
    }

    llama_batch batch = llama_batch_get_one(tokens.data(), n_tokens);
    if (llama_decode(ctx, batch) != 0) {
        fprintf(stderr, "dump-logits: decode failed\n");
        llama_free(ctx);
        llama_model_free(model);
        return 1;
    }

    const float * logits = llama_get_logits_ith(ctx, n_tokens - 1);
    if (logits == nullptr) {
        fprintf(stderr, "dump-logits: llama_get_logits_ith returned null\n");
        llama_free(ctx);
        llama_model_free(model);
        return 1;
    }

    FILE * f = fopen(out_path.c_str(), "wb");
    if (f == nullptr) {
        fprintf(stderr, "dump-logits: cannot open %s for writing\n", out_path.c_str());
        llama_free(ctx);
        llama_model_free(model);
        return 1;
    }
    fwrite("TSLG", 1, 4, f);
    const uint32_t n_vocab_u32 = (uint32_t) n_vocab;
    fwrite(&n_vocab_u32, sizeof(uint32_t), 1, f);
    fwrite(logits, sizeof(float), (size_t) n_vocab, f);
    fclose(f);

    fprintf(stderr, "dump-logits: wrote %d logits to %s (n_tokens=%d, n_gpu_layers=%d)\n",
            n_vocab, out_path.c_str(), n_tokens, n_gpu_layers);

    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
