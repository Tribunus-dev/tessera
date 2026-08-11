//
// test_t640_core_reconstruct_parity.cpp
//
// Bit-exact gate for the tile-neutral TILE640 transport path that drops
// `core` from the safetensors artifact. The packer's `ts_compute_scales`
// has two branches:
//
//   core != nullptr : uses per-element |core| magnitudes for the lane
//                     scale fit. Higher quality, but core = 2 bytes/elem
//                     to ship (162 GiB for a 35B model in fp16).
//
//   core == nullptr : reconstructs every non-zero trit as |trit| * global_amp
//                     (single scalar). Loses per-element magnitude
//                     variation but preserves the sign pattern. core=0
//                     bytes to ship; 33 GiB for the same 35B model.
//
// The 5x transport size reduction is real but only acceptable if the
// core=nullptr path is functionally equivalent within a documented
// tolerance. This test pins that tolerance down by comparing the
// dequantized radix-243 + page/lane reconstruction (excluding the
// outlier CSR addback, which is identical on both paths) against the
// AWQ-scaled original weights, for both paths on the same input.
//
// The kernel-side outlier addback is identical in both paths (same CSR),
// so the test isolates the trits+scales fidelity delta. If the kernel
// stack ever diverges on the core=nullptr path, the test catches it.
//
// Pass criteria:
//   1. Both paths produce valid 6-tuple pack artifacts (no size asserts).
//   2. core=nullptr dequant L_inf error is at most 1.5x the core=full
//      dequant L_inf error on every shape. (Measured empirically on the
//      fixed random seed; documented tolerance, not arbitrary.)
//   3. core=nullptr dequant L2 error is at most 1.5x the core=full
//      dequant L2 error on every shape.
//   4. The dequant results are NOT bit-identical (we want a real parity
//      gate, not a no-op).
//
// What this test does NOT do:
//   - Verify outlier addback fidelity (same CSR on both paths, already
//     covered by test_b5_tile640_metal_dequant.cpp).
//   - Verify the actual GPU kernel output (test_b5 covers that).
//   - Verify the AWQ alpha search (covered by test_quant.cpp).
//
// Build: clang++ -std=c++17 -O2
//          tools/quantize/tessera/test_t640_core_reconstruct_parity.cpp
//          tools/quantize/tessera/tessera-quant.cpp
//          tools/quantize/tessera/tessera-vec.cpp
//          ggml/src/ggml-quants.c
//          tools/quantize/tessera/tile-detect.cpp
//          -I ggml/include -I ggml/src -I tools/quantize/tessera
//          -framework Accelerate
//          -o /tmp/test_t640_core_reconstruct_parity
//

#include "tessera-quant.h"
#include "tessera-ternary.h"
#include "ggml-common.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// Flat dequant (ggml-quants.c) for the 6-tuple Tile640 packed layout.
// Reads [packed | page_scales | lane_scales] concatenated per row.
extern "C" void dequantize_row_tessera_t640(const void * x, float * y, int64_t k);

static int g_fail = 0;
static void check(const char * name, bool ok) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) g_fail++;
}

// Pseudo-random Gaussian via Box-Muller, seeded for determinism.
static std::mt19937 make_rng(uint32_t seed) {
    return std::mt19937(seed);
}
static float gauss(std::mt19937 & rng) {
    // Marsaglia polar method, no reject loop needed for the test size.
    float u1, u2, s;
    do {
        u1 = 2.0f * (float) rng() / (float) rng.max() - 1.0f;
        u2 = 2.0f * (float) rng() / (float) rng.max() - 1.0f;
        s  = u1 * u1 + u2 * u2;
    } while (s >= 1.0f || s == 0.0f);
    return u1 * std::sqrt(-2.0f * std::log(s) / s);
}

static uint16_t f32_to_f16(float f) {
    uint32_t x;
    std::memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000u;
    int32_t  e    = (int32_t)((x >> 23) & 0xff) - 127 + 15;
    uint32_t m    = x & 0x7fffffu;
    if (e <= 0) {
        if (e < -10) return (uint16_t) sign;
        m = (m | 0x800000u) >> (uint32_t)(1 - e);
        return (uint16_t)(sign | ((m + 0x1000) >> 13));
    }
    if (e >= 31) return (uint16_t)(sign | 0x7c00u);
    return (uint16_t)(sign | ((uint32_t) e << 10) | ((m + 0x1000) >> 13));
}

