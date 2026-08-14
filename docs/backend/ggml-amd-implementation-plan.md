# ggml-amd First-Class Backend Implementation Plan

Status: Architect-approved direction, implementation not started

Date: 2026-08-13

## 1. Objective

Build `ggml-amd` as the single AMD platform backend for Linux systems that combine an AMD CPU, one or more AMD GPUs, and an AMD XDNA NPU. The public backend owns device discovery, graph-visible memory, synchronization, scheduling, residency, provider selection, packing caches, metrics, and configuration. HIP, Vulkan, ZenDNN, and XDNA remain internal compute providers whose implementations are reused rather than copied.

The target is Apple-platform architectural parity, not an attempt to make unrelated hardware behave identically. On Apple, CPU, Metal, ANE, IOSurface, shared events, residency, and the GGML scheduler form the platform. On AMD, the corresponding platform is CPU, HIP, XDNA, dma-buf, provider fences, residency, and the GGML scheduler. Vulkan is retained as a compatibility and validation provider.

This plan supersedes the monolithic source-copy direction and public `GGML_TYPE_TILE_AMD` proposal in `docs/backend/AMD.md`. That document remains useful as a record of the original investigation until it is rewritten or marked historical in the first implementation wave.

## 2. Binding decisions

1. dma-buf is first-class from the first working milestone. Every graph-visible allocation that may cross provider boundaries has a dma-buf identity from creation or import.
2. HIP is the primary AMD GPU compute provider when the runtime probe and operation probe succeed. Vulkan is not the default compute path on a HIP-capable Radeon device.
3. `ggml-amd` is one registry, device model, memory contract, scheduler, configuration surface, and observability surface. It is not a new copy of HIP, Vulkan, ZenDNN, or XRT.
4. Provider-private scratch memory is allowed. It must not silently become graph-visible or cross a provider boundary.
5. The scheduler assigns regions, residency, and state ownership. It does not choose a provider independently for every cheap node.
6. KV state has one home provider during steady-state decode unless an explicit migration plan proves a net benefit.
7. XDNA executes compiled coarse regions. It is not presented as a generic low-latency implementation of every GGML operation.
8. The tile-neutral safetensors artifact is canonical. Provider packing is an internal cache product, not a public AMD tensor type.
9. Existing direct CPU, HIP, Vulkan, ZenDNN, and OpenVINO builds remain available as test oracles until the AMD facade meets its parity gates.
10. FastFlow and distributed execution are out of scope. They solve a separate problem from local CPU, GPU, and NPU composition.
11. CK or AITER kernels may be added behind the HIP provider after profiling proves a gap. They are not part of the control plane and are not copied into the initial backend.
12. No direct provider is retired, hidden, or removed until the replacement path passes its functional, numerical, scheduling, and performance gates.

## 3. Known host baseline

The initial bring-up system is a Minisforum UM790 Pro with:

- AMD Ryzen 9 7940HS, 8 cores and 16 threads, Zen 4, AVX-512, VNNI, and BF16 support.
- Radeon 780M iGPU, PCI device `1002:15bf`, architecture `gfx1103`, using `amdgpu`.
- ROCm 7.1.1 and HIP 7.1 installed on Bluefin/Fedora 44.
- Successful native HIP device allocation, memset, device-to-host copy, synchronization, and free.
- `/dev/dri/renderD128` and `/dev/dma_heap/system` present.
- In-tree, signed `amdxdna` driver and Phoenix `1502_00` firmware present.
- UM790 Pro IPU currently disabled in firmware, so the host exposes `1022:14ec` dummy functions instead of the supported Phoenix NPU device `1022:1502`.
- Secure Boot disabled.

The host baseline makes CPU plus HIP the first executable platform. XDNA provider work can compile before the firmware change, but device execution cannot pass until `IPU Control` is enabled in UEFI and `/dev/accel/accel0` exists.

## 4. Scope

### 4.1 In scope

- One `GGML_AMD` build option and one `ggml_backend_amd_reg()` registry.
- AMD CPU, integrated GPU, discrete GPU, and XDNA NPU discovery.
- First-class dma-buf allocation, import, mapping, lifetime, and synchronization.
- HIP-first GPU execution with native events and external-memory interoperability.
- Vulkan fallback and differential-validation execution.
- Generic CPU execution plus optional ZenDNN matmul acceleration.
- XDNA/XRT compiled-region execution.
- Region formation, cost modeling, scheduling, and stable state placement.
- Tiered residency for UMA, discrete VRAM, system memory, and NPU-visible memory.
- Tile-neutral artifact loading and provider-specific runtime packing caches.
- T640 semantic operation parity on HIP before any new AMD-specific packing is considered.
- Metrics, debug dumps, deterministic routing, tests, benchmarks, and CI.
- Linux-first implementation with no regression to existing macOS behavior.

### 4.2 Out of scope

- Distributed inference, TCP fabrics, MPI, FastFlow DFF, or multi-host collectives.
- A public `GGML_TYPE_TILE_AMD` or an architecture-specific canonical model artifact.
- Replacing all provider code with a common lowest-level kernel language.
- Treating pageable migration as a substitute for explicit residency policy.
- NPU training.
- Per-node NPU routing.
- Deleting upstream-compatible direct backend build modes.
- Equal numerical throughput or power behavior across fundamentally different Apple and AMD hardware.

