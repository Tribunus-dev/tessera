// Cross-backend IOSurface buffer test (the data plane for lock-free
// CPU/Metal/ANE dispatch).
//
// Validates that ggml_backend_ane_iosurface_buffer_alloc produces a
// buffer whose memory is shared between the CPU (locked CVPixelBuffer
// base), Metal (lazily-wrapped MTLBuffer), and (transitively) ANE
// (raw IOSurfaceRef). The contract is "no copies": writing through the
// CPU view is observable through the Metal view, and vice versa.
//
// This is the foundation of the lock-free cross-backend dispatch
// (per the prism-engine IOSurface arena / SharedEventContract pattern,
// mapped to llama.cpp). The control plane (MTLSharedEvent) and the
// dispatch API build on top of this primitive in subsequent commits.

#include "ggml-ane.h"
#include "ggml.h"
#include "ggml-backend.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

namespace {

constexpr uint32_t kN = 4096;

bool cpu_write_metal_read() {
    ggml_backend_buffer_t buf = ggml_backend_ane_iosurface_buffer_alloc(kN * sizeof(float));
    if (!buf) {
        std::fprintf(stderr, "alloc failed\n");
        return false;
    }
    if (!ggml_backend_ane_iosurface_buffer_check(buf)) {
        std::fprintf(stderr, "check failed: not an ANE IOSurface buffer\n");
        return false;
    }
    void * base = ggml_backend_buffer_get_base(buf);
    if (!base) {
        std::fprintf(stderr, "base is null\n");
        return false;
    }
    void * surface = ggml_backend_ane_iosurface_buffer_get_iosurface(buf);
    if (!surface) {
        std::fprintf(stderr, "iosurface is null\n");
        return false;
    }
    void * mtl_buf_void = ggml_backend_ane_iosurface_buffer_get_mtl_buffer(buf);
    if (!mtl_buf_void) {
        std::fprintf(stderr, "metal buffer is null\n");
        return false;
    }
    id<MTLBuffer> mtl_buf = (__bridge id<MTLBuffer>) mtl_buf_void;
    if (mtl_buf.length < kN * sizeof(float)) {
        std::fprintf(stderr, "metal buffer too small (got %zu, expected >= %zu)\n",
                     (size_t) mtl_buf.length, (size_t) (kN * sizeof(float)));
        return false;
    }
    if (mtl_buf.contents == nullptr) {
        std::fprintf(stderr, "metal buffer contents pointer is null\n");
        return false;
    }

    // The CPU base, the IOSurface base, and the MTLBuffer contents must
    // all point to the same physical pages. Per Apple's docs, the IOSurface
    // is process-shared and the MTLBuffer (created with
    // newBufferWithBytesNoCopy) shares the same memory.
    void * isurf_base = IOSurfaceGetBaseAddress((IOSurfaceRef) surface);
    if (isurf_base != base) {
        std::fprintf(stderr, "iosurface base (%p) does not match CPU base (%p)\n",
                     isurf_base, base);
        return false;
    }
    if (mtl_buf.contents != base) {
        std::fprintf(stderr, "metal buffer contents (%p) does not match CPU base (%p)\n",
                     mtl_buf.contents, base);
        return false;
    }

    // Write a deterministic pattern through the CPU view, read it back
    // through the Metal view, and verify they match.
    auto * cpu = static_cast<float *>(base);
    auto * mtl = static_cast<float *>(mtl_buf.contents);
    for (uint32_t i = 0; i < kN; ++i) {
        cpu[i] = static_cast<float>(i) * 0.5f - 1.0f;
    }
    bool ok = true;
    for (uint32_t i = 0; i < kN; ++i) {
        if (mtl[i] != cpu[i]) {
            std::fprintf(stderr, "mismatch at %u (cpu=%.4f metal=%.4f)\n",
                         i, cpu[i], mtl[i]);
            ok = false;
            break;
        }
    }
    if (!ok) {
        return false;
    }

    // Reverse: write through Metal, read through CPU.
    for (uint32_t i = 0; i < kN; ++i) {
        mtl[i] = static_cast<float>(i) * -0.25f + 3.5f;
    }
    for (uint32_t i = 0; i < kN; ++i) {
        if (cpu[i] != static_cast<float>(i) * -0.25f + 3.5f) {
            std::fprintf(stderr, "cpu view did not see metal write at %u (cpu=%.4f)\n",
                         i, cpu[i]);
            ok = false;
            break;
        }
    }
    if (!ok) {
        return false;
    }

    // Calling get_mtl_buffer twice should return the same MTLBuffer
    // (lazy-cached).
    void * mtl_buf_2 = ggml_backend_ane_iosurface_buffer_get_mtl_buffer(buf);
    if (mtl_buf_2 != mtl_buf_void) {
        std::fprintf(stderr, "mtl_buffer not cached (got %p then %p)\n",
                     mtl_buf_void, mtl_buf_2);
        ok = false;
    }

    ggml_backend_buffer_free(buf);
    return ok;
}

// The IOSurface buffer type is exported and truthful about host access.
// The type is what the CPU, BLAS, Metal, and ANE backends advertise from
// supports_buft; is_host must report the locked base truthfully or the
// host backends refuse the type.
bool buffer_type_export() {
    ggml_backend_buffer_type_t buft = ggml_backend_ane_iosurface_buffer_type();
    if (!buft) {
        std::fprintf(stderr, "buffer type is null\n");
        return false;
    }
    if (std::strcmp(ggml_backend_buft_name(buft), "ANE_IOSURFACE") != 0) {
        std::fprintf(stderr, "unexpected buffer type name: %s\n", ggml_backend_buft_name(buft));
        return false;
    }
    if (!ggml_backend_buft_is_host(buft)) {
        std::fprintf(stderr, "buffer type must report host memory (locked IOSurface base)\n");
        return false;
    }

    // alloc through the type produces a buffer the check accepts
    ggml_backend_buffer_t buf = ggml_backend_buft_alloc_buffer(buft, kN * sizeof(float));
    if (!buf) {
        std::fprintf(stderr, "alloc through the exported type failed\n");
        return false;
    }
    if (!ggml_backend_ane_iosurface_buffer_check(buf)) {
        std::fprintf(stderr, "check rejected a buffer allocated through the exported type\n");
        return false;
    }
    ggml_backend_buffer_free(buf);
    return true;
}

// Every registered backend device accepts the IOSurface buffer type. This is
// the scheduler-visible condition for zero-copy: if any device rejects the
// type, ggml_backend_sched inserts a CPY when a tensor in it crosses to that
// device.
bool backend_buft_acceptance() {
    ggml_backend_buffer_type_t buft = ggml_backend_ane_iosurface_buffer_type();

    size_t n_dev = ggml_backend_dev_count();
    if (n_dev == 0) {
        std::fprintf(stderr, "no backend devices registered\n");
        return false;
    }

    bool saw_cpu = false, saw_metal = false, saw_ane = false;
    int failures = 0;
    for (size_t i = 0; i < n_dev; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char * name = ggml_backend_dev_name(dev);
        bool ok = ggml_backend_dev_supports_buft(dev, buft);
        std::printf("\n  device %-8s accepts ANE_IOSURFACE: %s", name, ok ? "yes" : "no");
        if (!ok) {
            failures++;
        }
        if (std::strcmp(name, "CPU") == 0)      saw_cpu   = true;
        if (std::strncmp(name, "MTL", 3) == 0)  saw_metal = true;
        if (std::strncmp(name, "ANE", 3) == 0)  saw_ane   = true;
    }
    std::printf("\n");
    if (!saw_cpu || !saw_metal || !saw_ane) {
        std::fprintf(stderr, "expected CPU, MTL*, and ANE devices registered (cpu=%d metal=%d ane=%d)\n",
                     saw_cpu, saw_metal, saw_ane);
        return false;
    }
    if (failures) {
        std::fprintf(stderr, "%d device(s) rejected the IOSurface buffer type\n", failures);
        return false;
    }
    return true;
}

// The ANE device's default buffer type is the IOSurface type: model-load
// placement for the ANE lane goes through IOSurface buffers by default. The
// escape hatch GGML_ANE_NO_IOSURFACE_DEFAULT=1 restores the private ANE
// heap. The IOSurface singleton must stay device-less (portable) either way.
bool device_default_placement() {
    ggml_backend_dev_t ane_dev = ggml_backend_dev_by_name("ANE");
    if (!ane_dev) {
        std::fprintf(stderr, "ANE device not registered\n");
        return false;
    }

    ggml_backend_buffer_type_t dev_buft = ggml_backend_dev_buffer_type(ane_dev);
    ggml_backend_buffer_type_t ios_buft = ggml_backend_ane_iosurface_buffer_type();

    const char * env = getenv("GGML_ANE_NO_IOSURFACE_DEFAULT");
    const bool disabled = env && env[0] != '\0' && env[0] != '0';

    if (disabled) {
        if (dev_buft == ios_buft) {
            std::fprintf(stderr, "escape hatch set but ANE default is still IOSurface\n");
            return false;
        }
        if (std::strcmp(ggml_backend_buft_name(dev_buft), "ANE") != 0) {
            std::fprintf(stderr, "escape hatch set: expected ANE buft, got %s\n",
                         ggml_backend_buft_name(dev_buft));
            return false;
        }
        std::printf("(escape hatch active) ");
    } else {
        if (dev_buft != ios_buft) {
            std::fprintf(stderr, "ANE default buft is %s, expected ANE_IOSURFACE\n",
                         ggml_backend_buft_name(dev_buft));
            return false;
        }
        if (ggml_backend_buft_get_device(ios_buft) != nullptr) {
            std::fprintf(stderr, "IOSurface singleton must stay device-less\n");
            return false;
        }
    }
    return true;
}

// A scheduler-visible IOSurface buffer crosses CPU -> Metal -> CPU with zero
// inserted copies. The leaves are allocated in the IOSurface buffer type; the
// compute (F32 MUL_MAT) runs on Metal, which accepts the type and wraps the
// surface as an MTLBuffer at encode time. With every backend on the path
// advertising the type, the scheduler must not insert any CPY nodes.
bool scheduler_zero_copy() {
    ggml_backend_buffer_type_t buft = ggml_backend_ane_iosurface_buffer_type();

    ggml_backend_dev_t cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    ggml_backend_dev_t gpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    if (!cpu_dev || !gpu_dev) {
        std::fprintf(stderr, "need CPU + GPU devices\n");
        return false;
    }
    ggml_backend_t cpu_backend   = ggml_backend_dev_init(cpu_dev, nullptr);
    ggml_backend_t metal_backend = ggml_backend_dev_init(gpu_dev, nullptr);
    if (!cpu_backend || !metal_backend) {
        std::fprintf(stderr, "backend init failed\n");
        return false;
    }

    const int64_t K = 4, M = 4, N = 4;

    struct ggml_init_params params = {
        /*.mem_size   =*/ 8 * 1024 * 1024,
        /*.mem_buffer =*/ NULL,
        /*.no_alloc   =*/ true,
    };
    struct ggml_context * ctx = ggml_init(params);
    if (!ctx) {
        std::fprintf(stderr, "ggml_init failed\n");
        return false;
    }

    struct ggml_tensor * a = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, M);
    struct ggml_tensor * b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
    struct ggml_tensor * c = ggml_mul_mat(ctx, a, b);

