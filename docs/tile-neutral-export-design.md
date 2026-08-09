# Tile-Neutral Export + Client-Side Tile Packing

## Design

Separate the tile-NEUTRAL quantization artifact (trits + outliers + AWQ scales, computed
once on the build server with the imatrix) from the tile-SPECIFIC packing (grouping trits
into pages/lanes, computing per-page/lane scales, packing radix-243 words, done on the
client at download time for the detected GPU's optimal geometry).

The trit + outlier + AWQ-scale decision is expensive (imatrix calibration, AWQ grid
search, residual top-k). The tile packing is cheap (O(n) regrouping + scale fit, no
forward passes, no quality loss — the trits don't change).

## Why this works (verified from the code)

`ts_quantize_2d` (tools/quantize/tessera/tessera-quant.cpp) ALREADY separates these:

  Step 1: AWQ scale search      (:925-934)  -> wscale[c], input_scale[c]   [tile-neutral]
  Step 2: fused ternarize       (:951-971)  -> ws, ternary, global_amp     [tile-neutral]
  Step 3: outlier select        (:974-980)  -> outlier_flat (residual top-k, [tile-neutral]
                                               global threshold, then zero trits)
  --- seam: everything below is tile-specific ---
  Step 4: ts_pack_tile640       (:982-989)  -> packed words (640x32 pages) [tile-specific]
  Step 5: ts_compute_scales     (:991-994)  -> page_scales, lane_scales   [tile-specific]
  Step 6: CSR build             (:996-1014) -> outlier_row_offsets/cols/vals [tile-neutral!]

The trit DECISION (step 2-3) uses `global_amp = mean(|ws|)` over the WHOLE tensor —
NOT per-page. So the trits + outliers are invariant to the tile geometry. Only steps 4-5
(the page/lane grouping + scale fit) bake in the 640x32 geometry.

The outlier CSR (step 6) is indexed by absolute (row, col) and stores f16 scaled weights —
also tile-neutral. It travels with the trits unchanged across tile geometries.

## The tile-neutral artifact (.tn640 / safetensors)

For each weight matrix W[out_dim, in_dim]:

  trits           : int8[out_dim * in_dim]   # -1/0/+1 per element (outliers zeroed)
  outlier_cols    : int32[nnz]               # column index per outlier (absolute)
  outlier_row_offsets : int32[out_dim + 1]   # CSR row pointers
  outlier_vals    : f16[nnz]                 # AWQ-scaled weight at each outlier
  awq_scale       : f32[in_dim]              # per-input-channel AWQ scale (wscale[c])
  awq_input_scale : f32[in_dim]             # AWQ input scale (for activation quant)
  act_scale       : f16[in_dim]              # per-input-channel activation scale (if alpha > 0)
  global_amp      : f32                      # whole-tensor mean(|ws|), the ternary threshold

That's 1 byte/element for the trits + a sparse outlier side-channel + a per-channel scale
vector. For a 35B model this is roughly the size of the BF16 weights divided by 2 (trits
are 1 byte vs BF16's 2 bytes, plus the sparse outliers which are a few % of elements).

This is what gets uploaded to the HuggingFace repo (tribunus-dev).

## The client-side tile packer (Tessera Studio)

At download time, Tessera Studio:
  1. Detects the GPU family (Apple7/8/9/10, Intel Xe-HPG/Xe2, etc.)
  2. Selects the tile geometry (T640, T512, T1024, or a future variant)
  3. Runs the packer: trits + outliers + scales -> the 5 GGUF sub-tensors

The packer reuses the EXISTING packing + scale-fit functions, just parameterized:
  - ts_pack_tile640  -> ts_pack_tile(trits, config.page_size, config.lane_size, ...)
  - ts_compute_scales -> ts_compute_scales(core, trits, config, ...)

No imatrix, no AWQ search, no forward passes. Pure regrouping + arithmetic.

## Files to change

### Phase 1: tile-neutral export mode (build server)

1. tools/quantize/tessera/tessera-quant.h
   - Add ts_quant_result_neutral struct (trits, outlier CSR, AWQ scales, global_amp)
   - Add ts_quantize_2d_neutral() — runs steps 1-3 + 6 of ts_quantize_2d, skips 4-5
   - Add ts_export_neutral_safetensors() — writes the .tn640 safetensors

2. tools/quantize/tessera/tessera-quant.cpp
   - Refactor ts_quantize_2d to call ts_quantize_2d_neutral then ts_pack_neutral_to_tile640
     (split at the seam; the existing function becomes a thin wrapper)
   - Implement ts_quantize_2d_neutral (extract steps 1-3, 6)
   - The packing (steps 4-5) becomes a separate function callable on the neutral artifact

3. tools/quantize/tessera/tessera-gguf-writer.cpp
   - Add ts_export_neutral() entry point that iterates tensors and calls the safetensors writer

4. tools/quantize/quantize.cpp (or llama-tessera)
   - Add --export-tile-neutral flag: produces .tn640 safetensors instead of GGUF
   - Routes to ts_quantize_2d_neutral + ts_export_neutral_safetensors

### Phase 2: runtime tile-config struct

5. ggml/src/ggml-common.h
   - Add struct ts_tile_config { int page_size; int lane_size; int lanes_per_page;
     int words_per_page; enum ts_packing_kind { TS_PACK_RADIX243, TS_PACK_2BIT } packing; }
   - Add ts_tile_config_t640(), ts_tile_config_t512(), ts_tile_config_t1024() constructors
   - Keep the existing #defines as the values the constructors return

6. tools/quantize/tessera/tessera-quant.cpp
   - Parameterize ts_pack_tile640 and ts_compute_scales to take a ts_tile_config
   - The existing TS_PAGE_SIZE etc. become ts_tile_config_t640() values
   - This unblocks per-tile packing on the client

### Phase 3: client-side tile packer

7. tools/quantize/tessera/tile-packer.cpp (NEW)
   - ts_pack_neutral_to_gguf(neutral_artifact, tile_config, gguf_out)
     Reads trits + outliers + scales, groups into pages/lanes per tile_config,
     computes page/lane scales, packs words, writes the 5 GGUF sub-tensors
   - Reuses ts_pack_tile (parameterized) + ts_compute_scales (parameterized) from Phase 2
   - GPU-family detection: probe via ggml_backend_dev (Metal supportsFamily, etc.)
     -> select tile_config

8. tools/quantize/quantize.cpp (or a new llama-tessera subcommand: pack)
   - `llama-tessera pack --in model.tn640 --out model-t640.gguf --tile t640`
   - `llama-tessera pack --in model.tn640 --out model-t512.gguf --tile t512`
   - `llama-tessera pack --in model.tn640 --out model.gguf --tile auto` (detect GPU)
   - This is what Tessera Studio invokes at download time

### Phase 4: loader support for non-640 tiles (if Phase 2/3 produce them)

9. src/llama-model.cpp:3205
   - Replace hardcoded `pages_per_row = (row_width + 639) / 640` with a runtime read
     from GGUF metadata (e.g. `t640.page_size`, `t640.lane_size` KV pairs)
   - The loader must know the tile geometry the GGUF was packed with

10. ggml/src/ggml-quants.c (dequant + matmul kernels)
    - The kernel dispatch currently hardcodes TILE640_* constants; to support T512/T1024
      GGUFs at runtime, either (a) compile separate kernel variants per tile and dispatch
      on a metadata flag, or (b) parameterize the kernels (more invasive)
    - For Apple-Si-only initial deployment, T640-only is fine; the loader change (#9)
      alone lets the format carry its geometry for future variants

### Phase 5: regime router integration

11. The regime router (per-GPU kernel-dispatch tuning) already exists for T640. When
    multiple tile geometries are supported, the router picks not just the kernel path
    (accel vs scalar) but also validates the GGUF's tile matches the GPU's optimal one.
    If mismatched, suggests re-packing. (This is the "regime router tuned for the system"
    part — it lives in the runtime, not the format.)

## Threshold strategy (design decision)

The current offline exporter uses `global_amp = mean(|ws|)` over the whole tensor as the
ternary threshold — tile-neutral by construction. The ggml row quantizer uses per-page
`mean(|x|)` — tile-dependent.

Decision: the tile-neutral export uses the OFFLINE exporter's global-threshold approach
(already in ts_quantize_2d). No change needed — the global threshold is what makes the
artifact tile-neutral. The client packer does NOT recompute the threshold; it respects
the trits as-decided and only recomputes the page/lane SCALES (which are a pure function
of the trit values + the tile grouping).

This means: same trits + outliers + AWQ scales regardless of tile. Different page/lane
scales + word packing per tile. Quality is identical across tile variants (the trits are
the same); only throughput/memory-access-pattern differs.

## What this enables

- tribunus-dev HuggingFace repo ships ONE .tn640 artifact per model (tile-neutral)
- Tessera Studio downloads the .tn640, detects the GPU, packs to the optimal GGUF tile
- No client-side imatrix calibration, no AWQ search, no forward passes
- Per-GPU-family tile optimization (Apple T640, Intel T512/T1024, future Apple variants)
- The packing step is seconds-to-minutes, not the hours calibration takes
- Regime router tunes the kernel dispatch per-system at runtime

## Scope for initial implementation

Phase 1-3 (export + packer) is the minimum viable feature: ship .tn640, pack to T640 on
the client. This validates the round-trip (export -> safetensors -> pack -> GGUF -> load
-> inference) without yet supporting multiple tile geometries (the packer produces T640
from the neutral artifact, same as today, just split into two steps).

Phase 2 (tile-config struct) + Phase 4 (loader/kernel multi-tile) is what enables actually
shipping different tiles to different GPUs. This is where the per-generation Apple
investigation would plug in — once we know M4 wants a different page size, we add a
ts_tile_config_apple10() and the packer produces it.

Phase 5 (regime router) is the runtime polish.

## Verification

1. Round-trip test: BF16 -> ts_quantize_2d_neutral -> .tn640 -> ts_pack_neutral_to_gguf(T640)
   -> load -> inference logits. Compare against the current single-step ts_quantize_2d ->
   GGUF -> load -> inference. Logits must match bit-for-bit (same trits, same scales, same
   outliers — only the code path differs).
2. Multi-tile test: once Phase 2 lands, .tn640 -> T640 GGUF vs .tn640 -> T512 GGUF. Both
   load and run; quality is identical (same trits); throughput may differ.
3. The existing test-tessera-quants.cpp asserts T640 round-trip error bounds; the
   tile-neutral path must satisfy the same bounds.
