// test-tq2-parity.cpp - isolated CPU vs Metal parity for TQ2_0
//
// Covers the two ops that matter for running Bonsai-style ternary models on
// Apple Silicon without touching the full test-backend-ops matrix:
//
//   * MUL_MAT with type_a=TQ2_0, type_b=F32  (weights * activations)
//   * GET_ROWS with type=TQ2_0               (embedding gather)
//
// The harness deliberately avoids test_tessera_paged_attn and the
// show_coverage path - it constructs only the graphs it needs and compares
// them with ggml_backend_compare_graph_backend (CPU ref vs Metal).
//
// Usage:
//   ./bin/test-tq2-parity              // runs both suites on Metal if present
//   ./bin/test-tq2-parity --cpu-only   // CPU self-check only

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---- helpers copied from test-backend-ops (trimmed) -------------------------

static void init_tensor_uniform(ggml_tensor * tensor, float min = -1.0f, float max = 1.0f) {
    size_t nels = ggml_nelements(tensor);
    std::vector<float> data(nels);
    std::mt19937 rng(0x1234u + (uint32_t)nels);
    std::uniform_real_distribution<float> dist(min, max);
    for (size_t i = 0; i < nels; ++i) data[i] = dist(rng);

    if (tensor->type == GGML_TYPE_F32 || tensor->type == GGML_TYPE_I32) {
        ggml_backend_tensor_set(tensor, data.data(), 0, nels * sizeof(float));
    } else if (ggml_is_quantized(tensor->type) || tensor->type == GGML_TYPE_F16 || tensor->type == GGML_TYPE_BF16) {
        assert(nels % ggml_blck_size(tensor->type) == 0);
        std::vector<float> imatrix(tensor->ne[0], 1.0f);
        const float * im = imatrix.data();
        if (!ggml_quantize_requires_imatrix(tensor->type)) {
            if (data[0] > 0.5f*(min + max)) im = nullptr;
        }
        std::vector<uint8_t> dataq(ggml_row_size(tensor->type, nels));
        // single-threaded quantize is fine for the harness sizes
        ggml_quantize_chunk(tensor->type, data.data(), dataq.data(), 0, nels / ggml_blck_size(tensor->type), ggml_blck_size(tensor->type), im);
        ggml_backend_tensor_set(tensor, dataq.data(), 0, dataq.size());
    } else if (tensor->type == GGML_TYPE_I8 || tensor->type == GGML_TYPE_I16) {
        ggml_backend_tensor_set(tensor, data.data(), 0, nels * ggml_type_size(tensor->type));
    } else {
        GGML_ABORT("init_tensor_uniform: unsupported type %d", tensor->type);
    }
}

static std::vector<float> tensor_to_float(const ggml_tensor * t) {
    std::vector<float> tv;
    tv.reserve(ggml_nelements(t));
    std::vector<uint8_t> buf(ggml_nbytes(t));
    ggml_backend_tensor_get(t, buf.data(), 0, ggml_nbytes(t));
    const auto * tt = ggml_get_type_traits(t->type);
    size_t bs = ggml_blck_size(t->type);
    std::vector<float> vq(bs);
    bool quantized = ggml_is_quantized(t->type);
    for (int64_t i3 = 0; i3 < t->ne[3]; ++i3) {
        for (int64_t i2 = 0; i2 < t->ne[2]; ++i2) {
            for (int64_t i1 = 0; i1 < t->ne[1]; ++i1) {
                for (int64_t i0 = 0; i0 < t->ne[0]; i0 += (int64_t)bs) {
                    size_t i = i3*t->nb[3] + i2*t->nb[2] + i1*t->nb[1] + i0/bs*t->nb[0];
                    if (t->type == GGML_TYPE_F16) {
                        tv.push_back(ggml_fp16_to_fp32(*(ggml_fp16_t*)&buf[i]));
                    } else if (t->type == GGML_TYPE_BF16) {
                        tv.push_back(ggml_bf16_to_fp32(*(ggml_bf16_t*)&buf[i]));
                    } else if (t->type == GGML_TYPE_F32) {
                        tv.push_back(*(float*)&buf[i]);
                    } else if (t->type == GGML_TYPE_I32) {
                        tv.push_back((float)*(int32_t*)&buf[i]);
                    } else if (quantized) {
                        tt->to_float(&buf[i], vq.data(), bs);
                        tv.insert(tv.end(), vq.begin(), vq.end());
                    } else {
                        GGML_ABORT("tensor_to_float: unsupported");
                    }
                }
            }
        }
    }
    return tv;
}

