# ggml-amd Build Guide

## Overview

`ggml-amd` is the first-class AMD platform backend for Linux systems combining AMD CPU, AMD GPU(s), and AMD XDNA NPU. It provides a unified facade over HIP, Vulkan, ZenDNN, and XDNA providers.

## Prerequisites

### System Requirements

- Linux (dma-buf support required)
- CMake 3.14+
- C++17 compiler (GCC 9+, Clang 10+)

### Provider-Specific Requirements

**HIP Provider:**
- ROCm 6.0+ installed
- HIP runtime and compiler
- rocBLAS, hipBLAS libraries
- AMD GPU with gfx900+ architecture

**Vulkan Provider:**
- Vulkan SDK 1.3+
- AMD GPU with Vulkan support
- `VK_EXT_memory_fd` extension support (for dma-buf import)

**ZenDNN Provider:**
- ZenDNN library (optional, for Zen 4+ CPU acceleration)
- AMD CPU with AVX-512 support

**XDNA Provider:**
- XRT (Xilinx Runtime) base installed
- XDNA plugin from matching revision
- `/dev/accel/accel0` device node
- Phoenix NPU firmware loaded

## Build Options

### CMake Options

```cmake
option(GGML_AMD "ggml: use AMD platform backend" OFF)
option(GGML_AMD_HIP "ggml: AMD backend with HIP provider" OFF)
option(GGML_AMD_VULKAN "ggml: AMD backend with Vulkan provider" OFF)
option(GGML_AMD_ZENDNN "ggml: AMD backend with ZenDNN provider" OFF)
option(GGML_AMD_XDNA "ggml: AMD backend with XDNA provider" OFF)
option(GGML_AMD_METRICS "ggml: AMD backend with detailed metrics" OFF)
```

### Default Behavior

- `GGML_AMD=OFF` by default until the backend reaches production gate
- When `GGML_AMD=ON`, providers are auto-detected:
  - HIP: enabled when ROCm is found
  - Vulkan: enabled when requested or HIP unavailable
  - ZenDNN: enabled when requested and found
  - XDNA: enabled when XRT headers/libraries found

## Build Instructions

### Basic Build (CPU + HIP)

```bash
mkdir build-amd && cd build-amd
cmake .. \
  -DGGML_AMD=ON \
  -DGGML_AMD_HIP=ON \
  -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

### Full Build (All Providers)

```bash
mkdir build-amd && cd build-amd
cmake .. \
  -DGGML_AMD=ON \
  -DGGML_AMD_HIP=ON \
  -DGGML_AMD_VULKAN=ON \
  -DGGML_AMD_ZENDNN=ON \
  -DGGML_AMD_XDNA=ON \
  -DGGML_AMD_METRICS=ON \
  -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

### CMake Preset

Use the `x64-linux-amd` preset:

```bash
cmake --preset x64-linux-amd
cmake --build --preset x64-linux-amd
```

## Verification

### Check Backend Registration

```bash
./build-amd/bin/llama-cli --list-backends
```

Expected output includes `AMD` in the backend list.

### Check Provider Probe

```bash
GGML_AMD_METRICS=/tmp/amd-metrics.json ./build-amd/bin/llama-cli --model <model> --prompt "Hello"
cat /tmp/amd-metrics.json
```

The metrics file shows which providers were probed and their capabilities.

### Run Tests

```bash
cd build-amd
ctest --output-on-failure
```

Key tests:
- `test-amd-registry`: device enumeration
- `test-amd-dmabuf`: dma-buf allocation and mapping
- `test-amd-scheduler`: region formation and cost model
- `test-amd-packing-cache`: cache keying and eviction

## Troubleshooting

### HIP Provider Not Found

**Symptom:** `ggml_amd_hip_probe` returns false

**Solutions:**
1. Verify ROCm installation: `rocminfo`
2. Check HIP runtime: `hipinfo`
3. Ensure GPU is visible: `rocm-smi`
4. Verify CMake found HIP: check `CMakeCache.txt` for `HIP_FOUND`

### Vulkan Provider Not Found

**Symptom:** `ggml_amd_vulkan_probe` returns false

**Solutions:**
1. Verify Vulkan SDK: `vulkaninfo`
2. Check for AMD GPU: `vulkaninfo | grep AMD`
3. Ensure `VK_EXT_memory_fd` is available: `vulkaninfo | grep VK_EXT_external_memory_fd`

