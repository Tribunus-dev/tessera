// ggml-regime-router.h
//
// v1 regime router: a learned per-(family, shape_bucket) override
// of the v1 static v2 dispatch cost model in
// ggml/src/ggml-quants-v2-dispatch.h.
//
// The static v2 dispatch (ts_v2_dispatch_should_use_v2_outlier /
// ts_v2_dispatch_should_use_v2_meta) is a single-shape threshold
// derived from the per-function M1 base 16GB bench (see
// ggml-quants-v2-dispatch.h:1-50 for the data and the rationale).
// v1 is shape-agnostic: it picks v2 for ALL n_total in (0, 1024]
// and for ALL n_total_pages >= 4096, regardless of which GGUF
// tensor the call is for. That is correct on the M1 base
// aggregate bench, but per-(family, shape) it can be off by
// 1-2x: an attn_q tensor at 256 elems behaves differently from
// an ffn_down tensor at 256 elems (different weight distributions,
// different outlier ratios, different cache residency).
//
// v1 regime router adds one layer of per-(family, shape) overrides
// on top of the static threshold. The router is a fixed
// static-include lookup table (no runtime allocation, no virtual
// dispatch, no per-call scoring); the calibration runner
// (tools/quantize/tessera/calibrate_regime_router.cpp) produces
// the .gen.h entries at build time, and the dispatch in
// ggml-ane.mm calls the lookup as a static inline. The static
// v1 helper is the FALLBACK for any (family, shape_bucket) that
// has no entry: the v1 cost model is the contract, the router
// is the override.
//
// Architecture:
//   1. The dispatch (ggml-ane.mm GGML_OP_TILE640_MATMUL) calls
//      ts_regime_router_lookup_outlier(family, n_total) and
//      ts_regime_router_lookup_meta(family, n_rows, n_pages).
//   2. Both lookups derive shape_bucket from in_dim and look up
//      kRegimePolicy[]. If a matching entry exists, its bool
//      wins. Otherwise, the helper calls the v1 static
//      ts_v2_dispatch_should_use_v2_* helper and returns its
//      result. The fallback path is the EXACT same code path
//      main has today; the router NEVER breaks the static
//      contract.
//   3. family is derived from the op's tensor name (the same
//      suffix map as ts_higgs_proxy_classify_family, plus a
//      handful of multimodal-only suffixes - patch_embd,
//      position_embd, mm_*, other). shape_bucket is derived
//      from in_dim (the matmul's inner dim, which is the
//      primary shape axis for the dispatch decision).
//
// Score formula (the calibration runner's per-cell metric):
//   score_v2 = t_l2_v2 / mean_latency_v2_us
//   score_ref = t_l2_ref / mean_latency_ref_us
//   winner = (score_v2 <= score_ref) ? use_v2 : C ref
// Both t_l2 and latency are measured; t_l2 is the
// ts_higgs_proxy_measure_l1 L1 distance (the same function the
// L1-on-ANE path uses, so the regime router's learning target
// IS the kernel-direct t_l2). The score is the per-call
// (t_l2 / us) ratio - lower is better - so the winner is the
// path that minimises the product (error x time), not the
// path that minimises either alone. See Part 6.10 of
// docs/ane-backend-deep-study.md for the rationale.

#pragma once

#include "ggml-common.h"
#include "ggml-quants-v2-dispatch.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Family key
//
// The router's family axis mirrors ts_higgs_proxy_classify_family
// (tools/quantize/tessera/tessera-higgs-proxy.cpp:83-110) plus
// the multimodal-only suffixes Tessera cares about. The enum
// value is the policy table key; the string is the
// human-readable label that lands in the .gen.h comments.
//
// The values are dense (no -1 sentinel) so the policy table is
// a flat array indexed by [family * kNumShapeBuckets +
// shape_bucket]; lookup is a single bounds check + 32-bit
// comparison, no hashing.
// ---------------------------------------------------------------------------

