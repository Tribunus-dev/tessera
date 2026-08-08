# Spec: Porting the Apple ANE Optimizations onto the OpenVINO Backend

**Date:** 2026-08-06
**Target:** Tessera OpenVINO backend (Intel GPU / NPU) on Linux
**Status:** Draft / design study. No code written against this spec yet.

## 0. Purpose and scope

The Apple ANE backend (`ggml/src/ggml-ane/`) and the OpenVINO backend
(`ggml/src/ggml-openvino/`) are two accelerator backends in the Tessera fork
that were designed around the same core ideas: shared zero-copy memory, a
stateless graph with the KV cache held by the host, chunked prefill,
low-precision weight matmul, compiled-model reuse, and (ANE only) speculative
decode. Both backends are documented in depth elsewhere:

- ANE: `docs/ane-backend-deep-study.md`, `common/ane-*.mm`,
  `ggml/src/ggml-ane/ggml-ane.mm`
- OpenVINO: `ggml/src/ggml-openvino/*` (a whole-cgraph translator backend)

This document is the feasibility and design spec for re-implementing the
portable portion of the ANE optimization set on the OpenVINO backend for
Intel GPUs / NPUs on Linux, using OpenVINO 2025.1 (`pkg-config --modversion
openvino` -> `2025.1.0`, headers at `/usr/include/openvino`).

### 1.1 Ground truths

1. The two backends are different execution models.
   - ANE is a per-op + per-function executor that talks to Core ML.
   - OpenVINO is a whole-cgraph translator (with a small naive fast path). It
     builds one `ov::Model` per compute and runs `ov::InferRequest::infer()`.
     Every port must be expressed as a graph-level strategy, a compile
     configuration, or an async/scheduling concern - not as a per-kernel
     rewrite.
2. Apple-only primitives cannot be copied and have no exact OV counterpart:
   IOSurface, Core ML `predictionFromFeatures` / multifunction programs,
   `MTLSharedEvent`, Accelerate/NEON, E-core QoS, `NSProcessInfo`. Their OV
   equivalents are, respectively: remote/USM device memory, `ov::CompiledModel`
   per static shape, `ov::InferRequest` completion / callback, `ov::Tensor`,
   OpenVINO threading and CPU affinity.
3. The most valuable ANE optimizations are hardware-agnostic masking overhead -
   zero copy, cache reuse, async overlap, chunked prefill, speculative decode.
   Several already exist on the OV side; this spec closes the gaps.

### 1.2 Gap summary

| ANE optimization | OV backend today | Closing work |
|---|---|---|
| Async two-phase pump + overlap | sync `infer()` only (`utils.cpp:390`) | 4.1 async request pool |
| MTP / DFlash speculative drafting | not implemented at all | 4.4 llama.cpp-level engine |
| Zero-copy shared state plane | present (`ov::Tensor`, `ClContext`) | 4.0 verify/harden |
| Stateless host KV vs stateful | both present | 4.0 |
| Static buckets / chunked prefill | present (NPU) | 4.2 |
| Host dequant + low-bit matmul | present (W4/W8) | out of scope |
| Phase telemetry | present (timers) | 4.0 |
| Weights resident both shared + VRAM | single-device today | 4.6 two-tier residency |
| CPU/iGPU/eGPU shared activation handoff | none (no multi-device) | 4.7 dma-buf buffer |

Sections 4-5 are the design work. Section 2 maps primitives; Section 5 lists
risks that bound the whole effort.

---

## 2. Platform mapping (ANE primitive -> OpenVINO transport)

| ANE / Apple | OpenVINO 2025.1 Linux | Notes |
|---|---|---|
| `IOSurface` shared bytes (CPU/Metal/ANE) | `ov::Tensor` aliasing `tensor->data`; `ov::intel_gpu::ocl::ClContext` + `USMTensor` device buffers | Already implemented (`ggml-openvino-extra.cpp:87-122`, `utils.cpp:826-839`) |
| `MLPredictor.outputBackings` no memcpy | `ov::Tensor(shape, ptr)` I/O, zero copy | Present (`extra.cpp:392-434`) |
| keepalive / re-warm | TTL on compiled-model cache | Harden in 4.4 |
| `MTLSharedEvent` cross-device order | `ov::InferRequest` callback + `start_async` | Port 3.1 |
| GCD `dispatch_async` / semaphore | std::async / atomic flags, async infer | 3.1 |
| E-core pin (`QOS_CLASS_BACKGROUND`) | `pthread_setaffinity_np` to a low-power core | optional |
| per-function static buckets | one `CompiledModel` per static shape | 3.3 |
| ANE fp16 accumulate + fp32 sum | GPU/NPU plugin fp16 handling | not needed on OV |
| `NSProcessInfo.thermalState` | no equivalent; rely on plugin | not needed |
| host `mmap` GGUF weights | `ov::Constant` sharing GGUF data | already zero-copy |

