//
// ggml-amd-tile-hip.cu
//
// HIP kernel implementations for the four Tile640 semantic operations.
// Reference semantics: ggml-cpu/ops.cpp ggml_compute_forward_tile640_*.
// The kernels are correctness-first; MFMA-tuned variants are future work.
//

#include "ggml-amd-tile-hip.h"

#include <hip/hip_runtime.h>
#include <hip/hip_fp16.h>
#include <cstdint>
#include <cstdio>

// Tile640 geometry (matches ggml-common.h and the CPU reference).
#define T640_PAGE_SIZE      640
#define T640_LANE_SIZE      20
#define T640_LANES_PER_PAGE 32
#define T640_WORDS_PER_PAGE 32

// -- half-precision helpers --------------------------------------------------
// HIP half type is __half; conversions go through __half2float / __float2half
// from hip/hip_fp16.h. The CPU reference uses ggml_fp16_t (uint16_t) and
// ggml_fp16_to_fp32; on device we use the native __half.

static __device__ __forceinline__ float t640_half_to_float(unsigned short v) {
    return __half2float(*reinterpret_cast<const __half *>(&v));
}

// -- TILE640_DEQUANT kernel --------------------------------------------------
//
// One thread per output element. The thread determines which page, lane and
// intra-lane position it owns, reads the packed word for that lane, extracts
// the trit at its position, and writes scale * trit_sign to dst.
//
// After the ternary pass, threads whose element falls at an outlier column
// overwrite with the outlier value (CSR addback). The outlier pass uses a
// separate kernel to avoid divergent control flow in the main dequant.
//

__global__ void kernel_tile640_dequant(
        const uint32_t *       __restrict__ packed,
        const unsigned short * __restrict__ page_scales,
        const int8_t *         __restrict__ lane_scales,
        const int32_t *        __restrict__ outlier_row_offsets,
        const int32_t *        __restrict__ outlier_cols,
        const unsigned short * __restrict__ outlier_vals,
        float *                __restrict__ dst,
        int row_width,
        int n_rows,
        int n_elements) {

    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_elements) return;

    const int row = idx / row_width;
    const int col = idx % row_width;

    const int page_idx   = col / T640_PAGE_SIZE;
    const int page_col   = col % T640_PAGE_SIZE;
    const int lane_idx   = page_col / T640_LANE_SIZE;
    const int lane_pos   = page_col % T640_LANE_SIZE;

    const int pages_per_row = (row_width + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int words_per_row = pages_per_row * T640_WORDS_PER_PAGE;

    const uint32_t word = packed[row * words_per_row + page_idx * T640_WORDS_PER_PAGE + lane_idx];

    // Extract trit at lane_pos: base-3 digit extraction (LSB-first).
    uint32_t w = word;
    int trit = 0;
    for (int i = 0; i < lane_pos; i++) {
        w /= 3u;
    }
    trit = (int)(w % 3u);

    const float page_scale = t640_half_to_float(page_scales[row * pages_per_row + page_idx]);
    const float lane_s     = (float) lane_scales[row * words_per_row + page_idx * T640_LANES_PER_PAGE + lane_idx] * (1.0f / 127.0f);
    const float scale      = page_scale * lane_s;

    float val = (trit == 1) ? scale : (trit == 2) ? -scale : 0.0f;

    // Outlier addback: scan this row's CSR range for a matching column.
    const int off_lo = outlier_row_offsets[row];
    const int off_hi = outlier_row_offsets[row + 1];
    for (int k = off_lo; k < off_hi; k++) {
        if (outlier_cols[k] == col) {
            val = t640_half_to_float(outlier_vals[k]);
            break;
        }
    }

    dst[idx] = val;
}

// -- TILE640_DEQUANT outlier kernel (separate pass) --------------------------
//
// One thread per outlier entry. Each thread overwrites dst[row * row_width + col]
// with the outlier value. This is the sparse CSR addback pass.
//

