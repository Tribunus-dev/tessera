#!/usr/bin/env python3
"""Verify a qwen3-tts GGUF (talker or vocoder) against its safetensors source.

Auto-detects the arch from the GGUF header and branches checks:
  - qwen3-tts-talker   : 28 backbone + 5 predictor layers, codec vocab,
                         BPE merges, byte-parity on a spread of tensors
                         (mirrors the W2 talker pattern)
  - qwen3-tts-code2wav : 16 codebook tables + 8 transformer layers + 4
                         decoder blocks, snake alpha/beta baking,
                         codebook = embed_sum / cluster_usage,
                         output conv permuted to match the C++ GGUF shape

usage:
  python3 verify_qwen3tts_gguf.py <gguf> <safetensors>
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, "gguf-py")

import torch  # noqa: E402
from gguf import GGMLQuantizationType, GGUFReader  # noqa: E402

failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def get_field(reader: GGUFReader, key: str):
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


def _open_safetensors(path: str):
    # we want to support both real .safetensors files (HF) and synthetic
    # ones produced by the test harness; the latter are written by
    # safetensors.torch.save_file, the former may be sharded. for the
    # W2 talker + W5c vocoder the only shard path is single-file, so a
    # plain safe_open is enough. if the test harness emits a different
    # layout we may need a sharded index reader; not implemented yet.
    from safetensors import safe_open
    return safe_open(path, framework="pt")


def _list_safetensors_keys(path: str) -> list[str]:
    with open(path, "rb") as f:
        header_len = struct.unpack("<Q", f.read(8))[0]
        header_raw = f.read(header_len)
    import json
    header = json.loads(header_raw.decode("utf-8"))
    return [k for k in header.keys() if k != "__metadata__"]


def verify_talker(reader: GGUFReader, safetensors_path: str) -> None:
    arch = reader.fields["general.architecture"].parts[
        reader.fields["general.architecture"].data[0]
    ].tobytes().decode()
    check(arch == "qwen3-tts-talker", f"arch = {arch}")

    expect_meta = {
        "qwen3-tts-talker.block_count": 28,
        "qwen3-tts-talker.context_length": 32768,
        "qwen3-tts-talker.embedding_length": 2048,
        "qwen3-tts-talker.feed_forward_length": 6144,
        "qwen3-tts-talker.attention.head_count": 16,
        "qwen3-tts-talker.attention.head_count_kv": 8,
        "qwen3-tts-talker.codec_vocab_size": 3072,
        "qwen3-tts-talker.num_code_groups": 16,
        "qwen3-tts-talker.predictor_layers": 5,
        "qwen3-tts-talker.cp_hidden_size": 1024,
        "qwen3-tts-talker.cp_feed_forward_length": 3072,
        "qwen3-tts-talker.cp_head_count": 16,
        "qwen3-tts-talker.cp_head_count_kv": 8,
        "qwen3-tts-talker.codec_pad_id": 2148,
        "qwen3-tts-talker.codec_bos_id": 2149,
        "qwen3-tts-talker.codec_eos_id": 2150,
        "qwen3-tts-talker.codec_think_id": 2154,
        "qwen3-tts-talker.codec_nothink_id": 2155,
        "qwen3-tts-talker.codec_think_bos_id": 2156,
        "qwen3-tts-talker.codec_think_eos_id": 2157,
        "qwen3-tts-talker.position_id_per_seconds": 13,
    }
    for key, want in expect_meta.items():
        got = get_field(reader, key)
        check(got == want, f"{key} = {got} (want {want})")

    lang_names = get_field(reader, "qwen3-tts-talker.codec_language_names")
    lang_ids = get_field(reader, "qwen3-tts-talker.codec_language_ids")
    check(lang_names is not None and len(lang_names) == len(lang_ids),
          f"codec_language ids/names aligned ({len(lang_names or [])} langs)")
    check(get_field(reader, "qwen3-tts-talker.rope.dimension_sections") is not None,
          "rope.dimension_sections present")

    n_vocab = len(get_field(reader, "tokenizer.ggml.tokens") or [])
    check(n_vocab == 151936, f"text vocab size = {n_vocab}")
    merges = get_field(reader, "tokenizer.ggml.merges")
    check(merges is not None and len(merges) > 0,
          f"bpe merges present ({len(merges) if merges else 0})")

    names = {t.name: t for t in reader.tensors}
    print(f"\ntensor count: {len(names)}")
    check(len(names) == 404,
          f"tensor count = {len(names)} (want 404: all talker tensors, speaker_encoder dropped)")

    def expect_shape(name, want):
        t = names.get(name)
        if t is None:
            check(False, f"tensor {name} present")
            return
        check(list(t.shape) == want,
              f"{name} ggml shape {list(t.shape)} (want {want})")

    # ggml ne is reversed vs torch: torch (A,B) -> ggml ne [B,A]
    expect_shape("token_embd.weight", [2048, 151936])
    expect_shape("codec_embd.weight", [2048, 3072])
    expect_shape("codec_head.weight", [2048, 3072])
    expect_shape("output_norm.weight", [2048])
    expect_shape("text_proj_1.weight", [2048, 2048])
    expect_shape("text_proj_2.weight", [2048, 2048])
    expect_shape("cp_proj.weight", [2048, 1024])
    expect_shape("cp_norm.weight", [1024])
    expect_shape("blk.0.attn_q.weight", [2048, 2048])
    expect_shape("blk.0.attn_k.weight", [2048, 1024])
    expect_shape("blk.0.attn_q_norm.weight", [128])
    expect_shape("blk.0.ffn_gate.weight", [2048, 6144])
    expect_shape("blk.27.ffn_down.weight", [6144, 2048])
    expect_shape("blk.28.attn_q.weight", [1024, 2048])
    expect_shape("blk.28.ffn_gate.weight", [1024, 3072])
    expect_shape("blk.32.attn_output.weight", [2048, 1024])
    expect_shape("cp_codec_embd.0.weight", [2048, 2048])
    expect_shape("cp_codec_embd.14.weight", [2048, 2048])
    expect_shape("cp_head.0.weight", [1024, 2048])
    expect_shape("cp_head.14.weight", [1024, 2048])

    want_suffixes = {"attn_q", "attn_k", "attn_v", "attn_output", "attn_q_norm", "attn_k_norm",
                     "attn_norm", "ffn_norm", "ffn_gate", "ffn_up", "ffn_down"}
    for i in range(28, 33):
        prefix = f"blk.{i}."
        got = {n[len(prefix):].replace(".weight", "")
               for n in names if n.startswith(prefix)}
        check(got == want_suffixes,
              f"blk.{i} has all {len(want_suffixes)} tensors (got {len(got)})")

    for cid in range(15):
        for base in ("cp_codec_embd", "cp_head"):
            check(f"{base}.{cid}.weight" in names,
                  f"{base}.{cid}.weight present")

    print("\nparity spot checks:")
    parity = [
        ("talker.codec_head.weight", "codec_head.weight"),
        ("talker.model.text_embedding.weight", "token_embd.weight"),
        ("talker.model.codec_embedding.weight", "codec_embd.weight"),
        ("talker.model.layers.0.self_attn.q_proj.weight", "blk.0.attn_q.weight"),
        ("talker.model.layers.27.mlp.down_proj.weight", "blk.27.ffn_down.weight"),
        ("talker.code_predictor.model.layers.2.self_attn.q_proj.weight", "blk.30.attn_q.weight"),
        ("talker.code_predictor.model.layers.4.mlp.gate_proj.weight", "blk.32.ffn_gate.weight"),
        ("talker.code_predictor.small_to_mtp_projection.bias", "cp_proj.bias"),
        ("talker.code_predictor.model.codec_embedding.7.weight", "cp_codec_embd.7.weight"),
        ("talker.code_predictor.lm_head.13.weight", "cp_head.13.weight"),
        ("talker.text_projection.linear_fc2.bias", "text_proj_2.bias"),
        ("talker.model.norm.weight", "output_norm.weight"),
    ]
    with _open_safetensors(safetensors_path) as f:
        for st_name, gg_name in parity:
            src = f.get_tensor(st_name)
            t = names[gg_name]
            if t.tensor_type == GGMLQuantizationType.F32:
                a = np.ascontiguousarray(t.data).astype(np.float32)
                b = src.float().numpy()
                ok = a.shape == b.shape and bool((a == b).all())
                check(ok, f"{gg_name} == {st_name} (F32, {a.size} elts)")
                continue
            if src.dtype == torch.bfloat16:
                b16 = src.contiguous().view(torch.uint16).numpy().view(np.uint8)
            else:
                b16 = src.contiguous().numpy().view(np.uint8)
            a = np.ascontiguousarray(t.data).view(np.uint8)
            ok = a.shape == b16.shape and bool((a == b16).all())
            check(ok, f"{gg_name} == {st_name} ({a.size} bytes)")


def verify_vocoder(reader: GGUFReader, safetensors_path: str) -> None:
    arch = reader.fields["general.architecture"].parts[
        reader.fields["general.architecture"].data[0]
    ].tobytes().decode()
    check(arch == "qwen3-tts-code2wav", f"arch = {arch}")

    expect_meta = {
        "qwen3-tts-code2wav.block_count": 8,
        "qwen3-tts-code2wav.context_length": 8000,
        "qwen3-tts-code2wav.embedding_length": 512,
        "qwen3-tts-code2wav.embedding_length_out": 120,
        "qwen3-tts-code2wav.feed_forward_length": 1024,
        "qwen3-tts-code2wav.attention.head_count": 16,
        "qwen3-tts-code2wav.attention.head_count_kv": 16,
        "qwen3-tts-code2wav.attention.key_length": 64,
        "qwen3-tts-code2wav.attention.value_length": 64,
        "qwen3-tts-code2wav.attention.layer_norm_rms_epsilon": 1e-5,
        "qwen3-tts-code2wav.attention.sliding_window": 72,
        "qwen3-tts-code2wav.codebook_count": 16,
        "qwen3-tts-code2wav.residual_units": 3,
        "qwen3-tts-code2wav.sample_rate": 24000,
        "qwen3-tts-code2wav.convnext_norm_eps": 1e-6,
    }
    for key, want in expect_meta.items():
        got = get_field(reader, key)
        check(got == want, f"{key} = {got} (want {want})")

    # raw arch keys with array values: read raw bytes
    def get_array(key):
        f = reader.fields.get(key)
        if f is None or len(f.data) == 0:
            return None
        # each entry is a uint32 packed in a uint8 part
        return [int.from_bytes(f.parts[i].tobytes(), "little")
                for i in f.data]

    rates = get_array("qwen3-tts-code2wav.upsample_rates")
    check(rates == [8, 5, 4, 3], f"upsample_rates = {rates} (want [8, 5, 4, 3])")
    ratios = get_array("qwen3-tts-code2wav.upsample_ratios")
    check(ratios == [2, 2], f"upsample_ratios = {ratios} (want [2, 2])")
    dilations = get_array("qwen3-tts-code2wav.residual_dilations")
    check(dilations == [1, 3, 9],
          f"residual_dilations = {dilations} (want [1, 3, 9])")

    # placeholder token list (no real BPE; the C++ side doesn't tokenize)
    n_vocab = len(get_field(reader, "tokenizer.ggml.tokens") or [])
    check(n_vocab == 2048, f"placeholder vocab size = {n_vocab} (want 2048)")

    names = {t.name: t for t in reader.tensors}
    print(f"\ntensor count: {len(names)}")

    # spot-check the tensor names + shapes the C++ graph loads. The
    # converter names + reverses the HF weight to match the C++ ne[]
    # convention; ggml ne is reversed vs torch.
    def expect_shape(name, want):
        t = names.get(name)
        if t is None:
            check(False, f"tensor {name} present")
            return
        check(list(t.shape) == want,
              f"{name} ggml shape {list(t.shape)} (want {want})")

    expect_shape("c2w.codebook_embd.0.weight", [256, 2048])
    expect_shape("c2w.codebook_embd.15.weight", [256, 2048])
    expect_shape("c2w.vq_first_proj.weight", [256, 512])
    expect_shape("c2w.vq_rest_proj.weight", [256, 512])
    expect_shape("c2w.pre_conv.weight", [3, 512, 1024])
    expect_shape("c2w.pre_conv.bias", [1024])
    expect_shape("c2w.tf.input_proj.weight", [1024, 512])
    expect_shape("c2w.tf.input_proj.bias", [512])
    expect_shape("c2w.tf.norm.weight", [512])
    expect_shape("c2w.tf.output_proj.weight", [512, 1024])
    expect_shape("c2w.tf.output_proj.bias", [1024])
    expect_shape("c2w.tf.layers.0.attn_norm", [512])
    expect_shape("c2w.tf.layers.0.wq", [512, 1024])
    expect_shape("c2w.tf.layers.0.wk", [512, 1024])
    expect_shape("c2w.tf.layers.0.wv", [512, 1024])
    expect_shape("c2w.tf.layers.0.wo", [1024, 512])
    expect_shape("c2w.tf.layers.0.attn_scale", [512])
    expect_shape("c2w.tf.layers.0.ffn_norm", [512])
    expect_shape("c2w.tf.layers.0.ffn_gate", [512, 1024])
    expect_shape("c2w.tf.layers.0.ffn_up", [512, 1024])
    expect_shape("c2w.tf.layers.0.ffn_down", [1024, 512])
    expect_shape("c2w.tf.layers.0.ffn_scale", [512])
    expect_shape("c2w.tf.layers.7.ffn_down", [1024, 512])
    expect_shape("c2w.upsample.0.transconv.weight", [2, 1024, 1024])
    expect_shape("c2w.upsample.0.dwconv.weight", [7, 1, 1024])
    expect_shape("c2w.upsample.0.norm.weight", [1024])
    expect_shape("c2w.upsample.0.pwconv1.weight", [1024, 4096])
    expect_shape("c2w.upsample.0.pwconv2.weight", [4096, 1024])
    expect_shape("c2w.upsample.0.gamma", [1024])
    expect_shape("c2w.upsample.1.transconv.weight", [2, 1024, 1024])
    expect_shape("c2w.stem.weight", [7, 1024, 1536])
    expect_shape("c2w.stem.bias", [1536])
    expect_shape("c2w.block.0.alpha", [1536])
    expect_shape("c2w.block.0.beta", [1536])
    expect_shape("c2w.block.0.transconv.weight", [16, 768, 1536])
    expect_shape("c2w.block.0.res.0.alpha1", [768])
    expect_shape("c2w.block.0.res.0.beta1", [768])
    expect_shape("c2w.block.0.res.0.conv1.weight", [7, 768, 768])
    expect_shape("c2w.block.0.res.0.conv2.weight", [1, 768, 768])
    expect_shape("c2w.block.1.res.1.conv1.weight", [7, 384, 384])
    expect_shape("c2w.block.2.transconv.weight", [8, 192, 384])
    expect_shape("c2w.block.3.alpha", [192])
    expect_shape("c2w.block.3.transconv.weight", [6, 96, 192])
    expect_shape("c2w.output.alpha", [96])
    expect_shape("c2w.output.beta", [96])
    expect_shape("c2w.output.weight", [7, 1, 96])  # permuted to match C++ ne
    expect_shape("c2w.output.bias", [1])

    # block / codebook / layer / upsample index ranges
    import re

    def collect(re_pat):
        return sorted({int(m.group(1))
                       for t in names
                       for m in [re_pat.match(t)]
                       if m})

    blocks = collect(re.compile(r"^c2w\.block\.(\d+)\."))
    check(blocks == [0, 1, 2, 3], f"c2w block indices = {blocks} (want [0, 1, 2, 3])")
    cbs = collect(re.compile(r"^c2w\.codebook_embd\.(\d+)\."))
    check(cbs == list(range(16)),
          f"c2w codebook indices = {cbs} (want 0..15)")
    tfs = collect(re.compile(r"^c2w\.tf\.layers\.(\d+)\."))
    check(tfs == list(range(8)),
          f"c2w tf layer indices = {tfs} (want 0..7)")
    ups = collect(re.compile(r"^c2w\.upsample\.(\d+)\."))
    check(ups == [0, 1], f"c2w upsample indices = {ups} (want [0, 1])")
    res_units = collect(re.compile(r"^c2w\.block\.\d+\.res\.(\d+)\."))
    check(res_units == [0, 1, 2],
          f"residual unit indices = {res_units} (want [0, 1, 2])")

    # exact tensor count: 16 codebook + 2 vq proj + 2 pre_conv + 2 stem +
    # 22 upsample (2 stages * 11 = transconv w/b + dwconv w/b + norm w/b +
    # pw1 w/b + pw2 w/b + gamma) + 93 tf (input_proj w/b + 8 layers * 11 +
    # norm + output_proj w/b) + 112 block (4 blocks * 28 = 2 snake + 2
    # transconv + 3 res units * 8) + 4 output (alpha + beta + weight + bias)
    # = 16 + 2 + 2 + 2 + 22 + 93 + 112 + 4 = 253
    check(len(names) == 253,
          f"tensor count = {len(names)} (want 253: 16+2+2+2+22+93+112+4)")

    print("\nparity spot checks (c2w):")
    # the converter bakes: codebook = embed_sum / cluster_usage,
    # snake alpha = exp(hf_alpha), snake beta = 1/(exp(hf_beta) + 1e-9).
    # these derivations mean we can read the HF and apply them inline.
    with _open_safetensors(safetensors_path) as f:
        # codebook 0 (rvq_first layer 0)
        emb = f.get_tensor("decoder.quantizer.rvq_first.vq.layers.0._codebook.embedding_sum").float()
        use = f.get_tensor("decoder.quantizer.rvq_first.vq.layers.0._codebook.cluster_usage").float()
        want = (emb / use.clamp(min=1e-5).unsqueeze(1)).numpy()
        got = np.ascontiguousarray(names["c2w.codebook_embd.0.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.codebook_embd.0 == embed_sum / cluster_usage (shape {got.shape}, {got.size} elts)")

        # codebook 5 (rvq_rest layer 4)
        emb = f.get_tensor("decoder.quantizer.rvq_rest.vq.layers.4._codebook.embedding_sum").float()
        use = f.get_tensor("decoder.quantizer.rvq_rest.vq.layers.4._codebook.cluster_usage").float()
        want = (emb / use.clamp(min=1e-5).unsqueeze(1)).numpy()
        got = np.ascontiguousarray(names["c2w.codebook_embd.5.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.codebook_embd.5 == embed_sum / cluster_usage (shape {got.shape}, {got.size} elts)")

        # snake alpha (block 0) = exp(hf_alpha)
        hf_alpha = f.get_tensor("decoder.decoder.1.block.0.alpha").float()
        want = hf_alpha.exp().numpy()
        got = np.ascontiguousarray(names["c2w.block.0.alpha"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.block.0.alpha == exp(hf_alpha) (shape {got.shape})")

        # snake beta = 1/(exp(hf_beta) + 1e-9)
        hf_beta = f.get_tensor("decoder.decoder.1.block.0.beta").float()
        want = (1.0 / (hf_beta.exp() + 1e-9)).numpy()
        got = np.ascontiguousarray(names["c2w.block.0.beta"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.block.0.beta == 1/(exp(hf_beta)+1e-9) (shape {got.shape})")

        # residual snake alpha1 (block 0, unit 0) = exp(act1.alpha)
        hf = f.get_tensor("decoder.decoder.1.block.2.act1.alpha").float()
        want = hf.exp().numpy()
        got = np.ascontiguousarray(names["c2w.block.0.res.0.alpha1"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.block.0.res.0.alpha1 == exp(act1.alpha) (shape {got.shape})")

        # pre_conv weight: HF (1024, 512, 3) -> gguf (3, 512, 1024)
        hf = f.get_tensor("decoder.pre_conv.conv.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.pre_conv.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.pre_conv.weight shape {got.shape} (HF {list(hf.shape)} reversed)")

        # stem weight: HF (1536, 1024, 7) -> gguf (7, 1024, 1536)
        hf = f.get_tensor("decoder.decoder.0.conv.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.stem.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.stem.weight shape {got.shape} (HF {list(hf.shape)} reversed)")

        # block 0 transconv: HF ConvTranspose1d weight (1536, 768, 16) ->
        # gguf (16, 768, 1536). This is the (k, out, in) ggml view.
        hf = f.get_tensor("decoder.decoder.1.block.1.conv.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.block.0.transconv.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.block.0.transconv.weight shape {got.shape} (HF {list(hf.shape)} reversed)")

        # output conv: HF (1, 96, 7) was permuted to (96, 1, 7) so the gguf
        # file ne = (7, 1, 96) matches the W3 C++ create_tensor call (which
        # we believe is wrong; see report). The numpy layout in the file
        # is therefore (96, 1, 7) - we compare against the post-permute data.
        hf = f.get_tensor("decoder.decoder.6.conv.weight").float()
        want = hf.permute(1, 0, 2).contiguous().numpy()
        got = np.ascontiguousarray(names["c2w.output.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.output.weight shape {got.shape} (HF {list(hf.shape)} permuted to {list(want.shape)})")

        # pre_transformer input_proj: HF Linear (512, 1024) -> gguf (1024, 512)
        hf = f.get_tensor("decoder.pre_transformer.input_proj.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.tf.input_proj.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.tf.input_proj.weight shape {got.shape} (HF {list(hf.shape)} reversed)")

        # pre_transformer layer 0 q_proj: HF Linear (1024, 512) -> gguf (512, 1024)
        hf = f.get_tensor("decoder.pre_transformer.layers.0.self_attn.q_proj.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.tf.layers.0.wq"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.tf.layers.0.wq shape {got.shape} (HF {list(hf.shape)} reversed)")

        # 1D RMSNorm: HF (512,) -> gguf (512,), exact copy
        hf = f.get_tensor("decoder.pre_transformer.norm.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.tf.norm.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.tf.norm.weight == hf (F32)")

        # 1D final-snake alpha: HF (96,) -> exp -> gguf (96,)
        hf = f.get_tensor("decoder.decoder.5.alpha").float()
        want = hf.exp().numpy()
        got = np.ascontiguousarray(names["c2w.output.alpha"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.output.alpha == exp(hf_alpha) (shape {got.shape})")

        # upsample 0 pwconv1: HF Linear (4096, 1024) -> gguf (1024, 4096)
        hf = f.get_tensor("decoder.upsample.0.1.pwconv1.weight").float()
        want = hf.numpy()
        got = np.ascontiguousarray(names["c2w.upsample.0.pwconv1.weight"].data).astype(np.float32)
        check(got.shape == want.shape and bool((got == want).all()),
              f"c2w.upsample.0.pwconv1.weight shape {got.shape} (HF {list(hf.shape)} reversed)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("gguf", help="converted qwen3-tts GGUF (talker or vocoder)")
    ap.add_argument("safetensors", help="source model.safetensors")
    args = ap.parse_args()

    reader = GGUFReader(args.gguf, "r")
    arch = reader.fields["general.architecture"].parts[
        reader.fields["general.architecture"].data[0]
    ].tobytes().decode()

    if arch == "qwen3-tts-talker":
        verify_talker(reader, args.safetensors)
    elif arch == "qwen3-tts-code2wav":
        verify_vocoder(reader, args.safetensors)
    else:
        print(f"unsupported arch: {arch}")
        return 2

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s)")
        for m in failures:
            print("  -", m)
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
