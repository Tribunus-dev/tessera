# MoE Calibration: Precise Parity with Dense

_Status: design (2026-08-08). Scope: bring MoE expert tensors to the same
"super precise" calibration bar as dense 2D tensors — per-expert stats,
per-expert regime routing, per-expert evolutionary search, kernel-direct
fitness, and a flattened 3D GGUF that loaders actually read._

One sentence: **a MoE expert is a dense tensor that only sees a shard of
the data — calibrate it like one, then pack it flat.**

---

## 1. What "super precise" means on dense (the bar to hit)

For reference, the dense pipeline that earns the 12-18% per-tensor
Frobenius win is:

| Step | What it does | Code |
|---|---|---|
| **imatrix** | per-channel `E[x^2]` + `max|x|` from `llama-imatrix` on real corpus | `tools/imatrix/imatrix.cpp`, `tessera-imatrix.{h,cpp}` |
| **calib corpus** | `calib_X [n_tokens, in_dim]` + `ref_output` for AWQ layer-output search | `tessera-awq.cpp:ts_awq_scale_search_layer_output` |
| **regime descriptor** | `kurtosis, eff_rank, max_outlier_ratio, family, modality` per tensor | `tessera-regime.cpp:ts_regime_compute_descriptor` |
| **routing** | `family + kurtosis/eff_rank/modality -> 1 of 6 experts` (AWQ/LRQ/DartQuant/FLRQ/CHAMP-Q/SEPTQ) | `tessera-regime.cpp:ts_regime_classify` |
| **profile** | expert -> `(alpha_scale, clip_scale, septq, awq_grid, outlier_budget)` | `tessera-regime.cpp:ts_expert_default_profile` |
| **GA** | population 16, 8 gens, 4 islands; maximize `-t_l^2`; warm-start from DB | `tessera-awq.cpp`, `tessera-dispatch.cpp:263-294` |
| **fitness** | `ts_quantize_mse_streaming` offline proxy; optionally blended with L1 kernel sidecar `||W_hat - dequant_kernel||_F^2 / ||W||_F^2` | `tessera-quant.cpp`, `tessera-l1-fitness.{h,cpp}` |
| **L5 loop** | measure L2 `relative_frob`, requantize flagged families, iterate | `tessera-dispatch.cpp:ts_dispatch_run_l5_loop` |
| **DB** | `tessera.duckdb` warm-start (`ga_results`, `l5_weights`, `tensor_stats`), resume | `tessera-quantize-db.{h,cpp}` |
| **writer** | one T640 cluster per logical weight (packed + page/lane scales + outliers + act_scale) | `tessera-gguf-writer.cpp` |

The MoE path must clear every row of this table on a **per-expert** basis.

---

## 2. Audit: where MoE is today

### 2.1 What already works

- HF merge: `conversion/base.py:691` + `conversion/deepseek.py`, `qwen3moe.py`, … already fold `experts.{id}.gate/up/down` into `blk.I.ffn_{gate,up,down}_exps.weight [n_expert, n_ff, n_embd]` 3D tensors. Input GGUF is a single 3D weight per projection — no work needed.
- Gate: `tools/quantize/tessera/tessera-dispatch.cpp:93` `ts_is_quantizable()` accepts `n_dims==3` with any dequantizable type. `tessera-quant.cpp:1228` `ts_quantize_3d()` exists and is tested (`tools/quantize/tessera/test_moe_shapes.cpp`). Dispatch calls it at `tessera-dispatch.cpp:2538`.
- Kernel: T640 MoE matmul exists in `ggml/src/ggml-cpu/ops.cpp`, `ggml-metal`, `qwen35moe.cpp:136` `LOAD_TILE640_3D`. No new kernel needed.

### 2.2 Five gaps that break parity

**G1 — Writer emits unloadable tensors.**
Dispatch writes `blk.0.ffn_gate_exps.weight.0`, `.1`, … (`tessera-dispatch.cpp:2563-2566`, one cluster per expert, suffix-per-expert).
Every Tessera-aware MoE loader expects **one flattened cluster**:

```
qwen35moe.cpp:136: LOAD_TILE640_3D
  weight_packed              [n_expert * out_dim * ppr * 32]  I32
  weight_page_scales         [n_expert * out_dim * ppr]       F16
  weight_lane_scales         [n_expert * out_dim * ppr * 32]  I8
  weight_outlier_row_offsets [n_expert * (out_dim + 1)]       I32
  weight_outlier_cols/vals   [total_outliers]                 I32/F16

llama-model.cpp:3011: ffn_gate_up_exps (fused gate+up) uses the same flat layout.
```

Suffix clusters are valid GGUF but no model registers them — they load as unknown tensors and the expert is effectively zero.

**G2 — One activation scale for all experts.**
`ts_quantize_3d(const float *act_scales, ..., n_experts)` forwards the same pointer to every `ts_quantize_2d` iteration (`tessera-quant.cpp:1244-1248`). In a top-k router each expert sees a disjoint ~`1/frac` of tokens with different tail statistics. Sharing one `mean(|act|)` smears the outlier channels and misroutes the regime (a heavy-tailed expert gets plain AWQ when it needs DartQuant rotation). Imatrix and AWQ corpus are both un-sliced.

**G3 — Family collapse + missing per-expert descriptors.**
`tessera-regime.cpp:14-24` `ts_family_patterns` maps `ffn_gate` -> `ffn_gate`. An MoE `ffn_gate_exps` hits the same branch and never reaches the `routed_expert` family used by `tools/tessera/awq-evolve.py:51` and `docs/w4a4-calibration-design.md:541`. No per-expert `kurtosis/eff_rank/max_outlier_ratio` is computed — one descriptor is inferred from the 3D blob's in_dim or (worse) the first slice's weight column magnitudes.

**G4 — GA is disabled for 3D.**
`tools/quantize/tessera/tessera-dispatch.cpp:1878,2289` explicitly filter `nd != 2` for GA prep and warm-start. MoE tensors only ever see `ts_expert_default_profile()` — no evolutionary `(alpha, clip)` search, no `ts_quantize_mse_streaming` scoring per expert, no S5 kernel-direct sidecar. Unified `alpha/clip` across 8-64 experts leaves the 2-5% (+ 12-18% with `direct` fitness) win on the floor.

**G5 — Loader coverage is narrow and sensitive tensors are not protected.**
Only `qwen35moe`, `gemma4`, and the generic `llama-model.cpp:3004` fused `ffn_gate_up_exps` path advertise T640 3D. `qwen3moe`, `deepseek`, `olmoe`, `glm4moe`, etc. still declare `FFN_GATE_EXPS` as dense F16 only. Router tensors (`blk.*.ffn_gate_inp.weight [n_embd, n_expert]`) are quantizable by family and will be T640'd — they are 0.1% of params but 100% of routing fidelity and must be kept at high precision or excluded, like `attn_output` on Gemma.

Ancillary: `W4A4`, `L1 sidecar`, `L2 diff`, `L5 refine` all `deferred for 3D` (`tessera-dispatch.cpp:2532`); `tessera-l1-fitness` key is tensor name, not per-expert.

---

## 3. Design: per-expert calibration that reuses the dense machinery

Doctrine: evolve, don't version. No v2 quantizer, no `ts_quantize_3d_v2`. Extend `ts_quantize_3d`, the regime table, the DB keys, and the writer in place.

### 3.1 Naming and DB identity (the one decision everything hangs on)

- **Canonical expert identity:** `<logical>.%d` suffix internally — `blk.0.ffn_gate_exps.weight.7` is expert 7 of gate in layer 0. This is what the calibration stack, GA, imatrix, and DB see. It reuses the existing `tensor_stats` primary key `(model_hash, model_role, name)` and `ga_results(tensor_name)` without schema migration — rows are just more granular.
- **GGUF persistence:** one flattened cluster per logical — `blk.0.ffn_gate_exps.weight_packed` etc. with shape `[n_expert * ...]`. No suffix in the file. The loader's `LOAD_TILE640_3D` already expects this.
- **Mapping:** `ts_gguf_write_tensor_cluster_3d()` concatenates the per-expert `packed/page_scales/lane_scales/outlier_*` vectors in expert order; `ggml` reading side slices by `expert * stride`. The suffix namespace never leaves the build — it is the calibration DB's internal key, not the file format.

Policy files and receipts reference the suffix form so a human can audit "expert 7 is the DartQuant outlier". The unified writer doc (`tessera-unified-tts-integration-plan.md` §1.3) already resolved the same (role, name) vs name-only tension for the talker — reuse that precedent.

### 3.2 imatrix / act_scales: per-expert, router-aware

**Collector:** extend `IMatrixCollector` / `tessera-imatrix` to emit `[n_experts, in_dim]` per `*_exps.weight`. For each token, after the router top-k is computed, accumulate:

```
per_expert_sum[e][c]   += |x[c]|          // for act_scales (mean |act|)
per_expert_sumsq[e][c] += x[c]^2          // for E[x^2] -> kurtosis/eff_rank
per_expert_max[e][c]    = max(|x[c]|)     // for max_outlier_ratio
per_expert_count[e]    += 1               // for normalization + token budget
```

All four stay `[n_experts, in_dim]` — same shape as the weight's last dim so `ts_dispatch_act_scales` can just index by `e`. Shared (non-MoE) tensors keep the current `[in_dim]` path unchanged.

**Token budget:** an expert sees `top_k / n_experts` of tokens on average. To keep the same standard error on `kurtosis` as dense, scale corpus tokens:

```
tokens_for_parity ~= dense_tokens * n_experts / top_k
```

For Qwen3-30B-A3B (64 experts, top-8) that is 8x; for DeepSeek-V2 (160 experts, top-6) ~27x. The spec does not mandate a global multiplier — the imatrix writer records `per_expert_count` and the calibration verifier rejects experts with `< 512` routed tokens as "insufficient statistics" (fall back to the family prior).

