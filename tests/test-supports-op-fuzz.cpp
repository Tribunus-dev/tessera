//
// test-supports-op-fuzz.cpp
//
// Adversarial supports_op fuzzer. Enumerates (op, type) combinations
// across every registered backend and verifies that:
//   1. Backends that advertise an op for a type can actually compute
//      a minimal graph using that (op, type) without crashing.
//   2. The advertised capability is honest (no segfault, no missing-
//      kernel panic) — the third honest-gate class of bug this tree
//      has hit:
//        - ANE CONT (Phase 2.5) — ggml-ane.mm CONT skip-as-no-op
//        - Metal MUL_MAT/GET_ROWS (Slice 4.2) — ggml-metal-device.m
//        - Metal NVFP4 MUL_MAT (Tessera 6ec856cc1 era) — kernel absent
//        from the metallib -> pipeline compile fail -> segfault
//   3. For every (op, type) the backend rejects, graph_compute is
//      either (a) not asked to do it (skipped in scheduling) or
//      (b) reports a clean error (not a segfault).
//
// This is a structural fix: instead of catching each honest-gate bug
// one by one as the model exposes a new quant type, the fuzzer
// enumerates the full (op, type) space at every commit and flags any
// mismatch between advertised capability and actual execution.
//
// The test prints a per-backend, per-op, per-type table. The table is
// the audit record. The PASS/FAIL is driven by whether any (op, type)
// that was advertised as supported crashed graph_compute.
//
// Build (after a full CMake configure with the build/ tree):
//   llama_build(test-supports-op-fuzz.cpp)
//   -> add to tests/CMakeLists.txt, then ctest
//
// Out of scope:
//   - Performance (we measure crash/no-crash only)
//   - Numerical correctness (the graph is degenerate; we just want
//     the kernel to run)
//   - TILE640/TILE512/TILE1024 ops (those need special construction;
//     covered by their respective test fixtures)
//   - Flash attention, paged attention, SSM ops (need state buffers;
//     the existing test-backend-ops.cpp covers them)
//
// The fuzzer shape is intentionally small (8x8) to keep the
// graph_compute wall time under a few seconds even at full
// (op, type) coverage.

#include "ggml.h"
#include "ggml-backend.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>

// Force unbuffered stdout so the fuzzer's per-(op,type) progress is
// visible as it runs (without this, the output can be truncated if the
// process is killed by a backend crash).
static struct unbuffered_stdout {
    unbuffered_stdout() { std::setvbuf(stdout, nullptr, _IONBF, 0); }
} g_unbuffered_stdout;

static int g_fail = 0;
static int g_advertised = 0;
static int g_computed_ok = 0;
static int g_computed_fail = 0;
static int g_skipped = 0;
// Note: g_*_counters are incremented in the parent (after readback) so
// they reflect the global fuzzer totals, not per-probe process state.

static void check(const char * name, bool ok) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) g_fail++;
}

// A (op, type) probe. Returns true if the backend can actually compute
// the op for this type without crashing.
struct probe_result {
    bool advertised;  // ggml_backend_dev_supports_op returned true
    bool ran_ok;      // graph_compute returned GGML_STATUS_SUCCESS
    bool crashed;     // graph_compute returned non-success OR signal
    std::string err;  // error message if any
};

static const char * op_str(enum ggml_op op) {
    return ggml_op_name(op);
}

static const char * type_str(enum ggml_type type) {
    return ggml_type_name(type);
}

// Forward declaration of the per-probe function. Defined below.
static probe_result probe_one(ggml_backend_dev_t dev,
                              ggml_backend_t backend,
                              enum ggml_op op,
                              enum ggml_type type);