## 5. Target architecture

```text
                         ggml_backend_amd_reg()
                                    |
                   +----------------+----------------+
                   |                                 |
            physical devices                 AMD-HETERO policy
                   |                                 |
        +----------+----------+                      |
        |          |          |                      |
      CPU        GPU(s)      NPU                     |
        |          |          |                      |
   CPU/ZenDNN  HIP/Vulkan  XRT/amdxdna               |
        |          |          |                      |
        +----------+----------+----------------------+
                           |
                dma-buf allocation contract
                           |
                  fence and ownership graph
                           |
             region scheduler and residency manager
                           |
              neutral tensors and packing cache
```

The registry presents stable AMD device identities. `AMD-HETERO` is a policy layer over physical devices, not a fictitious memory device. Applications may still select an individual physical device for diagnosis or deterministic single-provider execution.

## 6. Proposed source layout

```text
ggml/include/ggml-amd.h

ggml/src/ggml-amd/
  CMakeLists.txt
  ggml-amd.cpp
  ggml-amd-registry.cpp
  ggml-amd-device.cpp
  ggml-amd-probe.cpp
  ggml-amd-config.cpp

  ggml-amd-buffer.cpp
  ggml-amd-dmabuf.cpp
  ggml-amd-fence.cpp
  ggml-amd-residency.cpp

  ggml-amd-region.cpp
  ggml-amd-scheduler.cpp
  ggml-amd-cost-model.cpp
  ggml-amd-cache.cpp
  ggml-amd-metrics.cpp

  providers/
    ggml-amd-provider.h
    ggml-amd-cpu.cpp
    ggml-amd-hip.cpp
    ggml-amd-vulkan.cpp
    ggml-amd-zendnn.cpp
    ggml-amd-xdna.cpp

  tile/
    ggml-amd-tile-ref.cpp
    ggml-amd-tile-hip.cu
    ggml-amd-tile-vulkan.comp

  xdna/
    ggml-amd-xdna-translate.cpp
    ggml-amd-xdna-op-table.cpp
    ggml-amd-xdna-compile.cpp
    ggml-amd-xdna-cache.cpp
```

The current copied Vulkan and ZenDNN sources under `ggml/src/ggml-amd/` are transitional scaffolding. The implementation must depend on reusable provider targets or adapters, then remove the copies after parity tests prove the replacement.

## 7. Public and internal API design

### 7.1 Public header

Add `ggml/include/ggml-amd.h` with the smallest stable surface needed by applications:

```c
GGML_BACKEND_API ggml_backend_reg_t ggml_backend_amd_reg(void);
GGML_BACKEND_API bool ggml_backend_is_amd(ggml_backend_t backend);
GGML_BACKEND_API bool ggml_backend_dev_is_amd(ggml_backend_dev_t device);
```

Backend selection, physical device enumeration, buffer selection, and ordinary execution continue through the generic GGML backend API. AMD-specific query functions should be exposed through `get_proc_address` until a use case proves that they belong in the public ABI.

### 7.2 Provider contract

Define an internal provider table that separates the AMD control plane from execution engines:

```cpp
struct ggml_amd_provider_i {
    const char * name;
    bool (*probe)(ggml_amd_provider *, ggml_amd_probe_result *);
    bool (*supports_op)(ggml_amd_provider *, const ggml_tensor *);
    bool (*supports_import)(ggml_amd_provider *, const ggml_amd_allocation *);
    ggml_status (*import_allocation)(ggml_amd_provider *, ggml_amd_allocation *, ggml_amd_import *);
    void (*release_import)(ggml_amd_provider *, ggml_amd_import *);
    ggml_status (*submit_region)(ggml_amd_provider *, const ggml_amd_region *, ggml_amd_fence *);
    ggml_status (*wait_fence)(ggml_amd_provider *, const ggml_amd_fence *);
    void (*query_memory)(ggml_amd_provider *, ggml_amd_memory_info *);
};
```

The exact names may change to match surrounding code, but the separation is required. Provider adapters must not own global scheduling policy.

### 7.3 Device identities

Use stable names derived from provider-independent hardware identity:

```text
AMD0-CPU
AMD0-IGPU
AMD1-GPU
AMD0-NPU
AMD-HETERO
```

Store PCI domain, bus, device, function, vendor/device ID, DRM render node, HSA UUID when available, XDNA device ID, NUMA node, and a provider capability fingerprint. Do not key persistent caches by enumeration order alone.

## 8. Build-system integration

Add the following options to `ggml/CMakeLists.txt`:

```text
GGML_AMD                 Enable the AMD platform backend
GGML_AMD_HIP             Build the HIP provider
GGML_AMD_VULKAN          Build the Vulkan compatibility provider
GGML_AMD_ZENDNN          Build the optional ZenDNN CPU provider
GGML_AMD_XDNA            Build the XDNA provider
GGML_AMD_METRICS         Enable detailed provider and transfer metrics
```

Default policy on Linux:

- `GGML_AMD=OFF` until the backend reaches the production gate.
- When `GGML_AMD=ON`, detect HIP and enable it when usable.
- Enable Vulkan only when requested or when HIP is unavailable.
- Enable ZenDNN only when requested and found.
- Enable XDNA only when XRT headers and libraries are found.
- Fail configuration when `GGML_AMD=ON` and the required Linux dma-buf data plane is unavailable. This invariant is not user-disableable.

Add `ggml_add_backend(AMD)` to `ggml/src/CMakeLists.txt`. When AMD is built, direct providers still compile as reusable targets, but `ggml-backend-reg.cpp` registers only the AMD facade by default. A test-only option may register both the facade and direct providers for differential testing.

Do not glob or copy Vulkan into AMD. Refactor the HIP and Vulkan targets only as far as required to expose provider construction and external-buffer import while retaining their existing direct registry entry points.

## 9. First-class dma-buf data plane

### 9.1 Allocation object

The graph-visible allocation object carries the cross-provider identity and lifetime:

```cpp
struct ggml_amd_allocation {
    int dma_buf_fd;
    size_t size;
    size_t alignment;
    void * cpu_mapping;
    ggml_amd_memory_domain domain;
    ggml_amd_coherency coherency;
    ggml_amd_fd_ownership fd_ownership;
    ggml_amd_import_cache imports;
    ggml_amd_fence last_writer;
    uint64_t generation;
};
```

The implementation must preserve the existing `ggml_backend_buffer_i` contract. Tensor offsets are subranges of an allocation. One fd per tensor is forbidden unless a provider requires isolated objects and profiling proves the cost acceptable.

### 9.2 Memory domains

Support three initial domains:

1. `SHARED_SYSTEM`: Allocate through `/dev/dma_heap/system`, map on the CPU, and import into HIP, Vulkan, and XDNA when supported.
2. `GPU_LOCAL_EXPORTABLE`: Allocate an AMD GEM buffer in the preferred GPU heap and export it through DRM PRIME. Use this for discrete-GPU resident weights or scratch that must occasionally cross a boundary.
3. `PROVIDER_PRIVATE`: Allocate through HIP, Vulkan, or XRT for scratch that never becomes graph-visible.

Also accept `IMPORTED_EXTERNAL` dma-buf objects with explicit fd ownership, size, alignment, and synchronization requirements.

### 9.3 Mandatory allocation spike

Before higher-level backend work, implement a standalone test that compares two candidate producers:

- System dma-heap fd imported into HIP external memory, Vulkan external memory, and the XDNA registration UAPI.
- AMD GEM allocation exported through PRIME and imported into the same providers.

Measure allocation latency, mapping latency, import latency, CPU bandwidth, HIP bandwidth, synchronization overhead, and failure behavior. The result selects the default UMA allocator. Both paths may remain because discrete VRAM and system memory have different residency needs.

Do not weaken the dma-buf contract if the system-heap path fails in one provider. Change the producer or domain while preserving dma-buf as the graph-visible identity.

### 9.4 CPU access

CPU mapping must:

- Use `DMA_BUF_IOCTL_SYNC` start/end around CPU access when required.
- Wait for the last non-CPU writer before exposing readable memory.
- Publish a new writer fence after CPU mutation.
- Track read, write, and read-write intent.
- Avoid redundant map/unmap cycles for persistently mapped coherent UMA buffers.

### 9.5 Lifetime rules

- The allocation owns or duplicates its fd according to an explicit ownership enum.
- Provider imports hold references to the allocation and release their native objects before the allocation closes its fd.
- Cache entries never outlive the provider device or allocation generation.
- Forked processes do not inherit a usable scheduler state unless explicitly reinitialized.
- All error paths close duplicated fds.
- Metrics and tests count live allocations, imports, mappings, and fds.

## 10. Cross-provider synchronization

### 10.1 Fence representation

```cpp
enum ggml_amd_fence_kind {
    GGML_AMD_FENCE_NONE,
    GGML_AMD_FENCE_HOST,
    GGML_AMD_FENCE_SYNC_FILE,
    GGML_AMD_FENCE_HIP_EVENT,
    GGML_AMD_FENCE_VULKAN_TIMELINE,
    GGML_AMD_FENCE_XRT,
};
```

Every allocation records its last writer plus an access sequence. Every scheduled region declares read and write sets. The scheduler inserts the minimum waits needed to preserve those dependencies.

### 10.2 Interoperability order

1. Prefer a native shared fence or external semaphore when both providers support it.
2. Export or import a Linux `sync_file` through the dma-buf reservation object when supported.
3. Fall back to an explicit host wait while retaining the zero-copy allocation.
4. Copy only when the destination provider cannot import the allocation at all and policy permits a migration.

The correctness milestone may use host waits. It may not use hidden staging copies and call them shared execution.

### 10.3 Deadlock prevention

- Assign every submission a monotonically increasing sequence.
- Do not wait on a fence produced by a later sequence in the same queue.
- Build the region dependency graph before submission and reject cycles.
- Give every provider wait a timeout in debug builds.
- Dump the allocation, provider, writer, waiter, and sequence on timeout.

## 11. HIP provider

HIP is the first full compute provider because the initial host executes native `gfx1103` HIP successfully.

### 11.1 Reuse strategy

The existing HIP backend compiles the mature `ggml-cuda` kernels under HIP. Preserve that coverage. Refactor only the ownership boundary needed for AMD:

- Construct a HIP provider without globally registering it as a separate user-facing backend.
- Import externally allocated dma-buf memory through HIP external-memory APIs.
- Expose streams, events, memory information, graph execution, and supported-operation queries to the AMD facade.
- Replace user-facing CUDA names and definitions only where they leak through the AMD facade. Do not begin with a broad CUDA/HIP source rename.

### 11.2 Device probe

The HIP probe must record:

- HIP runtime and compiler version.
- HSA agent name and UUID.
- GFX architecture and wavefront size.
- Integrated or discrete memory topology.
- Fine-grained and coarse-grained memory capabilities.
- External-memory and external-semaphore import availability.
- hipBLAS and rocBLAS availability.
- Graph support.
- MFMA and datatype support.

`supports_op` must remain authoritative. A successful device probe does not imply that every operation or datatype is enabled.

### 11.3 T640 parity

HIP currently lacks the full Metal T640 semantic operation set. Implement:

- `GGML_OP_TILE640_MATMUL`
- `GGML_OP_TILE640_MATMUL_ID`
- `GGML_OP_TILE640_GET_ROWS`
- `GGML_OP_TILE640_DEQUANT`

Use the CPU dequantizer as the ground truth and the Metal implementation as an optimized semantic reference. Preserve the existing debug-dequant dump format so layer-by-layer CPU, Metal, and HIP results can be compared by the same tools.

Start with a correct native HIP kernel for the existing T640 packing. Add MFMA or CK specialization only after the reference path passes parity and profiling identifies the limiting shape regimes.

### 11.4 HIP exit gate

- Native `gfx1103` kernel dispatch passes outside the backend test harness.
- `test-backend-ops` passes for every operation advertised by AMD-HIP.
- T640 dequant and matmul meet documented absolute, relative, cosine, and Frobenius tolerances.
- A calibrated model completes prefill and at least 256 decode tokens without NaNs.
- Shared CPU/HIP tests report zero staging bytes.
- Provider metrics report queue time, execution time, imported bytes, resident bytes, and fallback reason.

## 12. CPU and ZenDNN providers

The generic CPU backend remains the complete fallback and correctness reference. Build native Zen 4 variants through existing CPU feature selection rather than creating an AMD-only CPU kernel tree.

ZenDNN is an optional provider for the operation and datatype combinations it actually accelerates. Initially that means supported F32, BF16, and Q8_0 matmul shapes. Unsupported operations remain on generic CPU or HIP.

The scheduler must account for ZenDNN initialization and reorder costs. It must not choose ZenDNN because the CPU vendor is AMD.

CPU provider exit gate:

- The AMD facade exposes a complete CPU fallback without ZenDNN installed.
- CPU can map and operate on `SHARED_SYSTEM` allocations.
- ZenDNN is selected only for measured winning regions.
- Direct CPU and AMD-CPU numerical results match.

## 13. Vulkan provider

Vulkan is a compatibility, validation, and recovery provider. It is built from the existing `ggml-vulkan` implementation through a provider adapter.

Required adapter work:

- Match only AMD Vulkan physical devices when running under the AMD registry.
- Import dma-buf memory through the appropriate external-memory fd extension.
- Import or export synchronization primitives when supported.
- Expose timeline semaphore completion to the AMD fence layer.
- Preserve direct Vulkan builds for non-AMD and differential testing.
- Record when Vulkan is selected because HIP is absent, unsupported for an operation, or explicitly requested.

Vulkan exit gate:

- HIP and Vulkan can address the same shareable allocation in a controlled interoperability test.
- Differential operation tests pass on Radeon 780M.
- Provider switching is visible in logs and metrics.
- Vulkan never outranks healthy HIP by default on an AMD GPU.

## 14. XDNA provider and NPU host setup

### 14.1 Host enablement gate

On the initial UM790 Pro host:

1. Enter UEFI setup.
2. Set `Advanced -> CPU Configuration -> IPU Control` to `Enabled`.
3. Boot the staged Bluefin deployment.
4. Verify PCI device `1022:1502`.
5. Load `amdxdna` and verify `/dev/accel/accel0`.
6. Verify that the loaded driver and `1502_00` firmware versions match.
7. Build XRT base and the XDNA plugin from one upstream revision in a Fedora toolbox.
8. Build RPM artifacts and layer them through the immutable-host package mechanism.
9. Configure memlock limits for the user session.
10. Run `xrt-smi examine` and `xrt-smi validate`.

Do not replace the in-tree kernel driver unless XRT validation demonstrates an ioctl or firmware mismatch. If replacement is necessary, install a matched driver, firmware, XRT base, and plugin set from one source revision. Never mix a current plugin with stale firmware by hand.

### 14.2 Execution model

The XDNA provider consumes compiled regions:

```text
GGML region
  -> supported-op validation
  -> shape and state classification
  -> XDNA graph translation
  -> overlay and control-code compilation or cache lookup
  -> dma-buf registration
  -> XRT submission
  -> XRT fence publication
```

Borrow the translation-table and compiled-model-cache architecture from OpenVINO. Do not copy its current single-device, globally selected, synchronous shell.

### 14.3 Initial region candidates

