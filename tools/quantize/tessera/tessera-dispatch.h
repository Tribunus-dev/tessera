#pragma once

//
// tessera-dispatch.h
//
// Top-level Tessera pipeline orchestrator. Called from quantize.cpp as
// llama_model_quantize_tessera(). Decides which steps to run based on
// flag presence, runs calibration / GA / per-tensor quantize, and
// returns results ready for the GGUF writer.
//

#include <string>
#include <vector>
#include <cstdint>
#include <unordered_map>

#include "tessera-acceptance.h"

// Forward declaration so the dispatch header does not require duckdb.hpp.
struct ts_tessera_db;

// Forward declaration; full definition in tessera-dispatch-internal.h.
struct ts_dispatch_refine_entry;

struct ts_dispatch_params {
    std::string input_path;
    std::string output_path;
    std::string imatrix_path;     // empty = run calibration
    std::string policy_path;      // empty = run GA
    std::string policy_out_path;
    std::string calib_corpus;     // empty = use built-in mini-corpus
    std::string higgs_alpha_mode; // "auto", "uniform", "cache-only" (default: "uniform")
    std::string higgs_cache_dir;  // empty = default (~/.cache/tessera/higgs_alpha/)
    uint64_t    evolve_seed;
    int         evolve_iters;
    int         evolve_islands;
    int         evolve_population;
    bool        evolve_only;
    bool        calibrate_only;
    float       outlier_frac;
    std::string awq_alpha;        // "auto" or a float string
    float       awq_clip;
    int         nthreads;
    bool        verbose;
    // S5 kernel-direct fitness (L1 sidecar). When kernel_fitness is set the
    // GA evaluator scores candidates against the kernel's real dequant output
    // (from kernel_fitness_dir) blended with the offline proxy.
    bool        kernel_fitness;
    std::string kernel_fitness_dir;     // empty = $LLAMA_TILE640_DEBUG_DEQUANT_DIR
    float       kernel_fitness_blend;   // 0.0 = offline, 1.0 = kernel-direct
    // S9 W4A4 activation quantization. When w4a4 is set the pipeline computes
    // per-token activation scales and the LLM.int8 outlier decomposition from
    // the calibration activations and records them as sidecar metadata; the
    // weight-only contract is unchanged when w4a4 is false.
    bool        w4a4;
    float       w4a4_outlier_thresh;    // LLM.int8 |X| threshold (default 6.0)
    // S7 G6 acceptance gate. When set, re-quantizes each tensor under every
    // single-proxy expert and runs the composite-beats-single + ranking
    // disagreement test after quantization. On by default; the dispatch
    // plumbs the common_tessera_params default (true) through.
    bool        run_acceptance = true;
    ts_acceptance_config acceptance_config;
    // L5 adaptive requantization. When set, runs the L2 -> L5 -> re-quantize
    // loop after step 7 for up to l5_max_generations, tightening alpha/clip
    // (Stage A) or outlier_fraction (Stage B, A/B per tensor family) on
    // tensors whose L2 divergence overshoots their type baseline. See
    // docs/runtime-aware-pipeline.md Layer 5. On by default; the dispatch
    // plumbs the common_tessera_params default (true) through.
    //
    // DEPRECATED: weights-only per-tensor path. Superseded by the joint
    // PPL harness (l5_joint_mode). Kept as a fallback for --no-tessera-l5-joint.
    bool        adaptive_requantize = true;
    int         l5_max_generations  = 3;     // generational cap
    float       l5_flag_multiplier  = 1.5f;  // L2 flag threshold = multiplier * type baseline
    float       l5_alpha_min        = 0.1f;  // floor for the Stage A alpha multiplier
    float       l5_clip_min         = 0.1f;  // floor for the Stage A clip multiplier
    float       l5_outlier_overshoot_scale = 0.5f;  // Stage B outlier_frac bump per unit overshoot
    float       l5_outlier_frac_cap = 0.25f; // Stage B outlier_fraction ceiling
    std::string l5_out_path;                 // empty = beside policy_out_path as <stem>.l5-loop.json

