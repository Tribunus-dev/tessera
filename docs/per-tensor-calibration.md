# Per-Tensor Evolutionary Calibration

> **Status (2026-08-12).** This document describes the original Python
> prototype. The search has since moved to the C++ dispatch GA
> (`tools/quantize/tessera/tessera-awq.{h,cpp}`, driven by
> `tessera-dispatch.cpp`); the six-knob mutation space and its ranges
> survived the port intact, but the Python surface described under
> "Fitness modes" and "Lossless target" below no longer exists. See
> those sections for what replaced it, and
> `docs/runtime-aware-pipeline.md` for the L1-L6 pipeline this feeds.

The user (sole architect) observed on 2026-07-29 that the drafter
0.86% accept rate on tessera Q4_K_M wasn't a drafter problem — the
requantization algorithm itself wasn't calibrated for the bulk of the
network. The layer-level error analysis showed 70-150% relative
divergence at the middle layers (4, 8, 16, 32) between F16 and the
existing tessera output, while the sensitive tensors (QK-norm,
post-norm, attn_output, ffn_down) were fine.

## The missing knob

The legacy tessera code uses a single hard-coded threshold:

```python
threshold = np.mean(np.abs(core_weights), axis=1, keepdims=True)
```

This is the per-row `mean(|W|)`. For most tensors it's not optimal.
For QAT models the weight distribution is bimodal (QAT trains for
specific low-precision layouts) and the optimal threshold is
tensor-dependent. The user added `ternary_threshold` as a multiplier
on the per-row mean(|W|):

```python
threshold = mean(|W_per_row|) * ternary_threshold
```

with `ternary_threshold ∈ [0.3, 3.0]`. The default of `1.0` reproduces
the legacy behavior.

## The GA

The search runs per tensor. It began in
`tools/tessera/per_tensor_calibrate.py` and now lives in the C++
dispatch GA (`ts_awq_evolve` in
`tools/quantize/tessera/tessera-awq.cpp`, invoked from step 5c of
`ts_dispatch_run`). The mutation space is unchanged by the port, and
the C++ gene struct clamps to the same ranges:

- `ternary_threshold` ∈ [0.3, 3.0] — multiplier on the ternarization
  threshold (the missing calibration knob)
- `outlier_fraction` ∈ [0.0001, 0.05] — fraction of weights stored as
  F16 residuals
- `awq_alpha` ∈ [0.0, 1.0] — per-channel pre-scaling exponent
- `awq_clip` ∈ [0.7, 1.0] — magnitude clip
- `moment_mix` ∈ [0.0, 1.0] — kurtosis contribution to importance
- `tail_guard` ∈ [0.0, 2.0] — tail-excess contribution to importance

Per-tensor GA: 8 population x 6 generations x 2 islands = ~96
candidates per tensor. With 48 tensors this runs in ~140 seconds on
a single M1 Max.

The 48 here is the **sampled bundle** count (up to 24 per family
across model depth, as exported by `make-awq-layer-bundles.py`), not
the model's quantizable tensor count -- a 12B dense model has ~320.
Costs quoted against "48 tensors" scale by ~6.7x for a full-model
pass; see `docs/runtime-aware-pipeline.md` Layer 6 section 6.3.

## Fitness

The round-trip form is unchanged:

```
W (BF16 source)  --AWQ scale-->  W'  --clip+ternarize-->  T
T  --reconstruct with outliers-->  R'  --unscale-->  R
fitness = ||W - R||^2 / ||W||^2
```

Note this is a **squared** (energy) ratio, not a relative Frobenius
norm: a reported value of `0.18` is ~42 % RMS relative error, not
18 %. The L6 `t_l^2` uses the same squared convention (it is the
Linearity-Theorem term, which is defined that way). L2's
`relative_frobenius` used to as well, but as of schema v2 it is a
norm ratio -- so to compare the two, square the L2 figure first.

The production fitness is now the L6 kernel-direct `t_l^2`, which
replaces `R` above with the L1 sidecar's record of what the kernel
actually dequantized, blended with this offline proxy via
`blend_factor`. See `docs/runtime-aware-pipeline.md` Layer 6.

The three Python fitness modes this section used to document
(`direct`, `importance`, `combined`) and the `--lossless-target`
early-stop flag were not carried across the C++ port and no longer
exist. `per_tensor_calibrate.py --fitness` today selects a
*calibration algorithm*, not an error metric: `lrq` (default), `awq`,
`flrq`, `dartquant`, `compare`.

## Output

A per-tensor JSON policy consumable by `tile640_quantize_v3.py` via
`--calibration-policy`. Schema:

```json
{
  "schema": "llama.speculative.calibration-policy.v1",
  "search_schema": "llama.tessera.per-tensor-calibration.v1",
  "tensor_families": {
    "override:blk.16.attn_q.weight": {
      "match": ["blk.16.attn_q.weight"],
      "ternary_threshold": 0.75,
      "outlier_fraction": 0.005,
      "awq_alpha": 0.32,
      "awq_clip": 0.95
    },
    ...
  },
  "per_tensor_calibration": {
    "summary": {
      "tensors_calibrated": 48,
      "lossless_met": 12,
      "median_relative_mse": 0.18
    },
    "tensors": {...}
  }
}
```

## Validation

What has actually been measured, stated precisely so it is not read
as more than it is:

| Claim | Scope | Fitness it was measured on |
|---|---|---|
| 5.4 % relative Frobenius reduction (`ternary_threshold` 1.0 -> 0.75) | **one tensor** (`blk.16.attn_q`) | offline round-trip |
| 2-5 % median improvement per tensor | 48 sampled tensors | importance-weighted |
| 12-18 % median improvement per tensor | 48 sampled tensors | offline round-trip |

Three caveats the numbers above do not carry on their own:

1. **The headline 5.4 % is N=1.** It is a single tensor in a single
   layer, not a distribution.
2. **All three figures are measured on the offline fitness** -- the
   round-trip against the BF16 source. That is precisely the
   objective the L1-L6 pipeline argues is the wrong one to optimize
   (see `docs/runtime-aware-pipeline.md`): it scores what the
   quantizer produced, not what the kernel dequantizes. An
   improvement on the offline fitness is not evidence of an
   improvement in deployed fidelity.
3. **There is no end-to-end number.** No perplexity delta, no
   drafter-acceptance recovery against the 0.86 % baseline that
   motivated this work. Every C++ test covering this path
   (`test_l2l5.cpp`, `test_l5_dispatch.cpp`, `test_l1_fitness.cpp`,
   `test_l15_capture.cpp`) runs on synthetic tensors or a two-tensor
   synthetic GGUF, which establishes that the plumbing works, not that
   the calibration helps.

The end-to-end validation path now exists and is the thing to run:
`tools/tessera/runtime_probe.py` for the L2 forward-pass differential
and `tools/tessera/e2e_probe.py` for the L4 behavioural probe. Until
one of them has been run on a real model pair, the case for this
calibration rests on the offline fitness alone.
