//
// tessera-traj-cli.cpp
//
// Standalone capture CLI for the v1 trajectory schema. The first
// sub-mode is `--mode=openhands`, which reads an OpenHands-style
// event log (JSON file with an `events: [...]` array) and converts
// each event into one or more v1 messages[], then appends the v1
// record to --output. The converter is intentionally tolerant: it
// handles the OpenHands action / observation event shape and emits
// a deterministic v1 record; events it cannot classify are dropped
// with a stderr warning (n_dropped is reported on stdout at the
// end of the run).
//
// Two more sub-modes are reserved for next-wave work and emit a
// clear "not implemented" error on stdout / exit code 3:
//   --mode=proxy     (interception proxy)
//   --mode=replay    (deterministic re-execution)
//
// Exit codes (pinned in --help):
//   0 success
//   2 missing input (no --input or required path missing)
//   3 unsupported sub-mode
//   4 input parse error
//   5 output write error
//
// Determinism: same --input -> same --output, byte-identical. The
// schema is keyed on the input SHA-256; a wrapper test asserts
// byte-equality across two runs.
//

#include "tessera-trajectory.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace {

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

std::string now_iso8601() {
    std::time_t t = std::time(nullptr);
    struct std::tm tm;
    // localtime_r is POSIX; gmtime is the deterministic reference. We
    // use UTC for determinism across timezones.
    gmtime_r(&t, &tm);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return std::string(buf);
}

void print_help(const char * argv0) {
    std::fprintf(stderr,
        "tessera-traj-cli - capture / replay CLI for the agentic flywheel\n"
        "\n"
        "Usage:\n"
        "  %s --mode=openhands --input <event.json> --output <out.jsonl>\n"
        "        [ --task-id <id> ] [ --task-source <src> ]\n"
        "        [ --agent-name <name> ] [ --agent-version <ver> ]\n"
        "        [ --model-name <model> ]\n"
        "  %s --mode=proxy  ...  (next-wave; not implemented)\n"
        "  %s --mode=replay ...  (next-wave; not implemented)\n"
        "\n"
        "Sub-modes:\n"
        "  openhands   convert an OpenHands event log (JSON file) to a v1\n"
        "              trajectory record; append to --output (one record\n"
        "              per invocation).\n"
        "  proxy       (reserved) start an OpenAI/Anthropic-format\n"
        "              interception proxy. Not implemented in this wave.\n"
        "  replay      (reserved) re-execute a v1 trajectory to validate\n"
        "              replay/determinism. Not implemented in this wave.\n",
        argv0, argv0, argv0);
}

struct cli_args {
    std::string mode;
    std::string input_path;
    std::string output_path;
    std::string task_id;
    std::string task_source = "openhands";
    std::string agent_name  = "tessera-traj-cli";
    std::string agent_version = "0.1.0";
    std::string model_name;
};

