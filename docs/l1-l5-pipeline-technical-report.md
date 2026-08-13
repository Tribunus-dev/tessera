# Tessera Runtime-Aware Calibration Pipeline (L1-L5): A Technical Report

_Author: Mavis for Julian Torres. Date: 2026-08-12. Source-of-truth audit
of the L1-L5 layer implementation against the design spec, the
research-alignment doc, and the actual on-disk code._

## Abstract

We describe Tessera's runtime-aware calibration pipeline, a six-layer
measurement-and-control loop that closes the gap between an offline
quantization reference and the C++ runtime that actually executes the
dequantization. The pipeline is motivated by an empirical observation
on a gemma-4-12B target: per-tensor mid-layer divergence between a
BF16 reference and a T640-quantized reference ran 70-150 %, even
though the sensitive tensors (QK-norm, post-norm, attn_output,
ffn_down) were individually well-calibrated. The source of the
divergence was not a per-tensor regression; it was a **fitness that
optimized the wrong reference**. The pipeline replaces the offline
round-trip fitness with kernel-dequant fidelity as the ground truth,
ties the per-tensor evolutionary search to that ground truth, and
closes the loop with adaptive requantization conditioned on a joint
perplexity probe across the target model and its spec-decoding
drafters. The implementation is in C++ (`tools/quantize/tessera/` and
`common/tessera-*`); approximately 3,200 LoC of pipeline logic on top
of the llama.cpp fork. We document the design, the as-shipped state
versus the design spec, the gap analysis, and the production findings
that bind the design to recent literature.

## 1. Problem statement

Tessera's quantizer is a T640 ternary-plus-outliers scheme with AWQ
diagonal pre-scaling, six per-tensor experts routed by a regime
classifier, and a MAP-Elites evolutionary archive indexed by regime
descriptors (kurtosis, effective rank, tensor family, modality). The
quantizer produces a T640 GGUF artifact that the llama.cpp runtime
loads and runs through the Tile640 matmul kernel.

The original calibrator used an offline round-trip fitness:
reconstruct each weight from its T640 representation, compare to the
BF16 source under `||W - R||_F^2 / ||W||_F^2`. This fitness is
correct for "did the quantizer preserve this tensor." It is incorrect
for "did the runtime preserve this tensor" because the kernel's
dequant may differ from the offline reference in F16 precision, in
order of operations, and in how outliers are folded with ternary
codebooks. Calibration that scores against the offline reference
therefore optimizes a quantity that is not the one we care about.

The empirical cost on gemma-4-12B was measurable: 70-150 % relative
divergence at layers 4, 8, 16, 32, manifesting downstream as a 0.86 %
drafter acceptance rate versus the 30-70 % range expected for working
spec decoding. The drafter was not the problem; the requantization
algorithm was.

## 2. Pipeline architecture

