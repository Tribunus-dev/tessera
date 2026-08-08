# Workspace: Tessera on a T2 Intel MacBook (Fedora Linux)

**Date:** 2026-08-06
**Scope:** Technical discussion and findings for running the Tessera fork
(calibrated/audited quantization, T640 ternary, speculative decoding) on a
2020 Apple T2 Intel MacBook Pro running Fedora Linux — CPU and iGPU, with a
focus on zero-copy and CPU/GPU overlap.

This document captures the engineering discussion, hardware constraints, and
the port/rework paths agreed as worth pursuing. It is a live workspace note,
not release documentation.

---

## 1. Host system

| Property | Value |
|---|---|
| OS | Fedora release 44 (Forty Four), x86_64 |
| Kernel | `6.19.12-210.t2.fc44.x86_64` (T2 kernel fork) |
| Machine | Apple T2 MacBook Pro 2020 (13") |
| CPU | Intel Core i5-1038NG7 (Ice Lake, U-series, 4C/8T, 2.0/3.8 GHz) |
| iGPU | Intel Iris Plus Graphics G7 (Gen11, 64 EU) — **no discrete VRAM** |
| RAM | 16 GB (LPDDR4X shared CPU/GPU pool) |
| NVMe | T2-native transport (no USB-boot stick) |
| WiFi / BT | BCM (via `apple_bce`), connected `wlp229s0` |

### Hardware driver status (verified working)
- Touch Bar: display + backlight + keys (`appletbdrm`, `hid_appletb_*`)
- Keyboard / trackpad (Apple internal, `hid_apple`), SMC (`applesmc`)
- Audio: `Apple T2 Audio` (Speaker, Codec Output, Bridge Loopback) + HDMI on PCH
- Backlight (`brightness = 16546/17777`), battery monitoring
- Kernel cmdline flags: `intel_iommu=on iommu=pt pm_async=off` (T2-appropriate)
- Verified: WiFi connected, Bluetooth controller up, NVMe on native transport

---

## 1. Memory: it is shared, not Apple-style unified

- 16 GB soldered system DRAM is shared by CPU + iGPU. The iGPU gets a small
  framebuffer carve-out at boot and borrows the rest of the system RAM on demand.
- **Not** cache-coherent "unified memory" in the Apple Silicon sense — CPU and
  GPU contend on the same ~60 GB/s controller via the ring bus.

### Bandwidth: i5-1038NG7 vs Apple M1
| | i5-1038NG7 | Apple M1 |
|---|---|---|
| Memory | LPDDR4X-3733, 128-bit, ~59.7 GB/s theoretical | LPDDR4X-4266, 128-bit, ~68.25 GB/s theoretical |
| Real-world (STREAM) | ~40–45 GB/s | ~40–50 GB/s |

The M1's real advantage is **latency / efficiency / sustained throughput**, not
the headline bandwidth. Larger M-class (Pro/Max, 200/400 GB/s) are in a
different class entirely.

---

## 2. Inference feasibility on CPU (llama.cpp-class)

- Runs, but bounded by **weight-by-byte bandwidth**, not compute.
- 4C/8T can run a 7B at a few tok/s; AVX-512 helps the decode/unpack compute.
- No usable Metal/ANE for Tessera's fused GPU kernels on this Linux box (see §5).

---

## 3. The CPU: strong AVX-512 for a quantization workload

Ice Lake carries the full **512-bit ISA set**, unusually relevant for
quantization unpacking:

- `avx512f`, `avx512bw`, `avx512dq`, `avx512vl`
- `avx512_vnni` — INT8 dot product (Q4/Q5 Russian matmul)
- `avx512_vpopcntdq`, `avx512ifma` — bit deinterleave for ternary/bitpacked data
- `gfni`, (`vaes`, `vpclmulqdq`) — table-based quant unpack acceleration

Many later laptop AVX-512 parts drop `vpopcntdq`/`ifma`/`gfni`; Ice Lake keeps
them, so quantization **decode** (unpack) is genuinely faster per byte than most
AVX-512 laptops. Decode is compute-bound (unpacking), which is where this shines.

**Ceiling:** decode is still weight-bound — model bytes are read every token,
capped at the ~60 GB/s shared pool.

---

## 4. The Tessera fork — high-level review

Result of a full clone of `github.com/tribunus-dev/tessera` (10,832 commits),
a fork of llama.cpp.

**What it is**
- Not a wrapper — a fork with C++ changes in the llama.cpp tree.
- "Tessera-T640": a per-tensor ternary + outlier quantization policy
  (ternary threshold, outlier fraction, AWQ pre-scalings, per-tensor GA),
  calibrated offline and replayed at runtime; schema-versioned JSONL "receipt".
- First-class speculative decoding (DFlash / DSpark drafter) with telemetry.
- Apple Neural Engine prefill path (actually ANE/Core ML) — **M-series only**.
- Big: ~110 x SYCL files in `ggml-sycl`, heavy T640 references across ggml.

**Licensing (flagged, important)**
- Top-level `LICENSE` = MIT (upstream llama.cpp / ggml).
- `LICENSE-TESSERA` = **PolyForm Noncommercial 1.0.0** for Tessera-authored code
  (quantizer, ANE toolkit, schemas). README gem/badge says "MIT" (misleading).
- Personal patent claims (pending) for some technology.
- Real risk: upstream llama.cpp maintainers push back on noncommercial forks
  for MIT ecosystem; clarify `NOTICE` / `REFERENCES` before upstreaming.

**Review verdict**
Real, above-median effort. Historically the no-editing-squashed history +
non copyrable licensing + some over-strong "bit-identical/audited" claims are
the main concerns. Architecture is sound; verification value needs weights.

---

## 5. T640 ternary quantization on this system (the promising part)

T640 packs ~1.6 bit/weight (4 base-243 digits → per 32-bit word, 20 ternary
values), plus a half-page scale, per-lane scale, sparse **outlier** corrections.

**Why it fits THIS box**: 
- Your bottleneck is **bandwidth**, and T640 is roughly **half the bytes of
  Q4**. On a 60 GB/s shared pool, that's the single biggest lever.
- Decode needs the bit-manipulation ISA you have — `avx512_vnni` (dot),
  `vpopcntdq`/`ifma`/`gfni` (unpack), all present on Ice Lake.

**Honest reservations**
1. **Accuracy is the decision-maker.** Ternary quality must be validated on the
   target model with real calibration; outlier fraction must stay small or the
2-bit story collapses. Recommended action: sanity-run imatrix on a small model.
2. **Do not expect the iGPU to add throughput** — it shares the same memory pool.

---

## 6. Porting the Tessera Metal kernels to Linux / this iGPU

**The fundamental blocker:** the optimized kernels exist only as **Metal**
(Metal Shading Language → MSL). Metal is a macOS-only, Apple-proprietary API.
The `GGML_METAL` backend is `__APPLE__`-gated. On Fedora there is no Metal
driver — the Iris G7 exposes **Vulkan (ANV)** and **OpenGL**, not Metal.

**Kernel backends in the fork:** the T640 kernels exist in **Metal** (and a
partial CPU path). The CUDA / sycl / Vulkan / OpenCL backends do **not** contain
a T640 kernel — grep `tile640` across `ggml-sycl/` is empty.

**Two real options**
1. **Port → Vulkan (`ggml-vulkan`):** port also to the existing Vulkan
   backend. Medium effort.
2. **Port → SYCL / Level Zero (`ggml-sycl`):** Intel-native, fits the G7 via
   Level 0. The port sketch is in §8.

For an off-CPU *decode* effort, a SYCL/L0 kernel is the most natural for an
Intel iGPU (Mesa + compute runtime first-class).

---

## 7. Zero-copy CPU <-> iGPU

**Physical reality:** The G7 has no dedicated VRAM — it reads the same system
DRAM, so any CPU-accessible buffer is already "gpu-visible" at the memory-BUS
level. The only copies in ggmml appear in the **software stack**:
- `ggml-sycl` uses `sycl::malloc_host` + explicit `.memcpy` (a PVC-workaround
  pattern at `ggml-sycl.cpp:1800,2070,2200`).
- It does **not** use SYCL **shared** USM; there's no `usm_shared` allocation
  in the backend.

**The lever:** use `sycl::malloc_shared` (Level 0 "shared" USM) so one
coherent pointer is touched by CPU and GPU with no explicit copies. On a
single Intel iGPU, L0 USM already gives zero-copy within one device — **no
dma-buf needed** for this.

**`dma-buf` (the Linux analog to IOSurface):** yes it exists — buffer export
via `drmPrimeHandleToFd` + import + `syncf` / fences — but it is
IOSurface's *cross-device / cross-process* path. Not required for a
single-iGPU shared allocation.

**Zero-copy here != more bandwidth.** It only removes copy latency, not the
GB/s ceiling; shared pool means GPU+CPU do not get 2× bandwidth.

---

## 8. Hybrid CPU+GPU overlap — the missing piece (Metal events ⇔ SYCL)

Your macOS design used **Metal events** to run CPU and GPU work concurrently
and join at the barrier. Linux equivalent:

**Mechanisms that mirror Metal events:**
- **SYCL `sycl::event` + `out-of-order` queues** — the analog of running
  multiple Metal queues and only waiting on a dependency. `queue.submit(...)`
  returns events; independent kernels can overlap.
- **`sycl::queue::submit_barrier()`** (in `ggml-sycl.cpp`: use of
  `ext_oneapi_submit_barrier()`) — the equivalent of Metal's event
  snapshot/waittime.
- **Host event / host signal**: a CPU thread can block on the SYCL event
  (`event.wait()`) / query — like Metal's event handshake.

**What `ggml-sycl` ACTUALLY does today (the problem):**
- The backend serializes with `.wait()` everywhere (e.g. `ggml-sycl.cpp:797,
  1225, 3134, 3252, 3831, 3870`).
- Result: **CPU enqueues → CPU blocks on GPU → no CPU/GPU overlap.** It is an
  in-order, fully-synchronous pipeline.

**So to recreate the Metal-event overlap you must:**
1. Make the T640 decode ops use an **out-of-order** SYCL queue.
2. Replace dependent `.wait()` with **`submit_barrier()` events** — wait only
   at the point of cross-dependency.
3. Split the graph into a **CPU-bound** (AVX-512 quant unpack / prefill) and
   **GPU-bound** (iGPU) half feeding the same bounded queue.
This means **re-engineering the scheduler**, not flipping a flag.

**Note:** because both use one ~60 GB/s pool, overlap *improves latency* not
aggregate throughput — the split is win for wall-time on prefill+decode, not a
2× decode.

---

## 9. Conclusions / recommended path

1. **Viable machine for Tessera's core idea**: yes—bandwidth-bound, and the
   T640 2-bit-heavy numerical format + full AVX-512 unpack ISA is the strongest
   combination on an x86 laptop.
2. **Do CPU-first.** Use the CPU AVX512 T640 dequant path (already in the
   fork) — it is bandwidth-optimal and the iGPU/Metal work is not needed for
   raw decode speed.
3. **Validate accuracy FIRST** — run imatrix on a small model and confirm the
   outlier budget stays tight. This decides if the rest is worth it.
4. **Hybrid split is the value-add:** SYCL/L0 + shared USM for zero-copy, and
   an **out-of-order event-driven scheduler** to overlap CPU prefill with GPU
   decode. Rebuild `ggml-sycl`'s `.wait()` pattern to achieve it.
5. **Keep the Metal kernels on Apple silicon.** A T640 Metal→SYCL/L0 port is a
   step-change effort; doing it changes per-decode performance on a
   bandwidth-first pool only via better overlap, not more bandwidth.

---

## OpenVINO backend: build status (2026-08-06)
- Configured: `cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_OPENVINO=ON -DOpenVINO_DIR=/usr/lib64/cmake/openvino-2025.1.0`.
- Deps: `opencl-headers` + `OpenCL-ICD-Loader-devel` (NOT `ocl-icd`). OpenVINO 2025.1.0, tbb-devel.
- Builds end-to-end clean (348/348). Runtime registers `OPENVINO0` (15 GiB) ggml backend; `ldd` shows
  libopenvino.so.2510 / libOpenCL.so.1 / libtbb.so.12. The npu_level_zero_backend warning
  ("cannot load libze_loader.so.1") is benign: this T2 has no Intel NPU.
- Fork bugs fixed to build under GCC 16 / libstdc++ 16 + OpenVINO 2025.1:
  1. `common/tessera-debug/tessera-debug.cpp` - missing `#include <math.h>` (fabsf).
  2. `ggml/src/ggml-openvino/ggml-quants.cpp:72/74` - `ov::Tensor(type,shape,const void*)` bound the
     templated `Allocator` overload (A=const void*), not the host-ptr ctor; added `const_cast<void*>`.
  3. `common/speculative.cpp` - uses std::array/vector/unique_ptr/uint16_t with no direct includes
     (relied on libstdc++ transitive includes); added <array> <cstdint> <functional> <memory>
     <string> <utility> <vector>.
  4. `tools/quantize/tessera/tessera-quant.cpp` - `double err` (line 685) vs `float err` (692) name
     clash inside the same loop scope (#if/#else adds no braces); renamed outer var to `err_mse`.
  5. `tools/quantize/tessera/tessera-progress.cpp` - missing `#include <cmath>` (std::isfinite).
`POSITION_INDEPENDENT_CODE ON` so it can link into the shared libllama-quantize-impl.so.
   7. `common/arg.cpp` (`common_tessera_params_parse`): the Tier-2 refactor re-appended
      positional args to the argv handed to common_params_parse, which rejects them
      ("error: invalid argument: <path>"), so `llama-tessera <in> <out> <ftype>` was unusable.
      Fix: do not re-append pos_argv to the argv passed to common_params_parse (the main
      quantize subroutine re-reads the ORIGINAL argv for <input> <ftype> anyway).
   8. `tools/quantize/quantize.cpp` (`llama_quantize`): the refactor's `--model`-required
      check left llama_quantize reading only positional argv[1], conflicting with the flag
      CLI. Fix: recognize `-m/--model <val>` in the flag loop, use it as fname_inp.
 - These are local build-fix patches only (fork is exempt from upstream PR rules); not committed.

## Model baseline (2026-08-06)
- `models/gemma-4-12b-unified-qat/gemma-4-12b-it-qat-q4_0.gguf` - Gemma 4 12B Unified QAT
  official Q4_0 GGUF (google/gemma-4-12B-it-qat-q4_0-gguf), 6.5 GiB, arch `gemma4`,
  328x Q4_0 + Q6_K token_embd + f32 norms/rope. Downloaded via HF CLI (huggingface_hub 1.26.1).
- `models/gemma-4-12b-assistant-q4_0.gguf` - QAT MTP drafter, Q4_0, 308 MiB, arch
  `gemma4-assistant`. Src: google/gemma-4-12B-it-qat-q4_0-unquantized-assistant
  (model.safetensors) -> conversion/gemma.py (fork converter) -> bf16 GGUF ->
  llama-tessera Q4_0 (token_embd at Q6_K per recipe).
- HF CLI + converter deps (transformers, torch, safetensors) installed user-local;
  converter run with `PYTHONPATH=gguf-py`.
- Quantize CLI: `<in> <out> <ftype>` OR `--model <in> <out> <ftype>`. Auto-named `ggml-model-<FTYPE>.gguf` when output omitted.
- Downloading 6-7 GiB files: foreground invocation survives (background nohup/setsid kept
  getting killed around ~322 MiB); use a long bash timeout + resume (`hf download --local-dir`).

 ## TODO / next steps
- [x] Build OpenVINO backend ON (348/348) + remote/USM + async gaps documented (SS 8.1).
- [x] Download Gemma 4 12B Unified QAT Q4_0 + QAT MTP drafter (q4_0). Baseline targets ready.
- [ ] Baseline: run OpenVINO CPU + GPU on the Q4_0 12B + drafter; GGML_OPENVINO_PROFILING;
      measure prefill/decode + where copies remain.
- [ ] Zero-copy weights/IO (host-visible USMTensor for weights/inputs, not just cache_).
- [ ] Async infer (start_async + event) on decode (Metal-event analog).
- [ ] Backend .async registration so ggml-cpu + ggml-openvino overlap under scheduler.
- [ ] Build the fork CPU-only with AVX-512 on Fedora and benchmark a Q4-like
      quant model probe to get a baseline.
- [ ] Sanity-run the ternary calibration (imatrix) on a small model; watch.
- [ ] Sketch `ggml_sycl_mul_mat_tile640` launcher + SYCL kernel skeleton (patch
      to drop into `ggml-sycl.cpp`) if the dir is pursued.
- [ ] If overlap is pursued: split graph into CPU/GPU halves and replace
      `.wait()` with `submit_barrier` events for a hybrid scheduler.