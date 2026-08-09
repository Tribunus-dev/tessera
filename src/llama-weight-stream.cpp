// llama-weight-stream.cpp — generic wrapper over gguf_weight_stream
//
// On Apple/GGML_USE_ANE forwards to ane_weight_stream_*.
// Elsewhere: stub that reports "not supported".
// Slice 4.1 adds: async prefetch (background memcpy) + layer_bytes helper.

#include "llama-weight-stream.h"

#if defined(__APPLE__) && defined(GGML_USE_ANE)
#include "gguf_weight_stream.h"

#include <future>
#include <thread>

struct llama_weight_stream_t {
    ane_weight_stream_t * inner = nullptr;
};

struct llama_weight_stream_prefetch {
    std::future<int64_t> fut;
};

bool llama_weight_stream_open(const char * p, llama_weight_stream_t ** out,
                              char * e, size_t es) {
    if (!out) return false;
    *out = nullptr;
    ane_weight_stream_t * inner = nullptr;
    if (!ane_weight_stream_open(p, &inner, e, es)) return false;
    auto * s = new llama_weight_stream_t();
    s->inner = inner;
    *out = s;
    return true;
}
void llama_weight_stream_close(llama_weight_stream_t * s) {
    if (!s) return;
    ane_weight_stream_close(s->inner);
    delete s;
}
int64_t llama_weight_stream_layer(llama_weight_stream_t * s, int32_t l,
                                  void * d, size_t n) {
    if (!s || !s->inner) return -1;
    return ane_weight_stream_layer(s->inner, l, d, n);
}
uint32_t llama_weight_stream_n_block_tensors(const llama_weight_stream_t * s, int32_t l) {
    if (!s || !s->inner) return 0;
    return ane_weight_stream_n_block_tensors(s->inner, l);
}
bool llama_weight_stream_block_tensor_info(const llama_weight_stream_t * s, int32_t l,
                                           uint32_t i, const char ** n, size_t * z,
                                           uint32_t * d, uint64_t * sh) {
    if (!s || !s->inner) return false;
    return ane_weight_stream_block_tensor_info(s->inner, l, i, n, z, d, sh);
}
int64_t llama_weight_stream_block_tensor(llama_weight_stream_t * s, int32_t l,
                                         uint32_t i, void * d, size_t n) {
    if (!s || !s->inner) return -1;
    return ane_weight_stream_block_tensor(s->inner, l, i, d, n);
}
int64_t llama_weight_stream_expert_slice(llama_weight_stream_t * s, int32_t l,
                                         uint32_t ti, int32_t ei,
                                         void * d, size_t n) {
    if (!s || !s->inner) return -1;
    return ane_weight_stream_expert_slice(s->inner, l, ti, ei, d, n);
}
size_t llama_weight_stream_file_size(const llama_weight_stream_t * s) {
    if (!s || !s->inner) return 0;
    return ane_weight_stream_file_size(s->inner);
}
size_t llama_weight_stream_layer_bytes(const llama_weight_stream_t * s, int32_t l) {
    if (!s || !s->inner) return 0;
    const uint32_t n = ane_weight_stream_n_block_tensors(s->inner, l);
    if (n == 0) return 0;
    size_t total = 0;
    for (uint32_t i = 0; i < n; ++i) {
        size_t sz = 0;
        if (!ane_weight_stream_block_tensor_info(s->inner, l, i, nullptr, &sz, nullptr, nullptr)) return 0;
        total += sz;
    }
    return total;
}
llama_weight_stream_prefetch_t * llama_weight_stream_prefetch_async(
        llama_weight_stream_t * s, int32_t l, void * d, size_t n) {
    if (!s || !s->inner || !d) return nullptr;
    auto * pre = new llama_weight_stream_prefetch_t();
    // Capture s->inner + layer + dst + size. The inner stream is
    // thread-safe for concurrent reads (mmap + map only reads the
    // header map). The sync path holds no lock; we rely on the
    // fact that stream_layer only reads the mmap.
    ane_weight_stream_t * inner = s->inner;
    pre->fut = std::async(std::launch::async, [inner, l, d, n]() -> int64_t {
        return ane_weight_stream_layer(inner, l, d, n);
    });
    return pre;
}
int64_t llama_weight_stream_prefetch_wait(llama_weight_stream_prefetch_t * p) {
    if (!p) return -1;
    int64_t r = -1;
    try { r = p->fut.get(); } catch (...) { r = -1; }
    delete p;
    return r;
}
void llama_weight_stream_prefetch_free(llama_weight_stream_prefetch_t * p) {
    if (!p) return;
    // Cancel-safe: block on the future so the background memcpy completes
    // before its dst buffer can be reused or freed. This is wait-and-discard
    // (the memcpy is not preempted, but it does not outlive its dst), which
    // eliminates the detach-and-leak race the original stub admitted. Used by
    // llama_weight_pool_prefetch_cancel on decode->prefill transitions.
    try { (void) p->fut.get(); } catch (...) {}
    delete p;
}

#else // !APPLE || !GGML_USE_ANE — stub

#include <cstdio>

struct llama_weight_stream_t { int dummy; };
struct llama_weight_stream_prefetch { int dummy; };

bool llama_weight_stream_open(const char *, llama_weight_stream_t ** out,
                              char * e, size_t es) {
    if (out) *out = nullptr;
    if (e && es) std::snprintf(e, es, "weight stream requires Apple GGML_USE_ANE build");
    return false;
}
void llama_weight_stream_close(llama_weight_stream_t * s) { delete s; }
int64_t llama_weight_stream_layer(llama_weight_stream_t *, int32_t, void *, size_t) { return -1; }
uint32_t llama_weight_stream_n_block_tensors(const llama_weight_stream_t *, int32_t) { return 0; }
bool llama_weight_stream_block_tensor_info(const llama_weight_stream_t *, int32_t, uint32_t,
                                           const char **, size_t *, uint32_t *, uint64_t *) { return false; }
int64_t llama_weight_stream_block_tensor(llama_weight_stream_t *, int32_t, uint32_t, void *, size_t) { return -1; }
int64_t llama_weight_stream_expert_slice(llama_weight_stream_t *, int32_t, uint32_t, int32_t, void *, size_t) { return -1; }
size_t llama_weight_stream_file_size(const llama_weight_stream_t *) { return 0; }
size_t llama_weight_stream_layer_bytes(const llama_weight_stream_t *, int32_t) { return 0; }
llama_weight_stream_prefetch_t * llama_weight_stream_prefetch_async(llama_weight_stream_t *, int32_t, void *, size_t) { return nullptr; }
int64_t llama_weight_stream_prefetch_wait(llama_weight_stream_prefetch_t * p) { delete p; return -1; }
void    llama_weight_stream_prefetch_free(llama_weight_stream_prefetch_t * p) { delete p; }

#endif