    // L5 joint PPL mode. THE DEFAULT. Joint forward pass across the
    // target + 3 spec drafters (DFlash, DSPark, MTP) + talker, measured
    // by per-model normalized PPL delta with a per-model AND-gate at
    // l5_joint_epsilon. Search is coarse-to-fine with adaptive
    // slippery detection (epsilon/5). Strict mode (--tessera-l5-strict)
    // re-evaluates the winning policy at 0.25% and reports
    // STRICT_CONVERGED or STRICT_BEST_EFFORT.
    //
    // See common/tessera-ppl-harness.h + common/tessera-l5-joint.h
    // for the design. See .zcode/plans/plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d.md
    // for the locked spec.
    bool        l5_joint_mode          = true;    // on by default
    bool        l5_joint_strict        = false;   // --tessera-l5-strict
    float       l5_joint_epsilon       = 0.0099f; // 0.99% (juuust below 1%)
    int         l5_joint_max_generations = 5;     // search generations
    int         l5_joint_top_k         = 4;       // top policies kept
    int         l5_joint_n_gen0_samples = 32;     // gen 0 random samples
    uint32_t    l5_joint_rng_seed      = 0x5EED5u;
    // Search metric: 0=MAX (default, worst-case model drives the search;
    // every active model - including the 3 drafters and the talker -
    // gets full optimization when it is the worst case), 1=SUM, 2=MEAN.
    // See ts_l5_joint_metric in common/tessera-ppl-harness.h.
    int         l5_joint_metric        = 0;
    // Drafter / talker GGUFs. Empty = that model inactive (FP baseline,
    // contributes 0 to the AND-gate). At minimum, the target is always
    // active (it's the dispatch's input). For a real 5-model joint
    // calibration, all 4 paths are populated.
    std::string dflash_gguf_path;
    std::string dspark_gguf_path;
    std::string mtp_gguf_path;
    std::string talker_gguf_path;
    // Joint calibration set (JSONL: text + talker_targets per record).
    // Empty = generate from a synthetic fixture (v1 schema; v3 wires
    // the real text-to-audio target mapping).
    std::string l5_joint_calibration_path;
    std::string l5_joint_out_path;     // empty = beside policy_out_path as <stem>.l5-joint.json
    // Structured progress reporting. When progress_file is non-empty, the
    // dispatch writes one NDJSON event per tick to that path for the Studio
    // UI to tail. Terminal live-update auto-enables on TTY stderr.
    std::string progress_file;               // empty = no NDJSON output
    bool        progress_force_terminal = false;
    // Unified tessera.duckdb store path. When non-empty the dispatch
    // opens (or creates) a DuckDB file at this path, records one row
    // per run / tensor / GA result / L4 plan outcome, bulk-logs every
    // GA candidate evaluation through the per-table write buffer, and
    // reloads family-optimal alpha/clip from prior runs to warm-start
    // the GA. Tensors with a converged result for the same model_hash
    // are skipped unless force_requantize is set, making the pipeline
    // crash-resumable. The C++ side also writes the cross-pipeline
    // tensor_stats feature table (kurtosis / eff_rank / dtype) here;
    // the Python calibration pipeline fills rms / mean_abs /
    // tail_ratio on a subsequent upsert.
    std::string tessera_db_path;            // empty = ephemeral, no DB
    bool        force_requantize = false;
    // Phase 16 (calibrate-model-role follow-up): the model_role
    // tag stamped on every tensor_stats upsert from the GA-prep
    // walk. One of "trunk" / "dflash" / "dspark" / "mtp_nextn" /
    // "shared_embd". The default "trunk" preserves the pre-Phase-16
    // single-component contract; the unified_calibrate.py driver
    // passes the user-supplied role via this field so the per-role
    // dispatch runs stamp the cross-pipeline tensor_stats table
    // correctly. Mirrors the awq-evolve.py --model-role arg.
    std::string model_role;
    // L2 forward-pass differential plumbing (Layer 2 of the runtime-aware
    // pipeline, see docs/runtime-aware-pipeline.md). The dispatch itself
    // does not run the forwards; the tools/tessera/runtime_probe.py
    // orchestrator shells out to llama-cli / llama-imatrix with
    // --tessera-matmul-output-dir and reads the resulting .matmul-output.f32
    // sidecars. The dispatch records the orchestrator's config in the
    // L2 report's provenance block when these fields are non-empty.
    std::string runtime_probe;            // orchestrator marker (the prompts file the orchestrator is using)
    std::string runtime_probe_bf16;       // path to the BF16 source model
    std::string runtime_probe_l2_out;     // path to the L2 JSONL report
    // L6 tail-weighted kernel loss (NEW, v3.1, spec section 11). The
    // t_l^2 fitness function adds a mean-MSE term on the outlier-tail
    // weights (|W_l[i]| > l6_tail_tau) scaled by l6_tail_weight. This
    // forces the GA to preserve the outlier codebook at the same time
    // as the bulk. The 6.0 default is the LLM.int8() precedent
    // (Dettmers et al., arXiv:2208.07339); the 4.0 weight matches
    // per_tensor_calibrate.py:73's `combined` fitness mode. Set
    // l6_tail_weight = 0 to disable tail weighting and reproduce the
    // shipped Frobenius behavior (back-compat with the pre-v3.1
    // ts_l1_kernel_direct_t2). Placed at the end of the struct so
    // appending it doesn't shift the layout of fields that downstream
    // test fixtures initialize via `ts_dispatch_params p = {};` and
    // then set explicitly (the L5 dispatch test, the quantize DB e2e
    // test).
    float       l6_tail_tau     = 6.0f;  // outlier threshold
    float       l6_tail_weight  = 4.0f;  // tail loss multiplier
    // L5 Hessian scorer dispatch (v3.1, spec section 9.4). When non-empty,
    // the main dispatch parses it via ts_l5_parse_scorer_spec and joins
    // the named scorers via ts_l5_combine (e.g.
    // --tessera-l5-scorer=hessian:0.5,imatrix:0.3,grad:0.2). Empty = legacy
    // (no Hessian combine). Placed last so appending it doesn't shift
    // the layout of fields that fixtures initialize via `ts_dispatch_params
    // p = {};` then set explicitly.
    std::string l5_scorer;
};