**Dispatch resolution:** new helper `ts_dispatch_act_scales_3d(name, e, in_dim, imatrix_3d, calib_X_3d, scratch)` returns `&act[e*in_dim]`. `ts_imatrix_lookup` gains an `expert` overload that returns `nullptr` when the caller has no 3D entry, so the 2D fast path is untouched.

**AWQ corpus:** when `calib_X` is available, slice it by routing too — `calib_X_expert[e]` is the row-subset routed to `e`. The layer-output search `ts_awq_scale_search_layer_output` then minimizes `||calib_X_expert @ (W_e - W_hat_e)||` per expert rather than the global reconstruction. If routing metadata is absent (offline imatrix-only run), fall back to the global `calib_X` — correct but less sharp, explicitly logged as `imatrix-only (no expert routing)` at `verbose`.

### 3.3 Regime: per-expert descriptors

- Extend `ts_family_patterns` with the most specific fragments first:

```cpp
{ "ffn_gate_exps", "routed_expert" },
{ "ffn_up_exps",   "routed_expert" },
{ "ffn_down_exps", "routed_expert" },
{ "ffn_gate_up_exps", "routed_expert" }, // fused path
// ... existing ffn_gate/ffn_up/ffn_down follow
```

- `ts_regime_compute_descriptor` is called per slice: `weights = base + e*out_dim*in_dim`, `imdata = &imatrix_3d[e*in_dim]`. That gives per-expert `kurtosis/eff_rank/max_outlier_ratio` and thus a potentially different routed expert (one expert's gate may be `DartQuant` while its sibling is plain `AWQ`) — exactly the heterogeneity that makes MoE worth the extra calibration.
- `tensor_stats` gets one row per `(model_hash, model_role, name.e)`. Existing analytics (`calibration_to_tensor_stats.py`) already call `ts_regime_infer_family` — they pick up the new family with no change.

### 3.4 GA: lift the n_dims filter, keep the unified knob as fallback

- Remove the `nd != 2` guard at `tessera-dispatch.cpp:1878` (GA prep) and `2289` (warm-start). The GA loop already keys by `tensor_name` string — feeding it `blk.0.ffn_gate_exps.weight.7` makes each expert a separate `ts_awq_layer` with its own `(alpha, clip)` search.
- Fitness per expert is the same `ts_quantize_mse_streaming` (or `ts_quantize_2d` when `use_kernel_direct`) that dense uses, so S5 blending with the L1 sidecar works unmodified — `tessera-l1-fitness` just loads `sidecar_dir/<name>.<e>.act.dequant.f32` when present, else falls back to the offline proxy, same as dense.
- Default policy: **per-expert search**. For users who want speed, add `--tessera-moe-unified` (single `(alpha, clip)` broadcast to all experts of a logical) — but it is not the precise mode and its receipt must carry `moe_search: unified` so audit can distinguish. Precise receipts carry `moe_search: per_expert`.
- DB warm-start (`family_seed_lookup`) stays per `routed_expert` family — the first expert of each MoE projection warm-starts from prior runs' best `routed_expert` composite, same as `attn_q` does today.

Cost note: 60 layers * 3 projs * 8 experts * (16 pop * 8 gens) ~= 18k candidate evals vs ~1.5k dense. Each eval is `ts_quantize_mse_streaming` (~132 KB scratch, streaming), so wall time scales with expert count, not memory. The 64-expert Qwen case is ~8x the 8-expert case — shard by layer (the existing sharded GA dispatch does this) and the parallelism is embarrassingly per-expert.

### 3.5 Writer: flat 3D cluster (the 60-line fix)

New API in `tessera-gguf-writer.{h,cpp}`:

```cpp
void ts_gguf_write_tensor_cluster_3d(
    struct gguf_context * ctx, struct ggml_context * gctx,
    const char * logical_name,               // e.g. blk.0.ffn_gate_exps.weight
    const std::vector<ts_quant_result_2d> & per_expert,
    int64_t n_experts, int64_t out_dim, int64_t in_dim);
```

It concatenates:

```
packed              : cat([e.packed])              -> [n_expert*out_dim*ppr*32] I32
page_scales         : cat([e.page_scales])         -> [n_expert*out_dim*ppr]    F16
lane_scales         : cat([e.lane_scales])         -> [n_expert*out_dim*ppr*32] I8
outlier_row_offsets : cat([e.outlier_row_offsets] with prefix-sum fixup)
                      each expert's CSR offsets are 0-based per expert; the flat
                      tensor is n_expert*(out_dim+1) with no cross-expert prefix.
outlier_cols/vals   : cat([e.outlier_cols/vals])   -> [total_outliers]
act_scale           : optional; when present, emit [n_experts, in_dim] F16
                      (matches qwen35moe.cpp:239 ffn_gate_up_exps_act_scale shape)
```

Dispatch's 3D branch (`tessera-dispatch.cpp:2582-2568`) replaces the suffix loop with one call. No suffix tensors are emitted. The generic `llama-model.cpp:3011` fused `ffn_gate_up_exps` path (which already expects flat) works with no loader change.

Error handling: the writer asserts `per_expert.size() == n_experts` and that every slice's `in_dim/out_dim` matches the first — same guard `test_moe_shapes.cpp` already has.

### 3.6 Loaders + sensitive tensors

- Sweep every MoE arch under `src/models/*.cpp` that declares `FFN_GATE_EXPS/FFN_UP_EXPS/FFN_DOWN_EXPS` as dense and add the `create_tensor_or_tile640` arm (copy `qwen35moe.cpp:227` / `gemma4.cpp:165`). At minimum: `qwen3moe`, `qwen2moe`, `deepseek`, `olmoe`, `glm4moe`, `phimoe`. The `TENSOR_NOT_REQUIRED` flag keeps backward compat — old F16 GGUFs still load.
- **Sensitive list:** extend `is_gemma4_sensitive_tensor` / policy with `ffn_gate_inp` (the router) and `ffn_exp_probs_b`. They are the MoE analogue of `attn_output`/`qk-norm` — quantizing them collapses top-k. Precise mode keeps them `F16` (or `Q8_0` at most); the `--tessera-quantize-skip` / `route copy-through` path already exists for this, just add the substring `ffn_gate_inp` / `exp_probs` to the skip set. Document it alongside the existing `DEFAULT_GEMMA4_SENSITIVE_PATTERNS`.

### 3.7 L1/L2/L5/W4A4 follow-ons (deferred but scoped)

With per-expert names in place, these become trivial extensions — intentionally not in the initial precise-parity slice:

- **L1 sidecar** — writer emits `sidecar_dir/<logical>.%d.act.dequant.f32`; reader probes per-expert first, then logical.
- **L2 diff** — per-expert `relative_frob` + type-aware flagging (same thresholds as dense).
- **L5 loop** — group by logical family `routed_expert`, not by name prefix; the A/B harness already does `ts_regime_infer_family` grouping.
- **W4A4** — currently `MoE 3D W4A4 is deferred` (`tessera-dispatch.cpp:2532`). Once the 2D W4A4 path stabilizes, the same per-expert slicing applies to `ts_w4a4_quantize_weights`.

None of these block the writer + GA + imatrix work.

---

## 4. Phases and gates

**Phase M1 — Writer + family + sensitive list (1-2 days).**
Files: `tessera-regime.cpp`, `tessera-gguf-writer.{h,cpp}`, `tessera-dispatch.cpp` (3D branch), `llama-model.cpp` or per-arch loaders for the slice under test, `src/models/qwen3moe.cpp` (or the target arch for the first model).

Gate: `test_moe_shapes` + new `test_moe_writer_flat` (round-trip: quantize 64x `ffn_gate_exps` with known weights, write flat, reload via `ggml` and assert `packed.size() == n_expert*out_dim*ppr*32` and `outlier_row_offsets` segments are independent). Manual: `llama-cli -m qwen3-30b-a3b-t640.gguf -p "Hello"` loads and produces tokens (no NaN, no missing-tensor error).

**Phase M2 — Per-expert imatrix + AWQ slicing (3-5 days).**
Files: `tools/imatrix/imatrix.cpp` (router-aware accumulation), `tessera-imatrix.{h,cpp}` (3D lookup), `tessera-dispatch.cpp` (act_scales_3d helper), `calibration_to_tensor_stats.py` (no-op, already family-generic).

Gate: imatrix GGUF contains `blk.0.ffn_gate_exps.weight.in_sum2 [n_experts, in_dim]` (inspect with `gguf-dump`). Per-expert `kurtosis` varies across experts on a real corpus (assert stddev > 0.1 on Qwen3-30B). Dispatch `--verbose` prints per-expert `family=routed_expert expert=DartQuant/AWQ/...` heterogeneity.

**Phase M3 — Per-expert GA + DB + L5 grouping (2-3 days).**
Files: `tessera-dispatch.cpp` (lift `nd!=2` filter), `tessera-quantize-db.{h,cpp}` (no schema change — just more rows), `tessera-awq.cpp` (no change).

Gate: `tessera.duckdb: SELECT count(*) FROM ga_results WHERE tensor_name LIKE '%.ffn_%_exps.weight.%'` equals `n_layers * n_projs * n_experts`. Per-expert `relative_frob` is 2-18% better than the unified-alpha baseline on the same imatrix (reproduce the dense `direct` vs `importance` delta, now per expert). Receipt carries `moe_search: per_expert` with per-expert `(alpha, clip, outlier_thresh)`.

Honest total: **~1.5-2 weeks** for parity, with the corpus-token cost (8-27x depending on `n_experts/top_k`) being the real wall time, not the code. Phase M1 alone unblocks an end-to-end MoE T640 that is byte-compatible with loaders — M2+M3 make it *precise*.

---

## 5. Risks and open questions

1. **Corpus cost.** 8-27x tokens for parity is real egress/compute. Mitigation: the `per_expert_count` guard lets thinly-routed experts fall back to the family prior rather than overfitting on <512 tokens. Cold-start models can ship M1-only (unified) and upgrade to per-expert on the next corpus refresh — the receipt makes the difference auditable.
2. **Quantized router.** Keeping `ffn_gate_inp` in F16 is the safe default. If the architect wants the router quantized, it should be a separate experiment with top-k accuracy as the metric, not Frobenius.
3. **Fused `ffn_gate_up_exps` vs split.** `llama.cpp` generic path fuses gate+up (`llama-model.cpp:3004` `n_ff*2`). The conversion layer already handles both; the writer must not double-fuse. The spec preserves whatever the input GGUF's logical is — if the input is fused, `n_experts` is still `ne[2]` and the flat shape is `n_expert * (n_ff*2) * ppr * 32`.
4. **No new versioned types.** `GGML_TYPE_TESSERA_T640` stays the type — MoE is a shape, not a type. The `c++-port-design.md` §8 `TESSERA_T640_3D` enum was superseded by the flat-cluster convention (mirrors how `MXFP4_MOE` was handled as a naming prefix, not a type, in `conversion/base.py:620`).
5. **Tooling.** `gguf-dump`, `llama-quantize --tessera-dump-policy`, and the Studio quantizer already handle arbitrary tensor names — per-expert suffixes are visible with no change. The Studio UI should group by logical when presenting `routed_expert` families (one row per expert, collapsed by default).

---

## 6. What this spec does NOT do

- No Hadamard rotation / OliVe outlier pairing / HAWQ ILP — same exclusion as W4A4 §1 non-goals.
- No MoE-specific W4A4 in the first slice (deferred, §3.7; full design is §9.4 — new spec starting here).
- No change to the Tile640 page/lane geometry (640/20/32) or the kernel math.
- No new subcommand — the existing `llama-quantize` + `--tessera-*` flags gain MoE awareness transparently, same as multimodal did with `model_role`.

---

# Part II — Full fleet: L1/L2/L5/W4A4 across every MoE arch

> New spec (2026-08-08). This part extends Part I from "Qwen3-30B-shaped MoE"
> to the full production matrix: DeepSeek V4 (Flash / Pro), GLM-5.2 (and 4.5
> as its baseline), Kimi K3 (and K2 as its baseline), Minimax M3 (and M2),
> Mistral 3 / 4, and the Ornith family. It is the single source of truth for
> what L1/L2/L5/W4A4 have to do on MoE. Nothing in Part I is retracted — Part II
> makes the §3.7 "deferred" rows concrete and adds the per-arch loader/writer
> sweep that Part I left as "at minimum: qwen3moe, ..." .

## 7. Model matrix

One row per deployable variant. "TBD" means "read it off the GGUF header at
port time — the code already handles any n_expert/top_k; the number below is
the expected value from the HF config and must be confirmed before gating".
All MoE layers use SwiGLU (`LLM_FFN_SILU` + `LLM_FFN_PAR`) unless noted.

| # | Family | Variants (HF id shape) | GGUF `arch` | Arch file(s) | Total / Active | Layers | Routed / Shared / Top-k | `n_ff_exp` (per expert) | Layout | Gating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Qwen3-MoE | 30B-A3B (48L), 235B-A22B (94L) | `qwen3moe` | `qwen3moe.cpp`, `qwen35moe.cpp` (reference T640) | 30B/3B, 235B/22B | 48, 94 | 128 / 0 / 8 | 768 (30B), 1536 (235B) | split `gate/up/down` 3D | softmax | The baseline Part I was built against. `qwen35moe.cpp` is the only arch that already has `LOAD_TILE640_3D` wired; `qwen3moe.cpp` still needs it. |
| 2 | DeepSeek V3.2 | V3 671B-A37B (61L), V3.2 refresh | `deepseek2` / `deepseek4` | `deepseek2.cpp`, `deepseek4.cpp`, `deepseek32.cpp` | 671B/37B | 61 | 256 / 1 / 8 | 2048 | fused `gate_up` + `down` 3D | sigmoid | V3.2 keeps V3 geometry (256/8) but shares the deepseek4-style HC/DSA plumbing in the newer GGUFs. |
| 3 | DeepSeek V4 | Flash (60L, ~600B class) / Pro (61L, ~700B class) | `deepseek4` | `deepseek4.cpp` | TBD / 37-50B | 60-61 | 256 / 1 / 8 (Flash), 288 / 1 / 8 (Pro, TBD) | TBD (confirm `expert_feed_forward_length`) | fused `gate_up` via `create_tensor_gate_up_exps` + `down` 3D | `sqrt_softplus` (`deepseek4.cpp:52` asserts) | Flash vs Pro is a layer-count + expert-count + compress-ratio (`LLM_KV_ATTENTION_COMPRESS_RATIOS`) variant, not a code fork. Both use `LLM_TENSOR_FFN_GATE_UP_EXPS` (fused) so writer must handle `n_ff*2`. Pro may add a second shared expert — treat as `n_expert_shared>1`. |
| 4 | GLM-4.5 | Air 106B-A12B (46L), 355B (92L) | `glm4moe` | `glm4-moe.cpp`, `glm-dsa.cpp` | 106B/12B, 355B/32B | 46, 92 | 128 / 1 / 8 (Air), 160 / 1 / 8 (355B) | 1536 | fused `gate_up` + `down` 3D | sigmoid | `n_layer_dense_lead=1` (layer 0 dense, rest MoE). 355B variant has optional Q/K-norm. |
| 5 | GLM-5.2 | TBD (expected 400B+ class, 92-96L) | `glm4moe` (reuse) | `glm4-moe.cpp` (+ `glm-dsa.cpp` if DSA) | TBD | TBD (likely 92-96) | TBD (confirm `expert_count` / `expert_used_count`) | TBD | fused `gate_up` + `down` 3D (inherit from 4.5) | sigmoid | No arch fork expected — 5.2 reuses `glm4moe` with larger `n_expert`/`n_ff_exp`. Onboarding = confirm header values and run loader smoke only. |
| 6 | Kimi K2 | K2 1T-A32B (62L class) | `kimi-linear` | `kimi-linear.cpp` | ~1T/32B | 62 | 384 / 1 / 8 | 1024 (`moe_intermediate_size`) | split `gate/up/down` 3D + latent `moe_latent_size` | sigmoid | KDA+MLA hybrid. MoE input dim is `moe_latent_size` when `>0` (via `ffn_latent_down/up`), not `n_embd`. |
| 7 | Kimi K3 | K3 2.78T-A104B (93L) | `kimi-linear` | `kimi-linear.cpp` | 2780B/104B | 93 | **896 / 1 / 16** | 1024 | same as K2 | sigmoid | Disk-offload study artifact (`docs/moe-disk-offload-study.md`): 93L * 896 * 1024, 16 active/layer. Latent MoE, same loader as K2. Largest calibration-cost row (56x). |
| 8 | Minimax M2 | M2 230B-A10B (62L) | `minimax-m2` | `minimax-m2.cpp` | 230B/10B | 62 | 32 / 0 / 6 | `n_ff` (not `n_ff_exp`) | split 3D dense | softmax | No fused path, no shared expert, no dense lead. `n_rot` != `n_embd_head` (ignore the GGML assert in the file). |
| 9 | Minimax M3 | M3 400-600B class (62-80L, TBD) | `minimax-m2` (reuse) or `minimax-m3` if Arch bump | `minimax-m2.cpp` (or new `minimax-m3.cpp` if HF config adds fields) | TBD | TBD | TBD (expect 64-128 / 1 / 8) | TBD | split 3D (inherit) | TBD (confirm `expert_gating_func`) | Assume reuse of `minimax-m2` arch unless HF adds a new KV (e.g. latent MoE). Onboard via header check. |
| 10 | Mistral 3 | 8x7B, 8x22B (NeMo style), 32L-56L | `mistral3` | `mistral3.cpp` | 47B-141B/13B | 32-56 | 8 / 0 / 2 | `n_ff` (≈14336/8) | split 3D (optional, else dense) | softmax | `n_expert==0` means dense — same binary handles both. Granite shared-expert path reuses `n_ff_shexp` when present. |
| 11 | Mistral 4 | Medium 3 / Large 3 refresh (TBD) | `mistral4` | `mistral4.cpp` (stub) + `llama-arch.cpp:80` | TBD | TBD | TBD (expect 8-16 / 0-1 / 2-4) | TBD | split 3D | softmax | File is currently a stub (`models.h` graph only). Treat as Mistral-3 loader pattern + new KV if HF adds it. |
| 12 | Ornith | Internal code-name family (covers `afmoe` 6B/26B and future bird-named MoEs) | `afmoe` (and future `ornith-*`) | `afmoe.cpp`, `bailingmoe*.cpp`, `ernie4-5-moe.cpp`, `lfm2moe.cpp` as templates | 6B-400B | 26-56 | 64-128 / 1 / 6-8 | 1408-2048 | split 3D + shared shexp, ISWA when `n_swa>0` | sigmoid | No single GGUF arch — "Ornith" is a dispatch label for the fleet of small/medium MoEs that share the `afmoe` loader shape (dual attn/ffn norm, `n_layer_dense_lead`, `ffn_gate_shexp`). Onboard each new bird by cloning `afmoe.cpp` loader + adding `LLM_ARCH_*` if HF introduces a new `model_type`. |

Reading the matrix:

- "Fused" means the HF export merges `gate+up` into one logical `ffn_gate_up_exps.weight [n_embd, n_ff*2, n_expert]` (DeepSeek, GLM). "Split" means three separate 3D tensors (Qwen, Kimi, Minimax, Mistral, AfMoE). The writer handles both — see §8.
- Latent MoE (Kimi only): when `moe_latent_size > 0`, the expert's `in_dim` is `moe_latent_size`, not `n_embd`. The imatrix/act_scale dimension follows the latent dim. The shared-expert path stays at `n_embd` dim (it bypasses the latent projections).
- Dense lead: GLM and AfMoE (and Kimi when `n_layer_dense_lead>0`) have first `k` layers dense. Those layers calibrate as dense 2D — no per-expert rows, no corpus multiplier.

### 7.1 What "done" means per family

A family is done when all three are true:

1. Loader advertises T640 3D (or fused) and a stock F16 GGUF still loads (`TENSOR_NOT_REQUIRED`).
2. Quantizer emits a flat cluster that `llama-cli -m <family>-t640.gguf -p "Hello"` loads and produces non-NaN tokens on both CPU and Metal.
3. `tessera.duckdb` has `n_layers_moe * n_proj_3d * n_experts` rows in `ga_results` + `tensor_stats` with per-expert `moe_search=per_expert` receipt.

## 8. Per-arch loader & writer mapping

This is the exhaustive file sweep that Part I left as "at minimum". Every row is a required code touch for parity — the default is `create_tensor_or_tile640` for the 3D projections, gated by `TENSOR_NOT_REQUIRED` so old F16 GGUFs keep loading.

### 8.1 Split-3D families (Qwen, Kimi, Minimax, Mistral, AfMoE/Ornith)

Pattern (copy `qwen35moe.cpp:136` `LOAD_TILE640_3D` shape, or the generic helper in `llama-model.cpp:3013`):

```cpp
// before (today)
layer.ffn_gate_exps = create_tensor(tn(LLM_TENSOR_FFN_GATE_EXPS, "weight", i), {n_embd, n_ff_exp, n_expert}, 0);

// after (adds T640 flat cluster)
layer.ffn_gate_exps = create_tensor_or_tile640(
        tn(LLM_TENSOR_FFN_GATE_EXPS, "weight", i),
        {n_embd, n_ff_exp, n_expert}, 0);
// create_tensor_or_tile640 probes "<name>_packed" in the GGUF meta;
// if absent it falls back to create_tensor with the same shape.
// No TENSOR_NOT_REQUIRED needed when the dense shape is the fallback —
// but keep it when the arch also supports fused (DeepSeek/GLM path).
```

Apply to **every** `FFN_GATE_EXPS / FFN_UP_EXPS / FFN_DOWN_EXPS` declaration in:

| File | Current | Patch |
|---|---|---|
| `src/models/qwen3moe.cpp:52-54` | `create_tensor` | `create_tensor_or_tile640` |
| `src/models/qwen2moe.cpp` | `create_tensor` | `create_tensor_or_tile640` |
| `src/models/qwen35.cpp` / `qwen35moe.cpp` | already T640 | reference impl — no change |
| `src/models/kimi-linear.cpp:256-259` | already `create_tensor_or_tile640` | verify latent dim (`moe_n_embd`) path still correct |
| `src/models/minimax-m2.cpp:36-38` | `create_tensor` | `create_tensor_or_tile640` |
| `src/models/mistral3.cpp:76` | `create_tensor` (conditional on `n_expert>0`) | `create_tensor_or_tile640` inside the `else` branch |
| `src/models/mistral4.cpp` | stub — add `load_arch_tensors` mirroring `mistral3.cpp` | new |
| `src/models/afmoe.cpp:85-87` | `create_tensor` | `create_tensor_or_tile640` |
| `src/models/bailingmoe.cpp`, `bailingmoe2.cpp` | `create_tensor` | `create_tensor_or_tile640` |
| `src/models/ernie4-5-moe.cpp`, `lfm2moe.cpp`, `granite-moe.cpp`, `olmoe.cpp`, `phimoe.cpp`, `exaone-moe.cpp`, `grok.cpp`, `hunyuan-moe.cpp`, etc. | `create_tensor` | `create_tensor_or_tile640` (mechanical sweep) |
| `src/models/deepseek.cpp`, `deepseek2.cpp`, `deepseek2ocr.cpp`, `deepseek32.cpp` | `create_tensor` or legacy fused | `create_tensor_gate_up_exps` + `create_tensor_or_tile640` for `down` (see §8.2) |
| `src/models/glm4-moe.cpp:91-94` | mixed (`create_tensor_gate_up_exps` for fused, `create_tensor_or_tile640` for down) | ensure `down` already T640, add fused writer support |
| `src/models/dots1.cpp`, `glm-dsa.cpp`, `llada-moe.cpp`, `openai-moe.cpp`, `seed-oss.cpp` | `create_tensor` | `create_tensor_or_tile640` |

Mechanical rule: if `grep -n FFN_.*_EXPS src/models/*.cpp` finds a `create_tensor` without `_or_tile640`, it is a gap. The sweep is intentionally exhaustive — missing one arch means a GGUF that quantizes but not loads, which is worse than not quantizing at all.

### 8.2 Fused gate_up families (DeepSeek V4, GLM-4.5/5.2)

Fused layout is one logical tensor:

```
ffn_gate_up_exps.weight [n_embd, n_ff_exp*2, n_expert]   // gate || up concatenated on dim 1
```

Loader is `llama-model.cpp:3071 create_tensor_gate_up_exps()` — it already handles both the dense 3D and the T640 flat cluster (`*_packed` with shape `n_expert * (n_ff*2) * ppr * 32`). No per-arch change needed except ensuring the arch's `load_arch_tensors` calls `create_tensor_gate_up_exps` (both `deepseek4.cpp:139` and `glm4-moe.cpp:91` already do).

Writer must not double-fuse. Rule: preserve whatever the input GGUF's logical is.

- If the input GGUF has `ffn_gate_exps` + `ffn_up_exps` (split), the writer emits two flat clusters.
- If it has `ffn_gate_up_exps` (fused), the writer emits one flat cluster with `out_dim = n_ff_exp*2`. The dispatch looks up `n_experts = ne[2]` and `out_dim = ne[1]` from the GGUF tensor header — it does not synthesize `*2`.

### 8.3 Special cases

- **Kimi latent MoE.** `moe_latent_size` replaces `n_embd` as the experts' `in_dim` (and `out_dim` for `down`'s second dim). The loader at `kimi-linear.cpp:234-235` already computes `moe_n_embd`; the writer must read `ne[0]` from the input tensor header rather than re-deriving from `hparams.n_embd`. The imatrix collector's `in_dim` for these tensors is `moe_latent_size`, and `per_expert_act_scales` is `[n_experts, moe_latent_size]`. No code fork — just ensure the dispatch never assumes `in_dim == n_embd`.
- **Dense lead layers.** When `i < hparams.n_layer_dense_lead`, the layer is dense 2D (`ffn_gate/up/down` at `n_embd x n_ff`). Calibration, regime, GA, L1/L2, W4A4 all run the dense path. The MoE 3D path is gated on `layer.ffn_gate_exps != nullptr || layer.ffn_gate_up_exps != nullptr`. No writer change.
- **Shared experts.** `ffn_gate_shexp / ffn_up_shexp / ffn_down_shexp` are dense 2D (`n_embd x n_ff_shexp` where `n_ff_shexp = n_ff_exp * n_expert_shared`). They are not routed, not per-expert, and calibrate as dense. No 3D handling, but they are *not* sensitive — quantize normally. Only `ffn_gate_inp` / `ffn_exp_probs_b` are protected.
- **Ornith / new birds.** Onboarding checklist for an arch not yet in the tree:
  1. Add `LLM_ARCH_*` in `src/llama-arch.cpp` + `src/llama-hparams.h`.
  2. Add converter in `conversion/*.py` that merges `experts.{e}.gate/up/down` into the 3D GGUF layout (reuse `base.py:691` pattern).
  3. Add `src/models/<new>.cpp` loader — clone `afmoe.cpp` as template, wire `ffn_gate_inp` + 3D exps + shared shexp.
  4. `grep` the quantizer allowlist (`tessera-dispatch.cpp:93 ts_is_quantizable`) — 3D types are already allowed, no change.
  5. Run the writer flat smoke (`test_moe_writer_flat`) and `llama-cli` load.

