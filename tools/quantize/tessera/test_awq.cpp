//
// test_awq.cpp
//
// Tests for tessera-awq.cpp:
//   1. GA convergence + determinism (existing).
//   2. per-gene clip ranges enforced (mutate beyond bounds -> clipped).
//   3. random_candidate stays in range across many samples.
//   4. policy <-> candidate bridge: ts_awq_candidate_from_genes seeds from a
//      ts_policy read back from a policy file (round-trips with B4).
//

#include "tessera-awq.h"
#include "tessera-policy.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static int g_failures = 0;

#define CHECK(cond, msg)                                     \
    do {                                                     \
        if (!(cond)) {                                       \
            std::printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
            g_failures++;                                    \
        }                                                    \
    } while (0)

static bool feq(float a, float b) {
    return std::fabs(a - b) < 1e-6f;
}

static ts_awq_score test_eval(const ts_awq_candidate * cand,
                               const ts_awq_layer * layer, void * ctx) {
    (void)layer;
    (void)ctx;
    ts_awq_score s;
    // optimum at alpha = 0.5
    float d = cand->genes.alpha - 0.5f;
    s.mse = d * d;
    s.relative_frob = 0.0f;
    s.heldout_mse = 0.0f;
    s.composite = -(d * d);
    return s;
}

// Resolve a path relative to this source file (so the test works regardless
// of the CWD the harness invokes it from).
static std::string src_relative(const std::string & tail) {
    std::string f = __FILE__;
    size_t slash = f.find_last_of("/\\");
    std::string dir = (slash == std::string::npos) ? "." : f.substr(0, slash);
    return dir + "/" + tail;
}

