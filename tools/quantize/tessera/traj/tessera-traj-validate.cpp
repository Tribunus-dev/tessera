//
// tessera-traj-validate.cpp
//
// CLI for the v1 schema gate. Reads a *.agent-traj.v1.jsonl file,
// validates each record, prints per-error lines to stderr, and exits
// 0 / 1 / 2 per the exit code contract in the design doc.
//
// Exit codes (pinned in --help):
//   0  every record validates (or no records; an empty file is OK)
//   1  one or more records failed validation (or wrong schema on
//      a record; that goes to n_skipped but still exits 1 - a
//      wrong-schema line is a real problem, not a pass)
//   2  I/O error (cannot open file, read failure, etc.)
//
// The CLI is also the boundary test entry point - test_traj_validate
// calls ts_traj::validate_file directly with the C++ API; the CLI
// just wraps it for human use.
//

#include "tessera-trajectory.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

static void print_help(const char * argv0) {
    std::fprintf(stderr,
        "tessera-traj-validate - schema-gate for llama.tessera.agent-traj.v1\n"
        "\n"
        "Usage: %s <input.jsonl>\n"
        "\n"
        "Validates each line against the v1 schema. Prints per-error\n"
        "lines to stderr; prints a one-line summary to stdout. Exits\n"
        "0 on all valid, 1 on any invalid or wrong-schema, 2 on I/O.\n"
        "\n"
        "Empty files are valid (exit 0). Lines with a wrong schema\n"
        "field are counted as skipped AND fail the run - a wrong\n"
        "schema is a real bug in the producer.\n",
        argv0);
}

int main(int argc, char ** argv) {
    if (argc != 2) {
        print_help(argv[0]);
        return argc == 1 ? 0 : 2;
    }
    if (std::strcmp(argv[1], "-h") == 0 || std::strcmp(argv[1], "--help") == 0) {
        print_help(argv[0]);
        return 0;
    }

    const char * path = argv[1];

    ts_traj::ts_traj_validation_result result;
    std::string err_msg;
    int rc = ts_traj::validate_file(path, &result, &err_msg);
    if (rc != 0) {
        std::fprintf(stderr, "tessera-traj-validate: %s\n", err_msg.c_str());
        return 2;
    }

    // Per-error lines to stderr. Stable, line-by-line, parseable.
    for (const auto & e : result.errors) {
        std::fprintf(stderr, "line %d traj=%s field=%s : %s\n",
                     e.line_no,
                     e.trajectory_id.empty() ? "(none)" : e.trajectory_id.c_str(),
                     e.field.empty() ? "(root)" : e.field.c_str(),
                     e.message.c_str());
    }

    // One-line summary to stdout. Used by the test driver to assert.
    std::printf("valid=%d invalid=%d skipped=%d\n",
                result.n_valid, result.n_invalid, result.n_skipped);

    return (result.n_invalid == 0 && result.n_skipped == 0) ? 0 : 1;
}
