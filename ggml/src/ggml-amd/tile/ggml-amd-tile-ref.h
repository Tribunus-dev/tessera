//
// ggml-amd-tile-ref.h
//
// CPU reference implementation for Tile640 operations. Used for testing
// parity against the HIP kernels. Not intended for production use.
//

#ifndef GGML_AMD_TILE_REF_H
#define GGML_AMD_TILE_REF_H

#ifdef __cplusplus
extern "C" {
#endif

// Dequantize T640-packed weights to f32. dst must hold row_width * n_rows floats.
void ggml_amd_tile_ref_dequant(
        const void * packed,
        const void * page_scales,
        const void * lane_scales,
        const void * outlier_row_offsets,
        const void * outlier_cols,
        const void * outlier_vals,
        void * dst,
        int row_width,
        int n_rows);

// Dense matmul: dst = dequant(A) @ B.
// B is [in_dim, n_tokens, n_batch, n_seqs] f32 contiguous.
// dst is [out_dim, n_tokens, n_batch, n_seqs] f32 contiguous.
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
        int n_seqs);

// MoE matmul: per-expert routing via ids.
// act_scale_kind: 0 = none, 1 = shared (in_dim), 2 = per-expert (in_dim * n_experts).
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
        int act_scale_kind);

// Row extraction: dst[i] = dequant(packed, ids[i]).
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
        int n_ids);

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_TILE_REF_H
