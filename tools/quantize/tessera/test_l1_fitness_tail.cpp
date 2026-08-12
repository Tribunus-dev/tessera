//
// test_l1_fitness_tail.cpp
//
// Tests for ts_l1_kernel_direct_t2_tail (L6 tail-weighted kernel-direct
// t_l^2, §11 of docs/l1-l6-telemetry-refinements-spec.md). The function is
//
//   t_l^2_tail = ||W_hat - dequant_kernel||_F^2 / ||W||_F^2
//              + lambda_tail * mean_{i: |W_l[i]| > tau} (W_hat[i] - dequant_kernel[i])^2
//
// The tests pin down the four properties the spec needs:
//   1. lambda_tail = 0 reduces to the existing Frobenius (compatibility).
//   2. tau larger than all |W_l[i]| zeroes the tail term (degenerate).
//   3. with synthetic outliers and large kernel errors on them, the tail
//      term dominates and is non-zero.
//   4. null/empty/zero-denominator inputs return 0 cleanly.
//   5. negative lambda is clamped to 0 (no tail weighting).
//
// We don't compare the closed-form value with float-arithmetic Python;
// relative tolerances are tight enough to catch sign/scale bugs without
// being brittle to rounding mode.
//

#include "tessera-l1-fitness.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
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
        std::printf("FAIL %-32s got %.7g want %.7g\n", name, (double)got, (double)want);
        g_fail++;
    } else {
        std::printf("ok   %-32s %.7g\n", name, (double)got);
    }
}