Profile these candidates in order:

1. Fused MLP body during prefill.
2. Repeated projection plus activation groups.
3. Static-shape attention body with host-owned KV.
4. T640 dequant plus matmul only if compiler and memory behavior justify it.

Elementwise nodes are included only when they belong to a profitable fused region. Per-node NPU launch is out of scope.

### 14.4 State policy

- KV remains on CPU or GPU for the first XDNA milestone.
- XDNA inputs and outputs use dma-buf-backed slabs.
- Static shape buckets are keyed by batch, sequence, hidden width, datatype, and compiled provider ABI.
- Compiled artifacts are validated against NPU device ID, firmware version, compiler version, and provider version.
- NPU compilation never occurs on the steady decode critical path.

### 14.5 XDNA exit gate

- `xrt-smi examine` and `xrt-smi validate` pass.
- XDNA imports a `ggml-amd` dma-buf and completes a read/write smoke test.
- One compiled fused region matches the CPU reference.
- A cache hit avoids recompilation.
- Unsupported regions fall back without model reload.
- NPU use demonstrates a measured latency, throughput, or energy benefit after transfer and synchronization costs.

## 15. Region scheduler

### 15.1 Region formation

Form regions from maximal supported subgraphs while respecting:

- Stateful tensor ownership.
- Provider operation support.
- Required tensor layout.
- Static-shape requirements.
- Fusion boundaries.
- Memory-domain importability.
- Quantized packing availability.

Metadata-only views should follow the storage owner. Cheap operations should stay with an adjacent expensive region unless moving them produces a measured benefit.

### 15.2 Cost model

```text
region_cost = execution_cost
            + queue_cost
            + fence_cost
            + import_cost
            + copy_cost
            + compile_cost
            + packing_cost
            + expected_eviction_cost
```

Use static heuristics before measurements exist. Store measured results by:

```text
device fingerprint
provider ABI
region signature
shape bucket
datatype signature
packing version
prefill or decode phase
power profile
```

### 15.3 Prefill policy

- Favor throughput and coarse regions.
- Permit one-time compilation or packing before execution.
- Consider XDNA only when the region is compiled and transfer cost is amortized.
- Allow CPU plus HIP pipeline overlap when dependencies permit.

### 15.4 Decode policy

- Favor stable residency and low launch latency.
- Keep KV on one home provider.
- Reject provider crossings for isolated cheap nodes.
- Prefer a slightly slower kernel over a state migration unless the measured horizon repays the migration.
- Exclude first-use compilation and packing from the token loop.

### 15.5 Modes

- `deterministic`: Fixed routing from capabilities and an existing cache. No online microbenchmarking.
- `adaptive`: Bounded warm-up measurements update the local cost cache.
- `diagnostic`: Executes selected regions on multiple providers and compares results.
- `single-provider`: Pins execution to CPU, HIP, Vulkan, or XDNA where supported.

### 15.6 Scheduler exit gate

- A transformer layer does not ping-pong between CPU and GPU.
- Steady decode does not migrate KV unexpectedly.
- Every provider crossing records bytes, fence wait, cause, and expected benefit.
- Routing is reproducible from the same cache and configuration.
- A rejected route explains which cost or capability gate failed.

## 16. Residency and weight streaming

Complete the existing residency tracker by connecting suggestions to actual policy actions.

### 16.1 UMA policy

- Prefer shared system allocations that are directly accessible to CPU and iGPU.
- Treat the configured VRAM aperture as a placement hint, not the total usable iGPU memory.
- Track bandwidth pressure and page-fault behavior even when no explicit copy occurs.
- Pin hot decode weights only when the runtime exposes a meaningful mechanism.

### 16.2 Discrete GPU policy

- Keep hot weights in VRAM.
- Keep a system-memory dma-buf backing or reload source when eviction is permitted.
- Move at layer or region boundaries, not per tensor operation.
- Use asynchronous prefetch with explicit completion fences.

### 16.3 NPU policy

- Register only slabs required by compiled regions.
- Reuse registrations and compiled buffers across iterations.
- Respect memlock and driver limits.
- Evict compiled-region resources independently from model weights.

### 16.4 Exit gate

- Suggestions result in observable retain, release, prefetch, or eviction actions.
- Memory budgets are reported per domain and provider.
- Out-of-memory fallback is deterministic and tested.
- No allocation is released while referenced by an import or outstanding fence.

## 17. Layout-neutral quantization and runtime packing

The canonical artifact follows `docs/tile-neutral-export-design.md`. It contains trits, outlier CSR data, AWQ scales, activation scales, and global amplitude without a tile geometry in the file extension, tensor key, or metadata.

### 17.1 Runtime path

```text
neutral safetensors
  -> validate semantic tensor
  -> select provider packing
  -> pack once
  -> cache packed representation
  -> allocate or import provider buffer
```

### 17.2 Initial packings

- Existing T640 packing for correctness and cross-platform parity.
- HIP-optimized physical arrangement only after existing T640 semantics pass.
- Vulkan-specific arrangement only if shader measurements require it.
- Zen CPU arrangement only if it beats direct neutral or T640 consumption.
- XDNA compiler-owned layout stored as a compiled artifact, not as canonical model data.

### 17.3 Cache key

