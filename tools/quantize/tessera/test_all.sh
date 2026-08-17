#!/bin/bash
# Tessera C++ port integration test suite.
# Usage: bash tools/quantize/tessera/test_all.sh
# Run from the repository root.
#
# Two-phase driver:
#   1. Compile every test in parallel (xargs -P nproc, default-nproc unless
#      TESSERA_TEST_JOBS=N is set), keyed by a content-hash cache so repeat
#      runs skip work.
#   2. Run every test serially in the same order they were declared.
#
# Per-test result line: "<name>\t<status>\t<log_path>" where status is one of
#   pass | fail | skip | compile_fail. Workers write to a shared sink; the
#   driver prints in declaration order so the per-test column matches the
#   source order.

set -e
set -o pipefail

PASS=0
FAIL=0
SKIP=0
ERRORS=""

T=tools/quantize/tessera
C=common/tessera-debug
BIN=/tmp/tessera_test_bin
CXX="g++ -std=c++17 -O2"
CXX_PRELUDE="g++ -std=c++17 -O2"
TS_DUCKDB_DIR=third-party/duckdb
UNAME=$(uname)

# Platform-aware link-line tokens. $TS_BLAS is empty on macOS (the legacy
# shape) and "-I/usr/include/openblas" on Linux. Tests that call Accelerate-
# only paths fall back to scalar when neither is present (tessera-vec.cpp /
# tessera-linalg.cpp both compile-gate the BLAS paths).
if [ "$UNAME" = "Darwin" ]; then
    TS_BLAS="$TS_BLAS"
else
    TS_BLAS="-I/usr/include/openblas"
fi

# Parallelism: TESSERA_TEST_JOBS overrides nproc. Default to all cores so a
# 4- or 8-core box uses them all.
if [ -n "${TESSERA_TEST_JOBS:-}" ]; then
    JOBS="$TESSERA_TEST_JOBS"
else
    JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fi
[ "$JOBS" -ge 1 ] || JOBS=1

mkdir -p "$BIN/cache" "$BIN/build"
# Generated header consumed by l15 and l1_sidecar via -I "$BIN".
printf '#pragma once\n#define TESSERA_KERNEL_VERSION "test"\n#define TESSERA_MAIN_TIP "test"\n' \
    > "$BIN/tessera-build-info.h"

# --- Cache key helper --------------------------------------------------------
# Compute a sha1 over (canonicalized CXX args) + (g++ -MM -MG dep output) for
# a given argv. Output: 40-char hex key on stdout. The dep-scan happens via
# ONE g++ -MM -MG invocation listing every .cpp/.cc source in argv (each
# source produces its own ".o:" rule in the output). The raw g++ output
# (with line-continuation backslashes) is fully deterministic across runs,
# so hashing it directly is sound and avoids brittle multi-line parsing.
#
# Cost: ~40ms per test (one g++ -MM -MG invocation). With JOBS=N parallel
# xargs, the total wall-clock for the cache-key phase is ~num_tests/N*40ms.
#
# Side effect: writes a single file used by cache_put() on a cache miss:
#   $BIN/build/<name>.canon - the canonicalized argv + name + platform + BLAS
#                            + the raw g++ -MM -MG output (joined).
cache_key() {
    local name="$1"
    shift
    local prelude="$CXX_PRELUDE"
    local args=("$@")

    {
        echo "name=$name"
        echo "uname=$UNAME"
        echo "TS_BLAS=$TS_BLAS"
        printf '%s\n' "${args[@]}" | sort -u
    } > "$BIN/build/$name.canon"

    # Build list of .cpp/.cc sources and run g++ -MM -MG ONCE with all of
    # them. -x c++ lets us accept sources that are explicit (the rest of the
    # argv is flags + paths). -MG suppresses abort on missing headers.
    : > "$BIN/build/$name.deps"
    local src
    local sources=()
    for src in "${args[@]}"; do
        case "$src" in
            *.cpp|*.cc) sources+=("$src") ;;
        esac
    done
    if [ "${#sources[@]}" -gt 0 ]; then
        $prelude -MM -MG -x c++ "${args[@]}" "${sources[@]}" 2>/dev/null \
            >> "$BIN/build/$name.deps" || true
    fi

    {
        cat "$BIN/build/$name.canon"
        cat "$BIN/build/$name.deps"
    } | sha1sum | awk '{print $1}'
}

