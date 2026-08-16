# Research evidence: IBM Granite + Red Hat ecosystem (2026-08-16)

Prepared by the ecosystem research agent. Evidence input to
`../training-flywheel-granite-design-2026-08-16.md`. UNVERIFIED marks
items where primary pages were unreachable (ibm.com blocks fetches).

## 1. Granite family, current state (mid-2026)

- **Granite 4.0** (2025-10-02): hybrid Mamba-2/transformer, Apache 2.0.
  h-small 32B-A9B, h-tiny 7B-A1B (MoE), h-micro 3B dense-hybrid,
  micro 3B pure transformer ("when Mamba-2 isn't fully supported").
  **Granite 4.0 Nano** (2025-10-28): 1B + 350M, hybrid AND
  pure-transformer variants, for on-device/edge. ~9:1 Mamba-2:attention
  interleave, NoPE in hybrid blocks, 128K ctx (350M = 32K).
  https://www.ibm.com/new/announcements/ibm-granite-4-0-hyper-efficient-high-performance-hybrid-models
- **Granite 4.1** (2026-04-29): mainline pivoted BACK TO DENSE
  transformers - granite-4.1-3b / -8b / -30b (base + instruct + FP8 +
  official GGUF). GraniteForCausalLM, GQA/RoPE/SwiGLU/RMSNorm; 3B
  explicitly "optimized for edge deployment". Dense chosen partly for
  fine-tuning flexibility; 8B dense matches old 32B-A9B quality.
  Context: shipped configs 128K ("512K" claims UNVERIFIED as shipped).
  Companions: vision-4.1-4b, speech-4.1-2b, guardian-4.1-8b,
  embedding-97m/311m-r2.
  https://research.ibm.com/blog/granite-4-1-ai-foundation-models
  https://huggingface.co/ibm-granite/granite-4.1-8b
- **Granite Libraries / aLoRA / Switch** (Dec 2025 - May 2026), the
  most Tessera-relevant development: granitelib = collections of
  ACTIVATED-LoRA adapters for well-defined operations (core/rag/
  guardian r1.0), targeting granite-4.0-micro 3B dense; aLoRA (NeurIPS
  2025) applies adapter weights only to tokens after an invocation
  string so the base KV cache is reused - cheap runtime adapter
  switching. Granite Switch (switch-4.1-3b/8b/30b-preview, 2026-05-01):
  one checkpoint embedding multiple aLoRAs selected via control tokens.
  Mellea = IBM's generative-programming library over them. Also:
  granite-swash-2b/-3b-a600m (2026-07-01) SWA previews - small-model
  architecture still in motion.
  https://research.ibm.com/blog/granite-libraries-project-switch
  https://arxiv.org/abs/2504.12397
- **Licensing**: Apache 2.0 across the family, no exceptions found.
  Training-data disclosure: summary-level, not dumps.
  **Indemnification: IBM's uncapped IP indemnity applies ONLY to
  Granite consumed through watsonx.ai. HF/Ollama/GGUF downloads carry
  Apache 2.0 only - NO indemnity.** The key legal asymmetry for a
  local-first product.

## 2. Trust/certification story, precisely

- ISO/IEC 42001: certifies IBM's AI MANAGEMENT SYSTEM (process), not
  model artifacts. Auditor: Schellman (first ANAB-accredited 42001 CB);
  reportedly zero non-conformities. Does NOT transfer to derivatives;
  no IBM program to certify derivatives/partners exists (searched;
  absent). Tessera's honest path: certify its OWN AIMS later so the
  chain reads "42001-certified org fine-tuning a model from a
  42001-certified org".
  https://digital.nemko.com/news/ibm-granite-40-first-iso-42001-certified-open-source-ai
- **Checkpoint signing**: Sigstore-based via sigstore/model-transparency
  (`pip install model-signing`); every ibm-granite HF repo ships
  `model.sig`; IBM runs its OWN Sigstore instance
  (sigstore.verify.ibm.com), labeled "experimental". Verify:
  `python -m model_signing verify sigstore --signature model.sig
  --identity Granite.Preview@ibm.com
  --identity_provider https://sigstore.verify.ibm.com/oauth2 .`
  https://github.com/ibm-granite/docs/blob/main/granite/docs/model-standards/signature-verification.mdx
- HackerOne bounty: invite-only, ~$100K pool, deployment-scenario
  red-teaming with Guardian active - does not cover derivatives.
- Trust hub: https://www.ibm.com/granite/trust