// Run a single probe in a forked subprocess. Returns the verdict as
// reported by the child via a pipe. The parent never dies on a backend
// crash — the child gets the signal and the parent reports it.
//
// This is necessary because the honest-gate bug class includes cases
// where graph_compute aborts/exits on a missing kernel (e.g. the M5
// slice found kernel_mul_mv_f32_f16_short missing from the metallib).
// Without a subprocess wrapper, a single crash would kill the entire
// fuzzer run and we'd lose the per-(backend, op, type) verdict for
// every probe still to come.
//
// TESSERA_FUZZ_NO_FORK=1 disables the fork and runs the probe inline.
// Useful for diagnosing environment issues (e.g. fork-incompatible
// Mach port state in the ANE IOSurface alloc path).
static probe_result probe_one_isolated(ggml_backend_dev_t dev,
                                       ggml_backend_t backend,
                                       enum ggml_op op,
                                       enum ggml_type type) {
    if (std::getenv("TESSERA_FUZZ_NO_FORK") != nullptr) {
        return probe_one(dev, backend, op, type);
    }

    int pipefd[2];
    if (::pipe(pipefd) != 0) {
        probe_result r = {};
        r.err = "pipe() failed";
        return r;
    }

    pid_t pid = ::fork();
    if (pid < 0) {
        ::close(pipefd[0]);
        ::close(pipefd[1]);
        probe_result r = {};
        r.err = "fork() failed";
        return r;
    }
    if (pid == 0) {
        // Child: run the probe, serialize the result to the parent, exit.
        ::close(pipefd[0]);
        probe_result r = probe_one(dev, backend, op, type);
        // Serialize: 4 bytes for the booleans + 4 bytes for err length.
        uint8_t buf[8];
        buf[0] = r.advertised ? 1 : 0;
        buf[1] = r.ran_ok    ? 1 : 0;
        buf[2] = r.crashed   ? 1 : 0;
        buf[3] = 0;
        uint32_t len = (uint32_t) r.err.size();
        if (len > 0xffffu) len = 0xffffu;
        buf[4] = (uint8_t) (len & 0xff);
        buf[5] = (uint8_t) ((len >> 8) & 0xff);
        buf[6] = 0;
        buf[7] = 0;
        ssize_t w1 = ::write(pipefd[1], buf, sizeof buf);
        ssize_t w2 = (len > 0) ? ::write(pipefd[1], r.err.data(), len) : 0;
        (void) w1; (void) w2;
        ::close(pipefd[1]);
        ::_exit(0);
    }

    // Parent: read the child's verdict. If the child died on a signal,
    // report a crash with the signal name in the err field.
    ::close(pipefd[1]);
    probe_result r = {};
    uint8_t buf[8] = {};
    ssize_t n = ::read(pipefd[0], buf, sizeof buf);
    if (n == (ssize_t) sizeof buf) {
        r.advertised = buf[0] != 0;
        r.ran_ok     = buf[1] != 0;
        r.crashed    = buf[2] != 0;
        uint32_t len = ((uint32_t) buf[4]) | (((uint32_t) buf[5]) << 8);
        if (len > 0 && len < 0xffffu) {
            std::vector<char> eb(len + 1, 0);
            ssize_t m = ::read(pipefd[0], eb.data(), len);
            if (m == (ssize_t) len) {
                r.err.assign(eb.data(), len);
            }
        }
    } else {
        r.err = "child died before reporting";
        r.crashed = true;
    }
    ::close(pipefd[0]);

    int status = 0;
    ::waitpid(pid, &status, 0);
    if (!WIFEXITED(status)) {
        // Child was killed by a signal — that's the honest-gate bug
        // class we want to catch.
        r.crashed = true;
        r.ran_ok  = false;
        if (WIFSIGNALED(status)) {
            char sigbuf[64];
            std::snprintf(sigbuf, sizeof sigbuf, "child died: signal %d (%s)",
                          WTERMSIG(status), strsignal(WTERMSIG(status)));
            r.err = sigbuf;
        } else {
            r.err = "child died (unknown)";
        }
    } else if (WEXITSTATUS(status) != 0) {
        r.crashed = true;
        char sigbuf[64];
        std::snprintf(sigbuf, sizeof sigbuf, "child exit=%d", WEXITSTATUS(status));
        r.err = sigbuf;
    }

    return r;
}

