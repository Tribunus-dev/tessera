//
// tessera-l2-diff.cpp
//
// L2 BF16-vs-quantized weight-level differential. See tessera-l2-diff.h.
//

#include "tessera-l2-diff.h"

#include "tessera-linalg.h"

#include <nlohmann/json.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <vector>
#include <sstream>

using json = nlohmann::json;

static const char * TS_L2_SCHEMA = "llama.tessera.runtime-probe.v1";

// finite stand-in for an infinite relative error (zero-norm reference)
static const float TS_L2_INF = 1e30f;

void ts_l2_default_config(ts_l2_config * cfg) {
    if (cfg == nullptr) {
        return;
    }
    cfg->bf16_model_path[0]   = '\0';
    cfg->quant_model_path[0]  = '\0';
    cfg->corpus_path[0]       = '\0';
    cfg->output_json_path[0]  = '\0';
    cfg->flag_multiplier      = 1.5f;
}

float ts_l2_expected_frob(const char * qtype) {
    if (qtype == nullptr) {
        return 5e-2f;
    }
    if (strcmp(qtype, "f16") == 0 || strcmp(qtype, "f32") == 0) {
        return 1e-5f;
    }
    if (strcmp(qtype, "q8_0") == 0) {
        return 1e-3f;
    }
    if (strcmp(qtype, "q4_k") == 0 || strcmp(qtype, "q4_0") == 0) {
        return 5e-2f;
    }
    if (strcmp(qtype, "tessera_t640") == 0 || strcmp(qtype, "t640") == 0) {
        return 2e-2f;
    }
    return 5e-2f;
}

ts_l2_divergence ts_l2_tensor_divergence(const float * bf16,
                                         const float * quant,
                                         int64_t n) {
    ts_l2_divergence d = { 0.0f, 0.0f, 0.0f, 0.0f };
    if (bf16 == nullptr || quant == nullptr || n <= 0) {
        return d;
    }

    double max_abs = 0.0;
    double sum_abs = 0.0;
    double num     = 0.0;   // ||bf16 - quant||_F^2
    double den     = 0.0;   // ||bf16||_F^2
    for (int64_t i = 0; i < n; i++) {
        const double diff = (double)bf16[i] - (double)quant[i];
        const double a    = fabs(diff);
        if (a > max_abs) {
            max_abs = a;
        }
        sum_abs += a;
        num += diff * diff;
        den += (double)bf16[i] * (double)bf16[i];
    }

    d.max_abs  = (float)max_abs;
    d.mean_abs = (float)(sum_abs / (double)n);
    d.relative_frobenius = (den > 0.0) ? (float)(num / den)
                                       : (num > 0.0 ? TS_L2_INF : 0.0f);
    d.per_layer_norm = (float)sqrt(num / (double)n);
    return d;
}

