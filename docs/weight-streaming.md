# Per-Layer Weight Streaming

**Status: first-class. This is how Tessera runs models larger than the GPU
working-set limit. It is not optional, not experimental, and not a
debug path.**

If you are an agent reading this because something in the streaming
subsystem looked like dead code: it is not. Read §5 before you delete,
narrow, or "simplify" anything named `weight_pool`, `weight_stream`, or
`GGML_USE_ANE`.

## 1. The problem it solves

A 23 GiB unified GGUF cannot be bulk-resident on Apple Silicon. The
single allocation trips `recommendedMaxWorkingSetSize` -- 12.4 GiB on an
M1. The FFN weights dominate: `blk.L.ffn_gate/up/down` is ~450 MiB per
layer across 48 layers, ~21.6 GiB of the total.

Bulk allocation therefore fails outright. Streaming is what makes the
model runnable at all, so the subsystem is load-bearing on exactly the
configuration Tessera targets.

## 2. How it works

Two IOSurface slots, each sized to the largest layer. Every FFN tensor's
`->data` is aliased into one of them. The Metal encoder paces compute one
layer at a time, refilling the active slot from the mmap'd GGUF before
each layer's `MUL_MAT`.

```
  mmap'd GGUF ──llama_weight_stream_layer──▶ slot[L % 2] ──alias──▶ tensor->data
                                                   ▲
                        background fill thread ────┘  (prefetches L+1
                                                       while GPU computes L)
```

Slot reuse across layers `L` and `L+2` is guarded by a GPU sync callback
waiting on the `MTLSharedEvent` signalled at the end of each layer's
command buffer. Two fill paths are live: the background prefetch thread,
and a synchronous fallback inside `ensure_layer` for when the thread is
not running.

Only the active layer's weights need to be resident. Peak footprint is
`2 x max_layer_bytes`, not the model size.

## 3. The pieces

| File | Role |
|---|---|
| `src/llama-weight-pool.{h,cpp}` | 2-slot IOSurface pool, per-layer residency, aliasing, prefetch |
| `src/llama-weight-stream.{h,cpp}` | mmap'd GGUF -> slot refill; forwards to `ane_weight_stream_*` |
| `src/llama-model.cpp` | opens the pool, aliases tensors, attaches to the Metal device |
| `src/llama-model-loader.cpp` | streamed tensor load path |
| `common/common.cpp` | installs the FFN -> IOSurface buft overrides |
| `ggml/src/ggml-ane/` | IOSurface buffer type + the underlying streamer |
| `ggml/src/ggml-metal/` | consumes the IOSurface buft zero-copy at encode time |

## 4. How it is switched on

Two CMake definitions, both required, neither substituting for the other:

1. **`ggml/src/CMakeLists.txt`** -- `target_compile_definitions(ggml PUBLIC
   GGML_USE_ANE)` when `TARGET ggml-ane AND NOT GGML_BACKEND_DL`.
   **PUBLIC is the whole point**: it propagates to `llama` and
   `llama-common`, where the subsystem actually lives. `ggml` itself does
   not use the macro.
2. **`ggml/src/ggml-metal/CMakeLists.txt`** -- `PRIVATE GGML_USE_ANE` on
   `ggml-metal`, which links `ggml-base` rather than `ggml` and so does
   not see the PUBLIC one.

`NOT GGML_BACKEND_DL` is also load-bearing: the streaming code calls
`ane_weight_stream_*` and `ggml_backend_ane_iosurface_buffer_alloc`
directly, so `ggml-ane` must be a linkable library. Under
`GGML_BACKEND_DL` it is a `MODULE_LIBRARY`, which CMake refuses to link
into another target.

Build with:

```bash
cmake -B build -DGGML_ANE=ON -DGGML_BACKEND_DL=OFF
```

Configure prints `ANE weight streaming enabled` when the propagation is
live. If you do not see that line, streaming is off and large models will
fail to allocate.

## 5. How it was disconnected (read this before "cleaning up")

For an unknown period ending 2026-08-13, the entire subsystem compiled to
nothing in every shipped build.

`GGML_USE_ANE` was defined in exactly one place -- `PRIVATE` on
`ggml-metal` -- while a comment three lines above asserted it was "PUBLIC
on the ggml umbrella target". It was not. `PRIVATE` never reaches another
target, so every `#if defined(__APPLE__) && defined(GGML_USE_ANE)` block
in `llama` and `llama-common` was preprocessed away. The macro appeared
zero times in a generated `build.ninja` for a default macOS configure.

