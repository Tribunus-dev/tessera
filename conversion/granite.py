from __future__ import annotations

import re
from typing import Any, Callable, Iterable, TYPE_CHECKING

import torch

if TYPE_CHECKING:
    from torch import Tensor

from .base import MmprojModel, ModelBase, gguf, logger

from .llama import LlamaModel
from .mamba import Mamba2Model


@ModelBase.register("GraniteForCausalLM")
class GraniteModel(LlamaModel):
    """Conversion for IBM's GraniteForCausalLM"""
    model_arch = gguf.MODEL_ARCH.GRANITE

    def set_gguf_parameters(self):
        """Granite uses standard llama parameters with the following differences:

        - No head_dim support
        - New multiplier params:
            - attention_scale
            - embedding_scale
            - residual_scale
        - logits_scaling
        """
        if head_dim := self.hparams.pop("head_dim", None):
            logger.warning("Ignoring head_dim (%s) from config for Granite", head_dim)
        super().set_gguf_parameters()
        # NOTE: Convert _multiplier params to _scale params for naming
        #   consistency
        if attention_scale := self.hparams.get("attention_multiplier"):
            self.gguf_writer.add_attention_scale(attention_scale)
            logger.info("gguf: (granite) attention_scale = %s", attention_scale)
        if embedding_scale := self.hparams.get("embedding_multiplier"):
            self.gguf_writer.add_embedding_scale(embedding_scale)
            logger.info("gguf: (granite) embedding_scale = %s", embedding_scale)
        if residual_scale := self.hparams.get("residual_multiplier"):
            self.gguf_writer.add_residual_scale(residual_scale)
            logger.info("gguf: (granite) residual_scale = %s", residual_scale)
        if logits_scale := self.hparams.get("logits_scaling"):
            self.gguf_writer.add_logit_scale(logits_scale)
            logger.info("gguf: (granite) logits_scale = %s", logits_scale)

        # If being used as the base for Granite4 Vision, add deepstack_layer_arr.
        # Guard: only run for TEXT models, not for MmprojModel components embedded in the
        # same GGUF. MmprojModel calls GraniteModel.set_gguf_parameters() via the
        # inheritance chain, but it should not write deepstack params (the TEXT model does).
        has_spatial = self.hparams.get("spatial_target_layers")
        has_deepstack = self.hparams.get("deepstack_layer_map")
        is_mmproj = isinstance(self, MmprojModel)
        if not is_mmproj and (has_spatial or has_deepstack):
            normalized_projector_map = Granite4VisionMmprojModel.get_normalized_projector_map(self.hparams)
            deepstack_mapping_arr = [-1 for _ in range(self.block_count)]
            n_layerwise = len(self.hparams.get("deepstack_layer_map", []))
            # Layerwise projectors (proj_idx 1..n_layerwise) use deepstack indices 0..n_layerwise-1.
            # Spatial projectors use deepstack indices n_layerwise..n_proj-2 (same LLM layer, overriding).
            for proj_idx, (_, llm_layer, proj_type, type_idx) in enumerate(normalized_projector_map):
                # ds_idx for layerwise: proj_idx (sorted order, 0..n_layerwise-1).
                # ds_idx for spatial: type_idx + n_layerwise (spatial_idx 0..n_spatial-1 maps to 4..7).
                ds_idx = (type_idx + n_layerwise) if proj_type == "spatial" else proj_idx
                deepstack_mapping_arr[llm_layer] = ds_idx
            non_sentinel = [v for v in deepstack_mapping_arr if v >= 0]
            n_deepstack_layers = (max(non_sentinel) + 1) if non_sentinel else 1
            self.gguf_writer.add_deepstack_mapping(deepstack_mapping_arr)
            self.gguf_writer.add_num_deepstack_layers(n_deepstack_layers)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, gen = item
        # Skip multimodal tensors
        if (
            name.startswith(("encoder."))
            or "image_" in name
            or "layerwise_projectors" in name
            or "spatial_projectors" in name
        ):
            return
        return super().filter_tensors(item)


