# XDNA NPU Acceleration for Tessera

Status: design proposal. Owner: tesseracore inference.
Source pull: `.zcode/xdna-research/context7/digest.md` (2026-08-15, 9 libraries,
31 topics). Scaffolding on `main`: commit `10cdefaa3` (M1 device foundation
shipped 2026-08-15).

## 1. Executive summary

AMD XDNA is the AI Engine (AIE) array integrated into AMD Ryzen APUs. Phoenix
and Hawk Point carry XDNA1 (AIE1, 16-tile 4-column array, INT8 only).
Strix Point and Strix Halo carry XDNA2 (AIE2, larger array, native INT8 and
BF16) [xdna1-vs-xdna2]. The NPU is exposed to Linux by the `amdxdna` kernel
driver (accel-class nodes `/dev/accel/accelN`, not DRM render nodes
[xdna-overview]). Userspace has two reasonable execution paths: XRT
(`xrt::bo` / `xrt::kernel` / `xrt::run`, native C++ API, links against
`xrt_coreutil` [xrt-overview]) and the VitisAI ONNX Runtime Execution Provider
[VitisAIEP].

Tessera already has the M1 device foundation: `common/xdna-runtime.{h,cpp}`
opens the first accel node, queries AIE / firmware / clock metadata
[common/xdna-runtime.cpp:50-90], allocates the per-client device-heap BO
[common/xdna-runtime.cpp:324-361] (64 MiB on AIE 1.1, the load-bearing step
that drives `amdxdna_hmm_register` and unblocks later DEV allocations),
exposes SHMEM and DEV buffer objects with `mmap` / `sync` / device-address
accessors [common/xdna-runtime.cpp:471-592], and parses the xclbin2 container
for the shipped artifact [common/xdna-runtime.cpp:594-664]. The bundled
kernel is a single `MLIR_AIE:MLIRAIE` DPU instance (kernel id `0x901`,
standard DPU argument convention `opcode / instr / ninstr / bo0..bo4`) with
HOST (64 MiB DRAM) and SRAM (48 MiB) banks [xdna-kernels-readme].
`common_xdna_context_create` is best-effort; on AIE 1.1 + amdxdna v7.1.y the
firmware rejects heap BOs without DMA mappings
[common/xdna-runtime.cpp:50-90 / xdna-kernels-readme M2 blockers]. There is
no ggml backend yet; the wider `ggml/src/ggml-amd/` tree is dormant.

This spec proposes the path that scaffold should grow into. The two design
axes are: kernel-mode driver boundary (amdxdna UAPI + XRT SHIM
[xdna-ioctl]), and user-mode execution path (XRT native API for direct kernel
calls [xrt-kernel] + a custom ggml-xdna bridge for graph capture, VitisAI ONNX
EP only as a fallback). Wave plan in section 7. Open questions in section 8.

## 2. Hardware target inventory

TBD = pending measurement on real hardware before shipping any wave that
depends on the figure. All numbers are sourced from the public AMD XDNA
architecture spec captured in the digest.

| SoC              | NPU     | AIE gen | AIE array       | TOPS int8  | SRAM (L2)  | AIE tiles | AIE-ML tiles | Notes |
|------------------|---------|---------|------------------|------------|------------|-----------|--------------|-------|
| Phoenix (7040)   | XDNA1   | AIE1    | 4 cols x N rows | ~16-20     | 2560 KB    | 16 (TBD)  | 0            | up to 6 concurrent hwctx [xdna1-vs-xdna2] |
| Hawk Point (8040)| XDNA1   | AIE1    | 4 cols x N rows | ~16-20     | 2560 KB    | 16 (TBD)  | 0            | same silicon as Phoenix; refresh SKU |
| Strix Point (AI 300 12-core) | XDNA2 | AIE2 | larger (TBD) | ~50 (TBD) | 4096 KB | TBD | TBD  | up to 16 concurrent hwctx [xdna1-vs-xdna2]; BF16 native |
| Strix Halo (AI 300 HX)      | XDNA2 | AIE2 | larger still (TBD) | TBD  | 4096 KB | TBD | TBD | same AIE2 gen, larger array; exact cols/rows TBD pending hardware meas |

Column counts (4 for XDNA1) and memory-tile pool sizes (2560 KB / 4096 KB)
are sourced from the digest [xdna1-vs-xdna2]. TOPS and per-tile SRAM are
manufacturer-spec claims that the wave-1 acceptance test must confirm on
each target board. The Strix/Halo distinction ("Point" = 12-core mobile
silicon, "Halo" = 16-core HX with bigger AIE footprint) is real but the
exact AIE geometry split between Point and Halo is TBD in the digest and
needs `common_xdna_device_query` (`DRM_AMDXDNA_QUERY_AIE_METADATA`,
[common/xdna-runtime.cpp:69-79]) to disambiguate at runtime.

## 3. Software stack layers

App (ggml-xdna bridge, llama.cpp graph partitioner)
  |
  | `xrt::kernel(device, uuid, name)` / `xrt::bo(device, bytes, group_id)`
  v
XRT C++ native API (libxrt_coreutil, C++17 required [xrt-overview])
  |
  | `xrt::run::start()` -> ERT command queue; `xrt::bo::sync(dir)`
  v
