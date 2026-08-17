//
// tessera-metal-hip.cpp
//
// HIP implementation of the tessera-metal.h GPU lane. Selected on non-Apple
// builds when ROCm is available (see tools/quantize/CMakeLists.txt); the
// Apple build uses tessera-metal.mm and the fallback is tessera-metal-stub.cpp.
// Same ABI, same gate: ts_quantize_2d/3d only ever check ts_metal_available().
//
// The device kernels are a 1:1 port of tessera-metal.metal with two
// mechanical differences:
//   - simd_sum/simd_max become wave-size-agnostic __shared__ tree reductions
//     (correct on wave32 RDNA and wave64 CDNA alike).
//   - the dmr cross-wave reduction tail uses TS_SCT_THREADS floats instead of
//     Metal's 8-slot simdgroup array, so the host allocates
//     in_dim*4 + TS_SCT_THREADS*4 bytes of dynamic shared memory.
// The numeric semantics (f16 decode, ternary thresholds, lane/page scale
// fit, the page_max broadcast slot) match the Metal kernels exactly so the
// two lanes are interchangeable.
//
// Thread-safety: init/shutdown take a global mutex; all dispatches are
// serialized on one stream behind a dispatch mutex. The GA threads share
// the lane instead of encoding concurrently (one device, memory-bound).
//

#include <hip/hip_runtime.h>

#include "tessera-metal.h"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

// Concrete definitions of the opaque ABI types forward-declared in
// tessera-metal.h. They must live at global scope so they complete the
// header's `typedef struct ts_metal_context ts_metal_context_t` declarations
// (the Metal implementation does the same in tessera-metal.mm).
struct ts_hip_buf {
    void * ptr = nullptr;
    size_t bytes = 0;
};

struct ts_metal_context {
    int device = 0;
    int max_shared_mem = 0;
    hipStream_t stream = nullptr;

    // persistent per-process scratch (sized to the largest tensor seen)
    ts_hip_buf ws, core, tern, recon, partials, clip_limits, thresholds;
    // two scratch slots for make_qx_quants: integer and fractional halves
    // are kept separate so the (int)q count is preserved exactly.
    ts_hip_buf qx_partials_l, qx_partials_lx;  // [19 * n_blocks_max] floats each
};

struct ts_metal_weights {
    int64_t out_dim = 0;
    int64_t in_dim  = 0;

    float * W    = nullptr;   // [out_dim * in_dim] device
    float * act  = nullptr;   // [in_dim] device (may be null)
    float * act2 = nullptr;   // [in_dim] device (may be null)
    float   inv_median = 0.0f;
};

namespace {

#define TS_PAGE_SIZE      640
#define TS_LANE_SIZE      20
#define TS_LANES_PER_PAGE 32
#define TS_SCT_THREADS    256
#define TS_DMR_MAX_ROW    8192
#define TS_AWQ_MAX_PAGES  32

// Mirror of the device-side argument structs (keep layout identical).
struct ts_sct_args {
    uint32_t out_dim;
    uint32_t in_dim;
    float    clip;
    uint32_t do_clip;
};
struct ts_dmr_args {
    uint32_t out_dim;
    uint32_t in_dim;
    uint32_t n_outliers;
    uint32_t _pad;
};
struct ts_awq_args {
    uint32_t out_dim;
    uint32_t in_dim;
    uint32_t n_grid;
    uint32_t _pad;
};

struct ts_sct_partial { float abs_sum; float maxabs; };
struct ts_dmr_partial { float mse_sum; float n_count; };
struct ts_awq_partial { float err_sum; float n_count; };

// ---------------------------------------------------------------------------
// f16 -> f32 (bit-identical to tessera-metal.metal / tessera-quant.cpp)
// ---------------------------------------------------------------------------

__device__ __forceinline__ float ts_f16_to_f32(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000u) << 16;
    uint32_t exp  = (h >> 10) & 0x1fu;
    uint32_t mant = h & 0x3ffu;
    uint32_t bits;
    if (exp == 0u) {
        if (mant == 0u) {
            bits = sign;
        } else {
            int e = -1;
            do { mant <<= 1; e--; } while ((mant & 0x400u) == 0u);
            mant &= 0x3ffu;
            bits = sign | ((uint32_t)(e + 127 + 1) << 23) | (mant << 13);
        }
    } else if (exp == 0x1fu) {
        bits = sign | 0x7f800000u | (mant << 13);
    } else {
        bits = sign | ((exp - 15u + 127u) << 23) | (mant << 13);
    }
    float out;
    std::memcpy(&out, &bits, sizeof(out));
    return out;
}

// Wave-size-agnostic block reduction over blockDim.x threads (power of two).
__device__ __forceinline__ void ts_block_reduce_sum_max(float * sh_sum, float * sh_max,
                                                        float & val_sum, float & val_max) {
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;
    sh_sum[tid] = val_sum;
    sh_max[tid] = val_max;
    __syncthreads();
    for (uint32_t s = nt / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sh_sum[tid] += sh_sum[tid + s];
            sh_max[tid]  = fmaxf(sh_max[tid], sh_max[tid + s]);
        }
        __syncthreads();
    }
}

__device__ __forceinline__ void ts_block_reduce_sum(float * sh, float & val) {
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;
    sh[tid] = val;
    __syncthreads();
    for (uint32_t s = nt / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sh[tid] += sh[tid + s];
        }
        __syncthreads();
    }
}

// ===========================================================================
// Kernel 1: scale + clip + ternarize (two dispatches, mirrors the Metal split)
// ===========================================================================

__global__ void ts_hip_sct_reduce(ts_sct_args args,
                                  const float * __restrict__ W,
                                  const float * __restrict__ wscale,
                                  float * __restrict__ ws,
                                  float * __restrict__ core,
                                  ts_sct_partial * __restrict__ partials) {
    const uint64_t row = blockIdx.x;
    if (row >= args.out_dim) return;
    const uint32_t in_dim = args.in_dim;
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;

    const float * Wrow    = W    + row * in_dim;
    float       * wsrow   = ws   + row * in_dim;
    float       * corerow = core + row * in_dim;

    float local_abs_sum = 0.0f;
    float local_maxabs  = 0.0f;
    for (uint32_t c = tid; c < in_dim; c += nt) {
        float v = Wrow[c] * wscale[c];
        wsrow[c]   = v;
        corerow[c] = v;
        float a = fabsf(v);
        local_abs_sum += a;
        local_maxabs   = fmaxf(local_maxabs, a);
    }

    __shared__ float tg_sum[TS_SCT_THREADS];
    __shared__ float tg_max[TS_SCT_THREADS];
    ts_block_reduce_sum_max(tg_sum, tg_max, local_abs_sum, local_maxabs);
    if (tid == 0u) {
        partials[row].abs_sum = tg_sum[0];
        partials[row].maxabs  = tg_max[0];
    }
}

__global__ void ts_hip_sct_ternarize(ts_sct_args args,
                                     float * __restrict__ core,
                                     int8_t * __restrict__ ternary,
                                     const float * __restrict__ clip_limits,
                                     float threshold) {
    const uint64_t row = blockIdx.x;
    if (row >= args.out_dim) return;
    const uint32_t in_dim = args.in_dim;
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;

    float  * corerow = core    + row * in_dim;
    int8_t * terow   = ternary + row * in_dim;

    const float limit = args.do_clip ? clip_limits[row] : INFINITY;

    for (uint32_t c = tid; c < in_dim; c += nt) {
        float v = corerow[c];
        if (args.do_clip) {
            v = fminf(fmaxf(v, -limit), limit);
            corerow[c] = v;
        }
        int8_t t = 0;
        if (fabsf(v) >= threshold) {
            t = (v > 0.0f) ? (int8_t)1 : (v < 0.0f ? (int8_t)(-1) : (int8_t)0);
        }
        terow[c] = t;
    }
}