### 8.4 Sensitive tensors (router protection, all families)

Extend the `is_gemma4_sensitive_tensor` / policy skip set with:

```
ffn_gate_inp        // router logits [n_embd, n_expert] — 0.1% of params, 100% of routing fidelity
ffn_exp_probs_b     // router bias [n_expert]
ffn_gate_tid2eid    // DeepSeek-V4 hash-layer token->expert map [n_expert_used, n_vocab]
```

Precise mode: copy-through at F16 (or Q8_0 at most). The `--tessera-quantize-skip` / `route copy-through` path already exists — just add these substrings to the skip set and document alongside `DEFAULT_GEMMA4_SENSITIVE_PATTERNS`. No per-expert logic.

## 9. L1/L2/L5/W4A4 on MoE — what parity means at each layer

The runtime-aware pipeline (`docs/runtime-aware-pipeline.md`) defines six layers. On MoE, each layer's "per tensor" becomes "per expert" for the 3D projections. Everything else (naming, DB keys, flat persistence) reuses §3.1.

```
Dense:  tensor "blk.0.ffn_up.weight"  -> one row in tensor_stats / ga_results
MoE:    expert "blk.0.ffn_up_exps.weight.7" -> one row per expert, same tables, same PK
        GGUF file: one flat cluster "blk.0.ffn_up_exps.weight_packed" [n_expert*...]
```

