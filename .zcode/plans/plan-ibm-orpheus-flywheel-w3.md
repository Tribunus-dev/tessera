# IBM + Orpheus Flywheel W3 Implementation Plan

**Lane**: `scratch/ibm-orpheus-w3` (parent branch; workers are `scratch/w3-{n}-{name}`)
**Goal**: Close the agentic training data flywheel (stages 7-10) with text and
         audio (Orpheus TTS) modality support from day one. Produce GGUF-compatible
         fine-tuned drafters for Granite 3.3 8B text agents and Orpheus TTS audio
         drafters, within the procurement-safe IBM stack.
**Workers**: 5 isolated worktrees, no alphaevolve until pipeline is proven
**alphaevolve scope**: reserved for post-landing optimization of throughput/
         memory/batch-latency only — not for correctness or architecture

---

## Research Findings

### 1. Chat Template Token-Fidelity (Critical Path)

The literature is unambiguous: **template mismatch between training and inference is
the #1 cause of SFT failure**. Specific failure modes from 2025-2026 sources:

- **Format collapse**: Instruct model fine-tuned without its documented template
  produces incoherent outputs or never samples EOS. (HuggingFace forums, NIPS 2024)
- **Alignment degradation**: safety fine-tuning with mismatched template drops
  defense effectiveness by >30pp. (arXiv:2607.27081)
- **Tool call breakage**: `tool_call_id` correlation for parallel tool calls requires
  the template to preserve the 9-digit numeric ID. Some templates crash on
  `tool_calls[].function.arguments` when passed as a JSON string (not dict) —
  requires `fromjson` filter in Jinja2.
- **Label masking**: only assistant tokens get loss; user/tool/system tokens get
  weight 0. If the template renders these incorrectly, the masking is wrong.

**Implication**: the template library MUST be a single shared header consumed by
both the training driver and the inference path. No ad-hoc string concatenation
anywhere in the codebase.

**Template formats needed**:
- `qwen3_chat` — for Granite 3.3 8B (uses `<|im_start|>` ChatML)
- `granite_guardian` — for Granite Guardian 4.1 reward signal (read-only during training)
- `orpheus_tts` — for Orpheus audio modality (SOH/SOT/EOH/SOA/SOS/EOS/SOA
  special-token sequence, SNAC 7-tokens-per-frame interleaving)
- `generic_agent` — for tessera-traj-cli `--mode=openhands` capture output
  (ATIF v1.7 compatible, tool_call_id correlation, observation correlation)

### 2. Granite Embedding for Tier-3 Dedup

IBM's Granite Embedding R2 family (August 2025) is the right model:

| Model | Params | Embed dim | Seq len | License | GGUF |
|---|---|---|---|---|---|
| `granite-embedding-english-r2` | 149M | 768 | 8192 | Apache 2.0 | Q4_K_M available (bartowski) |
| `granite-embedding-small-english-r2` | 47M | 384 | 8192 | Apache 2.0 | Q4_K_M available |

Both are encoder-only (RoBERTa-backbone) models. The 47M variant is the right
choice for on-device dedup given the Apple Silicon ANE/Metal stack (small enough
to run fast, enough quality for cosine-similarity clustering). The 149M variant
is the right choice for the reranking step if we add a reranker.

**Procurement safety**: Apache 2.0 is fully permissive, no egress concerns, IBM
ships GGUF directly via their automated CI. Tessera's no-egress doctrine is intact.

### 3. Orpheus TTS Modality

Orpheus uses the SNAC codec (7 tokens per frame at 24kHz). The training sequence:

```
[SOH] [SOT] <text_tokens> [EOT] [EOH] [SOA] [SOS] <audio_codes> [EOS] [EOA]
```

For Tessera's fine-tuning context, the relevant facts:

- **Orpheus is fine-tuned from Llama 3.2 3B-Instruct**, so it inherits the Llama
  tokenizer + chat template. The Orpheus-specific special tokens (SOH/SOT/EOH/SOA/SOS/EOS/EOA)
  are appended to the vocabulary and map to the audio codec.
- **Dataset minimum**: ~50 examples for a voice to sound recognizable; ~300 for
  high-quality voice cloning per speaker. Tessera's per-customer opt-in means each
  customer's user contributes their own voice data — the volume question is per-customer.
- **Reward signal for audio**: acoustic quality metrics (STFT-based: SI-SDR, PESQ)
  are the equivalent of token accuracy for text. The verifier for Orpheus training
  is NOT the SWE-bench outcome — it's a waveform quality metric.
- **Audio modality in the flywheel**: Stage 1 (capture) needs to record audio
  alongside text. The `llama.tessera.agent-traj.v1` schema has `messages[].audio`
  field for this. Stage 4 (scrub) must handle both text PII and audio PII
  (voice biometric anonymization — not covered by Presidio, needs a separate
  voice anonymization step).

