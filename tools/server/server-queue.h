#pragma once

#include "server-task.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>
#include <unordered_map>
#include <unordered_set>

// Overlap scheduler: a background worker that pre-stages CPU-only preparation
// for tasks while the main inference loop is busy on the GPU. This mirrors the
// spirit of TRT-LLM's overlap scheduler (prepare iteration N+1 while iteration
// N decodes) without splitting into a separate process: the main loop stays the
// single GPU-submission thread, and only pure-function work that touches no
// slot/llama_context state is allowed to run here.
//
// The first staged artifact is the stable cache-key vector used by the
// block-radix prefix cache and the serialized prompt cache. Computing it is
// O(prompt length) and previously ran on the inference thread inside
// get_available_slot(); staging it on the worker removes that cost from the
// admission critical path whenever a request waited in the queue.
//
// Fine-grained GPU/CPU overlap via Metal shared events or CUDA streams is left
// as a TODO: it requires double-buffered slot/batch state which is a larger
// change than is safe to make here.
struct server_prep_pool {
    // A single staged prep request. Holds only the data needed to derive
    // stable cache keys without referencing the (move-only, shared) task
    // object: the token ids and whether multimodal chunks are present. Text
    // prompts are fully cacheable here; multimodal prompts are skipped and
    // derived inline on the inference thread.
    struct request {
        int                      task_id  = -1;
        bool                     has_mtmd = false;
        std::vector<llama_token> tokens;
    };

    // Process staged requests. Called from the worker thread; the result is
    // typically stored by the callback in a thread-safe map keyed by task_id.
    using prep_fn = std::function<void(const request &)>;

    server_prep_pool() = default;
    ~server_prep_pool();

    // Start the worker thread. idempotent. Returns false if the thread could
    // not be started (caller falls back to inline prep).
    bool start(prep_fn callback);

    // Stop the worker and join. safe to call from any thread.
    void stop();

    // Submit a request for background staging. Moves the snapshot. If the
    // worker is not running, the request is dropped (caller will compute
    // inline on demand).
    void submit(request && req);

private:
    void loop();

    std::mutex              mutex;
    std::condition_variable cv;
    std::thread             worker;
    std::atomic<bool>       running { false };
    std::atomic<bool>       stop_requested { false };
    std::deque<request>     queue;
    prep_fn                 fn;
};

// General-purpose worker pool for CPU prep work that should run in parallel
// with the inference thread. vLLM's EngineCore-in-separate-process buys
// throughput by overlapping Python CPU work with GPU work (vllm-concurrency
// study section 14.2). Tessera's hot path is already C++ with no GIL, so the
// reason for the split does not apply; the spirit does. The single-thread
// server_prep_pool above covers the cache-key staging use case; this pool is
// the general fan-out for any other pure-function CPU prep (CLI tokenization,
// future Jinja template application, etc.) so the inference thread only sees
// "ready to run" tasks.
//
// API shape mirrors a std::thread::hardware_concurrency()-sized executor:
//   pool.dispatch_async([this, t = std::move(task)] { ... });
// dispatch_async returns false when the pool is at capacity or not running;
// the caller is expected to fall back to inline execution. The queue is
// bounded to keep HTTP-driven dispatch from OOMing the process under load.
struct server_host_pool {
    using task_fn = std::function<void()>;

    server_host_pool() = default;
    ~server_host_pool();

    // Start n_workers background threads. n_workers = 0 picks
    // std::thread::hardware_concurrency() (or 1 if the query returns 0).
    // Idempotent; returns false if thread creation failed (caller falls
    // back to inline execution).
    bool start(size_t n_workers = 0);

    // Stop and join. Safe to call from any thread. Pending tasks are dropped.
    void stop();

    // Submit a task for background execution. Returns true if the task was
    // accepted, false if the pool is at capacity or not running. Bounded by
    // set_queue_capacity() (default 1024) so dispatch_async is the
    // observable backpressure point, not the heap.
    bool dispatch_async(task_fn fn);

    // Pending-task count. For observability.
    size_t queue_size() const;

    // Max pending tasks. dispatch_async returns false once the queue
    // reaches this size. Default 1024; settable for tests.
    void   set_queue_capacity(size_t cap) { capacity = cap; }
    size_t queue_capacity() const         { return capacity; }

    // Number of worker threads (0 if not started).
    size_t pool_size() const { return n_workers; }

private:
    void worker_loop();

    mutable std::mutex       mutex;
    std::condition_variable  cv;
    std::deque<task_fn>      queue;
    std::vector<std::thread> workers;
    std::atomic<bool>        running { false };
    std::atomic<bool>        stop_requested { false };
    size_t                   capacity  = 1024;
    size_t                   n_workers = 0;
};

// struct for managing server tasks
// in most cases, use server_response_reader to post new tasks and retrieve results
struct server_queue {
private:
    int id = 0;
    bool running  = false;
    bool sleeping = false;
    bool req_stop_sleeping = false;
    int64_t time_last_task = 0;