No schema migration. The suffix never leaves the build. `tensor_stats.model_role` stays as today (`trunk` etc. — if a MoE family ever needs a role dimension, add `moe_latent` etc. as values, not a column).

### 9.1 L1 — kernel dequant fidelity (per expert ground truth)

**Goal on MoE:** for each T640 expert, the kernel's effective dequant for that expert is dumped alongside the BF16 source, keyed by the per-expert name.

Changes:

- **Sidecar key:** `tessera_debug::open_dequant_writer` is called with `blk.0.ffn_gate_exps.weight.7` (the suffix form) for the MoE matmuls, not the logical name. The `llama_tile640_tensor` dequant loop in `llama.cpp` already iterates `for e in 0..n_expert-1` when `GGML_OP_TILE640_MATMUL_ID` is used — the hook point is per-expert inside that loop. One file per expert: `<dequant_dir>/blk.0.ffn_gate_exps.weight.7.dequant.f32` (same 28-byte `TDQT` header as dense).
- **Backend coverage:** the hook lives in the same three backends as dense (`ggml-cpu.c`, `ggml-cuda.cu`, `ggml-metal-ops.cpp` linked via `llama-tessera-debug`). No new backend file — the T640 MoE matmul reuses the dense dequant (`ggml_tile640_dequant` with `n_expert` stride), so the existente `common/tessera-debug/tessera-debug.{h,cpp}` writer covers it.
- **Verification:** `test_l1_sidecar.cpp` gains a `test_l1_moe` case that quantizes a 2-expert fixture, runs one `ggml_tile640_matmul_id` invocation with `LLAMA_TILE640_DEBUG_DEQUANT_DIR` set, and asserts two sidecar files exist with per-expert `kernel_id` in the provenance JSON.

