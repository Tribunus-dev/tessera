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
#include "tessera-linalg.h"
#include "tessera-ppl.h"

#include <cmath>
#include <cstdint>
#include <string>
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
// on-disk layout of the runtime hook in common/tessera-debug). Emits
// the full v3 header including the 16-byte FP env block (spec §2.3,
// PR #8); a pre-PR-#8 reader that doesn't know about the FP env
// would rewind 16 bytes and read the file at the legacy 40-byte
// offset.
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

    // FP env block (v3.1 spec §2.3): 16 bytes. Defaults match the
    // v3 zero-init contract: F32 accumulator, RTN rounding, IEEE
    // denormals, CPU backend.
    uint32_t fp_accumulator_dtype = 0;   // F32
    uint32_t rounding_mode        = 0;   // RTN
    uint32_t denormal_mode        = 0;   // IEEE
    uint32_t backend_id           = 0;   // CPU
    fwrite(&fp_accumulator_dtype, sizeof(fp_accumulator_dtype), 1, f);
    fwrite(&rounding_mode,        sizeof(rounding_mode),        1, f);
    fwrite(&denormal_mode,        sizeof(denormal_mode),        1, f);
    fwrite(&backend_id,           sizeof(backend_id),           1, f);

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

    // --- L4 spec telemetry (v3.1 spec §8) ---
    {
        // Build a 5-step x 8-layer spec telemetry fixture. The
        // per-step data simulates a drafter that loses acceptance
        // at layer 4 (the spec's "Layer 4 symptom" case): 4 of 5
        // steps have first_reject_layer == 4, one is all-accept.
        const int64_t n_steps  = 5;
        const int64_t n_layers = 8;
        std::vector<std::vector<float>> per_layer_alpha(n_steps, std::vector<float>(n_layers, 0.0f));
        std::vector<std::vector<float>> per_layer_kl   (n_steps, std::vector<float>(n_layers, 0.0f));
        // Step 0: all-accept (high alpha across all layers).
        per_layer_alpha[0] = { 0.95f, 0.94f, 0.92f, 0.90f, 0.88f, 0.85f, 0.83f, 0.80f };
        // Steps 1-4: drop at layer 4 (the systematic reject).
        for (int64_t s = 1; s < n_steps; s++) {
            per_layer_alpha[(size_t) s] = { 0.95f, 0.94f, 0.92f, 0.90f, 0.30f, 0.85f, 0.83f, 0.80f };
        }
        std::vector<ts_l4_spec_step> steps((size_t) n_steps);
        for (int64_t s = 0; s < n_steps; s++) {
            steps[(size_t) s].step_idx            = s;
            steps[(size_t) s].n_drafted           = 5;
            steps[(size_t) s].accepted_count     = (s == 0) ? 5 : 1;  // step 0 all-accept
            steps[(size_t) s].first_reject_layer = (s == 0) ? -1 : 4;
            steps[(size_t) s].per_layer_alpha    = per_layer_alpha[(size_t) s].data();
            steps[(size_t) s].per_layer_kl       = per_layer_kl[(size_t) s].data();
            steps[(size_t) s].n_layers           = n_layers;
        }

        // Aggregate + histogram.
        ts_l4_spec_summary summary = {};
        std::vector<int64_t> histograms((size_t) n_layers, 0);
        int rc = ts_l4_compute_spec_telemetry(
            steps.data(), n_steps, n_layers, /*n_drafters=*/1,
            &summary, histograms.data());
        check("l4_spec rc == 0", rc == 0);
        check("l4_spec n_steps == 5", summary.n_steps == 5);
        check("l4_spec n_total_drafted == 25", summary.n_total_drafted == 25);
        check("l4_spec n_total_accepted == 9", summary.n_total_accepted == 9);
        check("l4_spec n_steps_with_reject == 4", summary.n_steps_with_reject == 4);
        // overall_alpha = 9/25 = 0.36 (below 0.50 threshold).
        check_close("l4_spec overall_alpha == 0.36",
                    summary.overall_alpha, 0.36f, 1e-5f);
        // Histogram mode at layer 4 (4 steps reject there).
        check("l4_spec first_reject_layer_peak == 4",
              summary.first_reject_layer_peak == 4);
        // Per-layer histogram bin counts.
        check("l4_spec histograms[4] == 4", histograms[4] == 4);
        check("l4_spec histograms[0] == 0", histograms[0] == 0);

        // Flag verdict: trips on the mid-stack reject peak (4 in {1..5})
        // and ALSO on the overall alpha (0.36 < 0.50). The
        // function returns the first trip in priority order; the
        // overall_alpha is checked first.
        const float per_layer_alpha_mean[8] = {
            0.95f, 0.94f, 0.92f, 0.90f, 0.42f, 0.85f, 0.83f, 0.80f
        };
        ts_l4_spec_flag_result flag = ts_l4_spec_flag(
            &summary, per_layer_alpha_mean, n_layers);
        check("l4_spec flag: NOT pass (overall_alpha low)", !flag.pass);
        check("l4_spec flag: reason == low_overall_alpha",
              std::string(flag.reason) == "low_overall_alpha");

        // Make a passing summary: bump the overall alpha to 0.55.
        // Keep the mid-stack drop intact (we WANT to verify the
        // mid-stack peak check fires when overall_alpha is OK).
        for (int64_t s = 1; s < n_steps; s++) {
            // Each non-zero step: 3 accepted out of 5 (instead of 1).
            // total accepted = 5 + 4*3 = 17; total drafted = 25;
            // overall_alpha = 17/25 = 0.68.
            steps[(size_t) s].accepted_count = 3;
        }
        ts_l4_compute_spec_telemetry(
            steps.data(), n_steps, n_layers, 1, &summary, histograms.data());
        check_close("l4_spec passing overall_alpha == 0.68",
                    summary.overall_alpha, 0.68f, 1e-5f);
        // The per-layer alpha mid (layer 4) is still ~0.42 (below
        // 0.40? no, 0.42 > 0.40 so this criterion is OK), but the
        // peak is still at layer 4, so the mid-stack reject peak
        // trips.
        flag = ts_l4_spec_flag(&summary, per_layer_alpha_mean, n_layers);
        check("l4_spec flag: NOT pass (mid-stack peak)",
              !flag.pass);
        check("l4_spec flag: reason == mid_stack_reject_peak",
              std::string(flag.reason) == "mid_stack_reject_peak");

        // Fix the mid-stack peak: spread the rejects across
        // different layers so the mode is at the boundary or
        // above.
        steps[1].first_reject_layer = 7;  // late reject
        steps[2].first_reject_layer = 6;
        steps[3].first_reject_layer = 7;
        steps[4].first_reject_layer = 6;
        ts_l4_compute_spec_telemetry(
            steps.data(), n_steps, n_layers, 1, &summary, histograms.data());
        check("l4_spec peak NOT in {1..5}",
              summary.first_reject_layer_peak < 1 || summary.first_reject_layer_peak > 5);
        // The mid-stack drop is still 0.42 (below 0.40? no, 0.42
        // > 0.40). Actually 0.42 is above 0.40 so the mid-stack
        // drop test passes. But the per_layer_alpha_mid in the
        // flag struct reads the input array; we set the mean
        // explicitly to test the threshold.
        const float per_layer_alpha_drop[8] = {
            0.95f, 0.94f, 0.92f, 0.90f, 0.30f, 0.85f, 0.83f, 0.80f
        };
        flag = ts_l4_spec_flag(&summary, per_layer_alpha_drop, n_layers);
        check("l4_spec flag: NOT pass (mid-stack drop)",
              !flag.pass);
        check("l4_spec flag: reason == mid_stack_alpha_drop",
              std::string(flag.reason) == "mid_stack_alpha_drop");
        check_close("l4_spec flag: per_layer_alpha_mid == 0.30",
                    flag.per_layer_alpha_mid, 0.30f, 1e-5f);

        // Passing flag: peak NOT in {1..5}, alpha_mid >= 0.40,
        // overall_alpha >= 0.50.
        const float per_layer_alpha_ok[8] = {
            0.95f, 0.94f, 0.92f, 0.90f, 0.55f, 0.85f, 0.83f, 0.80f
        };
        flag = ts_l4_spec_flag(&summary, per_layer_alpha_ok, n_layers);
        check("l4_spec flag: pass", flag.pass);
        check("l4_spec flag: reason == OK", std::string(flag.reason) == "OK");

        // Null summary: pass with reason "OK".
        flag = ts_l4_spec_flag(nullptr, nullptr, 0);
        check("l4_spec null summary: pass", flag.pass);

        // n_steps = 0: returns zero summary, no flag checks fire.
        ts_l4_spec_summary zero = {};
        rc = ts_l4_compute_spec_telemetry(
            steps.data(), 0, n_layers, 1, &zero, nullptr);
        check("l4_spec n_steps=0: rc == 0", rc == 0);
        check("l4_spec n_steps=0: n_steps == 0", zero.n_steps == 0);
        check("l4_spec n_steps=0: overall_alpha == 0",
              zero.overall_alpha == 0.0f);
        check("l4_spec n_steps=0: peak == -1",
              zero.first_reject_layer_peak == -1);

        // Shape mismatch (per-step n_layers != top-level n_layers):
        // returns -1.
        ts_l4_spec_step bad_step = steps[0];
        bad_step.n_layers = n_layers + 1;
        std::vector<ts_l4_spec_step> one_step(1, bad_step);
        rc = ts_l4_compute_spec_telemetry(
            one_step.data(), 1, n_layers, 1, &summary, nullptr);
        check("l4_spec shape mismatch: rc == -1", rc == -1);
    }

    // --- L2 spectral metrics (v3.1 spec §5) ---
    {
        // Identity matrix: full rank, spectral_norm = 1, erank = n.
        const int64_t m = 4, n = 4, k = 4;
        std::vector<float> I((size_t) (m * n), 0.0f);
        for (int64_t i = 0; i < m; i++) I[(size_t) (i * n + i)] = 1.0f;
        ts_l2_spectral_metrics s_id = ts_l2_compute_spectral_metrics(
            I.data(), m, n, k, /*n_singular_values=*/0, /*n_iters=*/100, 42);
        check("spec identity: spectral_norm ~= 1",
              std::fabs(s_id.spectral_norm - 1.0f) < 1e-3f);
        check("spec identity: erank ~= n", std::fabs(s_id.erank - (float) n) < 1e-2f);
        check("spec identity: top_k_concentration == 1.0",
              s_id.top_k_concentration > 0.99f);

        // Rank-1 matrix: spectral_norm = ||u||*||v||, erank ~= 1.
        // A = u v^T where u = [1;2;3] and v = [1;2;3] (a column
        // times a row). The spectral norm of an outer product is
        // ||u|| * ||v|| = sqrt(14) * sqrt(14) = 14.
        // Build A = [1 2 3; 2 4 6; 3 6 9] (rank 1, sigma_1 = 14).
        const int64_t m2 = 3, n2 = 3, k2 = 2;
        std::vector<float> A = { 1, 2, 3,  2, 4, 6,  3, 6, 9 };
        ts_l2_spectral_metrics s_r1 = ts_l2_compute_spectral_metrics(
            A.data(), m2, n2, k2, 0, 100, 42);
        // Spectral norm: sigma_1 = 14 (the outer product norm).
        check_close("spec rank-1: spectral_norm == 14",
                    s_r1.spectral_norm, 14.0f, 1e-2f);
        // Erank is between 1 and 2 (the second singular value is
        // 0 in exact math but the power iteration picks up some
        // numerical noise; we just check it's small).
        check("spec rank-1: erank < 2", s_r1.erank < 2.0f);
        check("spec rank-1: erank >= 1", s_r1.erank >= 1.0f);
        // top_k_concentration for k=2 should be very close to 1.0
        // (the first SV is dominant).
        check("spec rank-1: top_k_concentration ~= 1",
              s_r1.top_k_concentration > 0.99f);

        // Drop computation: Y_ref has full rank, Y_quant is rank-1.
        std::vector<float> Y_quant_r1 = A;  // rank-1
        ts_l2_spectral_metrics s_drop = ts_l2_compute_spectral_drop(
            I.data(), Y_quant_r1.data(), 3, 3, 2, 0, 100, 42);
        check("spec drop: erank_drop > 0", s_drop.erank_drop > 0.0f);
        check("spec drop: top_k_concentration_drop > 0 (quant has more concentrated spectrum)",
              s_drop.top_k_concentration_drop > 0.0f);

        // Flag verdict.
        bool flagged = ts_l2_spectral_flagged(&s_drop);
        check("spec drop: flagged (erank_drop > 0.1 * ref_erank)", flagged);

        // Identical matrices: drops are 0, NOT flagged.
        ts_l2_spectral_metrics s_none = ts_l2_compute_spectral_drop(
            I.data(), I.data(), 4, 4, 4, 0, 100, 42);
        check("spec identical: erank_drop ~= 0",
              std::fabs(s_none.erank_drop) < 1e-3f);
        check("spec identical: top_k_concentration_drop ~= 0",
              std::fabs(s_none.top_k_concentration_drop) < 1e-3f);
        check("spec identical: NOT flagged",
              !ts_l2_spectral_flagged(&s_none));

        // Null matrix: returns zero metrics, no crash.
        ts_l2_spectral_metrics s_null = ts_l2_compute_spectral_metrics(
            nullptr, 4, 4, 2, 0, 100, 42);
        check("spec null: spectral_norm == 0", s_null.spectral_norm == 0.0f);
        check("spec null: erank == 0", s_null.erank == 0.0f);

        // 0x0: zero metrics.
        std::vector<float> empty;
        ts_l2_spectral_metrics s_0 = ts_l2_compute_spectral_metrics(
            empty.data(), 0, 0, 2, 0, 100, 42);
        check("spec 0x0: spectral_norm == 0", s_0.spectral_norm == 0.0f);
    }

    // --- L4 domain-weighted prompt bank (v3.1 spec §7) ---
    {
        // 7-domain fixture with the spec's canonical names. Each
        // domain has a distinct pass rate and PPL; the worst is
        // "adversarial" (pass_rate 0.55).
        const int64_t n_domains = 7;
        const char * names[7] = {
            "factual", "math", "code", "structured",
            "reasoning", "conversational", "adversarial"
        };
        ts_l4_domain_metrics per_domain[7] = {
            { "factual",        12.3f, 0.96f,  50 },
            { "math",           18.4f, 0.84f, 100 },
            { "code",            9.1f, 0.72f, 100 },
            { "structured",     11.2f, 0.88f, 100 },
            { "reasoning",      22.6f, 0.60f, 100 },
            { "conversational", 15.0f, 0.78f,  50 },
            { "adversarial",    19.8f, 0.55f, 100 },
        };

        // Default uniform weights (1/7 each). The weighted pass
        // rate is the mean of the seven pass rates: (0.96 + 0.84 +
        // 0.72 + 0.88 + 0.60 + 0.78 + 0.55) / 7 = 5.33 / 7 = 0.761.
        std::vector<float> weights((size_t) n_domains, 0.0f);
        ts_l4_domain_default_weights(names, n_domains, weights.data());
        for (int64_t i = 0; i < n_domains; i++) {
            check_close("default weights are uniform",
                        weights[(size_t) i], 1.0f / (float) n_domains, 1e-6f);
        }

        ts_l4_domain_summary summary = {};
        const int rc = ts_l4_domain_aggregate(
            per_domain, weights.data(), n_domains,
            /*pass_threshold=*/0.85f, &summary);
        check("domain_aggregate rc == 0", rc == 0);
        check("domain_aggregate n_domains == 7", summary.n_domains == 7);
        check_close("domain_aggregate weighted_pass_rate ~= 0.7614",
                    summary.weighted_pass_rate, 0.7614285f, 1e-4f);
        check("domain_aggregate pass == false (below 0.85 threshold)",
              !summary.pass);
        check("domain_aggregate total_prompts == 600",
              summary.total_prompts == 600);
        // Worst domain is "adversarial" (pass_rate 0.55).
        check("domain_aggregate worst_domain_idx == 6 (adversarial)",
              summary.worst_domain_idx == 6);
        check_close("domain_aggregate worst_pass_rate == 0.55",
                    summary.worst_pass_rate, 0.55f, 1e-6f);

        // Higher weights on code + reasoning (the spec's
        // production default). The weighted pass rate is
        // skewed: (0.96 + 0.84 + 2*0.72 + 0.88 + 2*0.60 + 0.78 + 0.55) / (1+1+2+1+2+1+1)
        //   = 6.65 / 9 = 0.7389.
        // Below the 0.85 threshold -> NOT pass. The weight uplift
        // on the two low-scoring domains (code 0.72, reasoning 0.60)
        // pulls the aggregate below the uniform 0.7614 baseline.
        std::vector<float> prod_weights = {
            1.0f, 1.0f, 2.0f, 1.0f, 2.0f, 1.0f, 1.0f
        };
        ts_l4_domain_summary prod_summary = {};
        const int prc = ts_l4_domain_aggregate(
            per_domain, prod_weights.data(), n_domains,
            /*pass_threshold=*/0.85f, &prod_summary);
        check("prod rc == 0", prc == 0);
        check_close("prod weighted_pass_rate ~= 0.7389",
                    prod_summary.weighted_pass_rate, 0.7388889f, 1e-4f);
        check("prod pass == false (uplift on low-scoring domains pulls aggregate below threshold)",
              !prod_summary.pass);

        // All-zero pass rates: weighted is 0, NOT pass.
        ts_l4_domain_metrics zero_pr[7] = {};
        for (int64_t i = 0; i < n_domains; i++) {
            zero_pr[i] = per_domain[i];
            zero_pr[i].pass_rate = 0.0f;
        }
        ts_l4_domain_summary zero_summary = {};
        const int zrc = ts_l4_domain_aggregate(
            zero_pr, weights.data(), n_domains, 0.85f, &zero_summary);
        check("zero pass rates: rc == 0", zrc == 0);
        check_close("zero pass rates: weighted_pass_rate == 0",
                    zero_summary.weighted_pass_rate, 0.0f, 1e-9f);
        check("zero pass rates: NOT pass", !zero_summary.pass);

        // Single domain: aggregate is that domain's metrics.
        ts_l4_domain_metrics single = { "math", 18.4f, 0.84f, 100 };
        ts_l4_domain_summary single_summary = {};
        const int src = ts_l4_domain_aggregate(
            &single, nullptr, 1, 0.85f, &single_summary);
        check("single domain: rc == 0", src == 0);
        check_close("single domain: weighted_ppl == 18.4",
                    single_summary.weighted_ppl, 18.4f, 1e-6f);
        check_close("single domain: weighted_pass_rate == 0.84",
                    single_summary.weighted_pass_rate, 0.84f, 1e-6f);
        check("single domain: worst_domain_idx == 0",
              single_summary.worst_domain_idx == 0);
        check("single domain: NOT pass (0.84 < 0.85)", !single_summary.pass);

        // All weights zero: invalid (returns -1).
        std::vector<float> zero_w(7, 0.0f);
        ts_l4_domain_summary invalid_summary = {};
        const int irc = ts_l4_domain_aggregate(
            per_domain, zero_w.data(), n_domains, 0.85f, &invalid_summary);
        check("all-zero weights: rc == -1", irc == -1);

        // Negative weight: invalid.
        std::vector<float> neg_w(7, 1.0f);
        neg_w[0] = -1.0f;
        ts_l4_domain_summary neg_summary = {};
        const int nrc = ts_l4_domain_aggregate(
            per_domain, neg_w.data(), n_domains, 0.85f, &neg_summary);
        check("negative weight: rc == -1", nrc == -1);

        // Null per_domain: invalid.
        ts_l4_domain_summary null_summary = {};
        const int nprc = ts_l4_domain_aggregate(
            nullptr, weights.data(), n_domains, 0.85f, &null_summary);
        check("null per_domain: rc == -1", nprc == -1);

        // Default weight function with null inputs: invalid.
        std::vector<float> out_w(7, 0.0f);
        check("default weights null names: rc == -1",
              ts_l4_domain_default_weights(nullptr, 7, out_w.data()) == -1);
        check("default weights null out: rc == -1",
              ts_l4_domain_default_weights(names, 7, nullptr) == -1);
        check("default weights n=0: rc == -1",
              ts_l4_domain_default_weights(names, 0, out_w.data()) == -1);
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

    // --- L5 Hessian sensitivity scoring (v3.1 spec §9) ---
    //
    // OBQ criterion (Frantar & Alistarh 2022):
    //   omega_ij = (w_ij - quant(w_ij))^2 / [H^{-1}]_ii
    //   sensitivity[T] = mean over (i, j) of omega_ij
    //
    // For a lower-triangular Cholesky L of H^{-1}: [H^{-1}]_ii = L_ii^2.
    //
    // Tests below use:
    //   - Identity L (L_ii = 1 for all i): L_ii^2 = 1, so omega_ij is
    //     the raw squared error. This is the simplest case.
    //   - Diagonal L with L_ii = 2, 3, 4, 5 (in_dim=4): L_ii^2 = 4, 9,
    //     16, 25. Verifies the per-row division is index-correct.
    //   - All-zero quantization error (weights_quant = nullptr):
    //     sensitivity is 0 for every tensor.
    //   - Mismatched in_dim: empty map (fail-closed).
    //   - Null L: empty map.
    //   - NYSTROM source: empty map (v2 deferred).
    {
        const int64_t in_dim  = 4;
        const int64_t out_dim = 2;

        // Identity L (4x4, row-major). L_ii = 1 for all i.
        std::vector<float> L_identity(in_dim * in_dim, 0.0f);
        for (int64_t i = 0; i < in_dim; i++) {
            L_identity[i * in_dim + i] = 1.0f;
        }

        // Diagonal L with L_ii = 2, 3, 4, 5.
        std::vector<float> L_diag(in_dim * in_dim, 0.0f);
        L_diag[0 * in_dim + 0] = 2.0f;  // L_ii^2 = 4
        L_diag[1 * in_dim + 1] = 3.0f;  // L_ii^2 = 9
        L_diag[2 * in_dim + 2] = 4.0f;  // L_ii^2 = 16
        L_diag[3 * in_dim + 3] = 5.0f;  // L_ii^2 = 25

        // Two tensors, each (in_dim, out_dim) = (4, 2) = 8 weights.
        // Layout is (in_dim, out_dim) row-major, so W[i, j] = W[i * out_dim + j].
        // Tensor A: bf16 = (1, 1, 1, 1, 1, 1, 1, 1),
        //          quant = (0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
        //   per-weight error (1 - 0.5) = 0.5; per-row err_i = 0.5^2 + 0.5^2 = 0.5
        //   mean omega = 0.5 / 1.0 = 0.5  (identity L: L_ii^2 = 1)
        // Tensor B: bf16 = (1, 1, 1, 1, 1, 1, 1, 1),
        //          quant = (0, 0, 0, 0, 0, 0, 0, 0)
        //   per-weight error (1 - 0) = 1; per-row err_i = 1^2 + 1^2 = 2.0
        //   mean omega = 2.0 / 1.0 = 2.0
        // After normalize: A = 0.5/2.0 = 0.25, B = 1.0
        std::vector<float> bf16_a  = { 1, 1, 1, 1, 1, 1, 1, 1 };
        std::vector<float> quant_a = { 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f };
        std::vector<float> quant_b = { 0, 0, 0, 0, 0, 0, 0, 0 };

        std::vector<float> w_bf16 = bf16_a;
        w_bf16.insert(w_bf16.end(), bf16_a.begin(), bf16_a.end());  // both tensors share bf16
        std::vector<float> w_quant = quant_a;
        w_quant.insert(w_quant.end(), quant_b.begin(), quant_b.end());

        const char * names[2] = { "tensor_a", "tensor_b" };
        const int64_t in_dims[2]  = { in_dim, in_dim };
        const int64_t out_dims[2] = { out_dim, out_dim };

        ts_l5_second_order_info soi;
        soi.source   = TS_L5_SOI_IN_CORE;
        soi.in_dim   = in_dim;
        soi.L_in_core = L_identity.data();

        ts_score_map s_id = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi, names, 2);
        check("hessian: identity L: 2 entries", s_id.size() == 2);
        check_close("hessian: identity L: tensor_a == 0.25",
                    s_id["tensor_a"], 0.25f, 1e-5f);
        check_close("hessian: identity L: tensor_b == 1.0",
                    s_id["tensor_b"], 1.0f, 1e-5f);

        // Diagonal L: L_ii^2 = 4, 9, 16, 25. Per-row err for tensor A
        // is 0.5 (constant); tensor B is 2.0. The ratio A/B is
        // preserved by the normalize step, so:
        //   Tensor A: mean over i of 0.5 / L_ii^2
        //           = ((0.5/4) + (0.5/9) + (0.5/16) + (0.5/25)) / 4
        //           = 0.5 * (0.25 + 0.1111 + 0.0625 + 0.04) / 4
        //           = 0.5 * 0.4636 / 4 = 0.05795
        //   Tensor B: mean over i of 2.0 / L_ii^2
        //           = 2.0 * 0.4636 / 4 = 0.2318
        //   Ratio: B/A = 0.2318 / 0.05795 = 4.0  (uniform error scaling
        //   with out_dim=2 makes B's row error 4x A's, not 2x)
        // After normalize: A = 0.05795/0.2318 = 0.25, B = 1.0.
        soi.L_in_core = L_diag.data();
        ts_score_map s_diag = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi, names, 2);
        check("hessian: diag L: 2 entries", s_diag.size() == 2);
        check_close("hessian: diag L: tensor_a == 0.25 (ratio preserved)",
                    s_diag["tensor_a"], 0.25f, 1e-4f);
        check_close("hessian: diag L: tensor_b == 1.0",
                    s_diag["tensor_b"], 1.0f, 1e-4f);

        // All-zero error: weights_quant = nullptr -> sensitivity 0.
        // After normalize (peak=0), all stay at 0.
        ts_score_map s_zero = ts_l5_hessian_sensitivity(
            w_bf16.data(), nullptr,
            in_dims, out_dims, &soi, names, 2);
        check("hessian: zero error: 2 entries", s_zero.size() == 2);
        check_close("hessian: zero error: tensor_a == 0",
                    s_zero["tensor_a"], 0.0f, 1e-9f);
        check_close("hessian: zero error: tensor_b == 0",
                    s_zero["tensor_b"], 0.0f, 1e-9f);

        // Mismatched in_dim: soi.in_dim = 8, tensors have in_dim = 4.
        // Empty map (fail-closed).
        ts_l5_second_order_info soi_bad;
        soi_bad.source   = TS_L5_SOI_IN_CORE;
        soi_bad.in_dim   = 8;
        soi_bad.L_in_core = L_identity.data();
        ts_score_map s_bad = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi_bad, names, 2);
        check("hessian: mismatched in_dim: empty map", s_bad.empty());

        // Null L_in_core: empty map.
        ts_l5_second_order_info soi_null;
        soi_null.source   = TS_L5_SOI_IN_CORE;
        soi_null.in_dim   = in_dim;
        soi_null.L_in_core = nullptr;
        ts_score_map s_nullL = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi_null, names, 2);
        check("hessian: null L: empty map", s_nullL.empty());

        // NYSTROM source: v2 deferred -> empty map in v1.
        ts_l5_second_order_info soi_nys;
        soi_nys.source   = TS_L5_SOI_NYSTROM;
        soi_nys.in_dim   = in_dim;
        soi_nys.nystrom_k = 2;
        soi_nys.nystrom_U = L_identity.data();  // dummy
        soi_nys.nystrom_W_inv = L_identity.data();
        ts_score_map s_nys = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi_nys, names, 2);
        check("hessian: nystrom: empty map (v2 deferred)", s_nys.empty());

        // STREAMING source: v2+ deferred -> empty map in v1.
        ts_l5_second_order_info soi_str;
        soi_str.source   = TS_L5_SOI_STREAMING;
        soi_str.in_dim   = in_dim;
        soi_str.streaming_row = 0;
        ts_score_map s_str = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi_str, names, 2);
        check("hessian: streaming: empty map (v2+ deferred)", s_str.empty());

        // Null safety: every null input -> empty map.
        ts_score_map s_null_everywhere = ts_l5_hessian_sensitivity(
            nullptr, nullptr, nullptr, nullptr, &soi, nullptr, 0);
        check("hessian: null everywhere: empty map", s_null_everywhere.empty());

        // n_tensors = 0: empty map.
        ts_score_map s_zero_t = ts_l5_hessian_sensitivity(
            w_bf16.data(), w_quant.data(),
            in_dims, out_dims, &soi, names, 0);
        check("hessian: n_tensors=0: empty map", s_zero_t.empty());

        // Single tensor: no normalize (peak = self).
        ts_score_map s_one = ts_l5_hessian_sensitivity(
            bf16_a.data(), quant_a.data(),
            in_dims, out_dims, &soi, names, 1);
        check("hessian: single tensor: 1 entry", s_one.size() == 1);
        check_close("hessian: single tensor: peak=1.0",
                    s_one["tensor_a"], 1.0f, 1e-5f);

        // SCORER_VERSION defined.
        check("hessian: SCORER_VERSION defined",
              TS_L5_HESSIAN_SCORER_VERSION >= 1);

        // --- Independent readback validation (Nemotron-style lesson) ---
        //
        // The synthetic tests above use hand-computed expected values
        // that share the same per-row loop as the SUT. That's not
        // circular for the *scalar* value (the test's expected is a
        // literal float, not a function call), but it doesn't exercise
        // the off-diagonal L entries — the SUT reads L[i*in_dim+i] for
        // the diagonal, and a bug in the index arithmetic would
        // silently pick up an off-diagonal value.
        //
        // This fixture:
        //   1. Uses a non-diagonal L (off-diagonals != 0) so a wrong
        //      L_ii extraction cannot accidentally match a "correct"
        //      off-diagonal value.
        //   2. Uses a two-tensor input so the normalize step gives a
        //      non-trivial ratio (single-tensor normalize is peak/self
        //      = 1.0, which doesn't distinguish a wrong sensitivity
        //      from a right one).
        //   3. Computes the expected per-tensor mean omega by hand
        //      from the inputs (not via a function call into the SUT).
        //   4. Trap: a second L with misleading off-diagonal entries
        //      (99.0 where a wrong index would land) must produce the
        //      same output. If the SUT reads an off-diagonal, this
        //      fails loudly.
        {
            const int64_t in_dim2  = 3;
            const int64_t out_dim2 = 3;

            // L is lower triangular with off-diagonal entries. L_ii
            // are 1.0, 2.0, 3.0 (L_ii^2 = 1, 4, 9). The off-diagonals
            // are deliberately non-zero so a bug in the diagonal
            // extraction would pick up the wrong value.
            //   L = [ 1    0    0 ]
            //       [ 0.5  2    0 ]
            //       [ 0.25 0.75 3 ]
            std::vector<float> L_nondiag(in_dim2 * in_dim2, 0.0f);
            L_nondiag[0 * in_dim2 + 0] = 1.0f;
            L_nondiag[1 * in_dim2 + 0] = 0.5f;   // off-diag (ignored by scorer)
            L_nondiag[1 * in_dim2 + 1] = 2.0f;
            L_nondiag[2 * in_dim2 + 0] = 0.25f;  // off-diag
            L_nondiag[2 * in_dim2 + 1] = 0.75f;  // off-diag
            L_nondiag[2 * in_dim2 + 2] = 3.0f;

            // Tensor A: bf16 = (1, 2, 3, 4, 5, 6, 7, 8, 9)
            //          quant = (1.1, 1.9, 3.1, 3.9, 5.1, 4.9, 7.0, 7.9, 9.1)
            //   Per-weight error: (-0.1, 0.1, -0.1, 0.1, -0.1, 1.1, 0, 0.1, -0.1)
            //   Squared:          (0.01, 0.01, 0.01, 0.01, 0.01, 1.21, 0, 0.01, 0.01)
            //   Per-row sums:     row 0 = 0.03, row 1 = 1.23, row 2 = 0.02
            //   omega_i = err_i / L_ii^2:  0.03/1, 1.23/4, 0.02/9
            //                         = 0.03, 0.3075, 0.002222
            //   mean omega_A = (0.03 + 0.3075 + 0.002222) / 3 = 0.113241
            //
            // Tensor B: bf16 = (1, 1, 1, 1, 1, 1, 1, 1, 1)
            //          quant = (0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
            //   Per-weight error: 0.5, 0.5, ..., 0.5  (9 entries)
            //   Squared:          0.25, 0.25, ..., 0.25
            //   Per-row sums:     0.75, 0.75, 0.75
            //   omega_i = 0.75 / L_ii^2:  0.75/1, 0.75/4, 0.75/9
            //                        = 0.75, 0.1875, 0.083333
            //   mean omega_B = (0.75 + 0.1875 + 0.083333) / 3 = 0.340278
            //
            // Peak = 0.340278, A_normalized = 0.113241 / 0.340278 = 0.332764
            //                            B_normalized = 1.0
            std::vector<float> bf16_a  = { 1, 2, 3, 4, 5, 6, 7, 8, 9 };
            std::vector<float> quant_a = { 1.1f, 1.9f, 3.1f, 3.9f, 5.1f,
                                            4.9f, 7.0f, 7.9f, 9.1f };
            std::vector<float> bf16_b(9, 1.0f);
            std::vector<float> quant_b(9, 0.5f);

            std::vector<float> w_bf16  = bf16_a;
            w_bf16.insert(w_bf16.end(), bf16_b.begin(), bf16_b.end());
            std::vector<float> w_quant = quant_a;
            w_quant.insert(w_quant.end(), quant_b.begin(), quant_b.end());

            ts_l5_second_order_info soi_nd;
            soi_nd.source    = TS_L5_SOI_IN_CORE;
            soi_nd.in_dim    = in_dim2;
            soi_nd.L_in_core = L_nondiag.data();

            const char * names_nd[2] = { "nd_a", "nd_b" };
            const int64_t in_dims_nd[2]  = { in_dim2, in_dim2 };
            const int64_t out_dims_nd[2] = { out_dim2, out_dim2 };

            ts_score_map s_nd = ts_l5_hessian_sensitivity(
                w_bf16.data(), w_quant.data(),
                in_dims_nd, out_dims_nd, &soi_nd, names_nd, 2);
            check("hessian readback: non-diag L: 2 entries", s_nd.size() == 2);
            // Expected ratios (computed above):
            //   A = 0.332764, B = 1.0
            check_close("hessian readback: non-diag L: nd_a == 0.3328",
                        s_nd["nd_a"], 0.332764f, 1e-4f);
            check_close("hessian readback: non-diag L: nd_b == 1.0",
                        s_nd["nd_b"], 1.0f, 1e-5f);

            // Readback sanity: the scorer should NOT see the
            // off-diagonal entries. Construct an L where the
            // off-diagonals are deliberately misleading (99.0 where
            // a wrong index would land) and verify the output is
            // unchanged. If the SUT read an off-diagonal, the
            // sensitivity would shift and the test would fail.
            std::vector<float> L_nondiag_trap(in_dim2 * in_dim2, 0.0f);
            L_nondiag_trap[0 * in_dim2 + 0] = 1.0f;
            L_nondiag_trap[1 * in_dim2 + 0] = 99.0f;  // wrong index would land here
            L_nondiag_trap[1 * in_dim2 + 1] = 2.0f;
            L_nondiag_trap[2 * in_dim2 + 0] = 99.0f;
            L_nondiag_trap[2 * in_dim2 + 1] = 99.0f;
            L_nondiag_trap[2 * in_dim2 + 2] = 3.0f;
            ts_l5_second_order_info soi_trap = soi_nd;
            soi_trap.L_in_core = L_nondiag_trap.data();
            ts_score_map s_trap = ts_l5_hessian_sensitivity(
                w_bf16.data(), w_quant.data(),
                in_dims_nd, out_dims_nd, &soi_trap, names_nd, 2);
            check("hessian readback: off-diagonal trap: nd_a unchanged",
                  fabsf(s_trap["nd_a"] - s_nd["nd_a"]) < 1e-5f);
            check("hessian readback: off-diagonal trap: nd_b unchanged",
                  fabsf(s_trap["nd_b"] - s_nd["nd_b"]) < 1e-5f);
        }
    }
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
