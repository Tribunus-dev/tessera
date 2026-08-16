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
// The slot pool is per-role (TS_RBLAS_IN_F32_A, ..., TS_RBLAS_CACHE_REF_HELDOUT
// - see the enum in tessera-rocblas.h for why simultaneously-live buffers of
// the same conceptual type each get their own role). One slot per role;
// allocations grow monotonically across the process lifetime
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
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace {

struct ts_rblas_slot {
    void *  dev     = nullptr;
    size_t  bytes   = 0;
    bool    in_use  = false;
};

// Recursive: ts_rblas_buf_get is called multiple times in a row from the
// same thread before any ts_rblas_buf_release (staging A/B/C operands for
// one GEMM, e.g. ts_rblas_sgemm_bf16acc below) - a plain std::mutex would
// deadlock on the second call now that the lock is held across the whole
// checkout (see ts_rblas_buf_get's own comment).
std::recursive_mutex g_pool_mutex;
ts_rblas_slot     g_pool[TS_RBLAS_ROLE_COUNT] = {};

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
std::atomic<uint64_t> g_dispatch_count[TS_RBLAS_ROLE_COUNT] = {};
std::atomic<uint64_t> g_fallback_count[TS_RBLAS_ROLE_COUNT] = {};

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

// W2 kill switch (rule 0.2): TS_RBLAS_BF16=0 forces every bf16-promotion
// helper to its plain f32 rocBLAS path. Independent of TS_RBLAS_DISABLE
// (which kills the whole shim); this only kills the bf16 promotion.
std::atomic<bool> g_bf16_checked{false};
std::atomic<bool> g_bf16_enabled{true};
std::atomic<bool> g_gemm_ex_fail_logged{false};
std::atomic<bool> g_sync_fail_logged{false};

bool ts_rblas_bf16_enabled() {
    if (!g_bf16_checked.exchange(true, std::memory_order_acq_rel)) {
        const char * v = std::getenv("TS_RBLAS_BF16");
        bool enabled = !(v != nullptr && std::strcmp(v, "0") == 0);
        g_bf16_enabled.store(enabled, std::memory_order_release);
        if (!enabled) {
            std::fprintf(stderr, "ts_rblas: TS_RBLAS_BF16=0 - bf16-compute promotion "
                                  "disabled, plain f32 rocBLAS for the process\n");
        }
    }
    return g_bf16_enabled.load(std::memory_order_acquire);
}

// One-shot log for any rocblas_gemm_ex failure (rule 0.8: API error -> log
// with status, fall back THIS call, counter++ - the counter side is the
// caller's per-role fallback count via ts_rblas_buf_get; this is just the
// diagnostic line, capped to one occurrence like the other shim logs).
void ts_rblas_log_gemm_ex_fail_once(const char * who, rocblas_status st) {
    if (!g_gemm_ex_fail_logged.exchange(true, std::memory_order_acq_rel)) {
        std::fprintf(stderr, "%s: rocblas_gemm_ex failed (%d) - falling back to "
                              "plain f32 rocBLAS\n", who, (int) st);
    }
}

// rocblas_gemm_ex/rocblas_sgemm returning rocblas_status_success only means
// the async kernel launched validly onto the shim's own stream - a fault
// during execution (illegal device address, GPU hang/reset, etc.) surfaces
// at the NEXT synchronization point, not at dispatch. Every GEMM helper in
// this file that stages its own H2D/D2H copies must check this, or a
// mid-kernel fault is invisible: the caller's D2H copy reads a stale/
// partial device buffer and the helper still reports rocblas_status_success,
// so a caller like export-ternary proceeds with corrupted output and the
// process exits 0. Returns true iff the stream is genuinely fenced with no
// fault pending.
bool ts_rblas_check_sync(const char * who, hipStream_t s) {
    hipError_t err = hipStreamSynchronize(s);
    if (err != hipSuccess) {
        if (!g_sync_fail_logged.exchange(true, std::memory_order_acq_rel)) {
            std::fprintf(stderr, "%s: hipStreamSynchronize failed (%s) - GEMM result is "
                                  "not trustworthy, treating this call as a failure\n",
                                  who, hipGetErrorString(err));
        }
        return false;
    }
    return true;
}

} // anonymous namespace

