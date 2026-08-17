// tile-amd-rdna3.cu
//
// W3 task 3.7 (docs/amd-tile-format-spec.md 3.4): the real, active HIP
// backend dispatch for GGML_OP_TILE_RDNA3_MATMUL. ggml-hip/CMakeLists.txt
// globs ggml-cuda/*.cu automatically (the same mechanism that already
// builds tile640-interleaved.cu into ggml-hip.so), so this file needs no
// separate build wiring.
//
// Pipeline: dequantize the i8+page/lane-scale A cluster into a bf16
// scratch buffer, convert B (f16/f32) into a bf16 scratch buffer, then
// dispatch the WMMA kernel shared with ggml-amd/tile/
// tile_amd_matmul_rdna3.cpp (tile_amd_matmul_rdna3.cuh - one copy of the
// WMMA lane-mapping code, not two). TS_TILE_GPU=0 skips the WMMA kernel
// and uses a plain per-thread scalar accumulate instead, on the same
// dequantized/converted device buffers - a GPU-resident fallback, not a
// host round-trip.

#include "tile-amd-rdna3.cuh"
#include "../ggml-amd/tile/tile_amd_matmul_rdna3.cuh"

#include "ggml.h"

#include <cstdint>
#include <cstdlib>

// One thread per output element of the dequantized (out_dim, in_dim) A
// matrix. Mirrors dequantize_row_tessera_t_rdna3 (ggml-quants.c)
// element-for-element - see that function for the scale-formula
// derivation.
__global__ static void ts_dequant_rdna3_to_bf16_kernel(
        const int8_t * __restrict__ packed,
        const __half * __restrict__ page_scales,
        const int8_t * __restrict__ lane_scales,
        __hip_bfloat16 * __restrict__ out,
        int64_t out_dim, int64_t in_dim,
        int64_t pages_per_row, int64_t words_per_row, int64_t lanes_per_row) {
    const int64_t row = blockIdx.y;
    const int64_t col = (int64_t) blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= out_dim || col >= in_dim) {
        return;
    }
    const int64_t p = col / TILE_AMD_RDNA3_PAGE_SIZE;
    const int64_t within_page = col % TILE_AMD_RDNA3_PAGE_SIZE;
    const int64_t l = within_page / TILE_AMD_RDNA3_LANE_SIZE;

    const float page_max = __half2float(page_scales[row * pages_per_row + p]);
    const int8_t ls = lane_scales[row * lanes_per_row + p * TILE_AMD_RDNA3_LANES_PER_PAGE + l];
    const float scale = page_max * ((float) ls * (1.0f / 127.0f));
    const int8_t q = packed[row * words_per_row + col];

    out[row * in_dim + col] = __float2bfloat16((float) q * scale);
}

// ggml stores B (activations) as [in_dim, n_tokens, ...] - ne[0]=in_dim is
// the fastest-varying dim, so each token's in_dim features are contiguous
// ("token-major, feature-contiguous": (n_cols, K) row-major in C-array
// terms). ts_tile_amd_matmul_rdna3_kernel wants its B argument as (K,N)
// row-major - the transpose of ggml's native layout. Rather than change
// the WMMA kernel (shared with the standalone reference in ggml-amd/),
// this conversion step transposes while it converts dtype: in[n*K+k] ->
// out[k*N+n].
__global__ static void ts_convert_transpose_f32_to_bf16_kernel(
        const float * __restrict__ in, __hip_bfloat16 * __restrict__ out, int64_t K, int64_t N) {
    const int64_t k = (int64_t) blockIdx.x * blockDim.x + threadIdx.x;
    const int64_t n = blockIdx.y;
    if (k >= K || n >= N) return;
    out[k * N + n] = __float2bfloat16(in[n * K + k]);
}

__global__ static void ts_convert_transpose_f16_to_bf16_kernel(
        const __half * __restrict__ in, __hip_bfloat16 * __restrict__ out, int64_t K, int64_t N) {
    const int64_t k = (int64_t) blockIdx.x * blockDim.x + threadIdx.x;
    const int64_t n = blockIdx.y;
    if (k >= K || n >= N) return;
    out[k * N + n] = __float2bfloat16(__half2float(in[n * K + k]));
}

// TS_TILE_GPU=0 fallback: one thread per output element, plain scalar
// accumulate over the already-dequantized/converted bf16 buffers. No
// WMMA, no lane-mapping risk - a deliberately simple GPU-resident path
// for when the WMMA kernel is disabled, not a performance target.
__global__ static void ts_scalar_matmul_bf16_kernel(
        const __hip_bfloat16 * __restrict__ A, const __hip_bfloat16 * __restrict__ B,
        float * __restrict__ C, int64_t M, int64_t N, int64_t K) {
    const int64_t row = blockIdx.y;
    const int64_t col = (int64_t) blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= M || col >= N) return;
    float acc = 0.0f;
    for (int64_t k = 0; k < K; ++k) {
        acc += __bfloat162float(A[row * K + k]) * __bfloat162float(B[k * N + col]);
    }
    C[row * N + col] = acc;
}

// dst is also ggml-native-laid-out ([out_dim, n_tokens, ...], ne[0]=
// out_dim fastest-varying = (n_cols, out_dim) row-major), the transpose
// of the (out_dim, n_cols) row-major C the WMMA/scalar kernels above
// produce. One more transposing pass, same reasoning as the B conversion.
__global__ static void ts_transpose_f32_kernel(
        const float * __restrict__ in, float * __restrict__ out, int64_t M, int64_t N) {
    // in is (M,N) row-major; out is (N,M) row-major: out[n*M+m] = in[m*N+n]
    const int64_t n = (int64_t) blockIdx.x * blockDim.x + threadIdx.x;
    const int64_t m = blockIdx.y;
    if (n >= N || m >= M) return;
    out[n * M + m] = in[m * N + n];
}

