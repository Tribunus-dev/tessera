#!/usr/bin/env python3
"""End-to-end tests for ``conversion/qwen3tts_vocoder.py``.

The c2w converter is a one-way HF -> GGUF transform; we test it in two
complementary ways:

1. **Synthetic safetensors** (default). We build a tiny decoder config
   (4 codebooks, 2 transformer layers, narrow dims) and a matching
   model.safetensors with deterministic values. The converter runs
   end-to-end against the synthetic bundle and the produced GGUF is
   re-read with the gguf-py reader to verify arch, metadata, tensor
   inventory, shapes, and the snake / codebook / output-conv
   derivations are exactly what the C++ side expects.

2. **Real HF weights** (gated by a marker). When the
   ``TESSERA_VOCODER_HF`` environment variable points at the real
   ``/Volumes/Julian T7/models/qwen3-tts-model/speech_tokenizer`` HF
   directory, the same harness runs the converter against the real
   682 MB safetensors. This is the parity check: 16 codebooks, 8
   transformer layers, 4 decoder blocks, full conv stack.

   pytest marker: ``pytest -m "real_weights"`` runs this path; the
   default pytest invocation skips it. The verify tool
   (tools/tessera/verify_qwen3tts_gguf.py) is the canonical place for
   full byte-parity coverage against the real weights; this test
   just confirms the converter does not regress on the full inventory.

Run as::

    python3 tools/tessera/test_vocoder_converter.py
    pytest -m "real_weights" tools/tessera/test_vocoder_converter.py
"""
from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

import numpy as np

THIS_DIR = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent.parent
GGUF_PY = REPO_ROOT / "gguf-py"
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(GGUF_PY))

# mirror the W2 talker test convention: standalone script + unittest.
# the harness deliberately does NOT depend on pytest fixtures.

# The GGUF writer needs torch (LazyTorchTensor, quantize, etc.) and
# safetensors (write/read of synthetic bundles).
import torch  # noqa: E402

# Test constants for the synthetic bundle. The shapes here are not
# the real V2 decoder (we do not want a 400MB test artifact); they
# keep the same topology (codebooks, transformer, conv blocks,
# snake) at minimum sizes that still exercise every converter code
# path. The C++ side does not get loaded by this test - the GGUF
# reader re-imports it through the same converter's tensor name map.
SYN_VOCAB = 8
SYN_CODEBOOK_DIM = 16       # vq_dim (per_codebook_dim in the V2 source)
SYN_CODEBOOK_SIZE = 8       # 8 entries per codebook
SYN_N_QUANTIZERS = 4
SYN_HIDDEN_SIZE = 32        # n_embd for the pre-transformer
SYN_INTERMEDIATE_SIZE = 64  # n_ff
SYN_NUM_HEADS = 4
SYN_HEAD_DIM = 8
SYN_NUM_LAYERS = 2
SYN_LATENT_DIM = 64
SYN_DECODER_DIM = 96
SYN_UPSAMPLE_RATES = [4, 2]
SYN_UPSAMPLING_RATIOS = [2]
SYN_SLIDING_WINDOW = 4
SYN_RMS_NORM_EPS = 1e-5
SYN_OUTPUT_SAMPLE_RATE = 24000
SYN_INPUT_SAMPLE_RATE = 24000
SYN_DECODE_UPSAMPLE_RATE = (
    SYN_UPSAMPLE_RATES[0] * SYN_UPSAMPLE_RATES[1] * SYN_UPSAMPLING_RATIOS[0])

# tests skip themselves if torch's safetensors binding is missing.
try:
    from safetensors.torch import save_file as _save_st  # noqa: E402
    from safetensors import safe_open as _safe_open  # noqa: E402
    HAVE_SAFETENSORS = True
except ImportError:
    HAVE_SAFETENSORS = False


