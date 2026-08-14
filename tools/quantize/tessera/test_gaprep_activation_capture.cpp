//
// test_gaprep_activation_capture.cpp
//
// Integration test for pipeline refactor stage 3: wiring the real
// activation-capture sidecar (tessera-activation-sidecar.h, stage 2)
// into ts_dispatch_run_gaprep's per-tensor ts_awq_layer construction
// (tools/quantize/tessera/tessera-dispatch-gaprep.cpp), via the
// activations_load_fn/activations_release_fn streaming plumbing added
// in stage 1 (tessera-awq.h).
//
// Builds a tiny synthetic GGUF with two 2D weights, writes a real
// activation-capture sidecar (train + heldout splits) for ONE of them,
// and runs the full dispatch pipeline (ts_dispatch_run) twice with
// identical params/seed except params.activation_capture_dir -- once
// pointing at the sidecar, once empty (control). Asserts:
//   1. Both runs succeed.
//   2. total_mse differs between the two runs -- proof the wiring has
//      a real, end-to-end effect on what the GA actually picks, not
//      just structural plumbing that gets called and ignored (the
//      exact regression class stage 0/1 already pin at the
//      ts_awq_evaluate_layer/ts_awq_evolve_all level; this test proves
//      the same thing survives all the way through the production
//      dispatch entry point).
// A tensor with no sidecar (the second fixture weight) exercises the
// "no capture data -> fall back to the diagonal weight-space error"
// path implicitly, since ts_dispatch_run_gaprep's own fallback (stage
// 1/3 wiring) requires no test-visible assertion beyond "the run still
// succeeds and produces sane output" -- ts_awq_evaluate_layer's
// fallback is already unit-pinned directly in test_awq_fitness.cpp.
//
// The fixture ALSO writes a minimal imatrix GGUF (<tensor>.in_sum2 +
// <tensor>.counts, the format tools/imatrix/imatrix.cpp itself emits
// and common/imatrix-loader.cpp reads back) and points params.imatrix_path
// at it. This is required, not optional: ts_dispatch_awq_eval only calls
// ts_awq_evaluate_layer (the sole consumer of train_activations) when
// layer.second_moment is non-null, and second_moment is only populated
// from an imatrix lookup (tessera-dispatch-gaprep.cpp). Without an
// imatrix, the GA falls back entirely to the streaming/S5 weight-space
// path, which never reads train_activations at all -- confirmed the hard
// way: an earlier version of this test with no imatrix produced bit-
// identical total_mse (0.20825085 both runs) despite the sidecar wiring
// working correctly, because the code path that would have used it was
// never reached.
//

#include "tessera-dispatch.h"
#include "tessera-activation-sidecar.h"

#include "ggml.h"
#include "gguf.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

static int g_fail = 0;
static void check(const char * name, bool ok) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) g_fail++;
}

// Deterministic fixture weights for tensor `idx` (same generator shape as
// test_l5_dispatch.cpp's fixture_tensor_data, kept local to avoid a
// cross-test-file dependency for one small helper).
static std::vector<float> fixture_tensor_data(size_t idx, int64_t out_dim, int64_t in_dim) {
    std::vector<float> data((size_t)(out_dim * in_dim));
    uint32_t rng = (uint32_t)(idx + 1) * 2654435761u;
    for (int64_t j = 0; j < out_dim * in_dim; j++) {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        float u = (float)((rng >> 8) & 0xFFFF) / (float)0xFFFF;
        data[(size_t)j] = (u - 0.5f) * (1.0f + 2.0f * (float)idx);
    }
    return data;
}

static bool build_fixture_gguf(const char * path,
                               const std::vector<std::string> & tensor_names,
                               const std::vector<std::pair<int64_t, int64_t>> & dims) {
    struct gguf_context * ctx = gguf_init_empty();
    struct ggml_init_params ip = { /*mem_size=*/ 4 * 1024 * 1024,
                                   /*mem_buffer=*/ nullptr,
                                   /*no_alloc=*/ false };
    struct ggml_context * gctx = ggml_init(ip);

    for (size_t i = 0; i < tensor_names.size(); i++) {
        const int64_t out_dim = dims[i].first;
        const int64_t in_dim  = dims[i].second;
        struct ggml_tensor * t = ggml_new_tensor_2d(gctx, GGML_TYPE_F32, in_dim, out_dim);
        ggml_set_name(t, tensor_names[i].c_str());
        const std::vector<float> src = fixture_tensor_data(i, out_dim, in_dim);
        std::memcpy(t->data, src.data(), src.size() * sizeof(float));
        gguf_add_tensor(ctx, t);
    }

    bool ok = gguf_write_to_file(ctx, path, false);
    ggml_free(gctx);
    gguf_free(ctx);
    if (!ok) {
        std::printf("FAIL: gguf_write_to_file(%s) returned false\n", path);
        g_fail++;
    }
    return ok;
}

