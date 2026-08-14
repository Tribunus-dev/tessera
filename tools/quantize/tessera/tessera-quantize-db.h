#pragma once

//
// tessera-quantize-db.h
//
// DuckDB-backed persistent store for the Tessera quantize pipeline.
//
// The quantize pipeline has historically been ephemeral: every run starts the
// GA from scratch, family warm-start lives only in process memory, and the
// only durable artifact is a flat policy JSON. ts_tessera_db wraps a DuckDB
// connection so the pipeline can:
//   - record one row per run, tensor, GA result, and acceptance comparison
//   - stream per-candidate GA evaluations to disk via the Appender API
//   - reload family-optimal alpha/clip on restart to warm-start the GA
//   - skip tensors that already converged in a prior (interrupted) run
//
// The whole store is optional: when the dispatch is constructed with a null
// ts_tessera_db*, every method is a no-op (guarded by the caller's null
// check). This keeps the existing ephemeral path unchanged.
//
// DuckDB's C++ API throws on errors; this wrapper catches and reports via the
// out `err` parameter, returning non-zero. The dispatch treats a DB error as
// non-fatal (logs + continues) so a corrupt DB never blocks quantization.
//

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Forward declaration so the public header does not require duckdb.hpp.
// (The .cpp includes the amalgamation; translation units that only need the
// API surface stay clean of DuckDB's 2 MB header.)
namespace duckdb { class DuckDB; class Connection; }

struct ts_tessera_db {
    std::unique_ptr<duckdb::DuckDB>     db;
    std::unique_ptr<duckdb::Connection> conn;
    // Phase 16.7: stores the on-disk path passed to
    // ts_tessera_db_open (or "" for ":memory:"). Used by
    // ts_tessera_db_migrate_model_role to write the
    // model_role_migration.json sidecar next to the duckdb
    // file. The C++ struct used to discard the path; the
    // sidecar needs it.
    std::string                        db_path;
    // Phase 2 (eval cache): ts_expert_eval is called from the acceptance
    // panel's concurrent worker pool (and, once the GA converts, from
    // parallel candidate evaluation too). DuckDB's Connection is not
    // documented safe for concurrent Query() calls from multiple threads;
    // every eval_cache read/write serializes through this mutex. The
    // expensive work (the actual REAL-tier computation on a cache miss)
    // happens OUTSIDE the lock -- only the cache lookup/store itself is
    // serialized, mirroring the "lock-sharded or append-buffered" guidance
    // in the contracts appendix (a single shard, since eval_cache ops are
    // individually fast SQL statements).
    std::mutex                         eval_cache_mutex;

    ts_tessera_db() = default;
    ~ts_tessera_db();
};

// Schema-owner helper (pipeline refactor phase 2): returns the ordered
// column-name list for `table_name` by querying the LIVE database (post-
// migration), not by parsing the CREATE TABLE string -- l5_outcome's
// kurtosis/eff_rank/layer_position columns exist ONLY via an ALTER TABLE
// migration and never appear in the schema string, so a parser over the
// DDL would silently miss them. This is what kills the l4_cols drift
// class: buffer/appender column lists generated (or asserted against)
// from this instead of hand-copied stay in sync with the table by
// construction. Returns 0 on success (*out may be empty if the table does
// not exist -- not itself an error); non-zero only on a real SQL error.
int ts_tessera_db_table_columns(
        ts_tessera_db * db,
        const std::string & table_name,
        std::vector<std::string> * out,
        std::string * err);

// Compares `expected` (a caller's hardcoded ts_db_buffer_open column list)
// against the live schema for `table_name`. Returns true when they match
// exactly (size and order) OR when the check itself could not run (db ==
// nullptr, or a SQL error -- an unrelated DB problem should not block the
// run over a check that could not complete; *mismatch is left empty in
// both the "matched" and the "could not check" cases). Returns false only
// on a confirmed drift, with *mismatch set to a human-readable summary
// naming exactly what differs -- this is the check that turns the l4_cols
// bug class (a migration added a column to the struct/shim/table but not
// the buffer's column list, so every flush silently misaligned values
// against the wrong columns and dropped the whole batch) into a loud,
// immediate, specific failure instead of a silent one.
bool ts_tessera_db_check_buffer_columns(
        ts_tessera_db * db,
        const std::string & table_name,
        const std::vector<std::string> & expected,
        std::string * mismatch);

// Open (or create) the database at `path` and ensure the schema exists.
// Returns nullptr on failure (message in *err). An in-memory DB (":memory:")
// is supported for tests.
ts_tessera_db * ts_tessera_db_open(const std::string & path,
                                     std::string * err);

// Run-lifecycle hooks. begin_run inserts a new row and returns the run_id
// (a hash of model_hash + config + timestamp). complete_run / fail_run flip
// the status. The run_id is reused across all per-tensor inserts.
std::string ts_tessera_db_begin_run(ts_tessera_db * db,
                                     const std::string & model_path,
                                     const std::string & model_hash,
                                     const std::string & tessera_commit,
                                     const std::string & config_json,
                                     std::string * err);
int ts_tessera_db_complete_run(ts_tessera_db * db,
                                const std::string & run_id,
                                const std::string & status,   // "completed" / "failed"
                                std::string * err);

// Tensor registry. One row per quantizable 2D/3D weight, captured during the
// ga-prep walk. layer_depth is the block index (0 for non-block tensors).
struct ts_tessera_db_tensor {
    std::string  run_id;
    std::string  name;
    std::string  family;
    int32_t      layer_depth = 0;
    int64_t      out_dim     = 0;
    int64_t      in_dim      = 0;
    int64_t      n_elements  = 0;
    float        kurtosis    = 0.0f;
    float        eff_rank    = 0.0f;
    std::string  source_type;   // "f16", "f32", "q8_0", ...
};
int ts_tessera_db_insert_tensor(ts_tessera_db * db,
                                 const ts_tessera_db_tensor & t,
                                 std::string * err);