typedef enum {
    TS_REGIME_FAM_ATTN_Q              = 0,
    TS_REGIME_FAM_ATTN_K              = 1,
    TS_REGIME_FAM_ATTN_V              = 2,
    TS_REGIME_FAM_ATTN_OUTPUT         = 3,
    TS_REGIME_FAM_FFN_GATE            = 4,
    TS_REGIME_FAM_FFN_UP              = 5,
    TS_REGIME_FAM_FFN_DOWN            = 6,
    TS_REGIME_FAM_TOKEN_EMBD          = 7,
    TS_REGIME_FAM_OUTPUT              = 8,
    TS_REGIME_FAM_PATCH_EMBD          = 9,
    TS_REGIME_FAM_POSITION_EMBD       = 10,
    TS_REGIME_FAM_MM_UP               = 11,
    TS_REGIME_FAM_MM_GATE             = 12,
    TS_REGIME_FAM_MM_INPUT_PROJECTION = 13,
    TS_REGIME_FAM_OTHER               = 14,
    TS_REGIME_FAM_COUNT               = 15,
} ts_regime_family_kind_t;

// Human-readable family label. Stable across rebuilds (the
// .gen.h emits the same strings in comments). Mirrors
// ts_higgs_proxy_classify_family's output for the families
// both share.
static const char * ts_regime_family_label(int family) {
    switch (family) {
        case TS_REGIME_FAM_ATTN_Q:              return "attn_q";
        case TS_REGIME_FAM_ATTN_K:              return "attn_k";
        case TS_REGIME_FAM_ATTN_V:              return "attn_v";
        case TS_REGIME_FAM_ATTN_OUTPUT:         return "attn_output";
        case TS_REGIME_FAM_FFN_GATE:            return "ffn_gate";
        case TS_REGIME_FAM_FFN_UP:              return "ffn_up";
        case TS_REGIME_FAM_FFN_DOWN:            return "ffn_down";
        case TS_REGIME_FAM_TOKEN_EMBD:          return "token_embd";
        case TS_REGIME_FAM_OUTPUT:              return "output";
        case TS_REGIME_FAM_PATCH_EMBD:          return "patch_embd";
        case TS_REGIME_FAM_POSITION_EMBD:       return "position_embd";
        case TS_REGIME_FAM_MM_UP:               return "mm_up";
        case TS_REGIME_FAM_MM_GATE:             return "mm_gate";
        case TS_REGIME_FAM_MM_INPUT_PROJECTION: return "mm_input_projection";
        case TS_REGIME_FAM_OTHER:               return "other";
        default:                                return "other";
    }
}

// ---------------------------------------------------------------------------
// Shape bucket
//
// The router's shape axis. Bucketed from in_dim (the matmul's
// inner dim) so the dispatch's call site has exactly one number
// to feed in. The bucket boundaries match the canonical Phase 0
// shapes: 128 (tiny, single partial page), 256-512 (small,
// single full page + 1 partial), 1024-2048 (medium, 2-3 full
// pages), 4096 (large, 6-7 full pages), 8192+ (xlarge, 13+ full
// pages).
//
// The mapping is monotonic and dense:
//   in_dim <= 128       -> tiny
//   in_dim <= 512       -> small
//   in_dim <= 2048      -> medium
//   in_dim <= 4096      -> large
//   in_dim >  4096      -> xlarge
// Anything <= 0 maps to tiny (the dispatch's degenerate cases
// are caught by the n_total / n_rows checks, not by the bucket).
// ---------------------------------------------------------------------------

typedef enum {
    TS_REGIME_SHAPE_TINY   = 0,  // in_dim <= 128
    TS_REGIME_SHAPE_SMALL  = 1,  // 129 <= in_dim <= 512
    TS_REGIME_SHAPE_MEDIUM = 2,  // 1024 <= in_dim <= 2048
    TS_REGIME_SHAPE_LARGE  = 3,  // 4096 <= in_dim <= 4096
    TS_REGIME_SHAPE_XLARGE = 4,  // in_dim >= 8192
    TS_REGIME_SHAPE_COUNT  = 5,
} ts_regime_shape_bucket_t;

// Human-readable shape label.
static const char * ts_regime_shape_label(int shape) {
    switch (shape) {
        case TS_REGIME_SHAPE_TINY:   return "tiny";
        case TS_REGIME_SHAPE_SMALL:  return "small";
        case TS_REGIME_SHAPE_MEDIUM: return "medium";
        case TS_REGIME_SHAPE_LARGE:  return "large";
        case TS_REGIME_SHAPE_XLARGE: return "xlarge";
        default:                     return "tiny";
    }
}

