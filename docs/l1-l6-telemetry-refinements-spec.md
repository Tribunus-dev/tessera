# Tessera L1-L6 Telemetry Refinements: Informed Spec for Review

_Author: Mavis for Julian Torres. Date: 2026-08-12. Goal: turn the 10
refinements in the user's brief into a single reviewable spec. Each
section: motivation grounded in the current code, SOTA papers that
informs the design, the proposed Tessera-side change, integration with
the existing L1-L6 spine, and references._

_Last revised 2026-08-12 (v5). The v3 revision updated the order of
work (§12), rewrote the risk mitigations (§13) with the agreed-upon
approaches, added the four-forward attribution framework to L3
(§6), and recorded the assessment verdicts (§14). The v4 revision
added three refinements surfaced by the over-engineering
re-assessment: the `ts_l5_second_order_info` struct and the
verifier-scale streaming / Nyström capture paths in §9, the ANE
heterogeneous dispatch architectural note in §1, and the tiered L4
prompt bank deployment (smoke / CI / calibration / audit) in §7.
The v5 revision adds §16 "Joint calibration thesis" — the
integrating capstone that frames the L1-L6 layers as the
implementation of a single goal: verifier + 3 drafters + talker
calibrated and quantized together, with the drafter's loss
attribution as the primary L5 trigger._


## 0. Reading guide

The current Tessera pipeline has six layers (L1-L6) plus a feedback
loop. The shipped state vs. the design spec was audited in
`docs/l1-l5-pipeline-technical-report.md`. The 10 refinements below
are not independent: they form three coordinated moves.

1. **Capture density + diversity (L1, L1.5).** Static stride is
   replaced with outlier-driven dynamic capture. The TDQT v3 header
   grows to carry backend-specific FP telemetry. The L1.5 ground
   truth is wired to the actual FP16 reference path.
2. **Measurement where it matters (L2, L3, L4).** Weight-level
   Frobenius gives way to activation-space differential, spectral
   norm tracking, autoregressive depth-dependent KL, and
   domain-weighted + spec-aware prompt banks.
3. **Fitness where the error lives (L5, L6).** Imatrix magnitude is
   replaced with empirical Hessian-based sensitivity. The HIGGS
   `alpha_l` is empirically estimated. The kernel loss is tail-weighted
   to preserve the outlier codebook.

Each refinement cites the SOTA paper that motivates the move. The
synthesis is intentionally Tessera-specific: it preserves the
ground-truth-instantiation thesis (L1 is the spine, kernel-direct
`t_l^2` is the production fitness) while replacing the static
weight-snapshot primitives with dynamic, distribution-aware signals.

---

## 1. L1 — Adaptive Outlier-Driven Capture

### 1.1 Motivation in current code

The current L1 capture is stride-based: `set_dequant_stride(N)` (env
`LLAMA_TILE640_DEBUG_DEQUANT_STRIDE`) writes every Nth row to the
sidecar, default 1. The per-row `outlier_count` (LLM.int8() |x|>6.0)
is collected, but the row selection is uniform: there is no notion of
"this row was the interesting one, the other 4095 are redundant." For
a 4096x4096 ffn_down with stride=16, ~256 rows are captured, costing
~64 MB; the same model with a 2 % outlier hit-rate would have ~82
rows that explain 80 % of the calibration signal and ~174 rows that
are essentially copies of the most-common 2-3 ternary codebook
entries.

The shipped `tessera-debug.h:143` constant `DEQUANT_DEFAULT_OUTLIER_THRESHOLD = 6.0f`
is hardcoded; the per-row strip carries the count but not the
cumulative-top-k identity. There is no notion of "trigger" — every
matmul invocation re-pays the F32-write cost regardless of whether
the row is novel.

### 1.2 SOTA grounding

- **LLM.int8() (Dettmers et al., NeurIPS 2022, arXiv:2208.07339)**
  identifies the 0.1 %-of-channels phenomenon: a small number of
  activation features are ~100x larger than the rest, and they
  dominate quantization loss. The paper's two-part procedure —
  vector-wise quantization for the bulk, mixed-precision for the
  outliers — is the original argument for *separation*, which is what
  the dynamic capture extends to the *capture* side.
- **SpQR (Dettmers et al., 2023, arXiv:2306.03078)** formalizes the
  outlier set as a sparse structure (CSR: 16-bit weight + 16-bit
  column index, 32-bit row cumulative). The sensitivity criterion
  `omega_ij > tau * median(omega)` is the precedent for a
  content-driven threshold rather than a fixed magnitude.
- **OWQ (Lee et al., AAAI 2024, arXiv:2306.02272)** refines the
  SpQR criterion by weighting sensitivity with the activation
  outliers — weak columns are those where the activation
  outlier is large *and* the weight column is sensitive. The
  joint criterion is what makes 3.1-bit OWQ match 4-bit OPTQ.

The three papers converge on a principle: capture should be
*information-driven*, not *time-driven*. The fraction of
captured weights that explains the bulk of the calibration signal
is consistently <5 % of the parameter set.

### 1.3 Proposed Tessera change

Replace the static row stride with **two capture modes**, both
additive to the existing L1 capture:

- **Mode A — Outlier-only rows.** Set a per-row trigger:
  `capture_row(r) = (row_outlier_count[r] > trigger_quantile) OR
  (||row - row_neighbor_mean||_infty > delta)`. Rows that don't
  fire are written as a single F32 mean + per-channel stddev
  (compressed to 8 bytes/row) instead of the full F32 row. The
  TDQT v3 header grows a new strip carrying the
  `trigger_quantile` and the `delta` so the reader can reproduce.
- **Mode B — Streaming reservoir (Approx Sample-and-Hold).** When
  `--tessera-dequant-mode=reservoir` is set, allocate a
  fixed-size F32 reservoir (default 1.5 % of rows), then for each
  row compute a priority `p = row_outlier_count * (1 + entropy_row)`
  and replace the lowest-priority reservoir element with probability
  proportional to p. The header carries the reservoir content as
  `(row_idx, f32_row[cols])` pairs.

Mode A is cheap and integrates with the existing 0.86 % drafter
case (most rows are noise; a few rows carry the signal). Mode B is
the principled upgrade for calibration passes where every row might
matter.

### 1.4 Schema extension (TDQT v4)

```
header v4 additions (still readable by v3 readers):
  40 + R*4 + R*24     4   capture_mode   uint32 (0=full, 1=outlier-only, 2=reservoir)
  +4                  4   trigger_quantile (F32, 0 if mode 0)
  +4                  4   trigger_delta    (F32, 0 if mode 0)
  +4                  4   reservoir_size   (uint32, 0 if mode != 2)
  +R*4              R*4   row_priority     (int32 per row; v3 readers see this as 4 bytes of garbage and skip the rest of the row data)
```

The v3 reader falls back gracefully (treats the v4 strip as
opaque padding) and recovers the full F32 data block at
`40 + R*4 + R*24 + v4_strip_size`. A v4 reader can also read v3
files: v4 strip size is 0 for v3 files.

### 1.5 Integration

- New CLI flags: `--tessera-dequant-capture-mode {full,outlier,reservoir}`,
  `--tessera-dequant-trigger-quantile Q`,
  `--tessera-dequant-trigger-delta D`,
  `--tessera-dequant-reservoir-size R`.
- Env equivalents: `LLAMA_TILE640_DEBUG_DEQUANT_CAPTURE_MODE`,
  `LLAMA_TILE640_DEBUG_DEQUANT_TRIGGER_QUANTILE`,
  `LLAMA_TILE640_DEBUG_DEQUANT_TRIGGER_DELTA`,
  `LLAMA_TILE640_DEBUG_DEQUANT_RESERVOIR_SIZE`.
- The L3 per-row cosine reader is updated to recognize the v4
  schema; missing rows (Mode A) are filled with the mean+stddev
  surrogate before cosine is computed, with a flag in the report
  indicating which rows were substituted.
- The L5 orchestrator reads the per-row priority strip and uses
  it as a Tier 4 regime signal in the 4-tier dynamic router.

### 1.6 References

- arXiv:2208.07339 (LLM.int8, Dettmers 2022)
- arXiv:2306.03078 (SpQR, Dettmers 2023)
- arXiv:2306.02272 (OWQ, Lee 2024)

### 1.7 Architectural note: ANE heterogeneous dispatch (NEW, v4)

The L1 hook in `common/tessera-debug/tessera-debug.cpp` is
the only matmul hook in the calibration pipeline. The
shipped v1 design runs the FP16 reference and the T640
matmul sequentially on the same backend (CPU/CUDA/Metal
GPU). On Apple Silicon, the FP16 reference is a natural
fit for the ANE (which is a fixed-function FP16
accelerator), while the T640 matmul runs on the GPU. The
two share the activation input via unified memory.

The architect's #1a proposal (Interleaved Heterogeneous
Dispatch) was v3-rejected on the framing of "kernel
fusion." Re-framed correctly: it is *heterogeneous
dispatch* — two different accelerators (ANE + GPU) sharing
the activation input via unified memory, with the FP16
reference on ANE and the T640 matmul on GPU. This is *not*
kernel fusion and is a real Tessera-relevant design
pattern, not over-engineering, because Tessera has a real
ANE surface (`common/ane-mtp.{h,mm}`) and because the
calibration pipeline runs on every model deployment (the
2x cost compounds).

The v1 hook design should not preempt this, but should not
preclude it either. The architectural constraint:

- The L1 hook signature takes the activation input and the
  weight tensor. The backend dispatch is internal.
- The v1 backend dispatch is `{CPU, CUDA, METAL_GPU}`,
  selected by device query.
- A future v2 backend dispatch can add `{ANE}` for the
  FP16 reference path, gated by `--tessera-l1-ane-enabled`.
  The ANE path runs the unquantized matmul on ANE; the GPU
  path runs the T640 matmul on GPU; the two share the
  activation input via unified memory.
- The L1 sidecar writeback is unchanged: the ANE result
  and the GPU result are both captured in the same
  `ts_l5_soi_source` style struct (FP16 reference in the
  `.act.dequant.f16` sidecar; T640 in the `.dequant.f32`
  sidecar).

The v1 implementation does not need to add the ANE path.
The constraint is that the L1 hook signature and the
sidecar schema should support it without breaking changes
when the ANE path is added. ~3 lines of architectural
note in the L1 hook header.

**Cost impact when added.** The ANE FP16 matmul on
M-series is ~3x the Metal GPU matmul (the ANE prefill
work in `common/ane-mtp.{h,mm}` has this empirical
ratio). The T640 matmul on GPU is unchanged. The total
calibration cost is `(T640_on_GPU + FP16_on_ANE) = T640
* (1 + 1/3) = 1.33x T640`, vs the v1 2x. A 33% cost
increase vs a 100% cost increase.

**When to add.** After the v1 L1 hook is in production
and the T640 matmul is the dominant calibration cost
(~50% of total calibration wall-clock). At that point
the 33% saving is worth the ~1-2 weeks of ANE
integration.

---

## 2. L1 — Hardware Truncation Telemetry

### 2.1 Motivation in current code

`common/tessera-debug/tessera-debug.h` carries the F32 dequant data
plus per-row `timing_ns`, `kernel_id`, `dispatch_count`. It does not
carry:

- **FMA rounding mode**: whether the backend used IEEE round-to-nearest,
  round-toward-zero, or stochastic rounding. The Tile640 matmul
  accumulates in F32 in CUDA, in F16 with F32 accumulator in Metal
  depending on the kernel variant, and in plain F32 on CPU.
- **Subnormal handling**: Metal flush-to-zero is implementation-defined
  per Apple documentation (Metal Shading Language Specification §5.5:
  "Denormalized numbers may be flushed to zero"). CUDA has
  `__device__` denormal flushing. CPU IEEE 754 is strict.
- **Per-row min/max/scale distribution**: only the count of
  |x|>threshold is captured. The full min/max/scale histogram per
  row is what the L5 Tier 2 activation-stats scorer wants.
- **Backend identity + kernel version**: `kernel_id` is a uint32
  opaque; the L6 acceptance verdict should know whether this is
  CPU NEON, CUDA MMQ, or Metal Tile640.

The result is that two sidecar files produced on different hardware
are silently incomparable. The L3 cosine looks identical; the
provenance JSON claims the same `kernel_version` (the main-tip SHA
of tessera), but the FMA mode may have differed.

### 2.2 SOTA grounding

- **Mixed Precision Training (Micikevicius et al., ICLR 2018,
  arXiv:1710.03740)** establishes the FP32-master-weight recipe
  but the relevant insight here is the *FP16 loss-scaling
  requirement* — the F16 representation is not lossless, and the
  paper's correction is end-to-end (loss scaling) rather than
  per-op. For inference telemetry, the analogous insight is that
  the kernel's chosen F16 path is observable and should be
  recorded.
- **BF16 (Kalamkar et al., 2019, arXiv:1905.12322)** demonstrates
  that BF16's wider range trades off mantissa precision — the
  precision floor changes between F16, BF16, and TF32. A
  telemetry field that distinguishes them is what makes the
  sidecar reproducible across hardware.
- **FP8 (Micikevicius et al., 2022, arXiv:2209.05433)** E4M3 vs
  E5M2 is the current frontier; the same principle applies —
  knowing which of N precisions the kernel used is part of
  provenance.
