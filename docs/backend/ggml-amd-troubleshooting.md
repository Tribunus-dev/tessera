# ggml-amd Troubleshooting

## Common Issues

### Build Failures

#### "HIP compiler not found"

**Symptom:** CMake stops with "GGML_AMD_HIP=ON requires a ROCm HIP compiler"

**Cause:** ROCm/HIP not installed or not in PATH

**Solution:**
```bash
# Verify ROCm installation
rocminfo
hipinfo

# Add ROCm to PATH
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH

# Re-run CMake with the ROCm prefix
cmake -S . -B build-amd -DGGML_AMD=ON -DGGML_AMD_HIP=ON -DROCM_PATH=/opt/rocm
```

The AMD backend intentionally fails configuration rather than silently building
without a compute provider.

#### "Vulkan SDK not found"

**Symptom:** CMake error "Could not find Vulkan"

**Cause:** Vulkan SDK not installed

**Solution:**
```bash
# Ubuntu/Debian
sudo apt install vulkan-sdk

# Fedora
sudo dnf install vulkan-headers vulkan-loader-devel

# Verify
vulkaninfo | head -20
```

#### "XRT headers not found"

**Symptom:** CMake error when `GGML_AMD_XDNA=ON`

**Cause:** XRT not installed

**Solution:**
```bash
# Build XRT from source (Fedora toolbox)
git clone https://github.com/Xilinx/XRT.git
cd XRT/build
./build.sh

# Install RPMs
sudo rpm -i build/xrt_2026XX.2.X.X_XX.rpm
sudo rpm -i build/xdna.rpm

# Verify
xrt-smi examine
```

The current adapter only validates that XRT is installed. It is not linked to
XRT until its runtime owns actual XRT handles, so enabling the option does not
enable NPU execution yet.

### Runtime Failures

#### Backend Not Registered

**Symptom:** `llama-cli --list-backends` does not show AMD

**Cause:** Backend not built or not loaded

**Diagnosis:**
```bash
# Check if built
ls build-amd/libggml-amd.so

# Check CMake options
grep GGML_AMD build-amd/CMakeCache.txt

# Check runtime loading
GGML_LOG_LEVEL=debug ./build-amd/bin/llama-cli --list-backends 2>&1 | grep AMD
```

**Solutions:**
1. Rebuild with `GGML_AMD=ON`
2. Ensure `libggml-amd.so` is in library path
3. Check for missing dependencies: `ldd libggml-amd.so`

#### HIP Probe Fails

**Symptom:** Metrics show HIP provider not probed

**Cause:** HIP runtime initialization failed

**Diagnosis:**
```bash
# Check HIP runtime
hipinfo

# Check GPU visibility
rocm-smi

# Check permissions
ls -l /dev/kfd
ls -l /dev/dri/renderD128
```

**Solutions:**
1. Add user to render/video groups:
   ```bash
   sudo usermod -aG render,video $USER
   ```
2. Verify ROCm driver loaded: `lsmod | grep amdgpu`
3. Check dmesg for GPU errors: `dmesg | grep amdgpu`

#### Vulkan Probe Fails

**Symptom:** Metrics show Vulkan provider not probed

**Cause:** Vulkan instance creation failed

**Diagnosis:**
```bash
# Check Vulkan
vulkaninfo | grep AMD

# Check for AMD GPU
lspci | grep -i vga
```

**Solutions:**
1. Install AMD Vulkan driver:
   ```bash
   # Fedora
   sudo dnf install mesa-vulkan-drivers
   
   # Ubuntu
   sudo apt install mesa-vulkan-drivers
   ```
2. Verify `VK_ICD_FILENAMES` includes AMD ICD
3. Check for conflicting Vulkan layers

#### XDNA Probe Fails

**Symptom:** Metrics show XDNA provider not probed

**Cause:** NPU not enabled or XRT not installed