int main() {
    // ---- Test 1: lambda = 0 must reduce to the Frobenius. ----
    // Build a small weight set with no outliers (|w_l[i]| <= 4.0 for all i),
    // a small kernel perturbation, and a separate offline reconstruction.
    const int64_t n = 16;
    std::vector<float> w_orig((size_t)n);
    std::vector<float> w_hat ((size_t)n);
    std::vector<float> k_deq ((size_t)n);
    for (int64_t i = 0; i < n; i++) {
        w_orig[(size_t)i] = 0.5f * (float)((i % 5) - 2);   // |w_l[i]| <= 1.0
        w_hat [(size_t)i] = w_orig[(size_t)i] + 0.01f;
        k_deq [(size_t)i] = w_orig[(size_t)i] + 0.02f;
    }

    // Reference Frobenius = ||w_hat - k_deq||^2 / ||w_orig||^2.
    double num = 0.0, den = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const double d = (double)w_hat[(size_t)i] - (double)k_deq[(size_t)i];
        num += d * d;
        den += (double)w_orig[(size_t)i] * (double)w_orig[(size_t)i];
    }
    const float frob = (float)(num / den);

    const float t2_lam0 = ts_l1_kernel_direct_t2_tail(
        w_hat.data(), w_orig.data(), k_deq.data(), n,
        /*tau*/ 6.0f, /*lambda_tail*/ 0.0f);
    check_close("lambda=0 matches Frobenius", t2_lam0, frob, 1e-6f);

    // ---- Test 2: tau larger than all |W_l[i]| -> tail term is 0. ----
    // Same data, tau = 100.0, lambda_tail = 4.0. No element is an
    // "outlier" so the tail MSE loop produces 0 and we get Frobenius.
    const float t2_big_tau = ts_l1_kernel_direct_t2_tail(
        w_hat.data(), w_orig.data(), k_deq.data(), n,
        /*tau*/ 100.0f, /*lambda_tail*/ 4.0f);
    check_close("tau huge -> no outliers -> Frobenius",
                t2_big_tau, frob, 1e-6f);

    // ---- Test 3: synthetic outliers + large kernel error on them. ----
    // We plant two outlier indices (idx 2, 9) where |w_orig| > 6.0 and
    // the kernel makes a big error on them (|k_deq - w_hat| ~ 5.0). The
    // tail MSE on the two outliers is large; Frobenius is small. The
    // tail-weighted form must be measurably larger than the Frobenius.
    std::vector<float> w_orig2((size_t)n, 0.1f);     // bulk ~ 0.1
    std::vector<float> w_hat2 ((size_t)n, 0.1f);
    std::vector<float> k_deq2 ((size_t)n, 0.1f);
    w_orig2[2] =  8.0f;  w_hat2[2] =  8.0f;  k_deq2[2] =  2.0f;  // err 6.0
    w_orig2[9] = -7.5f;  w_hat2[9] = -7.5f;  k_deq2[9] = -2.0f;  // err 5.5

    double num2 = 0.0, den2 = 0.0, tail_sum = 0.0;
    int64_t n_tail = 0;
    for (int64_t i = 0; i < n; i++) {
        const double d = (double)w_hat2[(size_t)i] - (double)k_deq2[(size_t)i];
        num2 += d * d;
        den2 += (double)w_orig2[(size_t)i] * (double)w_orig2[(size_t)i];
        if (std::fabs((double)w_orig2[(size_t)i]) > 6.0) {
            tail_sum += d * d;
            n_tail++;
        }
    }
    const float frob2    = (float)(num2 / den2);
    const float tail_mse = (n_tail > 0) ? (float)(tail_sum / (double)n_tail) : 0.0f;
    const float lambda   = 4.0f;
    const float want_t2  = frob2 + lambda * tail_mse;

    const float got_t2 = ts_l1_kernel_direct_t2_tail(
        w_hat2.data(), w_orig2.data(), k_deq2.data(), n,
        /*tau*/ 6.0f, /*lambda_tail*/ lambda);
    check("n_tail == 2 in the test fixture", n_tail == 2);
    check_close("with outliers + lambda=4 -> frob + 4 * tail_mse",
                got_t2, want_t2, 1e-5f);
    check("tail term dominates the bulk", got_t2 > 10.0f * frob2);

    // ---- Test 4: degenerate inputs return 0 cleanly. ----
    std::vector<float> scratch((size_t)n, 0.0f);
    check("null w_hat returns 0",
          ts_l1_kernel_direct_t2_tail(nullptr, scratch.data(), scratch.data(),
                                      n, 6.0f, 4.0f) == 0.0f);
    check("null w_original returns 0",
          ts_l1_kernel_direct_t2_tail(scratch.data(), nullptr, scratch.data(),
                                      n, 6.0f, 4.0f) == 0.0f);
    check("null kernel_dequant returns 0",
          ts_l1_kernel_direct_t2_tail(scratch.data(), scratch.data(), nullptr,
                                      n, 6.0f, 4.0f) == 0.0f);
    check("n == 0 returns 0",
          ts_l1_kernel_direct_t2_tail(scratch.data(), scratch.data(), scratch.data(),
                                      0, 6.0f, 4.0f) == 0.0f);
    check("n < 0 returns 0",
          ts_l1_kernel_direct_t2_tail(scratch.data(), scratch.data(), scratch.data(),
                                      -1, 6.0f, 4.0f) == 0.0f);
    // zero-denominator: ||W||_F^2 = 0
    std::vector<float> zero_w((size_t)n, 0.0f);
    std::vector<float> small_e((size_t)n, 0.0f);
    small_e[3] = 1e-3f;
    check("||W||_F^2 == 0 returns 0",
          ts_l1_kernel_direct_t2_tail(small_e.data(), zero_w.data(), small_e.data(),
                                      n, 6.0f, 4.0f) == 0.0f);

    // ---- Test 5: negative lambda is clamped to 0 (no tail weighting). ----
    const float t2_neg_lambda = ts_l1_kernel_direct_t2_tail(
        w_hat2.data(), w_orig2.data(), k_deq2.data(), n,
        /*tau*/ 6.0f, /*lambda_tail*/ -100.0f);
    check_close("negative lambda clamped to 0 -> Frobenius",
                t2_neg_lambda, frob2, 1e-6f);

    // ---- Test 6: very negative tau makes everything an outlier. ----
    // tau = -1.0, lambda = 1.0: every |w_l[i]| > -1 (trivially true), so
    // tail_mse is the global mean (||w_hat - k_deq||^2 / n), not the
    // sum normalized by ||W||^2. The function should still return
    // frob + lambda * mean_d^2.
    const float t2_neg_tau = ts_l1_kernel_direct_t2_tail(
        w_hat.data(), w_orig.data(), k_deq.data(), n,
        /*tau*/ -1.0f, /*lambda_tail*/ 1.0f);
    double mean_d2 = num / (double)n;   // mean of (w_hat - k_deq)^2
    const float want_neg_tau = frob + 1.0f * (float)mean_d2;
    check_close("tau < 0 -> all elements in tail", t2_neg_tau, want_neg_tau, 1e-5f);

    if (g_fail == 0) {
        std::printf("PASS\n");
        return 0;
    }
    std::printf("%d FAILURES\n", g_fail);
    return 1;
}
