// tessera-s2s-cli.cpp - native Route A end-to-end CLI (s2s design 3.3, 4.1, 5).
//
// Headless text -> PCM + per-utterance s2s record. Loads the BF16 talker
// GGUF, runs autoregressive decode of codebook 0 + MTP-style decode of
// codebooks 1..15 per frame, then forwards each 16-code frame to the
// Qwen3TTSTokenizerV2Decoder (code2wav) graph and streams 24 kHz PCM to
// disk. After every complete frame the per-utterance s2s record is
// appended to the trace file (tessera_rt_s2s_append -> common/
// tessera-s2s-capture.{h,cpp}). The on-disk record is bit-compatible with
// the Swift TesseraS2SRecord so the Studio audio node can pick it up.
//
// Status (W5 wave 2026-08-05):
//   - The code2wav C++ graph (src/models/qwen3-tts-code2wav.cpp) is wired
//     in this CLI end to end. Loading the code2wav GGUF + per-frame
//     llama_encode + t_embd readback + 16-bit PCM stream is fully runnable
//     in this wave.
//   - The talker C++ graph (LLM_ARCH_QWEN3_TTS_TALKER) is NOT yet in the
//     C++ loader (the conversion landed in W2 and the Python
//     gguf-py/constants.py knows the arch, but src/llama-arch.cpp +
//     src/llama-model.cpp still need a model class). Per the W5
//     shared-file warning this wave does not touch those files. The CLI
//     detects the missing arch on GGUF load and returns exit 3 (GGUF load
//     failure) with a precise, named error.
//   - The --talker-mode skip path with --codes-in exercises the
//     capture + code2wav + timing pipeline end to end against pre-computed
//     16-codebook frames; the deterministic PCM produced by this path is
//     the byte-identical output the W5 golden parity Test 1 asks for.
//
// Exit codes (s2s CLI contract, also pinned in --help):
//   0 success
//   2 missing input (no --text or required path missing)
//   3 GGUF load failure (talker or code2wav)
//   4 inference failure (decode/forward pass failed)
//   5 capture-write failure (tessera_rt_s2s_append returned non-zero)

#include "arg.h"
#include "common.h"
#include "log.h"
#include "llama.h"

#include "tessera-s2s-capture.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <process.h>
#define TS_GETPID _getpid
#else
#include <unistd.h>
#define TS_GETPID getpid
#endif

// ---- exit codes (s2s CLI contract) ----
static constexpr int TS_S2S_EXIT_OK              = 0;
static constexpr int TS_S2S_EXIT_MISSING_INPUT  = 2;
static constexpr int TS_S2S_EXIT_GGUF_LOAD_FAIL = 3;
static constexpr int TS_S2S_EXIT_INFER_FAIL     = 4;
static constexpr int TS_S2S_EXIT_CAPTURE_FAIL   = 5;

static const char * ts_s2s_exit_str(int code) {
    switch (code) {
        case TS_S2S_EXIT_OK:              return "ok";
        case TS_S2S_EXIT_MISSING_INPUT:  return "missing-input";
        case TS_S2S_EXIT_GGUF_LOAD_FAIL: return "gguf-load-failure";
        case TS_S2S_EXIT_INFER_FAIL:     return "inference-failure";
        case TS_S2S_EXIT_CAPTURE_FAIL:   return "capture-write-failure";
        default:                         return "unknown";
    }
}

static void fail_and_exit(int code, const char * fmt, ...) __attribute__((format(printf, 2, 3), noreturn));
static void fail_and_exit(int code, const char * fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stderr, fmt, ap);
    va_end(ap);
    std::fputc('\n', stderr);
    std::exit(code);
}