---

## 3. Constraints and risks (read before writing code)

1. **Single device.** The OV backend advertises `get_device_count() == 1`
   (`ggml-openvino.cpp:658-660`). Any pipelining must stay within one device.
2. **Static NPU vs dynamic CPU/GPU.** The static/NPU path disallows
   multi-sequence (`ggml-decoder.cpp:490-494`). Async work should target the
   CPU/GPU dynamic path first; the NPU static path is secondary.
3. **No implicit host/device coherency.** On a discrete iGPU the plugin kernel
   reads must be fenced. Follow the existing `clFinish` pattern
   (`ggml-openvino.cpp:216,401`); do not assume the ANE's hardware coherency.
4. **The plugin scheduler is opaque.** There is no API to query which op ran
   where. Any op-routing must be heuristic plus measurement, as the ANE doc
   warns in its part 1.
5. **Requant policy is Intel-device-tuned** (`ggml-openvino-extra.cpp:220-241`).
   A W4 format tuned for NPUW does not automatically suit iGPU; keep the
   policy keyed to device and revisit per hardware.
6. **0 keep the existing zero-copy paths intact.** New async must reuse the
   `ov::Tensor` extras already present, not force copies (with 3.1's pool in
   place).

---

## 4. Work items

### 4.0 Baseline verification + tests (do first, cheapest)

Trace the execution path end-to-end and annotate the section 2 map against
the live source. Confirm:

- The three compile sites (`utils.cpp:334`, `552`, `754`) route through the
  same remote/host selection.
- The compiled-model cache key / reuse (`graph_key`, `utils.h:19-46`) is
  consistent with preallocating a request pool (4.1).
- The `infer()` call sites (`utils.cpp:390,607,637,772`) that the async
  replacement touches.
- The NPU static path stays untouched.

Deliver a small copy-count unit test asserting that for a host tensor the
`ov::Tensor` aliases `tensor->data` and the I/O map never inserts a copy.
This mirrors and validates the ANE IOSurface zero-copy claim in OV terms.

### 4.1 Two-phase async request pool (biggest lift, largest win)

**Goal:** overlap device inference with CPU graph prep by replacing blocking
`infer()` with `start_async()` + wait. Map the ANE lock-free
pump/consumer model onto OpenVINO's async interface
(`infer_request.hpp:279-308`: `start_async`, `wait`, `wait_for`,
`set_callback`; `compiled_model.hpp:148`: `create_infer_request`).

**Design:**

- Add a per-`decoder_runtime_ctx` request **pool** of N `ov::InferRequest`
  objects created from the single compiled model. Start with N=2 for CPU/GPU,
  N=1 for NPU static. Make N env-overridable (`GGML_OPENVINO_ASYNC_DEPTH`),
  following the existing env-var style (`ggml-openvino-extra.cpp:30-48`).
- Change the synchronous `prefill`/`decode` executes
  (`utils.cpp:607,637`) into:
  1. bind inputs / prep outputs (unchanged, zero copy),
  2. `start_async()`,
  3. return a small completion handle used by the caller.
- The ggml scheduler may prepare the next graph while the inference runs; the
  final `graph_compute` waits with `wait_for(ms)` and falls back to `wait()`.
- `ggml_backend_openvino_synchronize` drains all in-flight handles
  (call `wait()` on every pending request).
- Keep N=1 on NPU to avoid over-committing the single device.
- Update the interface flags at `ggml-openvino.cpp:639-656` (today `async=0`).

**Files/sites:** new request-pool helper; edits in `utils.cpp:607,637,779`;
interface flags in `ggml-openvino.cpp:639-656`.

**Acceptance:** `GGML_OPENVINO_PROFILING=2` trace shows decode overlap and no
CPU stall waiting on an unrelated graph; toggle defaults off, current
synchronous behavior is the reference path.

### 4.2 Static-shape bucket matrix (dynamic-to-static route map)

**Goal:** reproduce ANE's fixed, pre-compiled per-length functions
(`prefill_sN`, `decode`, `dflash`) on OpenVINO so a prompt of any length can
bind to a reusable compile rather than the dynamic model.

**Design:**

- Reuse the existing static (NPU) chunk and two-model (prefill/decode) split
  (`utils.cpp:383-583`).
- Extend that split to CPU/GPU: compile the same translated model as a set of
  static bucket shapes (e.g. token lengths {256,512,1024,2048,L3}), similar
  to the ANE `sequence_buckets`. Compile once, then let the compiled-model
  cache reuse; bind each prompt to the smallest bucket that fits (or the
  existing chunk path if none).