// Result of the Tessera pipeline for one tensor.
struct ts_dispatch_tensor_result {
    std::string name;
    std::string family;
    int64_t     out_dim;
    int64_t     in_dim;
    // quantized data (the 6 components) - opaque blob for the writer
    std::vector<uint8_t> packed;
    std::vector<uint8_t> page_scales;
    std::vector<uint8_t> lane_scales;
    std::vector<uint8_t> outlier_row_offsets;
    std::vector<uint8_t> outlier_cols;
    std::vector<uint8_t> outlier_vals;
    std::vector<uint8_t> act_scale;   // empty if alpha == 0
    float       mse;
    float       alpha_used;
    // routed expert + the profile actually applied to this tensor
    int         expert_id;
    std::string expert_name;
    float       profile_alpha;
    float       profile_clip;
    int         profile_awq_grid;
    int         profile_max_outliers;
    float       profile_outlier_thresh;
    bool        profile_use_septq;
    // modality axis: operative modality (0=text, 1=image, 2=audio) and the
    // per-modality AWQ alpha from the multimodal imatrix (0 when absent)
    int         modality_id;
    float       modality_alpha[3];
    // S9 W4A4 sidecar metadata (populated when params.w4a4 is set)
    bool        w4a4_enabled = false;
    int         w4a4_activation_bits = 0;
    std::string w4a4_scale_mode;        // "per_token" / "per_tensor"
    float       w4a4_outlier_frac = 0.0f;
    float       w4a4_act_scale_static = 0.0f;
    std::vector<uint32_t> w4a4_outlier_channels;
};