XRT SHIM library (xdna plugin: maps XRT generic BO/kernel calls onto
amdxdna DRM UAPI; pluggable per device family)
  |
  | `DRM_IOCTL_AMDXDNA_CREATE_BO` / `CREATE_HWCTX` / `EXEC_CMD` /
  | `SYNC_BO` / `GET_BO_INFO` [xdna-ioctl, xdna-buffer]
  v
amdxdna.ko (Linux kernel module; accel-class device at
/dev/accel/accelN; per-`vxdna_hwctx` fence / syncobj / pending-queue /
polling thread [xdna-ioctl])
  |
  | mailbox protocol to the AIE microcontroller (ERT in protected mode);
  | PDI load + spatial-partition PASID update; ERT_CMD_STATE_RUNNING /
  | COMPLETED polled via syncobj [xdna-load-xclbin, xrt-kernel]
  v
AIE array (2D compute + memory tiles; partitionable at column boundaries;
DMA between host DDR and the memory-tile L2 pool [xdna-overview])

The two concurrent paths into the array (VitisAI ONNX EP and direct
xrt::kernel) share the same XRT SHIM and amdxdna layer; they diverge only
at the top. Section 5.5 picks one for Tessera.

## 4. Existing Tessera scaffolding

`common/xdna-runtime.h` declares a small POD-style device API. The struct
shapes (`common_xdna_device_info` with `aie_major/minor`, `fw_*`,
`cols/rows/core_rows/mem_rows/shim_rows`, `npu_clock_mhz`,
`h_clock_mhz`; `common_xdna_bo_kind` enumerating `shmem / dev_heap / dev /
cmd`) are intentionally identical to the `amdxdna_drm_query_*` UAPI so the
device-foundation layer is a thin translation, not a redesigned abstraction
[common/xdna-runtime.h:25-49]. The AMD counterpart of the Apple ANE
sidecar in `ane-mtp.h` [common/xdna-runtime.h:1-15].

`common/xdna-runtime.cpp` ships: device open via the first `accel0..accel7`
that `open()` succeeds on [common/xdna-runtime.cpp:93-105]; full identity
query [common/xdna-runtime.cpp:50-90]; heap BO allocation and mmap that
intentionally drives `amdxdna_gem_obj_mmap -> amdxdna_hmm_register`
[common/xdna-runtime.cpp:319-361]; SHMEM / DEV BO alloc and mmap / sync /
`xdna_addr` accessors [common/xdna-runtime.cpp:471-592]; xclbin2 container
parsing for the shipped artifact only (4-section axlf layout with magic /
cipher / key block / header / in-line section table)
[common/xdna-runtime.cpp:107-189 / 594-664]. Hardware context create is
best-effort [common/xdna-runtime.cpp:427-454]; the heap-DMA blocker on AIE
1.1 + amdxdna v7.1.y means context create cannot be promoted to hard-PASS
until the driver either DMA-maps shmem objects or accepts the ubuf dmabuf
path with a custom mmap [xdna-kernels-readme M2 blockers].

The bundled kernel artifact at
`ggml/src/ggml-amd/xdna/kernels/xdna_kernels.{xclbin,insts}` is one DPU
instance `MLIR_AIE:MLIRAIE` (kernel id `0x901`) with HOST (64 MB DRAM) and
SRAM (48 MB) banks, PDI in the `AIE_PARTITION` section
[xdna-kernels-readme]. The `.insts` is the DPU instruction blob dispatched
through the standard `instr`/`ninstr` argument pair [xdna-kernels-readme].
Bring-up test is `common/test_xdna.cpp` (`bin/test-xdna`)
[xdna-kernels-readme]. Intentionally deferred: PDI load via UAPI, EXEC_CMD
DPU-chain dispatch, `.insts` relocation patching, and the ANE-style
product-seam (`common_xdna_*` counterparts of the five `ane-mtp.h` entry
points consumed by `speculative.cpp` and `tools/server/server-context.cpp`)
[xdna-kernels-readme M2].

## 5. Proposed Tessera integration surface

### 5.1 Tile640 + ANE-style fallback on NPU

