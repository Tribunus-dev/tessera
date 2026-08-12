#include "tessera-regime.h"

#include <cstdio>
#include <cstring>
#include <vector>

static int test_family_inference() {
    struct { const char * name; const char * expected; } cases[] = {
        // Standard dense transformer families
        { "blk.5.attn_q.weight",       "attn_q"      },
        { "blk.0.ffn_down.weight",     "ffn_down"    },
        { "blk.12.attn_k.weight",      "attn_k"      },
        { "blk.3.attn_v.weight",       "attn_v"      },
        { "blk.7.attn_output.weight",   "attn_out"    },
        { "blk.1.ffn_gate.weight",     "ffn_gate"    },
        { "blk.2.ffn_up.weight",       "ffn_up"      },
        // Granite Hybrid SSM layers (heavy projections — qualifies for DartQuant / CHAMP-Q)
        { "blk.5.ssm_in.weight",       "ssm_in"      },
        { "blk.5.ssm_out.weight",      "ssm_out"     },
        // Granite Hybrid SSM layers (conv / norm — AWQ is fine)
        { "blk.5.ssm_conv1d.weight",   "ssm_conv"    },
        { "blk.5.ssm_conv1d_q.weight",  "ssm_conv"    },
        { "blk.5.ssm_conv1d_k.weight",  "ssm_conv"    },
        { "blk.5.ssm_norm.weight",     "ssm_norm"    },
        // Granite Hybrid SSM layers (small {1,N} state — falls through to unknown)
        { "blk.5.ssm_dt.weight",        "unknown"     },
        { "blk.5.ssm_a.weight",         "unknown"     },
        { "blk.5.ssm_d.weight",         "unknown"     },
        { "blk.5.ssm_x.weight",         "unknown"     },
        // Granite MoE router (sparse top-K gate, avoids "unknown" bucket)
        { "blk.5.ffn_gate_inp.weight",  "ffn_gate_inp" },
        // Granite MoE shared expert FFN (runs every token, treated as dense FFN)
        { "blk.5.ffn_gate_shexp.weight","ffn_gate"    },
        { "blk.5.ffn_up_shexp.weight",  "ffn_up"      },
        { "blk.5.ffn_down_shexp.weight","ffn_down"    },
        // Granite MoE routed expert FFNs (G3 fix: sparsity-aware regime —
        // distinguished from dense FFN so the Q4-middle/DartQuant-edge
        // cascade applies; tessera-moe-calibration-design.md §3.3)
        { "blk.5.ffn_gate_exps.weight", "routed_expert" },
        { "blk.5.ffn_up_exps.weight",    "routed_expert" },
        { "blk.5.ffn_down_exps.weight",  "routed_expert" },
        // Non-layer tensors
        { "token_embd.weight",          "unknown"     },
    };
    for (const auto & c : cases) {
        std::string got = ts_regime_infer_family(c.name);
        if (got != c.expected) {
            printf("FAIL family: \"%s\" -> \"%s\", expected \"%s\"\n",
                   c.name, got.c_str(), c.expected);
            return 1;
        }
    }
    printf("PASS family inference: %d cases\n", (int)(sizeof(cases) / sizeof(cases[0])));
    return 0;
}

static int test_route_high_kurtosis_down() {
    ts_regime_descriptor desc = {};
    desc.tensor_name = "blk.0.ffn_down.weight";
    desc.family      = "ffn_down";
    desc.kurtosis    = 15.0f;
    desc.eff_rank    = 0.5f;

    ts_regime_routing r = ts_regime_classify(&desc);
    if (r.expert != TS_EXPERT_DARTQUANT) {
        printf("FAIL route: kurtosis=15 + ffn_down -> expert %d, expected DARTQUANT\n", r.expert);
        return 1;
    }
    printf("PASS route: high kurtosis + ffn_down -> DARTQUANT (%s)\n", r.reason.c_str());
    return 0;
}

