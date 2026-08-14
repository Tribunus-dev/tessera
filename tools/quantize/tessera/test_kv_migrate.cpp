//
// test_kv_migrate.cpp
//
// Unit tests for tessera-kv-migrate.{h,cpp}: KV-joint reconstruction item 5
// (scale migration). Covers:
//   - ts_kv_migrate_fit_scale: RMS-equalization arithmetic, pair-tying
//     enforced bit-exactly, clamp saturation, min_samples fallback.
//   - ts_kv_migrate_read_stat: dual name-convention fallback
//     (attn_k/attn_v preferred, kv_k/kv_v fallback), clean miss.
//   - Forward-math identity check, exercising GQA directly: proves the
//     row/column fold derivation (Q.(K_int D)^T == (Q D).K_int^T, folded
//     into W_q/W_o) is correct for a query-head count that differs from
//     the kv-head count.
//   - ts_kv_migrate_apply_to_tensor integration: no-op on wrong family,
//     missing DB row, and shape mismatch.
//
// Links against llama-quantize-impl (DuckDB + the KV-migrate module are
// already bundled there); run with no args, uses a tmp DB file. Exit 0 on
// success, non-zero on failure.
//

#include "tessera-kv-migrate.h"
#include "tessera-quantize-db.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL [%s:%d]: %s\n", __FILE__, __LINE__, msg); \
        failures++; \
    } \
} while (0)

static ts_tessera_db_kv_stat make_stat(const std::vector<float> & sum2, int64_t n_samples) {
    ts_tessera_db_kv_stat s;
    s.model_hash  = "m";
    s.model_role  = "trunk";
    s.n_channels  = (int32_t) sum2.size();
    s.n_samples   = n_samples;
    s.sum2        = sum2;
    s.maxabs.assign(sum2.size(), 1.0f);
    return s;
}

static void test_fit_scale_basic() {
    // 4 channels, deliberately different magnitudes: rms = sqrt(sum2/n).
    // n_samples=1000 so target_rms/rms lands comfortably inside the
    // default clamp range for all 4 channels.
    std::vector<float> sum2 = { 1000.0f, 4000.0f, 9000.0f, 1000.0f };
    ts_tessera_db_kv_stat stat = make_stat(sum2, 1000);

    ts_kv_migrate_params params;
    std::vector<float> scale;
    std::string err;
    int rc = ts_kv_migrate_fit_scale(stat, /*pair_tie=*/false, params, &scale, &err);
    CHECK(rc == 0, ("fit_scale: basic case should succeed: " + err).c_str());
    CHECK(scale.size() == 4, "fit_scale: output length matches n_channels");

    // rms = [1.0, 2.0, 3.0, 1.0]; target_rms = mean = 1.75
    // scale = target_rms / rms = [1.75, 0.875, 0.5833, 1.75]
    const float expect[4] = { 1.75f, 0.875f, 1.75f / 3.0f, 1.75f };
    for (int i = 0; i < 4; i++) {
        CHECK(std::fabs(scale[i] - expect[i]) < 1e-3f,
              "fit_scale: scale[i] matches target_rms/rms(i)");
    }
}

static void test_fit_scale_pair_tying() {
    // Deliberately different sum2 within a pair {0,1} and {2,3}: pair-tying
    // must produce EXACTLY equal scale within each pair despite that.
    std::vector<float> sum2 = { 1000.0f, 9000.0f, 500.0f, 500.0f };
    ts_tessera_db_kv_stat stat = make_stat(sum2, 1000);

    ts_kv_migrate_params params;
    std::vector<float> scale;
    std::string err;
    int rc = ts_kv_migrate_fit_scale(stat, /*pair_tie=*/true, params, &scale, &err);
    CHECK(rc == 0, ("fit_scale: pair_tie case should succeed: " + err).c_str());
    CHECK(scale.size() == 4, "fit_scale/pair_tie: output length matches n_channels");
    CHECK(scale[0] == scale[1],
          "fit_scale/pair_tie: d[0] == d[1] bit-exactly despite differing raw sum2");
    CHECK(scale[2] == scale[3],
          "fit_scale/pair_tie: d[2] == d[3] bit-exactly despite differing raw sum2");
    CHECK(scale[0] != scale[2], "fit_scale/pair_tie: the two pairs still differ from each other");
}

