// Intel MKL / OpenBLAS cblas_sgemm bridge for per-chunk calibration
// (parallel lane to apple_accelerate_matmul.cpp).
//
// On Linux the dispatch in calibration_metal.py falls back to numpy.
// This file provides a small C bridge that routes the same (M,K)x(K,N)
// F32 matmul through the system's BLAS. When linked against Intel MKL
// (oneMKL) it dispatches to AMX/AVX-512/AVX-VNNI; when linked against
// OpenBLAS it dispatches to the OpenBLAS kernels. No Apple code is
// touched; this is the Intel parallel lane.
//
// Exposes tessera_mkl_sgemm_f32 so the Python ctypes wrapper in
// calibration_metal.py can call it without a C++ ABI.

#if defined(__has_include)
#  if __has_include(<mkl_cblas.h>)
#    include <mkl_cblas.h>
#  elif __has_include(<mkl/cblas.h>)
#    include <mkl/cblas.h>
#  elif __has_include(<cblas.h>)
#    include <cblas.h>
#  elif __has_include(<openblas/cblas.h>)
#    include <openblas/cblas.h>
#  else
#    include <cblas.h>
#  endif
#else
#  include <cblas.h>
#endif

#include <cstddef>
#include <cstdint>

extern "C" int tessera_mkl_sgemm_f32(
        const float * a,
        const float * b,
        float * c,
        std::size_t m,
        std::size_t n,
        std::size_t k,
        int transpose_a,
        int transpose_b) {
    if (!a || !b || !c || m == 0 || n == 0 || k == 0) {
        return -1;
    }
    const CBLAS_ORDER layout = CblasRowMajor;
    const CBLAS_TRANSPOSE op_a = transpose_a ? CblasTrans : CblasNoTrans;
    const CBLAS_TRANSPOSE op_b = transpose_b ? CblasTrans : CblasNoTrans;
    int lda = static_cast<int>(transpose_a ? m : k);
    int ldb = static_cast<int>(transpose_b ? k : n);
    int ldc = static_cast<int>(n);
    cblas_sgemm(
        layout,
        op_a,
        op_b,
        static_cast<int>(m),
        static_cast<int>(n),
        static_cast<int>(k),
        1.0f,
        a, lda,
        b, ldb,
        0.0f,
        c, ldc);
    return 0;
}