// ===========================================================================
// Kernel 2: dequant + outlier restore + MSE + recon
// ===========================================================================
// Dynamic shared memory layout: deq_scratch[in_dim] followed by the
// TS_SCT_THREADS-float reduction tail. The host passes
// in_dim*4 + TS_SCT_THREADS*4 bytes.

__global__ void ts_hip_dmr(ts_dmr_args args,
                           const int8_t * __restrict__ ternary,
                           const uint16_t * __restrict__ page_scales,
                           const int8_t * __restrict__ lane_scales,
                           const int32_t * __restrict__ outlier_idx,
                           const uint32_t * __restrict__ row_starts,
                           const float * __restrict__ ws,
                           const float * __restrict__ input_scale,
                           float * __restrict__ recon,
                           ts_dmr_partial * __restrict__ partials) {
    extern __shared__ float deq_scratch[];

    const uint64_t row = blockIdx.x;
    if (row >= args.out_dim) return;
    const uint32_t in_dim = args.in_dim;
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;
    const uint32_t pages_per_row = (in_dim + TS_PAGE_SIZE - 1) / TS_PAGE_SIZE;

    const int8_t   * terow    = ternary     + row * in_dim;
    const float    * wsrow    = ws          + row * in_dim;
    float          * reconrow = recon       + row * in_dim;
    const uint16_t * row_ps   = page_scales + row * pages_per_row;
    const int8_t   * row_ls   = lane_scales + row * pages_per_row * TS_LANES_PER_PAGE;

    for (uint32_t c = tid; c < in_dim; c += nt) {
        const uint32_t p    = c / TS_PAGE_SIZE;
        const uint32_t lane = (c % TS_PAGE_SIZE) / TS_LANE_SIZE;
        const float amp = ts_f16_to_f32(row_ps[p]) *
                          (float)row_ls[p * TS_LANES_PER_PAGE + lane] * (1.0f / 127.0f);
        deq_scratch[c] = (float)terow[c] * amp;
    }
    __syncthreads();

    const uint32_t lo = row_starts[row];
    const uint32_t hi = row_starts[row + 1];
    for (uint32_t k = lo + tid; k < hi; k += nt) {
        const uint32_t col = (uint32_t)outlier_idx[k] % in_dim;
        deq_scratch[col] = wsrow[col];
    }
    __syncthreads();

    float local_mse = 0.0f;
    for (uint32_t c = tid; c < in_dim; c += nt) {
        const float dq = deq_scratch[c];
        const float d  = wsrow[c] - dq;
        local_mse += d * d;
        reconrow[c] = dq * input_scale[c];
    }

    float * tg_sum = deq_scratch + in_dim;
    ts_block_reduce_sum(tg_sum, local_mse);
    if (tid == 0u) {
        partials[row].mse_sum = tg_sum[0];
        partials[row].n_count = (float)in_dim;
    }
}

// ===========================================================================
// Kernel 3: batched AWQ grid search (two phases, mirrors the Metal split)
// ===========================================================================

__global__ void ts_hip_awq_threshold(ts_awq_args args,
                                     const float * __restrict__ W,
                                     const float * __restrict__ act,
                                     const float * __restrict__ grid,
                                     float inv_median,
                                     float * __restrict__ abs_partials) {
    const uint64_t row  = blockIdx.x;
    const uint32_t gidx = blockIdx.y;
    const uint32_t tid  = threadIdx.x;
    const uint32_t nt   = blockDim.x;
    if (row >= args.out_dim || gidx >= args.n_grid) return;
    const uint32_t in_dim = args.in_dim;
    const float alpha = grid[gidx];

    const float * Wrow = W + row * in_dim;

    float abs_sum = 0.0f;
    for (uint32_t c = tid; c < in_dim; c += nt) {
        float rel = fminf(fmaxf(act[c] * inv_median, 1.0f / 256.0f), 256.0f);
        abs_sum += fabsf(Wrow[c] * powf(rel, alpha));
    }

    __shared__ float tg_sum[TS_SCT_THREADS];
    ts_block_reduce_sum(tg_sum, abs_sum);
    if (tid == 0u) {
        abs_partials[row * args.n_grid + gidx] = tg_sum[0];
    }
}

__global__ void ts_hip_awq_grid(ts_awq_args args,
                                const float * __restrict__ W,
                                const float * __restrict__ act,
                                const float * __restrict__ act2,
                                const float * __restrict__ grid,
                                const float * __restrict__ thresholds,
                                float inv_median,
                                ts_awq_partial * __restrict__ partials) {
    const uint64_t row  = blockIdx.x;
    const uint32_t gidx = blockIdx.y;
    const uint32_t tid  = threadIdx.x;
    const uint32_t nt   = blockDim.x;
    if (row >= args.out_dim || gidx >= args.n_grid) return;
    const uint32_t in_dim   = args.in_dim;
    const float alpha     = grid[gidx];
    const float threshold = thresholds[gidx];

    const float * Wrow = W + row * in_dim;

    __shared__ float lane_tg[TS_AWQ_MAX_PAGES * TS_LANES_PER_PAGE];
    __shared__ float tg_sum[TS_SCT_THREADS];

    const uint32_t pages_per_row = (in_dim + TS_PAGE_SIZE - 1) / TS_PAGE_SIZE;

    float local_err = 0.0f;
    for (uint32_t p = 0; p < pages_per_row; p++) {
        // lane targets: one thread per lane (32 threads).
        if (tid < TS_LANES_PER_PAGE) {
            float s_abs = 0.0f;
            int   cnt   = 0;
            for (uint32_t k = 0; k < TS_LANE_SIZE; k++) {
                const uint32_t c = p * TS_PAGE_SIZE + tid * TS_LANE_SIZE + k;
                if (c >= in_dim) break;
                const float rel = fminf(fmaxf(act[c] * inv_median,
                                              1.0f / 256.0f), 256.0f);
                const float wsv = Wrow[c] * powf(rel, alpha);
                if (fabsf(wsv) >= threshold) { s_abs += fabsf(wsv); cnt++; }
            }
            lane_tg[p * TS_LANES_PER_PAGE + tid] = (cnt > 0) ? (s_abs / (float)cnt) : 0.0f;
        }
        __syncthreads();

        // page_max = max over the 32 lane targets. Thread 0 reduces serially
        // (max is order-independent) and broadcasts via slot 0, matching the
        // Metal kernel's simd_max + lane_tg[p*32] write exactly.
        if (tid == 0u) {
            float page_max = 0.0f;
            for (uint32_t l = 0; l < TS_LANES_PER_PAGE; l++) {
                page_max = fmaxf(page_max, lane_tg[p * TS_LANES_PER_PAGE + l]);
            }
            lane_tg[p * TS_LANES_PER_PAGE] = page_max;
        }
        __syncthreads();
        float page_max = lane_tg[p * TS_LANES_PER_PAGE];
        if (page_max < 1e-30f) page_max = 1.0f;

        // dequant + err. Each thread strides the 640 page columns.
        for (uint32_t c = tid; c < TS_PAGE_SIZE; c += nt) {
            const uint32_t col = p * TS_PAGE_SIZE + c;
            if (col >= in_dim) break;
            const float rel = fminf(fmaxf(act[col] * inv_median, 1.0f / 256.0f), 256.0f);
            const float s   = powf(rel, alpha);
            const float wsv = Wrow[col] * s;
            int t = 0;
            if (fabsf(wsv) >= threshold) {
                t = (wsv > 0.0f) ? 1 : (wsv < 0.0f ? -1 : 0);
            }
            const uint32_t lane = c / TS_LANE_SIZE;
            const float lt      = lane_tg[p * TS_LANES_PER_PAGE + lane];
            // Match ts_compute_scales + ts_dequant exactly: the stored lane
            // scale is round(lt/page_max*127) clamped to [1,127], and the
            // dequant amplitude is page_max * lane_q / 127.
            float raw_q = (lt / page_max) * 127.0f;
            int   q = (int) rintf(raw_q);
            q = max(1, min(127, q));
            const float amp = page_max * (float)q * (1.0f / 127.0f);
            const float dq       = (float)t * amp;
            const float dq_orig  = dq / s;       // back to original weight space
            const float d        = dq_orig - Wrow[col];
            local_err += d * d * act2[col];
        }
        __syncthreads();
    }

    ts_block_reduce_sum(tg_sum, local_err);
    if (tid == 0u) {
        const uint64_t pidx = row * args.n_grid + gidx;
        partials[pidx].err_sum = tg_sum[0];
        partials[pidx].n_count = (float)in_dim;
    }
}