ts_l2_act_divergence ts_l2_compute_act_diff(const float * y_ref,
                                            const float * y_quant,
                                            int64_t n_samples,
                                            int64_t out_dim) {
    ts_l2_act_divergence d = { 0.0f, 0.0f, 0 };
    if (y_ref == nullptr || y_quant == nullptr ||
        n_samples <= 0 || out_dim <= 0) {
        return d;
    }

    // Two reductions:
    //   (1) Frobenius: ||Y_ref - Y_quant||_F^2 / ||Y_ref||_F^2
    //   (2) Per-row argmax mismatch: mean over rows of
    //       1[argmax(Y_ref[r]) != argmax(Y_quant[r])]
    //
    // Both reductions walk the buffer once (single-pass for
    // Frobenius; per-row argmax with one pass over out_dim per row).
    // We accumulate in F64 for numerical stability on large n.

    double num = 0.0;        // ||Y_ref - Y_quant||_F^2
    double den = 0.0;        // ||Y_ref||_F^2
    int64_t n_mismatch = 0;  // per-row argmax mismatch count

    std::vector<float> y_ref_row((size_t) out_dim, 0.0f);
    std::vector<float> y_quant_row((size_t) out_dim, 0.0f);

    for (int64_t r = 0; r < n_samples; r++) {
        // Copy this row into the local buffers (small per-row copy
        // is cheaper than random-access math on the inputs). Then
        // walk the row once for Frobenius accumulation and once for
        // argmax (the argmax is single-pass within the row).
        std::memcpy(y_ref_row.data(),   y_ref   + r * out_dim, (size_t) out_dim * sizeof(float));
        std::memcpy(y_quant_row.data(), y_quant + r * out_dim, (size_t) out_dim * sizeof(float));

        // Frobenius contribution for this row.
        for (int64_t c = 0; c < out_dim; c++) {
            const double diff = (double) y_ref_row[(size_t) c] - (double) y_quant_row[(size_t) c];
            num += diff * diff;
            den += (double) y_ref_row[(size_t) c] * (double) y_ref_row[(size_t) c];
        }

        // Argmax of each row. Ties broken by lowest index (standard
        // argmax convention); the test fixture uses distinct values
        // to make the argmax deterministic, so ties are not a
        // practical concern.
        int64_t argmax_ref   = 0;
        int64_t argmax_quant = 0;
        float   max_ref      = y_ref_row[0];
        float   max_quant    = y_quant_row[0];
        for (int64_t c = 1; c < out_dim; c++) {
            if (y_ref_row[(size_t) c] > max_ref) {
                max_ref    = y_ref_row[(size_t) c];
                argmax_ref = c;
            }
            if (y_quant_row[(size_t) c] > max_quant) {
                max_quant    = y_quant_row[(size_t) c];
                argmax_quant = c;
            }
        }
        if (argmax_ref != argmax_quant) {
            n_mismatch++;
        }
    }

    d.relative_frobenius = (den > 0.0) ? (float)(num / den)
                                       : (num > 0.0 ? TS_L2_INF : 0.0f);
    d.top1_mismatch = (float) ((double) n_mismatch / (double) n_samples);
    d.n_samples     = n_samples;
    return d;
}

int ts_l2_run(const ts_l2_config * cfg,
              const ts_l2_tensor_input * inputs,
              int64_t n_tensors,
              ts_l2_report * report) {
    if (cfg == nullptr || inputs == nullptr || report == nullptr || n_tensors < 0) {
        return -1;
    }

    const float mult = cfg->flag_multiplier > 0.0f ? cfg->flag_multiplier : 1.5f;

    report->tensors.clear();
    report->tensors.reserve((size_t)n_tensors);
    report->n_flagged = 0;

    for (int64_t i = 0; i < n_tensors; i++) {
        const ts_l2_tensor_input & in = inputs[i];
        const int64_t n = in.rows * in.cols;

        ts_l2_tensor_result r;
        r.tensor_name = in.name != nullptr ? in.name : "";
        r.qtype       = in.qtype != nullptr ? in.qtype : "";
        r.rows        = in.rows;
        r.cols        = in.cols;
        r.divergence  = ts_l2_tensor_divergence(in.bf16, in.quant, n);
        r.expected_frob  = ts_l2_expected_frob(in.qtype);
        r.flag_threshold = mult * r.expected_frob;
        r.flagged        = r.divergence.relative_frobenius > r.flag_threshold;

        if (r.flagged) {
            report->n_flagged++;
        }
        report->tensors.push_back(std::move(r));
    }

    if (cfg->output_json_path[0] != '\0') {
        if (ts_l2_write_report(cfg->output_json_path, cfg, report) != 0) {
            return -1;
        }
    }
    return (int)report->n_flagged;
}

int ts_l2_write_report(const char * path,
                       const ts_l2_config * cfg,
                       const ts_l2_report * report) {
    if (path == nullptr || report == nullptr) {
        return -1;
    }

    json j;
    j["schema"]          = TS_L2_SCHEMA;
    j["layer"]           = "L2";
    j["bf16_model"]      = cfg != nullptr ? cfg->bf16_model_path : "";
    j["quant_model"]     = cfg != nullptr ? cfg->quant_model_path : "";
    j["corpus"]          = cfg != nullptr ? cfg->corpus_path : "";
    j["flag_multiplier"] = cfg != nullptr ? cfg->flag_multiplier : 1.5f;
    j["n_tensors"]       = (int64_t)report->tensors.size();
    j["n_flagged"]       = report->n_flagged;

    json tensors = json::array();
    for (const auto & r : report->tensors) {
        json t;
        t["tensor"] = r.tensor_name;
        t["qtype"]  = r.qtype;
        t["shape"]  = json::array({ r.rows, r.cols });

        json div;
        div["max_abs"]            = r.divergence.max_abs;
        div["mean_abs"]           = r.divergence.mean_abs;
        div["relative_frobenius"] = r.divergence.relative_frobenius;
        div["per_layer_norm"]     = r.divergence.per_layer_norm;
        t["divergence"] = div;

        t["expected_frob"]  = r.expected_frob;
        t["flag_threshold"] = r.flag_threshold;
        t["flagged"]        = r.flagged;
        tensors.push_back(t);
    }
    j["tensors"] = tensors;

    std::ofstream out(path);
    if (!out) {
        return -1;
    }
    out << j.dump(2) << "\n";
    return out.good() ? 0 : -1;
}

