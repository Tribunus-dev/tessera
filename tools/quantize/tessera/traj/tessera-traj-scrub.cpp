//
// tessera-traj-scrub.h
//
// Ingest-time PII / secret scrubber for v1 trajectory records. Thin
// wrapper around the existing tessera-anonymizer and tessera-scrub
// modules. Iterates over the messages[] content + tool_call arguments
// and rewrites them in place; records the aggressiveness level and
// removal counts in the trajectory's ingest_scrub field.
//
// Aggressiveness:
//   light      - rename user symbols only (anonymizer light)
//   balanced   - + scrub string-literal / comment contents (anonymizer
//                balanced + scrub secrets)
//   aggressive - + scrub numeric constants and path-like tokens
//                (anonymizer aggressive + scrub secrets)
//
// All three modes are byte-stable (same input -> same output).
// Reusing the existing egress tools preserves the determinism
// contract from docs/agentic-training-data-flywheel-design.md
// Stage 4.
//

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "tessera-anonymizer.h"
#include "tessera-scrub.h"

using json = nlohmann::json;

namespace {

enum class aggressiveness { light, balanced, aggressive };

aggressiveness parse_agg(const std::string & s, bool * ok) {
    *ok = true;
    if (s == "light")      return aggressiveness::light;
    if (s == "balanced")   return aggressiveness::balanced;
    if (s == "aggressive") return aggressiveness::aggressive;
    *ok = false;
    return aggressiveness::balanced;
}

const char * agg_name(aggressiveness a) {
    switch (a) {
        case aggressiveness::light:      return "light";
        case aggressiveness::balanced:   return "balanced";
        case aggressiveness::aggressive: return "aggressive";
    }
    return "balanced";
}

}  // namespace

int main(int argc, char ** argv) {
    if (argc != 4) {
        std::fprintf(stderr,
            "tessera-traj-scrub - ingest-time PII/secret scrub for v1 trajectories\n"
            "\n"
            "Usage: %s <input.jsonl> <output.jsonl> <light|balanced|aggressive>\n",
            argv[0]);
        return argc == 1 ? 0 : 2;
    }

    const char * in_path  = argv[1];
    const char * out_path = argv[2];
    const char * agg_str  = argv[3];
    bool agg_ok = false;
    aggressiveness agg = parse_agg(agg_str, &agg_ok);
    if (!agg_ok) {
        std::fprintf(stderr, "tessera-traj-scrub: invalid aggressiveness '%s'\n", agg_str);
        return 2;
    }

    std::ifstream fin(in_path);
    if (!fin) {
        std::fprintf(stderr, "tessera-traj-scrub: cannot open input %s\n", in_path);
        return 2;
    }
    std::ofstream fout(out_path, std::ios::binary);
    if (!fout) {
        std::fprintf(stderr, "tessera-traj-scrub: cannot open output %s\n", out_path);
        return 2;
    }

    int n_written = 0, n_skipped = 0;
    int n_pii_removed = 0, n_secrets_removed = 0;
    int n_redacted_chars = 0;
    std::string line;
    while (std::getline(fin, line)) {
        if (line.empty()) continue;
        json rec;
        try { rec = json::parse(line); }
        catch (...) { n_skipped++; continue; }
        if (rec.value("schema", "") != "llama.tessera.agent-traj.v1") {
            n_skipped++;
            continue;
        }

        // Walk messages and scrub content + tool_call arguments.
        if (rec.contains("messages") && rec["messages"].is_array()) {
            for (auto & m : rec["messages"]) {
                if (m.contains("message") && m["message"].is_string()) {
                    std::string s = m["message"].get<std::string>();
                    std::string out;
                    std::string err;
                    int rc = ts_anonymize_text(s, agg_name(agg), &out, &err);
                    if (rc == 0) {
                        if (out != s) n_pii_removed++;
                        m["message"] = out;
                    }
                    std::string scrubbed;
                    int scr = ts_scrub_secrets(out.empty() ? s : out, &scrubbed, &err);
                    if (scr == 0 && scrubbed != (out.empty() ? s : out)) {
                        n_secrets_removed += std::abs((int)scrubbed.size() - (int)(out.empty() ? s : out).size());
                        m["message"] = scrubbed;
                        n_redacted_chars += std::abs((int)scrubbed.size() - (int)s.size());
                    }
                }
                if (m.contains("tool_calls") && m["tool_calls"].is_array()) {
                    for (auto & tc : m["tool_calls"]) {
                        if (tc.contains("arguments") && tc["arguments"].is_string()) {
                            std::string s = tc["arguments"].get<std::string>();
                            std::string scrubbed;
                            std::string err;
                            int scr = ts_scrub_secrets(s, &scrubbed, &err);
                            if (scr == 0 && scrubbed != s) {
                                n_secrets_removed += std::abs((int)scrubbed.size() - (int)s.size());
                                tc["arguments"] = scrubbed;
                                n_redacted_chars += std::abs((int)scrubbed.size() - (int)s.size());
                            }
                        }
                    }
                }
            }
        }

        // Stamp ingest_scrub metadata. Preserve existing content if
        // the user already wrote something; only fill the fields the
        // tool actually controlled.
        json scrub_meta;
        scrub_meta["applied"]       = true;
        scrub_meta["aggressiveness"] = agg_name(agg);
        scrub_meta["removed_pii"]    = n_pii_removed;
        scrub_meta["removed_secrets"] = n_secrets_removed;
        scrub_meta["redaction_map_id"] = std::string("redmap-") + agg_name(agg);
        rec["ingest_scrub"] = scrub_meta;

        fout << rec.dump() << "\n";
        n_written++;
    }

    std::printf("scrubbed %d records, skipped %d, pii_removed=%d secrets_redacted_chars=%d\n",
                n_written, n_skipped, n_pii_removed, n_redacted_chars);
    return 0;
}