static int test_route_ssm_projection() {
    // SSM projections (ssm_in, ssm_out) are heavy matmuls analogous to attention
    // projections. High kurtosis should fire DartQuant, same as attn_q / ffn_down.
    ts_regime_descriptor desc = {};
    desc.tensor_name = "blk.5.ssm_out.weight";
    desc.family      = "ssm_out";
    desc.kurtosis    = 12.0f;
    desc.eff_rank    = 0.6f;

    ts_regime_routing r = ts_regime_classify(&desc);
    if (r.expert != TS_EXPERT_DARTQUANT) {
        printf("FAIL route: kurtosis=12 + ssm_out -> expert %d, expected DARTQUANT\n", r.expert);
        return 1;
    }
    printf("PASS route: high kurtosis + ssm_out -> DARTQUANT (%s)\n", r.reason.c_str());

    // SSM conv / norm: well-conditioned, should fall to AWQ at normal kurtosis
    ts_regime_descriptor desc_conv = {};
    desc_conv.tensor_name = "blk.5.ssm_conv1d.weight";
    desc_conv.family      = "ssm_conv";
    desc_conv.kurtosis    = 2.5f;
    desc_conv.eff_rank    = 0.8f;

    ts_regime_routing r_conv = ts_regime_classify(&desc_conv);
    if (r_conv.expert != TS_EXPERT_AWQ) {
        printf("FAIL route: ssm_conv -> expert %d, expected AWQ\n", r_conv.expert);
        return 1;
    }
    printf("PASS route: ssm_conv (well-conditioned) -> AWQ (%s)\n", r_conv.reason.c_str());
    return 0;
}

static int test_route_moe_router() {
    // MoE router (ffn_gate_inp): sparse top-K gate. Falls through to
    // kurtosis cascade. At normal kurtosis / eff_rank it should default to AWQ.
    ts_regime_descriptor desc = {};
    desc.tensor_name = "blk.5.ffn_gate_inp.weight";
    desc.family      = "ffn_gate_inp";
    desc.kurtosis    = 2.5f;
    desc.eff_rank    = 0.6f;

    ts_regime_routing r = ts_regime_classify(&desc);
    if (r.expert != TS_EXPERT_AWQ) {
        printf("FAIL route: ffn_gate_inp -> expert %d, expected AWQ\n", r.expert);
        return 1;
    }
    printf("PASS route: ffn_gate_inp (normal) -> AWQ (%s)\n", r.reason.c_str());

    // Shared expert FFN (shexp): runs every token, treated as dense FFN.
    // Heavy tails should still fire DartQuant / CHAMP-Q.
    ts_regime_descriptor desc_shexp = {};
    desc_shexp.tensor_name = "blk.5.ffn_up_shexp.weight";
    desc_shexp.family      = "ffn_up";
    desc_shexp.kurtosis    = 8.0f;
    desc_shexp.eff_rank    = 0.5f;

    ts_regime_routing r_shexp = ts_regime_classify(&desc_shexp);
    if (r_shexp.expert != TS_EXPERT_CHAMPQ) {
        printf("FAIL route: ffn_up_shexp (kurtosis=8) -> expert %d, expected CHAMPQ\n", r_shexp.expert);
        return 1;
    }
    printf("PASS route: ffn_up_shexp (heavy tails) -> CHAMPQ (%s)\n", r_shexp.reason.c_str());
    return 0;
}

static int test_route_low_eff_rank() {
    ts_regime_descriptor desc = {};
    desc.tensor_name = "blk.0.attn_q.weight";
    desc.family      = "attn_q";
    desc.kurtosis    = 2.0f;
    desc.eff_rank    = 0.2f;

    ts_regime_routing r = ts_regime_classify(&desc);
    if (r.expert != TS_EXPERT_FLRQ && r.expert != TS_EXPERT_LRQ) {
        printf("FAIL route: eff_rank=0.2 -> expert %d, expected FLRQ or LRQ\n", r.expert);
        return 1;
    }
    printf("PASS route: low eff_rank -> %s (%s)\n",
           r.expert == TS_EXPERT_FLRQ ? "FLRQ" : "LRQ", r.reason.c_str());
    return 0;
}