// ---------------------------------------------------------------------------
// Kernel: imatrix per-row sum-of-squares
// ---------------------------------------------------------------------------
// Replaces the scalar inner loop in IMatrixCollector::collect_imatrix
// (tools/imatrix/imatrix.cpp:618 for MoE, :675 for dense). One block per
// source row; 256 threads cooperate to compute the F32 sum-of-squares
// over `channels` elements, then atomicAdd the result into the per-row
// target slot in the collector's stats vector (host-resident, atomic via
// the device atomicAdd on the value_dev buffer that the shim mirrors).
//
// Two layouts:
//   dense  : values_dev[mat_start + j] += x[j] * x[j]
//   MoE    : values_dev[mat_id * channels + j] += x[j] * x[j]
//
// The shim does the H2D copy of x, runs one kernel, D2H-copies the row
// totals back. On hosts without the HIP lane the function returns 1 and
// the caller falls back to the scalar loop.

__global__ void ts_hip_imatrix_sumsq(const float * __restrict__ x,
                                      float * __restrict__ values_dev,
                                      uint32_t channels,
                                      uint32_t row_offset_floats) {
    const uint32_t row = blockIdx.x;
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;
    const float * xrow = x + (uint64_t)row * channels;

    float local = 0.0f;
    for (uint32_t c = tid; c < channels; c += nt) {
        float v = xrow[c];
        local += v * v;
    }
    __shared__ float tg[TS_SCT_THREADS];
    ts_block_reduce_sum(tg, local);
    if (tid == 0u && tg[0] != 0.0f) {
        // Atomic add to the per-row slot. The shim pre-zeros the device
        // buffer for the dense case; the MoE case accumulates across
        // tokens, so the slot starts at zero.
        atomicAdd(values_dev + (uint64_t)row_offset_floats + (uint64_t)row * channels,
                  tg[0]);
    }
}

// ---------------------------------------------------------------------------
// Kernel: F64 Frobenius ratio (||approx||_F^2 / ||target||_F^2)
// ---------------------------------------------------------------------------
// Replaces the scalar Frobenius loop in ts_l1_kernel_direct_t2
// (tools/quantize/tessera/tessera-l1-fitness.cpp). F64 accumulation rules
// out the rocBLAS shim (F32-only). One block per 8192 elements, 256 threads,
// per-thread F64 partial sums, warp-shuffle then shared-memory reduction,
// atomicAdd into the per-block slot. The host folds the per-block pairs
// into a single numerator+denominator (block count is small).

#define TS_L1_BLOCK_THREADS 256
#define TS_L1_BLOCK_ELEMS  8192

__global__ void ts_hip_l1_ratio(const float * __restrict__ approx,
                                const float * __restrict__ target,
                                double * __restrict__ partials,
                                uint32_t n,
                                uint32_t n_blocks) {
    const uint32_t bid = blockIdx.x;
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;
    const uint64_t base = (uint64_t)bid * (uint64_t)TS_L1_BLOCK_ELEMS;
    const uint64_t end  = min((uint64_t)n, base + (uint64_t)TS_L1_BLOCK_ELEMS);

    double local_num = 0.0;
    double local_den = 0.0;
    for (uint64_t i = base + (uint64_t)tid; i < end; i += (uint64_t)nt) {
        const double a = (double)approx[i];
        const double b = (double)target[i];
        local_num += a * a;
        local_den += b * b;
    }

    // warp-shuffle reduce within each warp (wave32 on gfx1103 / wave64 on
    // CDNA). The shuffle mask is 32 lanes; for lane >= 32 the result is
    // unchanged, so the warp reduction is correct on wave32. On wave64 the
    // latter two warps end up with their original partial sums (a no-op), and
    // the cross-warp fold in shared memory still produces the block sum.
    unsigned mask = 0xffffffffu;
    for (int off = 16; off > 0; off >>= 1) {
        local_num += __shfl_down(local_num, (unsigned)off, mask);
        local_den += __shfl_down(local_den, (unsigned)off, mask);
    }
    const uint32_t lane = tid & 31u;
    const uint32_t warp = tid >> 5;
    const uint32_t n_warps = (nt + 31u) >> 5;

    __shared__ double sh_num[TS_L1_BLOCK_THREADS / 32];
    __shared__ double sh_den[TS_L1_BLOCK_THREADS / 32];
    if (lane == 0u) {
        sh_num[warp] = local_num;
        sh_den[warp] = local_den;
    }
    __syncthreads();

    if (warp == 0u) {
        const uint32_t w = (n_warps > lane) ? lane : 0u;
        double wn = (lane < n_warps) ? sh_num[w] : 0.0;
        double wd = (lane < n_warps) ? sh_den[w] : 0.0;
        for (int off = 16; off > 0; off >>= 1) {
            wn += __shfl_down(wn, (unsigned)off, mask);
            wd += __shfl_down(wd, (unsigned)off, mask);
        }
        if (lane == 0u && (uint64_t)bid < (uint64_t)n_blocks) {
            // 2 doubles per block: [num_0, den_0, num_1, den_1, ...].
            atomicAdd(partials + (uint64_t)bid * 2u,         wn);
            atomicAdd(partials + (uint64_t)bid * 2u + 1u,   wd);
        }
    }
}

// ---------------------------------------------------------------------------
// Kernel: make_qx_quants 19-trial scale sweep
// ---------------------------------------------------------------------------
// Replaces the 19-trial scale sweep in upstream make_qx_quants
// (ggml/src/ggml-quants.c:1435-1502). One block per 8192 elements, 256
// threads, per-thread accumulation across 19 trials, a shared-memory
// reduction over the 19 trials, and a single atomicAdd per (trial, block)
// to a per-trial scratch slot. The host folds the per-block partials into
// the 19 quant_max outputs.
//
// Each trial produces two accumulators: suml (integer count, large - the
// (int)q cast), and sumlx (fractional remainder in [0, n)). The upstream
// output is suml + sumlx/n. The kernel keeps the two halves separate (so
// the integer count is preserved exactly) and the host does the final
// suml + sumlx/n fold.
//
// Per-element work is lightweight (~95 FLOPs/element across 19 trials), so
// the kernel is memory-bandwidth-bound. The 19 atomicAdds per block are
// the only cross-block synchronization; the host folds the two halves of
// the [19 * n_blocks] partials into 19 floats in a single pass.

#define TS_QX_TRIALS       19
#define TS_QX_BLOCK_ELEMS  8192

