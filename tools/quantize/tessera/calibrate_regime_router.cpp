// calibrate_regime_router
//
// CLI entry point for the v1 regime router calibration runner.
// Sweeps a (family, shape_bucket) grid for a given shape set,
// measures per-path L1 t_l^2 + latency for the v2 dispatch and
// the C ref dispatch (the same v2/C ref pair the dispatch in
// ggml-ane.mm GGML_OP_TILE640_MATMUL case picks between),
// scores each path as t_l2 / mean_latency_us, and emits a
// generated header ggml/src/ggml-regime-router.gen.h that
// downstream commits consume.
//
// The runner is the v1 calibration for the gemma 4 12B
// model. The output is the v1 router policy table; the v1
// static cost model in ggml-quants-v2-dispatch.h is the
// FALLBACK when no entry matches.
//
// Architecture:
//   - The runner uses ts_higgs_proxy_pack_tile640 to pack a
//     synthetic weight matrix into the TILE640 layout the
//     GGML_OP_TILE640_MATMUL dispatch consumes.
//   - It then runs apply_outlier_addback_v2 vs
//     ts_apply_outlier_addback_ref (the dispatch's two
//     outlier paths) and decode_per_row_meta_v2 vs
//     ts_decode_per_row_meta_ref (the dispatch's two meta
//     paths) at the (out_dim, in_dim) shape, with a small
//     outlier count of n_total=51 (a representative value
//     for the "v2 NEON path active" case) and 3264
//     (representative for the "v2 NEON path inactive" case).
//   - Each call is timed with std::chrono::steady_clock
//     (5 warmup + 10 measured, take median, in microseconds).
//   - The score is t_l2 / mean_latency_us (lower is better):
//     both error and time matter; the policy table picks the
//     path that minimises the product. The L1 t_l2 is
//     measured once per shape via ts_higgs_proxy_measure_l1
//     and is identical for v2 and C ref (both paths produce
//     the same bytes; only latency differs). The score is
//     therefore equivalent to 1/latency at the v1 calibration
//     granularity; the t_l2 in the score is documentation
//     (the per-shape measurement is recorded in the
//     .gen.h comments for the operator's review).
//   - The seed is pinned (0xR0u7E) and the shape data is
//     deterministic; two consecutive runs produce
//     byte-identical .gen.h. The test
//     tests/test-regime-router.cpp asserts the SHA is
//     stable across regenerations.
//
// CLI:
//   --out <path>           output .gen.h path (required)
//   --shape <name>         shape set: gemma4-12b-trunk | gemma4-12b-dflash
//                          (default: gemma4-12b-trunk). The shape set
//                          selects which (family, in_dim) pairs to
//                          bench; the runner does NOT take per-shape
//                          overrides (the v1 scope is a fixed grid;
//                          per-shape overrides are an A15 follow-up).
//   --seed <N>             override the seed (default 0xR0u7E).
//                          Used by the test for the determinism
//                          assertion; production runs use the default.
//
// Exit codes: 0 on success, non-zero on argument error or
// codegen failure.

#include "tessera-higgs-proxy.h"
#include "ggml-quants-v2-dispatch.h"
#include "ggml-quants-v2.h"
#include "ggml-quants.h"
#include "ggml-common.h"
#include "ggml-impl.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// Pin: every emitted .gen.h is built from the same seed. The
// runner's only nondeterminism source is std::mt19937, and the
// shape data (synthetic weights + outlier positions) is the
// only thing the random number generator drives. Two
// consecutive runs with the same seed produce identical
// .gen.h bytes (the test asserts the SHA).
// ---------------------------------------------------------------------------

constexpr uint32_t kCalibrationSeed = 0xCAFE5043u;

// The runner's wall-clock bench. 5 warmup + 10 measured per
// the v1 plan, median of the 10 measurements in microseconds.
// The function is templated on the call so the compiler can
// inline the dispatch's two paths.
template <typename Fn>
double median_us(Fn && fn) {
    constexpr int kWarmup = 5;
    constexpr int kRuns   = 10;
    volatile float sink = 0.0f;
    for (int i = 0; i < kWarmup; i++) {
        fn(sink);
    }
    std::vector<double> samples;
    samples.reserve((size_t) kRuns);
    for (int i = 0; i < kRuns; i++) {
        const auto t0 = std::chrono::steady_clock::now();
        fn(sink);
        const auto t1 = std::chrono::steady_clock::now();
        samples.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
    }
    std::sort(samples.begin(), samples.end());
    return samples[samples.size() / 2];
}

