#!/bin/bash
# Tessera C++ port integration test suite.
# Usage: bash tools/quantize/tessera/test_all.sh
# Run from the repository root.

set -e
PASS=0
FAIL=0
ERRORS=""

T=tools/quantize/tessera
C=common/tessera-debug
BIN=/tmp/tessera_test_bin
CXX="clang++ -std=c++17 -O2"
TS_DUCKDB_DIR=third-party/duckdb

mkdir -p "$BIN"

run_test() {
    local name="$1"
    shift
    printf "  %-30s" "$name"
    if "$@" > /tmp/tessera_test_$name.log 2>&1; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  $name: see /tmp/tessera_test_$name.log"
    fi
}

# compile_and_run <name> <source...> [extra flags...]
compile_and_run() {
    local name="$1"
    shift
    if ! $CXX "$@" -o "$BIN/$name" > /tmp/tessera_build_$name.log 2>&1; then
        printf "  %-30s" "$name"
        echo "FAIL (compile)"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  $name: compile error, see /tmp/tessera_build_$name.log"
        return
    fi
    run_test "$name" "$BIN/$name"
}

echo "Tessera integration tests"
echo ""

# --- Standalone (test + own module) ---
compile_and_run linalg      $T/test_linalg.cpp      $T/tessera-linalg.cpp -framework Accelerate
compile_and_run lbfgs       $T/test_lbfgs.cpp       $T/tessera-lbfgs.cpp
compile_and_run awq         $T/test_awq.cpp         $T/tessera-awq.cpp $T/tessera-policy.cpp -I common -I vendor
# AWQ GA fitness port (parity vs Python awq-evolve.py + GA convergence).
# Links the standalone port against tessera-policy (for ts_policy_genes) +
# the awq sources + nlohmann/json (fixture loader).
compile_and_run awq_fitness $T/test_awq_fitness.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp $T/tessera-policy.cpp -I common -I vendor -framework Accelerate
# FLRQ outlier-aware low-rank port (parity vs Python flrq_bcl; loads the
# Python sketch basis from the fixture so the deterministic BLC core is pinned
# bit-for-bit). Needs tessera-linalg (sym-eig for the sketch basis) + vendor.
compile_and_run flrq        $T/test_flrq.cpp        $T/tessera-flrq.cpp $T/tessera-linalg.cpp -I vendor -framework Accelerate
compile_and_run l5          $T/test_l5.cpp          $T/tessera-l5.cpp
compile_and_run imatrix     $T/test_imatrix.cpp     $T/tessera-imatrix.cpp
compile_and_run corpus      $T/test_corpus.cpp      $T/tessera-corpus.cpp
compile_and_run ppl         $T/test_ppl.cpp         $T/tessera-ppl.cpp

# --- L5 joint search loop (v2/v3/v4 of plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d) ---
# Case 1: target-only. Case 2: full 5-model joint. Case 3: strict-mode
# acceptance gate (--tessera-l5-strict at 0.25%).
printf "  %-30s" "l5_joint"
if [ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]; then
    if [ -f build-ane/bin/libggml.dylib ]; then
        GGML_LIB="-L build-ane/bin -Wl,-rpath,build-ane/bin -lggml -lggml-base"
    else
        GGML_LIB="-L build/bin -Wl,-rpath,build/bin -lggml -lggml-base"
    fi
    compile_and_run l5_joint \
        $T/test_l5_joint.cpp \
        $T/tessera-ppl.cpp \
        ../../common/tessera-ppl-harness.cpp \
        ../../common/tessera-l5-joint.cpp \
        -I ../../common -I ggml/include -I ggml/src -I vendor -I $C -I $T \
        $GGML_LIB -framework Accelerate
else
    echo "SKIP (needs CMake build for libggml)"
fi