def _build_synthetic_decoder_config() -> dict:
    # mirrors the shape of the real Qwen3TTSTokenizerV2Config; the
    # converter only reads the decoder_config subtree, so we omit the
    # encoder/architectures noise.
    return {
        "architectures": ["Qwen3TTSTokenizerV2Model"],
        "model_type": "qwen3_tts_tokenizer_12hz",
        "decoder_config": {
            "hidden_act": "silu",
            "hidden_size": SYN_HIDDEN_SIZE,
            "intermediate_size": SYN_INTERMEDIATE_SIZE,
            "num_attention_heads": SYN_NUM_HEADS,
            "num_key_value_heads": SYN_NUM_HEADS,
            "num_hidden_layers": SYN_NUM_LAYERS,
            "head_dim": SYN_HEAD_DIM,
            "max_position_embeddings": 32,
            "rms_norm_eps": SYN_RMS_NORM_EPS,
            "rope_theta": 10000,
            "sliding_window": SYN_SLIDING_WINDOW,
            "codebook_size": SYN_CODEBOOK_SIZE,
            "codebook_dim": SYN_CODEBOOK_DIM * 2,  # HF stores as 2x vq_dim
            "vector_quantization_hidden_dimension": SYN_CODEBOOK_DIM * 2,
            "latent_dim": SYN_LATENT_DIM,
            "decoder_dim": SYN_DECODER_DIM,
            "num_quantizers": SYN_N_QUANTIZERS,
            "num_semantic_quantizers": 1,
            "upsample_rates": SYN_UPSAMPLE_RATES,
            "upsampling_ratios": SYN_UPSAMPLING_RATIOS,
        },
        "encoder_config": {
            "hidden_size": SYN_HIDDEN_SIZE,
            "intermediate_size": SYN_INTERMEDIATE_SIZE,
            "num_attention_heads": SYN_NUM_HEADS,
            "num_hidden_layers": SYN_NUM_LAYERS,
            "head_dim": SYN_HEAD_DIM,
            "sliding_window": 8,
            "codebook_size": SYN_CODEBOOK_SIZE,
            "codebook_dim": SYN_CODEBOOK_DIM,
            "upsampling_ratios": [2, 2],
        },
        "input_sample_rate": SYN_INPUT_SAMPLE_RATE,
        "output_sample_rate": SYN_OUTPUT_SAMPLE_RATE,
        "encode_downsample_rate": SYN_DECODE_UPSAMPLE_RATE,
        "decode_upsample_rate": SYN_DECODE_UPSAMPLE_RATE,
        "encoder_valid_num_quantizers": SYN_N_QUANTIZERS,
    }


