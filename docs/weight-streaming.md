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