### XDNA Provider Not Found

**Symptom:** `ggml_amd_xdna_probe` returns false

**Solutions:**
1. Enable NPU in UEFI: `Advanced -> CPU Configuration -> IPU Control -> Enabled`
2. Verify device node: `ls -l /dev/accel/accel0`
3. Check XRT installation: `xrt-smi examine`
4. Validate firmware: `xrt-smi validate`
5. Ensure driver and firmware versions match

### dma-buf Allocation Fails

**Symptom:** `ggml_amd_dma_heap_alloc` returns -1

**Solutions:**
1. Check dma-heap device: `ls -l /dev/dma_heap/system`
2. Verify permissions: user must have read/write access
3. Check kernel config: `CONFIG_DMA_HEAP` must be enabled
4. Try GEM PRIME fallback (requires DRM device access)

## Performance Tuning

### Scheduler Mode

```bash
export GGML_AMD_MODE=deterministic  # Fixed routing from cache
export GGML_AMD_MODE=adaptive       # Bounded warm-up measurements
export GGML_AMD_MODE=diagnostic     # Multi-provider comparison
export GGML_AMD_MODE=single-provider # Pin to one provider
```

### Provider Selection

```bash
export GGML_AMD_PROVIDER=auto       # Auto-select based on capabilities
export GGML_AMD_PROVIDER=hip        # Force HIP
export GGML_AMD_PROVIDER=vulkan     # Force Vulkan
export GGML_AMD_PROVIDER=cpu        # Force CPU
export GGML_AMD_PROVIDER=xdna       # Force XDNA
```

### KV Cache Home

```bash
export GGML_AMD_KV_HOME=auto        # Auto-select (usually HIP)
export GGML_AMD_KV_HOME=hip         # Keep KV on HIP
export GGML_AMD_KV_HOME=cpu         # Keep KV on CPU
```

### Cache Directory

```bash
export GGML_AMD_CACHE_DIR=/path/to/cache  # Default: ~/.cache/ggml-amd
```

### Metrics Output

```bash
export GGML_AMD_METRICS=/path/to/metrics.json
```

## Debugging

### Debug Dumps

```bash
export GGML_AMD_DUMP_GRAPH=/path/to/graph.dump
export GGML_AMD_DUMP_DEQUANT=/path/to/dequant.dump
```

### Verbose Logging

```bash
export GGML_LOG_LEVEL=debug
```

### Fence Diagnostics

The fence layer logs timeout diagnostics when waits exceed the configured threshold. Check metrics output for `fence_wait_ns` counters.

## Architecture Notes

### Memory Domains

1. **SHARED_SYSTEM**: `/dev/dma_heap/system` allocations, CPU-mappable, importable by all providers
2. **GPU_LOCAL_EXPORTABLE**: AMD GEM buffers exported via DRM PRIME, for discrete GPU residency
3. **PROVIDER_PRIVATE**: Provider-internal scratch memory, not graph-visible
4. **IMPORTED_EXTERNAL**: External dma-buf fds with explicit ownership

### Synchronization

- **HOST**: CPU-side synchronization (fastest, no hardware wait)
- **SYNC_FILE**: Linux sync_file fd (cross-provider via dma-buf reservation)
- **HIP_EVENT**: HIP event (GPU-side synchronization)
- **VULKAN_TIMELINE**: Vulkan timeline semaphore value
- **XRT**: XRT fence (NPU-side synchronization)

### Region Formation

The scheduler forms regions from maximal supported subgraphs, respecting:
- Stateful tensor ownership
- Provider operation support
- Required tensor layout
- Static-shape requirements
- Fusion boundaries
- Memory-domain importability

### Cost Model

Region cost = execution + queue + fence + import + copy + compile + packing + eviction

Keyed by: device fingerprint, provider ABI, region signature, shape bucket, datatype signature, packing version, prefill/decode phase, power profile.

## Next Steps

After successful build and verification:

1. Run the full test suite: `ctest`
2. Benchmark with `llama-bench`: `./build-amd/bin/llama-bench -m <model>`
3. Profile with metrics enabled: `GGML_AMD_METRICS=metrics.json`
4. Calibrate cost model: run with `GGML_AMD_MODE=adaptive`
5. Tune scheduler mode based on workload characteristics