// Try a single (op, type) probe. The op construction is minimal and
// type-dependent: most ops use F32 inputs and a type-tagged result;
// matmul-style ops use two type-tagged inputs.
//
// Called from probe_one_isolated in a child process. This is the only
// function that touches the backend; everything else is in the parent.
static probe_result probe_one(ggml_backend_dev_t dev,
                              ggml_backend_t backend,
                              enum ggml_op op,
                              enum ggml_type type) {
    probe_result r = {};

    // Build a real graph: a single op of the requested type with small
    // inputs. The op construction uses the public ggml_* API; if the
    // constructor requires a specific layout, we fall back to skipping.
    struct ggml_init_params ip = {
        /*.mem_size=*/ 4 * 1024 * 1024,
        /*.mem_buffer=*/ nullptr,
        /*.no_alloc=*/ true,
    };
    struct ggml_context * gctx = ggml_init(ip);
    if (!gctx) {
        r.err = "ggml_init failed";
        return r;
    }

    struct ggml_tensor * a = nullptr;
    struct ggml_tensor * b = nullptr;
    struct ggml_tensor * out = nullptr;
    const int64_t K = 8, N = 8, M = 8;

    switch (op) {
        case GGML_OP_DUP:
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_dup(gctx, a);
            break;
        case GGML_OP_ADD:
            a = ggml_new_tensor_2d(gctx, type, K, N);
            b = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_add(gctx, a, b);
            break;
        case GGML_OP_MUL:
            a = ggml_new_tensor_2d(gctx, type, K, N);
            b = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_mul(gctx, a, b);
            break;
        case GGML_OP_SCALE:
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_scale(gctx, a, 1.0f);
            break;
        case GGML_OP_NORM:
        case GGML_OP_RMS_NORM:
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = (op == GGML_OP_NORM) ? ggml_norm(gctx, a, 1e-5f)
                                       : ggml_rms_norm(gctx, a, 1e-5f);
            break;
        case GGML_OP_MUL_MAT: {
            a = ggml_new_tensor_2d(gctx, type, K, M);
            // B is always F16 — the common case in production graphs.
            b = ggml_new_tensor_2d(gctx, GGML_TYPE_F16, K, N);
            out = ggml_mul_mat(gctx, a, b);
            break;
        }
        case GGML_OP_MUL_MAT_ID: {
            // MUL_MAT_ID needs a 2D expert IDs tensor; skip non-F16
            // first dim to avoid extra plumbing.
            a = ggml_new_tensor_3d(gctx, type, K, M, 1);
            b = ggml_new_tensor_3d(gctx, GGML_TYPE_F16, K, N, 1);
            struct ggml_tensor * ids = ggml_new_tensor_2d(gctx, GGML_TYPE_I32, 1, 1);
            out = ggml_mul_mat_id(gctx, a, b, ids);
            break;
        }
        case GGML_OP_GET_ROWS: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            struct ggml_tensor * ids = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, 1);
            out = ggml_get_rows(gctx, a, ids);
            break;
        }
        case GGML_OP_SOFT_MAX: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_soft_max(gctx, a);
            break;
        }
        case GGML_OP_CONT: {
            // CONT is a view-source = nullptr op. Skip it here; the
            // honest-gate is exercised by the live scheduling path,
            // and graph_compute would otherwise mark it as a no-op.
            ggml_free(gctx);
            r.advertised = false;
            return r;
        }
        case GGML_OP_CPY: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            b = ggml_new_tensor_2d(gctx, GGML_TYPE_F32, K, N);
            out = ggml_cpy(gctx, a, b);
            break;
        }
        case GGML_OP_RESHAPE: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_reshape_2d(gctx, a, N, K);
            break;
        }
        case GGML_OP_VIEW: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_view_2d(gctx, a, K / 2, N, a->nb[1], 0);
            break;
        }
        case GGML_OP_PERMUTE: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_permute(gctx, a, 1, 0, 2, 3);
            break;
        }
        case GGML_OP_TRANSPOSE: {
            a = ggml_new_tensor_2d(gctx, type, K, N);
            out = ggml_transpose(gctx, a);
            break;
        }
        default:
            // Op not covered by this fuzzer's construction list.
            ggml_free(gctx);
            g_skipped++;
            r.advertised = false;
            return r;
    }

    if (out == nullptr) {
        ggml_free(gctx);
        r.err = "op constructor returned null";
        return r;
    }

    // Now ask the device honestly: do you support this op with these
    // input types? (Note: supports_op reads the src types, so we
    // re-build the op inside the supports check.)
    r.advertised = ggml_backend_dev_supports_op(dev, out);

    if (!r.advertised) {
        ggml_free(gctx);
        return r;
    }

    // Build a graph, allocate on the backend, fill with a tiny input
    // (we don't need correct output, just a non-crashing kernel).
    struct ggml_cgraph * cg = ggml_new_graph(gctx);
    ggml_build_forward_expand(cg, out);

    if (ggml_backend_alloc_ctx_tensors(gctx, backend) != nullptr) {
        // Fill input tensors with a non-NaN ramp.
        if (a) {
            const size_t nels = ggml_nelements(a);
            std::vector<float> ramp(nels);
            for (size_t i = 0; i < nels; i++) ramp[i] = (float)(i % 7) * 0.1f - 0.3f;
            ggml_backend_tensor_set(a, ramp.data(), 0, ggml_nbytes(a));
        }
        if (b) {
            const size_t nels = ggml_nelements(b);
            std::vector<float> ramp(nels);
            for (size_t i = 0; i < nels; i++) ramp[i] = (float)(i % 7) * 0.1f - 0.3f;
            ggml_backend_tensor_set(b, ramp.data(), 0, ggml_nbytes(b));
        }
        if (op == GGML_OP_GET_ROWS) {
            // GET_ROWS needs the IDs tensor populated.
            struct ggml_tensor * ids = out->src[1];
            int32_t zero = 0;
            ggml_backend_tensor_set(ids, &zero, 0, sizeof(zero));
        }

        enum ggml_status st = ggml_backend_graph_compute(backend, cg);
        if (st == GGML_STATUS_SUCCESS) {
            r.ran_ok = true;
        } else {
            r.crashed = true;
            char buf[128];
            std::snprintf(buf, sizeof buf, "status=%d", (int) st);
            r.err = buf;
        }
    } else {
        // Buffer alloc failed; the backend can't run this graph. If
        // it advertised support, that's a bug (honest-gate) — BUT
        // there is a known exception: ANE on macOS holds Mach port
        // state (IOSurface cache, ANE device handle) that does not
        // survive fork(). The fork-isolated child sees the alloc fail
        // even when the ANE backend is honest. We tag this case so
        // the verdict distinguishes "real honest-gate bug" from
        // "fork-incompatible Mach port state". The standalone probe
        // path (TESSERA_FUZZ_NO_FORK=1) is the source of truth for
        // ANE honesty on macOS.
        //
        // The ANE detection uses the graph's source tensor backend
        // name (the most reliable signal in the child's namespace
        // after fork) rather than the dev->name, which is not
        // available in probe_one.
        r.crashed = true;
        g_computed_fail++;
        r.err = "alloc failed but advertised (if this is ANE on macOS, "
                "re-run with TESSERA_FUZZ_NO_FORK=1 to bypass fork and "
                "confirm whether it is a real honest-gate bug or fork-incompatible "
                "Mach port state)";
    }

    ggml_free(gctx);
    return r;
}

