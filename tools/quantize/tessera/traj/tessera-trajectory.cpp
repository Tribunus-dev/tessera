//
// tessera-trajectory.cpp
//
// Schema-gate implementation for the llama.tessera.agent-traj.v1 record.
// Reads a JSONL file, parses each line, and validates against the v1
// contract documented in tessera-trajectory.h and
// docs/agentic-training-data-flywheel-design.md.
//
// The validation is intentionally strict at parse time. A wrong-schema
// line is a skip, not an error (consistent with tessera-dataset.cpp:170-174);
// a schema-conforming but semantically broken line is an invalid
// (corrupt step_id ordering, mismatched tool_call_id, broken reward
// enum, broken final_metrics.total_steps, etc.) and contributes to
// n_invalid + an entry in errors[].
//
// Pure logic: no llama/ggml dependency. The nlohmann/json library is
// already a tessera build dependency via tessera-dataset.cpp.
//

#include "tessera-trajectory.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace {

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

bool is_iso8601(const std::string & s) {
    // Cheap check: must contain a "T" between date and time, and the
    // date portion must be at least 10 chars (YYYY-MM-DD). We do not
    // validate every calendar edge case - the goal is "not 1970-01-01"
    // and "not garbage", not RFC 3339 strict.
    if (s.size() < 19) return false;
    if (s[4] != '-' || s[7] != '-') return false;
    if (s[10] != 'T' && s[10] != ' ') return false;
    if (s[13] != ':' || s[16] != ':') return false;
    return true;
}

bool is_known_reward_outcome(const std::string & s) {
    return s == "pass" || s == "fail" || s == "partial" ||
           s == "error" || s == "timeout";
}

// Validate one parsed JSON record. Pushes a structured error on
// failure; returns true if the record passes.
bool validate_record(const json & rec,
                     const std::string & trajectory_id,
                     ts_traj::ts_traj_validation_result * result) {

    auto fail = [&](const std::string & field, const std::string & msg) {
        ts_traj::ts_traj_validation_error e;
        e.line_no = -1;  // filled in by caller
        e.trajectory_id = trajectory_id;
        e.field = field;
        e.message = msg;
        result->errors.push_back(e);
        return false;
    };

    // -- messages[] ---------------------------------------------------------
    if (!rec.contains("messages") || !rec["messages"].is_array()) {
        return fail("messages", "missing or not an array");
    }
    const auto & messages = rec["messages"];

    // -- step_id sequential, source allowed set ----------------------------
    std::set<std::string> tool_call_ids_seen;
    int prev_step_id = 0;
    int n_assistant = 0;
    for (size_t i = 0; i < messages.size(); ++i) {
        const auto & m = messages[i];
        std::string field_prefix = "messages[" + std::to_string(i) + "]";

        if (!m.is_object()) {
            return fail(field_prefix, "not an object");
        }
        if (!m.contains("step_id") || !m["step_id"].is_number_integer()) {
            return fail(field_prefix + ".step_id", "missing or not an integer");
        }
        int step_id = m["step_id"].get<int>();
        if (step_id != prev_step_id + 1) {
            return fail(field_prefix + ".step_id",
                        "non-sequential (expected " + std::to_string(prev_step_id + 1) +
                        ", got " + std::to_string(step_id) + ")");
        }
        prev_step_id = step_id;

        if (!m.contains("source") || !m["source"].is_string()) {
            return fail(field_prefix + ".source", "missing or not a string");
        }
        const std::string source = m["source"];
        if (source != "user" && source != "agent" && source != "tool" && source != "system") {
            return fail(field_prefix + ".source",
                        "must be one of user/agent/tool/system, got \"" + source + "\"");
        }

        if (m.contains("timestamp") && m["timestamp"].is_string()) {
            if (!is_iso8601(m["timestamp"].get<std::string>())) {
                return fail(field_prefix + ".timestamp",
                            "not a valid ISO 8601 timestamp");
            }
        }

        // -- tool_calls (agent only) --------------------------------------
        if (source == "agent") {
            n_assistant++;
            if (m.contains("tool_calls") && m["tool_calls"].is_array()) {
                for (size_t k = 0; k < m["tool_calls"].size(); ++k) {
                    const auto & tc = m["tool_calls"][k];
                    std::string tc_field = field_prefix + ".tool_calls[" + std::to_string(k) + "]";
                    if (!tc.is_object()) {
                        return fail(tc_field, "not an object");
                    }
                    if (!tc.contains("tool_call_id") || !tc["tool_call_id"].is_string()) {
                        return fail(tc_field + ".tool_call_id", "missing or not a string");
                    }
                    std::string tcid = tc["tool_call_id"].get<std::string>();
                    if (tcid.empty()) {
                        return fail(tc_field + ".tool_call_id", "empty string");
                    }
                    if (!tool_call_ids_seen.insert(tcid).second) {
                        return fail(tc_field + ".tool_call_id",
                                    "duplicate \"" + tcid + "\" in same trajectory");
                    }
                    if (!tc.contains("function_name") || !tc["function_name"].is_string()) {
                        return fail(tc_field + ".function_name", "missing or not a string");
                    }
                }
            }
        }

        // -- observation (agent only) --------------------------------------
        if (source == "agent" && m.contains("observation") && m["observation"].is_object()) {
            const auto & obs = m["observation"];
            if (!obs.contains("results") || !obs["results"].is_array()) {
                return fail(field_prefix + ".observation.results", "missing or not an array");
            }
            for (size_t r = 0; r < obs["results"].size(); ++r) {
                const auto & res = obs["results"][r];
                std::string r_field = field_prefix + ".observation.results[" + std::to_string(r) + "]";
                if (!res.is_object()) {
                    return fail(r_field, "not an object");
                }
                if (!res.contains("source_call_id") || !res["source_call_id"].is_string()) {
                    return fail(r_field + ".source_call_id", "missing or not a string");
                }
                std::string scid = res["source_call_id"].get<std::string>();
                if (tool_call_ids_seen.find(scid) == tool_call_ids_seen.end()) {
                    return fail(r_field + ".source_call_id",
                                "references tool_call_id \"" + scid + "\" which is not present");
                }
            }
        }
    }

    // -- final_metrics ------------------------------------------------------
    if (rec.contains("final_metrics") && rec["final_metrics"].is_object()) {
        const auto & fm = rec["final_metrics"];
        if (fm.contains("total_steps") && fm["total_steps"].is_number_integer()) {
            int total_steps = fm["total_steps"].get<int>();
            if (total_steps != (int)messages.size()) {
                return fail("final_metrics.total_steps",
                            "expected " + std::to_string(messages.size()) +
                            " (== messages.size()), got " + std::to_string(total_steps));
            }
        }
    }

    // -- reward -------------------------------------------------------------
    if (rec.contains("reward") && rec["reward"].is_object()) {
        const auto & rw = rec["reward"];
        if (rw.contains("verifier_outcome") && rw["verifier_outcome"].is_string()) {
            if (!is_known_reward_outcome(rw["verifier_outcome"].get<std::string>())) {
                return fail("reward.verifier_outcome",
                            "must be one of pass/fail/partial/error/timeout");
            }
        }
    }

    return true;
}

}  // namespace

