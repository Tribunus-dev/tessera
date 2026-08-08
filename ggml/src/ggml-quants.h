#pragma once

#define GGML_COMMON_DECL_C
#include "ggml-common.h"

#include "ggml.h"

// GGML internal header

#ifdef __cplusplus
extern "C" {
#endif

// NOTE: these functions are defined as GGML_API because they used by the CPU backend

// Quantization
GGML_API void quantize_row_q1_0_ref(const float * GGML_RESTRICT x, block_q1_0 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q2_0_ref(const float * GGML_RESTRICT x, block_q2_0 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_tessera_t640_ref(const float * GGML_RESTRICT x, void * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q4_0_ref(const float * GGML_RESTRICT x, block_q4_0 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q4_1_ref(const float * GGML_RESTRICT x, block_q4_1 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q5_0_ref(const float * GGML_RESTRICT x, block_q5_0 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q5_1_ref(const float * GGML_RESTRICT x, block_q5_1 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q8_0_ref(const float * GGML_RESTRICT x, block_q8_0 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q8_1_ref(const float * GGML_RESTRICT x, block_q8_1 * GGML_RESTRICT y, int64_t k);

GGML_API void quantize_row_mxfp4_ref(const float * GGML_RESTRICT x, block_mxfp4 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_nvfp4_ref(const float * GGML_RESTRICT x, block_nvfp4 * GGML_RESTRICT y, int64_t k);

GGML_API void quantize_row_q2_K_ref(const float * GGML_RESTRICT x, block_q2_K * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q3_K_ref(const float * GGML_RESTRICT x, block_q3_K * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q4_K_ref(const float * GGML_RESTRICT x, block_q4_K * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q5_K_ref(const float * GGML_RESTRICT x, block_q5_K * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q6_K_ref(const float * GGML_RESTRICT x, block_q6_K * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_q8_K_ref(const float * GGML_RESTRICT x, block_q8_K * GGML_RESTRICT y, int64_t k);

GGML_API void quantize_row_tq1_0_ref(const float * GGML_RESTRICT x, block_tq1_0 * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_tq2_0_ref(const float * GGML_RESTRICT x, block_tq2_0 * GGML_RESTRICT y, int64_t k);

GGML_API void quantize_row_iq3_xxs_ref(const float * GGML_RESTRICT x, block_iq3_xxs * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_iq4_nl_ref (const float * GGML_RESTRICT x, block_iq4_nl  * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_iq4_xs_ref (const float * GGML_RESTRICT x, block_iq4_xs  * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_iq3_s_ref  (const float * GGML_RESTRICT x, block_iq3_s   * GGML_RESTRICT y, int64_t k);
GGML_API void quantize_row_iq2_s_ref  (const float * GGML_RESTRICT x, block_iq2_s   * GGML_RESTRICT y, int64_t k);

// Dequantization
GGML_API void dequantize_row_q1_0(const block_q1_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q2_0(const block_q2_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_tessera_t640(const void * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
// Same dequant, but the caller pre-decoded the row's meta
// (ts_decode_per_row_meta for the whole tile) and passes the
// per-row page_max / lane_scale views. Used by the batched
// GGML_OP_TILE640_MATMUL dispatch to hoist the meta decode out
// of the per-row loop.
GGML_API void dequantize_row_tessera_t640_with_meta(const void * GGML_RESTRICT packed,
                                                    const float * GGML_RESTRICT page_max_in,
                                                    const float * GGML_RESTRICT lane_scale_in,
                                                    int64_t k,
                                                    float * GGML_RESTRICT y);
GGML_API void dequantize_row_q4_0(const block_q4_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q4_1(const block_q4_1 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q5_0(const block_q5_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q5_1(const block_q5_1 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q8_0(const block_q8_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
//GGML_API void dequantize_row_q8_1(const block_q8_1 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);

GGML_API void dequantize_row_mxfp4(const block_mxfp4 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_nvfp4(const block_nvfp4 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);

GGML_API void dequantize_row_q2_K(const block_q2_K * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q3_K(const block_q3_K * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q4_K(const block_q4_K * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q5_K(const block_q5_K * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q6_K(const block_q6_K * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_q8_K(const block_q8_K * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);

GGML_API void dequantize_row_tq1_0(const block_tq1_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_tq2_0(const block_tq2_0 * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);

GGML_API void dequantize_row_iq2_xxs(const block_iq2_xxs * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq2_xs (const block_iq2_xs  * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq2_s  (const block_iq2_s   * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq3_xxs(const block_iq3_xxs * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq1_s  (const block_iq1_s   * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq1_m  (const block_iq1_m   * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq4_nl (const block_iq4_nl  * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq4_xs (const block_iq4_xs  * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);
GGML_API void dequantize_row_iq3_s  (const block_iq3_s   * GGML_RESTRICT x, float * GGML_RESTRICT y, int64_t k);

// Quantization utilizing an importance matrix (a.k.a. "Activation aWare Quantization")
GGML_API size_t quantize_iq2_xxs(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq2_xs (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq2_s  (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq3_xxs(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq1_s  (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq1_m  (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq4_nl (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq4_xs (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_iq3_s  (const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);

GGML_API size_t quantize_tq1_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_tq2_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);

GGML_API size_t quantize_q2_K(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q3_K(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q4_K(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q5_K(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q6_K(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q1_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q2_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q4_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q4_1(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q5_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q5_1(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_q8_0(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);

GGML_API size_t quantize_mxfp4(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);
GGML_API size_t quantize_nvfp4(const float * GGML_RESTRICT src, void * GGML_RESTRICT dst, int64_t nrows, int64_t n_per_row, const float * imatrix);

GGML_API void iq2xs_init_impl(enum ggml_type type);
GGML_API void iq2xs_free_impl(enum ggml_type type);
GGML_API void iq3xs_init_impl(int grid_size);
GGML_API void iq3xs_free_impl(int grid_size);

// ---------------------------------------------------------------------------
// Tessera TILE640 batched host helpers
//
// One implementation per contract, each with an Accelerate (vDSP)
// + NEON path and a scalar path selected per call. The
// GGML_OP_TILE640_MATMUL dispatch in ggml-ane.mm passes the
// regime router's decision; tests and benches pass an explicit
// path or the static cost model's below.
// ---------------------------------------------------------------------------

// Accel cutoff for the quant path: below this k the vDSP call
// setup costs more than the per-page work, so
// quantize_row_tessera_t640_ref runs its scalar path. 1024 is
// conservative (the smallest canonical Phase 0 shape is 256x256).
#define GGML_TESSERA_T640_ACCEL_MIN_K 1024

// Outlier addback: the accel NEON bulk-convert path is capped by
// its 4 KB stack scratch (1024 fp32). Above this n_total the
// scalar path runs regardless. Named after the internal property
// so the cost model documents its source.
#define TS_T640_OUTLIER_ACCEL_MAX_N_TOTAL 1024

// Meta decode: minimum n_total_pages (= n_rows * n_pages) for the
// accel path to win; below it the vDSP + NEON setup tax dominates
// and the scalar loop is faster.
#define TS_T640_META_DECODE_MIN_N_TOTAL_PAGES 4096

// Measured static cost model (M1 base 16GB, ~68 GB/s bench):
//   outlier addback: accel wins iff n_total in (0, 1024].
//     1.66-1.88x at n_total 51-409; tie at 3264-52224
//     (memory-bandwidth bound); the threshold is pinned to the
//     accel path's internal NEON scratch boundary.
//   meta decode: accel wins iff n_total_pages >= 4096.
//     0.80-0.92x at small N (setup tax), 0.99x tie at
//     n_total_pages=1024, 1.09x at >= 4096. 4096 is the first
//     clean win; routing the tie to accel would lose ~0.5% on a
//     per-tile hot path.
// The regime router (ggml-regime-router.h) overrides these per
// (family, shape) and falls back to them on a lookup miss.
static inline bool ts_t640_outlier_accel_wins(int64_t n_total) {
    return n_total > 0 && n_total <= TS_T640_OUTLIER_ACCEL_MAX_N_TOTAL;
}

static inline bool ts_t640_meta_accel_wins(int64_t n_rows, int64_t n_pages) {
    if (n_rows <= 0 || n_pages <= 0) {
        return false;
    }
    return n_rows * n_pages >= TS_T640_META_DECODE_MIN_N_TOTAL_PAGES;
}

// Batched meta decode for a whole TILE of rows: reads
// n_rows * n_pages page_scales (fp16) and
// n_rows * n_pages * TILE640_LANES_PER_PAGE lane_scales (int8);
// writes page_max_out (fp32) and lane_scale_out (fp32,
// pre-divided by 127). use_accel selects the vDSP + NEON bulk
// path; the scalar path is the fallback (and the only path on
// non-Apple builds).
GGML_API void ts_decode_per_row_meta(const void * GGML_RESTRICT page_scales_packed,
                                     const void * GGML_RESTRICT lane_scales_packed,
                                     int64_t n_rows,
                                     int64_t n_pages,
                                     float * GGML_RESTRICT page_max_out,
                                     float * GGML_RESTRICT lane_scale_out,
                                     bool use_accel);

// Batched outlier addback for a whole BUFFER of rows: scatter
// fp16 outlier_vals into rows[r, col] at the CSR positions.
// use_accel selects the NEON bulk fp16 -> fp32 convert path
// (active only for n_total <= TS_T640_OUTLIER_ACCEL_MAX_N_TOTAL;
// above it the scalar convert runs regardless).
GGML_API void ts_apply_outlier_addback(float * GGML_RESTRICT rows,
                                       int64_t row_len,
                                       int64_t n_rows,
                                       const int32_t * GGML_RESTRICT outlier_row_offsets,
                                       const int32_t * GGML_RESTRICT outlier_cols,
                                       const void * GGML_RESTRICT outlier_vals,
                                       bool use_accel);

// Per-input-channel activation scale: y[i] *= fp16_to_fp32(act_scale[i]).
GGML_API void ts_apply_act_scale(float * GGML_RESTRICT y,
                                 const void * GGML_RESTRICT act_scale_packed,
                                 int64_t n);

// Accel feature flag: default on; set GGML_TESSERA_T640_ACCEL_DISABLE=1
// to force the scalar paths at runtime (no recompile).
GGML_API int ggml_tessera_t640_accel_enabled(void);

// Explicit override of the accel flag for tests and benches
// that need to pin a specific internal path. The production
// dispatch reads the flag; it never sets it.
GGML_API void ggml_tessera_t640_set_accel_enabled(int enabled);

#ifdef __cplusplus
}
#endif