__global__ void ts_hip_make_qx_quants(const float * __restrict__ x,
                                      float * __restrict__ partials_l,    // [19 * n_blocks]
                                      float * __restrict__ partials_lx,   // [19 * n_blocks]
                                      uint32_t n,
                                      uint32_t n_blocks,
                                      float inv_l2) {
    const uint32_t bid = blockIdx.x;
    const uint32_t tid = threadIdx.x;
    const uint32_t nt  = blockDim.x;
    const uint64_t base = (uint64_t)bid * (uint64_t)TS_QX_BLOCK_ELEMS;
    const uint64_t end  = min((uint64_t)n, base + (uint64_t)TS_QX_BLOCK_ELEMS);

    // Per-thread accumulators across all 19 trials. Two arrays keep the
    // integer and fractional halves separate so the (int)q cast on the
    // CPU side stays integer-typed here too.
    float local_suml [TS_QX_TRIALS];
    float local_sumlx[TS_QX_TRIALS];
    for (int t = 0; t < TS_QX_TRIALS; ++t) {
        local_suml [t] = 0.0f;
        local_sumlx[t] = 0.0f;
    }

    for (uint64_t i = base + (uint64_t)tid; i < end; i += (uint64_t)nt) {
        const float v = x[i] * x[i];
        if (v > 0.0f) {
            for (int t = 0; t < TS_QX_TRIALS; ++t) {
                const float qmax = 0.95f * powf(1.0f - 0.05f * (float)t, 0.5f);
                const float q    = v * inv_l2 * qmax * qmax;
                const float qq   = sqrtf(q);
                const int   qi   = (int)qq;
                local_suml [t] += (float)qi;
                local_sumlx[t] += qq - (float)qi;
            }
        }
    }

    // Block reduction over the 256 threads, per trial, for both halves.
    // 19 trials x 2 halves -> 38 shared sums. Fold serially.
    __shared__ float tg_l [TS_QX_TRIALS * TS_SCT_THREADS];
    __shared__ float tg_lx[TS_QX_TRIALS * TS_SCT_THREADS];
    for (int t = 0; t < TS_QX_TRIALS; ++t) {
        tg_l [t * TS_SCT_THREADS + tid] = local_suml [t];
        tg_lx[t * TS_SCT_THREADS + tid] = local_sumlx[t];
    }
    __syncthreads();
    for (uint32_t s = nt / 2u; s > 0u; s >>= 1u) {
        if (tid < s) {
            for (int t = 0; t < TS_QX_TRIALS; ++t) {
                tg_l [t * TS_SCT_THREADS + tid] += tg_l [t * TS_SCT_THREADS + tid + s];
                tg_lx[t * TS_SCT_THREADS + tid] += tg_lx[t * TS_SCT_THREADS + tid + s];
            }
        }
        __syncthreads();
    }

    // One atomicAdd per (trial, block) per half: 38 atomic ops per block.
    // The host zeros both partial buffers before launch so the accumulation
    // is exact.
    if (tid == 0u && (uint64_t)bid < (uint64_t)n_blocks) {
        for (int t = 0; t < TS_QX_TRIALS; ++t) {
            atomicAdd(partials_l  + (uint64_t)t * (uint64_t)n_blocks + (uint64_t)bid,
                      tg_l [t * TS_SCT_THREADS]);
            atomicAdd(partials_lx + (uint64_t)t * (uint64_t)n_blocks + (uint64_t)bid,
                      tg_lx[t * TS_SCT_THREADS]);
        }
    }
}

// ---------------------------------------------------------------------------
// global context
// ---------------------------------------------------------------------------

ts_metal_context * g_ctx = nullptr;
std::mutex         g_init_mutex;
std::mutex         g_dispatch_mutex;
std::atomic<int>   g_avail{0};   // -1 = untried/failed-final, 0 = unavailable, 1 = available

// Stream accessor for the rocBLAS shim (tessera-rocblas.cpp). Returns the
// process-global HIP stream when the Metal/HIP lane is initialized,
// nullptr otherwise (callers fall back to the HIP default stream).
extern "C" hipStream_t ts_metal_hip_stream() {
    return (g_ctx != nullptr) ? g_ctx->stream : nullptr;
}

// Grow-only device scratch: hipMalloc of large buffers is expensive, and the
// GA hot path dispatches hundreds of evals per layer. Buffers only grow;
// ts_metal_shutdown frees them.
static bool ensure_buf(ts_hip_buf & b, size_t need) {
    if (b.bytes >= need) return true;
    if (b.ptr != nullptr) {
        (void)hipFree(b.ptr);
        b.ptr = nullptr;
        b.bytes = 0;
    }
    if (hipMalloc(&b.ptr, need) != hipSuccess) {
        b.ptr = nullptr;
        return false;
    }
    b.bytes = need;
    return true;
}

// median of the finite, strictly-positive entries; mirrors the CPU
// ts_median_finite_positive so AWQ normalization matches exactly.
static float median_finite_positive(const float * x, int64_t n) {
    std::vector<float> v;
    v.reserve((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        float xv = x[i];
        if (std::isfinite(xv) && xv > 0.0f) v.push_back(xv);
    }
    if (v.empty()) return 0.0f;
    size_t mid = v.size() / 2;
    std::nth_element(v.begin(), v.begin() + mid, v.end());
    float m = v[mid];
    if (v.size() % 2 == 0) {
        float lo = *std::max_element(v.begin(), v.begin() + mid);
        m = 0.5f * (lo + m);
    }
    return m;
}

static bool upload(const void * host, void * dev, size_t bytes, hipStream_t stream) {
    return hipMemcpyAsync(dev, host, bytes, hipMemcpyHostToDevice, stream) == hipSuccess;
}

}  // namespace

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

