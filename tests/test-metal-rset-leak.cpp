// Test that an unreleased Metal buffer surfaces as a structured warning
// at process exit instead of aborting with GGML_ASSERT.
//
// Aug 2026 hardening: ggml_metal_rsets_free was changed from
// "GGML_ASSERT([rsets->data count] == 0); abort" to "drain + log the
// leaked rset labels". This test:
//
//   1. forks a child
//   2. in the child: redirects stderr to a temp file, allocates a
//      Metal buffer, INTENTIONALLY skips ggml_backend_buffer_free,
//      then calls std::exit(0). The static device destructors run
//      during exit, the rset drain writes the warning to the temp
//      file.
//   3. in the parent: reads the temp file, asserts the leak warning
//      header is present, the rset label includes the buffer size,
//      and the "Leaked sets:" line is emitted.
//
// If a future change reverts the drain behavior to a hard abort, this
// test fails (the child aborts with a signal, the warning is never
// written, the parent sees an empty log and reports failure).
//
// CRITICAL — std::exit vs std::_Exit: the rset drain is in the device's
// std::unique_ptr deleter, which is a C++ static destructor. C++ static
// destructors run on:
//   - normal return from main()
//   - std::exit(N)  (POSIX exit, runs atexit + static destructors)
// They do NOT run on:
//   - std::_Exit(N)  (POSIX _exit, immediate termination, NO C++ runtime)
//   - abort() / signal death
// Using std::_Exit(0) in the child would SKIP the drain and the test
// would falsely report failure (the log file would be empty and the
// "warning present" check would fail). The earlier draft of this
// test used _Exit; this version uses exit(0) for exactly this reason.
//
// Run: cmake --build build --target test-metal-rset-leak && \
//      build/bin/test-metal-rset-leak

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-metal.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static std::string read_file(const char * path) {
    std::string out;
    FILE * f = std::fopen(path, "rb");
    if (!f) return out;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    if (sz < 0) sz = 0;
    std::fseek(f, 0, SEEK_SET);
    out.resize((size_t) sz);
    size_t n = std::fread(out.data(), 1, (size_t) sz, f);
    out.resize(n);
    std::fclose(f);
    return out;
}