@ModelBase.register("GraniteMoeForCausalLM", "GraniteMoeSharedForCausalLM")
class GraniteMoeModel(GraniteModel):
    """Conversion for IBM's GraniteMoeForCausalLM"""
    model_arch = gguf.MODEL_ARCH.GRANITE_MOE

    def set_gguf_parameters(self):
        """GraniteMoeShared uses GraniteMoe parameters plus the following:
        - shared_intermediate_size
        """
        super().set_gguf_parameters()
        if shared_feed_forward_length := self.hparams.get("shared_intermediate_size"):
            self.gguf_writer.add_expert_shared_feed_forward_length(shared_feed_forward_length)
            logger.info("gguf: (granitemoeshared) shared_feed_forward_length = %s", shared_feed_forward_length)

    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        """In modeling_granitemoe, the JetMoe implementation of parallel experts
        is used. This essentially merges w1 and w3 into a single tensor with 2x
        the hidden size that is then split during forward. To keep compatibility
        with existing mixtral support, we pull them apart here.
        """

        if name.endswith("block_sparse_moe.input_linear.weight"):
            ffn_dim = self.hparams["intermediate_size"]
            assert data_torch.shape[-2] == 2 * ffn_dim, "Merged FFN tensor size must be 2 * intermediate_size"
            gate, up = data_torch.split(ffn_dim, dim=-2)
            yield from ModelBase.modify_tensors(self, gate, self.format_tensor_name(gguf.MODEL_TENSOR.FFN_GATE_EXP, bid), bid)
            yield from ModelBase.modify_tensors(self, up, self.format_tensor_name(gguf.MODEL_TENSOR.FFN_UP_EXP, bid), bid)
            return

        has_experts = bool(self.hparams.get('num_local_experts'))

        if name.endswith("shared_mlp.input_linear.weight"):
            ffn_dim = self.hparams["shared_intermediate_size"]
            assert data_torch.shape[-2] == 2 * ffn_dim, "Merged FFN tensor size must be 2 * shared_intermediate_size"
            gate, up = data_torch.split(ffn_dim, dim=-2)
            if has_experts:
                yield from ModelBase.modify_tensors(self, gate,self.format_tensor_name(gguf.MODEL_TENSOR.FFN_GATE_SHEXP, bid), bid)
                yield from ModelBase.modify_tensors(self, up, self.format_tensor_name(gguf.MODEL_TENSOR.FFN_UP_SHEXP, bid), bid)
                return
            yield from ModelBase.modify_tensors(self, gate, self.format_tensor_name(gguf.MODEL_TENSOR.FFN_GATE, bid), bid)
            yield from ModelBase.modify_tensors(self, up, self.format_tensor_name(gguf.MODEL_TENSOR.FFN_UP, bid), bid)
            return

        if not has_experts and name.endswith("shared_mlp.output_linear.weight"):
            yield from ModelBase.modify_tensors(self, data_torch, self.format_tensor_name(gguf.MODEL_TENSOR.FFN_DOWN, bid), bid)
            return

        yield from super().modify_tensors(data_torch, name, bid)


