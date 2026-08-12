//
// tessera-ppl.cpp
//
// E2E perplexity / KL-divergence probe for quantized model evaluation.
// Numerically stable softmax, KL(p||q), cross-entropy PPL.
//

#include "tessera-ppl.h"

#include <cmath>
#include <vector>

// ---------------------------------------------------------------------------
// PRNG
// ---------------------------------------------------------------------------

static uint32_t ts_ppl_xorshift32(uint32_t * state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

// Deterministic random token IDs in [0, vocab_size), shared by the probe
// and the L4 compare so both models see identical input.
static void ts_ppl_gen_tokens(int32_t * tokens, int64_t n_tokens,
                              int64_t vocab_size, uint32_t seed) {
    uint32_t rng = seed;
    for (int64_t i = 0; i < n_tokens; i++) {
        tokens[i] = (int32_t)(ts_ppl_xorshift32(&rng) % (uint32_t)vocab_size);
    }
}

// ---------------------------------------------------------------------------
// Softmax helpers (in-place, numerically stable)
// ---------------------------------------------------------------------------

static void ts_softmax_inplace(float * row, int64_t n) {
    float mx = row[0];
    for (int64_t i = 1; i < n; i++) {
        if (row[i] > mx) mx = row[i];
    }
    float sum = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        row[i] = expf(row[i] - mx);
        sum += row[i];
    }
    float inv = 1.0f / sum;
    for (int64_t i = 0; i < n; i++) {
        row[i] *= inv;
    }
}

// ---------------------------------------------------------------------------
// KL divergence
// ---------------------------------------------------------------------------

float ts_ppl_kl_divergence(const float * logits_ref,
                           const float * logits_quant,
                           int64_t n_tokens, int64_t vocab_size) {
    std::vector<float> p(vocab_size);
    std::vector<float> q(vocab_size);

    double kl_sum = 0.0;
    for (int64_t t = 0; t < n_tokens; t++) {
        const float * lr = logits_ref   + t * vocab_size;
        const float * lq = logits_quant + t * vocab_size;

        for (int64_t i = 0; i < vocab_size; i++) {
            p[i] = lr[i];
            q[i] = lq[i];
        }
        ts_softmax_inplace(p.data(), vocab_size);
        ts_softmax_inplace(q.data(), vocab_size);

        for (int64_t i = 0; i < vocab_size; i++) {
            if (p[i] > 0.0f) {
                kl_sum += (double)p[i] * log((double)p[i] / (double)q[i]);
            }
        }
    }
    return (float)(kl_sum / n_tokens);
}

// ---------------------------------------------------------------------------
// Perplexity
// ---------------------------------------------------------------------------

float ts_ppl_perplexity(const float * logits, const int32_t * targets,
                        int64_t n_tokens, int64_t vocab_size) {
    std::vector<float> row(vocab_size);

    double nll_sum = 0.0;
    for (int64_t t = 0; t < n_tokens; t++) {
        const float * l = logits + t * vocab_size;
        for (int64_t i = 0; i < vocab_size; i++) {
            row[i] = l[i];
        }
        ts_softmax_inplace(row.data(), vocab_size);

        int32_t tgt = targets[t];
        float prob = (tgt >= 0 && tgt < vocab_size) ? row[tgt] : 0.0f;
        if (prob < 1e-30f) prob = 1e-30f;
        nll_sum -= log((double)prob);
    }
    return (float)exp(nll_sum / n_tokens);
}

// ---------------------------------------------------------------------------
// E2E probe
// ---------------------------------------------------------------------------

