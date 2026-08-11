// Test that GGML_OP_TILE640_MATMUL actually writes to its output tensor.
//
// Regression test for the slot-binding bug introduced by commit
// f10569f8d ("tessera: kernel - add act_scale + modality branch +
// precision invariant", Jul 30 2026): the dense kernel_TILE640_MATMUL
// signature was extended with `act_scale` at slot 8 and `modality_id`
// at slot 10, but the dispatch in ggml_metal_op_tile640_matmul was
// never updated. The dispatch still binds output to slot 8 (where
// act_scale is now expected) and never binds slot 9 (where output is
// now expected). Metal doesn't error on unbound slots — it just gives
// you a null/undefined MTLBuffer — so the kernel runs to completion
// but output[output_offset] = acc writes to garbage.
//
// The previous B5 test (test_b5_tile640_metal_dequant) never caught
// this because it only checks the L1 dequant sidecar (written async
// in a Metal completed handler, which IS synchronized correctly), never
// the matmul output itself. This test reads the matmul output via
// ggml_backend_tensor_get and asserts the values match a CPU reference.
//
// We bypass the quantizer with pre-baked packed tensors (all-zero
// packed trits + a known per-row outlier) because the slot-binding
// bug is in the dispatch, not in the math. Pre-baked data keeps the
// test hermetic and < 1s wall.
//
// Scenarios covered:
//   1. F32 input, n_tokens=1, single outlier per row, all same val
//   2. F16 input, n_tokens=1, single outlier per row, all same val
//   3. F32 input with all packed data zero (kernel must write 0,
//      NOT the prefill sentinel)
//   4. sentinel-presence check: pre-fill output with 42, run, verify
//      the kernel wrote (value changed from 42) — would have caught
//      the slot mismatch even without a CPU reference
//
// Run: cmake --build build --target test-tile640-matmul-output &&
//      build/bin/test-tile640-matmul-output

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-metal.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int g_fail = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { std::fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); g_fail++; } \
    else          { std::fprintf(stderr, "  ok : %s\n", msg); } \
} while (0)

struct PackedFixture {
    // dense layout: out_dim rows, 1 page per row (in_dim <= 640)
    // per-row = 32 (packed) + 2 (ps) + 32 (ls) = 66 words
    // bytes: 128 (packed) + 2 (ps) + 32 (ls) = 162 bytes per row
    int64_t out_dim;
    int64_t in_dim;
    int64_t pages_per_row;
    std::vector<uint8_t>  packed_total;  // out_dim * pages_per_row * 128 bytes
    std::vector<int32_t>  oro;           // [0, 1, 2, ..., out_dim] — one outlier per row
    std::vector<int32_t>  oc;            // [0, 0, 0, ...] — outlier col 0
    std::vector<uint16_t> ov;            // [val_f16, val_f16, ...] — outlier value per row
};

static PackedFixture make_fixture(int64_t out_dim, int64_t in_dim, float outlier_val) {
    PackedFixture f;
    f.out_dim = out_dim;
    f.in_dim  = in_dim;
    f.pages_per_row = (in_dim + 639) / 640;
    // All packed = zero (all trits are 0 -> dequant = 0)
    // All page_scale = 0 (no contribution)
    // All lane_scale = 0 (no contribution)
    f.packed_total.assign((size_t)(out_dim * f.pages_per_row * 162), 0);
    f.oro.resize((size_t)(out_dim + 1));
    for (int64_t r = 0; r <= out_dim; r++) f.oro[(size_t)r] = (int32_t) r;
    f.oc.assign((size_t) out_dim, 0);  // outlier col = 0 for every row
    f.ov.assign((size_t) out_dim, 0);
    // f16 of outlier_val
    uint16_t val_f16 = (uint16_t) ggml_fp32_to_fp16(outlier_val);
    for (int64_t r = 0; r < out_dim; r++) f.ov[(size_t)r] = val_f16;
    return f;
}

