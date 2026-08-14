#include "tessera-kv-migrate.h"

#include "tessera-quantize-db.h"
#include "tessera-higgs-proxy.h"
#include "tessera-regime.h"

#include <cmath>

int ts_kv_migrate_fit_scale(const ts_tessera_db_kv_stat & stat, bool pair_tie,
                             const ts_kv_migrate_params & params,
                             std::vector<float> * out_scale, std::string * err) {
    if (stat.n_samples < params.min_samples) {
        if (err) *err = "kv_migrate: insufficient samples (" +
                        std::to_string(stat.n_samples) + " < " +
                        std::to_string(params.min_samples) + ")";
        return 1;
    }
    const int64_t n = stat.n_channels;
    if (n <= 0 || (int64_t) stat.sum2.size() != n) {
        if (err) *err = "kv_migrate: malformed kv_stat (n_channels/sum2 mismatch)";
        return 1;
    }
    if (pair_tie && (n % 2) != 0) {
        if (err) *err = "kv_migrate: pair_tie requested with odd n_channels";
        return 1;
    }

    std::vector<float> rms(n);
    if (pair_tie) {
        for (int64_t i = 0; i < n; i += 2) {
            const double pooled_sum2 = (double) stat.sum2[i] + (double) stat.sum2[i + 1];
            const double pooled_n    = (double) stat.n_samples * 2.0;
            const float  r           = (float) std::sqrt(pooled_sum2 / pooled_n);
            rms[i]     = r;
            rms[i + 1] = r;
        }
    } else {
        for (int64_t c = 0; c < n; c++) {
            rms[c] = (float) std::sqrt((double) stat.sum2[c] / (double) stat.n_samples);
        }
    }

    double sum_rms = 0.0;
    for (int64_t c = 0; c < n; c++) {
        sum_rms += rms[c];
    }
    const float target_rms = (float) (sum_rms / (double) n);

    out_scale->resize(n);
    for (int64_t c = 0; c < n; c++) {
        float scale = (rms[c] > 1e-12f) ? (target_rms / rms[c]) : params.clamp_max;
        if (scale < params.clamp_min) scale = params.clamp_min;
        if (scale > params.clamp_max) scale = params.clamp_max;
        (*out_scale)[c] = scale;
    }
    return 0;
}

int ts_kv_migrate_read_stat(ts_tessera_db * db, const std::string & model_hash,
                             const std::string & model_role, int32_t layer_depth,
                             bool is_k, ts_tessera_db_kv_stat * out, bool * hit,
                             std::string * err) {
    if (hit) *hit = false;
    if (db == nullptr) {
        return 0;
    }

    const std::string layer_prefix = "blk." + std::to_string(layer_depth) + ".";
    const std::string primary   = layer_prefix + (is_k ? "attn_k" : "attn_v");
    const std::string fallback  = layer_prefix + (is_k ? "kv_k"   : "kv_v");

    for (const std::string & name : { primary, fallback }) {
        bool row_hit = false;
        std::string local_err;
        int rc = ts_tessera_db_read_kv_stat(db, model_hash, model_role, name,
                                            out, &row_hit, &local_err);
        if (rc != 0) {
            if (err) *err = local_err;
            return rc;
        }
        if (row_hit) {
            if (hit) *hit = true;
            return 0;
        }
    }
    return 0;
}

void ts_kv_migrate_tile_scale(const std::vector<float> & head_scale, int64_t n_head,
                               std::vector<float> * out_tiled) {
    const int64_t head_dim = (int64_t) head_scale.size();
    out_tiled->resize((size_t) (n_head * head_dim));
    for (int64_t h = 0; h < n_head; h++) {
        for (int64_t c = 0; c < head_dim; c++) {
            (*out_tiled)[(size_t) (h * head_dim + c)] = head_scale[(size_t) c];
        }
    }
}

void ts_kv_migrate_apply_row_scale(float * w, int64_t out_dim, int64_t in_dim,
                                    const std::vector<float> & row_scale) {
    const int64_t period = (int64_t) row_scale.size();
    if (period == 0) return;
    for (int64_t r = 0; r < out_dim; r++) {
        const float s = row_scale[(size_t) (r % period)];
        float * row = w + r * in_dim;
        for (int64_t c = 0; c < in_dim; c++) {
            row[c] *= s;
        }
    }
}

void ts_kv_migrate_apply_col_scale(float * w, int64_t out_dim, int64_t in_dim,
                                    const std::vector<float> & col_scale) {
    const int64_t period = (int64_t) col_scale.size();
    if (period == 0) return;
    for (int64_t r = 0; r < out_dim; r++) {
        float * row = w + r * in_dim;
        for (int64_t c = 0; c < in_dim; c++) {
            row[c] *= col_scale[(size_t) (c % period)];
        }
    }
}

int ts_kv_migrate_apply_to_tensor(ts_tessera_db * db, const std::string & model_hash,
                                   const std::string & model_role,
                                   const std::string & tensor_name,
                                   float * w, int64_t out_dim, int64_t in_dim,
                                   const ts_kv_migrate_params & params,
                                   std::string * err) {
    if (db == nullptr || !params.enabled) {
        if (err) *err = "kv_migrate: no db / disabled";
        return 1;
    }

    const std::string family = ts_higgs_proxy_classify_family(tensor_name);
    const bool is_q = (family == "attn_q");
    const bool is_o = (family == "attn_output");
    if (!is_q && !is_o) {
        if (err) *err = "kv_migrate: tensor family '" + family + "' is not attn_q/attn_output";
        return 1;
    }

    const int32_t layer_depth = ts_regime_extract_layer(tensor_name.c_str());
    if (layer_depth < 0) {
        if (err) *err = "kv_migrate: could not extract layer index from '" + tensor_name + "'";
        return 1;
    }

    // D (for W_q) comes from K's stats and must be pair-tied (RoPE
    // legality); E (for W_o) comes from V's stats and needs no such tie.
    ts_tessera_db_kv_stat stat;
    bool hit = false;
    std::string local_err;
    int rc = ts_kv_migrate_read_stat(db, model_hash, model_role, layer_depth,
                                     /*is_k=*/is_q, &stat, &hit, &local_err);
    if (rc != 0) {
        if (err) *err = local_err;
        return rc;
    }
    if (!hit) {
        if (err) *err = "kv_migrate: no kv_stats row for layer " + std::to_string(layer_depth);
        return 1;
    }

    const int64_t head_dim = stat.n_channels;
    const int64_t fold_dim = is_q ? out_dim : in_dim;
    if (head_dim <= 0 || (fold_dim % head_dim) != 0) {
        if (err) *err = "kv_migrate: " + std::string(is_q ? "out_dim" : "in_dim") +
                        " is not a multiple of head_dim (" + std::to_string(head_dim) + ")";
        return 1;
    }
    const int64_t n_head = fold_dim / head_dim;

    std::vector<float> head_scale;
    rc = ts_kv_migrate_fit_scale(stat, /*pair_tie=*/is_q, params, &head_scale, &local_err);
    if (rc != 0) {
        if (err) *err = local_err;
        return rc;
    }

    std::vector<float> tiled;
    ts_kv_migrate_tile_scale(head_scale, n_head, &tiled);

    if (is_q) {
        ts_kv_migrate_apply_row_scale(w, out_dim, in_dim, tiled);
    } else {
        ts_kv_migrate_apply_col_scale(w, out_dim, in_dim, tiled);
    }
    return 0;
}
