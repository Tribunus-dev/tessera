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
// Thread-safety: the handle is process-global and lazily created on first
// call to ts_rocblas_handle(). All callers serialize through the same
// handle; rocBLAS itself is thread-safe at the handle level when bound to
// independent streams, and the L1-L6 dispatch loops are single-threaded per
// candidate, so a single shared handle is sufficient.
//

#pragma once

#include <rocblas.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns the process-global rocBLAS handle, lazily creating it on first
// call. Returns nullptr only when rocblas_create_handle failed (which would
// indicate a broken ROCm install); in that case every caller falls back to
// the scalar path, matching the pre-rocBLAS behaviour.
rocblas_handle ts_rocblas_handle();

#ifdef __cplusplus
}
#endif
