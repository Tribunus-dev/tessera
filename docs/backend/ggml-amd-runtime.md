# ggml-amd Runtime Configuration

## Overview

`ggml-amd` runtime behavior is controlled via environment variables and, where applicable, CLI flags. This document covers all configuration knobs, their effects, and recommended settings for different workloads.

## Environment Variables

### Provider Selection

**`GGML_AMD_PROVIDER`**
- Values: `auto` (default), `hip`, `vulkan`, `cpu`, `xdna`
- Effect: Selects the primary compute provider
- `auto`: HIP if available, else Vulkan, else CPU
- Recommendation: `auto` for most workloads; `hip` for GPU-heavy; `xdna` for NPU-optimized models

**`GGML_AMD_VULKAN_FALLBACK`**
- Values: `0` (default), `1`
- Effect: Allow fallback to Vulkan when HIP is unavailable or not selected
- Default: `1` (enabled). `0` disables fallback.
- Recommendation: `1` for robustness; `0` for strict HIP-only behavior

**`GGML_AMD_XDNA`**
- Values: `0` (default), `1`, `on`, `off`, `true`, `false`
- Effect: Enable/disable XDNA NPU probe
- `on`/`1`/`true`: probe and expose XDNA if runtime dependencies are present
- `off`/`0`/`false`: never probe XDNA
- Recommendation: `off` unless debugging NPU issues

### Scheduler Mode

**`GGML_AMD_MODE`**
- Values: `deterministic` (default), `adaptive`, `diagnostic`, `single-provider`
- Effect: Controls how the scheduler assigns regions to providers

**`deterministic`:**
- Fixed routing from capabilities and existing cost cache
- No online microbenchmarking
- Reproducible from same cache and configuration
- Best for: production, CI, benchmarks

**`adaptive`:**
- Bounded warm-up measurements update the local cost cache
- Learns provider performance over first N iterations
- Best for: initial deployment, heterogeneous workloads

**`diagnostic`:**
- Executes selected regions on multiple providers and compares results
- Useful for debugging numerical differences
- Best for: development, validation

**`single-provider`:**
- Pins execution to one provider (CPU, HIP, Vulkan, or XDNA)
- No cross-provider scheduling
- Best for: profiling, debugging, performance isolation

### KV Cache Placement

**`GGML_AMD_KV_HOME`**
- Values: `auto` (default), `hip`, `cpu`
- Effect: Where to keep KV cache during steady-state decode
- `auto`: HIP if available, else CPU
- Recommendation: `hip` for decode-heavy workloads; `cpu` for memory-constrained systems

### Cache Configuration

**`GGML_AMD_CACHE_DIR`**
- Default: `~/.cache/ggml-amd`
- Effect: Directory for packing cache and compiled XDNA regions
- Recommendation: SSD-backed directory for fast cache hits

**`GGML_AMD_CACHE_MAX_SIZE`**
- Default: `10737418240` (10 GB)
- Effect: Maximum packing cache size in bytes
- Recommendation: 10-20% of available disk space

### Metrics and Observability

**`GGML_AMD_METRICS`**
- Default: unset (no metrics output)
- Effect: Path to JSON metrics output file
- Example: `GGML_AMD_METRICS=/tmp/amd-metrics.json`
- Contents: queue time, execution time, imported bytes, resident bytes, fallback count/reason, copy bytes, shared bytes, fence wait, cache hits/misses, KV home, migration count

**`GGML_AMD_DUMP_GRAPH`**
- Default: unset
- Effect: Path to dump the computed graph structure
- Use case: debugging region formation

**`GGML_AMD_DUMP_DEQUANT`**
- Default: unset
- Effect: Path to dump dequantized weights (TDQT v3 format)
- Use case: layer-by-layer comparison with CPU/Metal reference

### Debugging

**`GGML_AMD_LOG_LEVEL`**
- Values: `error` (default), `warn`, `info`, `debug`
- Effect: Verbosity of AMD backend logging

**`GGML_AMD_FENCE_TIMEOUT_MS`**
- Default: `5000` (5 seconds)
- Effect: Timeout for fence waits in debug builds
- Recommendation: increase for large models or slow providers

## CLI Flags

Tessera CLI flags (when applicable):

**`--tessera-amd-provider <provider>`**
- Equivalent to `GGML_AMD_PROVIDER`
- Values: `auto`, `hip`, `vulkan`, `cpu`, `xdna`

**`--tessera-amd-mode <mode>`**
- Equivalent to `GGML_AMD_MODE`
- Values: `deterministic`, `adaptive`, `diagnostic`, `single-provider`

**`--tessera-amd-kv-home <home>`**
- Equivalent to `GGML_AMD_KV_HOME`
- Values: `auto`, `hip`, `cpu`

