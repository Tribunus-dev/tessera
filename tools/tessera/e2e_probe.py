#!/usr/bin/env python3
"""L4 end-to-end probe: does the quantized model still behave like BF16?

This is Layer 4 of the runtime-aware calibration pipeline (see
``docs/runtime-aware-pipeline.md``). Every other layer in the spine
closes on weight-space or perplexity proxies; this is the only one
that closes on *behaviour*, which is the failure mode that started
the project (0.86 % drafter acceptance on gemma-4-12B while the
per-tensor metrics looked fine).

Two independent measurements, both against the BF16 source as
reference:

1. **exact_match** -- greedy (temp 0) continuation of each prompt in
   the bank, from both models, compared token-for-token. The BF16
   model's own output is the reference, so the bank does not carry
   hardcoded expected strings and does not go stale when the source
   checkpoint changes.

2. **divergence** -- ``llama-perplexity --kl-divergence`` over the
   concatenated bank. This reuses upstream's KL machinery rather than
   reimplementing it, and yields three numbers directly comparable to
   published quant comparisons:

       Mean PPL(Q)-PPL(base)  -> delta_ppl
       Mean KLD               -> mean_kld
       Same top p             -> top1_agreement_pct

Verdict (the single number the design doc asks for):

    PASS  all prompts exact-match AND ppl_ratio <= 2.0
    WARN  exactly one prompt mismatches AND ppl_ratio <= 2.0
    FAIL  two or more mismatches, OR ppl_ratio > 2.0

Exit code is 0 on PASS, 1 on WARN, 2 on FAIL, 3 on harness error, so
it can gate CI directly.

Usage::

    python3 tools/tessera/e2e_probe.py \\
        --bf16 model-bf16.gguf \\
        --quantized model-tessera.gguf \\
        --llama-cli ./build/bin/llama-cli \\
        --llama-perplexity ./build/bin/llama-perplexity \\
        --out l4_probe.json

``--skip-ppl`` runs the exact-match half alone, which needs only
``llama-cli`` and is fast enough for a per-PR gate; the full probe is
the nightly. Pure stdlib -- no numpy, so it runs anywhere the build
does.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA_NAME = "llama.tessera.l4-probe.v1"

DEFAULT_BANK = Path(__file__).resolve().parent / "prompts" / "bank.json"

# PPL ratio above which the model is considered broken regardless of
# exact-match results. From docs/runtime-aware-pipeline.md Layer 4:
# "FAIL (multiple mismatches or perplexity > 2x reference)".
PPL_RATIO_FAIL = 2.0


class ProbeError(RuntimeError):
    """Harness failure (missing binary, model, or unparsable output).

    Distinct from a model-quality failure: the caller maps this to
    exit code 3 so CI can tell "the probe broke" from "the model
    regressed".
    """


def load_bank(bank_path: Path) -> list[dict]:
    try:
        with open(bank_path, "r", encoding="utf-8") as f:
            bank = json.load(f)
    except OSError as exc:
        raise ProbeError(f"cannot read prompt bank {bank_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ProbeError(f"prompt bank {bank_path} is not valid JSON: {exc}") from exc

    prompts = bank.get("prompts")
    if not prompts:
        raise ProbeError(f"prompt bank {bank_path} has no 'prompts' array")

    base = bank_path.parent
    for p in prompts:
        pfile = base / p["file"]
        if not pfile.is_file():
            raise ProbeError(f"prompt file missing: {pfile}")
        p["path"] = str(pfile)
        p["text"] = pfile.read_text(encoding="utf-8")
    return prompts


def greedy_generate(llama_cli: str, model: str, prompt_file: str,
                    n_tokens: int, seed: int, n_ctx: int,
                    extra_args: list[str]) -> str:
    """Greedy-decode `n_tokens` from `prompt_file` and return the
    continuation only (the echoed prompt is stripped).

    Greedy decoding is what makes this comparison meaningful: with
    temp 0 and a fixed seed the only source of difference between the
    two runs is the weights.
    """
    cmd = [
        llama_cli,
        "-m", model,
        "-f", prompt_file,
        "-n", str(n_tokens),
        "-c", str(n_ctx),
        "--temp", "0",
        "--seed", str(seed),
        "--single-turn",
        "--no-display-prompt",
        "--no-warmup",
        *extra_args,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise ProbeError(f"cannot run {llama_cli}: {exc}") from exc
    if proc.returncode != 0:
        raise ProbeError(
            f"llama-cli failed (rc={proc.returncode}) on {prompt_file}\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {proc.stderr[-800:]}"
        )
    # --no-display-prompt makes stdout the continuation alone. Trailing
    # whitespace differs harmlessly between runs (the EOG handling can
    # append a newline), so normalize the right edge only -- leading
    # whitespace is part of the continuation and IS significant.
    return proc.stdout.rstrip()


# llama-perplexity prints these three lines in its --kl-divergence
# summary. Values may carry a "± unc" tail, which we drop.
_PPL_DIFF_RE  = re.compile(r"^Mean PPL\(Q\)-PPL\(base\)\s*:\s*(-?[\d.]+)", re.M)
_PPL_RATIO_RE = re.compile(r"^Mean PPL\(Q\)/PPL\(base\)\s*:\s*(-?[\d.]+)", re.M)
_PPL_Q_RE     = re.compile(r"^Mean PPL\(Q\)\s*:\s*(-?[\d.]+)", re.M)
_PPL_BASE_RE  = re.compile(r"^Mean PPL\(base\)\s*:\s*(-?[\d.]+)", re.M)
_KLD_RE       = re.compile(r"^Mean\s+KLD:\s*(-?[\d.]+)", re.M)
_SAMETOP_RE   = re.compile(r"^Same top p:\s*(-?[\d.]+)", re.M)


def run_kl_divergence(llama_perplexity: str, bf16: str, quantized: str,
                      bank_text_file: str, n_ctx: int,
                      extra_args: list[str]) -> dict:
    """Two-pass KL divergence: save BF16 logits, then score the
    quantized model against them.

    Returns the parsed metric dict. Raises ProbeError if either pass
    fails or the summary cannot be parsed -- a silently-zero metric
    here would read as "perfect", which is the worst possible failure
    mode for a gate.
    """
    with tempfile.TemporaryDirectory(prefix="tessera_l4_") as tmp:
        base_logits = os.path.join(tmp, "base.dat")

        save = [
            llama_perplexity, "-m", bf16, "-f", bank_text_file,
            "-c", str(n_ctx), "--save-all-logits", base_logits, *extra_args,
        ]
        try:
            proc = subprocess.run(save, capture_output=True, text=True, check=False)
        except OSError as exc:
            raise ProbeError(f"cannot run {llama_perplexity}: {exc}") from exc
        if proc.returncode != 0:
            raise ProbeError(
                f"--save-all-logits pass failed (rc={proc.returncode})\n"
                f"  stderr: {proc.stderr[-800:]}"
            )

        score = [
            llama_perplexity, "-m", quantized, "-f", bank_text_file,
            "-c", str(n_ctx), "--kl-divergence-base", base_logits,
            "--kl-divergence", *extra_args,
        ]
        proc = subprocess.run(score, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise ProbeError(
                f"--kl-divergence pass failed (rc={proc.returncode})\n"
                f"  stderr: {proc.stderr[-800:]}"
            )

        # llama-perplexity writes its summary to stderr under some log
        # configurations; search both streams.
        blob = proc.stdout + "\n" + proc.stderr

        def grab(rx, label):
            m = rx.search(blob)
            if not m:
                raise ProbeError(
                    f"could not parse '{label}' from llama-perplexity output. "
                    f"The summary format may have changed upstream; refusing to "
                    f"report a default value.\n  tail: {blob[-800:]}"
                )
            return float(m.group(1))

        return {
            "ppl_quant": grab(_PPL_Q_RE, "Mean PPL(Q)"),
            "ppl_base": grab(_PPL_BASE_RE, "Mean PPL(base)"),
            "delta_ppl": grab(_PPL_DIFF_RE, "Mean PPL(Q)-PPL(base)"),
            # llama-perplexity reports the ratio directly (with its own
            # covariance-aware uncertainty); parse it rather than
            # dividing our two rounded values.
            "ppl_ratio": grab(_PPL_RATIO_RE, "Mean PPL(Q)/PPL(base)"),
            "mean_kld": grab(_KLD_RE, "Mean KLD"),
            "top1_agreement_pct": grab(_SAMETOP_RE, "Same top p"),
        }


def verdict(n_mismatch: int, ppl_ratio: float | None) -> str:
    if ppl_ratio is not None and ppl_ratio > PPL_RATIO_FAIL:
        return "FAIL"
    if n_mismatch == 0:
        return "PASS"
    if n_mismatch == 1:
        return "WARN"
    return "FAIL"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bf16", required=True, help="BF16/F16 reference GGUF")
    ap.add_argument("--quantized", required=True, help="quantized GGUF under test")
    ap.add_argument("--bank", default=str(DEFAULT_BANK), help="prompt bank JSON")
    ap.add_argument("--llama-cli", default="./build/bin/llama-cli")
    ap.add_argument("--llama-perplexity", default="./build/bin/llama-perplexity")
    ap.add_argument("--out", default="", help="write the JSON report here")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--n-ctx", type=int, default=2048)
    ap.add_argument("--skip-ppl", action="store_true",
                    help="exact-match only (fast path for a per-PR gate)")
    ap.add_argument("--extra-arg", action="append", default=[],
                    help="pass through to both binaries; repeatable")
    args = ap.parse_args()

    t0 = time.monotonic()
    try:
        prompts = load_bank(Path(args.bank))

        results = []
        n_mismatch = 0
        for p in prompts:
            ref = greedy_generate(args.llama_cli, args.bf16, p["path"],
                                  p["n_tokens"], args.seed, args.n_ctx,
                                  args.extra_arg)
            got = greedy_generate(args.llama_cli, args.quantized, p["path"],
                                  p["n_tokens"], args.seed, args.n_ctx,
                                  args.extra_arg)
            match = (ref == got)
            if not match:
                n_mismatch += 1
            results.append({
                "name": p["name"],
                "domain": p["domain"],
                "n_tokens": p["n_tokens"],
                "exact_match": match,
                "reference": ref,
                "quantized": got,
            })

        divergence = None
        if not args.skip_ppl:
            # llama-perplexity needs a single text blob with enough
            # tokens to fill at least one context window; the bank
            # concatenated is what we score.
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                             encoding="utf-8") as tf:
                tf.write("\n\n".join(p["text"] for p in prompts))
                bank_text = tf.name
            try:
                divergence = run_kl_divergence(
                    args.llama_perplexity, args.bf16, args.quantized,
                    bank_text, args.n_ctx, args.extra_arg)
            finally:
                os.unlink(bank_text)

        ppl_ratio = divergence["ppl_ratio"] if divergence else None
        v = verdict(n_mismatch, ppl_ratio)

    except ProbeError as exc:
        print(f"e2e_probe: harness error: {exc}", file=sys.stderr)
        return 3

    report = {
        "schema": SCHEMA_NAME,
        "verdict": v,
        "bf16_model": args.bf16,
        "quantized_model": args.quantized,
        "bank": args.bank,
        "seed": args.seed,
        "n_prompts": len(prompts),
        "n_mismatch": n_mismatch,
        "duration_s": round(time.monotonic() - t0, 2),
        "prompts": results,
        "divergence": divergence,
    }

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
            f.write("\n")

    print(f"L4 {v}: {len(prompts) - n_mismatch}/{len(prompts)} exact-match", end="")
    if divergence:
        print(f" | dPPL={divergence['delta_ppl']:+.4f}"
              f" ratio={divergence['ppl_ratio']:.3f}"
              f" KLD={divergence['mean_kld']:.5f}"
              f" top1={divergence['top1_agreement_pct']:.2f}%")
    else:
        print(" | ppl skipped")

    for r in results:
        if not r["exact_match"]:
            print(f"  mismatch [{r['name']}/{r['domain']}]\n"
                  f"    bf16: {r['reference']!r}\n"
                  f"    quant: {r['quantized']!r}", file=sys.stderr)

    return {"PASS": 0, "WARN": 1, "FAIL": 2}[v]


if __name__ == "__main__":
    sys.exit(main())
