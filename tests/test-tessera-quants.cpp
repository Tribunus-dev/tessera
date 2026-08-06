// test-tessera-quants
//
// Path-parity test for the TILE640 quant helpers in
// ggml/src/ggml-quants.c. Each batched helper is ONE
// implementation with two internal paths (Accelerate + NEON
// accel, scalar fallback); this test asserts the two paths
// agree:
//
//   1. dequant: the flat dequantize_row_tessera_t640 (inline
//      meta) and dequantize_row_tessera_t640_with_meta
//      (pre-decoded meta) agree per element. The two read the
//      lane scale differently (flat multiplies by the fp32
//      reciprocal of 127; with_meta consumes ls/127 from the
//      meta decode), so the bar is 1-2 ulp per element, and
//      in practice they are bit-identical on these fixtures.
//   2. quantize: quantize_row_tessera_t640_ref selects its
//      path internally (accel iff k >= GGML_TESSERA_T640_ACCEL_MIN_K
//      and the flag is on). The test pins the flag with
//      ggml_tessera_t640_set_accel_enabled and compares the
//      round-trip dequant of both pins. The vDSP parallel
//      reductions can shift the page threshold by 1-2 ulp;
//      the fixture signal sits far from the threshold, so the
//      trits are stable and the bar is 1e-5 abs. Below the
//      cutoff (k=640) both pins run the scalar path and must
//      be byte-identical.
//   3. outlier addback: ts_apply_outlier_addback accel vs
//      scalar, bit-identical (fp16 -> fp32 is exact; the
//      scatter is per-element in both paths).
//   4. meta decode: ts_decode_per_row_meta accel vs scalar,
//      bit-identical (both compute ls/127 with IEEE division;
//      fp16 -> fp32 is exact).
//   5. act_scale: ts_apply_act_scale vs a scalar loop,
//      bit-identical.

#include "ggml.h"
#include "ggml-common.h"
#include "ggml-impl.h"
#include "ggml-quants.h"

#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