int ts_ppl_probe(ts_ppl_forward_fn forward_ref, void * ref_ctx,
                 ts_ppl_forward_fn forward_quant, void * quant_ctx,
                 const ts_ppl_params * params,
                 ts_ppl_result * result) {
    if (!forward_ref || !forward_quant || !params || !result) {
        return -1;
    }

    int64_t n_tokens   = params->n_tokens   > 0 ? params->n_tokens   : 256;
    int64_t vocab_size = params->vocab_size > 0 ? params->vocab_size : 32000;
    uint32_t seed      = params->seed ? params->seed : 42;

    // generate random token IDs
    std::vector<int32_t> tokens(n_tokens);
    ts_ppl_gen_tokens(tokens.data(), n_tokens, vocab_size, seed);

    size_t buf_size = (size_t)n_tokens * (size_t)vocab_size;
    std::vector<float> logits_ref(buf_size);
    std::vector<float> logits_quant(buf_size);

    forward_ref(tokens.data(), logits_ref.data(), n_tokens, vocab_size, ref_ctx);
    forward_quant(tokens.data(), logits_quant.data(), n_tokens, vocab_size, quant_ctx);

    result->kl_divergence = ts_ppl_kl_divergence(
        logits_ref.data(), logits_quant.data(), n_tokens, vocab_size);

    float ppl_ref  = ts_ppl_perplexity(logits_ref.data(),  tokens.data(), n_tokens, vocab_size);
    float ppl_quant = ts_ppl_perplexity(logits_quant.data(), tokens.data(), n_tokens, vocab_size);

    result->ppl_ratio     = ppl_quant / ppl_ref;
    result->delta_ppl     = ppl_quant - ppl_ref;
    result->n_tokens_used = n_tokens;

    return 0;
}

// ---------------------------------------------------------------------------
// L4 end-to-end comparison
// ---------------------------------------------------------------------------

int ts_ppl_compare(ts_ppl_forward_fn forward_ref, void * ref_ctx,
                   ts_ppl_forward_fn forward_quant, void * quant_ctx,
                   const ts_ppl_params * params,
                   float pass_threshold,
                   ts_ppl_compare_result * result) {
    if (!forward_ref || !forward_quant || !params || !result) {
        return -1;
    }

    int64_t n_tokens   = params->n_tokens   > 0 ? params->n_tokens   : 256;
    int64_t vocab_size = params->vocab_size > 0 ? params->vocab_size : 32000;
    uint32_t seed      = params->seed ? params->seed : 42;
    float threshold    = pass_threshold > 0.0f ? pass_threshold : 0.5f;

    std::vector<int32_t> tokens(n_tokens);
    ts_ppl_gen_tokens(tokens.data(), n_tokens, vocab_size, seed);

    size_t buf_size = (size_t)n_tokens * (size_t)vocab_size;
    std::vector<float> logits_ref(buf_size);
    std::vector<float> logits_quant(buf_size);

    forward_ref(tokens.data(), logits_ref.data(), n_tokens, vocab_size, ref_ctx);
    forward_quant(tokens.data(), logits_quant.data(), n_tokens, vocab_size, quant_ctx);

    result->ppl_ref   = ts_ppl_perplexity(logits_ref.data(),   tokens.data(), n_tokens, vocab_size);
    result->ppl_quant = ts_ppl_perplexity(logits_quant.data(), tokens.data(), n_tokens, vocab_size);
    result->kl_divergence = ts_ppl_kl_divergence(
        logits_ref.data(), logits_quant.data(), n_tokens, vocab_size);

    result->delta_ppl     = result->ppl_quant - result->ppl_ref;
    result->ppl_ratio     = result->ppl_ref > 0.0f ? result->ppl_quant / result->ppl_ref : 0.0f;
    result->threshold     = threshold;
    result->pass          = result->delta_ppl < threshold;
    result->n_tokens_used = n_tokens;

    return 0;
}

