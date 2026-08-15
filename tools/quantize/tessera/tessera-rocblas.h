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
enum {
    TS_RBLAS_IN_F32     = 0,  // input scratch, f32 array
    TS_RBLAS_IN_F64     = 1,  // input scratch, f64 array
    TS_RBLAS_OUT_F32    = 2,  // output scratch, f32 array
    TS_RBLAS_OUT_F64    = 3,  // output scratch, f64 array
    TS_RBLAS_SCALAR_F32 = 4,  // single f32 (sdot result)
    TS_RBLAS_SCALAR_F64 = 5,  // single f64
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

#ifdef __cplusplus
}
#endif
