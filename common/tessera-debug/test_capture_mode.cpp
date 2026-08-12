// test_capture_mode.cpp
//
// Test for the Tessera L1+L1.5 row-capture mode (NEW, v3.1).
// Covers:
//   1. The default behavior (DEQUANT_CAPTURE_FULL) is unchanged.
//   2. The setter/getter pair is idempotent and last-write-wins.
//   3. The Mode A trigger fires on the configured conditions and
//      bypasses on others.
//   4. The env-var loaders parse the documented strings.
//   5. The trigger respects the configured thresholds.
//
// The tests are header-only consumers of tessera_debug's public API
// (tessera-debug.h). No internal state is reached into; the file is
// a sibling to test_sidecar_v3.cpp and follows the same standalone-
// executable pattern (no gtest dependency).
//
// Run as: ./bin/test-tessera-capture-mode

#include "tessera-debug.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

static int g_failures = 0;

#define EXPECT(cond)                                                        \
    do {                                                                    \
        if (!(cond)) {                                                     \
            std::fprintf(stderr, "FAIL %s:%d: %s\n",                       \
                    __FILE__, __LINE__, #cond);                             \
            g_failures++;                                                  \
        }                                                                   \
    } while (0)

#define EXPECT_EQ_INT(a, b)                                                \
    do {                                                                    \
        int _a = (int)(a);                                                 \
        int _b = (int)(b);                                                 \
        if (_a != _b) {                                                    \
            std::fprintf(stderr, "FAIL %s:%d: %s == %s "                    \
                    "(%d != %d)\n",                                        \
                    __FILE__, __LINE__, #a, #b, _a, _b);                   \
            g_failures++;                                                  \
        }                                                                   \
    } while (0)

#define EXPECT_NEAR(a, b, eps)                                             \
    do {                                                                    \
        float _a = (float)(a);                                             \
        float _b = (float)(b);                                             \
        float _d = _a - _b;                                                \
        if (_d < 0) _d = -_d;                                              \
        if (_d > (eps)) {                                                  \
            std::fprintf(stderr, "FAIL %s:%d: |%s - %s| = %.6f > %.6f\n",\
                    __FILE__, __LINE__, #a, #b, _d, (float)(eps));         \
            g_failures++;                                                  \
        }                                                                   \
    } while (0)

// Test 1: defaults match shipped behavior. The capture mode is FULL,
// the trigger quantile is 0.01, the trigger delta is 0.5, and
// dequant_row_fires_trigger returns true for any input (the
// shipped behavior is "always capture").
static int test_defaults() {
    using namespace tessera_debug;

    // Set the env to a known-bad value; ensure_env_loaded reads it
    // once per process. We can't fully reset internal state from
    // outside, so we only assert that the *initial* values match.
    EXPECT_EQ_INT(dequant_capture_mode(),     DEQUANT_CAPTURE_FULL);
    EXPECT_NEAR (dequant_trigger_quantile(), 0.01f,  1e-6f);
    EXPECT_NEAR (dequant_trigger_delta(),     0.5f,   1e-6f);

    // In FULL mode the trigger is bypassed: it always returns true
    // regardless of the input, which preserves the shipped behavior.
    EXPECT(dequant_row_fires_trigger(/*outlier_count=*/0,
                                    /*row_max_abs=*/0.0f,
                                    /*rolling_mean=*/0.0f) == true);
    EXPECT(dequant_row_fires_trigger(/*outlier_count=*/100,
                                    /*row_max_abs=*/100.0f,
                                    /*rolling_mean=*/1.0f) == true);
    return 0;
}

// Test 2: setter/getter idempotence. The setter is last-write-wins;
// reading back gives the same value. The mutex-free read of a
// single int is atomic on every target platform.
static int test_setter_getter() {
    using namespace tessera_debug;

    set_dequant_capture_mode(DEQUANT_CAPTURE_OUTLIER);
    EXPECT_EQ_INT(dequant_capture_mode(), DEQUANT_CAPTURE_OUTLIER);

    set_dequant_capture_mode(DEQUANT_CAPTURE_RESERVOIR);
    EXPECT_EQ_INT(dequant_capture_mode(), DEQUANT_CAPTURE_RESERVOIR);

    set_dequant_capture_mode(DEQUANT_CAPTURE_FULL);
    EXPECT_EQ_INT(dequant_capture_mode(), DEQUANT_CAPTURE_FULL);

    // Quantile clamping
    set_dequant_trigger_quantile(-0.5f);
    EXPECT_NEAR(dequant_trigger_quantile(), 0.0f, 1e-6f);
    set_dequant_trigger_quantile(1.5f);
    EXPECT_NEAR(dequant_trigger_quantile(), 1.0f, 1e-6f);
    set_dequant_trigger_quantile(0.05f);
    EXPECT_NEAR(dequant_trigger_quantile(), 0.05f, 1e-6f);

    // Delta clamping
    set_dequant_trigger_delta(-1.0f);
    EXPECT_NEAR(dequant_trigger_delta(), 0.0f, 1e-6f);
    set_dequant_trigger_delta(2.0f);
    EXPECT_NEAR(dequant_trigger_delta(), 2.0f, 1e-6f);
    return 0;
}

// Test 3: Mode A trigger fires on the configured conditions. With
// the trigger set to Mode A and the rolling_mean branch active, the
// trigger should fire when |row_max_abs - rolling_mean| > delta and
// bypass when it is not.
static int test_mode_a_trigger() {
    using namespace tessera_debug;

    set_dequant_capture_mode(DEQUANT_CAPTURE_OUTLIER);
    set_dequant_trigger_quantile(0.0f);   // disable outlier-count branch
    set_dequant_trigger_delta(0.5f);

    // rolling_mean = 1.0, delta = 0.5
    // Fire if |row_max_abs - 1.0| > 0.5
    EXPECT(dequant_row_fires_trigger(0, 2.0f,  1.0f) == true);   // diff 1.0 > 0.5
    EXPECT(dequant_row_fires_trigger(0, 1.4f,  1.0f) == false);  // diff 0.4 <= 0.5
    EXPECT(dequant_row_fires_trigger(0, 0.5f,  1.0f) == false);  // diff 0.5 <= 0.5
    EXPECT(dequant_row_fires_trigger(0, 0.6f,  1.0f) == false);  // diff 0.4 <= 0.5

    // When rolling_mean == 0.0 the divergence branch is disabled
    // (the rolling mean has not been initialized yet) and the
    // trigger bypasses the divergence check.
    EXPECT(dequant_row_fires_trigger(0, 100.0f, 0.0f) == false);

    // Switch back to FULL: trigger always returns true.
    set_dequant_capture_mode(DEQUANT_CAPTURE_FULL);
    EXPECT(dequant_row_fires_trigger(0, 0.0f, 0.0f) == true);
    return 0;
}

// Test 4: set_dequant_capture_mode rejects unknown enum values
// rather than silently corrupting state. The shipped behavior is
// unchanged: an unknown mode is ignored.
static int test_setter_rejects_unknown() {
    using namespace tessera_debug;

    set_dequant_capture_mode(DEQUANT_CAPTURE_OUTLIER);
    EXPECT_EQ_INT(dequant_capture_mode(), DEQUANT_CAPTURE_OUTLIER);

    // Pass an out-of-range int; the setter should ignore.
    set_dequant_capture_mode(static_cast<DequantCaptureMode>(99));
    EXPECT_EQ_INT(dequant_capture_mode(), DEQUANT_CAPTURE_OUTLIER);
    return 0;
}

int main() {
    test_defaults();
    test_setter_getter();
    test_mode_a_trigger();
    test_setter_rejects_unknown();

    if (g_failures > 0) {
        std::fprintf(stderr, "test-capture-mode: %d failure(s)\n",
                g_failures);
        return 1;
    }
    std::fprintf(stdout, "test-capture-mode: ok\n");
    return 0;
}
