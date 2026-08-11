//
// tessera-traj-dedup.h
//
// Three-tier deduplication for v1 trajectory records (NeMo Curator
// playbook, see docs/agentic-training-data-flywheel-design.md Stage 3).
//
// Tier 1 - exact dedup
//   SHA-256 over the normalized (system_prompt.text, joined assistant
//   and user message content) of the trajectory. Byte-identical
//   trajectories collide; the first seen is kept, the rest are removed.
//
// Tier 2 - fuzzy dedup (MinHash + LSH)
//   Shingle messages into 5-grams (whitespace-tokenized, lowercased).
//   Compute MinHash with NUM_PERM permutations, band at
//   NUM_BANDS bands with MINHASHES_PER_BAND hashes per band. Pairs above
//   JACCARD_THRESHOLD are duplicates. The first seen wins.
//
// Tier 3 - semantic dedup
//   Deferred. Requires an on-device embedding model (Apple Silicon ANE /
//   Metal). Hooked in as a stub in this wave; the threshold is 0.87
//   cosine. See docs/agentic-training-data-flywheel-design.md Stage 3.
//
// Halt on anomaly: if any tier removes more than ANOMALY_THRESHOLD
// (default 35%) of input, the run exits with code 4 and the per-tier
// removal distribution is printed; this is the "threshold is too loose"
// signal, not a "dedup is done" success. The threshold is configurable.
//
// Pure logic: no llama/ggml dependency. The dedup_log.jsonl sidecar is
// one record per removal: {kept_id, removed_id, tier, similarity, reason}.
//

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ts_traj_dedup {

// Default MinHash configuration. Matches the design doc's stated
// band/hash count: 20 bands * 13 hashes per band = 260 permutations.
// LSH inflection is at Jaccard J where J^13 = 0.5 -> J ~= 0.949, so
// collisions become likely only above ~0.85 Jaccard and very likely
// above ~0.92. This is the right shape for the "fuzzy" tier: we want
// to catch true near-duplicates (>=0.85 body overlap) and not waste
// budget on loose overlaps. JACCARD_THRESHOLD below keeps a safety
// margin under the inflection.
constexpr int    NUM_PERM             = 260;
constexpr int    NUM_BANDS            = 20;
constexpr int    MINHASHES_PER_BAND   = 13;
constexpr double JACCARD_THRESHOLD    = 0.8;

// Default halt-on-anomaly threshold. If any tier removes more than
// this fraction of input, the run is considered a threshold bug and
// returns non-zero.
constexpr double ANOMALY_THRESHOLD    = 0.35;

// Per-tier counts. n_kept is the survivors at the end of the tier;
// n_removed is the number of trajectories removed in this tier.
struct ts_tier_stats {
    int n_input    = 0;
    int n_kept     = 0;
    int n_removed  = 0;
    int n_anomaly  = 0;  // 1 if the tier tripped ANOMALY_THRESHOLD
};

struct ts_dedup_params {
    char input_path[1024];
    char output_path[1024];        // kept records (one per line)
    char log_path[1024];           // removal log JSONL
    int  num_perm            = NUM_PERM;
    int  num_bands           = NUM_BANDS;
    int  minhashes_per_band  = MINHASHES_PER_BAND;
    double jaccard_threshold = JACCARD_THRESHOLD;
    double anomaly_threshold = ANOMALY_THRESHOLD;
    bool   run_tier3_semantic = false;  // off until an embedder is wired
};

struct ts_dedup_result {
    ts_tier_stats tier1;
    ts_tier_stats tier2;
    ts_tier_stats tier3;        // always zero unless run_tier3_semantic
};

// Initialize params with sane defaults.
void ts_traj_dedup_default_params(ts_dedup_params * p);

// Run the three-tier dedup. Returns 0 on success; 4 on halt-on-anomaly
// (a tier removed more than anomaly_threshold of its input); non-zero
// on I/O error. *result is populated with per-tier stats.
int ts_traj_dedup_run(const ts_dedup_params * params,
                      ts_dedup_result * result,
                      std::string * err_msg);

}  // namespace ts_traj_dedup
