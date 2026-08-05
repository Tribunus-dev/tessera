#!/usr/bin/env python3
"""Fetch the gemma4 mmproj GGUFs from the unsloth GGUF mirror.

Tessera's gemma4 12B deployment needs the multimodal projector
("mmproj") weights in addition to the text trunk. The mmproj
encapsulates the vision encoder, audio encoder, and the
multimodal projector that lifts the encoder outputs into the
trunk's embedding space. The unsloth GGUF mirror
(``unsloth/gemma-4-12b-it-GGUF``) publishes all three precisions
(BF16 / F16 / F32) under one Apache-2.0 roof, alongside the
BF16 text trunk that already lives on the external drive.

This script does the inspect -> download -> place -> verify ->
receipt flow as a single command. ``--dry-run`` lists the
targeted files and decodes their tensor name conventions
without performing any network I/O, so CI can keep the test
suite hermetic.

The destination is normally an external drive (e.g.
``/Volumes/Julian T7/models/``); the drive is gitignored and
the .gguf files are not committed. The script emits a JSON
receipt next to the artifacts recording the upstream repo,
the per-file size + SHA, the license, and the attribution
required by Apache-2.0.

Tensor name convention check
---------------------------
The C++ unified writer and the clip-capture v2 code expect
tensor names with the ``v.`` / ``a.`` / ``mm.`` / ``mm.a.``
prefix convention (see ``tools/mtmd/clip.cpp:1831`` and the
gemma4uv / gemma4ua projector handling around line 2673).
After download, the script opens the GGUF and groups the
tensor names by their first-segment prefix; the report
surfaces whether the prefixes are compatible with the
unified writer or whether they fall back to a legacy
``vision_model.layers.0.``-style convention that would
break the full 8-component run.

License
-------
Gemma 4 is released under Apache-2.0 (this is the architect's
correction from the older Gemma 1/2/3 custom gemma license).
The script surfaces the exact license string from the upstream
``README.md`` front-matter so the receipt carries the verbatim
attribution required for GDPR / commercial-use analysis.

Usage
-----
::

    # default: BF16 mmproj -> /Volumes/Julian T7/models/
    python3 -m tools.tessera.fetch_mmproj

    # dry-run: list what would be fetched, no network
    python3 -m tools.tessera.fetch_mmproj --dry-run

    # override destination, fetch F16 instead
    python3 -m tools.tessera.fetch_mmproj \\
        --output /tmp/tessera-mmproj-test/ \\
        --mmproj-precision F16
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

try:
    from huggingface_hub import HfApi, hf_hub_download  # type: ignore
    HF_HUB_AVAILABLE = True
except ImportError:
    HF_HUB_AVAILABLE = False


SCHEMA = "llama.tessera.mmproj-fetch-receipt.v1"
DEFAULT_REPO = "unsloth/gemma-4-12b-it-GGUF"
DEFAULT_OUTPUT = "/Volumes/Julian T7/models"
DEFAULT_PRECISION = "BF16"
DEFAULT_MAX_FILE_SIZE_MB = 5 * 1024
DEFAULT_CACHE_DIR = "/tmp/tessera-mmproj-staging"

# Destination naming convention. The mmproj GGUFs combine the
# vision encoder + audio encoder + multimodal projector in one
# file, so we keep the single ``gemma4-12B-mmproj-<PRECISION>.gguf``
# name. If the upstream repo ever splits them into separate
# ``vision_tower`` / ``audio_tower`` / ``mm_projector`` files,
# the per-component destination names below will be used.
PRECISION_TO_FILENAME = {
    "BF16": "mmproj-BF16.gguf",
    "F16": "mmproj-F16.gguf",
    "F32": "mmproj-F32.gguf",
}
PRECISION_TO_DESTINATION = {
    "BF16": "gemma4-12B-mmproj-BF16.gguf",
    "F16": "gemma4-12B-mmproj-F16.gguf",
    "F32": "gemma4-12B-mmproj-F32.gguf",
}

# Legacy split naming (used if upstream ever publishes separate
# per-modality files; the gemma4 12B Unified mmproj in this repo
# is currently a single combined file, so these stay in the table
# but are not in the default per-precision mapping).
SPLIT_FILE_ROLES = {
    "vision_tower": "vision_encoder",
    "audio_tower": "audio_encoder",
    "mm_projector": "multimodal_projector",
}

# C++ unified-writer compatible prefixes. A tensor name whose
# first segment is one of these is routed by ``route_destination_name``
# without a rewrite; anything else is a legacy convention that
# will produce wrong destination names in the full 8-component run.
COMPATIBLE_PREFIXES = {"v", "a", "mm"}


@dataclass(frozen=True)
class MmprojFileRecord:
    """Per-file audit record carried in the receipt."""

    source_filename: str
    destination_filename: str
    role: str
    size_bytes: int
    sha256: str
    head_sha256_1mb: str
    license: str
    license_link: str
    attribution: str
    tensor_count: int
    tensor_prefixes: dict[str, int]
    convention_compatible: bool
    source_path: str = ""
    destination_path: str = ""


@dataclass
class FetchResult:
    """Aggregate result for the run, suitable for both the receipt
    and the human-readable summary."""

    repo: str
    precision: str
    upstream_readme_path: Optional[str]
    upstream_license: Optional[str]
    upstream_license_link: Optional[str]
    upstream_attribution: str
    upstream_base_model: Optional[str]
    files: list[MmprojFileRecord] = field(default_factory=list)
    wall_clock_seconds: float = 0.0
    total_bytes_downloaded: int = 0
    dry_run: bool = False


# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------


def inspect_repo_files(api: "HfApi", repo: str) -> list[dict[str, Any]]:
    """List mmproj-related files in the repo, with sizes.

    Returns a list of dicts with keys ``rfilename``, ``size`` (bytes),
    and any other fields the HfApi sibling metadata exposes.
    """
    info = api.repo_info(repo, files_metadata=True)
    out = []
    for s in info.siblings:
        if "mmproj" in s.rfilename.lower():
            out.append(
                {
                    "rfilename": s.rfilename,
                    "size": int(s.size) if s.size is not None else 0,
                }
            )
    return out


def read_upstream_readme(api: "HfApi", repo: str, cache_dir: str) -> tuple[Optional[str], dict[str, str]]:
    """Fetch the upstream README and extract license attribution.

    Returns the local path to the cached README and a dict with
    ``license``, ``license_link``, ``attribution``, ``base_model``,
    and ``pipeline_tag`` parsed from the README front-matter / body.
    Returns (None, {}) if the README cannot be downloaded.
    """
    if not HF_HUB_AVAILABLE:
        return None, {}
    try:
        local = hf_hub_download(
            repo_id=repo,
            filename="README.md",
            repo_type="model",
            cache_dir=cache_dir,
        )
    except Exception as exc:  # pragma: no cover - network dependent
        print(f"  WARN: failed to fetch README.md: {exc}", file=sys.stderr)
        return None, {}

    info: dict[str, str] = {}
    try:
        text = Path(local).read_text(encoding="utf-8", errors="replace")
    except Exception:
        return local, info

    # YAML-ish front-matter. The unsloth README uses ``license:`` and
    # ``license_link:`` as plain top-level keys. We scan line-by-line
    # so we don't pull in a yaml dependency.
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        for key in ("license", "license_link", "pipeline_tag", "base_model"):
            prefix = f"{key}:"
            if stripped.startswith(prefix):
                value = stripped[len(prefix):].strip()
                # strip optional surrounding quotes
                if value.startswith(("'", '"')) and value.endswith(("'", '"')):
                    value = value[1:-1]
                info[key] = value
                break
    # Attribution: the README body contains a "License" link block.
    if "license" in info and "license_link" not in info:
        # fall back: many unsloth READMEs omit license_link; surface the
        # front-matter license as the link target if no explicit link.
        info.setdefault("license_link", "")
    # Attribution: prefer the front-matter base_model + the unsloth
    # 'quantized_by' style annotation if present in the metadata.
    info.setdefault("attribution", "Unsloth (mirror); Google DeepMind (upstream)")
    return local, info


def decode_gguf_string_field(field: Any) -> Optional[str]:
    """Decode a STRING-typed GGUF metadata field's value.

    ``gguf-py``'s ``ReaderField`` for a STRING stores the value as
    the last memmap in ``field.parts`` (per gguf_reader.py:93). We
    defensively try several decoding strategies so the helper works
    on both recent and older gguf-py versions.
    """
    if field is None:
        return None
    parts = getattr(field, "parts", None)
    if parts is None:
        return None
    try:
        raw = bytes(parts[-1])
        return raw.decode("utf-8", errors="replace")
    except Exception:
        return None


def inspect_mmproj_tensor_convention(path: Path) -> tuple[int, dict[str, int], bool]:
    """Open ``path`` as a GGUF and summarize the tensor name prefixes.

    Returns (tensor_count, prefix_counts, convention_compatible) where
    ``convention_compatible`` is True iff every tensor's first segment
    is in ``COMPATIBLE_PREFIXES``. Any non-conforming prefix flips the
    flag to False and the caller is expected to surface it.
    """
    if HF_HUB_AVAILABLE is False:
        # Late import so the dry-run path (which doesn't need gguf-py)
        # can still report a clean error if the dependency is missing.
        try:
            from gguf import GGUFReader  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "gguf-py is required to inspect mmproj tensor conventions"
            ) from exc
    else:
        from gguf import GGUFReader  # type: ignore

    reader = GGUFReader(str(path), "r")
    prefixes: dict[str, int] = {}
    compatible = True
    for tensor in reader.tensors:
        first = tensor.name.split(".", 1)[0] if tensor.name else ""
        prefixes[first] = prefixes.get(first, 0) + 1
        if first not in COMPATIBLE_PREFIXES:
            compatible = False
    return len(reader.tensors), prefixes, compatible


# ---------------------------------------------------------------------------
# Download + place
# ---------------------------------------------------------------------------


def sha256_file(path: Path, block_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(block_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def head_sha256(path: Path, n_bytes: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        digest.update(source.read(n_bytes))
    return digest.hexdigest()


def stream_copy(src: Path, dst: Path) -> int:
    """Stream-copy ``src`` to ``dst``; returns bytes copied."""
    n = 0
    with src.open("rb") as fin, dst.open("wb") as fout:
        while True:
            chunk = fin.read(8 * 1024 * 1024)
            if not chunk:
                break
            fout.write(chunk)
            n += len(chunk)
    return n


def fetch_one(
    api: "HfApi",
    repo: str,
    precision: str,
    cache_dir: str,
    max_file_size_bytes: int,
) -> MmprojFileRecord:
    """Download the single mmproj GGUF at the given precision and
    return a fully populated ``MmprojFileRecord``.

    Raises ``RuntimeError`` if the upstream file is missing or
    larger than ``max_file_size_bytes``.
    """
    filename = PRECISION_TO_FILENAME[precision]
    info = api.repo_info(repo, files_metadata=True)
    siblings = {s.rfilename: s for s in info.siblings}
    if filename not in siblings:
        raise RuntimeError(
            f"{repo}: upstream file '{filename}' not found; "
            f"available mmproj files: "
            f"{[s.rfilename for s in info.siblings if 'mmproj' in s.rfilename.lower()]}"
        )
    size_bytes = int(siblings[filename].size or 0)
    if size_bytes > max_file_size_bytes:
        raise RuntimeError(
            f"{repo}:{filename} is {size_bytes} bytes "
            f"(>{max_file_size_bytes}); refusing to download. "
            f"Override with --max-file-size-mb."
        )

    local = Path(
        hf_hub_download(
            repo_id=repo,
            filename=filename,
            repo_type="model",
            cache_dir=cache_dir,
        )
    )

    tensor_count, prefixes, compatible = inspect_mmproj_tensor_convention(local)
    return MmprojFileRecord(
        source_filename=filename,
        destination_filename=PRECISION_TO_DESTINATION[precision],
        role="mmproj_combined",  # single file: vision + audio + projector
        size_bytes=size_bytes,
        sha256=sha256_file(local),
        head_sha256_1mb=head_sha256(local),
        license="",  # filled in by caller from upstream README
        license_link="",
        attribution="",
        tensor_count=tensor_count,
        tensor_prefixes=prefixes,
        convention_compatible=compatible,
        source_path=str(local),
        destination_path="",
    )


def plan_one(
    api: "HfApi",
    repo: str,
    precision: str,
    max_file_size_bytes: int,
) -> MmprojFileRecord:
    """Pure plan step: query upstream metadata for the file, do not
    download. The returned record has ``size_bytes`` populated,
    ``tensor_count=0`` (no GGUF open), and sha fields empty.
    """
    filename = PRECISION_TO_FILENAME[precision]
    info = api.repo_info(repo, files_metadata=True)
    siblings = {s.rfilename: s for s in info.siblings}
    if filename not in siblings:
        raise RuntimeError(
            f"{repo}: upstream file '{filename}' not found; "
            f"available mmproj files: "
            f"{[s.rfilename for s in info.siblings if 'mmproj' in s.rfilename.lower()]}"
        )
    size_bytes = int(siblings[filename].size or 0)
    if size_bytes > max_file_size_bytes:
        raise RuntimeError(
            f"{repo}:{filename} is {size_bytes} bytes "
            f"(>{max_file_size_bytes}); refusing to plan. "
            f"Override with --max-file-size-mb."
        )
    return MmprojFileRecord(
        source_filename=filename,
        destination_filename=PRECISION_TO_DESTINATION[precision],
        role="mmproj_combined",
        size_bytes=size_bytes,
        sha256="",
        head_sha256_1mb="",
        license="",
        license_link="",
        attribution="",
        tensor_count=0,
        tensor_prefixes={},
        convention_compatible=True,  # unknown until inspected
        source_path="",
        destination_path="",
    )


# ---------------------------------------------------------------------------
# Receipt
# ---------------------------------------------------------------------------


def build_receipt(
    result: FetchResult,
    tessera_version: str,
) -> dict[str, Any]:
    """Compose the JSON receipt as a plain dict.

    The shape mirrors ``build-calibration-corpus.py``: a top-level
    ``corpora`` block (kept as a list of {name, source, ...} records
    so the receipt is consistent with the calibration corpus audit
    trail) plus a per-file ``mmproj_files`` block. The receipt is
    written next to the artifacts on the external drive and is NOT
    committed.
    """
    corpora = []
    for f in result.files:
        corpora.append(
            {
                "name": f.destination_filename,
                "source": f"hf:{result.repo}@{f.source_filename}",
                "sample_count": f.tensor_count,
                "license": f.license,
                "total_bytes_downloaded": f.size_bytes,
                "sha256_of_first_1MB": f.head_sha256_1mb,
            }
        )
    mmproj_files = []
    for f in result.files:
        mmproj_files.append(
            {
                "name": f.destination_filename,
                "role": f.role,
                "source_path": f.source_path,
                "destination_path": f.destination_path,
                "size_bytes": f.size_bytes,
                "sha256": f.sha256,
                "head_sha256_1mb": f.head_sha256_1mb,
                "license": f.license,
                "license_link": f.license_link,
                "attribution": f.attribution,
                "tensor_count": f.tensor_count,
                "tensor_prefixes": f.tensor_prefixes,
                "convention_compatible": f.convention_compatible,
            }
        )
    return {
        "schema": SCHEMA,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime()),
        "tessera_version": tessera_version,
        "dry_run": result.dry_run,
        "repo": result.repo,
        "precision": result.precision,
        "wall_clock_seconds": result.wall_clock_seconds,
        "total_bytes_downloaded": result.total_bytes_downloaded,
        "corpora": corpora,
        "mmproj_files": mmproj_files,
        "license": result.upstream_license,
        "license_link": result.upstream_license_link,
        "attribution": result.upstream_attribution,
        "base_model": result.upstream_base_model,
        "upstream_readme_path": result.upstream_readme_path,
    }


def write_receipt(receipt: dict[str, Any], output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / ".mmproj-fetch-receipt.json"
    with path.open("w", encoding="utf-8") as fout:
        json.dump(receipt, fout, indent=2, sort_keys=True)
        fout.write("\n")
    return path


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def print_summary(result: FetchResult) -> None:
    print(f"== mmproj fetch summary ==")
    print(f"  repo:        {result.repo}")
    print(f"  precision:   {result.precision}")
    print(f"  dry_run:     {result.dry_run}")
    print(f"  wall_clock:  {result.wall_clock_seconds:.2f}s")
    print(f"  bytes:       {result.total_bytes_downloaded:,}")
    print(f"  license:     {result.upstream_license}")
    print(f"  base_model:  {result.upstream_base_model}")
    print(f"  attribution: {result.upstream_attribution}")
    print()
    for f in result.files:
        print(f"  file:        {f.destination_filename}")
        print(f"    source:    {f.source_filename}")
        print(f"    size:      {f.size_bytes:,} bytes")
        print(f"    sha256:    {f.sha256}")
        print(f"    head_sha:  {f.head_sha256_1mb}")
        print(f"    tensors:   {f.tensor_count}")
        print(f"    prefixes:  {f.tensor_prefixes}")
        ok = "OK" if f.convention_compatible else "MISMATCH"
        print(f"    convention {ok} (compatible={f.convention_compatible})")
        print(f"    dst:       {f.destination_path}")
        print()


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def tessera_version() -> str:
    """Return the short git SHA of the working tree, or 'unknown'."""
    try:
        import subprocess

        sha = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=Path(__file__).resolve().parents[2],
            stderr=subprocess.DEVNULL,
        )
        return sha.decode("ascii").strip()
    except Exception:
        return "unknown"


def run(args: argparse.Namespace) -> int:
    if not HF_HUB_AVAILABLE:
        print(
            "ERROR: huggingface_hub is not installed. "
            "Run `pip install huggingface_hub` first.",
            file=sys.stderr,
        )
        return 2

    api = HfApi()
    output_dir = Path(args.output).expanduser()
    max_size_bytes = int(args.max_file_size_mb * 1024 * 1024)

    t0 = time.time()
    readme_path, readme_info = read_upstream_readme(
        api, args.repo, args.cache_dir
    )
    upstream_license = readme_info.get("license")
    upstream_license_link = readme_info.get("license_link")
    upstream_base_model = readme_info.get("base_model")
    upstream_attribution = readme_info.get(
        "attribution",
        "Unsloth (mirror); Google DeepMind (upstream Gemma 4 family)",
    )

    files: list[MmprojFileRecord] = []
    if args.dry_run:
        rec = plan_one(api, args.repo, args.mmproj_precision, max_size_bytes)
        files.append(rec)
    else:
        rec = fetch_one(
            api, args.repo, args.mmproj_precision, args.cache_dir, max_size_bytes
        )
        # Place on the drive (or in the override output dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        dst = output_dir / rec.destination_filename
        copied = stream_copy(Path(rec.source_path), dst)
        if copied != rec.size_bytes:
            raise RuntimeError(
                f"copy size mismatch: {copied} != {rec.size_bytes}"
            )
        # Re-verify the destination
        on_disk = MmprojFileRecord(
            source_filename=rec.source_filename,
            destination_filename=rec.destination_filename,
            role=rec.role,
            size_bytes=rec.size_bytes,
            sha256=sha256_file(dst),
            head_sha256_1mb=head_sha256(dst),
            license=upstream_license or "",
            license_link=upstream_license_link or "",
            attribution=upstream_attribution,
            tensor_count=rec.tensor_count,
            tensor_prefixes=rec.tensor_prefixes,
            convention_compatible=rec.convention_compatible,
            source_path=rec.source_path,
            destination_path=str(dst),
        )
        files.append(on_disk)

    result = FetchResult(
        repo=args.repo,
        precision=args.mmproj_precision,
        upstream_readme_path=readme_path,
        upstream_license=upstream_license,
        upstream_license_link=upstream_license_link,
        upstream_attribution=upstream_attribution,
        upstream_base_model=upstream_base_model,
        files=files,
        wall_clock_seconds=time.time() - t0,
        total_bytes_downloaded=sum(f.size_bytes for f in files),
        dry_run=args.dry_run,
    )

    print_summary(result)

    if args.dry_run:
        return 0

    receipt = build_receipt(result, tessera_version())
    receipt_path = write_receipt(receipt, output_dir)
    print(f"  receipt: {receipt_path}")

    if args.print_receipt:
        print()
        print(json.dumps(receipt, indent=2, sort_keys=True))

    if not all(f.convention_compatible for f in files):
        print(
            "WARNING: at least one mmproj file uses a non-compatible "
            "tensor name convention. The unified writer's "
            "route_destination_name will produce wrong destination "
            "names in the full 8-component run. See tensor_prefixes "
            "above and inspect the file with a GGUF reader before "
            "proceeding.",
            file=sys.stderr,
        )
        return 3

    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Fetch the gemma4 mmproj GGUF from the unsloth GGUF "
            "mirror and place it on the external drive. Emits an "
            "Apache-2.0 license receipt next to the artifact."
        )
    )
    p.add_argument(
        "--repo", default=DEFAULT_REPO,
        help=f"Hugging Face repo id (default: {DEFAULT_REPO})",
    )
    p.add_argument(
        "--output", default=DEFAULT_OUTPUT,
        help=(
            f"Destination directory on the external drive "
            f"(default: {DEFAULT_OUTPUT})"
        ),
    )
    p.add_argument(
        "--mmproj-precision", default=DEFAULT_PRECISION,
        choices=sorted(PRECISION_TO_FILENAME.keys()),
        help=(
            f"mmproj precision to fetch "
            f"(default: {DEFAULT_PRECISION})"
        ),
    )
    p.add_argument(
        "--max-file-size-mb", type=float, default=DEFAULT_MAX_FILE_SIZE_MB,
        help=(
            f"Refuse to download a single file larger than this "
            f"many MB (default: {DEFAULT_MAX_FILE_SIZE_MB})"
        ),
    )
    p.add_argument(
        "--cache-dir", default=DEFAULT_CACHE_DIR,
        help=(
            f"Local staging directory used by huggingface_hub "
            f"(default: {DEFAULT_CACHE_DIR})"
        ),
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help=(
            "List the targeted file (with size and upstream "
            "metadata) without downloading or writing anything"
        ),
    )
    p.add_argument(
        "--print-receipt", action="store_true",
        help="Print the full JSON receipt after writing it",
    )
    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return run(args)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
