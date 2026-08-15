// HIP port of ggml-metal-tile640-interleaved.metal.
//
// Mirrors kernel_TILE640_MATMUL_INTERLEAVED exactly. P0 path is bit-exact
// equivalent to kernel_TILE640_MATMUL; P1 (drafter) and P2 (KV) paths
// run only when the host populates iargs.drafter_enabled / kv_enabled.
// simdgroup reductions map to warp_reduce_sum / warp_reduce_max
// (WARP_SIZE = 32 -> wave32 on gfx1103); cross-warp fold goes to
// __shared__ memory. FC_TILE640_INTERLEAVE and the offset constants are
// kernel template parameters; T640_TRIT5_LUT lives in __constant__ at
// file scope.

#include "tile640-interleaved.cuh"
#include "ggml.h"

#include <cstdint>
#include <hip/hip_runtime.h>
#include <hip/hip_fp16.h>

#define FC_TILE640_INTERLEAVE 1710

enum {
    FC_TILE640I_IN_DIM    = FC_TILE640_INTERLEAVE + 0,
    FC_TILE640I_OUT_DIM   = FC_TILE640_INTERLEAVE + 1,
    FC_TILE640I_PACKING   = FC_TILE640_INTERLEAVE + 2,
    FC_TILE640I_INPUT_F32 = FC_TILE640_INTERLEAVE + 3,
};

#define T640_PAGE 640
#define T640_LANE 20
#define T640_LANES_PER_PAGE 32
#define T640_WORDS_PER_PAGE 32
#define T640_TOKEN_TILE 4
#define T640_KV_PREFETCH_MAX 128

static __constant__ unsigned short T640_TRIT5_LUT[243] = {
    0x000, 0x001, 0x002, 0x004, 0x005, 0x006, 0x008, 0x009, 0x00a, 0x010, 0x011, 0x012,
    0x014, 0x015, 0x016, 0x018, 0x019, 0x01a, 0x020, 0x021, 0x022, 0x024, 0x025, 0x026,
    0x028, 0x029, 0x02a, 0x040, 0x041, 0x042, 0x044, 0x045, 0x046, 0x048, 0x049, 0x04a,
    0x050, 0x051, 0x052, 0x054, 0x055, 0x056, 0x058, 0x059, 0x05a, 0x060, 0x061, 0x062,
    0x064, 0x065, 0x066, 0x068, 0x069, 0x06a, 0x080, 0x081, 0x082, 0x084, 0x085, 0x086,
    0x088, 0x089, 0x08a, 0x090, 0x091, 0x092, 0x094, 0x095, 0x096, 0x098, 0x099, 0x09a,
    0x0a0, 0x0a1, 0x0a2, 0x0a4, 0x0a5, 0x0a6, 0x0a8, 0x0a9, 0x0aa, 0x100, 0x101, 0x102,
    0x104, 0x105, 0x106, 0x108, 0x109, 0x10a, 0x110, 0x111, 0x112, 0x114, 0x115, 0x116,
    0x118, 0x119, 0x11a, 0x120, 0x121, 0x122, 0x124, 0x125, 0x126, 0x128, 0x129, 0x12a,
    0x140, 0x141, 0x142, 0x144, 0x145, 0x146, 0x148, 0x149, 0x14a, 0x150, 0x151, 0x152,
    0x154, 0x155, 0x156, 0x158, 0x159, 0x15a, 0x160, 0x161, 0x162, 0x164, 0x165, 0x166,
    0x168, 0x169, 0x16a, 0x180, 0x181, 0x182, 0x184, 0x185, 0x186, 0x188, 0x189, 0x18a,
    0x190, 0x191, 0x192, 0x194, 0x195, 0x196, 0x198, 0x199, 0x19a, 0x1a0, 0x1a1, 0x1a2,
    0x1a4, 0x1a5, 0x1a6, 0x1a8, 0x1a9, 0x1aa, 0x200, 0x201, 0x202, 0x204, 0x205, 0x206,
    0x208, 0x209, 0x20a, 0x210, 0x211, 0x212, 0x214, 0x215, 0x216, 0x218, 0x219, 0x21a,
    0x220, 0x221, 0x222, 0x224, 0x225, 0x226, 0x228, 0x229, 0x22a, 0x240, 0x241, 0x242,
    0x244, 0x245, 0x246, 0x248, 0x249, 0x24a, 0x250, 0x251, 0x252, 0x254, 0x255, 0x256,
    0x258, 0x259, 0x25a, 0x260, 0x261, 0x262, 0x264, 0x265, 0x266, 0x268, 0x269, 0x26a,
    0x280, 0x281, 0x282, 0x284, 0x285, 0x286, 0x288, 0x289, 0x28a, 0x290, 0x291, 0x292,
    0x294, 0x295, 0x296, 0x298, 0x299, 0x29a, 0x2a0, 0x2a1, 0x2a2, 0x2a4, 0x2a5, 0x2a6,
    0x2a8, 0x2a9, 0x2aa,
};

