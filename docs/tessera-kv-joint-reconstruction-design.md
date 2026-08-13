# Joint Weight x KV-Cache Reconstruction: Audit and Design

_Audit date 2026-08-13, against the fork at `bb1f7593f`. Requirement
stated by the architect the same day: ternary weights AND a quantized
KV cache with reconstruction data, and the two are RECONSTRUCTED
JOINTLY -- one reconstruction system, fitted together, assessed as a
composition._

## 0. The principle everything below follows from

**The runtime never does math on codes. It does math on
reconstructions.** T640 kernels reconstruct `W_hat` from
trits + outliers + scales and the matmul runs on `W_hat`; that is the
whole point of the L1 kernel-dequant sidecar (ground truth is what the
kernel reconstructs, not what an offline simulation says). A quantized
KV cache extends the same identity to activations: the cache stores
codes plus reconstruction data, the attention kernel reconstructs
`K_hat`/`V_hat` at read time, and attention runs on the
reconstructions.

Two consequences:

1. **Certify the composition, not the components.** Today L4 certifies
   `W_hat` under an f16 cache -- a runtime nobody deploys. A weight
   quantization that passes at f16 KV and fails at the deployed cache
   type is a false accept. (This is the same failure class the
   streaming subsystem just demonstrated: every component audit green,
   the composed system wrong.)
2. **Fit the reconstructions jointly.** The errors of `W_hat` and
   `K_hat`/`V_hat` meet inside the same dot products. Reconstruction
   parameters can and should migrate across the weight/cache boundary
   to wherever they are cheapest (section 3), which is only possible
   if one calibration sees both.

The split of labor is offline/online:

- **Offline (calibration)**: fit the reconstruction STRUCTURE jointly
  -- weight trits/outliers/scales AND the cache codec's structure
  (which per-channel scales exist, where they live after migration,
  pair-tying, per-layer outlier budgets, per-layer precision tiers).
- **Online (inference)**: weights reconstruct from static data; the
  cache write path quantizes each token's K/V into the calibrated
  structure; kernels reconstruct both at read. Math always on
  reconstructions.

## 1. Audit: what exists, what is missing

| Seam | State | Where |
|---|---|---|
| Context-level cache types | Exist, global per context, EXPERIMENTAL | `llama_context_params.type_k/type_v` (include/llama.h:384) |
| CLI plumbing | Exists incl. the DRAFT cache (`-ctk/-ctv/-ctkd`) -- spec-decoding deployment means the drafters' caches are part of the composition too | common/arg.cpp:445 (`kv_cache_type_from_str`), :2721, :2734, :5564 |
| L4 behavioral probe | **Zero KV awareness.** Drives `llama-perplexity --kl-divergence`; both legs run f16 cache | tools/tessera/e2e_probe.py |
| L5 joint-PPL harness | `llama_context_default_params()` -- optimizes weight decisions under an f16 cache the deployment will not use | common/tessera-ppl-harness.cpp:383 |
| SWA/global split | Two sub-caches but ONE shared `type_k/type_v` -- the natural seam for two-tier KV precision on gemma-class models | src/llama-kv-cache-iswa.cpp:30 |
| Quantized-V constraint | Quantized V requires the flash-attention (non-transposed) path | `v_trans`, src/llama-kv-cache.cpp:69,156,1482 |
| Activation capture | Input-side only (`in_sum2` etc. on matmul INPUTS). The cached quantities -- attn_k/attn_v OUTPUTS, K post-RoPE -- have **no capture point anywhere** | tools/imatrix/imatrix.cpp:526,1445 |
| Artifact | `.tsq` already carries weight reconstruction data (trits, outlier CSR, awq scales, global_amp); KV reconstruction data has a natural home there and is geometry-free (tile-neutrality preserved) | docs/tile-neutral-export-design.md |
| DB | `eval_cache.params_digest` absorbs (ctk, ctv, codec id) with zero schema change; activation stats want a `kv_stats` sibling of `tensor_stats` | docs/tessera-eval-cache-design.md |

## 2. Terminology correction (applies to older docs)

Where existing documents say "math on the quantized weights" or
"quantized KV", read "math on the reconstruction of". The codes are a
storage format; every FLOP downstream of them is on reconstructed
values. New text must be written reconstruction-first.

## 3. The joint-reconstruction structure (why "jointly" has teeth)

Attention, with every quantized object written as its reconstruction:

    scores = RoPE(x W_q_hat) . K_hat^T        out = A V_hat W_o_hat

**K leg.** Give K a static per-channel reconstruction scale `D`
(diagonal over head-dim channels): `K_hat = K_int . D`. Then
`Q . (K_int D)^T = (Q D) . K_int^T`, and `D` folds into `W_q`'s
reconstruction: `W_q' = W_q D`. Legal under RoPE only if the scales
are TIED WITHIN EACH ROTATED CHANNEL PAIR (`d_2i = d_2i+1`) -- equal
scaling of a pair commutes with its rotation. The alternative is
caching pre-RoPE K and rotating after reconstruction (fork surgery in
the attention path; llama.cpp caches post-RoPE). The pair-tying
constraint is the cheaper first answer; record which one measurement
prefers.