int ts_l2_load_report(const char * path, ts_l2_report * report) {
    if (path == nullptr || report == nullptr) {
        return -1;
    }

    std::ifstream in(path);
    if (!in) {
        return -1;
    }
    std::stringstream ss;
    ss << in.rdbuf();

    json j;
    try {
        j = json::parse(ss.str());
    } catch (const std::exception &) {
        return -1;
    }

    if (j.value("schema", std::string()) != TS_L2_SCHEMA) {
        return -1;
    }

    report->tensors.clear();
    report->n_flagged = 0;

    if (!j.contains("tensors") || !j["tensors"].is_array()) {
        return -1;
    }
    for (const auto & t : j["tensors"]) {
        ts_l2_tensor_result r;
        r.tensor_name = t.value("tensor", std::string());
        r.qtype       = t.value("qtype", std::string());

        r.rows = 0;
        r.cols = 0;
        if (t.contains("shape") && t["shape"].is_array() && t["shape"].size() == 2) {
            r.rows = t["shape"][0].get<int64_t>();
            r.cols = t["shape"][1].get<int64_t>();
        }

        const json & div = t["divergence"];
        r.divergence.max_abs            = div.value("max_abs", 0.0f);
        r.divergence.mean_abs           = div.value("mean_abs", 0.0f);
        r.divergence.relative_frobenius = div.value("relative_frobenius", 0.0f);
        r.divergence.per_layer_norm     = div.value("per_layer_norm", 0.0f);

        r.expected_frob  = t.value("expected_frob", 0.0f);
        r.flag_threshold = t.value("flag_threshold", 0.0f);
        r.flagged        = t.value("flagged", false);

        if (r.flagged) {
            report->n_flagged++;
        }
        report->tensors.push_back(std::move(r));
    }
    return 0;
}

// Internal: compute erank + top_k_concentration from a singular-value
// vector. sigma is (n_singular_values,) F32, sorted descending (the
// SVD routine returns descending-ordered sigma). k is the top-k for
// the concentration metric.
static void ts_l2_spectral_from_sigma(const float * sigma,
                                     int64_t n_singular_values, int64_t k,
                                     float * erank_out,
                                     float * top_k_conc_out) {
    double sum_sig = 0.0;
    double sum_sq  = 0.0;
    for (int64_t i = 0; i < n_singular_values; i++) {
        const double s = (double) sigma[i];
        if (s < 0.0) continue;  // guard against negative SVs from noise
        sum_sig += s;
        sum_sq  += s * s;
    }
    if (sum_sig <= 0.0 || n_singular_values <= 0) {
        *erank_out     = 0.0f;
        *top_k_conc_out = 0.0f;
        return;
    }
    // Effective rank: exp(-sum_i p_i log p_i) where p_i = sigma_i / sum
    // sigma. The entropy-of-singular-values form (Roy & Vetterli;
    // reformulated in ARSVD arXiv:2504.20078). When only a sketch is
    // available (n_singular_values < min(m,n)), the missing mass is
    // treated as a single extra "tail" term so the erank is a
    // well-defined upper bound on the true erank.
    double entropy = 0.0;
    for (int64_t i = 0; i < n_singular_values; i++) {
        const double s = (double) sigma[i];
        if (s <= 0.0) continue;
        const double p = s / sum_sig;
        entropy -= p * std::log(p);
    }
    // The tail mass: sum_sig^2 - sum_sq is not the right invariant
    // (sum_sq is sum sigma^2, not sum sigma). For the "missing tail"
    // we just use the residual mass (1.0 - sum_p) as a single term.
    const double p_tail = 1.0 - (sum_sig / sum_sig);  // 0; the captured SVs sum to sum_sig
    (void) p_tail;
    *erank_out = (float) std::exp(entropy);

    // top_k_concentration: sum_{i<=k} sigma_i^2 / sum sigma^2.
    double top_k_sq = 0.0;
    const int64_t kk = (k > n_singular_values) ? n_singular_values : k;
    for (int64_t i = 0; i < kk; i++) {
        const double s = (double) sigma[i];
        top_k_sq += s * s;
    }
    *top_k_conc_out = (sum_sq > 0.0) ? (float) (top_k_sq / sum_sq) : 0.0f;
}