namespace {

constexpr uint32_t kSeed = 0xBEEFu;

size_t tessera_t640_row_bytes(int64_t k) {
    const int pages = (int) ((k + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE);
    return (size_t) pages * TILE640_WORDS_PER_PAGE * sizeof(uint32_t)
         + (size_t) pages * sizeof(uint16_t)
         + (size_t) pages * TILE640_LANES_PER_PAGE * sizeof(int8_t);
}

void make_signal(std::vector<float> & x, int64_t k, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> dist(-0.5f, 0.5f);
    x.assign((size_t) k, 0.0f);
    for (int64_t i = 0; i < k; i++) {
        const int lane_idx = (int) (i / TILE640_LANE_SIZE);
        const int pos      = (int) (i % TILE640_LANE_SIZE);
        const float amp    = (lane_idx < 16) ? 2.5f : 4.0f;
        if (pos % 3 == 0) {
            x[(size_t) i] = 0.0f;
        } else {
            x[(size_t) i] = (pos % 2 == 0) ? amp : -amp;
        }
    }
    // Add a small uniform noise so the trits are not all
    // deterministic.
    for (int64_t i = 0; i < k; i++) {
        x[(size_t) i] += 0.01f * dist(rng);
    }
}

int test_dequant(int64_t k, uint32_t seed) {
    std::vector<float> x;
    make_signal(x, k, seed);
    std::vector<uint8_t> packed(tessera_t640_row_bytes(k));
    quantize_row_tessera_t640_ref(x.data(), packed.data(), k);
    std::vector<float> y_flat((size_t) k);
    std::vector<float> y_meta((size_t) k);
    dequantize_row_tessera_t640(packed.data(), y_flat.data(), k);
    // Pre-decode the per-row meta (the dispatch calls
    // ts_decode_per_row_meta once for the whole tile), then
    // dequant with the pre-decoded arrays.
    const int pages = (int) ((k + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE);
    const uint8_t * packed_bytes = packed.data();
    const uint32_t * packed_words = (const uint32_t *) packed_bytes;
    const uint16_t * page_scales = (const uint16_t *) (packed_words + pages * TILE640_WORDS_PER_PAGE);
    const int8_t   * lane_scales = (const int8_t   *) (page_scales + pages);
    std::vector<float> page_max((size_t) pages);
    std::vector<float> lane_scale((size_t) (pages * TILE640_LANES_PER_PAGE));
    ts_decode_per_row_meta(page_scales, lane_scales, 1, (int64_t) pages,
                           page_max.data(), lane_scale.data(),
                           /*use_accel=*/true);
    dequantize_row_tessera_t640_with_meta(packed_words, page_max.data(), lane_scale.data(),
                                          k, y_meta.data());
    int mismatches = 0;
    float max_diff = 0.0f;
    for (int64_t i = 0; i < k; i++) {
        const float d = std::fabs(y_flat[i] - y_meta[i]);
        if (d > max_diff) max_diff = d;
        // The two paths read the lane scale differently
        // (reciprocal multiply vs ls/127); allow 2 ulp of the
        // magnitude.
        const float tol = 2.0f * FLT_EPSILON * std::fmax(std::fabs(y_flat[i]), std::fabs(y_meta[i]));
        if (d > tol) mismatches++;
    }
    printf("  dequant k=%lld seed=%u max_diff=%g mismatches=%d/%lld\n",
           (long long) k, seed, max_diff, mismatches, (long long) k);
    return mismatches == 0 ? 0 : 1;
}

int test_quant_roundtrip(int64_t k, uint32_t seed) {
    std::vector<float> x;
    make_signal(x, k, seed);
    std::vector<uint8_t> packed_accel(tessera_t640_row_bytes(k));
    std::vector<uint8_t> packed_scalar(tessera_t640_row_bytes(k));
    ggml_tessera_t640_set_accel_enabled(1);
    quantize_row_tessera_t640_ref(x.data(), packed_accel.data(), k);
    ggml_tessera_t640_set_accel_enabled(0);
    quantize_row_tessera_t640_ref(x.data(), packed_scalar.data(), k);
    ggml_tessera_t640_set_accel_enabled(1);
    std::vector<float> y_a((size_t) k);
    std::vector<float> y_s((size_t) k);
    dequantize_row_tessera_t640(packed_accel.data(), y_a.data(), k);
    dequantize_row_tessera_t640(packed_scalar.data(), y_s.data(), k);
    int mismatches = 0;
    float max_diff = 0.0f;
    for (int64_t i = 0; i < k; i++) {
        const float d = std::fabs(y_a[i] - y_s[i]);
        if (d > max_diff) max_diff = d;
        if (d > 1e-5f) mismatches++;
    }
    printf("  quant round-trip k=%lld seed=%u max_diff=%g mismatches=%d/%lld\n",
           (long long) k, seed, max_diff, mismatches, (long long) k);
    return mismatches == 0 ? 0 : 1;
}

int test_quant_below_cutoff(int64_t k, uint32_t seed) {
    // k < GGML_TESSERA_T640_ACCEL_MIN_K: both pins run the
    // scalar path, the packed bytes must be identical.
    std::vector<float> x;
    make_signal(x, k, seed);
    std::vector<uint8_t> packed_accel(tessera_t640_row_bytes(k));
    std::vector<uint8_t> packed_scalar(tessera_t640_row_bytes(k));
    ggml_tessera_t640_set_accel_enabled(1);
    quantize_row_tessera_t640_ref(x.data(), packed_accel.data(), k);
    ggml_tessera_t640_set_accel_enabled(0);
    quantize_row_tessera_t640_ref(x.data(), packed_scalar.data(), k);
    ggml_tessera_t640_set_accel_enabled(1);
    const bool same = packed_accel == packed_scalar;
    printf("  quant below cutoff k=%lld byte_identical=%s\n",
           (long long) k, same ? "true" : "false");
    return same ? 0 : 1;
}

int test_outlier_addback(int64_t n_rows, int64_t k, int64_t n_per_row) {
    const int64_t n_total = n_rows * n_per_row;
    std::vector<float> rows((size_t) (n_rows * k), 0.0f);
    std::vector<int32_t> cols((size_t) n_total);
    std::vector<uint16_t> vals((size_t) n_total);
    std::vector<int32_t> row_offsets((size_t) (n_rows + 1));
    std::mt19937 rng(kSeed);
    std::uniform_int_distribution<int64_t> col_dist(0, k - 1);
    for (int64_t r = 0; r < n_rows; r++) {
        row_offsets[(size_t) r] = (int32_t) (r * n_per_row);
    }
    row_offsets[(size_t) n_rows] = (int32_t) n_total;
    for (int64_t i = 0; i < n_total; i++) {
        cols[(size_t) i] = (int32_t) col_dist(rng);
        const float v = (rng() & 1) ? 5.0f : -5.0f;
        vals[(size_t) i] = (uint16_t) GGML_FP32_TO_FP16(v);
    }
    std::vector<float> rows_accel  = rows;
    std::vector<float> rows_scalar = rows;
    ts_apply_outlier_addback(rows_accel.data(), k, n_rows,
                             row_offsets.data(), cols.data(), vals.data(),
                             /*use_accel=*/true);
    ts_apply_outlier_addback(rows_scalar.data(), k, n_rows,
                             row_offsets.data(), cols.data(), vals.data(),
                             /*use_accel=*/false);
    int mismatches = 0;
    float max_diff = 0.0f;
    for (int64_t i = 0; i < n_rows * k; i++) {
        const float d = std::fabs(rows_accel[i] - rows_scalar[i]);
        if (d > max_diff) max_diff = d;
        if (d > 0.0f) mismatches++;
    }
    printf("  outlier n_rows=%lld k=%lld n/row=%lld n_total=%lld max_diff=%g mismatches=%d\n",
           (long long) n_rows, (long long) k, (long long) n_per_row,
           (long long) n_total, max_diff, mismatches);
    return mismatches == 0 ? 0 : 1;
}

int test_meta_decode(int64_t n_rows, int64_t n_pages) {
    const int64_t n_lanes_per_row = n_pages * TILE640_LANES_PER_PAGE;
    std::vector<uint16_t> page_scales((size_t) (n_rows * n_pages));
    std::vector<int8_t> lane_scales((size_t) (n_rows * n_lanes_per_row));
    std::mt19937 rng(kSeed);
    std::uniform_real_distribution<float> ps_dist(0.1f, 1.0f);
    std::uniform_int_distribution<int> ls_dist(-127, 127);
    for (int64_t i = 0; i < n_rows * n_pages; i++) {
        page_scales[(size_t) i] = (uint16_t) GGML_FP32_TO_FP16(ps_dist(rng));
    }
    for (int64_t i = 0; i < n_rows * n_lanes_per_row; i++) {
        lane_scales[(size_t) i] = (int8_t) ls_dist(rng);
    }
    std::vector<float> page_max_a((size_t) (n_rows * n_pages));
    std::vector<float> lane_scale_a((size_t) (n_rows * n_lanes_per_row));
    std::vector<float> page_max_s((size_t) (n_rows * n_pages));
    std::vector<float> lane_scale_s((size_t) (n_rows * n_lanes_per_row));
    ts_decode_per_row_meta(page_scales.data(), lane_scales.data(),
                           n_rows, n_pages,
                           page_max_a.data(), lane_scale_a.data(),
                           /*use_accel=*/true);
    ts_decode_per_row_meta(page_scales.data(), lane_scales.data(),
                           n_rows, n_pages,
                           page_max_s.data(), lane_scale_s.data(),
                           /*use_accel=*/false);
    int mismatches = 0;
    float max_diff = 0.0f;
    for (int64_t i = 0; i < n_rows * n_pages; i++) {
        const float d = std::fabs(page_max_a[(size_t) i] - page_max_s[(size_t) i]);
        if (d > max_diff) max_diff = d;
        if (d > 0.0f) mismatches++;
        // Both paths decode fp16 exactly; also check against
        // the documented value.
        const float ref = GGML_FP16_TO_FP32(page_scales[(size_t) i]);
        if (page_max_a[(size_t) i] != ref) mismatches++;
    }
    for (int64_t i = 0; i < n_rows * n_lanes_per_row; i++) {
        const float d = std::fabs(lane_scale_a[(size_t) i] - lane_scale_s[(size_t) i]);
        if (d > max_diff) max_diff = d;
        if (d > 0.0f) mismatches++;
        // Both paths divide by 127 (IEEE); check against the
        // same operation.
        const float ref = ((float) lane_scales[(size_t) i]) / 127.0f;
        if (lane_scale_a[(size_t) i] != ref) mismatches++;
    }
    printf("  meta decode n_rows=%lld n_pages=%lld max_diff=%g mismatches=%d\n",
           (long long) n_rows, (long long) n_pages, max_diff, mismatches);
    return mismatches == 0 ? 0 : 1;
}

int test_act_scale(int64_t n) {
    std::vector<float> y((size_t) n);
    std::vector<uint16_t> as((size_t) n);
    std::mt19937 rng(kSeed);
    std::uniform_real_distribution<float> y_dist(-1.0f, 1.0f);
    std::uniform_real_distribution<float> as_dist(0.5f, 2.0f);
    for (int64_t i = 0; i < n; i++) {
        y[(size_t) i] = y_dist(rng);
        as[(size_t) i] = (uint16_t) GGML_FP32_TO_FP16(as_dist(rng));
    }
    std::vector<float> y_ref = y;
    for (int64_t i = 0; i < n; i++) {
        y_ref[(size_t) i] *= GGML_FP16_TO_FP32(as[(size_t) i]);
    }
    ts_apply_act_scale(y.data(), as.data(), n);
    int mismatches = 0;
    float max_diff = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        const float d = std::fabs(y_ref[i] - y[i]);
        if (d > max_diff) max_diff = d;
        if (d > 0.0f) mismatches++;
    }
    printf("  act_scale n=%lld max_diff=%g mismatches=%d/%lld\n",
           (long long) n, max_diff, mismatches, (long long) n);
    return mismatches == 0 ? 0 : 1;
}

}  // namespace

int main(void) {
    printf("accel flag: %s (env GGML_TESSERA_T640_ACCEL_DISABLE)\n",
           ggml_tessera_t640_accel_enabled() ? "on" : "off");
    int rc = 0;
    printf("dequant parity (flat vs with_meta):\n");
    rc |= test_dequant(640,  kSeed);      // single partial page
    rc |= test_dequant(1024, kSeed + 1);
    rc |= test_dequant(1280, kSeed + 2);  // 2 pages, partial last
    rc |= test_dequant(4096, kSeed + 3);
    printf("quant round-trip (accel pin vs scalar pin):\n");
    rc |= test_quant_roundtrip(1024, kSeed + 4);
    rc |= test_quant_roundtrip(1280, kSeed + 5);
    rc |= test_quant_roundtrip(4096, kSeed + 6);
    rc |= test_quant_below_cutoff(640, kSeed + 7);
    printf("outlier addback (accel vs scalar):\n");
    rc |= test_outlier_addback(1, 1024, 51);     // n_total=51, accel path
    rc |= test_outlier_addback(1, 4096, 204);    // n_total=204, accel path
    rc |= test_outlier_addback(1, 4096, 1024);   // n_total=1024, boundary
    rc |= test_outlier_addback(16, 4096, 204);   // n_total=3264, over the cap
    rc |= test_outlier_addback(1024, 4096, 204); // n_total=208896, large
    printf("meta decode (accel vs scalar):\n");
    rc |= test_meta_decode(1, 1);
    rc |= test_meta_decode(1, 6);    // 4096 / 640
    rc |= test_meta_decode(16, 16);  // batched: 16 rows of 16 pages
    rc |= test_meta_decode(256, 16); // n_total_pages=4096 boundary
    rc |= test_meta_decode(1024, 16);
    printf("act_scale:\n");
    rc |= test_act_scale(256);
    rc |= test_act_scale(1024);
    rc |= test_act_scale(4096);
    rc |= test_act_scale(8192);   // above the internal scratch cap
    if (rc == 0) printf("OK\n");
    return rc;
}
