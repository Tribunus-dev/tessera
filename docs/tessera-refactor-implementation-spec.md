# Pipeline Refactor -- Implementation Specification (handoff)

_Companion to docs/tessera-pipeline-refactor-plan.md (the architecture and
phase gates). This document is the self-contained work order: a session with
no prior context implements from here. Written 2026-08-13; contracts
verified against main @ f86e6114d._

## 0. Orientation for the implementing session

- Repo: `/Users/user/Developer/GitHub/tessera`, branch `main`, single
  worktree. Do not create long-lived side branches; milestone commits on a
  short-lived branch per phase, merged on green, is the house pattern.
- Read first, in order: `docs/tessera-pipeline-refactor-plan.md` (the why
  and the gates), this file (the what),
  `docs/tessera-refactor-contracts-appendix.md` (the exact current
  contracts -- mandatory before writing code), then per phase:
  `docs/tessera-eval-cache-design.md` (phase 2),
  `docs/tessera-kv-joint-reconstruction-design.md` (phase 3),
  `docs/l1-l5-pipeline-technical-report.md` section 12 (backlog context).
- Build: `cmake -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=ON`
  then `cmake --build build --target llama-tessera
  test-tessera-l5-dispatch test-tessera-regime -j8`. The streaming/ANE
  build (`-DGGML_ANE=ON -DGGML_BACKEND_DL=OFF`, see
  docs/weight-streaming.md section 4) is NOT needed until phase 3's L5
  harness work; configure it as `build-ws/` inside the repo when needed.
- Orphan tests (not in CMake) compile via
  `tools/quantize/tessera/test_all.sh` pattern -- the l2l5 suite line is
  the reference for compiling a test standalone.
- Models + telemetry DBs live on the external T7 volume
  (`/Volumes/Julian T7/models/...`). If it is not mounted, stop and ask.
- The Orpheus pair is the iteration model: `orpheus-3b-ft/orpheus-3b-ft-
  F16.gguf` (6.2 GB source) -> T640 quantize completes in ~15-30 min.

### Hard rules (each one was learned the expensive way this week)

1. **Never run or load a model larger than RAM via CPU/mmap paging.** A
   24 GB model on this 16 GB M1 hard-panicked the machine twice
   (watchdog timeout). Validation legs use the streamed path, a small
   model, or do not run.
2. **DuckDB is single-writer.** Never open a DB a run is writing. To
   inspect mid-run: copy the `.duckdb` AND its `.wal` to scratch, open
   the copy in write mode (WAL replays), query the copy.
3. **llama-tessera CLI parses classic flags only BEFORE positionals**;
   tessera-owned flags (`--tessera-db`, `--progress-file`) also work
   trailing. A trailing classic flag is SILENTLY IGNORED (this turned a
   `--dry-run` smoke into 16 CPU-minutes of real calibration; open
   finding). Phase 4 fixes this; until then, flags first.
4. **The fork's llama-cli has a chat TUI that redraws into redirected
   stdout** (one run produced 461 MB of frames). For any inference
   validation use `llama-server` + a JSON `/completion` curl.
5. **DuckDB recording is default-on**: every llama-tessera/llama-imatrix
   run derives `<output>.tessera.duckdb`. Give every experimental run
   its own explicit `--tessera-db` path or a distinct output name --
   resume-from-db is keyed by model_hash and WILL skip converged tensors
   from a prior DB (`--force-requantize` overrides).
6. **Equivalence runs pin `TESSERA_QUANTIZE_LAYERS=1`.** Layer
   parallelism legitimately reorders family warm-start propagation and
   changes GA outcomes; byte-equivalence is only defined serial.
7. Builds live inside the repo (`build/`, `build-ws/`), never /tmp -- a
   reboot erased a /tmp build tree once already.

### Phase 0 baseline (already done; inherit, do not redo)

- Consolidated build green; test-tessera-l5-dispatch and
  test-tessera-regime pass on main.
- Artifact-equivalence reference: Orpheus run-3 T640 GGUF,
  sha256 `20a2273ad0d8034ca99ec051f2fa3d6f29083eb9d13765098c4b64cddddac9ce`
  (`/Volumes/Julian T7/models/orpheus-3b-ft/orpheus-3b-ft-T640.gguf`,
  839 MB). A serial-pinned reproducibility run of the current binary
  against this hash was launched 2026-08-13; its verdict is recorded
  below when complete. If it did NOT match, the equivalence gate
  re-baselines on the repro artifact and the mismatch cause must be
  understood before phase 1 lands.
  - REPRO VERDICT: [pending at handoff -- check
    /tmp/orpheus-repro.log and compare hashes; update this line]

## 1. The seam: `ts_expert_eval` (phase 1)