The pipeline has six layers, L1-L6, that form a measurement spine
plus a feedback loop. The spine is L1 -> L2 -> L3 -> L4 (read
"ground truth -> per-tensor divergence -> per-token coherence ->
end-to-end behaviour"). The loop is L4 -> L5 -> L6 (read "decide what
to requantize -> requantize -> re-evaluate the fitness against the
ground truth").

```
                   L1  (kernel-dequant sidecar: the ground truth)
                     |
                     v
        L2 (per-tensor BF16-vs-quant divergence)
                     |
                     v
        L3 (per-token / per-row coherence)
                     |
                     v
        L4 (PPL / KL end-to-end probe)
                     |
        +------------+--------------+
        |                           |
        v                           v
  L5 (adaptive requantize)    L6 (kernel-direct GA fitness)
        |                           |
        +-------+-------------------+
                v
       ts_dispatch (the wiring)
```

The layers are not parallel. L1 is the critical path: without the
kernel-dequant sidecar, every layer above it is calibrating against
the wrong reference. The 2026-07-30 research-alignment pass
re-ordered the broader Tessera roadmap around L1, promoting it from a
parallel workstream to the spine.

## 3. L1: Kernel-dequant fidelity

### 3.1 Design

L1 is a runtime hook on every Tessera matmul kernel: when
`LLAMA_TILE640_DEBUG_DEQUANT_DIR` is set, the kernel writes the
**effective dequantized weight** for each invocation to a sidecar
file. The hook is the only measurement that tells us what the
runtime is doing, not what the offline reference thinks.

The on-disk format is a versioned binary header + F32 data block,
prefixed by a magic number `TDQT`. The current version is 3. The
header carries rows, cols, dtype (F32, F16, BF16), an outlier
threshold (default 6.0, following the LLM.int8() precedent), the
total outlier count, and per-row strips carrying timing in
nanoseconds, kernel id, dispatch count, and a reserved field. The
data block is row-major F32, streamed one row at a time.

Two sidecar kinds are written. The L1 sidecar (suffix
`.dequant.f32`) carries the kernel's actual dequant. The L1.5
reference sidecar (suffix `.act.dequant.f32` or `.act.dequant.f16`)
carries the FP16 ground truth that the quantizer would have produced
in the absence of any quantization error; this is the W4A4
activation-path sidecar. The two are read together by L3 to compute
per-row coherence.

The hook is invoked from the real matmul paths in all three
backends: `ggml-cpu.c`, `ggml-cuda.cu`, and
`ggml-metal-ops.cpp`. The CLI surface is
`--tessera-dequant-dir` (or the env var
`LLAMA_TILE640_DEBUG_DEQUANT_DIR`); the mode flag
`--tessera-dequant-mode=w4a4` enables the L1.5 reference sidecar.
Stride is configurable (`--tessera-dequant-stride N`) for sparse
capture when full capture is too expensive (20 GB per 12B model per
chunk at full stride is the worst case).

### 3.2 Implementation

The hook lives in `common/tessera-debug/` (884 LoC
`tessera-debug.cpp` + 328 LoC header; plus 304 LoC
`tessera-sidecar-v3.cpp` and 641 LoC `tessera-matmul-output.cpp`).
Concurrency is handled with a recursive mutex serializing the
per-tensor open / write_rows / close sequence so concurrent Metal
addCompletedHandler blocks firing in parallel across multiple Tile640
matmuls cannot interleave their writes on the file-static
SidecarStream state. The reader (`tessera-sidecar-v3.cpp`) dispatches
on the version field so v1 / v2 / v3 files are all readable with
appropriate fallback for missing fields.

### 3.3 Acceptance state

L1 is shipped and exceeds the spec. The acceptance test
`test_l1_sidecar.cpp` validates the round-trip; `test_sidecar_v3.cpp`
validates the v3 schema. Per-tensor outlier counts, per-row timing,
kernel id, and dispatch count are present in the sidecar and consumed
by the L3 metric and the L5 orchestrator.

L1.5's FP16 ground truth has since landed, but not in the runtime
hook. The round-trip the hook could produce -- `F16(F32(dequant))` --
is not a reference at all: it collapses L3's per-row cosine to ~1.0 by
construction. The capture moved to calibration time instead:
`ts_dispatch_capture_l15_references`
(`tools/quantize/tessera/tessera-dispatch-l15.cpp`) walks the input
GGUF and writes `F16` of the **original** weight per 2D tensor, which
is the actual ground truth. The runtime hooks in all three backends
retain the old path as a no-op behind `TESSERA_L15_RUNTIME_ROUNDTRIP`
for legacy readers. Capture is gated on `w4a4` mode plus an
`l15_dtype` of `f16`; the sidecar directory resolves through
`tessera_debug::dequant_dir()`, so both `--tessera-dequant-dir` and
the env var reach it. Tested by `test_l15_capture.cpp`.

## 4. L2: BF16-vs-quantized differential

### 4.1 Design

L2 runs the same calibration corpus through the BF16 source and the
Tessera-quantized model. Per quantized tensor, it captures the
divergence between the two passes' matmul outputs and emits a JSON
report. The metrics are max-abs, mean-abs, relative Frobenius, and
per-layer norm. Tensors whose relative Frobenius exceeds 1.5x their
type's expected baseline are flagged for requantization (this is the
input to L5).

The original design called for two full forward passes with
top-1/top-5 mismatch and per-sample counts. The shipped
implementation is the offline weight-level equivalent: it compares the
dequantized Tessera weights against the BF16 source at the
quantize-tool layer, not the runtime. The header comment is explicit
that "the quantize tool cannot run full forwards."

### 4.2 Implementation

`tools/quantize/tessera/tessera-l2-diff.{h,cpp}` (97 + 229 LoC).
The `ts_l2_tensor_divergence` core computes the four metrics per
tensor; `ts_l2_expected_frob` is the type-aware baseline table (F16
< 1e-5, Q8_0 < 1e-3, Q4_K < 5e-2, Tessera-T640 < 2e-2, Tessera-T640
per-tensor GA < 1e-2); `ts_l2_run` aggregates the per-tensor inputs
into a `ts_l2_report`. The schema is `llama.tessera.runtime-probe.v2`
so the L5 adaptive requantizer (`ts_l5_adaptive_requant`) can read
the report back.

**Units (schema v2).** `relative_frobenius` is
`||W - R||_F / ||W||_F`, a norm ratio. Through schema v1 it emitted the
un-rooted energy ratio under the same field name, which made every
reported figure read about twice as good as it was. The v2 producer
takes the sqrt, and the type table entries are the sqrt of their v1
values, so a tensor at a given underlying error flags identically
before and after the correction. A v1 report converts forward as
`sqrt(v1)`; readers must check the schema string rather than the field
name to know the units.

Note that the offline GA fitness and the L6 `t_l^2` remain squared --
`t_l^2` is the Linearity-Theorem term and is *defined* as an energy
ratio, so it was not changed. The two are no longer directly
comparable; square the L2 figure first.

**The table is unfitted.** These baselines came from the design
spec's estimates, not from measurement, and they disagree with the
only measured figure available: `docs/per-tensor-calibration.md`
reports a median relative MSE of `0.18` across the 48 calibrated
tensors, roughly 9x the T640 baseline in the same convention. If the
measured number holds on a real model, every T640 tensor exceeds the
`1.5x` flag threshold in every L5 generation, and L5's "identify the
tensors that exceed their type's expected divergence" step selects
everything -- the loop still runs and still emits a well-formed
receipt, it just is not choosing. Refitting this table against a real
`runtime-probe.v2` report is item 1 of section 12.

