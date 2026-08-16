//
// tessera-rocblas.cpp
//
// Owns the rocBLAS handle lifetime (lazy create on first use, destroy on
// process exit), the shim's own HIP stream (independent of the Metal/HIP lane
// in tessera-metal-hip.cpp), and a small grow-only slot pool for caller-
// managed device scratch. Every rocBLAS dispatch is staged: the caller grabs
// a ts_rblas_buf, hipMemcpyAsync's its inputs to device on ts_rblas_stream,
// invokes the BLAS op, hipMemcpyAsync's the output back, then releases.
//
// The slot pool is per-role (TS_RBLAS_IN_F32, ..., TS_RBLAS_SCALAR_F64). One
// slot per role; allocations grow monotonically across the process lifetime
// (no shrink) so the L6 GA hot loop reuses the same device memory across
// every candidate without re-allocation. The pool mutex is the only
// synchronization.
//
// Compiled as a LANGUAGE HIP OBJECT library by tools/quantize/CMakeLists.txt
// (mirrors the tessera-metal-hip.cpp split). The OBJECT lib links hip::device
// private; the parent ${TARGET} links hip::host private for symbol resolution.
//

#include "tessera-rocblas.h"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>

namespace {

struct ts_rblas_slot {
    void *  dev     = nullptr;
    size_t  bytes   = 0;
    bool    in_use  = false;
};

std::mutex        g_pool_mutex;
ts_rblas_slot     g_pool[6] = {};

std::mutex        g_init_mutex;
rocblas_handle    g_handle       = nullptr;
hipStream_t       g_rblas_stream = nullptr;
std::atomic<int>  g_initialized{0};
std::atomic<bool> g_init_failed{false};

// Runtime kill switch (TS_RBLAS_DISABLE=1) + per-role observability
// (TS_RBLAS_STATS=1 dumps this at exit - see ts_rocblas_shutdown). The pool
// is grow-only, so g_pool[i].bytes already is the high-water mark per role.
std::atomic<bool>     g_disabled_checked{false};
std::atomic<bool>     g_disabled{false};
std::atomic<bool>     g_alloc_fail_logged{false};
std::atomic<uint64_t> g_dispatch_count[6] = {};
std::atomic<uint64_t> g_fallback_count[6] = {};
std::atomic<uint64_t> g_dispatch_thread{0};  // debug-only single-thread guard, W1-D2

bool ts_rblas_disabled() {
    if (!g_disabled_checked.exchange(true, std::memory_order_acq_rel)) {
        bool v = std::getenv("TS_RBLAS_DISABLE") != nullptr;
        g_disabled.store(v, std::memory_order_release);
        if (v) {
            std::fprintf(stderr, "ts_rblas: TS_RBLAS_DISABLE=1 - rocBLAS lane disabled, "
                                  "CPU fallback for the process\n");
        }
    }
    return g_disabled.load(std::memory_order_acquire);
}

} // anonymous namespace

hipStream_t ts_rblas_stream() {
    // Stream is created lazily alongside the handle (see ts_rocblas_handle()).
    // Before init, callers get nullptr and should defer any H2D/D2H to handle
    // creation; in practice the handle init happens on first ts_rblas_buf_get,
    // which is the first operation any caller performs.
    return g_rblas_stream;
}

rocblas_handle ts_rocblas_handle() {
    if (ts_rblas_disabled() || g_init_failed.load(std::memory_order_acquire)) {
        return nullptr;
    }
    if (g_initialized.load(std::memory_order_acquire)) {
        return g_handle;
    }
    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (g_initialized.load(std::memory_order_relaxed)) {
        return g_handle;
    }

    // Create the shim's own HIP stream first so rocBLAS can bind to it.
    hipError_t serr = hipStreamCreateWithFlags(&g_rblas_stream, hipStreamNonBlocking);
    if (serr != hipSuccess || g_rblas_stream == nullptr) {
        std::fprintf(stderr, "ts_rocblas_handle: hipStreamCreateWithFlags failed (%d) - "
                              "permanent CPU fallback for this process\n", (int) serr);
        g_rblas_stream = nullptr;
        g_init_failed.store(true, std::memory_order_release);
        return nullptr;
    }

    rocblas_handle h = nullptr;
    rocblas_status status = rocblas_create_handle(&h);
    if (status != rocblas_status_success || h == nullptr) {
        std::fprintf(stderr, "ts_rocblas_handle: rocblas_create_handle failed (%d) - "
                              "permanent CPU fallback for this process\n", (int) status);
        // leave g_rblas_stream alive for ts_rblas_stream() callers; the pool
        // is empty so nothing will try to dispatch.
        g_init_failed.store(true, std::memory_order_release);
        return nullptr;
    }
    rocblas_set_stream(h, g_rblas_stream);

    g_handle = h;
    g_initialized.store(1, std::memory_order_release);
    return g_handle;
}

