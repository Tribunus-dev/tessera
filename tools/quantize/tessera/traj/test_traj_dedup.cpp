//
// test_traj_dedup.cpp
//
// Boundary test for the three-tier dedup. Builds a small corpus of
// v1 trajectory records: some exact duplicates, some near-duplicates,
// some unique, and one anomaly-cluster (a "bug" tier that would
// remove > anomaly_threshold of input). Asserts:
//
//   - tier 1 removes only byte-identical records (SHA-256 collision)
//   - tier 2 collapses near-duplicates above the Jaccard threshold
//     and keeps the rest
//   - the anomaly case trips halt-on-anomaly (rc=4)
//   - the schema-gate still validates the survivors
//

#include "tessera-traj-dedup.h"
#include "tessera-trajectory.h"

#include <cstdio>
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

static std::string make_traj(const std::string & tid, const std::string & task_id,
                             const std::string & body_text) {
    json r;
    r["schema"]        = ts_traj::SCHEMA_V1;
    r["trajectory_id"] = tid;
    r["session_id"]    = "sess-test";
    r["task_id"]       = task_id;
    r["task_source"]   = "test";
    r["agent"]         = { {"name", "test"}, {"version", "0.0.1"} };
    r["env"]           = { {"image", ""}, {"git_sha", ""}, {"git_branch", ""}, {"seed", 0} };
    r["system_prompt"] = { {"text", "you are an agent"}, {"hash", ""} };
    r["messages"] = json::array();
    {
        json m; m["source"] = "user"; m["message"] = body_text;
        m["timestamp"] = "2026-08-10T10:00:00Z";
        r["messages"].push_back(m);
    }
    {
        json m; m["source"] = "agent"; m["message"] = "ack " + body_text;
        m["timestamp"] = "2026-08-10T10:00:01Z";
        r["messages"].push_back(m);
    }
    r["final_metrics"] = {
        {"total_prompt_tokens", 0}, {"total_completion_tokens", 100},
        {"total_cached_tokens", 0}, {"total_cost_usd", 0.0},
        {"total_steps", 2}, {"n_user_turns", 1}, {"n_assistant_turns", 1},
        {"n_tool_calls", 0}, {"n_errors", 0}, {"n_recoveries", 0}
    };
    r["manifest"] = {
        {"captured_by", "test"}, {"captured_at", "2026-08-10T10:00:00Z"},
        {"harness", "test"}, {"schema_version", ts_traj::SCHEMA_V1}
    };
    return r.dump();
}

