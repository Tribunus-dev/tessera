//
// test_linalg.cpp
//
// Smoke tests for tessera-linalg.cpp. Prints PASS/FAIL per test,
// returns 0 only if all pass.
//

#include "tessera-linalg.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

static bool test_qr() {
    const int64_t m = 4, n = 3;
    const float A[m*n] = {
        1.0f, 2.0f, 3.0f,
        4.0f, 5.0f, 6.0f,
        7.0f, 8.0f, 10.0f,
        2.0f, 0.0f, 1.0f,
    };
    std::vector<float> Q(m*n), R(n*n);
    ts_linalg_householder_qr(A, Q.data(), R.data(), m, n);

    // Q^T Q ~= I_n
    float err_orth = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        for (int64_t j = 0; j < n; j++) {
            float s = 0.0f;
            for (int64_t r = 0; r < m; r++) s += Q[r*n + i] * Q[r*n + j];
            float target = (i == j) ? 1.0f : 0.0f;
            err_orth = fmaxf(err_orth, fabsf(s - target));
        }
    }

    // Q R ~= A
    float err_recon = 0.0f;
    for (int64_t i = 0; i < m; i++) {
        for (int64_t j = 0; j < n; j++) {
            float s = 0.0f;
            for (int64_t p = 0; p < n; p++) s += Q[i*n + p] * R[p*n + j];
            err_recon = fmaxf(err_recon, fabsf(s - A[i*n + j]));
        }
    }

    printf("  qr: orth=%.2e recon=%.2e\n", err_orth, err_recon);
    return err_orth < 1e-4f && err_recon < 1e-4f;
}

static bool test_stiefel_project() {
    const int64_t n = 4;
    std::vector<float> R(n*n), G(n*n), P(n*n);
    ts_linalg_random_orthogonal(R.data(), n, 1234);
    // arbitrary ambient gradient
    for (int64_t i = 0; i < n*n; i++) {
        G[i] = 0.3f * (float)(i % 5) - 0.1f * (float)(i % 3);
    }
    ts_linalg_stiefel_project(G.data(), R.data(), P.data(), n, n);

    // R^T P should be skew-symmetric: M + M^T ~= 0
    float err = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        for (int64_t j = 0; j < n; j++) {
            float mij = 0.0f, mji = 0.0f;
            for (int64_t r = 0; r < n; r++) {
                mij += R[r*n + i] * P[r*n + j];
                mji += R[r*n + j] * P[r*n + i];
            }
            err = fmaxf(err, fabsf(mij + mji));
        }
    }

    printf("  stiefel_project: skew_err=%.2e\n", err);
    return err < 1e-4f;
}

static bool test_svd_topk() {
    const int64_t m = 3, n = 3, k = 3;
    const float A[m*n] = {
        3.0f, 0.0f, 0.0f,
        0.0f, 2.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    };
    std::vector<float> U(m*k), S(k), V(n*k);
    ts_linalg_svd_topk(A, U.data(), S.data(), V.data(), m, n, k, 30, 7);

    printf("  svd_topk: S=[%.4f, %.4f, %.4f]\n", S[0], S[1], S[2]);
    return fabsf(S[0] - 3.0f) < 1e-2f;
}

static bool test_gram_schmidt() {
    const int64_t k = 3, n = 4;
    float V[k*n] = {
        1.0f, 1.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 1.0f, 1.0f,
    };
    ts_linalg_gram_schmidt(V, k, n);

    // V V^T ~= I_k
    float err = 0.0f;
    for (int64_t i = 0; i < k; i++) {
        for (int64_t j = 0; j < k; j++) {
            float s = 0.0f;
            for (int64_t c = 0; c < n; c++) s += V[i*n + c] * V[j*n + c];
            float target = (i == j) ? 1.0f : 0.0f;
            err = fmaxf(err, fabsf(s - target));
        }
    }

    printf("  gram_schmidt: orth_err=%.2e\n", err);
    return err < 1e-4f;
}