- Leave the dynamic-dimension engine untouched; the bucket is a consumer of
  it, not a replacement.

**Files:** in `utils.*`, reusing the prefill/decode request split.

**Acceptance:** a GPU model compiled once per bucket; a prompt over the
largest bucket uses the chunked path; fewer compiles than the dynamic model
today; parity with NPU or CPU behavior unchanged.

### 4.3 Compiled-model reuse: LRU priority instead of plain FIFO (harden)

**Goal:** close the gap where ANE keeps a model "live" while OV evicts by
plain FIFO.

**Change:** replace the `max_entries=8` FIFO eviction
(`utils.h:88-110`) with an LRU that keeps the working set (decode shapes)
hot and evicts the least-frequently-used, least-recently-compiled buckets
first. Keep the cgraph-shape hash key (`utils.h:19-46`) and per-key mutexes.

**Files:** `utils.h:19-111`, `utils.cpp:200-265`.

**Acceptance:** a long-running server alternating two shapes beats today's
FIFO churn; measured via profiling trace.

### 4.4 MTP / DFlash speculative draft engine (llama.cpp-level, Phase 2)

**Goal:** bring the ANE speculative mechanic (`common/ane-mtp.mm`) to OV.
This is not inside the OV backend; it is a llama.cpp scheduler / processor
that drives multiple `llama_decode` cgraphs.

**Design proposal (needs a separate design document):**

- Port the `ane-mtp.mm` orchestration (draft model, accept/reject, tree
  attention) to a device-neutral draft engine that emits ordinary
  `llama_decode` compute graphs.
- The OV backend only serves the extra graphs from its existing pool, so
  4.1 must land first.
- Confidence gating is a llama.cpp-level concern.

This is a genuine new subsystem; per repo policy it must be discussed and
approved separately from this spec, and 4.1+4.2 are its enabling seeds.

### 4.5 Per-op dispatch policy (optional, lowest priority)

- ANE routes ops ANE/Accelerate/none (`ggml-ane.mm:896-2004`). OV has a
  similar `supports_op` + CPU-fallback gate (`ggml-openvino.cpp`).
- Consider an env (`GGML_OPENVINO_OP_POLICY`) marking cheap elementwise ops as
  CPU to avoid plugin dispatch overhead.

### 4.6 Weight / activation residency across CPU, iGPU, eGPU (two-tier)

**Goal:** resident readonly weights on both shared memory and the eGPU VRAM,
with only activations (and handoffs) crossing the PCIe boundary — the
single biggest win when adding a discrete eGPU.

**Why it is correct.** Weights and activations have opposite economics:

- **Weights (read-mostly, huge, reused every token):** replicate once per
  device into that device's fastest local memory and amortize the one-time
  fill across all tokens. Never read them from the bus per step.
- **Activations (small, per-token, transient):** are the only data allowed
  to cross. Contiguous within one device never move at all.
- **KV cache (read-mostly but grows per token):** keep it on whichever device
  computes attention rather than streaming it.

Encoding this removes the impractical "one coherent buffer for CPU + iGPU +
eGPU" idea. Each device reads its own local copy; the only cross-device bytes
are small activation handoffs.

**Current repo state / reusable infra:**

- Weight -> device-side constant already exists (`create_weight_node`,
  `ggml-decoder.cpp:790-816`; `ov::Constant` sharing GGUF memory,
  `ggml-quants.cpp:768-777`); a device remote/USM copy is already produced
  (`ggml-openvino.cpp:157-168`).
- Layer-level device routing exists for model splits (`is_model_splitted` /
  `-sm` tracking, `utils.cpp:666-716`), giving us a residency vehicle.
- Blocking walls: `get_device_count()==1` (`ggml-openvino.cpp:658-660`),
  and a single OV `ClContext` per process.

**Priority ordering (each behind a `GGML_OPENVINO_*` toggle):**

1. **Enable a second device.** Relax `get_device_count()` and create a second
   `ClContext` for the eGPU using its own imported/owned buffer. Two OV
   instances or one `ov::Core` hosting both; each keeps its own device-local
   tensors.
2. **Per-device weight pinning at load.** When a `ClContext` targets the eGPU,
   resolve each weight `Constant` produced by the `ggml-quants`/decoder
   weight node into an eGPU VRAM tensor at model load, reusing the existing
   remote/USM path (`ggml-openvino.cpp:157-168`). Keep the host/`ov::Tensor`
   for the CPU/iGPU side. This is the literal "resident on both": one load-time
   bound, not a per-token copy.