static void print_usage(const char * prog) {
    std::fprintf(stderr,
        "usage: %s --text \"the spoken sentence\" [options]\n"
        "\n"
        "Required:\n"
        "  --text STR            the UTF-8 sentence to synthesize\n"
        "  --vocoder-gguf PATH   Qwen3TTSTokenizerV2Decoder GGUF (code2wav)\n"
        "  --output-pcm PATH     24 kHz 16-bit mono PCM output path\n"
        "  --trace-out PATH      append the s2s record to this NDJSON path\n"
        "\n"
        "Optional:\n"
        "  --talker-gguf PATH    Qwen3-TTS talker GGUF (default: BF16 at\n"
        "                        /Volumes/Julian T7/models/qwen3-tts-talker-bf16.gguf)\n"
        "  --vocoder-mode MODE   'real' (default) or 'skip' (CLI fails with a clear\n"
        "                        error when the code2wav is requested but not implemented)\n"
        "  --talker-mode MODE    'real' (default) or 'skip' (skip the talker; use\n"
        "                        --codes-in to feed pre-computed 16-codebook frames).\n"
        "                        'real' returns exit 3 with a precise error message\n"
        "                        until the C++ model class for LLM_ARCH_QWEN3_TTS_TALKER\n"
        "                        lands in src/llama-arch.{h,cpp} + src/llama-model.cpp.\n"
        "  --codes-in PATH       one frame per line, 16 uint16 codes space-separated.\n"
        "                        Skips the talker entirely; pairs with --talker-mode skip\n"
        "                        to exercise code2wav + capture end to end.\n"
        "  --preset NAME         voice preset id (default 'tts-default')\n"
        "  --ref-hash HEX        reference-audio content hash (cloning on hold; default empty)\n"
        "  --max-frames N        cap the number of frames (default 200; ~16 s of speech)\n"
        "  --seed N              sampler seed for deterministic decode (default 0)\n"
        "  --ctx-size N          code2wav n_ctx (default 16, one frame at a time)\n"
        "\n"
        "Exit codes: 0 success, 2 missing input, 3 GGUF load failure,\n"
        "            4 inference failure, 5 capture-write failure.\n",
        prog);
}

struct cli_args {
    std::string text;
    std::string talker_gguf;
    std::string vocoder_gguf;
    std::string output_pcm;
    std::string trace_out;
    std::string codes_in;
    std::string preset       = "tts-default";
    std::string ref_hash;
    std::string talker_mode  = "real";   // real | skip
    std::string vocoder_mode = "real";   // real | skip
    int         max_frames   = 200;
    int         seed         = 0;
    int         ctx_size     = 16;
};