The Apple ANE path (Tessera's primary on-Apple product surface) loads a
self-contained `.mlmodelc` from the GGUF, warms it on the E-core, and the
heterogeneous backend offloads a fixed-shape prefill / decode / dflash
function to ANE with a CPU fallback when ANE is unavailable
[common/ane-mtp.h:121-340]. The XDNA path is the AMD counterpart: the
GGUF carries an `xdna` payload (xclbin2 container + matching instruction
blob), `common_xdna_*` loads + warms the kernel (AIE spatial partition +
PDI loaded + mailbox ready), and the heterogeneous backend offloads the
same prefill / decode / dflash functions to the AIE array with the same
CPU fallback shape.

Dispatch rule (which ops belong on NPU vs GPU vs CPU). The default is
"if the op is in the warm function set, try NPU; otherwise ggml native
backend." The NPU is not a general matmul accelerator. Concretely:
- NPU-eligible (v1): matmul with K-major INT8 x INT8 -> INT32 accum;
  RMSNorm / LayerNorm (vector add / sub / mul fused); GELU / SiLU (vec
  ops); softmax (row-wise reduction). AIE2 adds BF16 + INT8 mixed-precision.
- GPU-eligible: large attention prefill with a long context (the AIE SRAM
  pool cannot hold a 64 kV-page window on Strix); grouped-query / paged KV
  reads beyond the NPU partition footprint; ops with shapes that fail
  AIE intrinsic alignment requirements.
- CPU-only: any Q2/Q3 weight tensor (see 5.4); control-flow ops; ops
  inside the speculative-decoding tree that need branching.

Dispatch decision lands at `ggml/src/ggml.c:3320` (`ggml_can_mul_mat`)
and `ggml/src/ggml.c:7539` (`case GGML_OP_MUL_MAT`) by extending the
existing ggml backend-negotiation helper to add an `amd_xdna` backend,
gated on `common_xdna_available() && op_is_warm(program, op_id)`. The
NPU is a backend in the ggml sense (registers
`ggml_backend_xdna::graph_compute`); warm-function lookup is a cache
key, not a per-op graph rewrite.

### 5.2 Buffer model

Three BO types per the digest [xdna-buffer]: `AMDXDNA_BO_DEV` (device-only,
lives in AIE SRAM), `AMDXDNA_BO_SHMEM` (host-shared, mmappable, System RAM),
`AMDXDNA_BO_CMD` (System RAM command buffer). Tessera's per-tensor scratch
maps cleanly: weight tensors are SHMEM BOs that the host writes once at
load time (T640 4-bit packed, see 5.4); activations are SHMEM BOs that
the host stages through; KV-cache tensors are DEV BOs carved from the
device-heap BO owned by `common_xdna_device_open`; the DPU instruction
blob is a CMD BO (or a SHMEM BO with the mailbox protocol's "command"
flavor) that the runtime patches with BO device addresses and submits.

Sync model. Two surfaces are available. The high-level XRT path
(`xrt::bo::sync(dir)` [xrt-bo]) takes an `XCL_BO_SYNC_BO_TO_DEVICE` or
`XCL_BO_SYNC_BO_FROM_DEVICE` flag with optional offset / size and
delegates to the SHIM's DMA. The low-level path is the amdxdna UAPI
itself: `DRM_IOCTL_AMDXDNA_SYNC_BO` with `direction =
SYNC_DIRECT_TO_DEVICE / SYNC_DIRECT_FROM_DEVICE`
[common/xdna-runtime.cpp:577-592]. Tessera's runtime exposes both: the
XRT path for kernels the runtime registers through XRT, the UAPI path
for the `common_xdna_*` device-foundation BOs (the runtime owns the
heap BO and DEV BOs directly, not via XRT, so they cannot go through
`xrt::bo::sync`). Explicit dma-fence is not exposed by the amdxdna UAPI
in the form the digest captured; syncobj handle is returned from
`CREATE_HWCTX` and the runtime can poll `ERT_CMD_STATE_RUNNING /
COMPLETED` on the `xrt::run` handle [xrt-kernel] when using XRT, or on
the driver-side polling thread for direct UAPI submissions [xdna-ioctl].

KV-cache interaction. Tessera carries three KV-cache variants under
`src/`: `llama-kv-cache-iswa.{h,cpp}` (sliding-window attention,
`llama_kv_cache_iswa` [src/llama-kv-cache-iswa.h:14]),
`llama-kv-cache-dsa.{h,cpp}` (DeepSeek sparse attention), and
`llama-kv-cache-dsv4.{h,cpp}` (DeepSeek V4 attention, inherits from
`llama_kv_cache_iswa` and adds `llama_dsv4_comp_state`
[src/llama-kv-cache-dsv4.h:11]). XDNA-feasibility flag:

- `*-iswa` and `*-dsv4`: feasible on XDNA2 only. The 4 MiB L2 SRAM pool
  on Strix fits the per-token KV slice for one head only at typical
  hidden / head_dim; windowed attention keeps the working set bounded.
  Spatial partition size (`num_tiles = num_col * core_row_count`,
  [common/xdna-runtime.cpp:436-442]) caps the concurrent KV pages the
  NPU can hold. AIE1 / Phoenix is rejected: 2.5 MiB SRAM is below the
  working-set floor.
- `*-dsa`: not feasible. DSA's per-row sparsity pattern is data-dependent;
  the AIE array needs static-shape kernels (DPU chain expects pre-built
  instruction blob). Fall back to CPU / GPU.

### 5.3 xclbin packaging

The shipped artifact is one DPU instance `MLIR_AIE:MLIRAIE`
[xdna-kernels-readme]. The first M2 xclbin should be a matmul-only
kernel with shape parameterization at the host side (DPU takes
`M / N / K` as scalar args; the instruction blob carries the data-movement
schedule, not the matmul shape). Vitis AI's DPU pattern packs a graph
into one xclbin; we intentionally diverge because Tessera's per-tensor
calibration story does not match Vitis AI's fixed DPU arch assumptions
[vai-overview, vai-compile]: T640 has per-tensor scale factors that the
graph has to thread through, and the activation-aware AWQ step
(`ts_awq_relative_output_error_device`) lives outside the AIE array.

One op per xclbin vs fused. Matmul + attention + layernorm fused is
attractive (saves AIE-to-AIE DMA for the matmul output feeding the
norm) but breaks the dispatch rule (each ggml op must map to exactly one
NPU kernel so a CPU fallback can replace it). We pick "one op per
xclbin" for v1: matmul, layernorm, attention-prefill, attention-decode
ship as separate xclbin artifacts, all loaded side by side into one
xclbin slot per AIE-generation (one xclbin for XDNA1, one for XDNA2),
and dispatched by name at runtime. Runtime dispatch decision is
`op -> kernel name` table; the table is per-generation and matches the
warm-function set.

### 5.4 Quantization story on NPU

AIE2 native types are INT8 and BF16; AIE1 is INT8 only [xdna1-vs-xdna2,
aie-ml context]. Tessera's T640 packs weights to 4 bits with per-tensor
scale, plus activation-aware AWQ calibration
[tools/tessera/_accelerate.py docstring, ts_awq_relative_output_error_device
referenced from docs/PROJECT-STATUS.md:225]. The intersection with NPU
types:

- INT8 weights (Q8_0 family): NPU-portable on AIE1 + AIE2. Zero
  re-quantization.
- BF16 weights: NPU-portable on AIE2 only. Q4 / Q5 BF16 mixed-precision
  packs to native BF16 with an INT8 multiplier in the loop. Requires
  shape-unrolled kernel variants per group size (T640 uses group 32 by
  default); compile-time explosion is the dominant cost.
- T640 4-bit weights (Q4_0 / Q4_1): CPU fallback only. The DPU does not
  have a native 4-bit datapath; emulating 4-bit on INT8 costs a 2x
  bandwidth multiplier that the AIE SRAM pool cannot absorb. Quark's
  `get_default_config("XINT8")` and `get_default_config("A8W8")`
  [ryzenai-quark] confirm the boundary: NPU quant stops at INT8.

The runtime exposes a per-tensor NPU-eligibility flag derived from the
tensor's quant family + the device's `aie_major`. Dispatch falls back to
CPU when the flag is false; this is the same fallback shape the ANE path
uses for unsupported ops [common/ane-mtp.h:121-340]. Vitis AI's quantizer
snippets show the same boundary: `activation_type=QInt8,
weight_type=QInt8` is the only NPU-portable pair [vai-quant]; per-channel
quantization is rejected (`per_channel=False`); reduce_range is rejected
(`reduce_range=False`) [vai-quant].

### 5.5 ONNX Runtime EP bridge vs custom ggml-xdna EP

Two paths to put ggml graphs on the NPU.

- **VitisAI ONNX Runtime EP.** Mature, ships in
  `ryzen_ai-<version>/voe-4.0-win_amd64/xclbins/phoenix/4x4.xclbin` for
  PHX/HPT [ryzenai-hybrid]. Registration is one line:
  `providers=['VitisAIExecutionProvider']` plus a `provider_options`
  dict carrying `target`, `xclbin`, `cache_dir`, `cache_key` [ort-ep
  reference, ryzenai-onnx-ep]. Allocator surface is
  `OrtValue.ortvalue_from_numpy(x, 'cuda', 0)` and the IO-binding API
  binds / allocates output on the device [ort-allocator]. The
  graph-capture path is CUDA-Graph-shaped (`cuda_graph_.SetStream(...)`
  / `CaptureBegin` / `CaptureEnd` / `ReplayGraph`) [ort-graph]; the
  XDNA analog would lock-step the AIE partition for the duration of the
  captured graph. Cost: every graph partition must be ONNX, and ONNX
  graph optimization is not under Tessera's control.
- **Custom ggml-xdna EP.** Tessera controls graph capture, partition
  policy, and quant-fallback decision. Mirrors the existing `amd_hip`
  backend in `ggml/src/ggml-amd/` (Phase 9 wired `ts_hip_*` helpers in
  [docs/PROJECT-STATUS.md:212-223]). Costs: we own the dispatch glue,
  the BO alloc + xclbin load + EXEC_CMD wiring, and the per-op shape
  negotiation.

Pick: **custom ggml-xdna EP**. Reasoning. VitisAI EP is the right
default for users shipping an ONNX model they did not write. Tessera
owns the graph and the per-tensor calibration; the per-tensor quant
fallback story (5.4) and the Tile640 + ANE-style offload seam (5.1) do
not survive the round-trip through Vitis AI's graph optimization. The
EP-bridge snippets in [ort-ep, ort-allocator] are kept as a reference
for the allocator IO-binding shape when ggml-xdna needs to share a
device buffer with another EP (the VitisAI EP as a fallback partition
inside the same graph), but the primary path is the custom EP.

### 5.6 MLIR-AIE compilation path

The shipped xclbin was built with the MLIR-AIE toolchain
(`MLIR_AIE:MLIRAIE` kernel id `0x901`, [xdna-kernels-readme]). MLIR's
role for us is "compiler from `linalg.matmul` / `linalg.generic` to
PDI", not "compiler from scratch". The affine dialect carries the
tile-and-fuse schedule (`memref` loops with `affine.for` nests and
`affine.apply` linearization [mlir-affine]); the bufferization +
convert-to-llvm pipeline lowers to the AIE objectFifo + `aie.dma_*`
ops [mlir-lowering].

We punt on building xclbins from MLIR for v1. The shipped artifact is
the only M2 kernel; the matmul / layernorm / attention xclbins for
wave 2 onward are built externally with the AMD-provided MLIR-AIE flow
and consumed by Tessera via `common_xdna_xclbin_inspect` (the parser
already handles the standard 4-section axlf layout
[common/xdna-runtime.cpp:107-189]). The host-side glue that patches
buffer device addresses into the DPU instruction blob and submits via
`DRM_IOCTL_AMDXDNA_EXEC_CMD` is the missing piece, and that lands in
wave 2 / 3 alongside the EXEC_CMD dispatch work
[xdna-kernels-readme M2 blockers].

## 6. Build + runtime requirements

Install time.

- XRT runtime package (`xrt`, the open-source stack that interfaces with
  amdxdna [xdna-ioctl]; builds via `xrt/build/build.sh -npu -opt`
  [xdna-version]). Arch packaging: `xrt-plugin-amdxdna`
  (`PKGBUILD-xrt-plugin-amdxdna` [xdna-version]).
- AMDXDNA driver package (separate, built first because the plugin
  depends on it; `PKGBUILD-amdxdna-driver`, installed via `pacman -U`
  [xdna-version]).
- DKMS / kernel headers (`amdxdna_deps.sh` for build-time deps
  [xdna-ioctl]). Out-of-tree build flow is provided as a CMake
  `add_custom_command` template [xdna-version].
- ryzenai-sw optional, only needed for the VitisAI EP fallback path
  (5.5); install via `ryzen_ai-<ver>/install_ryzen_ai_1_4.sh`
  [ryzenai-overview, ryzenai-onnx-ep].

Compile time (for the ggml-xdna bridge and any host code that links
XRT native API).

- Headers: `$XILINX_XRT/include`. Build: `g++ -std=c++17
  -I$XILINX_XRT/include -L$XILINX_XRT/lib ... -lxrt_coreutil -pthread`
  [xrt-overview].
- For AIE-RT consumer builds: `xrt_add_subdirectory_disable_install_target
  (aie-rt/driver/src)` [xrt-xdna]. Links `xaiengine` (xrt_hwemu target
  only [xrt-xdna]).
- Tessera-specific: Linux only (the device-foundation implementation
  uses `<drm/amdxdna_accel.h>` and raw `ioctl()` [common/xdna-runtime.cpp:15]).
  Non-Linux platforms link `common/xdna-runtime-stub.cpp` which returns
  the "no NPU" sentinel values [common/xdna-runtime.h:11-14].

Runtime detection.

- `common_xdna_available()` opens `/dev/accel/accel0..accel7` and reports
  whether the open succeeds [common/xdna-runtime.cpp:293-301].
- `common_xdna_device_query()` returns the identity tuple
  (aie_major/minor, fw_*, geometry, clocks) [common/xdna-runtime.cpp:303-317].
- XRT-side: `xrt::device(0)` returns the first enumerated device; query
  name and BDF via `xrt::info::device::name / bdf` [xrt-device].
- Debugging tools: `dmesg` (kernel + XRT log), `strace`, `lspci`,
  `xrt-smi`, `xclbinutil`; XRT API trace via `xrt.ini` with
  `runtime_log=...` [xrt-device].
- Pre-flight check before any dispatch: confirm `aie_major` matches
  the bundled xclbin (1 for Phoenix / Hawk Point, 2 for Strix); reject
  if mismatched and fall back to CPU / GPU.

## 7. Phased rollout

Each phase ends with an acceptance test on the named hardware. Promotion
between waves is gated on the previous wave's acceptance passing.

- **a) M1 (shipped, commit `10cdefaa3`).** `common/xdna-runtime.{h,cpp}`
  device foundation. Heap BO + identity query + SHMEM / DEV BO alloc +
  xclbin2 container parse + best-effort hardware context create on AIE 1.1
  + amdxdna v7.1.y [xdna-kernels-readme]. Acceptance: `bin/test-xdna`
  PASSes on Phoenix, opening the accel node + heap BO + identity round-trip
  + SHMEM BO host pattern round-trip through `SYNC_BO`
  [common/xdna-runtime.cpp:577-592].
