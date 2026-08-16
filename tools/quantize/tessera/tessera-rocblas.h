//
// tessera-rocblas.h
//
// Third BLAS dispatch lane for the Tessera calibration/quantization pipeline
// (tools/quantize/tessera/). Mirrors the cblas / TS_HAS_CBLAS surface but
// routes through rocBLAS on AMD systems where find_package(rocblas) resolved.
// Selected when the CMake build sets TS_USE_ROCBLAS (see
// tools/quantize/CMakeLists.txt for the gate). The cblas path
// (Accelerate on Apple, OpenBLAS/flexiblas on Linux) is untouched.
//
// Thread-safety: the handle and the slot pool are process-global; all callers
// serialize through the same pool mutex. The L1-L6 dispatch loops are
// single-threaded per candidate, so a single shared handle is sufficient.
//
// Runtime controls (read once, lazily, at first use): TS_RBLAS_DISABLE=1
// forces every ts_rblas_buf_get to the failure sentinel (permanent CPU
// fallback for the process). TS_RBLAS_STATS=1 dumps per-role dispatch /
// fallback / high-water-bytes counters to stderr at process exit.
//
// Hosting notes: rocBLAS sgemm / dgemm expect device-pointer inputs that the
// GPU can dereference. On APUs without XNACK on the ISA (gfx1103 in the Ryzen
// 7040 series, gfx1100/1101/1102, all RDNA-2/3/4 consumer parts) the device
// cannot fault-in a host page, so every input is staged through
// ts_rblas_buf_get + hipMemcpyAsync on the shim's own HIP stream and every
// output is D2H-copied back. This works uniformly on XNACK-on and XNACK-off
// GPUs; the staging cost is identical in both cases.
//

#pragma once

#include <rocblas.h>
#include <hip/hip_runtime.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Persistent device scratch slot returned by ts_rblas_buf_get. dev is nullptr
// when the shim could not allocate (caller falls back). bytes is the current
// allocation size; callers that pass a smaller bytes to get() reuse the
// existing device memory without re-allocation.
typedef struct {
    void *  dev;
    size_t  bytes;
} ts_rblas_buf;

// Buffer roles: input vs output, scalar (single-value) vs array. The pool has
// one slot per role; callers reuse the slot across calls in a hot loop.
//
// A GEMM needs two input operands alive at once, so IN_F32/IN_F64 are split
// into _A/_B - requesting the same role twice while the first is still
// in_use frees it out from under the caller (the pool's "grow" path
// unconditionally hipFrees the existing slot). The AWQ GA eval cache
// (tessera-awq-fitness.cpp) needs five f32 buffers alive simultaneously for
// its lifetime (weights + train/heldout activations + train/heldout
// reference output), so it gets five dedicated roles rather than reusing
// IN_F32_A/_B, which would hit the exact same collision one level up.
enum {
    TS_RBLAS_IN_F32_A          = 0,  // input scratch, f32 array, operand A
    TS_RBLAS_IN_F32_B          = 1,  // input scratch, f32 array, operand B
    TS_RBLAS_IN_F64_A          = 2,  // input scratch, f64 array, operand A
    TS_RBLAS_IN_F64_B          = 3,  // input scratch, f64 array, operand B
    TS_RBLAS_OUT_F32           = 4,  // output scratch, f32 array
    TS_RBLAS_OUT_F64           = 5,  // output scratch, f64 array
    TS_RBLAS_SCALAR_F32        = 6,  // single f32 (sdot result)
    TS_RBLAS_SCALAR_F64        = 7,  // single f64
    TS_RBLAS_CACHE_WEIGHTS     = 8,  // AWQ GA eval cache: layer weights
    TS_RBLAS_CACHE_TRAIN_ACT   = 9,  // AWQ GA eval cache: train activations
    TS_RBLAS_CACHE_HELDOUT_ACT = 10, // AWQ GA eval cache: heldout activations
    TS_RBLAS_CACHE_REF_TRAIN   = 11, // AWQ GA eval cache: train reference output
    TS_RBLAS_CACHE_REF_HELDOUT = 12, // AWQ GA eval cache: heldout reference output
    TS_RBLAS_CACHE_BF16_WEIGHTS = 13, // AWQ GA eval cache: bf16 weights (W2 move 3)
    TS_RBLAS_BF16_A            = 14, // per-call bf16-cast scratch, operand A (ts_rblas_sgemm_bf16acc)
    TS_RBLAS_BF16_B            = 15, // per-call bf16-cast scratch, operand B (ts_rblas_sgemm_bf16acc)
    TS_RBLAS_ROLE_COUNT        = 16,
};