    // Place both leaves in a single IOSurface buffer at aligned offsets.
    const size_t align = ggml_backend_buft_get_alignment(buft);
    const size_t sz_a  = ggml_backend_buft_get_alloc_size(buft, a);
    const size_t off_a = 0;
    const size_t off_b = (sz_a + align - 1) / align * align;
    const size_t total = off_b + ggml_backend_buft_get_alloc_size(buft, b);

    ggml_backend_buffer_t leaf_buf = ggml_backend_buft_alloc_buffer(buft, total);
    if (!leaf_buf) {
        std::fprintf(stderr, "IOSurface buffer allocation failed\n");
        return false;
    }
    char * base = (char *) ggml_backend_buffer_get_base(leaf_buf);
    if (ggml_backend_tensor_alloc(leaf_buf, a, base + off_a) != GGML_STATUS_SUCCESS ||
        ggml_backend_tensor_alloc(leaf_buf, b, base + off_b) != GGML_STATUS_SUCCESS) {
        std::fprintf(stderr, "tensor placement in IOSurface buffer failed\n");
        return false;
    }

    // fill the leaves through the CPU view
    std::vector<float> host_a(K * M), host_b(K * N);
    for (int64_t i = 0; i < K * M; i++) host_a[i] = 0.25f * (float) (i % 7) - 0.5f;
    for (int64_t i = 0; i < K * N; i++) host_b[i] = 0.5f  * (float) (i % 5) - 1.0f;
    ggml_backend_tensor_set(a, host_a.data(), 0, ggml_nbytes(a));
    ggml_backend_tensor_set(b, host_b.data(), 0, ggml_nbytes(b));