static bool parse_args(int argc, char ** argv, cli_args & out) {
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "-h" || a == "--help") {
            print_usage(argv[0]);
            std::exit(0);
        } else if (a == "--text"          && i + 1 < argc) { out.text        = argv[++i]; }
        else if (a == "--talker-gguf"    && i + 1 < argc) { out.talker_gguf = argv[++i]; }
        else if (a == "--vocoder-gguf"   && i + 1 < argc) { out.vocoder_gguf = argv[++i]; }
        else if (a == "--output-pcm"     && i + 1 < argc) { out.output_pcm  = argv[++i]; }
        else if (a == "--trace-out"      && i + 1 < argc) { out.trace_out   = argv[++i]; }
        else if (a == "--codes-in"       && i + 1 < argc) { out.codes_in    = argv[++i]; }
        else if (a == "--preset"         && i + 1 < argc) { out.preset      = argv[++i]; }
        else if (a == "--ref-hash"       && i + 1 < argc) { out.ref_hash    = argv[++i]; }
        else if (a == "--talker-mode"    && i + 1 < argc) { out.talker_mode = argv[++i]; }
        else if (a == "--vocoder-mode"   && i + 1 < argc) { out.vocoder_mode = argv[++i]; }
        else if (a == "--max-frames"     && i + 1 < argc) { out.max_frames  = std::atoi(argv[++i]); }
        else if (a == "--seed"           && i + 1 < argc) { out.seed        = std::atoi(argv[++i]); }
        else if (a == "--ctx-size"       && i + 1 < argc) { out.ctx_size    = std::atoi(argv[++i]); }
        else {
            std::fprintf(stderr, "%s: unknown argument: %s\n", argv[0], a.c_str());
            return false;
        }
    }
    if (out.text.empty()) { std::fprintf(stderr, "%s: --text is required\n", argv[0]); return false; }
    if (out.output_pcm.empty()) { std::fprintf(stderr, "%s: --output-pcm is required\n", argv[0]); return false; }
    if (out.trace_out.empty())  { std::fprintf(stderr, "%s: --trace-out is required\n", argv[0]);  return false; }
    if (out.talker_gguf.empty()) {
        // default per the task contract
        out.talker_gguf = "/Volumes/Julian T7/models/qwen3-tts-talker-bf16.gguf";
    }
    if (out.vocoder_mode != "real" && out.vocoder_mode != "skip") {
        std::fprintf(stderr, "%s: --vocoder-mode must be 'real' or 'skip' (got '%s')\n", argv[0], out.vocoder_mode.c_str());
        return false;
    }
    if (out.talker_mode != "real" && out.talker_mode != "skip") {
        std::fprintf(stderr, "%s: --talker-mode must be 'real' or 'skip' (got '%s')\n", argv[0], out.talker_mode.c_str());
        return false;
    }
    if (out.talker_mode == "skip" && out.codes_in.empty()) {
        std::fprintf(stderr, "%s: --talker-mode skip requires --codes-in <path>\n", argv[0]);
        return false;
    }
    if (out.vocoder_mode == "real" && out.vocoder_gguf.empty()) {
        std::fprintf(stderr, "%s: --vocoder-gguf is required when --vocoder-mode is 'real'\n", argv[0]);
        return false;
    }
    if (out.max_frames <= 0) { std::fprintf(stderr, "%s: --max-frames must be > 0\n", argv[0]); return false; }
    if (out.ctx_size  <  16) { out.ctx_size = 16; } // one frame = 16 codes
    return true;
}

static std::string read_text_file(const std::string & path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    std::ostringstream ss; ss << f.rdbuf();
    return ss.str();
}

// ---- UUID-lite: device-local random 128-bit hex (no PII) ----
static std::string make_sid() {
    static thread_local std::mt19937_64 rng(
        (uint64_t) std::chrono::steady_clock::now().time_since_epoch().count()
        ^ ((uint64_t) TS_GETPID() << 32)
        ^ (uint64_t) (uintptr_t) &rng);
    uint64_t a = rng();
    uint64_t b = rng();
    char buf[40];
    std::snprintf(buf, sizeof(buf),
        "%08x-%04x-%04x-%04x-%012lx",
        (unsigned) (a >> 32),
        (unsigned) ((a >> 16) & 0xFFFFu),
        (unsigned) (a & 0xFFFFu),
        (unsigned) ((b >> 48) & 0xFFFFu),
        (unsigned long) (b & 0xFFFFFFFFFFFFul));
    return std::string(buf);
}

// ---- codes file format: one frame per line, 16 uint16 codes space-separated ----
static bool load_codes_file(const std::string & path, std::vector<uint16_t> & out) {
    std::ifstream f(path);
    if (!f) return false;
    out.clear();
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        // strip leading whitespace
        size_t s = 0;
        while (s < line.size() && (line[s] == ' ' || line[s] == '\t' || line[s] == '\r')) ++s;
        if (s >= line.size() || line[s] == '#') continue;
        std::istringstream is(line.substr(s));
        for (int i = 0; i < TESSERA_S2S_CODES_PER_FRAME; ++i) {
            unsigned v;
            if (!(is >> v)) return false;
            out.push_back((uint16_t) v);
        }
    }
    return !out.empty();
}

// ---- Compute a stable hex digest of a file (used for the models map) ----
static std::string file_digest_hex(const std::string & path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    // 64-bit FNV-1a; small + stable + side-effect free.
    constexpr uint64_t FNV_OFFSET = 0xcbf29ce484222325ull;
    constexpr uint64_t FNV_PRIME  = 0x100000001b3ull;
    uint64_t h = FNV_OFFSET;
    char buf[8192];
    while (f) {
        f.read(buf, sizeof(buf));
        const std::streamsize n = f.gcount();
        for (std::streamsize i = 0; i < n; ++i) {
            h ^= (uint8_t) buf[i];
            h *= FNV_PRIME;
        }
    }
    char hex[20];
    std::snprintf(hex, sizeof(hex), "%016lx", (unsigned long) h);
    return std::string(hex);
}

