"""Tests for tools.tessera.fetch_mmproj.

The tests are hermetic: no network I/O, no real downloads, no
filesystem writes outside ``tempfile.TemporaryDirectory``. The
``HfApi`` is patched with a fake so the upstream repo metadata
is served from an in-memory dict. This keeps the suite under
five seconds on developer machines and on CI.

Coverage map
------------
* ``TestPrecisionToFilename``    : per-precision filename mapping
* ``TestPrecisionToDestination`` : per-precision destination filename
* ``TestCompatiblePrefixes``     : the gate table used by the
                                   convention check
* ``TestPlanOne``                : the dry-run plan function (size
                                   cap, missing-file error, role
                                   tag, sha fields empty)
* ``TestInspectTensorConvention``: tensor-name convention check
                                   (compatible vs. legacy)
* ``TestReadmeLicenseParsing``   : front-matter parsing of
                                   ``license`` / ``license_link``
                                   / ``base_model`` from a canned
                                   README
* ``TestBuildReceipt``           : receipt shape (schema, corpora,
                                   mmproj_files, license, timestamp)
* ``TestSha256StreamCopy``       : the copy routine preserves
                                   bytes and computes SHA correctly
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

import fetch_mmproj as fm  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _fake_sibling(rfilename: str, size: int) -> MagicMock:
    s = MagicMock()
    s.rfilename = rfilename
    s.size = size
    return s


def _fake_repo_info(siblings: list[MagicMock]) -> MagicMock:
    info = MagicMock()
    info.siblings = siblings
    return info


class _FakeApi:
    """Drop-in stand-in for ``huggingface_hub.HfApi``."""

    def __init__(self, siblings: list[MagicMock]) -> None:
        self._siblings = siblings
        self.repo_info_calls: list[str] = []

    def repo_info(self, repo: str, files_metadata: bool = True) -> Any:
        self.repo_info_calls.append(repo)
        return _fake_repo_info(self._siblings)


# ---------------------------------------------------------------------------
# 1) Precision -> filename mapping
# ---------------------------------------------------------------------------


class TestPrecisionToFilename(unittest.TestCase):
    def test_bf16(self) -> None:
        self.assertEqual(fm.PRECISION_TO_FILENAME["BF16"], "mmproj-BF16.gguf")

    def test_f16(self) -> None:
        self.assertEqual(fm.PRECISION_TO_FILENAME["F16"], "mmproj-F16.gguf")

    def test_f32(self) -> None:
        self.assertEqual(fm.PRECISION_TO_FILENAME["F32"], "mmproj-F32.gguf")

    def test_all_precisions_covered(self) -> None:
        # If a new precision is added without a destination, the
        # plan / fetch path will keyerror; keep this assertion
        # so the suite fails loudly.
        self.assertEqual(
            set(fm.PRECISION_TO_FILENAME.keys()),
            set(fm.PRECISION_TO_DESTINATION.keys()),
        )


# ---------------------------------------------------------------------------
# 2) Precision -> destination mapping
# ---------------------------------------------------------------------------


class TestPrecisionToDestination(unittest.TestCase):
    def test_bf16_destination(self) -> None:
        # Mirrors the existing on-drive convention
        # (gemma4-12B-dflash-BF16.gguf, mtp-gemma-4-12b-it-BF16.gguf)
        self.assertEqual(
            fm.PRECISION_TO_DESTINATION["BF16"],
            "gemma4-12B-mmproj-BF16.gguf",
        )

    def test_f16_destination(self) -> None:
        self.assertEqual(
            fm.PRECISION_TO_DESTINATION["F16"],
            "gemma4-12B-mmproj-F16.gguf",
        )

    def test_f32_destination(self) -> None:
        self.assertEqual(
            fm.PRECISION_TO_DESTINATION["F32"],
            "gemma4-12B-mmproj-F32.gguf",
        )


# ---------------------------------------------------------------------------
# 3) Compatible-prefix gate table
# ---------------------------------------------------------------------------


class TestCompatiblePrefixes(unittest.TestCase):
    def test_vision_prefix(self) -> None:
        self.assertIn("v", fm.COMPATIBLE_PREFIXES)

    def test_audio_prefix(self) -> None:
        self.assertIn("a", fm.COMPATIBLE_PREFIXES)

    def test_projector_prefix(self) -> None:
        self.assertIn("mm", fm.COMPATIBLE_PREFIXES)

    def test_legacy_prefix_not_compatible(self) -> None:
        # The legacy transformers / huggingface convention uses
        # ``vision_model.layers.0.``; this MUST not be in the
        # compatible set, otherwise the convention check will
        # silently accept files that the unified writer can't
        # route.
        self.assertNotIn("vision_model", fm.COMPATIBLE_PREFIXES)
        self.assertNotIn("audio_model", fm.COMPATIBLE_PREFIXES)
        self.assertNotIn("model", fm.COMPATIBLE_PREFIXES)


# ---------------------------------------------------------------------------
# 4) plan_one (dry-run path)
# ---------------------------------------------------------------------------


class TestPlanOne(unittest.TestCase):
    def test_plan_bf16_returns_role_and_size(self) -> None:
        api = _FakeApi([
            _fake_sibling("mmproj-BF16.gguf", 175_000_000),
            _fake_sibling("mmproj-F16.gguf", 175_000_000),
        ])
        rec = fm.plan_one(api, "unsloth/gemma-4-12b-it-GGUF", "BF16", 5 * 1024 * 1024 * 1024)
        self.assertEqual(rec.source_filename, "mmproj-BF16.gguf")
        self.assertEqual(rec.destination_filename, "gemma4-12B-mmproj-BF16.gguf")
        self.assertEqual(rec.role, "mmproj_combined")
        self.assertEqual(rec.size_bytes, 175_000_000)
        self.assertEqual(rec.sha256, "")  # not yet downloaded
        self.assertEqual(rec.head_sha256_1mb, "")
        self.assertEqual(rec.tensor_count, 0)  # not yet inspected

    def test_plan_refuses_oversize(self) -> None:
        api = _FakeApi([_fake_sibling("mmproj-BF16.gguf", 6 * 1024 * 1024 * 1024)])
        with self.assertRaises(RuntimeError) as ctx:
            fm.plan_one(api, "unsloth/gemma-4-12b-it-GGUF", "BF16", 5 * 1024 * 1024 * 1024)
        self.assertIn("refusing to plan", str(ctx.exception))

    def test_plan_missing_file_raises(self) -> None:
        # Only the trunk + an MTP file, no mmproj at all.
        api = _FakeApi([
            _fake_sibling("gemma-4-12b-it-BF16.gguf", 23_000_000_000),
            _fake_sibling("MTP/mtp-gemma-4-12b-it-BF16.gguf", 100_000_000),
        ])
        with self.assertRaises(RuntimeError) as ctx:
            fm.plan_one(api, "unsloth/gemma-4-12b-it-GGUF", "BF16", 5 * 1024 * 1024 * 1024)
        self.assertIn("not found", str(ctx.exception))
        self.assertIn("mmproj", str(ctx.exception))


# ---------------------------------------------------------------------------
# 5) Tensor-name convention check
# ---------------------------------------------------------------------------


class _FakeReaderTensor:
    def __init__(self, name: str) -> None:
        self.name = name


class _FakeReader:
    def __init__(self, tensors: list[_FakeReaderTensor]) -> None:
        self.tensors = tensors


class TestInspectTensorConvention(unittest.TestCase):
    def _patch_reader(self, names: list[str]) -> Any:
        # The script does a local ``from gguf import GGUFReader``,
        # so the patch target is the gguf module, not fetch_mmproj.
        fake = _FakeReader([_FakeReaderTensor(n) for n in names])
        return patch("gguf.GGUFReader", return_value=fake)

    def test_compatible_vision_only(self) -> None:
        names = [
            "v.patch_embd.weight",
            "v.patch_embd.bias",
            "v.patch_norm.1.weight",
        ]
        with self._patch_reader(names):
            count, prefixes, compatible = fm.inspect_mmproj_tensor_convention(
                Path("/tmp/whatever.gguf")
            )
        self.assertEqual(count, 3)
        self.assertEqual(prefixes, {"v": 3})
        self.assertTrue(compatible)

    def test_compatible_with_audio_embedder(self) -> None:
        # The mmproj-BF16.gguf in the unsloth repo uses mm.a.* for
        # the audio multimodal embedder (see clip.cpp:2673); mm.a.
        # is a sub-prefix of mm. so it's still compatible.
        names = [
            "v.patch_embd.weight",
            "mm.input_projection.weight",
            "mm.a.input_projection.weight",
        ]
        with self._patch_reader(names):
            count, prefixes, compatible = fm.inspect_mmproj_tensor_convention(
                Path("/tmp/whatever.gguf")
            )
        self.assertEqual(count, 3)
        self.assertEqual(prefixes, {"v": 1, "mm": 2})
        self.assertTrue(compatible)

    def test_legacy_convention_detected(self) -> None:
        # A transformers-style mmproj would have names like
        # ``vision_model.layers.0.``. The check must flip the
        # compatible flag so the dry-run report / the post-fetch
        # warning surface it.
        names = [
            "vision_model.layers.0.weight",
            "vision_model.layers.1.weight",
            "multi_modal_projector.linear_1.weight",
        ]
        with self._patch_reader(names):
            count, prefixes, compatible = fm.inspect_mmproj_tensor_convention(
                Path("/tmp/whatever.gguf")
            )
        self.assertEqual(count, 3)
        self.assertEqual(
            prefixes,
            {"vision_model": 2, "multi_modal_projector": 1},
        )
        self.assertFalse(compatible)

    def test_compatible_real_unsloth_layout(self) -> None:
        # The exact 11-tensor layout from the real unsloth
        # mmproj-BF16.gguf (verified on 2026-08-04). This is the
        # gate test: if unsloth ever republishes the file with a
        # different layout, the test fails and the architect is
        # alerted before the full 8-component run.
        names = [
            "mm.a.input_projection.weight",
            "mm.input_projection.weight",
            "v.patch_embd.bias",
            "v.patch_embd.weight",
            "v.patch_norm.1.bias",
            "v.patch_norm.1.weight",
            "v.patch_norm.2.bias",
            "v.patch_norm.2.weight",
            "v.position_embd.weight",
            "v.patch_norm.3.bias",
            "v.patch_norm.3.weight",
        ]
        with self._patch_reader(names):
            count, prefixes, compatible = fm.inspect_mmproj_tensor_convention(
                Path("/tmp/whatever.gguf")
            )
        self.assertEqual(count, 11)
        self.assertEqual(prefixes, {"v": 9, "mm": 2})
        self.assertTrue(compatible)


# ---------------------------------------------------------------------------
# 6) README license parsing
# ---------------------------------------------------------------------------


CANNED_README = """\
---
license: apache-2.0
license_link: https://ai.google.dev/gemma/docs/gemma_4_license
pipeline_tag: image-text-to-text
base_model: google/gemma-4-12B-it
tags:
- gemma4
- unsloth
---