static int test_route_normal() {
    ts_regime_descriptor desc = {};
    desc.tensor_name = "blk.0.attn_k.weight";
    desc.family      = "attn_k";
    desc.kurtosis    = 2.5f;
    desc.eff_rank    = 0.8f;

    ts_regime_routing r = ts_regime_classify(&desc);
    if (r.expert != TS_EXPERT_AWQ) {
        printf("FAIL route: normal stats -> expert %d, expected AWQ\n", r.expert);
        return 1;
    }
    printf("PASS route: normal stats -> AWQ (%s)\n", r.reason.c_str());
    return 0;
}

static int test_route_all_summary() {
    // 5 synthetic tensors with known routing outcomes
    ts_regime_descriptor descs[5] = {};

    // 0: kurtosis=15, ffn_down -> DARTQUANT
    descs[0].tensor_name = "blk.0.ffn_down.weight";
    descs[0].family      = "ffn_down";
    descs[0].kurtosis    = 15.0f;
    descs[0].eff_rank    = 0.5f;

    // 1: kurtosis=7, ffn_gate -> CHAMPQ
    descs[1].tensor_name = "blk.0.ffn_gate.weight";
    descs[1].family      = "ffn_gate";
    descs[1].kurtosis    = 7.0f;
    descs[1].eff_rank    = 0.5f;

    // 2: eff_rank=0.2, low kurtosis -> LRQ
    descs[2].tensor_name = "blk.0.attn_q.weight";
    descs[2].family      = "attn_q";
    descs[2].kurtosis    = 2.0f;
    descs[2].eff_rank    = 0.2f;

    // 3: well-conditioned attn_k -> AWQ
    descs[3].tensor_name = "blk.0.attn_k.weight";
    descs[3].family      = "attn_k";
    descs[3].kurtosis    = 2.0f;
    descs[3].eff_rank    = 0.8f;

    // 4: default regime -> AWQ
    descs[4].tensor_name = "blk.0.ffn_up.weight";
    descs[4].family      = "ffn_up";
    descs[4].kurtosis    = 3.5f;
    descs[4].eff_rank    = 0.5f;

    // route_all takes an explicit thresholds ptr (no default in the
    // merged header); nullptr exercises the builtin cascade.
    std::vector<ts_regime_routing> routings = ts_regime_route_all(descs, 5, nullptr);
    if ((int64_t)routings.size() != 5) {
        printf("FAIL route_all: got %zu routings, expected 5\n", routings.size());
        return 1;
    }

    ts_regime_summary s = ts_regime_summarize(&routings, descs, 5);

    if (s.count_per_expert[TS_EXPERT_DARTQUANT] != 1) {
        printf("FAIL summary: DARTQUANT count %lld, expected 1\n",
               (long long)s.count_per_expert[TS_EXPERT_DARTQUANT]);
        return 1;
    }
    if (s.count_per_expert[TS_EXPERT_CHAMPQ] != 1) {
        printf("FAIL summary: CHAMPQ count %lld, expected 1\n",
               (long long)s.count_per_expert[TS_EXPERT_CHAMPQ]);
        return 1;
    }
    if (s.count_per_expert[TS_EXPERT_LRQ] != 1) {
        printf("FAIL summary: LRQ count %lld, expected 1\n",
               (long long)s.count_per_expert[TS_EXPERT_LRQ]);
        return 1;
    }
    if (s.count_per_expert[TS_EXPERT_AWQ] != 2) {
        printf("FAIL summary: AWQ count %lld, expected 2\n",
               (long long)s.count_per_expert[TS_EXPERT_AWQ]);
        return 1;
    }

    int64_t total = 0;
    for (int i = 0; i < TS_EXPERT_COUNT; i++) {
        total += s.count_per_expert[i];
    }
    if (total != 5) {
        printf("FAIL summary: total %lld, expected 5\n", (long long)total);
        return 1;
    }

    printf("PASS route_all + summary: AWQ=%lld DARTQUANT=%lld CHAMPQ=%lld LRQ=%lld "
           "mean_kurt=%.2f mean_er=%.2f\n",
           (long long)s.count_per_expert[TS_EXPERT_AWQ],
           (long long)s.count_per_expert[TS_EXPERT_DARTQUANT],
           (long long)s.count_per_expert[TS_EXPERT_CHAMPQ],
           (long long)s.count_per_expert[TS_EXPERT_LRQ],
           s.mean_kurtosis, s.mean_eff_rank);
    return 0;
}

