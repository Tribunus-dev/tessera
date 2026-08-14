#pragma once

//
// tessera-expert-eval.h
//
// The ONE evaluation door. Every expert, every tier, every caller.
//
// Today the pipeline evaluates tensors through five unrelated code paths
// (ts_dispatch_forced_t2, ts_dispatch_tier2_t2, the GA's eval callback,
// ts_dispatch_kernel_direct_t2, the L5 scorer combine) with no shared
// keying and no shared contract for what an "expert" produces. This seam
// replaces them: every expert (AWQ core, DartQuant, LRQ/FLRQ, CHAMP-Q,
// SEPTQ, and the routed composite) implements the same contract, and
// SEPTQ real scoring, the eval-cache memoization layer (phase 2), and the
// KV-joint codec digest (phase 3) become properties of the seam instead of
// three separate bolt-ons. See docs/tessera-pipeline-refactor-plan.md and
// docs/tessera-refactor-implementation-spec.md section 1.
//

#include "tessera-archive.h"   // ts_expert_id

#include <cstdint>
#include <string>

// Forward declaration so this header does not pull in duckdb.hpp (mirrors
// tessera-quantize-db.h's own forward declaration for the same reason);
// tessera-expert-eval.cpp includes the real header to call into it.
struct ts_tessera_db;

// Bumped whenever the scoring math for any tier/expert changes -- the same
// role scorer_version plays for the L5 Hessian cache. A version bump makes
// every eval_cache row keyed on the old version unreachable (never
// mutated, never deleted); it simply stops being read.
#define TS_EXPERT_EVAL_VERSION 1

enum ts_eval_tier {
    TS_EVAL_PROXY = 0,      // profile-scaled T640-core streaming MSE
    TS_EVAL_REAL,           // the expert's actual algorithm + scored
                            // reconstruction
    TS_EVAL_KERNEL_DIRECT,  // L1 sidecar tail-weighted t2 (falls back to
                            // REAL when no sidecar)
};

// Borrowed pointers; caller owns weights/act_scales/name/sidecar_dir for
// the duration of the call. Every field has an in-class initializer (the
// ts_awq_evolve_params invariant: this struct is default-constructed by
// tests, and a bare pointer left indeterminate has shipped as a bug once
// already in this codebase -- see the seed_candidate incident referenced
// in tessera-awq.h).
struct ts_eval_tensor_ctx {
    const char *  name = nullptr;
    const float * weights = nullptr;     // dequantized F32, row-major
                                          // (out_dim x in_dim)
    const float * act_scales = nullptr;  // (in_dim,) or nullptr
    int64_t       out_dim = 0;
    int64_t       in_dim = 0;
    // Digests + DB handle for eval-cache keying (phase 2). Caching is only
    // attempted when db != nullptr AND model_hash is non-empty AND name is
    // non-null; any one of those missing means "run fresh, do not cache"
    // (matches every other db==nullptr-is-a-safe-no-op convention in this
    // codebase). input_digest is caller-supplied when the caller knows a
    // more precise identity (e.g. an imatrix digest); when left empty the
    // seam derives a cheap non-cryptographic digest of act_scales itself
    // (or a stable sentinel when act_scales is null), which is enough to
    // distinguish "same corpus" from "different corpus" for memoization.
    std::string   model_hash;
    std::string   model_role;
    std::string   input_digest;          // imatrix / sidecar digest, or ""
                                          // to let the seam derive one
    const char *  sidecar_dir = nullptr; // for KERNEL_DIRECT; may be null
    ts_tessera_db * db = nullptr;        // borrowed; caller owns
};

struct ts_eval_opts {
    ts_eval_tier tier = TS_EVAL_PROXY;
    float        alpha = 0.0f;   // resolved base gene (post any GA scaling
                                  // the caller already applied)
    float        clip  = 1.0f;   // resolved base gene
    uint32_t     seed  = 0;
    float        l6_tail_tau    = 0.0f;  // KERNEL_DIRECT only
    float        l6_tail_weight = 0.0f;  // KERNEL_DIRECT only
    // Phase 3: the composed-runtime codec context enters the digest.
    std::string  kv_codec_digest;  // "" = weights-only evaluation
};

struct ts_eval_result {
    float t2  = 0.0f;   // normalized: mse * n / ||W||_F^2
    float mse = 0.0f;   // NOT cached (eval_cache stores t2 + aux only, per
                        // docs/tessera-refactor-implementation-spec.md
                        // section 2); reads as 0.0f on a cache hit
    bool  from_cache = false;  // phase 2
    char  aux[256] = {0};      // per-expert extras as compact JSON, e.g.
                                // {"expert":"septq","tier":"real",...}.
                                // Carries the ACTUALLY-DELIVERED tier and,
                                // when it differs from opts.tier, a
                                // "fallback" reason -- see the phase-1
                                // known-issue on silent proxy fallback
                                // (docs/tessera-refactor-implementation-spec.md
                                // section 1).
};

// expert: TS_EXPERT_AWQ / DARTQUANT / FLRQ / SEPTQ / CHAMPQ / LRQ / or the
// routed composite id (tessera-archive.h). Returns 0 on success (out is
// always populated with a usable t2, even when the requested tier could
// not be delivered -- see ts_eval_result::aux); non-zero only on invalid
// arguments (null ctx.weights/out, non-positive dims).
//
// Eval cache (phase 2): when ctx.db/model_hash/name make the call cache-
// eligible, this is a memoized read-through -- a hit skips computation
// entirely and returns exactly what the original computation produced
// (out->from_cache = true); a miss computes fresh and writes the result
// back before returning. The cache key is (model_hash, model_role,
// tensor, "expert:<Name>:<tier>", params_digest, input_digest,
// TS_EXPERT_EVAL_VERSION) -- every call site behind this seam gets
// memoization for free; there is no way to bypass it (the seam is the
// only door).
//
// Thread-safety: pure with respect to its inputs; safe under the
// acceptance stage's worker pool and the GA's eval threads. No module
// globals; all scratch is call-local (the eval-cache DB access is
// serialized internally via ctx.db's own mutex, not a seam-level global).
// Deterministic for fixed inputs (the GA's velocity gate depends on this;
// a cache hit returning the memoized value is what makes that still true).
int ts_expert_eval(ts_expert_id expert,
                   const ts_eval_tensor_ctx & ctx,
                   const ts_eval_opts & opts,
                   ts_eval_result * out);