@ModelBase.register("GraniteMoeHybridForCausalLM", "BambaForCausalLM")
class GraniteHybridModel(Mamba2Model, GraniteMoeModel):
    """GraniteHybrid is a hybrid SSM + Attention model that uses Mamba2 SSM
    layers and optionally uses MoE w/ a shared expert"""
    model_arch = gguf.MODEL_ARCH.GRANITE_HYBRID
    undo_permute = True

    def __init__(self, *args, **kwargs):

        # Hybrid mamba models use a prefix for the mamba-specific params.
        # TODO: Extend this if the prefix(es) need to be configurable
        self.hparam_prefixes = ["mamba"]

        super().__init__(*args, **kwargs)

        # Lists of which layers use ssm vs attention
        self._attn_layers = self.get_attn_layers()
        self._ssm_layers = [
            i for i in range(self.block_count)
            if i not in self._attn_layers
        ]

        # There are some models in this family that are non-hybrid, but keep the
        # same parent class by setting all layers to "attention." If this is the
        # case, the model architecture needs to be updated to a standard
        # "granite" or "granitemoe" model
        if not self._ssm_layers:
            has_experts = self.find_hparam(["num_experts_per_tok", "num_experts_per_token"], optional=True)
            new_arch = (
                gguf.MODEL_ARCH.GRANITE_MOE
                if has_experts else
                gguf.MODEL_ARCH.GRANITE
            )
            self.model_arch = new_arch
            self.gguf_writer.arch = gguf.MODEL_ARCH_NAMES[new_arch]
            self.gguf_writer.add_architecture()

        # n_group and d_inner are used during reshape_tensors for mamba2
        # NOTE: Explicitly include hparam prefix prefix for d_model to
        #   disambiguate with top-level head_dim
        # NOTE 2: If needed for future models, this can be isolated in a method
        #   to separate the prefix setting and the keys used
        self.d_model = self.find_hparam([f"{self.hparam_prefixes[0]}_head_dim", "hidden_size", "d_model"])
        self.n_group = self.find_hparam(["n_groups", "num_groups"])
        self.d_inner = self.find_hparam(["expand", "num_heads"]) * self.d_model

    def get_attn_layers(self):
        # Explicit list of layer type names
        if layer_types := self.hparams.get("layer_types"):
            return [
                i for i, typ in enumerate(layer_types)
                if typ == "attention"
            ]

        # Layer types indicated by index or period
        attn_layers = self.hparams.get("attn_layer_indices", [])
        if not attn_layers:
            attn_period = self.hparams.get("attn_layer_period")
            assert attn_period, "Didn't find attn_layer_indices or attn_layer_period"
            attn_offset = self.hparams.get("attn_layer_offset")
            assert attn_offset is not None, "No attention layer offset set with attn_layer_period"
            attn_layers = [
                i for i in range(self.block_count)
                if i % attn_period == attn_offset
            ]
        return attn_layers

    def find_hparam(self, keys: Iterable[str], *args, **kwargs) -> Any:
        prefixed = []
        for pfx in self.hparam_prefixes:
            prefixed.extend(
                "_".join([pfx, k])
                for k in keys
            )
        keys = list(keys) + prefixed
        return Mamba2Model.find_hparam(self, keys, *args, **kwargs)

    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        if (
            name.endswith("block_sparse_moe.input_linear.weight")
            or "shared_mlp" in name
        ):
            yield from GraniteMoeModel.modify_tensors(self, data_torch, name, bid)
            return

        # Determine whether this is a mamba layer or an attention layer
        if bid in self._ssm_layers:
            yield from Mamba2Model.modify_tensors(self, data_torch, name, bid)
            return
        elif bid in self._attn_layers:
            yield from GraniteMoeModel.modify_tensors(self, data_torch, name, bid)
            return
        yield from ModelBase.modify_tensors(self, data_torch, name, bid)

    def set_gguf_parameters(self):
        """This method merges params from both parents and some that are
        specific to this model. The result is some duplication of how the params
        get set. The following warnings are expected during conversion:

        WARNING:Duplicated key name 'granitehybrid.attention.head_count_kv'
        WARNING:Duplicated key name 'granitehybrid.context_length'
        """
        GraniteMoeModel.set_gguf_parameters(self)

        ## Mamba mixer params ##
        self.gguf_writer.add_ssm_conv_kernel(self.find_hparam(["conv_kernel", "d_conv"]))
        self.gguf_writer.add_ssm_state_size(self.find_hparam(["state_size", "d_state", "state_dim", "ssm_state_size"]))
        self.gguf_writer.add_ssm_group_count(self.n_group)
        self.gguf_writer.add_ssm_inner_size(self.d_inner)
        # NOTE: The mamba_dt_rank is _not_ the right field for how this is used
        #   in llama.cpp
        self.gguf_writer.add_ssm_time_step_rank(self.find_hparam(["n_heads", "num_heads"]))

        ## Attention params ##
        head_count_kv = self.find_hparam(["num_key_value_heads", "n_head_kv"])
        head_count_kv_vec = [
            head_count_kv if i in self._attn_layers else 0 for i in range(self.block_count)
        ]
        if rope_dim := self.hparams.get("attn_rotary_emb"):
            self.gguf_writer.add_rope_dimension_count(rope_dim)
        self.gguf_writer.add_head_count_kv(head_count_kv_vec)

        ## If Bamba or non-hybrid, use rope, otherwise don't
        use_rope = (
            "BambaForCausalLM" in self.hparams["architectures"]
            or not self._ssm_layers
        )
        self.gguf_writer.add_rope_scaling_finetuned(use_rope)
        if not use_rope:
            self.gguf_writer.add_context_length(2**20)

        ## Validation ##
        d_head = self.find_hparam(["d_head"], optional=True) or 64
        assert self.hparams.get("hidden_act") in [None, "silu"], "Only SILU activation supported"
        assert self.d_inner % d_head == 0, f"SSM inner size {self.d_inner} not a multiple of head dim {d_head}"

    def set_vocab(self):
        # For models with no ssm layers, don't pad for mamba2
        self.hparams["pad_vocab_size_multiple"] = 8 if self._ssm_layers else 1
        Mamba2Model.set_vocab(self)