### 4.3 Acceptance state

The weight-level differential is shipped and tested
(`test_l2l5.cpp::test_l2()` exercises the end-to-end path on a
synthetic input). The forward-pass differential has since landed as
`tools/tessera/runtime_probe.py`: it drives `llama-cli` twice (BF16
and quantized) with `--tessera-matmul-output-dir`, joins the two
`.matmul-output.f32` sidecar directories on tensor name, and emits
`max_abs` / `mean_abs` / `relative_frobenius` / `top1_mismatch` /
`top5_mismatch` per tensor as JSONL. It has not been run against a
real model pair, so the acceptance criteria (no-op F16-vs-F16 near
machine epsilon, Q4_0-vs-F16 in the baseline range) remain
undemonstrated. The 0.86 %
drafter acceptance root cause was diagnosed via this layer
on a per-tensor basis using the gemma-4-12B BF16 reference and a
Tessera-corrected candidate; the diagnosis revealed that the bulk
tensors (Q, K, V, gate, up, down) were miscalibrated, not the
sensitive tensors. That diagnosis is what motivated the per-tensor
GA + the kernel-direct fitness.

## 5. L3: Per-token (per-row) coherence

### 5.1 Design

L3 generates tokens with both BF16 and quantized models on a fixed
prompt. For each generated token, it tracks the divergence between
the two distributions: KL divergence at the position, top-1 mismatch,
top-5 overlap. A coherence test should fail (suggesting
requantization) if average KL > 0.1, or top-1 mismatch > 5 %, or any
mismatch in the first five tokens.

The shipped analogue is per-row weight-level cosine: for each tensor
that has both an L1 kernel-dequant sidecar and an L1.5 reference
sidecar, compute the cosine similarity between the kernel's
reconstructed row and the reference row. Rows below the threshold
(default 0.99) are flagged.

### 5.2 Implementation

`tools/quantize/tessera/tessera-l3-coherence.{h,cpp}` (69 + 156 LoC).
`ts_l3_row_cosine` is the per-row metric with the zero-vector
edge-case handled. `ts_l3_tensor_coherence` aggregates per-row
cosines into a per-tensor summary (mean, min, flagged row count).
`ts_l3_run` walks the sidecar directories and processes all tensors
that have BOTH sidecars; tensors missing either sidecar are
skipped. Tested via `test_l2l5.cpp::test_l3()`.

### 5.3 Acceptance state

The per-row weight-level analogue is shipped. The full per-token
KL/top-1/top-5 path (`tools/tessera/per_token_coherence.py`) is not
shipped. `ts_l3_run` is no longer blocked: with the calibration-time
L1.5 capture in place (section 3.3) both sidecars exist and the
per-row cosine is a real measurement rather than a trivial 1.0. It
has not been run against a real model, so there is no measured
distribution of per-row cosines to set the 0.99 flag threshold
against; the threshold is still a guess.

## 6. L4: End-to-end probe

### 6.1 Design

L4 is a short, deterministic 30-50 token generation run that
answers the "is this model coherent?" question with a single number.
The original design called for a prompt bank (`paris.txt`,
`gsm8k-easy.txt`, `multi-turn.txt`, `code.txt`) with exact-match
matchers, perplexity-delta, and logit-rank correlation. The shipped
implementation is a data-free PPL/KL substitute: random tokens, both
forwards, KL + PPL metrics over the logits.

### 6.2 Implementation

`tools/quantize/tessera/tessera-ppl.{h,cpp}`. The data-free probe is
`ts_ppl_probe(forward_ref, ref_ctx, forward_quant, quant_ctx, params,
result)` and computes `kl_divergence` (KL of the reference
distribution vs the quantized distribution, in nats), `ppl_ratio`
(PPL_quant / PPL_ref), `delta_ppl` (PPL_quant - PPL_ref), and
`n_tokens_used`. The L4 smoke test `ts_ppl_compare` wraps this with
a pass/fail verdict against a 0.5 threshold. Tested via
`test_l2l5.cpp::test_l4()` on synthetic uniform-vs-peaked logits.

### 6.3 Acceptance state

The data-free PPL/KL substitute is shipped and tested. The prompt
bank and its driver have since landed as `tools/tessera/prompts/`
(the four prompts the spec names, plus a `bank.json` manifest) and
`tools/tessera/e2e_probe.py`.

The driver differs from the spec in two ways, both deliberate. The
reference is the BF16 model's own greedy continuation rather than a
stored expected string, so the bank does not go stale when the source
checkpoint changes. And `perplexity_delta` plus the rank metric reuse
`llama-perplexity --kl-divergence` rather than a reimplementation:
the probe saves BF16 logits, scores the quantized model against them,
and parses `Mean PPL(Q)-PPL(base)`, `Mean PPL(Q)/PPL(base)`,
`Mean KLD`, and `Same top p`. That last figure -- top-1 agreement --
substitutes for the spec's `logit_rank_correlation`, which would
require a top-K logit export that does not exist today.