int ts_rblas_check_device_health(const char * where) {
    // hipGetLastError reports any error already latched by a prior
    // (synchronous) HIP call - cheap, no device-side wait.
    hipError_t err = hipGetLastError();
    if (err != hipSuccess) {
        std::fprintf(stderr, "ts_rblas: device health check at '%s': pending HIP error "
                              "%s (%s)\n", where, hipGetErrorName(err), hipGetErrorString(err));
        return 1;
    }
    // An async kernel/HW fault is not necessarily visible until the device
    // is fenced - hipDeviceSynchronize both fences the default stream and
    // returns the same error class if the device itself is in a faulted
    // state (e.g. mid-recovery from a GPU reset).
    err = hipDeviceSynchronize();
    if (err != hipSuccess) {
        std::fprintf(stderr, "ts_rblas: device health check at '%s': device fault on "
                              "synchronize: %s (%s)\n", where, hipGetErrorName(err), hipGetErrorString(err));
        return 1;
    }
    return 0;
}

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
    if (role < 0 || role >= TS_RBLAS_ROLE_COUNT || bytes == 0) {
        return {nullptr, 0};
    }
    if (ts_rocblas_handle() == nullptr) {
        // No usable handle - leave the slot alone, return the failure sentinel.
        g_fallback_count[role].fetch_add(1, std::memory_order_relaxed);
        return {nullptr, 0};
    }

    // W1-D2: the pool is process-global (one slot per role, grow-only) and
    // was designed for a single dispatching thread - the comment used to
    // say so and a debug-only assert used to catch a violation, but that
    // assert compiled out under -DNDEBUG (this pipeline's actual build),
    // so nothing ever enforced it. A second thread calling this while a
    // first thread's buffer for the same role was still in_use fell
    // through to the "grow" path below and hipFree'd a buffer the first
    // thread was still actively writing into via an in-flight GEMM -
    // observed directly as a GPU page fault with multiple threads inside
    // this function, one mid hipFree->SyncAllStreams. g_pool_mutex now
    // stays LOCKED across the whole checkout - ts_rblas_buf_release
    // unlocks it - so a second thread genuinely blocks and waits instead
    // of racing. Harmless for throughput: a single GPU serializes actual
    // device work regardless of caller count, and every rocBLAS dispatch
    // in this codebase is already a self-contained get-use-release
    // sequence within one function call (this file's own header comment),
    // so no caller can accidentally hold this across unrelated work.
    g_pool_mutex.lock();

    ts_rblas_slot & slot = g_pool[role];
    if (slot.dev != nullptr && slot.bytes >= bytes && !slot.in_use) {
        slot.in_use = true;
        g_dispatch_count[role].fetch_add(1, std::memory_order_relaxed);
        return {slot.dev, slot.bytes};
    }
    // Grow (or initial alloc). Free the old buffer if it was too small.
    // Safe now: the lock has been held continuously since this slot was
    // last handed out, so `slot.in_use` here can only be false (idle) or
    // "too small" for a role whose one prior caller already released it.
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
        g_pool_mutex.unlock();
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
    for (int i = 0; i < TS_RBLAS_ROLE_COUNT; i++) {
        if (g_pool[i].dev == b.dev) {
            g_pool[i].in_use = false;
            g_pool_mutex.unlock();
            return;
        }
    }
    // Slot not found - shouldn't happen if the buffer came from this shim,
    // but be defensive: free the device memory rather than leak. The lock
    // is still held (ts_rblas_buf_get only ever returns a non-null buffer
    // while holding it) - unlock before returning.
    (void)hipFree(b.dev);
    g_pool_mutex.unlock();
}

// ---------------------------------------------------------------------------
// W2 native-precision GEMM helpers. See tessera-rocblas.h for the full
// per-helper design rationale.
// ---------------------------------------------------------------------------