// Deterministic, non-degenerate F16 activation data (distinct from the
// weight fixture's own RNG stream so a bug that accidentally reused the
// weight buffer as "activations" would be visible as a shape-only, not
// value-only, coincidence).
static std::vector<uint16_t> fixture_activation_data(uint32_t seed, int64_t rows, int64_t cols) {
    std::vector<uint16_t> data((size_t)(rows * cols));
    uint32_t rng = seed;
    for (int64_t j = 0; j < rows * cols; j++) {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        float u = (float)((rng >> 8) & 0xFFFF) / (float)0xFFFF;
        data[(size_t)j] = ggml_fp32_to_fp16((u - 0.5f) * 3.0f);
    }
    return data;
}

// Minimal imatrix GGUF, one or more entries: <base_name>.in_sum2
// (in_dim floats, per-channel sum of squared activations) +
// <base_name>.counts (1 float) per entry. Matches the format
// tools/imatrix/imatrix.cpp's save_imatrix emits and
// common/imatrix-loader.cpp's common_imatrix_load reads back (verified
// against that reader: no KV metadata is required, just the two
// suffixed tensors per entry). base_name must NOT include ".weight" --
// ts_imatrix_lookup normalizes its query by stripping ".weight" before
// looking up the map key, so a stored key that still has ".weight"
// would never be found (real imatrix files store bare names for the
// same reason).
struct fixture_imatrix_entry {
    std::string base_name;
    int64_t     in_dim;
    uint32_t    seed;
};

static bool build_fixture_imatrix(const char * path,
                                  const std::vector<fixture_imatrix_entry> & entries) {
    struct gguf_context * ctx = gguf_init_empty();
    struct ggml_init_params ip = { /*mem_size=*/ 2 * 1024 * 1024,
                                   /*mem_buffer=*/ nullptr,
                                   /*no_alloc=*/ false };
    struct ggml_context * gctx = ggml_init(ip);

    gguf_set_val_str(ctx, "general.type", "imatrix");

    for (const auto & e : entries) {
        struct ggml_tensor * sum2   = ggml_new_tensor_1d(gctx, GGML_TYPE_F32, e.in_dim);
        struct ggml_tensor * counts = ggml_new_tensor_1d(gctx, GGML_TYPE_F32, 1);
        ggml_format_name(sum2, "%s.in_sum2", e.base_name.c_str());
        ggml_format_name(counts, "%s.counts", e.base_name.c_str());

        uint32_t rng = e.seed;
        for (int64_t j = 0; j < e.in_dim; j++) {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            // Positive, non-degenerate per-channel "mean squared
            // activation" values so the derived second_moment varies
            // across channels (a flat/constant imatrix would make the
            // importance-weighting math in ts_awq_ternary_reconstruct a
            // no-op).
            float v = 0.2f + 1.8f * (float)((rng >> 8) & 0xFFFF) / (float)0xFFFF;
            ((float *) sum2->data)[j] = v;
        }
        ((float *) counts->data)[0] = 1.0f;

        gguf_add_tensor(ctx, sum2);
        gguf_add_tensor(ctx, counts);
    }

    bool ok = gguf_write_to_file(ctx, path, false);
    ggml_free(gctx);
    gguf_free(ctx);
    return ok;
}

