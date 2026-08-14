#pragma once

//
// tessera-dispatch-internal.h
//
// Internal types shared between tessera-dispatch.cpp and its integration
// test (test_l5_dispatch.cpp). Not part of the public Tessera API surface;
// consumers outside the dispatch implementation and its tests should not
// include this file.
//

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cstdint>

#include "ggml.h"                 // enum ggml_type
#include "tessera-quant.h"       // ts_quant_result_2d, ts_quant_params_2d
#include "tessera-quantize-db.h" // ts_tessera_db, ts_tessera_db_l5_weight_list_entry
#include "tessera-db-buffer.h"   // ts_db_buffer
#include "tessera-regime.h"      // ts_regime_family_thresholds

// One captured 2D quantizable tensor from the step-7 walk. Stored once per
// tensor and indexed by name so the L5 refine loop can target tensors without
// re-walking the GGUF. act_scales_copy / inputGGUF index let the loop
// re-quantize without retaining every source weight in memory (sources are
// re-read from the input GGUF on demand, per the L5 memory budget).
struct ts_dispatch_refine_entry {
    std::string             name;
    std::string             family;
    int64_t                 gguf_idx = -1;     // index in in_ctx
    int64_t                 out_dim  = 0;
    int64_t                 in_dim   = 0;
    ts_quant_result_2d *    qr       = nullptr; // points into cluster_results
    ts_quant_params_2d      tqp{};             // baseline params applied at step 7
    std::vector<float>      act_scales_copy;   // owned copy (act_scales may alias imatrix memory)
};

// ---------------------------------------------------------------------------
// DuckDB store plumbing (pipeline refactor phase 4: moved out of
// tessera-dispatch.cpp so tessera-dispatch-db.cpp and every other dispatch
// module can share one definition; tessera-dispatch.h forward-declares this
// struct since ts_dispatch_run_l5_loop takes a pointer to it)
//
// ts_dispatch_db is the per-run state threaded through the GA hooks. It owns
// the open ts_tessera_db plus per-table write buffers. The buffers replace
// the previous per-tensor DuckDB Appender sharded map: each one is a single
// MPSC queue with a dedicated flusher thread, 65536-row batches, 1-second
// time flush, and sync-on-exit via the unique_ptr deleter. See
// tessera-db-buffer.h.
//
// Two buffers are owned:
//   eval_buffer       — ga_evaluations (the GA hot path; ~1.6M rows per run).
//   l4_outcome_buffer — l4_plan_outcome (the L5 feedback loop; one row per
//                       (tensor, iteration) in the adaptive_requantize loop).
//
// All DB calls are best-effort: a failure logs a one-line warning and the
// pipeline continues. The DB is a recording/warm-start aid, not a correctness
// requirement, so a corrupt file or full disk must never block quantization.
struct ts_dispatch_db {
    ts_tessera_db * db = nullptr;     // owned; null when --quantize-db is unset
    std::string      run_id;           // empty until begin_run succeeds
    std::string      model_hash;       // empty when hashing failed
    // Resume set: tensor names with a converged result for this run_id.
    // Populated at startup; the layer_skip_lookup callback checks membership.
    std::unordered_set<std::string> converged;
    // GA-prep warm-start registry. Populated at open time from
    // l5_weights (the orchestrator's retune output); the
    // family_seed_lookup hook prefers entries here over the
    // legacy ga_results-based seed lookup because l5_weights is
    // the more recent + orchestrator-scored signal. Keyed by
    // family; empty when --tessera-db is unset or the model has
    // no l5_weights rows yet.
    std::unordered_map<std::string, ts_tessera_db_l5_weight_list_entry>
        l5_weight_map;
    // Per-table write buffers. Both null when --quantize-db is unset.
    ts_db_buffer *   eval_buffer       = nullptr;
    ts_db_buffer *   l4_outcome_buffer = nullptr;
    // Tier 2 regime thresholds: learned kurtosis/eff_rank cutoffs per family.
    // Populated at open time from regime_thresholds DuckDB table.
    // Keyed by family string ("attn_q", "ffn_gate", etc.); empty when
    // no prior exists (the static cascade is used instead).
    std::unordered_map<std::string, ts_regime_family_thresholds>
        regime_threshold_map;
};

// Open the store and begin a run. Returns a heap-allocated ts_dispatch_db
// (owned by the caller via unique_ptr) or nullptr on failure / when the path
// is empty. model_path is hashed to fingerprint this run for warm-start.
ts_dispatch_db * ts_dispatch_db_open(
    const struct ts_dispatch_params * params, bool verbose);

