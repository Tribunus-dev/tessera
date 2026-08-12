#pragma once

//
// tessera-ppl.h
//
// E2E perplexity / KL-divergence probe for quantized model evaluation.
// Data-free KL variant on random tokens (HIGGS probe metric).
//

#include <cstdint>

struct ts_ppl_params {
    int64_t  n_tokens;      // number of probe tokens (default 256)
    int64_t  vocab_size;    // vocabulary size for softmax (default 32000)
    bool     use_kl;        // true = KL divergence, false = cross-entropy PPL
    uint32_t seed;          // for random token generation
};

struct ts_ppl_result {
    float   kl_divergence;  // KL(ref || quant), nats
    float   ppl_ratio;      // PPL(quant) / PPL(ref)
    float   delta_ppl;      // PPL(quant) - PPL(ref)
    int64_t n_tokens_used;
};

// Mean KL(ref || quant) per token.
// logits_ref, logits_quant: (n_tokens x vocab_size) row-major.
float ts_ppl_kl_divergence(const float * logits_ref,
                           const float * logits_quant,
                           int64_t n_tokens, int64_t vocab_size);

// Perplexity from logits and target token IDs.
// logits: (n_tokens x vocab_size). targets: (n_tokens,) token IDs.
float ts_ppl_perplexity(const float * logits, const int32_t * targets,
                        int64_t n_tokens, int64_t vocab_size);

// Forward callback: fills logits_out (n_tokens x vocab_size) for given tokens.
typedef void (*ts_ppl_forward_fn)(const int32_t * tokens, float * logits_out,
                                  int64_t n_tokens, int64_t vocab_size,
                                  void * model_ctx);

// Full E2E probe: random tokens -> both forwards -> KL + PPL metrics.
// Returns 0 on success, -1 on invalid params.
int ts_ppl_probe(ts_ppl_forward_fn forward_ref, void * ref_ctx,
                 ts_ppl_forward_fn forward_quant, void * quant_ctx,
                 const ts_ppl_params * params,
                 ts_ppl_result * result);

// --- L4 end-to-end comparison (runtime-aware pipeline Layer 4) ---

struct ts_ppl_compare_result {
    float   ppl_ref;        // PPL of the reference (BF16) model
    float   ppl_quant;      // PPL of the quantized model
    float   delta_ppl;      // ppl_quant - ppl_ref
    float   ppl_ratio;      // ppl_quant / ppl_ref
    float   kl_divergence;  // KL(ref || quant), nats
    float   threshold;      // pass threshold applied
    bool    pass;           // delta_ppl < threshold
    int64_t n_tokens_used;
};

// L4 smoke test: run PPL on both models over the same random tokens and
// report the whole-model delta plus a pass verdict. Acceptance for T640
// on standard benchmarks: delta_ppl < 0.5. pass_threshold <= 0 falls back
// to 0.5. Per-layer contribution needs model-graph access unavailable in
// the quantize tool, so this reports the whole-model delta only.
// Returns 0 on success, -1 on invalid params.
int ts_ppl_compare(ts_ppl_forward_fn forward_ref, void * ref_ctx,
                   ts_ppl_forward_fn forward_quant, void * quant_ctx,
                   const ts_ppl_params * params,
                   float pass_threshold,
                   ts_ppl_compare_result * result);

// --- L4 speculative-decoding spec telemetry (v3.1 spec §8) ---
//
// Per-layer, per-drafter alignment measurement. The L4 probe extends
// the existing per-position PPL with a per-layer acceptance rate and
// KL divergence between the verifier and each drafter. The diagnostic
// signal is the histogram of first_reject_layer (the verifier layer at
// which the first drafted token was rejected for a given step); a peak
// at mid-stack (layers 1-5) is the systematic alignment degradation
// that the 0.86 % drafter case exhibited.
//
// One ts_l4_spec_step entry per spec step; ts_l4_compute_spec_telemetry
// reduces the per-step data to a ts_l4_spec_summary with the reportable
// fields. Caller owns the storage for both inputs and outputs; sizes
// are passed in.
struct ts_l4_spec_step {
    int64_t step_idx;                  // 0-based step index
    int64_t accepted_count;            // number of drafted tokens accepted
    int     first_reject_layer;        // -1 when no reject, else the layer
    int64_t n_drafted;                 // total drafted tokens (per step)
    const float * per_layer_alpha;     // (n_layers,) per-layer acceptance
    const float * per_layer_kl;        // (n_layers,) per-layer KL(verifier||drafter)
    int64_t n_layers;                  // layer count for the per_layer_* arrays
};

struct ts_l4_spec_summary {
    float       overall_alpha;              // mean accepted / drafted across steps
    int64_t     n_steps;                    // total step count
    int64_t     n_drafters;                 // 1 for now (single drafter); future: 4 + talker
    int         first_reject_layer_peak;    // mode of the histogram, -1 if all-accept
    int64_t     n_total_drafted;            // sum across steps
    int64_t     n_total_accepted;          // sum across steps
    int64_t     n_steps_with_reject;        // steps where first_reject_layer >= 0
    // The flag criterion is applied to these scalars; the dispatch
    // reads them and decides whether to tighten the L5 loop on the
    // peak layer's family.
};