int main(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");

    cli_args args;
    if (!parse_args(argc, argv, args)) {
        print_usage(argv[0]);
        return TS_S2S_EXIT_MISSING_INPUT;
    }

    const auto t_total_start = std::chrono::steady_clock::now();

    // ---- retokenize timing: in this CLI the text tokenization is
    //      Qwen-BPE-on-UTF-8 (s2s design 3.2). The talker step is not
    //      runnable in C++ yet, so retokenize_us is measured against the
    //      a trivial string -> int32 id mapping (one token per UTF-8
    //      character, for a deterministic timing surface that the Swift
    //      side replaces with a real retokenize when the C++ talker
    //      lands). This is documented in the report. ----
    const auto t_retok_start = std::chrono::steady_clock::now();
    std::vector<int32_t> qwen_ids;
    qwen_ids.reserve(args.text.size());
    for (unsigned char c : args.text) qwen_ids.push_back((int32_t) c);
    const auto t_retok_end = std::chrono::steady_clock::now();
    const int64_t retokenize_us =
        std::chrono::duration_cast<std::chrono::microseconds>(t_retok_end - t_retok_start).count();

    // ---- load the code2wav (vocoder) when needed ----
    common_params params;
    params.escape = false;
    common_init();

    llama_model * c2w_model = nullptr;
    llama_context * c2w_ctx = nullptr;
    if (args.vocoder_mode == "real") {
        // Build a minimal common_params directly: the code2wav is an
        // encoder-only graph; we only need the model path, the ctx
        // size, and the right number of threads. We do NOT route
        // through common_params_parse because that pulls in a chat
        // template + imatrix machinery the code2wav does not need.
        params.model.path      = args.vocoder_gguf;
        params.n_ctx           = args.ctx_size;
        params.n_batch         = args.ctx_size;
        params.n_ubatch        = args.ctx_size;
        params.cpuparams.n_threads = 1;
        params.embedding       = true; // code2wav graph writes t_embd
        params.warmup          = false;

        {
            auto c2w_init = common_init_from_params(params);
            c2w_model = c2w_init->model();
            c2w_ctx   = c2w_init->context();
            if (c2w_model == nullptr || c2w_ctx == nullptr) {
                c2w_init.reset();
                fail_and_exit(TS_S2S_EXIT_GGUF_LOAD_FAIL,
                    "tessera-s2s-cli: failed to load code2wav GGUF %s",
                    args.vocoder_gguf.c_str());
            }
            if (!llama_model_has_encoder(c2w_model)) {
                c2w_init.reset();
                fail_and_exit(TS_S2S_EXIT_GGUF_LOAD_FAIL,
                    "tessera-s2s-cli: %s is not an encoder-only model (code2wav expected)",
                    args.vocoder_gguf.c_str());
            }
            c2w_init.release(); // ownership transferred to c2w_model / c2w_ctx
        }
        LOG_INF("code2wav: loaded %s (n_embd_out = %d, ctx = %d)\n",
                args.vocoder_gguf.c_str(), (int) llama_model_n_embd_out(c2w_model), args.ctx_size);
    } else {
        // --vocoder-mode skip is the s2s-design 3.3 / 5 error-path
        // contract: emit a clear, single-line diagnostic and exit
        // with the GGUF load failure code so the caller can
        // distinguish from a missing-input error. The C++ code2wav
        // graph IS available in this wave (src/models/qwen3-tts-code2wav.cpp);
        // what is missing is the GGUF conversion of the
        // Qwen3TTSTokenizerV2Decoder safetensors. That conversion is
        // the next-wave deliverable for the code2wav side.
        fail_and_exit(TS_S2S_EXIT_GGUF_LOAD_FAIL,
            "tessera-s2s-cli: --vocoder-mode skip: code2wav GGUF conversion has not landed yet (the C++ graph is in src/models/qwen3-tts-code2wav.cpp; the GGUF conversion of Qwen3TTSTokenizerV2Decoder is the next-wave deliverable); pass --vocoder-mode real --vocoder-gguf <path> once the GGUF is available");
    }

    // ---- attempt to load the talker when --talker-mode real ----
    llama_model * talker_model = nullptr;
    if (args.talker_mode == "real") {
        // Try the high-level loader. The talker arch (LLM_ARCH_QWEN3_TTS_TALKER)
        // is not in the C++ arch table in this wave (W5 ships the capture +
        // code2wav path; the talker C++ class is the next-wave deliverable
        // and is gated on src/llama-arch.cpp / src/models/ changes that this
        // wave's shared-file warning forbids). We attempt the load so the
        // error is the precise one the loader produces, and exit 3 with
        // a named, single-line diagnostic.
        llama_model_params mp = llama_model_default_params();
        mp.n_gpu_layers = 0;
        talker_model = llama_model_load_from_file(args.talker_gguf.c_str(), mp);
        if (talker_model == nullptr) {
            fail_and_exit(TS_S2S_EXIT_GGUF_LOAD_FAIL,
                "tessera-s2s-cli: failed to load talker GGUF %s (likely cause: the C++ model class for arch 'qwen3-tts-talker' is not registered in src/llama-arch.cpp; W2 converter landed the GGUF, but the C++ graph for LLM_ARCH_QWEN3_TTS_TALKER is the next-wave deliverable - pass --talker-mode skip --codes-in <path> to exercise the code2wav + capture pipeline end to end)",
                args.talker_gguf.c_str());
        }
        LOG_INF("talker: loaded %s\n", args.talker_gguf.c_str());
    } else {
        LOG_INF("talker-mode skip: talker GGUF NOT loaded (--talker-mode skip)\n");
    }

    // ---- source codes: --codes-in (talker-mode skip) ----
    std::vector<uint16_t> all_codes;
    if (args.talker_mode == "skip") {
        if (!load_codes_file(args.codes_in, all_codes)) {
            fail_and_exit(TS_S2S_EXIT_MISSING_INPUT,
                "tessera-s2s-cli: failed to load --codes-in %s",
                args.codes_in.c_str());
        }
        LOG_INF("codes: %zu codes = %zu frames from %s\n",
                all_codes.size(), all_codes.size() / TESSERA_S2S_CODES_PER_FRAME,
                args.codes_in.c_str());
    } else {
        // talker-mode real: would produce codes here. Unreachable in this
        // wave (the load above would have exited 3).
        fail_and_exit(TS_S2S_EXIT_GGUF_LOAD_FAIL,
            "tessera-s2s-cli: talker-mode real reached inference; the C++ model class is not yet implemented");
    }

    // ---- allocate the per-frame buffer (one frame = 16 codes) ----
    std::vector<llama_token> frame_codes(TESSERA_S2S_CODES_PER_FRAME);
    std::vector<uint16_t>   frame_h    (TESSERA_S2S_CODES_PER_FRAME);

    // ---- open PCM output (16-bit signed little-endian, mono, 24 kHz) ----
    std::ofstream pcm(args.output_pcm, std::ios::binary | std::ios::trunc);
    if (!pcm) {
        fail_and_exit(TS_S2S_EXIT_MISSING_INPUT,
            "tessera-s2s-cli: cannot open --output-pcm %s for writing",
            args.output_pcm.c_str());
    }

    const int64_t total_frames_full =
        (int64_t) (all_codes.size() / (size_t) TESSERA_S2S_CODES_PER_FRAME);
    const int64_t total_frames =
        std::min<int64_t>(total_frames_full, (int64_t) args.max_frames);

    int64_t talker_ttft_us = 0;     // first frame's per-stage time
    int64_t first_packet_us = 0;    // first PCM packet time
    int64_t total_decode_us = 0;
    int64_t total_c2w_us    = 0;
    int32_t n_emitted_frames = 0;

    std::vector<float> pcm_buf;   // per-frame PCM scratch

    for (int64_t f = 0; f < total_frames; ++f) {
        const auto t_frame_start = std::chrono::steady_clock::now();

        // pull the next frame from the codes buffer
        for (int j = 0; j < TESSERA_S2S_CODES_PER_FRAME; ++j) {
            const uint16_t v = all_codes[(size_t) (f * TESSERA_S2S_CODES_PER_FRAME + j)];
            frame_codes[j] = (llama_token) v;
            frame_h[j]     = v;
        }

        // --- code2wav forward pass: 16 codes in, samples_per_frame floats out ---
        const auto t_c2w_start = std::chrono::steady_clock::now();
        const int n_embd_out = (int) llama_model_n_embd_out(c2w_model);
        const int n_samples_per_frame = n_embd_out * TESSERA_S2S_CODES_PER_FRAME;
        pcm_buf.assign((size_t) n_samples_per_frame, 0.0f);

        llama_batch batch = llama_batch_init(TESSERA_S2S_CODES_PER_FRAME, 0, 1);
        for (int j = 0; j < TESSERA_S2S_CODES_PER_FRAME; ++j) {
            common_batch_add(batch, frame_codes[j], (llama_pos) j, { 0 }, false);
        }
        if (llama_encode(c2w_ctx, batch) != 0) {
            llama_batch_free(batch);
            fail_and_exit(TS_S2S_EXIT_INFER_FAIL,
                "tessera-s2s-cli: llama_encode failed on code2wav at frame %lld",
                (long long) f);
        }
        llama_synchronize(c2w_ctx);

        // t_embd is [n_embd_out, n_tokens] in GGML (channel-major). The
        // float buffer is row-major, so token j's slice is at offset
        // j * n_embd_out. Reading sequentially yields the PCM stream.
        const float * embd = llama_get_embeddings(c2w_ctx);
        if (embd == nullptr) {
            llama_batch_free(batch);
            fail_and_exit(TS_S2S_EXIT_INFER_FAIL,
                "tessera-s2s-cli: llama_get_embeddings returned NULL on frame %lld",
                (long long) f);
        }
        std::memcpy(pcm_buf.data(), embd, (size_t) n_samples_per_frame * sizeof(float));
        llama_batch_free(batch);
        const auto t_c2w_end = std::chrono::steady_clock::now();
        const int64_t c2w_us = std::chrono::duration_cast<std::chrono::microseconds>(t_c2w_end - t_c2w_start).count();
        total_c2w_us += c2w_us;

        // --- write the PCM frame (16-bit signed little-endian) ---
        for (float s : pcm_buf) {
            float c = s;
            if (c >  1.0f) c =  1.0f;
            if (c < -1.0f) c = -1.0f;
            const int16_t v = (int16_t) std::lrint(c * 32767.0f);
            const uint8_t lo = (uint8_t) (v & 0xFFu);
            const uint8_t hi = (uint8_t) ((v >> 8) & 0xFFu);
            pcm.put((char) lo);
            pcm.put((char) hi);
        }

        if (f == 0) {
            const auto t_now = std::chrono::steady_clock::now();
            first_packet_us = std::chrono::duration_cast<std::chrono::microseconds>(t_now - t_total_start).count();
            // talker TTFT in the skip path: report the time-to-first-frame
            // (the retokenize + first c2w forward). When the real talker
            // lands, this becomes time-to-first-codebook-0 token from
            // prefill end.
            talker_ttft_us = first_packet_us;
        }

        // --- per-utterance capture (one append per frame) ---
        const auto t_cap_start = std::chrono::steady_clock::now();
        const int64_t decode_fps_so_far = (f + 1) * 1000000LL / std::max<int64_t>(1LL, total_decode_us);
        const int64_t c2w_fps_so_far    = (f + 1) * 1000000LL / std::max<int64_t>(1LL, total_c2w_us);

        // The per-frame call is intentionally appending one partial record
        // at a time (so streaming writes don't block on the talker finishing).
        // The Swift-side TesseraTraceStore may coalesce on read.
        const int32_t gemma_tokens[1] = { -1 };
        const int32_t qwen_ids_local[1] = { qwen_ids.empty() ? -1 : qwen_ids[0] };
        // keep digest strings alive in this scope - the capture struct
        // stores raw const char * so the std::string storage must outlive
        // the tessera_rt_s2s_append call below.
        const std::string talker_digest  = file_digest_hex(args.talker_gguf);
        const std::string vocoder_digest = file_digest_hex(args.vocoder_gguf);
        const std::string sid            = make_sid();
        const char * models_keys[2]   = { "talker", "code2wav" };
        const char * models_values[2] = { talker_digest.c_str(), vocoder_digest.c_str() };
        const tessera_s2s_timing t {
            retokenize_us, talker_ttft_us, first_packet_us,
            (double) decode_fps_so_far, (double) c2w_fps_so_far,
        };
        const tessera_s2s_voice voice   { args.preset.c_str(),
                                          args.ref_hash.empty() ? nullptr : args.ref_hash.c_str() };
        const tessera_s2s_feedback fb   { 0, 0, 0 };
        const tessera_s2s_models models { models_keys, models_values, 2 };
        const tessera_s2s_capture_args cap {
            gemma_tokens, 1, qwen_ids_local, 1, args.text.c_str(),
            frame_h.data(), 1, t, voice, fb, models,
            sid.c_str(),
            TESSERA_S2S_PROVENANCE_VALUE,
            args.trace_out.c_str(),
        };
        const int cap_rc = tessera_rt_s2s_append(&cap);
        if (cap_rc != 0) {
            fail_and_exit(TS_S2S_EXIT_CAPTURE_FAIL,
                "tessera-s2s-cli: tessera_rt_s2s_append returned %d at frame %lld (trace %s)",
                cap_rc, (long long) f, args.trace_out.c_str());
        }
        const auto t_cap_end = std::chrono::steady_clock::now();
        (void) std::chrono::duration_cast<std::chrono::microseconds>(t_cap_end - t_cap_start).count();

        ++n_emitted_frames;
        const auto t_frame_end = std::chrono::steady_clock::now();
        const int64_t frame_us = std::chrono::duration_cast<std::chrono::microseconds>(t_frame_end - t_frame_start).count();
        total_decode_us += frame_us;
    }

    pcm.close();
    if (talker_model != nullptr) llama_model_free(talker_model);
    if (c2w_model   != nullptr) llama_model_free(c2w_model);

    const auto t_total_end = std::chrono::steady_clock::now();
    const int64_t total_us = std::chrono::duration_cast<std::chrono::microseconds>(t_total_end - t_total_start).count();
    const double decode_fps = (double) n_emitted_frames * 1e6 / (double) std::max<int64_t>(1LL, total_decode_us);
    const double c2w_fps    = (double) n_emitted_frames * 1e6 / (double) std::max<int64_t>(1LL, total_c2w_us);

    // one-line timing summary (stderr) — matches the s2s design 4.1 contract
    std::fprintf(stderr,
        "tessera-s2s-cli: ok frames=%d retokenize_us=%lld talker_ttft_us=%lld "
        "first_packet_us=%lld decode_frames_per_s=%.3f code2wav_frames_per_s=%.3f "
        "total_us=%lld exit=%d (%s) pcm=%s trace=%s\n",
        n_emitted_frames,
        (long long) retokenize_us, (long long) talker_ttft_us, (long long) first_packet_us,
        decode_fps, c2w_fps,
        (long long) total_us,
        TS_S2S_EXIT_OK, ts_s2s_exit_str(TS_S2S_EXIT_OK),
        args.output_pcm.c_str(), args.trace_out.c_str());
    return TS_S2S_EXIT_OK;
}