// GA results. One row per converged tensor (the summary). Re-inserting a
// (run_id, tensor_name) pair replaces the row (PRIMARY KEY conflict -> upsert).
struct ts_tessera_db_ga_result {
    std::string  run_id;
    std::string  tensor_name;
    std::string  family;
    float        best_alpha   = 0.0f;
    float        best_clip    = 0.0f;
    float        best_composite = 0.0f;
    float        best_mse     = 0.0f;
    int32_t      generations_run = 0;
    int64_t      n_evaluations    = 0;
    bool         converged   = false;
    bool         warm_started   = false;
};
int ts_tessera_db_insert_ga_result(ts_tessera_db * db,
                                    const ts_tessera_db_ga_result & r,
                                    std::string * err);

// Acceptance-gate comparison row (one per tensor).
struct ts_tessera_db_acceptance {
    std::string  run_id;
    std::string  tensor_name;
    std::string  family;
    float        composite_t2 = 0.0f;
    float        awq_t2       = 0.0f;
    float        rotation_t2  = 0.0f;
    float        lowrank_t2   = 0.0f;
    float        hessian_t2   = 0.0f;
    std::string  verdict;        // "pass" / "fail"
};
int ts_tessera_db_insert_acceptance(ts_tessera_db * db,
                                     const ts_tessera_db_acceptance & a,
                                     std::string * err);

// L5 adaptive requantize fixup row.
struct ts_tessera_db_l5_fixup {
    std::string  run_id;
    std::string  tensor_name;
    int32_t      generation   = 0;
    std::string  strategy;       // "A" (alpha/clip) or "B" (outlier)
    float        before_frob   = 0.0f;
    float        after_frob    = 0.0f;
};
int ts_tessera_db_insert_l5_fixup(ts_tessera_db * db,
                                   const ts_tessera_db_l5_fixup & f,
                                   std::string * err);

// --- tensor_stats upsert (cross-pipeline feature table) ---
//
// One row per (model_hash, name). The C++ GA-prep walk writes
// kurtosis / eff_rank / dtype here (alongside the legacy `tensors`
// per-run table); the Python calibration pipeline writes
// rms / mean_abs / tail_ratio. PRIMARY KEY (model_hash, name) +
// ON CONFLICT DO UPDATE makes this an upsert target.
//
// The `source` field records which pipeline last wrote the row
// ("cpp_quant" for the C++ side, "py_cal" for Python). It is
// informational; the upsert overwrites regardless.
//
// `recommended_action` is the per-tensor verdict produced by the
// calibration side (see tools/tessera/l5_action.py). It is a
// derived string ("protect" / "requant_up" / "requant_down" /
// "monitor" / "noop") that summarizes how the calibration pipeline
// should treat this tensor given the orchestrator's feedback
// (miscalibration_score, hit_rate, plan_accepted, delta_mse) for
// its (model, family). The C++ side does not write this field;
// the Python calibration_to_tensor_stats.py upserts it from
// l5_weights via the rules in l5_action.py. The COALESCE
// preservation in the upsert makes this a one-way Python write
// without disturbing the C++ side's other columns.
// Pipeline refactor phase 2, "Layer A": bumped whenever the meaning or
// computation of frob2/absq_sketch changes, so a reader can tell a
// pre-Layer-A row (stats_version 0, both fields absent) from a stale
// producer apart from a current one without inspecting the values.
#define TS_TENSOR_STATS_VERSION 1

struct ts_tessera_db_tensor_stat {
    std::string  model_hash;
    std::string  model_role;   // Phase 16: "trunk" / "dflash" / "dspark" /
                               // "mtp_nextn" / "shared_embd". Disambiguates
                               // tensors with the same name in the unified
                               // Gemma4 12B + dspark + dflash + MTP arch
                               // (e.g. "blk.0.attn_q.weight" exists in both
                               // the trunk and the dflash encoder). Default
                               // "trunk" preserves the pre-Phase-16 contract.
    std::string  name;
    std::string  family;
    int32_t      layer_depth = 0;
    int64_t      out_dim     = 0;
    int64_t      in_dim      = 0;
    int64_t      n_elements  = 0;
    std::string  dtype;       // "f16", "f32", "q8_0", ...
    double       kurtosis    = 0.0;
    double       eff_rank    = 0.0;
    double       rms         = 0.0;
    double       mean_abs    = 0.0;
    double       tail_ratio  = 0.0;
    std::string  source;      // "cpp_quant" / "py_cal"
    std::string  recommended_action;  // "protect" / "requant_up" /
                                      // "requant_down" / "monitor" / "noop"
                                      // (Python-side only; default empty)
    // Phase 2 "Layer A": producer is the dispatch's GA-prep walk (the same
    // loop that already materializes the full f32 weight buffer to compute
    // kurtosis/eff_rank above -- frob2/absq_sketch ride the same pass at
    // no extra I/O cost). frob2 = ||W||_F^2 (sum of squared weights).
    double       frob2         = 0.0;
    // ~1024-point ascending sketch of |W|, for interpolated quantile
    // lookups (see ts_tensor_stats_sketch_quantile below). Built from a
    // bounded deterministic sample, not a full sort -- an approximation,
    // not exact order statistics (see ts_tensor_stats_build_absq_sketch).
    std::vector<float> absq_sketch;
    // TS_TENSOR_STATS_VERSION at write time. 0 (the struct default) means
    // "row predates Layer A" -- frob2/absq_sketch are not populated and
    // readers must fall back to recomputing from raw weights.
    int32_t      stats_version = 0;
};
int ts_tessera_db_upsert_tensor_stat(ts_tessera_db * db,
                                     const ts_tessera_db_tensor_stat & row,
                                     std::string * err);