# --- Cache lookup / populate -------------------------------------------------
# Look up a cached binary for name with the given cache key. Echoes "hit" or
# "miss". On miss, nothing is done (worker will compile and populate).
cache_get() {
    local name="$1"
    local key="$2"
    if [ -n "$key" ] && [ -x "$BIN/cache/$key/$name" ]; then
        # Restore the executable bit (cp via cat below keeps it; explicit
        # chmod guards against an existing cache entry from a different umask).
        cp -p "$BIN/cache/$key/$name" "$BIN/$name" 2>/dev/null \
            || cp "$BIN/cache/$key/$name" "$BIN/$name"
        chmod +x "$BIN/$name"
        echo hit
    else
        echo miss
    fi
}

# Populate cache after a successful compile. Stores cmd line + dep list for
# debug alongside the binary.
cache_put() {
    local name="$1"
    local key="$2"
    mkdir -p "$BIN/cache/$key"
    cp -p "$BIN/$name" "$BIN/cache/$key/$name" 2>/dev/null \
        || cp "$BIN/$name" "$BIN/cache/$key/$name"
    chmod +x "$BIN/cache/$key/$name"
    [ -f "$BIN/build/$name.canon" ] && cp "$BIN/build/$name.canon" "$BIN/cache/$key/cmd.txt"
    [ -f "$BIN/build/$name.deps" ]  && cp "$BIN/build/$name.deps"  "$BIN/cache/$key/deps.txt"
}

# --- The worker invoked by xargs ---------------------------------------------
# Reads a job-spec line from stdin of the form: "<name>|<key>|<args...>"
# Args are space-separated, already shell-split safe (we use printf '%q'
# below when enqueuing). Runs the compile; copies into cache; writes one
# result line.
ts_compile_worker() {
    # COMPILE_FILE is TAB-separated: <name>\t<key>\t<args...>. We use a
    # sentinel: the compile line starts with a literal "compile:" prefix to
    # distinguish it from other data; the args are already shell-quoted via
    # printf %q at enqueue time.
    local line="$1"
    if [[ "$line" != compile:* ]]; then
        return 1
    fi
    local body="${line#compile:}"
    local name="${body%%$'\t'*}"
    local rest="${body#*$'\t'}"
    local key="${rest%%$'\t'*}"
    local args="${rest#*$'\t'}"
    local src_log="/tmp/tessera_build_${name}.log"

    # Reassemble argv (args is shell-quoted via printf %q at enqueue time).
    # shellcheck disable=SC2086
    if $CXX_PRELUDE $args -o "$BIN/$name" > "$src_log" 2>&1; then
        cache_put "$name" "$key"
        printf '%s\tcompiled\t%s\n' "$name" "$src_log"
    else
        printf '%s\tcompile_fail\t%s\n' "$name" "$src_log"
    fi
}
export -f ts_compile_worker cache_put cache_get cache_key
# ts_key_worker is exported after its definition further below.

# --- Run a single test binary, log to /tmp/tessera_test_<name>.log ----------
ts_run_one() {
    local name="$1"
    local log="/tmp/tessera_test_${name}.log"
    if [ ! -x "$BIN/$name" ]; then
        # Compile failed; surface build log via ERRORS at end.
        printf '%s' "$name"
        return 1
    fi
    if "$BIN/$name" > "$log" 2>&1; then
        printf '%s' "$name"
        return 0
    fi
    printf '%s' "$name"
    return 1
}