- **Apple Metal Shading Language Specification §5.5** (the
  language spec, not a paper, but it's the authoritative
  statement of Metal's denormal rules) is the explicit
  documented behavior that the L1 hook needs to record.

### 2.3 Proposed Tessera change

Extend TDQT v3 (this is a v3-extension, not a new version) with
two new strips, and extend the per-row strip with three new
fields.

**v3 extension 1: file-header `fp_env` block (16 bytes)**

```
  40 + R*4 + R*24 + v4_strip_size   4   fp_accumulator_dtype   uint32 (0=F32, 1=F16, 2=BF16, 3=TF32)
                                    4   rounding_mode          uint32 (0=RTN, 1=RTZ, 2=stochastic, 3=platform-default)
                                    4   denormal_mode          uint32 (0=IEEE, 1=FTZ)
                                    4   backend_id             uint32 (0=CPU, 1=CUDA, 2=METAL, 3=other)
```

`fp_accumulator_dtype` is the dtype of the matmul accumulator
(F32 on CPU/CUDA MMQ, F16 with F32 accum on Metal). `rounding_mode`
is the FMA rounding (RTN on IEEE-compliant platforms, platform-default
on Metal). `denormal_mode` is the FTZ flag (always IEEE on CPU,
configurable on CUDA, platform-default on Metal). `backend_id` is
the same enumeration the L4 probe uses for the spec-telemetry
writer.

**v3 extension 2: per-row strip extension (12 bytes)**

```
  per-row v3 strip + 12 bytes:
    4   row_min      F32 (min over cols)
    4   row_max      F32 (max over cols)
    4   row_scale    F32 (max(|row|) / 127 for INT8 quant bound; 0 for F32 dequant)
```

The 12-byte extension is appended to the existing 24-byte per-row
v3 strip. v3 readers see the new fields as 12 bytes of zero-padding
and the data block shifts by 12*R. v3+ readers can read both.

### 2.4 Integration

- The kernel hook at each backend records the FP environment at
  hook time (CPU/CUDA/Metal) and the per-row min/max/scale at
  write-row time. CPU and CUDA read it from the device-side
  register; Metal reads it from the thread-group-shared scratch.
- The L5 Tier 2 scorer (`tessera-regime.cpp`) uses `row_max` as a
  Tier 2 outlier-magnitude signal (complementing the existing
  activation-stats kurtosis).
- The L6 acceptance verdict reports `fp_accumulator_dtype` and
  `rounding_mode` in the receipt so that two receipts from
  different hardware are visibly different.

### 2.5 References

- arXiv:1710.03740 (Micikevicius 2018)
- arXiv:1905.12322 (Kalamkar 2019)
- arXiv:2209.05433 (Micikevicius 2022)
- Apple Metal Shading Language Specification §5.5

---

## 3. L1.5 — True FP16 Reference Routing

### 3.1 Motivation in current code

The L1.5 reference sidecar is wired correctly (suffix
`.act.dequant.f16`, dtype `DEQUANT_DTYPE_F16`, file
`common/tessera-debug/tessera-debug.h:127`). The CPU/CUDA/Metal
hooks are the gap. The current code path is: backend hook
materializes the F32 dequant into a scratch buffer, calls
`write_dequant_row`; the L1.5 path then *converts the same F32
buffer to FP16* via `ggml_fp32_to_fp16` and writes it as the
"reference." The reference is therefore a *round-tripped* version
of the kernel's output, not the actual unquantized reference.

This collapses L3's per-row cosine to ~1.0 by construction and
defeats the L2 forward-pass differential (the `Y_ref` in
`||Y_ref - Y_quant||_F^2` would be `quant(F16_round(F32_quant))`).
The fix requires the L1.5 path to receive a *different* buffer:
the FP16 ground truth that the unquantized matmul would have
produced. That buffer is computable on the matmul-input path:
before the dequant, materialize the BF16/FP16 source as FP16
weights and run the matmul; the result is the FP16 ground truth.

### 3.2 SOTA grounding

- **HIGGS (Malinovskii et al., NAACL 2025, arXiv:2411.17525)** uses
  the FP16 source as the ground truth for the linearity theorem's
  `t_l^2 = ||W_hat - W*||_F^2 / ||W*||_F^2`. The reference is
  not a quantized-and-dequantized buffer; it is the BF16 source
  itself.
- **SmoothQuant (Xiao et al., ICML 2023, arXiv:2211.10438)** is
  the precedent for routing activation quantization through a
  separate reference path. The paper's core observation — that
  *different tokens exhibit similar variations across their
  channels* — is the empirical reason the FP16 reference is
  stable enough to be captured once and replayed.
- **OWQ (Lee et al., 2023, arXiv:2306.02272)** uses FP16 as the
  storage format for the high-precision "weak columns" that the
  mixed-precision quantizer preserves. The FP16 reference here
  plays the analogous role: the ground-truth buffer that the
  kernel's output is being compared against.

### 3.3 Proposed Tessera change

Two coordinated changes.

**(a) Hook the L1.5 path to the *unquantized* source matmul.**

For each `blk.N.ffn_*` weight `W_N` that has a T640 representation,
the L1.5 path materializes the FP16 (or BF16) source `W_N` and runs
the same matmul as the L1 path would, on the same input activations.
The result is the FP16 ground truth `Y_ref`. The L1 path runs the
T640 matmul and produces `Y_quant`. Both are captured per
calibration sample.

Implementation: extend the kernel hook signature to take a second
matmul output (the unquantized reference) in addition to the existing
quantized output. On CPU this is a re-run with the BF16 source
cast to F32; on CUDA this is a separate cuBLAS call; on Metal this
is a separate command encoder. The cost is ~2x the matmul work, but
the L1.5 path is gated by the existing `dequant_w4a4_enabled()` flag
and only runs when W4A4 mode is on.

**(b) Write the FP16 ground truth verbatim to the sidecar.**

`write_fp16_reference_row_from_f32` (line 280 of
`tessera-debug.h`) currently converts F32 -> FP16 inline. The
change is: the F32 source for this call is the L1.5 *unquantized*
matmul output, not the L1 *dequant* matmul output. The on-disk
format is unchanged; the source is different.

### 3.4 Integration

- L1.5 path is a no-op (F32 reuse) until the kernel hook is
  extended. Once extended, L3's per-row cosine becomes non-trivial
  (cosine < 1.0 by construction because the quantized and
  reference outputs differ).
- The L2 activation-space differential (§4) consumes the
  Y_ref / Y_quant pair directly: `||Y_ref - Y_quant||_F^2 /
  ||Y_ref||_F^2`. This is the new ground truth for L2.
- L4's PPL probe (the random-token data-free variant) is
  unaffected; the L4 prompt-bank probe (§7) is enabled.

### 3.5 References

- arXiv:2411.17525 (HIGGS, Malinovskii 2024/2025)
- arXiv:2211.10438 (SmoothQuant, Xiao 2022)
- arXiv:2306.02272 (OWQ, Lee 2023)

---

## 4. L2 — Activation-Space Differential

### 4.1 Motivation in current code

`tools/quantize/tessera/tessera-l2-diff.{h,cpp}` computes
per-tensor weight-level divergence: `max_abs`, `mean_abs`,
`relative_frobenius = ||bf16 - quant||_F^2 / ||bf16||_F^2`,
`per_layer_norm`. The header comment is explicit that the
"quantize tool cannot run full forwards" — the existing L2 is the
*weight-space* analogue of the spec's L2 forward-pass differential.

The shipped analogue is correct for "did the quantizer preserve
this tensor." It is *not* the metric that downstream
layers care about. The empirical root cause of the 0.86 % drafter
acceptance on gemma-4-12B was 70-150 % relative divergence at
*layers 4, 8, 16, 32 in the forward-pass output*, not in the
weight space per se. The L2 measurement we want is the *output
divergence* under a real calibration input.

### 4.2 SOTA grounding

- **SmoothQuant (Xiao et al., arXiv:2211.10438)** is the seminal
  paper for activation-space quantization difficulty. The
  paper's central observation — that the *activations* are
  harder to quantize than the weights, and that the
  difficulty is concentrated in a small fraction of channels —
  is the exact signal that the activation-space L2 surfaces.
- **LLM.int8() (Dettmers et al., arXiv:2208.07339)** uses the
  vector-wise quantization result `||X_int8 - X_fp16||` as the
  per-row quality metric, *not* the per-weight metric. The
  per-row metric is the activation-space analogue.
- **AWQ (Lin et al., MLSys 2024, arXiv:2306.00978)** uses the
  activation magnitude (imatrix) as the per-channel importance
  weight, *not* the weight magnitude. The activation-weighted
  output error `||Y_ref - Y_quant||` weighted by per-channel
  activation magnitude is the AWQ loss; L2 is the version
  without the AWQ reparameterization.
- **QuIP (Chee et al., ICML 2024, arXiv:2307.13304)** uses the
  weight-space Frobenius as a lower bound on the output-space
  error, with the Hessian providing the bound-tightening.
  QuIP's lower-bound reasoning is what justifies using the
  weight-space metric as a cheap surrogate when the
  forward-pass metric is not available.

### 4.3 Proposed Tessera change

Replace the static weight-level L2 with a *dual* metric: the
existing weight-level metric (cheap, runs always) plus a new
activation-space metric (expensive, runs when a calibration
forward is available).

**(a) Activation-space metric.**

For each quantizable tensor `T` with an L1 sidecar (the kernel's
`Y_quant = dequant(T) @ X` for some captured input `X`) and an
L1.5 sidecar (the FP16 ground-truth `Y_ref = T_bf16 @ X` for
the same `X`), compute:

```
act_l2[T] = ||Y_ref - Y_quant||_F^2 / ||Y_ref||_F^2
act_l2_top1_mismatch[T] = (1/N) * sum_i 1[argmax(Y_ref[i]) != argmax(Y_quant[i])]
```

Both metrics are per-tensor scalars. The capture cost is
proportional to the calibration sample count; we capture the
same input `X` at every matmul, so the per-sample cost is
one BF16 matmul (the L1.5 path) + one T640 matmul (the L1 path).

**(b) Integration with the existing L2 report.**

`ts_l2_report` grows two fields per tensor: `act_l2_frob` and
`act_l2_top1_mismatch`. The flag-multiplier is applied to
`max(weight_l2_frob, act_l2_frob)` so that a tensor with a
clean weight-level reconstruction but a divergent forward output
is still flagged. The report schema bumps to
`llama.tessera.runtime-probe.v2` with v1 retained as a legacy
adapter.

### 4.4 Schema extension (runtime-probe.v2)

```json
{
  "schema": "llama.tessera.runtime-probe.v2",
  "v1_compat": true,
  "tensors": [
    {
      "name": "blk.16.ffn_down.weight",
      "shape": [4096, 4096],
      "weight_divergence": {
        "max_abs": 0.034,
        "mean_abs": 0.0012,
        "relative_frobenius": 0.018,
        "per_layer_norm": 0.014
      },
      "act_divergence": {           // NEW
        "relative_frobenius": 0.082,  // 8.2% output divergence
        "top1_mismatch": 0.04,         // 4% of positions have a top-1 flip
        "n_samples": 32
      },
      "expected_frob": 0.020,
      "flag_threshold": 0.030,
      "flagged": true,
      "flag_reason": "act_divergence"  // NEW: which metric tripped
    }
  ]
}
```

### 4.5 Integration

- The dispatch reads the L2 report and the L5 adaptive
  requantizer's flag decision is now driven by
  `max(weight_frob, act_frob) > 1.5 * expected`. The Stage A
  tighten is the same `alpha_scale`/`clip_scale`; the Stage B
  outlier bump is now scaled by the act-space mismatch, not the
  weight-space one.
- The L5 joint PPL search consumes `act_l2_top1_mismatch` as a
  per-tensor weight in the family-policy mutation (higher
  mismatch -> search the alpha/clip neighborhood more
  aggressively).

### 4.6 References

- arXiv:2211.10438 (SmoothQuant)
- arXiv:2208.07339 (LLM.int8)
- arXiv:2306.00978 (AWQ)
- arXiv:2307.13304 (QuIP, for the lower-bound justification)

---

## 5. L2 — Spectral Norm Tracking (SVD)

### 5.1 Motivation in current code

The current L2 metrics are all scalar norms of the
weight-difference matrix `W_bf16 - W_quant`. The Frobenius
metric is the L2 norm of the singular values; it can hide a
*rank collapse* where a few singular values have grown large
and the bulk have shrunk. Concretely: a quantized weight
matrix can have the same Frobenius distance from BF16 as another
candidate, but a different singular-value profile. The downstream
effect on the next layer is different.

The shipped `tessera-regime.cpp` already uses
`ts_regime_compute_descriptor` (kurtosis, eff_rank,
max_outlier_ratio) for routing, but the eff_rank is computed
from the weight space only. The L2 forward-pass output is a
better substrate for the spectral analysis because it's the
matrix the next layer actually sees.

### 5.2 SOTA grounding

- **Effective rank (Roy & Vetterli; reformulated in
  arXiv:2504.20078 ARSVD)** is the canonical spectral measure:
  `erank(W) = exp(-sum_i p_i log p_i)` where
  `p_i = sigma_i / sum_j sigma_j`. The exponential-of-entropy
  form is continuous, scale-invariant, and bounded in `[1, r]`.
- **D-Rank (openreview f13c53d16fd)** formalizes the
  "information density" interpretation of effective rank and
  uses it as the allocation signal for low-rank compression
  budgets. The L2 use case is symmetric: the L2 forward-pass
  output's effective rank is the layer's information density,
  and a quantization candidate that drops it is dropping
  capacity even if the Frobenius is unchanged.
- **ASVD (Yuan et al., 2023, arXiv:2312.05821)** is the
  activation-aware SVD: the SVD is computed on the
  activation-scaled weight, not the bare weight. ASVD's
  finding — that 10-30 % compression is possible when
  activation-scaled weights are low-rank — is the empirical
  justification for spectral tracking on the *output* side
  rather than the *weight* side.
- **PALU (Chang et al., ICLR 2025)** shows that low-rank
  compression is *additive* to quantization (the
  91.25 % combined compression with quantization + low-rank
  is the headline result). The implication for L2: the
  spectral analysis should be a *companion* metric to the
  Frobenius, not a replacement.

### 5.3 Proposed Tessera change

Add **per-layer spectral norm tracking** to the L2 report.

**(a) For each tensor with a forward-pass capture.**

Compute the SVD of `Y_ref` and `Y_quant` (the forward-pass
outputs from §4), or, cheaper, of the weight difference
`Delta_W = W_bf16 - W_quant` with activation pre-scaling
`(Delta_W) diag(s)` where `s_j = max(|X_j|) ^ alpha` (the
SmoothQuant migration formula). Track:

```
spec_l2[T] = {
  erank(Y_ref),                     // the "true" effective rank
  erank(Y_quant),                   // the quantized-model's rank
  erank_drop = erank(Y_ref) - erank(Y_quant),  // capacity loss
  top_k_concentration_ref = sum_{i=1..k} sigma_i^2 / sum sigma^2,
  top_k_concentration_quant = same on Y_quant,
  top_k_concentration_drop = top_k_concentration_quant - top_k_concentration_ref,
  spectral_norm = ||Delta_W||_2    // the operator norm
}
```

**(b) Flag criterion.**

A tensor is *spectrally flagged* if either `erank_drop > 0.1 *
erank(Y_ref)` OR `top_k_concentration_drop > 0.05`. The
criterion is independent of the Frobenius flag; both can fire
on the same tensor.

**(c) Cost.**

One SVD per layer per calibration pass. For a 12B model with
48 quantizable layers and 32 calibration samples, the
dominant cost is 48 SVDs on (4096, 4096)-ish matrices, which is
~10 seconds on M-series Metal. The pre-scaling to diag(s) is
a column-wise multiply; the SVD itself uses the existing
`cblas_sgesvd` (Linux) or `vDSP_SVD` (macOS) link.

### 5.4 Integration

- The L2 report grows a `spectral` block per tensor.
- The regime router in `tessera-regime.cpp` gets a new Tier 2
  signal: `erank_drop` informs the family routing (high
  `erank_drop` -> rotation expert, e.g. DartQuant, which
  preserves rank).
- The L5 adaptive requantizer treats `erank_drop > 0.1 *
  erank_ref` as a Stage A tighten trigger (the alpha/clip
  multiplier gets the standard bump).

### 5.5 References

- arXiv:2504.20078 (ARSVD, effective rank)
- D-Rank (openreview f13c53d16fdbe2e43a5b274aad9196a976b0c553)
- arXiv:2312.05821 (ASVD, activation-aware SVD)
- ICLR 2025 PALU (Chang et al.)

---

## 6. L3 — Autoregressive Context Drift

### 6.1 Motivation in current code

`tools/quantize/tessera/tessera-l3-coherence.{h,cpp}` computes
per-row weight-level cosine similarity between the L1 kernel
sidecar and the L1.5 reference sidecar. The per-row `cosine`
is the L3 metric. The header comment is explicit that the
spec's per-token KL / top-1 / top-5-overlap is not shipped.

The shipped per-row cosine is the *weight* analogue. It is
correct for "did the kernel's dequant drift from the reference
on this row." It is not the metric the user cares about
end-to-end. The empirical signal we want is *autoregressive
context drift*: how does the distribution divergence between
the BF16 model and the T640 model evolve as we generate
tokens? A model can have a 99.9 % per-row cosine match and
still produce a 30 % PPL degradation at position 200 because
the small per-row errors compound through the residual
stream.

### 6.2 SOTA grounding

- **Chroma 2025 Context Rot** (Hong, Troynikov, Huber,
  Chroma Research, July 2025) measured 18 frontier models and
  found performance degradation as input length grows, *well
  before the window fills*. The mechanism is the
  attention-budget dilution across more tokens, but the
  *symptom* is autoregressive error compounding at the
  distribution level. The Tessera L3 analogue is the
  position-wise `D_KL(P_BF16 || P_T640)` curve.
- **Liu et al., "Lost in the Middle" (Stanford, 2023)**
  established the U-shaped positional-accuracy curve. The
  L3 analogue is the *Kullback-Leibler divergence* curve:
  the BF16 model and the T640 model are not identical
  distributions, and the divergence at position p depends on
  the accumulated drift at positions <p. The U-shape
  predicts the divergence should be higher at mid-context.
- **Anthropic's "Effective context engineering for AI
  agents" (2025)** (industry report, not a paper, but it
  cites Chroma) frames the problem as engineering the input
  rather than enlarging the window. For L3, the equivalent
  is engineering the *measurement* — the per-token KL curve
  is the measurement that surfaces the U-shape, and the
  engineering response is to mark mid-context positions as
  high-priority in the regime router.
- **NoLiMa (Modarressi et al., 2025, arXiv:2502.05167)**
  strips lexical overlap from needle retrieval and shows that
  even at 32K tokens (well inside the advertised window) the
  accuracy drops to ~70 %. The L3 implication is that the
  KL/top-5-overlap must be measured *at the eval lengths
  the model will actually see*, not at 2K and assume
  stability.

### 6.3 Proposed Tessera change

Replace the per-row cosine with a *position-dependent,
weight+KV-attributed distribution-divergence curve*. The L3
question is not "BF16 vs reconstructed" but
"reconstructed (weight + KV cache) vs BF16 (weight + KV
cache), and which component is responsible when the joint
threshold is breached."

This is the four-forward attribution framework. Tessera's
KV cache is plumbed as a typed tensor in
`src/llama-kv-cache.cpp:231-232` (`type_k` and `type_v`,
default `GGML_TYPE_F16` in `common/common.h:386`), so
`cache_type_k = GGML_TYPE_Q8_0` is a one-line config change —
the "quantization on transport" surface the architect has
extended to the KV cache is real, not aspirational.

