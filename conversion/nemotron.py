# Part of the tessera GGUF conversion pipeline.
# SPDX-License-Identifier: Apache-2.0

"""
Conversion for NVIDIA Nemotron-3.5-Lightning models.

Target:   NVIDIA-Nemotron-3.5-Lightning-30B-A3B-{BF16,NVFP4}
            architecture = NemotronHForCausalLM
            model_type   = nemotron_h
            52 layers:  interleaved Mamba-2 + MoE (Latent) + Attention
            MoE: 128 routed experts, 6 active/tok, 1 shared expert
            Attention: 6 full-attention layers at positions [5,12,19,26,33,40]

Drafters: NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DFlash
            architecture = DFlashDraftModel  (registered in qwen.py)
            6 layers: dense GQA MLP + attention
            target_layer_ids = [1, 5, 19, 29, 41, 51] from trunk

          NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4-DSpark
            6 layers: dense GQA MLP + causal sliding-window attention
            same target_layer_ids

Tensor naming (HuggingFace → GGUF):
  backbone.layers.{bid}.mixer.{proj}        → blk.{bid}.ssm_{proj}
  backbone.layers.{bid}.mixer.gate           → blk.{bid}.ffn_latent_up / .ffn_latent_down
  backbone.layers.{bid}.mixer.experts.{e}.up/down_proj → blk.{bid}.ffn_up_exps.{e} / .ffn_down_exps.{e}
  backbone.layers.{bid}.mixer.shared_experts.up/down_proj → blk.{bid}.ffn_up_shexp / .ffn_down_shexp
  backbone.layers.{bid}.mixer.self_attn.q/k/v/o_proj → blk.{bid}.attn_q / .attn_k / .attn_v / .attn_output
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Callable, Iterable, TYPE_CHECKING

import torch

if TYPE_CHECKING:
    from torch import Tensor

from .base import ModelBase, TextModel, gguf, logger
from .mamba import Mamba2Model
from .granite import GraniteMoeModel, GraniteModel


# ---------------------------------------------------------------------------
# Shared utility: parse layers_block_type → per-block type
# ---------------------------------------------------------------------------

def parse_layers_block_type(hparams: dict) -> dict[int, str]:
    """Return {block_id: 'mamba'|'moe'|'attention'} from layers_block_type array."""
    block_types = hparams.get("layers_block_type", [])
    if not block_types:
        raise ValueError("nemotron_h model requires layers_block_type in config.json")
    result = {}
    for bid, block_type in enumerate(block_types):
        if block_type == "mamba":
            result[bid] = "mamba"
        elif block_type == "moe":
            result[bid] = "moe"
        elif block_type == "attention":
            result[bid] = "attention"
        else:
            raise ValueError(f"Unknown block type {block_type!r} at layer {bid}")
    return result


# ---------------------------------------------------------------------------
# NemotronHForCausalLM  — trunk converter
# ---------------------------------------------------------------------------

@ModelBase.register("NemotronHForCausalLM")
class NemotronHModel(Mamba2Model, GraniteMoeModel):
    """
    Conversion for NVIDIA Nemotron-3.5-Lightning.

    Architecture: hybrid LatentMoE (Mamba-2 SSM + MoE + Attention), registered as
    MODEL_ARCH.NEMOTRON_H_MOE.

    Layer routing (layers_block_type):
      - "mamba"     → Mamba2Model  (blk.{bid}.ssm_*)
      - "moe"       → GraniteMoeModel (blk.{bid}.ffn_latent_*, ffn_up/down_exps, ffn_up/down_shexp)
      - "attention"  → LlamaModel (blk.{bid}.attn_q/k/v/output, attention RMS norm)

    Key differences from GraniteHybridModel:
      - Uses backbone.layers.* naming (not blk.*) in source tensors
      - MoE gate (mixer.gate) is a latent gate, not a router weight
      - MoE latent projection (ffn_latent_up/down) is inserted before expert routing
      - Mamba2 in_proj must be split into ssm_in + ssm_x (already handled by Mamba2Model)
      - No rope on SSM layers (rope_scaling_finetuned=false)
    """

    model_arch = gguf.MODEL_ARCH.NEMOTRON_H_MOE

    def __init__(self, *args, **kwargs):
        # Avoid using AutoConfig for hparams; nemotron_h uses a top-level config
        hparams = kwargs.pop("hparams", None)
        if hparams is None:
            dir_model = args[0] if args else kwargs.get("dir_model")
            if dir_model is None:
                raise ValueError("NemotronHModel requires dir_model or explicit hparams")
            with open(Path(dir_model) / "config.json", "r", encoding="utf-8") as f:
                hparams = json.load(f)
        super().__init__(*args, hparams=hparams, **kwargs)

        # Parse layers_block_type to know which block handles which tensor
        self._block_types = parse_layers_block_type(self.hparams)

        # Mamba2 parameters (needed by Mamba2Model.modify_tensors for SSM ops)
        self.d_model = self.find_hparam(["hidden_size"])
        self.expand = self.find_hparam(["expand"], optional=True) or 2
        # d_inner for the Mamba-2 SSM is mamba_num_heads * mamba_head_dim
        # (NOT intermediate_size, which in HF Nemotron 3.5 is the MoE FFN
        # intermediate dim, not the SSM internal dim — different convention
        # from upstream Mamba-2 where intermediate_size WAS the SSM dim).
        mamba_nh = self.find_hparam(["mamba_num_heads"], optional=True)
        mamba_hd = self.find_hparam(["mamba_head_dim"], optional=True)
        if mamba_nh is not None and mamba_hd is not None:
            self.d_inner = int(mamba_nh) * int(mamba_hd)
        else:
            self.d_inner = self.expand * self.d_model
        self.n_group = self.find_hparam(["n_groups"], optional=True) or 8

    def find_hparam(self, keys, *args, **kwargs):
        # Nemotron uses mamba_* prefix for SSM params
        prefixed = []
        for pfx in ["mamba"]:
            prefixed.extend("_".join([pfx, k]) for k in keys)
        keys = list(keys) + prefixed
        return Mamba2Model.find_hparam(self, keys, *args, **kwargs)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        """Strip the backbone. prefix from nemotron layer tensor names."""
        name, gen = item
        if name.startswith("backbone."):
            name = name[len("backbone."):]
        # Handle Mamba-Codestral-style naming if present
        if name.startswith(("model.backbone", "model.lm_head")):
            name = name.removeprefix("model.")
        if name.endswith(".dt_bias"):
            name = name.rpartition(".dt_bias")[0] + ".dt_proj.bias"
        return super().filter_tensors((name, gen))

    def get_block_type(self, bid: int) -> str:
        """Return 'mamba', 'moe', or 'attention' for block bid."""
        return self._block_types.get(bid, "mamba")

    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        """
        Dedicated handler for the Nemotron 3.5 Lightning tensor schema.
        Bypasses the Mamba2 + GraniteMoe fallthrough pattern entirely
        because the Nemotron arch mixes three block types (Mamba-2 / MoE /
        Attention) with non-standard tensor names that the fallthrough does
        not cover (per-expert ffn_*_exps.{E}, e_score_correction.bias, latent
        gate split, MTP block, etc.).

        Routing:
          1. Non-block tensors (backbone.embeddings / backbone.norm_f /
             lm_head) — handle directly.
          2. MTP block (mtp.layers.0.*) — mapped to bid = block_count
             (one past the trunk).
          3. Trunk block (backbone.layers.{bid}.*) — dispatched by
             self._block_types[bid] to the appropriate inline handler.
        """

        # ---- 1. Non-block tensors ----
        # base.filter_tensors has already stripped the 'backbone.' prefix
        # from these names, so we see them without the leading 'backbone.'.
        if name == "embeddings.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.TOKEN_EMBD), data_torch)
            return
        if name == "norm_f.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.OUTPUT_NORM), data_torch)
            return
        if name == "lm_head.weight":
            # Model is tied (lm_head == embeddings). The Mamba2 base
            # class handles tied-output detection in its modify_tensors
            # path; for safety, write the output tensor only if it
            # differs from the embedding (we already yielded embeddings
            # earlier so Mamba2's tied check is bypassed here — just
            # write it). The loader will dedupe by tying.
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.OUTPUT), data_torch)
            return

        # ---- 2. MTP block (mtp.layers.0.*) ----
        # The MTP block lives at bid = block_count (one past the trunk),
        # so MTP tensors coexist with the trunk layers in the same
        # GGUF block space.
        if name.startswith("mtp.layers."):
            mtp_bid = self.block_count  # one past the trunk
            yield from self._handle_mtp_tensors(data_torch, name, mtp_bid)
            return

        # ---- 3. Trunk block (backbone.layers.{bid}.*) ----
        # bid was set by base.prepare_tensors from the layer index.
        if bid is None:
            return  # unknown, drop

        # 3a. Block-level input_layernorm → ATTN_NORM
        # For all three block types (mamba / moe / attention), the
        # block input layernorm maps to ATTN_NORM in the GGUF canonical
        # naming (it's the pre-block norm). HF name:
        #   layers.{bid}.norm.weight
        if name.endswith(".norm.weight") and not name.endswith(".mixer.norm.weight"):
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_NORM, bid), data_torch)
            return

        # 3b. Block-type-specific mixer handling
        block_type = self._block_types[bid]
        if block_type == "mamba":
            yield from self._handle_mamba_block(data_torch, name, bid)
        elif block_type == "moe":
            yield from self._handle_moe_block(data_torch, name, bid)
        elif block_type == "attention":
            yield from self._handle_attention_block(data_torch, name, bid)
        return

    # ------------------------------------------------------------------
    # Per-block-type tensor handlers
    # ------------------------------------------------------------------

    def _bf16_to_f32(self, t: Tensor) -> Tensor:
        """Cast BF16 → F32 in-place on a copy. Used for tiny SSM
        state tensors (A_log, D, conv1d, norm) where F32 precision
        matters more than the 2x size cost."""
        if t.dtype == torch.bfloat16:
            return t.to(torch.float32)
        return t

    def _handle_mamba_block(self, data_torch: Tensor, name: str, bid: int) -> Iterable[tuple[str, Tensor]]:
        """Handle a single tensor inside a Mamba-2 block.

        HF name (prefix `layers.{bid}.mixer.` already implicit; name is
        the suffix after `mixer.`):
          A_log            → blk.{bid}.ssm_a (F32)
          D                → blk.{bid}.ssm_d (F32)
          conv1d.weight    → blk.{bid}.ssm_conv1d (F32)
          conv1d.bias      → blk.{bid}.ssm_conv1d.bias (BF16)
          dt_bias          → blk.{bid}.ssm_dt.bias (BF16)
          dt_proj.bias     → blk.{bid}.ssm_dt.bias (BF16)
          in_proj.weight   → split 5-way → ssm_in + ssm_x + ssm_b_norm
                              + ssm_c_norm + ssm_dt
          out_proj.weight  → blk.{bid}.ssm_out
          norm.weight      → blk.{bid}.ssm_norm (F32)
        """
        suffix = name.rsplit(".mixer.", 1)[-1]

        if suffix == "A_log":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_A, bid),
                   self._bf16_to_f32(-torch.exp(data_torch)))
            return
        if suffix == "D":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_D, bid),
                   self._bf16_to_f32(data_torch))
            return
        if suffix == "conv1d.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_CONV1D, bid),
                   self._bf16_to_f32(data_torch))
            return
        if suffix == "conv1d.bias":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_CONV1D, bid, suffix=".bias"),
                   data_torch)
            return
        if suffix == "dt_bias":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_DT, bid, suffix=".bias"),
                   data_torch)
            return
        if suffix == "dt_proj.bias":
            # dt_proj.bias is a bias tensor for the dt projection. The
            # canonical GGUF tensor name for the dt projection's bias
            # is `blk.{bid}.ssm_dt.bias`; we have to write it directly
            # because SSM_DT is registered as a weight only.
            self.gguf_writer.add_tensor(f"blk.{bid}.ssm_dt.bias", data_torch)
            return
        if suffix == "out_proj.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_OUT, bid),
                   data_torch)
            return
        if suffix == "norm.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_NORM, bid),
                   self._bf16_to_f32(data_torch))
            return
        if suffix == "in_proj.weight":
            # Mamba-2 in_proj: [x, z, B, C, dt] stacked along dim 0.
            # Sizes: 2*d_inner + 2*d_state*n_groups + dt_rank.
            # We derive dt_rank from the residual of the actual shape
            # because HF Nemotron 3.5 doesn't expose dt_rank directly.
            d_inner = self.d_inner
            d_state = int(self.find_hparam(["ssm_state_size"]))
            n_groups = self.n_group
            x_size = d_inner
            z_size = d_inner
            b_size = d_state * n_groups
            c_size = d_state * n_groups
            known = x_size + z_size + b_size + c_size
            total = data_torch.shape[0]
            dt_size = int(total) - known
            assert dt_size > 0 and dt_size <= d_state, (
                f"bad in_proj split: total={total}, known={known}, "
                f"d_inner={d_inner}, d_state={d_state}, n_groups={n_groups}")
            x, z, b, c, dt = data_torch.split(
                [x_size, z_size, b_size, c_size, dt_size], dim=0)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_IN, bid), x)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_X, bid), z)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_B_NORM, bid), b)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_C_NORM, bid), c)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_DT, bid), dt)
            return
        # Unknown mamba tensor — drop.
        return

    def _handle_moe_block(self, data_torch: Tensor, name: str, bid: int) -> Iterable[tuple[str, Tensor]]:
        """Handle a single tensor inside a MoE block.

        HF name (suffix after `mixer.`):
          gate.weight                      → split 2-way → ffn_latent_up + ffn_latent_down
          gate.e_score_correction.bias     → ffn_gate_inp.bias
          experts.{E}.up_proj.weight       → ffn_up_exps.{E}.weight (permuted)
          experts.{E}.down_proj.weight     → ffn_down_exps.{E}.weight (permuted)
          shared_experts.up_proj.weight     → ffn_up_shexp.weight (permuted)
          shared_experts.down_proj.weight   → ffn_down_shexp.weight (permuted)
        """
        suffix = name.rsplit(".mixer.", 1)[-1]

        # Latent MoE gate: split into latent_up and latent_down
        if suffix == "gate.weight":
            moe_latent_size = self.find_hparam(["moe_latent_size"], optional=True) \
                or self.find_hparam(["moe_intermediate_size"], optional=True) \
                or 7680
            gate_up, gate_down = data_torch.split(moe_latent_size, dim=0)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.MOE_LATENT_UP, bid),
                   gate_up.t().contiguous())
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.MOE_LATENT_DOWN, bid),
                   gate_down.t().contiguous())
            return
        # Router e_score_correction.bias (DeepSeek-style MoE bias)
        # base.filter_tensors has already renamed `e_score_correction_bias`
        # → `e_score_correction.bias`.
        if suffix == "gate.e_score_correction.bias":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.FFN_GATE_INP, bid, suffix=".bias"),
                   data_torch)
            return
        # Routed experts — per-expert up/down projections
        m = re.search(r"experts\.(\d+)\.(up_proj|down_proj)\.weight$", suffix)
        if m:
            expert_id = int(m.group(1))
            proj_short = m.group(2).split("_")[0]  # "up" or "down"
            tensor_type = gguf.MODEL_TENSOR.FFN_UP_EXP if proj_short == "up" \
                else gguf.MODEL_TENSOR.FFN_DOWN_EXP
            # Permute: PyTorch [out, in] → GGUF [in, out]
            data_perm = data_torch.t().contiguous()
            # FFN_UP_EXP/FFN_DOWN_EXP format string is
            # `blk.{bid}.ffn_{up,down}_exps` (no {eid} placeholder), and
            # the Mamba2 tensor_map can't match per-expert names. Bypass
            # the map by yielding the full name directly; the base
            # pipeline's gguf_writer.add_tensor accepts any unique name.
            self.gguf_writer.add_tensor(
                f"blk.{bid}.ffn_{proj_short}_exps.{expert_id}.weight",
                data_perm)
            return
        # Shared expert (single tensor per block, no expert index)
        m_shared = re.search(r"shared_experts\.(up_proj|down_proj)\.weight$", suffix)
        if m_shared:
            proj_short = m_shared.group(1).split("_")[0]
            tensor_type = gguf.MODEL_TENSOR.FFN_UP_SHEXP if proj_short == "up" \
                else gguf.MODEL_TENSOR.FFN_DOWN_SHEXP
            data_perm = data_torch.t().contiguous()
            yield (self.format_tensor_name(tensor_type, bid), data_perm)
            return
        # Unknown moe tensor — drop.
        return

    def _handle_attention_block(self, data_torch: Tensor, name: str, bid: int) -> Iterable[tuple[str, Tensor]]:
        """Handle a single tensor inside a standard attention block.

        HF name (suffix after `mixer.`):
          q_proj.weight → blk.{bid}.attn_q
          k_proj.weight → blk.{bid}.attn_k
          v_proj.weight → blk.{bid}.attn_v
          o_proj.weight → blk.{bid}.attn_output
        """
        suffix = name.rsplit(".mixer.", 1)[-1]
        if suffix == "q_proj.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_Q, bid), data_torch)
            return
        if suffix == "k_proj.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_K, bid), data_torch)
            return
        if suffix == "v_proj.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_V, bid), data_torch)
            return
        if suffix == "o_proj.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_OUT, bid), data_torch)
            return
        return

    def _handle_mtp_tensors(self, data_torch: Tensor, name: str, mtp_bid: int) -> Iterable[tuple[str, Tensor]]:
        """Handle a single tensor inside the MTP block (mtp.layers.0.*).

        The MTP block has the same internal structure as a single MoE/
        Attention hybrid block (eh_proj → embed-to-hidden projection,
        enorm / hnorm / final_layernorm → normalization layers, then a
        scaled-down MoE mixer block). It maps to the NEXTN_* tensor
        family in GGUF, with the bid set to one past the trunk.
        """
        suffix = name.rsplit("mtp.layers.0.", 1)[-1]

        # eh_proj: embed-to-hidden projection for the MTP next-token
        # prediction. Maps to NEXTN_EH_PROJ.
        if suffix == "eh_proj.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.NEXTN_EH_PROJ, mtp_bid),
                   data_torch)
            return
        # enorm / hnorm: input normalizations for the MTP block.
        if suffix == "enorm.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.NEXTN_ENORM, mtp_bid),
                   data_torch)
            return
        if suffix == "hnorm.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.NEXTN_HNORM, mtp_bid),
                   data_torch)
            return
        # final_layernorm: the post-block norm in the MTP head.
        if suffix == "final_layernorm.weight":
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.NEXTN_SHARED_HEAD_NORM, mtp_bid),
                   data_torch)
            return
        # norm.weight (2 of them): the pre-block input norms. There are
        # 2 of these in the MTP block (one before the MTP mixer, one
        # after). Yield both with distinct names — we use the standard
        # ATTN_NORM / FFN_NORM naming since the MTP block's two input
        # norms are the same architectural position as in a regular
        # transformer block.
        if suffix == "norm.weight":
            # The base pipeline's prepare_tensors only knows the layer
            # index for the *trunk* layers; the MTP bid is outside that
            # range. We write both MTP norms directly with
            # ATTN_NORM and FFN_NORM naming.
            self.gguf_writer.add_tensor(
                f"blk.{mtp_bid}.attn_norm.weight", data_torch)
            return
        if suffix == "mixer.norm.weight":
            # The mixer's internal SSM norm (same as in a Mamba trunk
            # block). Map to SSM_NORM. (The MTP block in this model
            # actually uses MoE, not Mamba, so this case shouldn't be
            # hit, but handle it for safety.)
            yield (self.format_tensor_name(gguf.MODEL_TENSOR.SSM_NORM, mtp_bid),
                   data_torch)
            return
        # The MTP mixer is a small MoE/Attention block. Re-use the
        # standard MoE/Attention handlers, just with the MTP bid.
        if suffix.startswith("mixer."):
            mixer_suffix = "mixer." + suffix[len("mixer."):]
            # Wrap the suffix in a fake `layers.{bid}.mixer.X` so the
            # helpers can be reused. Easiest is to call them with the
            # MTP bid directly.
            # Detect MoE vs Attention by presence of gate/experts.
            if "experts." in suffix or "shared_experts." in suffix or "gate." in suffix:
                yield from self._handle_moe_block(data_torch,
                    "layers.0." + mixer_suffix, mtp_bid)
            elif any(p in suffix for p in ("q_proj.", "k_proj.", "v_proj.", "o_proj.")):
                yield from self._handle_attention_block(data_torch,
                    "layers.0." + mixer_suffix, mtp_bid)
            return
        return

    def _permute_qkv_for_gguf(self, q_name, k_name, v_name, q, k, v, n_head, n_embd_head_k):
              mixer.{A_log,B,C,dt_proj} → ssm_{A,B,D,dt}
              input_layernorm      → ssm_norm

          - MoE block (bid in moe_layers):
              mixer.gate           → split → ffn_latent_up + ffn_latent_down
              mixer.experts.{e}.up/down_proj → ffn_up_exps.{e} / ffn_down_exps.{e}
              mixer.shared_experts.{up,down}_proj → ffn_up_shexp / ffn_down_shexp
              input_layernorm      → ffn_norm

          - Attention block (bid in attn_layers):
              mixer.self_attn.q/k/v_proj → attn_q/k/v
              mixer.self_attn.o_proj     → attn_output
              input_layernorm           → attn_norm
        """
        if bid is None:
            # Non-block tensors: rewrite HF names to GGUF canonical before
            # forwarding to Mamba2Model.modify_tensors, whose tensor_map
            # expects the canonical names. The HF Nemotron 3.5 layout uses
            # 'backbone.embeddings.weight' / 'backbone.norm_f.weight' /
            # 'lm_head.weight' (and the model is tied, so lm_head == embeddings).
            # Note: NemotronHModel.filter_tensors already strips the 'backbone.'
            # prefix, so by the time we see these they are unprefixed.
            if name == "embeddings.weight":
                name = "token_embd.weight"
            elif name == "norm_f.weight":
                name = "output_norm.weight"
            elif name == "lm_head.weight":
                name = "output.weight"
            yield from super().modify_tensors(data_torch, name, bid)
            return

        block_type = self.get_block_type(bid)

        # ---- Mamba block ----
        if block_type == "mamba":
            if name.endswith(".mixer.in_proj.weight"):
                # Mamba2 in_proj: [x, z, B, C, dt] split along dim=0
                # x: d_inner, z: d_inner, B: d_state*n_groups, C: d_state*n_groups, dt: dt_rank
                d_inner = self.d_inner
                d_model = self.d_model
                n_groups = self.n_group
                d_state = self.find_hparam(["ssm_state_size"])  # state_size

                # Some HF Nemotron 3.5 builds don't expose a separate
                # ssm_dt/dt_rank field in config.json, so infer dt_rank from
                # the in_proj shape: total - (2*d_inner + 2*d_state*n_groups).
                # For the lightning config (d_inner=4096, d_state=128,
                # n_groups=8) this yields dt_rank=64, not 128 (which is what
                # ssm_state_size // n_group would give when n_group=1).
                x_size = d_inner
                z_size = d_inner
                b_size = d_state * n_groups
                c_size = d_state * n_groups
                known = x_size + z_size + b_size + c_size
                total = data_torch.shape[0] if hasattr(data_torch, 'shape') else None
                # Resolve eager shape for lazy tensors.
                if total is None or total == 0:
                    try:
                        total = data_torch.to_eager().shape[0] \
                            if hasattr(data_torch, 'to_eager') \
                            else int(data_torch.shape[0])
                    except Exception:
                        pass
                dt_size = int(total) - known if total else 0
                if dt_size <= 0 or dt_size > d_state:
                    # Fall back to a sensible default if the shape inference
                    # doesn't yield a positive dt_size. Keep this conservative
                    # so the split still matches the actual tensor size.
                    dt_size = max(1, d_state // 2)

                # Shape: [x+z+B+C+dt, d_model] = [2*d_inner + 2*d_state*n_groups + dt_rank, d_model]
                # split along dim=0 (the first axis is the feature dim, not batch)
                # For weight matrix: [out_features, in_features]
                # in_proj weight: [x+z+B+C+dt, d_model]
                x_size = d_inner
                z_size = d_inner
                b_size = d_state * n_groups
                c_size = d_state * n_groups
                # dt_size is computed above from the in_proj shape; if shape
                # inference was unavailable, the fallback set it to a
                # sensible default, so just keep what's already in dt_size.

                parts = [x_size, z_size, b_size, c_size, dt_size]
                splits = data_torch.split(parts, dim=0)
                x_part, z_part, b_part, c_part, dt_part = splits

                # x → ssm_in, z → ssm_x
                yield from Mamba2Model.modify_tensors(
                    self, x_part,
                    self.format_tensor_name(gguf.MODEL_TENSOR.SSM_IN, bid), bid)
                yield from Mamba2Model.modify_tensors(
                    self, z_part,
                    self.format_tensor_name(gguf.MODEL_TENSOR.SSM_X, bid), bid)
                # B, C, DT: write directly to gguf_writer with GGUF canonical names.
                # B → ssm_b_norm, C → ssm_c_norm, DT → ssm_dt (all in NEMOTRON_H_MOE tensor list)
                b_gguf_name = self.format_tensor_name(gguf.MODEL_TENSOR.SSM_B_NORM, bid)
                c_gguf_name = self.format_tensor_name(gguf.MODEL_TENSOR.SSM_C_NORM, bid)
                dt_gguf_name = self.format_tensor_name(gguf.MODEL_TENSOR.SSM_DT, bid)
                self.gguf_writer.add_tensor(b_gguf_name, b_part)
                self.gguf_writer.add_tensor(c_gguf_name, c_part)
                self.gguf_writer.add_tensor(dt_gguf_name, dt_part)
                return

            elif name.endswith(".mixer.out_proj.weight"):
                yield from Mamba2Model.modify_tensors(
                    self, data_torch,
                    self.format_tensor_name(gguf.MODEL_TENSOR.SSM_OUT, bid), bid)
                return

            elif ".mixer." in name:
                # Individual SSM tensors: A_log, B, C, D (skip), dt_proj, dt_bias, conv1d, norm
                # Strip ".mixer." → standard SSM tensor name
                # e.g. "layers.0.mixer.A_log" → blk.0.ssm_a
                base = name.rsplit(".mixer.", 1)
                if len(base) == 2:
                    suffix = base[1]
                    # dt_bias, conv1d.bias, and dt_proj.bias are 1-D biases,
                    # not weights. NEMOTRON_H_MOE registers SSM_DT/SSM_CONV1D
                    # as weights only, so write the bias variants directly
                    # with the canonical .bias suffix. The GGUF writer accepts
                    # any tensor name once the model arch is set and now
                    # handles BF16 directly (see gguf_writer.add_tensor_info +
                    # add_tensor), so we can pass the torch tensor as-is.
                    if suffix == "dt_bias":
                        self.gguf_writer.add_tensor(
                            f"blk.{bid}.ssm_dt.bias", data_torch)
                        return
                    if suffix == "conv1d.bias":
                        self.gguf_writer.add_tensor(
                            f"blk.{bid}.ssm_conv1d.bias", data_torch)
                        return
                    if suffix == "dt_proj.bias":
                        self.gguf_writer.add_tensor(
                            f"blk.{bid}.ssm_dt.bias", data_torch)
                        return
                    ssm_map = {
                        "A_log":         gguf.MODEL_TENSOR.SSM_A,
                        "D":             gguf.MODEL_TENSOR.SSM_D,   # skip connection (Mamba-2 D)
                        "dt_proj.weight": gguf.MODEL_TENSOR.SSM_DT,
                        "conv1d.weight":  gguf.MODEL_TENSOR.SSM_CONV1D,
                        "norm.weight":    gguf.MODEL_TENSOR.SSM_NORM,
                    }
                    for suffix_pat, tensor_type in ssm_map.items():
                        if suffix == suffix_pat:
                            tensor_name = self.format_tensor_name(tensor_type, bid)
                            yield from Mamba2Model.modify_tensors(self, data_torch, tensor_name, bid)
                            return
                    # layernorm goes to ssm_norm
                    if "layernorm" in suffix or "norm" in suffix:
                        tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.SSM_NORM, bid)
                        yield from Mamba2Model.modify_tensors(self, data_torch, tensor_name, bid)
                        return

            # Mamba block also has a block-level input_layernorm
            # (HF: layers.{bid}.norm.weight) → GGUF: attn_norm
            if name.endswith(f".norm.weight") and not ".mixer." in name:
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_NORM, bid)
                yield from Mamba2Model.modify_tensors(self, data_torch, tensor_name, bid)
                return

            # Fall through to parent
            yield from Mamba2Model.modify_tensors(self, data_torch, name, bid)
            return

        # ---- MoE block ----
        if block_type == "moe":
            # Latent gate: mixer.gate.weight [d_model, moe_latent_size]
            # Maps to ffn_latent_up + ffn_latent_down split
            if name.endswith(".mixer.gate.weight"):
                moe_latent_size = self.find_hparam(["moe_latent_size"], optional=True) or (
                    self.find_hparam(["moe_intermediate_size"], optional=True) or 7680)
                gate = data_torch.split(moe_latent_size, dim=0)
                gate_up = gate[0]    # [moe_latent_size, d_model]
                gate_down = gate[1]  # [moe_latent_size, d_model] → goes to ffn_latent_down

                # Swap to [d_model, moe_latent_size] for GGUF convention
                gate_up_t = gate_up.t()    # [d_model, moe_latent_size]
                gate_down_t = gate_down.t()  # [d_model, moe_latent_size]

                yield from ModelBase.modify_tensors(
                    self,
                    gate_up_t,
                    self.format_tensor_name(gguf.MODEL_TENSOR.MOE_LATENT_UP, bid), bid)
                yield from ModelBase.modify_tensors(
                    self,
                    gate_down_t,
                    self.format_tensor_name(gguf.MODEL_TENSOR.MOE_LATENT_DOWN, bid), bid)
                return

            # Routed experts: mixer.experts.{e}.{up,down}_proj.
            # Use re.search because the tensor name has a 'layers.{bid}.' prefix
            # that filter_tensors does NOT strip (only 'backbone.' is stripped).
            m = re.search(r"\.mixer\.experts\.(\d+)\.(up_proj|down_proj)\.weight$", name)
            if m:
                expert_id = int(m.group(1))
                proj_type = m.group(2)  # "up_proj" or "down_proj"
                proj_short = "up" if proj_type == "up_proj" else "down"
                # Permute: PyTorch [out, in] → GGUF [in, out]
                data_perm = data_torch.t().contiguous()
                # Write directly: the FFN_UP_EXP/FFN_DOWN_EXP format string
                # in constants.py is `blk.{bid}.ffn_{up,down}_exps` (no {eid}
                # placeholder), and the Mamba2 tensor_map can't match the
                # per-expert tensor name `blk.{bid}.ffn_*_exps.{eid}.weight`.
                # Bypass map_tensor_name and write the canonical name
                # directly; the GGUF writer accepts any tensor name once
                # the model arch is set, and the loader side (llama.cpp /
                # tessera) treats `blk.X.ffn_*_exps.E.weight` as a valid
                # per-expert tensor by suffix match.
                self.gguf_writer.add_tensor(
                    f"blk.{bid}.ffn_{proj_short}_exps.{expert_id}.weight",
                    data_perm)
                return

            # Shared expert: mixer.shared_experts.{up,down}_proj.
            # Use re.search for the same reason as the routed-expert regex
            # (tensor name has a 'layers.{bid}.' prefix).
            m_shared = re.search(r"\.mixer\.shared_experts\.(up_proj|down_proj)\.weight$", name)
            if m_shared:
                proj_type = m_shared.group(1)
                tensor_type = (
                    gguf.MODEL_TENSOR.FFN_UP_SHEXP
                    if proj_type == "up_proj"
                    else gguf.MODEL_TENSOR.FFN_DOWN_SHEXP
                )
                data_perm = data_torch.t().contiguous()
                tensor_name = self.format_tensor_name(tensor_type, bid)
                yield from ModelBase.modify_tensors(self, data_perm, tensor_name, bid)
                return

            # Expert gate (router): mixer.gate.weight is handled above
            # Expert probs: ffn_exp_probs_b
            if name.endswith(".mixer.expert_scores.weight") or name.endswith(".mixer.expert_probs_b.weight"):
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.FFN_EXP_PROBS_B, bid)
                yield from ModelBase.modify_tensors(self, data_torch, tensor_name, bid)
                return

            # e_score_correction.bias — DeepSeek-style MoE router bias.
            # base.py filter_tensors renames `e_score_correction_bias` →
            # `e_score_correction.bias`; map the renamed tensor to the
            # FFN_GATE_INP bias variant (blk.{bid}.ffn_gate_inp.bias).
            if name.endswith(".mixer.gate.e_score_correction.bias"):
                tensor_name = self.format_tensor_name(
                    gguf.MODEL_TENSOR.FFN_GATE_INP, bid, suffix=".bias")
                yield from ModelBase.modify_tensors(self, data_torch, tensor_name, bid)
                return

            # MoE block RMS norm → ffn_norm
            if "norm" in name.lower() or "layernorm" in name.lower():
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.FFN_NORM, bid)
                yield from ModelBase.modify_tensors(self, data_torch, tensor_name, bid)
                return

            # Fall through to GraniteMoeModel for any other MoE tensors
            yield from GraniteMoeModel.modify_tensors(self, data_torch, name, bid)
            return

        # ---- Attention block ----
        if block_type == "attention":
            # self_attn q/k/v/o projections
            if name.endswith(".mixer.self_attn.q_proj.weight"):
                data_perm = self._permute(data_torch, self.hparams["num_attention_heads"],
                                          self.hparams.get("head_dim", 128))
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_Q, bid)
                yield from ModelBase.modify_tensors(self, data_perm, tensor_name, bid)
                return
            if name.endswith(".mixer.self_attn.k_proj.weight"):
                data_perm = self._permute(data_torch, self.hparams["num_attention_heads"],
                                          self.hparams.get("head_dim", 128))
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_K, bid)
                yield from ModelBase.modify_tensors(self, data_perm, tensor_name, bid)
                return
            if name.endswith(".mixer.self_attn.v_proj.weight"):
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_V, bid)
                yield from ModelBase.modify_tensors(self, data_torch.t().contiguous(), tensor_name, bid)
                return
            if name.endswith(".mixer.self_attn.o_proj.weight"):
                data_perm = self._permute(data_torch, self.hparams["num_attention_heads"],
                                          self.hparams.get("head_dim", 128))
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_OUTPUT, bid)
                yield from ModelBase.modify_tensors(self, data_perm, tensor_name, bid)
                return

            # Attention block RMS norm
            if "norm" in name.lower() or "layernorm" in name.lower():
                tensor_name = self.format_tensor_name(gguf.MODEL_TENSOR.ATTN_NORM, bid)
                yield from ModelBase.modify_tensors(self, data_torch, tensor_name, bid)
                return

            yield from ModelBase.modify_tensors(self, data_torch, name, bid)
            return

        yield from super().modify_tensors(data_torch, name, bid)

    def _permute(self, w: Tensor, n_heads: int, head_dim: int) -> Tensor:
        """Permute weight for grouped-query attention: [n_heads*head_dim, n_kv_heads*head_dim] → [n_kv, head_dim, n_heads, head_dim]."""
        n_kv = self.find_hparam(["num_key_value_heads"])
        q_per_head = w.shape[0] // n_heads
        kv_per_head = w.shape[0] // n_kv if n_kv else q_per_head

        if n_heads == n_kv or n_kv == 0:
            return w.t().contiguous()

        # reshape: [q_per_head*n_heads + kv_per_head*n_kv, dim] → separate q and kv
        q_part = w[:n_heads * q_per_head]
        kv_part = w[n_heads * q_per_head:]
        q_reshaped = q_part.view(n_heads, q_per_head, -1)
        kv_reshaped = kv_part.view(n_kv, kv_per_head, -1) if n_kv > 0 else q_reshaped

        # kv: [n_kv, kv_per_head, dim] → [n_kv, dim, kv_per_head]
        kv_perm = kv_reshaped.permute(0, 2, 1).contiguous()
        result = torch.cat([q_reshaped.view(-1, q_per_head), kv_perm.view(-1, kv_per_head)], dim=0)
        return result.t().contiguous()

    def set_gguf_parameters(self):
        # Run GraniteModel (LlamaModel parent) to set base Llama parameters
        GraniteModel.set_gguf_parameters(self)

        # --- SSM / Mamba2 parameters ---
        rms_norm_eps = self.find_hparam(["rms_norm_eps", "layer_norm_epsilon"], optional=True) or 1e-5
        self.gguf_writer.add_layer_norm_rms_eps(rms_norm_eps)
        self.gguf_writer.add_ssm_conv_kernel(self.find_hparam(["conv_kernel", "d_conv"], optional=True) or 4)
        self.gguf_writer.add_ssm_state_size(self.find_hparam(["ssm_state_size"]))
        self.gguf_writer.add_ssm_inner_size(self.d_inner)
        self.gguf_writer.add_ssm_time_step_rank(
            self.find_hparam(["ssm_state_size"]) // self.n_group)
        self.gguf_writer.add_ssm_group_count(self.n_group)

        # --- MoE parameters ---
        n_routed = self.find_hparam(["n_routed_experts"], optional=True) or 0
        n_shared = self.find_hparam(["n_shared_experts"], optional=True) or 0
        moe_intermediate = self.find_hparam(["moe_intermediate_size"], optional=True) or 0
        moe_shared_intermediate = self.find_hparam(["moe_shared_expert_intermediate_size"], optional=True) or 0

        if n_routed > 0:
            self.gguf_writer.add_n_routed_experts(n_routed)
        if n_shared > 0:
            self.gguf_writer.add_expert_shared_count(n_shared)

        # moe_latent_size is written via MOE_LATENT_UP/DOWN tensor shapes
        # num_experts_per_tok: top-k routing
        num_experts_per_tok = self.find_hparam(["num_experts_per_tok"], optional=True) or 0
        if num_experts_per_tok > 0:
            self.gguf_writer.add_expert_num_experts_per_token(num_experts_per_tok)

        # --- Attention parameters ---
        head_count_kv = self.find_hparam(["num_key_value_heads"])
        attn_layers = [bid for bid, t in self._block_types.items() if t == "attention"]
        head_count_kv_vec = [
            head_count_kv if bid in attn_layers else 0
            for bid in range(self.block_count)
        ]
        self.gguf_writer.add_head_count_kv(head_count_kv_vec)

        # --- RoPE ---
        rope_theta = self.find_hparam(["rope_theta"], optional=True) or 10000.0
        rope_max_pos_emb = self.find_hparam(["max_position_embeddings"], optional=True) or 4096
        rope_factor = self.hparams.get("rope_parameters", {}).get("factor")
        rope_dim = self.find_hparam(["partial_rotary_factor"], optional=True) or 1.0
        if rope_factor:
            self.gguf_writer.add_rope_scaling(
                {"type": "yarn,long", "factor": rope_factor,
                 "original_max_pos_emb": rope_max_pos_emb, "original_context_factor": rope_factor})
        elif rope_dim and rope_dim < 1.0:
            self.gguf_writer.add_rope_dimension_count(int(self.find_hparam(["hidden_size"]) * rope_dim))
        self.gguf_writer.add_rope_freq_base(rope_theta)
        # rope_scaling_finetuned=false → rope applied only to attention layers
        self.gguf_writer.add_rope_scaling_finetuned(False)

        # --- Mamba cache dtype ---
        ssm_cache_dtype = self.hparams.get("mamba_ssm_cache_dtype", "float32")
        self.gguf_writer.add_ssm_cache_dtype(ssm_cache_dtype)

        # --- Chunk size (for SSM sequential processing) ---
        chunk_size = self.find_hparam(["chunk_size"], optional=True) or 128
        self.gguf_writer.add_ssm_chunk_size(chunk_size)

        # --- File type ---
        self.gguf_writer.add_file_type(self.ftype)

    def set_vocab(self):
        # Use Qwen tokenizer (same vocab size 131072, same tokenizer family)
        TextModel.set_vocab(self)


# ---------------------------------------------------------------------------
# Nemotron HDFlash — DFlash draft model for Nemotron
# ---------------------------------------------------------------------------

@ModelBase.register("NemotronHDFlashModel")
class NemotronHDFlashModel(Mamba2Model):
    """
    DFlash draft model for Nemotron-3.5-Lightning.

    Architecture:
      - 6 layers: dense MLP + full-sequence non-causal GQA attention
      - target_layer_ids = [1, 5, 19, 29, 41, 51] from trunk
      - Uses tokenizer from target model (via --target-model-dir)
      - Has embed_tokens (standalone loading), no lm_head

    Tensor naming: backbone.layers.* (same prefix as trunk, handled in filter_tensors)
    """

    model_arch = gguf.MODEL_ARCH.DFLASH

    def __init__(self, *args, **kwargs):
        hparams = kwargs.pop("hparams", None)
        if hparams is None:
            dir_model = args[0] if args else kwargs.get("dir_model")
            if dir_model is None:
                raise ValueError("NemotronHDFlashModel requires dir_model or explicit hparams")
            with open(Path(dir_model) / "config.json", "r", encoding="utf-8") as f:
                hparams = json.load(f)
        super().__init__(*args, hparams=hparams, **kwargs)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, gen = item
        # Strip backbone. prefix (same as trunk)
        if name.startswith("backbone."):
            name = name[len("backbone."):]
        return super().filter_tensors((name, gen))

    def set_vocab(self):
        # Use trunk tokenizer (via --target-model-dir in caller)
        if self.target_model_dir is None:
            raise ValueError(
                "Nemotron HDFlash draft model requires --target-model-dir "
                "to locate the tokenizer ( NemotronHForCausalLM trunk)")
        original_dir = self.dir_model
        self.dir_model = self.target_model_dir
        TextModel.set_vocab(self)
        self.dir_model = original_dir

        # Register mask token
        mask_token_id = self.hparams.get("mask_token_id")
        if mask_token_id is not None:
            self.gguf_writer.add_mask_token_id(mask_token_id)

    def generate_extra_tensors(self):
        # Inject embed_tokens from target model for standalone loading
        if self.target_model_dir is None:
            return
        import glob
        for st_path in sorted(glob.glob(str(self.target_model_dir / "*.safetensors"))):
            from safetensors.torch import safe_open
            with safe_open(st_path, framework="pt") as f:
                for key in f.keys():
                    if key.endswith("embed_tokens.weight"):
                        logger.info(f"NemotronHDFlash: injecting {key} from target model")
                        yield "model.embed_tokens.weight", f.get_tensor(key)
                        return

    def set_gguf_parameters(self):
        GraniteModel.set_gguf_parameters(self)

        # DFlash parameters
        dflash_config = self.hparams.get("dflash_config", {})
        block_size = self.hparams.get("block_size", 16)
        self.gguf_writer.add_block_size(block_size)

        target_layer_ids = dflash_config.get("target_layer_ids", [])
        if target_layer_ids:
            # Extract layers are 1-indexed in dflash_config
            extract_layer_ids = [i + 1 for i in target_layer_ids]
            self.gguf_writer.add_target_layers(extract_layer_ids)

        use_sliding_window = dflash_config.get("use_swa", False)
        if use_sliding_window:
            sliding_window = self.hparams.get("sliding_window")
            self.gguf_writer.add_sliding_window(sliding_window or 0)
            self.gguf_writer.add_sliding_window_pattern(False)

        # RoPE for attention layers
        rope_params = self.hparams.get("rope_parameters", {})
        rope_factor = rope_params.get("factor")
        rope_theta = rope_params.get("rope_theta", 10000.0)
        rope_max_pos = self.find_hparam(["max_position_embeddings"], optional=True) or 1048576
        if rope_factor:
            self.gguf_writer.add_rope_scaling(
                {"type": "yarn,long", "factor": rope_factor,
                 "original_max_pos_emb": rope_max_pos,
                 "original_context_factor": rope_factor})
        self.gguf_writer.add_rope_freq_base(rope_theta)


# ---------------------------------------------------------------------------
# NemotronH DSpark — semi-autoregressive drafter
# ---------------------------------------------------------------------------

@ModelBase.register("NemotronHDSparkModel")
class NemotronHDSparkModel(NemotronHDFlashModel):
    """
    DSpark draft model for Nemotron-3.5-Lightning.

    Architecture: same as NemotronHDFlashModel but with causal sliding-window
    attention and a Markov head. target_layer_ids and block_size are inherited
    from the dspark_config.
    """

    model_arch = gguf.MODEL_ARCH.DFLASH

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Normalize flat dspark params into dflash_config shape
        self.hparams.setdefault("dflash_config", {
            k: self.hparams[k] for k in ("target_layer_ids", "mask_token_id")
            if k in self.hparams
        })

    def set_gguf_parameters(self):
        NemotronHDFlashModel.set_gguf_parameters(self)
        # DSpark adds a Markov head; GGUF writer doesn't need extra metadata
        # (the dspark-specific parameters are in the checkpoint weights)