```text
model content hash
tensor namespace and name
neutral schema version
quantization parameters
provider name and ABI
device architecture
packing algorithm version
compiler version when applicable
```

### 17.4 Cache behavior

- Write to a temporary entry, validate, then rename atomically.
- Never use an entry whose complete key does not match.
- Bound cache size and use LRU eviction.
- Separate packed weight data from schedule measurements.
- Report cold-pack time, warm-load time, packed size, and hit rate.

### 17.5 Exit gate

- Neutral-to-T640 output matches the existing single-step exporter bit-for-bit.
- The same neutral artifact runs through CPU, Metal, and AMD-HIP paths.
- Cache invalidation works after any ABI or packing-version change.
- No public AMD-specific tensor type is introduced.

## 18. Configuration surface

Expose one AMD policy namespace. Initial environment variables or equivalent runtime parameters:

```text
GGML_AMD_PROVIDER=auto|hip|vulkan|cpu|xdna
GGML_AMD_MODE=deterministic|adaptive|diagnostic
GGML_AMD_KV_HOME=auto|hip|cpu
GGML_AMD_XDNA=auto|off|on
GGML_AMD_VULKAN_FALLBACK=0|1
GGML_AMD_CACHE_DIR=<path>
GGML_AMD_METRICS=<path>
GGML_AMD_DUMP_GRAPH=<path>
GGML_AMD_DUMP_DEQUANT=<path>
```

Build options determine compiled capabilities. Runtime configuration selects policy. A runtime option may not claim a provider is available when it was not compiled or did not pass its probe.

There is no runtime option that disables dma-buf for heterogeneous execution. A single-provider diagnostic build may use that provider's private buffers, but graph-visible cross-provider allocations always use the dma-buf contract.

Command-line integration should reuse the existing Tessera argument infrastructure. Do not add separate application-specific AMD configuration parsers.

## 19. Observability

Every run should be able to report:

- Physical devices, providers, driver/runtime versions, and capability fingerprints.
- Allocation domain, dma-buf import success, mapping state, and resident bytes.
- Region boundaries and selected provider.
- Provider-selection reason and rejected alternatives.
- Queue, fence, import, copy, packing, compile, and execution time.
- Bytes copied and bytes shared without copy.
- Cache hits and misses.
- Fallback counts and reasons.
- KV home and migration count.
- Per-provider peak memory.

Metrics output must be stable enough for `llama-bench` automation and AlphaEvolve comparison. Debug logging must not be required for ordinary metrics collection.

## 20. Test plan

### 20.1 Unit tests

Add focused tests for:

- Device discovery and stable identity.
- dma-buf allocation, mapping, fd ownership, import caching, and error cleanup.
- CPU access synchronization.
- Fence ordering and timeout diagnostics.
- Region formation.
- Cost-model keys and deterministic routing.
- Packing-cache keying, validation, and eviction.
- XDNA operation-table support decisions without hardware.

### 20.2 Provider tests

Run `tests/test-backend-ops.cpp` against:

- AMD-CPU.
- AMD-HIP.
- AMD-Vulkan.
- AMD-XDNA for the advertised compiled-region test surface.

An operation is not advertised until its backend test passes.

### 20.3 Interoperability tests

- CPU write -> HIP read from one dma-buf.
- HIP write -> CPU read from one dma-buf.
- HIP write -> Vulkan read from one dma-buf.
- Vulkan write -> HIP read from one dma-buf.
- CPU/HIP write -> XDNA read after NPU enablement.
- XDNA write -> CPU/HIP read after NPU enablement.
- Fence-only ordering tests with no payload copy.
- Lifetime tests with outstanding imports and fences.

Each test records actual copy bytes. A zero-copy test fails if the counter is nonzero.

### 20.4 Numerical tests

- CPU versus HIP per operation.
- HIP versus Vulkan per operation.
- T640 dequant row dumps.
- T640 dense and expert matmul.
- RMS norm, softmax, RoPE, GLU, and attention.
- Paged attention and KV Q8 variants.
- Compiled XDNA region versus CPU.
- Full-model logits, selected token sequence, and perplexity.

Use operation-appropriate absolute and relative tolerances plus cosine or Frobenius metrics where Tessera already uses them. Token equality alone is insufficient.

### 20.5 End-to-end tests

- Load one neutral artifact and create the HIP packed cache.
- Run prompt prefill.
- Run at least 256 decode tokens.
- Repeat from the warm cache.
- Run deterministic CPU-only, HIP-only, Vulkan-only, and hetero policies.
- Exercise an out-of-memory fallback.
- Exercise an unsupported-operation fallback.
- Exercise cache invalidation.

### 20.6 Performance tests

Record separately:

- Cold model load and packing.
- Warm model load.
- Prompt-processing tokens per second.
- Decode tokens per second.
- Time to first token.
- Peak RSS and per-domain device memory.
- Shared bytes, copied bytes, and fence-wait time.
- Energy per token when a stable host counter exists.

Performance parity means the AMD facade does not impose a material regression over the direct winning provider. It does not require equal throughput to Apple hardware.

## 21. CI matrix

### 21.1 Build-only CI