// Single-row keyed read for a tensor_stats row (model_hash, model_role,
// name) -- every column, including the Layer A additions. hit=false with
// return 0 means "no row for this key" (not an error, matches
// ts_tessera_db_read_eval_cache's contract); callers fall back to
// recomputing frob2/thresholds from raw weights. db == nullptr is a safe
// no-op (hit=false, return 0).
int ts_tessera_db_read_tensor_stat(
    ts_tessera_db * db,
    const std::string & model_hash,
    const std::string & model_role,
    const std::string & name,
    ts_tessera_db_tensor_stat * out,
    bool * hit,
    std::string * err);

// Builds an ascending sketch of |w| (up to max_points entries) by taking a
// bounded deterministic-stride sample (at most sample_cap elements, not
// the full n) and sorting the sample. This is O(n) (the stride pass) +
// O(sample log sample), NOT O(n log n) -- a full sort of a multi-million-
// element tensor inside the dispatch's per-tensor walk is a real
// wall-clock risk this pipeline has already stalled on once (the
// unaccelerated Jacobi eigensolver, see tessera-linalg.cpp); the sketch is
// an intentional approximation of the quantile function, not an exact
// order statistic. n <= 0 clears *out.
void ts_tensor_stats_build_absq_sketch(
    const float * w, int64_t n, std::vector<float> * out,
    int64_t max_points = 1024, int64_t sample_cap = 65536);

// Interpolated quantile lookup into a sketch built by the function above.
// q is clamped to [0, 1]; q=0 returns the sketch minimum, q=1 the sketch
// maximum. Returns 0.0f for an empty sketch.
float ts_tensor_stats_sketch_quantile(const std::vector<float> & sketch, float q);

// --- Per-component qtype reader (Phase 16 unified writer) ---
//
// The unified Gemma4 12B + dspark + dflash + MTP arch shares tensor
// names across components. The per-tensor qtype the writer needs is
// keyed on (model_hash, model_role, name). The reader pulls every
// tensor_stats row for a model (or a single role) so the writer can
// pick the right qtype for each component tensor in a single round
// trip.
//
// Empty `role` returns all roles. Rows are returned in
// (model_role, name) order so the writer's per-component scan is
// cache-friendly. dtype is the per-tensor qtype the calibration
// pipeline recommended (or "f16" / "f32" for the no-quantize
// passthrough); the writer filters on this when assigning qtypes to
// gemma4-assistant tensor slots.
struct ts_tessera_db_unified_policy_entry {
    std::string  model_role;
    std::string  name;
    std::string  family;
    std::string  dtype;
    std::string  source;
    std::string  recommended_action;
};
struct ts_tessera_db_unified_policy {
    std::vector<ts_tessera_db_unified_policy_entry> entries;
};
int ts_tessera_db_read_unified_policy(
    ts_tessera_db * db,
    const std::string & model_hash,
    const std::string & role,    // empty = all roles
    ts_tessera_db_unified_policy * out,
    std::string * err);

// --- Phase 16 migration: in-place model_role column add ---
//
// Performs the standard DuckDB PK-rebuild dance on tensor_stats:
// CREATE new -> INSERT FROM old -> DROP old -> RENAME. Idempotent
// via information_schema.columns check. The writer branch only
// needs the model_role column on tensor_stats; the schema branch
// (evolve/unified-schema) extends the same dance to the other 6
// affected tables. Called from ts_tessera_db_open on every open.
int ts_tessera_db_migrate_model_role(
    ts_tessera_db * db,
    std::string * err);

// --- L5 weights: per-(model, family) retuned scoring weights ---
//
// The "did this requant plan reduce error?" feedback loop lands
// its consumer at l5_outcome. The next consumer is l5_retune.py,
// which fits a closed-form OLS model of delta_mse on
// sensitivity_score per (model, family) and projects the result
// onto the (w_imatrix, w_gradient, w_layer) simplex. The
// orchestrator's next generation reads these weights as the
// starting point for SensitivityScorer, closing the loop.
//
// PRIMARY KEY (model_hash, family). bias is the OLS intercept;
// n_samples is the count of l5_outcome rows that fed the fit;
// in_sample_loss is the post-fit mean abs residual. retune_source
// records which algorithm produced the row.
struct ts_tessera_db_l5_weight {
    std::string  model_hash;
    std::string  model_role;   // Phase 16: same enum as tensor_stats.
                               // The l5_weights table is per-(model, role,
                               // family) so the dflash family's retuned
                               // weights don't collide with the trunk
                               // family's. Default "trunk" preserves the
                               // pre-Phase-16 contract.
    std::string  family;
    double       w_imatrix    = 0.0;
    double       w_gradient   = 0.0;
    double       w_layer      = 0.0;
    double       bias         = 0.0;
    int32_t      n_samples    = 0;
    double       in_sample_loss = 0.0;
    double       hit_rate     = 0.0;
    // requant_budget_bits is the dispatch-side budget the orchestrator's
    // l5_retune recommends for this family in the next requant pass.
    // Computed by l5_retune.py as
    //   budget = family_storage_bits * (1 - hit_rate) * base_budget_fraction
    // and NULL when the family has too few samples to project a budget
    // (or the family has no tensor_stats storage rows). The dispatch's
    // L5 loop consumes it: budgeted families pick their A/B winner on
    // the Lagrangian score frob + lambda * violation (measured storage
    // bits), with subgradient ascent on lambda while the family stays
    // over budget. See tessera-dispatch.cpp (ts_dispatch_run_l5_loop).
    int64_t      requant_budget_bits = -1;   // -1 = NULL (sentinel for C++)
    std::string  retune_source;
};
int ts_tessera_db_upsert_l5_weight(ts_tessera_db * db,
                                   const ts_tessera_db_l5_weight & row,
                                   std::string * err);