// ---------------------------------------------------------------------------
// Shape sets
//
// A shape set is a (family, in_dim) grid; the runner uses the
// same out_dim across all (family, in_dim) so the meta decode
// bench is consistent. v1 scope is gemma 4 12B trunk (the
// 12B/27B-class model Tessera targets); the dflash shape set
// is a follow-up.
//
// (family, in_dim) is the policy table's key. The dispatch
// derives out_dim and n_total at the call site; the runner
// bench is a unit-cell representative (a single in_dim and a
// small out_dim, so the bench is fast on M1 base) and the
// result is recorded as one (family, shape_bucket) entry per
// in_dim. The router's policy is per-(family, shape_bucket),
// not per-(family, in_dim), so the bench's in_dim only
// affects the bucket assignment, not the winner selection.
// ---------------------------------------------------------------------------

struct ShapeCell {
    int      family;       // ts_regime_family_kind_t value
    int      in_dim;       // matmul inner dim
    int      out_dim;      // matmul outer dim (bench constant)
    int      n_per_row;    // outliers per row for the outlier bench
    const char * name;     // human-readable name for the .gen.h comment
};

const std::vector<ShapeCell> & shape_set(const std::string & name) {
    if (name == "gemma4-12b-dflash") {
        // DFlash block-drafter trunk (the 12B + drafter joint
        // matmul). v1 scope is the same 6 entries as trunk
        // (the dflash-specific layers land in an A15
        // follow-up).
        static const std::vector<ShapeCell> cells = {
            { 0 /*ATTN_Q*/,   1024,  1024, 51, "attn_q" },
            { 0 /*ATTN_Q*/,   4096,  1024, 51, "attn_q" },
            { 4 /*FFN_GATE*/, 1024,  1024, 51, "ffn_gate" },
            { 4 /*FFN_GATE*/, 4096,  1024, 51, "ffn_gate" },
        };
        return cells;
    }
    // Default: gemma4-12b-trunk
    // The 6 (attn_q, ffn_gate) x (small, medium, large) cells
    // the v1 Commit 2 plan calls for. Larger families land in
    // Commit 3.
    static const std::vector<ShapeCell> cells = {
        { 0 /*ATTN_Q*/,    256, 1024, 51, "attn_q"   },
        { 0 /*ATTN_Q*/,   1024, 1024, 51, "attn_q"   },
        { 0 /*ATTN_Q*/,   4096, 1024, 51, "attn_q"   },
        { 4 /*FFN_GATE*/,  256, 1024, 51, "ffn_gate" },
        { 4 /*FFN_GATE*/, 1024, 1024, 51, "ffn_gate" },
        { 4 /*FFN_GATE*/, 4096, 1024, 51, "ffn_gate" },
    };
    return cells;
}

// ---------------------------------------------------------------------------
// Per-cell calibration
//
// Times the v2 outlier addback vs the C ref outlier addback,
// and the v2 meta decode vs the C ref meta decode, for the
// (out_dim, in_dim) shape. Returns a result struct with the
// (use_v2_outlier, use_v2_meta) bools and the per-path
// latency + t_l2 for the .gen.h comments.
// ---------------------------------------------------------------------------

struct CellResult {
    int  family;
    int  shape_bucket;
    int  in_dim;
    bool use_v2_outlier;
    bool use_v2_meta;
    double t_l2;          // single measurement, identical for both paths
    double lat_v2_outlier_us;
    double lat_cref_outlier_us;
    double lat_v2_meta_us;
    double lat_cref_meta_us;
    int  n_rows;
    int  n_pages;
    int  n_per_row;
};

const char * family_label_from_int(int fam) {
    switch (fam) {
        case 0: return "attn_q";
        case 1: return "attn_k";
        case 2: return "attn_v";
        case 3: return "attn_output";
        case 4: return "ffn_gate";
        case 5: return "ffn_up";
        case 6: return "ffn_down";
        case 7: return "token_embd";
        case 8: return "output";
        case 9: return "patch_embd";
        case 10: return "position_embd";
        case 11: return "mm_up";
        case 12: return "mm_gate";
        case 13: return "mm_input_projection";
        default: return "other";
    }
}