**`--tessera-amd-cache-dir <path>`**
- Equivalent to `GGML_AMD_CACHE_DIR`

**`--tessera-amd-metrics <path>`**
- Equivalent to `GGML_AMD_METRICS`

## Configuration Precedence

1. CLI flags (highest priority)
2. Environment variables
3. `--tessera-config` INI file (if used)
4. Built-in defaults (lowest priority)

## Recommended Configurations

### Production Inference

```bash
export GGML_AMD_PROVIDER=auto
export GGML_AMD_MODE=deterministic
export GGML_AMD_KV_HOME=hip
export GGML_AMD_CACHE_DIR=/var/cache/ggml-amd
export GGML_AMD_METRICS=/var/log/ggml-amd/metrics.json
```

### Development and Debugging

```bash
export GGML_AMD_PROVIDER=auto
export GGML_AMD_MODE=diagnostic
export GGML_AMD_KV_HOME=auto
export GGML_AMD_CACHE_DIR=/tmp/ggml-amd-cache
export GGML_AMD_METRICS=/tmp/amd-metrics.json
export GGML_AMD_DUMP_DEQUANT=/tmp/amd-dequant
export GGML_AMD_LOG_LEVEL=debug
```

### Benchmarking

```bash
export GGML_AMD_PROVIDER=hip
export GGML_AMD_MODE=deterministic
export GGML_AMD_KV_HOME=hip
export GGML_AMD_CACHE_DIR=/tmp/ggml-amd-cache
export GGML_AMD_METRICS=/tmp/amd-metrics.json
```

### NPU-Optimized Workload

```bash
export GGML_AMD_PROVIDER=xdna
export GGML_AMD_MODE=deterministic
export GGML_AMD_KV_HOME=cpu
export GGML_AMD_XDNA=on
export GGML_AMD_CACHE_DIR=/var/cache/ggml-amd
```

### Memory-Constrained System

```bash
export GGML_AMD_PROVIDER=cpu
export GGML_AMD_MODE=single-provider
export GGML_AMD_KV_HOME=cpu
export GGML_AMD_CACHE_MAX_SIZE=1073741824  # 1 GB
```

## Metrics Interpretation

### Key Metrics

**`queue_time_ns`:** Time spent waiting in provider queue before execution
- High values indicate provider saturation
- Recommendation: reduce batch size or add providers

**`execution_time_ns`:** Time spent executing on provider
- Dominant metric for throughput
- Compare across providers to identify bottlenecks

**`imported_bytes`:** Total bytes imported into providers
- High values indicate frequent cross-provider transfers
- Recommendation: improve region formation to reduce crossings

**`resident_bytes`:** Current bytes resident in providers
- Track over time to identify memory leaks
- Should stabilize after warm-up

**`fallback_count`:** Number of times a region fell back to a different provider
- Non-zero indicates capability gaps or scheduling issues
- Check `fallback_reason` for details

**`copy_bytes`:** Bytes copied between providers (not shared)
- Should be minimized; zero-copy is the goal
- High values indicate dma-buf import failures

**`shared_bytes`:** Bytes shared between providers via dma-buf
- Should be maximized; indicates successful zero-copy
- Compare to `copy_bytes` for efficiency ratio

**`fence_wait_ns`:** Time spent waiting on fences
- High values indicate synchronization bottlenecks
- Recommendation: improve region formation to reduce dependencies

**`cache_hits` / `cache_misses`:** Packing cache hit rate
- Hit rate should approach 100% after warm-up
- Low hit rate indicates cache size too small or key instability

**`kv_migration_count`:** Number of KV cache migrations
- Should be zero during steady-state decode
- Non-zero indicates KV home instability

**`kv_home`:** Current KV cache home provider
- Should be stable (e.g., "hip") during decode
- Changes indicate policy issues

### Derived Metrics

**Efficiency ratio:** `shared_bytes / (shared_bytes + copy_bytes)`
- Target: > 0.95 (95% zero-copy)
- Low values indicate dma-buf import issues

**Cache hit rate:** `cache_hits / (cache_hits + cache_misses)`
- Target: > 0.90 after warm-up
- Low values indicate cache thrashing

**Fallback rate:** `fallback_count / total_regions`
- Target: < 0.01 (1%)
- High values indicate capability gaps

## Runtime Behavior

### Prefill Phase

- Scheduler favors throughput and coarse regions
- Permits one-time compilation or packing before execution
- XDNA considered only when region is compiled and transfer cost amortized
- CPU + HIP pipeline overlap when dependencies permit

### Decode Phase