# --- Job staging ------------------------------------------------------------
# Declaration model: each test appends ONE line to $DECL_FILE in the form
# "<name>|<reason>|quote1 args quote2 args ...". `reason` is "plain" for an
# unconditional run, or the SKIP message (e.g. "needs CMake build for libgguf")
# for a gated test whose gate fails - but the gate is evaluated LAZILY at
# stage 2 so failure can skip the cache_key scan.
#
# Cache-key resolution happens in parallel at stage 2 (xargs -P $JOBS
# running cache_key across every declared job at once). At stage 3 we
# fold the keys + gate decisions back into $RESULTS_FILE / $COMPILE_FILE
# in original declaration order, so phase-4's printing matches the source.
DECL_FILE="$BIN/build/decls.tmp"
KEYS_FILE="$BIN/build/keys.tmp"
RESULTS_FILE="$BIN/build/results.tmp"
COMPILE_FILE="$BIN/build/compile.tmp"
# Final ordered record (one line per declared test, in declaration order).
# Produced by phase 4.5 from $RESULTS_FILE + $DECL_FILE.
DECL_FINAL_FILE="$BIN/build/decls.final.tmp"
: > "$DECL_FILE"
: > "$KEYS_FILE"
: > "$RESULTS_FILE"
: > "$COMPILE_FILE"
: > "$DECL_FINAL_FILE"

# Stage 1 helpers: stage a job declaration.

job_plain() {
    local name="$1"
    shift
    local args_quoted
    args_quoted=$(printf '%q ' "$@")
    printf '%s|plain|%s\n' "$name" "$args_quoted" >> "$DECL_FILE"
}

job_skip() {
    local name="$1"
    shift
    local gate_reason="$1"
    shift
    local gate_test="$1"
    shift
    local args_quoted
    args_quoted=$(printf '%q ' "$@")
    printf '%s|skip|%s|%s|%s\n' "$name" "$gate_reason" "$gate_test" \
        "$args_quoted" >> "$DECL_FILE"
}

# Stage 2 worker: compute the cache key for a plain job (or evaluate the
# gate for a skip job and emit "SKIP" without a key scan). Writes a single
# line to $KEYS_FILE: "<name>|<gate_decision>|<key>" where gate_decision is
# "run" (proceed to cache lookup), "skip" (gate failed, do not compile), or
# "nokey" (degenerate; rarely used).
#
# Invoked as: xargs -P $JOBS -L 1 -I {} bash -c 'ts_key_worker "$@"' _ {}
ts_key_worker() {
    local line="$1"
    local name="${line%%|*}"
    local rest="${line#*|}"
    local kind="${rest%%|*}"
    local args_quoted
    local gate_test gate_reason

    case "$kind" in
        plain)
            args_quoted="${rest#*|}"
            # Reconstruct the argv from the quoted form for cache_key.
            # shellcheck disable=SC2086
            local key
            key=$(eval "set -- $args_quoted; cache_key \"$name\" \"\$@\"")
            printf '%s|run|%s\n' "$name" "$key"
            ;;
        skip)
            local payload="${rest#*|}"
            gate_reason="${payload%%|*}"
            local rest2="${payload#*|}"
            gate_test="${rest2%%|*}"
            if eval "$gate_test" >/dev/null 2>&1; then
                args_quoted="${rest2#*|}"
                # shellcheck disable=SC2086
                local key
                key=$(eval "set -- $args_quoted; cache_key \"$name\" \"\$@\"")
                printf '%s|run|%s\n' "$name" "$key"
            else
                printf '%s|skip|%s\n' "$name" "$gate_reason"
            fi
            ;;
    esac
}
export -f ts_key_worker
export BIN CXX_PRELUDE UNAME TS_BLAS

# --- Duckdb amalgamation (one-shot, before workers) -------------------------
DUCKDB_O="$BIN/duckdb.o"
# Hash includes the contents of duckdb.cpp plus -DNDEBUG; computed only if the
# file's content hash differs from the cached .o's recorded key. Keep the key
# in DUCKDB_KEY so ga_model_role can include it in its own cache key.
DUCKDB_KEY_FILE="$BIN/build/duckdb.key"
if [ -f "$BIN/duckdb.o" ] && [ -f "$DUCKDB_KEY_FILE" ]; then
    DUCKDB_KEY=$(cat "$DUCKDB_KEY_FILE")
else
    DUCKDB_KEY=""
fi
DUCKDB_NEEDED_KEY=$( {
    echo "uname=$UNAME"
    echo "CXX=$CXX"
    echo "-DNDEBUG"
    echo "-I third-party/duckdb"
    echo "src=$TS_DUCKDB_DIR/duckdb.cpp"
    sha1sum "$TS_DUCKDB_DIR/duckdb.cpp" 2>/dev/null | awk '{print $1}'
} | sha1sum | awk '{print $1}')

