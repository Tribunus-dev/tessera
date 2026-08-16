#include "tessera-lrq.h"

#if defined(__APPLE__)
#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK
#endif
#include <Accelerate/Accelerate.h>
#define TS_HAS_CBLAS 1
#elif defined(TS_USE_ROCBLAS)
// rocBLAS before GGML_USE_OPENBLAS: matmul-acceleration, not fallback (D1),
// mirrors tessera-dartquant.cpp's own precedence.
#include "tessera-rocblas.h"
#elif defined(GGML_USE_OPENBLAS)
#include <cblas.h>
#define TS_HAS_CBLAS 1
#endif

#include <cmath>
#include <cstring>
#include <algorithm>

// --- helpers ---

static float ts_mean_abs(const float * x, int64_t n) {
    float s = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        s += fabsf(x[i]);
    }
    return s / (float)n;
}

// ternarize_recon: sign(x) * (|x| >= threshold) * mean(|x|)
// (shared reconstruction primitive; also used by tessera-dartquant)
static void ts_ternarize_recon(const float * x, float * out, int64_t n) {
    float thresh = ts_mean_abs(x, n);
    float scale = thresh;
    if (thresh <= 0.0f) {
        memset(out, 0, n * sizeof(float));
        return;
    }
    for (int64_t i = 0; i < n; i++) {
        float v = x[i];
        if (fabsf(v) >= thresh) {
            out[i] = (v > 0.0f ? 1.0f : -1.0f) * scale;
        } else {
            out[i] = 0.0f;
        }
    }
}

// ---------------------------------------------------------------------------
// Matmul helpers (row-major), CBLAS/rocBLAS-accelerated with a scalar
// fallback. Mirror tessera-dartquant.cpp's ts_dq_matmul/ts_dq_matmul_atb
// pattern exactly (same rocBLAS row-major-via-column-major remap) rather
// than re-deriving the transpose remap from scratch here: this training
// loop's 3 hot matmuls (S=U@V forward, dU, dV backward) were previously
// unaccelerated pure-scalar code -- by far the most expensive of the 4
// regime experts (see gap ledger) -- and a wrong remap here would silently
// degrade FLRQ's learned scale rather than crash, so correctness-by-reuse
// beats a fresh derivation.
// ---------------------------------------------------------------------------

// C(m x n) = A(m x k) @ B(k x n).
static void ts_lrq_matmul(const float * A, const float * B, float * C,
                          int64_t m, int64_t k, int64_t n) {
    if (m <= 0 || n <= 0) return;
#if defined(TS_HAS_CBLAS)
    std::vector<double> Ad((size_t)m * k), Bd((size_t)k * n), Cd((size_t)m * n);
    for (int64_t i = 0; i < m * k; i++) Ad[i] = (double)A[i];
    for (int64_t i = 0; i < k * n; i++) Bd[i] = (double)B[i];
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                (int)m, (int)n, (int)k,
                1.0, Ad.data(), (int)k, Bd.data(), (int)n, 0.0, Cd.data(), (int)n);
    for (int64_t i = 0; i < m * n; i++) C[i] = (float)Cd[i];
#elif defined(TS_USE_ROCBLAS)
    rocblas_status st = ts_rblas_dgemm_to_sgemm(
        rocblas_operation_none, rocblas_operation_none,
        (int)n, (int)m, (int)k, 1.0f,
        B, (int)n, (size_t)k * n,
        A, (int)k, (size_t)m * k,
        C, (int)n, (size_t)m * n);
    if (st != rocblas_status_success) {
        for (int64_t i = 0; i < m; i++) {
            for (int64_t j = 0; j < n; j++) {
                double s = 0.0;
                for (int64_t p = 0; p < k; p++) {
                    s += (double)A[i*k + p] * (double)B[p*n + j];
                }
                C[i*n + j] = (float)s;
            }
        }
    }
#else
    for (int64_t i = 0; i < m; i++) {
        for (int64_t j = 0; j < n; j++) {
            double s = 0.0;
            for (int64_t p = 0; p < k; p++) {
                s += (double)A[i*k + p] * (double)B[p*n + j];
            }
            C[i*n + j] = (float)s;
        }
    }
#endif
}