// Returns the process-global rocBLAS handle, lazily creating it (along with
// the shim's own HIP stream and scratch pool) on first call. Returns nullptr
// when rocblas_create_handle failed.
rocblas_handle ts_rocblas_handle();

// Acquires a device scratch buffer from the shim's pool. If a previously
// allocated buffer with the same role is at least `bytes` large and not
// currently in use, returns that buffer; otherwise allocates a fresh hipMalloc.
// Returns a sentinel {nullptr, 0} on allocation failure (caller falls back).
ts_rblas_buf ts_rblas_buf_get(int role, size_t bytes);

// Returns a scratch buffer to the pool. The device memory stays allocated for
// the next caller; only the slot's in-use flag clears.
void ts_rblas_buf_release(ts_rblas_buf b);

// The shim's own HIP stream. Callers use this for hipMemcpyAsync and for
// hipStreamSynchronize when they need to fence a rocBLAS dispatch.
hipStream_t ts_rblas_stream();

// ---------------------------------------------------------------------------
// W2: native-precision GEMM helpers (master plan D1 - one uniform
// mixed-precision policy: bf16 compute, f32 accumulate, for all eligible
// GEMM sites). Runtime kill switch TS_RBLAS_BF16=0 (read once, lazily)
// forces every one of these to the plain f32 rocBLAS path instead of
// rocblas_gemm_ex. Each helper also falls back to plain f32 rocBLAS on any
// gemm_ex failure (rule 0.8: API error -> log with status, fall back THIS
// call, counter++), and skips promotion entirely below the WMMA minimum
// tile (M,N,K < 16 - OQ-2), which is a silent, documented, non-error
// fallback per rule 0.8's "unsupported shape" class.
// ---------------------------------------------------------------------------

// Casts BOTH A and B host f32 arrays to real bf16 storage (rocblas_bfloat16
// truncation, matching the eval cache's own conversion technique) and
// dispatches rocblas_gemm_ex with a_type=b_type=bf16_r, c_type=d_type=
// f32_r, compute_type=f32_r (f32 accumulate - D1 W2: mandatory). This is
// the ONLY gemm_ex dtype combination confirmed to have an implemented
// Tensile kernel on this gfx1103 + ROCm 7.1.1 host: promoting compute_type
// alone over f32-typed storage (the master plan's original D1/D3
// assumption - inputs stay f32, only the internal compute dtype changes)
// and mixing one bf16 operand with one f32 operand both return
// rocblas_status_not_implemented empirically (gap-ledger
// CORRECTION-w2-2). Falls back to plain f32 rocblas_sgemm - re-staging the
// caller's ORIGINAL f32 data, not the bf16-truncated copy - on any
// gemm_ex failure, exactly like the other two helpers. Takes host
// pointers (not a device-pointer drop-in, unlike the design this
// replaced) since it owns its own bf16 casting; a_elems/b_elems/c_elems
// are exact host element counts (see ts_rblas_dgemm_to_sgemm for why
// these are explicit rather than derived from lda/transpose). 9 call
// sites: flrq, mm-awq, linalg (x2), champq (x2), vec (x2).
rocblas_status ts_rblas_sgemm_bf16acc(rocblas_operation transA, rocblas_operation transB,
                                       int m, int n, int k,
                                       const float * alpha,
                                       const float * A, int lda, size_t a_elems,
                                       const float * B, int ldb, size_t b_elems,
                                       const float * beta,
                                       float * C, int ldc, size_t c_elems);