if [ -f "$BIN/duckdb.o" ] && [ "$DUCKDB_KEY" = "$DUCKDB_NEEDED_KEY" ]; then
    : # cache hit
elif [ "${TESSERA_SKIP_DUCKDB:-0}" = "1" ]; then
    : # operator opted out (e.g. to validate parallel path without paying
      # the 9-minute single-threaded duckdb compile).
    rm -f "$BIN/duckdb.o" "$DUCKDB_KEY_FILE"
else
    if $CXX_PRELUDE -DNDEBUG -I third-party/duckdb \
            -c "$TS_DUCKDB_DIR/duckdb.cpp" -o "$BIN/duckdb.o" \
            > /tmp/tessera_build_duckdb.log 2>&1; then
        printf '%s' "$DUCKDB_NEEDED_KEY" > "$DUCKDB_KEY_FILE"
    else
        printf "  %-30s" "duckdb_amalgamation"
        echo "FAIL (compile, see /tmp/tessera_build_duckdb.log)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS"$'\n'"  duckdb_amalgamation: see /tmp/tessera_build_duckdb.log"
        rm -f "$BIN/duckdb.o"
    fi
fi

echo "Tessera integration tests"
echo ""

# ============================================================================
# Job declarations - one block per test, in declaration order. The order is
# preserved end-to-end so PASS/SKIP lines and the column alignment match the
# pre-refactor output exactly.
# ============================================================================

# --- Standalone (test + own module) ---
job_plain linalg $T/test_linalg.cpp $T/tessera-linalg.cpp $TS_BLAS
job_plain lbfgs $T/test_lbfgs.cpp $T/tessera-lbfgs.cpp
job_plain awq $T/test_awq.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp $T/tessera-policy.cpp -I common -I vendor $TS_BLAS
job_plain awq_fitness $T/test_awq_fitness.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp $T/tessera-policy.cpp -I common -I vendor $TS_BLAS
job_plain flrq $T/test_flrq.cpp $T/tessera-flrq.cpp $T/tessera-linalg.cpp -I vendor $TS_BLAS
job_plain l5 $T/test_l5.cpp $T/tessera-l5.cpp $T/tessera-septq.cpp -I vendor $TS_BLAS
# imatrix needs libgguf (for gguf_init_from_file in common_imatrix_load);
# skip in the standalone harness - covered by the CMake build.
job_skip imatrix "needs CMake build for libgguf" \
    '[ -f build/ggml/src/libgguf.a ] || [ -f build/ggml/src/libgguf.dylib ]' \
    $T/test_imatrix.cpp $T/tessera-imatrix.cpp common/imatrix-loader.cpp \
    -I common -I include -I ggml/include -I ggml/src \
    -L build/ggml/src -lgguf -lggml $TS_BLAS
job_plain corpus $T/test_corpus.cpp $T/tessera-corpus.cpp
job_plain ppl $T/test_ppl.cpp $T/tessera-ppl.cpp
# l5_joint and ppl_harness need a CMake-built libggml.dylib; the
# build-ane path is the default link line. (Same shape as pre-refactor.)
job_skip l5_joint "needs CMake build for libggml" \
    '[ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]' \
    -I ../../common -I ggml/include -I ggml/src -I vendor -I $C -I $T \
    -L build-ane/bin -lggml -lggml-base
job_skip ppl_harness "needs CMake build for libggml" \
    '[ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]' \
    -I ../../common -I ggml/include -I ggml/src -I vendor -I $C -I $T \
    -L build-ane/bin -lggml -lggml-base
# Real per-tensor activation capture sidecar (origin/main "pipeline refactor
# stage 2"): write/read round-trip for the v3-format-compatible train/heldout
# activation sidecar produced by llama-imatrix --activation-capture. Needs
# libggml for ggml_fp32_to_fp16/ggml_fp16_to_fp32 (test fixture data only).
job_skip activation_sidecar "needs CMake build for libggml" \
    '[ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]' \
    $T/test_activation_sidecar.cpp $T/tessera-activation-sidecar.cpp $C/tessera-sidecar-v3.cpp \
    -I common -I $C -I ggml/include \
    -L build-ane/bin -lggml -lggml-base