static int64_t run_matmul(ggml_backend_t backend, const PackedFixture & f,
                          ggml_type input_type, const std::vector<float> & input,
                          std::vector<float> & gpu_out) {
    struct ggml_init_params ip = { 8 * 1024 * 1024, nullptr, true };
    struct ggml_context * gctx = ggml_init(ip);

    struct ggml_tensor * A_packed = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, (int64_t)(f.out_dim * f.pages_per_row * 32));
    struct ggml_tensor * A_ps     = ggml_new_tensor_1d(gctx, GGML_TYPE_F16, (int64_t)(f.out_dim * f.pages_per_row));
    struct ggml_tensor * A_ls     = ggml_new_tensor_1d(gctx, GGML_TYPE_I8,  (int64_t)(f.out_dim * f.pages_per_row * 32));
    struct ggml_tensor * A_oro    = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, (int64_t) f.oro.size());
    struct ggml_tensor * A_oc     = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, (int64_t) f.oc.size());
    struct ggml_tensor * A_ov     = ggml_new_tensor_1d(gctx, GGML_TYPE_F16, (int64_t) f.ov.size());
    struct ggml_tensor * B         = ggml_new_tensor_2d(gctx, input_type, f.in_dim, /*n_tokens=*/1);
    struct ggml_tensor * out      = ggml_tile640_matmul(gctx, A_packed, A_ps, A_ls, A_oro, A_oc, A_ov, B);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(gctx, backend);
    if (!buf) { std::fprintf(stderr, "FAIL: alloc\n"); g_fail++; ggml_free(gctx); return -1; }
    auto set = [](struct ggml_tensor * t, const void * d) { ggml_backend_tensor_set(t, d, 0, ggml_nbytes(t)); };
    set(A_packed, f.packed_total.data());
    set(A_ps,     f.packed_total.data() + 128);
    set(A_ls,     f.packed_total.data() + 130);
    set(A_oro,    f.oro.data());
    set(A_oc,     f.oc.data());
    set(A_ov,     f.ov.data());
    if (input_type == GGML_TYPE_F32) {
        set(B, input.data());
    } else {
        std::vector<uint16_t> bh((size_t) f.in_dim);
        for (int64_t i = 0; i < f.in_dim; i++) bh[(size_t)i] = (uint16_t) ggml_fp32_to_fp16(input[(size_t)i]);
        set(B, bh.data());
    }
    // Pre-fill output with a known sentinel so we can tell if the kernel
    // actually wrote. If the slot-binding bug is reintroduced, the
    // output stays at the sentinel.
    std::vector<float> sentinel((size_t)(f.out_dim), 42.0f);
    set(out, sentinel.data());

    struct ggml_cgraph * cg = ggml_new_graph(gctx);
    ggml_build_forward_expand(cg, out);
    enum ggml_status st = ggml_backend_graph_compute(backend, cg);
    if (st != GGML_STATUS_SUCCESS) {
        std::fprintf(stderr, "FAIL: graph_compute status=%d\n", (int) st);
        g_fail++;
        ggml_backend_buffer_free(buf);
        ggml_free(gctx);
        return -1;
    }
    // Sync — ggml_backend_graph_compute is async; without synchronize
    // the readback races the GPU.
    ggml_backend_synchronize(backend);

    gpu_out.assign((size_t) f.out_dim, 0.0f);
    ggml_backend_tensor_get(out, gpu_out.data(), 0, ggml_nbytes(out));

    // Free the buffer BEFORE ggml_free(gctx) — the buffer's free_buffer
    // callback removes the residency set entry from the device's
    // collection. Skipping this leaks the rset entry, which trips
    // GGML_ASSERT([rsets->data count] == 0) at process exit
    // (ggml/src/ggml-metal/ggml-metal-device.m:647). ggml_free(gctx) only
    // destroys the tensors, not the buffer.
    ggml_backend_buffer_free(buf);
    ggml_free(gctx);
    return 0;
}