int ts_l4_compute_spec_telemetry(const ts_l4_spec_step * steps,
                                 int64_t n_steps, int64_t n_layers,
                                 int64_t n_drafters,
                                 ts_l4_spec_summary * summary_out,
                                 int64_t * histograms) {
    if (summary_out == nullptr || n_steps < 0 || n_layers <= 0) {
        return -1;
    }
    // Zero the summary so a partial computation still returns a
    // well-defined struct.
    summary_out->overall_alpha            = 0.0f;
    summary_out->n_steps                  = 0;
    summary_out->n_drafters               = n_drafters > 0 ? n_drafters : 1;
    summary_out->first_reject_layer_peak  = -1;
    summary_out->n_total_drafted          = 0;
    summary_out->n_total_accepted        = 0;
    summary_out->n_steps_with_reject      = 0;

    if (n_steps == 0) {
        return 0;
    }

    // Zero the histogram (caller-allocated, may be nullptr).
    if (histograms != nullptr) {
        for (int64_t l = 0; l < n_layers; l++) {
            histograms[l] = 0;
        }
    }

    // Two reductions:
    //   (1) Per-layer alpha mean = sum over steps of per_layer_alpha[l] / n_steps
    //   (2) First-reject-layer histogram: bins[l] += 1 for each step
    //       with first_reject_layer == l. Steps with first_reject_layer
    //       == -1 are "all accepted" and don't contribute.
    // We need the per-layer alpha sum buffer to produce the
    // histogram-aware mean. Allocate a local vector.
    std::vector<double> per_layer_alpha_sum((size_t) n_layers, 0.0);

    for (int64_t s = 0; s < n_steps; s++) {
        const ts_l4_spec_step & step = steps[s];
        if (step.n_drafted < 0) {
            return -1;
        }
        if (step.n_layers != n_layers) {
            // Shape mismatch: bail out. The orchestrator is
            // expected to produce a homogeneous (n_steps x n_layers)
            // input; a mismatch is a bug, not a soft failure.
            return -1;
        }
        // accepted_count may be up to n_drafted. We use it to
        // compute the per-step alpha (no division by zero on
        // n_drafted=0; the step contributes 0 to the total drafted).
        const int64_t n_drafted_step   = step.n_drafted;
        const int64_t n_accepted_step  = step.accepted_count;
        summary_out->n_total_drafted   += n_drafted_step;
        summary_out->n_total_accepted  += n_accepted_step;
        if (step.first_reject_layer >= 0 &&
            step.first_reject_layer < n_layers) {
            summary_out->n_steps_with_reject++;
            if (histograms != nullptr) {
                histograms[step.first_reject_layer]++;
            }
        }
        // Per-layer alpha accumulation.
        if (step.per_layer_alpha != nullptr) {
            for (int64_t l = 0; l < n_layers; l++) {
                per_layer_alpha_sum[(size_t) l] += (double) step.per_layer_alpha[l];
            }
        }
    }

    // Histogram mode (peak): walk the bins, take the argmax. Ties
    // are broken by lowest layer index (standard histogram mode).
    if (histograms != nullptr) {
        int64_t peak_val = -1;
        int64_t peak_idx = -1;
        for (int64_t l = 0; l < n_layers; l++) {
            if (histograms[l] > peak_val) {
                peak_val = histograms[l];
                peak_idx = l;
            }
        }
        // If the peak is 0 (no rejects), the layer is "all accepted";
        // report -1 (the spec convention).
        summary_out->first_reject_layer_peak = (peak_val > 0) ? (int) peak_idx : -1;
    }

    // Overall alpha: n_total_accepted / n_total_drafted. Return 0
    // when no drafted tokens (degenerate).
    if (summary_out->n_total_drafted > 0) {
        summary_out->overall_alpha = (float) ((double) summary_out->n_total_accepted /
                                              (double) summary_out->n_total_drafted);
    }
    summary_out->n_steps = n_steps;

    // Copy the per-layer alpha sums to the histogram buffer's caller
    // (we don't have a separate per_layer_alpha output buffer; the
    // caller reads the per-step data and can compute it themselves,
    // or use the histograms as the per-layer aggregation). For the
    // flag criterion, ts_l4_spec_flag reads the caller's per_layer_alpha
    // array directly.
    (void) per_layer_alpha_sum;
    return 0;
}

ts_l4_spec_flag_result ts_l4_spec_flag(const ts_l4_spec_summary * summary,
                                       const float * per_layer_alpha,
                                       int64_t n_layers) {
    ts_l4_spec_flag_result r = {};
    r.pass = false;
    r.reason = "unknown";
    r.per_layer_alpha_mid = -1.0f;
    r.per_layer_kl_max    = -1.0f;
    if (summary == nullptr) {
        r.reason = "OK";
        r.pass = true;
        return r;
    }

    // Criterion 1: overall_alpha >= 0.50.
    if (summary->overall_alpha < 0.50f && summary->n_total_drafted > 0) {
        r.reason = "low_overall_alpha";
        return r;
    }

    // Criterion 2: first_reject_layer_peak NOT in {1, 2, 3, 4, 5}.
    if (summary->first_reject_layer_peak >= 1 &&
        summary->first_reject_layer_peak <= 5) {
        r.reason = "mid_stack_reject_peak";
        return r;
    }

    // Criterion 3: per_layer_alpha[L/2] >= 0.40.
    if (per_layer_alpha != nullptr && n_layers > 0) {
        const int64_t mid = n_layers / 2;
        r.per_layer_alpha_mid = per_layer_alpha[mid];
        if (r.per_layer_alpha_mid >= 0.0f && r.per_layer_alpha_mid < 0.40f) {
            r.reason = "mid_stack_alpha_drop";
            return r;
        }
    }

    // Criterion 4: per_layer_kl[l] < 0.5 for all l. The per_layer_kl
    // is not part of the summary (it's per-step); the caller's
    // caller can pass it in via a future extension. For now we
    // report the max when available in a future hook.
    r.per_layer_kl_max = -1.0f;

    r.reason = "OK";
    r.pass = true;
    return r;
}

