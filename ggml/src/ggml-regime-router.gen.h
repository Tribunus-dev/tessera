// ggml-regime-router.gen.h
//
// v1 regime router policy table - GENERATED. DO NOT EDIT BY HAND.
//
// Regenerate with:
//   tools/quantize/build/bin/calibrate_regime_router \
//       --out ggml/src/ggml-regime-router.gen.h \
//       --shape gemma4-12b-trunk
// (the seed is pinned; the bytes below are bit-stable
// across runs and platforms - the latency rationale
// lives in the .gen.md report and the run stderr, not
// in this header, to keep the SHA stable).
//
// Shape set: gemma4-12b-trunk
// Cell count: 36
//
// Each entry: { family, shape_bucket, use_v2_outlier, use_v2_meta }.
// family = ts_regime_family_kind_t; shape_bucket =
// ts_regime_shape_bucket_t. The router's lookup is
// static inline; the dispatch's hot path is one
// bounds check + 32-bit compare per call.
//
// use_v2_* decision rule: the bench records the v2
// path's winner iff it is at least 5% faster than the
// C ref path at this (family, shape). On a tie the
// entry defers to the v1 static cost model in
// ggml/src/ggml-quants-v2-dispatch.h. The dispatch
// is identical to main when the runner records the
// v1 static result (i.e. the router is a strict no-op
// for tie cells).

#pragma once

#include "ggml-regime-router.h"

#ifdef __cplusplus
extern "C" {
#endif

const struct ts_regime_entry kRegimePolicy[] = {
    { 0, 1, true, false },
    { 0, 2, true, false },
    { 0, 3, false, false },
    { 0, 4, true, false },
    { 1, 1, true, false },
    { 1, 2, true, false },
    { 1, 3, true, false },
    { 2, 1, true, false },
    { 2, 2, true, false },
    { 2, 3, true, false },
    { 3, 1, false, false },
    { 3, 2, false, false },
    { 3, 3, false, false },
    { 3, 4, true, false },
    { 4, 1, false, false },
    { 4, 2, false, false },
    { 4, 3, true, false },
    { 4, 4, false, false },
    { 5, 1, true, false },
    { 5, 2, true, false },
    { 5, 3, false, false },
    { 6, 1, true, false },
    { 6, 2, true, false },
    { 6, 3, true, false },
    { 6, 4, true, false },
    { 7, 2, false, false },
    { 7, 3, true, false },
    { 7, 4, true, false },
    { 8, 2, false, false },
    { 8, 3, false, false },
    { 8, 4, false, false },
    { 10, 2, false, false },
    { 11, 4, false, false },
    { 12, 4, false, false },
    { 13, 2, false, false },
    { 13, 3, true, false },
};
const int kRegimePolicyCount = 36;

#ifdef __cplusplus
}
#endif
