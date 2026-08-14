#pragma once

//
// tessera-kv-migrate.h
//
// KV-joint reconstruction, item 5 ("scale migration"): fold K's and V's
// static per-channel reconstruction scales (D, E) into W_q and W_o so the
// runtime never needs to touch the KV cache's dequant path. See
// docs/tessera-kv-joint-reconstruction-design.md section 3 for the
// derivation:
//
//   scores = RoPE(x W_q_hat) . K_hat^T,  K_hat = K_int . D
//   Q . (K_int D)^T = (Q D) . K_int^T   =>   W_q' = W_q with each OUTPUT
//   row scaled by D[channel] (channel = row index mod head_dim; D is
//   shared across all heads since it is fit from a per-layer, pooled-
//   across-heads kv_stats row).
//
//   out = A V_hat W_o,  V_hat = V_int . E
//   A (V_int E) W_o = A V_int (E-scaled W_o)   =>   W_o' = W_o with each
//   INPUT column scaled by E[channel] (channel = column index mod
//   head_dim).
//
// D additionally must be pair-tied within each RoPE-rotated channel pair
// (D[2i] == D[2i+1]) for the fold to be legal; E has no such constraint
// (no RoPE on V).
//
// This is additive/opt-in: it only changes anything when a --tessera-db
// is open AND a kv_stats row with enough samples exists for the tensor's
// layer/side. Absent that (the case for every quantize run today, since
// no kv_stats data has been captured for any model yet), every function
// below is a clean no-op and the caller's weight buffer is untouched.
//

#include <cstdint>
#include <string>
#include <vector>

struct ts_tessera_db;
struct ts_tessera_db_kv_stat;

struct ts_kv_migrate_params {
    // A kv_stats row with fewer samples than this is treated as
    // insufficient data (fold skipped, not attempted) -- guards against
    // fitting a scale off a handful of tokens.
    int64_t min_samples = 256;
    // Clamp the fitted scale to [clamp_min, clamp_max] so a near-zero-RMS
    // channel (silence, a dead channel) cannot blow up into a huge
    // multiplier.
    float clamp_min = 0.25f;
    float clamp_max = 4.0f;
    // Cheap kill switch (e.g. for an A/B run comparing fold on vs off).
    bool enabled = true;
};

// Fits a per-channel reconstruction scale from a kv_stats row:
//   rms(c)     = sqrt(sum2[c] / n_samples)
//   target_rms = mean_c(rms(c))
//   scale[c]   = clamp(target_rms / rms(c), clamp_min, clamp_max)
//
// When pair_tie is true (K/D only -- RoPE legality), each channel pair
// {2i, 2i+1} is pooled BEFORE the sqrt/divide: pooled_sum2 = sum2[2i] +
// sum2[2i+1], pooled_n = n_samples * 2, giving the least-squares-optimal
// single scale for the tied pair. This guarantees out_scale[2i] ==
// out_scale[2i+1] bit-exactly even when the raw per-channel stats differ.
// E (V's scale) does not need pair-tying; pass pair_tie=false.
//
// Returns 0 and fills out_scale (length stat.n_channels) on success.
// Returns non-zero (out_scale untouched) when stat.n_samples <
// params.min_samples, stat.n_channels is odd while pair_tie is requested,
// or the row is otherwise malformed (sum2 size mismatch). *err is set on
// failure.
int ts_kv_migrate_fit_scale(const ts_tessera_db_kv_stat & stat, bool pair_tie,
                             const ts_kv_migrate_params & params,
                             std::vector<float> * out_scale, std::string * err);

// Reads the kv_stats row for (model_hash, model_role, layer_depth, K-or-V
// side), trying both name conventions the two Phase-3 capture paths write:
//   "blk.<layer_depth>.attn_k" / "attn_v"   (collector-side, preferred)
//   "blk.<layer_depth>.kv_k"   / "kv_v"     (graph-side, fallback)
// hit=false (return 0, not an error) when neither name has a row. db ==
// nullptr is a safe no-op (hit=false, return 0), mirroring
// ts_tessera_db_read_kv_stat's own contract.
int ts_kv_migrate_read_stat(ts_tessera_db * db, const std::string & model_hash,
                             const std::string & model_role, int32_t layer_depth,
                             bool is_k, ts_tessera_db_kv_stat * out, bool * hit,
                             std::string * err);

// Repeats a head_dim-length per-channel scale n_head times, producing the
// (n_head * head_dim)-length vector that directly indexes W_q's output
// rows (or W_o's input columns).
void ts_kv_migrate_tile_scale(const std::vector<float> & head_scale, int64_t n_head,
                               std::vector<float> * out_tiled);

// W_q' fold: scales row `r` of the (out_dim x in_dim) row-major weight by
// row_scale[r % row_scale.size()]. row_scale.size() must evenly divide
// out_dim (caller's responsibility -- ts_kv_migrate_apply_to_tensor
// enforces this before calling).
void ts_kv_migrate_apply_row_scale(float * w, int64_t out_dim, int64_t in_dim,
                                    const std::vector<float> & row_scale);

// W_o' fold: scales column `c` of the (out_dim x in_dim) row-major weight
// by col_scale[c % col_scale.size()]. col_scale.size() must evenly divide
// in_dim.
void ts_kv_migrate_apply_col_scale(float * w, int64_t out_dim, int64_t in_dim,
                                    const std::vector<float> & col_scale);

// Single entry point for every quantize call site. Classifies tensor_name
// via ts_higgs_proxy_classify_family and, for "attn_q" (row fold, D,
// pair-tied) or "attn_output" (column fold, E, not pair-tied), fits the
// scale from the matching kv_stats row and applies it to `w` in place.
//
// No-ops (returns 1, *err optionally set to a human-readable reason) when:
//   - db is null or !params.enabled
//   - the tensor's family is not attn_q / attn_output
//   - out_dim (attn_q) or in_dim (attn_output) is not an exact multiple
//     of the kv_stat's head_dim (n_channels) -- e.g. MLA-style tensors,
//     explicitly out of scope
//   - no sufficient kv_stats row exists for this layer/side
//
// Returns 0 iff the fold was actually applied in place to `w`.
int ts_kv_migrate_apply_to_tensor(ts_tessera_db * db, const std::string & model_hash,
                                   const std::string & model_role,
                                   const std::string & tensor_name,
                                   float * w, int64_t out_dim, int64_t in_dim,
                                   const ts_kv_migrate_params & params,
                                   std::string * err);