@ModelBase.register("GraniteSpeechForConditionalGeneration")
class GraniteSpeechMmprojModel(MmprojModel):
    has_vision_encoder = False
    has_audio_encoder = True

    _batch_norm_tensors: list[dict[str, Tensor]] | None = None

    def get_audio_config(self) -> dict[str, Any] | None:
        return self.global_config.get("encoder_config")

    def set_gguf_parameters(self):
        assert self.hparams_audio is not None
        a = self.hparams_audio
        a["hidden_size"] = a["hidden_dim"]
        a["intermediate_size"] = a["hidden_dim"] * a["feedforward_mult"]
        a["num_attention_heads"] = a["num_heads"]
        a["num_hidden_layers"] = a["num_layers"]

        super().set_gguf_parameters()

        self.gguf_writer.add_clip_projector_type(gguf.VisionProjectorType.GRANITE_SPEECH)
        self.gguf_writer.add_audio_num_mel_bins(a["input_dim"])
        self.gguf_writer.add_audio_attention_layernorm_eps(1e-5)
        self.gguf_writer.add_audio_chunk_size(a["context_size"])
        self.gguf_writer.add_audio_conv_kernel_size(a["conv_kernel_size"])
        self.gguf_writer.add_audio_max_pos_emb(a["max_pos_emb"])

        p = self.global_config
        self.gguf_writer.add_audio_projector_window_size(p["window_size"])
        self.gguf_writer.add_audio_projector_downsample_rate(p["downsample_rate"])
        self.gguf_writer.add_audio_projector_head_count(p["projector_config"]["num_attention_heads"])

    def tensor_force_quant(self, name, new_name, bid, n_dims):
        if "encoder" in name or "projector" in name:
            if ".conv" in name and ".weight" in name:
                return gguf.GGMLQuantizationType.F32
        return super().tensor_force_quant(name, new_name, bid, n_dims)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, gen = item
        if "attention_dists" in name or "num_batches_tracked" in name:
            return None
        return super().filter_tensors(item)

    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        # fold running_mean, running_var and eps into weight and bias for batch_norm
        if "batch_norm" in name and "encoder.layers." in name:
            if self._batch_norm_tensors is None:
                self._batch_norm_tensors = [{} for _ in range(self.block_count)]
            assert bid is not None
            self._batch_norm_tensors[bid][name] = data_torch
            if len(self._batch_norm_tensors[bid]) < 4:
                return
            prefix = f"encoder.layers.{bid}.conv.batch_norm"
            weight = self._batch_norm_tensors[bid][f"{prefix}.weight"]
            bias = self._batch_norm_tensors[bid][f"{prefix}.bias"]
            running_mean = self._batch_norm_tensors[bid][f"{prefix}.running_mean"]
            running_var = self._batch_norm_tensors[bid][f"{prefix}.running_var"]
            eps = 1e-5
            a = weight / torch.sqrt(running_var + eps)
            b = bias - running_mean * a
            yield from super().modify_tensors(a, f"encoder.layers.{bid}.conv.batch_norm.weight", bid)
            yield from super().modify_tensors(b, f"encoder.layers.{bid}.conv.batch_norm.bias", bid)
            return

        if ".attn.to_kv.weight" in name:
            k_weight, v_weight = data_torch.chunk(2, dim=0)
            yield from super().modify_tensors(k_weight, name.replace("to_kv", "to_k"), bid)
            yield from super().modify_tensors(v_weight, name.replace("to_kv", "to_v"), bid)
            return

        if ("up_conv" in name or "down_conv" in name) and name.endswith(".weight"):
            if data_torch.ndim == 3 and data_torch.shape[2] == 1:
                data_torch = data_torch.squeeze(2)

        if "depth_conv" in name and name.endswith(".weight"):
            if data_torch.ndim == 3 and data_torch.shape[1] == 1:
                data_torch = data_torch.squeeze(1)

        yield from super().modify_tensors(data_torch, name, bid)