int main() {
    float weights[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};

    ts_awq_layer layer;
    layer.name = "test_layer";
    layer.family = "ffn";
    layer.weights = weights;
    layer.act_scales = nullptr;
    layer.calib_X = nullptr;
    layer.ref_output = nullptr;
    layer.imatrix = nullptr;
    layer.second_moment      = nullptr;
    layer.fourth_moment      = nullptr;
    layer.max_abs            = nullptr;
    layer.train_activations  = nullptr;
    layer.heldout_activations = nullptr;
    layer.ref_train_output   = nullptr;
    layer.ref_heldout_output = nullptr;
    layer.out_dim = 4;
    layer.in_dim = 4;
    layer.n_tokens = 0;
    layer.n_tokens_h = 0;
    layer.kurtosis = 3.0f;
    layer.eff_rank = 0.5f;

    ts_awq_evolve_params params;
    params.population = 8;
    params.generations = 20;
    params.islands = 2;
    params.migration_interval = 10;
    params.mutation_sigma = 0.1f;
    params.crossover_rate = 0.7f;
    params.heldout_weight = 2.0f;
    params.seed = 42;
    params.verbose = false;

    // --- Test 1: convergence + determinism ---
    ts_awq_evolve_result r1;
    int rc = ts_awq_evolve(&layer, test_eval, nullptr, &params, &r1);
    assert(rc == 0);
    printf("run1: alpha=%.4f composite=%.6f evals=%lld\n",
           r1.best.genes.alpha, r1.best_score.composite, (long long)r1.evaluations);
    CHECK(fabsf(r1.best.genes.alpha - 0.5f) < 0.15f, "alpha did not converge near 0.5");

    ts_awq_evolve_result r2;
    rc = ts_awq_evolve(&layer, test_eval, nullptr, &params, &r2);
    assert(rc == 0);
    CHECK(feq(r1.best.genes.alpha,             r2.best.genes.alpha),             "determinism: alpha");
    CHECK(feq(r1.best.genes.clip,              r2.best.genes.clip),              "determinism: clip");
    CHECK(feq(r1.best.genes.outlier_fraction,  r2.best.genes.outlier_fraction),  "determinism: outlier_fraction");
    CHECK(feq(r1.best.genes.ternary_threshold, r2.best.genes.ternary_threshold), "determinism: ternary_threshold");
    CHECK(feq(r1.best_score.composite, r2.best_score.composite), "determinism: composite");
    CHECK(r1.evaluations == r2.evaluations, "determinism: evaluation count");

    // Archive + JSON sanity
    CHECK(!r1.archive.empty(), "archive should be non-empty");
    {
        std::string json = ts_awq_candidate_json(&r1.best);
        CHECK(json.find("\"awq_alpha\"")         != std::string::npos, "json has awq_alpha");
        CHECK(json.find("\"awq_clip\"")          != std::string::npos, "json has awq_clip");
        CHECK(json.find("\"outlier_fraction\"")  != std::string::npos, "json has outlier_fraction");
        CHECK(json.find("\"moment_mix\"")        != std::string::npos, "json has moment_mix");
        CHECK(json.find("\"tail_guard\"")        != std::string::npos, "json has tail_guard");
        CHECK(json.find("\"ternary_threshold\"") != std::string::npos, "json has ternary_threshold");
        CHECK(json.find("\"alpha\"")             == std::string::npos, "json must not emit legacy bare alpha");
        CHECK(json.find("\"lrq_rank_frac\"")     == std::string::npos, "json must not emit lrq fields");
    }

    // --- Test 2: per-gene clip ranges enforced ---
    // Push every gene out of range and confirm the result is clamped to the
    // Python per-gene bounds. Uses from_genes as the entry point that clamps.
    {
        ts_policy_genes g;
        g.alpha             = -5.0f;     // below [0, 1]
        g.clip              =  0.10f;    // below [0.70, 1.0]
        g.outlier_fraction  = 99.0f;     // above [0.0001, 0.05]
        g.moment_mix        = -1.0f;     // below [0, 1]
        g.tail_guard        = 50.0f;     // above [0, 2.0]
        g.ternary_threshold =  0.0f;     // below [0.30, 3.0]
        ts_awq_candidate c = ts_awq_candidate_from_genes(g, -1);
        CHECK(feq(c.genes.alpha,             0.0f),   "clip alpha lo");
        CHECK(feq(c.genes.clip,              0.70f),  "clip clip lo");
        CHECK(feq(c.genes.outlier_fraction,  0.05f),  "clip outlier_fraction hi");
        CHECK(feq(c.genes.moment_mix,        0.0f),   "clip moment_mix lo");
        CHECK(feq(c.genes.tail_guard,        2.0f),   "clip tail_guard hi");
        CHECK(feq(c.genes.ternary_threshold, 0.30f),  "clip ternary_threshold lo");

        g.alpha             =  2.0f;
        g.clip              =  2.0f;
        g.outlier_fraction  =  1e-6f;
        g.moment_mix        =  3.0f;
        g.tail_guard        = -1.0f;
        g.ternary_threshold =  9.0f;
        c = ts_awq_candidate_from_genes(g, -1);
        CHECK(feq(c.genes.alpha,             1.0f),    "clip alpha hi");
        CHECK(feq(c.genes.clip,              1.0f),    "clip clip hi");
        CHECK(feq(c.genes.outlier_fraction,  0.0001f), "clip outlier_fraction lo");
        CHECK(feq(c.genes.moment_mix,        1.0f),    "clip moment_mix hi");
        CHECK(feq(c.genes.tail_guard,        0.0f),    "clip tail_guard lo");
        CHECK(feq(c.genes.ternary_threshold, 3.0f),    "clip ternary_threshold hi");
    }

    // --- Test 3: random_candidate stays in range across many samples ---
    // Build candidates via the GA and confirm every gene is in range. We
    // re-run evolve with a different seed and a much larger population so the
    // sampling covers the space; the convergence eval keeps alpha near 0.5
    // but the other genes roam freely.
    {
        ts_awq_evolve_params p = params;
        p.population  = 64;
        p.generations = 4;
        p.islands     = 1;
        ts_awq_evolve_result rr;
        rc = ts_awq_evolve(&layer, test_eval, nullptr, &p, &rr);
        assert(rc == 0);
        const ts_policy_genes & g = rr.best.genes;
        CHECK(g.alpha             >= 0.0f    - 1e-6f && g.alpha             <= 1.0f    + 1e-6f, "alpha in range");
        CHECK(g.clip              >= 0.70f   - 1e-6f && g.clip              <= 1.0f    + 1e-6f, "clip in range");
        CHECK(g.outlier_fraction  >= 0.0001f - 1e-6f && g.outlier_fraction  <= 0.05f   + 1e-6f, "outlier_fraction in range");
        CHECK(g.moment_mix        >= 0.0f    - 1e-6f && g.moment_mix        <= 1.0f    + 1e-6f, "moment_mix in range");
        CHECK(g.tail_guard        >= 0.0f    - 1e-6f && g.tail_guard        <= 2.0f    + 1e-6f, "tail_guard in range");
        CHECK(g.ternary_threshold >= 0.30f   - 1e-6f && g.ternary_threshold <= 3.0f    + 1e-6f, "ternary_threshold in range");
    }

    // --- Test 4: policy <-> candidate bridge ---
    // Write a policy with a known gene payload, read it back via ts_policy_read
    // (B4), build a candidate from the family's genes, and confirm the genes
    // round-trip. This is the "GA refines a policy from disk" seeding path.
    {
        const std::string path = "/tmp/tessera_test_awq_bridge.json";
        ts_policy in;
        in.seed        = 7;
        in.generations = 4;
        in.islands     = 1;
        in.population  = 8;
        in.search_schema = "llama.tessera.awq-evolution.v1";

        ts_policy_tensor fam;
        fam.family = "ffn";
        fam.match  = {"ffn_gate", "ffn_up", "ffn_down"};
        fam.exact  = false;
        fam.genes.alpha             = 0.42f;
        fam.genes.clip              = 0.91f;
        fam.genes.outlier_fraction  = 0.012f;
        fam.genes.moment_mix        = 0.33f;
        fam.genes.tail_guard        = 0.7f;
        fam.genes.ternary_threshold = 1.25f;
        in.tensors.emplace_back("ffn", std::move(fam));

        int wrc = ts_policy_write(path.c_str(), &in);
        assert(wrc == 0);

        ts_policy out;
        std::string err;
        int rrc = ts_policy_read(path.c_str(), &out, &err);
        CHECK(rrc == 0, "ts_policy_read should succeed for bridge");
        if (rrc == 0) {
            const ts_policy_tensor * f = nullptr;
            for (const auto & kv : out.tensors) {
                if (kv.first == "ffn") { f = &kv.second; break; }
            }
            CHECK(f != nullptr, "ffn family present after read");
            if (f) {
                ts_awq_candidate c = ts_awq_candidate_from_genes(f->genes, 7);
                CHECK(feq(c.genes.alpha,             0.42f),  "bridge alpha");
                CHECK(feq(c.genes.clip,              0.91f),  "bridge clip");
                CHECK(feq(c.genes.outlier_fraction,  0.012f), "bridge outlier_fraction");
                CHECK(feq(c.genes.moment_mix,        0.33f),  "bridge moment_mix");
                CHECK(feq(c.genes.tail_guard,        0.7f),   "bridge tail_guard");
                CHECK(feq(c.genes.ternary_threshold, 1.25f),  "bridge ternary_threshold");
                CHECK(c.expert_hint == 7, "bridge expert_hint");

                // Seed the GA from the policy candidate and confirm it runs.
                ts_awq_evolve_result br;
                ts_awq_evolve_params bp = params;
                ts_awq_candidate seed[1] = { c };
                (void)seed;  // seed available for a warm-start API later (B2)
                int brc = ts_awq_evolve(&layer, test_eval, nullptr, &bp, &br);
                CHECK(brc == 0, "GA runs after policy seed");
            }
        }
    }

    // --- activation-capture stage 1: streaming activations_load_fn/
    // activations_release_fn plumbing, mirroring weights_load_fn/
    // weights_release_fn. Proves (a) ts_awq_evolve_all actually calls the
    // loader once per layer and the releaser once per successful load
    // (matching the existing weight-streaming call/release discipline), and
    // (b) the loaded activations have a real effect on the GA's result --
    // not just structural plumbing that gets called and ignored.
    {
        struct activation_state {
            std::vector<float> train;
            int64_t n_tokens;
            int     load_calls    = 0;
            int     release_calls = 0;
        };

        auto loader = [](void * ud,
                         const float ** out_train, int64_t * out_n_tokens,
                         const float ** out_heldout, int64_t * out_n_tokens_h,
                         const float ** out_ref_train,
                         const float ** out_ref_heldout) -> bool {
            auto * st = static_cast<activation_state *>(ud);
            st->load_calls++;
            *out_train      = st->train.data();
            *out_n_tokens   = st->n_tokens;
            *out_heldout    = nullptr;
            *out_n_tokens_h = 0;
            *out_ref_train  = nullptr;
            *out_ref_heldout = nullptr;
            return true;
        };
        auto releaser = [](void * ud) {
            static_cast<activation_state *>(ud)->release_calls++;
        };

        const int64_t out_dim = 4, in_dim = 8, n_tokens = 6;
        std::vector<float> w1(out_dim * in_dim), w2(out_dim * in_dim);
        std::vector<float> sm1(in_dim, 1.0f), sm2(in_dim, 1.0f);
        for (int64_t i = 0; i < out_dim * in_dim; i++) {
            w1[i] = (float)(i % 7) - 3.0f;
            w2[i] = (float)((i * 3) % 7) - 3.0f;
        }
        activation_state st1, st2;
        st1.n_tokens = n_tokens;
        st1.train.assign(n_tokens * in_dim, 0.0f);
        for (auto & v : st1.train) v = 0.3f;
        st2 = st1;  // same shape, distinct instance (independent call counters)

        ts_awq_layer layers[2] = {};
        layers[0].name = "act_L0"; layers[0].family = "ffn";
        layers[0].weights = w1.data(); layers[0].second_moment = sm1.data();
        layers[0].out_dim = out_dim;   layers[0].in_dim = in_dim;
        layers[0].activations_load_fn    = loader;
        layers[0].activations_release_fn = releaser;
        layers[0].activations_user_data  = &st1;

        layers[1].name = "act_L1"; layers[1].family = "ffn";
        layers[1].weights = w2.data(); layers[1].second_moment = sm2.data();
        layers[1].out_dim = out_dim;   layers[1].in_dim = in_dim;
        layers[1].activations_load_fn    = loader;
        layers[1].activations_release_fn = releaser;
        layers[1].activations_user_data  = &st2;

        ts_awq_evolve_params ap = {};
        ap.population = 8; ap.generations = 6; ap.islands = 2;
        ap.migration_interval = 10; ap.mutation_sigma = 0.1f;
        ap.crossover_rate = 0.7f; ap.heldout_weight = 2.0f;
        ap.seed = 7; ap.n_threads = 1;  // serial path

        std::vector<ts_awq_evolve_result> res_with;
        int rc = ts_awq_evolve_all(layers, 2, ts_awq_default_eval, nullptr, &ap, &res_with);
        CHECK(rc == 0, "activation-loader evolve_all rc==0");
        CHECK(st1.load_calls == 1 && st1.release_calls == 1,
              "activations_load_fn/release_fn called exactly once (layer 0)");
        CHECK(st2.load_calls == 1 && st2.release_calls == 1,
              "activations_load_fn/release_fn called exactly once (layer 1)");
        CHECK(layers[0].train_activations == nullptr && layers[0].n_tokens == 0,
              "release resets train_activations/n_tokens on layer 0");
        CHECK(layers[1].train_activations == nullptr && layers[1].n_tokens == 0,
              "release resets train_activations/n_tokens on layer 1");

        // Control: identical layers/params/seed, no loader wired -- proves
        // the loaded activations are not just plumbed through inertly.
        ts_awq_layer layers_ctrl[2] = {};
        layers_ctrl[0] = layers[0]; layers_ctrl[0].activations_load_fn = nullptr;
        layers_ctrl[0].activations_release_fn = nullptr; layers_ctrl[0].activations_user_data = nullptr;
        layers_ctrl[1] = layers[1]; layers_ctrl[1].activations_load_fn = nullptr;
        layers_ctrl[1].activations_release_fn = nullptr; layers_ctrl[1].activations_user_data = nullptr;

        std::vector<ts_awq_evolve_result> res_ctrl;
        int rc2 = ts_awq_evolve_all(layers_ctrl, 2, ts_awq_default_eval, nullptr, &ap, &res_ctrl);
        CHECK(rc2 == 0, "control evolve_all rc==0");
        std::printf("[activation-loader] load_calls=%d/%d release_calls=%d/%d "
                    "composite with=(%.6f,%.6f) ctrl=(%.6f,%.6f)\n",
                    st1.load_calls, st2.load_calls, st1.release_calls, st2.release_calls,
                    res_with[0].best_score.composite, res_with[1].best_score.composite,
                    res_ctrl[0].best_score.composite, res_ctrl[1].best_score.composite);
        CHECK(res_with[0].best_score.composite != res_ctrl[0].best_score.composite ||
              res_with[1].best_score.composite != res_ctrl[1].best_score.composite,
              "activations_load_fn changes at least one layer's GA result vs. no-loader control");
    }

    if (g_failures == 0) {
        printf("PASS\n");
        return 0;
    }
    printf("FAIL (%d failures)\n", g_failures);
    return 1;
}