struct ts_dispatch_result {
    std::vector<ts_dispatch_tensor_result> tensors;
    std::string policy_json;      // serialized policy for writing
    std::string archive_json;     // serialized MAP-Elites archive (empty if no GA)
    std::string policy_sha256;
    int64_t     n_tensors_quantized;
    int64_t     n_tensors_skipped;
    float       total_mse;
    // S7 G6 acceptance gate result (populated when run_acceptance is set)
    bool                  acceptance_ran;
    ts_acceptance_result  acceptance;
    // L5 adaptive requantization result (populated when adaptive_requantize is set)
    bool        l5_ran = false;
    std::string l5_report_json;   // schema llama.tessera.l5-loop.v1

    // L5 joint PPL result (populated when l5_joint_mode is set, the
    // production default). Populated regardless of whether the
    // weights-only path also ran (l5_ran); the two paths are
    // independent and can both be set in --no-tessera-l5-joint=false
    // + adaptive_requantize=true scenarios (legacy).
    bool        l5_joint_ran = false;
    std::string l5_joint_report_json;     // schema llama.tessera.l5-joint-loop.v1
    bool        l5_joint_and_gate_passed = false;  // all active models' delta < epsilon
    float       l5_joint_winning_ppl = 0.0f;       // sum of normalized deltas (active only)
    int32_t     l5_joint_n_generations = 0;        // gens run (search history)
    // Strict pass result (only set when l5_joint_strict is true).
    bool        l5_joint_strict_ran = false;
    bool        l5_joint_strict_converged = false; // true = STRICT_CONVERGED
    float       l5_joint_strict_epsilon = 0.0f;    // 0.25% if strict
    float       l5_joint_strict_worst_delta = 0.0f;
    // Worst per-model delta in the winning entry. Always tracked (even
    // when strict is off) so the report can show "the worst model in
    // the winning policy" without recomputing. With the MAX metric,
    // this equals l5_joint_winning_ppl; with SUM, it is the bound on
    // the worst individual model regardless of the aggregate metric.
    float       l5_joint_winning_max_delta = 0.0f;
    // Which metric the search used (0=MAX, 1=SUM, 2=MEAN). Echoed in
    // the JSON report so the user knows what drove the search.
    int         l5_joint_metric_used = 0;

    // L5 scorer-map combine result (populated when params->l5_scorer is
    // set; Phase C of docs/l1-l6-telemetry-refinements-spec.md §9.4).
    // The --l5-scorer spec ("hessian:0.5,imatrix:0.3,grad:0.2") is joined
    // via ts_l5_combine over the per-tensor scorer maps; the combined map
    // and the per-scorer contributions land in l5_scorer_report_json.
    // The hessian map is the OBQ sensitivity of each tensor's ACTUAL
    // quantized reconstruction (qr.recon), scored against the diagonal of
    // H^{-1} from the calibration corpus (cached in v2_hessian_cache,
    // forward-only, keyed by scorer_version). The grad map is always empty
    // in the dispatch today (no output_sensitivity is captured).
    bool        l5_scorer_ran = false;
    std::string l5_scorer_report_json;   // schema llama.tessera.l5-scorer.v1
    int32_t     l5_hessian_n_scored     = 0;  // tensors with a hessian score
    int32_t     l5_hessian_n_cached     = 0;  // H_inv_diag from the DB cache
    int32_t     l5_hessian_n_factorized = 0;  // Cholesky factorizes this run
    int32_t     l5_hessian_n_skipped    = 0;  // 2D tensors w/o calibration data
};

// Run the full Tessera quantization pipeline.
// Returns 0 on success, non-zero on error.
int ts_dispatch_run(const ts_dispatch_params * params,
                    ts_dispatch_result * result,
                    std::string * err_msg);

