//
// tessera-traj-filter.cpp
//
// Apply the OT-Agent filters to a v1 trajectory corpus. The default
// filter is the multi-turn + outcome filter (>=5 assistant turns,
// verifier_outcome in {pass, partial}, not "timeout", minimum
// total_completion_tokens floor). Optional difficulty filter keeps
// the top-K% of teacher-token consumption (the OT-Agent signal).
//
// All filter decisions are written to filter_log.jsonl:
//   {kept_id, removed_id, reason, dropped_field, dropped_value}.
// The CLI prints the per-reason drop counts at the end of the run.
//

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

struct filter_params {
    int min_assistant_turns = 5;
    int min_completion_tokens = 50;
    bool drop_timeout = true;
    bool drop_fail = false;          // off by default; recovery trajectories matter
    bool drop_partial = false;       // off by default
    bool drop_error = true;
    int  difficulty_top_k_percent = 0; // 0 = off; otherwise keep top K% by completion_tokens
    char input_path[1024] = {0};
    char output_path[1024] = {0};
    char log_path[1024] = {0};
};

static void print_help(const char * argv0) {
    std::fprintf(stderr,
        "tessera-traj-filter - apply OT-Agent filters to a v1 trajectory corpus\n"
        "\n"
        "Usage: %s <input.jsonl> <output.jsonl> <filter_log.jsonl>\n"
        "        [ --min-assistant-turns N ]      (default 5)\n"
        "        [ --min-completion-tokens N ]   (default 50)\n"
        "        [ --keep-fail ]                 (default off; do not drop fail outcomes)\n"
        "        [ --keep-partial ]              (default off; do not drop partial outcomes)\n"
        "        [ --keep-timeout ]              (default off; do not drop timeout outcomes)\n"
        "        [ --keep-error ]                (default off; default drops error)\n"
        "        [ --difficulty-top-k-percent K ] (default 0 = off; otherwise keep top K%% by completion_tokens)\n",
        argv0);
}