int main() {
    const std::string in_path  = "/tmp/test_traj_dedup_in.jsonl";
    const std::string out_path = "/tmp/test_traj_dedup_out.jsonl";
    const std::string log_path = "/tmp/test_traj_dedup_log.jsonl";

    // ---------------------------------------------------------------------
    // Build a small corpus: 1 unique, 2 exact dups, 1 near-dup, plus a
    // "bug" cluster that will trip the anomaly threshold.
    // ---------------------------------------------------------------------
    std::string body;
    body += make_traj("u-1", "task-A", "unique message about alpha\n") + "\n";
    body += make_traj("e-1", "task-B", "exact dup body beta\n") + "\n";
    body += make_traj("e-2", "task-B", "exact dup body beta\n") + "\n";  // tier-1 dup of e-1
    body += make_traj("n-1", "task-C", "this is a longish message about gamma with several words for the fuzzy shingler to chew on and produce a signature\n") + "\n";
    body += make_traj("n-2", "task-C", "this is a longish message about gamma with several words for the fuzzy shingler to chew on and produce a signature\n") + "\n";  // tier-2 dup of n-1
    body += make_traj("d-1", "task-D", "completely different content about delta task D run\n") + "\n";

    // Anomaly cluster: 5 records, all near-identical. Tier 2 will
    // collapse 4 of 5; the 1-removed/5-input = 20% rate does NOT
    // trip the default 35% anomaly. To force the trip, we need a
    // corpus where tier 1 (or tier 2) drops > 35%. The easiest is
    // to make MOST of the input exact dups of the same record. 10
    // copies of the same trajectory: tier 1 keeps 1, drops 9 -> 90%.
    // Use a separate input file for the anomaly test.
    write_file(in_path, body);

    // ---------------------------------------------------------------------
    // Run dedup with default config.
    // ---------------------------------------------------------------------
    {
        ts_traj_dedup::ts_dedup_params p;
        std::strncpy(p.input_path, in_path.c_str(), sizeof(p.input_path)-1);
        std::strncpy(p.output_path, out_path.c_str(), sizeof(p.output_path)-1);
        std::strncpy(p.log_path, log_path.c_str(), sizeof(p.log_path)-1);

        ts_traj_dedup::ts_dedup_result r;
        std::string em;
        int rc = ts_traj_dedup::ts_traj_dedup_run(&p, &r, &em);
        check_eq_int("dedup rc", rc, 0);
        check_eq_int("tier1 input",   r.tier1.n_input,   6);
        check_eq_int("tier1 removed", r.tier1.n_removed, 1);  // e-2 vs e-1
        check_eq_int("tier1 kept",    r.tier1.n_kept,    5);
        check_eq_int("tier2 input",   r.tier2.n_input,   5);
        check_eq_int("tier2 removed", r.tier2.n_removed, 1);  // n-2 vs n-1
        check_eq_int("tier2 kept",    r.tier2.n_kept,    4);
    }

    // Survivors: 4 records.
    {
        std::ifstream f(out_path);
        int n = 0;
        std::string line;
        while (std::getline(f, line)) if (!line.empty()) n++;
        check_eq_int("survivors count", n, 4);
    }

    // Schema-gate validates the survivors.
    {
        ts_traj::ts_traj_validation_result vr;
        std::string em;
        int rc = ts_traj::validate_file(out_path.c_str(), &vr, &em);
        check_eq_int("schema-gate rc on survivors", rc, 0);
        check_eq_int("schema-gate n_valid",   vr.n_valid,   4);
        check_eq_int("schema-gate n_invalid", vr.n_invalid, 0);
        check_eq_int("schema-gate n_skipped", vr.n_skipped, 0);
    }

    // Removal log: 2 entries (tier1 + tier2). The deferred-tier3 entry
    // is also written.
    {
        std::ifstream f(log_path);
        int n = 0;
        std::string line;
        while (std::getline(f, line)) if (!line.empty()) n++;
        check_eq_int("removal log lines", n, 3);  // tier1, tier2, deferred tier3
    }

    // ---------------------------------------------------------------------
    // Anomaly: 10 copies of the same trajectory -> tier 1 drops 9 of
    // 10 (90%) -> halt-on-anomaly exit 4.
    // ---------------------------------------------------------------------
    {
        const std::string anomaly_in = "/tmp/test_traj_dedup_anomaly_in.jsonl";
        const std::string anomaly_out = "/tmp/test_traj_dedup_anomaly_out.jsonl";
        const std::string anomaly_log = "/tmp/test_traj_dedup_anomaly_log.jsonl";
        std::string abody;
        for (int i = 0; i < 10; ++i) {
            abody += make_traj("a-" + std::to_string(i), "task-X", "anomaly body\n") + "\n";
        }
        write_file(anomaly_in, abody);

        ts_traj_dedup::ts_dedup_params p;
        std::strncpy(p.input_path,  anomaly_in.c_str(),  sizeof(p.input_path)-1);
        std::strncpy(p.output_path, anomaly_out.c_str(), sizeof(p.output_path)-1);
        std::strncpy(p.log_path,    anomaly_log.c_str(), sizeof(p.log_path)-1);
        p.anomaly_threshold = 0.35;

        ts_traj_dedup::ts_dedup_result r;
        std::string em;
        int rc = ts_traj_dedup::ts_traj_dedup_run(&p, &r, &em);
        check_eq_int("anomaly rc", rc, 4);
        check_eq_int("anomaly tier1 removed", r.tier1.n_removed, 9);
        check("anomaly tier1 n_anomaly set", r.tier1.n_anomaly == 1);
    }

    std::printf("\n%s\n", g_fail == 0 ? "all ok" : "FAILED");
    return g_fail == 0 ? 0 : 1;
}