Verdict is PASS / WARN / FAIL with exit codes 0/1/2, and 3 for
harness errors so CI can separate "the model regressed" from "the
probe broke". A failure to parse the `llama-perplexity` summary is a
hard error rather than a defaulted zero, since a silently-zero
divergence reads as a perfect score.

This is the only shipped layer that closes on behaviour rather than
on weight-space or perplexity proxies. It has not been run against a
real model pair, so the design spec's acceptance criteria (L4 PASS on
a Tessera-corrected build, <5 min on 12B) remain undemonstrated.

## 7. L5: Adaptive requantization

### 7.1 Design

L5 takes the L2 report (per-tensor divergence) plus the L4 outcome,
identifies the tensors that exceed their type's expected divergence,
and re-runs the per-tensor GA on them with kernel-based fitness (L6).
It applies the new policy, re-measures, and iterates until L4 passes
or no further improvement is observed.

The shipped implementation has two paths:

1. **Weights-only adaptive requant (legacy)**: `ts_l5_adaptive_requant`
   reads an `ts_l2_report`, finds flagged tensors, and tightens
   `alpha` and `clip` proportional to the overshoot, emitting an
   `ts_l5_adaptive_plan`. The dispatch
   (`ts_dispatch_run_l5_loop` in `tessera-dispatch.cpp`) re-quantizes
   flagged tensors in place, refreshes GGUF descriptors via
   `ts_gguf_repoint_tensor_cluster`, and re-measures. Loop receipt
   at `<stem>.l5-loop.json`, schema `llama.tessera.l5-loop.v1`.

2. **Joint PPL requant (production default)**: `ts_l5_joint_search`
   runs a coarse-to-fine search over a joint policy space across
   the target model and its spec drafters (DFlash, DSPark, MTP) and
   talker. The search is a generational MAP-Elites-style loop with
   per-model AND-gate, adaptive slippery detection (epsilon/5), and
   a strict-mode re-evaluation at 0.25 % for the acceptance gate.
   Loop receipt at `<stem>.l5-joint.json`, schema
   `llama.tessera.l5-joint-loop.v1`.

The two paths are independent and can run in the same dispatch
during the transition period. The joint path is the production
default (`l5_joint_mode = true`); the weights-only path is the
fallback for `--no-tessera-l5-joint`.

### 7.2 Sensitivity scoring (weights-only path)

`tools/quantize/tessera/tessera-l5.{h,cpp}` (148 + 408 LoC).
Scorers are `ts_l5_imatrix_magnitude` (mean of |act| per tensor),
`ts_l5_gradient_proxy` (proxy from output sensitivity),
`ts_l5_layer_position_prior` (earlier/later layers get different
priors), and `ts_l5_combine` (weighted combination). EMA tracker
for streaming updates. Percentile-rank normalization. Top-fraction
picker. Quantization ladder (`ts_l5_step_up` / `ts_l5_step_down`)
for stepping between qtype tiers. Generational orchestrator
`ts_l5_orchestrate_step`. Tested via `test_l5.cpp` and
`test_l2l5.cpp`.

### 7.3 Joint PPL search (production path)

`common/tessera-l5-joint.{h,cpp}` (246 + 497 LoC) and
`common/tessera-ppl-harness.{h,cpp}` (346 + 591 LoC). The harness
holds the 5 model contexts (target, DFlash, DSPark, MTP, talker)
plus per-model vocab sizes and the target-layer-id for each drafter.
The forward functions are model-specific: the trunk uses
`llama_decode` directly; each drafter consumes the trunk hidden
state at its `target_layer_id`; the talker consumes the trunk
output. The 5 forwards run in one joint forward pass; the per-model
PPL is extracted via the existing `ts_ppl_perplexity` helper.

The search is coarse-to-fine:

- **Gen 0**: sample N joint policies from a coarse grid of
  `(outlier_layout, algorithm)` per family; alpha/clip seeded
  uniformly.
- **Gen 1+**: refine top-K with continuous alpha/clip search around
  the winning `(outlier_layout, algorithm)` per family.
- **Slippery detection**: if per-gen PPL improvement < `epsilon/5`,
  switch that model to evolutionary (1-2 gens of mutation + crossover
  on the `(outlier_layout, algorithm, alpha, clip)` tuple).
- **Termination**: AND-gate across all active models' deltas, AND
  top-K PPL deltas within `delta_converged` of each other.

The 7 families are `attn_q`, `attn_k`, `attn_v`, `attn_out`,
`ffn_gate`, `ffn_up`, `ffn_down`. The 5 models are target, DFlash,
DSPark, MTP, talker. The 3 outlier layouts are per-row (current
T640 default), per-block, per-tensor. The search keeps `top_k` (4
default) entries by ascending `joint_ppl`, where `joint_ppl` is the
metric over the active models' per-model deltas.

The default metric is **MAX**: the worst active delta drives the
search. This guarantees every active model gets full optimization
when it is the worst case. Under the SUM metric, the model with
the largest absolute delta (typically the target) dominates the
ranking and the smaller-delta models (typically the drafters) are
shaded. The AND-gate is enforced independently of the metric - it
is the binary termination criterion. MEAN is the count-normalized
variant of SUM. The metric is configurable (`--tessera-l5-metric`)
and recorded in the JSON report.

