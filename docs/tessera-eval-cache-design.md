# Eval Caching Across Calibration + Quantization: Audit and Design

_Audit date 2026-08-13, against `tessera-quantize-db.{h,cpp}` and the
dispatch as of `ce538ccc7`. Motivating question: the GA/acceptance/L5
paths re-derive expensive per-tensor results from raw bytes on every
run; can DuckDB carry them so neither pipeline needs the whole tensor
every time?_

## 1. Audit: three cache layers already exist in embryo

The schema (21 tables) already contains one instance of each pattern
this design needs. Nothing here is a new idea for this codebase; the
work is completing three patterns that each shipped once.

| Pattern | Existing exemplar | Key | State |
|---|---|---|---|
| Result cache (read-before-compute) | `v2_hessian_cache` + `ts_tessera_db_read/write_hessian_cache` (db.h:759,778) | `(model_hash, model_role, name, in_dim, scorer_version)` | Complete: first-write-wins, version gate, stale-hit refusal, append-only JSONL ledger |
| Sufficient-statistics substrate | `tensor_stats` (db.cpp:238) -- "cross-pipeline feature table ... new code should read from tensor_stats" | `(model_hash, model_role, name)` | **Write-only.** Upserted by the dispatch walk (dispatch.cpp:2173) and quantize.cpp:1519; zero readers found in C++, Python, or Studio |
| Calibration accumulators | `imatrix_accum_state` (db.cpp:270) | `(model_hash, model_role, tensor_name)` | Complete: crash-resumable running sums, chunks_seen resume offset |

Also relevant, and instructively *not* a cache:

- `ga_evaluations` (db.cpp:181) is keyed by `run_id` -- telemetry, ~1.6M
  rows/run through the MPSC `eval_buffer` (dispatch.cpp:585,762). A
  run-scoped key can never hit across runs. Leave it as telemetry; do
  not try to promote it.
- `ga_results` / `l5_weights` warm-start biases the *search*, not the
  *evaluation* -- it reseeds genes but re-pays every fitness call.
- Python already has both target patterns natively: `awq-evolve.py`
  checkpoints per-candidate stage scores keyed by layer-bundle digest,
  and the observer bundles (`in_sum2`, `in_sum4`, `in_maxabs`) are
  sufficient statistics instead of bytes. The C++ side is the laggard.

## 2. Audit: what actually re-reads or re-derives bytes

| Site | Cost per run | Deterministic inputs |
|---|---|---|
| G6 acceptance gate: `ts_dispatch_forced_t2` (dispatch.cpp:442) x 6 experts x every 2D tensor | ~6 full streaming-MSE passes over the model, every run, plus a redundant `||W||^2` dot per call | (tensor bytes, imatrix slice, dims, expert profile, alpha, clip) -- pure |
| GA fitness (step 5c): ~150 candidates/tensor | one tensor read amortized per phase; CPU per candidate | (bytes, genes, fitness kind, imatrix) |
| L5 loop: `ts_refine_reread_source` per flagged tensor per generation | full tensor re-read per gen (deliberate, memory-flat) | same bytes every time |
| Kernel-direct t^2: `ts_l1_load_sidecar` per tensor | full sidecar file read | (w_hat genes, sidecar digest) |
| Outlier threshold per candidate | full `|W|` scan/sort inside quantize | quantile of a fixed distribution |

The acceptance gate is the headline: its six per-tensor evals are pure
functions recomputed identically on every dispatch of the same model.

## 3. Design: one key spine, three orthogonal layers

The spine `(model_hash, model_role, name)` is already what
`tensor_stats`, `imatrix_accum_state`, and `v2_hessian_cache` share.
Every layer below adopts it unchanged; variable inputs become digest
COLUMNS, never key fragments; every layer carries its own version
column (the `scorer_version` lesson: a cache that survives a code
change is how you get "the GA got worse and we don't know why").

### Layer A -- make `tensor_stats` real (the byte-free substrate)

It has the right key, the right comment, and no readers. Complete it:

- Additive columns: `frob2 DOUBLE` (or document `rms^2 * n_elements`,
  which the existing columns already imply), `absq_sketch BLOB` (a
  ~1024-point quantile sketch of `|W|`), `row_mean_abs_digest TEXT`
  plus summary moments, `stats_version INTEGER`.
