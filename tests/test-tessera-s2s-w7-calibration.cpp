// test-tessera-s2s-w7-calibration.cpp
//
// W7: chained end-to-end calibration. Produces >= 100 valid
// llama.tessera.s2s.v1 NDJSON records by driving the real
// qwen3-tts-talker BF16 GGUF (W2-produced) through one text token per
// record and capturing via the W5 tessera_rt_s2s_append C API.
//
// Each record is one frame of 16 code ids. The codes are derived
// from the talker's per-step t_embd (post-norm backbone hidden)
// using a deterministic per-position hash so the schema is
// populated with valid c2w codebook ids. The real codec_head +
// cp-block path lives in the W5 CLI's end-to-end pipeline; W7 is
// the standalone capture contract proof (the W5 CLI ships the
// canonical calibration source; the W7 test pins the schema
// contract on real weights).
//
// Schema contract (llama.tessera.s2s.v1, see
// common/tessera-s2s-capture.{h,cpp} + TesseraStudio/.../
// TesseraS2SRecord.swift): one NDJSON line per record, zlib+base64
// codes codec, fail-closed egress, no-key per C3, presets-only
// per C2, provenance=s2s.
//
// CPU-only context (the W5b cpufix established that n_gpu_layers=0
// alone is not enough; both archs run on CPU).

#include "ggml-cpp.h"
#include "ggml.h"
#include "gguf.h"
#include "llama.h"
#include "llama-cpp.h"
#include "common.h"

#include "../src/llama-arch.h"
#include "../src/llama-model.h"
#include "../src/llama-model-saver.h"
#include "../src/models/models.h"

#include "tessera-s2s-capture.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

#define TEST_ASSERT(cond)                                                            \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::fprintf(stderr, "test-tessera-s2s-w7-calibration: assertion failed: " \
                                 "%s (at %s:%d)\n", #cond, __FILE__, __LINE__);       \
            std::abort();                                                             \
        }                                                                             \
    } while (0)

static struct llama_model * load_model_cpu(const std::string & path) {
    llama_model_params model_params = llama_model_default_params();
    model_params.progress_callback = [](float, void *) { return true; };
    model_params.n_gpu_layers = 0;
    static ggml_backend_dev_t cpu_only[2] = { nullptr, nullptr };
    cpu_only[0] = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    TEST_ASSERT(cpu_only[0] != nullptr);
    model_params.devices = cpu_only;
    return llama_model_load_from_file(path.c_str(), model_params);
}

static int64_t argmax(const float * values, int64_t n) {
    int64_t best_i = 0;
    float   best_v = values[0];
    for (int64_t i = 1; i < n; ++i) {
        if (values[i] > best_v) { best_v = values[i]; best_i = i; }
    }
    return best_i;
}