__global__ void kernel_tile640_dequant_outliers(
        const int32_t *        __restrict__ outlier_row_offsets,
        const int32_t *        __restrict__ outlier_cols,
        const unsigned short * __restrict__ outlier_vals,
        float *                __restrict__ dst,
        int row_width,
        int n_outliers_total) {

    const int gk = blockIdx.x * blockDim.x + threadIdx.x;
    if (gk >= n_outliers_total) return;

    // Binary-search the CSR offsets to find which row owns gk.
    // For small outlier counts a linear scan is fine; for large counts
    // the bisection is O(log n) per thread.
    // We walk the offsets to find the row: offsets[row] <= gk < offsets[row+1].
    // Since we don't have n_rows here, we use the fact that outlier_cols[gk]
    // is the column and we need the row. The offsets array is monotonically
    // non-decreasing. We search for the largest row such that offsets[row] <= gk.
    // The caller passes n_outliers_total = offsets[n_rows], so we can recover
    // n_rows from context. For simplicity we do a linear scan from the
    // expected row range. A future optimization can pass n_rows and use
    // binary search.
    //
    // Simpler approach: the row for entry gk is the largest r such that
    // outlier_row_offsets[r] <= gk. We scan from gk downward (the offsets
    // array is indexed by row, not by entry). This is O(n_rows) worst case.
    // For the reference kernel this is acceptable.
    int row = 0;
    // Walk forward until offsets[row+1] > gk.
    while (outlier_row_offsets[row + 1] <= gk) {
        row++;
    }

    const int col = outlier_cols[gk];
    const float val = t640_half_to_float(outlier_vals[gk]);
    dst[(int64_t) row * row_width + col] = val;
}

// -- TILE640_MATMUL kernel ---------------------------------------------------
//
// Reference matmul: one thread per (output_row, token) pair. Each thread
// dequantizes the full weight row on-the-fly and accumulates the dot product
// with the activation vector. This is the simplest correct implementation;
// MFMA and shared-memory tiling are future optimizations.
//
// Output layout: dst[i, j, b, s] where i = out_dim, j = token, b = batch,
// s = seq. dst is [out_dim, n_tokens, n_batch, n_seqs] contiguous.
//

__global__ void kernel_tile640_matmul(
        const uint32_t *       __restrict__ A_packed,
        const unsigned short * __restrict__ A_page_scales,
        const int8_t *         __restrict__ A_lane_scales,
        const int32_t *        __restrict__ A_outlier_row_offsets,
        const int32_t *        __restrict__ A_outlier_cols,
        const unsigned short * __restrict__ A_outlier_vals,
        const float *          __restrict__ B,
        float *                __restrict__ dst,
        int out_dim,
        int in_dim,
        int n_tokens,
        int n_batch,
        int n_seqs,
        int pages_per_row,
        int words_per_row,
        int n_outliers_total) {

    const int global_idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int total_rows = out_dim * n_tokens * n_batch * n_seqs;
    if (global_idx >= total_rows) return;

    const int i = global_idx % out_dim;
    const int j = (global_idx / out_dim) % n_tokens;
    const int b = (global_idx / (out_dim * n_tokens)) % n_batch;
    const int s = global_idx / (out_dim * n_tokens * n_batch);

    const uint32_t *       A_row  = A_packed + (int64_t) i * words_per_row;
    const unsigned short * ps_row = A_page_scales + (int64_t) i * pages_per_row;
    const int8_t *         ls_row = A_lane_scales + (int64_t) i * pages_per_row * T640_LANES_PER_PAGE;

    const int row_off_lo = A_outlier_row_offsets[i];
    const int row_off_hi = A_outlier_row_offsets[i + 1];

    // B layout: [in_dim, n_tokens, n_batch, n_seqs] contiguous.
    // B[k, j, b, s] = B[((s * n_batch + b) * n_tokens + j) * in_dim + k]
    const float * B_col = B + ((int64_t) s * n_batch + b) * n_tokens * in_dim +
                          (int64_t) j * in_dim;

    float acc = 0.0f;

    for (int p = 0; p < pages_per_row; p++) {
        const float page_max = t640_half_to_float(ps_row[p]);
        for (int l = 0; l < T640_LANES_PER_PAGE; l++) {
            const float lane_s_f = (float) ls_row[p * T640_LANES_PER_PAGE + l] * (1.0f / 127.0f);
            const float scale = page_max * lane_s_f;

            uint32_t word = A_row[p * T640_WORDS_PER_PAGE + l];
            const int col0 = p * T640_PAGE_SIZE + l * T640_LANE_SIZE;
            const int col_end = (col0 + T640_LANE_SIZE < in_dim) ? (col0 + T640_LANE_SIZE) : in_dim;

            for (int v = 0; v < T640_LANE_SIZE; v++) {
                const int col = col0 + v;
                if (col >= col_end) break;
                const int trit = (int)(word % 3u);
                word /= 3u;
                if (trit == 1) {
                    acc += scale * B_col[col];
                } else if (trit == 2) {
                    acc -= scale * B_col[col];
                }
            }
        }
    }

    // Outlier addback.
    for (int kk = row_off_lo; kk < row_off_hi; kk++) {
        const int col = A_outlier_cols[kk];
        acc += t640_half_to_float(A_outlier_vals[kk]) * B_col[col];
    }

    const int dst_idx = s * (out_dim * n_tokens * n_batch) +
                        b * (out_dim * n_tokens) +
                        j * out_dim + i;
    dst[dst_idx] = acc;
}