rocblas_status ts_rblas_sgemm_bf16acc(rocblas_operation transA, rocblas_operation transB,
                                       int m, int n, int k,
                                       const float * alpha,
                                       const float * A, int lda, size_t a_elems,
                                       const float * B, int ldb, size_t b_elems,
                                       const float * beta,
                                       float * C, int ldc, size_t c_elems) {
    rocblas_handle handle = ts_rocblas_handle();
    if (handle == nullptr) {
        return rocblas_status_invalid_handle;
    }
    // OQ-2 + empirically confirmed hardware constraint (gap-ledger
    // CORRECTION-w2-2): below the WMMA minimum tile, or with the kill
    // switch off, skip straight to plain f32 - no bf16 cast overhead for
    // nothing.
    if (ts_rblas_bf16_enabled() && m >= 16 && n >= 16 && k >= 16) {
        std::vector<rocblas_bfloat16> A_bf16(a_elems), B_bf16(b_elems);
        for (size_t i = 0; i < a_elems; i++) A_bf16[i] = rocblas_bfloat16(A[i]);
        for (size_t i = 0; i < b_elems; i++) B_bf16[i] = rocblas_bfloat16(B[i]);

        ts_rblas_buf a = ts_rblas_buf_get(TS_RBLAS_BF16_A, a_elems * sizeof(rocblas_bfloat16));
        ts_rblas_buf b = ts_rblas_buf_get(TS_RBLAS_BF16_B, b_elems * sizeof(rocblas_bfloat16));
        ts_rblas_buf c = ts_rblas_buf_get(TS_RBLAS_OUT_F32, c_elems * sizeof(float));
        if (a.dev && b.dev && c.dev) {
            hipStream_t s = ts_rblas_stream();
            hipMemcpyAsync(a.dev, A_bf16.data(), a_elems * sizeof(rocblas_bfloat16),
                           hipMemcpyHostToDevice, s);
            hipMemcpyAsync(b.dev, B_bf16.data(), b_elems * sizeof(rocblas_bfloat16),
                           hipMemcpyHostToDevice, s);
            // Both operands must be bf16_r - c/d_type f32_r + compute_type
            // f32_r accumulate (D1 W2: f32 accumulation mandatory). The
            // f32-storage-with-bf16-compute_type design this replaced, and
            // a mixed bf16/f32 operand pair, both return
            // rocblas_status_not_implemented on this host - only this
            // combination has a Tensile kernel.
            rocblas_status st = rocblas_gemm_ex(
                handle, transA, transB, m, n, k,
                alpha,
                a.dev, rocblas_datatype_bf16_r, lda,
                b.dev, rocblas_datatype_bf16_r, ldb,
                beta,
                c.dev, rocblas_datatype_f32_r, ldc,
                c.dev, rocblas_datatype_f32_r, ldc,
                rocblas_datatype_f32_r,
                rocblas_gemm_algo_standard, 0, 0);
            if (st == rocblas_status_success) {
                hipMemcpyAsync(C, c.dev, c_elems * sizeof(float), hipMemcpyDeviceToHost, s);
                if (!ts_rblas_check_sync("ts_rblas_sgemm_bf16acc(bf16 fast path)", s)) {
                    st = rocblas_status_internal_error;
                }
                if (st == rocblas_status_success) {
                    ts_rblas_buf_release(a);
                    ts_rblas_buf_release(b);
                    ts_rblas_buf_release(c);
                    return st;
                }
            }
            ts_rblas_log_gemm_ex_fail_once("ts_rblas_sgemm_bf16acc", st);
        }
        ts_rblas_buf_release(a);
        ts_rblas_buf_release(b);
        ts_rblas_buf_release(c);
    }
    // Fallback: plain f32 rocBLAS, re-staging the caller's ORIGINAL data
    // (not the bf16-truncated copy).
    ts_rblas_buf af = ts_rblas_buf_get(TS_RBLAS_IN_F32_A, a_elems * sizeof(float));
    ts_rblas_buf bf = ts_rblas_buf_get(TS_RBLAS_IN_F32_B, b_elems * sizeof(float));
    ts_rblas_buf cf = ts_rblas_buf_get(TS_RBLAS_OUT_F32, c_elems * sizeof(float));
    if (!af.dev || !bf.dev || !cf.dev) {
        ts_rblas_buf_release(af);
        ts_rblas_buf_release(bf);
        ts_rblas_buf_release(cf);
        return rocblas_status_memory_error;
    }
    hipStream_t s = ts_rblas_stream();
    hipMemcpyAsync(af.dev, A, a_elems * sizeof(float), hipMemcpyHostToDevice, s);
    hipMemcpyAsync(bf.dev, B, b_elems * sizeof(float), hipMemcpyHostToDevice, s);
    rocblas_status st = rocblas_sgemm(handle, transA, transB, m, n, k,
                                      alpha, (float*) af.dev, lda,
                                      (float*) bf.dev, ldb,
                                      beta, (float*) cf.dev, ldc);
    hipMemcpyAsync(C, cf.dev, c_elems * sizeof(float), hipMemcpyDeviceToHost, s);
    // Always synchronize (regardless of st) - buffers are about to be
    // released back to the pool and must not be handed to the next caller
    // while an async copy is still in flight. Only let a genuine sync fault
    // downgrade st; an already-failed st stays failed either way.
    if (!ts_rblas_check_sync("ts_rblas_sgemm_bf16acc(f32 fallback)", s)) {
        st = rocblas_status_internal_error;
    }
    ts_rblas_buf_release(af);
    ts_rblas_buf_release(bf);
    ts_rblas_buf_release(cf);
    return st;
}