static int ts_tile_gpu_enabled_cuda() {
    static int cached = -1;
    if (cached < 0) {
        const char * env = getenv("TS_TILE_GPU");
        cached = (env != nullptr && env[0] == '0' && env[1] == '\0') ? 0 : 1;
    }
    return cached;
}

void ggml_cuda_op_tile_rdna3_matmul(
        ggml_backend_cuda_context & ctx,
        const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst) {
    GGML_ASSERT(src0->type == GGML_TYPE_I8);
    GGML_ASSERT(src1->type == GGML_TYPE_F16 || src1->type == GGML_TYPE_F32);
    GGML_ASSERT(dst->type  == GGML_TYPE_F32);

    cudaStream_t stream = ctx.stream();

    const ggml_tensor * A_packed      = src0;
    const ggml_tensor * A_page_scales = dst->src[1];
    const ggml_tensor * A_lane_scales = dst->src[2];
    const ggml_tensor * B             = src1;

    const int32_t out_dim  = ggml_get_op_params_i32(dst, 0);
    const int64_t in_dim   = B->ne[0];
    const int64_t n_tokens = B->ne[1];
    const int64_t n_batch  = B->ne[2];
    const int64_t n_seqs   = B->ne[3];
    const int64_t n_cols   = n_tokens * n_batch * n_seqs; // flattened batch dims of B/dst

    // Shapes not evenly divisible by 16 can't use the WMMA path at all
    // (task 3.6's guard); the scalar fallback below has no such
    // restriction, so it also serves as this op's general-shape path.
    const bool wmma_shape_ok =
        (out_dim % 16 == 0) && (in_dim % 16 == 0) && (n_cols % 16 == 0);

    const int64_t pages_per_row  = (in_dim + TILE_AMD_RDNA3_PAGE_SIZE - 1) / TILE_AMD_RDNA3_PAGE_SIZE;
    const int64_t words_per_row  = pages_per_row * TILE_AMD_RDNA3_PAGE_SIZE;
    const int64_t lanes_per_row  = pages_per_row * TILE_AMD_RDNA3_LANES_PER_PAGE;

    ggml_cuda_pool_alloc<__hip_bfloat16> A_bf16(ctx.pool(), (size_t) out_dim * in_dim);
    ggml_cuda_pool_alloc<__hip_bfloat16> B_bf16(ctx.pool(), (size_t) in_dim * n_cols);

    {
        const dim3 blk(256);
        const dim3 grd((unsigned) ((in_dim + blk.x - 1) / blk.x), (unsigned) out_dim);
        ts_dequant_rdna3_to_bf16_kernel<<<grd, blk, 0, stream>>>(
            (const int8_t *) A_packed->data,
            (const __half *) A_page_scales->data,
            (const int8_t *) A_lane_scales->data,
            A_bf16.get(), out_dim, in_dim, pages_per_row, words_per_row, lanes_per_row);
        CUDA_CHECK(cudaGetLastError());
    }
    {
        const dim3 blk(256);
        const dim3 grd((unsigned) ((in_dim + blk.x - 1) / blk.x), (unsigned) n_cols);
        if (B->type == GGML_TYPE_F32) {
            ts_convert_transpose_f32_to_bf16_kernel<<<grd, blk, 0, stream>>>(
                (const float *) B->data, B_bf16.get(), in_dim, n_cols);
        } else {
            ts_convert_transpose_f16_to_bf16_kernel<<<grd, blk, 0, stream>>>(
                (const __half *) B->data, B_bf16.get(), in_dim, n_cols);
        }
        CUDA_CHECK(cudaGetLastError());
    }

    // Scratch (out_dim, n_cols) row-major - the WMMA/scalar kernels'
    // native output layout, not ggml's. Transposed into dst->data below.
    ggml_cuda_pool_alloc<float> C_scratch(ctx.pool(), (size_t) out_dim * n_cols);

    if (ts_tile_gpu_enabled_cuda() && wmma_shape_ok) {
        const dim3 grid((unsigned) (n_cols / 16), (unsigned) (out_dim / 16));
        const dim3 block(32);
        ts_tile_amd_matmul_rdna3_kernel<<<grid, block, 0, stream>>>(
            A_bf16.get(), B_bf16.get(), C_scratch.get(), (int) out_dim, (int) n_cols, (int) in_dim);
        CUDA_CHECK(cudaGetLastError());
    } else {
        const dim3 blk(256);
        const dim3 grd((unsigned) ((n_cols + blk.x - 1) / blk.x), (unsigned) out_dim);
        ts_scalar_matmul_bf16_kernel<<<grd, blk, 0, stream>>>(
            A_bf16.get(), B_bf16.get(), C_scratch.get(), out_dim, n_cols, in_dim);
        CUDA_CHECK(cudaGetLastError());
    }

    {
        const dim3 blk(256);
        const dim3 grd((unsigned) ((n_cols + blk.x - 1) / blk.x), (unsigned) out_dim);
        ts_transpose_f32_kernel<<<grd, blk, 0, stream>>>(
            C_scratch.get(), (float *) dst->data, out_dim, n_cols);
        CUDA_CHECK(cudaGetLastError());
    }
}