### 4. C++ Implementation Constraints

Tessera's traj modules are pure C++ with no llama/ggml/DuckDB dependency.
The chat template library must be C++ and header-only. Options:

- **inja** (header-only, ~3KB, Jinja2-compatible): smallest, most portable.
  Supports `render()` with a `std::map`-like context. Missing: `fromjson` filter,
  `items` filter. Workaround: pre-parse JSON strings to dicts before rendering.
- **inja extended** (adds `tojson`, `fromjson`, `split`, `trim`): the right choice.
  MIT licensed, single header, no external deps.
- **Custom template evaluator**: worth considering if we only need 3-4 fixed
  templates (qwen3, granite_guardian, orpheus, generic_agent). A simple
  `ts_chat_template_render(templated_id, messages_json, out)` is 200 LoC and
  has no attack surface. Templates are validated at compile time by being
  C++ string literals.

**Decision**: use **custom C++ template evaluator** (option 3) — the set of
supported templates is small and fixed. Zero runtime deps, zero attack surface,
compile-time validation. If a future model needs a complex Jinja2 feature,
the custom evaluator is the bottleneck signal, not now.

---

## Architecture

```
common/
  tessera-chat-template.h   # C++ template evaluator (header-only, 4 fixed templates)
  tessera-chat-template.cpp # .cpp for unit test linking

tools/quantize/tessera/traj/
  tessera-train-agent.cpp           # W3: text agentic SFT driver (fills skeleton)
  tessera-train-agent-audio.cpp     # W3: Orpheus TTS fine-tuning driver (new)
  tessera-traj-observe.cpp          # W3: closed-loop capture with trained_model_id
  tessera-traj-otel.cpp             # W3: OTel GenAI span emitter (off by default)
  tessera-traj-cli.cpp              # W3: --mode=replay (deterministic re-execution)

tools/quantize/tessera/traj/embed/          # NEW subdir for dedup embedding
  tessera-embed-granite.cpp                 # Granite embedding inference (GGUF)
  tessera-dedup-tier3.cpp                   # semantic dedup using Granite embeddings
  CMakeLists.txt                            # standalone STATIC lib, NO llama/ggml/ane

tools/quantize/tessera/traj/audio/          # NEW subdir for Orpheus audio
  tessera-audio-scrub.cpp                   # voice biometric anonymization (new)
  tessera-snac-tokenizer.cpp                # SNAC encode/decode (new, wraps SNAC model)
  CMakeLists.txt                            # standalone STATIC lib

tests/
  test-chat-template.cpp          # 4 template formats, token-fidelity hash test
  test-train-agent.cpp            # wire existing skeleton to real driver
  test-dedup-tier3.cpp            # Granite embedding dedup, cosine sim, halt-on-anomaly
  test-dedup-pipeline.cpp        # full 3-tier dedup with Granite tier3
  test-audio-scrub.cpp           # voice anonymization smoke test
  test-orpheus-template.cpp       # SOH/SOT/EOT/EOH/SOA/SOS/EOS/EOA token sequence
  test-token-fidelity.cpp         # hash(train_output) == hash(inference_output)
```

**Critical invariant**: the `tessera-chat-template.h` header is consumed by BOTH
`tessera-train-agent.cpp` (training) AND the inference-side template rendering
(`llama.cpp` chat template path when loading a Granite/Orpheus model). This is
the token-fidelity enforcement mechanism — one file, two sides of the training/inference
boundary.

---

## Worker Breakdown

### Worker 1: Chat Template Library + Token-Fidelity Invariant
**Branch**: `scratch/ibm-orpheus-flywheel-w3/worker-1-chat-template`
**Depends on**: nothing
**Deliverables**:
1. `common/tessera-chat-template.h` — C++ header with 4 template evaluators:
   - `ts_chat_render_qwen3(messages_json, add_gen_prompt, out_tokens)` → token IDs
   - `ts_chat_render_granite_guardian(messages_json, out_tokens)` → for reward signal
   - `ts_chat_render_orpheus(text_tokens, audio_codes, out_tokens)` → audio template
   - `ts_chat_render_generic_agent(traj_messages, out_tokens)` → ATIF-compatible
2. `common/tessera-chat-template.cpp` — minimal impl + unit test linkage
3. `tests/test-chat-template.cpp` — 4 template formats, edge cases
   (empty messages, tool_calls with JSON-string args, multi-turn, generation prompt)
4. `test-token-fidelity.cpp` — hash of (template_output from C++) == hash of
   (same messages rendered by the Python `transformers` reference on the same tokenizer).
   This test runs against a real tokenizer file, not synthetic data. **This is the
   held-out gate**: if the hashes don't match, the C++ implementation is wrong.