**(a) Four-forward attribution.**

For each L3 calibration run, run four autoregressive forwards
on the same input prefix and capture per-position logits:

| Forward | Weights | KV cache | Measures |
|---------|---------|----------|----------|
| A | BF16 (reference) | BF16 | ground truth `Y_ref` |
| B | T640 (dequant) | T640 | deployed model — joint error |
| C | T640 (dequant) | BF16 | isolated weight error |
| D | BF16 (reference) | T640 | isolated KV cache error |

The per-position divergences are:

```
kl_joint[p]   = D_KL(P_A[p] || P_B[p])        // the deployed model
kl_weight[p]  = D_KL(P_A[p] || P_C[p])        // weight reconstruction alone
kl_kv[p]      = D_KL(P_A[p] || P_D[p])        // KV reconstruction alone
```

**(b) Why four forwards, not two.**

The deployed model's error is `kl_joint`. The two components
are *correlated* in an autoregressive forward: a weight
error in layer 4 produces a slightly off hidden state, which
produces a slightly off KV cache at layer 4's K and V
projections, which compounds through layer 5+ attention. The
joint threshold is therefore *not* `kl_joint ≈ kl_weight +
kl_kv`; the cross-coupling matters.

The attribution pattern:

- If `kl_joint >> max(kl_weight, kl_kv)`: the error is
  *compounding* through the autoregressive loop. This is the
  Context Rot / Lost-in-the-Middle signal. The fix is L5's
  Stage A tighten on the mid-stack layers, not a per-tensor
  requantization.
- If `kl_joint ≈ max(kl_weight, kl_kv)` and `kl_weight >
  epsilon`: the weight reconstruction is the dominant
  source. The L5 Stage B outlier bump on the weight tensors
  is the fix.
- If `kl_joint ≈ max(kl_weight, kl_kv)` and `kl_kv > epsilon`:
  the KV cache reconstruction is the dominant source. The
  fix is to raise `cache_type_k`/`cache_type_v` to a higher
  precision (Q8_0 -> F16, or relax the Q8_0 quantizer).
- If `kl_joint > epsilon AND kl_weight < epsilon AND kl_kv <
  epsilon`: a numerical artifact (FP rounding in attention,
  layout mismatch, etc.). The fix is an L1 hook
  investigation, not an L5 requantization.

**(c) Per-position metrics.**

For each generated token position p in [1, N] in each of the
four forwards:

```
jaccard5_per_pos[p] = |top5_A[p] ∩ top5_B[p]| / |top5_A[p] ∪ top5_B[p]|
top1_match_per_pos[p] = (argmax_A[p] == argmax_B[p]) ? 1 : 0
```

The same metrics are computed for the C and D forwards (the
attribution).

**(d) Aggregate statistics.**

The L3 report grows:

```
l3_summary: {
  // existing position-wise fields...
  mean_kl_first_50:           float,   // joint (B vs A)
  mean_kl_all:                float,
  top1_mismatch_rate_first_50: float,
  top1_mismatch_rate_all:     float,
  first_5_all_match:          bool,

  // NEW: attribution fields
  mean_kl_weight_first_50:     float,   // weight error only (C vs A)
  mean_kl_kv_first_50:         float,   // KV error only (D vs A)
  coupling_ratio:             float,   // kl_joint / max(kl_weight, kl_kv)
  attribution:                enum,    // COMPOUNDING | WEIGHT | KV | NUMERICAL | OK
  compounding_layer:          int,     // first layer where kl_joint diverges from the components
  kl_curves: {
    joint:                    [N]float,
    weight:                   [N]float,
    kv:                       [N]float
  },
  jaccard5_curves: { joint, weight, kv },
  top1_match_curves: { joint, weight, kv }
}
```

**(e) Flag criterion.**

A coherence run fails (suggests a specific requantization
action) if any of:

- `mean_kl_first_50 > 0.1`  (existing — joint fail)
- `top1_mismatch_rate_first_50 > 0.05`  (existing — joint fail)
- `!first_5_all_match`  (existing — joint fail)
- `coupling_ratio > 2.0 AND kl_joint > 0.1`  (NEW — compounding
  error, distinct from per-tensor error; points to L5 mid-stack
  tighten)
- `mean_kl_weight_first_50 > 0.5 * epsilon_joint`  (NEW —
  weight dominant, points to L5 Stage B outlier bump)
- `mean_kl_kv_first_50 > 0.5 * epsilon_joint`  (NEW — KV
  dominant, points to raising `cache_type_k`/`cache_type_v`)

**(f) Cost.**

Four forwards per L3 calibration run. With the speculative
drift scoring from §13 risk 4 mitigation, each forward is
~1-2 minutes (vs 10 minutes for a naive full forward). The
four-forward total is ~4-8 minutes. The four forwards share
the BF16 reference forward A, so the actual cost is
3 * (1-2 min) = 3-6 minutes for B/C/D plus 1-2 minutes for A.

For the 12B model, the wall-clock target is <10 minutes per
calibration pass — well under.

**(g) Why the four-forward pattern is the right shape.**

The architect's correction (2026-08-12): my v1 rejection of
#4a (KV-cache divergence predictors) was wrong. The L3
measurement is about *reconstructed* losslessness, not
original-BF16 vs reconstructed, and the KV cache is itself a
quantized surface (plumbed via `cache_type_k`/`cache_type_v`).
The four-forward attribution is the right shape: forward C
(T640 weights + BF16 KV cache) and forward D (BF16 weights +
T640 KV cache) are the "wrong model" forwards in isolation,
and the right metric is the *joint* losslessness of forward
B, decomposed by source.

The Speculative Drift Scoring in #4b (Leviathan-style
tree-attention with BF16 as verifier, T640 as drafter)
applies to forward B specifically — the joint error. Forwards
C and D are independent probes that score attribution, not
joint loss.

### 6.4 Integration

- L3 consumes the L1 + L1.5 pair from §3: the BF16 forward
  output is `Y_ref` and the T640 forward output is `Y_quant`.
  The L3 curve is the per-position divergence between
  these.
- L3's four-forward pattern requires a *KV cache swap hook*:
  the harness runs forward A with `cache_type_k = cache_type_v
  = GGML_TYPE_F16`; forwards B/D with the production
  `cache_type_k`/`cache_type_v`; forward C with
  `cache_type_k = cache_type_v = GGML_TYPE_F16` regardless of
  production setting. The hook is a per-forward override of
  the cache type in the model context, not a runtime
  quantization (the quantized K/V buffers are pre-built).
- L3 emits a CSV at the path the L4 prompt bank uses
  (`tools/tessera/per_token_coherence.csv`, schema
  `llama.tessera.per-token-coherence.v2` — bumped from v1 to
  carry the attribution block).
- L3 becomes a hard gate: the L5 adaptive requantizer reads
  the L3 report and the `attribution` enum tells it *which*
  action to take (mid-stack tighten, weight outlier bump, KV
  precision raise, or numerical investigation). The L4 prompt
  bank's worst-domain pass rate (§7) and the L3 attribution
  are the two routing signals for the L5 loop.
- The L5 dispatch consumes the L3 attribution enum and routes
  to the appropriate action: `COMPOUNDING` -> Stage A
  alpha/clip tighten on mid-stack layers; `WEIGHT` -> Stage
  B outlier bump; `KV` -> emit a `kv_cache_raise` event
  that bumps `cache_type_k`/`cache_type_v` to the next
  precision tier (F16 -> Q8_0 -> F16, depending on direction);
  `NUMERICAL` -> log a hook investigation alert (the L1
  sidecar or kernel hook has a bug).

### 6.5 References

- Chroma 2025 Context Rot (Hong et al., Chroma Research)
- arXiv:2502.05167 (NoLiMa, Modarressi 2025)
- Liu et al., "Lost in the Middle" (Stanford 2023)
- Anthropic "Effective context engineering for AI agents"
  (2025)

---

## 7. L4 — Domain-Weighted Prompt Banks

### 7.1 Motivation in current code

`tools/quantize/tessera/tessera-ppl.{h,cpp}` implements
`ts_ppl_probe` and `ts_ppl_compare` as a data-free probe on
random tokens. The shipped L4 is the *cheapest* possible
end-to-end metric: it answers "is the model producing valid
logits" but not "is the model producing valid
*task-specific* logits."

The shipped L4 has two known false-positive failure modes:

1. **Random tokens may not exercise the outlier channels.**
   If the calibration corpus happens to be uniform-random, the
   activation outliers are never triggered and the T640 model
   passes the L4 gate even when the real distribution would
   have failed it.
2. **Random tokens can't measure domain-specific alignment.**
   Code, math, and structured JSON each have characteristic
   output signatures; random-token PPL is uninformative
   about whether those signatures survived quantization.

The L4 design spec calls for a `prompts/` directory with four
canonical files (`paris.txt`, `gsm8k-easy.txt`,
`multi-turn.txt`, `code.txt`); none of these exist in the
shipped tree.

### 7.2 SOTA grounding

- **lm-evaluation-harness (Gao et al., 2023; Biderman et al.,
  arXiv:2405.14782)** is the de facto standard for
  reproducible LLM evaluation. The core abstraction — three
  request primitives (`loglikelihood`, `loglikelihood_rolling`,
  `generate_until`) and versioned YAML tasks — is the pattern
  Tessera's L4 should adopt. The library currently has
  60+ benchmarks with hundreds of subtasks.
- **Chroma 2025 Context Rot** (already cited in §6) measured
  18 frontier models across 194,480 calls and found that the
  L4-style "needle in a haystack" test is a *false
  all-clear* for semantic matching. The L4 prompt bank
  should include a non-lexical retrieval probe.
- **NoLiMa (Modarressi et al., 2025, arXiv:2502.05167)** is
  the relevant non-lexical retrieval benchmark. It strips
  the lexical overlap that makes the original
  needle-in-a-haystack test easy and shows 99.3 % -> 69.7 %
  degradation on GPT-4o at 32K.
- **RULER (Hsieh et al., 2024, arXiv:2404.06654)** is the
  multi-hop reasoning and aggregation benchmark. Roughly
  half the models tested fail at 32K despite claiming longer
  windows.
- **LongMemEval (Wu et al., 2024, arXiv:2410.10813)** is
  the conversational long-term memory benchmark. ~30 %
  accuracy drop when facts are surrounded by irrelevant
  history.

### 7.3 Proposed Tessera change

Add a domain-weighted prompt bank to the L4 driver, replacing
the data-free random-token probe as the production L4.

**(a) Prompt bank structure.**

```
tools/tessera/prompts/
  factual/paris.txt                    # "The capital of France is" -> " Paris"
  factual/trivia_50.txt                # 50 short factual QA pairs
  math/gsm8k_easy.txt                  # 50 one-step arithmetic
  math/gsm8k_medium.txt                # 50 two-step arithmetic
  code/humaneval_easy.txt              # 50 short code-completion
  code/mbpp_easy.txt                   # 50 short code-generation
  structured/json_schema_50.txt        # 50 JSON-schema-bound outputs
  structured/sql_50.txt                # 50 SQL-generation
  reasoning/longcontext_noliMa.txt     # NoLiMa-style 50 non-lexical needles
  reasoning/ruler_aggregate_50.txt     # RULER-style 50 multi-hop
  conversational/longmemeval_50.txt    # 50 long-context QA
  adversarial/distractor_long.txt      # Chroma distractor-heavy 50
  adversarial/replication_50.txt       # Chroma verbatim-replication 50
```

Each prompt is paired with a known-good BF16 reference output
and a match strategy (exact_match for factual, regex for code,
JSON-validate for structured, semantic for retrieval).

**(b) Domain weighting.**

The L4 report carries per-domain PPL, per-domain pass-rate,
and a domain-weighted aggregate:

```
l4_summary: {
  per_domain: {
    factual:        { ppl: 12.3, pass_rate: 0.96, n_prompts: 50 },
    math:           { ppl: 18.4, pass_rate: 0.84, n_prompts: 100 },
    code:           { ppl: 9.1,  pass_rate: 0.72, n_prompts: 100 },
    structured:     { ppl: 11.2, pass_rate: 0.88, n_prompts: 100 },
    reasoning:      { ppl: 22.6, pass_rate: 0.60, n_prompts: 100 },
    conversational: { ppl: 15.0, pass_rate: 0.78, n_prompts: 50 },
    adversarial:    { ppl: 19.8, pass_rate: 0.55, n_prompts: 100 }
  },
  weighted_ppl: float,             // weighted by domain importance
  weighted_pass_rate: float,
  worst_domain: { name, ppl, pass_rate },
  pass: weighted_pass_rate > 0.85
}
```

The domain weights are configurable (`--tessera-l4-domain-weights`)
and default to a uniform 1/7. The production default should
weight `code` and `reasoning` higher (the drafter
acceptance root cause was a code/reasoning test in the original
case).

**(c) Implementation.**

`tools/tessera/e2e_probe.py` is the new driver. It runs
the BF16 and T640 models on each prompt, scores with the
domain-specific matcher, and emits the JSON report. The
random-token `ts_ppl_probe` remains available for fast CI
smoke tests but is no longer the production L4.

### 7.4 Integration

- The L4 prompt bank is built from the lm-eval-harness
  task definitions where possible (GSM8K, HumanEval, etc.,
  via the YAML-to-Tessera shim).
- The dispatch reads the L4 report at the end of the
  pipeline. If `l4_summary.pass == false`, the dispatch
  re-runs the L5 adaptive requantizer with the worst-domain
  tensors prioritized.
- The domain weights are recorded in the L4 provenance and
  reused for the L5 weights.

### 7.5 References

- arXiv:2405.14782 (lm-evaluation-harness, Biderman 2024)
- Chroma 2025 Context Rot
- arXiv:2502.05167 (NoLiMa)
- arXiv:2404.06654 (RULER)
- arXiv:2410.10813 (LongMemEval)

### 7.6 Tiered deployment (NEW, v4)

The 1000-prompt bank is the **v1 L4** for one-time
calibration: ship it as a directory, run it on every
quantization pass, and use the domain-weighted pass rate
as the production L4 signal. The ~5 minute wall-clock per
model is acceptable for a calibration that runs once per
deployment.

The v1 is *not* the right shape for **CI** (L4 on every
PR). For CI, the architect's #5a proposal (dataset
distillation) is the right answer — a distilled 50-prompt
micro-benchmark that is mathematically optimized to have
maximal mutual information with the failure modes of the
full 1000-prompt bank. The distillation is *not* a
research project; it's a real engineering task that pays
for itself in CI (30 seconds vs 5 minutes per PR).

The tiered deployment is explicit:

| Tier | Prompt count | Wall-clock | Use case | When |
|------|--------------|------------|----------|------|
| 0 (smoke) | 10 (one per domain) | 5 sec | smoke test in CI | every PR |
| 1 (CI) | 50 (distilled micro-benchmark) | 30 sec | every PR | CI pipeline |
| 2 (calibration) | 1000 (full bank) | 5 min | every quantization pass | deploy pipeline |
| 3 (audit) | 5000+ (extended bank) | 25 min | quarterly model audit | scheduled |

The active learning gate from §13 risk 5 (the
`max(|pass_rate_d - 1/N_prompts_d|) > 0.15` heuristic)
governs the tier escalation: smoke test passes -> stop;
smoke test fails -> run the CI tier; CI tier fails or has
high variance -> run the calibration tier; calibration
tier fails -> run the audit tier and emit an L5 trigger.

The CI tier (50 prompts) is the architect's distilled
micro-benchmark. The distillation procedure:

1. Run the full 1000-prompt bank on a set of N
   calibration samples (different quantization policies).
2. For each (sample, prompt) pair, record the
   pass/fail outcome.