**Diagnosis:**
```bash
# Check device node
ls -l /dev/accel/accel0

# Check PCI device
lspci | grep 1022:1502

# Check XRT
xrt-smi examine
```

**Solutions:**

**NPU Not Enabled:**
1. Enter UEFI setup
2. Navigate to `Advanced -> CPU Configuration -> IPU Control`
3. Set to `Enabled`
4. Save and reboot
5. Verify: `lspci | grep 1022:1502`

**XRT Not Installed:**
```bash
# Build and install XRT
cd XRT/build
./build.sh
sudo rpm -i build/xrt_*.rpm

# Verify
xrt-smi examine
xrt-smi validate
```

**Driver/Firmware Mismatch:**
```bash
# Check driver version
cat /sys/bus/pci/drivers/amdxdna/module/version

# Check firmware version
ls /lib/firmware/amdnpu/

# Ensure versions match; if not, rebuild XRT from matching source
```

### dma-buf Failures

#### Allocation Fails

**Symptom:** `ggml_amd_dma_heap_alloc` returns -1

**Cause:** dma-heap not available or permissions issue

**Diagnosis:**
```bash
# Check dma-heap device
ls -l /dev/dma_heap/system

# Check kernel config
zcat /proc/config.gz | grep DMA_HEAP
```

**Solutions:**
1. Load dma-heap module:
   ```bash
   sudo modprobe dma_heap
   ```
2. Check permissions:
   ```bash
   sudo chmod 666 /dev/dma_heap/system
   ```
3. Verify kernel config includes `CONFIG_DMA_HEAP=y`
4. Try alternate heap list via environment:

   ```bash
   export GGML_AMD_DMA_HEAP_PATH=/dev/dma_heap/system-uncached:/dev/dma_heap/system:/dev/dma_heap/default_cma_region:/dev/dma_heap/cma:/dev/dma_heap/reserved
   ```

5. Fall back to GEM PRIME (requires DRM device access)

### Stale Test Binary

**Symptom:** A test message still says `HIP imports a system dma-buf` even though
the current source rejects non-brokered imports.

**Cause:** You are still running a previously built `test-amd-registry` binary
that does not include the current dma-buf contract checks.

**Resolution:**

1. Remove any prior build trees (including `/tmp/tessera-amd-test`).
2. Rebuild with `GGML_AMD_HIP=ON`.
3. Run the rebuilt test directly from the matching build directory.

```bash
rm -rf /tmp/tessera-amd-test
cmake -S . -B /tmp/tessera-amd-test -DGGML_AMD=ON -DGGML_AMD_HIP=ON -DGGML_BUILD_TESTS=ON -DROCM_PATH=/opt/rocm-7.1.1
cmake --build /tmp/tessera-amd-test --parallel
/tmp/tessera-amd-test/bin/test-amd-registry
```

The line should print `HIP imports a system dma-buf` when your HIP stack
can import system dma-buf allocations.

#### Import Fails

**Symptom:** Provider cannot import dma-buf allocation

**Cause:** Provider does not support external memory or dma-buf import

**Diagnosis:**
```bash
# Check HIP external memory
hipinfo | grep -i external

# Check Vulkan extensions
vulkaninfo | grep VK_EXT_external_memory_fd
```

**Solutions:**
1. Verify provider supports external memory
2. Check dma-buf fd is valid: `ls -l /proc/self/fd/<fd>`
3. Ensure allocation domain is compatible (SHARED_SYSTEM or GPU_LOCAL_EXPORTABLE)
4. Check for provider-specific import requirements

### Synchronization Issues

#### Fence Timeout

**Symptom:** Fence wait times out after `GGML_AMD_FENCE_TIMEOUT_MS`

**Cause:** Provider execution stalled or circular dependency

**Diagnosis:**
```bash
# Increase timeout
export GGML_AMD_FENCE_TIMEOUT_MS=30000

# Check metrics
cat $GGML_AMD_METRICS | jq '.fence_wait_ns'

# Enable debug logging
export GGML_AMD_LOG_LEVEL=debug
```