namespace ts_traj {

int validate_file(const char * path, ts_traj_validation_result * result, std::string * err_msg) {
    std::ifstream fin(path);
    if (!fin) {
        if (err_msg) *err_msg = std::string("cannot open: ") + path;
        return -1;
    }

    int line_no = 0;
    std::string line;
    while (std::getline(fin, line)) {
        line_no++;
        if (line.empty()) continue;

        json rec;
        try {
            rec = json::parse(line);
        } catch (const std::exception & e) {
            result->n_skipped++;
            ts_traj_validation_error err;
            err.line_no = line_no;
            err.trajectory_id = "";
            err.field = "";
            err.message = std::string("json parse error: ") + e.what();
            result->errors.push_back(err);
            continue;
        }

        const std::string schema = rec.value("schema", "");
        if (schema != SCHEMA_V1) {
            result->n_skipped++;
            continue;
        }

        const std::string trajectory_id = rec.value("trajectory_id", "");

        // Stamp line_no on every error pushed by validate_record.
        size_t err_count_before = result->errors.size();
        bool ok = validate_record(rec, trajectory_id, result);
        for (size_t i = err_count_before; i < result->errors.size(); ++i) {
            result->errors[i].line_no = line_no;
        }

        if (ok) {
            result->n_valid++;
        } else {
            result->n_invalid++;
        }
    }

    if (!fin.eof() && fin.bad()) {
        if (err_msg) *err_msg = std::string("read error: ") + path;
        return -1;
    }
    return 0;
}

}  // namespace ts_traj

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

extern "C" {

int ts_traj_validate_file(const char * path,
                          int * n_valid,
                          int * n_invalid,
                          int * n_skipped,
                          char ** err_msg_out) {
    ts_traj::ts_traj_validation_result result;
    std::string err_msg;
    int rc = ts_traj::validate_file(path, &result, &err_msg);
    if (rc != 0) {
        if (err_msg_out) {
            *err_msg_out = strdup(err_msg.c_str());
        }
        return rc;
    }
    if (n_valid)   *n_valid   = result.n_valid;
    if (n_invalid) *n_invalid = result.n_invalid;
    if (n_skipped) *n_skipped = result.n_skipped;
    if (err_msg_out) {
        // Build a one-line human summary; the C++ API has the structured
        // errors. CLI writes a per-error line to stderr; this is just
        // the exit-message.
        std::ostringstream os;
        os << "valid=" << result.n_valid
           << " invalid=" << result.n_invalid
           << " skipped=" << result.n_skipped;
        *err_msg_out = strdup(os.str().c_str());
    }
    return 0;
}

void ts_traj_free_errors(char * err_msg) {
    if (err_msg) free(err_msg);
}

}  // extern "C"
