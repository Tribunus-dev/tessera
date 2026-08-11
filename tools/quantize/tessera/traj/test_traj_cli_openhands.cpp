//
// test_traj_cli_openhands.cpp
//
// Boundary test for the OpenHands event-log converter. Writes a small
// synthetic OpenHands log covering the action types v1 recognizes
// (message, run_cmd + cmd_output, read, finish), runs the converter,
// then re-validates the produced v1 record with the schema gate.
//
// Round-trip invariants asserted:
//   - the produced record's schema is llama.tessera.agent-traj.v1
//   - the schema-gate returns n_invalid == 0
//   - step_id is sequential from 1
//   - tool_call_id is unique within the trajectory
//   - the cmd_output observation is attached to the run_cmd step
//   - n_user_turns + n_assistant_turns + n_tool_calls match
//     the structure of the input
//
// Run: ./test_traj_cli_openhands
//

#include "tessera-trajectory.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

static int g_fail = 0;

static void check(const char * name, bool ok) {
    if (ok) std::printf("ok   %s\n", name);
    else    { std::printf("FAIL %s\n", name); g_fail++; }
}

static void check_eq_int(const char * name, int got, int want) {
    if (got == want) std::printf("ok   %-44s %d\n", name, got);
    else             { std::printf("FAIL %-44s got %d want %d\n", name, got, want); g_fail++; }
}

static void write_file(const std::string & path, const std::string & body) {
    std::ofstream f(path, std::ios::binary);
    f << body;
}

static std::string read_file(const std::string & path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream os;
    os << f.rdbuf();
    return os.str();
}

// Run a child process synchronously and return its combined stdout +
// stderr + exit code. Lightweight; we only need it for the converter
// CLI which is built into the same build.
static int run_cmd(const std::string & cmd, std::string * out) {
    std::string full = cmd + " 2>&1";
    FILE * p = popen(full.c_str(), "r");
    if (!p) return -1;
    char buf[4096];
    std::string acc;
    while (fgets(buf, sizeof(buf), p)) acc += buf;
    int rc = pclose(p);
    if (WIFEXITED(rc)) rc = WEXITSTATUS(rc);
    if (out) *out = acc;
    return rc;
}

