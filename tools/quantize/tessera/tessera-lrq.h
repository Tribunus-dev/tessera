#pragma once

//
// tessera-lrq.h
//
// LRQ (Low-Rank Quantization) regime expert. Trains low-rank factors
// U/V whose product approximates an identity scaling of the weights,
// so the scaled weights ternarize with minimal reconstruction error.
// Ported from tools/tessera/per_tensor_calibrate.py.
//

#include <cstdint>
#include <vector>

struct ts_lrq_result {
    std::vector<float> U;       // (out_dim x rank)
    std::vector<float> V;       // (rank x in_dim)
    float              mse;
    int64_t            rank;
    int64_t            n_iters;
};

struct ts_lrq_params {
    int64_t rank;
    int64_t max_iters;      // default 200
    float     lr;           // Adam learning rate, default 1e-3
    float     tol;          // convergence tolerance
    uint32_t  seed;
};

// calib_X/n_tokens: optional real per-token calibration activations
// (row-major [n_tokens][in_dim]). When non-null, the training loss weights
// each input channel's reconstruction error by that channel's mean squared
// activation (the same diag(X^T X)/n signal SEPTQ's diagonal Hessian uses),
// so U/V learn to protect columns that actually move the layer's output
// instead of treating every weight element as equally important. nullptr/0
// reproduces the prior uniform-weight loss exactly.
int ts_train_lrq(const float * weights, int64_t out_dim, int64_t in_dim,
                 const ts_lrq_params * params, ts_lrq_result * result,
                 const float * calib_X = nullptr, int64_t n_tokens = 0);

// S_out[out_dim x in_dim] = result->U @ result->V, the learned multiplicative
// pre-scale. Callers (ts_quantize_2d_ternary's FLRQ dispatch) apply it as
// scaled[i] = weights[i] * S_out[i] before ternarizing. Uses the same
// CBLAS/rocBLAS-accelerated matmul as the training loop itself.
void ts_lrq_reconstruct_scale(const ts_lrq_result * result,
                              int64_t out_dim, int64_t in_dim, float * S_out);