- Linux CPU plus AMD facade with all optional providers disabled.
- Linux HIP provider compilation for a representative gfx target.
- Linux Vulkan provider compilation.
- Linux XDNA provider compilation with a mock device layer.
- macOS build proving no Metal or ANE regression.
- Dynamic and static backend builds.

### 21.2 Hardware CI

- Phoenix `gfx1103` self-hosted runner: CPU, HIP, dma-buf, and Vulkan interoperability.
- Supported discrete Radeon runner: HIP, VRAM residency, and system-memory tiering.
- Supported XDNA runner: XRT validation, dma-buf registration, and one compiled region.
- Apple runner: neutral artifact and T640 cross-platform reference.

### 21.3 Required gates

- No new compiler warnings in changed targets.
- Address and undefined-behavior sanitizer coverage for control-plane tests.
- fd-leak and allocation-lifetime tests.
- Backend operation suite for advertised support.
- Full-model smoke test on the Phoenix runner.
- Numerical parity report attached to every provider optimization wave.

## 22. Implementation waves

Each wave is independently reviewable and keeps direct backends available as oracles.

### Wave 0: Contract and evidence baseline

Files:

- `docs/backend/AMD.md`
- `docs/backend/ggml-amd-implementation-plan.md`
- `docs/PROJECT-STATUS.md`

Work:

- Mark the monolithic source-copy and public TILE_AMD decisions as superseded.
- Record host HIP and NPU evidence.
- Freeze public invariants, metrics, and acceptance gates.
- Capture direct CPU, HIP, and Vulkan baseline results before implementation.

Gate:

- Architect approves the public contract and baseline artifacts.

### Wave 1: dma-buf allocation and fence foundation

Files:

- `ggml/src/ggml-amd/ggml-amd-buffer.cpp`
- `ggml/src/ggml-amd/ggml-amd-dmabuf.cpp`
- `ggml/src/ggml-amd/ggml-amd-fence.cpp`
- New focused tests under `tests/`

Work:

- Implement allocation domains, mapping, fd ownership, import cache, and CPU synchronization.
- Run the system-heap versus GEM PRIME producer spike.
- Implement host and sync-file fence paths.

Gate:

- CPU/HIP zero-copy round trip passes with zero leaked fds and zero staging bytes.

### Wave 2: Registry and provider facade

Files:

- `ggml/include/ggml-amd.h`
- `ggml/CMakeLists.txt`
- `ggml/src/CMakeLists.txt`
- `ggml/src/ggml-backend-reg.cpp`
- `ggml/src/ggml-amd/CMakeLists.txt`
- Registry, device, probe, and provider-interface sources.

Work:

- Add the AMD backend and physical device enumeration.
- Add CPU and HIP adapters.
- Suppress duplicate user-facing provider registration in the ordinary AMD build.
- Preserve a differential-test mode.

Gate:

- One AMD registry enumerates stable CPU and `gfx1103` devices and initializes both.

### Wave 3: HIP compute parity

Files:

- HIP adapter and minimal reusable-provider changes in `ggml-hip` and `ggml-cuda`.
- `ggml/src/ggml-amd/tile/ggml-amd-tile-hip.cu`
- T640 tests and debug-dump integration.

Work:

- Import dma-buf allocations into HIP.
- Connect HIP streams and events.
- Pass the existing operation suite.
- Implement the four T640 semantic operations.
- Run calibrated-model prefill and decode.

Gate:

- AMD-HIP meets numerical parity and direct-HIP performance overhead is within the agreed threshold.

### Wave 4: Region scheduler and residency

Files:

- Region, scheduler, cost-model, residency, cache, and metrics sources.
- Integration changes near the existing backend scheduler and llama context.

Work:

- Form regions, calculate costs, maintain state ownership, and persist measurements.
- Implement separate prefill and decode policies.
- Connect residency suggestions to actions.

Gate:

- No unintended provider ping-pong, stable KV home, and reproducible routing.

### Wave 5: Neutral artifact and packing cache

Files:

- Files identified by `docs/tile-neutral-export-design.md`.
- AMD packing-cache integration.

Work:

- Complete neutral export and T640 client packing.
- Integrate provider packing cache with model loading.
- Prove bit-identical neutral-to-T640 round trip.

Gate:

- One neutral artifact runs through CPU, Metal, and AMD-HIP with correct cache behavior.

### Wave 6: Vulkan provider

Files:

- Vulkan adapter plus minimal reusable-provider changes in `ggml-vulkan`.
- Remove copied Vulkan sources after parity.

Work:

- Import dma-buf allocations and connect timeline synchronization.
- Add AMD device filtering and explicit fallback reasons.
- Run HIP/Vulkan interoperability and differential tests.

Gate:

- Vulkan fallback works without changing the public backend or model artifact.

### Wave 7: XDNA host and provider

Files:

- XDNA provider and translation/cache sources.
- XDNA build detection and mock tests.

Work:

- Enable and validate the host NPU.
- Install matched XRT userspace components.
- Register dma-buf allocations.
- Compile, cache, and execute the first fused region.

Gate:

- One profitable compiled region passes numerical parity and end-to-end fallback tests.

### Wave 8: Discrete GPU and tiered memory

Work:

- Add stable multi-GPU identities.
- Add GPU-local exportable allocations and asynchronous prefetch.
- Validate a discrete Radeon with HIP primary and Vulkan fallback.