struct interleaved_args_t {
    uint32_t drafter_enabled;
    uint32_t drafter_hidden_dim;
    uint32_t drafter_vocab_slice;
    uint32_t drafter_n_tokens;
    uint32_t kv_enabled;
    uint32_t kv_seq_start;
    uint32_t kv_seq_count;
    uint32_t kv_head_dim;
    int32_t  in_dim;
    int32_t  out_dim;
    int32_t  packing;
};

struct tile640_matmul_kargs_t {
    int32_t ne12;
    int32_t ne13;
    int32_t ne14;
};

static __device__ __forceinline__ unsigned int tile640_trit(unsigned int word, int32_t trit) {
    const unsigned int powers_of_243[4] = { 1u, 243u, 59049u, 14348907u };
    const unsigned int group = (unsigned int) trit / 5u;
    const unsigned int index = (word / powers_of_243[group]) % 243u;
    return (T640_TRIT5_LUT[index] >> (2u * ((unsigned int) trit % 5u))) & 3u;
}

template <bool input_f32>
static __device__ __forceinline__ float tile640_load_activation(
        const unsigned char * __restrict__ input,
        int64_t index) {
    if (input_f32) {
        return ((const float *) input)[index];
    }
    return __half2float(((const __half *) input)[index]);
}

template <bool input_f32>
static __device__ __forceinline__ float4 tile640_load_activation4(
        const unsigned char * __restrict__ input,
        int64_t index) {
    if (input_f32) {
        return *((const float4 *) ((const float *) input + index));
    }
    // F16 path: load 4 halves as two half2s via vector load.
    const __half2 h01 = *((const __half2 *) ((const __half *) input + index));
    const __half2 h23 = *((const __half2 *) ((const __half *) input + index + 2));
    float2 a = __half22float2(h01);
    float2 b = __half22float2(h23);
    return make_float4(a.x, a.y, b.x, b.y);
}

// Forward decl so the dispatch below can pick the right template instance.
template <bool input_f32, bool packing2>
__launch_bounds__(128, 1)
__global__ void tile640_matmul_interleaved_kernel(
        const tile640_matmul_kargs_t args,
        const unsigned int  * __restrict__ packed,
        const __half        * __restrict__ page_scales,
        const unsigned char * __restrict__ lane_scales,
        const unsigned int  * __restrict__ outlier_row_offsets,
        const unsigned int  * __restrict__ outlier_cols,
        const __half        * __restrict__ outlier_vals,
        const unsigned char * __restrict__ input,
        const __half        * __restrict__ act_scale,
        float               * __restrict__ output,
        const __half        * __restrict__ drafter_weights,
        const __half        * __restrict__ drafter_bias,
        const __half        * __restrict__ drafter_hidden_state,
        float               * __restrict__ drafter_logits,
        const __half        * __restrict__ kv_cache,
        unsigned char       * __restrict__ kv_quantized,
        __half              * __restrict__ kv_scales_out,
        const interleaved_args_t iargs);