// C(n x k) = A(m x n)^T @ B(m x k)
static void ts_lrq_matmul_atb(const float * A, const float * B, float * C,
                              int64_t m, int64_t n, int64_t k) {
    if (n <= 0 || k <= 0) return;
#if defined(TS_HAS_CBLAS)
    std::vector<double> Ad((size_t)m * n), Bd((size_t)m * k), Cd((size_t)n * k);
    for (int64_t i = 0; i < m * n; i++) Ad[i] = (double)A[i];
    for (int64_t i = 0; i < m * k; i++) Bd[i] = (double)B[i];
    cblas_dgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                (int)n, (int)k, (int)m,
                1.0, Ad.data(), (int)n, Bd.data(), (int)k, 0.0, Cd.data(), (int)k);
    for (int64_t i = 0; i < n * k; i++) C[i] = (float)Cd[i];
#elif defined(TS_USE_ROCBLAS)
    // Same fix as tessera-dartquant.cpp's ts_dq_matmul_atb (this function
    // was copied from that pattern): transA/transB were backwards for the
    // row-major-via-column-major identity C^T = B^T @ A - verified
    // against a scalar ground truth with a standalone rocBLAS-linked test
    // (rocblas_status_invalid_size at small scale, an unbounded-read GPU
    // page fault at real pipeline scale) before fixing.
    rocblas_status st = ts_rblas_dgemm_to_sgemm(
        rocblas_operation_none, rocblas_operation_transpose,
        (int)k, (int)n, (int)m, 1.0f,
        B, (int)k, (size_t)m * k,
        A, (int)n, (size_t)m * n,
        C, (int)k, (size_t)n * k);
    if (st != rocblas_status_success) {
        for (int64_t i = 0; i < n; i++) {
            for (int64_t j = 0; j < k; j++) {
                double s = 0.0;
                for (int64_t r = 0; r < m; r++) {
                    s += (double)A[r*n + i] * (double)B[r*k + j];
                }
                C[i*k + j] = (float)s;
            }
        }
    }
#else
    for (int64_t i = 0; i < n; i++) {
        for (int64_t j = 0; j < k; j++) {
            double s = 0.0;
            for (int64_t r = 0; r < m; r++) {
                s += (double)A[r*n + i] * (double)B[r*k + j];
            }
            C[i*k + j] = (float)s;
        }
    }
#endif
}

// out(cols x rows) = in(rows x cols)^T. Memory-bound, not compute-bound --
// no BLAS path needed; used to turn dU = d_s @ V^T into a plain A@B call
// via ts_lrq_matmul instead of deriving a 3rd (ABT) rocBLAS remap.
static void ts_lrq_transpose(const float * in, float * out, int64_t rows, int64_t cols) {
    for (int64_t i = 0; i < rows; i++) {
        for (int64_t j = 0; j < cols; j++) {
            out[j * rows + i] = in[i * cols + j];
        }
    }
}

