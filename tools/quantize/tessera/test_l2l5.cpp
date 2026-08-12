//
// test_l2l5.cpp
//
// Smoke tests for the L2-L5 runtime-aware pipeline layers using
// synthetic data:
//   L2 - weight divergence metrics, type tolerance table, flagging,
//        and JSON report round-trip.
//   L3 - per-row cosine coherence from synthetic L1 / L1.5 sidecars.
//   L5 - adaptive requantization of L2-flagged tensors.
// Returns 0 only if all checks pass.
//

#include "tessera-l2-diff.h"
#include "tessera-l3-coherence.h"
#include "tessera-l5.h"
#include "tessera-ppl.h"

#include <cmath>
#include <cstdint>
#include <vector>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
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

static void check_close(const char * name, float got, float want, float tol) {
    if (std::fabs(got - want) > tol) {
        std::printf("FAIL %-28s got %.7g want %.7g\n", name, (double)got, (double)want);
        g_fail++;
    } else {
        std::printf("ok   %-28s %.7g\n", name, (double)got);
    }
}

static const char * TEST_DIR = "/tmp/test_l2l5";

// Write a v3 TDQT sidecar with a caller-chosen suffix (matches the
// on-disk layout of the runtime hook in common/tessera-debug).
static bool write_sidecar(const std::string & name, const char * suffix,
                          int64_t rows, int64_t cols,
                          const std::vector<float> & data) {
    const std::string path = std::string(TEST_DIR) + "/" + name + suffix;
    FILE * f = fopen(path.c_str(), "wb");
    if (!f) {
        return false;
    }

    fwrite("TDQT", 1, 4, f);
    uint32_t version = 3;
    fwrite(&version, sizeof(version), 1, f);
    fwrite(&rows, sizeof(rows), 1, f);
    fwrite(&cols, sizeof(cols), 1, f);
    uint32_t dtype = 0;
    fwrite(&dtype, sizeof(dtype), 1, f);
    float outlier_threshold = 6.0f;
    fwrite(&outlier_threshold, sizeof(outlier_threshold), 1, f);
    int64_t outlier_count_total = 0;
    fwrite(&outlier_count_total, sizeof(outlier_count_total), 1, f);

    std::vector<int32_t> row_outlier_counts((size_t)rows, 0);
    fwrite(row_outlier_counts.data(), sizeof(int32_t), (size_t)rows, f);

    uint8_t row_meta[24];
    memset(row_meta, 0, sizeof(row_meta));
    for (int64_t r = 0; r < rows; r++) {
        fwrite(row_meta, 1, 24, f);
    }

    fwrite(data.data(), sizeof(float), data.size(), f);
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// L2
// ---------------------------------------------------------------------------

static void test_l2() {
    std::printf("--- L2 ---\n");

    // bf16 weights and a quantized reconstruction scaled by (1 + eps).
    // diff = bf16 * eps  =>  relative_frobenius = eps^2 exactly.
    const int64_t n = 64;
    std::vector<float> bf16((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        bf16[(size_t)i] = 1.0f + 0.1f * (float)(i % 5);
    }

    const float eps_bad  = 0.2f;   // rel_frob = 0.04 > 3e-2 (t640) -> flagged
    const float eps_good = 0.1f;   // rel_frob = 0.01 < 3e-2        -> ok
    std::vector<float> quant_bad((size_t)n);
    std::vector<float> quant_good((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        quant_bad[(size_t)i]  = bf16[(size_t)i] * (1.0f + eps_bad);
        quant_good[(size_t)i] = bf16[(size_t)i] * (1.0f + eps_good);
    }

    // --- core metrics ---
    ts_l2_divergence d_bad = ts_l2_tensor_divergence(bf16.data(), quant_bad.data(), n);
    check_close("l2 rel_frob == eps^2", d_bad.relative_frobenius, eps_bad * eps_bad, 1e-5f);
    check("l2 max_abs > 0", d_bad.max_abs > 0.0f);
    check("l2 mean_abs > 0", d_bad.mean_abs > 0.0f);
    check("l2 per_layer_norm > 0", d_bad.per_layer_norm > 0.0f);

    // identical buffers -> zero divergence
    ts_l2_divergence d_zero = ts_l2_tensor_divergence(bf16.data(), bf16.data(), n);
    check_close("l2 self rel_frob == 0", d_zero.relative_frobenius, 0.0f, 1e-9f);
    check_close("l2 self max_abs == 0", d_zero.max_abs, 0.0f, 1e-9f);

    // --- tolerance table ---
    check_close("l2 tol f16",  ts_l2_expected_frob("f16"),          1e-5f, 1e-9f);
    check_close("l2 tol q8_0", ts_l2_expected_frob("q8_0"),         1e-3f, 1e-9f);
    check_close("l2 tol q4_k", ts_l2_expected_frob("q4_k"),         5e-2f, 1e-9f);
    check_close("l2 tol t640", ts_l2_expected_frob("tessera_t640"), 2e-2f, 1e-9f);

    // --- L2 activation-space differential (v3.1 spec §4) ---
    // Synthetic matmul outputs: 4 samples x 8 out_dim. Each row is a
    // softmax-shaped distribution (one hot max + small noise) so the
    // argmax is unambiguous. y_ref has the max at index 2 for all
    // rows; y_quant has the max at index 5 for the first two rows
    // (mismatch) and at index 2 for the last two (match).
    {
        const int64_t n_samples = 4;
        const int64_t out_dim   = 8;
        std::vector<float> y_ref((size_t) (n_samples * out_dim), 0.05f);
        std::vector<float> y_quant((size_t) (n_samples * out_dim), 0.05f);
        // Set up distinct argmax positions so the argmax is deterministic.
        for (int64_t r = 0; r < n_samples; r++) {
            for (int64_t c = 0; c < out_dim; c++) {
                y_ref[(size_t) (r * out_dim + c)]   = 0.05f + 0.001f * (float) c;
                y_quant[(size_t) (r * out_dim + c)] = 0.05f + 0.001f * (float) c;
            }
            y_ref[(size_t)   (r * out_dim + 2)]   = 0.99f;  // argmax at 2
            y_quant[(size_t) (r * out_dim + 5)]   = 0.99f;  // argmax at 5
        }
        // Restore the first two rows' y_quant to also have argmax at 2
        // (so the mismatch count is 2/4 = 0.5).
        y_quant[(size_t) (2 * out_dim + 5)]   = 0.05f + 0.001f * 5.0f;
        y_quant[(size_t) (2 * out_dim + 2)]   = 0.99f;
        y_quant[(size_t) (3 * out_dim + 5)]   = 0.05f + 0.001f * 5.0f;
        y_quant[(size_t) (3 * out_dim + 2)]   = 0.99f;

        ts_l2_act_divergence d = ts_l2_compute_act_diff(
            y_ref.data(), y_quant.data(), n_samples, out_dim);
        check("act n_samples == 4", d.n_samples == 4);
        check_close("act top1_mismatch == 0.5", d.top1_mismatch, 0.5f, 1e-6f);
        check("act relative_frobenius > 0", d.relative_frobenius > 0.0f);
        std::printf("     act_l2_frob=%.6g  top1_mismatch=%.4g  n_samples=%lld\n",
                    (double) d.relative_frobenius, (double) d.top1_mismatch,
                    (long long) d.n_samples);

        // Identical inputs: Frobenius = 0, top1_mismatch = 0.
        ts_l2_act_divergence d_identical = ts_l2_compute_act_diff(
            y_ref.data(), y_ref.data(), n_samples, out_dim);
        check_close("act identical: relative_frobenius == 0",
                    d_identical.relative_frobenius, 0.0f, 1e-9f);
        check_close("act identical: top1_mismatch == 0",
                    d_identical.top1_mismatch, 0.0f, 1e-9f);
        check("act identical: n_samples == 4", d_identical.n_samples == 4);

        // Zero reference: degenerate case, frob == TS_L2_INF. The
        // top1_mismatch is well-defined but is determined by the
        // argmax of the zero row (always index 0) vs the argmax of
        // y_quant (which has a peak at index 2 in our fixture), so
        // the mismatch is 1.0 in this setup, not 0.
        std::vector<float> y_zero((size_t) (n_samples * out_dim), 0.0f);
        ts_l2_act_divergence d_zero = ts_l2_compute_act_diff(
            y_zero.data(), y_ref.data(), n_samples, out_dim);
        check("act zero ref: relative_frobenius == TS_L2_INF",
              d_zero.relative_frobenius >= 1e20f);
        check("act zero ref: top1_mismatch == 1.0 (zero argmax != y_quant argmax)",
              d_zero.top1_mismatch == 1.0f);

        // Single-sample single-column: degenerate shape, no NaN/Inf.
        // (0.5 - 0.4)^2 / 0.5^2 = 0.01 / 0.25 = 0.04
        std::vector<float> y1_ref(1,  0.5f);
        std::vector<float> y1_qt(1,  0.4f);
        ts_l2_act_divergence d1 = ts_l2_compute_act_diff(
            y1_ref.data(), y1_qt.data(), 1, 1);
        check("act 1x1: n_samples == 1", d1.n_samples == 1);
        check_close("act 1x1: relative_frobenius == 0.04",
                    d1.relative_frobenius, 0.04f, 1e-5f);
        check_close("act 1x1: top1_mismatch == 0",
                    d1.top1_mismatch, 0.0f, 1e-9f);

        // Null pointer / zero size: returns zeros.
        ts_l2_act_divergence d_null = ts_l2_compute_act_diff(
            nullptr, y_ref.data(), n_samples, out_dim);
        check("act nullptr y_ref: relative_frobenius == 0",
              d_null.relative_frobenius == 0.0f);
        check("act nullptr y_ref: top1_mismatch == 0",
              d_null.top1_mismatch == 0.0f);
        check("act nullptr y_ref: n_samples == 0", d_null.n_samples == 0);

        ts_l2_act_divergence d_zero_size = ts_l2_compute_act_diff(
            y_ref.data(), y_quant.data(), 0, 0);
        check("act 0x0: relative_frobenius == 0",
              d_zero_size.relative_frobenius == 0.0f);
        check("act 0x0: top1_mismatch == 0",
              d_zero_size.top1_mismatch == 0.0f);
    }

    // --- L3 KL divergence + four-forward attribution (v3.1 spec §6) ---
    {
        // KL(P || Q) for two simple distributions.
        const int64_t vocab = 4;
        float p[4] = { 0.5f, 0.3f, 0.15f, 0.05f };
        float q[4] = { 0.5f, 0.3f, 0.15f, 0.05f };  // identical
        const float kl_identical = ts_l3_kl_divergence(p, q, vocab);
        check_close("kl identical == 0", kl_identical, 0.0f, 1e-6f);

        // P different from Q: positive KL.
        float p2[4]  = { 0.7f, 0.2f, 0.05f, 0.05f };
        float q2[4]  = { 0.25f, 0.25f, 0.25f, 0.25f };
        const float kl_pq = ts_l3_kl_divergence(p2, q2, vocab);
        check("kl(p2 || q2) > 0", kl_pq > 0.0f);
        // P close to Q: small KL.
        float p_close[4] = { 0.51f, 0.29f, 0.15f, 0.05f };
        const float kl_close = ts_l3_kl_divergence(p_close, q, vocab);
        check("kl close to identical < kl(p2 || q2)",
              kl_close < kl_pq);

        // P == all-zero: degenerate, returns 0.
        float p_zero[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        const float kl_zero = ts_l3_kl_divergence(p_zero, q, vocab);
        check_close("kl zero P == 0", kl_zero, 0.0f, 1e-9f);

        // Q has a near-zero entry: smoothed by eps, no NaN/Inf.
        float q_tiny[4] = { 0.5f, 0.5f - 1e-15f, 0.0f, 0.0f + 1e-15f };
        const float kl_tiny = ts_l3_kl_divergence(p, q_tiny, vocab);
        check("kl with near-zero Q entries is finite",
              std::isfinite(kl_tiny));

        // Per-position breakdown.
        std::vector<float> per_pos((size_t) vocab, 0.0f);
        const float kl_breakdown = ts_l3_kl_divergence(
            p, q, vocab, 1e-10f, per_pos.data());
        double sum_per_pos = 0.0;
        for (int64_t i = 0; i < vocab; i++) {
            sum_per_pos += (double) per_pos[(size_t) i];
        }
        check_close("kl per_pos sum == kl scalar",
                    (float) sum_per_pos, kl_breakdown, 1e-5f);

        // --- four-forward attribution ---
        // OK: all three curves below joint_eps.
        {
            const int64_t n_layers = 4;
            std::vector<float> joint_curve (n_layers, 0.05f);
            std::vector<float> weight_curve(n_layers, 0.02f);
            std::vector<float> kv_curve    (n_layers, 0.01f);
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                joint_curve.data(), weight_curve.data(), kv_curve.data(),
                n_layers, 0.1f);
            check("attr OK: attribution == OK", s.attribution == TS_L3_ATTR_OK);
            check_close("attr OK: coupling_ratio", s.coupling_ratio, 0.05f / 0.02f, 1e-3f);
            check("attr OK: compounding_layer == -1", s.compounding_layer == -1);
        }
        // COMPOUNDING: joint >> max(weight, kv), with the components
        // both above eps (so the NUMERICAL test, which requires both
        // components below eps, does not preempt).
        {
            const int64_t n_layers = 4;
            std::vector<float> joint_curve (n_layers, 0.5f);
            std::vector<float> weight_curve(n_layers, 0.15f);
            std::vector<float> kv_curve    (n_layers, 0.15f);
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                joint_curve.data(), weight_curve.data(), kv_curve.data(),
                n_layers, 0.1f);
            check("attr COMPOUNDING: attribution", s.attribution == TS_L3_ATTR_COMPOUNDING);
            check_close("attr COMPOUNDING: coupling_ratio == 3.33",
                        s.coupling_ratio, 0.5f / 0.15f, 1e-3f);
            check("attr COMPOUNDING: compounding_layer == 0",
                  s.compounding_layer == 0);
        }
        // WEIGHT: joint ~ max(weight, kv), weight > kv.
        {
            const int64_t n_layers = 4;
            std::vector<float> joint_curve (n_layers, 0.3f);
            std::vector<float> weight_curve(n_layers, 0.25f);
            std::vector<float> kv_curve    (n_layers, 0.05f);
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                joint_curve.data(), weight_curve.data(), kv_curve.data(),
                n_layers, 0.1f);
            check("attr WEIGHT: attribution", s.attribution == TS_L3_ATTR_WEIGHT);
            check("attr WEIGHT: coupling_ratio < 2.0", s.coupling_ratio < 2.0f);
        }
        // KV: joint ~ max(weight, kv), kv > weight.
        {
            const int64_t n_layers = 4;
            std::vector<float> joint_curve (n_layers, 0.3f);
            std::vector<float> weight_curve(n_layers, 0.05f);
            std::vector<float> kv_curve    (n_layers, 0.25f);
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                joint_curve.data(), weight_curve.data(), kv_curve.data(),
                n_layers, 0.1f);
            check("attr KV: attribution", s.attribution == TS_L3_ATTR_KV);
        }
        // NUMERICAL: joint > eps, both components below eps.
        {
            const int64_t n_layers = 4;
            std::vector<float> joint_curve (n_layers, 0.2f);
            std::vector<float> weight_curve(n_layers, 0.0f);
            std::vector<float> kv_curve    (n_layers, 0.0f);
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                joint_curve.data(), weight_curve.data(), kv_curve.data(),
                n_layers, 0.1f);
            check("attr NUMERICAL: attribution",
                  s.attribution == TS_L3_ATTR_NUMERICAL);
        }
        // Compounding layer: only the 3rd layer is compounding.
        {
            const int64_t n_layers = 5;
            std::vector<float> joint_curve = { 0.05f, 0.05f, 0.5f, 0.5f, 0.5f };
            std::vector<float> weight_curve(n_layers, 0.15f);
            std::vector<float> kv_curve    (n_layers, 0.15f);
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                joint_curve.data(), weight_curve.data(), kv_curve.data(),
                n_layers, 0.1f);
            check("attr late compounding: attribution",
                  s.attribution == TS_L3_ATTR_COMPOUNDING);
            check("attr late compounding: layer == 2",
                  s.compounding_layer == 2);
        }
        // Null joint curve: zero summary.
        {
            ts_l3_attribution_summary s = ts_l3_attribute_drift(
                nullptr, nullptr, nullptr, 0, 0.1f);
            check("attr null: attribution == OK", s.attribution == TS_L3_ATTR_OK);
            check("attr null: compounding_layer == -1", s.compounding_layer == -1);
        }
    }

    // --- run + flagging ---
    ts_l2_config cfg;
    ts_l2_default_config(&cfg);
    std::snprintf(cfg.output_json_path, sizeof(cfg.output_json_path),
                  "%s/l2_report.json", TEST_DIR);
    check("l2 default multiplier", cfg.flag_multiplier == 1.5f);

    ts_l2_tensor_input inputs[2];
    inputs[0] = { "blk.0.attn_q.weight", "tessera_t640", 8, 8, bf16.data(), quant_bad.data() };
    inputs[1] = { "blk.1.attn_q.weight", "tessera_t640", 8, 8, bf16.data(), quant_good.data() };

    ts_l2_report report;
    int n_flagged = ts_l2_run(&cfg, inputs, 2, &report);
    check("l2 run flagged == 1", n_flagged == 1);
    check("l2 report n_flagged == 1", report.n_flagged == 1);
    check("l2 bad tensor flagged", report.tensors[0].flagged);
    check("l2 good tensor not flagged", !report.tensors[1].flagged);
    check_close("l2 flag threshold", report.tensors[0].flag_threshold, 1.5f * 2e-2f, 1e-9f);

    // --- JSON round-trip ---
    ts_l2_report loaded;
    int lrc = ts_l2_load_report(cfg.output_json_path, &loaded);
    check("l2 load rc == 0", lrc == 0);
    check("l2 round-trip n_flagged", loaded.n_flagged == 1);
    check("l2 round-trip n_tensors", loaded.tensors.size() == 2);
    check("l2 round-trip name", loaded.tensors[0].tensor_name == "blk.0.attn_q.weight");
    check_close("l2 round-trip rel_frob",
                loaded.tensors[0].divergence.relative_frobenius,
                report.tensors[0].divergence.relative_frobenius, 1e-6f);
    check("l2 round-trip flagged", loaded.tensors[0].flagged);
    check("l2 round-trip rows", loaded.tensors[0].rows == 8);

    // --- L5 consumes the loaded report: flagged tensor gets tightened ---
    std::printf("--- L5 ---\n");
    ts_l5_adaptive_params ap;
    ts_l5_adaptive_default_params(&ap);
    check("l5 default alpha_scale", ap.alpha_scale == 0.5f);

    ts_l5_adaptive_plan plan;
    int n_req = ts_l5_adaptive_requant(&loaded, &ap, 1, &plan);
    check("l5 n_requant == 1", n_req == 1);
    check("l5 plan n_requant", plan.n_requant == 1);
    check("l5 generation", plan.generation == 1);
    check("l5 spec name", plan.specs[0].tensor_name == "blk.0.attn_q.weight");

    // overshoot = 0.04 / 0.02 = 2.0 -> new_alpha = 0.5 / 2.0 = 0.25
    check_close("l5 overshoot", plan.specs[0].overshoot, 2.0f, 1e-4f);
    check_close("l5 new_alpha tightened", plan.specs[0].new_alpha, 0.25f, 1e-4f);
    check_close("l5 new_clip tightened", plan.specs[0].new_clip, 0.25f, 1e-4f);
    check("l5 alpha reduced", plan.specs[0].new_alpha < ap.alpha_scale);

    // larger overshoot -> smaller alpha (monotonic tightening)
    ts_l2_report worse = loaded;
    worse.tensors[0].divergence.relative_frobenius = 0.10f;  // overshoot 5.0
    ts_l5_adaptive_plan plan2;
    ts_l5_adaptive_requant(&worse, &ap, 2, &plan2);
    check("l5 worse -> smaller alpha",
          plan2.specs[0].new_alpha < plan.specs[0].new_alpha);
    check_close("l5 worse alpha == 0.5/5", plan2.specs[0].new_alpha, 0.1f, 1e-4f);

    // null report -> empty plan, not an error
    ts_l5_adaptive_plan empty;
    check("l5 null report rc == 0", ts_l5_adaptive_requant(nullptr, &ap, 0, &empty) == 0);
    check("l5 null report empty", empty.n_requant == 0);
}

