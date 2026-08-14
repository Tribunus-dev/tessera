//
// test_activation_reservoir.cpp
//
// Unit tests for tessera-activation-reservoir.h's bounded reservoir
// sampling (pipeline refactor stage 5, Vitter's Algorithm R). Tests the
// sampling algorithm in isolation from the ggml graph-harvesting
// machinery that feeds it in production (tools/imatrix/imatrix.cpp),
// since that machinery needs a real model to exercise end to end (see
// this stage's commit message for why a full CLI-level test isn't
// practical in this environment).
//

#include "tessera-activation-reservoir.h"

#include <cmath>
#include <cstdio>
#include <unordered_map>
#include <vector>

static int g_fail = 0;
static void check(const char * name, bool ok) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) g_fail++;
}

// Build n_rows rows of in_dim F16 values, each row's values all equal to
// its row index (as an F16-representable small integer) -- lets tests
// identify which "logical row" survived in the reservoir just by reading
// one value back, without needing a full F16<->F32 conversion helper.
static std::vector<uint16_t> make_rows(int64_t n_rows, int64_t in_dim) {
    std::vector<uint16_t> data((size_t)(n_rows * in_dim));
    for (int64_t r = 0; r < n_rows; ++r) {
        for (int64_t c = 0; c < in_dim; ++c) {
            data[(size_t)(r * in_dim + c)] = (uint16_t) r;
        }
    }
    return data;
}

int main() {
    const int64_t in_dim = 4;

    // --- Test 1: fewer rows than capacity -- every row survives, no
    // replacement needed, n_seen matches rows inserted. ---
    {
        ts_activation_reservoir res;
        res.in_dim = in_dim;
        res.capacity_rows = 100;
        res.rng.seed(1);

        auto rows = make_rows(10, in_dim);
        ts_activation_reservoir_insert(res, rows.data(), 10, in_dim);

        check("fewer-than-capacity: n_seen == rows inserted", res.n_seen == 10);
        check("fewer-than-capacity: filled_rows == rows inserted", res.filled_rows() == 10);
        bool all_present = true;
        for (int64_t r = 0; r < 10; ++r) {
            bool found = false;
            for (int64_t slot = 0; slot < res.filled_rows(); ++slot) {
                if (res.data[(size_t)(slot * in_dim)] == (uint16_t) r) { found = true; break; }
            }
            if (!found) all_present = false;
        }
        check("fewer-than-capacity: every inserted row is present", all_present);
    }

    // --- Test 2: bounded size -- reservoir never exceeds capacity_rows
    // even after inserting far more rows than capacity, across multiple
    // insert() calls (mirrors the real multi-ubatch, multi-slot harvest
    // pattern rather than one giant single call). ---
    {
        ts_activation_reservoir res;
        res.in_dim = in_dim;
        res.capacity_rows = 50;
        res.rng.seed(2);

        int64_t total_inserted = 0;
        for (int chunk = 0; chunk < 20; ++chunk) {
            auto rows = make_rows(37, in_dim);  // deliberately not a multiple of capacity
            ts_activation_reservoir_insert(res, rows.data(), 37, in_dim);
            total_inserted += 37;
        }

        check("bounded: n_seen matches total rows ever inserted", res.n_seen == total_inserted);
        check("bounded: data size never exceeds capacity", (int64_t)res.data.size() == res.capacity_rows * in_dim);
        check("bounded: filled_rows caps at capacity_rows", res.filled_rows() == res.capacity_rows);
    }

    // --- Test 3: determinism -- same seed, same insertion sequence,
    // produces a bit-identical reservoir. Required for reproducible
    // calibration (same corpus -> same captured activations -> same GA
    // search trajectory, matching this codebase's determinism convention
    // for anything seed-driven). ---
    {
        auto run = [&](uint32_t seed) {
            ts_activation_reservoir res;
            res.in_dim = in_dim;
            res.capacity_rows = 30;
            res.rng.seed(seed);
            auto rows = make_rows(500, in_dim);
            ts_activation_reservoir_insert(res, rows.data(), 500, in_dim);
            return res.data;
        };
        auto a = run(42);
        auto b = run(42);
        auto c = run(43);
        check("determinism: identical seed produces identical reservoir", a == b);
        check("determinism: different seed produces a different reservoir", a != c);
    }

    // --- Test 4: unbiased sampling -- over many independent runs, each
    // logical row (0..N-1) should survive into the final reservoir with
    // roughly equal frequency (capacity/N), not a skew toward early or
    // late rows. A skew here would mean Algorithm R is implemented wrong
    // (e.g. sampling from [0, capacity) instead of [0, n_seen]), silently
    // biasing the captured activations toward one part of the corpus. ---
    {
        const int64_t n_total = 200;
        const int64_t capacity = 20;
        const int n_trials = 4000;
        const double expected_freq = (double) capacity / (double) n_total;

        std::vector<int64_t> survival_count(n_total, 0);
        for (int trial = 0; trial < n_trials; ++trial) {
            ts_activation_reservoir res;
            res.in_dim = 1;
            res.capacity_rows = capacity;
            res.rng.seed((uint32_t) (1000 + trial));  // distinct seed per trial
            auto rows = make_rows(n_total, 1);
            ts_activation_reservoir_insert(res, rows.data(), n_total, 1);
            for (int64_t slot = 0; slot < res.filled_rows(); ++slot) {
                const uint16_t logical_row = res.data[(size_t) slot];
                survival_count[logical_row]++;
            }
        }

        double max_abs_dev = 0.0;
        int64_t worst_row = -1;
        for (int64_t r = 0; r < n_total; ++r) {
            const double freq = (double) survival_count[r] / (double) n_trials;
            const double dev = std::fabs(freq - expected_freq);
            if (dev > max_abs_dev) { max_abs_dev = dev; worst_row = r; }
        }
        // Binomial std dev for n_trials draws at p=expected_freq:
        // sqrt(p*(1-p)/n_trials). Allow 6 sigma of slack (this is a
        // correctness smoke test, not a statistical power analysis) --
        // still tight enough to catch a real off-by-range bug, which
        // produces deviations an order of magnitude larger than sampling
        // noise, not a borderline result.
        const double sigma = std::sqrt(expected_freq * (1.0 - expected_freq) / n_trials);
        const double tolerance = 6.0 * sigma;
        std::printf("  unbiased sampling: expected_freq=%.4f max_abs_dev=%.4f "
                    "(row %lld) tolerance=%.4f (6 sigma)\n",
                    expected_freq, max_abs_dev, (long long) worst_row, tolerance);
        check("unbiased sampling: every row's survival frequency is within 6 sigma of capacity/N",
              max_abs_dev <= tolerance);
    }

    // --- Test 5: zero capacity is a clean no-op (used when a caller
    // configures activation_capture_train_tokens=0 and
    // activation_capture_heldout_tokens=0, which should never happen via
    // the CLI validation but is worth being safe against). ---
    {
        ts_activation_reservoir res;
        res.in_dim = in_dim;
        res.capacity_rows = 0;
        res.rng.seed(5);
        auto rows = make_rows(10, in_dim);
        ts_activation_reservoir_insert(res, rows.data(), 10, in_dim);
        check("zero capacity: no-op, data stays empty", res.data.empty());
        check("zero capacity: n_seen unaffected (still 0)", res.n_seen == 0);
    }

    if (g_fail == 0) {
        std::printf("\nPASS\n");
        return 0;
    }
    std::printf("\nFAIL (%d failures)\n", g_fail);
    return 1;
}