// simple xorshift RNG
static uint32_t ts_rng_next(uint32_t * state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static float ts_rng_gaussian(uint32_t * state) {
    // Box-Muller
    uint32_t u1 = ts_rng_next(state) | 1;
    uint32_t u2 = ts_rng_next(state);
    float r1 = (float)u1 / 4294967296.0f;
    float r2 = (float)u2 / 4294967296.0f;
    return sqrtf(-2.0f * logf(r1)) * cosf(6.2831853f * r2);
}

// --- LRQ ---

int ts_train_lrq(const float * weights, int64_t out_dim, int64_t in_dim,
                 const ts_lrq_params * params, ts_lrq_result * result) {
    int64_t rank = params->rank;
    int64_t max_iters = params->max_iters > 0 ? params->max_iters : 200;
    float lr = params->lr > 0.0f ? params->lr : 1e-3f;
    float tol = params->tol > 0.0f ? params->tol : 1e-7f;
    uint32_t seed = params->seed ? params->seed : 42;

    if (rank < 1 || rank > std::min(out_dim, in_dim)) {
        return -1;
    }

    int64_t n_w = out_dim * in_dim;
    int64_t n_u = out_dim * rank;
    int64_t n_v = rank * in_dim;

    std::vector<float> U(n_u), V(n_v);
    std::vector<float> mU(n_u, 0.0f), vU(n_u, 0.0f);
    std::vector<float> mV(n_v, 0.0f), vV(n_v, 0.0f);
    std::vector<float> S(n_w), scaled(n_w), w_q(n_w);
    std::vector<float> d_scaled(n_w), d_s(n_w);
    std::vector<float> dU(n_u), dV(n_v);
    std::vector<float> Vt(n_v);  // V^T, (in_dim x rank), rebuilt each iter

    // init U, V so that S = U@V starts near 1 (identity scaling)
    uint32_t rng = seed;
    float noise = 0.01f / sqrtf((float)rank);
    for (int64_t i = 0; i < n_u; i++) {
        U[i] = ts_rng_gaussian(&rng) * noise;
    }
    for (int64_t i = 0; i < n_v; i++) {
        V[i] = ts_rng_gaussian(&rng) * noise;
    }
    // set first rank-1 component to produce S ≈ 1
    for (int64_t i = 0; i < out_dim; i++) {
        U[i * rank + 0] = 1.0f;
    }
    for (int64_t j = 0; j < in_dim; j++) {
        V[0 * in_dim + j] = 1.0f;
    }

    float beta1 = 0.9f, beta2 = 0.999f, eps_adam = 1e-8f;
    float prev_loss = 1e30f;

    for (int64_t it = 0; it < max_iters; it++) {
        // forward: S = U @ V
        ts_lrq_matmul(U.data(), V.data(), S.data(), out_dim, rank, in_dim);

        // scaled = W * S (element-wise)
        for (int64_t i = 0; i < n_w; i++) {
            scaled[i] = weights[i] * S[i];
        }

        // w_q = ternarize_recon(scaled)
        ts_ternarize_recon(scaled.data(), w_q.data(), n_w);

        // loss = mean((w_q - W)^2)
        float loss = 0.0f;
        for (int64_t i = 0; i < n_w; i++) {
            float d = w_q[i] - weights[i];
            loss += d * d;
        }
        loss /= (float)n_w;

        if (fabsf(prev_loss - loss) < tol) {
            prev_loss = loss;
            break;
        }
        prev_loss = loss;

        // backward (STE): d_loss/d_scaled = 2*(w_q - W) / n_w
        for (int64_t i = 0; i < n_w; i++) {
            d_scaled[i] = 2.0f * (w_q[i] - weights[i]) / (float)n_w;
        }

        // d_loss/d_S = d_scaled * W
        for (int64_t i = 0; i < n_w; i++) {
            d_s[i] = d_scaled[i] * weights[i];
        }

        // d_loss/d_U = d_s @ V^T: (out_dim x in_dim) @ (in_dim x rank).
        // V^T computed explicitly (rank x in_dim -> in_dim x rank, cheap
        // O(rank*in_dim) transpose) so this reuses the proven A@B helper
        // instead of a 3rd (ABT) rocBLAS remap.
        ts_lrq_transpose(V.data(), Vt.data(), rank, in_dim);
        ts_lrq_matmul(d_s.data(), Vt.data(), dU.data(), out_dim, in_dim, rank);

        // d_loss/d_V = U^T @ d_s: (rank x out_dim) @ (out_dim x in_dim)
        ts_lrq_matmul_atb(U.data(), d_s.data(), dV.data(), out_dim, rank, in_dim);

        // Adam step
        float t = (float)(it + 1);
        float bc1 = 1.0f - powf(beta1, t);
        float bc2 = 1.0f - powf(beta2, t);
        for (int64_t i = 0; i < n_u; i++) {
            mU[i] = beta1 * mU[i] + (1.0f - beta1) * dU[i];
            vU[i] = beta2 * vU[i] + (1.0f - beta2) * dU[i] * dU[i];
            U[i] -= lr * (mU[i] / bc1) / (sqrtf(vU[i] / bc2) + eps_adam);
        }
        for (int64_t i = 0; i < n_v; i++) {
            mV[i] = beta1 * mV[i] + (1.0f - beta1) * dV[i];
            vV[i] = beta2 * vV[i] + (1.0f - beta2) * dV[i] * dV[i];
            V[i] -= lr * (mV[i] / bc1) / (sqrtf(vV[i] / bc2) + eps_adam);
        }
    }

    result->U = std::move(U);
    result->V = std::move(V);
    result->mse = prev_loss;
    result->rank = rank;
    result->n_iters = max_iters;
    return 0;
}

void ts_lrq_reconstruct_scale(const ts_lrq_result * result,
                              int64_t out_dim, int64_t in_dim, float * S_out) {
    ts_lrq_matmul(result->U.data(), result->V.data(), S_out, out_dim, result->rank, in_dim);
}