// ts_linalg_sym_eig regression: nothing previously exercised this function
// directly (only indirectly via test_flrq.cpp's small 16x32 fixture, which
// never distinguishes a broken row-major/column-major convention from a
// correct one at that size by luck of the input). This pins the PUBLIC
// contract -- descending eigenvalues, orthonormal eigvecs, A v_i = lambda_i
// v_i -- against whichever backend ts_linalg_sym_eig dispatches to
// (LAPACK's ssyevd on Apple, portable Jacobi elsewhere or on LAPACK
// failure). n=200 is large enough that a transposed eigenvector matrix
// (the exact bug this pins: LAPACK writes eigenvectors column-major, this
// codebase is row-major) fails badly, small enough that even the Jacobi
// fallback finishes in about a second.
static bool test_sym_eig() {
    const int64_t n = 200;
    std::vector<float> A((size_t)(n * n));
    uint32_t s = 1234;
    auto rnd = [&]() {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        return ((float)(s >> 8) * (1.0f / 16777216.0f)) * 2.0f - 1.0f;
    };
    for (int64_t i = 0; i < n; i++) {
        for (int64_t j = i; j < n; j++) {
            float v = rnd();
            A[(size_t)(i*n + j)] = v;
            A[(size_t)(j*n + i)] = v;
        }
    }

    std::vector<float> eigvals((size_t)n), eigvecs((size_t)(n * n));
    ts_linalg_sym_eig(A.data(), eigvals.data(), eigvecs.data(), n);

    // Descending order.
    float order_err = 0.0f;
    for (int64_t i = 0; i + 1 < n; i++) {
        order_err = fmaxf(order_err, fmaxf(0.0f, eigvals[(size_t)(i+1)] - eigvals[(size_t)i]));
    }

    // Orthonormality: columns of eigvecs (eigvecs[i*n+j] = component i of
    // eigenvector j) are unit and mutually orthogonal.
    float orth_err = 0.0f;
    for (int64_t a = 0; a < n; a++) {
        for (int64_t b = a; b < n; b++) {
            double dot = 0.0;
            for (int64_t i = 0; i < n; i++) {
                dot += (double)eigvecs[(size_t)(i*n + a)] * (double)eigvecs[(size_t)(i*n + b)];
            }
            double target = (a == b) ? 1.0 : 0.0;
            orth_err = fmaxf(orth_err, (float)fabs(dot - target));
        }
    }

    // Eigen-equation residual on every eigenpair: A v_j = lambda_j v_j.
    double resid_num = 0.0, resid_den = 0.0;
    for (int64_t j = 0; j < n; j++) {
        for (int64_t i = 0; i < n; i++) {
            double acc = 0.0;
            for (int64_t k = 0; k < n; k++) {
                acc += (double)A[(size_t)(i*n + k)] * (double)eigvecs[(size_t)(k*n + j)];
            }
            double d = acc - (double)eigvals[(size_t)j] * (double)eigvecs[(size_t)(i*n + j)];
            resid_num += d*d;
            resid_den += acc*acc;
        }
    }
    double resid = std::sqrt(resid_num / std::max(1e-30, resid_den));

    printf("  sym_eig: order_err=%.2e orth_err=%.2e residual=%.2e (n=%lld)\n",
          order_err, orth_err, resid, (long long)n);
    return order_err < 1e-5f && orth_err < 1e-3f && resid < 1e-3;
}

int main() {
    struct { const char * name; bool (*fn)(); } tests[] = {
        { "qr",             test_qr },
        { "stiefel_project", test_stiefel_project },
        { "svd_topk",        test_svd_topk },
        { "gram_schmidt",    test_gram_schmidt },
        { "sym_eig",         test_sym_eig },
    };

    bool all = true;
    for (auto & t : tests) {
        bool ok = t.fn();
        printf("[%s] %s\n", ok ? "PASS" : "FAIL", t.name);
        all = all && ok;
    }
    return all ? 0 : 1;
}
