//
// tessera-l3-coherence.cpp
//
// L3 per-row coherence. See tessera-l3-coherence.h.
//

#include "tessera-l3-coherence.h"
#include "tessera-sidecar-v3.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>

// sidecar suffixes written by the runtime hook (common/tessera-debug)
static const char * TS_L3_SUFFIX_L1  = ".dequant.f32";
static const char * TS_L3_SUFFIX_REF = ".act.dequant.f32";

void ts_l3_default_config(ts_l3_config * cfg) {
    if (cfg == nullptr) {
        return;
    }
    cfg->sidecar_dir[0]   = '\0';
    cfg->reference_dir[0] = '\0';
    cfg->threshold        = 0.99f;
}

float ts_l3_row_cosine(const float * a, const float * b, int64_t n) {
    if (a == nullptr || b == nullptr || n <= 0) {
        return 0.0f;
    }

    double dot = 0.0;
    double na  = 0.0;
    double nb  = 0.0;
    for (int64_t i = 0; i < n; i++) {
        dot += (double)a[i] * (double)b[i];
        na  += (double)a[i] * (double)a[i];
        nb  += (double)b[i] * (double)b[i];
    }

    if (na == 0.0 || nb == 0.0) {
        return (na == 0.0 && nb == 0.0) ? 1.0f : 0.0f;
    }
    return (float)(dot / (sqrt(na) * sqrt(nb)));
}

float ts_l3_kl_divergence(const float * p, const float * q, int64_t n,
                          float eps, float * p_log_q_out) {
    if (p == nullptr || q == nullptr || n <= 0) {
        return 0.0f;
    }
    if (eps < 0.0f) {
        eps = 0.0f;
    }
    double sum_p   = 0.0;
    double kl      = 0.0;
    for (int64_t i = 0; i < n; i++) {
        sum_p += (double) p[i];
    }
    // Degenerate P (sums to 0): the per-token breakdown is undefined;
    // return 0.0 (no contribution to the joint KL).
    if (sum_p <= 0.0) {
        if (p_log_q_out != nullptr) {
            for (int64_t i = 0; i < n; i++) {
                p_log_q_out[i] = 0.0f;
            }
        }
        return 0.0f;
    }
    // Compute the KL contribution per token. Q is smoothed by eps
    // (caller controls the smoothing; default 1e-10 is the standard
    // practice for log-domain numerical stability).
    for (int64_t i = 0; i < n; i++) {
        const double pi = (double) p[i] / sum_p;
        const double qi = (double) q[i] + (double) eps;
        if (pi > 0.0) {
            // log(pi / qi) = log(pi) - log(qi)
            const double term = pi * (std::log(pi) - std::log(qi));
            kl += term;
            if (p_log_q_out != nullptr) {
                p_log_q_out[i] = (float) term;
            }
        } else {
            if (p_log_q_out != nullptr) {
                p_log_q_out[i] = 0.0f;
            }
        }
    }
    return (float) kl;
}

ts_l3_attribution_summary ts_l3_attribute_drift(
    const float * kl_joint_curve, const float * kl_weight_curve,
    const float * kl_kv_curve, int64_t n_layers, float joint_eps) {
    ts_l3_attribution_summary s = {};
    s.attribution = TS_L3_ATTR_OK;
    s.compounding_layer = -1;
    if (kl_joint_curve == nullptr || n_layers <= 0) {
        return s;
    }
    if (joint_eps <= 0.0f) {
        joint_eps = 0.1f;
    }

    // Per-layer sums (used for first-50 mean and the compounding
    // detection). The "first 50" is a position count, not a layer
    // count; the per-position mean at layer L is the average over
    // positions 1..50 of the per-position KL at layer L. For now we
    // treat the input curves as already-averaged (i.e. one scalar
    // per layer) and compute the layer-mean of those; the
    // position-level reduction is the orchestrator's job.
    double sum_joint  = 0.0;
    double sum_weight = 0.0;
    double sum_kv     = 0.0;
    int64_t n_joint_layers  = 0;
    int64_t n_weight_layers = 0;
    int64_t n_kv_layers     = 0;
    for (int64_t i = 0; i < n_layers; i++) {
        const float vj = kl_joint_curve[i];
        if (vj > 0.0f) {
            sum_joint += vj;
            n_joint_layers++;
        }
        if (kl_weight_curve != nullptr) {
            const float vw = kl_weight_curve[i];
            if (vw > 0.0f) {
                sum_weight += vw;
                n_weight_layers++;
            }
        }
        if (kl_kv_curve != nullptr) {
            const float vk = kl_kv_curve[i];
            if (vk > 0.0f) {
                sum_kv += vk;
                n_kv_layers++;
            }
        }
    }
    s.mean_kl_all_joint = (n_joint_layers > 0)
        ? (float) (sum_joint / (double) n_joint_layers) : 0.0f;
    // "first 50" is the same as the layer-mean in this scalar API;
    // the orchestrator may want to use the position-level curves
    // directly. We populate both fields with the same value so
    // the JSON report has a well-defined mean_kl_first_50_joint.
    s.mean_kl_first_50_joint  = s.mean_kl_all_joint;
    s.mean_kl_first_50_weight = (n_weight_layers > 0)
        ? (float) (sum_weight / (double) n_weight_layers) : 0.0f;
    s.mean_kl_first_50_kv     = (n_kv_layers > 0)
        ? (float) (sum_kv / (double) n_kv_layers) : 0.0f;

    // Coupling ratio: joint / max(weight, kv, eps). The eps floor
    // avoids div-by-zero when both components are zero.
    const float max_comp = std::max({
        s.mean_kl_first_50_weight, s.mean_kl_first_50_kv, joint_eps * 0.1f});
    s.coupling_ratio = s.mean_kl_first_50_joint / max_comp;

    // For the NUMERICAL check, use the raw max of the two
    // components (no floor) so a true "both below eps" situation
    // is detected even when joint_eps is small.
    const float max_comp_raw = std::max(
        s.mean_kl_first_50_weight, s.mean_kl_first_50_kv);

    // Attribution classification (spec §6.3b).
    if (s.mean_kl_first_50_joint < joint_eps) {
        s.attribution = TS_L3_ATTR_OK;
    } else if (max_comp_raw < joint_eps) {
        // Both components are below the joint epsilon: the joint
        // error isn't explained by either, so flag as numerical
        // (FP rounding, layout mismatch, etc.).
        s.attribution = TS_L3_ATTR_NUMERICAL;
    } else if (s.coupling_ratio > 2.0f) {
        s.attribution = TS_L3_ATTR_COMPOUNDING;
        // Find the first layer where joint > 2 * max(weight, kv).
        for (int64_t i = 0; i < n_layers; i++) {
            const float vj = kl_joint_curve[i];
            const float vw = (kl_weight_curve != nullptr) ? kl_weight_curve[i] : 0.0f;
            const float vk = (kl_kv_curve     != nullptr) ? kl_kv_curve[i]     : 0.0f;
            const float m  = std::max({vw, vk, joint_eps * 0.1f});
            if (vj > 2.0f * m) {
                s.compounding_layer = (int) i;
                break;
            }
        }
    } else if (s.mean_kl_first_50_weight > s.mean_kl_first_50_kv) {
        s.attribution = TS_L3_ATTR_WEIGHT;
    } else {
        s.attribution = TS_L3_ATTR_KV;
    }
    return s;
}