// -- TILE640_MATMUL_ID kernel ------------------------------------------------
//
// MoE variant: for each (e, j) in ids x tokens, compute
//   out[:, e, j] = dequant(A[ids[e,j], :, :]) @ B[:, j]
//
// Each expert has the same 2D Tile640 structure as a single weight.
// One thread per (out_row, expert_used, token) triple.
//

__global__ void kernel_tile640_matmul_id(
        const uint32_t *       __restrict__ A_packed,
        const unsigned short * __restrict__ A_page_scales,
        const int8_t *         __restrict__ A_lane_scales,
        const int32_t *        __restrict__ A_outlier_row_offsets,
        const int32_t *        __restrict__ A_outlier_cols,
        const unsigned short * __restrict__ A_outlier_vals,
        const unsigned short * __restrict__ B,
        const int32_t *        __restrict__ ids,
        const unsigned short * __restrict__ act_scale,
        float *                __restrict__ dst,
        int n_experts,
        int out_dim,
        int in_dim,
        int n_broadcast,
        int n_tokens,
        int n_expert_used,
        int pages_per_row,
        int words_per_row,
        int lanes_per_row,
        int act_scale_kind) {
    // act_scale_kind: 0 = none, 1 = shared (in_dim), 2 = per-expert (in_dim * n_experts)

    const int global_idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int total = out_dim * n_expert_used * n_tokens;
    if (global_idx >= total) return;

    // Linear order: (i, e, j) with i fastest.
    const int i = global_idx % out_dim;
    const int e = (global_idx / out_dim) % n_expert_used;
    const int j = global_idx / (out_dim * n_expert_used);

    const int expert_id = ids[(int64_t) j * n_expert_used + e];

    const int words_per_expert  = out_dim * words_per_row;
    const int pages_per_expert  = out_dim * pages_per_row;
    const int lanes_per_expert  = out_dim * lanes_per_row;
    const int offsets_per_expert = out_dim + 1;

    const uint32_t *       A_row  = A_packed + (int64_t) expert_id * words_per_expert  + (int64_t) i * words_per_row;
    const unsigned short * ps_row = A_page_scales + (int64_t) expert_id * pages_per_expert + (int64_t) i * pages_per_row;
    const int8_t *         ls_row = A_lane_scales + (int64_t) expert_id * lanes_per_expert + (int64_t) i * lanes_per_row;

    const int32_t * offs_e = A_outlier_row_offsets + (int64_t) expert_id * offsets_per_expert;
    const int row_off_lo = offs_e[i];
    const int row_off_hi = offs_e[i + 1];

    // B layout: [K, n_broadcast, n_tokens, 1] with nb strides.
    const unsigned short * B_col = B + (int64_t) j * in_dim * n_broadcast +
                                   (int64_t) (e % n_broadcast) * in_dim;

    const unsigned short * scale_row = nullptr;
    if (act_scale_kind == 1) {
        scale_row = act_scale;
    } else if (act_scale_kind == 2) {
        scale_row = act_scale + (int64_t) expert_id * in_dim;
    }

    float acc = 0.0f;

    for (int p = 0; p < pages_per_row; p++) {
        const float page_max = t640_half_to_float(ps_row[p]);
        for (int l = 0; l < T640_LANES_PER_PAGE; l++) {
            const float lane_s = (float) ls_row[p * T640_LANES_PER_PAGE + l] * (1.0f / 127.0f);
            const float scale  = page_max * lane_s;
            uint32_t word = A_row[p * T640_WORDS_PER_PAGE + l];
            const int col0 = p * T640_PAGE_SIZE + l * T640_LANE_SIZE;
            const int col_end = (col0 + T640_LANE_SIZE < in_dim) ? (col0 + T640_LANE_SIZE) : in_dim;
            for (int v = 0; v < T640_LANE_SIZE; v++) {
                const int col = col0 + v;
                if (col >= col_end) break;
                const int trit = (int)(word % 3u);
                word /= 3u;
                if (trit == 1 || trit == 2) {
                    float input = t640_half_to_float(B_col[col]);
                    if (scale_row) {
                        input *= t640_half_to_float(scale_row[col]);
                    }
                    if (trit == 1) {
                        acc += scale * input;
                    } else {
                        acc -= scale * input;
                    }
                }
            }
        }
    }

    // Outlier addback.
    for (int k = row_off_lo; k < row_off_hi; k++) {
        const int col = A_outlier_cols[k];
        float input = t640_half_to_float(B_col[col]);
        if (scale_row) {
            input *= t640_half_to_float(scale_row[col]);
        }
        acc += t640_half_to_float(A_outlier_vals[k]) * input;
    }

    dst[global_idx] = acc;
}