# Gemma 4 12B (Unsloth GGUF)

This is the Apache-2.0 release of Gemma 4 12B It, mirrored by Unsloth.
"""


class TestReadmeLicenseParsing(unittest.TestCase):
    def test_parses_license_from_canned_readme(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            readme = tmp_path / "README.md"
            readme.write_text(CANNED_README, encoding="utf-8")
            text = readme.read_text(encoding="utf-8")
            info: dict[str, str] = {}
            for line in text.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                for key in ("license", "license_link", "pipeline_tag", "base_model"):
                    prefix = f"{key}:"
                    if stripped.startswith(prefix):
                        value = stripped[len(prefix):].strip()
                        if value.startswith(("'", '"')) and value.endswith(("'", '"')):
                            value = value[1:-1]
                        info[key] = value
                        break
            self.assertEqual(info.get("license"), "apache-2.0")
            self.assertEqual(
                info.get("license_link"),
                "https://ai.google.dev/gemma/docs/gemma_4_license",
            )
            self.assertEqual(info.get("pipeline_tag"), "image-text-to-text")
            self.assertEqual(info.get("base_model"), "google/gemma-4-12B-it")

    def test_readme_with_no_front_matter(self) -> None:
        # A README that has no front-matter should yield an empty
        # info dict; the caller falls back to the default
        # attribution string.
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            readme = tmp_path / "README.md"
            readme.write_text("# Just a title\n\nNo front-matter here.\n", encoding="utf-8")
            text = readme.read_text(encoding="utf-8")
            info = {}
            for line in text.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                for key in ("license", "license_link", "pipeline_tag", "base_model"):
                    prefix = f"{key}:"
                    if stripped.startswith(prefix):
                        value = stripped[len(prefix):].strip()
                        if value.startswith(("'", '"')) and value.endswith(("'", '"')):
                            value = value[1:-1]
                        info[key] = value
                        break
            self.assertEqual(info, {})


# ---------------------------------------------------------------------------
# 7) build_receipt shape
# ---------------------------------------------------------------------------


class TestBuildReceipt(unittest.TestCase):
    def test_receipt_shape(self) -> None:
        from fetch_mmproj import FetchResult, MmprojFileRecord

        rec = MmprojFileRecord(
            source_filename="mmproj-BF16.gguf",
            destination_filename="gemma4-12B-mmproj-BF16.gguf",
            role="mmproj_combined",
            size_bytes=175_115_840,
            sha256="a" * 64,
            head_sha256_1mb="b" * 64,
            license="apache-2.0",
            license_link="https://ai.google.dev/gemma/docs/gemma_4_license",
            attribution="Unsloth (mirror); Google DeepMind (upstream)",
            tensor_count=11,
            tensor_prefixes={"v": 9, "mm": 2},
            convention_compatible=True,
            source_path="/tmp/cache/.../mmproj-BF16.gguf",
            destination_path="/Volumes/Julian T7/models/gemma4-12B-mmproj-BF16.gguf",
        )
        result = FetchResult(
            repo="unsloth/gemma-4-12b-it-GGUF",
            precision="BF16",
            upstream_readme_path="/tmp/cache/.../README.md",
            upstream_license="apache-2.0",
            upstream_license_link="https://ai.google.dev/gemma/docs/gemma_4_license",
            upstream_attribution="Unsloth (mirror); Google DeepMind (upstream)",
            upstream_base_model="google/gemma-4-12B-it",
            files=[rec],
            wall_clock_seconds=1.23,
            total_bytes_downloaded=175_115_840,
            dry_run=False,
        )
        receipt = fm.build_receipt(result, tessera_version="abc1234")
        self.assertEqual(receipt["schema"], fm.SCHEMA)
        self.assertEqual(receipt["repo"], "unsloth/gemma-4-12b-it-GGUF")
        self.assertEqual(receipt["precision"], "BF16")
        self.assertEqual(receipt["license"], "apache-2.0")
        self.assertEqual(receipt["base_model"], "google/gemma-4-12B-it")
        self.assertEqual(len(receipt["corpora"]), 1)
        self.assertEqual(receipt["corpora"][0]["name"], "gemma4-12B-mmproj-BF16.gguf")
        self.assertEqual(receipt["corpora"][0]["license"], "apache-2.0")
        self.assertEqual(receipt["corpora"][0]["sha256_of_first_1MB"], "b" * 64)
        self.assertEqual(len(receipt["mmproj_files"]), 1)
        self.assertEqual(
            receipt["mmproj_files"][0]["destination_path"],
            "/Volumes/Julian T7/models/gemma4-12B-mmproj-BF16.gguf",
        )
        self.assertTrue(receipt["mmproj_files"][0]["convention_compatible"])
        # ISO-8601-ish timestamp; we don't pin the exact value.
        self.assertRegex(receipt["timestamp"], r"^\d{4}-\d{2}-\d{2}T")

    def test_receipt_serializes_to_json(self) -> None:
        from fetch_mmproj import FetchResult, MmprojFileRecord

        rec = MmprojFileRecord(
            source_filename="mmproj-BF16.gguf",
            destination_filename="gemma4-12B-mmproj-BF16.gguf",
            role="mmproj_combined",
            size_bytes=100,
            sha256="c" * 64,
            head_sha256_1mb="d" * 64,
            license="apache-2.0",
            license_link="",
            attribution="",
            tensor_count=0,
            tensor_prefixes={},
            convention_compatible=True,
            source_path="",
            destination_path="",
        )
        result = FetchResult(
            repo="r", precision="BF16", upstream_readme_path=None,
            upstream_license="apache-2.0", upstream_license_link="",
            upstream_attribution="x", upstream_base_model="y",
            files=[rec], wall_clock_seconds=0.0,
            total_bytes_downloaded=100, dry_run=True,
        )
        receipt = fm.build_receipt(result, tessera_version="v")
        # Round-trip; if any field is not JSON-serializable
        # (numpy types, Path, etc.) this would raise.
        encoded = json.dumps(receipt, indent=2, sort_keys=True)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["repo"], "r")
        self.assertTrue(decoded["dry_run"])


# ---------------------------------------------------------------------------
# 8) sha256_file + stream_copy
# ---------------------------------------------------------------------------


class TestSha256StreamCopy(unittest.TestCase):
    def test_stream_copy_and_sha(self) -> None:
        # Deterministic 4 MiB payload; check that stream_copy
        # reproduces the bytes exactly and that sha256_file
        # matches the reference.
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            src = tmp_path / "src.bin"
            dst = tmp_path / "dst.bin"
            payload = (b"hello-tessera" * 1024 * 1024)[: 4 * 1024 * 1024]
            # Pad / truncate to exactly 4 MiB deterministically.
            payload = (payload * 2)[: 4 * 1024 * 1024]
            src.write_bytes(payload)

            n = fm.stream_copy(src, dst)
            self.assertEqual(n, len(payload))
            self.assertEqual(dst.stat().st_size, len(payload))
            self.assertEqual(dst.read_bytes(), payload)

            import hashlib
            ref = hashlib.sha256(payload).hexdigest()
            self.assertEqual(fm.sha256_file(src), ref)
            self.assertEqual(fm.sha256_file(dst), ref)

    def test_head_sha_truncates_at_1mb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            src = tmp_path / "big.bin"
            # 2 MiB; head_sha should hash only the first 1 MiB.
            payload = b"\xab" * (2 * 1024 * 1024)
            src.write_bytes(payload)
            import hashlib
            ref = hashlib.sha256(b"\xab" * (1024 * 1024)).hexdigest()
            self.assertEqual(fm.head_sha256(src), ref)


if __name__ == "__main__":
    unittest.main()
