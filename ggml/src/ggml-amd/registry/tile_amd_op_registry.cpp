// tile_amd_op_registry.cpp
//
// See tile_amd_op_registry.h for the design rationale (why this is a
// hand-populated table, not a runtime CSV parser, in W3).
//
// Table mirrors tools/quantize/tessera/configs/tile_amd_kernels.csv row
// for row - keep the two in sync by hand until a later wave's
// build_amd_kernels.py generates one from the other.
//
// RDNA 3.5 (gfx1103/1150/1151) is NOT a distinct row here: per
// docs/amd-tile-format-spec.md 3.6, RDNA35 has no wire format of its own -
// the loader resolves amd.tile.parent ("RDNA3" or "RDNA2") BEFORE this
// registry is ever consulted, so callers always look up with
// TS_ARCH_AMD_RDNA3 (or _RDNA2) for an RDNA35 host, never
// TS_ARCH_AMD_RDNA35 itself.

#include "tile_amd_op_registry.h"

#include <cstddef>
#include <cstring>

// task 3.6 defines the real RDNA3 GEMM kernel and will replace this
// forward declaration's null-pointer use below with the real function
// once it lands - see the .kernel = nullptr comment on the RDNA3 row.
// Declared here (not defined) purely so the intended signature is
// documented next to its registry entry; nothing currently calls it.
extern "C" bool tile_amd_matmul_rdna3_bf16_16x16x16(
    const void * A, const void * B, float * C,
    int64_t M, int64_t N, int64_t K, void * stream);

static const struct tile_amd_kernel_entry tile_amd_kernel_table[] = {
    // --- the one real row this wave ships ---
    // Shape-specific (16x16x16, the native WMMA result tile - spec 3.4);
    // not a wildcard, since this wave has exactly one kernel and no
    // generalized tiling/blocking beyond the native shape.
    {
        /* key */ {
            /* arch_target */ TS_ARCH_AMD_RDNA3,
            /* dtype       */ TILE_AMD_DTYPE_BF16,
            /* sparse      */ false,
            /* microscale  */ false,
            /* M */ 16, /* N */ 16, /* K */ 16,
        },
        // nullptr until task 3.6 lands the real kernel - deliberately
        // gap-safe (same pattern as W3 task 3.3's GGML_TYPE_TESSERA_T_RDNA3
        // traits entry): a caller that checks `.kernel != nullptr` before
        // dispatching gets the CPU fallback, not a null-pointer call.
        /* kernel */ nullptr,
        /* kernel_name */ "tile_amd_matmul_rdna3_bf16_16x16x16",
        /* anchor_hash */ "", // no autotune this wave; nothing to fingerprint yet
    },
    // --- CPU-fallback rows: archs this wave does not implement ---
    // Wildcard (M=N=K=0): "no GPU kernel for this arch at any shape".
    { { TS_ARCH_AMD_GCN,   TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_gcn",   "" },
    { { TS_ARCH_AMD_RDNA1, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_rdna1", "" },
    { { TS_ARCH_AMD_RDNA2, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_rdna2", "" },
    { { TS_ARCH_AMD_RDNA4, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_rdna4", "" },
    { { TS_ARCH_AMD_CDNA1, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_cdna1", "" },
    { { TS_ARCH_AMD_CDNA2, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_cdna2", "" },
    { { TS_ARCH_AMD_CDNA3, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_cdna3", "" },
    { { TS_ARCH_AMD_CDNA4, TILE_AMD_DTYPE_F16, false, false, 0, 0, 0 }, nullptr, "cpu_fallback_cdna4", "" },
};

static const int tile_amd_kernel_table_count =
    (int) (sizeof(tile_amd_kernel_table) / sizeof(tile_amd_kernel_table[0]));

static bool key_matches(const struct tile_amd_dispatch_key & row, enum ts_arch_target arch_target,
                         enum tile_amd_dtype dtype, bool sparse, bool microscale,
                         int64_t M, int64_t N, int64_t K) {
    if (row.arch_target != arch_target || row.sparse != sparse || row.microscale != microscale) {
        return false;
    }
    // Fallback rows key on arch_target alone (dtype/shape wildcarded via
    // M=N=K=0): they apply regardless of what dtype/shape the caller
    // asked for, since there is no kernel for this arch at all yet.
    const bool row_is_wildcard = (row.M == 0 && row.N == 0 && row.K == 0);
    if (row_is_wildcard) {
        return true;
    }
    return row.dtype == dtype && row.M == M && row.N == N && row.K == K;
}

const struct tile_amd_kernel_entry * tile_amd_op_registry_lookup(
        enum ts_arch_target arch_target, enum tile_amd_dtype dtype,
        bool sparse, bool microscale, int64_t M, int64_t N, int64_t K) {
    // Exact-shape rows before wildcard rows, so a future non-wildcard row
    // for an arch that also has a wildcard fallback row takes priority.
    const struct tile_amd_kernel_entry * wildcard_match = nullptr;
    for (int i = 0; i < tile_amd_kernel_table_count; ++i) {
        const struct tile_amd_kernel_entry & entry = tile_amd_kernel_table[i];
        if (!key_matches(entry.key, arch_target, dtype, sparse, microscale, M, N, K)) {
            continue;
        }
        const bool is_wildcard = (entry.key.M == 0 && entry.key.N == 0 && entry.key.K == 0);
        if (!is_wildcard) {
            return &entry;
        }
        if (wildcard_match == nullptr) {
            wildcard_match = &entry;
        }
    }
    return wildcard_match;
}

int tile_amd_op_registry_row_count(void) {
    return tile_amd_kernel_table_count;
}