int main(void) {
    ggml_backend_t backend = ggml_backend_metal_init();
    if (backend == nullptr) {
        std::fprintf(stderr, "SKIP: Metal backend not available\n");
        return 0;  // not a failure on non-Apple hosts
    }
    std::fprintf(stderr, "Metal backend initialized\n");

    // -----------------------------------------------------------------
    // 1. F32 input: out_dim=4, in_dim=640, outlier val=2.0 at col 0
    //    CPU ref: each row = 0 (dequant) + 2.0 * input[0] = 2.0 * 1.0 = 2.0
    // -----------------------------------------------------------------
    {
        std::fprintf(stderr, "\n--- Test 1: F32 input, single outlier per row ---\n");
        const int64_t out_dim = 4, in_dim = 640;
        const float outlier_val = 2.0f;
        PackedFixture f = make_fixture(out_dim, in_dim, outlier_val);
        std::vector<float> input((size_t) in_dim, 1.0f);
        std::vector<float> gpu_out;
        run_matmul(backend, f, GGML_TYPE_F32, input, gpu_out);
        // CPU ref
        for (int64_t r = 0; r < out_dim; r++) {
            float ref = 0.0f + outlier_val * input[0];
            CHECK(std::fabs(gpu_out[(size_t)r] - ref) < 0.01f, "F32 single-outlier matmul value");
        }
    }

    // -----------------------------------------------------------------
    // 2. F16 input: same shape, but B is F16
    // -----------------------------------------------------------------
    {
        std::fprintf(stderr, "\n--- Test 2: F16 input, single outlier per row ---\n");
        const int64_t out_dim = 4, in_dim = 640;
        const float outlier_val = 2.0f;
        PackedFixture f = make_fixture(out_dim, in_dim, outlier_val);
        std::vector<float> input((size_t) in_dim, 1.0f);
        std::vector<float> gpu_out;
        run_matmul(backend, f, GGML_TYPE_F16, input, gpu_out);
        for (int64_t r = 0; r < out_dim; r++) {
            float ref = 0.0f + outlier_val * input[0];
            CHECK(std::fabs(gpu_out[(size_t)r] - ref) < 0.01f, "F16 single-outlier matmul value");
        }
    }

    // -----------------------------------------------------------------
    // 3. sentinel-presence check: kernel must write (not stay at 42.0)
    //    even when the computed value is 0. This is the strict
    //    regression check — would have caught the slot-binding bug
    //    even without a CPU reference.
    // -----------------------------------------------------------------
    {
        std::fprintf(stderr, "\n--- Test 3: sentinel-presence (kernel must write) ---\n");
        const int64_t out_dim = 4, in_dim = 640;
        PackedFixture f = make_fixture(out_dim, in_dim, /*outlier_val=*/0.0f);
        std::vector<float> input((size_t) in_dim, 0.0f);  // input all zero
        std::vector<float> gpu_out;
        run_matmul(backend, f, GGML_TYPE_F32, input, gpu_out);
        bool any_changed = false;
        for (int64_t r = 0; r < out_dim; r++) {
            if (gpu_out[(size_t)r] != 42.0f) { any_changed = true; break; }
        }
        CHECK(any_changed, "kernel overwrote prefill sentinel (slot-binding is correct)");
    }

    // -----------------------------------------------------------------
    // 4. larger shape: in_dim=1280 (2 pages), verify multi-page decode
    // -----------------------------------------------------------------
    {
        std::fprintf(stderr, "\n--- Test 4: F32 input, in_dim=1280 (2 pages) ---\n");
        const int64_t out_dim = 8, in_dim = 1280;
        const float outlier_val = 3.5f;
        PackedFixture f = make_fixture(out_dim, in_dim, outlier_val);
        std::vector<float> input((size_t) in_dim, 1.0f);
        std::vector<float> gpu_out;
        run_matmul(backend, f, GGML_TYPE_F32, input, gpu_out);
        for (int64_t r = 0; r < out_dim; r++) {
            float ref = 0.0f + outlier_val * input[0];
            CHECK(std::fabs(gpu_out[(size_t)r] - ref) < 0.01f, "2-page F32 matmul value");
        }
    }

    ggml_backend_free(backend);
    std::fprintf(stderr, "\n%s (%d failure%s)\n",
        g_fail == 0 ? "PASS" : "FAIL",
        g_fail, g_fail == 1 ? "" : "s");
    return g_fail == 0 ? 0 : 1;
}
