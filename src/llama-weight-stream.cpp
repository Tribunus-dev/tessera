// llama-weight-stream.cpp — generic wrapper over gguf_weight_stream
//
// On Apple/GGML_USE_ANE forwards to ane_weight_stream_*.
// Elsewhere: stub that reports "not supported".

#include "llama-weight-stream.h"

#if defined(__APPLE__) && defined(GGML_USE_ANE)
#include "gguf_weight_stream.h"

struct llama_weight_stream_t {
    ane_weight_stream_t * inner = nullptr;
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
size_t llama_weight_stream_file_size(const llama_weight_stream_t * s) {
    if (!s || !s->inner) return 0;
    return ane_weight_stream_file_size(s->inner);
}

#else // !APPLE || !GGML_USE_ANE — stub

#include <cstdio>

struct llama_weight_stream_t { int dummy; };

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
size_t llama_weight_stream_file_size(const llama_weight_stream_t *) { return 0; }

#endif