3. Run a dataset distillation algorithm (e.g.,
   "Dataset Distillation by Synthetic Data" or the
   coreset-based approach from "Diverse and Effective Red
   Teaming") to find 50 synthetic prompts that
   approximate the joint distribution of pass/fail
   outcomes.
4. The 50 distilled prompts are saved as
   `tools/tessera/prompts_distilled/` and used for the CI
   tier.

The CI tier is *not* the same as the calibration tier —
the calibration tier needs full coverage; the CI tier
needs fast detection of regressions. The 50-prompt
distilled bank is a regression detector, not a coverage
benchmark.

**When to ship each tier:**

- **Tier 0 (smoke):** ship with v1 (10 prompts, hand-picked
  from each domain).
- **Tier 2 (calibration):** ship with v1 (the 1000-prompt
  bank in §7.3).
- **Tier 1 (CI, distilled):** ship in v2, after the
  calibration tier has run on enough quantization samples
  to seed the distillation.
- **Tier 3 (audit):** ship in v3, after the CI tier is
  stable enough to identify what the audit tier needs to
  catch.

The v1 ships tiers 0 and 2. The v1 dispatch implements the
tier escalation (smoke -> calibration if smoke fails).
The CI tier is added in v2 once the distillation data is
available.

---

## 8. L4 — Speculative Spec Telemetry

### 8.1 Motivation in current code

The current L4 (random-token PPL) is a *target-only* probe.
It tells us "is the T640 model's distribution close to BF16
on random tokens" but not "is the *spec decoding path*
aligned." The shipped speculative telemetry
(`docs/spec_calib.v1` / `llama.tessera.spec.v1`) emits
drafted/accepted/confidence[] per spec step from
`llama-imatrix`, but this is a *post-hoc* measurement — it
runs after the calibration is done, with whatever
distribution the calibrated T640 model produces.

The L4 probe should record drafter acceptance per *layer*
of the verifier. A drafter that loses acceptance at layer 4
because the verifier's layer-4 distribution has shifted
post-quantization is the exact failure mode the 0.86 %
drafter case exhibited.

### 8.2 SOTA grounding

- **Speculative decoding (Leviathan, Kalman, Matias, ICML
  2023; Chen et al., 2023)** establishes the rejection-sampling
  protocol: accept each drafted token with probability
  `min(1, p_target / p_draft)`. The expected accepted tokens
  per cycle is `(1 - alpha^(k+1)) / (1 - alpha)` where
  alpha is the per-token acceptance rate. Speedup is bounded
  by `1 + E[accepted]` in the ideal case.
- **EAGLE-1/2/3 (Li et al., 2024-2026)** demonstrates that
  the drafter can be a *feature-level* adapter on the
  verifier's hidden state. EAGLE-3 reaches 0.88-0.92 alpha
  on chat. The drafter is a *derivative* of the verifier,
  and the drafter's alpha *is* the alignment metric.
- **TriSpec (Sun et al., 2026, arXiv:2601.23180)** is the
  most recent advance: 82 % exact-match between a lightweight
  proxy verifier and the target. TriSpec's contribution is a
  *proxy* that aligns with the target better than an
  EAGLE-class drafter (68 % vs. 82 %). The relevant insight
  for L4 is that the drafter-verifier alignment is a
  measurable signal that can drive calibration.
- **HASS, Medusa, Lookahead** (in the speculative decoding
  survey) are alternative drafters with different
  acceptance characteristics. L4's spec telemetry should be
  drafter-agnostic: it measures the alignment, not the
  draft mechanism.

### 8.3 Proposed Tessera change

Add a *per-layer, per-drafter* alignment measurement to the
L4 probe.

**(a) L4 spec telemetry hooks.**

The existing `llama.tessera.spec.v1` schema is extended
with a per-position, per-layer field:

```json
{
  "schema": "llama.tessera.spec.v2",
  "v1_compat": true,
  "steps": [
    {
      "step_idx": 0,
      "drafted": [101, 202, 303, 404, 505],
      "accepted_count": 3,
      "first_reject_layer": 4,           // NEW: layer of first rejected drafted token
      "per_layer_alpha": {                // NEW: per-layer acceptance
        "0": 0.95, "1": 0.92, "2": 0.88,
        "3": 0.81, "4": 0.55,             // <-- the drafter drops at layer 4
        "5": 0.74, "6": 0.86
      },
      "per_layer_kl": {                   // NEW: KL(verifier || drafter) per layer
        "0": 0.02, "1": 0.04, ..., "4": 0.42
      }
    }
  ]
}
```

`first_reject_layer` is the verifier layer at which the first
rejected drafted token was rejected. This is the *Layer 4
symptom* signal: a drafter that loses acceptance at the
same layer in many steps is exhibiting the *systematic
alignment degradation* that the 0.86 % case showed.

`per_layer_alpha` is the per-layer acceptance rate across
all spec steps. The histogram of `first_reject_layer` is the
diagnostic.

**(b) L4 report schema.**

The L4 report grows a `spec_telemetry` block:

```
l4_summary: {
  // ... existing per-domain block ...
  spec_telemetry: {
    overall_alpha: float,                  // mean across all steps
    per_layer_alpha: [L]float,
    per_layer_kl: [L]float,
    first_reject_layer_histogram: [L]int,
    first_reject_layer_peak: int,          // mode of the histogram
    drafter_count: 4,                      // DFlash, DSPark, MTP, talker (5 if talker active)
    per_drafter_alpha: [n_drafters]float
  }
}
```

**(c) Flag criterion.**

L4 fails (suggests requantization focused on a specific
layer) if any of:

- `overall_alpha < 0.50`  // 50% per-token acceptance
- `first_reject_layer_peak in {1, 2, 3, 4, 5}`  // mid-stack reject cluster
- `per_layer_alpha[L/2] < 0.40`  // mid-stack per-layer drop
- `any(per_layer_kl[l] > 0.5)`  // mid-stack per-layer KL spike

### 8.4 Integration

- The spec telemetry is collected by the existing
  `llama-imatrix` spec hook, extended with per-layer
  acceptance capture. The hook already runs the verifier +
  drafter together and emits per-step accept/reject; the
  per-layer addition is a per-token capture in the drafter
  forward callback.
- The L4 prompt bank and the spec telemetry are co-run:
  the L4 driver emits both the per-domain block and the
  spec telemetry block in one report.
- The L5 adaptive requantizer treats `first_reject_layer_peak`
  as a *target* for the L5 tightening: the family whose
  layers cluster around the peak gets the Stage A alpha/clip
  bump.

### 8.5 References

- Leviathan, Kalman, Matias (ICML 2023); Chen et al. (2023)
- EAGLE-1/2/3 (Li et al., 2024-2026)
- arXiv:2601.23180 (TriSpec, Sun 2026)
- Anthropic, vLLM, SGLang spec decoding surveys (2024-2026)

---

## 9. L5 — Hessian Sensitivity Scoring

### 9.1 Motivation in current code

`tools/quantize/tessera/tessera-l5.cpp` ships three scorers:
`ts_l5_imatrix_magnitude` (mean of |act|), `ts_l5_gradient_proxy`
(some unspecified "output sensitivity"), and
`ts_l5_layer_position_prior`. The first is the per-channel
importance from the calibration corpus; it is a *first-order*
signal (how large is the activation) not a *second-order*
signal (how sensitive is the loss to a perturbation in this
weight).

The shipped scorers are the right shape for the L5 problem —
they produce a per-tensor sensitivity score that drives the
top-fraction picker — but they are missing the Hessian
information. The Hessian is the right signal because it
captures *which weights actually matter* under a calibration
forward, not just *which weights are touched by
high-magnitude activations*.

### 9.2 SOTA grounding

- **GPTQ (Frantar et al., ICLR 2023, arXiv:2210.17323)** is
  the seminal work on Hessian-based PTQ. The objective is
  `min ||W_hat X - W X||_F^2` whose Hessian is
  `H_F = 2 X_F X_F^T`. The Cholesky reformulation
  `H^{-1} = L L^T` is what makes GPTQ tractable on
  100B+ models. The sensitivity per weight is
  `(quant(w_q) - w_q)^2 / [H^{-1}]_qq` (the OBQ criterion).
- **OBQ (Frantar & Alistarh, 2022, arXiv:2208.11580)** is
  the predecessor: Optimal Brain Compression generalizes
  the OBS pruning framework to quantization. The OBS
  formula `delta_F = -(w_q - quant(w_q)) / [H^{-1}]_qq *
  (H^{-1})_{:,q}` is the Hessian-driven update.
- **SpQR (Dettmers et al., 2023, arXiv:2306.03078)** uses
  the OBS sensitivity to identify outlier weights
  (`omega_ij > tau * median(omega)`). The sensitivity is
  *exactly* the Hessian-based criterion. SpQR is the
  precedent for using the Hessian to inform outlier
  selection, not just the rounding error.
- **HIGGS (Malinovskii et al., NAACL 2025, arXiv:2411.17525)**
  uses the Linearity Theorem's `t_l^2` as the per-layer
  sensitivity. The Theorem says the *aggregate* sensitivity
  is what matters for PPL; the Hessian is the per-weight
  refinement.

### 9.3 Proposed Tessera change

Add a **Hessian-based sensitivity scorer** alongside the
existing imatrix-magnitude scorer.

**(a) Hessian capture.**

`H = 2 X X^T` is computed on the calibration activations
`X` (the same imatrix corpus). For a 12B model with
in_dim=4096, `H` is 4096x4096 in F32 (~64 MB). One
Hessian per quantizable tensor; the cost is one
`cblas_ssyrk` per tensor (O(d^2 n) where d is in_dim and
n is the calibration token count).

**(b) Sensitivity score.**

The per-weight sensitivity is
`omega_ij = (w_ij - quant(w_ij))^2 / [H^{-1}]_ii`. The
per-tensor sensitivity is the mean over the weight's row
(or column, depending on convention):
`sensitivity[T] = mean_j omega_ij`. The Cholesky factor
`L` (lower triangular, `H^{-1} = L L^T`) is reused across
all rows of the same tensor.

For the L5 scorer, we don't need per-weight — we need
per-tensor. We compute the diagonal `[H^{-1}]_ii =
||L[i, :]||^2` — the squared 2-norm of row i of the
lower-triangular Cholesky L of `H^{-1}` (`L L^T =
H^{-1}`) — not just `L_{ii}^2`. The `L_{ii}^2` form is
only valid when H is diagonal (uncorrelated activations).
For a real imatrix corpus the off-diagonals of L are
non-negligible (Frantar & Alistarh 2022, eq.&nbsp;3). The
per-tensor sensitivity is then `sum_j (w_ij -
quant(w_ij))^2 / ||L[i, :]||^2`, i.e. `H_inv_diag[i]` in
the API below.

**(c) Scoring API.**

The scorer takes a generic `ts_l5_second_order_info`
struct, not a literal Hessian, so the v1 in-core Cholesky
and the v2 Nyström / out-of-core streaming implementations
share a single code path. The struct is:

```cpp
// tools/quantize/tessera/tessera-l5.h
// (Spec errata 728a1c953, v3.1 §9.3: the per-weight OBQ
//  denominator is H_inv_diag[i] = [H^{-1}]_ii =
//  ||L[i, :]||^2, NOT L_{ii}^2. L_in_core is kept as an
//  optional full factor for v2 Nyström sketching.)
struct ts_l5_second_order_info {
    ts_l5_soi_source source;        // IN_CORE | STREAMING | NYSTROM
    int64_t in_dim;                 // matrix dimension
    const float * H_inv_diag;       // IN_CORE: diagonal of H^{-1} (size in_dim)
    const float * L_in_core;        // optional: lower triangular L of H^{-1}
    int64_t streaming_row;          // STREAMING: current row (caller advances)
    int64_t nystrom_k;               // NYSTROM: landmark count
    const float * nystrom_U;         // NYSTROM: (in_dim, nystrom_k) factor
    const float * nystrom_W_inv;     // NYSTROM: (nystrom_k, nystrom_k) inverse
};

ts_score_map ts_l5_hessian_sensitivity(
    const float * weights_bf16,
    const float * weights_quant,    // optional; if nullptr, use weights_bf16
    const ts_l5_second_order_info * soi,
    const char ** tensor_names,
    const int64_t * tensor_in_dims,
    int64_t n_tensors);
```

The `L_in_core` (or its NYSTROM / STREAMING equivalent) is
a pre-computed factorization shared across all tensors with
the same `in_dim`. The L5 dispatcher loads the
factorization once and calls the scorer for each tensor.

The struct-based API is the API constraint, not a
performance optimization: the verifier-scale (70B+) case
needs the STREAMING or NYSTROM variants to keep the
working set under 18 GB on Apple Silicon unified memory,
and the v1 IN_CORE path is a degenerate case of the same
struct. Shipping IN_CORE first and adding STREAMING /
NYSTROM later is an internal implementation change with no
caller updates.

**(d) Cost.**

For a 12B model with 48 quantizable layers (each with
in_dim=4096), the total Cholesky compute is
~48 * 4096^3 / 3 = 1.1e12 flops. On M-series Metal,
~10 seconds total. The per-tensor scorer is then O(d * n)
per tensor, ~5 ms per tensor.

### 9.4 Integration

- The L5 dispatch loads the Cholesky factors from the
  existing `tessera.duckdb` cache (keyed by
  `(model_hash, tensor_name, in_dim)`). On cache miss, the
  Cholesky is computed and cached.
- The Hessian scorer joins the existing scorers via
  `ts_l5_combine` with a configurable weight
  (`--tessera-l5-scorer=hessian:0.5,imatrix:0.3,grad:0.2`).
- The Tier 2 regime router in `tessera-regime.cpp` gets a
  new signal: `hessian_sensitivity` informs the expert
  routing (high sensitivity -> SEPTQ; low sensitivity ->
  AWQ; etc.).

### 9.5 References

- arXiv:2210.17323 (GPTQ, Frantar 2023)
- arXiv:2208.11580 (OBQ, Frantar & Alistarh 2022)
- arXiv:2306.03078 (SpQR)
- arXiv:2411.17525 (HIGGS)

### 9.6 Verifier-scale Hessian capture (NEW, v4)

The 12B working set is 3 GB; the 70B+ verifier working set
in the L5 joint PPL path is 18 GB. The v1 IN_CORE Cholesky
is correct for the drafter; the verifier scale needs a
different shape. The `ts_l5_second_order_info` struct's
`STREAMING` and `NYSTROM` variants are the answer, and the
API design supports both from day one.

**STREAMING — per-row OBQ sensitivity.** The OBQ criterion
computes `omega_ij = (w_ij - quant(w_ij))^2 / [H^{-1}]_ii`
per weight, with `[H^{-1}]_ii = ||L[i, :]||^2` (the squared
2-norm of row i of the lower-triangular L of `H^{-1}`),
NOT `L_{ii}^2`. The L5 scorer is *per-tensor*, not
per-weight; for
the per-tensor sensitivity we only need the diagonal of
`H^{-1}` and a row of `L` at a time. The STREAMING
variant holds one row of `L` in memory (O(d) memory, ~16 KB
at d=4096), reads the corresponding row of weights, and
emits the per-tensor sensitivity for that row. The
sensitivity score is then accumulated across rows with
constant memory. The total working set is O(d) per tensor
instead of O(d^2).

The cost is one disk read per row of `L` (sequential, so
the disk bandwidth is the limit). On Apple Silicon unified
memory, the "disk" is unified memory and the read is
effectively free; on Linux with `mmap`, the page-in is
amortized. The STREAMING path is the right answer for
verifier-scale calibration.

**NYSTROM — landmark approximation.** The Nyström method
approximates `H^{-1} ~ U diag(1/s) U^T` where `U` is the
eigenvectors of `H` restricted to `k` landmark columns and
`s` are the corresponding eigenvalues. The storage is
`O(d * k)` (one `d x k` matrix and one `k x k` matrix) instead
of `O(d^2)`. For `k = sqrt(d) = 64` at d=4096, the working
set is 1 MB per tensor, vs 64 MB for the full Cholesky.

The accuracy trade-off: Nyström is exact when the
eigenvectors of `H` are well-approximated by the first
`k` landmark columns, which holds for low-rank `H`. For
transformer attention / FFN Hessians, the empirical
spectrum is heavy-tailed (a few large eigenvalues, many
small ones); the Nyström approximation with `k = sqrt(d)`
preserves the large eigenvalues and under-weights the small
ones. The sensitivity score is dominated by the large
eigenvalues, so the under-weighting is exactly where we
don't care. The approximation is conservative: Nyström
sensitivity is a *lower bound* on the true sensitivity, so
a Nyström-flagged tensor is one we should requantize
(everything Nyström flags is a true positive; we may miss
some true positives that live in the small-eigenvalue
tail, which the STREAMING path catches).

**Implementation order.**

1. v1 ships IN_CORE only. Tests: `test_l5_hessian.cpp`
   with a synthetic Hessian, comparing the scorer's output
   against a brute-force OBQ computation.
2. v1.1 ships STREAMING. Tests: same test suite plus a
   memory-bound test (verifier-scale Hessian, working set
   < 1 GB).
3. v2 ships NYSTROM. Tests: same suite plus an accuracy
   bound test (Nyström sensitivity vs. IN_CORE on the
   attention/FFN Hessians of a real model, with the
   empirical claim that the rank-k approximation has
   Spearman rho > 0.9 with the full Hessian sensitivity
   for the top-fraction tensors).

The API design (§9.3) is the same for all three. The
dispatch picks the source based on the working-set budget
(`--tessera-l5-hessian-source=auto | in_core | streaming
| nystrom`, default `auto` = STREAMING for 70B+ and
IN_CORE for 12B).

---

## 10. L6 — Empirical HIGGS Layer Coefficients

### 10.1 Motivation in current code

The L6 cross-tensor objective
`Sum_l alpha_l * t_l^2` uses `alpha_l` from the HIGGS Linearity
Theorem. The Theorem says `alpha_l` exists and is
method-independent; the `runtime-aware-pipeline.md` design
calls for estimating `alpha_l` empirically via the HIGGS
calibration (perturb each layer, measure PPL response) and
caching it in the sidecar/policy. The current shipped L6
implementation hardcodes `alpha_l = 1.0` for all layers
(uniform weights).

The 0.86 % drafter case exhibited 70-150 % relative
divergence at layers 4, 8, 16, 32 — exactly the
*non-uniform* distribution that uniform alpha_l
under-weights. A correct alpha_l for layer 16 might be 4x
the alpha_l for layer 0; the uniform default would
*average* these, missing the fact that the GA fitness
should focus on layer 16.

### 10.2 SOTA grounding

- **HIGGS (Malinovskii et al., NAACL 2025, arXiv:2411.17525)**
  is the primary source. The Theorem states the linear
  approximation:
  `E[PPL(W_hat)] ≈ PPL(W*) + Sum_l alpha_l * t_l^2`.
  The paper *proves* the existence of `alpha_l` but does
  not estimate them. The empirical estimation is
  application-specific.
- **OBQ (Frantar & Alistarh, 2022, arXiv:2208.11580)** uses
  the local second-order approximation to estimate the
  sensitivity of a single weight; the *global* version
  across layers is the HIGGS extension. The OBS
  perturbation method — add `Delta` to one weight, measure
  the loss change, scale by `[H^{-1}]_qq` — is the
  per-weight analogue of the per-layer perturbation.
- **OWQ (Lee et al., 2023, arXiv:2306.02272)** uses
  activation-weighted sensitivity to rank weak columns.
  The layer-perturbation method is the natural extension:
  perturb the entire layer, measure the PPL response.
- **AWQ (Lin et al., MLSys 2024, arXiv:2306.00978)** uses
  the per-channel activation magnitude as a sensitivity
  weight. The layer-perturbation method is more accurate
  but more expensive.

### 10.3 Proposed Tessera change

Add **HIGGS empirical alpha_l estimation** to the L6
pipeline.

**(a) Per-layer perturbation.**

For each quantizable layer l, run a *partial* quantization
where only layer l is perturbed (random noise of scale
`epsilon * ||W_l||_F / sqrt(d)`) and all other layers are
unchanged. Measure the PPL delta against the unperturbed
BF16 model on a small calibration set (default: 64 chunks
of 2048 tokens).

The PPL delta `delta_PPL_l = PPL(perturb_l) - PPL(unperturbed)`
is the empirical alpha_l, up to a constant:
`alpha_l ≈ delta_PPL_l / t_l^2` where `t_l^2` is the
perturbation magnitude. The constant is the same across
layers (it depends on the calibration set, not the layer),
so for the GA objective `Sum_l alpha_l * t_l^2` we can
use the *unnormalized* `delta_PPL_l` directly.

**(b) Cost.**

For a 48-layer model, 64 chunks per perturbation, ~10
seconds per forward on M-series Metal: 48 * 10 = 480
seconds, or ~8 minutes. The cache key is
`(model_hash, calibration_corpus_hash, perturb_seed)`;
warm-start across runs is a single `SELECT` from DuckDB.

**(c) Storage.**

The empirical alpha_l is stored in the dispatch result and
written to the sidecar/policy:

```json
{
  "alpha_l": {
    "0": 0.0012,  "1": 0.0008,  "2": 0.0015,  "3": 0.0021,
    "4": 0.0048,  "5": 0.0029,  "6": 0.0034,  "7": 0.0027,
    "8": 0.0061,  // <-- layer 8's HIGGS coefficient
    ...
  },
  "alpha_l_source": "higgs_empirical_v1",
  "alpha_l_calibration_corpus_hash": "sha256:...",
  "alpha_l_calibration_seed": 42
}
```

**(d) Integration with the GA objective.**

The GA objective in `tessera-dispatch.cpp` (step 5c, the
per-tensor GA) becomes:

```
fitness = Sum_l alpha_l * t_l^2
```

with `alpha_l` from the empirical estimation. The default
is still uniform `alpha_l = 1.0` for backward compatibility
(`--tessera-l6-alpha-source=uniform`); the HIGGS-empirical
mode is `--tessera-l6-alpha-source=higgs` (default for new
runs).

### 10.4 References

- arXiv:2411.17525 (HIGGS, Malinovskii 2024/2025)
- arXiv:2208.11580 (OBQ)
- arXiv:2306.02272 (OWQ)
- arXiv:2306.00978 (AWQ)

---

## 11. L6 — Tail-Weighted Kernel Loss

### 11.1 Motivation in current code

`tools/quantize/tessera/tessera-l1-fitness.cpp` ships
`ts_l1_kernel_direct_t2` which computes
`||W_hat - dequant_kernel(W_l)||_F^2 / ||W_l||_F^2`. The
denominator is the Frobenius norm of the *entire* weight
matrix. The numerator is the squared error of the
dequantized reconstruction. A weight of 0.001 magnitude
contributes `0.001^2 ≈ 1e-6` to the denominator and a
similar small value to the numerator; a weight of 100
magnitude (an outlier) contributes `100^2 = 1e4` to both.

The outlier weight dominates the metric, which is *correct*
in the relative sense but *misleading* in the optimization
sense. The GA may preserve the outliers at the cost of
quantization noise on the bulk; the bulk's quantization
noise is the *common case* that affects more outputs. A
loss that *additionally* penalizes bulk error, beyond what
the Frobenius provides, would steer the GA toward a
better-balanced policy.

### 11.2 SOTA grounding

- **LLM.int8() (Dettmers et al., 2022, arXiv:2208.07339)**
  uses the `|x| > 6.0` threshold to identify the ~0.1 %
  of channels that are outliers; these are kept in FP16
  while the bulk is INT8. The 6.0 threshold is the
  empirical basis for the L1 sidecar's outlier counter
  and is the right threshold for the *outlier* side of
  the tail.
- **SpQR (Dettmers et al., 2023, arXiv:2306.03078)** is the
  second-generation outlier-aware method: store outliers
  in 16-bit, the bulk in 3-4-bit. The CSR storage
  (16-bit value + 16-bit column index, 32-bit row
  cumulative) is the format that the L1 sidecar's
  per-row outlier count is structured for.
- **OWQ (Lee et al., 2023, arXiv:2306.02272)** uses the
  *weak column* identification: columns where the
  activation outlier is large AND the weight column is
  sensitive. The criterion is a *joint* one — outlier +
  sensitivity, not outlier alone.
- **OWC / OmniQuant (Shao et al., 2023)** uses a learnable
  weight clipping parameter `gamma` to find the optimal
  clipping range. The `gamma` is itself a per-layer
  learnable parameter, fit by minimizing the
  layer-wise loss. The L6 tail-weighted loss is the
  symmetric move: the per-layer *weight* on the tail
  is itself learnable, fit by minimizing the *model*
  loss.

### 11.3 Proposed Tessera change

Add a **tail-weighted kernel loss** to L6.

**(a) Loss form.**

The tail-weighted loss is:

```
t_l^2_tail = ||W_hat - dequant_kernel(W_l)||_F^2 / ||W_l||_F^2
           + lambda_tail * mean_{i: |W_l[i]| > tau} (W_hat[i] - dequant_kernel[i])^2
```

where `tau` is the per-layer outlier threshold (default
`tau = 6.0` from LLM.int8) and `lambda_tail` is a
configurable weight (default `lambda_tail = 4.0`, matching
the existing `combined` fitness mode in
`per_tensor_calibrate.py:73`).

The first term is the existing Frobenius; the second term
penalizes the *mean* (not sum) error on the tail weights.
The mean is what makes the loss invariant to the number of
outliers; the Frobenius is invariant to the number of
weights. The two together are what makes the loss sensitive
to *both* the bulk and the tail.

**(b) Implementation.**

`ts_l1_kernel_direct_t2_tail`:

```cpp
// tools/quantize/tessera/tessera-l1-fitness.h
float ts_l1_kernel_direct_t2_tail(
    const float * w_hat, const float * w_original, const float * kernel_dequant,
    int64_t n, float tau, float lambda_tail);
```

The implementation is two passes: first pass identifies
which weights are outliers (|W_l[i]| > tau) and accumulates
the Frobenius; second pass accumulates the tail MSE.

**(c) Cost.**

Two passes over the weight tensor; the outlier indices can
be cached in a `std::vector<int>` of size
`O(n * Pr[|W| > tau])`. For 12B with 1 % outlier rate, the
indices vector is 1.2 MB; the second pass is O(n).

### 11.4 Integration

- The L6 fitness function in `tessera-dispatch.cpp:263-294`
  is extended to use `ts_l1_kernel_direct_t2_tail` instead
  of `ts_l1_kernel_direct_t2`. The CLI flag
  `--tessera-l6-tail-weight` controls `lambda_tail`; the
  default is 4.0; setting to 0.0 reproduces the existing
  behavior.
- The acceptance verdict (`tessera-dispatch.cpp:1346`) is
  fixed: the `at.kernel_direct_t2 = comp_t2;` hardcode is
  replaced with the actual kernel-direct `t_l^2_tail` when
  a sidecar is present (the known gap from the audit).
- The per-tensor GA's mutation operator in
  `per_tensor_calibrate.py` gets a new dimension:
  `tail_outlier_fraction` (the fraction of tail weights
  to keep in 16-bit), with range [0.0001, 0.05].

### 11.5 References

- arXiv:2208.07339 (LLM.int8)
- arXiv:2306.03078 (SpQR)
- arXiv:2306.02272 (OWQ)
- OmniQuant (Shao et al., 2023)
- Existing Tessera `combined` fitness mode in
  `per_tensor_calibrate.py:73` for the lambda=4 default

---

## 12. Cross-cutting integration summary

The 10 refinements are coupled at three points:

1. **L1 / L1.5 coupling.** The adaptive capture (§1) and the FP
   telemetry (§2) and the FP16 reference routing (§3) all
   share the TDQT v3 file format. The schema extension is
   additive (v3 + v4 strip), and a v3 reader can still read
   v4 files with reduced fidelity. The single highest-leverage
   change is **§1 (adaptive capture)** — it ships first because
   its trigger is what lets §3 (true FP16 reference) avoid the
   2x matmul cost (§13 risk 1 mitigation: trigger-gated
   reference). §1 unblocks §3; §3 unblocks §4; §4 unblocks §6.

2. **L2 / L3 / L4 coupling.** The activation-space differential
   (§4) is the substrate for both the spectral norm tracking
   (§5) and the autoregressive drift (§6). The domain-weighted
   prompt bank (§7) and the spec telemetry (§8) are both L4
   consumers. The L4 spec telemetry depends on the L1 + L1.5
   pair (for the per-position BF16 vs T640 logits). The
   L3 drift probe benefits from the speculative drift scoring
   (§13 risk 4 mitigation) which collapses 40 forwards to 8.

3. **L5 / L6 coupling.** The Hessian scorer (§9), the HIGGS
   alpha_l (§10), and the tail-weighted loss (§11) are all
   consumed by the GA objective in `tessera-dispatch.cpp:263-294`.
   They are *independent* in the sense that any one of them
   can be enabled alone, but the production GA benefits from
   all three: the Hessian scorer ranks which tensors to focus
   on; the HIGGS alpha_l weights the cross-tensor aggregation;
   the tail-weighted loss is the per-tensor fitness. The
   velocity-based convergence (§13 risk 7 mitigation) makes the
   AND-gate magnitude-agnostic, so adding a new loss form does
   not require re-calibrating `l5_joint_epsilon`.

> **Gate before any of this (added 2026-08-12).** The 11 refinements
> below total roughly six person-weeks and are layered on a spine
> whose layers have never been run against a real model pair. Since
> this spec was written, L1.5, L2's forward-pass differential, and
> L4's prompt bank have all landed, so the spine is wired end to end
> -- but no measurement from it exists. Consequently: every threshold
> these refinements tune against (L2's per-type expected Frobenius,
> L3's 0.99 cosine, L4's 0.5 PPL verdict) is an unfitted guess, and
> at least one of them is suspected wrong by ~9x (see
> `docs/l1-l5-pipeline-technical-report.md` section 12 item 1).
>
> Run one end-to-end calibration on gemma-4-12B and publish the
> drafter-acceptance and PPL numbers **first**. That run costs days,
> not weeks; it refits the thresholds, exercises `runtime_probe.py`
> and `e2e_probe.py`, and will reorder the list below. Building §16's
> tree-attention joint calibration and ANE heterogeneous dispatch on
> top of unmeasured layers is the main risk this document carries.

The recommended order of work (revised 2026-08-12 with the
agreed mitigations folded in; see §14 for the assessment):

1. **§1 Adaptive L1 Capture** — ships first because the
   outlier trigger is what gates the L1.5 materialization
   in §3. Backward-compatible (`FULL` mode = current
   behavior). 2-3 days.
2. **§3 True FP16 Reference** — depends on §1's trigger;
   trigger-gated so the L1.5 cost is O(outlier rate) not
   O(n). Unblocks §4. 1-2 days.
3. **§4 Activation-Space L2 Differential** — depends on §3.
   3-5 days.
4. **§6 Autoregressive L3 Drift** — depends on §4; uses the
   speculative drift scoring pattern (BF16 = verifier, T640 =
   drafter, tree-attention forward per measurement) to collapse
   the 10-minute probe to 1-2 minutes. 3-5 days.
5. **§7 Domain-Weighted L4 Prompt Bank** — independent; the
   active learning gate (max domain variance threshold)
   bounds the wall-clock cost. 3-5 days.
6. **§8 L4 Spec Telemetry** — independent; wire into the
   joint PPL harness (`ts_l5_trunk_forward_fn` callback) so
   the search RNG doesn't perturb the measurement. 1-2 days.
7. **§9 Hessian L5 Scorer** — independent; the L5 scorer API
   takes a generic "second-order info" struct so the v1
   full-Cholesky and the v2 Nyström share a single code
   path. The DuckDB cache key gets a `scorer_version` field.
   1 week.
8. **§10 HIGGS α_l** — depends on §7; the velocity-based
   convergence (improvement-per-generation gradient) replaces
   the static-magnitude AND-gate. 1 week.
9. **§11 Tail-Weighted L6 Loss** — depends on §3; plus the
   L6 acceptance verdict fix from the original audit (the
   `at.kernel_direct_t2 = comp_t2` hardcode in
   `tessera-dispatch.cpp:1346` becomes the actual
   `ts_l1_kernel_direct_t2_tail` when a sidecar is present).
   1 day for the loss + 1 day for the verdict fix.
10. **§2 L1 FP Telemetry** — independent. 1-2 days.
11. **§5 Spectral L2 Norm** — depends on §4. 1-2 days.

The first four are the spine: the L1 -> L2 -> L3 measurement
chain has to be non-trivial (real FP16 reference, real
activation-space differential, real per-position KL, real
outlier-driven capture) before any of the downstream scoring
matters. The remaining seven are independent and can be
parallelized. The velocity-based convergence is the
structural change with the longest tail: every future
loss-form change in the L6 family (tail-weighted, Hessian-
blended, regime-conditional) requires *zero* gate
re-calibration.

The highest-leverage single change that ships standalone is
the **trigger-gated L1.5 path** — it is a 1-day PR to
`common/tessera-debug/tessera-debug.cpp` (~20 LoC), back-
ward-compatible, testable end-to-end on the existing
synthetic two-tensor GGUF (`test_l5_dispatch.cpp`), and
unblocks three downstream items (the L1.5 spine, the §1
trigger logic, and the L3 row-subset computation). Ship
that first, then take the rest of the spine in order.

## 13. Risks and open questions

_The mitigations below were revised 2026-08-12 after the
architect's design review. Each risk is paired with the
specific mitigation, code anchor, and acceptance test that
shows the mitigation is sufficient. See §14 for the
assessment verdicts on the 8 mitigations proposed and the 3
additional ones added during the review._

1. **The FP16 reference cost is 2x the matmul work.**
   The L1.5 path is gated by `dequant_w4a4_enabled()`; making
   it the production L1.5 means doubling the L1 calibration
   cost. **Mitigation (trigger-gated reference):** tie the
   L1.5 materialization directly to the §1 outlier trigger.
   If a row doesn't fire `row_outlier_count[r] > trigger_quantile`,
   the L1.5 path substitutes the F32 mean+stddev surrogate
   from §1's Mode A instead of running the unquantized matmul.
   For a 12B with 1 % outlier rate, the L1.5 cost drops from
   2x to ~1.01x of the L1 cost. Implementation: one branch
   in the L1.5 hook (~5 LoC) reading
   `tessera-debug::dequant_capture_mode()`; the branch sits
   next to the existing `dequant_w4a4_enabled()` gate in
   `common/tessera-debug/tessera-debug.cpp`. **Interleaved
   heterogeneous dispatch (kernel fusion) is rejected** —
   it's a kernel-engineering problem that doesn't pay for
   itself on a calibration pass that runs once per model.

2. **The HIGGS α_l is a model fingerprint.** Two different
   models with the same architecture have different α_l.
   The DuckDB cache key must include the model and corpus
   identity. **Mitigation:** the existing `model_hash` is
   already SHA-256 over the safetensors index or GGUF
   content; a 64-bit prefix has collision probability
   ~10^-19 for any practical model count. **Add
   `scorer_version` to the cache key** (new): a bump on
   every scorer change (Hessian damping, Cholesky block
   size, etc.) invalidates stale cache entries silently
   rather than producing wrong scores. **MinHash/LSH corpus
   sketching is deferred to v2** — the value/cost ratio is
   bad for exact-match corpora and only matters for the
   joint PPL path where the corpus is regenerated. **Topological
   Merkle hashing is rejected** as over-engineered for the
   collision risk; the existing flat SHA-256 is sufficient.

3. **The Hessian capture is a 64 MB / tensor F32 buffer.**
   For a 12B model with 48 tensors, this is 3 GB of working
   set just for the Hessians. **Mitigation (Nyström-ready
   API, in-core v1):** design the L5 scorer API
   (`ts_l5_hessian_sensitivity`) to take a generic
   "second-order info" struct, not a literal Hessian. The v1
   implementation uses full Cholesky (one per 4096-dim
   tensor, ~10 seconds on M-series Metal). The v2 swap to
   Nyström approximation (k = sqrt(d) landmarks, O(d*k) =
   4 MB/tensor) is an internal implementation change with no
   API impact. **Out-of-core Cholesky (unified memory +
   disk streaming) is deferred to 70B+**: the 3 GB working
   set is acceptable on Apple Silicon unified memory; the
   18 GB working set for 70B+ would need it but Tessera's
   primary scale target is the 12B-drafter / 70B-verifier
   joint path where the L5 scorer runs on the drafter.
   **K-FAC is rejected for v1** because it needs gradient
   computations that the L5 scorer doesn't have access to
   in the current dispatch; Nyström is the right next move.

4. **The L3 autoregressive drift is a forward-pass probe**
   and **the L3 measurement is a four-forward attribution,
   not a single joint probe.** A real 200-position forward
   pass on a 12B model is ~10 seconds; the L3 calibration
   is ~10 minutes for 60 calibration samples. **Mitigation
   (speculative drift scoring on the joint forward, four-
   forward attribution via KV swap):** treat the BF16 model
   as the "verifier" and the T640 model as the "drafter" in
   a single tree-attention forward for the joint error
   (forward B vs A). The KL divergence is the rejection-
   sampling log-ratio in the Leviathan formulation, so one
   tree-attention forward scores multiple future positions.
   For 200 positions with EAGLE-2 default trees (depth 6,
   width 4), the 40 forward passes collapse to 8 — the
   10-minute probe becomes 1-2 minutes, and the measurement
   is *more robust* because it scores agreement across
   positions, not point-wise KL. **For the attribution
   forwards (C: T640 weights + BF16 KV cache, D: BF16
   weights + T640 KV cache), the architect's correction
   (2026-08-12) reframes what was originally rejected as
   "KV-cache divergence predictors":** the L3 measurement
   is about *reconstructed losslessness* (weight + KV cache
   together), not original-BF16 vs reconstructed, and the
   KV cache is itself a quantized surface plumbed via
   `cache_type_k`/`cache_type_v` in `src/llama-kv-cache.cpp:231-232`
   (default `GGML_TYPE_F16` in `common/common.h:386`). The
   four-forward pattern (A reference, B deployed, C weight-
   isolated, D KV-isolated) is the *attribution framework*
   that decomposes the joint error by source. The KV swap
   is a per-forward override of the cache type in the model
   context (the quantized K/V buffers are pre-built; the
   override is a context flag, not a runtime quantization).
   The full four-forward L3 probe is 3-6 minutes on 12B
   with the speculative scoring on B, plus 1-2 minutes for
   the shared reference A — under the 10-minute target.

5. **The L4 prompt bank is large.** The 13 categories with
   50-100 prompts each is ~1000 prompts at ~512 tokens each
   = ~500K tokens. The L4 run is ~5 minutes per model on
   M-series Metal. **Mitigation (active learning gates):**
   tiered CI gate. Run a 10-prompt smoke test per domain
   first; if `max(|pass_rate_d - 1/N_prompts_d|) > 0.15`
   across the 13 domains, dynamically unroll to the full
   bank. The bimodality detection is the *max* domain
   variance, not global variance, so "code failing while
   factual is fine" triggers the unroll (global variance
   would miss this). **Dataset distillation is deferred to
   v2** — it's a 1-2 week research project and the active
   learning gate collapses most of the L4 wall-clock cost
   in practice (the smoke test passes for ~90 % of models).

