//
// test_activation_sidecar.cpp
//
// Round-trip tests for tessera-activation-sidecar.{h,cpp} (pipeline
// refactor stage 2): write a known F16 matrix, read it back via
// ts_activation_sidecar_load, and confirm the shape/values survive.
// Also confirms a missing file is reported cleanly (nonzero return,
// out_data left untouched) -- the contract ts_dispatch_run_gaprep's
// stage 3 wiring relies on to fall back to the diagonal weight-space
// error for tensors with no capture data.
//
// (An in_dim-mismatch check belongs at the stage 3 call site, not
// here: this reader has no notion of what in_dim a caller expects --
// it just reports the shape actually stored in the file. Stage 3's
// wiring, which does know layer.in_dim, is where that comparison
// naturally lives.)
//

#include "tessera-activation-sidecar.h"

#include "ggml.h"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

static int g_fail = 0;

static void check(const char * name, bool ok) {
    if (!ok) {
        std::printf("FAIL %s\n", name);
        g_fail++;
    } else {
        std::printf("ok   %s\n", name);
    }
}

static const char * TEST_DIR = "/tmp/test_activation_sidecar";

int main() {
    std::filesystem::remove_all(TEST_DIR);

    const int64_t rows = 6, cols = 8;
    std::vector<float>    src_f32(rows * cols);
    std::vector<uint16_t> src_f16(rows * cols);
    for (int64_t i = 0; i < rows * cols; i++) {
        src_f32[i] = 0.1f * (float)(i % 13) - 0.5f;
        src_f16[i] = ggml_fp32_to_fp16(src_f32[i]);
    }

    // --- Test 1: round-trip a known matrix ---
    {
        std::string err;
        int wrc = ts_activation_sidecar_write(TEST_DIR, "blk.0.attn_q.weight",
                                              ".act_train.f16",
                                              rows, cols, src_f16.data(), &err);
        check("write rc == 0", wrc == 0);
        if (wrc != 0) std::printf("  err: %s\n", err.c_str());

        std::vector<float> loaded;
        int64_t out_rows = -1, out_cols = -1;
        int rrc = ts_activation_sidecar_load(TEST_DIR, "blk.0.attn_q.weight",
                                             ".act_train.f16",
                                             &loaded, &out_rows, &out_cols);
        check("load rc == 0", rrc == 0);
        check("load rows matches", out_rows == rows);
        check("load cols matches", out_cols == cols);
        check("load data size matches", (int64_t)loaded.size() == rows * cols);

        float max_abs_diff = 0.0f;
        for (int64_t i = 0; i < rows * cols && i < (int64_t)loaded.size(); i++) {
            // F16 round-trip: compare against the F16-cast of the original,
            // not the raw F32 (the sidecar's on-disk dtype is F16, so exact
            // F32 equality is not the contract -- F16 rounding is).
            const float want = ggml_fp16_to_fp32(src_f16[i]);
            const float diff = std::fabs(loaded[i] - want);
            if (diff > max_abs_diff) max_abs_diff = diff;
        }
        std::printf("  max_abs_diff (loaded vs F16-cast original) = %.3e\n", max_abs_diff);
        check("round-tripped values match F16 cast of original", max_abs_diff < 1e-6f);
    }

    // --- Test 2: missing file is reported cleanly, out_data untouched ---
    {
        std::vector<float> loaded = {1.0f, 2.0f, 3.0f};  // sentinel content
        int64_t out_rows = -1, out_cols = -1;
        int rrc = ts_activation_sidecar_load(TEST_DIR, "blk.0.does_not_exist.weight",
                                             ".act_train.f16",
                                             &loaded, &out_rows, &out_cols);
        check("missing file returns nonzero", rrc != 0);
        check("missing file leaves out_data untouched",
              loaded.size() == 3 && loaded[0] == 1.0f && loaded[1] == 2.0f && loaded[2] == 3.0f);
        check("missing file leaves out_rows/out_cols untouched",
              out_rows == -1 && out_cols == -1);
    }

    // --- Test 3: train and heldout splits are independent files for the
    // same tensor (the one-file-per-tensor-per-split layout) ---
    {
        std::vector<uint16_t> heldout_f16(3 * cols);
        for (auto & v : heldout_f16) v = ggml_fp32_to_fp16(0.25f);
        std::string err;
        int wrc = ts_activation_sidecar_write(TEST_DIR, "blk.0.attn_q.weight",
                                              ".act_heldout.f16",
                                              3, cols, heldout_f16.data(), &err);
        check("heldout write rc == 0", wrc == 0);

        std::vector<float> train_loaded, heldout_loaded;
        int64_t tr_rows = 0, tr_cols = 0, ho_rows = 0, ho_cols = 0;
        int rc1 = ts_activation_sidecar_load(TEST_DIR, "blk.0.attn_q.weight",
                                             ".act_train.f16", &train_loaded, &tr_rows, &tr_cols);
        int rc2 = ts_activation_sidecar_load(TEST_DIR, "blk.0.attn_q.weight",
                                             ".act_heldout.f16", &heldout_loaded, &ho_rows, &ho_cols);
        check("train split still loads independently", rc1 == 0 && tr_rows == rows);
        check("heldout split loads independently with its own row count",
              rc2 == 0 && ho_rows == 3 && ho_cols == cols);
        check("train and heldout contents differ",
              !train_loaded.empty() && !heldout_loaded.empty() &&
              train_loaded[0] != heldout_loaded[0]);
    }

    if (g_fail == 0) {
        std::printf("PASS\n");
        return 0;
    }
    std::printf("FAIL (%d failures)\n", g_fail);
    return 1;
}