New module `tools/quantize/tessera/tessera-expert-eval.{h,cpp}`, added to
the `llama-quantize-impl` source list in `tools/quantize/CMakeLists.txt`.

    // The ONLY evaluation door. Every expert, every tier, every caller.
    enum ts_eval_tier {
        TS_EVAL_PROXY = 0,     // profile-scaled T640-core streaming MSE
        TS_EVAL_REAL,          // the expert's actual algorithm + scored
                               // reconstruction
        TS_EVAL_KERNEL_DIRECT, // L1 sidecar tail-weighted t2 (falls back
                               // to REAL when no sidecar)
    };

    struct ts_eval_tensor_ctx {   // borrowed pointers; caller owns
        const char *  name;
        const float * weights;          // dequantized F32, row-major
        const float * act_scales;       // may be null
        int64_t       out_dim, in_dim;
        // digests for cache keying (phase 2; empty strings until then)
        std::string   model_hash;
        std::string   model_role;
        std::string   input_digest;     // imatrix / sidecar digest
        const char *  sidecar_dir;      // for KERNEL_DIRECT; may be null
    };

    struct ts_eval_opts {
        ts_eval_tier tier;
        float        alpha, clip;       // resolved base genes
        uint32_t     seed;
        float        l6_tail_tau, l6_tail_weight;  // KERNEL_DIRECT only
        // phase 3: the composed-runtime codec context enters the digest
        std::string  kv_codec_digest;   // "" = weights-only evaluation
    };

    struct ts_eval_result {
        float t2;          // normalized: mse * n / ||W||_F^2
        float mse;
        bool  from_cache;  // phase 2
        char  aux[256];    // per-expert extras as compact JSON
    };

    // expert: TS_EXPERT_AWQ / DARTQUANT / FLRQ / SEPTQ / CHAMPQ /
    //         LRQ / or the routed composite id
    int ts_expert_eval(ts_expert_id expert,
                       const ts_eval_tensor_ctx & ctx,
                       const ts_eval_opts & opts,
                       ts_eval_result * out);

Behavioral contract:
- PROXY tier reproduces today's `ts_dispatch_forced_t2` exactly
  (profile alpha/clip scaling into `ts_quantize_mse_streaming`).
- REAL tier per expert:
  - AWQ: identical to PROXY by construction (the T640 core with actual
    alpha/clip IS the real AWQ-family evaluation). Return PROXY result.
  - DARTQUANT: block rotation via `ts_dartquant_qr_orth` (block_size =
    largest of {128,64,32,16,8} dividing in_dim; max_iters 30, lr 1e-2,
    whip 0.1), `ts_dartquant_apply`, then T640-core MSE on the rotated
    weights; t2 against the ORIGINAL frob2 (orthogonal invariance).
    Migrate the existing `ts_dispatch_tier2_t2` DARTQUANT arm verbatim.
  - FLRQ/LRQ: `ts_train_lrq` (rank = clamp(min(out,in)/8, 1, 32),
    max_iters 50), residual = W - U*V, T640-core MSE on the residual,
    t2 against original frob2. Migrate the existing tier2 arm.
  - SEPTQ (the new work): `ts_septq_quantize_2d` with act_scales, then
    reconstruct via the T640 reference dequant
    (`dequantize_row_tessera_t640_with_meta`, ggml/src/ggml-quants.c:362)
    from the result's packed/page_scales/lane_scales/outlier_* fields,
    and score sum((W - W_hat)^2) * n / ||W||^2 = t2. Respect the same
    error bounds test-tessera-quants pins for the T640 round-trip.
  - CHAMPQ (also new): `ts_champq_compute` -> permutation; apply the
    column permutation; T640-core MSE on the permuted weights; t2
    against original frob2 (permutation-invariant norm).
- KERNEL_DIRECT: migrate `ts_dispatch_kernel_direct_t2` behind the seam;
  -1-sentinel fallback to REAL preserved.
- Thread-safety: pure w.r.t. inputs; safe under the acceptance stage's
  worker pool and the GA's eval threads. No globals; scratch is local.

Callers to convert in phase 1 (grep anchors, exact lines in the
CONTRACTS appendix): the G6 step-7b panel (both serial and threaded
branches -- five per-tensor calls each), `ts_dispatch_forced_t2`'s other
call sites, the tier2 call sites (delete `ts_dispatch_tier2_t2` after
migration), and the acceptance verdict's hessian slot loses its
"(proxy)" label in `tessera-acceptance.cpp` once SEPTQ is REAL (make the
label conditional or remove it and note the change in the commit).

The GA's `eval` callback (`ts_dispatch_awq_eval`) converts in phase 2
(it needs the cache to be worth routing; converting it in phase 1 is
allowed but must not change scores -- assert parity on a fixture).