- **b) Wave 2 — single kernel bring-up on Phoenix.** Land PDI-load via the
  amdxdna UAPI (gated on the upstream UAPI revision that exposes it
  [xdna-kernels-readme M2 blockers]); `common_xdna_context_create` promoted
  to hard-PASS by either (i) waiting for an upstream shmem-DMA fix, or
  (ii) adding an internal mmap-capable heap path through the ubuf
  `dma_buf_ops`. Acceptance: a single DPU instruction patch + dispatch
  round-trip on Phoenix with the shipped `MLIR_AIE:MLIRAIE` instance;
  output BO content matches the expected matmul to within rtol.
- **c) Wave 3 — dev/cmd BO + first end-to-end matmul.** Surface
  `common_xdna_bo_alloc(kind=dev)` and `common_xdna_bo_alloc(kind=cmd)`
  in the device-foundation API; wire `DRM_IOCTL_AMDXDNA_EXEC_CMD`; the
  ggml-xdna EP (5.5) registers an `amd_xdna` backend with one op (matmul)
  in `ggml/src/ggml.c:3320 / 7539`. Acceptance: a 1024x1024x1024 INT8
  matmul on the AIE array matches the CPU ggml reference within rtol
  1e-5; `common/test_xdna` extended with a matmul test.
- **d) Wave 4 — attention + KV-cache adapter.** Stand up
  `*-iswa` / `*-dsv4` KV-cache tensors as DEV BOs carved from the device
  heap (5.2); layernorm + attention-prefill + attention-decode xclbins
  land; ggml-xdna EP expands to the warm-function set. Acceptance:
  prefill of one `*-iswa` model bucket on Phoenix matches llama.cpp
  reference logits within rtol 1e-3.