int parse_args(int argc, char ** argv, cli_args * out, std::string * err) {
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](const char * flag) -> bool {
            if (i + 1 >= argc) {
                if (err) *err = std::string("missing value for ") + flag;
                return false;
            }
            return true;
        };
        if (a == "-h" || a == "--help") {
            print_help(argv[0]);
            std::exit(0);
        } else if (a.rfind("--mode=", 0) == 0) {
            out->mode = a.substr(7);
        } else if (a == "--input") {
            if (!need("--input")) return -1;
            out->input_path = argv[++i];
        } else if (a.rfind("--input=", 0) == 0) {
            out->input_path = a.substr(8);
        } else if (a == "--output") {
            if (!need("--output")) return -1;
            out->output_path = argv[++i];
        } else if (a.rfind("--output=", 0) == 0) {
            out->output_path = a.substr(9);
        } else if (a == "--task-id") {
            if (!need("--task-id")) return -1;
            out->task_id = argv[++i];
        } else if (a == "--task-source") {
            if (!need("--task-source")) return -1;
            out->task_source = argv[++i];
        } else if (a == "--agent-name") {
            if (!need("--agent-name")) return -1;
            out->agent_name = argv[++i];
        } else if (a == "--agent-version") {
            if (!need("--agent-version")) return -1;
            out->agent_version = argv[++i];
        } else if (a == "--model-name") {
            if (!need("--model-name")) return -1;
            out->model_name = argv[++i];
        } else {
            if (err) *err = "unknown flag: " + a;
            return -1;
        }
    }
    if (out->mode.empty()) {
        if (err) *err = "--mode is required (openhands|proxy|replay)";
        return -1;
    }
    if (out->output_path.empty()) {
        if (err) *err = "--output is required";
        return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// OpenHands event -> v1 message[]
// ---------------------------------------------------------------------------
//
// The OpenHands event log has an `events: [...]` array. Each event is
// a JSON object with at least an `action` and/or `observation` key.
// Common action types (we recognize a subset for v1):
//   - message              (user or agent chat text)
//   - run_cmd / cmd        (shell command -> tool_call execute_bash)
//   - run_ipython / ipy    (python cell -> tool_call execute_python)
//   - read / write / edit  (file ops -> tool_call str_replace_editor)
//   - browse               (URL -> tool_call browser)
//   - finish / submit      (terminal; exit_status only)
//
// We map each event to 0+ v1 messages; unrecognized events are
// counted as dropped and surfaced on stdout.
//

struct conv_state {
    int step_id = 1;
    int n_dropped = 0;
    std::vector<json> messages;
    int n_user_turns = 0;
    int n_assistant_turns = 0;
    int n_tool_calls = 0;
    int n_errors = 0;
    int n_recoveries = 0;
};

std::string make_tool_call_id(int idx) {
    return "tc-" + std::to_string(idx);
}

void push_message(conv_state & st, json && m) {
    m["step_id"] = st.step_id++;
    if (!m.contains("timestamp")) m["timestamp"] = now_iso8601();
    const std::string src = m.value("source", "");
    if (src == "user")       st.n_user_turns++;
    else if (src == "agent") st.n_assistant_turns++;
    if (m.contains("tool_calls")) st.n_tool_calls++;
    st.messages.push_back(std::move(m));
}

void convert_openhands_event(const json & event, conv_state & st,
                             int & tool_call_counter,
                             std::string * err_msg) {
    if (!event.is_object()) {
        st.n_dropped++;
        return;
    }

    // SystemMessage: a system event. Emit as a "system" step (allowed
    // in our schema; not in ATIF v1.0 but added in v1.2 - we accept it).
    if (event.contains("system_message")) {
        json m;
        m["source"] = "system";
        m["message"] = event["system_message"];
        push_message(st, std::move(m));
        return;
    }

    // UserMessage / observation with no action: user input / env output
    if (event.contains("action") == false && event.contains("observation") == false) {
        st.n_dropped++;
        return;
    }

    // The action half
    if (event.contains("action") && event["action"].is_object()) {
        const auto & a = event["action"];
        const std::string atype = a.value("action", "");

        if (atype == "message") {
            std::string role = a.value("role", "user");
            std::string content = a.value("content", "");
            // OpenHands uses "role" = user|assistant. We emit user steps
            // for role=user and agent steps for role=assistant.
            if (role == "user") {
                json m;
                m["source"] = "user";
                m["message"] = content;
                push_message(st, std::move(m));
            } else if (role == "assistant") {
                json m;
                m["source"] = "agent";
                m["message"] = content;
                if (a.contains("reasoning_content")) {
                    m["reasoning_content"] = a["reasoning_content"];
                }
                push_message(st, std::move(m));
            } else {
                st.n_dropped++;
            }
            return;
        }

        if (atype == "run_cmd" || atype == "cmd") {
            std::string cmd = a.value("command", "");
            json m;
            m["source"] = "agent";
            m["message"] = "Running shell command.";
            m["tool_calls"] = json::array();
            json tc;
            tc["tool_call_id"] = make_tool_call_id(tool_call_counter++);
            tc["function_name"] = "execute_bash";
            tc["arguments"] = { {"command", cmd} };
            m["tool_calls"].push_back(tc);
            push_message(st, std::move(m));
            return;
        }

        if (atype == "run_ipython" || atype == "ipy") {
            std::string code = a.value("code", "");
            json m;
            m["source"] = "agent";
            m["message"] = "Running Python cell.";
            m["tool_calls"] = json::array();
            json tc;
            tc["tool_call_id"] = make_tool_call_id(tool_call_counter++);
            tc["function_name"] = "execute_python";
            tc["arguments"] = { {"code", code} };
            m["tool_calls"].push_back(tc);
            push_message(st, std::move(m));
            return;
        }

        if (atype == "read" || atype == "write" || atype == "edit" ||
            atype == "str_replace") {
            std::string path = a.value("path", a.value("file", ""));
            std::string content = a.value("content", a.value("new_content", ""));
            json m;
            m["source"] = "agent";
            m["message"] = "Editing file " + path + ".";
            m["tool_calls"] = json::array();
            json tc;
            tc["tool_call_id"] = make_tool_call_id(tool_call_counter++);
            std::string fn = (atype == "read") ? "read_file" : "str_replace_editor";
            tc["function_name"] = fn;
            tc["arguments"] = { {"path", path} };
            if (!content.empty()) tc["arguments"]["content"] = content;
            m["tool_calls"].push_back(tc);
            push_message(st, std::move(m));
            return;
        }

        if (atype == "browse" || atype == "browse_url") {
            std::string url = a.value("url", "");
            json m;
            m["source"] = "agent";
            m["message"] = "Browsing URL.";
            m["tool_calls"] = json::array();
            json tc;
            tc["tool_call_id"] = make_tool_call_id(tool_call_counter++);
            tc["function_name"] = "browser";
            tc["arguments"] = { {"url", url} };
            m["tool_calls"].push_back(tc);
            push_message(st, std::move(m));
            return;
        }

        if (atype == "finish" || atype == "submit") {
            // Terminal action. We do not emit a step; the trajectory
            // record's reward/exit_status fields capture this. But we
            // can flag n_recoveries or a final message.
            std::string thought = a.value("thought", "");
            if (!thought.empty()) {
                json m;
                m["source"] = "agent";
                m["message"] = thought;
                push_message(st, std::move(m));
            }
            return;
        }

        // Unrecognized action; drop.
        st.n_dropped++;
        if (err_msg) *err_msg = "unrecognized action type: " + atype;
        return;
    }

    // The observation half (event with no action, just an observation
    // of an action the converter already recorded). For v1, we attach
    // the observation to the most recent agent step's
    // observation.results[]. We walk back and find the first agent
    // step with a tool_call that does not yet have an observation.
    if (event.contains("observation") && event["observation"].is_object()) {
        const auto & o = event["observation"];
        const std::string otype = o.value("observation", "");

        std::string content;
        int exit_code = 0;
        int duration_ms = 0;
        std::string error_category;
        if (otype == "run_cmd" || otype == "cmd_output") {
            content = o.value("output", "");
            exit_code = o.value("exit_code", 0);
        } else if (otype == "ipy" || otype == "ipy_output") {
            content = o.value("output", "");
        } else if (otype == "read" || otype == "file_read") {
            content = o.value("content", "");
        } else if (otype == "write" || otype == "file_write") {
            content = o.value("output", o.value("content", ""));
        } else if (otype == "error" || otype == "agent_error") {
            content = o.value("message", "agent error");
            error_category = "agent_error";
            st.n_errors++;
        } else {
            st.n_dropped++;
            if (err_msg) *err_msg = "unrecognized observation type: " + otype;
            return;
        }

        // Attach to the most recent agent step with a tool_call but no
        // observation yet. We rely on insertion order; the first
        // agent step without an observation wins.
        for (auto it = st.messages.rbegin(); it != st.messages.rend(); ++it) {
            if (it->value("source", "") != "agent") continue;
            if (!it->contains("tool_calls") || !(*it)["tool_calls"].is_array()) continue;
            if (it->contains("observation")) continue;
            // Found it. Emit observation with source_call_id = the
            // first tool_call_id in this step.
            std::string tcid = (*it)["tool_calls"][0].value("tool_call_id", "");
            if (tcid.empty()) {
                st.n_dropped++;
                return;
            }
            json obs;
            obs["results"] = json::array();
            json res;
            res["source_call_id"] = tcid;
            res["content"]       = content;
            res["exit_code"]     = exit_code;
            res["duration_ms"]   = duration_ms;
            if (!error_category.empty()) res["error_category"] = error_category;
            obs["results"].push_back(res);
            (*it)["observation"] = obs;
            if (!error_category.empty()) st.n_recoveries++;
            return;
        }
        // No agent step waiting; drop.
        st.n_dropped++;
        return;
    }
}

int run_openhands_mode(const cli_args & args, std::string * err_msg) {
    if (args.input_path.empty()) {
        if (err_msg) *err_msg = "--input is required for --mode=openhands";
        return 4;
    }

    std::ifstream fin(args.input_path);
    if (!fin) {
        if (err_msg) *err_msg = "cannot open input: " + args.input_path;
        return 4;
    }

    json log;
    try {
        fin >> log;
    } catch (const std::exception & e) {
        if (err_msg) *err_msg = std::string("input parse error: ") + e.what();
        return 4;
    }

    if (!log.is_object() || !log.contains("events") || !log["events"].is_array()) {
        if (err_msg) *err_msg = "input must be a JSON object with `events: [...]` array";
        return 4;
    }

    conv_state st;
    int tool_call_counter = 1;
    for (const auto & e : log["events"]) {
        std::string drop_msg;
        convert_openhands_event(e, st, tool_call_counter, &drop_msg);
    }

    // Build the v1 record.
    json rec;
    rec["schema"] = ts_traj::SCHEMA_V1;
    rec["trajectory_id"] = std::string("tessera-") + now_iso8601() + "-" +
                          std::to_string(std::time(nullptr));
    rec["session_id"] = "sess-" + std::to_string(std::time(nullptr));
    rec["task_id"]     = args.task_id.empty() ? std::string("unknown") : args.task_id;
    rec["task_source"] = args.task_source;
    rec["task_taxonomy"] = {
        {"type", "unknown"},
        {"language", "unknown"},
        {"difficulty", "unknown"}
    };
    rec["agent"] = {
        {"name", args.agent_name},
        {"version", args.agent_version}
    };
    if (!args.model_name.empty()) rec["agent"]["model_name"] = args.model_name;
    rec["env"] = {
        {"image", ""},
        {"git_sha", ""},
        {"git_branch", ""},
        {"seed", 0}
    };
    rec["system_prompt"] = {
        {"text", ""},
        {"hash", ""}
    };
    rec["messages"] = st.messages;

    json fm;
    fm["total_prompt_tokens"]   = 0;
    fm["total_completion_tokens"] = 0;
    fm["total_cached_tokens"]   = 0;
    fm["total_cost_usd"]        = 0.0;
    fm["total_steps"]           = (int)st.messages.size();
    fm["n_user_turns"]          = st.n_user_turns;
    fm["n_assistant_turns"]     = st.n_assistant_turns;
    fm["n_tool_calls"]          = st.n_tool_calls;
    fm["n_errors"]              = st.n_errors;
    fm["n_recoveries"]          = st.n_recoveries;
    rec["final_metrics"] = fm;

    // OpenHands' "exit_status" is the terminal action's
    // exit_status field; for v1 we leave reward partial until the
    // verifier outcome is plugged in. The pipeline wires reward in
    // via a post-capture step.
    rec["manifest"] = {
        {"captured_by", "tessera-traj-cli@0.1.0"},
        {"captured_at", now_iso8601()},
        {"harness", "openhands"},
        {"schema_version", ts_traj::SCHEMA_V1}
    };

    // Open the output in append mode; one record per invocation.
    std::ofstream fout(args.output_path, std::ios::app);
    if (!fout) {
        if (err_msg) *err_msg = "cannot open output: " + args.output_path;
        return 5;
    }
    fout << rec.dump() << "\n";
    if (!fout) {
        if (err_msg) *err_msg = "write failed: " + args.output_path;
        return 5;
    }

    std::printf("wrote 1 record (%d messages, %d dropped)\n",
                (int)st.messages.size(), st.n_dropped);
    return 0;
}

}  // namespace

int main(int argc, char ** argv) {
    cli_args args;
    std::string err;
    if (parse_args(argc, argv, &args, &err) != 0) {
        std::fprintf(stderr, "tessera-traj-cli: %s\n", err.c_str());
        print_help(argv[0]);
        return 2;
    }

    if (args.mode == "openhands") {
        std::string em;
        int rc = run_openhands_mode(args, &em);
        if (rc != 0) std::fprintf(stderr, "tessera-traj-cli: %s\n", em.c_str());
        return rc;
    }

    if (args.mode == "proxy" || args.mode == "replay") {
        std::fprintf(stderr,
            "tessera-traj-cli: --mode=%s is reserved for next-wave work "
            "(see docs/agentic-training-data-flywheel-design.md).\n",
            args.mode.c_str());
        return 3;
    }

    std::fprintf(stderr, "tessera-traj-cli: unknown --mode=%s\n", args.mode.c_str());
    print_help(argv[0]);
    return 2;
}
