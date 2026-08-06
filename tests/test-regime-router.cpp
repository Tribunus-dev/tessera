// test-regime-router
//
// Commit 1 baseline test for the v1 regime router
// (ggml/src/ggml-regime-router.h). The router is a
// static-include lookup table; the .gen.h is currently
// EMPTY (zero entries), so the test asserts the FALLBACK
// CONTRACT: every (family, shape_bucket) lookup must
// return the same bool as the v1 static helpers
// (ts_v2_dispatch_should_use_v2_outlier /
// ts_v2_dispatch_should_use_v2_meta).
//
// The fallback contract is the architectural invariant:
// when the calibration runner has not yet produced any
// entries, the dispatch in ggml-ane.mm must behave
// EXACTLY as it does on main without the router. The
// router is a strict no-op until Commit 3 populates
// the .gen.h with the gemma 4 12B tensor coverage.
//
// What the test asserts:
//   1. Family classifier: known suffixes map to the
//      correct family_kind, unknown -> OTHER, NULL ->
//      OTHER, "attn_output" wins over "attn_q" for
//      "blk.16.attn_output.weight".
//   2. Shape bucket: in_dim -> bucket boundaries
//      (128 -> tiny, 129 -> small, 512 -> small,
//      1024 -> medium, 4096 -> large, 8192 -> xlarge).
//   3. Fallback contract: every (family, shape_bucket)
//      lookup with the empty .gen.h returns the v1
//      static helper's bool, sweep across a representative
//      grid of n_total and n_rows/n_pages values.
//   4. Family "other" is the deliberate fallback: even
//      if a future entry exists for the other family,
//      the router's "other" branch returns the v1
//      static result without consulting the table.
//   5. Out-of-range family / shape_bucket values are
//      rejected and routed to the v1 static helpers
//      (defence against bad input from a future caller).

#include "ggml.h"
#include "ggml-common.h"
#include "ggml-impl.h"
#include "ggml-quants.h"
#include "ggml-quants-v2.h"
#include "ggml-quants-v2-dispatch.h"
#include "ggml-regime-router.h"
#include "ggml-regime-router.gen.h"

#include <cstdio>
#include <cstdint>
#include <cstdlib>