**Risk**: tokenization edge cases (special token IDs, tokenizer behavior on
multi-byte characters, bos/eos injection). Mitigate by using llama.cpp's built-in
tokenizer for the actual tokenization step — the C++ evaluator produces the
*string* that gets tokenized, and the tokenizer is the same binary used at
inference. The C++ evaluator only produces the rendered string, not token IDs.

### Worker 2: Orpheus Audio Modality Pipeline
**Branch**: `scratch/ibm-orpheus-flywheel-w3/worker-2-orpheus-audio`
**Depends on**: Worker 1 (chat template)
**Deliverables**:
1. `tools/quantize/tessera/traj/audio/tessera-audio-scrub.cpp` — voice biometric
   anonymization. Replaces Presidio for the audio modality. Uses a voice embedding
   + pitch-shifting approach (stateless, no API call). This is the only audio-PII
   tool Tessera needs; Granite Guardian covers semantic content.
2. `tools/quantize/tessera/traj/audio/tessera-snac-tokenizer.cpp` — wraps the
   SNAC model (loaded via `ggml` compute graph) for encode/decode. Input: raw
   audio waveform (float32 24kHz). Output: SNAC token IDs (7 tokens per frame).
   This is NOT the Orpheus LM itself — just the codec tokenizer.
3. `tools/quantize/tessera/traj/tessera-train-agent-audio.cpp` — the Orpheus
   TTS fine-tuning driver. Uses the same `ggml_opt` epoch loop as
   `tessera-train-dflash.cpp` but with:
   - Orpheus template (`ts_chat_render_orpheus`) for the SOH/SOT/... sequence
   - SNAC token IDs as labels (not text token IDs)
   - Acoustic reward signal (SI-SDR computed over ground-truth vs generated
     waveform, passed via `--reward-conditioned --reward-metric sisdr`)
   - Multi-speaker: speaker embedding prepended to prompt
4. `tests/test-audio-scrub.cpp` — voice anonymization smoke test
5. `tests/test-orpheus-template.cpp` — SOH/SOT/... token sequence correctness

**Design note**: Orpheus training uses the Orpheus 3B LM. Tessera doesn't need
to reimplement the Orpheus LM — the `tessera-train-agent-audio` driver consumes
a GGUF containing the Orpheus model weights (loaded via `llama.cpp`) and runs
`ggml_opt` on it, just like `tessera-train-dflash` does for DFlash. The Orpheus
GGUF is loaded from `model_path` just like any other model.

### Worker 3: tessera-train-agent Fills the Skeleton
**Branch**: `scratch/ibm-orpheus-flywheel-w3/worker-3-train-agent`
**Depends on**: Worker 1
**Deliverables**:
1. Complete `tessera-train-agent.cpp` (fills the existing skeleton):
   - `ts_chat_render_qwen3` applied to each trajectory's `messages[]`
   - Tokenization via llama.cpp tokenizer (same binary as inference)
   - `(tokens, label_indices, weights)` triple per trajectory
   - `ggml_opt` epoch loop with reward-conditioned weighting
   - `--reward-conditioned` flag: weight = 1.0/0.5/0.1 by verifier_outcome
   - Multi-source batching: upsample short dense, downsample long sparse,
     target-token-budget aware
   - `--teacher-model` flag (default: inference stack model, per OT-Agent lesson)
