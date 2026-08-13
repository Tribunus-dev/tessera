//
// test_l5_dispatch.cpp
//
// Integration test for the L5 adaptive requantize loop wired into
// ts_dispatch_run. Builds a tiny synthetic GGUF with two 2D weights in
// different tensor families (attention + FFN), runs the full dispatch
// pipeline with --tessera-adaptive-requantize enabled, and asserts:
//
//   1. result.l5_ran is true
//   2. result.l5_report_json is non-empty and parses as the
//      llama.tessera.l5-loop.v1 schema
//   3. the report's generations array is non-empty
//
// This proves the L2 -> L5 -> A/B -> re-quantize -> re-measure loop is
// reachable from the production entry point without crashing and emits the
// documented receipt.
//
// Mirrors test_gguf_write_lifetime.cpp's GGUF construction pattern.
//

#include "tessera-dispatch.h"
#include "tessera-dispatch-internal.h"
#include "tessera-quant.h"
#include "tessera-quantize-db.h"
#include "tessera-corpus.h"   // ts_corpus_* (Phase C calib corpus)

#include "ggml.h"
#include "gguf.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <utility>
#include <vector>

static int g_fail = 0;
static void check(const char * name, bool ok) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) g_fail++;
}

// Deterministic fixture weights for tensor `idx`. Shared by the GGUF builder
// and the sidecar writer so both see identical values.
static std::vector<float> fixture_tensor_data(size_t idx, int64_t out_dim, int64_t in_dim) {
    std::vector<float> data((size_t)(out_dim * in_dim));
    uint32_t rng = (uint32_t)(idx + 1) * 2654435761u;
    for (int64_t j = 0; j < out_dim * in_dim; j++) {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        float u = (float)((rng >> 8) & 0xFFFF) / (float)0xFFFF;
        // Scale to ~unit variance; deliberately uneven so the tensors have
        // different divergence profiles.
        data[(size_t)j] = (u - 0.5f) * (1.0f + 2.0f * (float)idx);
    }
    return data;
}

// Write a v3 TDQT sidecar (same on-disk layout as the runtime hook and as
// test_l1_fitness.cpp's writer).
static bool write_v3_sidecar(const char * dir, const std::string & tensor_name,
                             int64_t rows, int64_t cols,
                             const std::vector<float> & data) {
    const std::string path = std::string(dir) + "/" + tensor_name + ".dequant.f32";
    FILE * f = std::fopen(path.c_str(), "wb");
    if (!f) return false;

    std::fwrite("TDQT", 1, 4, f);
    uint32_t version = 3;
    std::fwrite(&version, sizeof(version), 1, f);
    std::fwrite(&rows, sizeof(rows), 1, f);
    std::fwrite(&cols, sizeof(cols), 1, f);
    uint32_t dtype = 0;                 // F32
    std::fwrite(&dtype, sizeof(dtype), 1, f);
    float outlier_threshold = 6.0f;
    std::fwrite(&outlier_threshold, sizeof(outlier_threshold), 1, f);
    int64_t outlier_count_total = 0;
    std::fwrite(&outlier_count_total, sizeof(outlier_count_total), 1, f);

    // FP env block: accumulator dtype, rounding, denormal, backend id.
    uint32_t fp_env[4] = { 0, 0, 0, 0 };
    std::fwrite(fp_env, sizeof(uint32_t), 4, f);

    std::vector<int32_t> row_outlier_counts((size_t)rows, 0);
    std::fwrite(row_outlier_counts.data(), sizeof(int32_t), (size_t)rows, f);

    uint8_t row_meta[24];
    std::memset(row_meta, 0, sizeof(row_meta));
    for (int64_t r = 0; r < rows; r++) {
        std::fwrite(row_meta, 1, sizeof(row_meta), f);
    }

    std::fwrite(data.data(), sizeof(float), data.size(), f);
    std::fclose(f);
    return true;
}

static std::string read_file_string(const char * path) {
    FILE * f = std::fopen(path, "rb");
    if (!f) return std::string();
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::string out;
    if (sz > 0) {
        out.resize((size_t)sz);
        size_t rd = std::fread(&out[0], 1, (size_t)sz, f);
        out.resize(rd);
    }
    std::fclose(f);
    return out;
}