3. **Residency selection on VRAM capacity.** Use the existing offload
   accounting (`utils.cpp:666-716`) to decide per-layer: hot decoder weights
   + KV resident in the eGPU VRAM; anything that does not fit falls back to
   shared memory and is read over the bus only when the eGPU must touch it.
4. **Shared activation buffer for handoffs.** Allocate the one dma-buf-backed
   buffer (4.7) as the only cross-device channel: CPU/iGPU/eGPU each import
   the same fd; the consuming device reads the produced small activation out
   of it, fenced by dma-buf sync fences. This is the only per-step PCIe
   traffic.

**Acceptance:** model loads once with weights on both shared and eGPU VRAM;
steady-state decode has zero weight reads across the bus; a dev activation
handoff trace (`GGML_OPENVINO_PROFILING=2`) shows cross-device bytes only for
activation-sized transfers. No behavior change with the toggle off.

**Risks:** eGPU VRAM is finite (partial residency fallback); any weights
falling back to shared memory cross the bus when the eGPU touches them;
PCIe bandwidth still bounds handoffs (fenced, not streamed); device
mismatch edges should reuse the existing `-sm` logic rather than a new
regime.

### 4.7 dma-buf shared activation buffer + fence handoff

Goal: the concrete Linux mechanism that lets CPU, iGPU, and eGPU read the
same activation bytes with no copies, and order their accesses without a
single shared queue. This is the IOSurface analog for this system; the
previous "zero-copy" questions resolved to this one buffer as the only
PCIe-crossing payload.

**Design:**

1. Allocate a **dma-buf** fd backed by host memory (`memfd_create` +
   `mmap` for the CPU base pointer = `IOSurfaceGetBaseAddress`; or a DRM
   exported buffer).
2. **CPU view:** `mmap` the fd to a plain pointer (`tensor->data`).
3. **iGPU view:** import the fd into `ov::intel_gpu::ocl::ClContext`
   (`clImportMemoryINTEL` with `CL_MEM_DMA_BUF_HANDLE_INTEL`, the returned
   CL buffer wrapped as an `ov::Tensor`). Hardware-coherent with the CPU
   since the iGPU shares DRAM.
4. **eGPU view:** import the same fd into the eGPU's ClContext as a
   `clImportMemoryINTEL` tensor; it reads the bytes over PCIe.
5. **Ordering instead of `clFinish`** (`ggml-openvino.cpp:216,401`):
   per-device **dma-buf sync fences** (`DMA_BUF_IOCTL_SYNC`) so the consumer
   only reads after the producer's queue empties, rather than relying on one
   device queue.

**Rule (from 4.6):** this buffer carries activations handoffs only; weights
and KV stay local (W1/KV policy). Keep the sizing small (attention outputs,
sampler inputs).

**Acceptance:** a three-device unit test writes one fd from CPU, reads it from
an iGPU OV tensor and an eGPU OV tensor without an intermediate copy; fence
ordering serializes write-before-read. Same bytes / no staging verified by a
checksum.

---

## 5. Sequencing and gates

| Order | Work | Depends on | Risk |
|---|---|---|---|---|
| 0 | 4.0 baseline + tests | none | low |
| 1 | 4.1 async depth | 4.0 | medium (concurrency) |
| 2 | 4.2 buckets | 4.1 | medium |
| 3 | 4.3 LRU | 4.1 | low |
| 4 | 4.4 speculative | 4.1 + 4.2 | high (new subsystem) |
| 5 | 4.5 dispatch policy | none | low |
| 6 | 4.7 dma-buf activation buffer | 4.0 | medium (interop) |
| 7 | 4.6 two-tier residency | 4.7 | medium-to-high (second device) |

Each item lands behind a `GGML_OPENVINO_*` toggle, default off, preserving
today's synchronous behavior as the reference path. Merge only the items the
contributor can explain and debug independently.

Note: 4.6 (second device + weight pinning) is gated on 4.7 (dma-buf buffer)
and, at the ordering wish of the contributor, is the higher-priority hardware
goal even though 4.1-4.5 are ordered first above — the two lists are
independent: 4.1-4.5 are single-device-throughput work; 4.6-4.7 are the
multi-device eGPU path.

---

## Appendix A. OpenVINO version check (used for this spec)

- `pkg-config --modversion openvino` -> `2025.1.0`
- Async surface present at `/usr/include/openvino/runtime/infer_request.hpp`:
  `start_async()` (L279), `wait()` (L285), `wait_for(ms)` (L294),
  `set_callback(...)` (L308).
- `compiled_model.hpp` provides `create_infer_request()` (L148).
- A second install sits under `.pip_openvino/` (Python) and
  `~/.local/lib/python3.14/site-packages/openvino/`; the system
  `/usr/include/openvino` is the build target assumed here.