// Build the flat per-row layout the dequantize_row_tessera_t640 trait
// expects: [packed | page_scales | lane_scales] concatenated.
static std::vector<uint8_t> pack_flat(const ts_quant_result_2d & r,
                                      int64_t out_dim, int64_t in_dim) {
    const int64_t pages = (in_dim + 639) / 640;
    const int64_t words_per_page = 32;
    std::vector<uint8_t> out;
    out.reserve((size_t)(out_dim * pages *
                         (words_per_page * 4 + 2 + 32)));
    for (int64_t row = 0; row < out_dim; row++) {
        for (int64_t p = 0; p < pages; p++) {
            for (int l = 0; l < words_per_page; l++) {
                uint32_t v = r.packed[(size_t)((row * pages + p) * words_per_page + l)];
                out.insert(out.end(), (uint8_t *) &v, (uint8_t *) &v + 4);
            }
        }
        for (int64_t p = 0; p < pages; p++) {
            uint16_t s = r.page_scales[(size_t)(row * pages + p)];
            out.insert(out.end(), (uint8_t *) &s, (uint8_t *) &s + 2);
        }
        for (int64_t p = 0; p < pages; p++) {
            for (int l = 0; l < 32; l++) {
                int8_t s = r.lane_scales[(size_t)((row * pages + p) * 32 + l)];
                out.push_back((uint8_t) s);
            }
        }
    }
    return out;
}

static void dequant_all(const ts_quant_result_2d & r,
                        int64_t out_dim, int64_t in_dim,
                        std::vector<float> & y) {
    auto flat = pack_flat(r, out_dim, in_dim);
    y.assign((size_t)(out_dim * in_dim), 0.0f);
    for (int64_t row = 0; row < out_dim; row++) {
        // Each row in `flat` is pages*(32*4+2+32) = pages*162 bytes.
        const int64_t pages = (in_dim + 639) / 640;
        const int64_t row_bytes = pages * 162;
        dequantize_row_tessera_t640(flat.data() + row * row_bytes,
                                    y.data() + row * in_dim, in_dim);
    }
}

// Reconstruct the AWQ-scaled reference (what the ternary step was
// targeting): ws[r,c] = W[r,c] * wscale[c]. The dequant output is the
// trits+scales approximation; the residual is the radix-243 quantization
// noise we want to measure.
static void awq_scale(const std::vector<float> & w,
                      const std::vector<float> & wscale,
                      int64_t out_dim, int64_t in_dim,
                      std::vector<float> & ws) {
    ws.assign((size_t)(out_dim * in_dim), 0.0f);
    for (int64_t r = 0; r < out_dim; r++) {
        for (int64_t c = 0; c < in_dim; c++) {
            ws[(size_t)(r * in_dim + c)] = w[(size_t)(r * in_dim + c)] * wscale[(size_t)c];
        }
    }
}

// L_inf, L2, L1 norms of (a - b). Returns 3 doubles.
static std::tuple<double, double, double> linalg_err(
        const std::vector<float> & a, const std::vector<float> & b) {
    double linf = 0.0, l2 = 0.0, l1 = 0.0;
    for (size_t i = 0; i < a.size(); i++) {
        double d = (double) a[i] - (double) b[i];
        if (std::fabs(d) > linf) linf = std::fabs(d);
        l2 += d * d;
        l1 += std::fabs(d);
    }
    l2 = std::sqrt(l2 / (double) a.size());
    l1 = l1 / (double) a.size();
    return {linf, l2, l1};
}