**Solutions:**
1. Increase timeout for large models
2. Check for circular dependencies in region formation
3. Verify provider is not saturated (check `queue_time_ns`)
4. Run in diagnostic mode to identify problematic regions

#### Deadlock

**Symptom:** Application hangs indefinitely

**Cause:** Circular fence dependency or provider deadlock

**Diagnosis:**
```bash
# Attach debugger
gdb -p <pid>
thread apply all bt

# Check fence ordering
export GGML_AMD_LOG_LEVEL=debug
```

**Solutions:**
1. Check region formation for circular dependencies
2. Verify fence sequence numbers are monotonic
3. Ensure providers are not waiting on each other
4. Run with `GGML_AMD_MODE=single-provider` to isolate

### Performance Issues

#### Low Throughput

**Symptom:** Tokens per second below expected

**Diagnosis:**
```bash
# Check metrics
cat $GGML_AMD_METRICS | jq '.'

# Profile with llama-bench
./build-amd/bin/llama-bench -m <model> --metrics
```

**Solutions:**
1. Check provider selection (should be HIP for GPU workloads)
2. Verify region formation (too many small regions?)
3. Check for frequent fallbacks (indicates capability gaps)
4. Verify KV home is stable (no migrations during decode)
5. Check cache hit rate (low rate indicates cold cache)
6. Tune scheduler mode: `GGML_AMD_MODE=adaptive` for initial deployment

#### High Memory Usage

**Symptom:** RSS or device memory exceeds expected

**Diagnosis:**
```bash
# Check metrics
cat $GGML_AMD_METRICS | jq '.resident_bytes'

# Check system memory
free -h

# Check GPU memory
rocm-smi --showmemuse
```

**Solutions:**
1. Reduce cache size: `GGML_AMD_CACHE_MAX_SIZE=1073741824` (1 GB)
2. Enable eviction: check residency manager settings
3. Reduce batch size
4. Check for memory leaks (resident_bytes should stabilize)
5. Verify KV home is appropriate (CPU for memory-constrained systems)

#### High Latency

**Symptom:** Time to first token is high

**Diagnosis:**
```bash
# Check metrics
cat $GGML_AMD_METRICS | jq '.queue_time_ns, .execution_time_ns'

# Profile prefill phase
GGML_AMD_METRICS=/tmp/prefill.json ./build-amd/bin/llama-cli --prompt "..."
```

**Solutions:**
1. Check for cold cache (first run packs weights)
2. Verify provider probe is fast (check probe times)
3. Reduce region compilation overhead (XDNA)
4. Check for excessive fence waits
5. Verify prefill policy is throughput-optimized

### Numerical Issues

#### NaN or Inf in Output

**Symptom:** Model produces NaN or Inf tokens

**Cause:** Numerical instability in provider kernels

**Diagnosis:**
```bash
# Dump dequantized weights
export GGML_AMD_DUMP_DEQUANT=/tmp/dequant

# Compare with CPU reference
./build-amd/bin/llama-cli --model <model> --prompt "..." --n-predict 10

# Check layer-by-layer
python3 tools/tessera/compare_dequant.py /tmp/dequant /tmp/cpu_dequant
```

**Solutions:**
1. Verify T640 kernels match CPU/Metal reference
2. Check for overflow in matmul kernels
3. Verify packing cache is not corrupted
4. Run in diagnostic mode to compare providers
5. Check for dtype mismatches (f16 vs f32)

#### Low Accuracy

**Symptom:** Model output is incoherent or low quality

**Cause:** Numerical divergence from reference

