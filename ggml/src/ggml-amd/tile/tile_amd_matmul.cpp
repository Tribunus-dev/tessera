// tile_amd_matmul.cpp — STUB for TILE_AMD CK MFMA kernel (AMD layout, like tile640_matmul.cpp:553)
// See docs/backend/AMD.md Final and .agents/plans/2026-08-08-tile-amd-hetro.md
// W5: HIP CK gfx1201 (R9700) + gfx942 (MI300) via ck_tile_gemm / ck_gemm_a8w8_bpreshuffle
// Contract mirrors ggml_tile640_matmul in ggml/include/ggml.h:2641 / ggml/src/ggml.c:6417:
//   A: TILE_AMD weight (K, M) column-major packed (QK_AMD=64 bpreshuffle), B: row-major (N, K), C: (N, M)
// Ground truth: dequantize_row_tessera_amd + ts_decode_per_row_meta_amd (ggml-quants.h) reused for GA.
#pragma once
// TODO: include <hip/hip_runtime.h>, <ck_tile/...>, ggml-impl.h, ggml-quants.h
// TODO: void tile_amd_matmul_ck(const void* A_packed, const void* scales, const void* outliers, const float* B, float* C, int64_t N, int64_t M, int64_t K);

// Fallback: route to ggml_compute_forward_tile_amd_matmul scalar ref (ggml-cpu/ops.cpp) until CK tuned for gfx1201/gfx942.
