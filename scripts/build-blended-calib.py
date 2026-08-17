#!/usr/bin/env python3
#
# build-blended-calib.py
#
# Builds a domain-diverse calibration corpus for llama-imatrix by blending
# three sources instead of relying on wikitext-2 alone:
#   - general/encyclopedic prose (wikitext-2, already used elsewhere)
#   - source code (real files across several languages, fetched from GitHub)
#   - instruction/dialogue text (Stanford Alpaca's instruction-response pairs)
#
# Motivation: a calibration corpus that's exclusively formal Wikipedia prose
# calibrates activation statistics (and, for SEPTQ, the Hessian) to what
# matters for encyclopedic text specifically - channels that matter for code
# or dialogue but are quiet on Wikipedia-style writing can end up
# under-weighted. Blending domains gets calibration statistics that actually
# reflect a general-purpose model's real input distribution, not just one
# register.
#
# Sources are split into "documents" and interleaved round-robin (not
# concatenated block-by-block) so that ANY prefix of the resulting file -
# not just the whole thing - contains a reasonable mix of all three domains.
# This matters because llama-imatrix's --calib-tokens flag caps how many
# per-token activation rows get captured per tensor; if the corpus were
# [wikitext][code][alpaca] concatenated and the cap were reached partway
# through the (much larger) wikitext block, the code/alpaca documents would
# never contribute to the captured calibration sample at all.
#
# Usage:
#   python3 scripts/build-blended-calib.py
#
# Output: blended-calib/blended-corpus.raw (plain text, feed to
# llama-imatrix via -f blended-calib/blended-corpus.raw)
#

import json
import os
import random
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "blended-calib"
SRC_DIR = OUT_DIR / "sources"
WIKITEXT_FILE = REPO_ROOT / "wikitext-2-raw" / "wiki.test.raw"
OUT_FILE = OUT_DIR / "blended-corpus.raw"

# Real, permissively-licensed source files across languages, chosen for
# breadth (not cherry-picked for any particular property) - large enough
# individually to each contribute many "documents" once split.
CODE_URLS = [
    "https://raw.githubusercontent.com/python/cpython/main/Lib/argparse.py",
    "https://raw.githubusercontent.com/python/cpython/main/Lib/asyncio/tasks.py",
    "https://raw.githubusercontent.com/torvalds/linux/master/kernel/sched/core.c",
    "https://raw.githubusercontent.com/torvalds/linux/master/fs/read_write.c",
    "https://raw.githubusercontent.com/microsoft/TypeScript/main/src/compiler/checker.ts",
    "https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/base/common/arrays.ts",
    "https://raw.githubusercontent.com/golang/go/master/src/net/http/server.go",
    "https://raw.githubusercontent.com/golang/go/master/src/encoding/json/decode.go",
    "https://raw.githubusercontent.com/rust-lang/rust/master/compiler/rustc_middle/src/ty/mod.rs",
    "https://raw.githubusercontent.com/rust-lang/cargo/master/src/cargo/core/resolver/mod.rs",
    "https://raw.githubusercontent.com/redis/redis/unstable/src/t_hash.c",
    "https://raw.githubusercontent.com/redis/redis/unstable/src/server.c",
    "https://raw.githubusercontent.com/apache/spark/master/core/src/main/scala/org/apache/spark/SparkContext.scala",
    "https://raw.githubusercontent.com/spring-projects/spring-framework/main/spring-core/src/main/java/org/springframework/core/annotation/AnnotationUtils.java",
    "https://raw.githubusercontent.com/facebook/react/main/packages/react-reconciler/src/ReactFiberBeginWork.js",
]

ALPACA_URL = "https://raw.githubusercontent.com/tatsu-lab/stanford_alpaca/main/alpaca_data.json"

# Target mix (by document count, not byte count - documents vary widely in
# size across sources, so a byte-ratio target would be dominated by whichever
# source happens to have the longest individual files).
TARGET_RATIO = {"general": 0.5, "code": 0.3, "dialogue": 0.2}

SEED = 0xC411B  # deterministic build