def _build_synthetic_state_dict(seed: int = 0) -> dict:
    """Build a state_dict with the exact HF tensor names + shapes the
    converter consumes. The values are deterministic (torch.manual_seed
    so byte-parity is exact across runs).

    Returns a dict of name -> torch.Tensor (F32). The encoder subtree
    and the VQ input_proj / cluster_usage / initialized are
    intentionally included so the converter's filter_tensors has to
    drop them; the round-trip parity checks then assert they are
    NOT in the output GGUF.
    """
    g = torch.Generator().manual_seed(seed)

    def rand(*shape):
        return torch.randn(*shape, generator=g, dtype=torch.float32)

    def zeros(*shape):
        return torch.zeros(*shape, dtype=torch.float32)

    def ones(*shape):
        return torch.ones(*shape, dtype=torch.float32)

    sd: dict = {}

    # ---- pre-transformer (n_layer x) ----
    sd["decoder.pre_transformer.input_proj.weight"] = rand(
        SYN_HIDDEN_SIZE, SYN_LATENT_DIM)
    sd["decoder.pre_transformer.input_proj.bias"] = zeros(SYN_HIDDEN_SIZE)
    sd["decoder.pre_transformer.norm.weight"] = ones(SYN_HIDDEN_SIZE)
    sd["decoder.pre_transformer.output_proj.weight"] = rand(
        SYN_LATENT_DIM, SYN_HIDDEN_SIZE)
    sd["decoder.pre_transformer.output_proj.bias"] = zeros(SYN_LATENT_DIM)
    for i in range(SYN_NUM_LAYERS):
        p = f"decoder.pre_transformer.layers.{i}"
        sd[f"{p}.input_layernorm.weight"] = ones(SYN_HIDDEN_SIZE)
        sd[f"{p}.post_attention_layernorm.weight"] = ones(SYN_HIDDEN_SIZE)
        sd[f"{p}.self_attn_layer_scale.scale"] = ones(SYN_HIDDEN_SIZE)
        sd[f"{p}.mlp_layer_scale.scale"] = ones(SYN_HIDDEN_SIZE)
        sd[f"{p}.self_attn.q_proj.weight"] = rand(
            SYN_HIDDEN_SIZE, SYN_HIDDEN_SIZE)
        sd[f"{p}.self_attn.k_proj.weight"] = rand(
            SYN_HIDDEN_SIZE, SYN_HIDDEN_SIZE)
        sd[f"{p}.self_attn.v_proj.weight"] = rand(
            SYN_HIDDEN_SIZE, SYN_HIDDEN_SIZE)
        sd[f"{p}.self_attn.o_proj.weight"] = rand(
            SYN_HIDDEN_SIZE, SYN_HIDDEN_SIZE)
        sd[f"{p}.mlp.gate_proj.weight"] = rand(
            SYN_INTERMEDIATE_SIZE, SYN_HIDDEN_SIZE)
        sd[f"{p}.mlp.up_proj.weight"] = rand(
            SYN_INTERMEDIATE_SIZE, SYN_HIDDEN_SIZE)
        sd[f"{p}.mlp.down_proj.weight"] = rand(
            SYN_HIDDEN_SIZE, SYN_INTERMEDIATE_SIZE)

    # ---- pre_conv (Conv1d in=codebook_dim, out=latent_dim, k=3) ----
    sd["decoder.pre_conv.conv.weight"] = rand(
        SYN_LATENT_DIM, SYN_CODEBOOK_DIM * 2, 3)
    sd["decoder.pre_conv.conv.bias"] = zeros(SYN_LATENT_DIM)

    # ---- quantizer: rvq_first (1 layer) + rvq_rest (n_quantizers-1) ----
    for cid in [0]:
        p = f"decoder.quantizer.rvq_first.vq.layers.{cid}._codebook"
        sd[f"{p}.embedding_sum"] = rand(SYN_CODEBOOK_SIZE, SYN_CODEBOOK_DIM)
        sd[f"{p}.cluster_usage"] = ones(SYN_CODEBOOK_SIZE)
        sd[f"{p}.initialized"] = ones(1)
        # C++ does not load input_proj; the converter must drop it.
        sd["decoder.quantizer.rvq_first.input_proj.weight"] = rand(
            SYN_CODEBOOK_DIM, SYN_CODEBOOK_DIM * 2, 1)
        sd["decoder.quantizer.rvq_first.output_proj.weight"] = rand(
            SYN_CODEBOOK_DIM * 2, SYN_CODEBOOK_DIM, 1)
    for cid in range(SYN_N_QUANTIZERS - 1):
        p = f"decoder.quantizer.rvq_rest.vq.layers.{cid}._codebook"
        sd[f"{p}.embedding_sum"] = rand(SYN_CODEBOOK_SIZE, SYN_CODEBOOK_DIM)
        sd[f"{p}.cluster_usage"] = ones(SYN_CODEBOOK_SIZE)
        sd[f"{p}.initialized"] = ones(1)
        sd["decoder.quantizer.rvq_rest.input_proj.weight"] = rand(
            SYN_CODEBOOK_DIM, SYN_CODEBOOK_DIM * 2, 1)
        sd["decoder.quantizer.rvq_rest.output_proj.weight"] = rand(
            SYN_CODEBOOK_DIM * 2, SYN_CODEBOOK_DIM, 1)

    # ---- upsample stages (2 stages, each = transconv + convnext block) ----
    for s in range(len(SYN_UPSAMPLING_RATIOS)):
        p = f"decoder.upsample.{s}.0"
        sd[f"{p}.conv.weight"] = rand(SYN_LATENT_DIM, SYN_LATENT_DIM, 2)
        sd[f"{p}.conv.bias"] = zeros(SYN_LATENT_DIM)
        # convnext block: dwconv (depthwise) + norm + pw1 + pw2 + gamma
        q = f"decoder.upsample.{s}.1"
        sd[f"{q}.dwconv.conv.weight"] = rand(SYN_LATENT_DIM, 1, 7)
        sd[f"{q}.dwconv.conv.bias"] = zeros(SYN_LATENT_DIM)
        sd[f"{q}.norm.weight"] = ones(SYN_LATENT_DIM)
        sd[f"{q}.norm.bias"] = zeros(SYN_LATENT_DIM)
        sd[f"{q}.pwconv1.weight"] = rand(SYN_LATENT_DIM * 4, SYN_LATENT_DIM)
        sd[f"{q}.pwconv1.bias"] = zeros(SYN_LATENT_DIM * 4)
        sd[f"{q}.pwconv2.weight"] = rand(SYN_LATENT_DIM, SYN_LATENT_DIM * 4)
        sd[f"{q}.pwconv2.bias"] = zeros(SYN_LATENT_DIM)
        sd[f"{q}.gamma"] = ones(SYN_LATENT_DIM)

    # ---- decoder.0 (stem conv) ----
    sd["decoder.decoder.0.conv.weight"] = rand(
        SYN_DECODER_DIM, SYN_LATENT_DIM, 7)
    sd["decoder.decoder.0.conv.bias"] = zeros(SYN_DECODER_DIM)

    # ---- decoder.{1..n_blk} (block snake + transconv + 3 res units) ----
    n_blk = len(SYN_UPSAMPLE_RATES)
    for b in range(1, n_blk + 1):
        c_in = SYN_DECODER_DIM >> (b - 1)
        c_out = SYN_DECODER_DIM >> b
        p = f"decoder.decoder.{b}"
        # block-level snake
        sd[f"{p}.block.0.alpha"] = rand(c_in)
        sd[f"{p}.block.0.beta"] = rand(c_in)
        # transconv (ConvTranspose1d in=c_in, out=c_out, k=2*rate)
        rate = SYN_UPSAMPLE_RATES[b - 1]
        sd[f"{p}.block.1.conv.weight"] = rand(c_in, c_out, 2 * rate)
        sd[f"{p}.block.1.conv.bias"] = zeros(c_out)
        # 3 residual units, each: act1 (a,b), conv1 (w,b), act2 (a,b), conv2 (w,b)
        for u in range(3):
            q = f"{p}.block.{u + 2}"
            sd[f"{q}.act1.alpha"] = rand(c_out)
            sd[f"{q}.act1.beta"] = rand(c_out)
            sd[f"{q}.conv1.conv.weight"] = rand(c_out, c_out, 7)
            sd[f"{q}.conv1.conv.bias"] = zeros(c_out)
            sd[f"{q}.act2.alpha"] = rand(c_out)
            sd[f"{q}.act2.beta"] = rand(c_out)
            sd[f"{q}.conv2.conv.weight"] = rand(c_out, c_out, 1)
            sd[f"{q}.conv2.conv.bias"] = zeros(c_out)

    # ---- final snake + output conv (decoder.{n_blk+1} + decoder.{n_blk+2}) ----
    c_last = SYN_DECODER_DIM >> n_blk
    sd[f"decoder.decoder.{n_blk + 1}.alpha"] = rand(c_last)
    sd[f"decoder.decoder.{n_blk + 1}.beta"] = rand(c_last)
    sd[f"decoder.decoder.{n_blk + 2}.conv.weight"] = rand(1, c_last, 7)
    sd[f"decoder.decoder.{n_blk + 2}.conv.bias"] = zeros(1)

    # ---- encoder subtree: must be dropped entirely ----
    sd["encoder.pre_conv.conv.weight"] = rand(
        SYN_LATENT_DIM, SYN_CODEBOOK_DIM, 3)
    sd["encoder.encoder_transformer.layers.0.self_attn.q_proj.weight"] = rand(
        SYN_HIDDEN_SIZE, SYN_HIDDEN_SIZE)
    sd["encoder.quantizer.semantic_residual_vector_quantizer.layers.0._codebook.embed_sum"] = \
        rand(SYN_CODEBOOK_SIZE, SYN_CODEBOOK_DIM)

    return sd