static void test_fit_scale_pair_tying_odd_channels() {
    std::vector<float> sum2 = { 1.0f, 2.0f, 3.0f };
    ts_tessera_db_kv_stat stat = make_stat(sum2, 1000);
    ts_kv_migrate_params params;
    std::vector<float> scale;
    std::string err;
    int rc = ts_kv_migrate_fit_scale(stat, /*pair_tie=*/true, params, &scale, &err);
    CHECK(rc != 0, "fit_scale: pair_tie with odd n_channels is rejected");
}

static void test_fit_scale_clamp() {
    // channel 0 has near-zero rms (would blow up to a huge scale without
    // clamping); channel 1 has huge rms relative to target (would clamp
    // low).
    std::vector<float> sum2 = { 1e-8f, 1e8f, 100.0f, 100.0f };
    ts_tessera_db_kv_stat stat = make_stat(sum2, 1000);

    ts_kv_migrate_params params;
    params.clamp_min = 0.25f;
    params.clamp_max = 4.0f;
    std::vector<float> scale;
    std::string err;
    int rc = ts_kv_migrate_fit_scale(stat, /*pair_tie=*/false, params, &scale, &err);
    CHECK(rc == 0, ("fit_scale: clamp case should succeed: " + err).c_str());
    CHECK(scale[0] <= params.clamp_max + 1e-6f, "fit_scale/clamp: near-zero-rms channel clamps at max");
    CHECK(scale[1] >= params.clamp_min - 1e-6f, "fit_scale/clamp: huge-rms channel clamps at min");
    for (float s : scale) {
        CHECK(s >= params.clamp_min - 1e-6f && s <= params.clamp_max + 1e-6f,
              "fit_scale/clamp: every scale stays within [clamp_min, clamp_max]");
    }
}

static void test_fit_scale_min_samples() {
    std::vector<float> sum2 = { 1.0f, 2.0f, 3.0f, 4.0f };
    ts_tessera_db_kv_stat stat = make_stat(sum2, 10);  // thin

    ts_kv_migrate_params params;
    params.min_samples = 256;
    std::vector<float> scale;
    std::string err;
    int rc = ts_kv_migrate_fit_scale(stat, /*pair_tie=*/false, params, &scale, &err);
    CHECK(rc != 0, "fit_scale: n_samples below min_samples is rejected");
    CHECK(scale.empty(), "fit_scale: out_scale untouched on min_samples rejection");
}

static void test_read_stat(ts_tessera_db * db) {
    // Row written under the collector-side name convention (attn_k).
    {
        ts_tessera_db_kv_stat row = make_stat({ 1.0f, 2.0f, 3.0f, 4.0f }, 1000);
        row.model_hash = "read_test_model";
        row.name       = "blk.3.attn_k";
        row.layer_depth = 3;
        row.source     = "collector_legacy";
        std::string err;
        CHECK(ts_tessera_db_upsert_kv_stat(db, row, &err) == 0,
              ("read_stat: fixture upsert (attn_k) failed: " + err).c_str());
    }
    // Row written under the graph-side name convention (kv_v), for a
    // DIFFERENT layer so the fallback test below has nothing else to hit.
    {
        ts_tessera_db_kv_stat row = make_stat({ 5.0f, 6.0f }, 1000);
        row.model_hash = "read_test_model";
        row.name       = "blk.7.kv_v";
        row.layer_depth = 7;
        row.source     = "graph_observer";
        std::string err;
        CHECK(ts_tessera_db_upsert_kv_stat(db, row, &err) == 0,
              ("read_stat: fixture upsert (kv_v) failed: " + err).c_str());
    }

    ts_tessera_db_kv_stat out;
    bool hit = false;
    std::string err;

    int rc = ts_kv_migrate_read_stat(db, "read_test_model", "trunk", 3, /*is_k=*/true,
                                     &out, &hit, &err);
    CHECK(rc == 0 && hit, "read_stat: hits the preferred attn_k name");
    CHECK(out.n_channels == 4, "read_stat: attn_k row content is correct");

    hit = false;
    rc = ts_kv_migrate_read_stat(db, "read_test_model", "trunk", 7, /*is_k=*/false,
                                 &out, &hit, &err);
    CHECK(rc == 0 && hit, "read_stat: falls back to kv_v when attn_v is absent");
    CHECK(out.n_channels == 2, "read_stat: kv_v fallback row content is correct");

    hit = true;  // start true so a bug that leaves it untouched is caught
    rc = ts_kv_migrate_read_stat(db, "read_test_model", "trunk", 99, /*is_k=*/true,
                                 &out, &hit, &err);
    CHECK(rc == 0, "read_stat: miss is not an error");
    CHECK(!hit, "read_stat: miss clears hit to false");
}