// ---------------------------------------------------------------------------
// L3
// ---------------------------------------------------------------------------

static void test_l3() {
    std::printf("--- L3 ---\n");

    // --- row cosine primitives ---
    float a[4] = { 1.0f, 2.0f, 3.0f, 4.0f };
    check_close("l3 cosine identical", ts_l3_row_cosine(a, a, 4), 1.0f, 1e-6f);

    float x[4] = { 1.0f, 0.0f, 0.0f, 0.0f };
    float y[4] = { 0.0f, 1.0f, 0.0f, 0.0f };
    check_close("l3 cosine orthogonal", ts_l3_row_cosine(x, y, 4), 0.0f, 1e-6f);

    float z[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    check_close("l3 cosine both zero", ts_l3_row_cosine(z, z, 4), 1.0f, 1e-6f);
    check_close("l3 cosine one zero", ts_l3_row_cosine(x, z, 4), 0.0f, 1e-6f);

    // --- tensor coherence on buffers ---
    const int64_t rows = 4;
    const int64_t cols = 8;
    std::vector<float> l1((size_t)(rows * cols));
    std::vector<float> ref((size_t)(rows * cols));
    for (int64_t r = 0; r < rows; r++) {
        for (int64_t c = 0; c < cols; c++) {
            float v = (float)(r + 1) + 0.1f * (float)c;
            ref[(size_t)(r * cols + c)] = v;
            l1[(size_t)(r * cols + c)]  = v;   // rows 0..2 identical below
        }
    }
    // make row 3 orthogonal to its reference
    for (int64_t c = 0; c < cols; c++) {
        ref[(size_t)(3 * cols + c)] = (c == 0) ? 1.0f : 0.0f;
        l1[(size_t)(3 * cols + c)]  = (c == 1) ? 1.0f : 0.0f;
    }

    ts_l3_tensor_result tr;
    tr.tensor_name = "synthetic";
    int crc = ts_l3_tensor_coherence(l1.data(), ref.data(), rows, cols, 0.99f, &tr);
    check("l3 coherence rc == 0", crc == 0);
    check("l3 flagged one row", tr.n_flagged == 1);
    check("l3 flagged row is 3",
          tr.flagged_rows.size() == 1 && tr.flagged_rows[0] == 3);
    check_close("l3 min_cosine == 0", tr.min_cosine, 0.0f, 1e-6f);
    check_close("l3 mean_cosine == 0.75", tr.mean_cosine, 0.75f, 1e-6f);

    // --- run over sidecars ---
    // tensor_full has both an L1 and an L1.5 sidecar; tensor_noref has
    // only an L1 sidecar and must be skipped.
    check("l3 write L1 sidecar",
          write_sidecar("tensor_full", ".dequant.f32", rows, cols, l1));
    check("l3 write L1.5 sidecar",
          write_sidecar("tensor_full", ".act.dequant.f32", rows, cols, ref));
    check("l3 write L1-only sidecar",
          write_sidecar("tensor_noref", ".dequant.f32", rows, cols, l1));

    ts_l3_config cfg;
    ts_l3_default_config(&cfg);
    std::snprintf(cfg.sidecar_dir,   sizeof(cfg.sidecar_dir),   "%s", TEST_DIR);
    std::snprintf(cfg.reference_dir, sizeof(cfg.reference_dir), "%s", TEST_DIR);
    check("l3 default threshold", cfg.threshold == 0.99f);

    const char * names[2] = { "tensor_full", "tensor_noref" };
    ts_l3_report report;
    int n_proc = ts_l3_run(&cfg, names, 2, &report);
    check("l3 run processed == 1", n_proc == 1);
    check("l3 report n_tensors == 1", report.n_tensors == 1);
    check("l3 report flagged rows == 1", report.n_flagged_rows == 1);
    check("l3 processed tensor_full",
          report.tensors.size() == 1 && report.tensors[0].tensor_name == "tensor_full");
    check("l3 run flagged row 3",
          report.tensors[0].flagged_rows.size() == 1 &&
          report.tensors[0].flagged_rows[0] == 3);
}

// ---------------------------------------------------------------------------
// L4
// ---------------------------------------------------------------------------

static const int64_t L4_V = 64;   // vocab
static const int64_t L4_T = 16;   // tokens

static void l4_forward_uniform(const int32_t * /*tokens*/, float * logits_out,
                               int64_t n_tokens, int64_t vocab_size,
                               void * /*ctx*/) {
    for (int64_t i = 0; i < n_tokens * vocab_size; i++) {
        logits_out[i] = 1.0f;
    }
}

static void l4_forward_peaked(const int32_t * /*tokens*/, float * logits_out,
                              int64_t n_tokens, int64_t vocab_size,
                              void * /*ctx*/) {
    // sharply peaked on token 0: nearly every random target is "wrong",
    // so PPL is reliably far above the uniform reference (seed-independent).
    for (int64_t t = 0; t < n_tokens; t++) {
        for (int64_t i = 0; i < vocab_size; i++) {
            logits_out[t * vocab_size + i] = (i == 0) ? 20.0f : 0.0f;
        }
    }
}

static void test_l4() {
    std::printf("--- L4 ---\n");

    ts_ppl_params params = {};
    params.n_tokens   = L4_T;
    params.vocab_size = L4_V;
    params.use_kl     = true;
    params.seed       = 7;

    // identical models -> zero delta / KL, ratio 1, passes default 0.5
    ts_ppl_compare_result same = {};
    int rc_same = ts_ppl_compare(l4_forward_uniform, nullptr,
                                 l4_forward_uniform, nullptr,
                                 &params, 0.0f, &same);
    check("l4 compare rc == 0", rc_same == 0);
    check_close("l4 identical delta == 0", same.delta_ppl, 0.0f, 1e-3f);
    check_close("l4 identical kl == 0", same.kl_divergence, 0.0f, 1e-6f);
    check_close("l4 identical ratio == 1", same.ppl_ratio, 1.0f, 1e-4f);
    check("l4 default threshold == 0.5", same.threshold == 0.5f);
    check("l4 identical passes", same.pass);
    check("l4 n_tokens_used", same.n_tokens_used == L4_T);

    // peaked quant model -> reliably worse: positive delta, ratio > 1, KL > 0
    ts_ppl_compare_result diff = {};
    int rc_diff = ts_ppl_compare(l4_forward_uniform, nullptr,
                                 l4_forward_peaked, nullptr,
                                 &params, 0.5f, &diff);
    check("l4 peaked rc == 0", rc_diff == 0);
    check("l4 peaked delta > 0", diff.delta_ppl > 0.0f);
    check("l4 peaked kl > 0", diff.kl_divergence > 0.0f);
    check("l4 peaked ratio > 1", diff.ppl_ratio > 1.0f);
    check("l4 peaked fails default 0.5", !diff.pass);

    // verdict tracks the threshold relative to the observed delta
    // (multiplicative margin: delta is ~1e8 here, so an additive +1 would
    // be lost to float rounding)
    ts_ppl_compare_result loose = {};
    ts_ppl_compare(l4_forward_uniform, nullptr,
                   l4_forward_peaked, nullptr,
                   &params, diff.delta_ppl * 2.0f, &loose);
    check("l4 loose threshold passes", loose.pass);

    // null forwards rejected
    ts_ppl_compare_result bad = {};
    check("l4 null reject",
          ts_ppl_compare(nullptr, nullptr, nullptr, nullptr, &params, 0.5f, &bad) == -1);
}

int main() {
    std::filesystem::create_directories(TEST_DIR);

    test_l2();
    test_l3();
    test_l4();

    std::filesystem::remove_all(TEST_DIR);

    if (g_fail == 0) {
        std::printf("PASS\n");
        return 0;
    }
    std::printf("%d FAILURES\n", g_fail);
    return 1;
}