extern "C" {

int ts_metal_available(void) {
    // Same kill switch contract as the Metal implementation.
    if (g_avail.load() == 1) {
        const char * dis = getenv("TS_METAL_DISABLE");
        if (dis && dis[0] == '1') return 0;
        return 1;
    }
    return 0;
}

int ts_metal_init(void) {
    if (g_avail.load() == 1) return 0;

    std::lock_guard<std::mutex> lk(g_init_mutex);
    if (g_avail.load() == 1) return 0;
    if (g_ctx != nullptr) return 1;  // previously failed in a weird state

    int count = 0;
    if (hipGetDeviceCount(&count) != hipSuccess || count <= 0) {
        g_avail.store(0);
        return 1;
    }

    ts_metal_context * ctx = new ts_metal_context();

    int device = 0;
    const char * dev_env = getenv("TS_HIP_DEVICE");
    if (dev_env != nullptr && dev_env[0] != '\0') {
        int d = atoi(dev_env);
        if (d >= 0 && d < count) device = d;
    }
    ctx->device = device;
    if (hipSetDevice(device) != hipSuccess) {
        delete ctx;
        g_avail.store(0);
        return 1;
    }

    int shared_mem = 0;
    if (hipDeviceGetAttribute(&shared_mem, hipDeviceAttributeMaxSharedMemoryPerBlock, device) != hipSuccess) {
        shared_mem = 0;  // query failed -> the dmr kernel falls back to CPU
    }
    ctx->max_shared_mem = shared_mem;

    if (hipStreamCreateWithFlags(&ctx->stream, hipStreamNonBlocking) != hipSuccess) {
        delete ctx;
        g_avail.store(0);
        return 1;
    }

    g_ctx = ctx;
    g_avail.store(1);
    return 0;
}

void ts_metal_shutdown(void) {
    std::lock_guard<std::mutex> lk(g_init_mutex);
    if (g_ctx != nullptr) {
        ts_hip_buf * bufs[] = { &g_ctx->ws, &g_ctx->core, &g_ctx->tern,
                                &g_ctx->recon, &g_ctx->partials,
                                &g_ctx->clip_limits, &g_ctx->thresholds,
                                &g_ctx->qx_partials_l, &g_ctx->qx_partials_lx };
        for (ts_hip_buf * b : bufs) {
            if (b->ptr != nullptr) (void)hipFree(b->ptr);
        }
        if (g_ctx->stream != nullptr) (void)hipStreamDestroy(g_ctx->stream);
        delete g_ctx;
        g_ctx = nullptr;
    }
    g_avail.store(-1);
}

ts_metal_weights_t * ts_metal_upload_weights(const float * weights,
                                             const float * act_scales,
                                             int64_t out_dim,
                                             int64_t in_dim) {
    if (!ts_metal_available() || g_ctx == nullptr ||
        weights == nullptr || out_dim <= 0 || in_dim <= 0) {
        return nullptr;
    }

    ts_metal_weights_t * w = new ts_metal_weights_t;
    w->out_dim = out_dim;
    w->in_dim  = in_dim;

    const size_t wbytes = (size_t)(out_dim * in_dim) * sizeof(float);
    if (hipMalloc((void **)&w->W, wbytes) != hipSuccess ||
        !upload(weights, w->W, wbytes, g_ctx->stream)) {
        if (w->W != nullptr) (void)hipFree(w->W);
        delete w;
        return nullptr;
    }

    if (act_scales != nullptr) {
        const size_t sbytes = (size_t)in_dim * sizeof(float);
        std::vector<float> act2((size_t)in_dim);
        for (int64_t c = 0; c < in_dim; c++) {
            float a = act_scales[c];
            act2[(size_t)c] = a * a;
        }
        if (hipMalloc((void **)&w->act, sbytes) != hipSuccess ||
            hipMalloc((void **)&w->act2, sbytes) != hipSuccess ||
            !upload(act_scales, w->act, sbytes, g_ctx->stream) ||
            !upload(act2.data(), w->act2, sbytes, g_ctx->stream)) {
            if (w->act  != nullptr) (void)hipFree(w->act);
            if (w->act2 != nullptr) (void)hipFree(w->act2);
            (void)hipFree(w->W);
            delete w;
            return nullptr;
        }

        float med = median_finite_positive(act_scales, in_dim);
        w->inv_median = (med > 0.0f) ? (1.0f / med) : 0.0f;
    }

    if (hipStreamSynchronize(g_ctx->stream) != hipSuccess) {
        if (w->act  != nullptr) (void)hipFree(w->act);
        if (w->act2 != nullptr) (void)hipFree(w->act2);
        (void)hipFree(w->W);
        delete w;
        return nullptr;
    }
    return w;
}

void ts_metal_release_weights(ts_metal_weights_t * w) {
    if (w == nullptr) return;
    if (w->W    != nullptr) (void)hipFree(w->W);
    if (w->act  != nullptr) (void)hipFree(w->act);
    if (w->act2 != nullptr) (void)hipFree(w->act2);
    delete w;
}

// -----------------------------------------------------------------------
// Kernel 1: scale + clip + ternarize
// -----------------------------------------------------------------------

int ts_metal_scale_clip_ternarize(ts_metal_weights_t * w,
                                  const float * wscale,
                                  float clip,
                                  float * ws_out,
                                  float * core_out,
                                  int8_t * ternary_out,
                                  float * global_amp_out) {
    if (!ts_metal_available() || g_ctx == nullptr || w == nullptr ||
        wscale == nullptr || ws_out == nullptr || core_out == nullptr ||
        ternary_out == nullptr || global_amp_out == nullptr) {
        return 1;
    }

    const int64_t out_dim = w->out_dim;
    const int64_t in_dim  = w->in_dim;
    const size_t n = (size_t)(out_dim * in_dim);

    std::lock_guard<std::mutex> lk(g_dispatch_mutex);
    hipStream_t stream = g_ctx->stream;

    if (!ensure_buf(g_ctx->ws, n * sizeof(float)) ||
        !ensure_buf(g_ctx->core, n * sizeof(float)) ||
        !ensure_buf(g_ctx->tern, n * sizeof(int8_t)) ||
        !ensure_buf(g_ctx->partials, (size_t)out_dim * sizeof(ts_sct_partial)) ||
        !ensure_buf(g_ctx->clip_limits, (size_t)out_dim * sizeof(float))) {
        return 1;
    }

    // wscale is small and per-call: stage through a fresh device buffer.
    float * wscale_dev = nullptr;
    if (hipMalloc((void **)&wscale_dev, (size_t)in_dim * sizeof(float)) != hipSuccess) {
        return 1;
    }
    bool ok = upload(wscale, wscale_dev, (size_t)in_dim * sizeof(float), stream);

    // ---- phase 0: scale + reduce ----
    ts_sct_args args;
    args.out_dim = (uint32_t)out_dim;
    args.in_dim  = (uint32_t)in_dim;
    args.clip    = clip;
    args.do_clip = (clip > 0.0f && clip < 1.0f) ? 1u : 0u;

    if (ok) {
        hipLaunchKernelGGL(ts_hip_sct_reduce,
                           dim3((unsigned)out_dim), dim3(TS_SCT_THREADS), 0, stream,
                           args, w->W, wscale_dev,
                           (float *)g_ctx->ws.ptr, (float *)g_ctx->core.ptr,
                           (ts_sct_partial *)g_ctx->partials.ptr);
        ok = (hipGetLastError() == hipSuccess);
    }

    std::vector<ts_sct_partial> part((size_t)out_dim);
    if (ok) {
        ok = (hipMemcpyAsync(part.data(), g_ctx->partials.ptr,
                             (size_t)out_dim * sizeof(ts_sct_partial),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);
    if (!ok) { (void)hipFree(wscale_dev); return 1; }

    double total_abs = 0.0;
    std::vector<float> clip_limits((size_t)out_dim);
    for (int64_t r = 0; r < out_dim; r++) {
        total_abs += (double)part[(size_t)r].abs_sum;
        clip_limits[(size_t)r] = part[(size_t)r].maxabs * clip;
    }
    const double total_n = (double)(out_dim * in_dim);
    const float threshold = (total_n > 0.0) ? (float)(total_abs / total_n) : 0.0f;
    *global_amp_out = threshold;

    // ---- phase 1: clip core in place + ternarize ----
    ok = upload(clip_limits.data(), g_ctx->clip_limits.ptr,
                (size_t)out_dim * sizeof(float), stream);
    if (ok) {
        hipLaunchKernelGGL(ts_hip_sct_ternarize,
                           dim3((unsigned)out_dim), dim3(TS_SCT_THREADS), 0, stream,
                           args, (float *)g_ctx->core.ptr, (int8_t *)g_ctx->tern.ptr,
                           (const float *)g_ctx->clip_limits.ptr, threshold);
        ok = (hipGetLastError() == hipSuccess);
    }

    // ---- copy results back ----
    if (ok) {
        ok = (hipMemcpyAsync(ws_out, g_ctx->ws.ptr, n * sizeof(float),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) {
        ok = (hipMemcpyAsync(core_out, g_ctx->core.ptr, n * sizeof(float),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) {
        ok = (hipMemcpyAsync(ternary_out, g_ctx->tern.ptr, n * sizeof(int8_t),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    (void)hipFree(wscale_dev);
    return ok ? 0 : 1;
}

// -----------------------------------------------------------------------
// Kernel 2: dequant + MSE + recon
// -----------------------------------------------------------------------

int ts_metal_dequant_mse_recon(ts_metal_weights_t * w,
                               const int8_t * ternary,
                               const uint16_t * page_scales,
                               const int8_t * lane_scales,
                               const int32_t * outlier_idx,
                               int64_t n_outliers,
                               const float * ws,
                               const float * input_scale,
                               float * recon_out,
                               float * mse_out) {
    if (!ts_metal_available() || g_ctx == nullptr || w == nullptr ||
        ternary == nullptr || page_scales == nullptr || lane_scales == nullptr ||
        ws == nullptr || input_scale == nullptr || recon_out == nullptr ||
        mse_out == nullptr) {
        return 1;
    }
    if (w->in_dim > TS_DMR_MAX_ROW) return 2;

    const int64_t out_dim = w->out_dim;
    const int64_t in_dim  = w->in_dim;
    const size_t n = (size_t)(out_dim * in_dim);
    const size_t pages_per_row = (size_t)((in_dim + TS_PAGE_SIZE - 1) / TS_PAGE_SIZE);

    // dynamic shared: dequant row + reduction tail
    const size_t tg_mem = (size_t)in_dim * sizeof(float) +
                          (size_t)TS_SCT_THREADS * sizeof(float);
    if (g_ctx->max_shared_mem > 0 && (int)tg_mem > g_ctx->max_shared_mem) {
        return 2;
    }

    std::lock_guard<std::mutex> lk(g_dispatch_mutex);
    hipStream_t stream = g_ctx->stream;

    // stage inputs
    int8_t * tern_dev = nullptr;
    uint16_t * ps_dev = nullptr;
    int8_t * ls_dev = nullptr;
    int32_t * oidx_dev = nullptr;
    uint32_t * rs_dev = nullptr;
    float * ws_dev = nullptr;
    float * iscale_dev = nullptr;

    bool ok = true;
    ok = ok && hipMalloc((void **)&tern_dev, n * sizeof(int8_t)) == hipSuccess;
    ok = ok && hipMalloc((void **)&ps_dev, (size_t)out_dim * pages_per_row * sizeof(uint16_t)) == hipSuccess;
    ok = ok && hipMalloc((void **)&ls_dev, (size_t)out_dim * pages_per_row * TS_LANES_PER_PAGE * sizeof(int8_t)) == hipSuccess;
    ok = ok && hipMalloc((void **)&ws_dev, n * sizeof(float)) == hipSuccess;
    ok = ok && hipMalloc((void **)&iscale_dev, (size_t)in_dim * sizeof(float)) == hipSuccess;
    ok = ok && ensure_buf(g_ctx->recon, n * sizeof(float));
    ok = ok && ensure_buf(g_ctx->partials, (size_t)out_dim * sizeof(ts_dmr_partial));

    if (ok) ok = upload(ternary, tern_dev, n * sizeof(int8_t), stream);
    if (ok) ok = upload(page_scales, ps_dev, (size_t)out_dim * pages_per_row * sizeof(uint16_t), stream);
    if (ok) ok = upload(lane_scales, ls_dev, (size_t)out_dim * pages_per_row * TS_LANES_PER_PAGE * sizeof(int8_t), stream);
    if (ok) ok = upload(ws, ws_dev, n * sizeof(float), stream);
    if (ok) ok = upload(input_scale, iscale_dev, (size_t)in_dim * sizeof(float), stream);

    // outlier CSR (sorted by row; matches the Metal host logic).
    std::vector<uint32_t> row_starts((size_t)out_dim + 1, 0);
    if (ok && n_outliers > 0 && outlier_idx != nullptr) {
        ok = ok && hipMalloc((void **)&oidx_dev, (size_t)n_outliers * sizeof(int32_t)) == hipSuccess;
        if (ok) ok = upload(outlier_idx, oidx_dev, (size_t)n_outliers * sizeof(int32_t), stream);
        for (int64_t i = 0; i < n_outliers; i++) {
            int64_t row = outlier_idx[i] / in_dim;
            if (row >= 0 && row < out_dim) row_starts[(size_t)row + 1]++;
        }
    }
    if (ok) {
        for (int64_t r = 0; r < out_dim; r++) {
            row_starts[(size_t)r + 1] += row_starts[(size_t)r];
        }
        ok = hipMalloc((void **)&rs_dev, (size_t)(out_dim + 1) * sizeof(uint32_t)) == hipSuccess;
        if (ok) ok = upload(row_starts.data(), rs_dev, (size_t)(out_dim + 1) * sizeof(uint32_t), stream);
    }

    if (ok) {
        ts_dmr_args args;
        args.out_dim = (uint32_t)out_dim;
        args.in_dim  = (uint32_t)in_dim;
        args.n_outliers = (uint32_t)n_outliers;
        args._pad = 0;

        hipLaunchKernelGGL(ts_hip_dmr,
                           dim3((unsigned)out_dim), dim3(TS_SCT_THREADS), tg_mem, stream,
                           args,
                           (const int8_t *)tern_dev, (const uint16_t *)ps_dev,
                           (const int8_t *)ls_dev, (const int32_t *)oidx_dev,
                           (const uint32_t *)rs_dev, (const float *)ws_dev,
                           (const float *)iscale_dev, (float *)g_ctx->recon.ptr,
                           (ts_dmr_partial *)g_ctx->partials.ptr);
        ok = (hipGetLastError() == hipSuccess);
    }

    std::vector<ts_dmr_partial> part((size_t)out_dim);
    if (ok) {
        ok = (hipMemcpyAsync(part.data(), g_ctx->partials.ptr,
                             (size_t)out_dim * sizeof(ts_dmr_partial),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) {
        ok = (hipMemcpyAsync(recon_out, g_ctx->recon.ptr, n * sizeof(float),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    if (ok) {
        double total_mse = 0.0;
        double total_n   = 0.0;
        for (int64_t r = 0; r < out_dim; r++) {
            total_mse += (double)part[(size_t)r].mse_sum;
            total_n   += (double)part[(size_t)r].n_count;
        }
        *mse_out = (total_n > 0.0) ? (float)(total_mse / total_n) : 0.0f;
    }

    if (tern_dev   != nullptr) (void)hipFree(tern_dev);
    if (ps_dev     != nullptr) (void)hipFree(ps_dev);
    if (ls_dev     != nullptr) (void)hipFree(ls_dev);
    if (oidx_dev   != nullptr) (void)hipFree(oidx_dev);
    if (rs_dev     != nullptr) (void)hipFree(rs_dev);
    if (ws_dev     != nullptr) (void)hipFree(ws_dev);
    if (iscale_dev != nullptr) (void)hipFree(iscale_dev);
    return ok ? 0 : 1;
}

// -----------------------------------------------------------------------
// Kernel 3: AWQ grid search
// -----------------------------------------------------------------------

int ts_metal_awq_grid_search(ts_metal_weights_t * w,
                             const float * grid,
                             int64_t n_grid,
                             float * mse_out) {
    if (!ts_metal_available() || g_ctx == nullptr || w == nullptr ||
        w->act == nullptr || w->act2 == nullptr ||
        grid == nullptr || mse_out == nullptr || n_grid <= 0) {
        return 1;
    }
    if (w->in_dim > TS_DMR_MAX_ROW) return 2;

    const int64_t out_dim = w->out_dim;
    const int64_t in_dim  = w->in_dim;

    std::lock_guard<std::mutex> lk(g_dispatch_mutex);
    hipStream_t stream = g_ctx->stream;

    float * grid_dev = nullptr;
    bool ok = hipMalloc((void **)&grid_dev, (size_t)n_grid * sizeof(float)) == hipSuccess;
    if (ok) ok = upload(grid, grid_dev, (size_t)n_grid * sizeof(float), stream);
    ok = ok && ensure_buf(g_ctx->partials,
                          (size_t)(out_dim * n_grid) * sizeof(ts_awq_partial));
    // phase-1 partials are plain floats; reuse the same scratch (larger).
    float * abs_partials_dev = nullptr;
    if (ok) {
        ok = hipMalloc((void **)&abs_partials_dev,
                       (size_t)(out_dim * n_grid) * sizeof(float)) == hipSuccess;
    }
    if (!ok) {
        if (grid_dev != nullptr) (void)hipFree(grid_dev);
        return 1;
    }

    ts_awq_args args;
    args.out_dim = (uint32_t)out_dim;
    args.in_dim  = (uint32_t)in_dim;
    args.n_grid  = (uint32_t)n_grid;
    args._pad    = 0;

    dim3 grid_dim((unsigned)out_dim, (unsigned)n_grid);

    // ---- phase 1: per-(row, alpha) abs_sum partials ----
    hipLaunchKernelGGL(ts_hip_awq_threshold, grid_dim, dim3(TS_SCT_THREADS), 0, stream,
                       args, w->W, w->act, grid_dev, w->inv_median, abs_partials_dev);
    ok = (hipGetLastError() == hipSuccess);

    std::vector<float> abs_part((size_t)(out_dim * n_grid));
    if (ok) {
        ok = (hipMemcpyAsync(abs_part.data(), abs_partials_dev,
                             (size_t)(out_dim * n_grid) * sizeof(float),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    // host: reduce across rows -> per-alpha threshold = sum / (out_dim*in_dim)
    std::vector<float> threshold((size_t)n_grid, 0.0f);
    if (ok) {
        for (int64_t g = 0; g < n_grid; g++) {
            double s = 0.0;
            for (int64_t r = 0; r < out_dim; r++) {
                s += (double)abs_part[(size_t)(r * n_grid + g)];
            }
            threshold[(size_t)g] = (float)(s / (double)(out_dim * in_dim));
        }
        ok = ensure_buf(g_ctx->thresholds, (size_t)n_grid * sizeof(float));
        if (ok) ok = upload(threshold.data(), g_ctx->thresholds.ptr,
                            (size_t)n_grid * sizeof(float), stream);
    }

    // ---- phase 2: ternarize + dequant + err using the thresholds ----
    if (ok) {
        hipLaunchKernelGGL(ts_hip_awq_grid, grid_dim, dim3(TS_SCT_THREADS), 0, stream,
                           args, w->W, w->act, w->act2, grid_dev,
                           (const float *)g_ctx->thresholds.ptr, w->inv_median,
                           (ts_awq_partial *)g_ctx->partials.ptr);
        ok = (hipGetLastError() == hipSuccess);
    }

    std::vector<ts_awq_partial> part((size_t)(out_dim * n_grid));
    if (ok) {
        ok = (hipMemcpyAsync(part.data(), g_ctx->partials.ptr,
                             (size_t)(out_dim * n_grid) * sizeof(ts_awq_partial),
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    if (ok) {
        std::vector<double> sum_err((size_t)n_grid, 0.0);
        std::vector<double> sum_n((size_t)n_grid, 0.0);
        for (int64_t r = 0; r < out_dim; r++) {
            for (int64_t g = 0; g < n_grid; g++) {
                const ts_awq_partial & p = part[(size_t)(r * n_grid + g)];
                sum_err[(size_t)g] += (double)p.err_sum;
                sum_n[(size_t)g]   += (double)p.n_count;
            }
        }
        for (int64_t g = 0; g < n_grid; g++) {
            mse_out[g] = (sum_n[(size_t)g] > 0.0)
                         ? (float)(sum_err[(size_t)g] / sum_n[(size_t)g])
                         : 0.0f;
        }
    }

    (void)hipFree(grid_dev);
    (void)hipFree(abs_partials_dev);
    return ok ? 0 : 1;
}

// -----------------------------------------------------------------------
// Kernel: imatrix per-row sum-of-squares (host shim)
// -----------------------------------------------------------------------
// Drives ts_hip_imatrix_sumsq over a [rows, channels] activation block.
// Returns 1 when the shim is unavailable or the dispatch fails (caller
// falls back to the scalar loop in IMatrixCollector::collect_imatrix).
//
// values_host is the collector's m_stats[stats_key].values buffer. The
// shim H2D-copies the activation rows, runs one kernel, D2H-copies the
// row-totals into values_host + host_offset. The collector's m_mutex
// already serializes concurrent invocations, so the host shim does not
// add a separate lock.
int ts_metal_imatrix_sumsq(const float * x,
                           int64_t channels,
                           int64_t rows,
                           float * values_host,
                           int64_t host_offset) {
    if (!ts_metal_available() || g_ctx == nullptr || x == nullptr ||
        values_host == nullptr || channels <= 0 || rows <= 0) {
        return 1;
    }
    if ((uint64_t)channels > (uint64_t)2147483647u ||
        (uint64_t)rows > (uint64_t)65535u) {  // grid.x dim limit on this lane
        return 1;
    }

    hipStream_t stream = g_ctx->stream;

    const size_t row_bytes = (size_t)channels * sizeof(float);
    const size_t values_bytes = (size_t)channels * sizeof(float);

    float * x_dev = nullptr;
    float * values_dev = nullptr;
    bool ok = (hipMalloc((void **)&x_dev, (size_t)rows * row_bytes) == hipSuccess);
    if (ok) {
        ok = (hipMalloc((void **)&values_dev, values_bytes) == hipSuccess);
    }
    if (ok) {
        // Zero the device values buffer (the kernel uses atomicAdd, so the
        // destination must start at zero; the host side will overwrite via
        // the D2H copy below).
        ok = (hipMemsetAsync(values_dev, 0, values_bytes, stream) == hipSuccess);
    }
    if (ok) {
        ok = (hipMemcpyAsync(x_dev, x, (size_t)rows * row_bytes,
                             hipMemcpyHostToDevice, stream) == hipSuccess);
    }
    if (ok) {
        hipLaunchKernelGGL(ts_hip_imatrix_sumsq,
                           dim3((unsigned)rows),
                           dim3(TS_SCT_THREADS), 0, stream,
                           x_dev, values_dev,
                           (uint32_t)channels, 0u);
        ok = (hipGetLastError() == hipSuccess);
    }
    // D2H the row-totals into values_host + host_offset (one row of channels
    // floats - the kernel atomicAdded them all into the [0, channels)
    // slice, but the actual stats vector slot spans the full [mat_start,
    // mat_start + channels) range; the caller sets host_offset = mat_start
    // for dense or mat_id * channels for MoE).
    if (ok) {
        ok = (hipMemcpyAsync(values_host + host_offset, values_dev,
                             values_bytes, hipMemcpyDeviceToHost, stream)
              == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    if (x_dev != nullptr) (void)hipFree(x_dev);
    if (values_dev != nullptr) (void)hipFree(values_dev);
    return ok ? 0 : 1;
}

// -----------------------------------------------------------------------
// Kernel: F64 Frobenius ratio (host shim)
// -----------------------------------------------------------------------
// Drives ts_hip_l1_ratio. Returns -1.0 when the shim is unavailable, the
// dispatch fails, or the per-block partials cannot be folded (caller falls
// back to the scalar loop in ts_l1_kernel_direct_t2). The block count is
// small (n_blocks = ceil(n / 8192)), so a host-side fold is cheap and the
// extra H2D copy of approx/target is the only wide-bandwidth cost.
double ts_metal_l1_ratio(const float * approx, const float * target, int64_t n) {
    if (!ts_metal_available() || g_ctx == nullptr || approx == nullptr ||
        target == nullptr || n <= 0) {
        return -1.0;
    }
    if ((uint64_t)n > (uint64_t)2147483647u) {  // grid.x dim limit on this lane
        return -1.0;
    }

    const uint32_t n_uint   = (uint32_t)n;
    const uint32_t n_blocks = (n_uint + TS_L1_BLOCK_ELEMS - 1u) / TS_L1_BLOCK_ELEMS;

    std::lock_guard<std::mutex> lk(g_dispatch_mutex);
    hipStream_t stream = g_ctx->stream;

    const size_t n_bytes = (size_t)n * sizeof(float);
    const size_t part_bytes = (size_t)n_blocks * 2u * sizeof(double);

    float * approx_dev = nullptr;
    float * target_dev = nullptr;
    double * partials_dev = nullptr;
    bool ok = (hipMalloc((void **)&approx_dev, n_bytes) == hipSuccess);
    if (ok) ok = (hipMalloc((void **)&target_dev, n_bytes) == hipSuccess);
    if (ok) ok = (hipMalloc((void **)&partials_dev, part_bytes) == hipSuccess);
    if (ok) ok = (hipMemsetAsync(partials_dev, 0, part_bytes, stream) == hipSuccess);
    if (ok) ok = (hipMemcpyAsync(approx_dev, approx, n_bytes,
                                 hipMemcpyHostToDevice, stream) == hipSuccess);
    if (ok) ok = (hipMemcpyAsync(target_dev, target, n_bytes,
                                 hipMemcpyHostToDevice, stream) == hipSuccess);
    if (ok) {
        hipLaunchKernelGGL(ts_hip_l1_ratio,
                           dim3(n_blocks), dim3(TS_L1_BLOCK_THREADS), 0, stream,
                           approx_dev, target_dev, partials_dev, n_uint, n_blocks);
        ok = (hipGetLastError() == hipSuccess);
    }

    std::vector<double> part((size_t)n_blocks * 2u);
    if (ok) {
        ok = (hipMemcpyAsync(part.data(), partials_dev, part_bytes,
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    double sum_num = 0.0;
    double sum_den = 0.0;
    if (ok) {
        for (uint32_t b = 0; b < n_blocks; b++) {
            sum_num += part[(size_t)b * 2u];
            sum_den += part[(size_t)b * 2u + 1u];
        }
    }

    if (approx_dev   != nullptr) (void)hipFree(approx_dev);
    if (target_dev   != nullptr) (void)hipFree(target_dev);
    if (partials_dev != nullptr) (void)hipFree(partials_dev);

    if (!ok || sum_den == 0.0) return -1.0;
    return sum_num / sum_den;
}

// -----------------------------------------------------------------------
// Kernel: make_qx_quants 19-trial scale sweep (host shim)
// -----------------------------------------------------------------------
// Drives ts_hip_make_qx_quants over the source vector x. The host pre-computes
// inv_l2 = 1 / (sqrt(sum(x^2))), mirrors the canonical upstream make_qx_quants
// (ggml/src/ggml-quants.c:1435-1502). The kernel runs one block per 8192
// elements; the host folds the per-block partials along the n_blocks axis
// into the 19 quant_max outputs. The kernel keeps suml vs sumlx separate
// (different magnitudes) so the integer-count information is preserved
// exactly; the host does the final suml + sumlx/n fold.
//
// Returns 0 on success, 1 when the shim is unavailable or the dispatch
// fails (caller falls back to the scalar 19-trial loop in make_qx_quants).
int ts_metal_make_qx_quants(const float * x, int64_t n, float * quant_max) {
    if (!ts_metal_available() || g_ctx == nullptr || x == nullptr ||
        quant_max == nullptr || n <= 0) {
        return 1;
    }
    if ((uint64_t)n > (uint64_t)2147483647u) {  // grid.x dim limit on this lane
        return 1;
    }

    const uint32_t n_uint   = (uint32_t)n;
    const uint32_t n_blocks = (n_uint + TS_QX_BLOCK_ELEMS - 1u) / TS_QX_BLOCK_ELEMS;

    const size_t n_bytes = (size_t)n * sizeof(float);
    const size_t part_bytes = (size_t)TS_QX_TRIALS * (size_t)n_blocks * sizeof(float);

    double l2_sq = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const double v = (double)x[i];
        l2_sq += v * v;
    }
    if (l2_sq <= 0.0) {
        for (int t = 0; t < TS_QX_TRIALS; ++t) quant_max[t] = 0.0f;
        return 0;
    }
    const float inv_l2 = (float)(1.0 / sqrt(l2_sq));

    std::lock_guard<std::mutex> lk(g_dispatch_mutex);
    hipStream_t stream = g_ctx->stream;

    float * x_dev = nullptr;
    bool ok = (hipMalloc((void **)&x_dev, n_bytes) == hipSuccess);
    if (ok) ok = ensure_buf(g_ctx->qx_partials_l,  part_bytes);
    if (ok) ok = ensure_buf(g_ctx->qx_partials_lx, part_bytes);
    if (ok) ok = (hipMemsetAsync(g_ctx->qx_partials_l.ptr,  0, part_bytes, stream) == hipSuccess);
    if (ok) ok = (hipMemsetAsync(g_ctx->qx_partials_lx.ptr, 0, part_bytes, stream) == hipSuccess);
    if (ok) ok = (hipMemcpyAsync(x_dev, x, n_bytes,
                                 hipMemcpyHostToDevice, stream) == hipSuccess);
    if (ok) {
        hipLaunchKernelGGL(ts_hip_make_qx_quants,
                           dim3(n_blocks), dim3(TS_SCT_THREADS), 0, stream,
                           x_dev,
                           (float *)g_ctx->qx_partials_l.ptr,
                           (float *)g_ctx->qx_partials_lx.ptr,
                           n_uint, n_blocks, inv_l2);
        ok = (hipGetLastError() == hipSuccess);
    }

    std::vector<float> part_l ((size_t)TS_QX_TRIALS * (size_t)n_blocks);
    std::vector<float> part_lx((size_t)TS_QX_TRIALS * (size_t)n_blocks);
    if (ok) {
        ok = (hipMemcpyAsync(part_l.data(), g_ctx->qx_partials_l.ptr, part_bytes,
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) {
        ok = (hipMemcpyAsync(part_lx.data(), g_ctx->qx_partials_lx.ptr, part_bytes,
                             hipMemcpyDeviceToHost, stream) == hipSuccess);
    }
    if (ok) ok = (hipStreamSynchronize(stream) == hipSuccess);

    if (ok) {
        // Fold per-block partials along n_blocks; quant_max[t] = suml + sumlx/n.
        // Accumulate in double to match the CPU scalar reference's precision.
        std::vector<double> suml ((size_t)TS_QX_TRIALS, 0.0);
        std::vector<double> sumlx((size_t)TS_QX_TRIALS, 0.0);
        for (uint32_t b = 0; b < n_blocks; b++) {
            for (int t = 0; t < TS_QX_TRIALS; ++t) {
                suml [(size_t)t] += (double)part_l [(size_t)t * (size_t)n_blocks + (size_t)b];
                sumlx[(size_t)t] += (double)part_lx[(size_t)t * (size_t)n_blocks + (size_t)b];
            }
        }
        const float inv_n = 1.0f / (float)n;
        for (int t = 0; t < TS_QX_TRIALS; ++t) {
            quant_max[t] = (float)suml[(size_t)t] + (float)sumlx[(size_t)t] * inv_n;
        }
    }

    if (x_dev != nullptr) (void)hipFree(x_dev);
    return ok ? 0 : 1;
}

}  // extern "C"