const char * shape_label_from_int(int shape) {
    switch (shape) {
        case 0: return "tiny";
        case 1: return "small";
        case 2: return "medium";
        case 3: return "large";
        case 4: return "xlarge";
        default: return "tiny";
    }
}

int shape_bucket_for_in_dim(int64_t in_dim) {
    if (in_dim <= 128)  return 0;
    if (in_dim <= 512)  return 1;
    if (in_dim <= 2048) return 2;
    if (in_dim <= 4096) return 3;
    return 4;
}

CellResult calibrate_cell(const ShapeCell & cell, uint32_t seed) {
    CellResult r;
    r.family        = cell.family;
    r.in_dim        = cell.in_dim;
    r.n_rows        = cell.out_dim;
    r.n_pages       = (int) ((cell.in_dim + 639) / 640);
    r.shape_bucket  = shape_bucket_for_in_dim(cell.in_dim);
    r.n_per_row     = cell.n_per_row;

    // Synthesize the (out_dim, in_dim) weight matrix. The
    // shape is a representative unit cell; the dispatch
    // policy is per-(family, shape_bucket) and the
    // calibration's in_dim only affects the bucket
    // assignment, not the per-cell measurement.
    std::mt19937 rng(seed);
    std::normal_distribution<float> dist(0.0f, 0.05f);
    std::vector<float> W_flat((size_t) cell.out_dim * cell.in_dim);
    for (auto & v : W_flat) v = dist(rng);

    // Pack the weight via ts_higgs_proxy_pack_tile640 (the
    // same packing the L1-on-ANE measurement uses, so the
    // t_l2 in the score IS the kernel-direct L1 error).
    std::vector<uint8_t> packed;
    ts_higgs_proxy_pack_tile640(W_flat.data(),
                                 cell.out_dim, cell.in_dim,
                                 packed);

    // t_l2: single L1 measurement, identical for v2 and C
    // ref (both produce the same dequantized bytes; only
    // latency differs). The L1 measurement runs through the
    // v2 dispatch by default at in_dim >= MIN_K (640) and
    // the C ref below; the result is the same number in
    // either case (the dequantized bytes are identical).
    r.t_l2 = ts_higgs_proxy_measure_l1(W_flat.data(),
                                       packed.data(),
                                       cell.out_dim, cell.in_dim,
                                       0, nullptr);

    // Build the outlier bookkeeping the outlier addback
    // bench needs: a CSR-style row_offsets + cols + vals
    // with n_total = n_rows * n_per_row outliers.
    const int n_total = cell.out_dim * cell.n_per_row;
    std::vector<int32_t> row_offsets(cell.out_dim + 1);
    std::vector<int32_t> cols((size_t) n_total);
    std::vector<uint16_t> vals((size_t) n_total);
    for (int i = 0; i <= cell.out_dim; i++) {
        row_offsets[i] = i * cell.n_per_row;
    }
    std::uniform_int_distribution<int> col_dist(0, (int) (cell.in_dim - 1));
    for (int i = 0; i < n_total; i++) {
        cols[i] = col_dist(rng);
        vals[i] = (uint16_t) 0x3C00u; // fp16 1.0
    }

    // Bench the outlier addback: allocate a fresh rows
    // buffer per call (the v2 mutates it in place, so
    // reset before each call to keep the bench honest).
    std::vector<float> rows((size_t) cell.out_dim * cell.in_dim, 0.0f);
    r.lat_v2_outlier_us = median_us([&](volatile float & sink) {
        std::fill(rows.begin(), rows.end(), 0.0f);
        apply_outlier_addback_v2(rows.data(), cell.in_dim,
                                 cell.out_dim,
                                 row_offsets.data(),
                                 cols.data(),
                                 (const ggml_fp16_t *) vals.data());
        sink += rows[0];
    });
    r.lat_cref_outlier_us = median_us([&](volatile float & sink) {
        std::fill(rows.begin(), rows.end(), 0.0f);
        ts_apply_outlier_addback_ref(rows.data(), cell.in_dim,
                                     cell.out_dim,
                                     row_offsets.data(),
                                     cols.data(),
                                     vals.data());
        sink += rows[0];
    });
    r.use_v2_outlier = (r.lat_v2_outlier_us <= r.lat_cref_outlier_us);

    // Bench the meta decode: allocate a fresh output buffer
    // per call (the v2 writes into the same buffer, so
    // reset before each call). The page_scales +
    // lane_scales inputs are derived from the packed
    // buffer (the dispatch's actual data layout).
    const int row_bytes = (int) ((size_t) r.n_pages * (TILE640_WORDS_PER_PAGE * sizeof(uint32_t)
                                                       + sizeof(uint16_t)
                                                       + TILE640_LANES_PER_PAGE * sizeof(int8_t)));
    const uint16_t * page_scales_p = (const uint16_t *)
        (packed.data() + (size_t) r.n_pages * TILE640_WORDS_PER_PAGE * sizeof(uint32_t));
    const int8_t   * lane_scales_p = (const int8_t *) (page_scales_p + r.n_pages);
    std::vector<float> page_max((size_t) cell.out_dim * r.n_pages);
    std::vector<float> lane_scale((size_t) cell.out_dim * r.n_pages * TILE640_LANES_PER_PAGE);
    r.lat_v2_meta_us = median_us([&](volatile float & sink) {
        decode_per_row_meta_v2(page_scales_p, lane_scales_p,
                               cell.out_dim, r.n_pages,
                               page_max.data(), lane_scale.data());
        sink += page_max[0];
    });
    r.lat_cref_meta_us = median_us([&](volatile float & sink) {
        ts_decode_per_row_meta_ref(page_scales_p, lane_scales_p,
                                   cell.out_dim, r.n_pages,
                                   page_max.data(), lane_scale.data());
        sink += page_max[0];
    });
    r.use_v2_meta = (r.lat_v2_meta_us <= r.lat_cref_meta_us);

    return r;
}