// ---------------------------------------------------------------------------
// Forward-math identity check, exercising GQA directly.
//
// n_head=4 (query), n_head_kv=2, head_dim=4. Verifies:
//   Q'[h] . K_int[h/2]  ==  Q[h] . (K_int[h/2] * D)
// for every query head h, where Q' comes from applying the row fold to
// W_q and Q comes from the unmodified W_q -- proving GQA head-sharing is
// correct because D is reused identically across every query head in a
// kv-head's group.
// ---------------------------------------------------------------------------

static void test_forward_identity_row_scale_gqa() {
    const int64_t head_dim   = 4;
    const int64_t n_head     = 4;   // query heads
    const int64_t n_head_kv  = 2;   // kv heads (n_rep = 2)
    const int64_t in_dim     = 3;
    const int64_t out_dim    = n_head * head_dim;  // 16

    // D: one value per channel (head_dim length), NOT pair-tied here (pure
    // fold-mechanics test; pair-tying is covered separately above).
    std::vector<float> D = { 1.3f, 0.7f, 2.1f, 0.4f };

    // Synthetic W_q (out_dim x in_dim), deterministic values.
    std::vector<float> Wq(out_dim * in_dim);
    for (int64_t i = 0; i < out_dim * in_dim; i++) {
        Wq[i] = 0.1f * (float) ((i * 37) % 23) - 1.0f;
    }
    std::vector<float> Wq_folded = Wq;

    std::vector<float> D_tiled;
    ts_kv_migrate_tile_scale(D, n_head, &D_tiled);
    CHECK((int64_t) D_tiled.size() == out_dim, "tile_scale: output length is n_head * head_dim");
    ts_kv_migrate_apply_row_scale(Wq_folded.data(), out_dim, in_dim, D_tiled);

    // Synthetic input x and per-kv-head K_int.
    std::vector<float> x(in_dim);
    for (int64_t i = 0; i < in_dim; i++) x[i] = 0.2f * (float) (i + 1);

    std::vector<std::vector<float>> K_int(n_head_kv, std::vector<float>(head_dim));
    for (int64_t kh = 0; kh < n_head_kv; kh++) {
        for (int64_t c = 0; c < head_dim; c++) {
            K_int[kh][c] = 0.5f + 0.3f * (float) (kh + 1) - 0.1f * (float) c;
        }
    }

    auto compute_head = [&](const std::vector<float> & W, int64_t h) {
        std::vector<float> q(head_dim, 0.0f);
        for (int64_t c = 0; c < head_dim; c++) {
            const float * row = W.data() + (h * head_dim + c) * in_dim;
            float acc = 0.0f;
            for (int64_t k = 0; k < in_dim; k++) acc += row[k] * x[k];
            q[c] = acc;
        }
        return q;
    };

    const int64_t n_rep = n_head / n_head_kv;
    bool all_match = true;
    for (int64_t h = 0; h < n_head; h++) {
        const int64_t kv_head = h / n_rep;
        std::vector<float> q_plain  = compute_head(Wq, h);
        std::vector<float> q_folded = compute_head(Wq_folded, h);

        // dot(q_folded, K_int[kv_head])  vs  dot(q_plain * D, K_int[kv_head])
        float lhs = 0.0f, rhs = 0.0f;
        for (int64_t c = 0; c < head_dim; c++) {
            lhs += q_folded[c] * K_int[kv_head][c];
            rhs += (q_plain[c] * D[c]) * K_int[kv_head][c];
        }
        if (std::fabs(lhs - rhs) > 1e-4f) all_match = false;
    }
    CHECK(all_match,
          "row_scale/GQA: Q'.K_int == Q.(K_int*D) holds for every query head across all kv-head groups");
}