int ts_l3_tensor_coherence(const float * l1, const float * ref,
                           int64_t rows, int64_t cols,
                           float threshold,
                           ts_l3_tensor_result * out) {
    if (l1 == nullptr || ref == nullptr || out == nullptr ||
        rows <= 0 || cols <= 0) {
        return -1;
    }

    out->rows = rows;
    out->cols = cols;
    out->flagged_rows.clear();
    out->n_flagged = 0;

    double cos_sum = 0.0;
    float  cos_min = 1.0f;
    for (int64_t r = 0; r < rows; r++) {
        const float * a = l1  + r * cols;
        const float * b = ref + r * cols;
        const float c = ts_l3_row_cosine(a, b, cols);
        cos_sum += (double)c;
        if (c < cos_min) {
            cos_min = c;
        }
        if (c < threshold) {
            out->flagged_rows.push_back(r);
            out->n_flagged++;
        }
    }

    out->mean_cosine = (float)(cos_sum / (double)rows);
    out->min_cosine  = cos_min;
    return 0;
}

// Load a v3 sidecar at <dir>/<name><suffix> into out (row-major F32).
static int ts_l3_load(const char * dir, const char * name, const char * suffix,
                      std::vector<float> * out, int64_t * rows, int64_t * cols) {
    std::string path(dir);
    path += '/';
    path += name;
    path += suffix;

    ts_sidecar_v3 sc;
    if (ts_sidecar_v3_read(path.c_str(), &sc, nullptr) != 0) {
        return -1;
    }
    if (sc.header.rows <= 0 || sc.header.cols <= 0) {
        return -1;
    }
    if ((int64_t)sc.data.size() != sc.header.rows * sc.header.cols) {
        return -1;
    }
    *out  = std::move(sc.data);
    *rows = sc.header.rows;
    *cols = sc.header.cols;
    return 0;
}

int ts_l3_run(const ts_l3_config * cfg,
              const char * const * tensor_names,
              int64_t n_tensors,
              ts_l3_report * report) {
    if (cfg == nullptr || tensor_names == nullptr || report == nullptr ||
        n_tensors < 0) {
        return -1;
    }

    const float threshold = cfg->threshold > 0.0f ? cfg->threshold : 0.99f;

    report->tensors.clear();
    report->n_tensors      = 0;
    report->n_flagged_rows = 0;

    for (int64_t i = 0; i < n_tensors; i++) {
        const char * name = tensor_names[i];
        if (name == nullptr) {
            continue;
        }

        std::vector<float> l1;
        std::vector<float> ref;
        int64_t l1_rows = 0, l1_cols = 0;
        int64_t rf_rows = 0, rf_cols = 0;

        if (ts_l3_load(cfg->sidecar_dir,   name, TS_L3_SUFFIX_L1,
                       &l1, &l1_rows, &l1_cols) != 0) {
            continue;   // no L1 sidecar
        }
        if (ts_l3_load(cfg->reference_dir, name, TS_L3_SUFFIX_REF,
                       &ref, &rf_rows, &rf_cols) != 0) {
            continue;   // no reference sidecar
        }
        if (l1_rows != rf_rows || l1_cols != rf_cols) {
            continue;   // shape mismatch
        }

        ts_l3_tensor_result r;
        r.tensor_name = name;
        if (ts_l3_tensor_coherence(l1.data(), ref.data(), l1_rows, l1_cols,
                                   threshold, &r) != 0) {
            continue;
        }

        report->n_flagged_rows += r.n_flagged;
        report->tensors.push_back(std::move(r));
        report->n_tensors++;
    }

    return (int)report->n_tensors;
}