The strict-mode acceptance gate (`ts_l5_joint_strict_pass`) takes
the winning policy from the standard pass (default `epsilon = 0.99 %`)
and re-evaluates at `0.25 %`. Status is either `STRICT_CONVERGED`
(all per-model deltas < 0.25 %) or `STRICT_BEST_EFFORT` (at least
one delta above 0.25 %).

### 7.4 Acceptance state

L5 is on the dispatch path. The loop receipt is emitted for every
run; the JSON report includes per-generation `n_flagged`,
`n_requant`, per-family winning stage, and per-tensor before/after
`relative_frobenius`. Tests: `test_l5.cpp` for the sensitivity
scorers and orchestrator; `test_l2l5.cpp` for `ts_l5_adaptive_requant`
end-to-end; `test_l5_dispatch.cpp` for the full dispatch pipeline on
a synthetic two-tensor GGUF (asserts the loop runs, the report is
well-formed, and the output GGUF survives in-place re-quantization);
`test_l5_joint.cpp` for the joint PPL path.

Source weights are re-read from the input GGUF per flagged tensor
per generation, keeping the L5 memory budget flat at the cost of one
read per flagged tensor.

## 8. L6: Kernel-based GA fitness

### 8.1 Design

L6 replaces the offline `_ternary_reconstruct` reference in the GA's
fitness evaluation with the actual kernel dequant captured in L1. The
GA then optimizes for the deployed fidelity, not the offline
reference. The per-tensor term is

```
t_l^2 = ||dequant_kernel(W_l) - W_l||_F^2 / ||W_l||_F^2
```

and the cross-tensor GA objective is `Sum_l alpha_l * t_l^2`, where
`alpha_l` is the method-independent layer coefficient estimated once
per model by HIGGS calibration (perturb each layer, measure PPL
response) and cached in the sidecar / policy.

The design is the ground-truth instantiation of the **Linearity
Theorem** from HIGGS (arXiv:2411.17525): in the medium-bitwidth,
locally-smooth regime,
`E[PPL(W_hat)] ~= PPL(W*) + Sum_l alpha_l * t_l^2`. QEP
(arXiv:2504.09629) is the off-switch - the cross-layer error
propagation it captures only pays off sub-3-bit, and TESSERA_T640 v1
is not in that regime.

The original plan was to add `fitness = "kernel-direct"` to the
Python `per_tensor_calibrate.py`. The shipped implementation is in
the **C++ dispatch GA** instead. The Python `--fitness` choices
remain `awq`, `lrq`, `flrq`, `dartquant`, `compare`; the
kernel-direct mode is consumed by `ts_dispatch_run` at lines 263-294
(per-candidate kernel-direct `t_l^2`, blended with the offline proxy
via `blend_factor`), 725-742 (enable from `params->kernel_fitness`),
and 833-858 (A/B harness report). The CLI subcommand is
`kernel-fitness` with `--enabled`, `--dir`, `--blend` flags.

### 8.2 Implementation

`tools/quantize/tessera/tessera-l1-fitness.{h,cpp}` (67 + 129 LoC).
`ts_l1_load_sidecar` reads the v3 sidecar via `ts_sidecar_v3_read`.
`ts_l1_kernel_direct_t2` computes the per-tensor term
`||W_hat - dequant_kernel||_F^2 / ||W||_F^2` (F64 accumulator for
numerical stability on large tensors; F32 result). `ts_l1_blended_t2`
interpolates between offline and kernel-direct. `ts_l1_compute_all_t2`
batches the computation across all tensors, falling back to the
offline proxy for tensors without a sidecar. Tested via
`test_l1_fitness.cpp`.

### 8.3 Acceptance state

L6 is effective in the GA scoring path and, since the
`ts_dispatch_kernel_direct_t2` helper landed, in the dispatch
acceptance verdict as well: the verdict measures the real
kernel-direct `t_l^2` from the L1 sidecar and falls back to the
offline composite only when no sidecar is present.

The first version of that fix was live on the serial acceptance
branch only. The gate evaluates tensors serially when
`work.size() < 2` and on a thread pool otherwise, and the pool branch
passed a null source buffer, so the helper returned its
"no measurement" sentinel and every tensor fell back to the offline
proxy. Production always takes the pool branch. The consequence was
worse than a silent no-op: `ranking_disagreement` is
`1 - |kendall_tau|` over the offline-vs-kernel-direct rankings, so
identical arrays gave `tau = 1`, `disagreement = 0`,
`novelty_survives = false` -- the G6 gate could never pass. The helper
now takes a single `w` pointer so the two branches cannot diverge, and
`test_l5_dispatch.cpp` covers the pool path with a four-tensor fixture
and synthetic v3 sidecars.

## 9. The wiring: `ts_dispatch_run`

The layers are wired together in
`tools/quantize/tessera/tessera-dispatch.cpp` (3,571 LoC; 85
`ts_dispatch_` entry points). The dispatch is a 11-step state machine:

| Step | What it does | Source |
|------|--------------|--------|
| 1 | Determine which steps to run from flag presence | `tessera-dispatch.cpp:1487` |
| 2 | Calibration (imatrix) | `tessera-dispatch.cpp:1491` |
| 3 | GA configuration (knobs -> params) | `tessera-dispatch.cpp:1583` |
| 4 | Resolve alpha (per-tensor or uniform) | `tessera-dispatch.cpp:1688` |
| 4b | Read calibration policy if any | `tessera-dispatch.cpp:1693` |
| 5 | Load input GGUF | `tessera-dispatch.cpp:1717` |
| 5b | HIGGS alpha_l estimation / cache lookup | `tessera-dispatch.cpp:1796` |
| 5c | Evolutionary per-tensor alpha search (GA) | `tessera-dispatch.cpp:1875` |
| 6 | Prepare output GGUF | `tessera-dispatch.cpp:2320` |
| 7 | Walk tensors, quantize or copy through | `tessera-dispatch.cpp:2367` |
| 7a | L5 joint PPL loop (production default) | `tessera-dispatch.cpp:2909` |
| 7a-legacy | L5 weights-only requant (fallback) | `tessera-dispatch.cpp:2942` |
| 7b | G6 acceptance gate | `tessera-dispatch.cpp:2954` |
| 8 | Write Tessera metadata | `tessera-dispatch.cpp:3141` |
| 9 | Write output GGUF | `tessera-dispatch.cpp:3157` |
| 10 | Write policy JSON alongside | `tessera-dispatch.cpp:3174` |
| 11 | Populate summary | `tessera-dispatch.cpp:3203` |

Step 7 captures per-tensor metadata into a `ts_dispatch_refine_entry`
map so the L5 refine loop can re-target flagged tensors without
re-walking the GGUF. Source weights are re-read from the input GGUF
per flagged tensor per generation, keeping memory flat.

The 6 regime experts (AWQ, LRQ, DartQuant, FLRQ, CHAMP-Q, SEPTQ) are
routed per-tensor by `tessera-regime.cpp` based on
`ts_regime_compute_descriptor` (kurtosis, eff_rank, max_outlier_ratio,
family, modality). The MAP-Elites archive is indexed by
`(kurtosis_bucket, eff_rank_bucket, family_bucket)`. DuckDB
(`tessera.duckdb`) provides warm-start across runs and crash-resume.

## 10. Comparison to the design spec

| Layer | Spec | Shipped | Gap |
|------|------|---------|-----|
| L1 | Kernel hook + sidecar; 12-20 GB per chunk | v3 TDQT with per-row outliers, timing, kernel_id, dispatch_count, provenance | None |
| L1.5 | FP16 reference sidecar | Calibration-time capture of `F16(original weight)` via `ts_dispatch_capture_l15_references`; runtime round-trip retained as an opt-in no-op | Never run against a real model |
| L2 | Forward-pass differential with top-1/top-5 mismatch | Weight-level differential in C++; forward-pass differential in `tools/tessera/runtime_probe.py` | `runtime_probe.py` unexercised against a real model pair |
| L3 | Per-token KL, top-1 mismatch, top-5 overlap | Per-row weight-level cosine | Token-level variant (`per_token_coherence.py`) not shipped; 0.99 threshold unfitted |
| L4 | Prompt bank, exact-match, perplexity-delta, logit-rank correlation | Data-free PPL/KL substitute in C++; prompt bank + `e2e_probe.py` (exact-match, PPL delta, KLD, top-1 agreement) | Never run against a real model pair; rank correlation approximated by top-1 agreement |
| L5 | Adaptive requant, schedule L2 -> GA -> apply -> L4 | Two paths shipped: weights-only `ts_l5_adaptive_requant` and joint PPL `ts_l5_joint_search` | Loop terminates on L2 weight-level `relative_frobenius`, not the L4 prompt probe; flag thresholds unfitted (section 12 item 1) |
| L6 | Per-tensor `t_l^2` against L1 sidecar | `ts_l1_kernel_direct_t2` + `ts_l1_blended_t2` in the C++ dispatch GA and in the acceptance verdict; Python `--fitness` choices remain offline | None |

The headline gap is no longer plumbing. L1, L1.5, L2, L5, L6 are on
the critical path and wired end to end; L3 has a weight-level
analogue and L4 a data-free one. What is missing is **evidence**:
none of these layers has been run against a real model pair, so
every threshold in the pipeline (L2's per-type expected Frobenius,
L3's 0.99 cosine, L4's 0.5 PPL verdict) is an unfitted guess, and
the acceptance criteria that require a real run (L4 PASS on a
Tessera-corrected build, <5 min on 12B) remain undemonstrated.

## 11. Findings that bind the design to recent literature

The 2026-07-30 research-alignment pass surfaced five results that
bind the L1-L6 design to external evidence:

1. **Linearity Theorem (HIGGS, arXiv:2411.17525)**: the L6
   kernel-direct `t_l^2` is the ground-truth instantiation of the
   per-layer relative Frobenius term in the Linearity-Theorem
   decomposition. The cross-tensor aggregation
   `Sum_l alpha_l * t_l^2` is the GA objective.