// Finalize: mark the run complete (or failed) and close any appenders left
// open by an early-return path. Called from the unique_ptr deleter so every
// exit from ts_dispatch_run cleans up.
void ts_dispatch_db_close(ts_dispatch_db * wrap, const char * status);

// Per-evaluation callback: formats one row and pushes it into the shared
// ga_evaluations buffer.
void ts_dispatch_eval_recorder(const struct ts_awq_layer * layer,
                               int32_t generation, int32_t island,
                               int32_t candidate_idx,
                               const struct ts_awq_candidate * cand,
                               const struct ts_awq_score    * score,
                               void * user);

// Look up a family warm-start seed in the persistent store (l5_weights,
// falling back to legacy ga_results).
bool ts_dispatch_family_seed_lookup(const char * family,
                                    struct ts_awq_candidate * out,
                                    float * out_composite,
                                    void * user);

// Resume hook: short-circuit the GA for tensors that already converged for
// this model in a prior run.
bool ts_dispatch_layer_skip(const struct ts_awq_layer * layer,
                            struct ts_awq_evolve_result * out_result,
                            void * user);

// ---------------------------------------------------------------------------
// Shared helpers (pipeline refactor phase 4: moved out of
// tessera-dispatch.cpp so tessera-dispatch-gaprep.cpp, tessera-dispatch-
// walk.cpp, and tessera-dispatch-acceptance.cpp can all call them without
// duplicating the logic)
// ---------------------------------------------------------------------------

std::vector<uint8_t> ts_to_bytes_u32(const std::vector<uint32_t> & v);
std::vector<uint8_t> ts_to_bytes_u16(const std::vector<uint16_t> & v);
std::vector<uint8_t> ts_to_bytes_i8(const std::vector<int8_t> & v);
std::vector<uint8_t> ts_to_bytes_i32(const std::vector<int32_t> & v);

// A tensor is quantizable if it is a 2D or 3D F32/F16 weight matrix whose
// name maps to a known tensor family (attn, ffn, etc).
bool ts_is_quantizable(const char * name, enum ggml_type type, int n_dims);

// Convert a ggml tensor's data to a flat F32 buffer. Handles F32 (copy) and
// F16/quantized (generic type-traits dequant). Returns empty on unsupported
// type or null data.
std::vector<float> ts_tensor_to_f32(const struct ggml_tensor * t);

// Resolve per-channel AWQ activation scales for one tensor. Priority: (1)
// imatrix lookup, (2) mean |activation| derived from the calibration corpus
// when its width matches the tensor in_dim. Returns nullptr when neither
// source is available. When the corpus path is used the result points into
// *scratch, which the caller must keep alive for as long as the returned
// pointer is needed.
const float * ts_dispatch_act_scales(
        const struct ts_imatrix * imatrix, const char * name, int64_t in_dim,
        const float * calib_X, int64_t calib_in_dim, int64_t calib_n_tokens,
        std::vector<float> * scratch);

// Resolve a tensor's operative modality against the multimodal imatrix.
const struct ts_mm_imatrix_entry * ts_dispatch_mm_resolve(
        const struct ts_mm_imatrix * mm, const char * name, int inferred, int * modality);

// Run the per-modality AWQ alpha search for one tensor against the
// multimodal imatrix.
int ts_dispatch_mm_awq(const struct ts_mm_imatrix * mm, const char * name,
                       const float * weights, int64_t out_dim, int64_t in_dim,
                       struct ts_mm_awq_result * result);

// Re-read one tensor's source weights from the input GGUF as F32. Returns an
// empty vector on failure (matching ts_tensor_to_f32's contract).
std::vector<float> ts_refine_reread_source(struct gguf_context * in_ctx,
                                           struct ggml_context * ggml_ctx,
                                           const ts_dispatch_refine_entry & e);

// Relative Frobenius between source weights and a quant result's recon.
float ts_refine_rel_frob(const float * src, const ts_quant_result_2d * qr,
                         int64_t n);

// Join a vector of strings with a separator (used for the per-family JSON
// array in the report).
std::string ts_join(const std::vector<std::string> & parts,
                    const std::string & sep);

// Exact storage footprint (bits) of a 2D quant result: every GGUF component
// the format writes.
int64_t ts_dispatch_result_bits(const ts_quant_result_2d * qr);
