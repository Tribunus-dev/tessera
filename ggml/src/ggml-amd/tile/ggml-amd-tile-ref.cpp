//
// ggml-amd-tile-ref.cpp
//
// CPU reference implementation for Tile640 operations. Mirrors the
// ggml-cpu/ops.cpp implementation exactly, used for testing parity
// against the HIP kernels. Not intended for production use.
//

#include "ggml-amd-tile-ref.h"
#include "ggml.h"

#include <cstdint>
#include <cstring>
#include <vector>

// Tile640 geometry (matches ggml-common.h).
#define T640_PAGE_SIZE      640
#define T640_LANE_SIZE      20
#define T640_LANES_PER_PAGE 32
#define T640_WORDS_PER_PAGE 32

// Decode a single T640 row to f32. Mirrors ggml-cpu/ops.cpp ggml_tile640_decode_row.
static void tile640_decode_row(
        float * dst,
        int64_t row,
        int64_t row_width,
        const uint32_t * packed,
        const ggml_fp16_t * page_scales,
        const int8_t * lane_scales,
        const int32_t * outlier_row_offsets,
        const int32_t * outlier_cols,
        const ggml_fp16_t * outlier_vals) {

    const int64_t pages_per_row = (row_width + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int64_t words_per_row = pages_per_row * T640_LANES_PER_PAGE;

    for (int64_t p = 0; p < pages_per_row; p++) {
        const float page_scale = ggml_fp16_to_fp32(page_scales[row * pages_per_row + p]);
        for (int64_t lane = 0; lane < T640_LANES_PER_PAGE; lane++) {
            const int64_t col0 = p * T640_PAGE_SIZE + lane * T640_LANE_SIZE;
            if (col0 >= row_width) break;

            uint32_t word = packed[row * words_per_row + p * T640_LANES_PER_PAGE + lane];
            const float scale = page_scale *
                ((float) lane_scales[row * words_per_row + p * T640_LANES_PER_PAGE + lane] / 127.0f);

            for (int64_t v = 0; v < T640_LANE_SIZE && col0 + v < row_width; v++) {
                const uint32_t trit = word % 3u;
                word /= 3u;
                dst[col0 + v] = trit == 1u ? scale : trit == 2u ? -scale : 0.0f;
            }
        }
    }

    // Outlier addback (CSR).
    for (int32_t k = outlier_row_offsets[row]; k < outlier_row_offsets[row + 1]; k++) {
        const int32_t col = outlier_cols[k];
        dst[col] = ggml_fp16_to_fp32(outlier_vals[k]);
    }
}

void ggml_amd_tile_ref_dequant(
        const void * packed,
        const void * page_scales,
        const void * lane_scales,
        const void * outlier_row_offsets,
        const void * outlier_cols,
        const void * outlier_vals,
        void * dst,
        int row_width,
        int n_rows) {

    for (int64_t row = 0; row < n_rows; row++) {
        tile640_decode_row(
            (float *) dst + row * row_width,
            row, row_width,
            (const uint32_t *) packed,
            (const ggml_fp16_t *) page_scales,
            (const int8_t *) lane_scales,
            (const int32_t *) outlier_row_offsets,
            (const int32_t *) outlier_cols,
            (const ggml_fp16_t *) outlier_vals);
    }
}

void ggml_amd_tile_ref_matmul(
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

    const int64_t pages_per_row = (in_dim + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int64_t words_per_row = pages_per_row * T640_WORDS_PER_PAGE;

    const uint32_t *    packed       = (const uint32_t *)    A_packed;
    const ggml_fp16_t * page_scales  = (const ggml_fp16_t *) A_page_scales;
    const int8_t *      lane_scales  = (const int8_t *)      A_lane_scales;
    const int32_t *     outlier_row_offsets = (const int32_t *) A_outlier_row_offsets;
    const int32_t *     outlier_cols = (const int32_t *)     A_outlier_cols;
    const ggml_fp16_t * outlier_vals = (const ggml_fp16_t *) A_outlier_vals;
    const float *       B_data       = (const float *)       B;
    float *             dst_data     = (float *)             dst;

    for (int64_t i = 0; i < out_dim; i++) {
        const uint32_t *    A_row  = packed + i * words_per_row;
        const ggml_fp16_t * ps_row = page_scales + i * pages_per_row;
        const int8_t *      ls_row = lane_scales + i * pages_per_row * T640_LANES_PER_PAGE;
        const int64_t row_off_lo = outlier_row_offsets[i];
        const int64_t row_off_hi = outlier_row_offsets[i + 1];

        for (int64_t s = 0; s < n_seqs; s++) {
            for (int64_t b = 0; b < n_batch; b++) {
                for (int64_t j = 0; j < n_tokens; j++) {
                    const float * B_col = B_data +
                        ((s * n_batch + b) * n_tokens + j) * in_dim;

                    float acc = 0.0f;

                    for (int64_t p = 0; p < pages_per_row; p++) {
                        const float page_max = ggml_fp16_to_fp32(ps_row[p]);
                        for (int64_t l = 0; l < T640_LANES_PER_PAGE; l++) {
                            const float lane_s_f = (float) ls_row[p * T640_LANES_PER_PAGE + l] * (1.0f / 127.0f);
                            const float scale = page_max * lane_s_f;

                            uint32_t word = A_row[p * T640_WORDS_PER_PAGE + l];
                            const int64_t col0 = p * T640_PAGE_SIZE + l * T640_LANE_SIZE;
                            const int64_t col_end = (col0 + T640_LANE_SIZE < in_dim) ? (col0 + T640_LANE_SIZE) : in_dim;

                            for (int64_t v = 0; v < T640_LANE_SIZE; v++) {
                                const int64_t col = col0 + v;
                                if (col >= col_end) break;
                                const int32_t trit = (int32_t)(word % 3u);
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
                    for (int64_t kk = row_off_lo; kk < row_off_hi; kk++) {
                        const int64_t col = outlier_cols[kk];
                        acc += ggml_fp16_to_fp32(outlier_vals[kk]) * B_col[col];
                    }

                    const int64_t dst_idx = s * (out_dim * n_tokens * n_batch) +
                                            b * (out_dim * n_tokens) +
                                            j * out_dim + i;
                    dst_data[dst_idx] = acc;
                }
            }
        }
    }
}

void ggml_amd_tile_ref_matmul_id(
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

    const int64_t pages_per_row = (in_dim + T640_PAGE_SIZE - 1) / T640_PAGE_SIZE;
    const int64_t words_per_row = pages_per_row * T640_WORDS_PER_PAGE;
    const int64_t lanes_per_row = pages_per_row * T640_LANES_PER_PAGE;
    const int64_t offsets_per_expert = out_dim + 1;

    const uint32_t *    packed       = (const uint32_t *)    A_packed;
    const ggml_fp16_t * page_scales  = (const ggml_fp16_t *) A_page_scales;
    const int8_t *      lane_scales  = (const int8_t *)      A_lane_scales;
    const int32_t *     outlier_row_offsets = (const int32_t *) A_outlier_row_offsets;
    const int32_t *     outlier_cols = (const int32_t *)     A_outlier_cols;
    const ggml_fp16_t * outlier_vals = (const ggml_fp16_t *) A_outlier_vals;
    const ggml_fp16_t * B_data       = (const ggml_fp16_t *) B;
    const int32_t *     ids_data     = (const int32_t *)     ids;
    const ggml_fp16_t * act_scale_data = act_scale ? (const ggml_fp16_t *) act_scale : nullptr;
    float *             dst_data     = (float *)             dst;

    const int64_t words_per_expert  = out_dim * words_per_row;
    const int64_t pages_per_expert  = out_dim * pages_per_row;
    const int64_t lanes_per_expert  = out_dim * lanes_per_row;

    for (int64_t i = 0; i < out_dim; i++) {
        for (int64_t e = 0; e < n_expert_used; e++) {
            for (int64_t j = 0; j < n_tokens; j++) {
                const int32_t expert_id = ids_data[j * n_expert_used + e];

                const uint32_t *    A_row  = packed + expert_id * words_per_expert + i * words_per_row;
                const ggml_fp16_t * ps_row = page_scales + expert_id * pages_per_expert + i * pages_per_row;
                const int8_t *      ls_row = lane_scales + expert_id * lanes_per_expert + i * lanes_per_row;

                const int32_t * offs_e = outlier_row_offsets + expert_id * offsets_per_expert;
                const int64_t row_off_lo = offs_e[i];
                const int64_t row_off_hi = offs_e[i + 1];

                const ggml_fp16_t * B_col = B_data + j * in_dim * n_broadcast + (e % n_broadcast) * in_dim;

                const ggml_fp16_t * scale_row = nullptr;
                if (act_scale_kind == 1) {
                    scale_row = act_scale_data;
                } else if (act_scale_kind == 2) {
                    scale_row = act_scale_data + expert_id * in_dim;
                }

                float acc = 0.0f;

                for (int64_t p = 0; p < pages_per_row; p++) {
                    const float page_max = ggml_fp16_to_fp32(ps_row[p]);
                    for (int64_t l = 0; l < T640_LANES_PER_PAGE; l++) {
                        const float lane_s = (float) ls_row[p * T640_LANES_PER_PAGE + l] * (1.0f / 127.0f);
                        const float scale  = page_max * lane_s;
                        uint32_t word = A_row[p * T640_WORDS_PER_PAGE + l];
                        const int64_t col0 = p * T640_PAGE_SIZE + l * T640_LANE_SIZE;
                        const int64_t col_end = (col0 + T640_LANE_SIZE < in_dim) ? (col0 + T640_LANE_SIZE) : in_dim;
                        for (int64_t v = 0; v < T640_LANE_SIZE; v++) {
                            const int64_t col = col0 + v;
                            if (col >= col_end) break;
                            const int32_t trit = (int32_t)(word % 3u);
                            word /= 3u;
                            if (trit == 1 || trit == 2) {
                                float input = ggml_fp16_to_fp32(B_col[col]);
                                if (scale_row) {
                                    input *= ggml_fp16_to_fp32(scale_row[col]);
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
                for (int64_t k = row_off_lo; k < row_off_hi; k++) {
                    const int64_t col = outlier_cols[k];
                    float input = ggml_fp16_to_fp32(B_col[col]);
                    if (scale_row) {
                        input *= ggml_fp16_to_fp32(scale_row[col]);
                    }
                    acc += ggml_fp16_to_fp32(outlier_vals[k]) * input;
                }

                const int64_t idx = i + e * out_dim + j * out_dim * n_expert_used;
                dst_data[idx] = acc;
            }
        }
    }
}

void ggml_amd_tile_ref_get_rows(
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

    const int32_t * ids_data = (const int32_t *) row_ids;
    float * dst_data = (float *) dst;

    for (int64_t i = 0; i < n_ids; i++) {
        const int64_t src_row = ids_data[i];
        tile640_decode_row(
            dst_data + i * row_width,
            src_row, row_width,
            (const uint32_t *) packed,
            (const ggml_fp16_t *) page_scales,
            (const int8_t *) lane_scales,
            (const int32_t *) outlier_row_offsets,
            (const int32_t *) outlier_cols,
            (const ggml_fp16_t *) outlier_vals);
    }
}