rocblas_status ts_rblas_dgemm_to_sgemm(rocblas_operation transA, rocblas_operation transB,
                                        int m, int n, int k,
                                        float alpha,
                                        const float * A, int lda, size_t a_elems,
                                        const float * B, int ldb, size_t b_elems,
                                        float * C, int ldc, size_t c_elems) {
    rocblas_handle handle = ts_rocblas_handle();
    if (handle == nullptr) {
        return rocblas_status_invalid_handle;
    }
    ts_rblas_buf a = ts_rblas_buf_get(TS_RBLAS_IN_F32_A, a_elems * sizeof(float));
    ts_rblas_buf b = ts_rblas_buf_get(TS_RBLAS_IN_F32_B, b_elems * sizeof(float));
    ts_rblas_buf c = ts_rblas_buf_get(TS_RBLAS_OUT_F32, c_elems * sizeof(float));
    if (!a.dev || !b.dev || !c.dev) {
        ts_rblas_buf_release(a);
        ts_rblas_buf_release(b);
        ts_rblas_buf_release(c);
        return rocblas_status_memory_error;
    }
    hipStream_t s = ts_rblas_stream();
    hipMemcpyAsync(a.dev, A, a_elems * sizeof(float), hipMemcpyHostToDevice, s);
    hipMemcpyAsync(b.dev, B, b_elems * sizeof(float), hipMemcpyHostToDevice, s);
    const float beta = 0.0f;
    rocblas_status st = rocblas_sgemm(handle, transA, transB, m, n, k,
                                      &alpha, (float*) a.dev, lda,
                                      (float*) b.dev, ldb,
                                      &beta,  (float*) c.dev, ldc);
    hipMemcpyAsync(C, c.dev, c_elems * sizeof(float), hipMemcpyDeviceToHost, s);
    if (!ts_rblas_check_sync("ts_rblas_dgemm_to_sgemm", s)) {
        st = rocblas_status_internal_error;
    }
    ts_rblas_buf_release(a);
    ts_rblas_buf_release(b);
    ts_rblas_buf_release(c);
    return st;
}

rocblas_status ts_rblas_gemm_bf16_mixed(rocblas_handle handle,
                                         rocblas_operation transA, rocblas_operation transB,
                                         int m, int n, int k,
                                         const float * alpha,
                                         const rocblas_bfloat16 * A_bf16,
                                         const float * A_f32,
                                         int lda,
                                         const float * B, int ldb,
                                         const float * beta,
                                         float * C, int ldc) {
    if (!ts_rblas_bf16_enabled() || A_bf16 == nullptr || m < 16 || n < 16 || k < 16) {
        return rocblas_sgemm(handle, transA, transB, m, n, k,
                             alpha, A_f32, lda, B, ldb, beta, C, ldc);
    }
    // Genuinely mixed input dtypes (A bf16, B/C f32) - unlike
    // ts_rblas_sgemm_bf16acc, which keeps all operands f32 and only
    // promotes compute_type. OQ-1 territory: unverified whether this
    // specific combination is accelerated (vs. silently falling back to a
    // slower internal path) on this ROCm version - rocprofv3 is the
    // diagnostic (task 2.4); the API-level fallback below makes an
    // outright rejection safe either way.
    rocblas_status st = rocblas_gemm_ex(
        handle, transA, transB, m, n, k,
        alpha,
        A_bf16, rocblas_datatype_bf16_r, lda,
        B,      rocblas_datatype_f32_r,  ldb,
        beta,
        C, rocblas_datatype_f32_r, ldc,
        C, rocblas_datatype_f32_r, ldc,
        rocblas_datatype_f32_r,   // f32 accumulation (D1 W2: mandatory)
        rocblas_gemm_algo_standard, 0, 0);
    if (st != rocblas_status_success) {
        ts_rblas_log_gemm_ex_fail_once("ts_rblas_gemm_bf16_mixed", st);
        return rocblas_sgemm(handle, transA, transB, m, n, k,
                             alpha, A_f32, lda, B, ldb, beta, C, ldc);
    }
    return st;
}

namespace {

__attribute__((destructor))
static void ts_rocblas_shutdown() {
    if (std::getenv("TS_RBLAS_STATS") != nullptr) {
        std::fprintf(stderr, "ts_rblas: per-role stats (dispatch / fallback / high-water bytes)\n");
        for (int i = 0; i < TS_RBLAS_ROLE_COUNT; i++) {
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
    std::lock_guard<std::recursive_mutex> lock(g_pool_mutex);
    for (int i = 0; i < TS_RBLAS_ROLE_COUNT; i++) {
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