int main(int argc, char ** argv) {
    if (argc < 4) {
        print_help(argv[0]);
        return argc == 1 ? 0 : 2;
    }
    filter_params p;
    std::strncpy(p.input_path,  argv[1], sizeof(p.input_path)  - 1);
    std::strncpy(p.output_path, argv[2], sizeof(p.output_path) - 1);
    std::strncpy(p.log_path,    argv[3], sizeof(p.log_path)    - 1);

    for (int i = 4; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](const char * flag) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "tessera-traj-filter: missing value for %s\n", flag);
                std::exit(2);
            }
            return std::string(argv[++i]);
        };
        if      (a == "--min-assistant-turns")    p.min_assistant_turns    = std::stoi(need(a));
        else if (a == "--min-completion-tokens")  p.min_completion_tokens  = std::stoi(need(a));
        else if (a == "--keep-fail")              p.drop_fail = false;
        else if (a == "--keep-partial")           p.drop_partial = false;
        else if (a == "--keep-timeout")           p.drop_timeout = false;
        else if (a == "--keep-error")             p.drop_error = false;
        else if (a == "--difficulty-top-k-percent")p.difficulty_top_k_percent = std::stoi(need(a));
        else {
            std::fprintf(stderr, "tessera-traj-filter: unknown flag %s\n", a.c_str());
            return 2;
        }
    }

    std::ifstream fin(p.input_path);
    if (!fin) {
        std::fprintf(stderr, "tessera-traj-filter: cannot open input %s\n", p.input_path);
        return 2;
    }
    std::ofstream fout(p.output_path, std::ios::binary);
    if (!fout) {
        std::fprintf(stderr, "tessera-traj-filter: cannot open output %s\n", p.output_path);
        return 2;
    }
    std::ofstream flog(p.log_path, std::ios::binary);
    if (!flog) {
        std::fprintf(stderr, "tessera-traj-filter: cannot open log %s\n", p.log_path);
        return 2;
    }

    int n_kept = 0, n_removed = 0, n_skipped = 0;
    int drop_turns = 0, drop_min_tokens = 0, drop_outcome = 0;
    std::vector<int> completion_tokens;
    std::vector<json> records;
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
        records.push_back(std::move(rec));
    }

    // First pass: per-record hard filters (turns, min tokens, outcome).
    std::vector<int> pass(records.size(), 0);
    for (size_t i = 0; i < records.size(); ++i) {
        const auto & r = records[i];
        int n_assist = r["final_metrics"].value("n_assistant_turns", 0);
        int tot_comp = r["final_metrics"].value("total_completion_tokens", 0);
        std::string outcome;
        if (r.contains("reward") && r["reward"].is_object()) {
            outcome = r["reward"].value("verifier_outcome", "");
        }
        std::string traj_id = r.value("trajectory_id", "");

        if (n_assist < p.min_assistant_turns) {
            drop_turns++;
            n_removed++;
            json e;
            e["kept_id"] = ""; e["removed_id"] = traj_id;
            e["reason"]  = "too_few_assistant_turns";
            e["dropped_field"]  = "final_metrics.n_assistant_turns";
            e["dropped_value"]  = n_assist;
            flog << e.dump() << "\n";
            continue;
        }
        if (tot_comp < p.min_completion_tokens) {
            drop_min_tokens++;
            n_removed++;
            json e;
            e["kept_id"] = ""; e["removed_id"] = traj_id;
            e["reason"]  = "below_min_completion_tokens";
            e["dropped_field"]  = "final_metrics.total_completion_tokens";
            e["dropped_value"]  = tot_comp;
            flog << e.dump() << "\n";
            continue;
        }
        if (outcome == "timeout" && p.drop_timeout) {
            drop_outcome++;
            n_removed++;
            json e;
            e["kept_id"] = ""; e["removed_id"] = traj_id;
            e["reason"]  = "outcome_timeout";
            e["dropped_field"]  = "reward.verifier_outcome";
            e["dropped_value"]  = outcome;
            flog << e.dump() << "\n";
            continue;
        }
        if (outcome == "error" && p.drop_error) {
            drop_outcome++;
            n_removed++;
            json e;
            e["kept_id"] = ""; e["removed_id"] = traj_id;
            e["reason"]  = "outcome_error";
            e["dropped_field"]  = "reward.verifier_outcome";
            e["dropped_value"]  = outcome;
            flog << e.dump() << "\n";
            continue;
        }
        if (outcome == "fail" && p.drop_fail) {
            drop_outcome++;
            n_removed++;
            json e;
            e["kept_id"] = ""; e["removed_id"] = traj_id;
            e["reason"]  = "outcome_fail";
            e["dropped_field"]  = "reward.verifier_outcome";
            e["dropped_value"]  = outcome;
            flog << e.dump() << "\n";
            continue;
        }
        if (outcome == "partial" && p.drop_partial) {
            drop_outcome++;
            n_removed++;
            json e;
            e["kept_id"] = ""; e["removed_id"] = traj_id;
            e["reason"]  = "outcome_partial";
            e["dropped_field"]  = "reward.verifier_outcome";
            e["dropped_value"]  = outcome;
            flog << e.dump() << "\n";
            continue;
        }
        pass[i] = 1;
        completion_tokens.push_back(tot_comp);
    }

    // Second pass: optional difficulty filter (top K% by completion_tokens).
    int n_after_hard = 0;
    for (int v : pass) if (v) n_after_hard++;

    std::vector<int> pass_after_diff = pass;
    int drop_diff = 0;
    if (p.difficulty_top_k_percent > 0 && n_after_hard > 0) {
        // Build (tokens, index) for records that passed hard filters.
        std::vector<std::pair<int, size_t>> idx;
        idx.reserve(n_after_hard);
        for (size_t i = 0; i < records.size(); ++i) {
            if (pass[i]) {
                idx.push_back({ records[i]["final_metrics"].value("total_completion_tokens", 0), i });
            }
        }
        std::sort(idx.begin(), idx.end(),
                  [](const std::pair<int, size_t> & a, const std::pair<int, size_t> & b) {
                      return a.first > b.first;  // desc
                  });
        int cutoff = (int)((double)p.difficulty_top_k_percent / 100.0 * n_after_hard);
        if (cutoff < 1 && p.difficulty_top_k_percent > 0) cutoff = 1;
        for (size_t k = 0; k < idx.size(); ++k) {
            if ((int)k >= cutoff) {
                pass_after_diff[idx[k].second] = 0;
                drop_diff++;
                n_removed++;
                std::string traj_id = records[idx[k].second].value("trajectory_id", "");
                json e;
                e["kept_id"] = ""; e["removed_id"] = traj_id;
                e["reason"]  = "below_difficulty_threshold";
                e["dropped_field"]  = "final_metrics.total_completion_tokens";
                e["dropped_value"]  = idx[k].first;
                flog << e.dump() << "\n";
            }
        }
    }

    // Write survivors.
    for (size_t i = 0; i < records.size(); ++i) {
        if (pass_after_diff[i]) {
            fout << records[i].dump() << "\n";
            n_kept++;
        }
    }

    std::printf("kept=%d removed=%d skipped=%d drop_turns=%d drop_min_tokens=%d drop_outcome=%d drop_difficulty=%d\n",
                n_kept, n_removed, n_skipped,
                drop_turns, drop_min_tokens, drop_outcome, drop_diff);
    return 0;
}