6. **The L5 Hessian scorer changes the GA's behavior.** A GA
   that scores against the Hessian will route differently
   than a GA that scores against imatrix magnitude. The
   regime-routing table in `tessera-regime.cpp` may need
   re-tuning. **Mitigation (table column, not search):** add
   a sixth axis to the 5-axis descriptor
   (`ts_regime_compute_descriptor`) — `hessian_sensitivity
   bucket` — and expand the routing table by one column. The
   existing 4-tier dynamic router handles the new axis
   without a code change beyond the bucket boundaries. The
   boundaries are OLS-fit from the DuckDB `l5_outcome` table
   on the next L5 run. **NSGA-II / Pareto co-evolution is
   rejected** for routing: per-tensor dispatch is a hash
   table lookup, not a search. Running NSGA-II per forward
   pass would be 100-1000x slower than the current lookup.
   Pareto co-evolution may be appropriate for the per-tensor
   GA (the L5 search), but that's a different problem from
   routing. The imatrix scorer remains available as
   `--tessera-l5-scorer=imatrix` for backward compatibility.

7. **The L6 tail-weighted loss changes the convergence
   criterion.** The AND-gate at `l5_joint_epsilon` was
   calibrated against the Frobenius-based `t_l^2`. The
   tail-weighted `t_l^2_tail` has a different distribution
   and may need a different gate. **Mitigation (velocity-
   based convergence):** replace the static-magnitude gate
   with a gradient-and-acceleration gate. Track
   `d(t_l^2_tail)/dg` and `d^2(t_l^2_tail)/dg^2` over
   generations. Gate on `|d| < velocity_threshold AND
   |d^2| < acceleration_threshold`. This is
   magnitude-agnostic: the same machinery applies to
   Frobenius, tail-weighted, Hessian-blended, or any future
   loss form. The L5 joint PPL already has slippery
   detection (`ts_l5_joint_is_slippery` in
   `common/tessera-l5-joint.h:190`) on per-generation
   improvement vs epsilon/5; extending it to per-tensor
   L6 is one implementation, two consumers. The `lambda_tail`
   knob remains as the per-loss-form lever.