// Map in_dim -> shape bucket. Static inline so the dispatch's
// hot path is a single compare cascade.
static inline int ts_regime_shape_bucket_for_in_dim(int64_t in_dim) {
    if (in_dim <= 128)  return TS_REGIME_SHAPE_TINY;
    if (in_dim <= 512)  return TS_REGIME_SHAPE_SMALL;
    if (in_dim <= 2048) return TS_REGIME_SHAPE_MEDIUM;
    if (in_dim <= 4096) return TS_REGIME_SHAPE_LARGE;
    return TS_REGIME_SHAPE_XLARGE;
}

// ---------------------------------------------------------------------------
// Family classifier
//
// Map a GGUF tensor name -> family_kind. Mirrors
// ts_higgs_proxy_classify_family (attn_q, attn_k, attn_v,
// attn_output, ffn_gate, ffn_up, ffn_down, token_embd, output)
// and extends it with the multimodal suffixes (patch_embd,
// position_embd, mm_up, mm_gate, mm_input_projection) and the
// "other" fallback. The order matters: attn_output is checked
// before attn_q so "blk.16.attn_output.weight" does not
// misclassify as attn_q.
//
// The "other" family is a deliberate fallback: a tensor with
// an unrecognised suffix (e.g. "rope_freqs", a custom head)
// routes to the v1 static threshold via the lookup miss path.
// ---------------------------------------------------------------------------

