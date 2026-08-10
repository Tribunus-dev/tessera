//
// tile-detect.cpp
//
// Runtime GPU tile-geometry detection for the Tessera pack subcommand.
// Probes the host Metal device family on macOS and maps it to the
// optimal ts_tile_config. Non-Apple hosts (Intel integrated / unknown)
// fall back to T512. The detection is best-effort: on any probe failure
// the safe T640 default is returned.
//
// The MTLGPUFamilyAppleN -> {T640,T512} mapping (see docs/tile-neutral-
// export-design.md):
//   Apple7..9  (M1/M2/M3): T640 (radix-243, the native SIMD-group tile)
//   Apple10+   (M4+)      : T640 (safe default until benchmarked)
//   Intel / Macs without Apple-family Metal: T512
//   Unknown / no Metal device: T640
//
// family probe: ggml_backend_metal_supports_family(backend, N) checks
// MTLGPUFamilyApple1 + N - 1 (== MTLGPUFamilyAppleN), so family=7 is
// Apple7 (M1), family=10 is Apple10 (M4).

#include "tile-detect.h"

#include "ggml.h"
#include "ggml-backend.h"

#include <cstdio>
#include <string>

#if defined(__APPLE__)
#  include <sys/sysctl.h>
#endif

#if defined(GGML_USE_METAL)
#  include "ggml-metal.h"
#endif

// Probe the highest supported Apple-family Metal GPU. Returns:
//   family >= 1: the highest MTLGPUFamilyAppleN supported (Apple Silicon)
//   0          : a Metal device exists but no Apple family (Intel Mac)
//   -1         : no Metal backend at all (non-Apple host / probe failure),
//                i.e. genuinely "unknown" rather than Intel
static int ts_detect_apple_family() {
#if defined(GGML_USE_METAL)
    ggml_backend_t backend = ggml_backend_metal_init();
    if (backend == nullptr) {
        return -1;
    }
    int family = 0;
    // Walk from a high bound down to 1; the first supported family is the
    // highest. MTLGPUFamilyApple1..N are contiguous in the enum, and the
    // public ggml_backend_metal_supports_family maps N -> AppleN.
    // Ceiling at 16 covers M1 (7) through M5+ (likely 11-12) with headroom.
    for (int n = 16; n >= 1; --n) {
        if (ggml_backend_metal_supports_family(backend, n)) {
            family = n;
            break;
        }
    }
    ggml_backend_free(backend);
    return family;
#else
    // No Metal backend compiled in: we cannot distinguish Intel from a
    // truly unknown host, so report "unknown".
    return -1;
#endif
}

struct ts_tile_config ts_detect_tile_config() {
    const int family = ts_detect_apple_family();

    // Detect M5+ for kernel-path selection. The tile geometry stays T640
    // regardless, but on M5 the Metal kernel uses MPP matmul2d (cooperative
    // tensor via the GPU Neural Accelerators) instead of scalar FMA. This
    // detection is logged so diagnostics can confirm the M5 fast path.
#if defined(__APPLE__)
    {
        char brand[128] = {};
        size_t sz = sizeof(brand);
        if (sysctlbyname("machdep.cpu.brand_string", brand, &sz, nullptr, 0) == 0) {
            std::string s(brand);
            bool is_m5 = s.find("M5") != std::string::npos ||
                         s.find("M6") != std::string::npos;
            if (is_m5) {
                fprintf(stderr, "tile-detect: %s detected; MPP cooperative-tensor "
                                "kernel path active (T640 tile, MMA-accelerated)\n",
                        s.c_str());
            }
        }
    }
#endif

    if (family >= 7) {
        // Apple Silicon (M1..M5+): T640 tile. The tile geometry (32 lanes,
        // 20 elements/lane, 640 page) is identical across all generations.
        // M5+ uses the MPP matmul2d kernel path (detected above); M1-M4
        // uses the scalar FMA path. Same GGUF, different kernel.
        return ts_tile_config_t640();
    }
    if (family >= 1) {
        // An Apple-family number below 7 (older integrated Apple GPUs that
        // do not appear in practice on shipping Macs). Treat as Intel-class.
        return ts_tile_config_t512();
    }
    if (family == 0) {
        // Metal device present but no Apple family: an Intel Mac. T512 is
        // the 2-bit tile tuned for the Intel SIMD width.
        return ts_tile_config_t512();
    }
    // family == -1: no Metal backend (non-Apple host or probe failure).
    // We cannot tell Intel from unknown here, so use the safe T640 default.
    return ts_tile_config_t640();
}