@ModelBase.register("GraniteSpeechPlusForConditionalGeneration")
class GraniteSpeechPlusMmprojModel(GraniteSpeechMmprojModel):
    """Conversion for GraniteSpeechPlus - extends GraniteSpeech with feature layer concatenation"""
    has_vision_encoder = False
    has_audio_encoder = True

    def set_gguf_parameters(self):
        assert self.hparams_audio is not None
        super().set_gguf_parameters()

        # Add feature_layer if present in encoder config
        if feature_layers := self.hparams_audio.get("cat_hidden_layers"):
            self.gguf_writer.add_audio_feature_layers(feature_layers)
            logger.info(f"gguf: audio feature_layers = {feature_layers}")

            # Validate projector dimension matches concatenated encoder output
            hidden_dim = self.hparams_audio["hidden_dim"]
            expected_dim = hidden_dim * (len(feature_layers) + 1)
            projector_dim = self.global_config["projector_config"]["encoder_hidden_size"]

            if projector_dim != expected_dim:
                raise ValueError(
                    f"Projector encoder_hidden_size ({projector_dim}) does not match "
                    f"expected concatenated dimension ({expected_dim}). "
                    f"Expected: hidden_dim ({hidden_dim}) * (len(feature_layers) + 1) = {expected_dim}"
                )