static inline bool std_strn_eq(const char * a, const char * b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

static inline int ts_regime_infer_family(const char * name) {
    if (!name) return TS_REGIME_FAM_OTHER;
    // Strip a trailing ".weight" or ".bias" so the suffix
    // match works for both "blk.16.attn_v.weight" and
    // "blk.16.attn_v".
    size_t n = 0;
    while (name[n]) n++;
    static const char weight_suffix[] = ".weight";
    static const char bias_suffix[]   = ".bias";
    if (n > sizeof(weight_suffix) - 1) {
        const size_t ws = sizeof(weight_suffix) - 1;
        bool match = true;
        for (size_t i = 0; i < ws; i++) {
            if (name[n - ws + i] != weight_suffix[i]) { match = false; break; }
        }
        if (match) n -= ws;
    }
    if (n > sizeof(bias_suffix) - 1) {
        const size_t bs = sizeof(bias_suffix) - 1;
        bool match = true;
        for (size_t i = 0; i < bs; i++) {
            if (name[n - bs + i] != bias_suffix[i]) { match = false; break; }
        }
        if (match) n -= bs;
    }
    // Walk the family table; first match wins. The order
    // is significant (see the comment above).
    struct { const char * suf; int fam; } table[] = {
        { "attn_output",         TS_REGIME_FAM_ATTN_OUTPUT         },
        { "attn_q",              TS_REGIME_FAM_ATTN_Q              },
        { "attn_k",              TS_REGIME_FAM_ATTN_K              },
        { "attn_v",              TS_REGIME_FAM_ATTN_V              },
        { "ffn_down",            TS_REGIME_FAM_FFN_DOWN            },
        { "ffn_gate",            TS_REGIME_FAM_FFN_GATE            },
        { "ffn_up",              TS_REGIME_FAM_FFN_UP              },
        { "token_embd",          TS_REGIME_FAM_TOKEN_EMBD          },
        { "output",              TS_REGIME_FAM_OUTPUT              },
        { "patch_embd",          TS_REGIME_FAM_PATCH_EMBD          },
        { "position_embd",       TS_REGIME_FAM_POSITION_EMBD       },
        { "mm_input_projection", TS_REGIME_FAM_MM_INPUT_PROJECTION },
        { "mm_up",               TS_REGIME_FAM_MM_UP               },
        { "mm_gate",             TS_REGIME_FAM_MM_GATE             },
    };
    const size_t table_n = sizeof(table) / sizeof(table[0]);
    for (size_t i = 0; i < table_n; i++) {
        size_t sn = 0;
        while (table[i].suf[sn]) sn++;
        // Exact match: the bare suffix (e.g. "token_embd",
        // "output") is itself the family name when the GGUF
        // tensor is at the top level.
        if (n == sn && std_strn_eq(name, table[i].suf, sn)) {
            return table[i].fam;
        }
        // Dotted-suffix match: "." + suf at the tail of
        // name. So "blk.16.attn_v" matches "attn_v" but
        // "myattn_v" does not.
        if (n > sn + 1 && name[n - sn - 1] == '.' &&
            std_strn_eq(name + n - sn, table[i].suf, sn)) {
            return table[i].fam;
        }
    }
    return TS_REGIME_FAM_OTHER;
}

// ---------------------------------------------------------------------------
// Policy table
//
// The generated table (ggml-regime-router.gen.h) provides
// `extern const ts_regime_entry kRegimePolicy[];` and
// `extern const int kRegimePolicyCount;`. The .gen.h is
// produced by tools/quantize/tessera/calibrate_regime_router.cpp
// and committed; the router looks up an entry by
// (family, shape_bucket) and falls back to the v1 static
// helper when no entry exists. An empty .gen.h is the
// Commit 1 baseline: every call falls back, and the dispatch
// behaves EXACTLY as the v1 main does today.
// ---------------------------------------------------------------------------

struct ts_regime_entry {
    int family;       // ts_regime_family_kind_t
    int shape_bucket; // ts_regime_shape_bucket_t
    bool use_v2_outlier;
    bool use_v2_meta;
};

extern const struct ts_regime_entry kRegimePolicy[];
extern const int kRegimePolicyCount;

// ---------------------------------------------------------------------------
// Lookup helpers (the dispatch's hot-path API)
//
// Both lookups return false (v1 static) when:
//   - the policy table is empty (Commit 1 baseline),
//   - the (family, shape_bucket) pair has no entry,
//   - the family is TS_REGIME_FAM_OTHER (an unrecognised
//     tensor name should not influence the dispatch; the v1
//     static threshold is the safe default),
//   - the in_dim is non-positive (degenerate call).
//
// This contract guarantees the router is a strict no-op when
// the calibration runner has not yet produced any entries:
// the dispatch in ggml-ane.mm sees the same bools it would
// have seen without the router, and the v1 cost model is the
// single source of truth.
// ---------------------------------------------------------------------------

// Look up the outlier addback decision for this (family, n_total).
// shape_bucket is derived from in_dim by the caller (the
// dispatch has in_dim at the call site already).
static inline bool ts_regime_router_lookup_outlier(int family,
                                                   int shape_bucket,
                                                   int64_t n_total) {
    if (family < 0 || family >= TS_REGIME_FAM_COUNT) {
        return ts_v2_dispatch_should_use_v2_outlier(n_total);
    }
    if (shape_bucket < 0 || shape_bucket >= TS_REGIME_SHAPE_COUNT) {
        return ts_v2_dispatch_should_use_v2_outlier(n_total);
    }
    if (family == TS_REGIME_FAM_OTHER) {
        return ts_v2_dispatch_should_use_v2_outlier(n_total);
    }
    for (int i = 0; i < kRegimePolicyCount; i++) {
        if (kRegimePolicy[i].family == family &&
            kRegimePolicy[i].shape_bucket == shape_bucket) {
            return kRegimePolicy[i].use_v2_outlier;
        }
    }
    return ts_v2_dispatch_should_use_v2_outlier(n_total);
}

// Look up the meta decode decision for this (family, n_rows, n_pages).
// shape_bucket is derived from in_dim by the caller.
static inline bool ts_regime_router_lookup_meta(int family,
                                                int shape_bucket,
                                                int64_t n_rows,
                                                int64_t n_pages) {
    if (family < 0 || family >= TS_REGIME_FAM_COUNT) {
        return ts_v2_dispatch_should_use_v2_meta(n_rows, n_pages);
    }
    if (shape_bucket < 0 || shape_bucket >= TS_REGIME_SHAPE_COUNT) {
        return ts_v2_dispatch_should_use_v2_meta(n_rows, n_pages);
    }
    if (family == TS_REGIME_FAM_OTHER) {
        return ts_v2_dispatch_should_use_v2_meta(n_rows, n_pages);
    }
    for (int i = 0; i < kRegimePolicyCount; i++) {
        if (kRegimePolicy[i].family == family &&
            kRegimePolicy[i].shape_bucket == shape_bucket) {
            return kRegimePolicy[i].use_v2_meta;
        }
    }
    return ts_v2_dispatch_should_use_v2_meta(n_rows, n_pages);
}

#ifdef __cplusplus
}
#endif
