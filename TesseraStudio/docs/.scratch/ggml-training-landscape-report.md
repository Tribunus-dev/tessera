# Research evidence: llama.cpp/ggml training landscape (2026-08-16)

Prepared by the training-landscape research agent; facts re-verified live
against master / api.github.com on 2026-08-16. Evidence input to
`../training-flywheel-granite-design-2026-08-16.md` section 2 (19e).
UNVERIFIED marks retained.

## 1. Upstream llama.cpp/ggml training

- examples/training/finetune.cpp: still FULL-finetune only, FP32-
  oriented, "very much WIP"; README documents CPU or CUDA; ~24GB for a
  1B at ctx 512. https://github.com/ggml-org/llama.cpp/tree/master/examples/training
- ggml-opt: AdamW + SGD, LR-schedule callback (lr0/lr-min/decay/wd via
  PR #13873, merged 2025-08-14), gradient accumulation (opt_period),
  dataset/epoch loop. NO mixed-precision (moments/grads f32; finetune
  forces KV cache F32 citing missing f16 OUT_PROD; CUDA f16 OUT_PROD
  only in open PR #26599). No activation checkpointing upstream.
- LoRA training NOT merged, no active owner: JG's issue #13485 "LoRA
  training example" (2025-05-12, open, "research" label, dormant since
  Sept 2025) - "simply not implemented", with open questions on
  training against quantized bases.
  https://github.com/ggml-org/llama.cpp/issues/13485
- Community QLoRA PRs without traction: #22705 (draft, +12.7k lines,
  MoE QLoRA + MUL_MAT_ID backward + checkpointing + GRPO-style SFT,
  ZERO maintainer review, unmergeable); #26794 (QLoRA + QAT + quantized
  AdamW states + cosine LR, closed unmerged after 2 days, Aug 2026).
- Frozen-base backward mechanics (verified in ggml.c MUL_MAT backward):
  grad-wrt-activations = ggml_out_prod(W, grad^T) IN W'S DTYPE - so
  frozen-base LoRA needs OUT_PROD per dtype per backend. f32 everywhere
  OUT_PROD exists; quantized partial on CPU; f16 CUDA pending; bf16
  OUT_PROD found nowhere (UNVERIFIED as absent).
- Upstream finetune path currently FRAGILE: issue #21037 (closed stale,
  unfixed) documents 5 cascading bugs - dataset-size underflow,
  SET_ROWS rejected by the backward view-op assert, FLASH_ATTN_EXT has
  NO backward (must disable FA), scheduler hash-set too small, grads
  lacking backend assignment. Fix PRs #21924/#27156 open unmerged.
  Maintainer bandwidth for training is low; stale-bot closes bugs.

## 2. Backward-pass backend coverage (docs/ops.md on master)