template <bool input_f32, bool packing2>
__launch_bounds__(128, 1)
__global__ void tile640_matmul_interleaved_kernel(
        const tile640_matmul_kargs_t args,
        const unsigned int  * __restrict__ packed,
        const __half        * __restrict__ page_scales,
        const unsigned char * __restrict__ lane_scales,
        const unsigned int  * __restrict__ outlier_row_offsets,
        const unsigned int  * __restrict__ outlier_cols,
        const __half        * __restrict__ outlier_vals,
        const unsigned char * __restrict__ input,
        const __half        * __restrict__ act_scale,
        float               * __restrict__ output,
        const __half        * __restrict__ drafter_weights,
        const __half        * __restrict__ drafter_bias,
        const __half        * __restrict__ drafter_hidden_state,
        float               * __restrict__ drafter_logits,
        const __half        * __restrict__ kv_cache,
        unsigned char       * __restrict__ kv_quantized,
        __half              * __restrict__ kv_scales_out,
        const interleaved_args_t iargs) {
    const unsigned int i  = blockIdx.x;
    const unsigned int j0 = blockIdx.y * T640_TOKEN_TILE;
    const unsigned int b  = blockIdx.z;
    const int32_t in_dim   = iargs.in_dim;
    const int32_t out_dim  = iargs.out_dim;
    const int32_t n_tokens = args.ne12;
    if (i >= (unsigned int) out_dim || j0 >= (unsigned int) n_tokens) return;

    const int32_t nt              = (in_dim + T640_PAGE - 1) / T640_PAGE;
    const int32_t words_per_row   = nt * (packing2 ? 40 : T640_WORDS_PER_PAGE);
    const int32_t pages_per_row   = nt;
    const int32_t token_count     = (n_tokens - (int32_t) j0) < T640_TOKEN_TILE
                                    ? (n_tokens - (int32_t) j0) : T640_TOKEN_TILE;

    const unsigned int  * row_pack = packed      + (int64_t) i * words_per_row;
    const __half        * row_ps   = page_scales + (int64_t) i * pages_per_row;
    const unsigned char * row_ls   = lane_scales  +
        (int64_t) i * pages_per_row * T640_LANES_PER_PAGE;

    __shared__ float decoded_page[T640_PAGE];
    __shared__ float kv_prefetch[T640_KV_PREFETCH_MAX];

    const int32_t tid      = threadIdx.x;
    const int32_t sl       = tid & 31;
    const int32_t si       = tid >> 5;
    const int32_t nthreads = blockDim.x * blockDim.y * blockDim.z;

    // Drafter state: each thread accumulates a partial dot product for one
    // (token, vocab) pair. The pair is assigned by tid and persists across
    // pages; each page contributes a chunk of the hidden_dim reduction.
    float drafter_acc = 0.0f;
    unsigned int drafter_token_idx = 0;
    unsigned int drafter_vocab_idx = 0;
    if (iargs.drafter_enabled) {
        const unsigned int total  = iargs.drafter_n_tokens * iargs.drafter_vocab_slice;
        const unsigned int my_tile = (unsigned int) tid % total;
        drafter_token_idx = my_tile / iargs.drafter_vocab_slice;
        drafter_vocab_idx = my_tile % iargs.drafter_vocab_slice;
    }

    // KV state: this threadgroup quantizes one KV line per page iteration.
    // kv_line_idx advances each page; threads cooperatively reduce max_abs.
    unsigned int kv_line_idx = 0;
    float kv_max_abs = 0.0f;

    float acc = 0.0f;

    for (int32_t p = 0; p < nt; ++p) {
        // --- Cooperative decode (identical to base kernel) ---
        const float page_max = __half2float(row_ps[p]);
        for (int32_t col = tid; col < T640_PAGE; col += nthreads) {
            const int32_t qlane = col / T640_LANE;
            const float scale = page_max *
                ((float) row_ls[p * T640_LANES_PER_PAGE + qlane]) * (1.0f / 127.0f);
            unsigned int d;
            if (packing2) {
                d = (row_pack[p * 40 + col / 16] >> (2 * (col & 15))) & 3u;
            } else {
                d = tile640_trit(row_pack[p * T640_WORDS_PER_PAGE + qlane],
                                 col % T640_LANE);
            }
            decoded_page[col] = (d == 1u) ? scale : (d == 2u) ? -scale : 0.0f;
        }

        // --- KV prefetch: load one cache line into threadgroup ---
        if (iargs.kv_enabled && kv_line_idx < iargs.kv_seq_count) {
            const unsigned int seq_idx = iargs.kv_seq_start + kv_line_idx;
            for (unsigned int d = (unsigned int) tid;
                 d < iargs.kv_head_dim;
                 d += (unsigned int) nthreads) {
                kv_prefetch[d] = __half2float(kv_cache[seq_idx * iargs.kv_head_dim + d]);
            }
            kv_max_abs = 0.0f;
        }

        __syncthreads();

        // --- Dot product with temporal interleaving ---
        if (si < token_count) {
            const int32_t page_col0 = p * T640_PAGE;
            const int32_t page_cols = (T640_PAGE < in_dim - page_col0)
                                      ? T640_PAGE : (in_dim - page_col0);
            const int64_t input_base =
                ((int64_t) b * n_tokens + j0 + si) * in_dim + page_col0;

            int32_t k = sl * 4;
            for (; k + 3 < page_cols; k += 128) {
                // Issue activation load (~200-400 cycle latency)
                float4 a4 = tile640_load_activation4<input_f32>(input, input_base + k);

                // --- P1: drafter FMA while a4 is in flight ---
                if (iargs.drafter_enabled) {
                    const unsigned int h_idx =
                        ((unsigned int) k / 4u + (unsigned int) sl) % iargs.drafter_hidden_dim;
                    drafter_acc = fmaf(
                        __half2float(drafter_weights[drafter_vocab_idx * iargs.drafter_hidden_dim + h_idx]),
                        __half2float(drafter_hidden_state[drafter_token_idx * iargs.drafter_hidden_dim + h_idx]),
                        drafter_acc);
                }
                // --- P2: KV max_abs reduction from threadgroup (no device loads) ---
                else if (iargs.kv_enabled && kv_line_idx < iargs.kv_seq_count) {
                    const unsigned int kv_d =
                        ((unsigned int) k / 4u + (unsigned int) sl) % iargs.kv_head_dim;
                    kv_max_abs = fmaxf(kv_max_abs, fabsf(kv_prefetch[kv_d]));
                }

                // --- a4 has arrived; P0 FMA chain ---
                if (act_scale != nullptr) {
                    a4.x *= __half2float(act_scale[page_col0 + k]);
                    a4.y *= __half2float(act_scale[page_col0 + k + 1]);
                    a4.z *= __half2float(act_scale[page_col0 + k + 2]);
                    a4.w *= __half2float(act_scale[page_col0 + k + 3]);
                }
                const float4 d4 = *((const float4 *) (decoded_page + k));
                acc = fmaf(a4.x, d4.x, acc);
                acc = fmaf(a4.y, d4.y, acc);
                acc = fmaf(a4.z, d4.z, acc);
                acc = fmaf(a4.w, d4.w, acc);
            }
            // Scalar tail
            for (; k < page_cols; ++k) {
                float a = tile640_load_activation<input_f32>(input, input_base + k);
                if (act_scale != nullptr) {
                    a *= __half2float(act_scale[page_col0 + k]);
                }
                acc = fmaf(a, decoded_page[k], acc);
            }
        }
        __syncthreads();

        // --- P2: write KV quantized output for this line ---
        if (iargs.kv_enabled && kv_line_idx < iargs.kv_seq_count) {
            // Reduce max_abs across all threads (warp = simdgroup on wave32)
            kv_max_abs = warp_reduce_max<WARP_SIZE>(kv_max_abs);
            // Cross-warp fold via threadgroup memory.
            __shared__ float kv_reduce[4];
            if (sl == 0) {
                kv_reduce[si] = kv_max_abs;
            }
            __syncthreads();
            if (tid == 0) {
                float global_max = kv_reduce[0];
                const int n_warps = (nthreads + 31) / 32;
                for (int s = 1; s < n_warps; ++s) {
                    global_max = fmaxf(global_max, kv_reduce[s]);
                }
                const unsigned int seq_idx = iargs.kv_seq_start + kv_line_idx;
                const float scale = global_max / 127.0f;
                kv_scales_out[seq_idx] = __float2half(scale);
                kv_reduce[0] = scale;
            }
            __syncthreads();
            const float kv_scale = kv_reduce[0];
            if (kv_scale > 0.0f) {
                const unsigned int seq_idx = iargs.kv_seq_start + kv_line_idx;
                for (unsigned int d = (unsigned int) tid;
                     d < iargs.kv_head_dim;
                     d += (unsigned int) nthreads) {
                    int q = (int) lroundf(kv_prefetch[d] / kv_scale);
                    q = q < -127 ? -127 : (q > 127 ? 127 : q);
                    kv_quantized[seq_idx * iargs.kv_head_dim + d] = (unsigned char) q;
                }
            }
            kv_line_idx++;
        }
    }

    // --- P1: write drafter logits (reduce across pages) ---
    if (iargs.drafter_enabled) {
        drafter_acc = warp_reduce_sum<WARP_SIZE>(drafter_acc);
        if (sl == 0 && drafter_token_idx < iargs.drafter_n_tokens) {
            drafter_logits[drafter_token_idx * iargs.drafter_vocab_slice + drafter_vocab_idx] =
                drafter_acc + __half2float(drafter_bias[drafter_vocab_idx]);
        }
    }

    // --- Sparse outlier addback (identical to base kernel) ---
    const int32_t row_off_lo = (int32_t) outlier_row_offsets[i];
    const int32_t row_off_hi = (int32_t) outlier_row_offsets[i + 1];
    const int32_t K_i = row_off_hi - row_off_lo;
    if (si < token_count) {
        const int64_t input_base = ((int64_t) b * n_tokens + j0 + si) * in_dim;
        for (int32_t k = sl; k < K_i; k += 32) {
            const int32_t gk  = row_off_lo + k;
            const int32_t col = (int32_t) outlier_cols[gk];
            if (col < in_dim) {
                if (act_scale != nullptr) {
                    float ov = __half2float(outlier_vals[gk]) * __half2float(act_scale[col]);
                    acc = fmaf(tile640_load_activation<input_f32>(input, input_base + col), ov, acc);
                } else {
                    acc = fmaf(tile640_load_activation<input_f32>(input, input_base + col),
                               __half2float(outlier_vals[gk]), acc);
                }
            }
        }
    }

    acc = warp_reduce_sum<WARP_SIZE>(acc);
    if (si < token_count && sl == 0) {
        const int64_t output_offset =
            ((int64_t) b * n_tokens + j0 + si) * out_dim + i;
        output[output_offset] = acc;
    }
}