// L5 adaptive requantize refine loop. Normally called by ts_dispatch_run when
// params->adaptive_requantize is set; exposed so the integration test can
// drive it directly. refine_map is keyed by tensor name; in_ctx/ggml_ctx are
// the input GGUF (for re-reading source weights) and out_ggml_ctx is the
// output descriptor context (refreshed via ts_gguf_repoint_tensor_cluster).
//
// db_wrap is optional. When non-null and its l4_outcome_buffer is
// non-null, the loop writes one l4_plan_outcome row per (tensor, gen)
// via ts_tessera_db_append_l4_outcome (the L5 feedback loop). The
// integration test passes nullptr.
//
// DEPRECATED: this is the weights-only per-tensor L5 path. Superseded
// by ts_dispatch_run_l5_joint (the joint PPL path, the production
// default). Kept as a fallback for --no-tessera-l5-joint. New code
// should use the joint path.
struct ts_dispatch_refine_entry;
struct ts_dispatch_db;
int ts_dispatch_run_l5_loop(
    const ts_dispatch_params * params,
    ts_dispatch_result * result,
    struct gguf_context * in_ctx,
    struct ggml_context * ggml_ctx,
    struct ggml_context * out_ggml_ctx,
    std::unordered_map<std::string, ts_dispatch_refine_entry> & refine_map,
    ts_dispatch_db * db_wrap);

// L5 joint PPL loop. THE PRODUCTION DEFAULT. Called by ts_dispatch_run
// when params->l5_joint_mode is true (the default). Runs the joint
// forward pass across the target + 3 spec drafters (DFlash, DSPark,
// MTP) + talker, evaluates per-model normalized PPL delta, and
// searches the joint (outlier_layout, algorithm, alpha, clip) policy
// space via coarse-to-fine with adaptive slippery detection.
//
// The drafter / talker GGUFs are loaded if their paths are non-empty;
// if a path is empty, that model is inactive and contributes 0 to
// the AND-gate (FP baseline). The calibration set is read from
// l5_joint_calibration_path; if empty, a synthetic fixture is
// generated (v1 schema, real text-to-audio target mapping at v3+).
//
// On success, result->l5_joint_ran is set, result->l5_joint_report
// contains the joint search history (JSON, schema
// llama.tessera.l5-joint-loop.v1), and (if l5_joint_strict) the strict
// pass result is appended.
//
// Real drafter / talker forward integration is in v3 follow-up
// (loading the qwen3-tts-talker model alongside the spec-decoding
// drafters; binding the real forward functions to the harness
// slots). For the production wiring, the harness uses synthetic
// all-zero-logits forwards (smoke test). The architecture is
// forward-compatible: swapping the synthetic forwards for real ones
// is a function-pointer replacement, no harness changes needed.
int ts_dispatch_run_l5_joint(
    const ts_dispatch_params * params,
    ts_dispatch_result * result,
    std::string * err_msg);

// L1.5 FP16 reference capture (§3 of docs/l1-l6-telemetry-refinements-spec.md).
//
// For each 2D weight tensor in the input GGUF, write the FP16 cast of
// the ORIGINAL (unquantized) weight to the L1.5 sidecar. This is the
// "true FP16 reference" — the FP16 ground truth that the kernel's
// dequant output is compared against by L3 coherence and (in v2) the
// L2 activation-space differential.
//
// The capture is a no-op when:
//   - sidecar_dir is empty
//   - tessera_debug::dequant_w4a4_enabled() is false
//   - tessera_debug::l15_dtype_is_f16() is false (the F32 legacy path
//     is handled by the existing runtime hook auto-populate branch and
//     doesn't need a calibration-time writer)
//
// Skips:
//   - Non-2D tensors (norms, biases, embeddings, expert stacks)
//   - Quantized input tensors (the input is expected to be BF16/FP16;
//     re-quantizing a quantized model is a different code path)
//
// on_input is the GGUF context (already loaded by ts_dispatch_run
// before this call); ggml_ctx is the ggml metadata context. The
// per-tensor data pointers are taken from t->data (which ts_dispatch_run
// patches into the mmap'd region at step 5). stride is the same
// dequant capture stride as the runtime hook (1 = every row).
//
// Returns 0 on success (or no-op), non-zero on hard error. err_msg
// (optional) is populated on error.
int ts_dispatch_capture_l15_references(
    const struct gguf_context * on_input,
    struct ggml_context * ggml_ctx,
    const std::string & sidecar_dir,
    int64_t stride,
    std::string * err_msg);