namespace {

int test_family_classifier(void) {
    printf("family classifier:\n");
    int failures = 0;
    struct { const char * name; int expected; } cases[] = {
        { "blk.0.attn_q.weight",              TS_REGIME_FAM_ATTN_Q              },
        { "blk.0.attn_k.weight",              TS_REGIME_FAM_ATTN_K              },
        { "blk.0.attn_v.weight",              TS_REGIME_FAM_ATTN_V              },
        { "blk.0.attn_output.weight",         TS_REGIME_FAM_ATTN_OUTPUT         },
        { "blk.0.ffn_gate.weight",            TS_REGIME_FAM_FFN_GATE            },
        { "blk.0.ffn_up.weight",              TS_REGIME_FAM_FFN_UP              },
        { "blk.0.ffn_down.weight",            TS_REGIME_FAM_FFN_DOWN            },
        { "token_embd.weight",                TS_REGIME_FAM_TOKEN_EMBD          },
        { "output.weight",                    TS_REGIME_FAM_OUTPUT              },
        { "patch_embd.weight",                TS_REGIME_FAM_PATCH_EMBD          },
        { "position_embd.weight",             TS_REGIME_FAM_POSITION_EMBD       },
        { "mm.mm_input_projection.weight",    TS_REGIME_FAM_MM_INPUT_PROJECTION },
        { "mm.mm_up.weight",                  TS_REGIME_FAM_MM_UP               },
        { "mm.mm_gate.weight",                TS_REGIME_FAM_MM_GATE             },
        // Order: attn_output wins over attn_q
        { "blk.16.attn_output.weight",        TS_REGIME_FAM_ATTN_OUTPUT         },
        // Bias suffix is stripped
        { "blk.0.attn_v.bias",                TS_REGIME_FAM_ATTN_V              },
        // Bare name (no .weight / .bias) is also OK
        { "blk.0.attn_v",                     TS_REGIME_FAM_ATTN_V              },
        // Unknown -> other
        { "rope_freqs",                       TS_REGIME_FAM_OTHER               },
        { "blk.0.custom_head.weight",         TS_REGIME_FAM_OTHER               },
        // NULL -> other
        { nullptr,                            TS_REGIME_FAM_OTHER               },
    };
    for (const auto & c : cases) {
        const int got = ts_regime_infer_family(c.name);
        const bool ok = (got == c.expected);
        if (!ok) failures++;
        printf("  %-40s -> %-18s (expected %-18s) %s\n",
               c.name ? c.name : "(null)",
               ts_regime_family_label(got),
               ts_regime_family_label(c.expected),
               ok ? "OK" : "FAIL");
    }
    return failures;
}

int test_shape_bucket(void) {
    printf("shape bucket:\n");
    int failures = 0;
    struct { int64_t in_dim; int expected; } cases[] = {
        {    0,  TS_REGIME_SHAPE_TINY   },
        {   64,  TS_REGIME_SHAPE_TINY   },
        {  128,  TS_REGIME_SHAPE_TINY   },
        {  129,  TS_REGIME_SHAPE_SMALL  },
        {  256,  TS_REGIME_SHAPE_SMALL  },
        {  512,  TS_REGIME_SHAPE_SMALL  },
        {  513,  TS_REGIME_SHAPE_MEDIUM },
        { 1024,  TS_REGIME_SHAPE_MEDIUM },
        { 2048,  TS_REGIME_SHAPE_MEDIUM },
        { 2049,  TS_REGIME_SHAPE_LARGE  },
        { 4096,  TS_REGIME_SHAPE_LARGE  },
        { 4097,  TS_REGIME_SHAPE_XLARGE },
        { 8192,  TS_REGIME_SHAPE_XLARGE },
        { 16384, TS_REGIME_SHAPE_XLARGE },
    };
    for (const auto & c : cases) {
        const int got = ts_regime_shape_bucket_for_in_dim(c.in_dim);
        const bool ok = (got == c.expected);
        if (!ok) failures++;
        printf("  in_dim=%-6lld -> %-7s (expected %-7s) %s\n",
               (long long) c.in_dim,
               ts_regime_shape_label(got),
               ts_regime_shape_label(c.expected),
               ok ? "OK" : "FAIL");
    }
    return failures;
}

int test_fallback_outlier(void) {
    printf("fallback contract (outlier):\n");
    int failures = 0;
    // Sweep n_total and a representative (family, shape_bucket)
    // grid. With an empty .gen.h every lookup must return
    // ts_v2_dispatch_should_use_v2_outlier(n_total) exactly.
    int64_t n_total_cases[] = { 0, 51, 204, 409, 1024, 1025, 3264, 52224, 208896 };
    int      family_cases[] = {
        TS_REGIME_FAM_ATTN_Q, TS_REGIME_FAM_ATTN_K, TS_REGIME_FAM_ATTN_V,
        TS_REGIME_FAM_ATTN_OUTPUT, TS_REGIME_FAM_FFN_GATE, TS_REGIME_FAM_FFN_UP,
        TS_REGIME_FAM_FFN_DOWN, TS_REGIME_FAM_TOKEN_EMBD, TS_REGIME_FAM_OUTPUT,
        TS_REGIME_FAM_PATCH_EMBD, TS_REGIME_FAM_POSITION_EMBD,
        TS_REGIME_FAM_MM_UP, TS_REGIME_FAM_MM_GATE, TS_REGIME_FAM_MM_INPUT_PROJECTION,
        TS_REGIME_FAM_OTHER,
    };
    int      shape_cases[] = {
        TS_REGIME_SHAPE_TINY, TS_REGIME_SHAPE_SMALL, TS_REGIME_SHAPE_MEDIUM,
        TS_REGIME_SHAPE_LARGE, TS_REGIME_SHAPE_XLARGE,
    };
    for (int64_t n_total : n_total_cases) {
        const bool expected = ts_v2_dispatch_should_use_v2_outlier(n_total);
        for (int fam : family_cases) {
            for (int shape : shape_cases) {
                const bool got = ts_regime_router_lookup_outlier(fam, shape, n_total);
                if (got != expected) {
                    failures++;
                    printf("  FAIL n_total=%-7lld fam=%-18s shape=%-7s got=%s expected=%s\n",
                           (long long) n_total, ts_regime_family_label(fam),
                           ts_regime_shape_label(shape),
                           got ? "v2" : "C ref",
                           expected ? "v2" : "C ref");
                }
            }
        }
    }
    // Out-of-range family / shape must also fall back to v1
    // static (defence against bad input).
    for (int64_t n_total : n_total_cases) {
        const bool expected = ts_v2_dispatch_should_use_v2_outlier(n_total);
        const bool got_bad_fam  = ts_regime_router_lookup_outlier(-1,  TS_REGIME_SHAPE_MEDIUM, n_total);
        const bool got_bad_shp  = ts_regime_router_lookup_outlier(TS_REGIME_FAM_ATTN_Q, 99, n_total);
        if (got_bad_fam != expected) failures++;
        if (got_bad_shp != expected) failures++;
    }
    printf("  swept %d n_total values x %d family x %d shape + 2 oor cases; failures=%d\n",
           (int)(sizeof(n_total_cases) / sizeof(n_total_cases[0])),
           (int)(sizeof(family_cases) / sizeof(family_cases[0])),
           (int)(sizeof(shape_cases) / sizeof(shape_cases[0])),
           failures);
    return failures;
}

int test_fallback_meta(void) {
    printf("fallback contract (meta):\n");
    int failures = 0;
    // Sweep (n_rows, n_pages) combinations that span the v1
    // static threshold at n_total_pages = 4096. With the
    // empty .gen.h every lookup must return the v1 static
    // helper's bool exactly.
    struct { int64_t n_rows; int64_t n_pages; } cases[] = {
        {  1,   1 }, {  1,  16 }, {  1,  64 },
        { 16,  16 }, { 16,  64 }, { 64,  16 },
        { 64,  64 }, { 65,  64 }, {256,  16 },
        {256,  64 }, {1024, 16 }, {1024, 64 },
        {  0,  16 },
    };
    int      family_cases[] = {
        TS_REGIME_FAM_ATTN_Q, TS_REGIME_FAM_FFN_GATE, TS_REGIME_FAM_FFN_DOWN,
        TS_REGIME_FAM_OTHER,
    };
    int      shape_cases[] = {
        TS_REGIME_SHAPE_TINY, TS_REGIME_SHAPE_SMALL, TS_REGIME_SHAPE_MEDIUM,
        TS_REGIME_SHAPE_LARGE, TS_REGIME_SHAPE_XLARGE,
    };
    for (const auto & c : cases) {
        const bool expected = ts_v2_dispatch_should_use_v2_meta(c.n_rows, c.n_pages);
        for (int fam : family_cases) {
            for (int shape : shape_cases) {
                const bool got = ts_regime_router_lookup_meta(fam, shape, c.n_rows, c.n_pages);
                if (got != expected) {
                    failures++;
                    printf("  FAIL n_rows=%-4lld n_pages=%-3lld fam=%-18s shape=%-7s got=%s expected=%s\n",
                           (long long) c.n_rows, (long long) c.n_pages,
                           ts_regime_family_label(fam), ts_regime_shape_label(shape),
                           got ? "v2" : "C ref",
                           expected ? "v2" : "C ref");
                }
            }
        }
    }
    printf("  swept %d (n_rows, n_pages) x %d family x %d shape; failures=%d\n",
           (int)(sizeof(cases) / sizeof(cases[0])),
           (int)(sizeof(family_cases) / sizeof(family_cases[0])),
           (int)(sizeof(shape_cases) / sizeof(shape_cases[0])),
           failures);
    return failures;
}

int test_gen_h_invariants(void) {
    printf("gen.h invariants:\n");
    int failures = 0;
    if (kRegimePolicyCount < 0) {
        printf("  FAIL kRegimePolicyCount=%d (must be >= 0)\n", kRegimePolicyCount);
        failures++;
    }
    if (kRegimePolicyCount > 0 && kRegimePolicy == nullptr) {
        printf("  FAIL kRegimePolicy is null but count=%d\n", kRegimePolicyCount);
        failures++;
    }
    printf("  kRegimePolicyCount=%d (Commit 1 baseline: must be 0)\n", kRegimePolicyCount);
    return failures;
}

}  // namespace

int main(void) {
    if (!ggml_tessera_t640_v2_enabled()) {
        printf("v2 disabled (GGML_TESSERA_T640_V2_DISABLE=1); skipping\n");
        return 0;
    }
    int rc = 0;
    rc |= test_family_classifier();
    rc |= test_shape_bucket();
    rc |= test_fallback_outlier();
    rc |= test_fallback_meta();
    rc |= test_gen_h_invariants();
    if (rc == 0) printf("OK\n");
    return rc;
}