The failure was silent by construction: the code still compiled, still
linked, and still ran -- it just ran without streaming, so the only
symptom was that large models could not be loaded, which reads like a
hardware limit rather than a build bug.

It surfaced only when sizing the L5 joint calibration: a 12B BF16 trunk
plus three drafters is a ~29 GB working set on a 17 GB machine, which is
precisely what this subsystem exists to make possible. Recorded as a
high-severity finding in `.zcode/alphaevolve/findings.jsonl`.

**Consequences for anyone editing here:**

- Do not narrow the `ggml` definition to `PRIVATE`. It will compile, and
  it will silently disable everything described above.
- Do not delete it on the grounds that "nothing in ggml uses it". Nothing
  in ggml does. Consumers do.
- Do not assume a guarded block is dead because your build does not
  compile it. Check the configure output for the status line first.
- When editing a `GGML_USE_ANE` block, verify it actually compiles. If
  your configuration does not enable it, a targeted
  `-DGGML_USE_ANE -fsyntax-only` on the translation unit is the minimum.

## 5b. Load-mode interaction: the pool requires a non-mapped load

Found empirically on the first live run (2026-08-13, 12B BF16 trunk,
17 GB M1). With the default `mmap` load mode the pool engaged, excluded
the FFN tensors from loading -- and the model still OOM'd at compute:

    MTL0_Mapped model buffer size = 22712.94 MiB
    allocated 27746.98 / 12124.17 MiB  (recommended max working set)

The mapped path wraps the mmap'd file range containing the Metal-assigned
tensors, and because FFN and non-FFN tensors interleave through the file
layer by layer, `min..max` of the non-FFN tensors spans essentially the
whole model. Metal counts every wrapped byte toward its working set, so
the 16 GiB of FFN data the pool was built to keep out of residency gets
dragged back in by the wrap itself.

With a non-mapped load (`-lm none`), only the non-FFN tensors are
allocated for real:

    CPU  model buffer size =  1920.00 MiB
    MTL0 model buffer size =  6512.24 MiB

and the pool streams the FFN per layer from its own file handle. Both
`common_model_params_to_llama()` and the L5 joint harness now force
`load_mode = none` automatically whenever the pool engages (logged), so
no caller needs to know this. `direct_io` also avoids the wrap and is
left untouched if explicitly chosen.

## 5c. Diagnosing a silent failure: the three tracer lines

A correct run logs all three, in order:

    load_tensors: weight streaming enabled: 2x IOSurface <N> MiB
    load_tensors: weight pool attached to MTL0 -- paced per-layer compute engaged
    ggml_metal_graph_compute_streamed: paced per-layer streamed compute engaged

Line 1 without line 2 means the pool exists but was never attached to
the Metal device -- the encoder will not pace, the slots are never
refilled, and because the loader deliberately skips bulk-loading FFN
tensors, the slots contain ZEROS. The model then runs fast, crash-free,
and wrong. This is not hypothetical: the first live run generated at
2.72 t/s with all-zero FFN because the attach loop matched the device
name against "Metal" while this tree registers Metal devices as "MTL0"
(`GGML_METAL_NAME "MTL"`, ggml-metal.cpp). A wrong-prefix string match
produced silently wrong model output.

Line 2 without line 3 means the pool is attached to a device that never
computes -- also a bug.

The attach path WARNs loudly on every failure mode now (facade dlsym
miss, no matching device, partial attach). If you are debugging this
subsystem, run with `-v` and find the three lines before trusting any
output.

There is a fourth instrument for content integrity:
`TESSERA_STREAM_CHECKSUM=1` re-streams every tensor of a layer from
disk at ensure-return time -- the closest CPU-observable point to
GPU-read -- and memcmps it against the slot bytes, logging one
clean/CORRUPT line per layer fill (raw stderr, so it is visible at any
log level, unlike the tracer lines). It costs one extra full read of
each layer per fill; diagnostic only.

## 5d. What the first live run surfaced (integration bugs in never-run code)

The subsystem had never executed end to end before 2026-08-13, so the
first run peeled failures one at a time. Each is fixed; they are
recorded because each one is a place where the two halves of a seam
were built to different assumptions and nothing could have caught it
without running.