2. **QEP off-switch (arXiv:2504.09629)**: the Linearity Theorem
   holds in the medium-bitwidth, locally-smooth regime. Cross-layer
   error propagation (QEP) is the off-switch - it only pays off
   sub-3-bit. TESSERA_T640 v1 is not in that regime, so QEP is
   excluded. The acceptance gate hardcodes this. The W4A4 path is
   the regime where the off-switch most likely needs revisiting.

3. **Regime axes select the method, not just the difficulty**:
   kurtosis, outlier localization (DuQuant: down_proj), effective
   rank, tensor family, and architecture paradigm are empirically
   predictive of which transform wins. The L5 requant planner and
   the L6 fitness report carry the regime descriptors per tensor so
   the adaptive loop can route experts, not just re-run one GA
   uniformly. The 4-tier dynamic router in `tessera-regime.cpp`
   instantiates this: Tier 1 is zero-cost (tensor role + layer
   position); Tier 2 is activation stats (imatrix kurtosis/eff_rank
   from DuckDB learned priors); Tier 3 is per-expert search (MoE
   per-expert regime); Tier 4 is L5 feedback (DuckDB `l5_outcome`
   feeds OLS for threshold refit).

4. **All search-based quantization prior art searches discrete
   bit-widths**: HAQ, RAMP, FracBits, Q-Palette, QuantEA, EvoPress
   all assign bit widths. Nobody runs an evolutionary search over
   continuous per-tensor reconstruction knobs (AWQ alpha, rotation
   angles, smoothing `s`, low-rank factors). The L1-L6 pipeline
   exploits this granularity: it searches over the continuous
   `(ternary_threshold, outlier_fraction, awq_alpha, awq_clip,
   moment_mix, tail_guard)` space per tensor, plus the joint
   `(outlier_layout, algorithm_id, alpha, clip)` space across the 7
   families and 5 models.

5. **Quality-diversity is the natural GA architecture for a
   regime-conditioned objective**: MAP-Elites keeps the best
   configuration per region of a descriptor space. The descriptor
   space in Tessera is the regime axes; the archive stores the
   best reconstruction-knob config per regime cell. The shipped
   MAP-Elites archive is indexed by
   `(kurtosis_bucket, eff_rank_bucket, family_bucket)`.

The novelty is the composition, not any component. Evolutionary
search over continuous reconstruction knobs, scored against actual
kernel-dequant fidelity, conditioned on regime descriptors. Each
piece is prior art; this exact composition is not.

## 12. What's left to ship

The L1.5 FP16 ground truth (was item 1) and the L6 acceptance verdict
path (was item 4) have shipped; see sections 3.3 and 8.3. What
remains, in priority order:

1. **Fit the L2 flag thresholds to a real model**. `ts_l2_expected_frob`
   returns `1.4142e-1` for T640 (v2 norm-ratio units) and L5 flags at
   `1.5x` that, but `docs/per-tensor-calibration.md` reports a median
   relative MSE of `0.18` across the 48 calibrated tensors -- `0.42` in
   v2 units, roughly 3x the T640 entry.
   If the measured value is right, every T640 tensor is flagged in
   every generation and L5's tensor selection degenerates into
   "requantize everything" while still emitting a well-formed
   receipt. Dump the `relative_frobenius` distribution from a
   `llama.tessera.runtime-probe.v2` report on a real model and refit
   the table. Estimated: 1 day once a model pair is available; this
   gates the meaning of every L5 receipt produced so far.

2. **Wire L4 into the L5 termination criterion.** The prompt bank and
   `e2e_probe.py` now exist (section 6.3), but L5 still terminates on
   the L2 weight-level `relative_frobenius` (weights-only path) or on
   per-model PPL deltas (joint path). Neither consults the behavioural
   probe, so the loop can still converge on a model that fails L4.
   Closing this is what the original design meant by "L2 -> GA ->
   apply -> L4".

3. **One end-to-end run on gemma-4-12B**. Every layer is wired but
   none has been run against a real model pair. The number that
   matters is drafter acceptance recovery against the 0.86 %
   baseline, plus a PPL delta. Publish it either way. This also
   supplies the data for item 1 and exercises `runtime_probe.py`.

4. **L3 per-token KL on real models**. The weight-level cosine is
   shipped and unblocked; the per-token KL path is the next step.
   Requires the joint forward pass harness from L5. Estimated: 3-5
   days, ties L3 to the L5 harness.

5. **HIGGS alpha_l estimation**. The cross-tensor coefficient
   `alpha_l` in the Linearity-Theorem aggregation is currently a
   uniform default. The HIGGS calibration (perturb each layer,
   measure PPL response) is the principled estimator. The DuckDB
   cache key is in place. Estimated: 1 week, the perturb-and-measure
   loop is the bottleneck.

6. **Per-expert MoE calibration**. The MoE path is a discovered gap
   in the 2026-08-08 design doc: per-expert stats, per-expert regime
   routing, per-expert evolutionary search, kernel-direct fitness
   per expert, and a flattened 3D GGUF that loaders actually read.
   Estimated: 2-3 weeks, requires 5 (HIGGS).

The L5 joint PPL path is the production default and is in good
shape structurally. The centre of gravity of the remaining work has
moved: it is no longer plumbing but calibration of the pipeline's own
thresholds against real data, plus the behavioural probe (L4) that
none of the shipped layers substitutes for.