Non-MoE tensors (router, shared expert, dense lead, attention) keep the current single-file path.

### 9.2 L2 — BF16 vs quant differential (per expert)

**Goal on MoE:** per-expert `max_abs / mean_abs / relative_frobenius / per_layer_norm` plus the type-aware flag `relative_frob > 1.5 * type_expected`.

Changes:

- **Scorer:** `tools/quantize/tessera/tessera-l2-diff.{h,cpp}` already scores a pair `(W_src_2d, W_recon_2d)` via `ts_l2_tensor_diff`. For MoE, call it per slice `W_src + e*out_dim*in_dim` vs the L1 sidecar for that expert. No new math.
- **Report shape:** schema `llama.tessera.runtime-probe.v1` gains no new top-level field — each per-expert entry is a regular per-tensor row keyed by the suffix name. A logical with 128 experts thus contributes 128 rows. Downstream consumers that group by family already call `ts_regime_infer_family`, which returns `routed_expert` for all `*_exps` fragments (§3.3 fix).
- **Thresholds:** type-aware table unchanged. T640 target remains `<2e-2` per expert. A MoE layer is flagged only if `median(expert rel_frob) > threshold` OR `p95(expert rel_frob) > 1.5*threshold` — this avoids flagging a layer because a single under-sampled expert is noisy.
- **Imatrix coupling:** when L2 runs with `--imatrix`, `per_expert_max_abs` influences the outlier budget (see W4A4 §9.4). L2 itself does not change.

### 9.3 L3 — per-token coherence (weight-level proxy)

The shipped L3 is per-row cosine between L1 kernel sidecar and L1.5 reference (`tessera-l3-coherence.{h,cpp}`), not per-token KL. The MoE extension is the same per-row cosine, computed per expert.

- `ts_l3_tensor_coherence` is called per expert slice; report key is suffix form.
- No per-token KL probe is added here — that probe lives in `tools/tessera/runtime_probe.py` and remains dense-only until the design in `runtime-aware-pipeline.md` §L3 is implemented. MoE L3 gates on the weight-level proxy only.

### 9.4 W4A4 — 4-bit weights + 4-bit activations on MoE

This is the §3.7 that was deferred. Full design — same doc that defines W4A4 for dense (`docs/w4a4-calibration-design.md`) now applies per expert.

**Why MoE W4A4 is per-expert.** Each expert sees a disjoint routed subset of tokens with different activation tails. A single `act_scale_static` or single SmoothQuant `alpha` across 896 experts would smear the outlier channels and lose the 1-2% PPL win that W4A4 calibration earns on dense.

Concrete fields (additive on top of the dense W4A4 sidecar fields in `w4a4-calibration-design.md` §2):

| Field | Shape when MoE | Notes |
|---|---|---|
| `tessera.w4a4.act_scale_static` | `[n_experts, in_dim]` F16 per logical (flattened to `n_expert*in_dim` in GGUF meta) | Per-expert static scale. `per_token` dynamic mode stores nothing (same as dense). |
| `tessera.w4a4.act_outlier_count` | `[n_experts]` U32 | Per-expert outlier channel count (LLM.int8 threshold 6.0). |
| `tessera.w4a4.act_outlier_indices` | packed per expert, concatenated | Sorted ascending per expert; kernel binary-searches. |
| `tessera.w4a4.act_outlier_vals` | packed F16 | One entry per outlier index. |
| in-GGUF tile cluster `weight_act_scale` | `[n_experts, in_dim]` or `[n_expert*in_dim]` | The SmoothQuant-folded per-channel scale that the T640 dequant applies as a per-channel mul (reuses the existing `weight_act_scale` tensor from `quantize_v3.py:3218`). For Kimi latent MoE, dim is `moe_latent_size`. |
| `weight_act_scale` for Kimi latent | `[moe_latent_size]` per expert | Same field, different dim — derived from `ne[0]` not `n_embd`. |

Flow:

1. **SmoothQuant fold per expert.** `s_j = max(|X_j|)^alpha / max(|W_j|)^(1-alpha)` is computed per expert from `calib_X_expert[e]` (the routed rows) and `W_e`. `W'_e = W_e * s_j`, `X'_e = X_e / s_j`. `alpha` is a per-expert gene in the GA (discrete `{0.5, 0.75, auto}`, same as dense §4). `auto` uses the 10% outlier-fraction rule per expert.
2. **AWQ search per expert** runs on the folded `W'_e` with `act_scales = per_expert_act_scales[e]`. Same `ts_quantize_2d` path as weight-only, but the activation scale is expert-specific and the AWQ alpha grid is post-fold.
3. **LLM.int8 decomposition per expert.** Threshold `|X'_t[c]| > 6.0`, cap 0.1% of `in_dim` per expert. Indices/sidecar emitted per expert. Kernel branch is per channel and invariant across tokens for that expert's routed rows.
4. **GA fitness per expert.** Section 6.2 of `w4a4-calibration-design.md` already defines `fitness = 0.5*W4A16 + 0.5*W4A4` per candidate. On MoE, that weighted sum is computed per expert candidate, not per logical. The `--tessera-moe-unified` fast mode broadcasts one `(alpha, clip, smoothquant_alpha)` across all experts of a logical — fitness is then the mean across experts, and the receipt carries `moe_search: unified`.
5. **Kernel.** No new dequant kernel file. The existing T640 MoE dequant already iterates experts and applies `weight_act_scale` per channel before the FMA (`ggml_tile640_dequant` path). The W4A4 activation dequant for MoE is the same per-channel branch as dense, just keyed by expert id. The three helper files in `w4a4-calibration-design.md` §7 (`quant-tessera-w4a4.{c,cuh,metal}`) are unchanged — they operate on `X_hat` after the per-expert scale is applied.
6. **Deferral lift.** `tessera-dispatch.cpp:2532` `MoE 3D W4A4 is deferred` guard is removed. The per-expert call becomes `ts_w4a4_quantize_weights(W_e, act_scales_3d[e], smoothquant_alpha_e, ...)`.

**Fallback when per-expert stats are thin.** If `per_expert_count[e] < 512`, the W4A4 per-expert path falls back to the dense/logical prior for that expert (family `routed_expert` seed), same as the weight-only GA fallback in §3.2. The receipt logs `w4a4_fallback: insufficient_routing` for that expert.

### 9.5 L5 — adaptive requantization (per expert)

**Goal on MoE:** given the per-expert L2 report and the per-expert `ga_results`, identify the expert slices that exceed their type's expected divergence and re-run the per-expert GA only on those slices, then re-emit the flat cluster.

Changes:

- **Scorer grouping.** `tessera-l5.{h,cpp}` currently groups by family via `ts_regime_infer_family`. On MoE, the interesting grouping is still by `routed_expert` family — but the scorer input is per-expert rows, so the rollup reports per-family p50/p95/median. The plan step (`ts_l5_pick_top`) picks experts, not logicals — the threshold is applied to the per-expert `relative_frob` distribution, not the per-logical mean.
- **Planner.** `ts_l5_orchestrator_run` takes the filtered per-expert names and re-runs `ts_quantize_2d` (or `ts_w4a4_quantize_weights`) only for those experts. The delta is a sparse patch: only the flagged experts' slices of the flat cluster are rewritten; unflagged experts are memcpy'd from the previous dispatch pass.
- **Retune.** `l5_retune.py` OLS in `tessera-unified-db.md` (`delta_mse ~ sensitivity_score`) becomes per-`(model, family)` still — but `family` is `routed_expert`, and the hit-rate is computed over expert rows. The retuned `(w_imatrix, w_gradient, w_layer)` weights feed back into the next GA's `family_seed_lookup` per expert, same as dense.
- **DB audit trail.** `l4_plan_outcome` / `l5_plan_summary` / `l5_outcome` already key by `tensor_name` string — per-expert suffix rows fit without migration. The plan_id stays `cpp_quant_gen{N}_stage{S}`; the per-expert iteration reuses the same `N` (one L5 generation covers all flagged experts).
- **Early-exit / converged-fast gate.** The `l5_outcome` hit-rate gate that short-circuits the L5 loop applies to the expert population, not the logical population. If 90% of flagged experts are `plan_accepted`, the loop exits.

**Non-MoE L5 is unchanged.** The existing dense/policy loop runs identically; the MoE extension is just that the "tensor" list it iterates may contain suffix keys.

### 9.6 L4 / L6 / DB

- **L4 (E2E probe).** No per-expert E2E — the probe runs on the full model with the flat MoE clusters loaded. The report gains no schema change; the per-expert fidelity story is L2/L3's job. If the MoE model fails L4 (PPL delta), the operator reruns L5 with a tighter per-expert threshold.
- **L6 (kernel-direct fitness).** The GA fitness already reads the L1 sidecar. On MoE it reads the per-expert sidecar `<logical>.%d.act.dequant.f32` when present, else falls back to the offline proxy — same as `tessera-l1-fitness.{h,cpp}` branch for dense. No new fitness file.
- **DB (`tessera.duckdb`).** No schema migration. `tensor_stats` PK is `(model_hash, model_role, name)` where `name` is already the string key — per-expert rows are just more granular. Budget warning: K3 (93L * 3 projs * 896 experts = ~250k rows in `tensor_stats` + `ga_results`). DuckDB handles this, but the Polars analytics queries should filter by `family='routed_expert'` before pulling the full table. The write-buffer pattern (`tessera-db-buffer.{h,cpp}`) already batches 65k rows, so the GA hot path (18k-250k candidate evals) stays I/O-bound, not lock-bound.