Phase 1 tests:
- New `test_expert_eval.cpp` (orphan-style or CMake target): per expert,
  REAL tier on a deterministic fixture returns finite t2; SEPTQ REAL
  matches a hand-computed dequant error within 1e-6; PROXY == old
  forced_t2 values bit-for-bit on the fixture; CHAMPQ/DARTQUANT
  invariance sanity (t2 unchanged under identity rotation/permutation).
- `test-tessera-l5-dispatch` G6 block: extend to assert hess is no
  longer "(proxy)" and five methods appear.
- GATE: full Orpheus acceptance pass shows five REAL methods; commit
  message records the first real 5-method spread.

## 2. First-class eval cache (phase 2)

Copy the `v2_hessian_cache` pattern verbatim (its read/write helpers in
`tessera-quantize-db.{h,cpp}` are the exemplar -- same refusal
semantics, same ledger):

    CREATE TABLE IF NOT EXISTS eval_cache (
        model_hash    TEXT NOT NULL,
        model_role    TEXT NOT NULL DEFAULT 'trunk',
        tensor_name   TEXT NOT NULL,
        evaluator     TEXT NOT NULL,   -- 'expert:AWQ', 'expert:SEPTQ',
                                       -- 'ga', 'kernel_direct', 'l2', 'l4'
        params_digest TEXT NOT NULL,   -- genes/alpha/clip/tier grid-quantized
                                       -- + kv_codec_digest (phase 3)
        input_digest  TEXT NOT NULL,   -- imatrix | sidecar | source digest
        eval_version  INTEGER NOT NULL,
        t2            DOUBLE,
        aux           TEXT,
        computed_at   TIMESTAMP,
        PRIMARY KEY (model_hash, model_role, tensor_name,
                     evaluator, params_digest, input_digest, eval_version)
    );

- `ts_tessera_db_read_eval_cache` / `write_eval_cache`: first-write-wins
  (`ON CONFLICT DO NOTHING`), reader refuses version/digest mismatch,
  `<db-stem>.eval-cache.jsonl` ledger rows {hit|miss|compute|store}.
- The seam consults the cache when `ctx.model_hash` is non-empty and a
  db handle was injected (add a `ts_expert_eval_set_db(ts_tessera_db*)`
  or pass through ctx -- prefer explicit ctx field over a global).
- Adoption order (matches docs/tessera-eval-cache-design.md section 5):
  1. Acceptance panel (biggest deterministic win: identical re-dispatch
     goes to ~zero recompute).
  2. GA elite/seed re-evals through the seam (genes grid-quantized at
     1e-4 into params_digest).
  3. kernel_direct rows (input_digest = sidecar digest).
- `tensor_stats` completion (Layer A): add `frob2 DOUBLE`,
  `absq_sketch BLOB` (~1024-point |W| quantile sketch),
  `stats_version INTEGER`; producers in the dispatch walk; first
  readers: the seam's frob2 (drop the per-eval `ts_vec_dotpr` full
  pass), outlier-threshold selection via sketch quantile lookup, GA
  screening.
- **Schema-owner helper** (kills the l4_cols drift class): a function
  in the DB module that returns the ordered column-name list for a
  table BY PARSING its own CREATE TABLE string (the schema SQL is a
  string constant in the same file). Every `ts_db_buffer_open` call
  site switches to it. Add a unit test asserting generated lists match
  the appenders' value counts for every buffered table.
- GATE: identical Orpheus re-dispatch (same DB) -- acceptance stage
  >95% cache hits per the ledger; bumping eval_version forces recompute.
  Wall-clock of the re-dispatch recorded in the commit message.

## 3. KV-joint plumbing (phase 3)