## 13. Reproducibility

Every dispatch run is deterministic via `--tessera-evolve-seed`.
The sidecar files are append-only; the JSON reports
(`llama.tessera.runtime-probe.v2`, `llama.tessera.l5-loop.v1`,
`llama.tessera.l5-joint-loop.v1`) carry provenance: model paths,
corpus hash, kernel version, main tip, GA seed. The DuckDB store
records one row per run / tensor / GA result / L4 plan outcome and
is the cross-run warm-start.

## 14. Conclusion

The runtime-aware calibration pipeline replaces the offline
round-trip fitness with kernel-dequant fidelity as the ground
truth, ties the per-tensor evolutionary search to that ground truth,
and closes the loop with adaptive requantization conditioned on a
joint perplexity probe across the target model and its spec-decoding
drafters. The shipped implementation covers the critical path
(L1, L2, L5, L6); the verification layers (L3, L4) have shipped
analogues but lack the forward-pass and prompt-bank instantiations.
The L5 joint PPL path is the production default and is the basis
for the acceptance gate; the L5 weights-only path is the legacy
fallback. The remaining work is the L1.5 FP16 ground truth, the
per-token / prompt-bank verifications, and the principled HIGGS
alpha_l estimator. None of the unblockers is large; the spine is
in place.

## Appendix A: File inventory

| Layer | File | LoC |
|-------|------|----:|
| L1 + L1.5 | `common/tessera-debug/tessera-debug.{h,cpp}` | 1,213 |
| L1 | `common/tessera-debug/tessera-sidecar-v3.{h,cpp}` | 365 |
| L1.5 / L2 forward-pass analogue | `common/tessera-debug/tessera-matmul-output.{h,cpp}` | 820 |
| L2 | `tools/quantize/tessera/tessera-l2-diff.{h,cpp}` | 326 |
| L3 | `tools/quantize/tessera/tessera-l3-coherence.{h,cpp}` | 225 |
| L4 | `tools/quantize/tessera/tessera-ppl.{h,cpp}` | ~200 |
| L5 weights-only | `tools/quantize/tessera/tessera-l5.{h,cpp}` | 556 |
| L5 joint | `common/tessera-l5-joint.{h,cpp}` | 743 |
| L5 joint harness | `common/tessera-ppl-harness.{h,cpp}` | 937 |
| L6 | `tools/quantize/tessera/tessera-l1-fitness.{h,cpp}` | 196 |
| Wiring | `tools/quantize/tessera/tessera-dispatch.{h,cpp}` | 3,571 + 200 |
| Total L1-L6 implementation | | ~9,350 LoC |

Plus the regime router (`tessera-regime.{h,cpp}`), the per-tensor GA
(`tessera-awq.{h,cpp}`), the 6 expert ports
(`tessera-{lrq,septq,champq,dartquant,flrq,peqat}.{h,cpp}`), the
DuckDB store (`tessera-quantize-db.{h,cpp}`), and the GGUF writer
(`tessera-gguf-writer.cpp`).

## Appendix B: Acronyms

- **AWQ**: Activation-aware Weight Quantization (Lin et al., 2023)
- **AND-gate**: binary pass criterion - all active models' deltas
  below epsilon
- **BF16**: Brain Float 16 (1 sign + 8 exponent + 7 mantissa bits)
- **CHAMP-Q**: Channel-ware Mixed-Precision Quantization
- **DartQuant**: rotation-based quantization (Tseng et al., 2024)
- **DFlash / DSPark**: DFlash is an EAGLE-style feature-conditioned
  drafter; DSPark adds a Markov head on top
- **DuckDB**: in-process analytical database used for the warm-start
  store (`tessera.duckdb`)
- **FLRQ**: Fast Low-Rank Quantization
- **GA**: Genetic Algorithm (the per-tensor evolutionary search)
- **GGUF**: GGML Universal Format (the file format for llama.cpp
  models)
- **HIGGS**: the Linearity-Theorem result (arXiv:2411.17525)
- **imatrix**: importance matrix - per-channel `E[x^2]` from the
  calibration corpus
- **L1 - L6**: the six pipeline layers
- **LRQ**: Low-Rank Quantization
- **MAP-Elites**: a quality-diversity evolutionary algorithm
  (Mouret & Clune, 2015)
- **MoE**: Mixture of Experts
- **MTP**: Multi-Token Prediction
- **PE-QAT**: Parameter-Efficient Quantization-Aware Training
- **PPL**: Perplexity
- **Q4_K, Q5_K, Q6_K, Q8_0**: GGML k-quant formats
- **QEP**: Quantization Error Propagation (arXiv:2504.09629)
- **SEPTQ**: Sensitivity-Equipped Pruning-Tuning Quantization
- **SLERP**: spherical linear interpolation
- **TDQT**: Tessera Dequant sidecar format (magic number, v3)
- **T640**: Tessera's ternary + outlier 4-bit weight format
- **vDSP**: macOS Accelerate vector digital signal processing API
- **W4A4**: 4-bit weight, 4-bit activation (the activation
  quantization path)