static double nmse(const float * a, const float * b, size_t n) {
    double mse_a_b = 0.0, mse_a_0 = 0.0;
    for (size_t i = 0; i < n; ++i) {
        double da = a[i], db = b[i];
        mse_a_b += (da - db)*(da - db);
        mse_a_0 += da*da;
    }
    if (mse_a_0 == 0.0) return mse_a_b;
    return mse_a_b / mse_a_0;
}

// ---- graph builders --------------------------------------------------------

struct GraphSpec {
    ggml_context * ctx = nullptr;
    ggml_cgraph  * gf  = nullptr;
    ggml_tensor  * out = nullptr;
    // keep ctx alive via unique_ptr in caller
};

static bool backend_supports_graph(ggml_backend_t be, ggml_context * ctx) {
    for (ggml_tensor * t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) {
        if (!ggml_backend_supports_op(be, t)) return false;
    }
    return true;
}

// MUL_MAT with TQ2_0 x F32. a=[k,m] TQ2_0, b=[k,n] F32, out=[m,n]
static GraphSpec build_mul_mat_tq2(ggml_context * ctx, int m, int n, int k, int bs0 = 1, int bs1 = 1) {
    ggml_tensor * a = ggml_new_tensor_4d(ctx, GGML_TYPE_TQ2_0, k, m, bs0, bs1);
    ggml_set_name(a, "a");
    ggml_tensor * b = ggml_new_tensor_4d(ctx, GGML_TYPE_F32,   k, n, bs0, bs1);
    ggml_set_name(b, "b");
    ggml_tensor * out = ggml_mul_mat(ctx, a, b);
    ggml_set_name(out, "out");
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, out);
    return {ctx, gf, out};
}

// GET_ROWS with TQ2_0 table [n,m] and I32 rows [r]
static GraphSpec build_get_rows_tq2(ggml_context * ctx, int n, int m, int r) {
    ggml_tensor * table = ggml_new_tensor_2d(ctx, GGML_TYPE_TQ2_0, n, m);
    ggml_set_name(table, "table");
    ggml_tensor * rows = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, r);
    ggml_set_name(rows, "rows");
    ggml_tensor * out = ggml_get_rows(ctx, table, rows);
    ggml_set_name(out, "out");
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, out);
    return {ctx, gf, out};
}

static void init_get_rows_ids(ggml_context * ctx, int m) {
    for (ggml_tensor * t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) {
        if (t->type == GGML_TYPE_I32) {
            // deterministic ids: 0,1,2,... mod m
            std::vector<int32_t> ids(t->ne[0]);
            int n = (int)t->ne[0];
            for (int i = 0; i < n; ++i) ids[i] = (i * 7 + 3) % m;
            ggml_backend_tensor_set(t, ids.data(), 0, n * sizeof(int32_t));
        } else {
            init_tensor_uniform(t);
        }
    }
}

// ---- comparison driver -----------------------------------------------------

struct CompareCBData {
    bool ok = true;
    double max_nmse = 0.0;
    double max_abs  = 0.0;
    std::string fail_msg;
};

static bool compare_callback(int /*index*/, ggml_tensor * t1, ggml_tensor * t2, void * user_data) {
    auto * d = (CompareCBData*)user_data;
    if (t1->op == GGML_OP_NONE) return true;
    // skip view ops (should not appear as nodes, but be safe)
    if (t1->op == GGML_OP_VIEW || t1->op == GGML_OP_RESHAPE || t1->op == GGML_OP_PERMUTE || t1->op == GGML_OP_TRANSPOSE) return true;

    std::vector<float> f1 = tensor_to_float(t1);
    std::vector<float> f2 = tensor_to_float(t2);
    assert(f1.size() == f2.size());
    double err = nmse(f1.data(), f2.data(), f1.size());
    d->max_nmse = std::max(d->max_nmse, err);
    double max_abs = 0.0;
    for (size_t i = 0; i < f1.size(); ++i) max_abs = std::max<double>(max_abs, std::fabs(f1[i]-f2[i]));
    d->max_abs = std::max(d->max_abs, max_abs);

    // NaN / Inf checks
    for (size_t i = 0; i < f1.size(); ++i) {
        if (std::isnan(f1[i]) || std::isnan(f2[i])) { d->ok = false; d->fail_msg = "NaN"; return false; }
        bool inf1 = std::isinf(f1[i]), inf2 = std::isinf(f2[i]);
        if (inf1 || inf2) {
            if (!(inf1 && inf2 && std::signbit(f1[i])==std::signbit(f2[i]))) { d->ok = false; d->fail_msg = "Inf mismatch"; return false; }
        }
    }
    // Thresholds: quantized matmuls are lossy; use the same 5e-4 as test_mul_mat.
    const double thresh = 5e-4;
    if (err > thresh) {
        d->ok = false;
        char buf[128];
        snprintf(buf, sizeof(buf), "NMSE %.6f > %.6f max_abs %.6f", err, thresh, max_abs);
        d->fail_msg = buf;
    }
    return true;
}