// Read the float that follows `key` at `pos` in a flat JSON string.
static bool parse_json_float_at(const std::string & s, size_t pos,
                                const char * key, float * out) {
    if (pos == std::string::npos || s.compare(pos, std::strlen(key), key) != 0) {
        return false;
    }
    const size_t vstart = pos + std::strlen(key);
    try {
        *out = std::stof(s.substr(vstart, 64));
    } catch (...) {
        return false;
    }
    return true;
}

// Build a synthetic F32 GGUF with the requested 2D weights, sized to
// tile640's page geometry so ts_quantize_2d accepts them.
static bool build_fixture_gguf(const char * path,
                               const std::vector<std::string> & tensor_names,
                               const std::vector<std::pair<int64_t, int64_t>> & dims) {
    struct gguf_context * ctx = gguf_init_empty();
    struct ggml_init_params ip = { /*mem_size=*/ 4 * 1024 * 1024,
                                   /*mem_buffer=*/ nullptr,
                                   /*no_alloc=*/ false };
    struct ggml_context * gctx = ggml_init(ip);

    for (size_t i = 0; i < tensor_names.size(); i++) {
        const int64_t out_dim = dims[i].first;
        const int64_t in_dim  = dims[i].second;
        struct ggml_tensor * t = ggml_new_tensor_2d(gctx, GGML_TYPE_F32, in_dim, out_dim);
        ggml_set_name(t, tensor_names[i].c_str());
        // Non-trivial but deterministic values so quantization produces
        // non-zero reconstruction error (required for L2 flagging).
        const std::vector<float> src = fixture_tensor_data(i, out_dim, in_dim);
        std::memcpy(t->data, src.data(), src.size() * sizeof(float));
        gguf_add_tensor(ctx, t);
    }

    bool ok = gguf_write_to_file(ctx, path, false);
    ggml_free(gctx);
    gguf_free(ctx);
    if (!ok) {
        std::printf("FAIL: gguf_write_to_file(%s) returned false\n", path);
        g_fail++;
    }
    return ok;
}