    struct ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, c);

    // the scheduler requires the CPU backend last in the list
    ggml_backend_t backends[2] = { metal_backend, cpu_backend };
    ggml_backend_buffer_type_t sched_bufts[2] = {
        ggml_backend_dev_buffer_type(gpu_dev),
        ggml_backend_dev_buffer_type(cpu_dev),
    };
    ggml_backend_sched_t sched = ggml_backend_sched_new(backends, sched_bufts, 2, 1024, false, false);
    if (!sched) {
        std::fprintf(stderr, "sched create failed\n");
        return false;
    }

    ggml_status status = ggml_backend_sched_graph_compute_async(sched, gf);
    ggml_backend_sched_synchronize(sched);
    if (status != GGML_STATUS_SUCCESS) {
        std::fprintf(stderr, "graph compute failed: %s\n", ggml_status_to_string(status));
        return false;
    }

    // Zero-copy evidence: the scheduler kept the IOSurface leaves and the
    // result on the Metal backend (the first backend that accepts both the
    // op and the IOSurface buft). If any backend on the path had rejected
    // the type, the leaves or the result would have been assigned to the
    // CPU backend behind a split.
    int n_splits = ggml_backend_sched_get_n_splits(sched);
    std::printf("\n  scheduler splits: %d", n_splits);
    bool placement_ok = true;
    for (struct ggml_tensor * t : { a, b, c }) {
        ggml_backend_t assigned = ggml_backend_sched_get_tensor_backend(sched, t);
        if (assigned != metal_backend) {
            std::fprintf(stderr, "\ntensor %s assigned to %s, expected Metal\n",
                         ggml_get_name(t), assigned ? ggml_backend_name(assigned) : "(none)");
            placement_ok = false;
        }
    }
    if (!placement_ok) {
        return false;
    }
    // ... and the leaves still live inside the IOSurface buffer (no
    // replacement copy tensor displaced them).
    for (struct ggml_tensor * t : { a, b }) {
        const char * p = (const char *) t->data;
        if (p < base || p >= base + total) {
            std::fprintf(stderr, "\ntensor %s escaped the IOSurface buffer\n", ggml_get_name(t));
            return false;
        }
    }

    // read back and compare against a host reference:
    // c[n][m] = sum_k a[m][k] * b[n][k]
    std::vector<float> host_c(M * N, 0.0f);
    ggml_backend_tensor_get(c, host_c.data(), 0, ggml_nbytes(c));

    float max_diff = 0.0f;
    for (int64_t n = 0; n < N; n++) {
        for (int64_t m = 0; m < M; m++) {
            float ref = 0.0f;
            for (int64_t k = 0; k < K; k++) {
                ref += host_a[m * K + k] * host_b[n * K + k];
            }
            max_diff = std::fmax(max_diff, std::fabs(host_c[n * M + m] - ref));
        }
    }
    std::printf("\n  MUL_MAT max_diff vs host reference: %.3e", max_diff);
    if (max_diff > 1e-4f) {
        std::fprintf(stderr, "\nFAIL: zero-copy result mismatch\n");
        return false;
    }

    ggml_backend_sched_free(sched);
    ggml_backend_buffer_free(leaf_buf);
    ggml_backend_free(metal_backend);
    ggml_backend_free(cpu_backend);
    ggml_free(ctx);
    return true;
}

} // namespace

int main() {
    std::printf("data plane: cross-backend IOSurface buffer\n");

    std::printf("  cpu_write_metal_read         ... ");
    if (!cpu_write_metal_read()) {
        std::printf("FAIL\n");
        return 1;
    }
    std::printf("OK\n");

    std::printf("  buffer_type_export           ... ");
    if (!buffer_type_export()) {
        std::printf("FAIL\n");
        return 1;
    }
    std::printf("OK\n");

    std::printf("  backend_buft_acceptance      ... ");
    if (!backend_buft_acceptance()) {
        std::printf("FAIL\n");
        return 1;
    }
    std::printf("  OK\n");

    std::printf("  device_default_placement     ... ");
    if (!device_default_placement()) {
        std::printf("FAIL\n");
        return 1;
    }
    std::printf("OK\n");

    std::printf("  scheduler_zero_copy          ... ");
    if (!scheduler_zero_copy()) {
        std::printf("FAIL\n");
        return 1;
    }
    std::printf("\n  OK\n");

    std::printf("All IOSurface buffer tests passed\n");
    return 0;
}