# --- L5 joint PPL harness (v1 of plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d) ---
# Joint forward pass across target + 3 drafters + talker; per-model PPL
# extraction; per-model AND-gate at --tessera-l5-epsilon. v1 sanity:
# 5 synthetic all-zero-logits models, FP PPL == vocab size exactly.
printf "  %-30s" "ppl_harness"
if [ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]; then
    if [ -f build-ane/bin/libggml.dylib ]; then
        GGML_LIB="-L build-ane/bin -Wl,-rpath,build-ane/bin -lggml -lggml-base"
    else
        GGML_LIB="-L build/bin -Wl,-rpath,build/bin -lggml -lggml-base"
    fi
    compile_and_run ppl_harness \
        $T/test_ppl_harness.cpp \
        $T/tessera-ppl.cpp \
        ../../common/tessera-ppl-harness.cpp \
        -I ../../common -I ggml/include -I ggml/src -I vendor -I $C -I $T \
        $GGML_LIB -framework Accelerate
else
    echo "SKIP (needs CMake build for libggml)"
fi

# --- L5 joint calibration set generator (v1 of plan-sess_57d0ae24-05b7-4442-b516-8175bc46df1d) ---
# Writes JSONL with synthetic text + synthetic audio targets. v3 wires
# the real text-to-audio target mapping. Schema-only at v1.
printf "  %-30s" "gen_joint_calib"
compile_and_run gen_joint_calib $T/gen_joint_calib.cpp
compile_and_run ab_harness  $T/test_ab_harness.cpp  $T/tessera-ab-harness.cpp
compile_and_run acceptance  $T/test_acceptance.cpp  $T/tessera-acceptance.cpp $T/tessera-ab-harness.cpp
compile_and_run higgs       $T/test_higgs.cpp       $T/tessera-higgs.cpp
compile_and_run regime      $T/test_regime.cpp      $T/tessera-regime.cpp
compile_and_run peqat       $T/test_peqat.cpp       $T/tessera-peqat.cpp
# SEPTQ banded-Cholesky quantizer parity (B3): standalone, links the septq
# port + nlohmann/json for the fixture loader.
compile_and_run septq       $T/test_septq.cpp       $T/tessera-septq.cpp -I vendor -framework Accelerate

# --- Needs vec (Accelerate) ---
compile_and_run vec         $T/test_vec.cpp         $T/tessera-vec.cpp -framework Accelerate
compile_and_run quant       $T/test_quant.cpp       $T/tessera-quant.cpp $T/tessera-vec.cpp -framework Accelerate
compile_and_run w4a4        $T/test_w4a4.cpp        $T/tessera-w4a4.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp -framework Accelerate
compile_and_run moe_shapes  $T/test_moe_shapes.cpp  $T/tessera-quant.cpp $T/tessera-vec.cpp -framework Accelerate
compile_and_run operative_routing $T/test_operative_routing.cpp $T/tessera-regime.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp -framework Accelerate
# dispatch requires libgguf/libggml (full CMake build); skip in standalone mode
printf "  %-30s" "dispatch"
if [ -f build/ggml/src/libgguf.a ] || [ -f build/ggml/src/libgguf.dylib ]; then
    compile_and_run dispatch $T/test_dispatch.cpp $T/tessera-dispatch.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp -I common -I ggml/include -I ggml/src -L build/ggml/src -lgguf -lggml -framework Accelerate
else
    echo "SKIP (needs CMake build for libgguf)"
fi

# --- Tile640 core=nullptr transport parity (Aug 2026 transport cut)
# Bit-exact gate for the 162G->33G tile-neutral transport compression at
# commit 0e110f9fc (Aug 10, today). Packs the same ternary tensor with
# and without core, dequantizes both, and asserts the radix-243+scales
# reconstruction is within 1.5x between the two paths. Catches the
# "core dropped silently degrades fidelity" class of bug at every commit.
# Needs libggml (for the flat dequantize_row_tessera_t640 trait).
printf "  %-30s" "t640_core_reconstruct_parity"
if [ -f build/ggml/src/libggml.a ] || [ -f build-ffi/ggml/src/libggml.a ] || \
   [ -f build-ane/bin/libggml.dylib ] || [ -f build/bin/libggml.dylib ]; then
    # Pick the first available libggml.
    if [ -f build-ffi/ggml/src/libggml.a ]; then
        GGML_LIB="-L build-ffi/ggml/src -lggml -lggml-base -lggml-cpu"
    elif [ -f build-ane/bin/libggml.dylib ]; then
        GGML_LIB="-L build-ane/bin -Wl,-rpath,build-ane/bin -lggml -lggml-base -lggml-cpu"
    elif [ -f build/bin/libggml.dylib ]; then
        GGML_LIB="-L build/bin -Wl,-rpath,build/bin -lggml -lggml-base -lggml-cpu"
    else
        GGML_LIB="-L build/ggml/src -lggml -lggml-base -lggml-cpu"
    fi
    compile_and_run t640_core_reconstruct_parity \
        $T/test_t640_core_reconstruct_parity.cpp \
        $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tile-detect.cpp $T/tessera-metal-stub.cpp \
        -I ggml/include -I ggml/src -I $T \
        $GGML_LIB -framework Accelerate
