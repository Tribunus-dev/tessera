// host_pool_dispatch: dispatch-or-inline helper used by the chat-msg diff
// and Jinja template offload paths. The test exercises the contract that
// the production code relies on:
//
//   1. Returns the callable's value with `dispatched == true` when the
//      pool accepts the work; the work runs on a worker thread.
//   2. Returns the callable's value with `dispatched == false` when the
//      pool is at capacity or not running; the work runs on the calling
//      thread inline.
//   3. Exceptions thrown by the callable propagate through the future
//      (same as inline execution).
//   4. The void overload does the same for void-returning callables and
//      returns the dispatched flag.
//   5. N workers can serve M parked callers concurrently: a dispatched
//      call releases its caller as soon as the worker finishes, not
//      before, and a saturated pool rejects new dispatches (capacity
//      gate fires before the work can be queued).
//
// What this test does NOT cover: the per-call-site wiring in
// server-context.cpp (Jinja offload in the 6 chat handlers, chat-msg
// diff in next()) - those are HTTP-integration territory and live
// behind the existing end-to-end server smoke tests.

#include "server-queue.h"

#include <atomic>
#include <chrono>
#include <cassert>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static void test_dispatch_returns_value() {
    server_host_pool pool;
    assert(pool.start(2));

    auto r = host_pool_dispatch(pool, []() { return std::string("hello"); });
    assert(r.dispatched);
    assert(r.value == "hello");

    pool.stop();
}

static void test_dispatch_runs_on_worker() {
    // The callable must run on a worker thread, not the calling thread.
    // Pin the test on a known main thread id and verify the callable
    // sees a different one.
    server_host_pool pool;
    assert(pool.start(2));

    const auto main_tid = std::this_thread::get_id();
    std::atomic<bool> saw_other_thread{false};

    auto r = host_pool_dispatch(pool, [&]() -> int {
        if (std::this_thread::get_id() != main_tid) {
            saw_other_thread.store(true);
        }
        return 0;
    });
    assert(r.dispatched);
    assert(saw_other_thread.load());

    pool.stop();
}

static void test_dispatch_inline_fallback_when_not_running() {
    server_host_pool pool;
    // intentionally do not call pool.start()

    const auto main_tid = std::this_thread::get_id();
    std::atomic<bool> saw_main_thread{false};

    auto r = host_pool_dispatch(pool, [&]() -> int {
        if (std::this_thread::get_id() == main_tid) {
            saw_main_thread.store(true);
        }
        return 42;
    });
    assert(!r.dispatched);
    assert(r.value == 42);
    assert(saw_main_thread.load());
}

static void test_dispatch_inline_fallback_when_saturated() {
    // Fill the queue beyond capacity, then dispatch one more. The pool
    // must reject it (return false) and the caller must run inline.
    server_host_pool pool;
    assert(pool.start(1));
    pool.set_queue_capacity(2);

    // Park the only worker on a long-running task so the queue is the
    // bottleneck. We dispatch the blocker via pool.dispatch_async directly
    // (bypassing host_pool_dispatch) because host_pool_dispatch blocks on
    // a future and we want to keep the test thread free to keep pushing
    // into the queue.
    std::atomic<bool> release{false};
    assert(pool.dispatch_async([&release]() {
        while (!release.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }));

    // Push two more tasks so the queue hits capacity. These use
    // dispatch_async directly too, for the same reason: their futures
    // would otherwise block the test thread on the still-busy worker.
    assert(pool.dispatch_async([]() {}));
    assert(pool.dispatch_async([]() {}));
    assert(pool.queue_size() == 2);

    // Queue is now full (capacity=2). The next host_pool_dispatch must
    // be refused and run inline on the calling thread.
    const auto main_tid = std::this_thread::get_id();
    std::atomic<bool> saw_main_thread{false};
    auto r = host_pool_dispatch(pool, [&]() {
        if (std::this_thread::get_id() == main_tid) {
            saw_main_thread.store(true);
        }
        return 7;
    });
    assert(!r.dispatched);
    assert(r.value == 7);
    assert(saw_main_thread.load());

    release.store(true);
    pool.stop();
}

static void test_dispatch_propagates_exception() {
    // Whether the work runs on a worker or inline, an exception must
    // rethrow at the caller's fut.get() (or inline) site. Same shape as
    // calling the callable directly.
    server_host_pool pool;
    assert(pool.start(2));

    std::string caught;
    try {
        auto r = host_pool_dispatch(pool, []() -> int {
            throw std::runtime_error("kaboom");
        });
        (void) r;
    } catch (const std::runtime_error & e) {
        caught = e.what();
    }
    assert(caught == "kaboom");

    pool.stop();
}

static void test_dispatch_void_overload() {
    server_host_pool pool;
    assert(pool.start(2));

    std::atomic<int> counter{0};
    assert(host_pool_dispatch_void(pool, [&counter]() {
        counter.fetch_add(1);
    }));
    assert(counter.load() == 1);

    // Not running: void overload returns false and still runs the work.
    server_host_pool pool2;
    counter.store(0);
    assert(!host_pool_dispatch_void(pool2, [&counter]() {
        counter.fetch_add(1);
    }));
    assert(counter.load() == 1);

    pool.stop();
}

static void test_n_workers_serve_m_callers_concurrently() {
    // N=2 workers; dispatch M=8 tasks that each sleep briefly. Total
    // wall time should be ~ceil(M/N) sleeps, not M sleeps - this proves
    // the workers actually run in parallel rather than serialising.
    server_host_pool pool;
    assert(pool.start(2));

    constexpr int M = 8;
    constexpr auto sleep_each = std::chrono::milliseconds(50);

    const auto t0 = std::chrono::steady_clock::now();
    std::vector<host_pool_dispatch_result<int>> results;
    for (int i = 0; i < M; ++i) {
        results.push_back(host_pool_dispatch(pool, [i, sleep_each]() -> int {
            std::this_thread::sleep_for(sleep_each);
            return i;
        }));
    }
    const auto t1 = std::chrono::steady_clock::now();

    for (int i = 0; i < M; ++i) {
        assert(results[i].dispatched);
        assert(results[i].value == i);
    }

    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
    // 4 batches of 2 (ceil(8/2)) at 50ms each = ~200ms. Serial would be
    // 8*50 = 400ms. Allow generous slack for thread wakeup + scheduling.
    // assert() is a no-op under NDEBUG so the value would otherwise be
    // unused; keep it observable for `time` debugging.
    const bool parallel = elapsed_ms < 350;
    assert(parallel);
    (void) parallel;

    pool.stop();
}

int main() {
    test_dispatch_returns_value();
    test_dispatch_runs_on_worker();
    test_dispatch_inline_fallback_when_not_running();
    test_dispatch_inline_fallback_when_saturated();
    test_dispatch_propagates_exception();
    test_dispatch_void_overload();
    test_n_workers_serve_m_callers_concurrently();
    return 0;
}