- Scheduler favors stable residency and low launch latency
- KV kept on one home provider (no surprise migrations)
- Provider crossings rejected for isolated cheap nodes
- Slightly slower kernel preferred over state migration
- First-use compilation and packing excluded from token loop

### Provider Selection

The scheduler selects providers based on:

1. **Capability:** Does the provider support the operation?
2. **Cost:** What is the estimated execution time?
3. **Residency:** Is the data already on this provider?
4. **Policy:** Does the mode allow this provider for this phase?

### Region Formation

Regions are formed from maximal supported subgraphs, respecting:

- Stateful tensor ownership (KV cache stays on one provider)
- Provider operation support (not all ops supported by all providers)
- Required tensor layout (some ops require specific packing)
- Static-shape requirements (XDNA needs static shapes)
- Fusion boundaries (some ops must be in same region)
- Memory-domain importability (dma-buf must be importable)

### Residency Management

The residency manager tracks tensor usage and suggests evictions:

- **UMA policy:** Prefer shared system allocations; VRAM aperture as hint
- **Discrete GPU policy:** Hot weights in VRAM; system-memory backing for eviction; async prefetch
- **NPU policy:** Register only slabs for compiled regions; reuse registrations

## Troubleshooting Runtime Issues

### High Fallback Count

**Symptom:** `fallback_count` is non-zero

**Diagnosis:**
1. Check `fallback_reason` in metrics
2. Enable debug logging: `GGML_AMD_LOG_LEVEL=debug`
3. Run in diagnostic mode: `GGML_AMD_MODE=diagnostic`

**Solutions:**
- If "unsupported op": check provider capabilities, consider enabling additional providers
- If "import failed": check dma-buf support, verify provider external-memory capabilities
- If "cost too high": adjust scheduler mode or provider selection

### KV Cache Instability

**Symptom:** `kv_migration_count` is non-zero during decode

**Diagnosis:**
1. Check `kv_home` in metrics
2. Verify `GGML_AMD_KV_HOME` setting
3. Check residency manager logs

**Solutions:**
- Set explicit KV home: `GGML_AMD_KV_HOME=hip`
- Increase residency idle threshold
- Check for memory pressure causing evictions

### Low Cache Hit Rate

**Symptom:** `cache_hits / (cache_hits + cache_misses)` < 0.90

**Diagnosis:**
1. Check cache size: `GGML_AMD_CACHE_MAX_SIZE`
2. Check cache directory: `GGML_AMD_CACHE_DIR`
3. Verify key stability (model hash, tensor names)

**Solutions:**
- Increase cache size
- Ensure cache directory is on SSD
- Check for model or tensor name changes between runs

### High Fence Wait Time

**Symptom:** `fence_wait_ns` is high

**Diagnosis:**
1. Check provider execution times
2. Verify region formation (too many small regions?)
3. Check for circular dependencies

**Solutions:**
- Improve region formation to reduce dependencies
- Increase fence timeout: `GGML_AMD_FENCE_TIMEOUT_MS`
- Check for provider saturation (high `queue_time_ns`)

### High Copy Bytes

**Symptom:** `copy_bytes` is high relative to `shared_bytes`

**Diagnosis:**
1. Check dma-buf allocation success
2. Verify provider import capabilities
3. Check for provider-private scratch memory

**Solutions:**
- Ensure dma-buf is first-class (check allocation domain)
- Verify provider supports dma-buf import
- Check for GEM PRIME fallback if system-heap fails

## Advanced Configuration

### Custom Cost Model

The cost model can be tuned by editing the cost cache directly:

```bash
# Dump current cost cache
cat $GGML_AMD_CACHE_DIR/cost_cache.json

# Edit and reload
# (requires restart)
```

### Custom Region Formation

Region formation heuristics can be adjusted via:

```bash
export GGML_AMD_REGION_MAX_NODES=64      # Max nodes per region
export GGML_AMD_REGION_MIN_NODES=4       # Min nodes per region
export GGML_AMD_REGION_FUSION_THRESHOLD=0.8  # Fusion benefit threshold
```

### Custom Residency Policy

Residency policies can be customized via:

```bash
export GGML_AMD_RESIDENCY_IDLE_THRESHOLD=10  # Iterations before eviction
export GGML_AMD_RESIDENCY_VRAM_BUDGET=8589934592  # 8 GB VRAM budget
export GGML_AMD_RESIDENCY_SYSTEM_BUDGET=17179869184  # 16 GB system budget
```

## Summary

`ggml-amd` runtime configuration balances performance, robustness, and observability. Start with `auto` settings and tune based on metrics. Use diagnostic mode for debugging, deterministic mode for production. Monitor metrics to identify bottlenecks and adjust configuration accordingly.
