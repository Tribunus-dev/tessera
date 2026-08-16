// tile_amd_matmul_rdna3.cpp
//
// W3 task 3.6 (host-amd-implementation-plan.md Wave 3): the Wave C tile
// kernel. Tessera-original code built on top of the vendored CK WMMA
// primitive (ggml-amd/ck/ck_tile/core/arch/mma/wmma/wmma_gfx11.hpp) - NOT
// CK's DeviceGemm pipeline framework (docs/amd-tile-format-spec.md 8.3).
//
// Computes C[M,N] = A[M,K] @ B[K,N] (all row-major, bf16 operands, f32
// accumulate) by tiling into 16x16x16 blocks and issuing one
// __builtin_amdgcn_wmma_f32_16x16x16_bf16_w32 per (M-tile, N-tile, K-tile),
// one wave (32 threads) per output tile, accumulating across the K-tile
// loop before a single write-back. No LDS staging, no packed-dot
// micro-optimization, no interleaved load/store: the AITER campaign found
// packed-dot regressed e2e on this bandwidth-bound APU and destabilized a
// kernel, and an interleaved-load bug corrupted every 8th element of a
// different kernel from exactly that pattern - both explicitly avoided
// here per the master plan's task 3.6 guidance.
//
// Per-lane operand/accumulator layout (the "gfx11 C-distribution permute"
// the master plan flags as load-bearing): AMD's own GPUOpen WMMA-on-RDNA3
// article (https://gpuopen.com/learn/wmma_on_rdna3/) gives the mapping
// this file implements - for lane = threadIdx.x % 16, half = threadIdx.x
// / 16, within one 16x16x16 tile:
//   A: a_frag[ele] = A[16*lane + ele]   (lane reads row `lane`, all 16 K)
//   B: b_frag[ele] = B[16*ele + lane]   (lane reads col `lane`, strided by 16)
//   C: row = ele*2 + half, col = lane   (2 lanes share a column, split
//                                        into even/odd rows across the 8
//                                        accumulator elements each holds)
// This is the one piece of this kernel with real correctness risk if the
// mapping were transcribed wrong (row/col swapped, wrong half, etc.) - it
// is verified bit-for-bit against the CPU reference at M=N=K=16 in task
// 3.7 (master-plan criterion 20), not trusted on documentation alone.

#include <hip/hip_runtime.h>
#include <hip/hip_bf16.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>

typedef short __attribute__((ext_vector_type(16))) ts_wmma_short16;
typedef float __attribute__((ext_vector_type(8)))  ts_wmma_float8;

// One wave (32 threads) computes one 16x16 output tile, looping over the
// K dimension in 16-wide sub-tiles and accumulating in registers.
__global__ void ts_tile_amd_matmul_rdna3_kernel(
        const __hip_bfloat16 * __restrict__ A, // (M, K) row-major
        const __hip_bfloat16 * __restrict__ B, // (K, N) row-major
        float * __restrict__ C,                // (M, N) row-major
        int M, int N, int K) {
    (void) M; // M is only needed by the launch grid, not the tile body
    const int tile_row = blockIdx.y; // which 16-row block of the M dim
    const int tile_col = blockIdx.x; // which 16-col block of the N dim
    const int lane = threadIdx.x & 15;
    const int half = threadIdx.x >> 4;

    ts_wmma_float8 acc = {0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f};

    const int num_k_tiles = K >> 4; // K/16, guaranteed exact by the launch guard
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

// TS_TILE_GPU=0 forces the CPU scalar-reference fallback (checked once,
// cached - env vars don't change mid-process). Never aborts: any launch
// failure or unsupported shape returns false, and the caller is expected
// to fall back to ggml_compute_forward_tile_rdna3_matmul (task 3.7).
static int ts_tile_gpu_enabled() {
    static int cached = -1;
    if (cached < 0) {
        const char * env = getenv("TS_TILE_GPU");
        cached = (env != nullptr && env[0] == '0' && env[1] == '\0') ? 0 : 1;
    }
    return cached;
}

// Registry-shaped entrypoint (tile_amd_kernel_t, ggml-amd/registry/
// tile_amd_op_registry.h). A/B/C are device pointers; A and B are bf16
// row-major ((M,K) and (K,N) respectively), C is f32 row-major (M,N).
// Returns false (caller must use the CPU fallback) on: the GPU kill
// switch, a shape not divisible by 16 in all three dims, or a launch
// failure - never aborts. Does NOT synchronize the stream; the caller is
// responsible for that before reading C (matches an async-launch
// convention, not an implicit-blocking one).
extern "C" bool tile_amd_matmul_rdna3_bf16_16x16x16(
        const void * A, const void * B, float * C,
        int64_t M, int64_t N, int64_t K, void * stream) {
    if (!ts_tile_gpu_enabled()) {
        return false;
    }
    if (M <= 0 || N <= 0 || K <= 0 || (M % 16) != 0 || (N % 16) != 0 || (K % 16) != 0) {
        return false;
    }

    const dim3 grid((unsigned) (N / 16), (unsigned) (M / 16));
    const dim3 block(32);
    hipStream_t s = (hipStream_t) stream;

    ts_tile_amd_matmul_rdna3_kernel<<<grid, block, 0, s>>>(
        (const __hip_bfloat16 *) A, (const __hip_bfloat16 *) B, C,
        (int) M, (int) N, (int) K);

    const hipError_t err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "tile_amd_matmul_rdna3: kernel launch failed: %s\n",
                hipGetErrorString(err));
        return false;
    }
    return true;
}