def fetch(url: str, dest: Path) -> bytes:
    if dest.exists():
        return dest.read_bytes()
    print(f"  fetching {url}", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": "tessera-calib-builder"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = resp.read()
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return data


def split_general_docs(text: str, max_words: int = 400) -> list[str]:
    # wikitext-2's raw format uses " = Title = " lines as article boundaries.
    docs, cur = [], []
    for line in text.splitlines():
        if line.strip().startswith("= ") and line.strip().endswith(" =") and cur:
            docs.append("\n".join(cur))
            cur = []
        cur.append(line)
    if cur:
        docs.append("\n".join(cur))
    # Some articles are long; cap each document so no single one dominates
    # its interleave slot.
    out = []
    for d in docs:
        words = d.split()
        for i in range(0, len(words), max_words):
            out.append(" ".join(words[i:i + max_words]))
    return [d for d in out if d.strip()]


def split_code_docs(text: str, chunk_lines: int = 60) -> list[str]:
    lines = text.splitlines()
    return [
        "\n".join(lines[i:i + chunk_lines])
        for i in range(0, len(lines), chunk_lines)
        if any(l.strip() for l in lines[i:i + chunk_lines])
    ]


def build_dialogue_docs(alpaca_json: bytes, n: int = 2000) -> list[str]:
    data = json.loads(alpaca_json)
    rng = random.Random(SEED)
    sample = rng.sample(data, min(n, len(data)))
    docs = []
    for row in sample:
        instr = row.get("instruction", "").strip()
        inp = row.get("input", "").strip()
        out = row.get("output", "").strip()
        if not instr or not out:
            continue
        if inp:
            docs.append(f"Instruction: {instr}\nInput: {inp}\nResponse: {out}")
        else:
            docs.append(f"Instruction: {instr}\nResponse: {out}")
    return docs


def interleave(doc_lists: dict[str, list[str]], ratio: dict[str, float]) -> list[str]:
    rng = random.Random(SEED)
    for docs in doc_lists.values():
        rng.shuffle(docs)
    pos = {k: 0 for k in doc_lists}
    out = []
    total_remaining = sum(len(v) for v in doc_lists.values())
    while total_remaining > 0:
        # Pick the source most "behind" its target ratio among sources that
        # still have documents left - keeps the interleave balanced across
        # the whole file, not just on average.
        available = [k for k in doc_lists if pos[k] < len(doc_lists[k])]
        if not available:
            break
        emitted_total = sum(pos.values()) or 1
        deficit = {
            k: ratio[k] - (pos[k] / emitted_total) for k in available
        }
        pick = max(available, key=lambda k: deficit[k])
        out.append(doc_lists[pick][pos[pick]])
        pos[pick] += 1
        total_remaining -= 1
    return out


def main() -> int:
    SRC_DIR.mkdir(parents=True, exist_ok=True)

    if not WIKITEXT_FILE.exists():
        print(f"error: {WIKITEXT_FILE} not found - run scripts/get-wikitext-2.sh first",
              file=sys.stderr)
        return 1
    general_docs = split_general_docs(WIKITEXT_FILE.read_text(errors="replace"))
    print(f"general: {len(general_docs)} documents from wikitext-2")

    code_texts = []
    for i, url in enumerate(CODE_URLS):
        ext = url.rsplit(".", 1)[-1]
        dest = SRC_DIR / f"code_{i:02d}.{ext}"
        try:
            data = fetch(url, dest)
            code_texts.append(data.decode("utf-8", errors="replace"))
        except Exception as e:
            print(f"  WARN: failed to fetch {url}: {e}", file=sys.stderr)
    code_docs = []
    for t in code_texts:
        code_docs.extend(split_code_docs(t))
    print(f"code: {len(code_docs)} documents from {len(code_texts)} files")

    alpaca_dest = SRC_DIR / "alpaca_data.json"
    alpaca_data = fetch(ALPACA_URL, alpaca_dest)
    dialogue_docs = build_dialogue_docs(alpaca_data)
    print(f"dialogue: {len(dialogue_docs)} documents from Alpaca")

    blended = interleave(
        {"general": general_docs, "code": code_docs, "dialogue": dialogue_docs},
        TARGET_RATIO,
    )
    OUT_FILE.write_text("\n\n".join(blended) + "\n")
    total_words = sum(len(d.split()) for d in blended)
    print(f"wrote {OUT_FILE} ({len(blended)} documents, ~{total_words} words, "
          f"{OUT_FILE.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