- **e) Wave 5 — Strix Point AIE2 port.** Re-target the dispatch table
  for AIE2 (BF16 + INT8 mixed); add the BF16 quant path; build the
  matmul / layernorm / attention xclbins for AIE2 in the AMD MLIR-AIE
  toolchain. Acceptance: same parity suite as Wave 4 runs on Strix
  Point with the AIE2 xclbins.
- **f) Wave 6 — Strix Halo scaling.** Larger AIE2 footprint; revisit
  spatial-partition sizing (`num_tiles = num_col * core_row_count`
  [common/xdna-runtime.cpp:436-442]); up to 16 concurrent hwctx
  [xdna1-vs-xdna2]. Acceptance: scaled-up parity suite; concurrent
  multi-stream NPU usage does not regress single-stream latency.

## 8. Open questions

- License for XRT. XRT is open-source [xdna-ioctl]; do we need to ship
  XRT headers / libs alongside Tessera, or document a runtime dependency?
- Ship our own xclbin vs consume Vitis AI graphs. Section 5.3 picks
  "ship our own" but the binary size + per-generation rebuild cost is
  not yet estimated.
- Weight format on-device. T640 packed (4-bit weights, per-tensor scale)
  vs unpacked INT8. The hardware-native answer is INT8 (AIE lacks a 4-bit
  datapath, 5.4); the calibration story wants T640 packed. Decision
  drives whether Q4 / Q5 weights are NPU-eligible at all.