# Real per-tensor activation capture reservoir sampling (origin/main
# "pipeline refactor stage 5"): Vitter's Algorithm R, header-only, no
# ggml/llama dependency.
job_plain activation_reservoir $T/test_activation_reservoir.cpp -I $T
job_plain gen_joint_calib $T/gen_joint_calib.cpp
job_plain ab_harness $T/test_ab_harness.cpp $T/tessera-ab-harness.cpp
job_plain acceptance $T/test_acceptance.cpp $T/tessera-acceptance.cpp $T/tessera-ab-harness.cpp
job_plain higgs $T/test_higgs.cpp $T/tessera-higgs.cpp
job_plain regime $T/test_regime.cpp $T/tessera-regime.cpp
job_plain peqat $T/test_peqat.cpp $T/tessera-peqat.cpp
job_plain septq $T/test_septq.cpp $T/tessera-septq.cpp -I vendor $TS_BLAS
job_plain vec $T/test_vec.cpp $T/tessera-vec.cpp $TS_BLAS
# tessera-quant.cpp holds unguarded ts_metal_* calls; link the stub so the
# symbol resolves on a non-HIP box. tessera-septq.cpp is also pulled in
# because tessera-quant.cpp now dispatches into SEPTQ when params->use_septq
# (operative-routing's FLRQ profile and the w4a4 activation-aware path).
job_plain quant $T/test_quant.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-metal-stub.cpp $T/tessera-septq.cpp -I ggml/src -I vendor $TS_BLAS
job_plain w4a4 $T/test_w4a4.cpp $T/tessera-w4a4.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-metal-stub.cpp $T/tessera-septq.cpp -I ggml/src -I vendor $TS_BLAS
job_plain moe_shapes $T/test_moe_shapes.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-metal-stub.cpp $T/tessera-septq.cpp -I ggml/src -I vendor $TS_BLAS
job_plain operative_routing $T/test_operative_routing.cpp $T/tessera-regime.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-metal-stub.cpp $T/tessera-septq.cpp -I ggml/src -I vendor $TS_BLAS
job_skip dispatch "needs CMake build for libgguf" \
    '[ -f build/ggml/src/libgguf.a ] || [ -f build/ggml/src/libgguf.dylib ]' \
    $T/test_dispatch.cpp $T/tessera-dispatch.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp \
    -I common -I ggml/include -I ggml/src -L build/ggml/src -lgguf -lggml $TS_BLAS
# T640 core=nullptr transport parity. 4-way libggml gate; needs -lggml-cpu.
# Inner-pick of $GGML_LIB is implicit in the picked -L/-l/-Wl args recorded
# below. The actual link args depend on which build artifact is present; we
# emit them in the GA from the gate test so the orchestrator never sees
# $GGML_LIB as a free variable.
job_skip t640_core_reconstruct_parity "needs CMake build for libggml" \
    '[ -f build/ggml/src/libggml.a ] || [ -f build-ffi/ggml/src/libggml.a ] || [ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]' \
    $T/test_t640_core_reconstruct_parity.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tile-detect.cpp $T/tessera-metal-stub.cpp \
    -I ggml/include -I ggml/src -I $T \
    -L build-ane/bin -lggml -lggml-base -lggml-cpu
job_skip l5_dispatch "needs CMake build for libgguf" \
    '[ -f build/ggml/src/libgguf.a ] || [ -f build/ggml/src/libgguf.dylib ]' \
    $T/test_l5_dispatch.cpp $T/tessera-dispatch.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp $T/tessera-l2-diff.cpp $T/tessera-l3-coherence.cpp $T/tessera-l5.cpp $T/tessera-ppl.cpp $C/tessera-sidecar-v3.cpp \
    -I common -I ggml/include -I ggml/src -I vendor -I $C -L build/ggml/src -lgguf -lggml $TS_BLAS