@ModelBase.register("Granite4VisionForConditionalGeneration")
class Granite4VisionMmprojModel(MmprojModel):
    has_vision_encoder = True
    has_audio_encoder = False

    @staticmethod
    def get_normalized_projector_map(global_config: dict) -> list[tuple[int, int, str, int]]:
        """Normalize both deepstack and spatial projector maps to the form:
        (vision_layer, llm_layer, <type>, type_index)

        Granite4Vision has:
        - 4 layerwise projectors: read from specific intermediate vision encoder layers,
          inject at specific LLM layers (from deepstack_layer_map)
        - 4 spatial projectors: read from last vision encoder layer,
          inject at specific LLM layers (from spatial_target_layers)

        This is then used to populate the following mappings:
        - vision_feature_layers (mmproj hparam): ordered list of all
          vision_layer values where order corresponds with the order of the
          stacked projector tensors
        - tensor_prefix_map (mmproj tensors): mapping from tensor prefixes to
          the index of the corresponding projector in the stacked tensors
        - deepstack_layer_arr (llm hparam): per-text-layer array indicating
          which input vision feature should be injected at that layer
          (-1 if none)

        Output: (vision_layer, llm_layer, <type>, type_index)
        """
        spatial_target_layers = global_config.get("spatial_target_layers", [])  # [llm_layer, ...]
        deepstack_layer_map = global_config.get("deepstack_layer_map", [])  # [[vision_offset, llm_layer], ...]
        n_vision_layers = global_config["vision_config"]["num_hidden_layers"]

        # Granite4Vision has 4 layerwise + 4 spatial projectors = 8 total
        n_projectors = 8
        n_layerwise = len(deepstack_layer_map)  # expected 4
        n_spatial = n_projectors - n_layerwise  # remaining = spatial projectors

        normalized_projector_map = []

        # Layerwise projectors: vision_layer from deepstack_layer_map offset, llm_layer from deepstack_layer_map
        # deepstack_layer_map = [[-19, 9], [-13, 6], [-7, 3], [-1, 0]] for Granite4Vision
        for proj_idx, (vision_offset, llm_layer) in enumerate(deepstack_layer_map):
            vision_layer = n_vision_layers + vision_offset if vision_offset < 0 else vision_offset
            normalized_projector_map.append((vision_layer, llm_layer, "layerwise", proj_idx))

        # Spatial projectors: read from last vision layer, inject at spatial_target_layers
        spatial_vision_layer = global_config.get("spatial_vision_layer", -1)
        if spatial_vision_layer < 0:
            spatial_vision_layer = n_vision_layers + spatial_vision_layer
        for spatial_idx in range(n_spatial):
            llm_layer = spatial_target_layers[spatial_idx] if spatial_idx < len(spatial_target_layers) else -1
            normalized_projector_map.append((spatial_vision_layer, llm_layer, "spatial", spatial_idx))

        return list(sorted(normalized_projector_map, key=(lambda entry: (entry[1], 0 if entry[2] == "layerwise" else 1))))

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        normalized_projector_map = self.get_normalized_projector_map(self.global_config)
        self._n_proj = len(normalized_projector_map)

        self._tensor_prefix_map = {
            f"model.{proj_type}_projectors.{type_idx}": proj_idx
            for proj_idx, (_, _, proj_type, type_idx) in enumerate(normalized_projector_map)
        }
        self._vision_feature_layers = [vision_layer for vision_layer, _, _, _ in normalized_projector_map]
        self._spatial_offsets = [
            type_idx if proj_type == "spatial" else -1
            for _, _, proj_type, type_idx in normalized_projector_map
        ]

    def set_gguf_parameters(self):
        # NOTE: call MmprojModel directly to avoid GraniteModel.set_gguf_parameters()
        # writing n_deepstack_layers/n_deepstack_mapping to the shared GGUFWriter.
        # Only Granite4VisionTextModel (the TEXT side) should write deepstack params.
        assert self.hparams_vision is not None
        MmprojModel.set_gguf_parameters(self)

        self.gguf_writer.add_clip_projector_type(gguf.VisionProjectorType.GRANITE4_VISION)

        # SigLIP encoder hparams
        self.gguf_writer.add_vision_attention_layernorm_eps(self.hparams.get("layer_norm_eps", 1e-6))
        self.gguf_writer.add_vision_use_gelu(True)

        # Preprocessor
        self.gguf_writer.add_vision_preproc_image_size(self.hparams.get("image_size", 384))

        # QFormer projector config
        ds_rate = self.global_config["downsample_rate"]
        ds_parts = ds_rate.split("/")
        assert len(ds_parts) == 2, f"Invalid 'downsample_rate' value: {ds_rate}"
        query_side, window_side = [int(p) for p in ds_parts]
        self.gguf_writer.add_vision_projector_query_side(query_side)
        self.gguf_writer.add_vision_projector_window_side(window_side)

        # Set vision feature layers
        self.gguf_writer.add_vision_feature_layers(self._vision_feature_layers)

        # Set the spatial offests per projector
        self.gguf_writer.add_vision_spatial_offsets(self._spatial_offsets)

        # Add flattened image grind pinpoints (resolution candidates internally)
        if pinpoints := self.global_config.get("image_grid_pinpoints"):
            # Flatten with h, w -> w, h inversion
            pinpoints = [val for h, w in pinpoints for val in (w, h)]
            self.gguf_writer.add_vision_image_grid_pinpoints(pinpoints)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, _ = item
        if ("vision_model.head" in name or name.startswith("lm_head")):
            return None
        return super().filter_tensors(item)

    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:

        # Detect projector tensors and bin them
        projector_idx = None
        for prefix, proj_idx in self._tensor_prefix_map.items():
            if name.startswith(prefix):
                projector_idx = proj_idx
                break
        if projector_idx is not None:
            # If this projector tensor has a block id within the projector,
            # alias the bid to projector_idx
            #
            # TODO: currently, none of the Granite 4 Vision models have
            # projectors with multiple QFormer layers, so the `layer.{}` index
            # is always 0. This allows us to simply map to a single `bid` that
            # matches the projector index. If this changes, we'll need a
            # convention that merges the two IDs.
            id_matches = list(re.finditer(r"\.([0-9]+)\.", name))
            all_ids = [int(m.group(1)) for m in id_matches]
            assert len(all_ids) >= 1 and len(all_ids) <= 2, "Must have at least 1 and at most 2 ids in tensor names"
            # If not layer id, just use the projector index
            new_bid = projector_idx
            if len(all_ids) == 1:
                new_name = name[:id_matches[0].span(1)[0]] + str(new_bid) + name[id_matches[0].span(1)[1]:]
            else: # len(all_ids) == 2
                new_bid = projector_idx # + all_ids[1]
                new_name = name[:id_matches[0].span(0)[0]] + name[id_matches[0].span(1)[1]:id_matches[1].span(1)[0]] + str(new_bid) + name[id_matches[1].span(1)[1]:]
            yield from super().modify_tensors(data_torch, new_name, new_bid)
            return
        yield from super().modify_tensors(data_torch, name, bid)