static void test_forward_identity_col_scale_gqa() {
    const int64_t head_dim  = 4;
    const int64_t n_head    = 4;  // A@V_hat is already GQA-expanded to n_head by this point
    const int64_t in_dim    = n_head * head_dim;  // W_o's input axis, 16
    const int64_t out_dim   = 3;

    std::vector<float> E = { 0.6f, 1.4f, 2.2f, 0.9f };

    std::vector<float> Wo(out_dim * in_dim);
    for (int64_t i = 0; i < out_dim * in_dim; i++) {
        Wo[i] = 0.1f * (float) ((i * 53) % 19) - 0.9f;
    }
    std::vector<float> Wo_folded = Wo;

    std::vector<float> E_tiled;
    ts_kv_migrate_tile_scale(E, n_head, &E_tiled);
    CHECK((int64_t) E_tiled.size() == in_dim, "tile_scale: output length is n_head * head_dim (col)");
    ts_kv_migrate_apply_col_scale(Wo_folded.data(), out_dim, in_dim, E_tiled);

    // Synthetic A@V_int (already GQA-expanded, length in_dim).
    std::vector<float> AVint(in_dim);
    for (int64_t i = 0; i < in_dim; i++) AVint[i] = 0.15f * (float) (i + 1) - 0.5f;

    // out = Wo_folded @ AVint   should equal   Wo @ (AVint elementwise-scaled by E_tiled)
    std::vector<float> AVint_scaled(in_dim);
    for (int64_t c = 0; c < in_dim; c++) AVint_scaled[c] = AVint[c] * E_tiled[c];

    bool all_match = true;
    for (int64_t r = 0; r < out_dim; r++) {
        float lhs = 0.0f, rhs = 0.0f;
        for (int64_t c = 0; c < in_dim; c++) {
            lhs += Wo_folded[r * in_dim + c] * AVint[c];
            rhs += Wo[r * in_dim + c]        * AVint_scaled[c];
        }
        if (std::fabs(lhs - rhs) > 1e-4f) all_match = false;
    }
    CHECK(all_match, "col_scale/GQA: Wo'.AVint == Wo.(AVint*E) holds for every output row");
}