2. `tests/test-train-agent.cpp` — wire the existing skeleton to the real driver
3. `test-token-fidelity.cpp` (extends Worker 1's version) — validates that
   `tessera-train-agent`'s tokenization output matches `llama-server`'s inference
   output for the same trajectory

### Worker 4: Granite Embedding Tier-3 Dedup
**Branch**: `scratch/ibm-orpheus-flywheel-w3/worker-4-granite-embed-dedup`
**Depends on**: nothing (pure standalone)
**Deliverables**:
1. `tools/quantize/tessera/traj/embed/tessera-embed-granite.cpp` — Granite
   embedding inference. Loads `granite-embedding-small-english-r2-Q4_K_M.gguf`
   (47M, 384-dim, Apache 2.0, GGUF-available). Runs ON-Device via ANE/Metal
   or CPU fallback. Produces normalized 384-dim vectors per trajectory.
2. `tools/quantize/tessera/traj/embed/tessera-dedup-tier3.cpp` — semantic dedup
   using cosine similarity on Granite embeddings. K-means clustering (k=16 default,
   configurable), drop trajectory nearest to cluster centroid if above cosine
   threshold (default 0.87). Halt on anomaly at 35% removal rate.
3. `tools/quantize/tessera/traj/embed/CMakeLists.txt` — standalone STATIC lib,
   NO llama/ggml/DuckDB/ane dependencies. Links only `ggml` for model inference.
4. `tests/test-dedup-tier3.cpp` — synthetic embeddings, cosine sim correctness,
   halt-on-anomaly
5. `tests/test-dedup-pipeline.cpp` — full 3-tier dedup (exact + fuzzy + Granite
   semantic) on synthetic corpus, verifies tier3 integration without OOM

**Design note**: the 47M Granite embedding model is small enough that ANE inference
is realistic on Apple Silicon. The Metal/ANE backend for the RoBERTa-architecture
model needs a GGML compute graph path — this is a new model architecture for
Tessera's GGML backend, but the pattern is the same as any encoder model.

### Worker 5: tessera-traj-observe + otel + replay
**Branch**: `scratch/ibm-orpheus-flywheel-w3/worker-5-observe-otel`
**Depends on**: Workers 1+3 (train-agent must exist to tag trained_model_id)
**Deliverables**:
1. `tools/quantize/tessera/traj/tessera-traj-observe.cpp` — closed-loop capture.
   Wraps `tessera-traj-cli --mode=openhands` with `trained_model_id` field
   injected into every record's `manifest`. Writes to local storage (no egress).
   The observe stage is a capture pass over a running agent harness.
2. `tools/quantize/tessera/traj/tessera-traj-otel.cpp` — OTel GenAI span emitter.
   Emits 4-span structure (LLM, tool, memory, agent) with correct attribute keys
   per OpenTelemetry GenAI semantic conventions v1.41. Off by default.
   Compatible with Honeycomb / Langfuse / Phoenix via OTLP export.
3. `tessera-traj-cli.cpp --mode=replay` — deterministic re-execution gate.
   Reads a captured trajectory (with `env.image`, `env.git_sha`, `env.seed`),
   re-executes the same tool calls in the same order, compares outcomes.
   Exit 0 if all tool calls produce the same exit code and output hash.
   **This is the held-out test for correctness**: if a trajectory's
   tool calls don't reproduce under replay, the trajectory is bad data.

### Alphaevolve: Reserved for Optimization Phase Only

After all 5 workers land and the pipeline is proven correct end-to-end,
alphaevolve is spun for:

1. **Batch throughput**: maximize trajectories-per-second through the dedup pipeline.
   Evaluator: `time -l` RSS + throughput on a 10K synthetic corpus.
2. **Memory floor**: minimize Granite embedding inference RSS on ANE/Metal.
   Evaluator: peak RSS on 47M model inference, N>=5 runs.
3. **Token-fidelity latency**: minimize the overhead of the chat-template render
   + tokenize step in the training driver's inner loop.
   Evaluator: microseconds per trajectory, N>=100 runs.
4. **Orpheus audio batch size**: maximize audio tokens per ggml_opt batch before OOM.
   Evaluator: tokens/batch at OOM-1.

Alphaevolve is NOT spun for: correctness, architecture, schema design, or
procurement compliance. Those are human calls.

---

## Sequencing

```
Worker 1 (chat template)    ─────────────────────┐
Worker 4 (Granite embed)     ────────────────────┼── parallel, no deps
Worker 2 (Orpheus audio)     ─── depends on W1 ──┘
Worker 3 (train-agent)       ─── depends on W1 ─────────────────┐
Worker 5 (observe+otel)     ─── depends on W1+W3 ─────────────┴──
                                                         alphaevolve
```

**Rationale**: Workers 1 and 4 run in parallel (no deps). Worker 2 and 3 both
depend on Worker 1. Worker 5 depends on the trained model existing (so it has
a `trained_model_id` to tag). Workers 2 and 3 can run in parallel after W1 lands.

---

## Open Design Decisions (Require Architect Call)

1. **Orpheus GGUF availability**: Does an Orpheus GGUF exist yet, or does Tessera
   need to produce one? The Canopy/Axolotl/unsloth ecosystem produces `.bin`/`.safetensors`
   checkpoints; the IBM GGUF CI (github.com/IBM/gguf) may not cover Orpheus yet.
   This affects whether Worker 2 can test against a real model or needs a synthetic stub.
   → **Architect call needed before Worker 2 starts.**

2. **Audio PII scrub granularity**: Voice biometric anonymization can be pitch-shift
   (speaker-irreversible, but changes audio quality) or speaker embedding anonymization
   (preserves prosody, but may be reversible with a strong enough attacker model).
   The data card section 5's "on-device, layered" pipeline covers text PII;
   audio PII (voice biometric) is a separate surface. Is a pitch-shift approach
   acceptable for the procurement story, or does Tessera need a stronger guarantee?
   → **Architect call needed before Worker 2 starts.**

3. **Teacher model for agentic SFT**: The OT-Agent evidence is "smaller verbose
   teacher beats silent frontier model". Default should be the user's own inference
   stack. Does Tessera hard-code Granite 3.3 8B as the default teacher, or leave
   it as `--teacher-model` with Granite as the recommended but not enforced default?
   → **Architect call before Worker 3 starts.**
