#pragma once

//
// tile-detect.h
//
// Runtime GPU tile-geometry detection for the Tessera pack subcommand.
// ts_detect_tile_config() probes the host GPU (Apple Metal device family
// on macOS, Intel/integrated otherwise) and returns the ts_tile_config
// that matches its optimal page/lane geometry:
//   Apple Silicon (M1/M2/M3/M4+) -> T640 (radix-243)
//   Intel / non-Apple            -> T512 (2-bit)
//   unknown                      -> T640 (safe default)
//
// The detection is best-effort: if the probe fails (no Metal device, the
// backend symbols are unavailable, or the host is not Apple), the safe T640
// default is returned. Callers that want a specific geometry regardless of
// the host GPU pass it explicitly via --tile {t640|t512|t1024}.

// ggml-common.h only emits its C++ definitions when GGML_COMMON_DECL_CPP is
// defined before the include; without it the header is a no-op and ts_tile_config
// would be left undefined (it is returned by value below). Match the pattern
// used by tessera-ternary.h.
#ifndef GGML_COMMON_DECL_CPP
#  define GGML_COMMON_DECL_CPP
#  include "ggml-common.h"
#else
#  include "ggml-common.h"
#endif

// Probe the host GPU and return the recommended tile config. The returned
// struct is a value copy (no ownership). Always returns a usable config.
struct ts_tile_config ts_detect_tile_config();

// ---------------------------------------------------------------------------
// W3 task 3.1: AMD arch taxonomy (docs/amd-tile-format-spec.md Section 2's
// dispatch table). Gated on GGML_USE_HIP || TS_USE_ROCBLAS (D3 W3) - never
// abort on detection failure, UNKNOWN routes to the T640 fallback path with
// a stderr warning at the --quant=host-amd call site.
// ---------------------------------------------------------------------------

enum ts_amd_arch {
    TS_ARCH_AMD_GCN = 0,
    TS_ARCH_AMD_RDNA1,
    TS_ARCH_AMD_RDNA2,
    TS_ARCH_AMD_RDNA3,
    TS_ARCH_AMD_RDNA35,
    TS_ARCH_AMD_RDNA4,
    TS_ARCH_AMD_CDNA1,
    TS_ARCH_AMD_CDNA2,
    TS_ARCH_AMD_CDNA3,
    TS_ARCH_AMD_CDNA4,
    TS_ARCH_AMD_UNKNOWN,
};

// Classifies a gcnArchName string (e.g. "gfx1103", "gfx90a:sramecc+:xnack-")
// per the spec's Section 2 gfx-target table. Pure string logic, no device
// access - this is what the unit test exercises directly (inject arbitrary
// arch strings without needing real hardware per arch), separated from the
// device probe below so the taxonomy itself is testable independent of
// hipGetDeviceProperties.
enum ts_amd_arch ts_classify_amd_arch_name(const char * gcn_arch_name);

// Probes device 0 via hipGetDeviceProperties() -> gcnArchName (NOT
// hipDeviceGetAttribute(hipDeviceAttributeGcnArch, ...) - that attribute
// was removed in ROCm 7 headers, renamed hipDeviceAttributeUnused4).
// Returns TS_ARCH_AMD_UNKNOWN on any HIP error, no HIP/ROCBLAS support
// compiled in, or no device present - detection failure is never fatal.
enum ts_amd_arch ts_detect_amd_arch();