**Diagnosis:**
```bash
# Compare logits
export GGML_AMD_DUMP_DEQUANT=/tmp/amd_dequant
./build-amd/bin/llama-cli --model <model> --prompt "..."

# Compare with CPU
export LLAMA_TILE640_DEBUG_DEQUANT_DIR=/tmp/cpu_dequant
./build/bin/llama-cli --model <model> --prompt "..."

# Compute cosine similarity
python3 tools/tessera/compare_layers.py /tmp/amd_dequant /tmp/cpu_dequant
```

**Solutions:**
1. Check T640 parity tests pass
2. Verify packing cache keys match (model hash, schema version)
3. Check for dtype conversion errors
4. Verify provider kernels are up to date
5. Run full numerical test suite: `ctest -R amd`

## Debugging Techniques

### Verbose Logging

```bash
export GGML_AMD_LOG_LEVEL=debug
./build-amd/bin/llama-cli --model <model> --prompt "..." 2>&1 | tee debug.log
```

### Metrics Analysis

```bash
# Pretty-print metrics
cat $GGML_AMD_METRICS | jq '.'

# Check specific metrics
cat $GGML_AMD_METRICS | jq '.fallback_count'
cat $GGML_AMD_METRICS | jq '.cache_hits / (.cache_hits + .cache_misses)'

# Compare runs
diff <(jq '.' metrics1.json) <(jq '.' metrics2.json)
```

### Graph Dumps

```bash
export GGML_AMD_DUMP_GRAPH=/tmp/graph.dump
./build-amd/bin/llama-cli --model <model> --prompt "..."
cat /tmp/graph.dump
```

### Provider Isolation

```bash
# Test each provider individually
export GGML_AMD_MODE=single-provider
export GGML_AMD_PROVIDER=hip
./build-amd/bin/llama-cli --model <model> --prompt "..."

export GGML_AMD_PROVIDER=vulkan
./build-amd/bin/llama-cli --model <model> --prompt "..."

export GGML_AMD_PROVIDER=cpu
./build-amd/bin/llama-cli --model <model> --prompt "..."
```

### Memory Debugging

```bash
# Address sanitizer
cmake .. -DGGML_AMD=ON -DGGML_SANITIZE_ADDRESS=ON
make
./build-amd/bin/llama-cli --model <model> --prompt "..."

# Valgrind
valgrind --leak-check=full ./build-amd/bin/llama-cli --model <model> --prompt "..."
```

## Getting Help

### Logs to Collect

1. Build logs: `cmake .. 2>&1 | tee build.log`
2. Runtime logs: `GGML_AMD_LOG_LEVEL=debug ./llama-cli ... 2>&1 | tee run.log`
3. Metrics: `GGML_AMD_METRICS=metrics.json ./llama-cli ...`
4. System info: `rocminfo`, `vulkaninfo`, `xrt-smi examine`
5. GPU info: `rocm-smi --showallinfo`

### Reporting Issues

When reporting issues, include:

1. System info:
   - CPU: `lscpu`
   - GPU: `lspci | grep -i vga`, `rocm-smi`
   - NPU: `lspci | grep 1022:1502`, `xrt-smi examine`
   - OS: `cat /etc/os-release`
   - Kernel: `uname -r`

2. Build info:
   - CMake version: `cmake --version`
   - Compiler: `gcc --version` or `clang --version`
   - ROCm version: `cat /opt/rocm/.info/version`
   - CMake options: `grep GGML_AMD build/CMakeCache.txt`

3. Runtime info:
   - Environment variables: `env | grep GGML_AMD`
   - Metrics output: `cat $GGML_AMD_METRICS`
   - Error messages: full stderr output

4. Reproduction steps:
   - Command line used
   - Model used (name, size, quantization)
   - Expected vs actual behavior

### Community Resources

- GitHub Issues: https://github.com/Tribunus-dev/tessera/issues
- Documentation: `docs/backend/ggml-amd-*.md`
- Implementation plan: `docs/backend/ggml-amd-implementation-plan.md`
- Project status: `docs/PROJECT-STATUS.md` (Priority 10)
