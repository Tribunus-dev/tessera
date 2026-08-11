//
// gen_joint_calib.cpp
//
// Generate the v1 joint calibration set for L5 adaptive requantization.
// One record per line of JSONL, each with:
//   - "text":           a synthetic text prompt (deterministic, fixed seed)
//   - "talker_targets": a synthetic audio target sequence (deterministic)
//
// v1 emits SCHEMA only. v3 wires the real text-to-audio mapping (the
// talker's FP forward on the trunk's final output produces the audio
// targets). For now, both halves are synthetic so the JSONL format is
// locked in and downstream code (v2 L5 loop, v3 muxer integration)
// can read the same shape regardless of whether the talker targets
// are real or synthetic.
//
// Output: stdout (or the file given by --out). Default 256 records.
//
// Phase: v1 of plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d.md.
//

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---- Synthetic text prompts (deterministic, no real LLM needed) ----
//
// Each prompt is a short sentence with a fixed structure: "The {noun}
// {verb} the {noun} {adverb}." The vocabulary is tiny but enough to
// exercise the L5 loop's tokenizer and forward pass on real data.

static const std::vector<std::string> k_nouns = {
    "cat", "dog", "tree", "river", "mountain", "city", "field", "ocean"
};
static const std::vector<std::string> k_verbs = {
    "sees", "hears", "follows", "crosses", "reaches", "leaves", "remembers"
};
static const std::vector<std::string> k_adverbs = {
    "slowly", "quickly", "silently", "carefully", "eventually", "always"
};

static std::string synth_text(uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_int_distribution<size_t> noun_pick(0, k_nouns.size() - 1);
    std::uniform_int_distribution<size_t> verb_pick(0, k_verbs.size() - 1);
    std::uniform_int_distribution<size_t> adv_pick(0, k_adverbs.size() - 1);
    char buf[128];
    std::snprintf(buf, sizeof(buf), "The %s %s the %s %s.",
            k_nouns[noun_pick(rng)].c_str(),
            k_verbs[verb_pick(rng)].c_str(),
            k_nouns[noun_pick(rng)].c_str(),
            k_adverbs[adv_pick(rng)].c_str());
    return std::string(buf);
}

// ---- Synthetic audio targets ----
//
// For v1, the audio target is a fixed-length sequence of audio token
// IDs in [0, 4096) derived from the seed. v3 replaces this with the
// real talker FP forward output.

static std::vector<int32_t> synth_audio_targets(uint32_t seed, int32_t n_tokens) {
    std::mt19937 rng(seed);
    std::uniform_int_distribution<int32_t> tok(0, 4095);
    std::vector<int32_t> out(n_tokens);
    for (int32_t i = 0; i < n_tokens; ++i) {
        out[i] = tok(rng);
    }
    return out;
}

// ---- JSONL writer (no external deps) ----

static std::string json_escape(const std::string & s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if ((unsigned char)c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

static void write_record(FILE * out, const std::string & text,
                          const std::vector<int32_t> & talker_targets) {
    std::fprintf(out, "{\"text\":\"%s\",\"talker_targets\":[",
            json_escape(text).c_str());
    for (size_t i = 0; i < talker_targets.size(); ++i) {
        std::fprintf(out, "%d", talker_targets[i]);
        if (i + 1 < talker_targets.size()) std::fprintf(out, ",");
    }
    std::fprintf(out, "]}\n");
}

// ---- main ----

int main(int argc, char ** argv) {
    int32_t n_records = 256;
    int32_t n_talker_tokens = 32;  // audio length per record
    uint32_t base_seed = 0xC0FFEE;
    const char * out_path = nullptr;

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--n-records") == 0 && i + 1 < argc) {
            n_records = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--n-talker-tokens") == 0 && i + 1 < argc) {
            n_talker_tokens = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
            base_seed = (uint32_t)std::strtoul(argv[++i], nullptr, 0);
        } else if (std::strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            out_path = argv[++i];
        } else if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
            std::fprintf(stderr,
                    "Usage: gen_joint_calib [--n-records N] [--n-talker-tokens N] "
                    "[--seed N] [--out PATH]\n"
                    "  Generates the v1 joint calibration set (synthetic text +\n"
                    "  synthetic audio targets) as JSONL on stdout or to --out.\n"
                    "  v3 wires the real text-to-audio target mapping.\n");
            return 0;
        }
    }

    FILE * out = stdout;
    if (out_path) {
        out = std::fopen(out_path, "w");
        if (!out) {
            std::fprintf(stderr, "gen_joint_calib: failed to open %s for write\n", out_path);
            return 1;
        }
    }

    for (int32_t i = 0; i < n_records; ++i) {
        const uint32_t seed = base_seed ^ (uint32_t)i;
        const std::string text = synth_text(seed);
        const std::vector<int32_t> targets = synth_audio_targets(seed + 1, n_talker_tokens);
        write_record(out, text, targets);
    }

    if (out != stdout) std::fclose(out);

    std::fprintf(stderr, "gen_joint_calib: wrote %d records (text + %d talker tokens each)\n",
            n_records, n_talker_tokens);
    return 0;
}