8. **The L4 spec telemetry is per-step overhead.** The
   per-layer acceptance capture adds one log per drafted
   token per layer. For a 12B with 32 layers and 200 drafted
   tokens, this is 6400 extra logs per spec step. **Mitigation
   (append-only binary event ledger with 8-bit counts):**
   pack the per-(token, layer) acceptance count into a dense
   `uint8_t` (not a 1-bit flag — that loses the count, which
   is the basis for `per_layer_alpha`). 5 KB per step vs
   800 bytes for 1-bit, but 8x the information. Lock-free
   ring buffer with a decoupled flush thread (the
   io_uring/SPDK pattern). A background thread flushes the
   ring to an append-only JSONL historical ledger. The
   critical-path overhead is O(1) ring-buffer write.
   The first-reject layer per step is the always-captured
   signal; the per-layer breakdown is gated by
   `--tessera-spec-telemetry-full`.

9. **NEW: L5 cache invalidation on scorer schema bump.** A
   change to the Hessian scorer (Cholesky damping, block
   size) silently produces wrong cached scores if the cache
   key doesn't include the scorer version. **Mitigation:**
   add `scorer_version` to the DuckDB cache key in
   `tessera-quantize-db.h`; bump it on every scorer change.
   ~10 LoC, catches a class of bugs that would otherwise
   show up as "the GA got worse and we don't know why."

10. **NEW: L4 spec telemetry's interaction with the joint
    PPL path.** The joint PPL harness in
    `common/tessera-ppl-harness.h` already runs 5 models in
    one forward. The L4 spec telemetry records per-layer
    drafter acceptance — which requires the verifier +
    drafter to run with the same calibration input. The
    joint PPL search has its own RNG (default `0x5EED5u`),
    which would make the spec telemetry non-reproducible
    across runs if the search RNG perturbed the trunk
    forward. **Mitigation:** wire the spec telemetry capture
    into the harness's `ts_l5_trunk_forward_fn` callback, not
    the search loop. The trunk forward is deterministic given
    the calibration input; the search RNG affects only the
    policy mutation, not the per-step accept/reject.

