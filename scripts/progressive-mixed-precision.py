#!/usr/bin/env python3
"""progressive-mixed-precision.py

Progressive, sensitivity-driven mixed-precision search for the host-amd
ternary pipeline (export-ternary/pack).

Background: pure ternary quantization ({-1,0,+1} weights) has a hard
representational ceiling - measured directly this session at cosine~0.95 on
a SINGLE weight tensor even with a perfect-magnitude oracle, and end-to-end
(all 280 eligible tensors forced ternary, best-of-4-algorithm selection,
real calibration) on Granite 4.1 3B measured cosine=0.400 vs the bf16
reference. No amount of additional per-tensor calibration sophistication
closes that gap, because none of it changes the underlying 3-symbol
representation. See the gap ledger (CORRECTION-w3-6) and this session's
research into mainstream quantizers (BitNet b1.58 achieves ternary via
training-time adaptation, not post-training quantization; QuIP#/SpQR/GPTQ/AWQ
all stop around 2-4 bits for the same reason).

This script instead searches for the MINIMAL set of tensors that need to
escape ternary (shipped as exact BF16 passthrough instead, via
export-ternary's --escape-list) to clear an "effectively lossless" bar
(cosine>=0.999 by default, matching scripts/compare-cosine.py's own
default), using:

  1. A cheap, one-time sensitivity ranking (export-ternary's
     --sensitivity-out, backed by ts_l5_imatrix_magnitude) to PRIORITIZE
     which tensors to try escaping first. This is a purely local, per-tensor
     proxy signal - it does not account for cross-layer compounding.
  2. Real end-to-end validation (export-ternary -> pack -> dump-logits ->
     compare-cosine.py, the exact tool chain used to measure this session's
     own 0.400 baseline) after each batch of escapes. This is the actual
     objective the search optimizes; the sensitivity ranking only decides
     the ORDER candidates are tried in, never the accept/reject decision.

Algorithm: greedy, coarse-to-fine batch promotion. Starting from the
all-ternary baseline, each round escapes the next batch of highest-ranked
remaining tensors, re-measures real end-to-end cosine, and either keeps the
batch size the same (still in the high-sensitivity tail, moving fast) or
halves it (diminishing returns, refine) based on the round-over-round gain.
Stops when the target cosine is reached, the batch size would drop below one
tensor, or --max-rounds is hit. There is no default escape-fraction cap -
the search's whole purpose is to discover how much of the model actually
needs to escape; --max-escape-fraction is an opt-in safety valve, not a
default.

Each round's export-ternary/pack/dump-logits artifacts and a final
report.json (full history + the final escape list) are written under
--evidence-dir, matching the .zcode/xdna-research/evidence/... pattern
already used elsewhere in this pipeline's validation.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

COSINE_RE = re.compile(r"cosine=([\d.eE+-]+)")
FROBENIUS_RE = re.compile(r"frobenius_rel=([\d.eE+-]+)")


def run(cmd):
    print(f"+ {' '.join(str(c) for c in cmd)}", file=sys.stderr)
    subprocess.run(cmd, check=True)


def compare_cosine(script_dir, ref, cand, label):
    # capture_output so we can parse the numbers; still echoed to stderr
    # below so nothing is lost from the live log. --cosine-min/--frobenius-max
    # are set permissive here (this script does its own target-cosine
    # decision) so compare-cosine.py's own exit code doesn't short-circuit
    # anything - only its printed numbers are used.
    proc = subprocess.run(
        [sys.executable, str(script_dir / "compare-cosine.py"), str(ref), str(cand),
         "--cosine-min", "0.0", "--frobenius-max", "999", "--label", label],
        capture_output=True, text=True,
    )
    out = proc.stdout + proc.stderr
    print(out, file=sys.stderr, end="")
    cm = COSINE_RE.search(out)
    fm = FROBENIUS_RE.search(out)
    if not cm or not fm:
        raise RuntimeError(f"compare-cosine.py output not parseable: {out!r}")
    return float(cm.group(1)), float(fm.group(1))


def export_and_pack(tessera_bin, source, imatrix, out_dir, escape_list=None, sensitivity_out=None,
                     reuse_ttt=None):
    ttt_dir = out_dir / "ttt"
    gguf_path = out_dir / "host-amd.gguf"
    cmd = [str(tessera_bin), "export-ternary", "--in", str(source), "--out", str(ttt_dir),
           "--imatrix", str(imatrix)]
    if escape_list is not None:
        cmd += ["--escape-list", str(escape_list)]
    if sensitivity_out is not None:
        cmd += ["--sensitivity-out", str(sensitivity_out)]
    if reuse_ttt is not None:
        # Round 0's own ttt output already has every tensor any later round
        # needs (the escape-list only grows), so every round after 0 passes
        # round 0's ttt dir here - export-ternary reuses each still-ternary
        # tensor's already-computed result instead of recomputing it, only
        # doing real work for tensors newly added to this round's
        # escape-list (a cheap passthrough copy, not a quantization).
        cmd += ["--reuse-ttt", str(reuse_ttt)]
    run(cmd)
    run([str(tessera_bin), "pack", "--quant", "host-amd", "--in", str(ttt_dir), "--out", str(gguf_path)])
    return gguf_path


def dump_logits(dump_bin, model, prompt, out_path, ngl=0):
    run([str(dump_bin), "-m", str(model), "-p", prompt, "-ngl", str(ngl), "-o", str(out_path)])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, help="source BF16 GGUF")
    ap.add_argument("--imatrix", required=True,
                     help="imatrix GGUF for calibration + sensitivity scoring (required - "
                          "the sensitivity ranking has no signal without it)")
    ap.add_argument("--evidence-dir", required=True, help="output directory for all rounds' artifacts")
    ap.add_argument("--build-dir", default="build-linux-amd")
    ap.add_argument("--prompt", default="The capital of France is")
    ap.add_argument("--target-cosine", type=float, default=0.999)
    ap.add_argument("--initial-batch-frac", type=float, default=0.05,
                     help="fraction of still-ternary tensors to escape per round initially (default 0.05)")
    ap.add_argument("--gain-threshold", type=float, default=0.01,
                     help="minimum round-over-round cosine gain to keep the batch size the same "
                          "instead of halving it (default 0.01)")
    ap.add_argument("--max-rounds", type=int, default=20)
    ap.add_argument("--max-escape-fraction", type=float, default=1.0,
                     help="opt-in safety cap on total escaped fraction (default: no cap, 1.0)")
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    build_dir = Path(args.build_dir)
    tessera_bin = build_dir / "bin" / "llama-tessera"
    dump_bin = build_dir / "bin" / "llama-dump-logits"
    for f in (tessera_bin, dump_bin):
        if not f.exists():
            print(f"error: required binary not found: {f}", file=sys.stderr)
            return 1

    evidence_dir = Path(args.evidence_dir)
    evidence_dir.mkdir(parents=True, exist_ok=True)

    ref_dump = evidence_dir / "ref.logits.bin"
    if not ref_dump.exists():
        dump_logits(dump_bin, args.source, args.prompt, ref_dump, ngl=0)

    # --- Round 0: all-ternary baseline + sensitivity ranking ---
    round0_dir = evidence_dir / "round-000"
    round0_dir.mkdir(exist_ok=True)
    sensitivity_path = round0_dir / "sensitivity.json"
    gguf0 = export_and_pack(tessera_bin, args.source, args.imatrix, round0_dir,
                            sensitivity_out=sensitivity_path)
    dump0 = round0_dir / "candidate.logits.bin"
    dump_logits(dump_bin, gguf0, args.prompt, dump0, ngl=0)
    cos0, frob0 = compare_cosine(script_dir, ref_dump, dump0, "round-000")
    print(f"[round 0] baseline (all-ternary): cosine={cos0:.6f} frobenius_rel={frob0:.6f}", file=sys.stderr)

    if not sensitivity_path.exists():
        print("error: round 0 produced no sensitivity.json - check export-ternary's own "
              "stderr above for why", file=sys.stderr)
        return 1
    scores = json.loads(sensitivity_path.read_text())
    if not scores:
        print("error: sensitivity.json is empty (no tensor had usable calibration data)", file=sys.stderr)
        return 1
    # descending by score (higher score = more sensitive = escape first),
    # stable tie-break by name for determinism.
    ranked = sorted(scores.keys(), key=lambda n: (-scores[n], n))
    n_total = len(ranked)

    history = [{"round": 0, "escaped_count": 0, "escaped_fraction": 0.0,
                "cosine": cos0, "frobenius_rel": frob0, "batch": []}]
    escaped = []  # cumulative escape list across all rounds; stays [] if the baseline already passes

    if cos0 >= args.target_cosine:
        print("target cosine already met with the all-ternary baseline; nothing to escape.", file=sys.stderr)
    else:
        remaining = list(ranked)
        batch_size = max(1, round(args.initial_batch_frac * n_total))
        prev_cosine = cos0

        for round_idx in range(1, args.max_rounds + 1):
            if not remaining:
                print("all candidate tensors already escaped; stopping.", file=sys.stderr)
                break

            batch = remaining[:batch_size]
            trial_escaped = escaped + batch
            escaped_fraction = len(trial_escaped) / n_total
            if escaped_fraction > args.max_escape_fraction:
                print(f"[round {round_idx}] escaping this batch would push the escaped fraction to "
                      f"{escaped_fraction:.3f}, over --max-escape-fraction {args.max_escape_fraction}; "
                      f"stopping without it.", file=sys.stderr)
                break

            remaining = remaining[batch_size:]
            escaped = trial_escaped

            round_dir = evidence_dir / f"round-{round_idx:03d}"
            round_dir.mkdir(exist_ok=True)
            escape_list_path = round_dir / "escape-list.txt"
            escape_list_path.write_text("\n".join(escaped) + "\n")

            gguf = export_and_pack(tessera_bin, args.source, args.imatrix, round_dir,
                                   escape_list=escape_list_path, reuse_ttt=round0_dir / "ttt")
            dump_path = round_dir / "candidate.logits.bin"
            dump_logits(dump_bin, gguf, args.prompt, dump_path, ngl=0)
            cos, frob = compare_cosine(script_dir, ref_dump, dump_path, f"round-{round_idx:03d}")

            print(f"[round {round_idx}] escaped={len(escaped)}/{n_total} ({escaped_fraction:.1%}) "
                  f"batch={len(batch)} cosine={cos:.6f} frobenius_rel={frob:.6f}", file=sys.stderr)
            history.append({"round": round_idx, "escaped_count": len(escaped),
                             "escaped_fraction": escaped_fraction, "cosine": cos,
                             "frobenius_rel": frob, "batch": batch})

            if cos >= args.target_cosine:
                print(f"target cosine {args.target_cosine} reached after {round_idx} round(s), "
                      f"escaping {len(escaped)}/{n_total} tensors ({escaped_fraction:.1%}).",
                      file=sys.stderr)
                break

            gain = cos - prev_cosine
            if gain < args.gain_threshold:
                new_batch_size = max(1, batch_size // 2)
                if new_batch_size != batch_size:
                    print(f"[round {round_idx}] gain {gain:.4f} < threshold {args.gain_threshold}; "
                          f"halving batch size {batch_size} -> {new_batch_size}", file=sys.stderr)
                    batch_size = new_batch_size
                elif batch_size == 1:
                    print(f"[round {round_idx}] gain {gain:.4f} < threshold with batch_size=1; "
                          f"diminishing returns, stopping.", file=sys.stderr)
                    break
            prev_cosine = cos
        else:
            print(f"reached --max-rounds={args.max_rounds} without hitting the target cosine; "
                  f"reporting best achieved.", file=sys.stderr)

    # The search's halving/gain-threshold schedule can (and did, on the
    # first real run) chase a batch past its peak - round N+1's cosine is
    # not guaranteed >= round N's, especially once batch_size has halved
    # down to chasing individual tensors whose interaction with the rest
    # of the model isn't captured by the static round-0 sensitivity
    # ranking. Report the BEST round found, not just the last one tried -
    # history[-1] would silently surface a worse result than what the
    # search actually discovered along the way.
    best = max(history, key=lambda h: h["cosine"])
    best_round_idx = history.index(best)
    best_escape_list = [t for h in history[:best_round_idx + 1] for t in h["batch"]]
    last = history[-1]

    report = {
        "source": str(args.source),
        "target_cosine": args.target_cosine,
        "n_total_candidates": n_total,
        "best_round": best["round"],
        "best_escaped_count": best["escaped_count"],
        "best_escaped_fraction": best["escaped_fraction"],
        "best_cosine": best["cosine"],
        "best_frobenius_rel": best["frobenius_rel"],
        "best_escape_list": best_escape_list,
        "last_round": last["round"],
        "last_cosine": last["cosine"],
        "last_frobenius_rel": last["frobenius_rel"],
        "history": history,
    }
    report_path = evidence_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2))

    print("\n=== SUMMARY ===", file=sys.stderr)
    print(f"best: round {best['round']}, escaped {best['escaped_count']}/{n_total} tensors "
          f"({best['escaped_fraction']:.1%}), cosine={best['cosine']:.6f} "
          f"(target {args.target_cosine})", file=sys.stderr)
    if best["round"] != last["round"]:
        print(f"note: the search continued past this round (last tried: round {last['round']}, "
              f"cosine={last['cosine']:.6f}) - later batches reduced fidelity rather than "
              f"improving it, so the best-found configuration is reported instead of the last "
              f"one tried.", file=sys.stderr)
    print(f"full report: {report_path}", file=sys.stderr)
    return 0 if best["cosine"] >= args.target_cosine else 1


if __name__ == "__main__":
    sys.exit(main())
