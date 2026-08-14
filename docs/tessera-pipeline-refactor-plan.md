# Calibration + Quantization Pipeline Refactor

_Greenlit 2026-08-13 (architect), un-deferring the additions tracked in
technical report 12.3b/3c/3e and PROJECT-STATUS 2b/2c/2e. Scope set by
the architect: the refactor carries real SEPTQ panel scoring,
first-class eval caching, and the KV-joint plumbing as parts of one
consolidation -- not three bolt-ons._

## 0. The unifying move: one evaluation seam

Everything this refactor must deliver lands on a single architectural
seam. Today the pipeline evaluates tensors through five unrelated code
paths -- `ts_dispatch_forced_t2` (profile proxies),
`ts_dispatch_tier2_t2` (real rotation/low-rank), the GA's `eval`
callback, `ts_dispatch_kernel_direct_t2` (sidecars), and the L5
scorers -- with no shared keying, no shared caching, and no shared
contract for what an "expert" produces. Every measured pathology of the
last two days traces to that scatter: the proxy panel that could not
disagree, the 79.8% duplicate evaluations, the l4_cols buffer/schema
drift, the SEPTQ slot that cannot be scored.

The seam:

    ts_expert_eval(expert, tensor_ctx, genes, eval_opts) -> ts_eval_result
      // tensor_ctx: weights + dims + act stats + imatrix slice + digests
      // genes:      grid-quantized candidate parameters
      // eval_opts:  scoring tier (proxy | real | kernel-direct),
      //             KV/cache codec context (phase 3), budget hints
      // result:     t2 + aux (mse, max_abs, per-expert extras)
      //             + optional reconstruction handle

Every expert -- AWQ core, DartQuant, LRQ/FLRQ, CHAMP-Q, SEPTQ, and the
routed composite -- implements the same contract. The three mandated
systems become properties of the seam:

- **SEPTQ real scoring** = SEPTQ implementing `tier = real`: dequant of
  its packed T640-convention output scored against the source. The
  dequant is written once, at the seam, and every packed-format expert
  gets scoring for free.
- **Eval-cache** = the seam's memoization layer: every call keyed on
  the design's spine `(model_hash, model_role, tensor, evaluator,
  params_digest, input_digest, eval_version)` with hessian-pattern
  semantics (read-before-compute, first-write-wins, JSONL ledger).
  Callers cannot bypass it because the seam is the only door.
- **KV-joint** = a new dimension of `eval_opts`/digests: the cache
  codec enters `params_digest`, so composed-runtime evaluations are
  first-class cacheable citizens, and the L4/L5 harnesses gain
  `-ctk/-ctv` as ordinary plumbing.

## 1. Phases, each independently shippable, each gated

**Phase 0 -- baseline.** Rebuild in the consolidated repo; test suite
green (built tests + the orphan `test_all.sh` set); record the Orpheus
run-3 artifact hash as the equivalence reference.

**Phase 1 -- the seam + SEPTQ real scoring.** Extract `ts_expert_eval`
(new module `tessera-expert-eval.{h,cpp}`); route the G6 panel,
`forced_t2`, and the Tier-2 paths through it; implement the packed-
output dequant scoring and turn SEPTQ real. CHAMP-Q joins the panel
(permute -> quantize -> score; permutation-invariant norm).
GATE: dispatch/regime/l2l5 tests green; an Orpheus acceptance pass
shows five real methods and the verdict drops "(proxy)".

**Phase 2 -- first-class eval-cache.** `eval_cache` table + read/write
helpers in the DB module (hessian pattern verbatim, from
docs/tessera-eval-cache-design.md Layer B); the seam consults it for
`tier >= real` and pure-proxy calls; `tensor_stats` completed (frob2,
|W| quantile sketch, stats_version) with its first readers: the
forced_t2 frob2 dot, outlier-threshold selection, GA screening
(Layer A). Buffer column lists are GENERATED from the schema strings
(one owner) so the l4_cols drift class dies structurally.
GATE: identical Orpheus re-dispatch hits >95% on the acceptance stage
and the ledger shows hit/miss/compute/store; a changed eval_version
refuses stale rows.

**Phase 3 -- KV-joint plumbing.** `-ctk/-ctv` (and draft-cache
variants) through `e2e_probe.py`, `calibrate_quantize.py`, and
`ts_l5_joint_models_load` cparams; codec digests in `params_digest`;
`kv_stats` sibling table + the post-RoPE K / V output capture point
(sufficient statistics, observer-bundle pattern) from
docs/tessera-kv-joint-reconstruction-design.md. Scale migration and
pair-tying stay OUT of this phase -- the design gates them on
measured data from the capture.
GATE: an L4 run under q8_0/q8_0 produces distinct eval_cache rows from
the f16 run; kv_stats populates on a capture run.

**Phase 4 -- dispatch decomposition.** `tessera-dispatch.cpp` (4,292
lines) splits along the now-real seams: ga-prep walk, dispatch walk,
L5 refine loop, acceptance stage, DB wiring -- each a module with its
existing tests attached. `quantize.cpp`'s argument handling unifies
(fixing the dry-run trailing/leading parse split as a side effect,
closing that open finding).
GATE: full suite green AND artifact equivalence -- same seed, same
inputs, byte-identical Orpheus T640 GGUF against the Phase 0 reference.

**Phase 5 -- measurement-gated extensions (explicitly out of this
pass).** KV scale migration into W_q/W_o, pair-tying validation,
alpha_l probes, the tile-neutral seam split. Each starts only when the
phase-3 capture data says what to build.

## 2. Invariants

- The DB spine `(model_hash, model_role, name)` is untouchable; every
  new table is a sibling, never a second source of truth.
- Every phase ends with a milestone commit, green tests, and its gate
  run recorded in the DuckDB (recording is default-on -- the refactor
  eats its own telemetry).
- Artifact equivalence is the refactor's falsifier: a refactor that
  changes the produced GGUF at identical inputs is a bug until proven
  a fix.
- The calibrator and quantizer still never include each other; both
  reach shared behavior through the seam and the DB module.
- No phase blocks on another model or hardware: everything gates on
  Orpheus-class runs that complete in minutes on this machine.