## 10. Calibration cost & corpus guidance

### 10.1 Token budget law

Same law as §3.2, now with fleet multipliers:

```
tokens_for_parity ~= dense_tokens * n_experts / top_k
per_expert_tokens   = total_routed_tokens * top_k / n_experts
per_expert_tokens >= 512  → keep per-expert calibration
per_expert_tokens <  512  → fall back to family prior (unified) for that expert
```

`dense_tokens` is the corpus size that gives stable `kurtosis/eff_rank` on a dense 2D tensor (≈4k-8k tokens on the Tessera imatrix pipeline). The imatrix writer records `per_expert_count` per expert so the verifier can enforce the 512-token floor.

### 10.2 Fleet multipliers (parity corpus size)

| Family | `n_experts / top_k` | Parity multiplier | 8k dense baseline → parity tokens | Verdict |
|---|---|---|---|---|
| Qwen3-30B/235B | 128/8 = 16 | **16x** | 128k | Feasible. One corpus refresh. |
| DeepSeek V3/V4 Flash | 256/8 = 32 | **32x** | 256k | Feasible. |
| DeepSeek V4 Pro | 288/8 = 36 | **36x** | 288k | Feasible. |
| GLM-4.5 Air | 128/8 = 16 | **16x** | 128k | Feasible. |
| GLM-4.5 355B | 160/8 = 20 | **20x** | 160k | Feasible. |
| GLM-5.2 TBD | ~192/8 = 24 | **~24x** | ~192k | Confirm header. |
| Kimi K2 | 384/8 = 48 | **48x** | 384k | Large but feasible (overnight corpus). |
| **Kimi K3** | **896/16 = 56** | **56x** | **448k** | **Dominant cost.** 93L * 896 experts = 250k per-expert fittings. Recommend hierarchical pooling (see §10.3) unless 400k+ routed tokens are available. |
| Minimax M2 | 32/6 ≈ 5.3 | **~5x** | 42k | Cheap. |
| Minimax M3 TBD | ~64/8 = 8 | **~8x** | 64k | Cheap. |
| Mistral 8x7B/8x22B | 8/2 = 4 | **4x** | 32k | Cheap. |
| AfMoE / Ornith small | 64/6 ≈ 10.7 | **~11x** | 86k | Feasible. |
| AfMoE / Ornith medium | 128/8 = 16 | **16x** | 128k | Feasible. |

For K3, the raw GA cost is also largest: 93 layers * 3 projs * 896 experts * (16 pop * 8 gens) ≈ **32M candidate evals**. Each eval is `ts_quantize_mse_streaming` (~132 KB scratch, streaming) — wall time, not memory, is the bottleneck. Shard by layer (the existing sharded GA dispatch in `tessera-dispatch.cpp` already does this) and the L5 loop becomes embarrassing per expert.

### 10.3 Hierarchical pooling for K3 (and any future 500+ expert model)

When `n_experts >= 384` and `per_expert_tokens` is thin, per-expert GA overfits. Use two-stage pooling:

1. **Family prior.** Run one GA per logical family (`routed_expert` per layer or global) to get `(alpha, clip)` seed — this is the `--tessera-moe-unified` path.
2. **Per-expert delta.** For experts with `per_expert_count >= 512`, run a 2-gen, pop-8 delta search seeded from the family prior (±15% on alpha/clip). For thin experts, keep the family prior.

Receipt carries `moe_search: hierarchical` and the verifier can audit how many experts were delta-tuned vs prior-held. On K3 this cuts evals from 32M to ~5M (family prior) + ~60k deltas (the well-sampled experts).

### 10.4 Offline imatrix-only fallback

If routing metadata is absent (imatrix collected without router tracing), the pipeline falls back to global `calib_X` for AWQ corpus and mean `act_scales` for regime (§3.2). On MoE this is correct but less sharp:

- L2 flagging still works (per-expert `relative_frob` is independent of routing).
- L5 still requants correctly — it just starts from a worse seed and takes one extra generation to converge.
- The dispatch logs `imatrix-only (no expert routing)` at `verbose` so audit can distinguish from the precise path.

## 11. Validation & gates (per family)

### 11.1 Shared gate (all families)

```
Phase M1 gate:  test_moe_shapes  +  test_moe_writer_flat
                (quantize 2-expert fixture, write flat, reload via ggml,
                 assert packed.size()==n_expert*out_dim*ppr*32 and
                 outlier_row_offsets segments are independent)
                Manual: llama-cli -m <family>-t640.gguf -p "Hello" -> tokens, no NaN, no missing-tensor
```

```
Phase M2 gate:  imatrix GGUF contains blk.0.ffn_gate_exps.weight.in_sum2 [n_experts, in_dim]
                (gguf-dump), per-expert kurtosis stddev > 0.1 on a real corpus,
                --verbose prints per-expert family=routed_expert heterogeneity
```

```
Phase M3 gate:  SELECT count(*) FROM ga_results WHERE tensor_name LIKE '%.ffn_%_exps.weight.%'
                == n_layers_moe * n_projs_3d * n_experts
                Per-expert relative_frob is 2-18% better than unified baseline (dense direct vs importance delta)
                Receipt carries moe_search: per_expert | unified | hierarchical
```

### 11.2 Per-family spot checks

| Family | Spot model for gate | Extra check |
|---|---|---|
| Qwen3-MoE | 30B-A3B (single-node) | 235B: load-only (too large for CI) |
| DeepSeek V4 Flash/Pro | DeepSeek-V3 671B F16 -> T640 (smoke 2 layers via `--tessera-layers 0,30`) | Hash-layer `ffn_gate_tid2eid` preserved F16 |
| GLM-4.5/5.2 | Air 106B (46L) | Dense lead layer 0 stays dense; `attn_post_norm` not quantized |
| Kimi K3 | K3 F16 -> T640 on 2 layers (`--tessera-layers 1,46`) | Latent dim `moe_latent_size` respected; `per_expert_count` >=512 for tuned experts |
| Minimax M2/M3 | M2 230B | Minimal — 32 experts, cheap baseline |
| Mistral 3/4 | Ministral 8B (8x7B) | `n_expert==0` dense path still works (`TENSOR_NOT_REQUIRED` fallback) |
| Ornith/AfMoE | AfMoE 6B | ISWA path (`n_swa>0`) plus MoE on same model |

### 11.3 W4A4 gate (when enabled)

Per-expert `act_scale_static` row exists for `routed_expert` families when `--w4a4` + per-expert routing. Fallback rows log `w4a4_fallback: insufficient_routing`. The `llama.tessera.per-tensor-calibration.v1 -> v2` schema bump is append-only (see `w4a4-calibration-design.md` §2 L1 sidecar format change).

## 12. Rollout order & file checklist

Honest total for parity across the fleet: **~2-3 weeks** (Part I M1-M3 is 1.5-2 weeks for the pipeline; the fleet sweep is code-mechanics plus per-family load smokes, not new algorithms). Corpus cost (4-56x) dominates wall time, not LoC.

### 12.1 Order

1. **M1 (1-2d):** `tessera-regime.cpp` family fix + `tessera-gguf-writer.{h,cpp}` flat cluster + `tessera-dispatch.cpp` 3D writer branch + sensitive list. Smoke `qwen3-30b-a3b-t640.gguf` (split 3D) and `deepseek-v3-t640.gguf` (fused).
2. **M1b (1d):** Loader sweep `src/models/*.cpp` (table §8.1). Mechanical, one PR. Gate: `ggrep FFN_.*_EXPS` finds no bare `create_tensor` left.
3. **M2 (3-5d):** Router-aware imatrix `[n_experts,in_dim]` in `tools/imatrix/imatrix.cpp` + `tessera-imatrix.{h,cpp}` 3D lookup + `ts_dispatch_act_scales_3d()` + calib_X slicing. Gate §11.1 M2.
4. **M3 (2-3d):** Lift GA filter (`nd !=2` at `tessera-dispatch.cpp:1878,2289`), DB per-expert rows, L5 grouping by `routed_expert`, verify 2-18% win. Hierarchical pooling for K3 (§10.3). Gate §11.1 M3.
5. **M4 (2-3d, overlaps M3):** W4A4 per-expert (§9.4) + L1/L2/L5 per-expert (§9.1-9.5). Remove `MoE 3D W4A4 is deferred` guard. Gate §11.3.
6. **M5 (1d):** Per-family load smokes (§11.2). No new code — `llama-cli` on 2 layers per family. Green means fleet is done.

### 12.2 File checklist (all paths relative to `tessera/` root)