static bool run_one(ggml_backend_t be_cpu, ggml_backend_t be_accel,
                    ggml_context * ctx, ggml_cgraph * gf,
                    const std::string & tag) {
    // check support
    for (ggml_backend_t be : {be_cpu, be_accel}) {
        for (ggml_tensor * t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) {
            if (!ggml_backend_supports_op(be, t)) {
                printf("  %-50s : SKIP (not supported on %s: %s)\n", tag.c_str(), ggml_backend_name(be), ggml_op_desc(t));
                return true; // not a failure
            }
        }
    }

    // allocate + init on the cpu backend's buffer (compare will copy to accel)
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(ctx, be_cpu);
    if (!buf) { printf("  %-50s : FAIL (alloc)\n", tag.c_str()); return false; }

    // Initialize: GET_ROWS needs special ids, otherwise uniform
    bool has_i32 = false;
    for (ggml_tensor * t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) if (t->type==GGML_TYPE_I32) has_i32 = true;
    if (has_i32 && tag.rfind("GET_ROWS",0)==0) init_get_rows_ids(ctx, (int)ggml_get_first_tensor(ctx)->ne[1]);
    else {
        for (ggml_tensor * t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) init_tensor_uniform(t);
        // fixup i32 ids again if any (mul_mat has none)
        for (ggml_tensor * t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) {
            if (t->type==GGML_TYPE_I32) {
                int n = (int)ggml_nelements(t);
                std::vector<int32_t> ids(n);
                // for safety, fill with 0..1
                for (int i=0;i<n;++i) ids[i]=0;
                ggml_backend_tensor_set(t, ids.data(), 0, n*sizeof(int32_t));
            }
        }
    }

    CompareCBData cb{};
    bool cmp_ok = ggml_backend_compare_graph_backend(be_cpu, be_accel, gf, compare_callback, &cb, nullptr, 0);
    ggml_backend_buffer_free(buf);
    if (!cmp_ok) {
        printf("  %-50s : FAIL (compare_graph failed)\n", tag.c_str());
        return false;
    }
    if (!cb.ok) {
        printf("  %-50s : FAIL (%s) nmse=%.3e max_abs=%.3e\n", tag.c_str(), cb.fail_msg.c_str(), cb.max_nmse, cb.max_abs);
        return false;
    }
    printf("  %-50s : OK   nmse=%.3e max_abs=%.3e\n", tag.c_str(), cb.max_nmse, cb.max_abs);
    return true;
}

// ---- main ------------------------------------------------------------------