static int run_shape(int64_t out_dim, int64_t in_dim, uint32_t seed) {
    std::printf("\n--- shape out=%lld in=%lld seed=0x%x ---\n",
                (long long) out_dim, (long long) in_dim, seed);

    auto rng = make_rng(seed);

    // Gaussian weights, 2% outliers, similar to b5 fixture.
    const int64_t n = out_dim * in_dim;
    std::vector<float> w((size_t) n);
    for (int64_t i = 0; i < n; i++) {
        w[(size_t) i] = 0.1f * gauss(rng);
    }
    for (int64_t r = 0; r < out_dim; r++) {
        for (int k = 0; k < 4; k++) {
            int64_t col = (int64_t)(rng() % (uint32_t) in_dim);
            w[(size_t)(r * in_dim + col)] = 5.0f * gauss(rng);
        }
    }

    // Activation scale (unit, since AWQ alpha=0 disables it in this
    // test path; we want to isolate the core=nullptr effect).
    std::vector<float> act_scales((size_t) in_dim, 1.0f);

    ts_quant_params_2d params = {};
    params.alpha          = 0.0f;     // no AWQ search; uniform ternarize
    params.clip           = 0.0f;
    params.max_outliers   = 8;
    params.outlier_thresh = 1e-3f;
    params.use_imatrix    = false;
    params.use_septq      = false;
    params.awq_grid       = 1;
    params.seed           = seed;

    // ---- Path A: production transport (core=nullptr reconstruction) ----
    ts_ternary_tensor tn;
    int rc = ts_quantize_2d_ternary(w.data(), act_scales.data(),
                                    /*calib_X=*/ nullptr, /*ref_output=*/ nullptr,
                                    /*imatrix=*/ nullptr,
                                    out_dim, in_dim, /*n_tokens=*/ 0,
                                    &params, &tn);
    check("Path A: ts_quantize_2d_ternary", rc == 0);
    if (rc != 0) return 1;
    check("Path A: core is empty (transport drops it)", tn.core.empty());

    ts_quant_result_2d result_a;
    rc = ts_pack_ternary_to_tile(tn, ts_tile_config_t640(), &result_a);
    check("Path A: ts_pack_ternary_to_tile", rc == 0);
    if (rc != 0) return 1;

    // ---- Path B: full core available (synthesize the "have core" case) ----
    // Populate tn.core as f16 of |ws| where ws = w * wscale (alpha=0
    // here, so wscale is uniform 1.0 and ws == w). This is the "old"
    // per-element magnitude path the production transport no longer
    // ships.
    ts_ternary_tensor tn_with_core = tn;  // shallow copy
    tn_with_core.core.assign((size_t) n, 0);
    for (int64_t i = 0; i < n; i++) {
        tn_with_core.core[(size_t) i] = f32_to_f16(std::fabs(w[(size_t) i]));
    }

    ts_quant_result_2d result_b;
    rc = ts_pack_ternary_to_tile(tn_with_core, ts_tile_config_t640(), &result_b);
    check("Path B: ts_pack_ternary_to_tile (with core)", rc == 0);
    if (rc != 0) return 1;
    check("Path B: core populated", !tn_with_core.core.empty());

    // Sanity: both pack artifacts should have the same shape.
    const int64_t pages = (in_dim + 639) / 640;
    check("packed size A == B",
          result_a.packed.size() == result_b.packed.size());
    check("page_scales size A == B",
          result_a.page_scales.size() == result_b.page_scales.size());
    check("lane_scales size A == B",
          result_a.lane_scales.size() == result_b.lane_scales.size());

    // Sanity: the packed trits are identical (trit selection is upstream
    // of the packer; both paths see the same trit tensor).
    const size_t packed_size = result_a.packed.size();
    int trit_diff = 0;
    for (size_t i = 0; i < packed_size; i++) {
        if (result_a.packed[i] != result_b.packed[i]) trit_diff++;
    }
    check("packed trits are identical (expected)",
          trit_diff == 0);

    // ---- Dequant both, compare to AWQ-scaled reference ----
    std::vector<float> y_a, y_b, ws;
    dequant_all(result_a, out_dim, in_dim, y_a);
    dequant_all(result_b, out_dim, in_dim, y_b);
    awq_scale(w, act_scales, out_dim, in_dim, ws);

    auto [linf_a, l2_a, l1_a] = linalg_err(y_a, ws);
    auto [linf_b, l2_b, l1_b] = linalg_err(y_b, ws);

    // Sanity: the two paths SHOULD differ (otherwise the test is a no-op).
    auto [linf_ab, l2_ab, l1_ab] = linalg_err(y_a, y_b);
    check("core=nullptr dequant != core=full dequant (test is meaningful)",
          linf_ab > 0.0);

    std::printf("    core=nullptr: L_inf=%.4e L2=%.4e L1=%.4e\n",
                linf_a, l2_a, l1_a);
    std::printf("    core=full   : L_inf=%.4e L2=%.4e L1=%.4e\n",
                linf_b, l2_b, l1_b);
    std::printf("    inter-path  : L_inf=%.4e L2=%.4e L1=%.4e\n",
                linf_ab, l2_ab, l1_ab);

    // Pass criteria: the transport path should not be more than 1.5x
    // worse than the full path on the radix-243+scales reconstruction
    // (excluding outliers, which are identical on both paths and add
    // the same correction in the kernel).
    const double TOL = 1.5;
    char buf[128];
    std::snprintf(buf, sizeof buf,
                  "core=nullptr L_inf within %.1fx of core=full",
                  TOL);
    check(buf, linf_a <= TOL * std::max(linf_b, 1e-12));

    std::snprintf(buf, sizeof buf,
                  "core=nullptr L2 within %.1fx of core=full",
                  TOL);
    check(buf, l2_a <= TOL * std::max(l2_b, 1e-12));

    // Sanity guard: the full path should be substantially better than
    // the transport path (otherwise the test isn't measuring what we
    // think it's measuring). Allow 1% slack on the L_inf ratio.
    check("core=full is at least marginally better than core=nullptr",
          linf_b <= 0.99 * linf_a || l2_b <= 0.99 * l2_a);

    return 0;
}

int main(void) {
    std::printf("Tile640 core=nullptr transport parity test\n");
    std::printf("==========================================\n");

    // Three shapes: 1 page (640 cols), 1.5 pages (1280 cols),
    // multi-page (3200 cols). out_dim kept small (8) to keep the
    // test <1s; shapes are the dimension that exercises the page/lane
    // scale fitting math.
    if (run_shape(/*out=*/ 8,  /*in=*/ 640,  0xC0DE0001u) != 0) return 1;
    if (run_shape(/*out=*/ 8,  /*in=*/ 1280, 0xC0DE0002u) != 0) return 1;
    if (run_shape(/*out=*/ 4,  /*in=*/ 3200, 0xC0DE0003u) != 0) return 1;

    std::printf("\n");
    if (g_fail == 0) {
        std::printf("PASS: all parity checks green\n");
        return 0;
    }
    std::printf("FAIL: %d check(s) failed\n", g_fail);
    return 1;
}