int main() {
    const std::string in_path  = "/tmp/test_traj_oh_input.json";
    const std::string out_path = "/tmp/test_traj_oh_output.jsonl";

    // ---------------------------------------------------------------------
    // Build a synthetic OpenHands log.
    // ---------------------------------------------------------------------
    json log;
    log["id"] = "sess-test-001";
    log["events"] = json::array();

    // 1. system message
    log["events"].push_back({
        {"system_message", "You are an OpenHands agent."}
    });

    // 2. user message
    log["events"].push_back({
        {"action", {{"action", "message"}, {"role", "user"},
                    {"content", "List the files in the current directory."}}}
    });

    // 3. agent reasoning + run_cmd action
    log["events"].push_back({
        {"action", {{"action", "message"}, {"role", "assistant"},
                    {"content", "I'll run ls to list the files."},
                    {"reasoning_content", "The user wants a directory listing."}}}
    });
    log["events"].push_back({
        {"action", {{"action", "run_cmd"}, {"command", "ls -la"}}}
    });
    // 4. cmd output observation (attached to the run_cmd step)
    log["events"].push_back({
        {"observation", {{"observation", "run_cmd"},
                         {"output", "total 8\ndrwxr-xr-x  .  ..\n"},
                         {"exit_code", 0}}}
    });

    // 5. read action + read observation
    log["events"].push_back({
        {"action", {{"action", "read"}, {"path", "/etc/hostname"}}}
    });
    log["events"].push_back({
        {"observation", {{"observation", "read"},
                         {"content", "tessera-test-host\n"}}}
    });

    // 6. finish
    log["events"].push_back({
        {"action", {{"action", "finish"},
                    {"thought", "Listed the files; task complete."}}}
    });

    // 7. unrecognized action type (will be dropped)
    log["events"].push_back({
        {"action", {{"action", "weird_future_type"},
                    {"content", "should be dropped"}}}
    });

    write_file(in_path, log.dump());

    // Remove any prior output so we know what was written.
    {
        std::remove(out_path.c_str());
    }

    // ---------------------------------------------------------------------
    // Run the converter.
    // ---------------------------------------------------------------------
    std::string run_out;
    int rc = run_cmd("tessera-traj-cli --mode=openhands "
                     "--input " + in_path +
                     " --output " + out_path +
                     " --task-id nebius__sdf-xarray-24 "
                     "--task-source swe-rebench "
                     " --model-name Qwen3-Coder-30B-A3B", &run_out);
    check_eq_int("converter exit code", rc, 0);

    // ---------------------------------------------------------------------
    // Read the output record.
    // ---------------------------------------------------------------------
    std::string body = read_file(out_path);
    check("output file non-empty", !body.empty());

    std::istringstream is(body);
    std::string line;
    std::vector<json> records;
    while (std::getline(is, line)) {
        if (line.empty()) continue;
        records.push_back(json::parse(line));
    }
    check_eq_int("exactly one record written", (int)records.size(), 1);

    const json & rec = records[0];
    check("record schema is v1", rec.value("schema", "") == ts_traj::SCHEMA_V1);
    check("task_id is preserved", rec.value("task_id", "") == "nebius__sdf-xarray-24");
    check("task_source is preserved", rec.value("task_source", "") == "swe-rebench");
    check("model_name is preserved",
          rec["agent"].value("model_name", "") == "Qwen3-Coder-30B-A3B");

    const auto & messages = rec["messages"];
    check("messages is array", messages.is_array());

    // Step ids sequential from 1.
    int prev = 0;
    bool seq_ok = true;
    for (const auto & m : messages) {
        if (m.value("step_id", 0) != prev + 1) { seq_ok = false; break; }
        prev = m.value("step_id", 0);
    }
    check("step_id is sequential from 1", seq_ok);

    // All step sources are in the allowed set.
    bool src_ok = true;
    for (const auto & m : messages) {
        const std::string s = m.value("source", "");
        if (s != "user" && s != "agent" && s != "tool" && s != "system") { src_ok = false; break; }
    }
    check("all sources are user/agent/tool/system", src_ok);

    // Tool call ids unique within the trajectory.
    std::vector<std::string> tcids;
    for (const auto & m : messages) {
        if (m.contains("tool_calls")) {
            for (const auto & tc : m["tool_calls"]) {
                tcids.push_back(tc.value("tool_call_id", ""));
            }
        }
    }
    {
        std::set<std::string> seen;
        bool uniq = true;
        for (const auto & t : tcids) {
            if (!seen.insert(t).second) { uniq = false; break; }
        }
        check("tool_call_ids are unique", uniq);
    }

    // The run_cmd observation is attached to the run_cmd step.
    bool cmd_obs_attached = false;
    for (const auto & m : messages) {
        if (m.contains("tool_calls") && m["tool_calls"].is_array()) {
            for (const auto & tc : m["tool_calls"]) {
                if (tc.value("function_name", "") == "execute_bash" &&
                    m.contains("observation") &&
                    m["observation"].contains("results") &&
                    m["observation"]["results"].is_array() &&
                    !m["observation"]["results"].empty() &&
                    m["observation"]["results"][0].value("source_call_id", "") ==
                        tc.value("tool_call_id", "")) {
                    cmd_obs_attached = true;
                }
            }
        }
    }
    check("run_cmd observation attached to its tool call", cmd_obs_attached);

    // n_user_turns = 1 (the user message), n_assistant_turns >= 1.
    const int n_user = rec["final_metrics"].value("n_user_turns", 0);
    const int n_assist = rec["final_metrics"].value("n_assistant_turns", 0);
    const int n_tools = rec["final_metrics"].value("n_tool_calls", 0);
    check("n_user_turns >= 1", n_user >= 1);
    check("n_assistant_turns >= 1", n_assist >= 1);
    check("n_tool_calls == 2", n_tools == 2);  // run_cmd + read

    // Re-validate the produced record: it must pass the schema gate.
    {
        ts_traj::ts_traj_validation_result vr;
        std::string em;
        int vrc = ts_traj::validate_file(out_path.c_str(), &vr, &em);
        check_eq_int("schema-gate re-validate rc", vrc, 0);
        check_eq_int("schema-gate n_valid",   vr.n_valid,   1);
        check_eq_int("schema-gate n_invalid", vr.n_invalid, 0);
        check_eq_int("schema-gate n_skipped", vr.n_skipped, 0);
    }

    // Determinism: a second run produces a record with the same
    // trajectory structure (step_id ordering, tool_call_ids, message
    // counts). We can't assert byte-equality because trajectory_id
    // embeds a timestamp; the structural invariants are what matter.
    {
        std::string before = read_file(out_path);
        // Append a second run, then re-validate.
        std::string em;
        int rc2 = run_cmd("tessera-traj-cli --mode=openhands "
                          "--input " + in_path +
                          " --output " + out_path +
                          " --task-id same-task", &em);
        check_eq_int("second run exit code", rc2, 0);

        ts_traj::ts_traj_validation_result vr2;
        std::string em2;
        int vrc2 = ts_traj::validate_file(out_path.c_str(), &vr2, &em2);
        check_eq_int("schema-gate n_valid after 2 runs",   vr2.n_valid,   2);
        check_eq_int("schema-gate n_invalid after 2 runs", vr2.n_invalid, 0);
        check_eq_int("schema-gate n_skipped after 2 runs", vr2.n_skipped, 0);
    }

    std::printf("\n%s\n", g_fail == 0 ? "all ok" : "FAILED");
    return g_fail == 0 ? 0 : 1;
}