Gate:

- Explicit system/VRAM tiering beats or matches direct HIP without correctness regression.

### Wave 9: Production parity and cleanup

Work:

- Run the complete CI and hardware matrix.
- Remove copied source scaffolding and stale TILE_AMD stubs.
- Make the AMD facade the recommended AMD build path.
- Retain direct provider builds as upstream-compatible diagnostics.
- Update user-facing build and runtime documentation.

Gate:

- Functional, numerical, memory, scheduling, observability, and performance acceptance criteria all pass.

## 23. Review gates

Every implementation wave must pass:

1. Surrounding-code review for new patterns.
2. `test-backend-ops` coverage for advertised operations.
3. Numerical comparison against a direct provider or CPU reference.
4. Allocation, fd, import, and fence lifetime checks where applicable.
5. Transfer-counter review proving whether the path copied or shared data.
6. Performance comparison against the previous wave and direct provider.
7. Claim-versus-evidence review for every parity statement.
8. Verifier review before any champion or integration branch is promoted.
9. Explicit architect approval before promotion, merge, or release.

## 24. Risk register

| Risk | Consequence | Mitigation | Gate |
|---|---|---|---|
| System dma-heap memory is not accepted by one provider | The preferred allocator cannot span all devices | Test GEM PRIME as the alternate producer while keeping dma-buf as the identity | Wave 1 import matrix |
| HIP external memory differs from ordinary HIP allocations | Kernels or libraries reject imported pointers | Probe library paths separately and use provider-private scratch where required | HIP operation suite on imported buffers |
| Fence interop is incomplete | Host waits reduce overlap or ordering fails | Ship correct host waits first, then add sync-file/native semaphore bridges | Fence ordering tests |
| Per-node routing causes ping-pong | Heterogeneous execution is slower than HIP-only | Schedule regions and charge crossings in the cost model | Crossing-count gate |
| XRT plugin and driver firmware mismatch | NPU enumerates but execution aborts | Install matched driver, firmware, XRT, and plugin revisions | `xrt-smi validate` |
| Phoenix NPU compiler coverage is narrow | Few profitable LLM regions | Keep XDNA optional and require measured benefit | XDNA profitability gate |
| T640 HIP packing or metadata decode diverges | NaNs or model-quality loss | CPU reference, Metal semantic reference, and layer dumps | T640 numerical gate |
| Runtime packing increases cold-start time | User-visible startup regression | Persistent atomic cache and measured cold/warm budgets | Packing-cache gate |
| AMD facade forks provider sources | Permanent upstream drift | Reusable targets and adapters, no copied implementation | Source-duplication check |
| Discrete GPU is treated like UMA | PCIe copies dominate execution | Explicit memory domains and coarse residency decisions | dGPU transfer budget |
| Device enumeration order changes | Wrong cache or policy is reused | Key by stable hardware fingerprint, not index | Device identity tests |
| Metrics omit hidden copies | False zero-copy claims | Count bytes at allocation migration and provider copy boundaries | Transfer-counter review |

## 25. Definition of done

`ggml-amd` is production-ready only when all of the following are true:

- `GGML_AMD=ON` builds one AMD registry with no copied HIP, Vulkan, or ZenDNN implementation.
- The initial Phoenix host enumerates AMD CPU, `gfx1103` HIP GPU, and enabled XDNA NPU where available.
- Graph-visible cross-provider allocations have a dma-buf identity.
- CPU/HIP and HIP/Vulkan interoperability tests use zero staging bytes.
- XDNA can register a ggml-amd dma-buf and execute at least one compiled region.
- HIP is selected ahead of Vulkan on the healthy Radeon 780M path.
- T640 semantic operations pass CPU and Metal reference tolerances.
- One neutral safetensors artifact produces valid provider packings without public AMD-specific tensor metadata.
- Prefill and decode use separate measured policies.
- KV remains on a stable home provider during steady decode.
- Every provider crossing and fallback is observable.
- The complete advertised backend operation suite passes.
- A calibrated model completes prefill and 256-token decode in deterministic and adaptive modes.
- Direct provider performance comparisons show no unexplained material facade regression.
- macOS Metal and ANE builds and tests do not regress.
- Copied AMD Vulkan sources, TILE_AMD stubs, and placeholder CK/FastFlow scope are removed or explicitly archived.
- Build, runtime, troubleshooting, and NPU setup documentation is complete.
- Verifier review and architect approval are recorded before promotion.

## 26. Immediate next actions

1. Enable `IPU Control` in the UM790 Pro UEFI, reboot, and re-audit the staged Bluefin kernel.
2. Capture direct CPU, HIP, and Vulkan correctness and performance baselines.
3. Implement the Wave 1 dma-buf producer/import matrix before creating the AMD registry.
4. Confirm that a system dma-heap or GEM PRIME allocation can be imported into HIP on `gfx1103` and registered through the XDNA UAPI.
5. Freeze the provider contract and public header only after the allocation spike proves the required ownership and synchronization data.
6. Begin Wave 2 registry work with CPU and HIP only.
7. Keep Vulkan, ZenDNN, XDNA, packing, and scheduling changes behind their later wave gates.
