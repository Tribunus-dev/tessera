#!/usr/bin/env python3
"""compare-cosine.py

W3 task 3.9 (master-plan criterion 21): compares two logit dumps produced
by tools/dump-logits and reports cosine similarity + relative Frobenius
error. Exits 0 iff both pass the criterion's bar (cosine >= 0.999 AND
Frobenius_rel <= 0.01); exits 1 on a threshold miss, exits 2 on a
malformed/mismatched input pair (distinct from a real parity failure -
scripts/validate-host-amd.sh depends on this distinction for its own
per-leg exit codes).

Dump format (see tools/dump-logits/dump-logits.cpp): 4-byte magic "TSLG",
u32 n_vocab (little-endian), then n_vocab float32 values.
"""

import argparse
import struct
import sys

MAGIC = b"TSLG"


def load_dump(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic != MAGIC:
            raise ValueError(f"{path}: bad magic {magic!r}, expected {MAGIC!r}")
        (n_vocab,) = struct.unpack("<I", f.read(4))
        data = f.read(4 * n_vocab)
        if len(data) != 4 * n_vocab:
            raise ValueError(f"{path}: truncated dump (expected {n_vocab} floats, got {len(data)//4})")
        return struct.unpack(f"<{n_vocab}f", data)


def cosine_similarity(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(y * y for y in b) ** 0.5
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def frobenius_rel_error(a, b):
    # ||a - b|| / ||a||, matching the master plan's "Frobenius_rel"
    # wording for a single vector (Frobenius norm of a vector reduces to
    # the ordinary L2 norm).
    diff_sq = sum((x - y) ** 2 for x, y in zip(a, b))
    norm_a_sq = sum(x * x for x in a)
    if norm_a_sq == 0.0:
        return float("inf") if diff_sq > 0.0 else 0.0
    return (diff_sq ** 0.5) / (norm_a_sq ** 0.5)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reference", help="path to the reference (bf16) logit dump")
    ap.add_argument("candidate", help="path to the candidate (host-amd) logit dump")
    ap.add_argument("--cosine-min", type=float, default=0.999, help="minimum acceptable cosine similarity (default: 0.999)")
    ap.add_argument("--frobenius-max", type=float, default=0.01, help="maximum acceptable relative Frobenius error (default: 0.01)")
    ap.add_argument("--label", default="", help="optional label for the report line (e.g. 'ngl0' / 'ngl999')")
    args = ap.parse_args()

    try:
        ref = load_dump(args.reference)
        cand = load_dump(args.candidate)
    except (OSError, ValueError) as e:
        print(f"compare-cosine: error loading dumps: {e}", file=sys.stderr)
        return 2

    if len(ref) != len(cand):
        print(
            f"compare-cosine: vocab size mismatch: reference has {len(ref)}, "
            f"candidate has {len(cand)} - not comparable (different models?)",
            file=sys.stderr,
        )
        return 2

    cos = cosine_similarity(ref, cand)
    frob = frobenius_rel_error(ref, cand)

    label = f"[{args.label}] " if args.label else ""
    print(f"{label}cosine={cos:.8f} (min {args.cosine_min}) frobenius_rel={frob:.8f} (max {args.frobenius_max})")

    ok = (cos >= args.cosine_min) and (frob <= args.frobenius_max)
    if not ok:
        print(f"{label}FAIL: parity criterion not met", file=sys.stderr)
        return 1
    print(f"{label}PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