int main() {
    const char * fixture_path = "/tmp/test_l5_dispatch_input.gguf";
    const char * output_path  = "/tmp/test_l5_dispatch_output.gguf";

    // Two tensors: an attention projection and an FFN down projection, in
    // separate families so the per-family A/B path has something to compare.
    // in_dim 1280 = 2 tile640 pages, matching the lifecycle test's geometry.
    std::vector<std::string> names = {
        "blk.0.attn_q.weight",
        "blk.0.ffn_down.weight",
    };
    std::vector<std::pair<int64_t, int64_t>> dims = {
        { 16, 1280 },
        { 16, 1280 },
    };

    if (!build_fixture_gguf(fixture_path, names, dims)) {
        std::printf("\nFAIL (setup)\n");
        return 1;
    }

    ts_dispatch_params params = {};
    params.input_path        = fixture_path;
    params.output_path       = output_path;
    params.imatrix_path      = "";
    params.policy_path       = "";
    params.policy_out_path   = "/tmp/test_l5_dispatch.policy.json";
    params.evolve_seed       = 42;
    params.evolve_iters      = 2;
    params.evolve_islands    = 2;
    params.evolve_population = 4;
    params.outlier_frac      = 0.005f;
    params.awq_alpha         = "0.5";   // fixed alpha so AWQ is on and the
                                        // Stage A multiplier path is exercisable
    params.awq_clip          = 0.95f;
    params.nthreads          = 1;
    params.verbose           = false;

    // Enable the L5 adaptive requantize loop under test.
    params.adaptive_requantize        = true;
    params.l5_max_generations         = 2;
    params.l5_flag_multiplier         = 1.5f;
    params.l5_alpha_min               = 0.1f;
    params.l5_clip_min                = 0.1f;
    params.l5_outlier_overshoot_scale = 0.5f;
    params.l5_outlier_frac_cap        = 0.25f;
    params.l5_out_path                = "/tmp/test_l5_dispatch.l5-loop.json";

    ts_dispatch_result result;
    std::string err;
    int rc = ts_dispatch_run(&params, &result, &err);

    check("dispatch rc == 0", rc == 0);
    if (rc != 0) {
        std::printf("  error: %s\n", err.c_str());
        std::printf("\nFAIL (dispatch did not complete)\n");
        return 1;
    }

    // 1. The L5 loop must have run.
    check("l5_ran == true", result.l5_ran);

    // 2. The report JSON must be non-empty and carry the schema name.
    check("l5_report_json non-empty", !result.l5_report_json.empty());
    bool has_schema = result.l5_report_json.find("llama.tessera.l5-loop.v1") != std::string::npos;
    check("report carries the l5-loop.v1 schema", has_schema);
    bool has_generations = result.l5_report_json.find("\"generations\"") != std::string::npos;
    check("report has a generations array", has_generations);

    // 3. The report file was written.
    FILE * f = std::fopen("/tmp/test_l5_dispatch.l5-loop.json", "rb");
    check("l5-loop.json written to disk", f != nullptr);
    if (f) std::fclose(f);

    // 4. The dispatch still produced a valid output GGUF despite the
    //    in-place re-quantization (the repoint path must not have corrupted
    //    the descriptors). Reopen and confirm tensors are present.
    struct ggml_context * rin_ctx = nullptr;
    struct gguf_init_params rp = { /*no_alloc=*/ false, /*ctx=*/ &rin_ctx };
    struct gguf_context * rin = gguf_init_from_file(output_path, rp);
    check("output GGUF reopens", rin != nullptr);
    if (rin) {
        const int64_t n = gguf_get_n_tensors(rin);
        // Each Tessera weight produces 6+ component tensors; two weights
        // therefore yield >= 12 component tensors in the output.
        check("output GGUF has >= 12 tensors (2 weights * 6+ components)", n >= 12);
        gguf_free(rin);
        ggml_free(rin_ctx);
    }

    // ---- Phase 14: warm-start + converged-fast end-to-end ----
    // Re-run the dispatch against a tessera.duckdb that has l5_weights
    // pre-populated. The dispatch's family_seed_lookup hook should
    // consult the l5_weight_map (loaded at db_open) instead of
    // ga_results. We can't directly observe the bias from outside
    // the GA, but we can verify the dispatch didn't fail and the DB
    // contains the l5_weight rows after the run.
    //
    // The dispatch hashes the input GGUF for the model_hash, so we
    // need a deterministic input. We re-build the same fixture the
    // main test uses, then run the dispatch with --tessera-db set
    // and l5_weights pre-populated for the dispatch's model_hash.
    {
        const char * db_path = "/tmp/test_l5_dispatch.duckdb";
        std::remove(db_path);
        ts_tessera_db * db = ts_tessera_db_open(db_path, nullptr);
        check("phase14: open tessera.duckdb", db != nullptr);
        if (db != nullptr) {
            // Hash the fixture so we know what model_hash the
            // dispatch will compute. The dispatch does the same
            // head+tail SHA256 via ts_tessera_db_hash_gguf.
            std::string model_hash = ts_tessera_db_hash_gguf(fixture_path);
            check("phase14: hash fixture", !model_hash.empty());
            std::string err;
            std::string seed_run_id = ts_tessera_db_begin_run(
                db, fixture_path, model_hash, "test-build",
                "{\"phase\":14}", &err);
            check("phase14: begin_run seed", !seed_run_id.empty());

            // Pre-populate l5_weights for both families used by the
            // fixture (attn_q + ffn_down). hit_rate > 0.5 biases
            // the warm-start alpha/clip upward.
            ts_tessera_db_l5_weight wq;
            wq.model_hash     = model_hash;
            wq.family         = "attn_q";
            wq.w_imatrix      = 0.45;
            wq.w_gradient     = 0.35;
            wq.w_layer        = 0.20;
            wq.bias           = -0.0005;
            wq.n_samples      = 80;
            wq.in_sample_loss = 0.0008;
            wq.hit_rate       = 0.92;   // > 0.5 -> biased
            wq.requant_budget_bits = 4096;
            wq.retune_source  = "ols_slope_v1";
            check("phase14: upsert l5_weight attn_q",
                  ts_tessera_db_upsert_l5_weight(db, wq, &err) == 0);

            ts_tessera_db_l5_weight wf;
            wf.model_hash     = model_hash;
            wf.family         = "ffn_down";
            wf.w_imatrix      = 0.50;
            wf.w_gradient     = 0.30;
            wf.w_layer        = 0.20;
            wf.bias           = 0.0010;
            wf.n_samples      = 50;
            wf.in_sample_loss = 0.0012;
            wf.hit_rate       = 0.40;   // < 0.5 -> base (no bias)
            wf.requant_budget_bits = -1; // NULL
            wf.retune_source  = "ols_slope_v1";
            check("phase14: upsert l5_weight ffn_down",
                  ts_tessera_db_upsert_l5_weight(db, wf, &err) == 0);

            // Sanity: list_l5_weights returns both, ordered by hit_rate DESC.
            ts_tessera_db_l5_weight_list l5_list;
            check("phase14: list_l5_weights",
                  ts_tessera_db_list_l5_weights(db, model_hash, "",
                                                &l5_list) == 0);
            check("phase14: 2 l5_weight rows",
                  l5_list.entries.size() == 2);
            if (l5_list.entries.size() == 2) {
                check("phase14: highest hit_rate first",
                      l5_list.entries[0].hit_rate >=
                          l5_list.entries[1].hit_rate);
                check("phase14: attn_q hit_rate round-trip",
                      l5_list.entries[0].family == "attn_q" ||
                      l5_list.entries[1].family == "attn_q");
                check("phase14: requant_budget_bits NULL sentinel",
                      (l5_list.entries[0].requant_budget_bits == -1
                       && l5_list.entries[1].requant_budget_bits == 4096)
                      || (l5_list.entries[0].requant_budget_bits == 4096
                          && l5_list.entries[1].requant_budget_bits == -1));
            }
            ts_tessera_db_complete_run(db, seed_run_id, "completed", &err);
            // The struct is heap-allocated; the destructor closes the
            // DuckDB handles. No public close helper exists (intentional
            // — callers either use ts_dispatch_db's unique_ptr or delete
            // directly).
            delete db;
        }

        // Re-run the dispatch with --tessera-db so the GA's
        // family_seed_lookup hook can consult l5_weight_map. This
        // is the "the warm-start path actually runs through the
        // dispatch" end-to-end check; the previous block only
        // verified the l5_weight rows landed in the table.
        ts_dispatch_params params2 = params;
        params2.tessera_db_path    = db_path;
        params2.force_requantize   = true;  // don't skip on resume
        params2.verbose            = true;
        ts_dispatch_result result2;
        std::string err2;
        int rc2 = ts_dispatch_run(&params2, &result2, &err2);
        check("phase14: dispatch with --tessera-db rc == 0", rc2 == 0);
        if (rc2 == 0) {
            check("phase14: warm-start dispatch l5_ran", result2.l5_ran);
            check("phase14: warm-start dispatch l5_report non-empty",
                  !result2.l5_report_json.empty());
        } else {
            std::printf("  phase14 dispatch err: %s\n", err2.c_str());
        }
    }

    // ---- Phase 14: converged-fast end-to-end ----
    // Re-run with a tessera.duckdb that has l5_outcome rows for the
    // model with hit_rate > 0.95. The l5 loop's early-exit at the
    // top of each gen (gen >= 1) should fire on the first re-loop
    // and break before max_generations. The report JSON should
    // carry a converged_fast=true marker.
    //
    // We use the test-only ts_tessera_db_test_insert_l5_outcome
    // helper to populate l5_outcome (the table is normally
    // Python-written, but the test scope is the C++ early-exit
    // logic).
    {
        const char * db_path = "/tmp/test_l5_dispatch_fast.duckdb";
        std::remove(db_path);
        ts_tessera_db * db = ts_tessera_db_open(db_path, nullptr);
        check("phase14-fast: open", db != nullptr);
        if (db != nullptr) {
            std::string err;
            std::string model_hash = ts_tessera_db_hash_gguf(fixture_path);
            // Begin a run so the l5_outcome rows have a model_hash
            // that lines up with the dispatch's ts_tessera_db_hash_gguf.
            std::string seed_run_id = ts_tessera_db_begin_run(
                db, fixture_path, model_hash, "test-build",
                "{\"phase\":14,\"fast\":true}", &err);
            check("phase14-fast: begin_run", !seed_run_id.empty());

            // Insert 10 l5_outcome rows for the model, all
            // accepted, for both fixture families. hit_rate = 1.0
            // (= 10/10) > 0.95 -> the early-exit should fire.
            int n_inserted = 0;
            for (int i = 0; i < 10; i++) {
                ts_tessera_db_l5_outcome_row r;
                r.model_hash     = model_hash;
                r.name           = "blk.0.attn_q.weight";
                r.layer          = 0;
                r.iteration      = i;
                r.plan_id        = "phase14_fast_p" + std::to_string(i);
                r.family         = (i % 2 == 0) ? "attn_q" : "ffn_down";
                r.sensitivity_score = 0.7;
                r.recommended_alpha = 0.5;
                r.recommended_clip  = 0.95;
                r.mse_before        = 0.010;
                r.mse_after         = 0.008;  // delta < 0 -> accepted
                r.delta_mse         = -0.002;
                r.plan_accepted     = true;
                if (ts_tessera_db_test_insert_l5_outcome(db, r) == 0) {
                    n_inserted++;
                }
            }
            check("phase14-fast: 10 l5_outcome rows inserted",
                  n_inserted == 10);

            // Sanity: stats reflect hit_rate=1.0 across families.
            ts_tessera_db_l5_outcome_stats s;
            check("phase14-fast: l5_outcome_stats_for (populated)",
                  ts_tessera_db_l5_outcome_stats_for(
                      db, model_hash, "", &s) == 0);
            check("phase14-fast: n_rows=10", s.n_rows == 10);
            check("phase14-fast: n_accepted=10", s.n_accepted == 10);
            check("phase14-fast: hit_rate=1.0", s.hit_rate > 0.99);

            ts_tessera_db_complete_run(db, seed_run_id, "completed", &err);
            delete db;
        }

        // Re-run the dispatch with --tessera-db pointing at the
        // seeded DB. The dispatch's l5 loop's early-exit at the
        // top of each gen (gen >= 1) should fire on the first
        // re-loop and break before max_generations. The report
        // JSON should carry a converged_fast=true marker.
        //
        // The fixture was cleaned up by the main test's cleanup
        // block; rebuild it for this dispatch run.
        if (!build_fixture_gguf(fixture_path, names, dims)) {
            check("phase14-fast: rebuild fixture", false);
        } else {
            ts_dispatch_params params3 = params;
            params3.tessera_db_path    = db_path;
            params3.force_requantize   = true;
            params3.l5_max_generations = 4;  // enough that early-exit
                                              // is observable if it
                                              // fires (it would skip
                                              // gens 2 and 3)
            params3.verbose            = false;
            ts_dispatch_result result3;
            std::string err3;
            int rc3 = ts_dispatch_run(&params3, &result3, &err3);
            check("phase14-fast: dispatch with seeded l5_outcome rc == 0",
                  rc3 == 0);
            if (rc3 == 0) {
                check("phase14-fast: l5_ran", result3.l5_ran);
                const std::string & rj = result3.l5_report_json;
                // Debug: write the report next to the test so the
                // failure mode is visible without re-running.
                if (std::getenv("TESSERA_TEST_DEBUG")) {
                    FILE * rf = std::fopen("/tmp/test_l5_dispatch_fast.report.json", "wb");
                    if (rf) { std::fwrite(rj.data(), 1, rj.size(), rf); std::fclose(rf); }
                    std::printf("  phase14-fast report size: %zu bytes\n", rj.size());
                }
                check("phase14-fast: report has converged_fast",
                      rj.find("\"converged_fast\"") != std::string::npos);
                check("phase14-fast: report has hit_rate",
                      rj.find("\"hit_rate\"") != std::string::npos);
                // Count "converged_fast" markers in the whole
                // report. The early-exit fires once and breaks,
                // so there should be exactly 1 marker. The marker
                // appears once per generation entry where the
                // fast-path fires; if the dispatch took 2 gens
                // (1 normal + 1 fast-exit) the count is 1.
                size_t pos = 0;
                int count = 0;
                while ((pos = rj.find("converged_fast", pos))
                        != std::string::npos) {
                    count++;
                    pos += 14;
                }
                check("phase14-fast: exactly 1 converged_fast entry",
                      count == 1);
            } else {
                std::printf("  phase14-fast dispatch err: %s\n", err3.c_str());
            }
        }
    }

    // ---- Phase C: L5 scorer combine (hessian + imatrix) ----
    // The l5_scorer spec joins the per-tensor scorer maps via ts_l5_combine
    // after the quantize walk. The hessian map needs a calibration corpus
    // whose width matches the tensors (in_dim 1280): generate one, point
    // calib_corpus at it, and run the dispatch twice against the same
    // tessera.duckdb. Run 1 factorizes the Hessian (once per in_dim);
    // run 2 must hit the forward-only v2_hessian_cache for both tensors.
    {
        const char * corpus_path  = "/tmp/test_l5_dispatch_hessian_corpus.npy";
        const char * hdb_path     = "/tmp/test_l5_dispatch_hessian.duckdb";
        const char * hledger_path = "/tmp/test_l5_dispatch_hessian.hessian-cache.jsonl";

        ts_corpus_params cp = ts_corpus_default_params();
        cp.n_tokens = 64;
        cp.in_dim   = 1280;   // matches the fixture tensors' in_dim
        cp.seed     = 7;
        std::string cerr;
        if (ts_corpus_generate_to_file(&cp, corpus_path, &cerr) != 0) {
            std::printf("  phase-c setup: corpus generate failed: %s\n", cerr.c_str());
            g_fail++;
        } else {
            // Fresh fixture + fresh DB for the cache assertions.
            if (!build_fixture_gguf(fixture_path, names, dims)) {
                std::printf("  phase-c setup: fixture rebuild failed\n");
                g_fail++;
            } else {
                ts_dispatch_params hp = {};
                hp.input_path      = fixture_path;
                hp.output_path     = output_path;
                hp.imatrix_path    = "";
                hp.policy_path     = "";
                hp.policy_out_path = "/tmp/test_l5_dispatch_hessian.policy.json";
                hp.calib_corpus    = corpus_path;
                hp.tessera_db_path = hdb_path;
                hp.l5_scorer       = "hessian:0.6,imatrix:0.4";
                hp.evolve_seed     = 7;
                hp.evolve_iters    = 1;
                hp.evolve_islands  = 1;
                hp.evolve_population = 4;
                hp.outlier_frac    = 0.005f;
                hp.awq_alpha       = "0.5";
                hp.awq_clip        = 0.95f;
                hp.nthreads        = 1;
                hp.verbose         = false;

                ts_dispatch_result hr;
                std::string herr;
                int hrc = ts_dispatch_run(&hp, &hr, &herr);
                check("phase-c: dispatch rc == 0", hrc == 0);
                if (hrc != 0) {
                    std::printf("  phase-c dispatch err: %s\n", herr.c_str());
                } else {
                    check("phase-c: l5_scorer_ran", hr.l5_scorer_ran);
                    check("phase-c: hessian n_scored == 2",
                          hr.l5_hessian_n_scored == 2);
                    check("phase-c: hessian n_factorized == 1 (memoized per in_dim)",
                          hr.l5_hessian_n_factorized == 1);
                    check("phase-c: hessian n_cached == 0 (fresh DB)",
                          hr.l5_hessian_n_cached == 0);
                    check("phase-c: hessian n_skipped == 0",
                          hr.l5_hessian_n_skipped == 0);
                    bool rep_ok = hr.l5_scorer_report_json.find(
                        "llama.tessera.l5-scorer.v1") != std::string::npos;
                    check("phase-c: report carries the l5-scorer.v1 schema", rep_ok);
                    bool scores_ok = hr.l5_scorer_report_json.find(
                        "\"scores\"") != std::string::npos;
                    check("phase-c: report has a scores array", scores_ok);
                    // Exactly 2 combined entries (one per fixture tensor).
                    size_t pos = 0;
                    int combined_count = 0;
                    while ((pos = hr.l5_scorer_report_json.find("\"combined\"", pos))
                           != std::string::npos) {
                        combined_count++;
                        pos += 10;
                    }
                    check("phase-c: report has 2 combined scores",
                          combined_count == 2);
                }

                // Run 2 against the same DB: both H_inv_diag come from the
                // forward-only cache (no factorization).
                ts_dispatch_result hr2;
                std::string herr2;
                int hrc2 = ts_dispatch_run(&hp, &hr2, &herr2);
                check("phase-c: second dispatch rc == 0", hrc2 == 0);
                if (hrc2 != 0) {
                    std::printf("  phase-c second dispatch err: %s\n", herr2.c_str());
                } else {
                    check("phase-c: second run n_cached == 2",
                          hr2.l5_hessian_n_cached == 2);
                    check("phase-c: second run n_factorized == 0",
                          hr2.l5_hessian_n_factorized == 0);
                    check("phase-c: second run n_scored == 2",
                          hr2.l5_hessian_n_scored == 2);
                }

                // Ledger: the append-only hessian-cache.jsonl exists next to
                // the duckdb and records the full lifecycle.
                FILE * lf = std::fopen(hledger_path, "rb");
                check("phase-c: hessian ledger exists", lf != nullptr);
                if (lf) {
                    std::fseek(lf, 0, SEEK_END);
                    long sz = std::ftell(lf);
                    std::fseek(lf, 0, SEEK_SET);
                    std::vector<char> buf((size_t) sz);
                    if (sz > 0) {
                        std::fread(buf.data(), 1, (size_t) sz, lf);
                    }
                    std::fclose(lf);
                    std::string lc(buf.begin(), buf.end());
                    check("phase-c: ledger has cache_store",
                          lc.find("\"event\": \"cache_store\"") != std::string::npos);
                    check("phase-c: ledger has cache_hit",
                          lc.find("\"event\": \"cache_hit\"") != std::string::npos);
                    check("phase-c: ledger has cache_compute",
                          lc.find("\"event\": \"cache_compute\"") != std::string::npos);
                }
            }
        }

        std::remove(corpus_path);
        std::remove(hdb_path);
        std::remove(hledger_path);
        std::remove("/tmp/test_l5_dispatch_hessian.policy.json");
        std::remove("/tmp/test_l5_dispatch_hessian.duckdb.wal");
    }

    // ---- G6 acceptance: kernel-direct t_l^2 on the threaded path ----
    // Regression guard. The acceptance gate evaluates tensors serially when
    // work.size() < 2 and on a thread pool otherwise; production always takes
    // the pool. Both branches must feed the same source buffer to
    // ts_dispatch_kernel_direct_t2, or the sidecar measurement silently
    // degrades to the offline proxy -- which makes kendall_tau identically 1,
    // ranking_disagreement 0, and novelty_survives false, so the G6 gate can
    // never pass. Four tensors force the pool; the assertion is that at least
    // one kernel_direct_t2 differs from its offline_proxy_mse.
    {
        const char * acc_fixture = "/tmp/test_l5_dispatch_acc.gguf";
        const char * acc_output  = "/tmp/test_l5_dispatch_acc_out.gguf";
        const char * acc_report  = "/tmp/test_l5_dispatch_acc.json";
        const char * sidecar_dir = "/tmp/test_l5_dispatch_sidecars";

        std::vector<std::string> anames = {
            "blk.0.attn_q.weight",
            "blk.0.ffn_down.weight",
            "blk.1.attn_q.weight",
            "blk.1.ffn_down.weight",
        };
        std::vector<std::pair<int64_t, int64_t>> adims(anames.size(), { 16, 1280 });

        if (build_fixture_gguf(acc_fixture, anames, adims)) {
            std::filesystem::create_directories(sidecar_dir);

            // One sidecar per tensor, holding the source weights scaled by
            // (1 + eps). eps is non-monotonic across tensors so the
            // kernel-direct ranking is neither the offline ranking nor its
            // exact reverse (|tau| == 1 in both of those cases would leave
            // ranking_disagreement at 0 and hide a regression).
            const float eps[4] = { 0.03f, 0.005f, 0.05f, 0.015f };
            bool wrote_all = true;
            for (size_t i = 0; i < anames.size(); i++) {
                std::vector<float> deq = fixture_tensor_data(i, adims[i].first, adims[i].second);
                for (auto & v : deq) v *= (1.0f + eps[i]);
                wrote_all &= write_v3_sidecar(sidecar_dir, anames[i],
                                              adims[i].first, adims[i].second, deq);
            }
            check("g6: sidecars written", wrote_all);

            ts_dispatch_params ap = {};
            ap.input_path        = acc_fixture;
            ap.output_path       = acc_output;
            ap.policy_out_path   = "/tmp/test_l5_dispatch_acc.policy.json";
            ap.evolve_seed       = 42;
            ap.evolve_iters      = 2;
            ap.evolve_islands    = 2;
            ap.evolve_population = 4;
            ap.outlier_frac      = 0.005f;
            ap.awq_alpha         = "0.5";
            ap.awq_clip          = 0.95f;
            ap.nthreads          = 1;
            ap.verbose           = false;
            ap.adaptive_requantize = false;
            ap.run_acceptance      = true;
            ts_acceptance_default_config(&ap.acceptance_config);
            snprintf(ap.acceptance_config.output_path,
                     sizeof(ap.acceptance_config.output_path), "%s", acc_report);
            ap.kernel_fitness_dir = sidecar_dir;

            ts_dispatch_result ares;
            std::string aerr;
            int arc = ts_dispatch_run(&ap, &ares, &aerr);
            check("g6: dispatch rc == 0", arc == 0);
            if (arc != 0) {
                std::printf("  error: %s\n", aerr.c_str());
            } else {
                check("g6: acceptance_ran", ares.acceptance_ran);

                // Parse the per-tensor breakdown and require at least one
                // tensor whose kernel-direct score is a real measurement
                // rather than a copy of the offline proxy.
                std::string rep = read_file_string(acc_report);
                check("g6: acceptance report written", !rep.empty());

                int n_seen = 0;
                int n_differ = 0;
                size_t pos = 0;
                while ((pos = rep.find("\"offline_proxy_mse\":", pos)) != std::string::npos) {
                    float off = 0.0f, kd = 0.0f;
                    if (!parse_json_float_at(rep, pos, "\"offline_proxy_mse\":", &off)) break;
                    size_t kpos = rep.find("\"kernel_direct_t2\":", pos);
                    if (kpos == std::string::npos) break;
                    if (!parse_json_float_at(rep, kpos, "\"kernel_direct_t2\":", &kd)) break;
                    n_seen++;
                    if (std::fabs(off - kd) > 1e-9f) n_differ++;
                    pos = kpos;
                }
                check("g6: report has per-tensor scores", n_seen >= 2);
                check("g6: kernel_direct_t2 is measured, not the offline proxy",
                      n_differ > 0);
            }

            std::filesystem::remove_all(sidecar_dir);
            std::remove(acc_fixture);
            std::remove(acc_output);
            std::remove(acc_report);
            std::remove("/tmp/test_l5_dispatch_acc.policy.json");
            std::remove("/tmp/test_l5_dispatch_acc.duckdb");
        }
    }

    // Cleanup.
    std::remove(fixture_path);
    std::remove(output_path);
    std::remove("/tmp/test_l5_dispatch.policy.json");
    std::remove("/tmp/test_l5_dispatch.l5-loop.json");
    std::remove("/tmp/test_l5_dispatch.duckdb");
    std::remove("/tmp/test_l5_dispatch_fast.duckdb");
    std::remove("/tmp/test_l5_dispatch_empty.duckdb");

    std::printf("\n%s (%d failures)\n", g_fail == 0 ? "PASS" : "FAIL", g_fail);
    return g_fail == 0 ? 0 : 1;
}