else
    echo "SKIP (needs CMake build for libggml)"
fi

# L5 dispatch integration test: same libgguf/libggml link line as dispatch,
# plus the L2-diff/L5 modules the adaptive-requantize loop pulls in.
printf "  %-30s" "l5_dispatch"
if [ -f build/ggml/src/libgguf.a ] || [ -f build/ggml/src/libgguf.dylib ]; then
    compile_and_run l5_dispatch $T/test_l5_dispatch.cpp $T/tessera-dispatch.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp $T/tessera-awq.cpp $T/tessera-awq-fitness.cpp $T/tessera-l2-diff.cpp $T/tessera-l3-coherence.cpp $T/tessera-l5.cpp $T/tessera-ppl.cpp $C/tessera-sidecar-v3.cpp -I common -I ggml/include -I ggml/src -I vendor -I $C -L build/ggml/src -lgguf -lggml -framework Accelerate
else
    echo "SKIP (needs CMake build for libgguf)"
fi

# --- Needs linalg + lbfgs (search pulls in vendor/nlohmann for the archive JSON) ---
compile_and_run search      $T/test_search.cpp      $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp -I vendor -framework Accelerate

# --- CHAMP-Q L-BFGS permutation port (parity vs Python champq_permute.py) ---
compile_and_run champq      $T/test_champq.cpp      $T/tessera-champq.cpp $T/tessera-lbfgs.cpp -I vendor -framework Accelerate

# --- MAP-Elites archive (search + linalg + lbfgs + vendor/nlohmann) ---
compile_and_run map_elites  $T/test_map_elites.cpp  $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp -I vendor -framework Accelerate

# --- Modality as operative regime axis (regime + search + linalg + lbfgs + vendor) ---
compile_and_run modality_routing $T/test_modality_routing.cpp $T/tessera-regime.cpp $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp -I vendor -framework Accelerate

# --- HIGGS integration (higgs + cache + search + quant + vec) ---
compile_and_run higgs_integration $T/test_higgs_integration.cpp $T/tessera-higgs.cpp $T/tessera-higgs-cache.cpp $T/tessera-lrq.cpp $T/tessera-dartquant.cpp $T/tessera-flrq.cpp $T/tessera-champq.cpp $T/tessera-archive.cpp $T/tessera-linalg.cpp $T/tessera-lbfgs.cpp $T/tessera-quant.cpp $T/tessera-vec.cpp -I vendor -framework Accelerate

# --- Needs sidecar + vec ---
# L1.5 test exercises both the F32 (back-compat) and the FP16 ground
# truth paths, and the L1 F32 writer regression check. Links
# tessera-debug.cpp for the sidecar writer (open_dequant_writer,
# open_fp16_reference_writer, write_fp16_reference_row, etc.) and
# the sidecar v3 reader for the FP16/F32 dispatch on read. The
# tessera-build-info.h stub is generated by the l1_sidecar test
# runner below; we reproduce it here so the l15 build is
# self-contained.
printf '#pragma once\n#define TESSERA_KERNEL_VERSION "test"\n#define TESSERA_MAIN_TIP "test"\n' > "$BIN/tessera-build-info.h"
compile_and_run l15         $T/test_l15.cpp         $T/tessera-l15.cpp $C/tessera-debug.cpp $C/tessera-sidecar-v3.cpp $T/tessera-vec.cpp -I $C -I "$BIN" -framework Accelerate

