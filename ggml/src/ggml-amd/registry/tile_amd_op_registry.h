// tile_amd_op_registry.h
//
// AMD tile-kernel dispatch registry (docs/amd-tile-format-spec.md 8.1a /
// 11.8). Mirrors AITER's SMEM_CAPACITY_MAP gating shape structurally (not
// by vendoring code): callers key a lookup on
// (arch_target, dtype, sparse, microscale, M, N, K) and get back either a
// real kernel function pointer or a null one meaning "no GPU kernel for
// this combination yet - use the CPU/scalar fallback".
//
// W3 task 3.4 (host-amd-implementation-plan.md Wave 3) populates exactly
// ONE real row (AMD_RDNA3, bf16, 16x16x16 - the native WMMA tile, see
// docs/amd-tile-format-spec.md 3.4) plus explicit fallback rows for every
// other arch this wave does not implement. No autotune: the RDNA3 row's
// BM/BN/BK/stages are seeded directly from the tile geometry, not measured
// (see tools/quantize/tessera/configs/tile_amd_kernels.csv's comment
// header for the seed-vs-measured distinction).
//
// This registry is hand-populated C++, not a runtime CSV parser: the CSV
// (spec 8.1a artifact 2) is the human-facing, future-measurement-campaign
// source of truth that a later wave's build_amd_kernels.py (spec 8.1a
// artifact 3, out of scope this wave - no autotune yet) would consume to
// regenerate tables like this one. Wiring an actual CSV-parse-at-runtime
// path for a single hand-seeded row would be premature - see spec 8.1a's
// own "Empty in Wave A.1; populated by Wave B-I measurement campaigns"
// framing for the CSV, and this file's own tile_amd_kernel_table[]
// mirroring the CSV's one populated row by hand until that machinery
// exists.

#pragma once

// ggml-common.h only emits its C++ definitions when GGML_COMMON_DECL_CPP is
// defined before the include; without it the header is a no-op and
// enum ts_arch_target would be left undefined. Matches the pattern used by
// tools/quantize/tessera/tile-detect.h.
#ifndef GGML_COMMON_DECL_CPP
#  define GGML_COMMON_DECL_CPP
#  include "ggml-common.h"
#else
#  include "ggml-common.h"
#endif

#include <cstdint>

// Compute dtype the kernel's WMMA/MFMA operands use. This is the KERNEL's
// internal compute type, not the GGUF on-disk storage quant (criterion 19
// pins amd.tile.quant="i8" for the on-disk format; task 3.6's kernel
// dequantizes i8-packed weights to bf16 before the WMMA call, reusing the
// bf16 WMMA primitive already vendored in ggml-amd/ck/ - see
// docs/amd-tile-format-spec.md 3.4 and the CK vendoring rationale in
// ggml-amd/ck/README.md).
enum tile_amd_dtype {
    TILE_AMD_DTYPE_I8 = 0,
    TILE_AMD_DTYPE_F16,
    TILE_AMD_DTYPE_BF16,
    TILE_AMD_DTYPE_I4,
};

// Dispatch key: (arch_target, dtype, sparse, microscale, M, N, K) per spec
// 11.8.1. M/N/K of 0 means "any shape" (a wildcard row) - task 3.4's one
// real row is shape-specific (16x16x16, the native WMMA tile); the
// fallback rows are wildcards since "no kernel" applies to every shape.
struct tile_amd_dispatch_key {
    enum ts_arch_target arch_target;
    enum tile_amd_dtype dtype;
    bool                sparse;
    bool                microscale;
    int64_t             M;
    int64_t             N;
    int64_t             K;
};

// GEMM-primitive kernel entrypoint: A/B are device pointers in the dtype's
// native WMMA operand layout, C is a device f32 accumulator buffer,
// row-major (spec 3.4's cluster tensor layout). Returns false on any
// launch/status failure (caller falls back to the CPU reference) rather
// than aborting - matches this codebase's established GPU-kill-switch
// convention (TS_TILE_GPU=0, checked by the caller before even reaching
// the registry; hipGetLastError checked inside the kernel implementation
// itself, task 3.6).
typedef bool (*tile_amd_kernel_t)(const void * A, const void * B, float * C,
                                   int64_t M, int64_t N, int64_t K,
                                   void * stream);

struct tile_amd_kernel_entry {
    struct tile_amd_dispatch_key key;
    tile_amd_kernel_t            kernel;       // nullptr = no GPU kernel yet, use CPU fallback
    const char *                 kernel_name;  // CSV `kernelName` column
    const char *                 anchor_hash;  // CSV `anchor_hash` column - content fingerprint, "" until measured
};

// Looks up the best-matching entry for the given key. Exact match on
// (arch_target, dtype, sparse, microscale); M/N/K match either exactly or
// against a wildcard (0/0/0) row. Returns nullptr if no row at all exists
// for this arch_target (a genuinely unlisted arch) - callers should treat
// that identically to a listed-but-kernel-null row: use the CPU fallback.
const struct tile_amd_kernel_entry * tile_amd_op_registry_lookup(
    enum ts_arch_target arch_target,
    enum tile_amd_dtype dtype,
    bool                sparse,
    bool                microscale,
    int64_t             M,
    int64_t             N,
    int64_t             K);

// Number of rows currently in the table - exposed for tests, not part of
// the dispatch contract.
int tile_amd_op_registry_row_count(void);
