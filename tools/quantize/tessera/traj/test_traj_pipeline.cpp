//
// test_traj_pipeline.cpp
//
// End-to-end smoke test: build a small v1 trajectory corpus, run
// validate -> dedup -> filter -> split -> manifest, and assert
// every stage passes. Tests the *wiring* (file paths, schema gates,
// halt-on-anomaly safety) rather than the per-stage logic, which
// each stage's own test covers in detail.
//
// Run: ./test_traj_pipeline
//

#include "tessera-trajectory.h"
#include "tessera-traj-dedup.h"

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
    std::ofstream f(path, std::ios::binary); f << body;
}

static std::string read_file(const std::string & path) {
    std::ifstream f(path, std::ios::binary);
    std::ostringstream os; os << f.rdbuf(); return os.str();
}

static int run(const std::string & cmd, std::string * out) {
    std::string full = cmd + " 2>&1";
    FILE * p = popen(full.c_str(), "r");
    if (!p) return -1;
    char buf[4096]; std::string acc;
    while (fgets(buf, sizeof(buf), p)) acc += buf;
    int rc = pclose(p);
    if (WIFEXITED(rc)) rc = WEXITSTATUS(rc);
    if (out) *out = acc;
    return rc;
}

int main() {
    const std::string in_path   = "/tmp/test_pipe_in.jsonl";
    const std::string valid_p   = "/tmp/test_pipe_valid.jsonl";
    const std::string dedup_p   = "/tmp/test_pipe_dedup.jsonl";
    const std::string log_p     = "/tmp/test_pipe_dedup_log.jsonl";
    const std::string filter_p  = "/tmp/test_pipe_filter.jsonl";
    const std::string filter_log_p = "/tmp/test_pipe_filter_log.jsonl";
    const std::string train_p   = "/tmp/test_pipe_train.jsonl";
    const std::string eval_p    = "/tmp/test_pipe_eval.jsonl";
    const std::string train_man = "/tmp/test_pipe_train.manifest.json";
    const std::string eval_man  = "/tmp/test_pipe_eval.manifest.json";

    // ---------------------------------------------------------------------
    // Build a small corpus: 3 tasks, each with 2 trajectories (so
    // the train/eval split has work to do). One trajectory is a
    // near-duplicate of another to exercise tier-2.
    // ---------------------------------------------------------------------
    auto mk = [](const std::string & tid, const std::string & task_id,
                 const std::string & body, int n_turns, const std::string & outcome) {
        json r;
        r["schema"]        = ts_traj::SCHEMA_V1;
        r["trajectory_id"] = tid;
        r["session_id"]    = "sess-pipe";
        r["task_id"]       = task_id;
        r["task_source"]   = "test";
        r["agent"]         = { {"name", "test"}, {"version", "0.0.1"} };
        r["env"]           = { {"image", ""}, {"git_sha", ""}, {"git_branch", ""}, {"seed", 0} };
        r["system_prompt"] = { {"text", "you are an agent"}, {"hash", ""} };
        r["messages"] = json::array();
        for (int i = 0; i < n_turns; ++i) {
            json m;
            m["source"]  = (i == 0) ? "user" : "agent";
            // The body lives in the user message only. Agent turns are
            // short, body-independent, and unique per turn - mirroring
            // a realistic agent loop where the assistant takes a
            // different action each turn. The previous version
            // ("ack " + body + " turn N") repeated the body 6x and
            // crushed the LSH shingle Jaccard from 0.97 to 0.65
            // (each repetition added 6 new boundary 5-grams).
            m["message"]   = (i == 0) ? body
                                    : ("agent turn " + std::to_string(i) + " response ack");
            m["step_id"]   = i + 1;
            m["timestamp"] = "2026-08-10T10:00:0" + std::to_string(i) + "Z";
            r["messages"].push_back(m);
        }
        r["final_metrics"] = {
            {"total_prompt_tokens", 0}, {"total_completion_tokens", 200},
            {"total_cached_tokens", 0}, {"total_cost_usd", 0.0},
            {"total_steps", n_turns},
            {"n_user_turns", 1}, {"n_assistant_turns", n_turns - 1},
            {"n_tool_calls", 0}, {"n_errors", 0}, {"n_recoveries", 0}
        };
        r["reward"] = {
            {"verifier", "test"},
            {"verifier_outcome", outcome},
            {"verifier_partial", outcome == "pass" ? 1.0 : 0.5}
        };
        r["manifest"] = {
            {"captured_by", "test"}, {"captured_at", "2026-08-10T10:00:00Z"},
            {"harness", "test"}, {"schema_version", ts_traj::SCHEMA_V1}
        };
        return r.dump();
    };

    // Each near-dup pair (t1/t2, t3/t4, t5/t6) uses a long body so
    // appending " with extra detail" at the end keeps shingle
    // Jaccard well above the 0.8 tier-2 threshold. The other four
    // records are unique short bodies.
    const std::string t1_body =
        "this is a longish message about alpha with several words for the fuzzy shingler to chew on and produce a unique signature on this fine day of the year today we test things and produce a great result on this fine day and the rest of the day is also fine because we are testing the fuzzy dedup and we want to see if the shingles overlap enough to trigger the minhash lsh banding for near duplicate detection at a high enough jaccard threshold to be useful";
    const std::string t3_body =
        "another long message about beta that goes on for a while with enough content to make 5-gram shingles overlap meaningfully with a near-duplicate that appends a small extra phrase at the very end of the body to test the append-at-end pattern for the LSH fuzzy dedup tier to confirm the shingle jaccard stays well above the inflection point";
    const std::string t5_body =
        "yet another long message about gamma content with many words and phrases to make the 5-gram shingler produce a stable signature for near duplicate detection using the append-at-end pattern that we know keeps the shingle jaccard above the threshold for the LSH banding to fire and catch the near duplicate pair reliably";
    std::string body;
    body += mk("t1", "task-A", t1_body,                                            7, "pass") + "\n";
    body += mk("t2", "task-A", t1_body + " with extra detail",                     7, "pass") + "\n";  // tier-2 near-dup of t1
    body += mk("t3", "task-B", t3_body,                                            7, "pass") + "\n";
    body += mk("t4", "task-B", t3_body + " with extra detail",                     7, "pass") + "\n";  // tier-2 near-dup of t3
    body += mk("t5", "task-C", t5_body,                                            7, "pass") + "\n";
    body += mk("t6", "task-C", t5_body + " with extra detail",                     7, "pass") + "\n";  // tier-2 near-dup of t5
    body += mk("t7", "task-D", "completely unique short body for task D trajectory", 7, "pass") + "\n";
    body += mk("t8", "task-E", "unique short body for task E trajectory only",     4, "pass") + "\n";  // 4 turns: filtered
    body += mk("t9", "task-F", "unique short body for task F trajectory only",     6, "fail") + "\n";  // 6 turns, fail: kept (default)
    body += mk("ta", "task-G", "unique short body for task G trajectory only",     7, "pass") + "\n";
    write_file(in_path, body);

    // ---------------------------------------------------------------------
    // Stage 2: validate.
    // ---------------------------------------------------------------------
    {
        std::string out;
        int rc = run("tessera-traj-validate " + in_path, &out);
        check_eq_int("validate rc", rc, 0);
        check("validate says valid=10", out.find("valid=10") != std::string::npos);
    }
    // Copy the validated file forward (CLI writes the same JSONL on
    // stdout summary only, so we just continue with the same path).
    {
        std::ifstream f(in_path, std::ios::binary);
        std::ofstream g(valid_p, std::ios::binary);
        g << f.rdbuf();
    }

    // ---------------------------------------------------------------------
    // Stage 3: dedup. We expect 3 tier-2 removals (t2/t4/t6).
    // ---------------------------------------------------------------------
    {
        std::string out;
        int rc = run("tessera-traj-dedup --input " + valid_p +
                     " --output " + dedup_p + " --log " + log_p, &out);
        check_eq_int("dedup rc", rc, 0);
        check("dedup says tier1 removed=0", out.find("tier1: input=10 removed=0") != std::string::npos);
        check("dedup says tier2 removed=3", out.find("tier2: input=10 removed=3") != std::string::npos);
    }

    // Schema-gate validates the survivors.
    {
        ts_traj::ts_traj_validation_result vr;
        std::string em;
        ts_traj::validate_file(dedup_p.c_str(), &vr, &em);
        check_eq_int("dedup survivors n_valid",   vr.n_valid,   7);
        check_eq_int("dedup survivors n_invalid", vr.n_invalid, 0);
    }

    // ---------------------------------------------------------------------
    // Stage 4: scrub. Wraps tessera-anonymizer + tessera-scrub; reuses
    // the existing egress privacy tools in light-touch mode for the
    // pipeline test (we're not asserting on the exact redaction here -
    // just that the stage runs, doesn't drop records, and the output
    // still passes the schema gate).
    // ---------------------------------------------------------------------
    const std::string scrub_p = "/tmp/test_pipe_scrub.jsonl";
    {
        std::string out;
        int rc = run("tessera-traj-scrub " + dedup_p + " " + scrub_p + " balanced", &out);
        check_eq_int("scrub rc", rc, 0);
        check("scrub ran", out.find("scrubbed") != std::string::npos);
    }
    {
        ts_traj::ts_traj_validation_result vr;
        std::string em;
        ts_traj::validate_file(scrub_p.c_str(), &vr, &em);
        check_eq_int("scrub survivors n_valid",   vr.n_valid,   7);
        check_eq_int("scrub survivors n_invalid", vr.n_invalid, 0);
    }

    // ---------------------------------------------------------------------
    // Stage 5: filter. With --min-assistant-turns 5 and a 4-turn record
    // (t8), we drop 1 (t8). t9 (fail) is kept by default.
    // ---------------------------------------------------------------------
    {
        std::string out;
        int rc = run("tessera-traj-filter " + scrub_p + " " + filter_p + " " + filter_log_p, &out);
        check_eq_int("filter rc", rc, 0);
        check("filter kept=6", out.find("kept=6") != std::string::npos);
        check("filter drop_turns=1", out.find("drop_turns=1") != std::string::npos);
    }

    // ---------------------------------------------------------------------
    // Stage 6: split. 7 -> maybe 6/1 or 5/2 depending on the bucket.
    // Manifest is emitted.
    // ---------------------------------------------------------------------
    {
        std::string out;
        int rc = run("tessera-traj-split " + filter_p + " " + train_p + " " + eval_p + " 5", &out);
        check_eq_int("split rc", rc, 0);
        // The manifest is the only stdout line; verify it parses and
        // has the right shape.
        json m;
        try { m = json::parse(out); } catch (...) { m = json::object(); }
        check("split manifest is JSON", m.is_object());
        check_eq_int("split manifest n_train + n_eval = 6",
                     m.value("n_train", 0) + m.value("n_eval", 0), 6);
        check("split manifest has manifest_hash", !m.value("manifest_hash", "").empty());
    }

    // ---------------------------------------------------------------------
    // Stage 10: manifest emit + verify.
    // ---------------------------------------------------------------------
    {
        std::string out;
        int rc = run("tessera-traj-manifest emit "
                     "--stage dedup --input " + valid_p + " --output " + dedup_p +
                     " --manifest-out " + std::string(dedup_p) + ".manifest.json", &out);
        check_eq_int("manifest emit rc", rc, 0);
        std::string m_path = dedup_p + ".manifest.json";
        std::ifstream mf(m_path);
        std::stringstream mb; mb << mf.rdbuf();
        json m; try { m = json::parse(mb.str()); } catch (...) { m = json::object(); }
        check("manifest schema_version",
            std::string(m.value("schema_version", "")) == "tessera.dataset-manifest.v1");
        check("manifest stage", m.value("stage", "") == "dedup");

        // verify round-trip
        std::string vout;
        int vrc = run("tessera-traj-manifest verify --manifest " + m_path, &vout);
        check_eq_int("manifest verify rc", vrc, 0);
        check("manifest verify ok", vout.find("manifest ok") != std::string::npos);
    }

    std::printf("\n%s\n", g_fail == 0 ? "all ok" : "FAILED");
    return g_fail == 0 ? 0 : 1;
}
