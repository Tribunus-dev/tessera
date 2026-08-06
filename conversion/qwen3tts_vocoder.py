from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from typing import Any, Iterable, TYPE_CHECKING

if TYPE_CHECKING:
    from torch import Tensor

# allow direct invocation (`python3 conversion/qwen3tts_vocoder.py ...`):
# the relative `.base` import only works when conversion/ is a package
# on sys.path. The W2 talker only ships inside convert_hf_to_gguf.py,
# so the same package import works through that path; the standalone
# entry point below needs both `conversion.` and `gguf` resolvable.
_PKG_PARENT = Path(__file__).resolve().parent.parent
if str(_PKG_PARENT) not in sys.path:
    sys.path.insert(0, str(_PKG_PARENT))
if 'NO_LOCAL_GGUF' not in os.environ:
    sys.path.insert(1, str(_PKG_PARENT / "gguf-py"))

from conversion.base import ModelBase, TextModel, gguf  # noqa: E402


@ModelBase.register("Qwen3TTSTokenizerV2Model", "Qwen3TTSTokenizerV2Decoder")
class Qwen3TTSVocoderModel(TextModel):
    # Qwen3-TTS-12Hz Code2Wav vocoder (Qwen3TTSTokenizerV2Decoder).
    #
    # The C++ side (src/models/qwen3-tts-code2wav.cpp) loads this arch as a
    # single graph: 16 RVQ code ids per frame -> 1920 PCM samples per frame
    # at 24 kHz, fully causal, no text vocab.
    #
    # GGUF layout mirrors the C++ tensor name map (c2w.*):
    #   c2w.codebook_embd.{cid}.weight          (16 entries, vq_dim x n_vocab)
    #   c2w.vq_first_proj.weight                (vq_dim x n_embd)
    #   c2w.vq_rest_proj.weight                 (vq_dim x n_embd)
    #   c2w.pre_conv.{weight,bias}              (Conv1d k=3, n_embd -> latent)
    #   c2w.tf.input_proj.{weight,bias}        (Linear latent -> n_embd)
    #   c2w.tf.layers.{i}.{attn_norm, wq, wk, wv, wo, attn_scale,
    #                      ffn_norm, ffn_gate, ffn_up, ffn_down, ffn_scale}
    #   c2w.tf.norm.weight                      (final pre-out RMS)
    #   c2w.tf.output_proj.{weight,bias}        (Linear n_embd -> latent)
    #   c2w.upsample.{s}.{transconv, dwconv, norm, pw1, pw2, gamma} (+ biases)
    #   c2w.stem.{weight,bias}                  (Conv1d k=7, latent -> decoder)
    #   c2w.block.{b}.{alpha, beta, transconv}  (snake_a/b + upsample transconv)
    #   c2w.block.{b}.res.{u}.{alpha1, beta1, conv1, alpha2, beta2, conv2}
    #   c2w.output.{alpha, beta}                (final snake_a/b)
    #   c2w.output.{weight, bias}               (Conv1d k=7, -> 1ch PCM)
    #
    # The HF side stores the codebook as a running EMA
    # (embedding_sum / cluster_usage) per codebook; the C++ graph
    # does the division at convert time and stores the precomputed
    # codebook as c2w.codebook_embd.{cid}.weight.
    #
    # The HF stores snake parameters as log-scale (alpha, beta); the
    # C++ graph uses a = exp(alpha) and b = 1 / (exp(beta) + 1e-9),
    # so the converter bakes the nonlinearity at convert time.
    #
    # The arch is registered as ModelType.TEXT (not MMPROJ) because
    # the C++ graph reads hparams.n_vocab for the codebook size; the
    # converter writes a 2048-entry placeholder token list so the
    # n_vocab hparam resolves correctly. The C++ side does not tokenize.
    model_arch = gguf.MODEL_ARCH.QWEN3_TTS_CODE2WAV

    _pre_tf_layer_re = re.compile(
        r"^decoder\.pre_transformer\.layers\.(\d+)\.(.+)$")
    _pre_tf_top_re = re.compile(
        r"^decoder\.pre_transformer\.(?!layers\.)(.+)$")
    _dec_block_re = re.compile(
        r"^decoder\.decoder\.(\d+)\.block\.(\d+)\.(.+)$")
    _upsample_re = re.compile(
        r"^decoder\.upsample\.(\d+)\.(\d+)\.(.+)$")
    _vq_layer_re = re.compile(
        r"^decoder\.quantizer\.(rvq_first|rvq_rest)\.vq\.layers\.(\d+)\._codebook\.(.+)$")

    def __init__(self, *args: Any, **kwargs: Any):
        dir_model = args[0] if args else kwargs.get("dir_model")
        if kwargs.get("hparams") is None and dir_model is not None:
            with open(dir_model / "config.json", "r", encoding="utf-8") as f:
                config = json.load(f)
            # the HF config nests everything under decoder_config; the base
            # class expects the params it consumes (hidden_size,
            # num_hidden_layers, etc.) at the root, so we promote them.
            decoder = dict(config.get("decoder_config") or config)
            # the HF config's top-level `architectures` field is what
            # base.get_model_architecture() looks for to set self.hf_arch.
            if config.get("architectures") is not None:
                decoder["architectures"] = config["architectures"]
            # architecturally the same arch appears as two class names
            # upstream (the encoder/decoder split lives in encoder_config);
            # we deliberately ignore the encoder subtree.
            kwargs["hparams"] = decoder
        super().__init__(*args, **kwargs)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Any]) -> tuple[str, Any] | None:
        name, gen = item
        if not name.startswith("decoder."):
            return None
        # the C++ side does not load the VQ input projection; the output
        # projection (Conv1d 256x512x1) maps vq_dim -> n_embd and is the
        # only projection the C++ graph consumes. The pre_transformer's
        # input_proj/output_proj (Linear 1024->512 / 512->1024) IS loaded
        # and renamed to c2w.tf.{input,output}_proj, so the filter must
        # scope the drop to the VQ subtree only. The codebook running
        # EMA bookkeeping (cluster_usage, initialized) is training-only,
        # but cluster_usage is KEPT here so the parallel embed_sum
        # tensor in modify_tensors can find it; the actual drop happens
        # in _map_tensor where it is never yielded.
        if name.startswith("decoder.quantizer.") and (
                name.endswith(".input_proj.weight")
                or name.endswith(".input_proj.bias")):
            return None
        return name, gen

    def set_vocab(self) -> None:
        # The C++ graph reads hparams.n_vocab as the codebook size
        # (GGML_ASSERT(meta->ne[1] == n_vocab)) and never tokenizes. Write
        # a 2048-entry placeholder token list so the n_vocab metadata
        # resolves to the codebook size. The placeholder strings are
        # diagnostic only; the C++ side ignores them.
        n_vocab = int(self.hparams["codebook_size"])
        tokens = [f"c2w_code_{i}" for i in range(n_vocab)]
        toktypes = [gguf.TokenType.NORMAL] * n_vocab
        self.gguf_writer.add_tokenizer_model("none")
        self.gguf_writer.add_token_list(tokens)
        self.gguf_writer.add_token_types(toktypes)

    def set_gguf_parameters(self) -> None:
        # the base TextModel writes block_count, context_length, embedding_length,
        # head_count, head_count_kv, feed_forward_length, rms_norm_eps,
        # head_dim, etc. from the decoder_config fields (promoted into
        # self.hparams by __init__).
        super().set_gguf_parameters()

        w = self.gguf_writer
        cfg = self.hparams

        # n_embd_out (per-codebook output dim). samples_per_frame =
        # prod(upsample_rates) * prod(upsample_ratios); per codebook =
        # samples_per_frame / n_codebooks. The C++ asserts
        # up == hparams.n_embd_out() * n_codebooks in load_arch_hparams.
        up = 1
        for r in cfg["upsample_rates"]:
            up *= int(r)
        for r in cfg["upsampling_ratios"]:
            up *= int(r)
        n_codebooks = int(cfg["num_quantizers"])
        n_embd_out = up // n_codebooks
        w.add_embedding_length_out(n_embd_out)

        # the c2w model uses sliding-window attention; the HF config
        # names it "sliding_window" (decoder_config). Mirror to the
        # standard attention.sliding_window key.
        swa = int(cfg.get("sliding_window", 0))
        if swa > 0:
            w.add_sliding_window(swa)

        # raw arch-prefixed keys; no LLM_KV entries needed (the C++ side
        # constructs the key as arch_name + suffix).
        w.add_uint32(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.codebook_count", n_codebooks)
        # the V2 decoder has 3 residual units per block (1x dilated conv
        # with dilations 1/3/9 + 1x conv with k=1). The C++ reads
        # residual_dilations.size() == n_res_units.
        w.add_uint32(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.residual_units", 3)
        w.add_array(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.upsample_rates",
            [int(r) for r in cfg["upsample_rates"]])
        w.add_array(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.upsample_ratios",
            [int(r) for r in cfg["upsampling_ratios"]])
        w.add_array(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.residual_dilations",
            [1, 3, 9])

        # the HF config has both input_sample_rate and output_sample_rate;
        # the C++ reads sample_rate as a single uint32 (defaulted to 24000
        # when absent). We mirror the output rate.
        w.add_uint32(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.sample_rate",
            int(cfg.get("output_sample_rate", 24000)))

        # convnext_norm_eps: the HF config does not expose it. The C++
        # default is 1e-6; document that fallback by writing it explicitly
        # (the C++ side reads it as optional but the graph is unusable
        # without a finite eps).
        w.add_float32(
            f"{gguf.MODEL_ARCH_NAMES[self.model_arch]}.convnext_norm_eps", 1e-6)

    def modify_tensors(
            self, data_torch: "Tensor", name: str,
            bid: int | None) -> Iterable[tuple[str, "Tensor"]]:
        new_name, new_t = self._map_tensor(name, data_torch)
        if new_name is None:
            return
        yield new_name, new_t

    def _map_tensor(
            self, name: str, data_torch: "Tensor"
            ) -> tuple[str | None, "Tensor"]:
        # helper: dropped tensor (filter kept it for an adjacent tensor,
        # but this one is not consumed by the C++ graph)
        if name is None:
            return None, data_torch
        # ---- codebook tables (EMA -> codebook) ----
        m = self._vq_layer_re.match(name)
        if m is not None:
            group, layer_idx, suffix = m.group(1), int(m.group(2)), m.group(3)
            # c2w.codebook_embd.0 = rvq_first layer 0
            # c2w.codebook_embd.1..15 = rvq_rest layer 0..14
            if group == "rvq_first":
                assert layer_idx == 0, (
                    f"rvq_first has only one layer, got {layer_idx}")
                cid = 0
            else:
                cid = layer_idx + 1
            if suffix == "embedding_sum":
                # convert embed_sum -> actual codebook by dividing by
                # cluster_usage. The cluster_usage tensor is fetched
                # lazily; we have a parallel safetensors entry in
                # model_tensors that the base class already loaded.
                usage = self._lookup_codebook_usage(group, layer_idx)
                usage = usage.clamp(min=1e-5)
                codebook = data_torch / usage.unsqueeze(1)
                return f"c2w.codebook_embd.{cid}.weight", codebook
            # cluster_usage + initialized are training-only bookkeeping;
            # we kept cluster_usage in the filter so the parallel
            # embed_sum can divide by it, but we never yield it.
            return None, data_torch

        # ---- upsample stages (time-major) ----
        m = self._upsample_re.match(name)
        if m is not None:
            stage, sub, suffix = int(m.group(1)), int(m.group(2)), m.group(3)
            return self._map_upsample(stage, sub, suffix, data_torch)

        # ---- decoder blocks (block snake, transconv, residual units) ----
        m = self._dec_block_re.match(name)
        if m is not None:
            block, sub, suffix = int(m.group(1)), int(m.group(2)), m.group(3)
            return self._map_decoder_block(block, sub, suffix, data_torch)

        # ---- pre-transformer (channel-major Linear-style) ----
        m = self._pre_tf_layer_re.match(name)
        if m is not None:
            il, suffix = int(m.group(1)), m.group(2)
            return self._map_pre_transformer(il, suffix, data_torch)
        m = self._pre_tf_top_re.match(name)
        if m is not None:
            return self._map_pre_transformer(None, m.group(1), data_torch)

        # ---- top-level decoder tensors ----
        if name == "decoder.pre_conv.conv.weight":
            return "c2w.pre_conv.weight", data_torch
        if name == "decoder.pre_conv.conv.bias":
            return "c2w.pre_conv.bias", data_torch
        if name == "decoder.pre_transformer.norm.weight":
            return "c2w.tf.norm.weight", data_torch
        if name == "decoder.decoder.0.conv.weight":
            return "c2w.stem.weight", data_torch
        if name == "decoder.decoder.0.conv.bias":
            return "c2w.stem.bias", data_torch
        if name == "decoder.quantizer.rvq_first.output_proj.weight":
            # Conv1d(256, 512, 1) -> 2D (out, in) = (512, 256).
            # The C++ tensor is (vq_dim=256, n_embd=512); the GGUF writer
            # reverses the shape on write, so the on-disk shape is
            # (256, 512) and the column-major view in C++ matches.
            return "c2w.vq_first_proj.weight", data_torch.squeeze(-1)
        if name == "decoder.quantizer.rvq_rest.output_proj.weight":
            return "c2w.vq_rest_proj.weight", data_torch.squeeze(-1)

        # final snake + output conv live at decoder.decoder.{n_blk+1}
        # and {n_blk+2}; n_blk comes from upsample_rates. Look the
        # tail off the path numerically so the synthetic-tiny config
        # (n_blk=2) and the real config (n_blk=4) both work.
        n_blk = len(self.hparams["upsample_rates"])
        if name == f"decoder.decoder.{n_blk + 1}.alpha":
            return "c2w.output.alpha", data_torch.exp()
        if name == f"decoder.decoder.{n_blk + 1}.beta":
            return "c2w.output.beta", 1.0 / (data_torch.exp() + 1e-9)
        if name == f"decoder.decoder.{n_blk + 2}.conv.weight":
            # The C++ side creates c2w.output with shape { 7, 1, c_last }
            # (ne[0]=7, ne[1]=1, ne[2]=c_last). ggml_conv_1d interprets the
            # weight as (K, IC, OC) and the reshape to (IC*K, OC) requires
            # (K, IC, OC) layout; the C++ here uses (K, OC, IC) which is
            # the OPPOSITE of every other conv in this graph (pre_conv,
            # stem, block transconv all use K, IC, OC). To make the GGUF
            # load cleanly without a C++ patch, the converter permutes the
            # HF weight (1, c_last, 7) so the on-disk GGUF ne=(7, 1, c_last)
            # matches the C++ expectation. NOTE: this is a band-aid; the
            # W3 C++ create_tensor call should be (7, c_last, 1) for the
            # output conv. See the report for the full mismatch.
            permuted = data_torch.permute(1, 0, 2).contiguous()
            return "c2w.output.weight", permuted
        if name == f"decoder.decoder.{n_blk + 2}.conv.bias":
            return "c2w.output.bias", data_torch

        # nothing matched: the base filter already dropped encoder + vq
        # bookkeeping tensors, so a stray decoder.* name is a real error
        raise ValueError(f"unhandled tensor: {name!r}")

    def _map_upsample(
            self, stage: int, sub: int, suffix: str,
            data_torch: "Tensor") -> tuple[str, "Tensor"]:
        # the V2 convnext upsample has 2 sub-modules per stage:
        #   sub=0: transposed conv
        #   sub=1: convnext block (dwconv + norm + pw1 + pw2 + gamma)
        if sub == 0:
            if suffix == "conv.weight":
                return f"c2w.upsample.{stage}.transconv.weight", data_torch
            if suffix == "conv.bias":
                return f"c2w.upsample.{stage}.transconv.bias", data_torch
            raise ValueError(
                f"unexpected upsample.{stage}.0.{suffix}")
        # sub == 1
        if suffix == "dwconv.conv.weight":
            return f"c2w.upsample.{stage}.dwconv.weight", data_torch
        if suffix == "dwconv.conv.bias":
            return f"c2w.upsample.{stage}.dwconv.bias", data_torch
        if suffix == "norm.weight":
            return f"c2w.upsample.{stage}.norm.weight", data_torch
        if suffix == "norm.bias":
            return f"c2w.upsample.{stage}.norm.bias", data_torch
        if suffix == "pwconv1.weight":
            return f"c2w.upsample.{stage}.pwconv1.weight", data_torch
        if suffix == "pwconv1.bias":
            return f"c2w.upsample.{stage}.pwconv1.bias", data_torch
        if suffix == "pwconv2.weight":
            return f"c2w.upsample.{stage}.pwconv2.weight", data_torch
        if suffix == "pwconv2.bias":
            return f"c2w.upsample.{stage}.pwconv2.bias", data_torch
        if suffix == "gamma":
            return f"c2w.upsample.{stage}.gamma", data_torch
        raise ValueError(f"unhandled upsample.{stage}.1.{suffix}")

    def _map_decoder_block(
            self, block: int, sub: int, suffix: str,
            data_torch: "Tensor") -> tuple[str, "Tensor"]:
        # the HF structure uses decoder.decoder.{1..n_blk} for the
        # n_blk upsample blocks (decoder.decoder.0 is the stem conv,
        # decoder.decoder.{n_blk+1} is the final snake, decoder.decoder.
        # {n_blk+2} is the output conv). The C++ side numbers the
        # upsample blocks 0..n_blk-1 (the loop walks upsample_rates).
        # So HF block index 1..n_blk maps to c2w block index 0..n_blk-1.
        block -= 1
        # sub=0: block-level snake (alpha, beta)
        # sub=1: transposed conv (up_conv) (weight, bias)
        # sub=2..4: residual units (act1, conv1, act2, conv2)
        if sub == 0:
            if suffix == "alpha":
                # snake a = exp(alpha_hf)
                return (f"c2w.block.{block}.alpha",
                        data_torch.exp())
            if suffix == "beta":
                # snake b = 1 / (exp(beta_hf) + 1e-9)
                return (f"c2w.block.{block}.beta",
                        1.0 / (data_torch.exp() + 1e-9))
        if sub == 1:
            if suffix == "conv.weight":
                return f"c2w.block.{block}.transconv.weight", data_torch
            if suffix == "conv.bias":
                return f"c2w.block.{block}.transconv.bias", data_torch
        # residual units: each sub has act1 + conv1 + act2 + conv2; the C++
        # names them .alpha1/.beta1/.conv1/.alpha2/.beta2/.conv2, indexed
        # by residual unit id u = sub - 2.
        if 2 <= sub <= 4:
            u = sub - 2
            if suffix == "act1.alpha":
                return (f"c2w.block.{block}.res.{u}.alpha1",
                        data_torch.exp())
            if suffix == "act1.beta":
                return (f"c2w.block.{block}.res.{u}.beta1",
                        1.0 / (data_torch.exp() + 1e-9))
            if suffix == "conv1.conv.weight":
                return f"c2w.block.{block}.res.{u}.conv1.weight", data_torch
            if suffix == "conv1.conv.bias":
                return f"c2w.block.{block}.res.{u}.conv1.bias", data_torch
            if suffix == "act2.alpha":
                return (f"c2w.block.{block}.res.{u}.alpha2",
                        data_torch.exp())
            if suffix == "act2.beta":
                return (f"c2w.block.{block}.res.{u}.beta2",
                        1.0 / (data_torch.exp() + 1e-9))
            if suffix == "conv2.conv.weight":
                return f"c2w.block.{block}.res.{u}.conv2.weight", data_torch
            if suffix == "conv2.conv.bias":
                return f"c2w.block.{block}.res.{u}.conv2.bias", data_torch
        raise ValueError(f"unhandled decoder.{block}.{sub}.{suffix}")

    def _map_pre_transformer(
            self, il: int, suffix: str,
            data_torch: "Tensor") -> tuple[str, "Tensor"]:
        # the pre_transformer is a Qwen-style transformer: input_proj,
        # then N layers (attn + mlp), then norm + output_proj.
        if suffix == "input_proj.weight":
            return "c2w.tf.input_proj.weight", data_torch
        if suffix == "input_proj.bias":
            return "c2w.tf.input_proj.bias", data_torch
        if suffix == "norm.weight":
            return "c2w.tf.norm.weight", data_torch
        if suffix == "output_proj.weight":
            return "c2w.tf.output_proj.weight", data_torch
        if suffix == "output_proj.bias":
            return "c2w.tf.output_proj.bias", data_torch
        if suffix == "self_attn_layer_scale.scale":
            return f"c2w.tf.layers.{il}.attn_scale", data_torch
        if suffix == "mlp_layer_scale.scale":
            return f"c2w.tf.layers.{il}.ffn_scale", data_torch
        if suffix == "input_layernorm.weight":
            return f"c2w.tf.layers.{il}.attn_norm", data_torch
        if suffix == "post_attention_layernorm.weight":
            return f"c2w.tf.layers.{il}.ffn_norm", data_torch
        if suffix == "self_attn.q_proj.weight":
            return f"c2w.tf.layers.{il}.wq", data_torch
        if suffix == "self_attn.k_proj.weight":
            return f"c2w.tf.layers.{il}.wk", data_torch
        if suffix == "self_attn.v_proj.weight":
            return f"c2w.tf.layers.{il}.wv", data_torch
        if suffix == "self_attn.o_proj.weight":
            return f"c2w.tf.layers.{il}.wo", data_torch
        if suffix == "mlp.gate_proj.weight":
            return f"c2w.tf.layers.{il}.ffn_gate", data_torch
        if suffix == "mlp.up_proj.weight":
            return f"c2w.tf.layers.{il}.ffn_up", data_torch
        if suffix == "mlp.down_proj.weight":
            return f"c2w.tf.layers.{il}.ffn_down", data_torch
        raise ValueError(f"unhandled pre_transformer.layers.{il}.{suffix}")

    def _lookup_codebook_usage(self, group: str, layer_idx: int) -> "Tensor":
        usage_name = (
            f"decoder.quantizer.{group}.vq.layers.{layer_idx}."
            f"_codebook.cluster_usage")
        gen = self.model_tensors.get(usage_name)
        if gen is None:
            raise ValueError(
                f"missing codebook usage tensor for {group} layer "
                f"{layer_idx}; the filter should have kept it for the "
                f"embed_sum / cluster_usage pair")
        return gen()


def main(argv: list[str] | None = None) -> int:
    """Standalone entry point.

    Mirrors the W2 talker invocation surface (single HF dir, single
    output GGUF). PyTorch is the only non-gguf-py dep; the converter
    works against a real HF checkpoint (model.safetensors) or a
    synthetic stand-in produced by the test harness.
    """
    import argparse
    import os
    import sys
    from pathlib import Path

    if argv is None:
        argv = sys.argv[1:]

    p = argparse.ArgumentParser(
        prog="qwen3tts_vocoder",
        description=(
            "Convert Qwen3TTSTokenizerV2Model (Qwen3-TTS-12Hz vocoder) "
            "from HF safetensors to a QWEN3_TTS_CODE2WAV GGUF that the "
            "C++ graph in src/models/qwen3-tts-code2wav.cpp can load."),
    )
    p.add_argument(
        "--vocoder-hf", required=True, type=Path,
        help="path to a HF directory containing config.json and "
             "model.safetensors (e.g. /Volumes/Julian T7/models/"
             "qwen3-tts-model/speech_tokenizer)")
    p.add_argument(
        "--vocoder-out", required=True, type=Path,
        help="output GGUF path")
    p.add_argument(
        "--outtype", default="f32",
        choices=["f32", "f16", "bf16"],
        help="weight dtype; biases and 1D tensors stay F32")
    args = p.parse_args(argv)

    if not args.vocoder_hf.is_dir():
        p.error(f"--vocoder-hf {args.vocoder_hf} is not a directory")
    if not (args.vocoder_hf / "config.json").is_file():
        p.error(f"--vocoder-hf {args.vocoder_hf} has no config.json")

    # mirror the W2 main: the ftype is what the base class uses to decide
    # 2D/3D weight dtype (1D tensors stay F32 regardless).
    ftype_map = {
        "f32": gguf.LlamaFileType.ALL_F32,
        "f16": gguf.LlamaFileType.MOSTLY_F16,
        "bf16": gguf.LlamaFileType.MOSTLY_BF16,
    }
    ftype = ftype_map[args.outtype]

    os.environ.setdefault("NO_LOCAL_GGUF", "0")
    instance = Qwen3TTSVocoderModel(
        dir_model=args.vocoder_hf,
        ftype=ftype,
        fname_out=args.vocoder_out,
    )
    instance.write()
    print(
        f"wrote {args.vocoder_out} "
        f"(arch={gguf.MODEL_ARCH_NAMES[instance.model_arch]}, "
        f"n_tensors={len(instance.gguf_writer.tensors)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