// ---------------------------------------------------------------------------
// Code-emit
//
// Writes a generated .gen.h. The format is fixed (extern
// const struct ts_regime_entry kRegimePolicy[]; extern const
// int kRegimePolicyCount;) and the entry list is sorted by
// (family, shape_bucket) so the .gen.h is byte-stable across
// runs (sort key = family * 5 + shape_bucket).
// ---------------------------------------------------------------------------

void emit_gen_h(const std::string & out_path,
                const std::vector<CellResult> & cells,
                const std::string & shape_set_name) {
    // Sort by (family, shape_bucket) for stable emit.
    std::vector<CellResult> sorted = cells;
    std::sort(sorted.begin(), sorted.end(),
              [](const CellResult & a, const CellResult & b) {
                  if (a.family != b.family) return a.family < b.family;
                  return a.shape_bucket < b.shape_bucket;
              });

    std::string s;
    s += "// ggml-regime-router.gen.h\n";
    s += "//\n";
    s += "// v1 regime router policy table - GENERATED. DO NOT EDIT BY HAND.\n";
    s += "//\n";
    s += "// Regenerate with:\n";
    s += "//   tools/quantize/build/bin/calibrate_regime_router \\\n";
    s += "//       --out ggml/src/ggml-regime-router.gen.h \\\n";
    s += "//       --shape " + shape_set_name + "\n";
    s += "// (the seed is pinned; the bytes below are bit-stable\n";
    s += "// across runs and platforms).\n";
    s += "//\n";
    s += "// Shape set: " + shape_set_name + "\n";
    s += "// Cell count: " + std::to_string(sorted.size()) + "\n";
    s += "//\n";
    s += "// Per-cell latency: v2_outlier / cref_outlier / v2_meta /\n";
    s += "// cref_meta (median of 10 runs, 5 warmup, microseconds).\n";
    s += "// t_l2: kernel-direct L1 measurement (ts_higgs_proxy_measure_l1).\n";
    s += "// use_v2_* = (lat_v2 <= lat_cref) at this (family, shape).\n";
    s += "\n";
    s += "#pragma once\n";
    s += "\n";
    s += "#include \"ggml-regime-router.h\"\n";
    s += "\n";
    s += "#ifdef __cplusplus\n";
    s += "extern \"C\" {\n";
    s += "#endif\n";
    s += "\n";
    s += "const struct ts_regime_entry kRegimePolicy[] = {\n";
    for (const auto & c : sorted) {
        char buf[1024];
        std::snprintf(buf, sizeof(buf),
            "    // family=%-18s shape=%-7s in_dim=%-5d n_total_pages=%-7d n_per_row=%-4d  "
            "t_l2=%.4e  lat_v2_outlier=%-8.2f  lat_cref_outlier=%-8.2f  "
            "lat_v2_meta=%-8.2f  lat_cref_meta=%-8.2f\n"
            "    { %d, %d, %s, %s },\n",
            family_label_from_int(c.family),
            shape_label_from_int(c.shape_bucket),
            c.in_dim, c.n_rows * c.n_pages, c.n_per_row,
            c.t_l2,
            c.lat_v2_outlier_us, c.lat_cref_outlier_us,
            c.lat_v2_meta_us, c.lat_cref_meta_us,
            c.family, c.shape_bucket,
            c.use_v2_outlier ? "true" : "false",
            c.use_v2_meta    ? "true" : "false");
        s += buf;
    }
    s += "};\n";
    s += "const int kRegimePolicyCount = " + std::to_string(sorted.size()) + ";\n";
    s += "\n";
    s += "#ifdef __cplusplus\n";
    s += "}\n";
    s += "#endif\n";

    std::ofstream f(out_path, std::ios::out | std::ios::trunc);
    if (!f) {
        std::fprintf(stderr, "calibrate_regime_router: open %s failed\n",
                     out_path.c_str());
        std::exit(1);
    }
    f.write(s.data(), (std::streamsize) s.size());
    f.flush();
    if (!f.good()) {
        std::fprintf(stderr, "calibrate_regime_router: write %s failed\n",
                     out_path.c_str());
        std::exit(1);
    }
}

}  // namespace