| Op | CPU | CUDA | Metal | Vulkan |
|---|---|---|---|---|
| OUT_PROD | partial | yes | NO (PR #23724 open) | partial |
| SOFT_MAX_BACK | yes | yes | NO (PR #26033 open) | partial |
| ROPE_BACK | yes | yes | NO | yes |
| RMS_NORM_BACK | yes | yes | NO | yes |
| SILU_BACK | yes | yes | merged 2026-08-02 | yes |
| GET_ROWS_BACK | ref | yes | NO | partial |
| CROSS_ENTROPY(+BACK) | yes | yes | NO | NO (CPU fallback ok) |
| OPT_STEP_ADAMW/SGD | yes | yes | yes | yes |

- CUDA (+HIP/ROCm by compilation): complete; the reference GPU path.
- **Vulkan: essentially train-capable on master TODAY** (CE loss falls
  back to CPU via the scheduler - tiny tensors, cheap). The Linux
  AMD/Intel leg exists upstream.
- **Metal: NOT natively trainable today** - missing OUT_PROD,
  SOFT_MAX_BACK, ROPE_BACK, RMS_NORM_BACK, GET_ROWS_BACK, CE_BACK; ops
  trickling in via good-first-issue tracker #14909. Mac training = CPU
  or scheduler-fallback until then.
- FLASH_ATTN_EXT has no backward on ANY backend: training attention is
  materialized softmax, O(ctx^2) memory - ctx effectively capped ~1k
  without checkpointing.

## 3. Community GGUF-native training

- **QVAC Fabric (Tether AI) - the standout.** MIT fork
  tetherto/qvac-fabric-llm.cpp (created 2025-06-25, last push
  2026-08-14, active) + binaries repo + HF blog (2025-12-01). Ships
  `llama-finetune-lora`: LoRA training on Vulkan/Metal/CUDA/CPU with
  the missing Metal/Vulkan backward kernels implemented IN-FORK;
  configurable rank/alpha/target modules; masked loss
  (--assistant-loss-only); cosine LR + warmup; JSONL instruction data;
  GGUF adapter output loadable via --lora; merged-GGUF export.
  Benchmarks (Qwen3-1.7B Q8, 8 epochs, few-hundred-sample corpora):
  RTX 4090 45 min; Apple M3 Pro 5.3h (Metal); iPhone 16 ~15h.
  Supported archs: Qwen3/Gemma-3/Llama-family - **NO Granite, NO PEFT
  export**. Claims upstream-safe design; no upstream PR found yet.
  https://huggingface.co/blog/qvac/fabric-llm-finetune
  https://github.com/tetherto/qvac-fabric-llm.cpp
- xaedes finetune: dead (removed 2024, never revived). Historical CPU
  datapoints (rentry.co/cpu-lora): 3B LoRA ~2h49m on a 2023 laptop
  CPU; "16GB RAM trains a 3B".
- candle/burn/llm.c: no GGUF-native LLM-LoRA training story.
- No non-Python trainer emitting PEFT-compatible adapters exists
  anywhere - the gap the fork can fill.

## 4. MLX on Linux

- MLX: macOS/Metal + Linux CUDA (pip mlx[cuda]) + Linux CPU; mlx-lm
  LoRA documented as running on CUDA (partially UNVERIFIED maturity).
- **No AMD path**: ROCm is an open feature request (#2556); Vulkan a
  wishlist item the team is unlikely to staff (#1751). MLX cannot
  cover Linux AMD/Intel - confirms the multi-platform objection.

## 5. IBM tooling interop

- IBM/activated-lora: PyTorch + PEFT subclasses, now DEPRECATED in
  favor of upstream PEFT's aLoRA implementation (PEFT issue #2523).
  Artifacts: standard PEFT (adapter_model.safetensors +
  adapter_config.json with alora_invocation_tokens). aLoRA mechanics:
  adapter applies only to tokens AFTER the invocation sequence (KV
  cache for the prefix reusable); typically needs higher rank (r=32).
  Reference aLoRAs published for Granite 3.x only (4.x: none found).
- llama.cpp aLoRA (IBM's PR #15327, merged 2025-09-05): GGUF KV
  `adapter.alora.invocation_tokens`, C API, server KV-cache
  preservation on adapter switch. **convert_lora_to_gguf.py handles
  aLoRA today** (reads alora_invocation_tokens / tokenizes
  invocation_string). Conversion is ONE-WAY PEFT->GGUF; no GGUF->PEFT
  tool exists upstream.
- training_hub: SFT/OSFT/LoRA+SFT (Unsloth/PEFT)/GRPO (verl); datasets
  JSONL "messages" + Alpaca; outputs HF/PEFT artifacts. sdg_hub: YAML
  flows emitting JSONL. The IBM/Red Hat boundary: JSONL-messages in,
  PEFT out.
- IBM interest in llama.cpp-native TRAINING: no public signal found -
  IBM's llama.cpp investment is inference-side. (The visible gap.)
- Unsloth supports Granite 4.1 fine-tuning (the server-side reference
  for parity validation).
- granite-4.1-3b confirmed dense llama-like graph (GraniteForCausalLM,
  hidden 2560, 40L, GQA 40/8, vocab 100352, tied embeddings, bf16,
  128K) + Granite scalar multipliers (backward = SCALE) - trainable
  with the standard ggml backward set, no mamba blocks.

## 6. Budgets (3B dense, LoRA r=8-16)

- Adapter state r=16 all 7 projections: ~31M params (~1% of base);
  f32 A/B + grads + AdamW moments ~ 0.5GB (r=8 ~0.25GB).
- bf16 base 6.4GB + materialized attention (ctx 512) ~1.7GB + FFN/misc
  ~3GB = **~11-12GB total: fits the 16GB floor at short context**.
  Upstream's f32-base restriction would need ~18GB+ - bf16/quant
  OUT_PROD coverage is what makes 16GB work. ctx 2048 without
  checkpointing: ~26GB attention alone - cap ctx <= 1024 in v1 or port
  checkpointing (QVAC/#22705 carry it).
- Throughput class: QVAC M3 Pro Metal 5.3h for an 8-epoch small-corpus
  run; historical CPU 3B LoRA ~3h. Overnight idle adapter runs on
  1-3B with 10k-1M token corpora: feasible. >10M tokens multi-epoch:
  not.

## 7. Gap analysis for the fork (build vs reuse vs upstream)

REUSE (upstream today): ggml-opt optimizers/schedules/accumulation/
epoch loop; **llama_opt_init's param_filter callback - the exact
freezing hook**; Vulkan backward coverage; GGUF adapter format +
runtime + aLoRA metadata + PEFT->GGUF converter; Granite dense graph.

BUILD/PORT in the fork:
1. Trainable-LoRA graph path (allocate blk.N.*.lora_a/b as params,
   wire into build_lora_mm - the fork already instruments this seam
   for activation capture; freeze base via param_filter). Port QVAC's
   llama-finetune-lora = the biggest shortcut (M; adaptation not
   cherry-pick - QVAC branched mid-2025).
2. Frozen-base backward dtype coverage: bf16 (cast-based cheapest)
   and/or Q8_0 OUT_PROD on CPU/Vulkan/Metal (S-M; Metal quantized
   OUT_PROD is exactly open PR #23724 - upstreamable).
3. Metal backward kernels (port QVAC's, or v1 fallback = Mac trains on
   CPU): each kernel small + individually upstreamable via #14909.
4. Finetune-path bug patches carried until upstream merges (#21037
   list; PRs #21924/#27156).
5. Masked/weighted loss via the existing LK-loss seam (S).
6. **aLoRA training semantics - first-of-its-kind in C++** (S once 1
   exists): position-gate the lora branch at >= invocation offset
   (elementwise 0/1 mask; trivial backward), loss restricted to
   post-invocation tokens, emit adapter.alora.invocation_tokens.
7. Adapter save: GGUF adapter writer + PEFT export (safetensors +
   adapter_config.json incl. alora fields, HF module-name map) + a
   ~200-line GGUF->PEFT script (no such tool exists anywhere).
8. Activation checkpointing port for ctx > 1k (or documented cap).
9. Parity validation vs an Unsloth/PEFT reference run (loss curves +
   adapter equivalence) - NON-NEGOTIABLE for the IBM-interop claim (M).

UPSTREAMABLE with likely acceptance: Metal kernels, the 5 bug patches,
dtype OUT_PROD coverage, a plain-LoRA example against #13485. NOT
easily upstreamable: aLoRA training semantics, custom losses,
Granite-specific UX.

## 8. Recommendation

**Extend the fork - by porting, not pioneering - with a hybrid
upstream strategy.** Wait-for-upstream is not viable (dormant issue,
unreviewed PRs, stale-bot). Vulkan backward is on master; QVAC (MIT,
active) proves LoRA + masked loss + Metal/Vulkan kernels on the same
codebase lineage. Risks: Metal backward numerics need CPU-parity
validation (upstream Metal training has never run end-to-end); bf16
backward unproven everywhere; ctx capped ~1k until checkpointing;
QVAC could land upstream any time (good news - ports become rebases).