# Granite 4.1 Vision: text backbone.
# The SigLIP vision encoder + 8-projector deepstack are handled by Granite4VisionMmprojModel.
# This class provides the TEXT model so Granite4VisionForConditionalGeneration is
# registered in _model_classes[TEXT] with the correct MODEL_ARCH.GRANITE4VISION.
@ModelBase.register("Granite4VisionForConditionalGeneration")
class Granite4VisionTextModel(GraniteModel):
    model_arch = gguf.MODEL_ARCH.GRANITE4VISION
    # set_gguf_parameters inherited from GraniteModel (handles deepstack_mapping_arr)

    @classmethod
    def get_model_architecture(cls, hparams: dict, model_type) -> str:
        # The Granite4Vision config has a nested text_config.architectures = ["GraniteForCausalLM"].
        # We must return the OUTER architecture name so Granite4VisionTextModel is used, not GraniteModel.
        arches = hparams.get("architectures")
        if arches:
            return arches[0]
        return super().get_model_architecture(hparams, model_type)

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, gen = item
        # Granite4Vision tensors are prefixed "model." (e.g. model.language_model.embed_tokens.weight).
        # Strip it so the base class can remap "language_model.*" -> "blk.*" / "token_embd.*".
        if name.startswith("model."):
            name = name[len("model."):]
        # Skip vision / projector / encoder tensors (handled by Granite4VisionMmprojModel).
        if (
            "vision_tower." in name
            or "layerwise_projectors" in name
            or "spatial_projectors" in name
            or "image_newline" in name
        ):
            return None
        return super().filter_tensors((name, gen))


# Granite Speech: text backbone (whisper-style audio encoder is handled by GraniteSpeechMmprojModel).
@ModelBase.register("GraniteSpeechForConditionalGeneration")
class GraniteSpeechTextModel(GraniteModel):
    model_arch = gguf.MODEL_ARCH.GRANITE_SPEECH_PLUS
    # Granite Speech uses the same text backbone parameters as GraniteModel


# Granite Speech Plus: text backbone (GraniteSpeechPlusMmprojModel handles audio encoder).
@ModelBase.register("GraniteSpeechPlusForConditionalGeneration")
class GraniteSpeechPlusTextModel(GraniteModel):
    model_arch = gguf.MODEL_ARCH.GRANITE_SPEECH_PLUS


# Granite Docling: text backbone for Idefics3ForConditionalGeneration.
# The SigLIP vision encoder + Idefics3 QFormer are handled by GraniteDoclingMmprojModel.
@ModelBase.register("Idefics3ForConditionalGeneration")
class GraniteDoclingTextModel(GraniteModel):
    model_arch = gguf.MODEL_ARCH.GRANITE_DOCLING

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, gen = item
        # Granite Docling tensors are prefixed "model." (e.g. model.text_model.model.embed_tokens.weight).
        # Strip it so the base class can remap "text_model.*" -> "blk.*" / "token_embd.*".
        if name.startswith("model."):
            name = name[len("model."):]
        # Skip vision / connector tensors (handled by GraniteDoclingMmprojModel).
        if "vision_model." in name or "connector." in name:
            return None
        return super().filter_tensors((name, gen))


# Granite Docling: mmproj for SigLIP vision encoder + Idefics3 QFormer.
# Registered for "idefics3" model_type to distinguish from SmolVLM (which uses "smolvlm_vision").
# Both models share "Idefics3ForConditionalGeneration" in the HF model registry.
@ModelBase.register("idefics3")
class GraniteDoclingMmprojModel(MmprojModel):
    """Conversion for Granite Docling mmproj (SigLIP encoder + Idefics3 QFormer connector)."""
    has_vision_encoder = True
    has_audio_encoder = False

    def set_gguf_parameters(self):
        assert self.hparams_vision is not None
        super().set_gguf_parameters()

        self.gguf_writer.add_clip_projector_type(gguf.VisionProjectorType.IDEFICS3)

        # SigLIP encoder hparams
        self.gguf_writer.add_vision_attention_layernorm_eps(
            self.hparams_vision.get("layer_norm_eps", 1e-6))
        self.gguf_writer.add_vision_use_gelu(True)

        # QFormer projector config
        self.gguf_writer.add_vision_projector_scale_factor(
            self.global_config.get("scale_factor", 4))

        # Preprocessor
        self.gguf_writer.add_vision_preproc_image_size(
            self.preprocessor_config.get("size", {}).get("longest_edge", self.image_size))

    @classmethod
    def filter_tensors(cls, item: tuple[str, Callable[[], Tensor]]) -> tuple[str, Callable[[], Tensor]] | None:
        name, _ = item
        # Skip language model tensors (text backbone, not mmproj).
        if "language_model." in name:
            return None
        return super().filter_tensors(item)
