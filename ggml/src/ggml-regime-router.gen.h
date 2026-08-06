// ggml-regime-router.gen.h
//
// v1 regime router policy table - GENERATED. DO NOT EDIT BY HAND.
//
// Regenerate with:
//   tools/quantize/build/bin/calibrate_regime_router \
//       --out ggml/src/ggml-regime-router.gen.h \
//       --shape gemma4-12b-trunk
// (the seed in the runner is pinned; the bytes below are
// bit-stable across runs and platforms).
//
// Commit 1 baseline: zero entries. Every dispatch call falls
// back to the v1 static cost model in
// ggml/src/ggml-quants-v2-dispatch.h, and the dispatch in
// ggml-ane.mm behaves EXACTLY as it does on main without
// this header. Subsequent commits populate the table.

#pragma once

#include "ggml-regime-router.h"

#ifdef __cplusplus
extern "C" {
#endif

const struct ts_regime_entry kRegimePolicy[] = {
    // (intentionally empty; populated by Commit 3+)
};
const int kRegimePolicyCount = 0;

#ifdef __cplusplus
}
#endif
