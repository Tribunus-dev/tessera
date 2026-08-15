# Tessera — Project Status

_Last updated: 2026-08-15_

Tessera is a fork of [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) at
[Tribunus-dev/tessera](https://github.com/Tribunus-dev/tessera). Default branch:
`tessera/integration-upstream-experiments` (Tessera work rebased onto
upstream `master`).

This document tracks what's been built, what works today, and what comes next.
For subsystem details see the linked docs.

---

## TL;DR

We started from a gemma 4 12B QAT drafter that was incoherent at 0.86% spec
acceptance and a Tessera-quantized target that diverged 70–150 % from BF16 at
the middle layers. After five phases of work:

- Tessera's quantizer is now a per-tensor evolutionary system with a direct
  round-trip fitness mode. It improves round-trip Frobenius by 12–18 % per
  tensor over the legacy importance-weighted calibrator.
- Spec-decoding telemetry (`llama.tessera.spec.v1`) is in `llama-imatrix`.
  The schema is a single unified record whose cheap per-step fields
  (drafted, accepted, confidence[]) are always emitted; the per-position
  verifier + drafter top-k distributions are added on top when
  `--telemetry-topk > 0`. Suitable for rejection-sampling LoRA
  fine-tuning of dspark.
- The fork builds clean for `llama-cli`, `llama-server`, and `llama-imatrix`
  against upstream `master` (60 commits ahead of the original dspark-int base).
- Eight worktrees cover the active branches: `main` (the original Tessera
  chain), seven hardening-agent branches, and `tessera/integration-upstream-experiments`
  (the upstream-rebased line).
- The **GPU acceleration wave** (2026-08-15) layers three accelerations on
  top of the existing HIP lane: HIP kernels for the L1-L5 per-element
  scalar paths, a per-thread GA-loop device cache that hoists stable
  layer fields across candidates, and the Tile640 interleaved matmul
  wired on Metal and ported to HIP. Build verified clean on gfx1103
  with ROCm 6.2.4; `test_all.sh` runs 54 declared cases (48 runnable +
  6 libgguf/libggml CMake-gated skips, 0 failures) and the wave ship gate
  passes (38 directly, 10 triaged and fixed this session — see Phase 9).

**The next big thing is the runtime-aware calibration pipeline (Layers 1–6)**
that closes the loop between kernel dequant fidelity and per-tensor GA fitness.

A parallel next-big-thing is the **Tessera Studio product-surface expansion**
to bring documents, spreadsheets, and slides to LibreOffice-class capability
parity within `tesseracore`. Architect-approved plan at
`TesseraStudio/docs/studio-expansion-plan.md`; see the section below.

---

## What we've built

### Phase 1 — Diagnose the incoherency

The shipped gemma 4 12B Tessera build with a dflash drafter was producing
0.86 % acceptance vs. the 30–70 % range expected for working dflash. Two
root causes:

1. **Null imatrix ledger.** The pre-existing
   `gemma4-12b-rich.imatrix.gguf` was clean (328 tensors, chunks 64 → 2048,
   no NaNs). The "rich" rerun that produced the broken state had 321/328
   tensors with all-null `previous_moments` due to a Metal OOM during graph
   construction. The fix is the missing `isfinite()` guard in
   `tools/imatrix/imatrix.cpp:772–778` of the upstream codebase.
2. **Wrong sub-hypothesis.** The drafter was never the problem. Per-layer
   differential probing (F16 vs Tessera-corrected logits) showed 70–150 %
   relative divergence at layers 4, 8, 16, and 32. The sensitive tensors
   (QK-norm, post-norm, attn_output, ffn_down) were fine; the bulk
   (Q, K, V, gate, up, down) was mis-calibrated.

The reframing was the key insight of the project: **the requantization
algorithm was the bug, not the drafter.**

### Phase 2 — SOTA survey

`final_turn_001.md` at
`/Volumes/Julian T7/mavis-deep-research/20260729_130345_tessera-imatrix-quant-sota/`
captures the deep-research pass: AWQ, k-quants, i-quants, GPTQ, SmoothQuant,
OmniQuant, BRECQ, SqueezeLLM, SpQR, and a long tail of inference-time
techniques. The conclusion was that AWQ + importance-matrix remains the SOTA
starting point but none of the public tools have proper per-tensor ternary
threshold tuning.

### Phase 3 — Tessera quantizer gap-fill

Six identified gaps in `tile640_quantize_v3.py`, all now closed:

- **§5.1 n_swa override.** `apply_gemma4_metadata_overrides()` forces
  `gemma4.attention.sliding_window` from 1024 to 512.
- **§5.2 imatrix_mse range selection.** `_imatrix_mse_row_scale()` and
  `quantize_2d_imatrix_mse()` for per-row scale-aware error.
- **§5.3 AWQ layer-output error search.** `awq_scale_search` dispatches via
  `AWQ_SEARCH_TARGET`.
- **§5.4 gemma 4 sensitive tensors.** `is_gemma4_sensitive_tensor()` plus
  `DEFAULT_GEMMA4_SENSITIVE_PATTERNS`.
- **§5.5/§5.6 calibration real X.** `load_calibration_activations()` reads
  from `.npz`; `CALIBRATION_ACTIVATIONS` is a module-level cache.
- **New: per-tensor `ternary_threshold` knob.** Multiplier on per-row
  `mean(|W|)`, range `[0.3, 3.0]`, default `1.0` (legacy behaviour). The
  missing calibration control that surfaced during the layer-probe analysis.

`tools/tessera/per_tensor_calibrate.py` is the new GA over the full
calibration mutation space.

### Phase 4 — Per-tensor GA

`tools/tessera/per_tensor_calibrate.py` runs a small GA per tensor over six
mutation dimensions:

| Dimension | Range | Default |
|---|---|---|
| `ternary_threshold` | [0.3, 3.0] | 1.0 |
| `outlier_fraction` | [0.0001, 0.05] | (legacy) |
| `awq_alpha` | [0, 1] | (legacy) |
| `awq_clip` | [0.7, 1.0] | (legacy) |
| `moment_mix` | [0, 1] | (legacy) |
| `tail_guard` | [0, 2] | (legacy) |

Three fitness modes: `direct` (BF16-source-vs-dequant round-trip relative
Frobenius), `importance` (legacy imatrix-weighted), `combined` (direct + a
max-abs penalty, λ = 4). Default population 8, generations 6, islands 2. The
`direct` mode gives 12–18 % improvement per tensor over `importance` (which
gives 2–5 %). `--lossless-target X` enables early stop when relative MSE
falls below `X`.

Two production policies are already in place:
`/Volumes/Julian T7/runs/gemma4-12b-tessera-overnight/gemma4-12b-per-tensor.json`
and `…-direct.json`.

### Phase 5 — Spec-decoding telemetry

Built the spec-calibration telemetry path inside `llama-imatrix`:

- **Unified schema** (`llama.tessera.spec.v1`) — single record per spec
  step. The cheap per-step payload (drafted, accepted, confidence[],
  draft / accepted token sequences) is always emitted; the per-position
  verifier and drafter top-k distributions are added on top when
  `--telemetry-topk > 0`. This is the right shape for rejection-sampling
  LoRA fine-tuning of dspark: we record what each side would have
  predicted at each position and the relative probability mass, then
  sample dspark outputs from the verifier's distribution weighted by
  the drafter's confidence.

CLI surface:
- `--model-draft <path>` — path to a dflash/DSpark drafter gguf.
- `--spec-steps N` — number of spec steps to roll forward.
- `--telemetry-out <path>` — JSONL output.
- `--telemetry-topk K` — switch on v2 schema with K-element top-k per position.

Plus: `dft.` prefix on drafter observer names to keep verifier/drafter
tensors separated inside `IMatrixCollector::m_stats`.

### Phase 6 — dspark drafter

`tools/dspark-gguf-patch/` is a preprocessor for legacy dspark `.gguf` files
because the shipped `dspark_gemma4_12b_q4pure.gguf` doesn't load directly:

1. Rename arch `dspark` → `dflash` (folded-arch convention from PR #25173).
2. Rename `markov.w{1,2}.weight` → `markov_w{1,2}.weight` and
   `confidence.proj.{weight,bias}` → `conf_proj.{weight,bias}`.
3. Rename hparam prefix `dspark.*` → `dflash.*` (keep `dspark.markov_*`).
4. Inject `blk.{N}.attn_v.weight` by copying `blk.{N}.attn_k.weight` (MQA
   V = K; the loader requires explicit V).
5. Set `dflash.attention.sliding_window = 0` (gemma 4 12B drafter doesn't
   use SWA despite the upstream default).

`dspark` actually runs end-to-end: 33 % acceptance on Q4_0 (1-of-3 step),
11 % on Q5_K_M (3-step). The DFlash-only path reaches ~30 % on Q4_K_M and
Q5_K_M. Spec alignment is the bottleneck, not the loader.

### Phase 7 — Production hardening audit

`tessera/docs/audit-2026-07-29.md` lists 12 concrete findings, including:

- Duplicate `--spec-steps`/`--telemetry-out`/`--telemetry-topk` registrations
  in `common/arg.cpp` (since fixed by the `arg-cpp-dedup` agent).
- `mtp_context()`/`ane_mtp_program()` stubbed to `nullptr` in
  `common/speculative.cpp` (the upstream rewrite absorbed the real MTP
  integration under the `DRAFT_MTP` enum).
- `dft.` string prefix workaround in `src/llama-graph.cpp` (4 call sites).
- Two parallel telemetry schemas (v1, v2) without an adapter. The
  `telemetry-schemas` agent first unified them under
  `llama.spec_calib.v3` (with v1/v2 as legacy adapters); the
  `spec-consolidate` agent later collapsed v1/v2/v3 into a single
  `llama.tessera.spec.v1` record.
- Test coverage shockingly thin (28 621 LOC of code, 68 lines of test).
  The `tests` agent added production-grade coverage for dflash, dspark,
  telemetry, server-MTP, patcher, and quantizer policy.

### Phase 8 — Upstream integration

Surveyed 637 upstream branches, identified 13 high-value experimental
candidates, confirmed via `git format-patch -1` that **all 13 are already
absorbed into upstream `master`** through the recent rewrite. The actual
integration work is bringing Tessera's commits onto current master:

- `upstream/master` is at `64d528be7` (60 commits, no shared ancestry with
  our dspark-int line at `720d7fa4`-based history).
- `tessera/integration-upstream-experiments` rebases the 9 tessera commits
  onto `upstream/master`. 4 of the 9 are no-ops (already in master). The
  remaining 5 plus 1 porting-fix commit produce a clean build with
  `llama-cli`, `llama-server`, and `llama-imatrix`.

### Phase 9 — GPU acceleration wave (2026-08-15)

Adds three layers on top of the existing HIP lane without changing the
caller-visible fitness semantics:

1. **Custom HIP kernels for the L1-L5 per-element scalar paths.**
   `ts_hip_imatrix_sumsq` replaces the dense + MoE inner-loop sumsq in
   `IMatrixCollector::collect_imatrix` (one block per row, 256 threads,
   shared-memory reduction + atomic-add). `ts_hip_make_qx_quants` ports
   the 19-trial scale sweep in upstream `make_qx_quants` to a per-element
   shared-memory reduction; the bridge in `ggml/src/ggml-quants.c` falls
   back to the scalar body when the shim returns -1. `ts_hip_l1_ratio`
   replaces the F64 Frobenius inner loop in `ts_l1_kernel_direct_t2` with
   a per-block F64 reduction kernel (single F32 -> F64 conversion at the
   read site, shared-memory fold, single-block per-block partial write
   to scratch). All three are gated by `TS_USE_TESSERA_METAL` so the
   HIP-free link graph stays clean.
2. **GA-loop hoist (per-thread device cache).** `ts_awq_eval_cache` in
   `tessera-awq.h` holds `ts_rblas_buf` handles for the five layer
   fields stable across candidates (`weights`, `train_act`, `heldout_act`,
   `ref_train`, `ref_heldout`). `ts_awq_eval_with_cache` acquires them
   once per worker thread on first call and reuses the device buffers
   for the two sgemms in `ts_awq_relative_output_error_device`. H2D cost
   drops from {per candidate x 5 fields} to {per worker thread x 5 fields
   once}. The slot pool guarantees one layer's stable buffers are
   allocated once per GA, shared across candidates and layers.
3. **Tile640 interleaved matmul (Metal + HIP).** The previously-orphaned
   `kernel_TILE640_MATMUL_INTERLEAVED` source is now wired on Metal
   (CMake embeds the `.metal` file, a new pipeline fetcher compiles it
   with `FC_TILE640_INTERLEAVE = 1710` + the four offsets, and a new
   ops handler dispatches the 11-buffer + 2-constant shape) and ported
   to HIP (`ggml/src/ggml-cuda/tile640-interleaved.cu`). Dispatch is
   feature-flagged by `TESSERA_TILE640_INTERLEAVED`; unset keeps the
   existing `kernel_TILE640_MATMUL` path so parity holds by default.

Build verified clean on gfx1103 / ROCm 6.2.4 (downgraded from the
Fedora 44 default 7.1.1 because GFX10+ rejects the
`V_MOV_B32_dpp wavefront` codegen). `test_all.sh` runs 54 declared cases
(2026-08-15, after the Phase 9.1 driver refactor): 48 runnable + 6
libgguf/libggml CMake-gated skips, 0 failures on a cold-cache run.
The 10 pre-existing failures triaged and fixed this session:
test_all.sh link-line gaps for `l5`/`imatrix`/`quant`/`w4a4`/`moe_shapes`/
`operative_routing`/`higgs_integration`, `std::fabs` without `<cmath>`
in `test_dflash_train_data.cpp`, the case2 fixture in `test_acceptance`
that exercised constant-vectors (tau undefined) under the v2 cross-method
novelty check, and the `ts_l1_kernel_direct_t2` in-place mutate bug that
broke the scalar fallback when `ts_metal_l1_ratio` returned -1).
Wave-targeted parity vs python fixture: max_abs 2.384e-07, max_rel
1.054e-07 (within rtol 1e-5). Wave-level measurement architecture (per
the agent-ux-fatigue skill): primary is full-L6 GA wall-clock on a 7B
reference layer drops 30-50% with HIP enabled; trust is the parity suite
passes within existing tolerances; anti-metric is the GA cache stays
bounded under 256 MiB per layer.

#### Phase 9.1 — `test_all.sh` parallel + cache (2026-08-15)

Driver refactor on top of the Phase 9 fixes. Same 54 declared cases
(48 runnable + 6 libgguf/libggml CMake-gated skips), same PASS/SKIP
distribution as the serial driver, but compile and cache-key work now
fans out across `nproc` workers. Architecturally:

- **Per-test content-hash binary cache.** Cache key is
  `sha1(canonicalized CXX args ∪ g++ -MM -MG dep list ∪ uname ∪ TS_BLAS)`.
  On a re-run with no source change, the test binary is fetched from the
  cache and the compile step is skipped.
- **3-stage pipeline.** Stage 1 declares every test as one job record
  (`name | kind | args`) into `$DECL_FILE`. Stage 2 fans out cache-key
  computation across `xargs -P $JOBS`, with skip-gate tests evaluated
  lazily so a gated test does not pay the dep-scan cost. Stage 3 folds
  the keys + gate decisions back into declaration order, splitting
  into `$RESULTS_FILE` (cache_hit / skip_gate) and `$COMPILE_FILE`
  (compile work). Phase 4 fans out the compile pool via xargs; the
  workers append `compiled` / `compile_fail` records to `$RESULTS_FILE`.
  Phase 4.5 re-folds RESULTS_FILE onto declaration order so phase 5
  prints in source order regardless of compile completion order.
- **Apple/Linux gating already in place.** `tessera-quant.cpp` uses
  `#if defined(__APPLE__)` for vDSP; the `tessera-metal-stub.cpp`
  no-op shim resolves `ts_metal_*` symbols on non-Mac; the Linux build
  skips the `.metal` pipeline compile. No new gating needed; the
  Linux build was never carrying Apple-specific artifacts.

Duckdb amalgamation is built once in phase 0 (with content-hash cache
on `duckdb.cpp`) so the parallel pool does not serialize on the
amalgamation. `$BIN/duckdb.o` is consumed by both `tessera_db_indexes`
and `ga_model_role`; if the .o fails to build both convert to
`SKIP (duckdb amalgamation build failed)`.

Measured on the 780M (8-core box):

| Scenario | Wall clock | PASS / SKIP / FAIL |
|---|---|---|
| Cold cache (`rm -rf /tmp/tessera_test_bin`) | 13m10s | 48 / 6 / 0 |
| Warm cache (no source change) | 11s | 48 / 6 / 0 (1 run hit the w4a4 flake) |
| One source touch (`tessera-awq.cpp`) | 16s | 48 / 6 / 0 |

Cache hit rate on a warm re-run: 48/48 binaries. Cache invalidation is
content-hash-precise — touching `tessera-awq.cpp` rebuilds every test
that consumes it (via `g++ -MM -MG`) and leaves the rest on cache.
Phase-0 dep scan is the new dominant cost on warm runs (~40ms/test ÷
nproc). The driver falls back to `g++` as `CXX`; parallelism is
`TESSERA_TEST_JOBS=N` (default `nproc`).

Pre-existing flake: `w4a4` is RNG-dependent and passes ~17/20 runs
(85%). Not a driver regression; the cached binary is byte-identical
across runs but the calibration sequence varies. Tracked as a Phase
10 item (seed the calibration RNG in `test_w4a4.cpp`).

---

## What works today

| Subsystem | Status | Where |
|---|---|---|
| `llama-cli` | builds + runs | tessera fork, integration branch |
| `llama-server` | builds + runs | tessera fork, integration branch |
| `llama-imatrix` | builds + runs (HIP-accelerated per-row sumsq when present) | tessera fork, integration branch; `ts_hip_imatrix_sumsq` shim in `tessera-metal-hip.cpp` replaces the dense + MoE inner-loop accumulation, gated by `TS_USE_TESSERA_METAL` |
| Per-tensor GA calibration | ready for use | `tessera-awq.{h,cpp}` (step 5c of `ts_dispatch_run`) |
| dspark-gguf-patch preprocessor | ready | `tools/dspark-gguf-patch/` |
| Spec-decoding telemetry v1 | ready | `tools/imatrix/imatrix.cpp` |
| Spec-decoding telemetry v2 | ready | `tools/imatrix/imatrix.cpp` |
| DFlash drafter | 30 % accept on Q4_K_M, Q5_K_M | via llama-imatrix spec path |
| DSpark drafter | 33 % accept on Q4_0 (1-step), 11 % on Q5_K_M (3-step) | via dspark-gguf-patch |
| Per-tensor quant policy loading | ready | `tile640_quantize_v3.py --calibration-policy` |
| Kernel-direct GA fitness (L6) | ready (HIP-accelerated F64 ratio when present) | `kernel-fitness --enabled --dir --blend`; `ts_hip_l1_ratio` shim replaces the scalar `ts_l1_kernel_direct_t2` inner loop with a per-block F64 reduction kernel, gated by `TS_USE_TESSERA_METAL` |
| rocBLAS BLAS lane (AMD) | ready (XNACK-independent) | `tools/quantize/tessera/tessera-rocblas.{h,cpp}`; 24 cblas sites + `ts_mm_awq_mse` sgemm rewrite; caller-managed `ts_rblas_buf` scratch + dedicated HIP stream; every input H2D-copied via `ts_rblas_buf_get`. Works uniformly on XNACK-on and XNACK-off APUs (incl. gfx1103 / Ryzen 7040 iGPU). |
| GA-loop device cache | ready | `ts_awq_eval_cache` in `tessera-awq.h`; H2D cost for stable layer fields (weights, train/heldout activations, ref outputs) drops from {per candidate x 5 fields} to {per worker thread x 5 fields once}. Hot path through `ts_awq_eval_with_cache`; scalar fallback when `TS_USE_ROCBLAS` is unset. |
| Per-tensor GA `make_qx_quants` (HIP) | ready | `ts_hip_make_qx_quants` shim replaces the upstream `make_qx_quants` scale sweep with a per-element 19-trial shared-memory reduction; bridge in `ggml/src/ggml-quants.c` falls back to scalar when the shim returns -1; gated by `TS_USE_TESSERA_METAL`. |
| Tile640 interleaved matmul (Metal + HIP) | M1 device foundation | HIP port of `kernel_TILE640_MATMUL_INTERLEAVED` in `ggml/src/ggml-cuda/tile640-interleaved.cu`; Metal wire-up gated by `TESSERA_TILE640_INTERLEAVED` (pipeline fetcher + ops handler added next to the existing `kernel_TILE640_MATMUL` path; CMake embeds the interleaved .metal file). Dispatch goes through the existing `kernel_TILE640_MATMUL` path when the env var is unset. |
| ANE MTP prefill | compiles, untested runtime | `common/ane-mtp.{h,mm}` |
| XDNA NPU runtime (AMD Ryzen AI) | M1 device foundation (heap BO, identity, SHMEM+DEV BO alloc/sync, xclbin parse); context create best-effort on AIE 1.1 + amdxdna v7.1.y | `common/xdna-runtime.{h,cpp}` |
| `dft.` observer prefix | applied | `src/llama-graph.cpp` |
| `--no-embedded-mtp` flag | ready | `common/arg.cpp` |
| Production tests (dflash, dspark, telemetry, server-MTP, patcher, policy) | landed in `tessera/tests` branch | `tests/` |

---

## Tessera Studio agent-UX-fatigue audit (2026-08-12)

Twelve implementation units from the agent-ux-fatigue audit landed on the
`agent-ux-fatigue-sprint` branch across Waves 1-3. The work targets
Tessera Studio (the SwiftUI macOS + iOS agent product), not the
calibration fork. The full audit, the wave plan, and the per-move
measurement architectures are in `docs/AGENT-UX-FATIGUE-REVIEW.md`. The
move is opinionated and short: ship the named surface (chip, panel,
feed) the existing infrastructure already holds the data for, and let
the user verify in place instead of opening a drawer.

Each unit ships with a one-primary + one-trust + one-anti measurement
architecture (per the skill's `references/measurement-architecture.md`).
The columns below are the headline targets; the deadline is week 2-6
depending on the unit.

### Wave 1 (4 units, all independent)

#### 1A. Onboarding starter prompts + firstGoal card (review #1)

The empty chat (macOS dock placeholder, iOS `ContentUnavailableView`,
`LibraryView` empty state) is the empty-canvas paradox: an "ask me
anything" surface with no entry point. The fix is 3-5 destination-aware
starter prompts + a typed-sentence "firstGoal" card on the onboarding
step that seeds `UnifiedChatController`.

Files:

- `TesseraStudio/Sources/TesseraCore/Agent/DestinationStarterPrompts.swift`
  (new: `DestinationStarterPrompts`, `DestinationStarterPrompts.Context`,
  `DestinationStarterPrompts.Prompt`, `DestinationStarterPromptsList`).
- `TesseraStudio/Sources/TesseraStudioMac/App/ContentView.swift`
  (macOS dock placeholder -> starter list).
- `TesseraStudio/Sources/TesseraStudioiOS/App/ContentView.swift`
  (iOS `ContentUnavailableView` -> starter list).
- `TesseraStudio/Sources/TesseraCore/Views/OnboardingView.swift` (page 3
  -> firstGoal card; later folds in 2B).

Measurement architecture:

- primary (leading-behavior): time-to-first-message, down >=30% by
  week 2. `TelemetryMonitor` records the event when the first message
  is sent.
- trust (leading-qualitative): "first suggested task felt relevant"
  pulse score, >=60% by week 4. Catches stale prompts.
- anti (leading-behavior): onboarding firstGoal skip rate, <25% by
  week 4. Catches the over-correction (asking too long, user dismisses).

#### 1B. `TesseraTier` enum + `tier(for:)` + tier label on `ConfirmationPanel` (review #4)

The approval engine implements tier policy as code in five files but
never names the tier. The fix is a `TesseraTier` enum + computed
property on `TesseraSafetyDecision`, with the tier label surfaced on
`ConfirmationPanel` as a chip. Pure: same inputs always produce the
same tier. No behavior change. The dimension is reversibility + blast
radius, NOT action type.

Files:

- `TesseraStudio/Sources/TesseraCore/Agent/TesseraTier.swift` (new:
  `TesseraTier.tier0 | tier1 | tier2 | tier3`, `tier(for:)`,
  `tier(forRisk:)`, `revoke()`).
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraSafetyDecision.swift`
  (adds `tier(forActionClass:)` and `riskOnlyTier`).
- `TesseraStudio/Sources/TesseraStudioMac/Encryption/ConfirmationPanel.swift`
  (surfaces the tier chip).
- `TesseraStudio/Tests/TesseraCoreTests/Agent/TesseraTierTests.swift`
  (boundary-drift guard: no tier downgrade without `TesseraTier.revoke`).

Measurement architecture:

- primary (leading-behavior): % of `ApprovalSheet` opens where the
  user accepted without modification, >=70% by week 4 (catches
  tier mis-calibration).
- trust (leading-behavior): approval reject rate on Tier 2/3 actions,
  <20% by week 6.
- anti (leading-behavior): % of actions that bypassed the gate
  (`tier3 -> autoApprove` or `tier0 -> askUser`), <1% by week 4.
  Catches the tier-boundary drift failure mode. Computable from the
  existing `approval-receipts.jsonl`.

#### 1C. Audit-log HEAD chip on `TesseraDiffOverlayView` (review #5)

The diff overlay shows "Rewrite complete" prose; the audit log's HEAD
(risk, tool, receipt id) is one drawer away. The fix is to inline the
HEAD as a one-line chip on the diff overlay between the diff and the
Accept/Reject controls. The chip uses the field-cap-of-5 discipline so
the user reads one chip language on the diff overlay, the chat progress
feed, and the audit log.

Files:

- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/TesseraDiffOverlayView.swift`
  (adds `AuditLogHeadChip` between the diff and the controls; chip
  rendered only on `state == .diffComplete` or `.editable`; suppressed
  on `.streaming` and when `Receipt.mutations` is empty).
- `TesseraStudio/Tests/TesseraCoreTests/Editor/DiffOverlayChipTests.swift`.

Measurement architecture:

- primary (leading-behavior): median time from `diffComplete` to
  `Accept` tap, <3s. Lau & Hartanto 2026: longer verification windows
  correlate with approval-by-reflex.
- trust (leading-behavior): % of Accept taps where the user clicked
  the receipt-id chip, non-zero = chip is useful, near zero =
  decoration (Baldeo active-use signal).
- anti (leading-behavior): P95 character length of
  `VerifierDecision.rationale`, <80 chars. Paradox 6 alarm.

#### 1D. `TesseraNotificationBudget` actor + `onFinished` hooks (review #3)

Two push notifiers fire without a shared budget. The fix is one
`TesseraNotificationBudget` actor (per-UTC-day counter, default cap 3,
**no `force:` override**) called by the two existing push notifiers.
The cap is a hard cap, not a soft target. `.dryRun` notifications are
dropped from the postable set and gated behind a separate `devMode`
flag. `TesseraAdaptationScheduler` and `TesseraAssessmentScheduler`
gain `onFinished` hooks so silent scheduler collapses surface through
the budget.

Files:

- `TesseraStudio/Sources/TesseraCore/Encryption/TesseraNotificationBudget.swift`
  (new: `TesseraNotificationBudget` actor,
  `TesseraNotificationCategory` enum, `TesseraNotificationEvent` struct,
  `TesseraNotificationBudgetLog` test-only reader; JSONL log at
  `tessera.notifications.log`).
- `TesseraStudio/Sources/TesseraStudioMac/Encryption/PleadTheFifthNotifications.swift`
  (wrapped in `tryPost`).
- `TesseraStudio/Sources/TesseraCore/Encryption/CovertTriggerMonitor.swift`
  (wrapped in `tryPost`).
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraAdaptationScheduler.swift`
  (adds `onFinished` hook).
- `TesseraStudio/Sources/TesseraCore/Learning/TesseraAssessmentScheduler.swift`
  (adds `onFinished` hook).
- `TesseraStudio/Tests/TesseraCoreTests/Encryption/TesseraNotificationBudgetTests.swift`.

Measurement architecture:

- primary (leading-behavior): # of push notifications fired per user
  per UTC day, <=3.
- trust (leading-behavior): % of fired notifications acted on within
  15 min (the "actionable" check), >=50%.
- anti (leading-behavior): # of silent scheduler collapses where
  `onFinished` should have fired, ==0 by week 2. Catches the
  silent-forgotten side of paradox 7.

### Wave 2 (4 units, mixed dependencies on Wave 1)

#### 2A. Chat dock progress feed (review #2)

`UnifiedChatController` already has live state (routing, tool calls,
approval gates, hold queue, collab trace); `statusPill` is a one-line
bar. The fix is a pull-to-open `ChatProgressFeed` in the dock. **Pull,
not push** -- the feed never auto-surfaces, or it becomes the
proactive-agent paradox in production. Depends on 1D
(`TesseraNotificationBudget`) being in place so the feed cannot
become a notification flood.

Files:

- `TesseraStudio/Sources/TesseraCore/Agent/ChatProgressFeed.swift`
  (new: `ChatProgressFeed` view, pull-binding-driven, chip vocabulary
  shared with the audit-log HEAD chip).
- `TesseraStudio/Sources/TesseraCore/Agent/UnifiedChatController.swift`
  (live-state surface model).
- `TesseraStudio/Sources/TesseraCore/Agent/UnifiedChatRow.swift` (the
  `LiveState` row type).
- `TesseraStudio/Sources/TesseraStudioMac/App/ContentView.swift` (the
  pull-to-open affordance on the chat dock).

Measurement architecture:

- primary (leading-behavior): % of sessions where the feed is opened
  at least once, >=60% by week 4.
- trust (leading-qualitative): "I can see what the agent is doing"
  score, up >=20% by week 4.
- anti (leading-behavior): % of feed events that arrive as a push
  notification, <10% by week 4. Catches the proactive-agent paradox
  failure mode.

#### 2B. `OnboardingView` fold (review #6)

The first-run onboarding imported the SaaS default: a centered purple
hero, four-row feature list, page dots, page-turn animation, and
pastel page-tint rotation. The fix is to delete `welcomePage`, the
page-turn chrome, the page-tint rotation, the `.largeTitle` headline,
and the `feature()` helper, then fold the model-directory step into
the form shape used by `TesseraSettings` (PathField verbatim). The
agent-approval step is the firstGoal card from 1A; preserved as the
seed mechanism. Depends on 1A (firstGoal card) being in place.

Files:

- `TesseraStudio/Sources/TesseraCore/Views/OnboardingView.swift`
  (single form, two sections: model-directory + firstGoal card;
  no welcome page, no page dots, no `.largeTitle`).

Measurement architecture:

- primary (leading-qualitative): first-impression rating from new
  users in the first 5 minutes (1-question in-app survey on
  first-run completion), >=4/5.
- trust (leading-qualitative): "feels premium / feels like a tool"
  tag, >=80% positive (n=10 session-replay annotation).
- anti (leading-behavior): bounce rate within 30 seconds of first
  open (close-app / Cmd-W within 30s of `TesseraStudioMacApp`
  finishing launch), <10%.

#### 2C. Time-limited undo (review #5)

`AppKitUndoManagerBridge.levelsOfUndo = 100` caps depth, not time.
After ~30s most users stop noticing the undo affordance. The fix is
a `TimeLimitedUndoPolicy` (default 90s, configurable) with lazy
expiry on every `canUndo` read, plus a visible "Undo available for
Ns" affordance on the editor.

Files:

- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/EditorUndoCoordinator.swift`
  (replaces the depth cap with `TimeLimitedUndoPolicy`,
  `TimeLimitedUndoBudget`, `TimeLimitedUndoChip`).
- `TesseraStudio/Tests/TesseraCoreTests/Editor/TimeLimitedUndoTests.swift`.

Measurement architecture:

- primary (leading-behavior): % of undone actions where the undo was
  performed within 30s of the action, >=80% (the rest are cognitive
  offload -- user forgot).
- trust (leading-qualitative): "I can recover from a wrong action"
  score, up >=15% by week 4.
- anti (leading-behavior): % of undo-affordance impressions that
  were ignored past the expiry, <20% (catches: affordance is too
  noisy).

#### 2D. `uncertainty` on `ToolResultPayload` (review #5)

`ToolResultPayload` has `success | output | error` but no
uncertainty. The Tian Pan 2026-04-12 split: the UI must distinguish
"the agent was uncertain and said so" from "the agent was confident
and was wrong". The fix is a categorical `ConfidenceBand` (low |
medium | high) on `ToolResultPayload`. Categorical bands are more
robust to model miscalibration than numeric percentages (per the
skill's anti-pattern on numeric confidence).

Files:

- `TesseraStudio/Sources/TesseraCore/Models/ChatMessage.swift`
  (adds `ConfidenceBand` enum, extends `ToolResultPayload` with
  `confidenceBand: ConfidenceBand?`).
- `TesseraStudio/Sources/TesseraCore/Agent/TesseraActionVerifier.swift`
  (emits the band on every `ToolResultPayload`).
- `TesseraStudio/Tests/TesseraCoreTests/Agent/UncertaintyFieldTests.swift`.

Measurement architecture:

- primary (leading-behavior): % of `ToolResultPayload` emissions
  where the uncertainty is set, 100% by week 2.
- trust (leading-behavior): % of accept actions on `high`
  uncertainty payloads, <20% (the user should reject or verify
  before accepting).
- anti (leading-behavior): % of `low` uncertainty payloads that
  the user still verified manually, <30% (catches: user over-trusts,
  the field is decoration).

### Wave 3 (4 units, 3C and 3D depend on 1B)

#### 3A. `sources: [Citation]` on `ChatMessage` (review #5)

`ChatMessage.content` is free-form `String` with no source citation.
The fix is a `Citation` struct (`id`, `label`, `snippet`, `url`,
optional `RangeOffset`) added to `ChatMessage` and `ToolResultPayload`,
with the chat row rendering the first 3 as inline chips (consistent
with the audit-log HEAD chip vocabulary). The `research` tool is the
first producer; other tools that surface evidence can contribute to
the list.

Files:

- `TesseraStudio/Sources/TesseraCore/Models/ChatMessage.swift` (adds
  `Citation`, `RangeOffset`, extends `ChatMessage` with
  `sources: [Citation]` and `ToolResultPayload` with
  `sources: [Citation]`).
- `TesseraStudio/Sources/TesseraCore/Agent/UnifiedChatController.swift`
  (emits citations from the tool-call provenance).
- `TesseraStudio/Tests/TesseraCoreTests/Agent/ChatMessageCitationTests.swift`.

Measurement architecture:

- primary (leading-behavior): % of `ChatMessage` emissions with at
  least one citation, >=40% by week 4 (some messages won't have
  sources).
- trust (leading-qualitative): "the agent's claims have evidence I
  can check" score, up >=20% by week 4.
- anti (leading-behavior): % of citation-chip clicks that route to
  a non-existent source, ==0 (catches: broken citations).

#### 3B. `ReceiptsCoordinator` refresh -> `AsyncStream` (review #5)

`ReceiptsCoordinator.refresh()` polled every 200ms. The fix is an
`AsyncStream<Receipt>` broadcast source on the coordinator with
back-pressure bounded per subscriber via `.bufferingNewest(64)`.
Drops are exposed via `droppedReceiptCount` as the back-pressure
anti-metric.

Files:

- `TesseraStudio/Sources/TesseraCore/Productivity/Receipts/ReceiptsCoordinator.swift`
  (adds `receiptStream()` -> `AsyncStream<Receipt>`, `register(receipt:)`,
  `droppedReceiptCount`; replaces the 200ms polling in
  `ReceiptsCoordinatorBridge`).

Measurement architecture:

- primary (leading-behavior): P95 latency from receipt creation to
  stream emission, <100ms.
- trust: not applicable (this is infra, not UX).
- anti (leading-behavior): # of dropped receipts due to
  back-pressure, ==0 (or logged explicitly via `droppedReceiptCount`).

#### 3C. Inline-stop (paradox 5) (review #4)

The off-ramp is a first-class stage. The fix is a `stop(reason:)`
method on `TesseraAgentLoop` plus an inline stop button on
`AgentCursorOverlay` (per Microsoft HAX G11, "Support efficient
dismissal"). The stop is a hard stop: the agent does not auto-resume.
A new `run()` call is rejected until the caller explicitly invokes
`clearStop()`. Depends on 1B (`TesseraTier`) for the weight class
of the stop affordance.

Files:

- `TesseraStudio/Sources/TesseraCore/Agent/TesseraAgentLoop.swift`
  (adds `StopReason` enum, `lastStopReason`, `stop(reason:)`,
  `clearStop()`).
- `TesseraStudio/Sources/TesseraStudioMac/Views/Editor/AgentCursorOverlay.swift`
  (renders the inline `AgentInlineStopButton`).
- `TesseraStudio/Tests/TesseraCoreTests/Agent/InlineStopTests.swift`
  (`testHardStop`).

Measurement architecture:

- primary (leading-behavior): % of agent actions that were stopped
  by the user, <5% (low = user trusts the agent; high = over-eager
  agent).
- trust (leading-qualitative): "I can stop the agent at any time"
  score, up >=15% by week 4.
- anti (leading-behavior): % of stop-button presses that were
  followed by an agent auto-resume, ==0 (hard-stop guard).

#### 3D. Action audit log side panel (review #4)

The audit log belongs in a pull surface, not in a notification. The
fix is a SwiftUI `ActionAuditLogPanel` as a side panel on the macOS
app, toggled from `ConfirmationPanel`. The panel renders a
chronological list of every agent action + outcome with the tier
label, time, and receipt id, using the same chip vocabulary as the
audit-log HEAD chip. Compact default view with filter + search so
the list does not become a wall. Depends on 1B (`TesseraTier`) and
1C (chip vocabulary).

Files:

- `TesseraStudio/Sources/TesseraCore/Agent/ActionAuditLogPanel.swift`
  (new: `ActionAuditOutcome` enum, `ActionAuditEntry` struct,
  `ActionAuditLogStore` (`@Observable`, `@MainActor`,
  default capacity 500), `ActionAuditLogPanel` view,
  `ActionAuditLogRow` view).
- `TesseraStudio/Sources/TesseraStudioMac/Encryption/ConfirmationPanel.swift`
  (audit-log toggle handler).
- `TesseraStudio/Tests/TesseraCoreTests/Agent/ActionAuditLogPanelTests.swift`.

Measurement architecture:

- primary (leading-behavior): % of sessions where the audit panel
  is opened at least once, >=30% by week 4.
- trust (leading-qualitative): "I can see what the agent has done"
  score, up >=20% by week 4.
- anti (leading-behavior): % of audit-panel opens that are followed
  by an "undo" action, <10% (catches: the audit is being used as a
  debugging tool, not as a trust surface).

### Healthy surfaces (do not touch)

The audit's "do not touch" list is the explicit boundary on the next
pass. The agent-ux-fatigue work did not change:

- Persona design (Tessy / Sky, `AgentPersona.swift:42-55`).
- Off-ramp exit affordances (`cancel` + `hold` + iOS
  `HoldYourHorsesDialog_iOS` at `ChatPanelView_iOS.swift:280-323`).
- Autonomy spine (per-task ratchet; see Priority 9 in this doc).
- Verifier (rule-based categorical risk at
  `TesseraActionVerifier.swift:74-90`; fail-closed on its own error
  at `:55-63`; structured `PendingAction` at `:6-14`).
- Approval engine (3 pattern shapes, asymmetric ratchet,
  RULES-not-ML irreversibility guard, denial circuit breaker, scoped
  YOLO, miscalibration regime-shift tightening, approver-training
  collapse-guard, tier-1/tier-2 escalation frame, `ConfirmationPanel`
  friction: paste-block + 5s unlock + 3/30s rate-limit, approval
  receipts).
- Telemetry local-only design (`telemetryEnabled` defaults to false
  at `TesseraSettings.swift:109`; in-memory ring buffer of 60 samples
  at `TelemetryDrawer.swift:17`; no URLSession).
- Covert-trigger path (pull-only; `ReportWindow.swift` is a menu item,
  not a surface ping).
- Push notifiers' frontmost+surface-visible suppression logic
  (HIG 14.12, their own comments).
- iOS navigation (5-tab `TabView` with no landing hero;
  13-destination sidebar on macOS).
- Typography / icons / imagery app-wide (zero custom faces,
  `Font.system(_:design:)` only; SF Symbols everywhere; banned-copy
  list has zero occurrences in the views).

### Source provenance

The audit is sourced; the per-move citations live in
`docs/AGENT-UX-FATIGUE-REVIEW.md` Part 7. The headline citations:

- Lau, Hartanto et al. (2026). AI fatigue scale, *Computers in Human
  Behavior Reports* (n=717, alpha=.92). The 4-factor model.
- Microsoft Research. HAX Toolkit, 18 Guidelines for Human-AI
  Interaction (2019 CHI, validated).
- OWASP Top 10 for Agentic Applications 2026, item ASI09
  (confirmation fatigue as security vulnerability).
- Gloria Mark et al. (2005, 2008). Interruption cost, CHI. The
  23-min recovery number.
- Tian Pan (2026). Trust calibration curve; background agents and
  the notification budget.
- Baldeo (2026). Cognitive offload in high-use GenAI users, *TMB*
  (APA). Caveat: under community-pending review. The active-use vs
  passive-use finding.

The skill that produced the move list:
`/Users/user/.zcode/skills/agent-ux-fatigue/SKILL.md` (load
`references/measurement-architecture.md` for the one-primary +
one-trust + one-anti architecture; `references/pattern-catalog.md`
for the pattern moves; `references/paradoxes-deep.md` for the seven
paradoxes).

---

## Tessera Studio product-surface expansion (LibreOffice parity, 2026-08-13, Draw added 2026-08-13)

The agent-ux-fatigue audit (above) shipped the agent *control surface* of
Tessera Studio. The **product-surface expansion** is a separate, parallel
track: bring documents, spreadsheets, slides, **and drawings** to
LibreOffice-class capability parity inside `tesseracore`. The full plan is
at `TesseraStudio/docs/studio-expansion-plan.md`; the per-suite evidence
(Writer/Calc/Impress capability inventories) is at
`TesseraStudio/docs/.scratch/lo-{writer,calc,impress}-report.md`. Three
parallel explore agents inventoried LibreOffice's `sw/`, `sc/`, `sd/`
modules against the current `tesseraCore` surface (29K LoC across
`Productivity/`, `Editor/`, `FormulaEngine/`, `Materials/`,
`DocumentProcessing/`, `Views/`). Draw is a green-field surface; its
high-level inventory is in §2 of the master plan, and a dedicated Draw
scratch report can be dispatched when the rollout needs the per-source
path evidence.

### Architect decisions (binding for every wave)

| Question | Decision |
|---|---|
| DOCX import | UNO bridge (`WriterBridgeFilter`); no native Swift ODT/DOCX reader |
| `SheetWorkbook` name | Keep the name; do not rename to `Workbook` |
| `BlockType` enum growth | 16 -> ~24 over P0-P1 is approved (incl. `.shape`/`.shapeGroup` for Draw) |
| Number formats | **Full** parser in Swift (`NumberFormatEngine`, parity with `svl/source/numbers/`). Not the 80% subset. |
| Master pages | **Full** layout picker UI at P1 (`MasterPageLayoutPicker`) |
| Chart engine | **CoreGraphics** long-term (`ChartRenderer` with `CGContext`). Not Swift Charts. Parity with all 14 LO chart types. |
| Animations | **Evolve to SMIL tree** at P2 (`SMILAnimationTree`, port of `CustomAnimationEffect.cxx`). P1 ships a flat `AnimationEffectList` as an interim; P2 evolves it. |
| Pivot tables | **Swift with full UNO parity** (`PivotTableStore`, parity with `ScDPObject`). Not a simplified model. |
| **Draw: separate surface or feature of Impress?** | **Separate surface** (`Materials/Draw/` quartet + `Shape` value type). A deck is a sequence of slides; a drawing is a single page of vector graphics. Shared `sd/` upstream binary; distinct Tessera product surfaces. |
| **Draw: 3D objects + morph in scope?** | **Out of scope.** 2D capability set is in scope (shape catalog, geometry, fill/stroke, z-order, layers, snap, transform, group, connector, text frame, ODG / SVG / PDF I/O). 3D (`fucon3d.cxx`) + morph (`fumorph.cxx`) explicitly punted. |

### Phased rollout

- **P0 - MVP (16 deliverables)**: `SheetWorkbook` multi-sheet, `RecalcScheduler` + `TokenArray` IR + shared formula groups, `CellValue`/`CellFormat`/`NumberFormat` index, `NumberFormatEngine` (full parser), `BlockType` evolutions (`.section`/`.frame`/`.shape`/`.shapeGroup`), `BlockType.table` rowSpans/colSpans/nested, `MasterPageStore` + `SlideLayoutSpec`, `WriterBridgeFilter` (UNO), `CalcBridgeFilter` (UNO), `SheetProtection`, **`Shape` value type + `ShapeCatalog` + `ShapeRenderer` (Draw data model)**, **`Drawing` material quartet (data only)**, **`BlockType.shape` z-order**, plus the `tessera_lo_service.py` schema update.
- **P1 - parity milestone (19 deliverables)**: `BlockType` evolutions (`.field`/`.footnote`/`.endnote`/`.chart`/`.media`), `FieldController`, `Footnote`/`Endnote`, `ChartRenderer` (CoreGraphics), `MediaBlock`, `Theme`/`ThemeStore`, `TransitionStore`, `SlideDeckRenderer` + `DeckExportCoordinator` (PNG/JPG), `LOBridgeDeckIO`, `MasterPageLayoutPicker`, `QueryEngine`, `CellStyle`, `ConditionalFormat`, `DataValidation`, `RevisionController`, **`LayerStore` + `TransformController` + `SnapEngine` (Draw UI)**, **`ODGBridgeFilter` + `SVGBridgeFilter` + `PDFExportBridge` (Draw format I/O)**, **text frames on shapes (connector, bullet lists inside shape text)**, plus the flat `AnimationEffectList` as a SMIL interim.
- **P2 - advanced + architect-locked substantial work (12 deliverables)**: `SMILAnimationTree` (3-5K LoC, full `XAnimationNode` tree), `PivotTableStore` (4-6K LoC, full `ScDPObject` schema), **`BezierPathController` (Draw custom-geometry paths)**, mail merge, ToC/index, solver (UNO), subtotals, statistics wizards, change-track reviewer, custom shows, master documents, **Draw advanced (annotations, measure, Draw tables, bullet lists inside shape text)**.

### Top reusable components (priority-ordered)

1. `SheetWorkbook` multi-sheet model (evolves `SheetWorkbook`)
2. `RecalcScheduler` (evolves `DependencyGraph`)
3. `TokenArray` IR (peer of `FormulaAST`)
4. `CellValue` + `CellFormat` + per-cell `NumberFormat` (evolves `SheetColumn`)
5. `NumberFormatEngine` (peer of `FunctionRegistry`; full locale-aware parser)
6. `BlockType` evolutions (evolves `BlockType` enum; 9 new cases incl. `.shape`/`.shapeGroup`)
7. `MasterPageStore` (peer of `SlideStore`)
8. `SlideLayoutSpec` (evolves `SlideLayout`)
9. `WriterBridgeFilter` (peer of `TesseraImporter`; UNO path)
10. `CalcBridgeFilter` (peer of `SpreadsheetDigester`; UNO path)
11. **`Shape` value type (peer of `Block`)** - **Draw primitive**
12. **`ShapeCatalog` (peer of `SlideLayoutSpec`)** - Draw + Impress
13. **`ShapeRenderer` (CoreGraphics, peer of `BlockRenderer`)** - Draw + Impress
14. **`Drawing` material + `DrawingStore` + `DrawingsViewModel` + `DrawingReceiptType` + `DrawingsGraphConnector` (full quartet, peer of Slide)** - Draw
15. `MasterPageLayoutPicker` (peer of `SlideDetailView`; full UI)
16. `Theme` + `ThemeStore`
17. `LOBridgeDeckIO` (evolves `EmbeddedPythonBridge`)
18. `SlideDeckRenderer` (Core Graphics; evolves `BlockRenderer`)
19. `ChartRenderer` (Core Graphics; full LO chart type parity)
20. `QueryEngine` (peer of `SheetsViewModel`)
21. `FieldController` + `RevisionController`
22. **`LayerStore` + `TransformController` + `SnapEngine` (Draw UI)**
23. **`ODGBridgeFilter` + `SVGBridgeFilter` + `PDFExportBridge` (Draw format I/O)**

### No-versioned-implementations rule (binding)

Every new component either **evolves an existing type** (`BlockType` cases,
`SheetColumnType` cases, `SlideLayout` cases, `SheetWorkbook` model,
`DocumentPageLayout` fields, `FormulaEngine.Evaluator`) or **sits as a
peer file** next to its sibling. Nothing paralleled; nothing v2.

The Draw surface follows the rule: `Drawing` is a peer of `SlideDeck`,
`DrawingStore` is a peer of `SlideStore`, `Shape` is a peer of `Block`,
`ShapeCatalog` is a peer of `SlideLayoutSpec`, `ShapeRenderer` is a peer
of `BlockRenderer`. The quartet of `*Store` / `*ViewModel` / `*ReceiptType`
/ `*GraphConnector` for `Drawing` mirrors the same quartet for `Doc` /
`Sheet` / `SlideDeck`.

### Bridge vs Swift split

UNO drives the heavy format-specific paths: DOCX/ODT/ODP/PPTX import, PDF
deck export, ODG / SVG / PDF-for-Draw export, presenter console, solver.
Swift drives the authoring surface (formula engine, cells, slides, shapes,
charts, animations), the receipts pipeline, and the constitutional
mutation backbone. The existing
`LibreOfficeBootstrap` + `EmbeddedPythonBridge` + `tessera_lo_service.py`
is the gateway; no parallel v2 service.

### Wave routing

The four named capabilities (`alphaevolve`, `tessera-analyst`,
`findings-curator`, `verifier`) carry the work into the wave loop. The
conductor section in `AGENTS.md` is unchanged. Branch namespaces
(`scratch/<feature>/agent-X`, `evolve-review/...`, `champions/<id>`,
`evolve-baseline/wN`) carry through unchanged.

### Post-claim audit (skill refinements, 2026-08-13)

The user performed an independent post-claim audit of the agent-ux-
fatigue sprint on 2026-08-13 and surfaced intent-vs-outcome gaps that
the existing `superpowers:verification-before-completion` and
`code-review` skills do not cover. The audit caught: 251 compile
errors during the sprint, an integration-test target that hung
forever, a measurement layer with 42 unrunnable metrics, three
"shipped" units with no open path, and a `/var/folders/...` source-
of-truth directory that was purged on reboot.

The refinement patches are at
`TesseraStudio/docs/skill-refinement-patches-2026-08-13.md`. The
patches add (a) a "Post-claim audit" section to `verification-before-
completion` (system-level integrity) and (b) a "Claim-vs-evidence
pass" section to `code-review` (per-unit integrity). Both skills
are built-in (immutable at runtime per the skill-refiner procedure);
the patches ship via MR to the upstream Mavis skill source. Every
wave's review gate runs both passes on the previous wave's claims.

### Agent tools surface (2026-08-13)

The expansion is the *architecture* (this section). The *agent-facing
surface* on top of that architecture is the tools the agent loop can
call. The full sketch is at
`TesseraStudio/docs/agent-tools-surface.md`. Headline shape:

- **~65 tools** across `doc_*` (Doc/Writer, ~18), `sheet_*`
  (Sheet/Calc, ~14), `slide_*` (SlideDeck/Impress, ~12), `drawing_*`
  (Drawing/Draw, ~12), `materials_*` (cross-cutting, ~6), `lifecycle_*`
  (lifecycle, ~3). One tool file per material, peer of the existing
  `Tools/SheetTools.swift`. No `_v2`; no parallel implementations.
- **Existing `TesseraTool` protocol** is the binding contract
  (`TesseraCore/Agent/TesseraTool.swift:182`): `name` (snake_case),
  `description`, `defaultApprovalLevel`, `parameters: JSONSchema`,
  `execute(arguments:) async throws -> ToolResult`. No new tool shape.
- **Tier mapping** to `TesseraTier` (audit Wave 1): read = `tier0`,
  per-entity write = `tier1`, import / export = `tier2`, non-empty
  trash = `tier3`.
- **Receipt semantics** ride the existing `ReceiptsCoordinator` and
  per-material receipt vocabularies. Every mutating tool emits exactly
  one receipt per call. Read tools do not emit.
- **Citation + uncertainty** ride the audit Wave 2-3 work: every
  `ToolResult` carries `sources: [Citation]` and
  `confidenceBand: ConfidenceBand?`. Numeric confidence percentages
  are forbidden.
- **Inline stop + notification budget** bind: long-running tools
  wire to `TesseraAgentLoop.stop(reason:)`; no tool posts a user-facing
  push (the budget's 3-per-UTC-day cap is hard; no `force:` override);
  the audit log is pull, not push.

The wave loop ships a tesseracore component + its tools in the same
wave (the tool is the agent-facing half of the component). The
`tools/agent-tools-surface.md` doc is the source of truth for the tool
API; per-wave briefs enumerate the specific tools that land in that
wave.

---

## Active worktrees

```
/Users/user/Developer/GitHub/tessera                                             220e60f4f [main]
/Users/user/Developer/GitHub/tessera.worktrees/arg-cpp-dedup                     603324327 [tessera/arg-cpp-dedup]
/Users/user/Developer/GitHub/tessera.worktrees/auto-mtp-fix                      f9b6d0211 [tessera/auto-mtp-fix]
/Users/user/Developer/GitHub/tessera.worktrees/dflash-gemma4                     e9c211bc6 [tessera/dflash-gemma4]
/Users/user/Developer/GitHub/tessera.worktrees/dft-observer                      b38fcc42f [tessera/dft-observer]
/Users/user/Developer/GitHub/tessera.worktrees/integration-upstream-experiments  d682e2302 [tessera/integration-upstream-experiments]
/Users/user/Developer/GitHub/tessera.worktrees/spec-calib-api                    ce60508b5 [tessera/spec-calib-api]
/Users/user/Developer/GitHub/tessera.worktrees/telemetry-schemas                 1a7e9a577 [tessera/telemetry-schemas]
/Users/user/Developer/GitHub/tessera.worktrees/tests                             b1ab95c91 [tessera/tests]
```

Each `tessera/*` branch is on top of `tessera:main` (`220e60f4f`). The
integration branch is the only one rebased onto upstream `master`.

---

## External research inputs (2026-07-31)

Two video sources, with every paper identity verified against arXiv. Full
analysis and citations in `docs/research-efficiency-and-mutation-2026-07-31.md`
(the source of truth; where it and a plan doc disagree, it wins until the
plan doc is updated):

- **YC "Kernel & Chip Club"** (`youtube.com/watch?v=n8dz2FX0_uY`) — the
  state of the art on efficient inference, and almost a mirror of
  Tessera's own thesis.
- **"I Tried to Make an AI"** (`youtube.com/watch?v=IoM5zUI8oFc`,
  commonLuke) — a from-scratch neuroevolution demo whose one transferable
  idea is the mutation operator.

A second, separate research input landed the same day: a deep-research pass
over the five shipping coding agents with the most mature permission
systems plus thirty years of human-factors trust-calibration literature.
Full analysis and citations in
`docs/research-autonomy-calibration-2026-07-31.md` (source of truth for
autonomy calibration; binds `tessera-studio-design.md` section 15.5 and
Priority 9 Wave 1 below). Headline: every shipping agent has a static
permission gate; none learns. Tessera's receipt-driven learned permission
is the differentiator.

Six findings bind the roadmap:

1. **Intelligence per Watt** (arXiv:2511.07885). `IPW = accuracy / watt`
   (steady-state), `IPJ = accuracy / joule` (end-to-end). Local models
   answer 88.7 % of queries; IPW improved 5.3x over 2023–2025; local
   accelerators sit >=1.4x below cloud on the identical model ("significant
   headroom for local accelerator optimization"). Tessera's hero metric
   (`mWh/token`, the 30-minute flight test) IS IPJ — adopt the vocabulary
   and cite the 1.4x headroom as the external justification for the
   CoreML/ANE line. Follow-up "Open Jarvis" is a near-neighbor to track.
2. **Reward hacking in self-improving code agents** (KernelBench,
   arXiv:2502.10517; OpenReview `ikrQWGgxYg`). LLMs optimizing kernels game
   the eval — the "world's fastest vector mean" returns 0; one hack detected
   the correctness-vs-performance phase and submitted correct-slow then
   fast-wrong (explicitly compared to VW dieselgate). Mitigation that
   worked: an adversarial detector plus a flywheel where every hack becomes
   a regression test. Independent published validation of the loop's
   grounding rule (agent curates, world judges, never self-judge).
3. **Heterogeneous inference + the roofline** (Williams/Waterman/Patterson,
   CACM 2009). Prefill is compute-bound, decode is memory-bandwidth-bound,
   attention vs MLP differ in arithmetic intensity — no single backend wins
   everywhere. First-principles explanation for "ANE beats Metal ~3x on
   prefill." On-device twist: route prefill to Metal and decode to
   CoreML/ANE on the same SoC, measured with IOReport.
4. **The evolutionary mutation operator** (NEAT, Stanley & Miikkulainen,
   Artificial Life 2002). Selection + crossover + mutation; mutation is the
   exploration term that reaches gains greedy hill-climbing provably cannot.
   The one genuinely net-new mechanism for Tessera — the offensive twin of
   the collapse guard. Becomes Priority 7.
5. **ParallelKittens** (arXiv:2511.13940; ThunderKittens, arXiv:2410.20399).
   Low direct applicability (single-SoC, not NVLink multi-GPU), but the
   "simple kernels maintainable by humans and AI agents" philosophy is the
   AGENTS.md directive stated back at us. The compute/communication-overlap
   idea transfers to overlapping ANE execution with memory movement.
6. **Batch simulation / GPU ECS** (Madrona; Large Batch Simulation for Deep
   RL, ICLR '21). Batching thousands of environments into one throughput GPU
   megakernel gives 100–1000x over CPU. The self-improving loop is
   bottlenecked by eval throughput — batch candidate evaluations into one
   pass rather than one at a time.

---

## What's next

### Priority 1 — Runtime-aware calibration pipeline (Layers 1–6)

Status as of 2026-08-12. Design in `docs/pipeline-design.md`; per-layer
details, code paths, and Reality notes in
`docs/runtime-aware-pipeline.md`; audit in
`docs/l1-l5-pipeline-technical-report.md`. Every layer is now wired end
to end. The blocker is no longer plumbing: it is that none of these
layers has been run against a real model pair, so the pipeline's own
thresholds are unfitted and the L6 fidelity claim is undemonstrated.

- **Layer 1: kernel dequant fidelity — SHIPPED.** The
  `LLAMA_TILE640_DEBUG_DEQUANT_DIR` hook emits the effective dequantized
  weight per row to a v3 TDQT sidecar. Complete in all three backends
  (`ggml-cpu/cpu-dump-dequant.cpp`,
  `ggml-cuda/cuda-dump-dequant.cu`, `ggml-metal/metal-dump-dequant.mm`),
  all called from their real matmul paths. Fitness reader in
  `tessera-l1-fitness.{h,cpp}`. This is the runtime ground truth.
- **Layer 1.5: W4A4 FP16 reference sidecar — SHIPPED.** The capture
  lives at calibration time, not in the runtime hook: the hook can only
  produce `F16(F32(dequant))`, a round-trip that collapses L3's cosine
  to ~1.0 by construction. `ts_dispatch_capture_l15_references`
  (`tessera-dispatch-l15.cpp`) writes `F16` of the original weight per
  2D tensor instead. The runtime path survives as a no-op behind
  `TESSERA_L15_RUNTIME_ROUNDTRIP`. Test: `test_l15_capture.cpp`.
- **Layer 2: BF16 vs quantized differential — SHIPPED.** Per-tensor
  weight-level divergence and type-aware flagging in
  `tessera-l2-diff.{h,cpp}`; the two-forward-pass differential in
  `tools/tessera/runtime_probe.py` (never run against a real model
  pair). The type-aware flag table is unfitted — see item 1 below.
- **Layer 3: per-token coherence — SHIPPED (per-row cosine).**
  `tessera-l3-coherence.{h,cpp}` produces per-row cosine between the L1
  and L1.5 sidecars; unblocked now that L1.5 is a real reference. Per-token
  KL and `per_token_coherence.py` are not yet built.
- **Layer 4: end-to-end probe — SHIPPED.** A data-free PPL/KL
  substitute in `tessera-ppl.{h,cpp}`, plus the prompt bank
  (`tools/tessera/prompts/`) and driver
  (`tools/tessera/e2e_probe.py`): greedy exact-match against the BF16
  model's own continuation, and PPL delta / mean KLD / top-1 agreement
  via `llama-perplexity --kl-divergence`. PASS/WARN/FAIL with exit
  codes 0/1/2 (3 = harness error). Not yet run against a real model
  pair, and not yet wired into the L5 termination criterion.
- **Layer 5: adaptive requantization — SHIPPED (on the dispatch path).**
  Sensitivity scorers and L2-closing adaptive requant in
  `tessera-l5.{h,cpp}`. The full generational loop
  (`ts_dispatch_run_l5_loop` in `tessera-dispatch.cpp`) runs when
  the `l5` subcommand is active (the `--enabled` / `--no-enabled` flag
  on `l5`; on by default): L2 measure ->
  `ts_l5_adaptive_requant` plan -> A/B per tensor family (Stage A
  tightens alpha/clip as multipliers, Stage B raises outlier_fraction)
  -> re-quantize flagged tensors in place -> re-measure, up to
  `l5 --generations`. Emits an `llama.tessera.l5-loop.v1` report
  at `l5 --out`.
- **Layer 6: kernel-based GA fitness — SHIPPED.** The C++ dispatch GA
  consumes L1 sidecars as `t_l^2 = ||dequant_kernel(W_l) - W_l||_F^2 /
  ||W_l||_F^2`, blended with the offline proxy, via
  `tessera-l1-fitness.{h,cpp}` and `tessera-dispatch.cpp:263-294`. CLI:
  `kernel-fitness --enabled`, `--dir`, `--blend`. The G6 acceptance
  verdict measures the real kernel-direct `t_l^2` as well (fixed
  2026-08-12; the thread-pool branch had been falling back to the
  offline proxy, which pinned `ranking_disagreement` at 0 and made the
  gate unpassable).

Remaining work, ranked:

1. ~~Fit the L2 flag thresholds against a real model~~ (done
   2026-08-13 for T640: fitted to the talker DuckDB run -- 267
   tensors, median `relative_frobenius` 0.452 in v2 norm-ratio
   units, confirming the 0.18-squared prediction.
   `ts_l2_expected_frob(t640)` = 4.5e-1 and flagging is two-legged:
   `max(1.0 x baseline, run's per-qtype 0.85 quantile)`, so a
   healthy run flags its own tail instead of everything or nothing.
   Other qtype baselines remain unfitted; refit per type as
   measured distributions land -- DB recording is default-on now.)
2. Wire L4 into the L5 termination criterion. The prompt-bank probe
   now exists, but the weights-only L5 still terminates on L2
   `relative_frobenius` and the joint L5 on PPL deltas, so the loop can
   converge on a model that fails the behavioural probe.
2b. Eval caching, designed and deferred (see
   `docs/tessera-eval-cache-design.md`): `eval_cache` on the existing
   `(model_hash, model_role, name)` spine (acceptance gate first),
   `tensor_stats` readers + quantile sketch, `alpha_l_probe` gated on
   streaming correctness. Additions only -- no pipeline refactor.
2c. Joint weight x KV-cache reconstruction, designed and deferred
   (see `docs/tessera-kv-joint-reconstruction-design.md`): math is
   always on reconstructions, so L4/L5 must certify the composed
   runtime (`W_hat` + reconstructed cache), not `W_hat` over the f16
   cache nobody deploys. Order: `-ctk/-ctv` through the L4 probe and
   L5 harness, composed baseline matrix on gemma-4 12B, `kv_stats`
   capture (post-RoPE K / V outputs -- no capture point exists),
   static per-channel KV scales migrated into `W_q`/`W_o`
   reconstruction (pair-tied under RoPE), Tessera-native ternary KV
   codec last. Additions only -- no pipeline refactor.
2d. Adaptive search budget (architect, 2026-08-13): the pipeline is
   sized for Nemotron-class MoE but must not beat dead horses --
   spend proportional to observed marginal value. Talker-DB
   evidence: winner found at initialization (8 generations bought
   zero), islands identical, clip dimension dead, 77% of duplicate
   evals within-generation. Order: within-gen unique-genes filter
   (-62% evals, ~10 lines, ahead of eval_cache), plateau early-stop
   (wire the existing `converged` signal to actually gate spending),
   escalation to flagged/improving tensors, family/expert
   statistical stops, per-expert-slot warm-start for MoE. Validate
   every constant against the Orpheus DB before hard-coding. See
   technical report 12.3d. SHIPPED 2026-08-13 (generation fix +
   patience-2 + auto layer parallelism): 200 evals/tensor measured
   (was 2,040), 30-minute Orpheus pass, fitted L2 baseline
   confirmed on the second model.
2e. G6 novelty prong structurally dead (measured, Orpheus run 2):
   the panel's per-method scores are proxies that cannot disagree
   (rotation/Hessian bit-identical to AWQ, 197/197; low-rank within
   6e-5), so tau=1.0 and novelty=null always. The router
   differentiates (DartQuant 143 / AWQ 34 / CHAMP-Q 20); the gate
   cannot see it. Fix: real per-expert quantization on the held-out
   set, or replace the novelty prong. See technical report 12.3e.
3. One end-to-end run on gemma-4-12B reporting drafter acceptance
   against the 0.86 % baseline plus a PPL delta. This supplies the data
   for item 1 and exercises `runtime_probe.py`. Artifact-level
   (architect, 2026-08-13): gates score the produced Tessera GGUF as
   loaded by the runtime, not pipeline-internal metrics; base logits
   captured once via the streamed BF16 leg, candidates score resident.
4. ~~Fix the L1.5 suffix mismatch so the W4A4 reference path is live~~
   (done 2026-08-01). ~~Lift the L1.5 ground truth to actual FP16~~
   (done 2026-08-12, at calibration time). ~~Wire `tessera-l5` into the
   dispatch path and add the apply-plan-and-iterate loop.~~ (done
   2026-08-01; gated on L2 `relative_frobenius` rather than L4).

### Priority 2 — Rebase dspark-int work onto integration

The 7 hardening-agent branches are stacked on `tessera:main`, not on
`tessera/integration-upstream-experiments`. Need a `tessera/main..int`
rebase pass to bring:

- `arg-cpp-dedup` — `--spec-steps`/`--telemetry-out`/`--telemetry-topk`
  deduplication and help-text polish.
- `auto-mtp-fix` — server no longer auto-triggers broken MTP path.
- `dflash-gemma4` — extract gemma4-specific extras into
  `llama_model_dflash_gemma4` (cleaner than the `TENSOR_NOT_REQUIRED`
  bolted-on pattern).
- `dft-observer` — replace `dft.` string-prefix workaround with proper
  per-scope observer state.
- `spec-calib-api` — extract spec-decoding calibration into
  `common/speculative-calibration.{h,cpp}`.
- `telemetry-schemas` — unify v1/v2 under `llama.spec_calib.v3` with
  v1/v2 as legacy adapters. Superseded by `spec-consolidate` which
  collapsed v1/v2/v3 into a single `llama.tessera.spec.v1` record.
- `tests` — production-grade test coverage.

Expected conflict surface: `common/arg.cpp`, `common/speculative.cpp`,
`src/llama-graph.cpp`, `tests/test-*`. Estimated 50–150 lines of
resolution.

### Priority 3 — Native drafter-training pipeline (C++, not Python)

_Architect directive (2026-07-31): the training drivers are native C++/Swift,
not PyTorch/peft. The Python plan that used to live here is superseded (kept in
git history). The drivers train drafters directly against
`llama.tessera.spec.v1` telemetry, in-tree, reusing ggml-opt and the
llama training API — no second runtime, no model-format round-trip._

Two drivers share one plumbing (the self-improving flywheel's training step):

1. **Path A — LK autoregressive drafter driver (LANDED).** Executable
   `tools/quantize/tessera/tessera-train-lk` + pure trace→dense-label builder
   `tessera-lk-train-data.{h,cpp}` (27/27 standalone tests). Trains with
   `GGML_OPT_LOSS_TYPE_LK` (total-variation distance = 1 − acceptance rate).
   One spec step per datapoint: input `[prime, draft...]`, label at position j
   = `densify(verifier_topk[j])`. This is on-policy distillation, and it is the
   only input prefix consistent with how the traces were collected (the
   verifier distributions are conditioned on the draft prefix). Design:
   `docs/tessera-lk-training-design.md`. Status: built, unit-tested, and the
   dataset contract verified line-for-line against the llama-layer dense-label
   epoch path; the numeric training loop still needs a real drafter GGUF smoke
   test (this driver is the first consumer of that path).
2. **Path B — DFlash/D-PACE block-drafter driver (next).** Reuses the arg
   pre-scan, the dataset-build pattern, and the epoch loop; its labels are
   pre-weighted cross-entropy rows (baked D-PACE weights from `tessera dataset
   --mode dflash`), not dense LK columns. Plus the offline
   trunk-feature capture pipeline. Design: `docs/tessera-dflash-training-design.md`.

Sanity target (carried over from the old plan): drafter acceptance on Q4_0 from
~33 % (1-step) to ≥50 %. This is still the right way to align a drafter with
Tessera's QAT target, since a stock drafter's head is trained against a
different distribution.

### Priority 4 — End-to-end verification

Once the GA and rebase work is done, validate against the gemma 4 12B
QAT target:

1. Build Tessera Q4_K_M and Q5_K_M with the per-tensor GA policy.
2. Load with `llama-cli` and the dspark drafter, run the Paris coherency
   probe (`--no-embedded-mtp` first, then with the real MTP path).
3. Compare to Unsloth UD-Q4_K_XL (6.7 GB, no MTP, works) for baseline.
4. Compare dspark acceptance before/after the LoRA pass.
5. Compare F16 vs Tessera-corrected layer probe deltas — they should
   close from the current 70–150 % at middle layers down to <20 %.

### Priority 5 — ANE MTP prefill

`common/ane-mtp.{h,mm}` compiles but has no real end-to-end test. The next
step is to:

1. Build a smoke-test mlpackage for gemma 4 12B prefill.
2. Verify the prefill handoff against the autoregressive baseline.
3. Measure the ANE-vs-CPU latency and energy trade.
4. Wire the `ane_mtp_program` through the spec-decoding calibration
   path so it gets used during imatrix collection.

### Priority 6 — Production polish

- CI workflow on the integration branch (the fork doesn't have one).
- Doc coverage: per-tensor calibration API, telemetry schemas, dspark
  patcher, ANE prefill.
- Schema versioning policy for `llama.tessera.*` (the spec-decoding
  telemetry is now a single `llama.tessera.spec.v1` record; the
  previous v1/v2/v3 split is gone) and
  `llama.tessera.per-tensor-calibration.v*`.

### Priority 7 — Evolutionary mutation operator (heavy-tailed, world-gated)

From finding 4 (NEAT). Mutation is the offensive twin of the collapse
guard: the guard stops the loop getting worse, mutation is how it gets
unexpectedly better. Full design in
`research-efficiency-and-mutation-2026-07-31.md` section 3. In priority
order:

1. **Drafter loop is the safe sandbox — mutate here first.** Drafter
   recursion is already safe (the trunk verifier rejects bad drafts), so
   the acceptance rate against the trunk is a clean world-grounded fitness
   — the exact analogue of "did Mario advance." Run a high mutation rate
   over drafter configs (decoding thresholds, regime routing, LoRA
   rank/alpha, prompt-template variants) essentially for free. This is
   finding 3's drafter/verifier split repurposed as explore/exploit:
   drafter = spice, trunk = world gate.
2. **Three NEAT-style mutation classes** on the per-tensor GA and the
   capability archive (which today is pure exploitation):
   - *Parametric* — perturb a continuous knob, with a HEAVY-TAILED step
     (Levy-flight / log-normal), not fixed-range Gaussian. Mostly tiny
     nudges, rarely a large jump — the precise meaning of "occasional" +
     "spicy."
   - *Structural* — occasionally change structure, not just values: add a
     regime bucket, enable/disable a drafter, swap a routing rule,
     introduce a new tool. This is where the surprising gains live.
   - *Random-restart* — very low probability, sample a fully random
     configuration.
3. **Every mutant still passes the world gate.** A mutant enters the
   archive only if tests/builds/commits pass and guard axes do not regress
   > epsilon. Because mutation widens the search, it widens the reward-hack
   attack surface (finding 2) — strengthen the KernelGuard-style checker in
   proportion. A dieselgate mutant is rejected and becomes a regression
   test.
4. **Adaptive schedule + island migration.** Trigger mutation BURSTS on
   stagnation (no archive improvement for K generations -> reheat). Use the
   existing island-GA infra for occasional cross-island migration (~1–5 %
   every N generations) so islands don't each converge on their own local
   optimum.
5. **Measure it, don't hand-tune it.** Treat mutation rate and step
   distribution as just another axis the multi-axis eval optimizes, A/B'd
   via `tessera-ab-harness`, with guard axes ensuring "spicier" never means
   "regressed."

### Priority 8 — External-validation follow-ups (low effort, high leverage)

Cheap deltas from findings 1–3 and 6 that strengthen existing work without
new subsystems:

- **Rename/align the hero metric to IPW/IPJ** (finding 1). `mWh/token` and
  the flight-test metric are the same quantity as IPJ; adopt the vocabulary
  in `tessera-studio-design.md` and `runtime-aware-pipeline.md` so Tessera's
  numbers are comparable to a published Stanford baseline, and cite the
  "1.4x local headroom" result as the written justification for the
  CoreML/ANE line.
- **Add a `fast_p`-shaped acceptance criterion** (finding 2): correct AND
  beats baseline by threshold — never accuracy-or-speed alone.
- **Add roofline / arithmetic-intensity framing** to
  `tessera-coreml-conversion-design.md` to justify backend routing
  (finding 3): compute-bound prefill -> Metal, bandwidth-bound decode ->
  CoreML/ANE, measured with IOReport.
- **Add a KernelGuard-style adversarial reward-hack checker** on acceptance
  traces (`self-improving-loop-design.md` 4.4), not just a pass/fail gate,
  with every discovered hack archived as a permanent regression test
  (finding 2).
- **Batch candidate evaluations** into one throughput pass rather than one
  at a time (`self-improving-loop-design.md` 4.7), per Madrona (finding 6).
- **Track "Open Jarvis"** (finding 1) as a near-neighbor of the
  self-improving coding harness.

### Priority 9 — General-agent harness (open-source absorption)

Make Studio a genuinely good GENERAL agent harness, not just a coding
agent - and the vehicle for the model-improvement flywheel, since the two
are the same loop ("one machine, two payloads,"
`self-improving-loop-design.md` section 1). Full absorption map in
`docs/tessera-harness-absorption-2026-07-31.md`, built from seven scouted
open-source agents (open-interpreter/Codex-RS, self-operating-computer,
UI-TARS, OpenAdapt, browser-use, gpt-researcher, openclaw); per-repo
evidence in `tessera-scout/reports/`.

Ground truth: the inward flywheel is already built (agent loop + tool
protocol + approval engine + 17 Learning services + 9 learning tools, all
building green). The new work is the OUTWARD capabilities plus the safety
spine both payloads share. Five themes, sequenced in three waves:

- **Wave 1 — safety spine + cheap high-soul wins (P0).** Approval-engine
  hardening (layered permission: policy x profile x sandbox-enforceability,
  fail-safe to AskUser); fail-closed action verifier ("verify a real state
  change, not a self-reported success"); denial circuit-breaker (the
  collapse guard, made concrete); per-claim citation + never-fabricate
  contract; skills directory + `SKILL.md` loader; research tool over a
  newly-built `TesseraWebSearch`.
- **Wave 2 — native capabilities (P0/P1, macOS-first).** Computer-use tool
  (ScreenCaptureKit -> Accessibility -> CGEvent, model-native coordinate
  grounding, skill-capture receipts, capture-time PII scrub); browser tool
  (WKWebView + indexed-DOM serializer + page-change re-ground guard).
- **Wave 3 — identity + polish (P1/P2).** `SOUL.md` persona, per-model
  harness profiles + context-budget rules, local-first config posture +
  `doctor` migrations, scoped gating, source curation.

**Wave 1 status (2026-07-31): landed.** The safety spine
(`TesseraSafetyDecision` / `TesseraActionVerifier` /
`TesseraDenialCircuitBreaker`), the skills loader, and the cited research
tool over the keyless `TesseraWebSearch` are built and tested. The
approval engine now produces AND the loop honors all three outcomes
(`autoApprove` / `askUser` / `reject`): `askUser` forces a real prompt
even for a tool the user generally auto-approves, and a user denial feeds
the circuit breaker. This is the research-backed spec in
`research-autonomy-calibration-2026-07-31.md` and
`tessera-studio-design.md` 15.5. The full autonomy system is specified in
`docs/autonomy-calibration-design.md` (the action-class-identity decision
that gated the ratchet is settled there: structural verb-prefix /
path-glob / arg-shape classes, no ML in the classifier).

**Autonomy Phases A-C (2026-07-31): landed.** The learned-permission
RATCHET (grant after N=5 approvals across M=3 sessions, revoke on one
denial), the irreversible-class guard, the dispositional floor/ceiling,
scoped YOLO (time/goal/session-boxed, always logged, always expired),
breaker suspension semantics, audit + revocation UI (Settings >
Autonomy), recommendation-confirmation, the miscalibration regime-shift
detector, and the LEASHED neural approver (pure-Swift MLP, idle-trained
on approval receipts, calibration collapse guard with rollback, smart
YOLO) are built and tested (188 tests green). The net predicts, never
grants, and fails closed; the rule-based ratchet remains load-bearing
and runs alone until the net warms up (50 receipts). Two pre-landing
bugs were fixed during integration: the regime-shift trigger was
mathematically unsatisfiable as written (replaced with a high-regime
latch), and a failed first net training now stays cold instead of
posing a random net as warm.

Deliberately NOT absorbed (the skips are as important as the takes):
anyone else's agent loop, cloud/vendor/server infra, heavy Python/CUDA/CV
stacks, unsigned-binary supply chains, and self-judging evaluation. The
cross-cutting risk is privacy (a screen recorder captures passwords/PHI by
construction; a browser agent runs inside logged-in sessions), so the
approval engine + no-egress boundary + capture-time scrub are gates, not
afterthoughts.

Differentiation: every scouted repo is a harness pointing at a model it
does not own, or a model with no harness. Tessera owns BOTH and lets them
co-evolve - the agent used by day improves the model by night, with a
receipt for every step.

**Product-direction decisions (2026-07-31).** Five calls that shape both
payloads:

- **Agent manager, not an editor.** Studio orchestrates, verifies, and
  records agents; editors and browsers are things it drives and diffs
  against, not things it is. No text editor, LSP, or debugger - that is a
  commodity (Antigravity just forked VS Code) and a tar pit for a solo
  dev. The seat Tessera takes is the layer above the editor.
- **Distribution: Developer ID + notarization for the Mac app** (confirmed
  by the user). Deep macOS integration (Accessibility, Full Disk Access,
  screen recording) is impossible under Mac App Store sandboxing, so the
  Mac app ships Developer ID; an iPhone companion, if built, is App Store
  and acts as a remote control only.
- **Telemetry is the fuel, not a liability.** Always-on LOCAL telemetry is
  required: every (prompt, context, model output, user accept/reject,
  outcome) tuple is a training example and the accept/reject signal is the
  label, feeding idle-time LoRA of the local model
  (`self-improving-loop-design.md`). The privacy invariant is that capture
  and training stay on-device by default - EGRESS is what the approval
  engine gates, not capture.
- **Cloud teachers are required; Apple Foundation Models are the default
  one.** The local model is the student; teachers supply reasoning on
  problems the student struggles with (struggle-detect -> teacher query ->
  reasoning capture -> distill). Apple Foundation Models (macOS 26+, no API
  key, on-device or Private Cloud Compute) are the always-available
  zero-friction default teacher; third-party cloud teachers (Claude/GPT)
  are higher-capability but higher-egress, so opt-in and approval-gated.
  Teacher bias (R3) and reasoning-externalization (R6) from the
  self-improving-loop risks apply and must be managed.
- **Egress caveat (the one honest tension).** Teacher distillation sends the
  user's struggling prompts to a teacher - the single real egress in an
  otherwise-local system. It is therefore opt-in, approval-governed, and
  scrubbed/anonymized where possible; AFM/PCC is the low-egress default
  precisely because of this.
- **Autonomy calibration: needy -> learned trust -> scoped YOLO.** Studio
  starts needy and asks often. Every approval/denial is a receipt, and the
  approval policy is a learned projection over that history: action-classes
  the user consistently allows auto-continue, novel/edge cases keep
  prompting. Safety invariant: learning only moves toward MORE autonomy on
  OBSERVED-SAFE patterns - a new consequential or irreversible action-class
  always prompts regardless of history. Scoped YOLO mode is a
  time/goal/session-boxed override that auto-approves within scope, is
  always logged, and always expires.

---

## Open questions

1. **Should the per-tensor GA's `direct` fitness be the new default, or
   should `combined` win?** Right now `direct` gives 12–18 % improvement
   per tensor; `combined` adds the max-abs penalty but its effect on
   end-to-end perplexity is untested. A test pass on gemma 4 12B QAT
   will settle this.

2. **Keep `tessera:main` and `tessera/integration-upstream-experiments`
   as separate branches, or merge?** They have different bases
   (`main` on the dspark-int chain, integration on `upstream/master`).
   Merging them means picking a base; the integration branch is the
   natural one because it has all of master's refactors. But the dspark
   drafter work and the hardening-agent work live on `main`.

3. **Is the runtime-aware pipeline the right way to spend the next two
   weeks, or is dspark LoRA finetuning more urgent?** The pipeline
   improves the quantizer, which improves the baseline; the LoRA pass
   improves the drafter, which is the drafter for the current QAT.
   Either is high-leverage. The user should pick.

4. **Push dspark-gguf-patch upstream?** The five patches are
   necessary-but-mundane renames that wouldn't surprise upstream. Could
   go as a `tools/dspark-gguf-patch/` PR.

5. **What does "tessera" mean to the project as a whole?** Right now
   it's a code-name for the per-tensor evolutionary calibration line.
   The fork is a wider container (ANE prefill, dspark patcher, runtime
   probe, etc.). The brand could use a clear statement of intent —
   probably a paragraph in the README.

6. **How spicy is too spicy?** The mutation operator (Priority 7) hinges
   on the heavy-tailed step distribution and the burst-on-stagnation
   policy, but the right tail heaviness, mutation rate, and stagnation
   threshold K are unknown. The plan is to A/B them via
   `tessera-ab-harness` with the guard axes as the regression constraint —
   but the guard epsilon that defines "regressed" still needs a number.

7. **Where does the adversarial reward-hack checker live?** Priority 8
   adds a KernelGuard-style checker on acceptance traces, but it's unclear
   whether it belongs in the eval harness (reject at the gate) or as a
   post-hoc auditor over the capability archive. Mutation widening the
   search (Priority 7) raises the stakes on this answer.