Scope guard: measurement plumbing ONLY. Scale migration, pair-tying,
and the native KV codec are explicitly out (design gates them on this
phase's data).

- `-ctk/-ctv` (+ `-ctkd` draft variants) through:
  - `tools/tessera/e2e_probe.py`: pass-through args appended to BOTH
    llama-perplexity invocations (the base-logits save leg stays
    f16/f16 -- the reference is the model as intended; the candidate
    leg runs the deployed composition).
  - `tools/tile640/calibrate_quantize.py` `run_l4_gate`: forward the
    new flags.
  - `common/tessera-ppl-harness.cpp` `ts_l5_joint_models_load`:
    `cparams.type_k/type_v` from new tessera params (plumb through
    common/tessera-args.h + common/arg.cpp, following the existing
    tessera-owned flag pattern).
- The seam's `kv_codec_digest`: "" for weights-only; else
  "ctk=<t>,ctv=<t>[,draft...]" folded into params_digest so composed
  evaluations cache as distinct rows.
- `kv_stats` table on the spine + capture: per-layer post-RoPE K and V
  output sufficient statistics (per-channel sum2/maxabs + a pair-tied
  quantile sketch), captured at the imatrix observer seam. The exact
  hook point is in the CONTRACTS appendix (harness reader); if no
  natural hook exists for attention OUTPUTS, the fallback is a
  dedicated capture flag on llama-imatrix that registers the k/v
  projection outputs -- keep it observer-bundle-shaped either way.
- GATE: an L4 probe run at q8_0/q8_0 produces eval_cache rows distinct
  from the f16 run's; a capture run populates kv_stats for every layer;
  both recorded via the default-on DB.

## 4. Dispatch decomposition + CLI unification (phase 4)

- Split `tessera-dispatch.cpp` along the (now-real) seams into:
  `tessera-dispatch-gaprep.cpp` (walk + stats + routing),
  `tessera-dispatch-walk.cpp` (quantize loop),
  `tessera-dispatch-l5.cpp` (refine loop),
  `tessera-dispatch-acceptance.cpp` (step 7b, thin over the seam),
  `tessera-dispatch-db.cpp` (open/buffers/recorders), with
  `tessera-dispatch.cpp` reduced to orchestration. The statics each
  region depends on are inventoried in the CONTRACTS appendix -- move
  them into explicit context structs; no new globals.
- `quantize.cpp` argument unification: one parse pass accepting classic
  flags in any position (or erroring loudly on trailing unknowns --
  NEVER silently ignoring; that silence cost 16 CPU-minutes once).
  Closes the open dry-run finding in `.zcode/alphaevolve/findings.jsonl`
  (update its status with the fix commit).
- GATE: full suite green AND the serial-pinned Orpheus run produces a
  byte-identical GGUF vs the phase-0 reference hash. This gate is the
  refactor's falsifier; a hash change is a bug until proven a fix, and
  if proven a fix, the reference re-baselines with the reason recorded
  here.

## 5. Ultracode orchestration guidance

What parallelizes safely:
- Phase 1 expert adapters: one agent per expert (SEPTQ, CHAMPQ,
  DARTQUANT-migrate, LRQ-migrate) against the shared header landed
  first by a lead agent. Adversarial-verify SEPTQ's adapter against the
  round-trip bounds in tests/test-tessera-quants.cpp.
- Phase 2: cache helpers / tensor_stats producers / schema-owner helper
  are three independent tracks after the table DDL lands.
- Phase 4: one agent per extracted module, in worktrees, merged in
  dependency order (db first, acceptance last).
Serial only:
- Anything running llama-tessera against the T7 (single-writer DBs,
  shared disk bandwidth, the hard rules above).
- The equivalence run and its hash comparison.
- CMakeLists edits (single file, high conflict rate).
Verification pattern per phase: builder agents -> a skeptic agent per
new module trying to refute correctness (units, ownership, thread
safety) -> the gate run. Do not skip the skeptic on SEPTQ scoring and
the schema-owner parser; both are one-mistake-silently-wrong shaped.

## 6. Evidence appendix (why these decisions; all measured this week)

- Proxy panel degeneracy: rotation/Hessian t2 bit-identical to AWQ on
  197/197 tensors (Orpheus run 2/3); novelty tau pinned at 1.0.
- Real-panel first light (fixture): awq=0.152 rot=0.197 lr=0.344.
- Duplicate evals: 77% of 601,920 within-generation (island-loop bug,
  fixed); eval_cache targets the cross-run remainder (~108k) plus the
  acceptance stage.
- GA: winner-at-initialization on both models; patience-2 gate ships;
  200 evals/tensor (was 2,040); 30-min Orpheus pass (was ~2.5 h).
- L2 baseline FITTED: t640 expected 4.5e-1 (norm ratio) -- talker
  median 0.452, Orpheus median 0.447. Two-legged flag =
  max(1.0 x baseline, per-qtype 0.85 run quantile).
- eff_rank is normalized (0,1] as of 2843be5d2; DB rows before that
  (first Orpheus runs) carry RAW units -- check magnitude before
  comparing across runs.
- l4_cols drift bug: buffer 18 columns vs table 19 (model_role) made
  every flush fail silently; hence the schema-owner requirement.
- G6 margin floor: 2% default (a 0.0%-worse tie previously read as a
  near-pass); TESSERA_G6_MARGIN overrides.

## 7. CONTRACTS appendix

Externalized to `docs/tessera-refactor-contracts-appendix.md`: 477
entries from six parallel subsystem readers (2026-08-13, verified
against main @ f86e6114d) -- exact signatures, struct fields with their
real defaults (including which documented defaults the code does NOT
apply), line maps, per-region static dependencies for the phase-4
decomposition, and the kv_stats capture seam. READ IT BEFORE WRITING
CODE; it records several places where header comments contradict
implementation behavior (e.g. dartquant's remainder-column identity
tail, n_iters always reporting max_iters). Re-verify line numbers after
any intervening commit.