job_plain search $T/test_search.cpp $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp -I vendor $TS_BLAS
job_plain champq $T/test_champq.cpp $T/tessera-champq.cpp $T/tessera-lbfgs.cpp -I vendor $TS_BLAS
job_plain map_elites $T/test_map_elites.cpp $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp -I vendor $TS_BLAS
job_plain modality_routing $T/test_modality_routing.cpp $T/tessera-regime.cpp $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp -I vendor $TS_BLAS
job_plain higgs_integration $T/test_higgs_integration.cpp $T/tessera-higgs.cpp $T/tessera-higgs-cache.cpp $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-metal-stub.cpp $T/tessera-septq.cpp -I vendor -I ggml/src $TS_BLAS
job_plain l15 $T/test_l15.cpp $T/tessera-l15.cpp $C/tessera-debug.cpp $C/tessera-sidecar-v3.cpp $T/tessera-vec.cpp -I $C -I "$BIN" $TS_BLAS
job_plain l1_fitness $T/test_l1_fitness.cpp $T/tessera-l1-fitness.cpp $C/tessera-sidecar-v3.cpp $T/tessera-metal-stub.cpp -I $C
job_plain l1_fitness_tail $T/test_l1_fitness_tail.cpp $T/tessera-l1-fitness.cpp $C/tessera-sidecar-v3.cpp $T/tessera-metal-stub.cpp -I $C
job_plain l2l5 $T/test_l2l5.cpp $T/tessera-l2-diff.cpp $T/tessera-l3-coherence.cpp $T/tessera-l5.cpp $T/tessera-ppl.cpp $T/tessera-linalg.cpp $T/tessera-septq.cpp $C/tessera-sidecar-v3.cpp -I vendor -I $C $TS_BLAS
job_plain policy $T/test_policy.cpp $T/tessera-policy.cpp -I vendor
job_plain capability_loop $T/test_capability_loop.cpp $T/tessera-capability-eval.cpp $T/tessera-adapt.cpp -I vendor
job_plain anonymizer $T/test_anonymizer.cpp $T/tessera-anonymizer.cpp -I vendor
job_plain scrub $T/test_scrub.cpp $T/tessera-scrub.cpp
job_plain throughput $T/test_throughput.cpp $T/tessera-throughput.cpp -I vendor
job_plain lk_loss $T/test_lk_loss.cpp $T/tessera-lk-loss.cpp
job_plain dataset $T/test_dataset.cpp $T/tessera-dataset.cpp $T/tessera-dpace.cpp -I vendor
job_plain dpace $T/test_dpace.cpp $T/tessera-dpace.cpp
job_plain features $T/test_features.cpp $T/tessera-features.cpp -I vendor
job_plain lk_train_data $T/test_lk_train_data.cpp $T/tessera-lk-train-data.cpp $T/tessera-lk-loss.cpp -I vendor
job_plain dflash_train_data $T/test_dflash_train_data.cpp $T/tessera-dflash-train-data.cpp -I vendor
job_plain imatrix_drafter_features $T/test_imatrix_drafter_features.cpp $T/tessera-features.cpp -I vendor
job_plain dartquant $T/test_dartquant.cpp $T/tessera-dartquant.cpp $T/tessera-linalg.cpp -I vendor $TS_BLAS
job_plain sidecar_v3 $C/test_sidecar_v3.cpp $C/tessera-sidecar-v3.cpp -I $C
job_plain l1_sidecar $T/test_l1_sidecar.cpp $C/tessera-debug.cpp $C/tessera-sidecar-v3.cpp -I $C -I "$BIN"
# tessera_db_indexes and ga_model_role both consume $BIN/duckdb.o so the
# duckdb amalgamation is compiled once in phase 0, not 2x (or 3x) inside
# the parallel pool (which would serialize itself on the same disk).
job_plain tessera_db_indexes $T/test_tessera_db_indexes.cpp $T/tessera-quantize-db.cpp $T/tessera-db-buffer.cpp "$BIN/duckdb.o" -I $TS_DUCKDB_DIR -I $T
job_plain coreml_bridge $T/test_coreml_bridge.cpp $T/tessera-coreml.cpp $T/tessera-coreml-builder.cpp $T/tessera-coreml-metadata.cpp $T/tessera-coreml-mil.cpp $T/tessera-coreml-telemetry.cpp -I ggml/include
job_plain coreml_mil $T/test_coreml_mil.cpp $T/tessera-coreml-mil.cpp $T/tessera-coreml-telemetry.cpp $T/tessera-coreml-builder.cpp $T/tessera-coreml.cpp -I ggml/include
# ga_model_role uses the cached $BIN/duckdb.o (or is converted to SKIP if
# the duckdb.o build failed). Each job_* call resolves the gate immediately
# and writes to $RESULTS_FILE / $COMPILE_FILE in declaration order.
job_plain ga_model_role tests/test-tessera-ga-model-role.cpp $T/tessera-quantize-db.cpp $T/tessera-db-buffer.cpp "$BIN/duckdb.o" -I third-party/duckdb -I $T -I vendor