ts_rblas_buf ts_rblas_buf_get(int role, size_t bytes) {
    if (role < 0 || role >= 6 || bytes == 0) {
        return {nullptr, 0};
    }
#ifndef NDEBUG
    // W1-D2: the L1-L6 dispatch loops are single-threaded per candidate, so
    // one process-global pool is sufficient. Catch a second dispatching
    // thread here rather than silently racing the pool.
    {
        uint64_t tid = std::hash<std::thread::id>{}(std::this_thread::get_id());
        uint64_t expected = 0;
        if (!g_dispatch_thread.compare_exchange_strong(expected, tid, std::memory_order_acq_rel)) {
            assert(expected == tid &&
                   "ts_rblas_buf_get called from a second thread - pool is process-global (W1-D2)");
        }
    }
#endif
    if (ts_rocblas_handle() == nullptr) {
        // No usable handle - leave the slot alone, return the failure sentinel.
        g_fallback_count[role].fetch_add(1, std::memory_order_relaxed);
        return {nullptr, 0};
    }

    std::lock_guard<std::mutex> lock(g_pool_mutex);
    ts_rblas_slot & slot = g_pool[role];
    if (slot.dev != nullptr && slot.bytes >= bytes && !slot.in_use) {
        slot.in_use = true;
        g_dispatch_count[role].fetch_add(1, std::memory_order_relaxed);
        return {slot.dev, slot.bytes};
    }
    // Grow (or initial alloc). Free the old buffer if it was too small.
    if (slot.dev != nullptr) {
        (void)hipFree(slot.dev);
        slot.dev = nullptr;
        slot.bytes = 0;
    }
    void * dev = nullptr;
    hipError_t err = hipMalloc(&dev, bytes);
    if (err != hipSuccess || dev == nullptr) {
        if (!g_alloc_fail_logged.exchange(true, std::memory_order_acq_rel)) {
            std::fprintf(stderr, "ts_rblas_buf_get: hipMalloc(%zu) failed (%d)\n",
                         bytes, (int) err);
        }
        slot.dev = nullptr;
        slot.bytes = 0;
        g_fallback_count[role].fetch_add(1, std::memory_order_relaxed);
        return {nullptr, 0};
    }
    slot.dev = dev;
    slot.bytes = bytes;
    slot.in_use = true;
    g_dispatch_count[role].fetch_add(1, std::memory_order_relaxed);
    return {slot.dev, slot.bytes};
}

void ts_rblas_buf_release(ts_rblas_buf b) {
    if (b.dev == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_pool_mutex);
    for (int i = 0; i < 6; i++) {
        if (g_pool[i].dev == b.dev) {
            g_pool[i].in_use = false;
            return;
        }
    }
    // Slot not found - shouldn't happen if the buffer came from this shim,
    // but be defensive: free the device memory rather than leak.
    (void)hipFree(b.dev);
}

namespace {

__attribute__((destructor))
static void ts_rocblas_shutdown() {
    if (std::getenv("TS_RBLAS_STATS") != nullptr) {
        std::fprintf(stderr, "ts_rblas: per-role stats (dispatch / fallback / high-water bytes)\n");
        for (int i = 0; i < 6; i++) {
            std::fprintf(stderr, "  role %d: %llu / %llu / %zu\n", i,
                         (unsigned long long) g_dispatch_count[i].load(std::memory_order_relaxed),
                         (unsigned long long) g_fallback_count[i].load(std::memory_order_relaxed),
                         g_pool[i].bytes);
        }
    }
    if (g_handle != nullptr) {
        rocblas_destroy_handle(g_handle);
        g_handle = nullptr;
    }
    std::lock_guard<std::mutex> lock(g_pool_mutex);
    for (int i = 0; i < 6; i++) {
        if (g_pool[i].dev != nullptr) {
            (void)hipFree(g_pool[i].dev);
            g_pool[i].dev = nullptr;
            g_pool[i].bytes = 0;
            g_pool[i].in_use = false;
        }
    }
    if (g_rblas_stream != nullptr) {
        (void)hipStreamDestroy(g_rblas_stream);
        g_rblas_stream = nullptr;
    }
    g_initialized.store(0, std::memory_order_release);
}

} // anonymous namespace