// --- L5 weights typed list reader ---
//
// One entry per (model_hash, family) row in l5_weights. Used by the
// dispatch's GA-prep walk warm-start to bias the GA's (alpha, clip)
// initial population per family when the orchestrator's retune has
// already characterized the family. Empty `family` means "all families
// for this model_hash"; the dispatch passes empty when it wants the
// full list at open time.
//
// Mirrors ts_tessera_db_list_converged_for_model. Returned in hit_rate
// DESC order so the dispatch sees the most-converged family first.
struct ts_tessera_db_l5_weight_list_entry {
    std::string  model_hash;
    std::string  model_role;   // Phase 16: echoes the row's role so the
                               // dispatch's GA-prep walk can filter on
                               // (model_hash, model_role) without a
                               // separate read. Default "trunk" for
                               // pre-Phase-16 rows.
    std::string  family;
    double       w_imatrix    = 0.0;
    double       w_gradient   = 0.0;
    double       w_layer      = 0.0;
    double       bias         = 0.0;
    int32_t      n_samples    = 0;
    double       in_sample_loss = 0.0;
    double       hit_rate     = 0.0;
    int64_t      requant_budget_bits = -1;   // -1 = NULL
    std::string  retune_source;
};
struct ts_tessera_db_l5_weight_list {
    std::vector<ts_tessera_db_l5_weight_list_entry> entries;
};
int ts_tessera_db_list_l5_weights(ts_tessera_db * db,
                                  const std::string & model_hash,
                                  const std::string & family,
                                  ts_tessera_db_l5_weight_list * out);

// --- L5 outcome stats: per-(model, family) verdict aggregates ---
//
// Used by the dispatch's converged-fast early-exit: if a family has
// hit_rate > 0.95 across prior l5_outcome rows AND the current tensor's
// MSE is already within epsilon of the expected MSE at the next-rung
// qtype, skip the requant. The reader aggregates the verdict
// (plan_accepted) over the (model, family) group: hit_rate is the
// fraction of l5_outcome rows where plan_accepted = TRUE.
//
// Empty `family` means "all families" (caller picks the most-converged
// one to use as the gate). n_rows = 0 means "no l5_outcome for this
// model yet"; the dispatch treats that as no-op.
struct ts_tessera_db_l5_outcome_stats {
    int32_t      n_rows       = 0;
    int32_t      n_accepted   = 0;
    double       hit_rate     = 0.0;
    double       mean_delta_mse = 0.0;
    double       mean_sensitivity = 0.0;
    std::string  family;       // empty when aggregating across families
};
int ts_tessera_db_l5_outcome_stats_for(ts_tessera_db * db,
                                       const std::string & model_hash,
                                       const std::string & family,
                                       ts_tessera_db_l5_outcome_stats * out);

// --- L4 plan outcome (the feedback loop audit trail) ---
//
// One row per (model_hash, name, iteration, plan_id) recording the
// L4 forward-pass measurement AFTER a requant plan was applied.
// The C++ adaptive_requantize loop writes one row per (tensor, gen)
// with strategy = "A" (alpha/clip multiplier) or "B" (outlier_thresh
// bump). The Python l5_orchestrator's per-iteration runs also land
// here when the apply step re-quantizes and re-probes.
//
// The C++ side writes through a ts_db_buffer (parallel workers
// funnel into one flusher thread). The buffer is opened in
// ts_dispatch_db_open alongside the ga_evaluations buffer; the
// helper below is a thin shim that the dispatch's L5 loop calls
// per (tensor, iteration).
struct ts_tessera_db_l4_outcome {
    std::string model_hash;        // empty when hashing failed
    std::string  model_role;       // Phase 16: "trunk" / "dflash" / "dspark" /
                                   // "mtp_nextn" / "shared_embd". The
                                   // l4_plan_outcome table is the
                                   // feedback-loop audit trail; rows
                                   // for dflash / dspark / mtp_nextn
                                   // tensors must be distinguishable.
                                   // Default "trunk" preserves the
                                   // pre-Phase-16 contract.
    std::string  name;             // tensor name (drafter-local for
                                   // non-trunk roles)
    int32_t      layer             = 0;
    int32_t      iteration         = 0;
    std::string  plan_id;          // "cpp_quant_gen{N}_stage{S}" or "py_orch_..."
    std::string  strategy;         // "A" (alpha/clip) or "B" (outlier_thresh)
    double       alpha_before      = 0.0;
    double       alpha_after       = 0.0;
    double       clip_before       = 0.0;
    double       clip_after        = 0.0;
    double       outlier_thresh_before = 0.0;
    double       outlier_thresh_after  = 0.0;
    double       mse_before        = 0.0;   // rel_frob before the requant
    double       mse_after         = 0.0;   // rel_frob after the requant
    double       frob_before       = 0.0;   // absolute ||w - w_hat||^2 / ||w||^2
    double       frob_after        = 0.0;
    std::string  family;
};

// Push one row into the per-table write buffer. Thread-safe; the
// buffer's MPSC queue + flusher thread serializes the actual SQL.
// Returns 0 on success, non-zero on format / argument failure
// (the buffer's stats are bumped for rows that fail to flush at
// SQL time, but argument failures are returned synchronously).
//
// `buffer` is the ts_db_buffer* for the l4_plan_outcome table;
// typically obtained via ts_db_buffer_open() in ts_dispatch_db_open.
int ts_tessera_db_append_l4_outcome(
    struct ts_db_buffer * buffer,
    const ts_tessera_db_l4_outcome & row);

// --- Appender: bulk GA evaluation logging (the hot path) ---
//
// The GA evaluates 64+ candidates per generation x 100 generations x 254
// tensors = ~1.6M rows. Individual INSERTs would dominate runtime. The
// Appender buffers rows in memory and flushes in one bulk insert per
// generation. One appender is owned per active tensor; BeginRow/EndRow
// bracket each candidate, Flush commits the batch.
struct ts_tessera_db_eval_row {
    std::string  run_id;
    std::string  tensor_name;
    int32_t      generation   = 0;
    int32_t      island       = 0;
    int32_t      candidate_idx = 0;
    float        alpha        = 0.0f;
    float        clip         = 0.0f;
    float        composite    = 0.0f;
    float        mse          = 0.0f;
    float        relative_frob = 0.0f;
};
struct ts_tessera_db_appender;
ts_tessera_db_appender * ts_tessera_db_appender_open(ts_tessera_db * db,
                                                       const std::string & run_id,
                                                       const std::string & tensor_name,
                                                       std::string * err);