static int test_compute_descriptor() {
    // 4x8 weight matrix, uniform
    const int64_t out_dim = 4, in_dim = 8;
    std::vector<float> W(out_dim * in_dim, 0.5f);

    // imatrix: 8 channel magnitudes with one outlier
    float imatrix[8] = { 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 10.0f };

    ts_regime_descriptor desc = ts_regime_compute_descriptor(
        "blk.0.ffn_down.weight", W.data(), out_dim, in_dim, imatrix, 8);

    if (desc.family != "ffn_down") {
        printf("FAIL compute: family \"%s\", expected \"ffn_down\"\n", desc.family.c_str());
        return 1;
    }
    if (desc.out_dim != out_dim || desc.in_dim != in_dim) {
        printf("FAIL compute: dims %lldx%lld, expected %lldx%lld\n",
               (long long)desc.out_dim, (long long)desc.in_dim,
               (long long)out_dim, (long long)in_dim);
        return 1;
    }
    // outlier should push kurtosis above gaussian baseline
    if (desc.kurtosis < 0.0f) {
        printf("FAIL compute: kurtosis %.4f unexpectedly negative\n", desc.kurtosis);
        return 1;
    }
    if (desc.p99 < 5.0f) {
        printf("FAIL compute: p99 %.4f, expected >= 5.0 with outlier at 10\n", desc.p99);
        return 1;
    }
    printf("PASS compute_descriptor: kurt=%.2f eff_rank=%.3f p99=%.2f mean_mag=%.2f\n",
           desc.kurtosis, desc.eff_rank, desc.p99, desc.mean_magnitude);
    return 0;
}

static int test_modality_inference() {
    // M0b: explicit v./a. role prefixes (real mmproj convention from
    // clip.cpp:1831) take precedence over legacy fragment matching. mm.*
    // projector tensors still fall through to the fragment check so
    // hand-written fixtures like "mm.vision_embed.weight" keep working.
    struct { const char * name; int want; } cases[] = {
        // role-prefix pass: vision tower
        { "v.patch_embd.weight",      1 },
        { "v.blk.0.attn_q.weight",    1 },
        { "v.blk.0.ffn_down.weight",  1 },
        // role-prefix pass: audio tower
        { "a.encoder.layers.0.weight", 2 },
        { "a.position_embeddings",    2 },
        // role-prefix pass: text-side projector (mm.* falls through to
        // fragment check; these names have no vision/audio fragment)
        { "mm.0.weight",              0 },
        { "mm.1.bias",                0 },
        // legacy fragment fallback: still classifies old-style names
        { "vision_tower.layer.weight", 1 },
        { "image_encoder.weight",      1 },
        { "audio_encoder.weight",      2 },
        { "speech_proj.weight",        2 },
        // regression: no prefix, no fragment match -> text
        { "attn_q.weight",             0 },
        // guards
        { "",                          0 },
    };
    int n_cases = (int)(sizeof(cases) / sizeof(cases[0]));
    for (int i = 0; i < n_cases; i++) {
        int got = ts_regime_infer_modality(cases[i].name);
        if (got != cases[i].want) {
            printf("FAIL modality: \"%s\" -> %d, expected %d\n",
                   cases[i].name, got, cases[i].want);
            return 1;
        }
    }
    if (ts_regime_infer_modality(nullptr) != 0) {
        printf("FAIL modality: nullptr -> %d, expected 0\n",
               ts_regime_infer_modality(nullptr));
        return 1;
    }
    n_cases += 1; // nullptr guard
    printf("PASS modality inference: %d cases\n", n_cases);
    return 0;
}

int main() {
    int failures = 0;
    failures += test_family_inference();
    failures += test_route_high_kurtosis_down();
    failures += test_route_ssm_projection();
    failures += test_route_moe_router();
    failures += test_route_low_eff_rank();
    failures += test_route_normal();
    failures += test_route_all_summary();
    failures += test_compute_descriptor();
    failures += test_modality_inference();

    if (failures == 0) {
        printf("\nAll tests passed.\n");
    } else {
        printf("\n%d test(s) FAILED.\n", failures);
    }
    return failures;
}