    // queues
    std::deque<server_task> queue_tasks;
    std::deque<server_task> queue_tasks_deferred;

    // Tasks whose CPU prep phase ran on a server_host_pool worker and are
    // ready to be processed on the inference thread. Workers post via
    // post_ready(); start_loop() drains this before the regular queue, so
    // a task that already paid its CPU cost does not wait behind a fresh
    // dispatch.
    //
    // The same mutex_tasks / condition_tasks used for queue_tasks guard
    // this deque, so a single condition variable wakes the inference
    // thread for either source.
    std::deque<server_task> queue_tasks_ready;

    std::mutex mutex_tasks;
    std::condition_variable condition_tasks;

    // callback functions
    std::function<void(server_task &&)> callback_new_task;
    std::function<void(void)>           callback_update_slots;
    std::function<void(bool)>           callback_sleeping_state;

public:
    // Add a new task to the end of the queue
    int post(server_task && task, bool front = false);

    // multi-task version of post()
    int post(std::vector<server_task> && tasks, bool front = false);

    // Add a new task, but defer until one slot is available
    void defer(server_task && task);

    // Called by server_host_pool workers to push a task that has finished
    // its CPU prep phase (tokenization, template application, etc.) and
    // is ready to be admitted to a slot. The task is moved in.
    void post_ready(server_task && task);

    // Get the next id for creating a new task
    int get_new_id();

    // Call when the state of one slot is changed, it will move one task from deferred to main queue
    // prioritize tasks that use the specified slot (otherwise, pop the first deferred task)
    void pop_deferred_task(int id_slot);

    // if sleeping, request exiting sleep state and wait until it is done
    // returns immediately if not sleeping
    void wait_until_no_sleep();

    bool is_sleeping() {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        return sleeping;
    }

    // end the start_loop routine
    void terminate();

    /**
     * Main loop consists of these steps:
     * - Wait until a new task arrives
     * - Process the task (i.e. maybe copy data into slot)
     * - Check if multitask is finished
     * - Update all slots
     *
     * Sleeping procedure (disabled if idle_sleep_ms < 0):
     * - If there is no task after idle_sleep_ms, enter sleeping state
     * - Call callback_sleeping_state(true)
     * - Wait until req_stop_sleeping is set to true
     * - Call callback_sleeping_state(false)
     * - Exit sleeping state
     */
    void start_loop(int64_t idle_sleep_ms = -1);

    // for metrics
    size_t queue_tasks_deferred_size() {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        return queue_tasks_deferred.size();
    }

    //
    // Functions below are not thread-safe, must only be used before start_loop() is called
    //

    // Register function to process a new task
    void on_new_task(std::function<void(server_task &&)> callback) {
        callback_new_task = std::move(callback);
    }

    // Register the function to be called when all slots data is ready to be processed
    void on_update_slots(std::function<void(void)> callback) {
        callback_update_slots = std::move(callback);
    }

    // Register callback for sleeping state change; multiple callbacks are allowed
    // note: when entering sleeping state, the callback is called AFTER sleeping is set to true
    //       when leaving sleeping state, the callback is called BEFORE sleeping is set to false
    void on_sleeping_state(std::function<void(bool)> callback) {
        if (callback_sleeping_state) {
            auto prev_callback = std::move(callback_sleeping_state);
            callback_sleeping_state = [prev_callback, callback](bool sleeping) {
                prev_callback(sleeping);
                callback(sleeping);
            };
        } else {
            callback_sleeping_state = std::move(callback);
        }
    }

private:
    void cleanup_pending_task(int id_target);
};

// struct for managing server responses
// in most cases, use server_response_reader to retrieve results
struct server_response {
private:
    bool running = true;

    // for keeping track of all tasks waiting for the result
    std::unordered_set<int> waiting_task_ids;

    // the main result queue (using ptr for polymorphism)
    std::vector<server_task_result_ptr> queue_results;

    std::mutex mutex_results;
    std::condition_variable condition_results;

public:
    // add the id_task to the list of tasks waiting for response
    void add_waiting_task_id(int id_task);

    void add_waiting_task_ids(const std::unordered_set<int> & id_tasks);

    // when the request is finished, we can remove task associated with it
    void remove_waiting_task_id(int id_task);

    // remove multiple tasks from waiting list
    void remove_waiting_task_ids(const std::unordered_set<int> & id_tasks);

    // This function blocks the thread until there is a response for one of the id_tasks
    server_task_result_ptr recv(const std::unordered_set<int> & id_tasks);

    // same as recv(), but have timeout in seconds
    // if timeout is reached, nullptr is returned
    server_task_result_ptr recv_with_timeout(const std::unordered_set<int> & id_tasks, int timeout);

    // single-task version of recv()
    server_task_result_ptr recv(int id_task);

