//
// tessera-rocblas.cpp
//
// Owns the rocBLAS handle lifecycle (lazy create on first use, destroy on
// process exit). Streams are bound to the HIP stream owned by
// tessera-metal-hip.cpp's ts_metal_context when that lane is active, so
// rocBLAS dispatches into the same queue as the kernel-direct GA work;
// otherwise we use HIP's default stream.
//
// Compiled as a LANGUAGE HIP OBJECT library by tools/quantize/CMakeLists.txt
// (mirrors the tessera-metal-hip.cpp split). The OBJECT lib links hip::device
// private; the parent ${TARGET} links hip::host private for symbol resolution.
//

#include "tessera-rocblas.h"

#include <hip/hip_runtime.h>

#include <atomic>
#include <cstdio>
#include <mutex>

namespace {

std::mutex g_init_mutex;
rocblas_handle g_handle = nullptr;
std::atomic<int> g_initialized{0};

// Forward-declare the Metal/HIP context's stream accessor. The definition
// lives in tessera-metal-hip.cpp; when the HIP lane is absent the symbol
// resolves to nullptr and we fall back to the HIP default stream.
extern "C" hipStream_t ts_metal_hip_stream();

} // anonymous namespace

rocblas_handle ts_rocblas_handle() {
    if (g_initialized.load(std::memory_order_acquire)) {
        return g_handle;
    }
    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (g_initialized.load(std::memory_order_relaxed)) {
        return g_handle;
    }
    rocblas_handle h = nullptr;
    rocblas_status status = rocblas_create_handle(&h);
    if (status != rocblas_status_success || h == nullptr) {
        std::fprintf(stderr, "ts_rocblas_handle: rocblas_create_handle failed (%d)\n",
                     (int) status);
        return nullptr;
    }
    hipStream_t stream = ts_metal_hip_stream();
    if (stream != nullptr) {
        rocblas_set_stream(h, stream);
    }
    g_handle = h;
    g_initialized.store(1, std::memory_order_release);
    return g_handle;
}

namespace {

__attribute__((destructor))
static void ts_rocblas_shutdown() {
    if (g_handle != nullptr) {
        rocblas_destroy_handle(g_handle);
        g_handle = nullptr;
        g_initialized.store(0, std::memory_order_release);
    }
}

} // anonymous namespace