int main(int argc, char ** argv) {
    bool cpu_only = false;
    for (int i=1;i<argc;++i) if (std::string(argv[i])=="--cpu-only") cpu_only = true;

    ggml_backend_load_all();
    ggml_backend_t be_cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (!be_cpu) { fprintf(stderr, "CPU backend init failed\n"); return 1; }
    // Use reference implementation for the CPU side (matches test-backend-ops)
    {
        auto * reg = ggml_backend_dev_backend_reg(ggml_backend_get_device(be_cpu));
        using set_use_ref_t = void(*)(ggml_backend_t,bool);
        auto * fn = (set_use_ref_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_cpu_set_use_ref");
        if (fn) fn(be_cpu, true);
    }

    ggml_backend_t be_metal = nullptr;
    if (!cpu_only) {
        // Prefer Metal by name; fallback to any GPU/ACCEL device
        for (size_t i=0;i<ggml_backend_dev_count();++i) {
            auto * dev = ggml_backend_dev_get(i);
            std::string name = ggml_backend_dev_name(dev);
            if (name=="Metal" || name=="MTL0" || ggml_backend_dev_type(dev)==GGML_BACKEND_DEVICE_TYPE_GPU) {
                be_metal = ggml_backend_dev_init(dev, nullptr);
                if (be_metal) break;
            }
        }
        // Try explicit "Metal" name
        if (!be_metal) {
            auto * dev = ggml_backend_dev_by_name("Metal");
            if (dev) be_metal = ggml_backend_dev_init(dev, nullptr);
        }
        if (!be_metal) {
            // try ACCEL
            auto * dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_ACCEL);
            if (dev) be_metal = ggml_backend_dev_init(dev, nullptr);
        }
    }

    printf("TQ2_0 parity harness: CPU=%s  accel=%s\n", ggml_backend_name(be_cpu), be_metal ? ggml_backend_name(be_metal) : "(none, cpu-only)");
    if (!be_metal) {
        be_metal = be_cpu;
        printf("  (no Metal/ACCEL found - running CPU self-check)\n");
    }

    int n_fail = 0, n_ok = 0, n_skip = 0;

    auto run = [&](ggml_context * ctx, ggml_cgraph * gf, const std::string & tag) {
        // quick support probe
        bool sup_cpu = backend_supports_graph(be_cpu, ctx);
        bool sup_acc = backend_supports_graph(be_metal, ctx);
        if (!sup_cpu || !sup_acc) { printf("  %-50s : SKIP (unsupported)\n", tag.c_str()); n_skip++; ggml_free(ctx); return; }
        bool ok = run_one(be_cpu, be_metal, ctx, gf, tag);
        if (ok) n_ok++; else n_fail++;
        ggml_free(ctx);
    };

    // ---- MUL_MAT suite ----------------------------------------------------
    // k must be multiple of QK_K=256
    // Covers three Metal dispatch paths for TQ2_0:
    //   n==1         -> kernel_mul_mv_tq2_0_f32
    //   2<=n<=8      -> kernel_mul_mv_ext_tq2_0_f32
    //   n>8          -> kernel_mul_mm_tq2_0_f32
    const struct { int m,n,k; int bs0,bs1; } mul_cases[] = {
        {32, 32, 256, 1,1},
        {64, 32, 512, 1,1},
        {32, 32, 256, 2,2},   // batched
        {16, 16, 1024, 1,1},
        {8,  32, 256, 1,1},
        // vec (n=1) — single-token decode, kernel_mul_mv_tq2_0_f32
        {128, 1, 256, 1,1},
        {1,   1, 256, 1,1},   // single row (tail)
        {7,   1, 256, 1,1},   // not divisible by N_R0=8
        {8,   1, 256, 1,1},   // exactly N_R0
        {9,   1, 256, 1,1},   // N_R0+1 (tail)
        {15,  1, 512, 1,1},   // 2*N_R0-1
        {16,  1, 512, 1,1},   // 2*N_R0
        {31,  1, 256, 1,1},   // small prime-ish
        {64,  1, 1024,1,1},   // larger K
        {128, 1, 1024,1,1},
        {256, 1, 2048,1,1},   // LLM hidden-ish
        // small-batch (2<=n<=8) — kernel_mul_mv_ext_tq2_0_f32
        {32,  2, 256, 1,1},
        {32,  4, 256, 1,1},
        {32,  8, 256, 1,1},
        {64,  5, 512, 1,1},
    };
    for (auto c : mul_cases) {
        ggml_init_params p = { ggml_tensor_overhead()*128 + ggml_graph_overhead(), nullptr, true };
        ggml_context * ctx = ggml_init(p);
        GraphSpec g = build_mul_mat_tq2(ctx, c.m, c.n, c.k, c.bs0, c.bs1);
        char tag[128]; snprintf(tag, sizeof(tag), "MUL_MAT TQ2_0 m=%d n=%d k=%d bs=[%d,%d]", c.m,c.n,c.k,c.bs0,c.bs1);
        run(ctx, g.gf, tag);
    }

    // ---- GET_ROWS suite ---------------------------------------------------
    const struct { int n,m,r; } gr_cases[] = {
        {256, 8,  4},
        {512, 32, 8},
        {256, 64, 16},
        {1024, 4, 32},
    };
    for (auto c : gr_cases) {
        ggml_init_params p = { ggml_tensor_overhead()*128 + ggml_graph_overhead(), nullptr, true };
        ggml_context * ctx = ggml_init(p);
        GraphSpec g = build_get_rows_tq2(ctx, c.n, c.m, c.r);
        char tag[128]; snprintf(tag, sizeof(tag), "GET_ROWS TQ2_0 n=%d m=%d r=%d", c.n,c.m,c.r);
        run(ctx, g.gf, tag);
    }

    printf("\nSummary: %d OK  %d FAIL  %d SKIP\n", n_ok, n_fail, n_skip);
    ggml_backend_free(be_cpu);
    if (be_metal && be_metal != be_cpu) ggml_backend_free(be_metal);
    return n_fail ? 1 : 0;
}