int main() {
    const char * fixture_path  = "/tmp/test_gaprep_activation_capture_input.gguf";
    const char * imatrix_path  = "/tmp/test_gaprep_activation_capture_imatrix.gguf";
    const char * sidecar_dir   = "/tmp/test_gaprep_activation_capture_sidecar";
    std::filesystem::remove_all(sidecar_dir);

    // Same in_dim=1280 (2 tile640 pages) geometry as test_l5_dispatch.cpp's
    // fixture. attn_q gets a capture sidecar; ffn_down does not.
    const std::vector<std::string> names = {
        "blk.0.attn_q.weight",
        "blk.0.ffn_down.weight",
    };
    const std::vector<std::pair<int64_t, int64_t>> dims = {
        { 16, 1280 },
        { 16, 1280 },
    };
    if (!build_fixture_gguf(fixture_path, names, dims)) {
        std::printf("\nFAIL (setup)\n");
        return 1;
    }

    // Imatrix entries for BOTH tensors (bare names, no ".weight" -- see
    // build_fixture_imatrix's comment), so second_moment is populated for
    // both and the only difference between the two dispatch runs below is
    // whether attn_q's train_activations get loaded.
    {
        bool iok = build_fixture_imatrix(imatrix_path, {
            { "blk.0.attn_q",   1280, 0x1001u },
            { "blk.0.ffn_down", 1280, 0x1002u },
        });
        check("fixture imatrix write ok", iok);
    }

    // Write train (32 rows) + heldout (8 rows) sidecars for attn_q only.
    {
        auto train   = fixture_activation_data(0xACE1u, 32, 1280);
        auto heldout = fixture_activation_data(0xACE2u, 8, 1280);
        std::string err;
        bool wok = ts_activation_sidecar_write(sidecar_dir, "blk.0.attn_q.weight",
                                               ".act_train.f16", 32, 1280,
                                               train.data(), &err) == 0;
        check("sidecar train write ok", wok);
        if (!wok) std::printf("  err: %s\n", err.c_str());
        wok = ts_activation_sidecar_write(sidecar_dir, "blk.0.attn_q.weight",
                                          ".act_heldout.f16", 8, 1280,
                                          heldout.data(), &err) == 0;
        check("sidecar heldout write ok", wok);
    }

    auto make_params = [&](const char * output_path, const std::string & capture_dir) {
        ts_dispatch_params p = {};
        p.input_path        = fixture_path;
        p.output_path       = output_path;
        p.imatrix_path      = imatrix_path;
        p.policy_out_path   = std::string(output_path) + ".policy.json";
        p.evolve_seed       = 42;
        p.evolve_iters      = 4;
        p.evolve_islands    = 2;
        p.evolve_population = 8;
        p.outlier_frac      = 0.005f;
        p.awq_clip          = 0.95f;
        p.nthreads          = 1;
        p.verbose           = false;
        p.activation_capture_dir = capture_dir;
        return p;
    };

    ts_dispatch_params params_with = make_params(
        "/tmp/test_gaprep_activation_capture_output_with.gguf", sidecar_dir);
    ts_dispatch_result result_with;
    std::string err_with;
    int rc_with = ts_dispatch_run(&params_with, &result_with, &err_with);
    check("dispatch (with capture) rc == 0", rc_with == 0);
    if (rc_with != 0) std::printf("  error: %s\n", err_with.c_str());

    ts_dispatch_params params_ctrl = make_params(
        "/tmp/test_gaprep_activation_capture_output_ctrl.gguf", "");
    ts_dispatch_result result_ctrl;
    std::string err_ctrl;
    int rc_ctrl = ts_dispatch_run(&params_ctrl, &result_ctrl, &err_ctrl);
    check("dispatch (control, no capture) rc == 0", rc_ctrl == 0);
    if (rc_ctrl != 0) std::printf("  error: %s\n", err_ctrl.c_str());

    if (rc_with == 0 && rc_ctrl == 0) {
        std::printf("  total_mse: with_capture=%.8f control=%.8f\n",
                    (double)result_with.total_mse, (double)result_ctrl.total_mse);
        check("both runs quantized both tensors",
              result_with.n_tensors_quantized == 2 && result_ctrl.n_tensors_quantized == 2);
        check("activation capture changes the GA's outcome (total_mse differs)",
              std::fabs(result_with.total_mse - result_ctrl.total_mse) > 1e-9f);
    }

    if (g_fail == 0) {
        std::printf("\nPASS\n");
        return 0;
    }
    std::printf("\nFAIL (%d failures)\n", g_fail);
    return 1;
}