- How to surface NPU failures to the user. Three candidate surfaces in
  the agent product (per `AGENTS.md`): `TesseraNotificationBudget`
  (push notifications, hard cap), `ActionAuditLogPanel` (pull-to-open
  side panel, single-sourced), and the diff overlay `AuditLogHeadChip`.
  Dispatch context errors (PDI load fails, `EXEC_CMD` returns
  non-zero) belong in the audit log; user-facing "your NPU is not being
  used" notifications belong in the budget with a new category. Neither
  exists yet.
- Runtime fallback policy. When the NPU is present but the warm-function
  set does not cover the current graph, do we silently use the CPU
  backend, or surface "model X is not NPU-accelerated; using CPU" to the
  user? Silent is the conservative default; explicit is better DX but
  needs an agent-surface decision.
- `num_tiles` selection per workload. The runtime currently sets
  `num_tiles = max(1, core_rows)` [common/xdna-runtime.cpp:439]; whether
  to grow the partition footprint for large matmul workloads, or shrink
  it for many concurrent decode streams, is a policy decision.
- Per-tensor quant metadata on the AIE side. T640 stores per-tensor
  scale at the host. The DPU chain needs that scale as a runtime
  argument; the encoding (u32 fixpos vs fp16 vs int8 multiplier + shift)
  is not yet pinned.
- Tessera model-format payload for the NPU. The `.mlmodelc` analog in
  the XDNA world is the `xclbin + .insts + patch table` triplet. Where
  in the GGUF this lives, how it is keyed (per-model / per-arch), and
  how it is shipped alongside T640 calibration data, is undecided.

## 9. References

All citations are Context7 REST API `/api/v2/context` pulls, Bearer-authenticated,
2026-08-15, cached at `.zcode/xdna-research/context7/`. `out` paths are relative
to that directory.

- `/amd/xdna-driver/xdna-overview` — Context7 pull 2026-08-15, query
  "XDNA driver overview AIE architecture Phoenix Strix Halo".
  Out: `by-library/amd-xdna-driver/xdna-overview.json`.
- `/amd/xdna-driver/xdna-ioctl` — Context7 pull 2026-08-15, query
  "XDNA driver IOCTL interface amdxdna_hwctx xrt::kernel submission".
  Out: `by-library/amd-xdna-driver/xdna-ioctl.json`.
- `/amd/xdna-driver/xdna-buffer` — Context7 pull 2026-08-15, query
  "XDNA driver buffer object drm_gem_object BO allocation EVQF flag".
  Out: `by-library/amd-xdna-driver/xdna-buffer.json`.
- `/amd/xdna-driver/xdna-load-xclbin` — Context7 pull 2026-08-15, query
  "XDNA driver load xclbin AIE partition PDI load_aim".
  Out: `by-library/amd-xdna-driver/xdna-load-xclbin.json`.
- `/amd/xdna-driver/xdna-version` — Context7 pull 2026-08-15, query
  "XDNA driver version 1.4 2.0 amdxdna xdna_mailbox".
  Out: `by-library/amd-xdna-driver/xdna-version.json`.
- `/amd/xdna-driver/xdna1-vs-xdna2` — Context7 pull 2026-08-15, query
  "XDNA1 Phoenix AIE1 XDNA2 Strix Halo AIE2 architecture differences".
  Out: `by-library/amd-xdna-driver/xdna1-vs-xdna2.json`.