**Fill layout mismatch.** The pool sizes and aliases its slots for the
streamable-FFN subset at subset-packed offsets, but filled them with
`llama_weight_stream_layer()`, which writes the WHOLE block (attention
and norms included) at full-set offsets: "stream_layer: layer 0 total
448329732 bytes > dst 353909760". The streamer's own comment marks the
whole-layer helper as the test-facing API. All three fill paths
(ensure_layer, the fill thread, async prefetch) now stream per tensor
via `ane_weight_stream_block_tensor` from one shared plan; the
whole-layer prefetch wrapper was deleted outright so the trap cannot be
re-trodden.

**Per-layer stream indices.** The layout builder probed layer 0 and
assumed "the streamer uses the same name-sorted order per block" for
every layer. False for SWA/global attention mixes: gemma-4's global
layers (every 6th) carry different attention tensors, shifting every
name-sorted index after them -- layer 5's idx 8 is a 15 KiB norm where
layer 0's idx 8 was the 112.5 MiB ffn_gate. Fill plans are now resolved
per layer BY NAME at pool open, with sizes validated against layer 0's
layout (FFN shapes are layer-invariant; that much of the assumption
held).

**Dangling cmd_buf_last.** The paced path creates its per-layer command
buffers unretained plus one manual retain owned by slot_cb, waits them
inline at graph end, and releases them -- but left `ctx->cmd_buf_last`
pointing at the final (freed) buffer. The next
`ggml_metal_synchronize` -- prompt checkpointing calls it right after
prefill -- did objc_msgSend on the freed object: EXC_BAD_ACCESS with a
pointer-authentication failure. The streamed path now clears
cmd_buf_last at exit; it drains everything inline, so there is nothing
for a later synchronize to wait on.

**ffn_norm streamed by substring.** The streamable filter matched
`ffn_` as a substring, which pulled `ffn_norm.weight` into the slot
layout -- but a norm's READER (the pre-FFN RMSNorm mul) sits before the
layer's first FFN MUL_MAT, i.e. before the segment boundary, so it
executed in the PREVIOUS layer's command buffer, one refill early.
Stale by construction, unfixable by fencing. The filter is now an
explicit allowlist (236efeb18); norms stay resident.

**Dropped graph preamble (the composition killer).** The segmentation
loop reset `seg_start` on EVERY layer boundary, including the first,
while the comment above it promised "the first segment runs from node
0". Everything before layer 0's first FFN MUL_MAT -- the embedding
scale, layer 0's whole attention block, layer 0's ffn_norm -- landed in
no segment: encoded into no command buffer, never executed. Layer 0's
FFN consumed whatever the compute buffer held, and 47 layers amplified
it into garbage that survived every data-path fix and changed flavor
each time one landed. Confirmed fixed by A/B: with the fix, a small
model runs token-identical streamed vs resident (16/16 greedy tokens,
510/510 slot fills verified byte-exact by the checksum probe), and the
12B's paced output left the degenerate regime. seg_start now advances
only when a segment is actually closed.

The general lesson repeats section 5's: none of these were visible in
review, in unit tests, or in the build. They were all cross-component
contract mismatches, and the only thing that finds those is running the
composed system.

## 6. Known gap: the L5 joint calibration harness

`ts_l5_joint_models_load` (`common/tessera-ppl-harness.cpp`) does **not**
benefit from streaming yet. It calls `llama_model_load_from_file` and
`llama_init_from_model` directly, bypassing `common_init_from_params`,
which is where the FFN -> IOSurface buft overrides are installed. It also
takes `llama_model_default_params()` with only `n_gpu_layers = 0`
overridden, and holds all five models for the duration of the search.

So the joint path still needs the full working set resident, and on a
17 GB machine a 12B trunk plus three drafters will thrash rather than
stream.

Closing this means either routing the harness through
`common_init_from_params` -- an ownership change, since
`common_init_result` is RAII-owning while `ts_l5_joint_models` frees raw
pointers -- or extracting the buft-override construction from
`common/common.cpp` into a helper both callers share. The second is
probably the better shape; duplicating the pattern list into the harness
is not.

Every other consumer that goes through `common_init_from_params`
(`llama-cli`, `llama-imatrix`, the server) gets streaming automatically
now that the definition propagates.