int main(void) {
    const char * tmp_path = "/tmp/test-metal-rset-leak.stderr.log";

    const pid_t pid = fork();
    if (pid < 0) {
        std::fprintf(stderr, "FAIL: fork\n");
        return 1;
    }
    if (pid == 0) {
        // CHILD: redirect stderr to the temp file, leak a buffer, exit.
        int fd = open(tmp_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) std::exit(1);
        if (dup2(fd, STDERR_FILENO) < 0) std::exit(1);
        close(fd);

        ggml_backend_t backend = ggml_backend_metal_init();
        if (backend == nullptr) {
            std::fprintf(stderr, "SKIP: Metal backend not available\n");
            std::exit(0);
        }
        struct ggml_init_params ip = { 8 * 1024 * 1024, nullptr, true };
        struct ggml_context * gctx = ggml_init(ip);
        struct ggml_tensor * a = ggml_new_tensor_1d(gctx, GGML_TYPE_F32, 1024);
        (void) a;
        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(gctx, backend);
        if (buf == nullptr) std::exit(1);
        // INTENTIONALLY skip ggml_backend_buffer_free(buf).
        ggml_free(gctx);
        ggml_backend_free(backend);
        // std::exit (NOT std::_Exit) so the C++ runtime runs static
        // destructors — the device's unique_ptr deleter fires the
        // rset drain. std::_Exit would terminate immediately without
        // running any C++ destructors, the drain wouldn't fire, and
        // the parent's "warning present" check would fail.
        std::exit(0);
    }

    // PARENT: wait for child, then read the log file.
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        std::fprintf(stderr, "FAIL: waitpid\n");
        return 1;
    }
    if (WIFSIGNALED(status)) {
        std::fprintf(stderr, "FAIL: child aborted with signal %d (%s) — the rset "
                         "drain path is broken (reverted to hard abort?)\n",
                         WTERMSIG(status), strsignal(WTERMSIG(status)));
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        std::fprintf(stderr, "FAIL: child exit status=%d (expected 0)\n",
                         WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        return 1;
    }

    const std::string log = read_file(tmp_path);
    int fail = 0;
    if (log.find("residency set(s) still in the collection") == std::string::npos) {
        std::fprintf(stderr, "FAIL: leak warning header not found in stderr\n");
        fail++;
    } else {
        std::fprintf(stderr, "PASS: leak warning header emitted\n");
    }
    if (log.find("ggml_metal_buffer(size=") == std::string::npos) {
        std::fprintf(stderr, "FAIL: rset label with size info not found\n");
        fail++;
    } else {
        std::fprintf(stderr, "PASS: rset label includes size info (leak is identifiable)\n");
    }
    if (log.find("Leaked sets:") == std::string::npos) {
        std::fprintf(stderr, "FAIL: 'Leaked sets:' line not found\n");
        fail++;
    } else {
        std::fprintf(stderr, "PASS: 'Leaked sets:' line emitted\n");
    }
    std::fprintf(stderr, "\n--- captured stderr from leak child ---\n%s--- end ---\n", log.c_str());

    //
    // HAPPY-PATH CHILD: do the same allocations but call
    // ggml_backend_buffer_free correctly. Verify the drain does NOT
    // emit a leak warning. This guards against false positives in the
    // drain path — if the drain were always-on (e.g. mis-keyed
    // associated-object lookup that finds the wrong object), every
    // correct usage would also produce a warning, and the test
    // would catch it.
    //
    const char * happy_path = "/tmp/test-metal-rset-happy.stderr.log";
    const pid_t pid_happy = fork();
    if (pid_happy < 0) {
        std::fprintf(stderr, "FAIL: fork (happy path)\n");
        return 1;
    }
    if (pid_happy == 0) {
        int fd = open(happy_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) std::exit(1);
        if (dup2(fd, STDERR_FILENO) < 0) std::exit(1);
        close(fd);

        ggml_backend_t backend = ggml_backend_metal_init();
        if (backend == nullptr) { std::exit(0); }
        struct ggml_init_params ip = { 8 * 1024 * 1024, nullptr, true };
        struct ggml_context * gctx = ggml_init(ip);
        struct ggml_tensor * a = ggml_new_tensor_1d(gctx, GGML_TYPE_F32, 1024);
        (void) a;
        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(gctx, backend);
        if (buf == nullptr) std::exit(1);
        // CORRECT usage: free the buffer before destroying the context.
        ggml_backend_buffer_free(buf);
        ggml_free(gctx);
        ggml_backend_free(backend);
        std::exit(0);
    }

    int status_happy = 0;
    if (waitpid(pid_happy, &status_happy, 0) < 0) {
        std::fprintf(stderr, "FAIL: waitpid (happy path)\n");
        return 1;
    }
    if (WIFSIGNALED(status_happy) || !WIFEXITED(status_happy) || WEXITSTATUS(status_happy) != 0) {
        std::fprintf(stderr, "FAIL: happy-path child crashed (status=%d)\n", status_happy);
        return 1;
    }
    const std::string log_happy = read_file(happy_path);
    if (log_happy.find("residency set(s) still in the collection") != std::string::npos) {
        std::fprintf(stderr, "FAIL: leak warning emitted on the happy path "
                         "(drain is mis-keyed or always-on; correct usage should "
                         "not produce a leak warning)\n");
        fail++;
    } else {
        std::fprintf(stderr, "PASS: no leak warning on correct usage (no false positive)\n");
    }
    std::fprintf(stderr, "\n--- captured stderr from happy-path child ---\n%s--- end ---\n",
                     log_happy.c_str());

    return fail;
}
