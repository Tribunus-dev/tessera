#!/usr/bin/env bash
# validate-host-amd.sh
#
# W3 task 3.9 (master-plan criteria 21-22): end-to-end host-amd
# validation. Pipeline: export-ternary (BF16 source -> .ttt) -> pack
# --quant=host-amd (.ttt -> host-amd GGUF) -> dump-logits on both the
# source and the host-amd GGUF -> compare-cosine.py.
#
# Legs (distinct exit code per failed leg, so a caller can tell which
# one broke without parsing the log):
#   10  export-ternary failed
#   11  pack --quant=host-amd failed
#   12  reference (source BF16) logit dump failed
#   13  -ngl 0 leg: dump or parity check failed
#   14  -ngl 999 leg: dump or parity check failed
#   15  q8_0-cache leg: dump or parity check failed
#
# set -euo pipefail per the task spec; every external command's success
# is load-bearing (a silent partial failure here would be worse than a
# loud one - this script's whole job is producing a trustworthy gate
# result).
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: validate-host-amd.sh --source BF16.gguf --evidence-dir DIR
                             [--build-dir DIR] [--prompt TEXT]

  --source PATH        source BF16 GGUF (export-ternary input, and the
                        parity reference logits are dumped from this)
  --evidence-dir PATH   output directory (created if missing) - dumps,
                        logs, peak-RSS captures, and the comparison
                        report all land here
  --build-dir PATH      build directory containing bin/llama-tessera and
                        bin/llama-dump-logits (default: build-linux-amd)
  --prompt TEXT         prompt for the logit dump (default: a fixed
                        sentence - determinism matters more than content
                        here, this is a parity check, not an eval)
EOF
    exit 1
}

SOURCE=""
EVIDENCE_DIR=""
BUILD_DIR="build-linux-amd"
PROMPT="The capital of France is"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[[ -z "$SOURCE" ]] && usage
[[ -z "$EVIDENCE_DIR" ]] && usage
[[ -f "$SOURCE" ]] || { echo "error: source GGUF not found: $SOURCE" >&2; exit 1; }

mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/validate.log"
# tee stdout+stderr into the log while still showing them live.
exec > >(tee -a "$LOG") 2>&1

echo "=== W3 task 3.9 host-amd validation: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "source:       $SOURCE"
echo "evidence-dir: $EVIDENCE_DIR"
echo "build-dir:    $BUILD_DIR"
echo "prompt:       $PROMPT"

BIN="$BUILD_DIR/bin"
TESSERA="$BIN/llama-tessera"
DUMP_LOGITS="$BIN/llama-dump-logits"
COMPARE="$(dirname "$0")/compare-cosine.py"

for f in "$TESSERA" "$DUMP_LOGITS"; do
    [[ -x "$f" ]] || { echo "error: required binary not found or not executable: $f" >&2; exit 1; }
done
[[ -f "$COMPARE" ]] || { echo "error: compare-cosine.py not found next to this script" >&2; exit 1; }

TTT_DIR="$EVIDENCE_DIR/ttt"
HOSTAMD_GGUF="$EVIDENCE_DIR/host-amd.gguf"
REF_DUMP="$EVIDENCE_DIR/ref.logits.bin"

# Peak RSS capture: /usr/bin/time -v writes "Maximum resident set size
# (kbytes): N" to its own stderr-ish report; -o writes that report to a
# file directly instead of interleaving with the command's own output.
run_captured() {
    local label="$1"; shift
    local time_log="$EVIDENCE_DIR/${label}.time-v.log"
    echo "--- leg: $label ---"
    echo "+ $*"
    /usr/bin/time -v -o "$time_log" "$@"
    local rss
    rss=$(grep "Maximum resident set size" "$time_log" | awk '{print $NF}')
    echo "${rss:-unknown}" > "$EVIDENCE_DIR/${label}.peak-rss-kb.txt"
    echo "[$label] peak RSS: ${rss:-unknown} KiB"
}

echo
echo "=== leg: export-ternary ($SOURCE -> $TTT_DIR) ==="
rm -rf "$TTT_DIR"
if ! run_captured "export-ternary" "$TESSERA" export-ternary --in "$SOURCE" --out "$TTT_DIR"; then
    echo "FAIL: export-ternary" >&2
    exit 10
fi

echo
echo "=== leg: pack --quant=host-amd ($TTT_DIR -> $HOSTAMD_GGUF) ==="
if ! run_captured "pack" "$TESSERA" pack --quant host-amd --in "$TTT_DIR" --out "$HOSTAMD_GGUF"; then
    echo "FAIL: pack --quant=host-amd" >&2
    exit 11
fi

echo
echo "=== leg: reference (source BF16) logit dump ==="
if ! run_captured "ref-dump" "$DUMP_LOGITS" -m "$SOURCE" -p "$PROMPT" -o "$REF_DUMP" -ngl 0; then
    echo "FAIL: reference logit dump" >&2
    exit 12
fi

FAILED=0

echo
echo "=== leg: -ngl 0 (CPU tile reference path) ==="
NGL0_DUMP="$EVIDENCE_DIR/hostamd.ngl0.logits.bin"
if run_captured "ngl0-dump" "$DUMP_LOGITS" -m "$HOSTAMD_GGUF" -p "$PROMPT" -o "$NGL0_DUMP" -ngl 0; then
    if ! python3 "$COMPARE" "$REF_DUMP" "$NGL0_DUMP" --label ngl0 | tee "$EVIDENCE_DIR/ngl0.compare.txt"; then
        echo "FAIL: -ngl 0 parity" >&2
        FAILED=13
    fi
else
    echo "FAIL: -ngl 0 dump" >&2
    FAILED=13
fi

echo
echo "=== leg: -ngl 999 (GPU WMMA tile path) ==="
NGL999_DUMP="$EVIDENCE_DIR/hostamd.ngl999.logits.bin"
if run_captured "ngl999-dump" "$DUMP_LOGITS" -m "$HOSTAMD_GGUF" -p "$PROMPT" -o "$NGL999_DUMP" -ngl 999; then
    if ! python3 "$COMPARE" "$REF_DUMP" "$NGL999_DUMP" --label ngl999 | tee "$EVIDENCE_DIR/ngl999.compare.txt"; then
        echo "FAIL: -ngl 999 parity" >&2
        [[ "$FAILED" -eq 0 ]] && FAILED=14
    fi
else
    echo "FAIL: -ngl 999 dump" >&2
    [[ "$FAILED" -eq 0 ]] && FAILED=14
fi

echo
echo "=== leg: q8_0 KV cache (-ngl 999 + -cache-q8_0) ==="
Q8_DUMP="$EVIDENCE_DIR/hostamd.q8cache.logits.bin"
if run_captured "q8cache-dump" "$DUMP_LOGITS" -m "$HOSTAMD_GGUF" -p "$PROMPT" -o "$Q8_DUMP" -ngl 999 -cache-q8_0; then
    if ! python3 "$COMPARE" "$REF_DUMP" "$Q8_DUMP" --label q8cache | tee "$EVIDENCE_DIR/q8cache.compare.txt"; then
        echo "FAIL: q8_0-cache parity" >&2
        [[ "$FAILED" -eq 0 ]] && FAILED=15
    fi
else
    echo "FAIL: q8_0-cache dump" >&2
    [[ "$FAILED" -eq 0 ]] && FAILED=15
fi

echo
if [[ "$FAILED" -ne 0 ]]; then
    echo "=== RESULT: FAIL (first failing leg exit code $FAILED) ==="
    exit "$FAILED"
fi
echo "=== RESULT: PASS (all legs) ==="
exit 0