# --- Needs sidecar (L1 kernel-direct fitness) ---
compile_and_run l1_fitness  $T/test_l1_fitness.cpp  $T/tessera-l1-fitness.cpp $C/tessera-sidecar-v3.cpp -I $C

# --- L1 tail-weighted kernel-direct t_l^2 (L6 v3.1, §11 of the spec) ---
# Pure-math on the t2 path, but ts_l1_load_sidecar (in
# tessera-l1-fitness.cpp) is the v3 sidecar reader and pulls in
# ts_sidecar_v3_read from common/tessera-debug. Link the sidecar
# source so the test can run the l6-tail assertion path end-to-end.
compile_and_run l1_fitness_tail $T/test_l1_fitness_tail.cpp $T/tessera-l1-fitness.cpp $C/tessera-sidecar-v3.cpp -I $C

# L1.5 dispatch-time capture (v3.1, §3 of the spec) is built via
# CMake (test-tessera-l15-capture target) because it needs ggml/gguf
# headers plus a chunk of the dispatch source tree. See
# tools/quantize/CMakeLists.txt.

# --- L2-L5 runtime-aware pipeline (L2 diff + L3 coherence + L5 adaptive) ---
# L2 needs vendor/nlohmann (JSON report); L3 needs the sidecar reader;
# L2 spectral metrics need tessera-linalg for ts_linalg_svd_topk.
compile_and_run l2l5        $T/test_l2l5.cpp        $T/tessera-l2-diff.cpp $T/tessera-l3-coherence.cpp $T/tessera-l5.cpp $T/tessera-ppl.cpp $T/tessera-linalg.cpp $T/tessera-septq.cpp $C/tessera-sidecar-v3.cpp -I vendor -I $C -framework Accelerate

# --- Needs vendor (nlohmann/json) ---
compile_and_run policy      $T/test_policy.cpp      $T/tessera-policy.cpp -I vendor

# --- Self-improving capability loop (capability-eval + adapt; needs vendor) ---
compile_and_run capability_loop $T/test_capability_loop.cpp $T/tessera-capability-eval.cpp $T/tessera-adapt.cpp -I vendor

# --- Tier-2 anonymizer (needs vendor/nlohmann for the de-anonymization map) ---
compile_and_run anonymizer    $T/test_anonymizer.cpp  $T/tessera-anonymizer.cpp -I vendor

# --- Text secret redactor (standalone; no vendor needed) ---
compile_and_run scrub         $T/test_scrub.cpp       $T/tessera-scrub.cpp

# --- North-star throughput harness (needs vendor/nlohmann for workload+receipt JSON) ---
compile_and_run throughput    $T/test_throughput.cpp  $T/tessera-throughput.cpp -I vendor

# --- Drafter training pipeline: LK loss (pure math, no vendor) ---
compile_and_run lk_loss       $T/test_lk_loss.cpp     $T/tessera-lk-loss.cpp

# --- Drafter training pipeline: dataset prep (needs vendor/nlohmann + dpace weights) ---
compile_and_run dataset       $T/test_dataset.cpp     $T/tessera-dataset.cpp $T/tessera-dpace.cpp -I vendor

# --- Drafter training pipeline: D-PACE loss (pure math, no vendor) ---
compile_and_run dpace         $T/test_dpace.cpp       $T/tessera-dpace.cpp

# --- Drafter training pipeline: offline feature-capture file format (needs vendor) ---
compile_and_run features      $T/test_features.cpp    $T/tessera-features.cpp -I vendor

# --- Drafter training pipeline: LK training-data builder (needs vendor + lk-loss densify) ---
compile_and_run lk_train_data $T/test_lk_train_data.cpp $T/tessera-lk-train-data.cpp $T/tessera-lk-loss.cpp -I vendor