- `/amd/ryzenai-sw/ryzenai-overview` — Context7 pull 2026-08-15, query
  "Ryzen AI Software overview installation RyzenAI-SW stack components".
  Out: `by-library/amd-ryzenai-sw/ryzenai-overview.json`.
- `/amd/ryzenai-sw/ryzenai-onnx-ep` — Context7 pull 2026-08-15, query
  "Ryzen AI ONNX Execution Provider VitisAI EP build install".
  Out: `by-library/amd-ryzenai-sw/ryzenai-onnx-ep.json`.
- `/amd/ryzenai-sw/ryzenai-quark` — Context7 pull 2026-08-15, query
  "AMD Quark quantization ONNX model quantization NPU".
  Out: `by-library/amd-ryzenai-sw/ryzenai-quark.json`.
- `/amd/ryzenai-sw/ryzenai-migraphx` — Context7 pull 2026-08-15, query
  "AMD MIGraphX ONNX compile optimization for NPU".
  Out: `by-library/amd-ryzenai-sw/ryzenai-migraphx.json`.
- `/amd/ryzenai-sw/ryzenai-npu-perf` — Context7 pull 2026-08-15, query
  "Ryzen AI NPU performance profiling benchmark IPS".
  Out: `by-library/amd-ryzenai-sw/ryzenai-npu-perf.json`.
- `/amd/ryzenai-sw/ryzenai-hybrid` — Context7 pull 2026-08-15, query
  "Ryzen AI hybrid execution NPU iGPU partition DML DirectML".
  Out: `by-library/amd-ryzenai-sw/ryzenai-hybrid.json`.
- `/xilinx/xrt/xrt-overview` — Context7 pull 2026-08-15, query
  "XRT runtime overview XRT native API C++ API Python API".
  Out: `by-library/xilinx-xrt/xrt-overview.json`.
- `/xilinx/xrt/xrt-bo` — Context7 pull 2026-08-15, query
  "XRT xrt::bo buffer object allocation copy map sync".
  Out: `by-library/xilinx-xrt/xrt-bo.json`.
- `/xilinx/xrt/xrt-kernel` — Context7 pull 2026-08-15, query
  "XRT xrt::kernel run argument xrt::run call".
  Out: `by-library/xilinx-xrt/xrt-kernel.json`.
- `/xilinx/xrt/xrt-xclbin` — Context7 pull 2026-08-15, query
  "XRT xclbin load register xrt::xclbin AIE partition".
  Out: `by-library/xilinx-xrt/xrt-xclbin.json`.
- `/xilinx/xrt/xrt-xdna` — Context7 pull 2026-08-15, query
  "XRT XDNA AIE NPU device ryzenai platform".
  Out: `by-library/xilinx-xrt/xrt-xdna.json`.
- `/xilinx/xrt/xrt-device` — Context7 pull 2026-08-15, query
  "XRT device enumeration xrt::device xclbin NPU ryzenai".
  Out: `by-library/xilinx-xrt/xrt-device.json`.
- `/xilinx/aie_api/aie-intrinsics` — Context7 pull 2026-08-15, query
  "AIE API intrinsics vector mul add broadcast accumulator".
  Out: `by-library/xilinx-aie-api/aie-intrinsics.json`.
- `/xilinx/aie_api/aie-ml` — Context7 pull 2026-08-15, query
  "AIE-ML API intrinsics bf16 int8 matrix multiplication".
  Out: `by-library/xilinx-aie-api/aie-ml.json`.
- `/xilinx/aie_api/aie-dma` — Context7 pull 2026-08-15, query
  "AIE API DMA buffer descriptor lock release acquire" (HTTP 404, no
  usable payload; cited as "no data" in section 5.3).
- `/xilinx/vitis-ai/vai-overview` — Context7 pull 2026-08-15, query
  "Vitis AI overview toolchain compiler quantizer".
  Out: `by-library/xilinx-vitis-ai/vai-overview.json`.
- `/xilinx/vitis-ai/vai-quant` — Context7 pull 2026-08-15, query
  "Vitis AI quantization PTQ QAT DPUCZDX8G vai_q_pytorch".
  Out: `by-library/xilinx-vitis-ai/vai-quant.json`.
- `/xilinx/vitis-ai/vai-compile` — Context7 pull 2026-08-15, query
  "Vitis AI compiler XIR DPU target arch vai_c_xir".
  Out: `by-library/xilinx-vitis-ai/vai-compile.json`.
- `/xilinx/vitis-ai/vai-run` — Context7 pull 2026-08-15, query
  "Vitis AI runtime VART xmodel run on NPU".
  Out: `by-library/xilinx-vitis-ai/vai-run.json`.
- `/xilinx/vitis-ai/vai-arch` — Context7 pull 2026-08-15, query
  "Vitis AI DPU arch DPUCZDX8G DPUCV2DX8G target compilation".
  Out: `by-library/xilinx-vitis-ai/vai-arch.json`.
- `/xilinx/vitis-tutorials/vit-tut-aie` — Context7 pull 2026-08-15,
  query "Vitis tutorials AIE kernel design hello world".
  Out: `by-library/xilinx-vitis-tutorials/vit-tut-aie.json`.
- `/xilinx/vitis-tutorials/vit-tut-dpu` — Context7 pull 2026-08-15,
  query "Vitis tutorials DPU CNN integration".
  Out: `by-library/xilinx-vitis-tutorials/vit-tut-dpu.json`.