int ts_tessera_db_appender_row(ts_tessera_db_appender * ap,
                                const ts_tessera_db_eval_row & row);
int ts_tessera_db_appender_flush(ts_tessera_db_appender * ap);
void ts_tessera_db_appender_close(ts_tessera_db_appender * ap);

// --- Warm-start query ---
//
// Look up the best-known alpha/clip for a family across all prior runs
// (excluding the current one). Used by the dispatch to seed the GA from
// history instead of from scratch. Returns false if no row exists.
struct ts_tessera_db_family_seed {
    float best_alpha     = 0.0f;
    float best_clip      = 0.0f;
    float best_composite = 0.0f;
    std::string tensor_name;   // the prior run's tensor that produced this
};
bool ts_tessera_db_lookup_family_seed(ts_tessera_db * db,
                                       const std::string & family,
                                       const std::string & exclude_run_id,
                                       ts_tessera_db_family_seed * out);

// --- Resumability: list which tensors already converged for this run ---
//
// Populates `out` with tensor_name for every ga_results row of `run_id` whose
// converged flag is true. The dispatch uses this to skip already-finished
// tensors when re-running against an existing DB.
int ts_tessera_db_list_converged(ts_tessera_db * db,
                                  const std::string & run_id,
                                  std::vector<std::string> * out);

// Resume set across runs: list tensor_name for every converged ga_results
// row of any run of `model_hash`. Used by the dispatch to skip tensors that
// already converged in a prior (interrupted) run of the same model. Distinct
// from list_converged (single-run) so the caller does not need to know the
// prior run_id; the model_hash is the cross-run key.
int ts_tessera_db_list_converged_for_model(ts_tessera_db * db,
                                            const std::string & model_hash,
                                            std::vector<std::string> * out);

// Load the full ga_results row for one tensor in this run. Returns false if
// no row exists. Used by the resume path to reconstruct a candidate without
// re-running the GA.
bool ts_tessera_db_load_ga_result(ts_tessera_db * db,
                                   const std::string & run_id,
                                   const std::string & tensor_name,
                                   ts_tessera_db_ga_result * out);

// Resume lookup: find the most recent converged ga_result row for
// (model_hash, tensor_name) across all runs of this model. Returns false if
// no such row exists. Used by the dispatch's layer_skip hook so a re-launch
// after a crash picks up from the last completed tensor of any prior run.
bool ts_tessera_db_load_ga_result_for_model(ts_tessera_db * db,
                                             const std::string & model_hash,
                                             const std::string & tensor_name,
                                             ts_tessera_db_ga_result * out);

// Test-only: run an arbitrary SELECT COUNT(*)... query and return the int64
// result. Used by the e2e test to verify rows landed. Returns -1 on error.
// Not for production code paths (which should use the typed helpers above).
int64_t ts_tessera_db_debug_count(ts_tessera_db * db,
                                   const std::string & query);

// --- Phase 16: model_role migration ---
//
// The unified Gemma4 12B + dspark + dflash + MTP arch has tensors
// with the same name in both the trunk and the drafter. Phase 16
// disambiguates them with a `model_role` column on 7 of the
// unified-schema tables (tensor_stats, l3_outlier_summary,
// l4_probe_summary, l4_plan_outcome, l5_plan_summary, l5_outcome,
// l5_weights). The PK changes to include model_role.
//
// This function is the C++ side of the migration. It is:
//   * Idempotent: re-running on an already-migrated DB is a no-op
//     (each affected table is checked for the model_role column;
//     if present, the rebuild is skipped).
//   * Forward-compatible: a fresh DB created with the new schema
//     (CREATE TABLE IF NOT EXISTS includes model_role) is detected
//     as already-migrated and the function returns 0 without any
//     DDL.
//   * PK-changing: when the table lacks model_role, the function
//     does the standard DuckDB PK-rebuild dance (CREATE TABLE
//     new_name with the new schema, INSERT INTO new_name SELECT
//     *, 'trunk' AS model_role FROM old_name, DROP old_name,
//     ALTER new_name RENAME TO old_name).
//
// Called automatically by ts_tessera_db_open on every open. The
// Python-side tools/tessera/migrate_model_role.py is the
// equivalent migration for Python-only-opened DBs; both are
// idempotent so calling either or both is safe.
int ts_tessera_db_migrate_model_role(ts_tessera_db * db,
                                      std::string * err);

// Test-only: insert one synthetic l5_outcome row. The l5_outcome
// table is normally Python-written (tools/tessera/l5_outcome.py),
// but the C++ converged-fast test in test_l5_dispatch needs a way
// to populate it. Returns 0 on success, non-zero on error. The
// row is keyed on (model_hash, name, iteration, plan_id) so the
// dispatch's ts_tessera_db_l5_outcome_stats_for query can find it.
struct ts_tessera_db_l5_outcome_row {
    std::string  model_hash;
    std::string  model_role;    // Phase 16: same enum as tensor_stats. The
                                // l5_outcome table is per-(model, role,
                                // tensor, iter, plan_id) so the dflash /
                                // dspark / mtp_nextn verdicts don't
                                // collide with the trunk's. Default
                                // "trunk" for pre-Phase-16 rows.
    std::string  name;
    int32_t      layer          = 0;
    int32_t      iteration      = 0;
    std::string  plan_id;
    std::string  family;
    double       sensitivity_score = 0.0;
    double       recommended_alpha = 0.0;
    double       recommended_clip  = 0.0;
    double       mse_before        = 0.0;
    double       mse_after         = 0.0;
    double       delta_mse         = 0.0;
    double       delta_frob        = 0.0;
    bool         plan_accepted     = false;
    double       accept_threshold  = 0.0;
    double       residual          = 0.0;
    double       imatrix_magnitude = 0.0;   // nullable; 0 -> NULL
    double       gradient_proxy    = 0.0;   // nullable; 0 -> NULL
    double       layer_position_prior = 0.0; // nullable; 0 -> NULL
};
int ts_tessera_db_test_insert_l5_outcome(ts_tessera_db * db,
                                          const ts_tessera_db_l5_outcome_row & row);

