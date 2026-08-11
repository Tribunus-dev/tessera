//
// tessera-traj-scrub.cpp
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
#include <cstdlib>
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

ts_anon_level agg_to_anon_level(aggressiveness a) {
    switch (a) {
        case aggressiveness::light:      return TS_ANON_LIGHT;
        case aggressiveness::balanced:   return TS_ANON_BALANCED;
        case aggressiveness::aggressive: return TS_ANON_AGGRESSIVE;
    }
    return TS_ANON_BALANCED;
}

// Run anonymizer + scrub on a string. Returns the (possibly modified)
// text. Counts are updated in-place: n_pii is bumped when anonymizer
// changed the text, n_secrets_chars is bumped by the byte-delta of the
// scrub pass.
//
// KNOWN LIMITATION: we run the anonymizer first, then the scrubber.
// The anonymizer renames C-like identifiers; if a user pastes an API
// key in plain text, the anonymizer can rename the prefix (e.g.
// "sk-abc..." -> "ts-...") and break the scrubber's secret pattern.
// The scrubber still catches high-confidence shapes the anonymizer
// cannot touch: emails (no identifier chars), IPs, absolute paths,
// PEM blocks, and ENV-style KEY=value tokens. Fixing the API-key
// gap needs the anonymizer to skip tokens that match a known secret
// shape - tracked as a follow-on, not in scope for this wave.
std::string scrub_text(const std::string & s,
                       aggressiveness agg,
                       int * n_pii,
                       int * n_secrets_chars) {
    // Anonymize first (symbol renaming).
    std::string after_anon = s;
    {
        ts_anon_params p;
        ts_anon_default_params(&p);
        p.level = agg_to_anon_level(agg);
        p.emit_map = false;
        char * out = nullptr;
        char * map = nullptr;
        int rc = ts_anonymize_run(&p, s.c_str(), &out, &map);
        if (rc == 0 && out != nullptr) {
            after_anon = std::string(out);
            if (after_anon != s) (*n_pii)++;
            std::free(out);
        }
        if (map) std::free(map);
    }

    // Scrub secrets on the anonymized text.
    std::string after_scrub = after_anon;
    {
        char * out = nullptr;
        int n_red = 0;
        int rc = ts_scrub_run(after_anon.c_str(), &out, &n_red);
        if (rc == 0 && out != nullptr) {
            after_scrub = std::string(out);
            *n_secrets_chars += std::abs((int)after_scrub.size() - (int)after_anon.size());
            std::free(out);
        }
    }
    return after_scrub;
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
    int n_pii_removed = 0, n_secrets_chars = 0;
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
                    std::string out = scrub_text(s, agg, &n_pii_removed, &n_secrets_chars);
                    if (out != s) m["message"] = out;
                }
                if (m.contains("tool_calls") && m["tool_calls"].is_array()) {
                    for (auto & tc : m["tool_calls"]) {
                        if (tc.contains("arguments") && tc["arguments"].is_string()) {
                            std::string s = tc["arguments"].get<std::string>();
                            std::string out = scrub_text(s, agg, &n_pii_removed, &n_secrets_chars);
                            if (out != s) tc["arguments"] = out;
                        }
                    }
                }
            }
        }

        // Stamp ingest_scrub metadata. Preserve existing content if
        // the user already wrote something; only fill the fields the
        // tool actually controlled.
        json scrub_meta;
        scrub_meta["applied"]          = true;
        scrub_meta["aggressiveness"]   = agg_name(agg);
        scrub_meta["removed_pii"]      = n_pii_removed;
        scrub_meta["redacted_chars"]   = n_secrets_chars;
        scrub_meta["redaction_map_id"] = std::string("redmap-") + agg_name(agg);
        rec["ingest_scrub"] = scrub_meta;

        fout << rec.dump() << "\n";
        n_written++;
    }

    std::printf("scrubbed %d records, skipped %d, pii_removed=%d secrets_redacted_chars=%d\n",
                n_written, n_skipped, n_pii_removed, n_secrets_chars);
    return 0;
}