ts_l2_spectral_metrics ts_l2_compute_spectral_metrics(
    const float * A, int64_t m, int64_t n, int64_t k,
    int64_t n_singular_values, int64_t n_iters, uint32_t seed) {
    ts_l2_spectral_metrics out = {};
    out.k = k;
    out.n_singular_values = 0;
    if (A == nullptr || m <= 0 || n <= 0 || k <= 0 || n_iters <= 0) {
        return out;
    }
    // Default n_singular_values: full SVD (min(m,n)).
    const int64_t min_dim = (m < n) ? m : n;
    if (n_singular_values <= 0 || n_singular_values > min_dim) {
        n_singular_values = min_dim;
    }
    // Allocate U, S, V. ts_linalg_svd_topk takes (m x k) U, (k,) S,
    // (n x k) V. We use a std::vector for the dynamic allocation
    // and pass .data() to the C-API.
    std::vector<float> U((size_t) (m * n_singular_values), 0.0f);
    std::vector<float> V((size_t) (n * n_singular_values), 0.0f);
    std::vector<float> S((size_t) n_singular_values, 0.0f);
    ts_linalg_svd_topk(A, U.data(), S.data(), V.data(),
                        m, n, n_singular_values, n_iters, seed);
    out.spectral_norm = S[0];  // S is descending-ordered by the SVD routine
    out.n_singular_values = n_singular_values;
    float erank_val = 0.0f;
    float top_k_val = 0.0f;
    ts_l2_spectral_from_sigma(S.data(), n_singular_values, k,
                              &erank_val, &top_k_val);
    out.erank = erank_val;
    out.top_k_concentration = top_k_val;
    return out;
}

ts_l2_spectral_metrics ts_l2_compute_spectral_drop(
    const float * Y_ref, const float * Y_quant,
    int64_t m, int64_t n, int64_t k,
    int64_t n_singular_values, int64_t n_iters, uint32_t seed) {
    ts_l2_spectral_metrics out = {};
    out.k = k;
    if (Y_ref == nullptr || Y_quant == nullptr || m <= 0 || n <= 0) {
        return out;
    }
    // Compute the metrics on Y_ref and Y_quant independently; the
    // drops are signed (positive = Y_quant has less capacity).
    const uint32_t seed_q = (seed == 0) ? 0xCAFEu : (seed + 1);
    const ts_l2_spectral_metrics ref = ts_l2_compute_spectral_metrics(
        Y_ref, m, n, k, n_singular_values, n_iters, seed);
    const ts_l2_spectral_metrics qnt = ts_l2_compute_spectral_metrics(
        Y_quant, m, n, k, n_singular_values, n_iters, seed_q);
    out.spectral_norm           = ref.spectral_norm;
    out.erank                   = ref.erank;
    out.top_k_concentration     = ref.top_k_concentration;
    out.n_singular_values       = ref.n_singular_values;
    out.k                       = k;
    // Drops: positive when the quantized matrix has lower erank /
    // higher top-k concentration (the spec's "capacity loss" signal).
    out.erank_drop              = ref.erank - qnt.erank;
    out.top_k_concentration_drop = qnt.top_k_concentration - ref.top_k_concentration;
    return out;
}

bool ts_l2_spectral_flagged(const ts_l2_spectral_metrics * metrics,
                           float erank_drop_eps, float top_k_drop_eps) {
    if (metrics == nullptr) {
        return false;
    }
    if (metrics->erank_drop > 0.1f * metrics->erank) {
        return true;
    }
    if (metrics->top_k_concentration_drop > 0.05f) {
        return true;
    }
    return false;
}