// --- Regime thresholds: per-(model, family) learned kurtosis/eff_rank thresholds ----
//
// The regime classifier (tessera-regime.cpp) uses static kurtosis/eff_rank
// thresholds (kurt_heavy=10, kurt_light=5, er_compact=0.15, er_sparse=0.30) as
// fallback when no DuckDB prior exists. This table stores the learned variants
// produced by ts_regime_fit_thresholds (Tier 4) so Tier 2 can override the
// static cascade on subsequent runs of the same model.
//
// The thresholds are keyed on (model_hash, model_role, family). Primary key
// conflict triggers an upsert so successive OLS fits overwrite prior thresholds
// rather than accumulating rows.
//
// Fields r2_score and n_samples let the dispatch gate on fit quality:
//   - r2_score < 0.05 → fit is noise; fall back to static cascade
//   - n_samples < 8   → insufficient data; fall back to static cascade
//
// threshold_source records which algorithm produced the row:
//   "ols_fit_v1" = ts_regime_fit_thresholds OLS on delta_mse vs kurtosis
//   "builtin"    = static cascade (written by the dispatch when no prior exists)
struct ts_tessera_db_regime_threshold {
    std::string  model_hash;
    std::string  model_role;    // Phase 16: "trunk" / "dflash" / "dspark" /
                                // "mtp_nextn" / "shared_embd". Default "trunk".
    std::string  family;        // "attn_q", "ffn_gate", etc.
    float        kurt_heavy;    // kurtosis > kurt_heavy  -> DartQuant
    float        kurt_light;    // kurtosis > kurt_light  -> CHAMPQ
    float        er_compact;    // eff_rank < er_compact -> LRQ
    float        er_sparse;     // eff_rank < er_sparse  -> FLRQ
    int32_t      n_samples;     // l5_outcome rows that fed the OLS fit
    float        r2_score;      // R² of the OLS; < 0.05 means noise
    std::string  threshold_source;  // "ols_fit_v1" / "builtin" / ...
};
int ts_tessera_db_upsert_regime_threshold(ts_tessera_db * db,
                                          const ts_tessera_db_regime_threshold & row,
                                          std::string * err);

// Load all regime thresholds for a model. Empty `family` means "all families";
// non-empty filters to one family. Returns an empty list when no prior exists
// (the caller falls back to the static cascade).
//
// Rows are returned in n_samples DESC order so the dispatch sees the most
// data-informed thresholds first. The caller is responsible for selecting the
// best-fit row per (family) when multiple rows exist (should not happen with
// a PRIMARY KEY, but the n_samples ordering disambiguates any duplicates from
// legacy / migration rows).
struct ts_tessera_db_regime_threshold_list_entry {
    std::string  model_hash;
    std::string  model_role;
    std::string  family;
    float        kurt_heavy;
    float        kurt_light;
    float        er_compact;
    float        er_sparse;
    int32_t      n_samples;
    float        r2_score;
    std::string  threshold_source;
};
struct ts_tessera_db_regime_threshold_list {
    std::vector<ts_tessera_db_regime_threshold_list_entry> entries;
};
int ts_tessera_db_list_regime_thresholds(ts_tessera_db * db,
                                         const std::string & model_hash,
                                         const std::string & model_role,
                                         const std::string & family,
                                         ts_tessera_db_regime_threshold_list * out,
                                         std::string * err = nullptr);

// Upsert a regime routing outcome into l5_outcome. Called by the dispatch
// after each L5 forward-pass measurement. This populates the feedback signal
// that ts_regime_fit_thresholds consumes for Tier 4 OLS threshold refitting.
//
// The regime routing fields (kurtosis, eff_rank, layer_position) are nullable
// in the schema so a pre-existing l5_outcome row without them doesn't break
// the PRIMARY KEY upsert (only the new columns get populated on conflict).
//
// Returns 0 on success, non-zero on error. Failures are non-fatal (logged
// and continued); the dispatch never blocks on a DB write.
int ts_tessera_db_append_regime_outcome(ts_tessera_db * db,
                                         const ts_tessera_db_l5_outcome_row & outcome,
                                         const struct ts_regime_descriptor * desc,
                                         std::string * err);

// ---------------------------------------------------------------------------
// Tier 4 regime routing: per-tensor regime routing decision written by dispatch
// ---------------------------------------------------------------------------
//
// Written by the C++ dispatch after each tensor's step-7 quantization.
// PRIMARY KEY (model_hash, model_role, name) so successive requantize passes
// overwrite the prior routing (only the most recent regime matters).
// Read by the Python l5_outcome.py consumer which joins this with
// l4_plan_outcome to produce l5_outcome rows with kurtosis/eff_rank needed
// for Tier 4 OLS threshold refitting.
//
// For MoE 3D tensors, one row is written per expert (name = "blk.N.ffn_gate.weight.e")
// so the OLS fitter sees per-expert routing signals.
struct ts_tessera_db_regime_routing_row {
    std::string  model_hash;
    std::string  model_role;    // Phase 16: "trunk" / "dflash" / "dspark" / ...
    std::string  name;          // tensor name (e.g. "blk.0.ffn_gate.weight" or "blk.0.ffn_gate.weight.0")
    std::string  family;       // e.g. "ffn_gate" / "attn_q" / "routed_expert"
    int32_t      layer_depth;   // block index, or 0 for non-block tensors
    float        kurtosis;
    float        eff_rank;
    int          layer_position;  // 0=MIDDLE, 1=NEAR_EDGE, 2=EDGE
    int          routed_expert;   // ts_expert_id as integer
    std::string  expert_name;     // ts_expert_name() string
    float        routing_confidence;
    std::string  threshold_source; // "static" / "ols_fit_v1" / ...
    std::string  routing_reason;  // human-readable routing reason
    int          modality;        // ts_modality as integer
    int          default_tier;    // TS_TIER_* enum as integer
};
// Returns 0 on success, non-zero on error. Failures are non-fatal (logged).
int ts_tessera_db_upsert_regime_routing(ts_tessera_db * db,
                                         const ts_tessera_db_regime_routing_row & row,
                                         std::string * err);