# ============================================================================
# Stage 2: parallel compute-keys (xargs -P $JOBS). Each declaration in
# $DECL_FILE becomes one ts_key_worker invocation. Output is in arbitrary
# order; the fold at stage 3 joins it back to declaration order.
# ============================================================================
if [ -s "$DECL_FILE" ]; then
    xargs -P "$JOBS" -I {} bash -c 'ts_key_worker "$@"' _ {} \
        < "$DECL_FILE" > "$KEYS_FILE"
fi

# ============================================================================
# Stage 3: fold $DECL_FILE + $KEYS_FILE -> $RESULTS_FILE + $COMPILE_FILE
# (in declaration order). Each plain/runnable job becomes either a
# (cache_hit, -) result or a (pending, key, args) compile entry.
# ============================================================================
declare -A KEY_FOR=()
declare -A REASON_FOR=()
# KEYS_FILE is <name>|<decision>|<value>. KEYS_FILE has 3 pipe-separated
# fields but the value (3rd) may itself contain a pipe (e.g. a quoted gate
# reason like "needs CMake build for libgguf"). Use `read -d ''` so the
# value slurps the rest of the line including any pipes it contains.
while IFS='|' read -r n d r; do
    KEY_FOR["$n"]="$r"
    REASON_FOR["$n"]="$d"
done < "$KEYS_FILE"

while IFS='|' read -r name kind rest; do
    case "$kind" in
        plain)
            local_key="${KEY_FOR[$name]}"
            local_args="$rest"
            if [ "${REASON_FOR[$name]}" = "skip" ]; then
                printf '%s\tskip_gate\t%s\n' "$name" "${KEY_FOR[$name]}" \
                    >> "$RESULTS_FILE"
            elif [ "$(cache_get "$name" "$local_key")" = "hit" ]; then
                printf '%s\tcache_hit\t-\n' "$name" >> "$RESULTS_FILE"
            else
                # COMPILE_FILE entries are "compile:"-prefixed; see worker.
                # Do NOT write a "pending" stub to RESULTS_FILE here — the
                # xargs pool is the sole writer of compiled / compile_fail
                # records, and phase 4.5 folds all status entries back into
                # declaration order using DECL_FILE.
                printf 'compile:%s\t%s\t%s\n' "$name" "$local_key" "$local_args" \
                    >> "$COMPILE_FILE"
            fi
            ;;
        skip)
            if [ "${REASON_FOR[$name]}" = "skip" ]; then
                printf '%s\tskip_gate\t%s\n' "$name" "${KEY_FOR[$name]}" \
                    >> "$RESULTS_FILE"
            else
                local_key="${KEY_FOR[$name]}"
                # Skip past "<reason>|<gate_test>|" prefix.
                local_args="${rest#*|*|*|}"
                if [ "$(cache_get "$name" "$local_key")" = "hit" ]; then
                    printf '%s\tcache_hit\t-\n' "$name" >> "$RESULTS_FILE"
                else
                    printf 'compile:%s\t%s\t%s\n' "$name" "$local_key" "$local_args" \
                        >> "$COMPILE_FILE"
                fi
            fi
            ;;
    esac
done < "$DECL_FILE"

# ============================================================================
# Special handling for ga_model_role: it depends on $BIN/duckdb.o, which the
# duckdb_amalgamation step above either produced (or refreshed) or failed to
# produce. Convert the cached/pending entry to SKIP if the .o is absent.
# ============================================================================
if [ ! -f "$BIN/duckdb.o" ]; then
    # tessera_db_indexes and ga_model_role both consume $BIN/duckdb.o. Skip
    # both if it didn't build, with the original driver message. In the new
    # pipeline these tests have COMPILE_FILE entries (no RESULTS_FILE entry
    # yet, since pending stubs are no longer emitted); we add skip_gate
    # records directly here and drop their COMPILE_FILE entries.
    printf 'tessera_db_indexes\tskip_gate\tduckdb amalgamation build failed\n' \
        >> "$RESULTS_FILE"
    printf 'ga_model_role\tskip_gate\tduckdb amalgamation build failed\n' \
        >> "$RESULTS_FILE"
    awk -F'\t' '$1!="tessera_db_indexes" && $1!="ga_model_role" { print }' \
        "$COMPILE_FILE" > "$COMPILE_FILE.tmp" && mv "$COMPILE_FILE.tmp" "$COMPILE_FILE"