@contextmanager
def _tempdir():
    with tempfile.TemporaryDirectory() as d:
        yield Path(d)


def _write_synthetic_hf(dir_: Path, seed: int = 0) -> Path:
    dir_.mkdir(parents=True, exist_ok=True)
    cfg = _build_synthetic_decoder_config()
    (dir_ / "config.json").write_text(json.dumps(cfg, indent=2))
    sd = _build_synthetic_state_dict(seed=seed)
    _save_st(sd, str(dir_ / "model.safetensors"))
    return dir_


def _read_gguf(path: Path):
    from gguf import GGUFReader
    return GGUFReader(str(path), "r")


def _gguf_field(reader, key):
    f = reader.fields.get(key)
    if f is None:
        return None
    if len(f.data) == 1:
        return f.parts[f.data[0]][0]
    parts = [f.parts[i] for i in f.data]
    if parts and parts[0].dtype == np.uint8:
        try:
            return [p.tobytes().decode("utf-8") for p in parts]
        except UnicodeDecodeError:
            pass
    return [p[0] for p in parts]


def _gguf_array(reader, key):
    f = reader.fields.get(key)
    if f is None or len(f.data) == 0:
        return None
    return [int.from_bytes(f.parts[i].tobytes(), "little") for i in f.data]


def _run_converter(hf_dir: Path, out_gguf: Path) -> None:
    """Run the converter via the script's __main__ entry point so the
    sys.path setup that lets `python3 conversion/qwen3tts_vocoder.py`
    import from the parent pkg is exercised. This is the same path
    the gate command runs."""
    import subprocess
    cmd = [
        sys.executable,
        str(REPO_ROOT / "conversion" / "qwen3tts_vocoder.py"),
        "--vocoder-hf", str(hf_dir),
        "--vocoder-out", str(out_gguf),
        "--outtype", "f32",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise AssertionError(
            f"converter failed (rc={r.returncode})\nstdout:\n{r.stdout}\n"
            f"stderr:\n{r.stderr}")


# ---------------------------------------------------------------------------
# test cases
# ---------------------------------------------------------------------------


@unittest.skipUnless(HAVE_SAFETENSORS, "safetensors not installed")
class TestSyntheticRoundTrip(unittest.TestCase):
    """End-to-end: synthetic HF -> GGUF -> re-read -> assert."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.hf_dir = self.tmp / "vocoder_hf"
        self.gguf_path = self.tmp / "vocoder.gguf"
        _write_synthetic_hf(self.hf_dir)
        _run_converter(self.hf_dir, self.gguf_path)
        self.reader = _read_gguf(self.gguf_path)
        self.names = {t.name: t for t in self.reader.tensors}

    def test_arch_and_block_count(self) -> None:
        arch = self.reader.fields["general.architecture"].parts[
            self.reader.fields["general.architecture"].data[0]
        ].tobytes().decode()
        self.assertEqual(arch, "qwen3-tts-code2wav")
        self.assertEqual(
            _gguf_field(self.reader, "qwen3-tts-code2wav.block_count"),
            SYN_NUM_LAYERS)
        self.assertEqual(
            _gguf_field(self.reader, "qwen3-tts-code2wav.codebook_count"),
            SYN_N_QUANTIZERS)
        self.assertEqual(
            _gguf_field(self.reader, "qwen3-tts-code2wav.residual_units"), 3)
        self.assertEqual(
            _gguf_field(self.reader, "qwen3-tts-code2wav.sample_rate"),
            SYN_OUTPUT_SAMPLE_RATE)

    def test_hparam_standard_keys(self) -> None:
        # the standard hparam keys the base TextModel writes from the
        # decoder_config fields
        w = self.reader
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.embedding_length"),
            SYN_HIDDEN_SIZE)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.embedding_length_out"),
            SYN_DECODE_UPSAMPLE_RATE // SYN_N_QUANTIZERS)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.feed_forward_length"),
            SYN_INTERMEDIATE_SIZE)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.attention.head_count"),
            SYN_NUM_HEADS)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.attention.head_count_kv"),
            SYN_NUM_HEADS)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.attention.key_length"),
            SYN_HEAD_DIM)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.attention.sliding_window"),
            SYN_SLIDING_WINDOW)
        self.assertAlmostEqual(
            float(_gguf_field(w,
                "qwen3-tts-code2wav.attention.layer_norm_rms_epsilon")),
            SYN_RMS_NORM_EPS, places=10)
        self.assertEqual(
            _gguf_field(w, "qwen3-tts-code2wav.context_length"), 32)

    def test_arch_prefixed_arrays(self) -> None:
        self.assertEqual(
            _gguf_array(self.reader, "qwen3-tts-code2wav.upsample_rates"),
            SYN_UPSAMPLE_RATES)
        self.assertEqual(
            _gguf_array(self.reader, "qwen3-tts-code2wav.upsample_ratios"),
            SYN_UPSAMPLING_RATIOS)
        # hardcoded in the converter (the V2 decoder's 3 res units with
        # the canonical snake dilations; HF config does not expose them)
        self.assertEqual(
            _gguf_array(self.reader, "qwen3-tts-code2wav.residual_dilations"),
            [1, 3, 9])

    def test_placeholder_vocab(self) -> None:
        # the C++ graph reads hparams.n_vocab for the codebook size;
        # the converter writes a 2048-entry placeholder token list so
        # the n_vocab metadata resolves. For the synthetic test, the
        # codebook size is SYN_CODEBOOK_SIZE.
        tokens = _gguf_field(self.reader, "tokenizer.ggml.tokens")
        self.assertIsNotNone(tokens, "placeholder token list missing")
        self.assertEqual(
            len(tokens), SYN_CODEBOOK_SIZE,
            f"placeholder vocab size = {len(tokens)} (want {SYN_CODEBOOK_SIZE})")
        tok_model = self.reader.fields.get("tokenizer.ggml.model")
        if tok_model is not None:
            self.assertEqual(
                tok_model.parts[tok_model.data[0]].tobytes().decode(), "none")

    def test_codebook_uses_embed_sum_over_usage(self) -> None:
        # the HF stores EMA running sum + cluster_usage; the converter
        # bakes the division at convert time. Re-derive the expected
        # codebook and byte-compare against the produced GGUF tensor.
        with _safe_open(str(self.hf_dir / "model.safetensors"),
                        framework="pt") as f:
            emb = f.get_tensor(
                "decoder.quantizer.rvq_first.vq.layers.0._codebook"
                ".embedding_sum").float()
            use = f.get_tensor(
                "decoder.quantizer.rvq_first.vq.layers.0._codebook"
                ".cluster_usage").float()
        want = (emb / use.clamp(min=1e-5).unsqueeze(1)).numpy()
        got = np.ascontiguousarray(
            self.names["c2w.codebook_embd.0.weight"].data
        ).astype(np.float32)
        self.assertEqual(got.shape, tuple(want.shape))
        self.assertTrue(
            bool((got == want).all()),
            "c2w.codebook_embd.0 != embedding_sum / cluster_usage")

    def test_snake_alpha_beta_baking(self) -> None:
        # the C++ graph uses a = exp(alpha_hf) and b = 1/(exp(beta_hf)+1e-9)
        with _safe_open(str(self.hf_dir / "model.safetensors"),
                        framework="pt") as f:
            hf_alpha = f.get_tensor(
                "decoder.decoder.1.block.0.alpha").float()
            hf_beta = f.get_tensor(
                "decoder.decoder.1.block.0.beta").float()
        want_a = hf_alpha.exp().numpy()
        want_b = (1.0 / (hf_beta.exp() + 1e-9)).numpy()
        got_a = np.ascontiguousarray(
            self.names["c2w.block.0.alpha"].data).astype(np.float32)
        got_b = np.ascontiguousarray(
            self.names["c2w.block.0.beta"].data).astype(np.float32)
        self.assertTrue(
            bool((got_a == want_a).all()),
            "c2w.block.0.alpha != exp(hf_alpha)")
        self.assertTrue(
            bool((got_b == want_b).all()),
            "c2w.block.0.beta != 1/(exp(hf_beta)+1e-9)")

    def test_filtered_tensors_absent(self) -> None:
        # the filter drops: encoder.*, VQ input_proj (the pre_transformer
        # input_proj IS kept and renamed to c2w.tf.input_proj.*), the
        # codebook bookkeeping (cluster_usage, initialized; embed_sum is
        # consumed into the c2w.codebook_embd tables so it must NOT
        # appear as a raw c2w tensor).
        bad = [n for n in self.names
               if n.startswith("decoder.quantizer.") and "input_proj" in n]
        self.assertEqual(
            bad, [],
            f"unexpected VQ input_proj in gguf: {bad}")
        bad = [n for n in self.names if "cluster_usage" in n]
        self.assertEqual(bad, [], f"unexpected cluster_usage: {bad}")
        bad = [n for n in self.names if "encoder." in n]
        self.assertEqual(bad, [], f"unexpected encoder.*: {bad}")
        bad = [n for n in self.names if "embed_sum" in n or "_codebook" in n]
        self.assertEqual(bad, [], f"unexpected _codebook: {bad}")
        # c2w.tf.input_proj.* is the pre-transformer input projection and
        # SHOULD be present; sanity-check the name does NOT collide with
        # the VQ input_proj.
        self.assertIn("c2w.tf.input_proj.weight", self.names)
        self.assertIn("c2w.tf.input_proj.bias", self.names)

    def test_tensor_inventory_size(self) -> None:
        # 16-codebook real model = 253 tensors. The synthetic model
        # has SYN_N_QUANTIZERS codebooks so the count is smaller.
        n = len(self.names)
        # quick sanity bounds: n >= 16 codebook + 1 vq_first + 1
        # vq_rest + 2 pre_conv + 2 stem + 2 output + 2 per layer * 8
        # layers * 11 + per-block tensors + 2 upsample * 11.
        # We only assert the count is > the c2w minimum (we are
        # permissive on the exact number; the real-weights verify
        # tool pins the exact 253 for the production config).
        self.assertGreater(n, 50, f"suspiciously few tensors: {n}")
        # every codebook present
        for cid in range(SYN_N_QUANTIZERS):
            self.assertIn(
                f"c2w.codebook_embd.{cid}.weight", self.names,
                f"missing codebook {cid}")

    def test_block_index_range_and_residual_count(self) -> None:
        # blocks 0..n_blk-1 (n_blk = len(upsample_rates))
        import re
        blocks = sorted({
            int(m.group(1))
            for t in self.names
            for m in [re.match(r"^c2w\.block\.(\d+)\.", t)]
            if m})
        self.assertEqual(
            blocks, list(range(len(SYN_UPSAMPLE_RATES))),
            f"c2w block indices {blocks} != {list(range(len(SYN_UPSAMPLE_RATES)))}")
        # 3 residual units per block
        res_units = sorted({
            int(m.group(1))
            for t in self.names
            for m in [re.match(r"^c2w\.block\.\d+\.res\.(\d+)\.", t)]
            if m})
        self.assertEqual(res_units, [0, 1, 2], f"res unit indices: {res_units}")
        # 2 upsample stages (one per upsampling_ratios entry)
        ups = sorted({
            int(m.group(1))
            for t in self.names
            for m in [re.match(r"^c2w\.upsample\.(\d+)\.", t)]
            if m})
        self.assertEqual(ups, list(range(len(SYN_UPSAMPLING_RATIOS))))

    def test_pre_transformer_round_trip(self) -> None:
        # one of the per-layer linear weights: HF (in, out) -> gguf
        # (out, in). The reversal is the GGUF writer's shape-inversion
        # at write time, not a converter-side transpose; this test
        # asserts the byte buffer is the raw numpy bytes (no copy).
        with _safe_open(str(self.hf_dir / "model.safetensors"),
                        framework="pt") as f:
            hf = f.get_tensor(
                "decoder.pre_transformer.layers.0.self_attn.q_proj.weight"
            ).float().numpy()
        got = np.ascontiguousarray(
            self.names["c2w.tf.layers.0.wq"].data).astype(np.float32)
        # HF (in, out) and gguf ne=(out, in); the writer reverses the
        # numpy shape on write, so the numpy buffer matches the HF
        # buffer exactly (gguf column-major <-> numpy row-major).
        self.assertEqual(got.shape, hf.shape,
                         f"shape {got.shape} != hf {hf.shape}")
        self.assertTrue(bool((got == hf).all()))

    def test_output_conv_permute(self) -> None:
        # the W3 C++ create_tensor has the in/out dims swapped for the
        # output conv (a known bug; see report). The converter
        # band-aids this by permuting the HF (1, c_last, 7) weight so
        # the on-disk GGUF ne=(7, 1, c_last) matches the C++ side.
        with _safe_open(str(self.hf_dir / "model.safetensors"),
                        framework="pt") as f:
            n_blk = len(SYN_UPSAMPLE_RATES)
            hf = f.get_tensor(
                f"decoder.decoder.{n_blk + 2}.conv.weight").float()
        want = hf.permute(1, 0, 2).contiguous().numpy()
        got = np.ascontiguousarray(
            self.names["c2w.output.weight"].data).astype(np.float32)
        self.assertEqual(got.shape, want.shape,
                         f"permute shape {got.shape} != {want.shape}")
        self.assertTrue(bool((got == want).all()))


@unittest.skipUnless(
    os.environ.get("TESSERA_VOCODER_HF"),
    "set TESSERA_VOCODER_HF to the real HF directory to run this",
)
class TestRealWeights(unittest.TestCase):
    """Parity check against the real 682MB HF safetensors. Gated by
    TESSERA_VOCODER_HF so the test is opt-in (CI does not have the
    weights). The verify tool (tools/tessera/verify_qwen3tts_gguf.py)
    does the full byte-parity sweep; this is a smoke test for the
    converter on the real inventory.
    """

    def test_real_weights_convert(self) -> None:
        hf = Path(os.environ["TESSERA_VOCODER_HF"])
        with _tempdir() as d:
            out = d / "real.gguf"
            _run_converter(hf, out)
            r = _read_gguf(out)
            arch = r.fields["general.architecture"].parts[
                r.fields["general.architecture"].data[0]
            ].tobytes().decode()
            self.assertEqual(arch, "qwen3-tts-code2wav")
            self.assertEqual(
                _gguf_field(r, "qwen3-tts-code2wav.codebook_count"), 16)
            self.assertEqual(
                _gguf_field(r, "qwen3-tts-code2wav.residual_units"), 3)
            self.assertEqual(
                _gguf_field(r, "qwen3-tts-code2wav.embedding_length_out"),
                120)
            names = {t.name for t in r.tensors}
            self.assertEqual(
                len([n for n in names if n.startswith("c2w.codebook_embd.")]),
                16)
            self.assertEqual(
                len([n for n in names if n.startswith("c2w.tf.layers.")]),
                8 * 11)  # 8 layers * 11 tensors
            self.assertIn("c2w.output.weight", names)


if __name__ == "__main__":
    unittest.main(verbosity=2)