    // Send a new result to a waiting id_task
    void send(server_task_result_ptr && result);

    // broadcast a new result to all waiting tasks
    // (used by router mode)
    void broadcast(server_task_result_ptr && result);

    // terminate the waiting loop
    void terminate();
};

// Run a pure-function CPU prep unit on a host_pool worker, falling back to
// inline execution on the calling thread if the pool is at capacity or not
// running. The caller blocks on a future when the work is dispatched, so the
// net effect for a single caller is identical to running inline - the win
// comes from N workers serving M parked callers concurrently, parallelising
// the CPU prep that would otherwise serialise on each caller's own thread.
//
// The caller is responsible for incrementing the matching counter
// (server_context_impl::n_host_dispatched_total or n_host_inline_total) using
// the `dispatched` field of the returned struct.
//
// The void overload is separate because the std::promise<void> type forces a
// different template instantiation; keeping the two cases distinct avoids
// forcing every caller to wrap a sentinel return value.
template <typename R>
struct host_pool_dispatch_result {
    bool dispatched;
    R     value;
};

template <typename F>
auto host_pool_dispatch(server_host_pool & pool, F f) -> host_pool_dispatch_result<std::invoke_result_t<F>> {
    using R = std::invoke_result_t<F>;
    static_assert(!std::is_void_v<R>, "use host_pool_dispatch_void for void callables");

    auto promise_ptr = std::make_shared<std::promise<R>>();
    auto fut = promise_ptr->get_future();

    bool accepted = pool.dispatch_async([promise_ptr, f = std::move(f)]() mutable {
        try {
            promise_ptr->set_value(f());
        } catch (...) {
            promise_ptr->set_exception(std::current_exception());
        }
    });

    if (accepted) {
        return {true, fut.get()};
    } else {
        return {false, f()};
    }
}

inline bool host_pool_dispatch_void(server_host_pool & pool, std::function<void()> f) {
    auto promise_ptr = std::make_shared<std::promise<void>>();
    auto fut = promise_ptr->get_future();

    bool accepted = pool.dispatch_async([promise_ptr, f = std::move(f)]() mutable {
        try {
            f();
            promise_ptr->set_value();
        } catch (...) {
            promise_ptr->set_exception(std::current_exception());
        }
    });

    if (accepted) {
        fut.get();
        return true;
    } else {
        f();
        return false;
    }
}

// RAII wrapper to make working with server_queue and server_response easier
// it provides a generator-like API for server responses
// support pooling connection state and aggregating multiple results
struct server_response_reader {
    std::unordered_set<int> id_tasks;
    server_queue & queue_tasks;
    server_response & queue_results;
    size_t received_count = 0;
    bool cancelled = false;
    int polling_interval_seconds;

    // tracking generation state and partial tool calls
    // only used by streaming completions
    std::vector<task_result_state> states;

    // Optional host_pool reference for offloading the per-chunk update() work
    // (chat-msg diff via task_result_state::update_chat_msg) to CPU workers.
    // Nullptr means inline execution on the HTTP thread. The two counter
    // pointers are incremented by next() when work is dispatched or falls
    // back; pass nullptr to skip accounting. Both fields default to nullptr
    // so callers that don't care about the offload keep working unchanged.
    server_host_pool * host_pool              = nullptr;
    uint64_t         * n_host_dispatched_total = nullptr;
    uint64_t         * n_host_inline_total     = nullptr;

    // should_stop function will be called each polling_interval_seconds
    server_response_reader(server_queue & queue_tasks, server_response & queue_results, int polling_interval_seconds,
                           server_host_pool * host_pool = nullptr,
                           uint64_t * n_host_dispatched_total = nullptr,
                           uint64_t * n_host_inline_total     = nullptr)
        : queue_tasks(queue_tasks), queue_results(queue_results), polling_interval_seconds(polling_interval_seconds),
          host_pool(host_pool),
          n_host_dispatched_total(n_host_dispatched_total),
          n_host_inline_total(n_host_inline_total) {}
    ~server_response_reader() {
        stop();
    }

    int get_new_id() {
        return queue_tasks.get_new_id();
    }

    // if front = true, the task will be posted to the front of the queue (high priority)
    void post_task(server_task && task, bool front = false);
    void post_tasks(std::vector<server_task> && tasks, bool front = false);
    bool has_next() const;

    // return nullptr if should_stop() is true before receiving a result
    // note: if one error is received, it will stop further processing and return error result
    server_task_result_ptr next(const std::function<bool()> & should_stop);

    struct batch_response {
        bool is_terminated = false; // if true, indicates that processing was stopped before all results were received
        std::vector<server_task_result_ptr> results;
        server_task_result_ptr error; // nullptr if no error
    };
    // aggregate multiple results
    batch_response wait_for_all(const std::function<bool()> & should_stop);

    void stop();
};
