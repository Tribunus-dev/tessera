//
// tessera-trajectory.h
//
// Trajectory record model for the Tessera agentic training data flywheel.
// Implements the llama.tessera.agent-traj.v1 JSON schema (see
// docs/agentic-training-data-flywheel-design.md) with a C API surface
// (ts_traj_*) that the validate CLI, the OpenHands event-log converter,
// and the closed-loop observe stage all use.
//
// The schema is a strict subset-and-superset of Harbor ATIF v1.7:
//   - ATIF's steps[] -> our messages[] (same record type, same
//     source / tool_call_id / observation correlation).
//   - ATIF's tool_definitions (v1.5) -> our agent.tool_definitions.
//   - ATIF's subagent_trajectories (v1.7) -> reserved (out of scope
//     for the v1 record; promote to v2 if/when we add multi-agent
//     capture).
// Tessera adds three v1 fields: task_source, task_taxonomy, reward.
// The schema name is llama.tessera.agent-traj.v1 to keep the existing
// Tessera convention (every schema is llama.tessera.<area>.vN) - this
// is what the rest of the codebase keys on.
//
// Pure logic: no llama/ggml dependency. nlohmann/json for parsing and
// formatting. ts_* C API follows the existing tessera-dataset /
// tessera-anonymizer convention: zero/return-int, out-params for
// results, std::string * err_msg for human-readable errors.
//

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ts_traj {

// Current schema version string. Bumping to v2 means: do not mutate
// v1 records; emit v2 records with a superset field set; the validate
// CLI accepts both.
constexpr const char * SCHEMA_V1 = "llama.tessera.agent-traj.v1";

// Maximum path length for the C API. Matches tessera-dataset.h.
constexpr int MAX_PATH = 1024;

// Per-trajectory validation result. errors[] is empty on full success.
// The CLI writes errors to stderr in line-per-error format; the test
// driver asserts on n_invalid and on the structured error contents.
struct ts_traj_validation_error {
    int line_no;            // 1-based line in the source file
    std::string trajectory_id;
    std::string field;      // dotted path, e.g. "messages[2].tool_calls[0].tool_call_id"
    std::string message;
};

struct ts_traj_validation_result {
    int n_valid = 0;
    int n_invalid = 0;
    int n_skipped = 0;       // wrong schema, parse error
    std::vector<ts_traj_validation_error> errors;
};

// Validate a JSONL trajectory file against the llama.tessera.agent-traj.v1
// schema. The same logic is reachable from C (ts_traj_validate_file) and
// from C++ (ts_traj::validate_file). Returns 0 on success (file readable,
// result populated); non-zero on I/O error with err_msg set.
int validate_file(const char * path, ts_traj_validation_result * result, std::string * err_msg);

}  // namespace ts_traj

// C API. Mirrors ts_dataset_run / ts_anonymize_string in the existing
// tessera-* modules. Pure C-linkage, no name mangling.
extern "C" {

// Validate a JSONL trajectory file. *n_valid, *n_invalid, *n_skipped
// (any of which may be NULL) are set on return. The errors[] array is
// written to a heap-allocated buffer; the caller must free it with
// ts_traj_free_errors(). Returns 0 on success (file readable), non-zero
// on I/O error with err_msg set (if err_msg is non-NULL).
//
// The C API returns counts only; the C++ API returns the full
// structured result. Tests use the C++ API; CLI uses the C API.
int ts_traj_validate_file(const char * path,
                          int * n_valid,
                          int * n_invalid,
                          int * n_skipped,
                          char ** err_msg_out);

void ts_traj_free_errors(char * err_msg);

}  // extern "C"