# --- Drafter training pipeline: DFlash training-data builder (needs vendor; weight schemes dpace|decay) ---
compile_and_run dflash_train_data $T/test_dflash_train_data.cpp $T/tessera-dflash-train-data.cpp -I vendor

# --- Drafter training pipeline: imatrix features file from the DFlash driver consumer side ---
compile_and_run imatrix_drafter_features $T/test_imatrix_drafter_features.cpp $T/tessera-features.cpp -I vendor

# --- DartQuant QR-Orth + Whip loss port (parity vs Python dartquant_qr_orth; needs vendor/nlohmann for fixture) ---
compile_and_run dartquant $T/test_dartquant.cpp $T/tessera-dartquant.cpp $T/tessera-linalg.cpp -I vendor -framework Accelerate

# --- common/tessera-debug ---
compile_and_run sidecar_v3  $C/test_sidecar_v3.cpp  $C/tessera-sidecar-v3.cpp -I $C

# L1 sidecar writer end-to-end (needs a stub tessera-build-info.h)
printf '#pragma once\n#define TESSERA_KERNEL_VERSION "test"\n#define TESSERA_MAIN_TIP "test"\n' > "$BIN/tessera-build-info.h"
compile_and_run l1_sidecar  $T/test_l1_sidecar.cpp  $C/tessera-debug.cpp $C/tessera-sidecar-v3.cpp -I $C -I "$BIN"

# --- Phase 16.7: per-component (model_role, name) covering index + audit sidecar ---
# 7 CREATE INDEX IF NOT EXISTS lines on open; smoke benchmark; the
# model_role_migration.json sidecar written when a pre-Phase-16 DB is
# opened. Standalone DuckDB test (no GGUF, no dispatch). Links the
# duckdb amalgamation directly.
compile_and_run tessera_db_indexes $T/test_tessera_db_indexes.cpp \
    $T/tessera-quantize-db.cpp $T/tessera-db-buffer.cpp \
    $TS_DUCKDB_DIR/duckdb.cpp -I $TS_DUCKDB_DIR -I $T -w

# --- CoreML bridge (builder pulls in the MIL + telemetry modules) ---
compile_and_run coreml_bridge $T/test_coreml_bridge.cpp $T/tessera-coreml.cpp $T/tessera-coreml-builder.cpp $T/tessera-coreml-metadata.cpp $T/tessera-coreml-mil.cpp $T/tessera-coreml-telemetry.cpp -I ggml/include

# --- CoreML MIL builder + weight serialization + IOReport telemetry scaffold ---
compile_and_run coreml_mil $T/test_coreml_mil.cpp $T/tessera-coreml-mil.cpp $T/tessera-coreml-telemetry.cpp $T/tessera-coreml-builder.cpp $T/tessera-coreml.cpp -I ggml/include

# --- Phase 16 follow-up: GA walk model_role plumb-through on tensor_stats ---
# Standalone DuckDB test (mirrors the existing test_quantize_db
# build line that CMake uses; the duckdb amalgamation is the
# slow part so we cache the .o between runs when possible).
DUCKDB_O="$BIN/duckdb.o"
if [ ! -f "$DUCKDB_O" ]; then
    $CXX -DNDEBUG -I third-party/duckdb -c third-party/duckdb/duckdb.cpp -o "$DUCKDB_O" \
        > /tmp/tessera_build_duckdb.log 2>&1 || {
            printf "  %-30s" "duckdb_amalgamation"
            echo "FAIL (compile, see /tmp/tessera_build_duckdb.log)"
            FAIL=$((FAIL + 1))
            ERRORS="$ERRORS\n  duckdb_amalgamation: see /tmp/tessera_build_duckdb.log"
        }
fi
if [ -f "$DUCKDB_O" ]; then
    compile_and_run ga_model_role tests/test-tessera-ga-model-role.cpp $T/tessera-quantize-db.cpp $T/tessera-db-buffer.cpp "$DUCKDB_O" -I third-party/duckdb -I $T -I vendor
else
    printf "  %-30s" "ga_model_role"
    echo "SKIP (duckdb amalgamation build failed)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    printf "$ERRORS\n"
    exit 1
fi