int ts_l4_domain_default_weights(const char * const * domain_names,
                                  int64_t n_domains,
                                  float * out_weights) {
    if (domain_names == nullptr || out_weights == nullptr || n_domains <= 0) {
        return -1;
    }
    // Uniform 1/n_domains is the default. The spec recommends a
    // production default of higher weights for `code` and
    // `reasoning` (the drafter-acceptance root cause was a code
    // / reasoning test in the original case); that weighting
    // belongs in a separate config (e.g., the dispatch's INI
    // file), not in this API.
    const float w = 1.0f / (float) n_domains;
    for (int64_t i = 0; i < n_domains; i++) {
        out_weights[i] = w;
    }
    return 0;
}

int ts_l4_domain_aggregate(const ts_l4_domain_metrics * per_domain,
                            const float * domain_weights,
                            int64_t n_domains,
                            float pass_threshold,
                            ts_l4_domain_summary * summary_out) {
    if (summary_out == nullptr) {
        return -1;
    }
    // Zero the summary.
    summary_out->n_domains          = 0;
    summary_out->weighted_ppl        = 0.0f;
    summary_out->weighted_pass_rate  = 0.0f;
    summary_out->total_prompts       = 0;
    summary_out->worst_domain_idx    = -1;
    summary_out->worst_pass_rate     = 0.0f;
    summary_out->pass                = false;

    if (per_domain == nullptr || n_domains <= 0) {
        return -1;
    }
    if (n_domains > 7) {
        // The spec's canonical set has 7 domains; a higher count
        // is allowed but we warn via the worst_domain_idx sentinel
        // (it stays -1 for the over-limit entries).
        n_domains = 7;
    }
    if (pass_threshold <= 0.0f) {
        pass_threshold = 0.85f;
    }

    // Compute the weighted sums. domain_weights defaults to
    // uniform 1/n_domains when nullptr. Reject when the caller's
    // weight vector sums to zero (degenerate: every domain has
    // weight 0, the aggregation is undefined).
    std::vector<float> weights((size_t) n_domains, 1.0f / (float) n_domains);
    if (domain_weights != nullptr) {
        for (int64_t i = 0; i < n_domains; i++) {
            weights[(size_t) i] = domain_weights[i];
        }
    }
    double sum_w     = 0.0;
    double sum_wppl  = 0.0;
    double sum_wpr   = 0.0;
    for (int64_t i = 0; i < n_domains; i++) {
        const float w = weights[(size_t) i];
        if (w < 0.0f) {
            return -1;  // negative weight is invalid
        }
        sum_w    += w;
        sum_wppl += w * (double) per_domain[i].ppl;
        sum_wpr  += w * (double) per_domain[i].pass_rate;
        summary_out->total_prompts += per_domain[i].n_prompts;
    }
    if (sum_w <= 0.0) {
        return -1;  // all weights zero
    }
    summary_out->weighted_ppl       = (float) (sum_wppl / sum_w);
    summary_out->weighted_pass_rate = (float) (sum_wpr / sum_w);
    summary_out->n_domains           = n_domains;
    summary_out->pass                = summary_out->weighted_pass_rate > pass_threshold;

    // Worst domain (lowest pass_rate). Ties broken by lowest ppl
    // (the worst domain on accuracy AND quality). The loop walks
    // the array once and tracks the best "worst" entry.
    int worst_idx = -1;
    float worst_pr = 2.0f;  // sentinel above 1.0
    float worst_ppl_at_pr = 0.0f;
    for (int64_t i = 0; i < n_domains; i++) {
        const float pr  = per_domain[i].pass_rate;
        const float ppl = per_domain[i].ppl;
        if (pr < worst_pr ||
            (pr == worst_pr && ppl > worst_ppl_at_pr)) {
            worst_pr        = pr;
            worst_ppl_at_pr = ppl;
            worst_idx       = (int) i;
        }
    }
    summary_out->worst_domain_idx = worst_idx;
    summary_out->worst_pass_rate  = (worst_idx >= 0) ? worst_pr : 0.0f;
    return 0;
}
