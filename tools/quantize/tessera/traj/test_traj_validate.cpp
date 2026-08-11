//
// test_traj_validate.cpp
//
// Boundary test for the v1 schema gate. Writes a small JSONL with
// both valid and invalid records, runs ts_traj::validate_file, and
// asserts the structured result matches expectations.
//
// Negative cases covered:
//   - wrong schema
//   - parse error
//   - non-sequential step_id
//   - bad source
//   - duplicate tool_call_id
//   - observation source_call_id references a missing tool_call
//   - final_metrics.total_steps != messages.size()
//   - bad reward.verifier_outcome
//   - bad timestamp
//
// Run: ./test_traj_validate
// Exits 0 on all assertions pass; non-zero otherwise.
//

#include "tessera-trajectory.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

static int g_fail = 0;

static void check(const char * name, bool ok) {
    if (ok) {
        std::printf("ok   %s\n", name);
    } else {
        std::printf("FAIL %s\n", name);
        g_fail++;
    }
}

static void check_eq_int(const char * name, int got, int want) {
    if (got == want) {
        std::printf("ok   %-44s %d\n", name, got);
    } else {
        std::printf("FAIL %-44s got %d want %d\n", name, got, want);
        g_fail++;
    }
}

static void write_file(const std::string & path, const std::string & body) {
    std::ofstream f(path, std::ios::binary);
    f << body;
}

// Build a known-good v1 record.
static json make_valid_record(const std::string & trajectory_id, int total_steps) {
    json r;
    r["schema"] = ts_traj::SCHEMA_V1;
    r["trajectory_id"] = trajectory_id;
    r["session_id"] = "sess-test";
    r["task_id"] = "task-test";
    r["task_source"] = "test";
    r["agent"] = { {"name", "test"}, {"version", "0.0.1"} };
    r["env"] = { {"image", ""}, {"git_sha", ""}, {"git_branch", ""}, {"seed", 0} };
    r["system_prompt"] = { {"text", "you are an agent"}, {"hash", ""} };
    r["messages"] = json::array();
    for (int i = 0; i < total_steps; ++i) {
        json m;
        m["source"] = (i == 0) ? "user" : "agent";
        m["message"] = "step " + std::to_string(i);
        m["timestamp"] = "2026-08-10T10:00:00Z";
        r["messages"].push_back(m);
    }
    r["final_metrics"] = {
        {"total_prompt_tokens", 0}, {"total_completion_tokens", 0},
        {"total_cached_tokens", 0}, {"total_cost_usd", 0.0},
        {"total_steps", total_steps}, {"n_user_turns", 1},
        {"n_assistant_turns", total_steps - 1},
        {"n_tool_calls", 0}, {"n_errors", 0}, {"n_recoveries", 0}
    };
    r["manifest"] = {
        {"captured_by", "test"}, {"captured_at", "2026-08-10T10:00:00Z"},
        {"harness", "test"}, {"schema_version", ts_traj::SCHEMA_V1}
    };
    return r;
}