static void test_apply_to_tensor_integration(ts_tessera_db * db) {
    const int64_t head_dim = 4;
    const int64_t n_head   = 2;
    const int64_t out_dim  = n_head * head_dim;
    const int64_t in_dim   = 3;

    // Fixture kv_stats row for layer 5.
    {
        ts_tessera_db_kv_stat row = make_stat({ 1.0f, 2.0f, 3.0f, 4.0f }, 1000);
        row.model_hash  = "apply_test_model";
        row.name        = "blk.5.attn_k";
        row.layer_depth = 5;
        std::string err;
        CHECK(ts_tessera_db_upsert_kv_stat(db, row, &err) == 0,
              ("apply_to_tensor: fixture upsert failed: " + err).c_str());
    }

    // 1. Wrong family (attn_v, ffn_gate): no-op, weight buffer untouched.
    {
        std::vector<float> w(out_dim * in_dim, 1.0f);
        std::vector<float> w_copy = w;
        std::string err;
        int rc = ts_kv_migrate_apply_to_tensor(
            db, "apply_test_model", "trunk", "blk.5.attn_v.weight",
            w.data(), out_dim, in_dim, ts_kv_migrate_params{}, &err);
        CHECK(rc != 0, "apply_to_tensor: attn_v is not attn_q/attn_output, no-op");
        CHECK(w == w_copy, "apply_to_tensor: weight buffer untouched on wrong family (attn_v)");

        rc = ts_kv_migrate_apply_to_tensor(
            db, "apply_test_model", "trunk", "blk.5.ffn_gate.weight",
            w.data(), out_dim, in_dim, ts_kv_migrate_params{}, &err);
        CHECK(rc != 0, "apply_to_tensor: ffn_gate is not attn_q/attn_output, no-op");
        CHECK(w == w_copy, "apply_to_tensor: weight buffer untouched on wrong family (ffn_gate)");
    }

    // 2. Missing DB row (a layer with no kv_stats fixture): no-op, not a crash.
    {
        std::vector<float> w(out_dim * in_dim, 1.0f);
        std::vector<float> w_copy = w;
        std::string err;
        int rc = ts_kv_migrate_apply_to_tensor(
            db, "apply_test_model", "trunk", "blk.999.attn_q.weight",
            w.data(), out_dim, in_dim, ts_kv_migrate_params{}, &err);
        CHECK(rc != 0, "apply_to_tensor: missing kv_stats row is a clean no-op");
        CHECK(w == w_copy, "apply_to_tensor: weight buffer untouched on missing row");
    }

    // 3. Shape mismatch: out_dim not a multiple of head_dim (simulating an
    // MLA-style tensor) -- no-op, not a crash.
    {
        const int64_t bad_out_dim = out_dim + 1;  // not a multiple of head_dim=4
        std::vector<float> w(bad_out_dim * in_dim, 1.0f);
        std::vector<float> w_copy = w;
        std::string err;
        int rc = ts_kv_migrate_apply_to_tensor(
            db, "apply_test_model", "trunk", "blk.5.attn_q.weight",
            w.data(), bad_out_dim, in_dim, ts_kv_migrate_params{}, &err);
        CHECK(rc != 0, "apply_to_tensor: out_dim not a multiple of head_dim is a clean no-op");
        CHECK(w == w_copy, "apply_to_tensor: weight buffer untouched on shape mismatch");
    }

    // 4. The success path, for completeness: attn_q with a valid fixture
    // actually changes the buffer (paired with the dedicated forward-math
    // identity tests above for correctness, this just proves the entry
    // point actually applies something when everything lines up).
    {
        std::vector<float> w(out_dim * in_dim, 1.0f);
        std::vector<float> w_copy = w;
        std::string err;
        int rc = ts_kv_migrate_apply_to_tensor(
            db, "apply_test_model", "trunk", "blk.5.attn_q.weight",
            w.data(), out_dim, in_dim, ts_kv_migrate_params{}, &err);
        CHECK(rc == 0, ("apply_to_tensor: valid attn_q fold should succeed: " + err).c_str());
        CHECK(w != w_copy, "apply_to_tensor: weight buffer IS modified on a valid attn_q fold");
    }

    // 5. db == nullptr / disabled: no-op, no crash.
    {
        std::vector<float> w(out_dim * in_dim, 1.0f);
        std::vector<float> w_copy = w;
        std::string err;
        int rc = ts_kv_migrate_apply_to_tensor(
            nullptr, "apply_test_model", "trunk", "blk.5.attn_q.weight",
            w.data(), out_dim, in_dim, ts_kv_migrate_params{}, &err);
        CHECK(rc != 0, "apply_to_tensor: db == nullptr is a clean no-op");
        CHECK(w == w_copy, "apply_to_tensor: weight buffer untouched when db == nullptr");

        ts_kv_migrate_params disabled;
        disabled.enabled = false;
        rc = ts_kv_migrate_apply_to_tensor(
            db, "apply_test_model", "trunk", "blk.5.attn_q.weight",
            w.data(), out_dim, in_dim, disabled, &err);
        CHECK(rc != 0, "apply_to_tensor: params.enabled == false is a clean no-op");
        CHECK(w == w_copy, "apply_to_tensor: weight buffer untouched when disabled");
    }
}

int main(int argc, char ** argv) {
    test_fit_scale_basic();
    test_fit_scale_pair_tying();
    test_fit_scale_pair_tying_odd_channels();
    test_fit_scale_clamp();
    test_fit_scale_min_samples();
    test_forward_identity_row_scale_gqa();
    test_forward_identity_col_scale_gqa();

    const char * path = argc > 1 ? argv[1] : "/tmp/tessera-kv-migrate-test.db";
    std::remove(path);
    std::string err;
    ts_tessera_db * db = ts_tessera_db_open(path, &err);
    CHECK(db != nullptr, ("open failed: " + err).c_str());
    if (db != nullptr) {
        test_read_stat(db);
        test_apply_to_tensor_integration(db);
        delete db;
    }
    std::remove(path);

    if (failures == 0) {
        printf("test_kv_migrate: all tests OK\n");
        return 0;
    }
    fprintf(stderr, "test_kv_migrate: %d failure(s)\n", failures);
    return 1;
}