// --- helpers used by the dispatch ---

// Extract the block index from a tensor name like "blk.12.ffn_gate.weight"
// -> 12. Returns 0 for non-block tensors (embeddings, norm, output).
int32_t ts_tessera_db_layer_depth(const std::string & name);

// SHA256 of the head + tail of a GGUF file (1 MB each). Full-file hashing of
// multi-GB models is too slow on every run; the head+tail fingerprint is
// unique enough for warm-start keying and runs in milliseconds. Returns an
// empty string on failure (the dispatch treats empty hash as "no warm-start").
std::string ts_tessera_db_hash_gguf(const std::string & path);

// --- L5 joint search gen-boundary checkpoint ---
//
// Writes one row per generation to the l5_search_state DuckDB table.
// ts_l5_joint_search() calls write at the end of each completed generation.
// The read function returns the highest-generation row for a run_id, enabling
// crash-resumable L5 search: on restart, the search resumes from gen+1
// seeded with the top-K from the last checkpoint.
//
// ts_l5_joint_topk_entry and ts_l5_joint_policy are defined in
// common/tessera-ppl-harness.h (included transitively). The gen_checkpoint
// struct mirrors the l5_search_state table columns.

struct ts_l5_joint_gen_checkpoint {
    std::string run_id;
    std::string model_hash;
    int32_t     generation = 0;
    // top_k: compact representation of top-K entries (policy + metric).
    // Serialized as JSON array via DuckDB json_object().
    std::vector<std::string> top_k_json;
    std::string best_policy_json;
    float       best_metric = 0.0f;
    bool        and_gate_pass = false;
    // gen_candidates: full population of the generation (for diagnostics).
    std::vector<std::string> candidates_json;
};

// Write one generation checkpoint. Uses INSERT OR REPLACE so the row is
// always the latest generation (PK = run_id). Returns 0 on success.
int ts_tessera_db_write_l5_gen_checkpoint(
        ts_tessera_db * db,
        const ts_l5_joint_gen_checkpoint & ckpt,
        std::string * err);

// Read the latest (highest generation) checkpoint for a run_id.
// Returns 0 and fills *out when a row exists; returns 1 when no
// checkpoint is found (first run). The top_k_json and candidates_json
// fields are raw JSON strings; the caller deserializes them.
int ts_tessera_db_read_l5_gen_checkpoint(
        ts_tessera_db * db,
        const std::string & run_id,
        ts_l5_joint_gen_checkpoint * out,
        std::string * err);

// --- L5 Hessian cache: forward-only second-order info (Phase C) ---
//
// The L5 Hessian scorer (§9 of docs/l1-l6-telemetry-refinements-spec.md)
// caches the diagonal of H^{-1} (the OBQ denominator, v3.1 spec errata:
// [H^{-1}]_ii = ||L_inv[i,:]||^2) per tensor. The v2_hessian_cache table is
// FORWARD-ONLY: the first row written for a (model_hash, model_role, name,
// in_dim, scorer_version) key is permanent. No code path ever overwrites,
// ALTERs, or DROPs a cached row; staleness is handled by keying:
//   - scorer_version (TS_L5_HESSIAN_SCORER_VERSION) invalidates rows when
//     the scorer math changes (§13 risk 2 / risk 9)
//   - n_samples / ridge_fraction are recorded with the value and the reader
//     refuses a hit when the caller's corpus or ridge differs, so a
//     different calibration corpus recomputes instead of reusing a stale
//     factor. The first row still stays (ON CONFLICT DO NOTHING).
//
// model_role uses the Phase 16 enum ("trunk" / "dflash" / "dspark" /
// "mtp_nextn" / "shared_embd"); the unified Gemma4 arch shares tensor names
// across components, so the role disambiguates the cache key exactly like
// tensor_stats / l5_weights.
struct ts_tessera_db_hessian_entry {
    std::string          model_hash;
    std::string          model_role;
    std::string          name;
    int64_t              in_dim          = 0;
    int32_t              scorer_version  = 0;
    std::vector<float>   h_inv_diag;     // in_dim floats; empty on read miss
    int64_t              n_samples       = 0;   // corpus rows that built H
    double               ridge_fraction  = 0.0; // ridge used when building H
};

// Read one cached H_inv_diag. Returns 0 on success with *hit set:
//   - *hit == true  -> h_inv_diag_out is the stored (in_dim,) diagonal.
//   - *hit == false -> no usable row (absent key, scorer_version mismatch,
//                      or n_samples / ridge_fraction mismatch with the
//                      caller's corpus). The caller should compute fresh.
// Never mutates. db == nullptr is a safe no-op (hit=false, return 0).
int ts_tessera_db_read_hessian_cache(
        ts_tessera_db * db,
        const std::string & model_hash,
        const std::string & model_role,
        const std::string & name,
        int64_t in_dim,
        int32_t scorer_version,
        int64_t n_samples,
        double ridge_fraction,
        std::vector<float> * h_inv_diag_out,
        bool * hit,
        std::string * err);