int main() {
    const std::string test_path = "/tmp/test_traj_validate_input.jsonl";
    const std::string out_path  = "/tmp/test_traj_validate_output.txt";

    // ---------------------------------------------------------------------
    // Build the test file: 1 valid, then 9 invalid records.
    // ---------------------------------------------------------------------

    std::string body;
    // 1. valid
    body += make_valid_record("ok-1", 3).dump();
    body += "\n";

    // 2. wrong schema
    {
        json r = make_valid_record("bad-schema", 2);
        r["schema"] = "llama.tessera.spec.v1";  // not the trajectory schema
        body += r.dump();
        body += "\n";
    }

    // 3. parse error
    body += "{ this is not valid json\n";

    // 4. non-sequential step_id (steps 1, 2, 4)
    {
        json r = make_valid_record("bad-stepid", 3);
        r["messages"][2]["step_id"] = 4;
        body += r.dump();
        body += "\n";
    }

    // 5. bad source
    {
        json r = make_valid_record("bad-source", 2);
        r["messages"][1]["source"] = "robot";
        body += r.dump();
        body += "\n";
    }

    // 6. duplicate tool_call_id on the same trajectory
    {
        json r = make_valid_record("bad-dup-tcid", 3);
        r["messages"][1]["tool_calls"] = json::array();
        r["messages"][1]["tool_calls"].push_back({
            {"tool_call_id", "tc-A"},
            {"function_name", "execute_bash"},
            {"arguments", {{"command", "ls"}}}
        });
        r["messages"][2]["tool_calls"] = json::array();
        r["messages"][2]["tool_calls"].push_back({
            {"tool_call_id", "tc-A"},  // duplicate
            {"function_name", "execute_bash"},
            {"arguments", {{"command", "pwd"}}}
        });
        r["final_metrics"]["n_tool_calls"] = 2;
        body += r.dump();
        body += "\n";
    }

    // 7. observation source_call_id references a tool_call that does not exist
    {
        json r = make_valid_record("bad-orphan-obs", 3);
        r["messages"][1]["tool_calls"] = json::array();
        r["messages"][1]["tool_calls"].push_back({
            {"tool_call_id", "tc-real"},
            {"function_name", "execute_bash"},
            {"arguments", {{"command", "ls"}}}
        });
        r["messages"][1]["observation"] = {
            {"results", json::array({
                { {"source_call_id", "tc-ghost"},
                  {"content", "..."}, {"exit_code", 0}, {"duration_ms", 0} }
            })}
        };
        body += r.dump();
        body += "\n";
    }

    // 8. final_metrics.total_steps != messages.size()
    {
        json r = make_valid_record("bad-totsteps", 4);
        r["final_metrics"]["total_steps"] = 3;  // wrong
        body += r.dump();
        body += "\n";
    }

    // 9. bad reward.verifier_outcome
    {
        json r = make_valid_record("bad-reward", 2);
        r["reward"] = {
            {"verifier", "test"},
            {"verifier_outcome", "maybe"},  // not in the enum
            {"verifier_partial", 0.5}
        };
        body += r.dump();
        body += "\n";
    }

    // 10. bad timestamp
    {
        json r = make_valid_record("bad-ts", 2);
        r["messages"][1]["timestamp"] = "yesterday";
        body += r.dump();
        body += "\n";
    }

    write_file(test_path, body);

    // ---------------------------------------------------------------------
    // Run validate_file; assert the structured result.
    // ---------------------------------------------------------------------

    ts_traj::ts_traj_validation_result result;
    std::string err_msg;
    int rc = ts_traj::validate_file(test_path.c_str(), &result, &err_msg);
    check_eq_int("validate_file returns 0 on a readable file", rc, 0);
    check_eq_int("n_valid",   result.n_valid,   1);
    check_eq_int("n_invalid", result.n_invalid, 8);
    check_eq_int("n_skipped", result.n_skipped, 2);  // wrong schema + parse error

    // Per-error checks: 8 invalid -> 8 errors. Validate a few of them.
    check_eq_int("errors.size()", (int)result.errors.size(), 8);

    auto find_err = [&](const std::string & tid, const std::string & field) -> bool {
        for (const auto & e : result.errors) {
            if (e.trajectory_id == tid && e.field == field) return true;
        }
        return false;
    };

    check("err: bad-stepid / step_id sequential",     find_err("bad-stepid",    "messages[2].step_id"));
    check("err: bad-source / source enum",            find_err("bad-source",    "messages[1].source"));
    check("err: bad-dup-tcid / duplicate tool_call",  find_err("bad-dup-tcid",  "messages[2].tool_calls[0].tool_call_id"));
    check("err: bad-orphan-obs / source_call_id",     find_err("bad-orphan-obs","messages[1].observation.results[0].source_call_id"));
    check("err: bad-totsteps / total_steps mismatch", find_err("bad-totsteps",  "final_metrics.total_steps"));
    check("err: bad-reward / verifier_outcome",       find_err("bad-reward",    "reward.verifier_outcome"));
    check("err: bad-ts / timestamp",                  find_err("bad-ts",        "messages[1].timestamp"));

    // ---------------------------------------------------------------------
    // Test the C API as well (the CLI uses it). It must return counts
    // that match the C++ result.
    // ---------------------------------------------------------------------
    {
        int nv = -1, ni = -1, ns = -1;
        char * em = nullptr;
        int crc = ts_traj_validate_file(test_path.c_str(), &nv, &ni, &ns, &em);
        check_eq_int("C API rc", crc, 0);
        check_eq_int("C API n_valid",   nv, 1);
        check_eq_int("C API n_invalid", ni, 8);
        check_eq_int("C API n_skipped", ns, 2);
        if (em) {
            std::printf("C API summary: %s\n", em);
            ts_traj_free_errors(em);
        }
    }

    // ---------------------------------------------------------------------
    // Edge: empty file is valid (n_valid = 0, n_invalid = 0).
    // ---------------------------------------------------------------------
    {
        write_file("/tmp/test_traj_validate_empty.jsonl", "");
        ts_traj::ts_traj_validation_result r2;
        std::string em;
        int rc2 = ts_traj::validate_file("/tmp/test_traj_validate_empty.jsonl", &r2, &em);
        check_eq_int("empty file rc",         rc2, 0);
        check_eq_int("empty file n_valid",   r2.n_valid,   0);
        check_eq_int("empty file n_invalid", r2.n_invalid, 0);
        check_eq_int("empty file n_skipped", r2.n_skipped, 0);
    }

    // ---------------------------------------------------------------------
    // Edge: nonexistent file -> -1, err_msg set.
    // ---------------------------------------------------------------------
    {
        ts_traj::ts_traj_validation_result r3;
        std::string em;
        int rc3 = ts_traj::validate_file("/tmp/this_does_not_exist.jsonl", &r3, &em);
        check_eq_int("nonexistent file rc", rc3, -1);
        check("nonexistent file sets err_msg", !em.empty());
    }

    std::printf("\n%s\n", g_fail == 0 ? "all ok" : "FAILED");
    return g_fail == 0 ? 0 : 1;
}