// -- TILE640_GET_ROWS kernel -------------------------------------------------
//
// One thread per output element. For output position (dst_row, col):
//   src_row = ids[dst_row]
//   dst[dst_row * row_width + col] = dequant(packed, scales, outliers, src_row, col)
//

__global__ void kernel_tile640_get_rows(
        const uint32_t *       __restrict__ packed,
        const unsigned short * __restrict__ page_scales,
        const int8_t *         __restrict__ lane_scales,
        const int32_t *        __restrict__ outlier_row_offsets,
        const int32_t *        __restrict__ outlier_cols,
        const unsigned short * __restrict__ outlier_vals,
        const int32_t *        __restrict__ row_ids,
        float *                __restrict__ dst,
        int row_width,
        int n_rows,
        int n_ids) {

    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int total = n_ids * row_width;
    if (idx >= total) return;

    const int dst_row = idx / row_width;
    const int col     = idx % row_width;
    const int src_row = row_ids[dst_row];

    const int pages_per_row = (row_width + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int words_per_row = pages_per_row * T640_WORDS_PER_PAGE;

    const int page_idx = col / T640_PAGE_SIZE;
    const int page_col = col % T640_PAGE_SIZE;
    const int lane_idx = page_col / T640_LANE_SIZE;
    const int lane_pos = page_col % T640_LANE_SIZE;

    uint32_t word = packed[src_row * words_per_row + page_idx * T640_WORDS_PER_PAGE + lane_idx];
    uint32_t w = word;
    for (int i = 0; i < lane_pos; i++) {
        w /= 3u;
    }
    const int trit = (int)(w % 3u);

    const float page_scale = t640_half_to_float(page_scales[src_row * pages_per_row + page_idx]);
    const float lane_s = (float) lane_scales[src_row * words_per_row + page_idx * T640_LANES_PER_PAGE + lane_idx] * (1.0f / 127.0f);
    const float scale  = page_scale * lane_s;

    float val = (trit == 1) ? scale : (trit == 2) ? -scale : 0.0f;

    // Outlier overwrite.
    const int off_lo = outlier_row_offsets[src_row];
    const int off_hi = outlier_row_offsets[src_row + 1];
    for (int k = off_lo; k < off_hi; k++) {
        if (outlier_cols[k] == col) {
            val = t640_half_to_float(outlier_vals[k]);
            break;
        }
    }

    dst[idx] = val;
}

// ============================================================================
// Host dispatch functions
// ============================================================================

#define HIP_CHECK(call) \
    do { \
        hipError_t err = (call); \
        if (err != hipSuccess) { \
            fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(err), __FILE__, __LINE__); \
        } \
    } while (0)

static const int T640_BLOCK_SIZE = 256;

void ggml_amd_hip_tile640_dequant(
        hipStream_t stream,
        const void * packed,
        const void * page_scales,
        const void * lane_scales,
        const void * outlier_row_offsets,
        const void * outlier_cols,
        const void * outlier_vals,
        void * dst,
        int row_width,
        int n_rows) {

    const int n_elements = row_width * n_rows;
    const int n_blocks = (n_elements + T640_BLOCK_SIZE - 1) / T640_BLOCK_SIZE;

    kernel_tile640_dequant<<<n_blocks, T640_BLOCK_SIZE, 0, stream>>>(
        (const uint32_t *)       packed,
        (const unsigned short *) page_scales,
        (const int8_t *)         lane_scales,
        (const int32_t *)        outlier_row_offsets,
        (const int32_t *)        outlier_cols,
        (const unsigned short *) outlier_vals,
        (float *)                dst,
        row_width, n_rows, n_elements);

    // Outlier overwrite pass.
    const int32_t * offsets = (const int32_t *) outlier_row_offsets;
    // Read n_outliers_total from offsets[n_rows] via a small D2H copy.
    // For the reference kernel this is acceptable; a production kernel
    // would pass n_outliers_total as a parameter.
    int n_outliers_total = 0;
    HIP_CHECK(hipMemcpyAsync(&n_outliers_total, offsets + n_rows, sizeof(int32_t),
                             hipMemcpyDeviceToHost, stream));
    HIP_CHECK(hipStreamSynchronize(stream));

    if (n_outliers_total > 0) {
        const int out_blocks = (n_outliers_total + T640_BLOCK_SIZE - 1) / T640_BLOCK_SIZE;
        kernel_tile640_dequant_outliers<<<out_blocks, T640_BLOCK_SIZE, 0, stream>>>(
            offsets,
            (const int32_t *)        outlier_cols,
            (const unsigned short *) outlier_vals,
            (float *)                dst,
            row_width, n_outliers_total);
    }
}

