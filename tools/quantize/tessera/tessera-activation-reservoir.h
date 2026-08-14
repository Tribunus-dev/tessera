#pragma once

//
// tessera-activation-reservoir.h
//
// Bounded reservoir sampling for real per-tensor activation capture
// (pipeline refactor stage 5). Header-only and free of any ggml/llama
// dependency so it can be unit-tested in isolation from the graph-
// harvesting machinery that feeds it (tools/imatrix/imatrix.cpp's
// IMatrixCollector).
//
// Algorithm R (Vitter): row i (0-indexed, across the whole run) replaces
// a uniformly-random already-held row with probability capacity/(i+1)
// once the reservoir is full, giving every row seen so far equal
// probability of surviving to the end of the run -- an unbiased sample
// of the whole calibration corpus, not just its first `capacity` rows.
//
// Capacity is train_target + heldout_target combined; the two splits are
// carved out of the single reservoir at write time (see
// tools/imatrix/imatrix.cpp's IMatrixCollector::flush_activation_capture):
// reservoir slot assignment is already randomized by construction, so any
// fixed partition of the filled reservoir is itself an unbiased, disjoint
// train/heldout split -- no separate sampling pass is needed.
//

#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

struct ts_activation_reservoir {
    std::vector<uint16_t> data;          // capacity_rows * in_dim, row-major F16
    int64_t                in_dim = 0;
    int64_t                capacity_rows = 0;
    int64_t                n_seen = 0;    // total rows observed, for Algorithm R
    std::mt19937            rng;           // seeded once per tensor by the caller

    // Rows actually held (<= capacity_rows; less than capacity_rows only
    // if fewer than capacity_rows rows have ever been seen).
    int64_t filled_rows() const {
        return n_seen < capacity_rows ? n_seen : capacity_rows;
    }
};

// Insert n_rows rows (row-major F16, in_dim columns each) into `res`,
// mutating it via Algorithm R. Caller owns `rows`; this function only
// reads from it. No-op if res.capacity_rows <= 0.
inline void ts_activation_reservoir_insert(
        ts_activation_reservoir & res,
        const uint16_t * rows, int64_t n_rows, int64_t in_dim) {
    if (res.capacity_rows <= 0 || n_rows <= 0 || in_dim <= 0) {
        return;
    }
    if (res.data.empty()) {
        res.data.assign((size_t) (res.capacity_rows * in_dim), 0);
    }
    for (int64_t r = 0; r < n_rows; ++r) {
        const uint16_t * row = rows + r * in_dim;
        if (res.n_seen < res.capacity_rows) {
            std::memcpy(res.data.data() + res.n_seen * in_dim, row,
                       (size_t) in_dim * sizeof(uint16_t));
        } else {
            // Uniform over [0, n_seen] inclusive; replace iff it lands in
            // the reservoir's index range. std::uniform_int_distribution
            // is inclusive on both ends.
            std::uniform_int_distribution<int64_t> dist(0, res.n_seen);
            const int64_t j = dist(res.rng);
            if (j < res.capacity_rows) {
                std::memcpy(res.data.data() + j * in_dim, row,
                           (size_t) in_dim * sizeof(uint16_t));
            }
        }
        ++res.n_seen;
    }
}
