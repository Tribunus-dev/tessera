// bench-tessera-quants
//
// Throughput benchmark for the TILE640 quant helpers in
// ggml/src/ggml-quants.c. Each helper is one implementation
// with two internal paths (Accelerate + NEON accel, scalar
// fallback); the bench times both paths on the 5 canonical
// Phase 0 shapes (256x256, 512x512, 1024x1024, 128x4096,
// 4096x4096) plus the smaller 640x640 (single page) and
// 1280x1280 (2 pages, partial last) for context.
//
// Reports:
//   - median us / call (across N=10 runs, 5 warmup runs)
//   - speedup of the accel path vs the scalar path
//   - throughput in MB/s for the dequant path
//
// The measurements are the empirical basis for the regime
// router's policy table (ggml/src/ggml-regime-router.gen.h)
// and the static cost model fallback in ggml-quants.h.
//
// The benchmark does NOT run the GGML_OP_TILE640_MATMUL
// dispatch end-to-end (that requires the .mlmodelc fixtures).
// It covers the host-side quant paths only.

#include "ggml.h"
#include "ggml-common.h"
#include "ggml-impl.h"
#include "ggml-quants.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

namespace {

constexpr int kWarmup = 5;
constexpr int kRuns   = 10;
constexpr uint32_t kSeed = 0xCAFEu;

size_t tessera_t640_row_bytes(int64_t k) {
    const int pages = (int) ((k + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE);
    return (size_t) pages * TILE640_WORDS_PER_PAGE * sizeof(uint32_t)
         + (size_t) pages * sizeof(uint16_t)
         + (size_t) pages * TILE640_LANES_PER_PAGE * sizeof(int8_t);
}

double median_us(std::vector<double> & samples) {
    std::sort(samples.begin(), samples.end());
    return samples[samples.size() / 2];
}

template <typename Fn>
double time_fn(Fn fn) {
    for (int i = 0; i < kWarmup; i++) fn();
    std::vector<double> us;
    us.reserve((size_t) kRuns);
    for (int i = 0; i < kRuns; i++) {
        const auto t0 = std::chrono::steady_clock::now();
        fn();
        const auto t1 = std::chrono::steady_clock::now();
        us.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
    }
    return median_us(us);
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
    for (int64_t i = 0; i < k; i++) {
        x[(size_t) i] += 0.01f * dist(rng);
    }
}

int bench_dequant(int64_t k) {
    std::vector<float> x;
    make_signal(x, k, kSeed);
    std::vector<uint8_t> packed(tessera_t640_row_bytes(k));
    quantize_row_tessera_t640_ref(x.data(), packed.data(), k);
    std::vector<float> y((size_t) k, 0.0f);
    // The with_meta path takes pre-decoded meta; decode once
    // outside the timing loop (the dispatch hoists the decode
    // the same way, one call per tile).
    const int pages = (int) ((k + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE);
    const uint32_t * packed_words = (const uint32_t *) packed.data();
    const uint16_t * page_scales_p = (const uint16_t *) (packed_words + pages * TILE640_WORDS_PER_PAGE);
    const int8_t   * lane_scales_p = (const int8_t   *) (page_scales_p + pages);
    std::vector<float> page_max((size_t) pages);
    std::vector<float> lane_scale((size_t) (pages * TILE640_LANES_PER_PAGE));
    ts_decode_per_row_meta(page_scales_p, lane_scales_p, 1, (int64_t) pages,
                           page_max.data(), lane_scale.data(),
                           /*use_accel=*/true);
    // Sink so the compiler can't DCE the writes.
    volatile float sink = 0.0f;
    const double us_flat = time_fn([&]() {
        dequantize_row_tessera_t640(packed.data(), y.data(), k);
        sink += y[0];
    });
    const double us_meta = time_fn([&]() {
        dequantize_row_tessera_t640_with_meta(packed_words,
                                              page_max.data(), lane_scale.data(),
                                              k, y.data());
        sink += y[0];
    });
    const double speedup = us_flat / us_meta;
    // Throughput: read packed + write fp32.
    const double bytes_io = (double) (tessera_t640_row_bytes(k) + k * sizeof(float));
    const double mbps_flat = bytes_io / (us_flat * 1e3);
    const double mbps_meta = bytes_io / (us_meta * 1e3);
    printf("  dequant k=%-5lld  flat: %7.2f us (%.0f MB/s)  with_meta: %7.2f us (%.0f MB/s)  speedup: %.2fx\n",
           (long long) k, us_flat, mbps_flat, us_meta, mbps_meta, speedup);
    (void) sink;
    return 0;
}

int bench_quant(int64_t k) {
    std::vector<float> x;
    make_signal(x, k, kSeed);
    std::vector<uint8_t> packed(tessera_t640_row_bytes(k));
    // The quantizer selects its path internally; pin the flag
    // around each measurement.
    const double us_scalar = time_fn([&]() {
        ggml_tessera_t640_set_accel_enabled(0);
        quantize_row_tessera_t640_ref(x.data(), packed.data(), k);
    });
    const double us_accel = time_fn([&]() {
        ggml_tessera_t640_set_accel_enabled(1);
        quantize_row_tessera_t640_ref(x.data(), packed.data(), k);
    });
    const double speedup = us_scalar / us_accel;
    const double bytes_io = (double) (tessera_t640_row_bytes(k) + k * sizeof(float));
    const double mbps_scalar = bytes_io / (us_scalar * 1e3);
    const double mbps_accel  = bytes_io / (us_accel * 1e3);
    printf("  quant  k=%-5lld  scalar: %7.2f us (%.0f MB/s)  accel: %7.2f us (%.0f MB/s)  speedup: %.2fx\n",
           (long long) k, us_scalar, mbps_scalar, us_accel, mbps_accel, speedup);
    return 0;
}

int bench_meta(int64_t n_rows, int64_t n_pages) {
    const int64_t n_lanes_per_row = n_pages * TILE640_LANES_PER_PAGE;
    std::vector<uint16_t> page_scales((size_t) (n_rows * n_pages));
    std::vector<int8_t> lane_scales((size_t) (n_rows * n_lanes_per_row));
    std::vector<float> page_max((size_t) (n_rows * n_pages));
    std::vector<float> lane_scale((size_t) (n_rows * n_lanes_per_row));
    std::mt19937 rng(kSeed);
    std::uniform_int_distribution<int> ls_dist(-127, 127);
    for (int64_t i = 0; i < n_rows * n_pages; i++) {
        page_scales[(size_t) i] = (uint16_t) 0x3C00u;  // 1.0 in fp16
    }
    for (int64_t i = 0; i < n_rows * n_lanes_per_row; i++) {
        lane_scales[(size_t) i] = (int8_t) ls_dist(rng);
    }
    // Sink so the compiler can't DCE the writes.
    volatile float sink = 0.0f;
    const double us_scalar = time_fn([&]() {
        ts_decode_per_row_meta(page_scales.data(), lane_scales.data(),
                               n_rows, n_pages,
                               page_max.data(), lane_scale.data(),
                               /*use_accel=*/false);
        sink += lane_scale[0];
    });
    const double us_accel = time_fn([&]() {
        ts_decode_per_row_meta(page_scales.data(), lane_scales.data(),
                               n_rows, n_pages,
                               page_max.data(), lane_scale.data(),
                               /*use_accel=*/true);
        sink += lane_scale[0];
    });
    const double speedup = (us_accel > 0.0) ? us_scalar / us_accel : 0.0;
    // Total elements processed (so the table is comparable
    // across different (n_rows, n_pages) shapes).
    const int64_t elems = n_rows * (n_pages + n_lanes_per_row);
    printf("  meta   n_rows=%-4lld n_pages=%-3lld  scalar: %7.2f us  accel: %7.2f us  speedup: %.2fx  elems=%lld\n",
           (long long) n_rows, (long long) n_pages, us_scalar, us_accel, speedup,
           (long long) elems);
    (void) sink;
    return 0;
}

int bench_act_scale(int64_t n) {
    std::vector<float> y_s((size_t) n, 1.0f);
    std::vector<float> y_f = y_s;
    std::vector<uint16_t> as((size_t) n, (uint16_t) 0x3C00u);  // 1.0 in fp16
    // The function selects its path internally (accel for
    // n <= 4096 on Apple); the scalar baseline is the inline
    // loop.
    const double us_scalar = time_fn([&]() {
        for (int64_t i = 0; i < n; i++) {
            y_s[(size_t) i] *= GGML_FP16_TO_FP32(as[(size_t) i]);
        }
    });
    const double us_fn = time_fn([&]() {
        ts_apply_act_scale(y_f.data(), as.data(), n);
    });
    const double speedup = (us_fn > 0.0) ? us_scalar / us_fn : 0.0;
    printf("  act    n=%-5lld  scalar: %7.2f us  fn: %7.2f us  speedup: %.2fx\n",
           (long long) n, us_scalar, us_fn, speedup);
    return 0;
}

int bench_outlier(int64_t n_rows, int64_t k, int64_t n_outliers_per_row) {
    const int64_t n_total = n_rows * n_outliers_per_row;
    std::vector<float> rows((size_t) (n_rows * k), 0.0f);
    std::vector<int32_t> cols((size_t) n_total);
    std::vector<uint16_t> vals((size_t) n_total);
    std::vector<int32_t> row_offsets((size_t) (n_rows + 1));
    std::mt19937 rng(kSeed);
    std::uniform_int_distribution<int64_t> col_dist(0, k - 1);
    for (int64_t r = 0; r < n_rows; r++) {
        row_offsets[(size_t) r] = (int32_t) (r * n_outliers_per_row);
    }
    row_offsets[(size_t) n_rows] = (int32_t) n_total;
    for (int64_t i = 0; i < n_total; i++) {
        cols[(size_t) i] = (int32_t) col_dist(rng);
        vals[(size_t) i] = (uint16_t) 0x3C00u;
    }
    std::vector<float> rows_s = rows;
    std::vector<float> rows_a = rows;
    // Sink so the compiler can't DCE the writes.
    volatile float sink = 0.0f;
    const double us_scalar = time_fn([&]() {
        ts_apply_outlier_addback(rows_s.data(), k, n_rows,
                                 row_offsets.data(),
                                 cols.data(), vals.data(),
                                 /*use_accel=*/false);
        sink += rows_s[0];
    });
    const double us_accel = time_fn([&]() {
        ts_apply_outlier_addback(rows_a.data(), k, n_rows,
                                 row_offsets.data(),
                                 cols.data(), vals.data(),
                                 /*use_accel=*/true);
        sink += rows_a[0];
    });
    const double speedup = (us_accel > 0.0) ? us_scalar / us_accel : 0.0;
    printf("  outlier n_rows=%-4lld k=%-5lld n/row=%-5lld  scalar: %7.2f us  accel: %7.2f us  speedup: %.2fx  total=%lld\n",
           (long long) n_rows, (long long) k, (long long) n_outliers_per_row,
           us_scalar, us_accel, speedup, (long long) n_total);
    (void) sink;
    return 0;
}

// Cost model calibration: measure the accel and scalar
// per-element slopes and setup taxes for the two batched
// helpers (outlier addback and meta decode). Print the
// constants so the static cost model in ggml-quants.h and
// the regime router's policy table can be recalibrated.
//
// Method: linear fit through the (n=1, n=1024) endpoints.
//   slope     = (cost_at_1024 - cost_at_1) / (1024 - 1)
//   intercept = cost_at_1 - slope * 1
// The intercept is the "setup tax" (the cost that doesn't
// scale with n). The slope is the per-element cost.
void bench_cost_model(void) {
    // Outlier addback: n_total = n_rows * n_outliers_per_row.
    // We use n_outliers_per_row = 204 (5% of 4096, the
    // canonical Phase 0 shape). n_total ranges from 204
    // (n_rows=1) to 208896 (n_rows=1024).
    constexpr int64_t kOutlierNRowsSmall = 1;
    constexpr int64_t kOutlierNRowsLarge = 1024;
    constexpr int64_t kOutlierK          = 4096;
    constexpr int64_t kOutlierPerRow     = 204;

    auto measure_outlier = [&](int64_t n_rows) {
        const int64_t n_total = n_rows * kOutlierPerRow;
        std::vector<float> rows((size_t) (n_rows * kOutlierK), 0.0f);
        std::vector<int32_t> cols((size_t) n_total);
        std::vector<uint16_t> vals((size_t) n_total, (uint16_t) 0x3C00u);
        std::vector<int32_t> row_offsets((size_t) (n_rows + 1));
        for (int64_t r = 0; r < n_rows; r++) {
            row_offsets[(size_t) r] = (int32_t) (r * kOutlierPerRow);
        }
        row_offsets[(size_t) n_rows] = (int32_t) n_total;
        std::mt19937 rng(kSeed);
        std::uniform_int_distribution<int64_t> col_dist(0, kOutlierK - 1);
        for (int64_t i = 0; i < n_total; i++) {
            cols[(size_t) i] = (int32_t) col_dist(rng);
        }
        std::vector<float> rows_s = rows;
        std::vector<float> rows_a = rows;
        volatile float sink = 0.0f;
        const double us_scalar = time_fn([&]() {
            ts_apply_outlier_addback(rows_s.data(), kOutlierK, n_rows,
                                     row_offsets.data(),
                                     cols.data(), vals.data(),
                                     /*use_accel=*/false);
            sink += rows_s[0];
        });
        const double us_accel = time_fn([&]() {
            ts_apply_outlier_addback(rows_a.data(), kOutlierK, n_rows,
                                     row_offsets.data(),
                                     cols.data(), vals.data(),
                                     /*use_accel=*/true);
            sink += rows_a[0];
        });
        (void) sink;
        return std::pair<double, double>{ us_scalar, us_accel };
    };
    const auto [us_s_small, us_a_small] = measure_outlier(kOutlierNRowsSmall);
    const auto [us_s_large, us_a_large] = measure_outlier(kOutlierNRowsLarge);
    // Per-outlier slopes (us per outlier in n_total).
    const double n_total_small = (double) (kOutlierNRowsSmall * kOutlierPerRow);
    const double n_total_large = (double) (kOutlierNRowsLarge * kOutlierPerRow);
    const double s_per_outlier = (us_s_large - us_s_small) / (n_total_large - n_total_small);
    const double a_per_outlier = (us_a_large - us_a_small) / (n_total_large - n_total_small);
    const double s_setup_tax   = us_s_small - s_per_outlier * n_total_small;
    const double a_setup_tax   = us_a_small - a_per_outlier * n_total_small;

    printf("cost model constants (linear fit, n_rows=1 and n_rows=1024 endpoints):\n");
    printf("  outlier addback (per outlier in n_total):\n");
    printf("    scalar: setup_tax=%6.3f us  per_outlier=%9.6f us\n", s_setup_tax, s_per_outlier);
    printf("    accel:  setup_tax=%6.3f us  per_outlier=%9.6f us\n", a_setup_tax, a_per_outlier);
    if (s_per_outlier > a_per_outlier) {
        const double crossover = a_setup_tax / (s_per_outlier - a_per_outlier);
        printf("    crossover (n_total): %.1f (accel wins below this)\n", crossover);
    } else {
        printf("    scalar is faster per outlier; accel never wins on per-row cost\n");
    }
    // Note: the accel path has an internal n_total <= 1024
    // NEON scratch cap (TS_T640_OUTLIER_ACCEL_MAX_N_TOTAL).
    // Above that, use_accel=true runs the scalar path, and the
    // static cost model never picks it there.

    // Meta decode: n_pages = 16, sweep n_rows.
    constexpr int64_t kMetaNRowsSmall = 1;
    constexpr int64_t kMetaNRowsLarge = 1024;
    constexpr int64_t kMetaNPages     = 16;

    auto measure_meta = [&](int64_t n_rows) {
        const int64_t n_lanes_per_row = kMetaNPages * TILE640_LANES_PER_PAGE;
        std::vector<uint16_t> page_scales((size_t) (n_rows * kMetaNPages), (uint16_t) 0x3C00u);
        std::vector<int8_t> lane_scales((size_t) (n_rows * n_lanes_per_row));
        std::mt19937 rng(kSeed);
        std::uniform_int_distribution<int> ls_dist(-127, 127);
        for (int64_t i = 0; i < (int64_t) lane_scales.size(); i++) {
            lane_scales[(size_t) i] = (int8_t) ls_dist(rng);
        }
        std::vector<float> page_max((size_t) (n_rows * kMetaNPages));
        std::vector<float> lane_scale((size_t) (n_rows * n_lanes_per_row));
        volatile float sink = 0.0f;
        const double us_scalar = time_fn([&]() {
            ts_decode_per_row_meta(page_scales.data(), lane_scales.data(),
                                   n_rows, kMetaNPages,
                                   page_max.data(), lane_scale.data(),
                                   /*use_accel=*/false);
            sink += lane_scale[0];
        });
        const double us_accel = time_fn([&]() {
            ts_decode_per_row_meta(page_scales.data(), lane_scales.data(),
                                   n_rows, kMetaNPages,
                                   page_max.data(), lane_scale.data(),
                                   /*use_accel=*/true);
            sink += lane_scale[0];
        });
        (void) sink;
        return std::pair<double, double>{ us_scalar, us_accel };
    };
    const auto [us_ms_small, us_ma_small] = measure_meta(kMetaNRowsSmall);
    const auto [us_ms_large, us_ma_large] = measure_meta(kMetaNRowsLarge);
    const double s_per_row = (us_ms_large - us_ms_small) / (double) (kMetaNRowsLarge - kMetaNRowsSmall);
    const double a_per_row = (us_ma_large - us_ma_small) / (double) (kMetaNRowsLarge - kMetaNRowsSmall);
    const double s_meta_setup = us_ms_small - s_per_row * (double) kMetaNRowsSmall;
    const double a_meta_setup = us_ma_small - a_per_row * (double) kMetaNRowsSmall;
    printf("  meta decode (per row in n_rows, n_pages=16):\n");
    printf("    scalar: setup_tax=%6.3f us  per_row=%9.6f us\n", s_meta_setup, s_per_row);
    printf("    accel:  setup_tax=%6.3f us  per_row=%9.6f us\n", a_meta_setup, a_per_row);
    if (s_per_row > a_per_row) {
        const double crossover = a_meta_setup / (s_per_row - a_per_row);
        printf("    crossover (n_rows): %.1f (accel wins below this)\n", crossover);
    } else {
        printf("    scalar is faster per row; accel never wins on per-row cost\n");
    }
}

// Cost model dispatch picks: for each bench shape, print what
// the static cost model (ts_t640_outlier_accel_wins /
// ts_t640_meta_accel_wins) would choose.
void bench_dispatch_picks(void) {
    printf("static cost model picks per shape:\n");
    printf("  meta decode (accel iff n_rows * n_pages >= %d):\n",
           TS_T640_META_DECODE_MIN_N_TOTAL_PAGES);
    for (int64_t n_rows : { (int64_t) 1, (int64_t) 16, (int64_t) 64, (int64_t) 256, (int64_t) 1024 }) {
        printf("    n_rows=%-4lld n_pages=16 -> %s\n",
               (long long) n_rows,
               ts_t640_meta_accel_wins(n_rows, 16) ? "accel" : "scalar");
    }
    printf("  outlier addback (accel iff n_total in (0, %d]):\n",
           TS_T640_OUTLIER_ACCEL_MAX_N_TOTAL);
    struct Shape { int64_t n_rows; int64_t k; int64_t n_per_row; };
    const Shape shapes[] = {
        {   1, 1024,  51 },  // n_total=51
        {   1, 4096, 204 },  // n_total=204
        {   1, 8192, 409 },  // n_total=409
        {  16, 4096, 204 },  // n_total=3264
        {  64, 4096, 204 },  // n_total=13056
        { 256, 4096, 204 },  // n_total=52224
        {1024, 4096, 204 },  // n_total=208896
    };
    for (const auto & s : shapes) {
        const int64_t n_total = s.n_rows * s.n_per_row;
        printf("    n_rows=%-4lld k=%-5lld n/row=%-5lld n_total=%-7lld -> %s\n",
               (long long) s.n_rows, (long long) s.k, (long long) s.n_per_row,
               (long long) n_total,
               ts_t640_outlier_accel_wins(n_total) ? "accel" : "scalar");
    }
}

}  // namespace

int main(void) {
    printf("accel flag: %s (env GGML_TESSERA_T640_ACCEL_DISABLE)\n",
           ggml_tessera_t640_accel_enabled() ? "on" : "off");
    printf("dequant (per row, fp32 out):\n");
    bench_dequant(640);
    bench_dequant(1024);
    bench_dequant(1280);
    bench_dequant(2560);
    bench_dequant(4096);
    bench_dequant(8192);
    printf("quant (per row, fp32 in):\n");
    bench_quant(640);
    bench_quant(1024);
    bench_quant(1280);
    bench_quant(2560);
    bench_quant(4096);
    bench_quant(8192);
    printf("meta decode (batched, n_rows * n_pages pages per call):\n");
    bench_meta(1, 1);
    bench_meta(1, 16);
    bench_meta(16, 16);
    bench_meta(64, 16);
    bench_meta(256, 16);
    bench_meta(1024, 16);
    printf("act_scale (per row, n = in_dim):\n");
    bench_act_scale(1024);
    bench_act_scale(4096);
    bench_act_scale(8192);
    printf("outlier addback (batched, sparse 5%%, n_rows rows per call):\n");
    bench_outlier(1, 1024, 51);
    bench_outlier(1, 4096, 204);
    bench_outlier(1, 8192, 409);
    bench_outlier(16, 4096, 204);
    bench_outlier(64, 4096, 204);
    bench_outlier(256, 4096, 204);
    bench_outlier(1024, 4096, 204);
    bench_cost_model();
    bench_dispatch_picks();
    return 0;
}