// Compute the L4 spec telemetry summary from a sequence of spec steps.
// steps: (n_steps,) per-step data; n_steps: step count; n_layers: layer
// count (must be the same for every step). summary_out: populated.
// histograms: optional (n_layers,) int64_t buffer that receives the
// first-reject-layer histogram (caller-allocated); nullptr is allowed.
// Returns 0 on success, -1 on invalid args.
int ts_l4_compute_spec_telemetry(const ts_l4_spec_step * steps,
                                 int64_t n_steps, int64_t n_layers,
                                 int64_t n_drafters,
                                 ts_l4_spec_summary * summary_out,
                                 int64_t * histograms);

// L4 spec-telemetry flag verdict (spec §8.3c). The summary is the
// input; the function returns a pass/fail decision plus the reason.
// pass = true means the L4 probe passes (no requantization needed).
// pass = false means the criterion tripped; reason_out (optional) gets
// a short string identifying the tripped condition.
//
// Pass criteria (all must hold):
//   - overall_alpha >= 0.50
//   - first_reject_layer_peak NOT in {1, 2, 3, 4, 5}
//   - per_layer_alpha[L/2] >= 0.40  (mid-stack per-layer drop)
//   - per_layer_kl[L] < 0.5 for all L  (no mid-stack KL spike)
//
// When per_layer_alpha_mid is -1 (not available), the mid-stack drop
// check is skipped; same for per_layer_kl_max when -1.
struct ts_l4_spec_flag_result {
    bool pass;
    const char * reason;   // one of "OK", "low_overall_alpha",
                           // "mid_stack_reject_peak", "mid_stack_alpha_drop",
                           // "mid_stack_kl_spike"; pointer is to a static
                           // string, do not free.
    float per_layer_alpha_mid;   // -1 when not available
    float per_layer_kl_max;      // -1 when not available
};

ts_l4_spec_flag_result ts_l4_spec_flag(const ts_l4_spec_summary * summary,
                                       const float * per_layer_alpha,
                                       int64_t n_layers);

// --- L4 domain-weighted prompt bank (v3.1 spec §7) ---
//
// Per-domain prompt bank replacing the data-free random-token probe
// as the production L4. Each domain (factual / math / code /
// structured / reasoning / conversational / adversarial) has its
// own prompt set, its own matcher (exact / regex / JSON-validate /
// semantic), and a configurable domain weight. The aggregate L4
// verdict is the weighted pass rate (the spec's pass criterion:
// weighted_pass_rate > 0.85).
//
// The C++ surface here is the AGGREGATION layer. The prompt
// loading, BF16 / T640 forward orchestration, and per-domain
// matchers live in tools/tessera/e2e_probe.py (Python). The C++
// side consumes the per-domain scalars (one ts_l4_domain_metrics
// per domain) and produces the ts_l4_domain_summary.
//
// Up to 7 domains (the spec's canonical set). n_domains is the
// count of populated entries in per_domain; the rest of the
// struct is zero.
struct ts_l4_domain_metrics {
    const char * name;        // "factual", "math", "code", etc.
    float        ppl;         // mean per-token PPL on this domain
    float        pass_rate;   // 0..1; fraction of prompts that
                              //   matched the reference output
    int64_t      n_prompts;   // number of prompts in the domain
};

struct ts_l4_domain_summary {
    int64_t n_domains;                 // populated count in per_domain
    float   weighted_ppl;             // sum(weight * ppl) / sum(weight)
    float   weighted_pass_rate;       // sum(weight * pass_rate) / sum(weight)
    int64_t total_prompts;            // sum of n_prompts across domains
    // Worst domain (lowest pass_rate). name is a pointer into the
    // caller's input array; do not free.
    int     worst_domain_idx;         // -1 when n_domains == 0
    float   worst_pass_rate;          // 0..1
    bool    pass;                     // weighted_pass_rate > 0.85
};

// Aggregate per-domain metrics into a domain-weighted L4 summary.
// per_domain: (n_domains,) caller-owned; domain_weights: (n_domains,)
// caller-owned (uniform 1/n_domains when nullptr). n_domains <= 7.
// pass_threshold: 0.85 (spec default; caller can override).
// summary_out: populated. Returns 0 on success, -1 on invalid args
// (n_domains out of range, null pointers, all weights zero).
int ts_l4_domain_aggregate(const ts_l4_domain_metrics * per_domain,
                            const float * domain_weights,
                            int64_t n_domains,
                            float pass_threshold,
                            ts_l4_domain_summary * summary_out);

// Default domain weights (uniform 1/n_domains). The spec recommends
// weighting `code` and `reasoning` higher for production; this
// returns the uniform default. Callers can override per-domain.
// domain_names: (n_domains,) caller-owned; out_weights: (n_domains,)
// caller-owned, populated. Returns 0 on success.
int ts_l4_domain_default_weights(const char * const * domain_names,
                                  int64_t n_domains,
                                  float * out_weights);