| File | Change | Phase |
|---|---|---|
| `tools/quantize/tessera/tessera-regime.cpp:14-24` | add `ffn_*_exps` -> `routed_expert` patterns, most-specific first | M1 |
| `tools/quantize/tessera/tessera-regime.h` | doc: `routed_expert` covers MoE 3D | M1 |
| `tools/quantize/tessera/tessera-gguf-writer.{h,cpp}` | add `ts_gguf_write_tensor_cluster_3d()` flat concatenator | M1 |
| `tools/quantize/tessera/tessera-dispatch.cpp:93` | no change (already allows 3D) — verify | M1 |
| `tools/quantize/tessera/tessera-dispatch.cpp:1878,2289` | remove `nd !=2` GA gate | M3 |
| `tools/quantize/tessera/tessera-dispatch.cpp:2532` | remove `MoE 3D W4A4 is deferred` | M4 |
| `tools/quantize/tessera/tessera-dispatch.cpp:2538,2563` | replace suffix loop with `ts_gguf_write_tensor_cluster_3d` + `ts_dispatch_act_scales_3d` | M1+M2 |
| `tools/quantize/tessera/tessera-dispatch.cpp:2827` | extend sensitive set (`ffn_gate_inp`, `ffn_exp_probs_b`, `ffn_gate_tid2eid`) | M1 |
| `src/llama-model.cpp:3013` `create_tensor_or_tile640` | no change — verify MoE latent dim path | M1b |
| `src/llama-model.cpp:3071` `create_tensor_gate_up_exps` | no change — verify fused | M1b |
| `src/models/qwen3moe.cpp`, `qwen2moe.cpp`, `deepseek*.cpp`, `glm4-moe.cpp`, `kimi-linear.cpp`, `minimax-m2.cpp`, `mistral3.cpp`, `mistral4.cpp`, `afmoe.cpp`, `bailingmoe*.cpp`, ... | `create_tensor` -> `create_tensor_or_tile640` sweep | M1b |
| `tools/imatrix/imatrix.cpp` | router-aware `per_expert_*` accumulation | M2 |
| `tools/quantize/tessera/tessera-imatrix.{h,cpp}` | 3D lookup overload | M2 |
| `tools/quantize/tessera/tessera-l2-diff.{h,cpp}` | per-expert scoring loop (suffix keys) | M4 |
| `tools/quantize/tessera/tessera-l3-coherence.{h,cpp}` | per-expert cosine | M4 |
| `tools/quantize/tessera/tessera-l5.{h,cpp}` | per-expert top-fraction + sparse patch | M4 |
| `tools/quantize/tessera/tessera-quantize-db.{h,cpp}` | no schema change — row count grows | M3 |
| `common/tessera-debug/tessera-debug.{h,cpp}` | per-expert sidecar keys | M4 |
| `tools/quantize/tessera/test_moe_shapes.cpp` | already exists — gate | M1 |
| `tools/quantize/tessera/test_moe_writer_flat.cpp` | **new** — flat round-trip test | M1 |
| `tools/quantize/tessera/test_l1_sidecar.cpp` | add `test_l1_moe` | M4 |
| `conversion/base.py:691`, `conversion/kimi_linear.py`, `conversion/deepseek.py`, `conversion/glm.py`, `conversion/minimax.py`, `conversion/mistral.py` | verify HF -> GGUF 3D merge produces `[n_expert, n_ff, n_embd]` (already does for most) | M5 |
| `docs/tessera-unified-db.md`, `docs/runtime-aware-pipeline.md` | add `routed_expert` per-expert note (doc-only) | M5 |

### 12.3 Explicit non-goals (fleet)

- No new `GGML_TYPE` — `GGML_TYPE_TESSERA_T640` stays the type; MoE is shape, not type (§5.4 precedent with `MXFP4_MOE`).
- No new subcommand or arch fork per bird — the Ornith family is a dispatch label, not a versioned implementation. Clone the loader, don't version the quantizer.
- No NVFP4 / TQ2_0 / block-vs-row imatrix work — orthogonal to MoE fleet.
- No prompt-bank L4 per-expert probe — L4 stays whole-model; L2 is the per-expert E2E.

---

## Appendix A. Glossary

| Term | Meaning |
|---|---|
| `routed_expert` | Family for `FFN_{GATE,UP,DOWN}_EXPS` and `FFN_GATE_UP_EXPS` (§3.3). Routes to the same 6 experts (AWQ/LRQ/DartQuant/FLRQ/CHAMP-Q/SEPTQ) but via per-expert descriptors. |
| `moe_search` | Receipt field: `per_expert` (precise), `unified` (one alpha/clip broadcast), `hierarchical` (§10.3 pooling). |
| `per_expert_act_scales` | `[n_experts, in_dim]` act scales (F16). For Kimi latent, `in_dim = moe_latent_size`. |
| `per_expert_count` | Routed token count per expert from the imatrix collector; floor 512 for precise path. |
| Flat cluster | One GGUF tensor set per logical (`weight_packed`, `weight_page_scales`, `weight_lane_scales`, `weight_outlier_*`) with `n_expert * ...` shape. No suffix in GGUF. |


---

# Part III — Weight-pool streaming for MoE (Slice 4.2a-MoE)

> New section (2026-08-08). Extends the 2-slot IOSurface weight pool
> (Slice 4.2a, `src/llama-weight-pool.{h,cpp}`) to handle MoE expert
> tensors (`ffn_gate_exps`, `ffn_up_exps`, `ffn_down_exps`,
> `ffn_gate_up_exps`). The dense pool streams one layer's FFN per slot;
> MoE needs per-expert streaming because a layer's full expert set is too
> large for a single IOSurface slot.

## 13. The MoE streaming problem

The dense weight pool (`src/llama-weight-pool.cpp`) aliases all of a layer's
FFN tensors (3 tensors, ~450 MiB on gemma-4-12B) into one of two ~461 MiB
IOSurface slots. The Metal encoder refills the slot per-layer during
`ggml_metal_graph_compute_streamed`.

MoE breaks this model in two ways:

### 13.1 Size: a MoE layer's experts don't fit in one slot

For Qwen3-30B-A3B (128 experts, n_ff_exp=768, n_embd=2048, bf16):

```
per expert: gate_up [2048, 1536] + down [768, 2048] = 9.0 MiB
per layer:  128 experts * 9.0 MiB = 1.15 GiB
```

A single IOSurface slot sized for the largest dense layer (~461 MiB) cannot
hold a MoE layer's full expert set. And the pool's `max_layer_bytes` —
computed as the max across all layers — would be dominated by the MoE layers,
requiring a ~1.15 GiB slot that exceeds the practical IOSurface budget on a
16 GiB M1.

### 13.2 Access: MUL_MAT_ID touches a subset of experts per token

Dense FFN uses `GGML_OP_MUL_MAT` — the full weight is consumed every token.
MoE uses `GGML_OP_MUL_MAT_ID` — `src[2]` is an expert-id list (`[n_tokens,
n_expert_used]`), and the kernel only reads the rows of `src[0]` (the 3D
weight) indexed by those IDs. With top-8 of 128 experts, only 8 of 128 expert
slices are read per token batch.

The streamed compute segments the cgraph by layer (detecting `is_streamed_ffn`
nodes). For dense, all FFN MUL_MATs of layer L fall in one segment. For MoE,
the MUL_MAT_ID node's `src[0]->name` is `blk.L.ffn_gate_exps.weight` (which
passes `is_streamed_ffn`), but the op is MUL_MAT_ID, and the weight is 3D.

## 14. Design: per-expert pool slots

### 14.1 The expert slot

Instead of two layer-sized slots, the MoE pool uses two **expert-set-sized**
slots. An "expert set" is the collection of expert slices that a single
MUL_MAT_ID call reads: `n_expert_used` (top-k) experts, one slice per expert,
for one projection (gate_up OR down). The slot size is:

```
expert_set_bytes = top_k * per_expert_bytes
```

For Qwen3-30B-A3B: `8 * 9.0 MiB = 72 MiB` per projection. Two slots = 144 MiB
total — well within budget.

The pool fills the slot with exactly the experts that the MUL_MAT_ID will
read, not the full 3D tensor. This requires the pool to know which expert IDs
are active for each call.

### 14.2 Expert ID extraction

The MUL_MAT_ID op carries the expert IDs in `src[2]` (the "ids" tensor,
`[n_tokens, n_expert_used]` I32). Before encoding a MoE segment, the streamed
compute extracts the unique expert IDs from `src[2]`, passes them to the
pool's refill callback, and the pool memcpy's only those expert slices into
the slot.

The slot is **not a contiguous slice of the 3D weight** — it is a gather of
selected expert slices, laid out in the order the kernel expects (expert ID
order from `src[2]`). The 3D weight tensor's `->data` is re-pointed to the
slot, with a stride that matches the per-expert layout.

### 14.3 Pool API extension

Add to `src/llama-weight-pool.h`:

```cpp
// Phase MoE: refill the slot with a specific set of expert slices for a
// 3D weight tensor. The pool gathers the named expert slices from the mmap
// and packs them contiguously into slot[slot_index]. Returns the slot index
// or -1 on failure.
int llama_weight_pool_ensure_experts(
    llama_weight_pool_t * pool,
    int32_t layer,
    const char * tensor_name,      // e.g. "blk.0.ffn_gate_exps.weight"
    const int32_t * expert_ids,    // [n_experts_used]
    int32_t n_experts_used);
```

The pool's `ensure_experts`:
1. Resolves the tensor name to a per-expert offset in the stream's layout.
2. For each `expert_ids[i]`, memcpy's that expert's slice from the mmap into
   `slot_base[slot] + i * per_expert_bytes`.
3. Sets `slot_layer[slot]` to a cache key derived from `(layer, tensor_name,
   expert_ids_hash)` so the same expert set isn't re-streamed on cache hit.

### 14.4 Streamed compute changes

In `ggml_metal_graph_compute_streamed` (`ggml-metal-context.m`), the segment
loop gains MoE awareness:

1. `is_streamed_ffn` already matches `blk.L.ffn_*_exps.weight` (the `.ffn_`
   substring check covers it). No predicate change needed.
2. Before encoding a segment that contains a MUL_MAT_ID node, extract the
   expert IDs from the node's `src[2]`. Call the pool's `ensure_experts`
   (via a new `ensure_experts_fn` on the device) to refill the slot with
   just those experts.
3. The 3D weight's `->data` is already aliased to the slot base (from the
   pool's alias step). The slot now contains exactly the active experts,
   packed in the order `src[2]` indexes. The kernel reads `src[0]->data +
   expert_id * stride`, but since only `n_expert_used` experts are in the
   slot (not all 128), the kernel must index by *slot position*, not raw
   expert ID.