## 3. llama.cpp / GGUF support for Granite

- MATURE AND IBM-DRIVEN: upstream arches `granite`, `granitemoe`,
  `granitehybrid`, `graniteswitch` (verified in src/llama-arch.cpp);
  built by IBM's Gabe Goodhart (tracking issue ggml-org/llama.cpp
  #13275); Granite 4.0 had day-0 GGUF support. **aLoRA merged upstream
  (PR #15327, release b6396).** Official first-party IBM GGUFs for the
  whole lineup incl. 4.1 and Nano.
- Metal: SSM_SCAN/SSM_CONV implemented; history of Mamba-on-Metal
  issues; recurrent ops have less soak time than attention - run a
  conformance pass before ever shipping hybrids.
- Quantization quirks for T640-class calibration on HYBRIDS: llama.cpp
  hard-codes ssm_conv1d exemptions (llama-quant.cpp:324-326); state/dt/
  A/D stay high precision; imatrix statistics flow differently through
  recurrent blocks (corpus ordering matters); h-tiny MoE adds
  per-expert calibration coverage problems. DENSE models (4.0-micro,
  all 4.1) behave like classic transformers - T640 unchanged.

## 4. On-device LoRA feasibility (16GB Apple Silicon)

- **MLX-LM is the realistic trainer**: mature mlx_lm.lora
  (LoRA/QLoRA/DoRA), trains on quantized bases, grad checkpointing;
  granite.py/granitemoe.py/granitemoehybrid.py/mamba2.py all present.
  Budgets: 3B QLoRA rank 8-16, few thousand samples = ~4-6GB peak,
  tens of minutes/epoch on M-series. Guardrails: AC power + idle,
  batch 1, seq cap 512-1024, thermals on fanless devices; ANE cannot
  train; iOS BGProcessingTask windows too short - train on macOS, sync
  adapters to iOS.
  https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md
- llama.cpp CANNOT train this (finetune.cpp is WIP FP32 full-finetune,
  no LoRA). Unsloth is IBM's documented fine-tune path but
  CUDA/Linux - server-side only.
- Adapter flow: train PEFT safetensors against the BF16 base (never a
  differently-quantized base), convert via convert_lora_to_gguf.py,
  hot-load with --lora (server supports multiple adapters +
  per-request scaling); llama-export-lora merges.
- **aLoRA is the sleeper feature**: llama.cpp supports it, IBM
  publishes the training repo (github.com/IBM/activated-lora), and it
  matches per-feature intrinsics invoked mid-context without KV
  invalidation - much cheaper than classic LoRA switching on 16GB.

## 5. InstructLab: effectively wound down

- CLI last release v0.26.1 (2025-05-05); Sept 2025 announcement:
  refactored to "a framework SDK"; components moved to
  Red-Hat-AI-Innovation-Team/sdg_hub + training_hub; taxonomy repo's
  April 2025 eulogy commit: "Goodnight sweet prince. You don't help us
  anymore."; newest community model is granite-3.0-8b-lab-community
  (Dec 2024); no Granite 4.x base ever supported.
- The LAB method survives inside Red Hat AI 3's customization toolkit
  (sdg_hub + training_hub: SFT, OSFT, LoRA+SFT, LoRA+GRPO via
  Unsloth/verl).
  https://www.redhat.com/en/blog/red-hat-ai-modular-building-blocks-scalable-repeatable-model-customization
- **VERDICT: the taxonomy qna.yaml format is NOT a sensible
  interchange format.** Export plain, hashed JSONL chat datasets
  (optional thin skill-metadata wrapper) - directly consumable by
  training_hub, Unsloth, MLX-LM, and anything future.

## 6. RHEL AI + Red Hat platform

- Red Hat AI 3 (2025-10-14) umbrella: RHEL AI (bootc server + Granite +
  vLLM), OpenShift AI, AI Inference Server (hardened vLLM + LLM
  Compressor + curated HF model repo incl. Granite), llm-d GA. vLLM is
  Red Hat's engine of record; RHEL AI is datacenter, not desktop.
- Desktop ISV reality: Partner Connect targets server/OpenShift ISVs;
  consumer-desktop partnership precedent essentially nonexistent.
  What EXISTS: **Podman Desktop + Podman AI Lab** (Red Hat's own
  llama.cpp-based local LLM tooling, Granite as default model,
  converging with RamaLama) - proof Red Hat cares about local Granite
  on desktops, and the natural integration/co-marketing hook.
  **Flathub is the sanctioned distribution channel** (Fedora offers
  unfiltered Flathub since F38; 2025 direction embraces it further).
  https://developers.redhat.com/products/podman-desktop/podman-ai-lab
  https://fedoraproject.org/wiki/Changes/UnfilteredFlathub

## 7. IBM partnership mechanics

- Partner Plus Build track = the ISV on-ramp; embed motion + indemnity
  are watsonx-centric.
- Granite distribution partners (4.0 launch): Dell, Docker Hub, HF,
  Kaggle, LM Studio, NVIDIA NIM, Ollama, OPAQUE, Replicate; Unsloth as
  fine-tuning partner. Edge flagship = Qualcomm (Snapdragon).
  **No Apple-Silicon / on-device-ISV program exists - a visible gap
  Tessera could fill as the showcase.**
- First-contact surfaces that work for one founder:
  github.com/ibm-granite-community (AI Alliance project; cookbook PRs
  welcome); ggml-org/llama.cpp (IBM's Granite lead reviews directly -
  engine contributions get IBM Research eyes); HF discussions; AI
  Alliance startup membership; Partner Plus Build once there is
  something to show.

## 8. Fit assessment (agent's recommendation)

**Base: granite-4.1-3b (dense) primary; granite-4.0-350m as
speculative-decoding draft (4.0/4.1 share the 100352-token vocab -
confirm tokenizer identity at integration); per-feature aLoRA
intrinsics on top. granite-4.1-8b (~5GB Q4) optional quality tier.
Hybrids = R&D only.**

Rationale: dense = T640 calibration + ANE prefill + existing fork
paths unchanged; ~2GB at Q4 fits the 16GB floor with suite + KV; Apache
2.0 + official GGUF + verifiable model.sig at import (feeds receipts);
newest mainline with best tool-calling; IBM's own granitelib targets a
3B dense - Tessera's locally-trained intrinsics would be structurally
compatible with IBM's "AI as software libraries" direction.

What breaks: hybrids need T640 changes + Metal SSM conformance (defer);
Mamba-2 does not map to ANE (another dense-first reason); training is
macOS/MLX only; no indemnity on HF weights; IBM signing is experimental
+ anchored to an IBM-run Sigstore endpoint (cache verification at
download, not per-launch); architecture churn (hybrid -> dense -> swash
in 10 months) - pin per-model engine profiles, budget one re-quantize/
re-train/re-sign cycle per Granite generation.

## 9. Collaboration paths ranked

IBM: (1) contribute where IBM lives - ibm-granite-community cookbooks +
llama.cpp upstream (quantization findings, Metal fixes, aLoRA/Switch
improvements) - the only channel where one founder gets IBM Research
eyes without a deal; (2) ship "Granite inside Tessera" (verified
signature import + receipts + Nano draft) and present it - IBM has no
signed-verification-on-device consumer showcase; (3) Partner Plus Build
application at 3-6 months; ask about extending indemnity to local
Granite (expect "watsonx only", but the ask opens the account); (4)
IBM Research collaboration on consent-gated on-device aLoRA intrinsics
(via generative-computing org / aLoRA authors); (5) AI Alliance
membership.

Red Hat: (1) Flathub NOW - do not wait for a partnership to ship on
Fedora; (2) integrate alongside Podman AI Lab / RamaLama conventions +
Fedora Magazine / Red Hat Developer writeups; (3) Partner Connect as a
marketing checkbox only; (4) align egress-grant export with
sdg_hub/training_hub dataset conventions; skip InstructLab taxonomy;
(5) llm-d/RHEL AI: ignore unless a server tier appears.

## 10. Risks

1. Small-model architecture churn at IBM - the base choice is
   perishable; abstract engine profiles.
2. Trust-story overreach - IBM's 42001 covers IBM's process;
   signatures cover IBM's checkpoints; the bounty covers IBM's
   scenarios. Inherited-certification claims would be false.
3. Legal asymmetry - indemnity is watsonx-only.
4. Ecosystem half-life - InstructLab died in ~18 months;
   granitelib/Switch/Mellea are young. Depend on FORMATS (GGUF, PEFT,
   plain JSONL), not programs.
5. Technical - Metal SSM maturity; 16GB contention between suite +
   inference + idle training; MLX-vs-llama.cpp quant mismatch (train
   against bf16); IBM Sigstore endpoint as a network dependency.
6. Partnership expectations - both relationships start as open-source
   contribution and content, not contracts; budget founder time.