void ggml_cuda_op_tile640_matmul_interleaved(
        ggml_backend_cuda_context & ctx,
        const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst) {
    GGML_ASSERT(src0->type == GGML_TYPE_I32);
    GGML_ASSERT(src1->type == GGML_TYPE_F16 || src1->type == GGML_TYPE_F32);
    GGML_ASSERT(dst->type  == GGML_TYPE_F32);

    cudaStream_t stream = ctx.stream();

    const ggml_tensor * A_packed              = src0;
    const ggml_tensor * A_page_scales         = dst->src[1];
    const ggml_tensor * A_lane_scales         = dst->src[2];
    const ggml_tensor * A_outlier_row_offsets = dst->src[3];
    const ggml_tensor * A_outlier_cols        = dst->src[4];
    const ggml_tensor * A_outlier_vals        = dst->src[5];
    const ggml_tensor * B                     = src1;

    const int32_t out_dim  = ggml_get_op_params_i32(dst, 0);
    const int32_t packing  = ggml_get_op_params_i32(dst, 1);
    const int64_t in_dim   = B->ne[0];
    const int64_t n_tokens = B->ne[1];
    const int64_t n_batch  = B->ne[2];
    const int64_t n_seqs   = B->ne[3];

    const tile640_matmul_kargs_t kargs = {
        /*.ne12 =*/ (int32_t) n_tokens,
        /*.ne13 =*/ (int32_t) A_outlier_cols->ne[0],
        /*.ne14 =*/ packing,
    };

    // P1/P2 plumbing: drafter / KV paths are gated by iargs.{drafter,kv}_enabled.
    // Until the graph wire-up (Part 3a + future P1/P2 wrappers) populates them,
    // both flags stay zero and the kernel reduces to the P0 path.
    const interleaved_args_t iargs = {
        /*.drafter_enabled     =*/ 0,
        /*.drafter_hidden_dim  =*/ 0,
        /*.drafter_vocab_slice =*/ 0,
        /*.drafter_n_tokens    =*/ 0,
        /*.kv_enabled          =*/ 0,
        /*.kv_seq_start        =*/ 0,
        /*.kv_seq_count        =*/ 0,
        /*.kv_head_dim         =*/ 0,
        /*.in_dim              =*/ (int32_t) in_dim,
        /*.out_dim             =*/ out_dim,
        /*.packing             =*/ packing,
    };

    const int token_tile = T640_TOKEN_TILE;
    const int simdgroups_per_tg = token_tile < std::max(1, (int) n_tokens)
                                  ? token_tile : std::max(1, (int) n_tokens);
    dim3 block(32, simdgroups_per_tg, 1);
    dim3 grid(out_dim, (n_tokens + token_tile - 1) / token_tile, n_batch * n_seqs);

    auto launch = [&](auto input_f32_const, auto packing2_const) {
        constexpr bool input_f32_c = decltype(input_f32_const)::value;
        constexpr bool packing2_c   = decltype(packing2_const)::value;
        tile640_matmul_interleaved_kernel<input_f32_c, packing2_c>
            <<<grid, block, 0, stream>>>(
                kargs,
                (const unsigned int  *) A_packed->data,
                (const __half        *) A_page_scales->data,
                (const unsigned char *) A_lane_scales->data,
                (const unsigned int  *) A_outlier_row_offsets->data,
                (const unsigned int  *) A_outlier_cols->data,
                (const __half        *) A_outlier_vals->data,
                (const unsigned char *) B->data,
                (const __half        *) nullptr,
                (float               *) dst->data,
                (const __half        *) nullptr,
                (const __half        *) nullptr,
                (const __half        *) nullptr,
                (float               *) nullptr,
                (const __half        *) nullptr,
                (unsigned char       *) nullptr,
                (__half              *) nullptr,
                iargs);
    };

    const bool input_f32 = (B->type == GGML_TYPE_F32);
    const bool packing2  = (packing != 0);
    if (input_f32) {
        if (packing2) launch(std::true_type{}, std::true_type{});
        else          launch(std::true_type{}, std::false_type{});
    } else {
        if (packing2) launch(std::false_type{}, std::true_type{});
        else          launch(std::false_type{}, std::false_type{});
    }
}