// Replaces DARTQuant's f64 dgemm staging (OQ-A: sgemm cast is the default
// attempt) - deliberately "gemm_ex-free": takes the caller's ORIGINAL host
// f32 pointers directly (skipping the f64 promotion those call sites used
// to do before staging), stages via the pool, dispatches plain
// rocblas_sgemm (no bf16-compute promotion layered on top - this helper's
// whole point is proving the cast-down staging path in isolation, so it is
// unaffected by TS_RBLAS_BF16), D2H's the f32 result to the caller's host
// buffer. beta=0 fixed (every call site already uses that); alpha is a
// caller-supplied scalar (not always 1.0 - one DARTQuant site scales by
// 1/X_count). a_elems/b_elems/c_elems are exact host-buffer element counts
// the caller already knows, taken explicitly rather than derived from
// lda/ldb/ldc + transpose flags: one call site passes a genuine BLAS
// submatrix view (A = W + col_off with lda = in_dim, a column-strided
// slice of a larger row-major buffer, not a contiguous block), where a
// derived-from-lda size would read past the source buffer. Bit-identity
// with the f64 path is not achievable in principle (criterion 12);
// DARTQuant's ~1e-3 rel-L2 error budget is the parity target, and the
// caller casts the f32 result up to double afterward for its own
// downstream double-precision math, matching current behavior.
rocblas_status ts_rblas_dgemm_to_sgemm(rocblas_operation transA, rocblas_operation transB,
                                        int m, int n, int k,
                                        float alpha,
                                        const float * A, int lda, size_t a_elems,
                                        const float * B, int ldb, size_t b_elems,
                                        float * C, int ldc, size_t c_elems);

// AWQ fitness-matmul promotion, move 3 (bf16-direct cached weights - master
// plan W2-D2's preferred move, attempted first per the plan's own
// ordering). Genuinely mixed dtypes: A_bf16 is the GA eval cache's
// device-resident bf16 copy of the layer weights (rocblas_bfloat16*,
// requested via TS_RBLAS_CACHE_BF16_WEIGHTS - halves the H2D bytes and
// device footprint for the weights buffer, which is hoisted once per
// worker thread and reused across every GA candidate); B is the
// (unchanged f32) activations; A_f32 is the cache's existing f32 weights
// copy, used as the fallback operand if A_bf16 is null, TS_RBLAS_BF16=0,
// the shape is below the WMMA minimum tile, or rocblas_gemm_ex rejects
// the bf16-A/f32-B combination (OQ-1: unverified on this ROCm version -
// the fallback makes that failure mode safe and silent, not a crash).
// Device pointers throughout (drop-in for the existing
// ts_fitness_matmul_at_dev rocblas_sgemm call). 2 call sites:
// ts_fitness_matmul_at_dev's two operand pairs (awq-fitness.cpp).
// Checks whether the process's HIP device is in a faulted state (e.g. the
// "HW Exception ... GPU Hang" class of fault this host is known to hit -
// see tessera-quant.cpp callers' own comments). Unlike every other function
// in this header, this does NOT require ts_rocblas_handle()/TS_RBLAS_DISABLE
// to have been consulted first: it inspects the ONE process-wide HIP
// runtime state directly, so it also observes faults that originated
// outside this shim entirely (e.g. ggml's dynamically-loaded HIP backend,
// or the initial device-enumeration probe at process startup - both share
// the same underlying libamdhip64 runtime as this shim's own calls).
// `where` is a short label for the diagnostic message (e.g. the CLI
// subcommand name). Returns 0 if healthy, non-zero if a fault was detected
// (in which case a message was already printed to stderr) - callers whose
// success path silently ignored a mid-run HW fault (the "export-ternary
// exits 0 with truncated output" bug class) should call this before
// reporting success and propagate a non-zero process exit if it fails.
int ts_rblas_check_device_health(const char * where);

rocblas_status ts_rblas_gemm_bf16_mixed(rocblas_handle handle,
                                         rocblas_operation transA, rocblas_operation transB,
                                         int m, int n, int k,
                                         const float * alpha,
                                         const rocblas_bfloat16 * A_bf16,
                                         const float * A_f32,
                                         int lda,
                                         const float * B, int ldb,
                                         const float * beta,
                                         float * C, int ldc);

#ifdef __cplusplus
}
#endif