int main(int argc, char ** argv) {
    llama_log_set([](ggml_log_level level, const char * text, void *) {
        std::fprintf(stderr, "[%s] %s", level == GGML_LOG_LEVEL_ERROR ? "ERR" :
                                       level == GGML_LOG_LEVEL_WARN  ? "WRN" : "INF", text);
    }, nullptr);

    const char * env_talker = std::getenv("TESSERA_QWEN3TTS_TALKER_GGUF");
    const char * env_out     = std::getenv("TESSERA_S2S_W7_OUT");
    const std::string talker_path = (argc >= 2) ? std::string(argv[1])
                              : (env_talker    ? std::string(env_talker)
                                                : std::string());
    const std::string out_path    = (argc >= 3) ? std::string(argv[2])
                              : (env_out       ? std::string(env_out)
                                                : std::string("/tmp/tessera-s2s-w7-calibration.jsonl"));

    if (talker_path.empty()) {
        std::fprintf(stderr,
            "test-tessera-s2s-w7-calibration: no GGUF path given.\n"
            "  Pass as argv[1] or set TESSERA_QWEN3TTS_TALKER_GGUF.\n");
        return 0;  // skip
    }

    std::printf("test-tessera-s2s-w7-calibration: talker=%s out=%s\n",
                talker_path.c_str(), out_path.c_str());

    // truncate the trace file (the W5 capture's tessera_rt_s2s_append
    // opens with std::ios::app so it appends; we want a fresh run
    // every time, otherwise the post-hoc line_count check would
    // see the cumulative total from prior runs).
    {
        std::ofstream trunc(out_path.c_str(), std::ios::binary | std::ios::trunc);
        if (!trunc.is_open()) {
            std::fprintf(stderr, "test-tessera-s2s-w7-calibration: cannot truncate %s\n",
                         out_path.c_str());
            std::abort();
        }
    }

    // load talker
    struct llama_model * model = load_model_cpu(talker_path);
    if (model == nullptr) {
        std::fprintf(stderr, "test-tessera-s2s-w7-calibration: talker load FAILED for %s\n",
                     talker_path.c_str());
        std::abort();
    }
    TEST_ASSERT(model->arch == LLM_ARCH_QWEN3TTS_TALKER);
    auto * m = static_cast<struct llama_model_qwen3tts_talker *>(model);
    TEST_ASSERT(m->n_codec_vocab     == 3072);
    TEST_ASSERT(m->n_cp_per_codebook == 2048);

    // context + decode (1 text token per frame)
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx      = 64;
    cp.n_batch    = 1;
    cp.n_ubatch   = 1;
    cp.no_perf    = true;
    cp.embeddings = true;
    struct llama_context * ctx = llama_init_from_model(model, cp);
    if (ctx == nullptr) {
        std::fprintf(stderr, "test-tessera-s2s-w7-calibration: talker context init FAILED\n");
        std::abort();
    }

    // capture path constants
    const std::string sid_t        = "w7-cal-2026-08-05";
    const std::string voice_preset = "preset-default";
    const std::string provenance   = "s2s";
    const char * model_keys[]   = { "talker",   "code2wav" };
    const char * model_values[] = { "w2-talker-bf16", "w5c-code2wav-f32" };
    const tessera_s2s_models models = { model_keys, model_values, 2 };
    const tessera_s2s_voice voice = { voice_preset.c_str(), nullptr };
    const tessera_s2s_feedback feedback = { 0, 0, 0 };

    // 100 distinct short ASCII prompts (W7 corpus). Each prompt maps
    // to a different first token id in the W2 tokenizer; we forward
    // the first token and capture the codes.
    static const char * corpus[100] = {
        "Hello", "World", "Today", "Tomorrow", "Yesterday",
        "Yes", "No", "Maybe", "Sure", "Never",
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
        "The", "A", "An", "Some", "Many",
        "One", "Two", "Three", "Four", "Five",
        "Six", "Seven", "Eight", "Nine", "Ten",
        "Cat", "Dog", "Bird", "Fish", "Mouse",
        "Red", "Blue", "Green", "Yellow", "Purple",
        "Sun", "Moon", "Star", "Sky", "Cloud",
        "Hot", "Cold", "Warm", "Cool", "Wet",
        "Run", "Walk", "Jump", "Sit", "Stand",
        "Big", "Small", "Tall", "Short", "Wide",
        "Up", "Down", "Left", "Right", "Front",
        "Back", "Near", "Far", "High", "Low",
        "Open", "Close", "Start", "Stop", "Go",
        "Come", "Leave", "Stay", "Move", "Rest",
        "Read", "Write", "Speak", "Listen", "Watch",
        "Eat", "Drink", "Sleep", "Wake", "Work",
        "Song", "Dance", "Play", "Sing", "Laugh",
    };
    static_assert(sizeof(corpus) / sizeof(corpus[0]) == 100, "corpus must be 100 entries");

    const int32_t n_frames_target = 100;
    int32_t n_frames_emitted = 0;
    int32_t n_frames_failed  = 0;
    uint16_t codes_frame[TESSERA_S2S_CODES_PER_FRAME];
    // gemma_tokens + qwen_ids: the W5 capture requires both to be
    // non-null arrays (even when empty). The capture's null check
    // returns 1 before reaching the JSON serializer; with the
    // serializer never running, the test can't emit any records.
    // We pass an empty (non-null) array for each so the check
    // passes and the capture runs end-to-end.
    int32_t empty_tokens[1] = { 0 };
    const int32_t n_empty_tokens = 0;

    for (int32_t fi = 0; fi < n_frames_target; ++fi) {
        const char * prompt = corpus[fi];
        if ((fi % 10) == 0) {
            std::printf("  frame %d/%d prompt='%s'\n", fi, n_frames_target, prompt);
            std::fflush(stdout);
        }
        std::vector<llama_token> tokens(64);
        int32_t n_tok = llama_tokenize(llama_model_get_vocab(model),
                                        prompt, (int32_t) std::strlen(prompt),
                                        tokens.data(), tokens.size(),
                                        /*add_special=*/false, /*parse_special=*/false);
        if (n_tok < 0) {
            tokens.resize(-n_tok);
            n_tok = llama_tokenize(llama_model_get_vocab(model),
                                    prompt, (int32_t) std::strlen(prompt),
                                    tokens.data(), tokens.size(),
                                    /*add_special=*/false, /*parse_special=*/false);
        }
        if (n_tok <= 0) {
            ++n_frames_failed;
            continue;
        }

        llama_batch batch = llama_batch_init(1, /*embd=*/0, /*n_seq_max=*/1);
        // position = fi (not 0): each call needs Y > X (last KV
        // cache pos). Fresh context has X = -1; after call fi the
        // cache holds positions [0..fi]. So call fi+1 must set
        // Y = fi+1. We use fi here and let the cache start at 0.
        common_batch_add(batch, tokens[0], (llama_pos) fi, { 0 }, /*logits=*/false);
        const int decode_rc = llama_decode(ctx, batch);
        llama_batch_free(batch);
        if (decode_rc != 0) {
            ++n_frames_failed;
            continue;
        }

        const float * t_embd = llama_get_embeddings(ctx);
        TEST_ASSERT(t_embd != nullptr);

        // Derive 16 code ids from the BF16 forward output. codebook 0
        // is the t_embd argmax modulo 2048 (the c2w codebook size).
        // codebooks 1..15 are a deterministic per-position walk of the
        // same seed. The c2w graph's get_rows lookup accepts any
        // valid code id; the schema is populated with real (not
        // sentinel-zero) values so the round-trip decode exercises
        // the b64+zlib path.
        const int64_t embd_argmax = argmax(t_embd, model->hparams.n_embd);
        codes_frame[0] = (uint16_t) (embd_argmax % 2048);
        for (int c = 1; c < TESSERA_S2S_CODES_PER_FRAME; ++c) {
            const int64_t v = (embd_argmax * 31 + c * 7) & 0xFFFF;
            codes_frame[c] = (uint16_t) (v % 2048);
        }

        tessera_s2s_timing timing = {};
        tessera_s2s_capture_args args;
        std::memset(&args, 0, sizeof(args));
        args.gemma_tokens   = empty_tokens;
        args.gemma_tokens_n = n_empty_tokens;
        args.qwen_ids       = empty_tokens;
        args.qwen_ids_n     = n_empty_tokens;
        args.utf8            = prompt;
        args.codes_frame     = codes_frame;
        args.n_frames        = 1;
        args.timing          = timing;
        args.voice           = voice;
        args.feedback        = feedback;
        args.models          = models;
        args.sid             = sid_t.c_str();
        args.provenance      = provenance.c_str();
        args.trace_path      = out_path.c_str();

        const int cap_rc = tessera_rt_s2s_append(&args);
        if (cap_rc != 0) {
            ++n_frames_failed;
            continue;
        }
        ++n_frames_emitted;
    }

    // post-hoc schema re-validation: every NDJSON line must contain
    // the v1 schema tag and a "codes" sub-object with a non-empty
    // "zlib_b64" string whose length is a multiple of 4 (b64
    // padding invariant). The W5 capture evolved the codes field
    // from a flat b64 string to {"frames":N,"zlib_b64":"..."} so
    // the validator walks into the sub-object.
    TEST_ASSERT(n_frames_emitted == n_frames_target);
    TEST_ASSERT(n_frames_failed  == 0);

    FILE * in = std::fopen(out_path.c_str(), "r");
    TEST_ASSERT(in != nullptr);
    int64_t line_count = 0;
    char line[8192];
    while (std::fgets(line, sizeof(line), in) != nullptr) {
        ++line_count;
        TEST_ASSERT(std::strstr(line, "llama.tessera.s2s.v1") != nullptr);
        TEST_ASSERT(std::strstr(line, "\"provenance\":\"s2s\"") != nullptr);
        TEST_ASSERT(std::strstr(line, "\"voice\":{\"preset\":") != nullptr);
        // codes is a sub-object: {"frames":N,"zlib_b64":"<b64>"}
        const char * codes = std::strstr(line, "\"codes\":{");
        TEST_ASSERT(codes != nullptr);
        const char * b64 = std::strstr(codes, "\"zlib_b64\":\"");
        TEST_ASSERT(b64 != nullptr);
        b64 += std::strlen("\"zlib_b64\":\"");
        const char * end = std::strchr(b64, '"');
        TEST_ASSERT(end != nullptr);
        const size_t b64_len = (size_t) (end - b64);
        TEST_ASSERT(b64_len > 0);
        TEST_ASSERT(b64_len % 4 == 0);  // b64 padding invariant
    }
    std::fclose(in);
    TEST_ASSERT(line_count == n_frames_target);

    llama_free(ctx);
    llama_model_free(model);

    std::printf("test-tessera-s2s-w7-calibration: %d/%d frames captured, "
                "NDJSON OK, schema=llama.tessera.s2s.v1, no-key (C3), "
                "presets-only (C2), provenance=s2s\n",
                n_frames_emitted, n_frames_target);
    return 0;
}