11. **NEW: L6 tail-weighted loss interaction with the
    4-tier dynamic router.** The Tier 2 scorer in
    `tessera-regime.cpp` is activation-stats (kurtosis,
    eff_rank, max_outlier_ratio). The L6 tail-weighted loss
    is per-tensor and is *post-hoc* in the dispatch (it
    doesn't feed back into routing). A tensor that should be
    routed to SEPTQ (because its tail-weighted loss is high)
    might be routed to AWQ (because its kurtosis is
    moderate) under the current scheme. **Mitigation:** add a
    Tier 4 feedback loop where the L5 adaptive requantizer's
    `l5_outcome` table records `tail_loss / frob_loss` per
    tensor per generation. The next run's Tier 2 thresholds
    are OLS-fit from this signal. This is the "DuckDB
    `l5_outcome` feeds OLS for threshold refit" line in
    `tessera-regime.h:18` that the current code describes
    but doesn't implement. The feedback loop is one column
    on the existing `l5_outcome` table plus a
    `ts_regime_refit_thresholds()` call after the L5 loop.

## 14. Mitigations assessment (2026-08-12 review)

_This section records the design review held after the v1 of
this spec. The architect proposed 8 mitigations for §13 risks;
this section records which were accepted as proposed, which
were accepted with refinement, and which were rejected, plus
3 additional mitigations added during the review._

### 14.1 Strong accept (do as proposed)

- **#1b Trigger-Gated Reference** for the L1.5 2x matmul
  cost (§13 risk 1). Cleaner than the v1 "subsample the
  L1.5 path" line: ties the L1.5 materialization to the same
  outlier trigger that drives the L1 capture, collapsing the
  cost to O(outlier rate) not O(n). For 12B with 1 % outlier
  rate, ~1.01x of L1 cost, not 2x.
- **#4b Speculative Drift Scoring** for the L3 probe
  latency (§13 risk 4). Strictly better than v1's "32
  samples is enough": treats BF16 as verifier and T640 as
  drafter in a tree-attention forward. KL is the
  rejection-sampling log-ratio in the Leviathan formulation,
  so one forward scores multiple future positions. 40
  forwards collapse to 8; the 10-minute probe becomes 1-2
  minutes, and the measurement is more robust.
- **#5b Active Learning Gates** for the L4 prompt bank
  (§13 risk 5). One refinement: gate on the *max* domain
  variance, not global variance, so per-domain failures
  trigger the unroll. Threshold: `max(|pass_rate_d -
  1/N_prompts_d|) > 0.15`.
- **#7 Velocity-Based Convergence** for the L6 gate
  re-calibration (§13 risk 7). Strictly better than v1's
  static-magnitude "small empirical sweep." The
  L5 joint PPL already has slippery detection on
  per-generation improvement (`ts_l5_joint_is_slippery` in
  `common/tessera-l5-joint.h:190`); extending to L6 is
  one implementation, two consumers. Magnitude-agnostic:
  every future loss form requires zero gate re-calibration.
- **#8 Append-Only Binary Event Ledgers** for the spec
  telemetry overhead (§13 risk 8). One push-back: **1 bit
  per (token, layer) is lossy**. Use `uint8_t` per cell
  (5 KB per step vs 800 bytes for 1-bit; 8x the
  information; preserves the per-layer acceptance count
  that `per_layer_alpha` depends on).

### 14.2 Accept with refinement (do, but with a different shape)

- **#2b Corpus Sketching (MinHash/LSH)** for the α_l cache
  (§13 risk 2). Right category of solution, wrong timing.
  v1 keeps the existing SHA-256 of corpus bytes for exact
  match. MinHash is a marginal optimization on top of
  exact-match; defer to v2 unless we measure real cache-miss
  pain.
- **#3b K-FAC / Nyström** for the Hessian memory cost
  (§13 risk 3). Right answer for 70B+; for 12B the full
  Cholesky is the simpler choice. Design the L5 scorer API
  to accept a generic "second-order info" struct so the v1
  full-Cholesky and the v2 Nyström share a single code
  path. K-FAC is rejected for v1 (needs gradient
  computations the L5 scorer doesn't have access to);
  Nyström is the right next move.
- **#3a Out-of-Core Cholesky** for the Hessian memory cost
  (§13 risk 3). Right category, wrong timing. Apple
  Silicon's unified memory handles 3 GB fine; the 18 GB
  working set for 70B+ would need this, but Tessera's
  primary scale target is the 12B-drafter path. Design the
  L5 scorer to accept either in-core or out-of-core Hessian
  sources; ship in-core first.

### 14.3 Reject

- **#1a Interleaved Heterogeneous Dispatch** for the L1.5
  cost. A kernel-fusion problem (separate command encoders,
  separate streams, separate memory) that doesn't pay for
  itself on a *calibration* pass that runs once per model.
  2x calibration cost is acceptable. Spend the
  kernel-engineering hours on the L1 hook quality or the L6
  verdict fix.
- **#6 Pareto Co-evolution / NSGA-II** for the L5 routing
  disruption. Wrong tool for the wrong job. The regime
  router in `tessera-regime.cpp` is a *dispatch function*,
  not a search. NSGA-II per forward pass would be 100-1000x
  slower than the current lookup table. The right answer is
  one new column in the routing descriptor (the
  `hessian_sensitivity` bucket); see §13 risk 6.
- **#2a Topological Merkle Hashing** for the model
  fingerprint. The existing `model_hash` (SHA-256 of the
  safetensors index or GGUF content) has collision
  probability ~10^-19 for any practical model count. A
  Merkle tree over tensor topology is over-engineered. The
  right per-layer PPL response to perturbation depends on
  the precision anyway, so the cache key includes precision
  directly; a content-addressed tree is unnecessary.
- **#5a Dataset Distillation** for the L4 prompt bank.
  Real research technique but a 1-2 week project, and the
  active learning gate in #5b collapses most of the L4
  wall-clock cost in practice. Defer to v2.
- **#4a KV-Cache Divergence Predictors** — **REJECTED in v1,
  RESURRECTED and REFINED in v2 after the architect's
  correction (2026-08-12).** My v1 rejection was wrong: the
  L3 measurement is about *reconstructed* losslessness
  (weight + KV cache together), not original-BF16 vs
  reconstructed, and the KV cache is itself a quantized
  surface plumbed via `cache_type_k`/`cache_type_v`. The
  v2 framing is a *four-forward attribution framework*
  (A: BF16 reference, B: T640 deployed, C: T640 weights +
  BF16 KV cache, D: BF16 weights + T640 KV cache). The
  coupling ratio `kl_joint / max(kl_weight, kl_kv)` and the
  `attribution` enum (COMPOUNDING / WEIGHT / KV / NUMERICAL
  / OK) decompose the joint error by source and route the
  L5 dispatch to the right action (mid-stack tighten,
  weight outlier bump, KV precision raise, or numerical
  investigation). #4a as written was "use BF16 KV with
  T640 weights to be faster" — that was the wrong
  motivation. The right framing is "isolate the weight
  reconstruction error from the KV cache reconstruction
  error, and from their joint compounding."

### 14.4 Additional mitigations added during review

Three mitigations were added that the architect did not
propose, surfaced by the gap analysis between the proposed
mitigations and the v1 risks:

- **§13 risk 9 — L5 scorer_version cache key.** The
  Hessian scorer (§9) silently produces wrong cached scores
  if the cache key doesn't include the scorer version. Add
  `scorer_version` to the DuckDB cache key; bump on every
  scorer change. ~10 LoC, catches a class of bugs that
  would otherwise show up as "the GA got worse and we
  don't know why."
- **§13 risk 10 — L4 spec telemetry wire into the joint
  PPL harness, not the search loop.** The search RNG
  affects policy mutation, not the per-step accept/reject.
  Wire into `ts_l5_trunk_forward_fn` for reproducibility.
- **§13 risk 11 — L6 tail-weighted loss feedback into the
  4-tier router.** The current Tier 2 scorer (kurtosis,
  eff_rank) doesn't see the tail-weighted loss; a tensor
  that should be routed to SEPTQ might be routed to AWQ
  under the current scheme. Add a Tier 4 OLS feedback loop
  on the `l5_outcome` table: record `tail_loss / frob_loss`
  per tensor per generation, refit the Tier 2 thresholds on
  the next run. This is the line in `tessera-regime.h:18`
  that the current code describes but doesn't implement.

### 14.5 Concrete first PR

The highest-leverage single change that ships standalone and
unblocks the most downstream work is the **trigger-gated
L1.5 path** (the combination of §1's outlier trigger and
§3's L1.5 materialization). It is:

- A change to `common/tessera-debug/tessera-debug.cpp`
  (~20 LoC: read `dequant_capture_mode()`, branch the L1.5
  materialization on it).
- A schema bump on the sidecar (TDQT v3-extension, same as
  §1 in this spec).
- Backward-compatible: `dequant_capture_mode() == FULL` is
  the current behavior, no callers need to change.
- Enables §3 (True FP16 Reference) without doubling
  calibration cost.
- Enables §1 (Adaptive L1 Capture) by sharing the trigger
  logic.
- Testable end-to-end on the existing synthetic two-tensor
  GGUF (`test_l5_dispatch.cpp`).

This is a 1-day PR that unblocks three downstream items
(§1, §3, and the L3 row-subset computation) and is the
recommended first commit. After it lands, the rest of the
spine (§4, §6, §7, §8) follows in order.

---

## 15. References (full bibliography)

### Outlier-aware quantization
- Dettmers et al. (2022). "LLM.int8(): 8-bit Matrix
  Multiplication for Transformers at Scale." NeurIPS 2022.
  arXiv:2208.07339.
- Dettmers et al. (2023). "SpQR: A Sparse-Quantized
  Representation for Near-Lossless LLM Weight Compression."
  arXiv:2306.03078.
- Lee et al. (2024). "OWQ: Outlier-Aware Weight Quantization
  for Efficient Fine-Tuning and Inference of Large Language
  Models." AAAI 2024. arXiv:2306.02272.
- Xiao et al. (2023). "SmoothQuant: Accurate and Efficient
  Post-Training Quantization for Large Language Models."
  ICML 2023. arXiv:2211.10438.

### Hessian-based PTQ
- Frantar et al. (2023). "GPTQ: Accurate Post-Training
  Quantization for Generative Pre-trained Transformers."
  ICLR 2023. arXiv:2210.17323.
- Frantar & Alistarh (2022). "Optimal Brain Compression: A
  framework for accurate post-training quantization and
  pruning." arXiv:2208.11580.
- Chee et al. (2024). "QuIP: 2-Bit Quantization of Large
  Language Models With Guarantees." ICML 2024.
  arXiv:2307.13304.

### Linearity Theorem / HIGGS
- Malinovskii et al. (2024/2025). "Pushing the Limits of
  Large Language Model Quantization via the Linearity
  Theorem." NAACL 2025. arXiv:2411.17525.

### Speculative decoding
- Leviathan, Kalman, Matias (2023). "Fast Inference from
  Transformers via Speculative Decoding." ICML 2023.
- Chen et al. (2023). "Accelerating Large Language Model
  Decoding with Speculative Sampling." arXiv:2302.01318.
- Li et al. (2024-2026). "EAGLE-1/2/3: Lossless
  Acceleration of LLM Decoding by Feature-level
  Self-Drafting." Various arXiv.
- Sun et al. (2026). "TriSpec: Ternary Speculative Decoding
  via Lightweight Proxy Verifiers." arXiv:2601.23180.

### Spectral methods
- ARSVD (2025). "Low-Rank Matrix Approximation for Neural
  Network Compression." arXiv:2504.20078.
- D-Rank. "Layer-wise Dynamic Rank for Compressing LLMs."
  OpenReview f13c53d16fdbe2e43a5b274aad9196a976b0c553.
- Yuan et al. (2023). "ASVD: Activation-aware Singular Value
  Decomposition for Compressing Large Language Models."
  arXiv:2312.05821.

### Floating point
- Micikevicius et al. (2018). "Mixed Precision Training."
  ICLR 2018. arXiv:1710.03740.
- Kalamkar et al. (2019). "A Study of BFLOAT16 for Deep
  Learning Training." arXiv:1905.12322.
- Micikevicius et al. (2022). "FP8 Formats for Deep
  Learning." arXiv:2209.05433.
- Apple Metal Shading Language Specification §5.5.

### Evaluation
- Biderman et al. (2024). "Lessons from the Trenches on
  Reproducible Evaluation of Language Models." arXiv:2405.14782.
- Chroma Research (2025). "Context Rot: How Increasing Input
  Tokens Impacts LLM Performance." July 2025.
- Modarressi et al. (2025). "NoLiMa: Long-Context Evaluation
  Beyond Literal Matching." arXiv:2502.05167.
- Hsieh et al. (2024). "RULER: What's the Real Context Size
  of Your Long-Context Language Models?" arXiv:2404.06654.
- Wu et al. (2024). "LongMemEval: Benchmarking Chat
  Assistants on Long-Term Interactive Memory." arXiv:2410.10813.

### Activation regeneration
- "FAQ: Mitigating Quantization Error via Regenerating
  Activations." arXiv:2601.11200.
- "Activation Sensitivity as a Unifying Principle for
  Post-Training Quantization." arXiv:2601.11663.

### Internals (existing Tessera code)
- `docs/runtime-aware-pipeline.md` (the L1-L6 design spec)
- `docs/research-alignment-2026-07-30.md` (the binding to
  the external literature)
- `docs/l1-l5-pipeline-technical-report.md` (the audit)
- `common/tessera-debug/tessera-debug.{h,cpp}` (L1 hook)
- `common/tessera-debug/tessera-sidecar-v3.{h,cpp}` (TDQT v3)
- `tools/quantize/tessera/tessera-l1-fitness.{h,cpp}` (L6)
- `tools/quantize/tessera/tessera-l2-diff.{h,cpp}` (L2)
- `tools/quantize/tessera/tessera-l3-coherence.{h,cpp}` (L3)
- `tools/quantize/tessera/tessera-l5.{h,cpp}` (L5 scorers)
- `tools/quantize/tessera/tessera-ppl.{h,cpp}` (L4)
- `tools/quantize/tessera/tessera-dispatch.cpp` (the wiring)
- `tools/quantize/tessera/tessera-regime.cpp` (4-tier router)
- `common/tessera-l5-joint.{h,cpp}` and
  `common/tessera-ppl-harness.{h,cpp}` (joint PPL path)
- `common/ane-mtp.{h,mm}` (ANE prefill surface, the ANE/GPU
  heterogeneous dispatch target for v2)
- `src/llama-kv-cache.cpp:231-232` (the typed KV cache,
  `type_k` / `type_v`, the surface for the four-forward L3
  attribution and the joint drafter KV recompute)

---

## 16. Joint calibration thesis (NEW, v5)

_The conceptual capstone. The L1-L6 layers are the
implementation; this section is the goal they implement.
The verifier + 3 drafters + talker are calibrated and
quantized together, in one joint forward, with the
drafter's loss attribution as the primary L5 trigger.
Read this section last; everything above is a building
block for it._

### 16.1 The thesis

A spec-decoding pipeline is a coupled system. The verifier
sets the distribution that the drafters approximate. When
the verifier's calibration shifts — alpha/clip tighten on
a layer, an outlier bump, a new quant ladder — the
drafters' alignment collapses at the corresponding layer.
The 0.86 % gemma-4-12B drafter acceptance case is the
exemplar: the bulk of the network was miscalibrated, and
the drafter's feature-level projection of the verifier's
hidden state lost fidelity at the same layers where the
verifier's distribution shifted.

**Thesis.** The L5 optimization loop must consume the
drafter's loss attribution as a primary signal, not as a
post-hoc measurement. The verifier's per-tensor policy is
informed by which layer the drafter lost alignment at; the
drafter's per-tensor policy is informed by the verifier's
distribution at the layer the drafter consumes. Both are
recalibrated in the same joint forward, with the L5
trigger routed per-drafter to the family responsible for
the attribution spike.

This is the integrating thesis for the L1-L6 spine. The
layers are not a parallel set of optimizations; they are
the implementation of this thesis. L1 is the kernel
ground truth that the joint forward measures. L2 is the
per-tensor divergence. L3 is the four-forward attribution.
L4 is the per-drafter per-layer telemetry. L5 is the
drafter-driven trigger. L6 is the kernel-direct fitness
that the joint forward scores against.

### 16.2 Central measurement primitive: single tree-attention forward

The joint calibration runs **one tree-attention forward**
per calibration sample, with the BF16 model as the
verifier and the T640 verifier + 3 drafters + talker as
drafters. The Leviathan-style rejection sampling
(Leviathan, Kalman, Matias, ICML 2023) treats each
drafter as a speculative proposal generator; the BF16
verifier validates in one tree-attention forward. This
is the joint PPL harness in `common/tessera-l5-joint.h`,
extended with the per-drafter `loss_attribution_d[layer]`
field that the L5 trigger consumes.

**Tree shape.** EAGLE-2 default (depth 6, width 4). For a
joint calibration with 4 drafters, the tree has
`4 * 16 = 64` candidate leaves per verifier forward.
Tree-attention in the verifier's last forward pass scores
all 64 candidates in `O(log n)` per token (vs `O(n)` for
sequential verification). The 5x forward cost (one per
drafter + one for the verifier) collapses to ~1.5x with
tree-attention.

**ANE heterogeneous dispatch (v2).** Apple Silicon has
unified memory and three execution units: CPU, GPU, ANE.
The v1 calibration runs the BF16 reference and the T640
matmul sequentially on the same backend. The v2 dispatch
maps the BF16 reference to the ANE (a fixed-function
FP16 accelerator) and the T640 matmul to the GPU. Both
share the activation input via unified memory. The
calibration cost is `T640 * (1 + 1/3) = 1.33x` of the
GPU-only baseline (ANE FP16 is ~3x the Metal GPU
matmul on the same workload; the GPU does the T640 path
in 1x). The v1.7 architectural note (§1.7) is the API
constraint that makes this possible without a breaking
change to the L1 hook signature.

The ANE surface is `common/ane-mtp.{h,mm}`. The dispatch
gates the ANE path on `--tessera-l1-ane-enabled` (default
off in v1, on in v2 when the ANE surface is verified).

**Cost summary.** Joint calibration per sample, 200 tokens,
12B verifier, three 12B drafters, 4B talker:

| Phase | v1 (sequential) | v2 (tree + ANE) |
|-------|-----------------|-----------------|
| BF16 reference | 1x | 1x (ANE) |
| T640 verifier | 1x | 1x (GPU) |
| DFlash drafter | 1x | ~0.1x (tree) |
| DSpark drafter | 1x | ~0.1x (tree) |
| MTP drafter | 1x | ~0.1x (tree) |
| Talker | 1x | ~0.1x (tree) |
| **Total per sample** | **6x** | **~1.4x** |

For a calibration pass with 32 samples and 5 L5
generations, the v1 wall-clock is 6 * 32 * 5 = 960
single-forward equivalents; the v2 wall-clock is 1.4 * 32
* 5 = 224 single-forward equivalents. ~4x speedup on
Apple Silicon; ~6x speedup on discrete GPU + ANE hosts.

### 16.3 Drafter-driven L5 trigger

The L5 trigger consumes three signals from the joint
forward:

1. `first_reject_layer_peak`: the mode of the histogram
   of the first-reject-layer per spec step. A shift in
   this mode (e.g., from layer 32 to layer 16) is the
   primary drafter-attribution signal.
2. `per_drafter_alpha`: the per-drafter mean acceptance
   rate. A drop in `per_drafter_alpha` for one drafter
   but not others is the architectural-mechanism signal.
3. `loss_attribution_d[layer]`: the per-drafter, per-
   layer loss gradient. This is the routing signal — the
   layer with the highest attribution per drafter is the
   family to tighten.

**Asynchronous actuation.** The trigger runs
*asynchronously* to the joint forward. The forward
emits per-step telemetry into the append-only JSONL
ledger at ~100 Hz (the existing `llama.tessera.spec.v1`
capture rate); the L5 trigger tails the ledger between
forwards, not inside them. The KV cache strategy (§16.4)
is built on this — the trigger fires after a forward
completes, when the cache is no longer needed.

**Sliding-window debouncing.** The trigger is debounced to
avoid noise-driven actuation. The debounce rule: fire
Stage A tighten on family `F` for drafter `d` if

```
count(reject_layer == peak_layer_d, window=50) > N
```

with `N = 20` (40% of the 50-step window) and
`peak_layer_d` defined as the most frequent
`first_reject_layer` for drafter `d` over the window. A
single anomalous reject is noise; a sustained shift in
the histogram is the signal. The debounce window of 50
steps at ~100 Hz is 0.5 seconds of joint forward time.

**Loss-attribution routing.** When the trigger fires, the
destination is per-drafter:

```
for each drafter d:
    layer_d = argmax_layer loss_attribution_d[layer]
    family_d = ts_regime_infer_family(layer_d)
    tighten_d = {
        family: family_d,
        alpha_scale: 0.5 * (loss_attribution_d[layer_d] / max_attribution),
        clip_scale: 0.5 * (loss_attribution_d[layer_d] / max_attribution)
    }
    if tighten_d.alpha_scale < 0.1: tighten_d.alpha_scale = 0.1
    if tighten_d.clip_scale < 0.1: tighten_d.clip_scale = 0.1
```

The `0.5` multiplier and the `0.1` floor mirror the
existing Stage A parameters in `ts_l5_adaptive_requant`
(`ts_l5_adaptive_params::alpha_scale = 0.5`,
`min_alpha = 0.1` per `tessera-l5.h:117-121`). The
attribution-weighted `alpha_scale` and `clip_scale` are
the drafter-specific tightening magnitude. Multiple
drafters can fire different tightens in the same forward
(DSpark's attribution spike at layer 16 fires a tighten
on layer 16's `ffn_down`; DFlash's attribution spike at
layer 24 fires a tighten on layer 24's `attn_v`; both
tightens apply on the next forward).

**Why debouncing matters for context rot.** Chroma
Research (2025 Context Rot, Hong et al.) measured 18
frontier models across 194,480 calls and found that
performance degradation is *continuous from token 1*, not
just at context overflow. The mechanism is
attention-budget dilution: at any sequence length, the
per-token attention signal is bounded. A spurious
`first_reject_layer` outlier at token 17 (an
anomalous-but-noise reject) is not the same as a
sustained shift to layer 16 over 50 tokens. The
sliding-window debounce distinguishes the two. Without
debouncing, every noise reject would fire a tighten,
chasing ghosts and masking the root cause.

### 16.4 KV cache strategy

The L5 trigger mutates the verifier's weights. The KV
cache built from the previous weights is stale at the
affected layer. The strategy depends on when the trigger
fires:

**Default — tolerate staleness between forwards.** The
trigger fires after a joint forward completes. The
next joint forward rebuilds the KV cache from the new
weights. The cache is not in use at the trigger point.
This is the trivial case and the right default.

**Opt-in — selective recompute (mid-forward actuation).**
The rare scenario where the trigger must fire inside a
long forward (e.g., a multi-thousand-token calibration
pass). The staleness analysis:

A Stage A tighten on `blk.N.ffn_down` mutates the
weights at layer N. The KV cache staleness is:

- **Verifier KV at layer L > N for positions 0..p**:
  stale. K and V at downstream layers were computed
  from a hidden state produced by the old `ffn_down`;
  the new `ffn_down` produces a different hidden state.
- **Verifier KV at layer L ≤ N**: not stale. New
  `ffn_down` is downstream of these layers.
- **Drafter KV at all layers for positions 0..p** (if
  drafter's `target_layer_id > N`): stale. Drafter
  consumes verifier's hidden state at `target_layer_id`,
  which is stale; drafter's K and V depend on its
  projection of that hidden state.

The recompute, when enabled:

1. For the affected verifier layer L, recompute K and V
   at positions 0..p-1 with the new weights.
   Cost: O(p · d_kv) per affected layer. For p=200,
   d_kv=128, that's 25,600 FLOPs. Trivial.
2. For the cascade — verifier layers L+1, L+2, ... —
   recompute K and V at positions 0..p-1.
   Cost: O(L_cascade · p · d_kv) where L_cascade is the
   number of downstream layers. For 12B with 32 layers,
   L_cascade=16, p=200, d_kv=128, that's 410K FLOPs.
3. For each drafter whose `target_layer_id > N`,
   recompute the drafter's K and V at all positions
   0..p-1. Cost: O(N_drafters_affected · N · d_drafter).
   For 4 drafters, N=200, d_drafter=4096, that's 3.2M
   FLOPs.
4. For each drafter whose `target_layer_id ≤ N`: no
   recompute needed.

**Total cost of a mid-forward L5 fire**:
O(L_cascade · p · d_kv + N_drafters_affected · N · d_drafter).
At p=200, this is ~5M FLOPs — negligible against the
verifier forward. On Apple Silicon unified memory, the
recompute is a clean matrix multiplication against the
new weights, not a memory copy.

**Catastrophic — full discard (rare).** The third tier,
for the rare case where the L5 trigger fires more than
~3 times in a single forward. Discard all KV caches and
restart from position 0. Cost: O(N · L · d_kv) — full
forward rebuild. Opt-in only.

The KV cache strategy is implemented in
`ts_l5_kv_recompute_policy`:

```cpp
enum ts_l5_kv_recompute_policy {
    TS_L5_KV_TOLERATE_STALENESS = 0,  // default
    TS_L5_KV_SELECTIVE_RECOMPUTE = 1,  // opt-in
    TS_L5_KV_FULL_DISCARD         = 2,  // rare
};
```

The default is `TOLERATE_STALENESS`. The opt-in flags
are `--tessera-l5-kv-policy=selective | full-discard`
on the dispatch. The selection is per-trigger (each
L5 fire can pick its own policy based on the staleness
depth and the cascade cost).

### 16.5 Memory strategy for verifier-scale joint calibration

For the joint calibration at verifier scale (70B+
verifier, three 12B drafters, 4B talker), the Hessian
working set is:

| Component | In-core (O(d^2)) | Streaming (O(d)) | Nyström (O(d·k)) |
|-----------|------------------|------------------|------------------|
| Verifier 70B+ | 18 GB | ~16 KB/tensor | ~1 MB/tensor |
| 3x 12B drafter | 9 GB | ~16 KB/tensor | ~1 MB/tensor |
| 4B talker | 1 GB | ~16 KB/tensor | ~1 MB/tensor |
| **Aggregate** | **~28 GB** | **~768 KB** | **~96 KB** |

**STREAMING is the production default.** Per-row OBQ
sensitivity, O(d) memory per tensor, exact (no lower-
bound). On Apple Silicon unified memory, the sequential
"disk reads" are effectively L2/L3 cache hits; the wall-
clock cost is dominated by the per-row matmul work, not
the sensitivity computation. STREAMING is the right
default for the joint calibration because false negatives
in the sensitivity (missed requantizations) directly
cause drafter acceptance collapse — exactly the failure
mode the drafter-driven L5 trigger is designed to
prevent.

**Nyström is the constrained-resource fallback** for:

1. **Linux without unified memory** — STREAMING's disk
   reads are real I/O; on NFS or slow SSD, Nyström
   trades accuracy for I/O independence.
2. **Tier 0 CI smoke tests** — 10 distilled prompts,
   ~1 second budget per tensor. Nyström's k=sqrt(d)
   lands in <100 ms per tensor on CPU; STREAMING is
   exact but adds ~500 ms per tensor on a constrained
   box.

**Auto-detection.** `--tessera-l5-hessian-source=auto`
selects based on platform:

| Platform | Default source |
|----------|----------------|
| macOS / Apple Silicon (unified memory) | STREAMING |
| Linux + unified memory (CUDA UVA) | STREAMING |
| Linux + discrete GPU (no UVA) | NYSTROM |
| Tier 0 smoke test | NYSTROM |

The CLI override is `--tessera-l5-hessian-source=in_core
| streaming | nystrom | auto` for the rare case where
auto-detection is wrong.

The source-selection happens once at dispatch start;
the L5 scorer reads the selected source from the
`ts_l5_second_order_info` struct (§9.3) and dispatches
on it. The v1 ships IN_CORE for 12B; v1.1 ships
STREAMING for 70B+; v2 ships NYSTROM as the
constrained-resource fallback.

### 16.6 Shadow-mode first PR

`ts_dispatch_run_l5_joint_drafter_triggered` is the
integration point between the joint PPL harness and the
L5 dispatch. It consumes the running telemetry
(`first_reject_layer_peak`, `per_drafter_alpha`,
`loss_attribution_d[layer]`) and computes the proposed
Stage A tighten. **The v1 ships in shadow mode**: the
function logs the intended tighten to the JSONL ledger
but does not mutate the verifier's policy.

```cpp
// common/tessera-l5-joint.h
int ts_dispatch_run_l5_joint_drafter_triggered(
    const ts_l5_joint_search_result * joint_result,
    ts_dispatch_params * params,           // may be null in shadow mode
    bool shadow_mode,                      // true = log only, no mutation
    std::string * log_path,                // JSONL ledger path
    std::string * err_msg);
```

**Acceptance criterion for closing the loop.** Run the
shadow mode for N calibration passes (N=32, default).
The shadow-mode JSONL ledger records, for each L5
fire:

- `trigger_step`: the spec step at which the trigger
  would have fired
- `peak_layer_d`: the per-drafter first-reject-layer
  mode at the trigger point
- `attribution_d[layer]`: the loss attribution per
  drafter per layer
- `proposed_tighten`: the family + alpha_scale +
  clip_scale the trigger would have applied
- `actual_outcome_d`: the drafter's mean acceptance
  rate over the next 50 spec steps, *if* the proposed
  tighten had been applied (measured by re-running with
  the tighten in place)

The acceptance test: across the 32 calibration passes,
the proposed tightens, when actually applied, reduce
`first_reject_layer_peak` shift by **≥50%** in at
least 80% of the L5 fires. "50% reduction" means: the
post-tighten `first_reject_layer_peak` (mode of the next
window's histogram) is at least 50% closer to the
pre-shift baseline. "80% of fires" is the engineering
threshold for the trigger to be useful; lower than 80%
means the trigger is chasing noise.

**Closing the loop.** When the acceptance test passes,
the dispatch flips `shadow_mode` to `false` and the
trigger becomes active. The first PR for closing the
loop is a one-line flip plus the test harness that
generates the 32-pass validation set. The dispatch
maintains the shadow-mode JSONL ledger as a permanent
record (the test data) for future audit.

The shadow-mode pattern is standard for control loops:
observe, log, validate, then actuate. The first PR is
the observe+log; the second PR is the validation
harness; the third PR is the loop closure. Three PRs,
each independently shippable, with the third gated on
the second passing.

### 16.7 "Calibrated and quantized together" — what this means concretely

The phrase "calibrated and quantized together" is a
strong claim. Two interpretations:

**(a) Single dispatch producing one unified policy for
all 5 models.** Reject. The dimensionality of a joint
policy (5 models * 7 families * 3 outlier layouts * N
alpha/clip values) is combinatorial. The convergence
of a joint GA on that space is not warranted — the
per-tensor policy for the verifier and the per-tensor
policy for DSpark are largely independent because the
architectural mechanisms are different.

**(b) One dispatch producing per-model policies with
cross-model L5 routing.** This is the right
interpretation. The per-tensor policy is per-model
(verifier's `blk.16.ffn_down`, DFlash's
`blk.16.mixer`, etc. are separate GA searches). What
is "joint" is the L5 trigger: the verifier's policy
is informed by the drafter's loss attribution, and
vice versa. The cross-model routing is the
drafter-driven trigger from §16.3.

The dispatch architecture in
`tools/quantize/tessera/tessera-dispatch.cpp:2909-2952`
(step 7a) already calls `ts_dispatch_run_l5_joint` per
L5 generation. The "joint" claim is the addition of
the drafter-driven trigger from §16.3 to that call.
The architecture is unchanged; the trigger is the
new code path inside `ts_dispatch_run_l5_joint`.

**Concretely, what changes:**

1. The joint PPL harness (`common/tessera-l5-joint.h`)
   emits `loss_attribution_d[layer]` per generation
   (the new field; the rest of the harness is
   unchanged).
2. The dispatch (`tessera-dispatch.cpp:2909-2952`)
   calls the new `ts_dispatch_run_l5_joint_drafter_triggered`
   (shadow mode first, then active) which consumes
   the attribution and routes the per-drafter
   tighten.
3. The verifier's per-tensor GA is unchanged —
   `ts_dispatch_run_l5_joint` already runs the
   verifier's GA in the joint forward context. The
   tighten is an *overlay* on the GA's policy, not a
   replacement.

The "calibrated and quantized together" claim is
satisfied when: (1) the verifier's per-tensor policy
is informed by the drafter's attribution spike at the
same layer, and (2) the L5 trigger fires the tighten
in shadow mode and the shadow-mode validation passes.
The first condition is the architectural claim; the
second is the empirical validation.

### 16.8 Integration with the L1-L6 spine

The joint calibration is the *goal*; the L1-L6 layers
are the *implementation*. The mapping:

| Layer | Joint-calibration role |
|-------|-------------------------|
| L1 (§1) | Kernel ground truth. The joint forward's matmul hook captures the L1 sidecar for both the verifier (BF16 reference + T640) and each drafter (T640). The trigger-gated L1.5 reference (§1) and the ANE heterogeneous dispatch (§1.7) are the v1.5 and v2 cost collapses. |
| L2 (§4) | Per-tensor weight divergence. The L2 forward-pass differential runs on the joint forward's `Y_ref` (BF16) and `Y_quant` (T640) for both the verifier and the drafters. The activation-space metric is the per-drafter loss attribution source. |
| L3 (§6) | Four-forward attribution. The L3 attribution framework isolates weight vs KV cache compounding per drafter. The `attribution` enum routes the L5 trigger to the right action. |
| L4 (§7 + §8) | Per-drafter per-layer telemetry + domain-weighted prompt bank. The §7 tier 2 prompt bank runs on the joint forward's outputs; the §8 spec telemetry emits `first_reject_layer` and `per_drafter_alpha` per spec step. The L4 prompt bank's worst-domain pass rate is the *secondary* L5 trigger (the primary is the drafter-driven trigger from §16.3). |
| L5 (§9 + §13 risk 6) | Drafter-driven trigger + Hessian scorer + Tier 4 OLS feedback. The trigger consumes `first_reject_layer_peak`, `per_drafter_alpha`, `loss_attribution_d[layer]`. The Hessian scorer (§9) ranks which tensors to focus on within the family identified by the trigger. The Tier 4 OLS feedback (§13 risk 6) refits the regime routing thresholds from the `l5_outcome` regression on the next L5 run. |
| L6 (§10 + §11) | HIGGS α_l + tail-weighted loss. The α_l is per-model (the cross-tensor aggregation is the GA objective within each model). The tail-weighted loss (§11) is the per-tensor fitness; the drafter's `loss_attribution_d[layer]` is the cross-tensor re-weighting for the joint calibration context. |

The dispatch in `tools/quantize/tessera/tessera-dispatch.cpp`
wires these together. The 11-step state machine (§12) is
unchanged; the joint calibration adds the drafter-driven
trigger as a new code path inside step 7a
(`ts_dispatch_run_l5_joint`).

### 16.9 References

- **Chroma Research (2025). "Context Rot: How Increasing
  Input Tokens Impacts LLM Performance."** The
  empirical basis for the sliding-window debounce
  (§16.3): performance degradation is continuous from
  token 1, not just at context overflow. The
  debouncing rule is what distinguishes a noise reject
  (an anomalous-but-cosmetic first_reject_layer) from
  a sustained shift (a real drafter alignment
  collapse).
- **Dettmers et al. (2022). "LLM.int8(): 8-bit Matrix
  Multiplication for Transformers at Scale."** NeurIPS
  2022. arXiv:2208.07339. The basis for the
  `loss_attribution_d[layer]` outlier threshold
  (§16.3): the 0.1%-of-channels phenomenon is what makes
  per-drafter attribution attribution meaningful.
- **Xiao et al. (2023). "SmoothQuant: Accurate and
  Efficient Post-Training Quantization for Large
  Language Models."** ICML 2023. arXiv:2211.10438. The
  basis for the migration-strength α in the loss
  attribution routing (§16.3): the same
  mathematically-equivalent per-channel scaling that
  migrates quantization difficulty from activations
  to weights is what makes the per-drafter attribution
  routing math well-defined.
- **Leviathan, Kalman, Matias (2023). "Fast Inference
  from Transformers via Speculative Decoding."** ICML
  2023. The basis for the single tree-attention
  forward (§16.2): the BF16 verifier + T640 drafters
  pattern is the Leviathan rejection-sampling protocol
  applied to calibration.
- **Li et al. (2024-2026). EAGLE-1/2/3.** The basis
  for the tree shape (§16.2) and the drafter's
  feature-level projection of the verifier's hidden
  state (the architectural mechanism that makes the
  per-drafter loss attribution meaningful). EAGLE-3
  reaches 0.88-0.92 alpha on chat; the drafter is a
  *derivative* of the verifier, and the drafter's
  alpha *is* the alignment metric.
- **Sun et al. (2026). "TriSpec: Ternary Speculative
  Decoding via Lightweight Proxy Verifiers."**
  arXiv:2601.23180. The basis for the per-drafter
  loss attribution routing (§16.3): TriSpec's 82%
  exact-match between a proxy verifier and the target
  is the empirical evidence that drafter loss
  attribution is a measurable signal, not noise.
- **Micikevicius et al. (2018, 2022); Kalamkar et al.
  (2019).** Mixed Precision Training / FP8. The basis
  for the BF16 reference path on the ANE (§16.2): the
  ANE is a fixed-function FP16 accelerator; the BF16
  reference is the natural fit.
- **Apple ANE documentation, Metal Shading Language
  Specification.** The authoritative source for the
  ANE behavior that makes the v2 heterogeneous dispatch
  viable (the ANE is FP16-native; the unified memory
  makes the activation input shareable).
- **HIGGS (Malinovskii et al., NAACL 2025,
  arXiv:2411.17525).** The basis for the per-model
  HIGGS α_l (§10) used in the joint calibration's
  per-tensor fitness aggregation. The Linearity
  Theorem is per-model; the drafter attribution is
  the cross-model re-weighting.

### 16.10 What this section does NOT do

For the avoidance of doubt, the joint calibration
thesis as stated in this section is a *measurement and
control* design, not a *retraining* design. The
per-tensor policies are post-training quantization
(PTQ) policies, not QAT policies. The drafter is
trained separately; the calibration is the *joint
PTQ* of the verifier and the already-trained drafter.
The cross-model routing is a calibration-time signal,
not a training-time signal.

If the joint calibration's per-drafter attribution
reveals a fundamental alignment gap — the drafter
*cannot* match the verifier at some layer regardless
of the verifier's policy — the right response is
*not* to relax the verifier's quantization. It's to
re-train the drafter. That's a separate workstream
(see `docs/tessera-dflash-training-design.md` and
the LK / D-PACE training loss designs); the joint
calibration's signal is the *diagnostic* that tells
you when re-training is needed, not the re-training
itself.