// Write one cached H_inv_diag. FORWARD-ONLY: INSERT ... ON CONFLICT DO
// NOTHING. The first row for the key is permanent; a later write for the
// same key (e.g. a different corpus) is dropped without touching the
// stored row. *stored reports whether this call inserted (false = conflict
// kept the existing row). Returns 0 on success (including the conflict
// case); non-zero only on a real SQL error. db == nullptr is a no-op.
int ts_tessera_db_write_hessian_cache(
        ts_tessera_db * db,
        const ts_tessera_db_hessian_entry & e,
        bool * stored,
        std::string * err);

// Append one line to the append-only Hessian cache ledger. The ledger
// lives next to the duckdb file as "<db-stem>.hessian-cache.jsonl" (the
// same stem rule as the model_role_migration.json sidecar); ":memory:" DBs
// have no ledger (returns 0, no-op). One JSON object per line:
//   {"ts": ..., "event": <event>, "model_hash": ..., "model_role": ...,
//    "name": ..., "in_dim": ..., "scorer_version": ..., "n_samples": ...,
//    "ridge_fraction": ...}
// event is one of "cache_hit" / "cache_miss" / "cache_compute" /
// "cache_store" / "cache_store_conflict". The read/write helpers emit
// hit/miss/store/conflict internally; the DISPATCH emits "cache_compute"
// when it factorized a missed key, so the ledger shows the full lifecycle.
// The ledger is append-only (a crash can leave a partial last line; the
// consumer skips a malformed trailing line). Returns 0 on success; 1 on a
// file error (non-fatal — the caller logs and continues).
int ts_tessera_db_append_hessian_ledger(
        ts_tessera_db * db,
        const char * event,
        const std::string & model_hash,
        const std::string & model_role,
        const std::string & name,
        int64_t in_dim,
        int32_t scorer_version,
        int64_t n_samples,
        double ridge_fraction,
        std::string * err);

// --- Eval cache: forward-only memoization for the ts_expert_eval seam ---
//
// Pipeline refactor phase 2 (docs/tessera-pipeline-refactor-plan.md,
// docs/tessera-eval-cache-design.md Layer B). Copies the v2_hessian_cache
// pattern above verbatim: FORWARD-ONLY (first row for a key is permanent,
// INSERT ... ON CONFLICT DO NOTHING), an append-only JSONL ledger, db ==
// nullptr is a safe no-op everywhere.
//
// Unlike the hessian cache, every variable input (genes/alpha/clip/tier,
// the KV-joint codec context) is folded into params_digest, which IS part
// of the primary key -- so a cache HIT is unconditionally valid for the
// exact key (no separate post-hoc value-gate re-check the way hessian's
// n_samples/ridge_fraction needed, since those were NOT part of that
// table's key). evaluator distinguishes both the expert AND the tier
// (e.g. "expert:SEPTQ:real", "expert:AWQ:proxy") so PROXY/REAL/
// KERNEL_DIRECT measurements of the same expert never collide.
struct ts_tessera_db_eval_cache_entry {
    std::string model_hash;
    std::string model_role;
    std::string tensor_name;
    std::string evaluator;        // "expert:<Name>:<tier>"
    std::string params_digest;    // resolved genes/alpha/clip/seed (grid-
                                   // quantized) + kv_codec_digest (phase 3)
    std::string input_digest;     // act_scales / imatrix slice digest, or
                                   // a stable sentinel when none is used
    int32_t     eval_version = 0;
    float       t2  = 0.0f;
    std::string aux;              // compact JSON, mirrors ts_eval_result::aux
};

// Read one cached (t2, aux). Returns 0 on success with *hit set:
//   - *hit == true  -> t2_out/aux_out are the stored value.
//   - *hit == false -> no row for the exact key (miss). Caller computes
//                      fresh and should write the result back.
// Never mutates. db == nullptr is a safe no-op (hit=false, return 0).
int ts_tessera_db_read_eval_cache(
        ts_tessera_db * db,
        const std::string & model_hash,
        const std::string & model_role,
        const std::string & tensor_name,
        const std::string & evaluator,
        const std::string & params_digest,
        const std::string & input_digest,
        int32_t eval_version,
        float * t2_out,
        std::string * aux_out,
        bool * hit,
        std::string * err);

// Write one cache entry. FORWARD-ONLY: INSERT ... ON CONFLICT DO NOTHING.
// *stored reports whether this call inserted (false = a conflicting row
// already existed and was kept). Returns 0 on success (including the
// conflict case); non-zero only on a real SQL error. db == nullptr is a
// no-op. Thread-safe: serializes internally via db->eval_cache_mutex.
int ts_tessera_db_write_eval_cache(
        ts_tessera_db * db,
        const ts_tessera_db_eval_cache_entry & e,
        bool * stored,
        std::string * err);

// Append one line to "<db-stem>.eval-cache.jsonl" (same stem rule as the
// hessian ledger). event is one of "cache_hit" / "cache_miss" /
// "cache_compute" / "cache_store" / "cache_store_conflict". The read/
// write helpers emit hit/miss/store/conflict internally; the SEAM (or its
// caller) emits "cache_compute" when a miss triggered a fresh REAL-tier
// computation, so the ledger shows the full lifecycle. Thread-safe (the
// caller already holds db->eval_cache_mutex via read/write above; direct
// callers emitting "cache_compute" take the lock themselves). Returns 0 on
// success; 1 on a file error (non-fatal -- the caller logs and continues).
int ts_tessera_db_append_eval_cache_ledger(
        ts_tessera_db * db,
        const char * event,
        const std::string & model_hash,
        const std::string & model_role,
        const std::string & tensor_name,
        const std::string & evaluator,
        const std::string & params_digest,
        const std::string & input_digest,
        int32_t eval_version,
        std::string * err);