- `/websites/kernel_doc_html/kern-dma-buf` — Context7 pull 2026-08-15,
  query "Linux kernel DMA-BUF buffer sharing exporter importer".
  Out: `by-library/websites-kernel-doc-html/kern-dma-buf.json`.
- `/websites/kernel_doc_html/kern-firmware` — Context7 pull 2026-08-15,
  query "Linux kernel firmware request_firmware_release xclbin load".
  Out: `by-library/websites-kernel-doc-html/kern-firmware.json`.
- `/websites/kernel_doc_html/kern-ioctl` — Context7 pull 2026-08-15,
  query "Linux kernel IOCTL unlocked_ioctl file_operations accelerator driver".
  Out: `by-library/websites-kernel_doc_html/kern-ioctl.json`.
- `/microsoft/onnxruntime/ort-ep` — Context7 pull 2026-08-15, query
  "ONNX Runtime Execution Provider interface custom EP append".
  Out: `by-library/microsoft-onnxruntime/ort-ep.json`.
- `/microsoft/onnxruntime/ort-graph` — Context7 pull 2026-08-15, query
  "ONNX Runtime graph capture IGraphBuilder fused".
  Out: `by-library/microsoft-onnxruntime/ort-graph.json`.
- `/microsoft/onnxruntime/ort-allocator` — Context7 pull 2026-08-15,
  query "ONNX Runtime IAllocator IExecutionProvider allocator".
  Out: `by-library/microsoft-onnxruntime/ort-allocator.json`.
- `/websites/mlir_llvm/mlir-affine` — Context7 pull 2026-08-15, query
  "MLIR affine dialect memref loop tile".
  Out: `by-library/websites-mlir-llvm/mlir-affine.json`.
- `/websites/mlir_llvm/mlir-lowering` — Context7 pull 2026-08-15, query
  "MLIR lowering pipeline convert-to-llvm bufferization".
  Out: `by-library/websites-mlir-llvm/mlir-lowering.json`.
- `/websites/mlir_llvm/mlir-aiebuf` — Context7 pull 2026-08-15, query
  "MLIR AIE objectFifo aie.dma_memcpy_nd tile lowering" (HTTP 404, no
  usable payload; cited as "no data" in section 5.6).

Citation short-hands used inline:
- `[xdna-overview]` -> `/amd/xdna-driver/xdna-overview`
- `[xdna-ioctl]` -> `/amd/xdna-driver/xdna-ioctl`
- `[xdna-buffer]` -> `/amd/xdna-driver/xdna-buffer`
- `[xdna-load-xclbin]` -> `/amd/xdna-driver/xdna-load-xclbin`
- `[xdna-version]` -> `/amd/xdna-driver/xdna-version`
- `[xdna1-vs-xdna2]` -> `/amd/xdna-driver/xdna1-vs-xdna2`
- `[ryzenai-overview]` -> `/amd/ryzenai-sw/ryzenai-overview`
- `[ryzenai-onnx-ep]` / `[VitisAIEP]` -> `/amd/ryzenai-sw/ryzenai-onnx-ep`
- `[ryzenai-quark]` -> `/amd/ryzenai-sw/ryzenai-quark`
- `[xrt-overview]` -> `/xilinx/xrt/xrt-overview`
- `[xrt-bo]` -> `/xilinx/xrt/xrt-bo`
- `[xrt-kernel]` -> `/xilinx/xrt/xrt-kernel`
- `[xrt-xclbin]` -> `/xilinx/xrt/xrt-xclbin`
- `[xrt-xdna]` -> `/xilinx/xrt/xrt-xdna`
- `[xrt-device]` -> `/xilinx/xrt/xrt-device`
- `[vai-overview]` -> `/xilinx/vitis-ai/vai-overview`
- `[vai-compile]` -> `/xilinx/vitis-ai/vai-compile`
- `[vai-quant]` -> `/xilinx/vitis-ai/vai-quant`
- `[ort-ep]` -> `/microsoft/onnxruntime/ort-ep`
- `[ort-allocator]` -> `/microsoft/onnxruntime/ort-allocator`
- `[ort-graph]` -> `/microsoft/onnxruntime/ort-graph`
- `[mlir-affine]` -> `/websites/mlir_llvm/mlir-affine`
- `[mlir-lowering]` -> `/websites/mlir_llvm/mlir-lowering`

Source files cited by file:line:
- `[common/xdna-runtime.h]` -> `/home/x/tessera/common/xdna-runtime.h`
- `[common/xdna-runtime.cpp]` -> `/home/x/tessera/common/xdna-runtime.cpp`
- `[xdna-kernels-readme]` -> `/home/x/tessera/ggml/src/ggml-amd/xdna/README.md`
- `[common/ane-mtp.h]` -> `/home/x/tessera/common/ane-mtp.h`
- `[docs/PROJECT-STATUS.md]` -> `/home/x/tessera/docs/PROJECT-STATUS.md`
  (lines 207-258 for the Phase 9 GPU wave context)
- `[src/llama-kv-cache-iswa.h]` ->
  `/home/x/tessera/src/llama-kv-cache-iswa.h`
- `[src/llama-kv-cache-dsv4.h]` ->
  `/home/x/tessera/src/llama-kv-cache-dsv4.h`