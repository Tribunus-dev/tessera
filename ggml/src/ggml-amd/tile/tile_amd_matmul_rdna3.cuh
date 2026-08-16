// tile_amd_matmul_rdna3.cuh
//
// Shared WMMA device kernel for the RDNA3 tile matmul, included by both:
//   - ggml-amd/tile/tile_amd_matmul_rdna3.cpp (standalone host launcher,
//     task 3.6 - ggml-amd/ is a staging area, not yet in the active build
//     graph, but kept as the spec-cited reference implementation)
//   - ggml-cuda/tile-amd-rdna3.cu (the real, active HIP backend dispatch,
//     task 3.7 - ggml-hip/CMakeLists.txt globs ggml-cuda/*.cu automatically)
//
// One copy of the kernel, not two: the WMMA lane-mapping in here is the
// one piece of this whole feature with real correctness risk if hand-
// transcribed wrong (see tile_amd_matmul_rdna3.cpp's header comment for
// the AMD GPUOpen source and the reasoning), so it must not drift between
// two independently-maintained copies.

#pragma once

#include <hip/hip_runtime.h>
#include <hip/hip_bf16.h>

#include <cstdint>

typedef short __attribute__((ext_vector_type(16))) ts_wmma_short16;
typedef float __attribute__((ext_vector_type(8)))  ts_wmma_float8;

// One wave (32 threads) computes one 16x16 output tile, looping over the
// K dimension in 16-wide sub-tiles and accumulating in registers. See
// tile_amd_matmul_rdna3.cpp for the full per-lane layout derivation.
__global__ static void ts_tile_amd_matmul_rdna3_kernel(
        const __hip_bfloat16 * __restrict__ A, // (M, K) row-major
        const __hip_bfloat16 * __restrict__ B, // (K, N) row-major
        float * __restrict__ C,                // (M, N) row-major
        int M, int N, int K) {
    (void) M;
    const int tile_row = blockIdx.y;
    const int tile_col = blockIdx.x;
    const int lane = threadIdx.x & 15;
    const int half = threadIdx.x >> 4;

    ts_wmma_float8 acc = {0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f};

    const int num_k_tiles = K >> 4;
    for (int kt = 0; kt < num_k_tiles; ++kt) {
        ts_wmma_short16 a_frag;
        ts_wmma_short16 b_frag;
        const int a_row = tile_row * 16 + lane;
        const int b_col = tile_col * 16 + lane;
#pragma unroll
        for (int ele = 0; ele < 16; ++ele) {
            const int a_col = kt * 16 + ele;
            const int b_row = kt * 16 + ele;
            a_frag[ele] = *reinterpret_cast<const short *>(&A[(int64_t) a_row * K + a_col]);
            b_frag[ele] = *reinterpret_cast<const short *>(&B[(int64_t) b_row * N + b_col]);
        }
        acc = __builtin_amdgcn_wmma_f32_16x16x16_bf16_w32(a_frag, b_frag, acc);
    }

#pragma unroll
    for (int ele = 0; ele < 8; ++ele) {
        const int row = ele * 2 + half;
        const int g_row = tile_row * 16 + row;
        const int g_col = tile_col * 16 + lane;
        C[(int64_t) g_row * N + g_col] = acc[ele];
    }
}