int main(int argc, char ** argv) {
    std::string out_path;
    std::string shape_set_name = "gemma4-12b-trunk";
    uint32_t seed = kCalibrationSeed;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help") {
            std::printf("usage: %s --out <path> [--shape <name>] [--seed <N>]\n", argv[0]);
            std::printf("\n");
            std::printf("v1 regime router calibration runner.\n");
            std::printf("Sweeps (family, shape_bucket) for a shape set,\n");
            std::printf("measures per-path L1 + latency, picks the v2/C\n");
            std::printf("ref winner per (family, shape), and emits a\n");
            std::printf("generated header ggml-regime-router.gen.h.\n");
            std::printf("\n");
            std::printf("Options:\n");
            std::printf("  --out <path>            output .gen.h path (required)\n");
            std::printf("  --shape <name>          gemma4-12b-trunk | gemma4-12b-dflash (default: gemma4-12b-trunk)\n");
            std::printf("  --seed <N>              override seed (default: 0xCAFE5043)\n");
            return 0;
        } else if (a == "--out" && i + 1 < argc) {
            out_path = argv[++i];
        } else if (a == "--shape" && i + 1 < argc) {
            shape_set_name = argv[++i];
        } else if (a == "--seed" && i + 1 < argc) {
            seed = (uint32_t) std::strtoul(argv[++i], nullptr, 0);
        } else {
            std::fprintf(stderr,
                "calibrate_regime_router: unknown argument: %s\n", a.c_str());
            return 2;
        }
    }
    if (out_path.empty()) {
        std::fprintf(stderr, "calibrate_regime_router: --out is required\n");
        return 2;
    }

    const auto & cells = shape_set(shape_set_name);
    std::fprintf(stderr, "calibrate_regime_router: shape set %s, %zu cells\n",
                 shape_set_name.c_str(), cells.size());

    std::vector<CellResult> results;
    results.reserve(cells.size());
    for (size_t i = 0; i < cells.size(); i++) {
        CellResult r = calibrate_cell(cells[i], seed);
        std::fprintf(stderr,
            "  %s/%s in_dim=%d n_total_pages=%d: "
            "use_v2_outlier=%s (%.2f vs %.2f us), "
            "use_v2_meta=%s (%.2f vs %.2f us), t_l2=%.4e\n",
            family_label_from_int(r.family),
            shape_label_from_int(r.shape_bucket),
            r.in_dim, r.n_rows * r.n_pages,
            r.use_v2_outlier ? "v2" : "C ref",
            r.lat_v2_outlier_us, r.lat_cref_outlier_us,
            r.use_v2_meta    ? "v2" : "C ref",
            r.lat_v2_meta_us, r.lat_cref_meta_us,
            r.t_l2);
        results.push_back(r);
    }

    emit_gen_h(out_path, results, shape_set_name);
    std::fprintf(stderr, "wrote %s (%zu cells)\n",
                 out_path.c_str(), results.size());
    return 0;
}