**V leg.** `V_hat = V_int . E` per channel; `A V_int E W_o` folds `E`
into `W_o`'s rows. No RoPE on V -- the fold is clean. The existing
sensitive-tensor policy already keeps attn_output high-precision, so
`W_o` absorbs V's per-channel reconstruction at zero cost.

**What migrates, what stays.** Migration is legal precisely because
the migrated component is CALIBRATION-STATIC: per-channel scales fitted
offline from calibration statistics can live inside static weight
reconstruction data. The cache keeps only what is dynamic -- the codes
themselves, per-token/per-block amplitudes, and outlier side-channels.
A runtime-dynamic per-channel scale could not be folded; this is
another reason the fit must be joint and offline.

**Joint fitting.** The AWQ-style scale search that already opens
`ts_quantize_2d` (step 1, tools/quantize/tessera/tessera-quant.cpp)
extends to the migrated KV scales: the search objective becomes the
composed reconstruction error of the attention block, and L5's
evaluator scores candidates under the composed runtime, so weight
decisions compensate cache error and vice versa. One reconstruction
budget, allocated across weights and cache where it buys the most.

**Code family.** The target is a Tessera-native KV codec in the T640
idiom -- ternary codes + outlier side-channel + scales, reconstructed
in-kernel -- so weights and cache carry the same kind of
reconstruction data. Bring-up uses the ggml cache types that exist
today (q8_0, then q4_0) because they validate every harness seam with
zero kernel work; they are scaffolding, not the destination.

## 4. Design: four additions

**A. L4 joint gate** (flag plumbing on an existing seam).
`e2e_probe.py` and `calibrate_quantize.py` grow `--ctk/--ctv` (and the
draft-cache variants). The REFERENCE leg stays f16 weights + f16 cache
-- the model as intended. The CANDIDATE leg runs the deployed
composition (`W_hat` + cache codec). PPL ratio / KLD / top-p agreement
semantics unchanged; they now measure the composition. Add an
attribution mode (`W_hat`+f16 vs `W_hat`+codec) to tell which knob to
turn when the joint gate fails.

**B. L5 under the composed runtime.** `cparams.type_k/type_v` in
`ts_l5_joint_models_load` so adaptive requant optimizes against the
cache the deployment uses. Later, the joint objective includes the
migrated-scale fitting from section 3.

**C. KV capture + sensitivity substrate** (the L1/L2 analogue for the
cache). Capture per-layer post-RoPE K and V outputs on the calibration
slice as SUFFICIENT STATISTICS, not raw dumps: per-channel sum2/maxabs
plus a pair-tied quantile sketch (the observer-bundle pattern), landed
in a `kv_stats` table on the DB spine keyed
`(model_hash, model_role, layer, kv_kind, calib_digest, stats_version)`.
Per-layer, per-codec divergence computed with the RUNTIME's own
quantize/reconstruct (kernel-reconstruction ground truth -- L1's rule).
This drives: the global codec choice, the ISWA two-tier split (global
attention layers do long-range retrieval and keep higher K precision;
SWA layers see a bounded window and drop lower), and eventual
per-layer codecs.

**D. Artifact + runtime contract.** `.tsq` carries the KV
reconstruction data -- migrated scales inside the `W_q`/`W_o` fields,
cache-side codec config, per-layer tiers -- plus the VALIDATED KV
ENVELOPE ("certified at these cache codecs; the L4 gate fails below").
The runtime warns when configured outside the envelope. All of it
geometry-free, so tile-neutrality is preserved.

## 5. Why this stacks orthogonally

- Same DB spine; joint-gate results are ordinary `eval_cache` rows
  (codec in `params_digest`); `kv_stats` is a sibling of
  `tensor_stats` with the same first-write-wins discipline.
- A alone closes the false accept. B alone makes L5 honest. C alone is
  a measurement substrate. D is a contract. Any subset ships.
- Streaming is complementary: paced runs are what make 12B composed
  probes runnable on-device. Gated on the open streaming-correctness
  finding, same as `alpha_l_probe`.
- The calibrator and quantizer still never include each other; both
  read the DB module.

## 6. Order of work

1. **A** -- hours of flag plumbing; first because it converts every
   subsequent run into a composed measurement.
2. **B** cparams -- small; makes the L5 default honest.
3. **Baseline composed matrix** on gemma-4 12B: T640 x {f16, q8_0,
   q4_0}^2 (trunk + draft caches), recorded through `eval_cache`.
   Requires the streaming-correctness fix for on-device runs.
4. **C** capture + sensitivity; validates or rejects the pair-tying
   constraint with data; produces the ISWA tier recommendation.
5. **Scale migration** into `W_q`/`W_o` reconstruction + the joint L5
   objective. Lands inside the quantizer seam split (tile-neutral
   Phase 1), which is pending.
6. **Tessera-native ternary KV codec** -- kernel work; shaped by 4's
   data and the architect's code-family sign-off.

Scheduling: per the 2026-08-13 call ("delay the refactor... add the
additions to the mix"), this document and the backlog entries ARE the
addition; implementation waits for the architect's go. Items 5-6 are
the joint-reconstruction heart and should not start before the seam
split exists.
