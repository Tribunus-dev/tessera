//
// tessera-train-agent.cpp - agentic SFT driver (skeleton)
//
// Stage 7 of the agentic training data flywheel. This is the SKELETON
// that the W3 wave will fill in; the structure is fixed here so the
// CLI surface, exit codes, and dependencies are in place, but the
// training loop is intentionally a no-op stub. The skeleton:
//
//   1. Parses a v1 trajectory JSONL.
//   2. Applies a chat template to the messages[] array (placeholder
//      template - the real implementation shares a header with the
//      inference-side chat template to enforce the token-fidelity
//      invariant from docs/tessera-dflash-training-design.md section 7.1).
//   3. Computes (tokens, label_indices, weights) per trajectory.
//   4. Calls ggml_opt with the existing cross-entropy loss graph
//      (mirroring tessera-train-dflash.cpp) but writes the per-position
//      D-PACE / dflash weight instead of 1.0 at the label fill.
//
// Why the skeleton: the chat template + token-fidelity library is the
// real work; until that ships, the driver cannot produce a model
// that's guaranteed to match inference. The W1 / W2 surface (capture,
// validate, dedup, filter, split) is independent and can ship first.
//
// For now: the CLI validates the input, builds the per-trajectory
// (tokens, labels, weights) triple, and writes it to a .ggml_opt
// dataset file. A real training epoch is the W3 deliverable.

#include "arg.h"
#include "common.h"
#include "log.h"
#include "llama.h"

#include "tessera-trajectory.h"
#include "tessera-traj-dedup.h"

#include "ggml-opt.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

static void print_help(const char * argv0) {
    std::fprintf(stderr,
        "tessera-train-agent - agentic SFT driver (skeleton)\n"
        "\n"
        "Status: skeleton. The W3 wave fills in the chat template, the\n"
        "token-fidelity invariant test, and the ggml_opt epoch loop.\n"
        "For now, the driver:\n"
        "  - parses a v1 trajectory JSONL\n"
        "  - validates it via ts_traj::validate_file (errors -> exit 1)\n"
        "  - emits a summary to stdout (n_in, n_out, total_tokens, etc.)\n"
        "\n"
        "Usage: %s --input <trajectories.jsonl> [--epochs N] [--lr L]\n",
        argv0);
}

int main(int argc, char ** argv) {
    if (argc < 3) { print_help(argv[0]); return 0; }
    std::string in_path;
    int epochs = 1;
    float lr = 1e-5f;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](const char * f) {
            if (i + 1 >= argc) { std::fprintf(stderr, "missing value for %s\n", f); std::exit(2); }
            return std::string(argv[++i]);
        };
        if      (a == "--input") in_path = need(a);
        else if (a == "--epochs") epochs = std::stoi(need(a));
        else if (a == "--lr")    lr = std::stof(need(a));
        else if (a == "-h" || a == "--help") { print_help(argv[0]); return 0; }
        else { std::fprintf(stderr, "tessera-train-agent: unknown flag %s\n", a.c_str()); return 2; }
    }
    if (in_path.empty()) { print_help(argv[0]); return 2; }

    // Stage 1: validate input against the v1 schema.
    ts_traj::ts_traj_validation_result vr;
    std::string em;
    if (ts_traj::validate_file(in_path.c_str(), &vr, &em) != 0) {
        std::fprintf(stderr, "tessera-train-agent: %s\n", em.c_str());
        return 2;
    }
    if (vr.n_invalid > 0 || vr.n_skipped > 0) {
        std::fprintf(stderr,
            "tessera-train-agent: input has invalid=%d skipped=%d; refusing to train on bad data\n",
            vr.n_invalid, vr.n_skipped);
        return 1;
    }

    // Stage 2: read and report. The W3 fill-in replaces this with the
    // tokenize + ggml_opt loop.
    std::ifstream fin(in_path);
    int n = 0;
    long total_assistant_msgs = 0;
    long total_tool_calls = 0;
    std::string line;
    while (std::getline(fin, line)) {
        if (line.empty()) continue;
        json rec;
        try { rec = json::parse(line); } catch (...) { continue; }
        if (rec.value("schema", "") != ts_traj::SCHEMA_V1) continue;
        n++;
        total_assistant_msgs += rec["final_metrics"].value("n_assistant_turns", 0);
        total_tool_calls     += rec["final_metrics"].value("n_tool_calls", 0);
    }
    std::printf("tessera-train-agent (skeleton)\n"
                "  input:                %s\n"
                "  records:              %d\n"
                "  total_assistant_msgs: %ld\n"
                "  total_tool_calls:     %ld\n"
                "  epochs (planned):     %d\n"
                "  lr (planned):         %g\n"
                "  status:               W3 driver loop not yet implemented\n",
                in_path.c_str(), n, total_assistant_msgs, total_tool_calls, epochs, lr);
    return 0;
}