This last point is the subtle one: the MUL_MAT_ID kernel uses the raw expert
ID from `src[2]` as an index into the 3D weight's first dimension. If the
slot only contains 8 of 128 experts, the raw IDs (e.g. expert 47) would
index past the slot's bounds. Two options:

**Option A: indirection table.** The pool builds a dense remap
`slot_expert_id_map[n_expert_used]` and the kernel indexes `src[2]` through
this map. This requires a kernel change.

**Option B: full-layer slot, skip-inactive.** Keep the slot sized for the
full layer (1.15 GiB) and accept the memory cost. This defeats the purpose
for large-expert-count models.

**Option C (recommended): pre-scatter into the 3D layout.** The pool allocates
a slot the size of the *full 3D weight* but only fills the active expert
slices (the rest are stale/zero). The kernel indexes by raw expert ID as
normal; inactive experts are never read. The slot is large but sparse.

Option C requires a slot per MoE projection (gate_up + down = 2 projections)
sized at the full 3D weight (1.15 GiB each for Qwen3-30B). That is 2.3 GiB
for both slots — too much for a 16 GiB Mac alongside attention/KV/compute.

**Option D (recommended, refined): per-projection slot with raw-ID layout.**
The slot is sized at `max(n_expert * per_expert_bytes)` across MoE layers
(the full 3D weight size). The fill gathers only the active experts but
places them at their natural offset (`expert_id * per_expert_bytes`). The
kernel indexes by raw expert ID as normal. Sparse fill: only `top_k` slices
are memcpy'd, the rest retain their previous content (which may be stale but
is never read by this batch's kernel invocation).

This works because MUL_MAT_ID only reads the experts listed in `src[2]` —
the stale slices are never touched. The slot is large (1.15 GiB for Qwen3-30B)
but there is only one per projection, double-buffered (2.3 GiB total).

For the 16 GiB M1, 2.3 GiB of IOSurface is feasible alongside ~2 GiB attention
+ KV + compute at low ngl (e.g. ngl=4). The sweep in Part II §10 confirms the
budget.

### 14.5 Memory budget (Qwen3-30B-A3B on 16 GiB M1)

```
2x IOSurface MoE slots:     2.3 GiB  (gate_up + down, double-buffered)
attention (4 layers):       ~0.8 GiB
KV cache (n_ctx=512):       ~0.2 GiB
compute buffers:            ~0.3 GiB
overhead:                   ~0.2 GiB
                            ------
total:                      ~3.8 GiB  (well under 12.4 GiB working set)
```

Contrast with the dense 12B model: 2x 461 MiB = 0.9 GiB for the pool, but
attention for 48 layers at ngl 6 adds ~3 GiB. The MoE model trades more
pool memory for fewer attention layers (only 4-8 offloaded).

### 14.6 Fused vs split MoE

- **Split** (Qwen, Kimi, Minimax, Mistral, AfMoE): three 3D tensors
  (`ffn_gate_exps`, `ffn_up_exps`, `ffn_down_exps`). The pool needs slots
  for all three per layer. With the sparse-fill approach, the slot for each
  is `n_expert * per_expert_bytes`, so three slots double-buffered = 6 slots.
  For Qwen3-30B that is 6 * 0.38 GiB = 2.3 GiB (same as fused, just split
  into more tensors).
- **Fused** (DeepSeek, GLM): one `ffn_gate_up_exps` + one `ffn_down_exps`.
  Two slots double-buffered = 4 slots.

The pool handles this via the `n_block_tensors` query — the streamer reports
all FFN expert tensors per layer, and the pool sizes `max_layer_bytes` to the
sum. For split MoE, this is `gate + up + down` per layer; for fused, it is
`gate_up + down`.

### 14.7 Streamer extension for per-expert fill

The current `llama_weight_stream_layer` copies all of layer L's tensors in one
contiguous memcpy. For the sparse-fill approach (Option D), the pool needs to
copy individual expert slices within a 3D tensor. Add to
`src/llama-weight-stream.h`:

```cpp
// Copy one expert slice of a 3D tensor from the mmap. For a tensor
// "blk.L.ffn_gate_exps.weight" with shape [in_dim, out_dim, n_expert],
// copies expert `expert_idx`'s slice (in_dim * out_dim * sizeof(type))
// into dst at offset `expert_idx * per_expert_bytes`. Returns bytes or -1.
int64_t llama_weight_stream_expert_slice(
    llama_weight_stream_t * stream,
    int32_t layer, uint32_t tensor_index,  // which blk.L.* tensor
    int32_t expert_idx,                     // which expert slice
    void * dst, size_t dst_size);
```

The ANE implementation (`gguf_weight_stream.mm`) already reads per-tensor
slices via `ane_weight_stream_block_tensor`; extending it to read a sub-range
of a 3D tensor is a bounds-check + offset adjustment on the mmap.

## 15. Heterog override for MoE

The existing override in `common/common.cpp` routes `blk.N.ffn_gate.*`,
`ffn_up.*`, `ffn_down.*` to the IOSurface buft. These regexes already match
`ffn_gate_exps.weight`, `ffn_up_exps.weight`, `ffn_down_exps.weight` — the
`.*` suffix covers `_exps`. No override change needed.

However, the same regexes also match tensors that should NOT be streamed:

```
blk.0.ffn_gate_inp.weight     -> matches ffn_gate.* (router — sensitive!)
blk.0.ffn_gate_shexp.weight   -> matches ffn_gate.* (shared expert — OK, dense)
blk.0.ffn_exp_probs_b.weight  -> no match (router bias — safe)
```

The router (`ffn_gate_inp`) is the MoE analogue of `attn_output` — quantizing
or streaming it collapses routing fidelity. It must be excluded from the pool.
Two options:

1. **Tighten the regex** to exclude `gate_inp`:
   `blk\\.[0-9]+\\.ffn_gate(?!_inp).*` (negative lookahead). C++ `std::regex`
   supports ECMAScript syntax by default, so this works.
2. **Pool alias filter**: in `llama_weight_pool_alias_tensors`, skip any tensor
   whose suffix contains `gate_inp` or `exp_probs`. This is the safer option —
   it keeps the regex simple and puts the exclusion logic where the aliasing
   actually happens.

Option 2 is recommended. The pool's alias callback already has the tensor name;
adding a `is_sensitive_moe_tensor(name)` check that returns true for
`gate_inp`/`exp_probs_b`/`gate_tid2eid` (the Part II §8.4 sensitive list)
prevents the pool from aliasing them. These tensors stay on MTL0 (resident),
which is correct — they are tiny (0.1% of params) and must be always-resident
for routing accuracy.

The loader's `select_weight_buft` skip (skip IOSurface for non-FFN) also works
unchanged: the `ggml_backend_ane_iosurface_buffer_check` predicate in
`is_streamed_ffn` matches any FFN tensor regardless of 3D-ness. The sensitive
tensors never get an IOSurface buffer (the pool doesn't alias them), so they
fall through to the normal MTL0 path.

## 16. What does NOT change

- **Per-expert calibration** (Part I-II): the imatrix, regime, GA, writer, and
  L1-L5 machinery are unchanged. The pool is a *runtime residency* mechanism,
  not a *calibration* mechanism. Per-expert calibration runs on CPU/GPU with
  the full (resident or mmap'd) weights; the pool only affects *inference
  residency* during imatrix collection.
- **Kernel**: `ggml_metal_op_mul_mat_id` reads `src[0]->data` by expert ID.
  With Option D (sparse slot), the data pointer is valid for all IDs the
  kernel will actually read. No kernel change.
- **DB / receipts**: unaffected. The pool is transparent to the calibration
  pipeline.

## 17. Phases and gates

**Phase MoE-1 — Sparse-fill pool + streamer (2-3 days).**
Files: `src/llama-weight-pool.{h,cpp}` (expert slot sizing, sparse fill),
`src/llama-weight-stream.{h,cpp}` (per-expert slice), `ggml-metal-context.m`
(MUL_MAT_ID expert extraction before segment encode), `common/common.cpp`
(no change — verify regex matches `_exps`).

Gate: on a MoE model (e.g. Qwen3-30B-A3B bf16), `llama-imatrix --chunks 1
-ngl 4 -ub 512 --device MTL0,BLAS --fit off` completes without OOM, with
`weight streaming enabled: 2x IOSurface` + `MoE expert slot sparse-fill`.
Per-pass time is dominated by the sparse memcpy (top_k * per_expert_bytes
per layer per projection), not the full 3D weight.

**Phase MoE-2 — Fence-based overlap for expert fills (1-2 days).**
Files: same fence plumbing as dense (§Part 1 of the fence-based sync). The
fill thread prefetches the *next* layer's expert set (predicted from the
previous chunk's routing) while the GPU computes the current layer.

Gate: per-pass time improves vs MoE-1 synchronous fill. The prediction
miss rate (experts that were prefetched but not used, or used but not
prefetched) is logged and should be < 15% for steady-state decode.

## 18. Risk: expert prediction for prefetch

Phase MoE-2's fill thread needs to know *which* experts to prefetch for the
next layer. During decode (M=1), the router output is deterministic given the
input — but the fill thread runs ahead of the router compute. Options:

1. **Previous-chunk routing.** Reuse the previous chunk's `src[2]` expert IDs
   as the prefetch hint. Works well for long sequences where routing is
   temporally correlated (common in practice). Miss rate logged.
2. **Popularity-based.** Prefetch the most-frequently-routed experts from
   the imatrix run so far. A small `expert_frequency[n_expert]` histogram
   updated per chunk. The top-k most frequent experts are prefetched.
3. **No prefetch (Phase MoE-1 fallback).** Synchronous fill. Correct, just
   slower. Phase MoE-1 ships with this; Phase MoE-2 adds the prediction.

The recommended path: ship MoE-1 with synchronous fill (correct, measurable
baseline), then add option 1 (previous-chunk hint) in MoE-2 for the overlap.



