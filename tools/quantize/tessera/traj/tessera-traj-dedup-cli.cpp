//
// tessera-traj-dedup-cli.cpp
//
// CLI wrapper for the three-tier dedup. Reads a v1 trajectory JSONL,
// runs tier 1 (exact SHA-256) and tier 2 (MinHash+LSH fuzzy), and
// emits a survivors file plus a removal log. Tier 3 (semantic) is
// off by default; pass --with-semantic to enable once an embedder
// is wired. Halt on anomaly: if any tier removes more than
// --anomaly-threshold (default 35%) of its input, exit code 4.
//

#include "tessera-traj-dedup.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static void print_help(const char * argv0) {
    std::fprintf(stderr,
        "tessera-traj-dedup - three-tier dedup for v1 trajectory records\n"
        "\n"
        "Usage: %s --input <in.jsonl> --output <out.jsonl> --log <dedup_log.jsonl>\n"
        "        [ --jaccard-threshold J ]   (default %.2f)\n"
        "        [ --num-perm N ]            (default %d)\n"
        "        [ --num-bands B ]           (default %d)\n"
        "        [ --minhashes-per-band M ]  (default %d)\n"
        "        [ --anomaly-threshold A ]   (default %.2f; 0..1)\n"
        "        [ --with-semantic ]         (off; requires on-device embedder)\n",
        argv0, ts_traj_dedup::JACCARD_THRESHOLD, ts_traj_dedup::NUM_PERM,
        ts_traj_dedup::NUM_BANDS, ts_traj_dedup::MINHASHES_PER_BAND,
        ts_traj_dedup::ANOMALY_THRESHOLD);
}

int main(int argc, char ** argv) {
    ts_traj_dedup::ts_dedup_params p;
    ts_traj_dedup::ts_traj_dedup_default_params(&p);
    p.input_path[0]  = 0;
    p.output_path[0] = 0;
    p.log_path[0]    = 0;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](std::string flag) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "tessera-traj-dedup: missing value for %s\n", flag.c_str());
                std::exit(2);
            }
            return std::string(argv[++i]);
        };
        if      (a == "-h" || a == "--help") { print_help(argv[0]); return 0; }
        else if (a == "--input")  { std::string v = need(a); std::strncpy(p.input_path, v.c_str(), sizeof(p.input_path)-1); }
        else if (a == "--output") { std::string v = need(a); std::strncpy(p.output_path, v.c_str(), sizeof(p.output_path)-1); }
        else if (a == "--log")    { std::string v = need(a); std::strncpy(p.log_path, v.c_str(), sizeof(p.log_path)-1); }
        else if (a == "--jaccard-threshold")    p.jaccard_threshold = std::stod(need(a));
        else if (a == "--num-perm")             p.num_perm = std::stoi(need(a));
        else if (a == "--num-bands")            p.num_bands = std::stoi(need(a));
        else if (a == "--minhashes-per-band")   p.minhashes_per_band = std::stoi(need(a));
        else if (a == "--anomaly-threshold")    p.anomaly_threshold = std::stod(need(a));
        else if (a == "--with-semantic")        p.run_tier3_semantic = true;
        else {
            std::fprintf(stderr, "tessera-traj-dedup: unknown flag %s\n", a.c_str());
            return 2;
        }
    }
    if (p.input_path[0] == 0 || p.output_path[0] == 0 || p.log_path[0] == 0) {
        print_help(argv[0]);
        return 2;
    }

    ts_traj_dedup::ts_dedup_result result;
    std::string err;
    int rc = ts_traj_dedup::ts_traj_dedup_run(&p, &result, &err);
    if (rc == 4) {
        std::fprintf(stderr,
            "tessera-traj-dedup: HALT-ON-ANOMALY: %s\n"
            "  tier1: input=%d removed=%d (threshold=%.2f)\n"
            "  tier2: input=%d removed=%d (threshold=%.2f)\n"
            "  tier3: input=%d removed=%d\n",
            err.c_str(),
            result.tier1.n_input, result.tier1.n_removed, p.anomaly_threshold,
            result.tier2.n_input, result.tier2.n_removed, p.anomaly_threshold,
            result.tier3.n_input, result.tier3.n_removed);
        return 4;
    }
    if (rc != 0) {
        std::fprintf(stderr, "tessera-traj-dedup: %s\n", err.c_str());
        return rc < 0 ? 2 : rc;
    }
    std::printf("tier1: input=%d removed=%d kept=%d\n"
                "tier2: input=%d removed=%d kept=%d\n"
                "tier3: input=%d removed=%d kept=%d (semantic %s)\n",
                result.tier1.n_input, result.tier1.n_removed, result.tier1.n_kept,
                result.tier2.n_input, result.tier2.n_removed, result.tier2.n_kept,
                result.tier3.n_input, result.tier3.n_removed, result.tier3.n_kept,
                p.run_tier3_semantic ? "on" : "off");
    return 0;
}