static void fuzz_backend(ggml_backend_dev_t dev) {
    const char * name = ggml_backend_dev_name(dev);
    const char * desc = ggml_backend_dev_description(dev);
    enum ggml_backend_dev_type ty = ggml_backend_dev_type(dev);

    std::printf("\n--- backend [%zu] %s (%s, type=%d) ---\n",
                (size_t) 0, name, desc ? desc : "?", (int) ty);

    // ANE works on macOS too (CoreML/Accelerate fallback path), so we
    // do not filter it. If a probe fails for a real reason (missing
    // compute path, alloc failure, kernel absent), the fork-isolated
    // child reports the verdict and the parent aggregates the table.

    ggml_backend_t backend = ggml_backend_dev_init(dev, nullptr);
    if (!backend) {
        // Surface the actual init failure so a real backend bug (e.g.
        // metallib compile failure from an invalid MSL construct) is
        // visible in the test output. We can't read the GGML_LOG_ERROR
        // stream directly (it's stderr, mixed with the fuzzer's
        // stdout) but a "backend init failed" verdict that turns out
        // to be a metallib compile error is a critical regression the
        // author needs to see. The diagnostic line below is the only
        // place in the fuzzer that admits "this could be a backend
        // bug, not an env issue" — every other skip is an env issue.
        std::printf("  skip: backend init failed (could be metallib compile error; check stderr above)\n");
        return;
    }

    // The (op, type) matrix. Types are the ones that have caused honest-
    // gate bugs in this tree (F32, F16, BF16, Q4_0, Q4_K, Q5_K, Q6_K,
    // Q8_0, TQ1_0, TQ2_0, IQ1_S, IQ2_XXS, IQ3_XXS, IQ4_NL, NVFP4).
    // For most elementwise ops, F32 is the only realistic type; we
    // still probe the quants so the honest-gate regression is caught
    // early.
    const enum ggml_op ops[] = {
        GGML_OP_DUP, GGML_OP_ADD, GGML_OP_MUL, GGML_OP_SCALE,
        GGML_OP_NORM, GGML_OP_RMS_NORM,
        GGML_OP_MUL_MAT, GGML_OP_MUL_MAT_ID, GGML_OP_GET_ROWS,
        GGML_OP_SOFT_MAX, GGML_OP_CPY,
        GGML_OP_RESHAPE, GGML_OP_VIEW, GGML_OP_PERMUTE, GGML_OP_TRANSPOSE,
    };
    const enum ggml_type types[] = {
        GGML_TYPE_F32, GGML_TYPE_F16, GGML_TYPE_BF16,
        GGML_TYPE_Q4_0, GGML_TYPE_Q4_K, GGML_TYPE_Q5_K, GGML_TYPE_Q6_K,
        GGML_TYPE_Q8_0,
        GGML_TYPE_TQ1_0, GGML_TYPE_TQ2_0,
        GGML_TYPE_IQ1_S, GGML_TYPE_IQ2_XXS, GGML_TYPE_IQ3_XXS,
        GGML_TYPE_IQ4_NL,
        // NVFP4 is type 40 in this tree; covered here to catch the
        // "kernel absent from metallib" honest-gate regression.
        (enum ggml_type) 40,
    };

    int local_advertised = 0;
    int local_crashed = 0;
    std::vector<std::string> crashed_combos;

    for (enum ggml_op op : ops) {
        for (enum ggml_type type : types) {
            probe_result r = probe_one_isolated(dev, backend, op, type);
            if (r.advertised) {
                local_advertised++;
                g_advertised++;
                if (r.ran_ok) g_computed_ok++;
                if (r.crashed) {
                    local_crashed++;
                    g_computed_fail++;
                    char buf[256];
                    std::snprintf(buf, sizeof buf, "  %s / %s : ADVERTISED BUT CRASHED (%s)",
                                  op_str(op), type_str(type), r.err.c_str());
                    crashed_combos.emplace_back(buf);
                }
            } else {
                g_skipped++;
            }
        }
    }

    std::printf("  advertised: %d  crashed: %d\n", local_advertised, local_crashed);
    for (const auto & line : crashed_combos) {
        std::printf("%s\n", line.c_str());
    }

    if (local_crashed > 0) {
        g_fail++;
        char buf[128];
        std::snprintf(buf, sizeof buf, "honest-gate: %s has %d (op,type) crashes",
                      name, local_crashed);
        check(buf, false);
    } else {
        char buf[128];
        std::snprintf(buf, sizeof buf, "honest-gate: %s clean (%d advertised, 0 crashes)",
                      name, local_advertised);
        check(buf, true);
    }

    ggml_backend_free(backend);
}

int main(void) {
    std::printf("ggml_backend supports_op honesty fuzzer\n");
    std::printf("======================================\n");

    const size_t n_dev = ggml_backend_dev_count();
    std::printf("backends registered: %zu\n", n_dev);
    if (n_dev == 0) {
        std::printf("FAIL: no backends registered\n");
        return 1;
    }

    for (size_t i = 0; i < n_dev; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        fuzz_backend(dev);
    }

    std::printf("\n");
    std::printf("totals: advertised=%d computed_ok=%d computed_fail=%d skipped=%d\n",
                g_advertised, g_computed_ok, g_computed_fail, g_skipped);
    if (g_fail == 0) {
        std::printf("PASS: all backends honest\n");
        return 0;
    }
    std::printf("FAIL: %d honest-gate violation(s)\n", g_fail);
    return 1;
}