void ggml_amd_hip_tile640_matmul(
        hipStream_t stream,
        const void * A_packed,
        const void * A_page_scales,
        const void * A_lane_scales,
        const void * A_outlier_row_offsets,
        const void * A_outlier_cols,
        const void * A_outlier_vals,
        const void * B,
        void * dst,
        int out_dim,
        int in_dim,
        int n_tokens,
        int n_batch,
        int n_seqs) {

    const int pages_per_row = (in_dim + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int words_per_row = pages_per_row * T640_WORDS_PER_PAGE;
    const int total = out_dim * n_tokens * n_batch * n_seqs;
    const int n_blocks = (total + T640_BLOCK_SIZE - 1) / T640_BLOCK_SIZE;

    kernel_tile640_matmul<<<n_blocks, T640_BLOCK_SIZE, 0, stream>>>(
        (const uint32_t *)       A_packed,
        (const unsigned short *) A_page_scales,
        (const int8_t *)         A_lane_scales,
        (const int32_t *)        A_outlier_row_offsets,
        (const int32_t *)        A_outlier_cols,
        (const unsigned short *) A_outlier_vals,
        (const float *)          B,
        (float *)                dst,
        out_dim, in_dim, n_tokens, n_batch, n_seqs,
        pages_per_row, words_per_row, 0);
}

void ggml_amd_hip_tile640_matmul_id(
        hipStream_t stream,
        const void * A_packed,
        const void * A_page_scales,
        const void * A_lane_scales,
        const void * A_outlier_row_offsets,
        const void * A_outlier_cols,
        const void * A_outlier_vals,
        const void * B,
        const void * ids,
        const void * act_scale,
        void * dst,
        int n_experts,
        int out_dim,
        int in_dim,
        int n_broadcast,
        int n_tokens,
        int n_expert_used,
        int act_scale_kind) {

    const int pages_per_row = (in_dim + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int words_per_row = pages_per_row * T640_WORDS_PER_PAGE;
    const int lanes_per_row = pages_per_row * T640_LANES_PER_PAGE;
    const int total = out_dim * n_expert_used * n_tokens;
    const int n_blocks = (total + T640_BLOCK_SIZE - 1) / T640_BLOCK_SIZE;

    kernel_tile640_matmul_id<<<n_blocks, T640_BLOCK_SIZE, 0, stream>>>(
        (const uint32_t *)       A_packed,
        (const unsigned short *) A_page_scales,
        (const int8_t *)         A_lane_scales,
        (const int32_t *)        A_outlier_row_offsets,
        (const int32_t *)        A_outlier_cols,
        (const unsigned short *) A_outlier_vals,
        (const unsigned short *) B,
        (const int32_t *)        ids,
        act_scale ? (const unsigned short *) act_scale : nullptr,
        (float *)                dst,
        n_experts, out_dim, in_dim, n_broadcast, n_tokens, n_expert_used,
        pages_per_row, words_per_row, lanes_per_row, act_scale_kind);
}

void ggml_amd_hip_tile640_get_rows(
        hipStream_t stream,
        const void * packed,
        const void * page_scales,
        const void * lane_scales,
        const void * outlier_row_offsets,
        const void * outlier_cols,
        const void * outlier_vals,
        const void * row_ids,
        void * dst,
        int row_width,
        int n_rows,
        int n_ids) {

    const int total = n_ids * row_width;
    const int n_blocks = (total + T640_BLOCK_SIZE - 1) / T640_BLOCK_SIZE;

    kernel_tile640_get_rows<<<n_blocks, T640_BLOCK_SIZE, 0, stream>>>(
        (const uint32_t *)       packed,
        (const unsigned short *) page_scales,
        (const int8_t *)         lane_scales,
        (const int32_t *)        outlier_row_offsets,
        (const int32_t *)        outlier_cols,
        (const unsigned short *) outlier_vals,
        (const int32_t *)        row_ids,
        (float *)                dst,
        row_width, n_rows, n_ids);
}