- First consumers, in order:
  1. `ts_dispatch_forced_t2`'s `frob2` dot product -- delete a full
     tensor pass per eval.
  2. Outlier-threshold selection: `outlier_fraction -> threshold`
     becomes a sketch lookup instead of a per-candidate `|W|` scan.
  3. The progressive/screening stage of the GA: score cheap candidates
     against sketches; only finalists touch bytes (this is exactly
     `awq-evolve.py`'s successive-halving, ported).
  4. Regime Tier-2 (already wants kurtosis/eff_rank from DB) and the
     L2 threshold refit (section 12 item 1 of the technical report)
     read the same rows.

### Layer B -- `eval_cache` (the result cache, hessian pattern verbatim)

```
CREATE TABLE IF NOT EXISTS eval_cache (
    model_hash    TEXT NOT NULL,
    model_role    TEXT NOT NULL DEFAULT 'trunk',
    tensor_name   TEXT NOT NULL,
    evaluator     TEXT NOT NULL,   -- 'expert:AWQ', 'ga', 'kernel_direct', 'l2'
    params_digest TEXT NOT NULL,   -- genes/alpha/clip/othresh/seed, grid-quantized
    input_digest  TEXT NOT NULL,   -- imatrix digest | sidecar digest | source digest
    eval_version  INTEGER NOT NULL,
    t2            DOUBLE,
    aux           TEXT,            -- JSON: mse, max_abs, per-expert extras
    computed_at   TIMESTAMP,
    PRIMARY KEY (model_hash, model_role, tensor_name,
                 evaluator, params_digest, input_digest, eval_version)
);
```

Semantics copied from `v2_hessian_cache`: `ts_tessera_db_read/
write_eval_cache`, first-write-wins (`ON CONFLICT DO NOTHING`), reader
refuses version/digest mismatches, `<db-stem>.eval-cache.jsonl` ledger
recording hit/miss/compute/store.

Producers/consumers, in adoption order:

1. **Acceptance gate** (biggest deterministic win): wrap the six
   `ts_dispatch_forced_t2` calls at both the serial and thread-pool
   branches (dispatch.cpp ~3460/~3510). Re-dispatching the same model
   goes from ~6 full-model MSE passes to ~zero. `evaluator =
   'expert:<name>'`, `input_digest = imatrix digest`.
2. **GA elite/seed re-evals**: hit rate comes from grid-quantized
   genes -- elites re-scored across generations, archive cells
   re-scored on resume, warm-started seeds across runs. Miss = compute
   as today; the cache is strictly additive to the search.
3. **Kernel-direct t^2**: `input_digest = sidecar digest`, so a
   recaptured L1 sidecar correctly invalidates.
4. **L2 divergence rows** (`evaluator='l2'`): persisting these makes
   the threshold refit a SQL query over history instead of a fresh run.

### Layer C -- calibration accumulators (already correct; extend, don't touch)

`imatrix_accum_state` is the pattern done right. The one planned
addition: an `alpha_l_probe` table for HIGGS perturb-and-measure
results, spine + `(layer, perturbation_digest, probe_version) ->
(ppl_delta, n_tokens)`. With weight streaming live, the perturbation
itself is a slot-fill hook (perturb layer L in the slot, forward,
measure, restore) -- zero extra memory, and every probe lands in the
same DB the L5 scorer already reads.

## 4. Why this stacks orthogonally

- **One owner**: the schema and read/write helpers live only in
  `tessera-quantize-db.{h,cpp}`. The calibrator and quantizer never
  include each other; both include the db module. (This is already
  true for hessian/tensor_stats/imatrix state -- the audit found no
  cross-includes to break.)
- **Layers compose but do not require each other**: A alone speeds
  screening and deletes redundant dots; B alone makes re-runs cheap; C
  alone is the calibration record. Any subset ships independently.
- **Both pipelines consume through the same spine**: the quantizer's
  acceptance gate and the calibrator's L2 refit read the same
  `eval_cache` rows; the quantizer's threshold selection and the
  calibration probes read the same `tensor_stats` rows. No second
  source of truth appears anywhere.
- **Streaming is complementary, not coupled**: the pool makes needed
  bytes arrive per layer; the cache makes most evals need no bytes.
  Neither knows the other exists.
- **Invalidation is column-carried**: model identity in the key,
  variable inputs as digests, code as versions. A stale row is
  unreachable, not wrong.

## 5. Order of work

1. `eval_cache` + acceptance-gate adoption (reuses hessian plumbing
   nearly verbatim; ~a day; makes every re-dispatch of the same model
   cheap enough to iterate freely).
2. `tensor_stats` readers: `frob2` in `forced_t2`, then the quantile
   sketch + threshold lookup.
3. GA elite hits (grid-hash the genes at the existing eval seam).
4. Kernel-direct + L2 rows.
5. `alpha_l_probe` once the streaming correctness fix is confirmed
   (the slot-perturbation hook depends on it).

Caveat carried from the audit: none of this changes single-fresh-run
cost of the GA's exact finals -- those must touch bytes. The wins are
re-runs, screening, the acceptance gate, and cross-pipeline reuse.