fi

# ============================================================================
# Phase 4: parallel compile (xargs -P $JOBS).
# ============================================================================
if [ -s "$COMPILE_FILE" ]; then
    xargs -P "$JOBS" -I {} bash -c 'ts_compile_worker "$@"' _ {} \
        < "$COMPILE_FILE" >> "$RESULTS_FILE"
fi

# ============================================================================
# Phase 4.5: fold RESULTS_FILE back onto declaration order. RESULTS_FILE
# currently holds (a) cache_hit / skip_gate entries from stage 3 in
# declaration order, and (b) compile results from xargs in arbitrary order.
# Build an associative array of "latest status per name" and walk $DECL_FILE
# (which is in declaration order) emitting one final record per name.
# ============================================================================
declare -A FINAL_STATUS=()
declare -A FINAL_LOG=()
while IFS=$'\t' read -r n s lp; do
    FINAL_STATUS["$n"]="$s"
    FINAL_LOG["$n"]="$lp"
done < "$RESULTS_FILE"

: > "$DECL_FINAL_FILE"
while IFS='|' read -r name kind rest; do
    s="${FINAL_STATUS[$name]:-pending}"
    lp="${FINAL_LOG[$name]:--}"
    printf '%s\t%s\t%s\n' "$name" "$s" "$lp" >> "$DECL_FINAL_FILE"
done < "$DECL_FILE"

# ============================================================================
# Phase 5: ordered serial run. Iterate RESULTS_FILE (which is in declaration
# order) and print PASS / FAIL / SKIP for each.
# ============================================================================
while IFS=$'\t' read -r name status log_path; do
    case "$status" in
        cache_hit|compiled)
            # Execute and convert to pass / fail.
            if [ -x "$BIN/$name" ]; then
                test_log="/tmp/tessera_test_${name}.log"
                if "$BIN/$name" > "$test_log" 2>&1; then
                    printf "  %-30s" "$name"
                    echo "PASS"
                    PASS=$((PASS + 1))
                else
                    printf "  %-30s" "$name"
                    echo "FAIL"
                    FAIL=$((FAIL + 1))
                    ERRORS="$ERRORS"$'\n'"  $name: see $test_log"
                fi
            else
                printf "  %-30s" "$name"
                echo "FAIL (compile, see $log_path)"
                FAIL=$((FAIL + 1))
                ERRORS="$ERRORS"$'\n'"  $name: compile error, see $log_path"
            fi
            ;;
        skip_gate)
            printf "  %-30s" "$name"
            # `log_path` slot carries the human-readable reason text.
            if [ -n "$log_path" ]; then
                echo "SKIP ($log_path)"
            else
                echo "SKIP"
            fi
            SKIP=$((SKIP + 1))
            ;;
        compile_fail)
            printf "  %-30s" "$name"
            echo "FAIL (compile, see $log_path)"
            FAIL=$((FAIL + 1))
            ERRORS="$ERRORS"$'\n'"  $name: compile error, see $log_path"
            ;;
        pending)
            # Compile pool never produced a result for this name (should not
            # happen in the new pipeline; surface loudly if it does).
            printf "  %-30s" "$name"
            echo "FAIL (compile never ran)"
            FAIL=$((FAIL + 1))
            ERRORS="$ERRORS"$'\n'"  $name: compile pool produced no result"
            ;;
    esac
done < "$DECL_FINAL_FILE"

# ============================================================================
# Phase 6: summary.
# ============================================================================
echo ""
echo "Results: $PASS passed, $SKIP skipped, $FAIL failed"
if [ -n "$ERRORS" ]; then
    printf '%s\n' "$ERRORS"
fi
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
