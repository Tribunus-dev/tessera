// llama-weight-stream.h — generic per-layer GGUF -> device slot streamer
//
// Promoted from ggml/src/ggml-ane/gguf_weight_stream.h (Phase 2 slices 1-3).
// The ANE slice proved mmap + per-layer memcpy into an IOSurface slot
// with last_streamed_layer caching. That same pattern now drives the
// unified heterog pipeline's residency fix: one mmap'd 23 GiB unified GGUF
// -> two ~450 MiB IOSurface slots, prefetch(L+1) overlaps compute(L).
//
// Destinations: ANE_IOSURFACE (T640 host-dequant fp16, FUSED=DEQUANT),
// MTL0 (BF16 FFN gate/up/down), CPU/BLAS (attn/norm/rope/observer).
// The backend buffer type that owns the slot is chosen by the caller;
// this module only streams bytes from the mmap into the caller's buffer.
//
// On Apple with GGML_USE_ANE the implementation forwards to
// ane_weight_stream_* (ggml-ane/gguf_weight_stream.h). On other
// platforms every entry point returns failure and the caller falls
// back to the resident-weight path.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct llama_weight_stream_t llama_weight_stream_t;
// Opaque async prefetch handle. Returned by llama_weight_stream_prefetch_async,
// consumed by llama_weight_stream_prefetch_wait (which frees it).
typedef struct llama_weight_stream_prefetch llama_weight_stream_prefetch_t;

bool     llama_weight_stream_open(const char * gguf_path,
                                  llama_weight_stream_t ** stream_out,
                                  char * error_out, size_t error_out_size);
void     llama_weight_stream_close(llama_weight_stream_t * stream);
int64_t  llama_weight_stream_layer(llama_weight_stream_t * stream,
                                   int32_t layer_idx, void * dst, size_t dst_size);
uint32_t llama_weight_stream_n_block_tensors(const llama_weight_stream_t * stream,
                                             int32_t layer_idx);
bool     llama_weight_stream_block_tensor_info(const llama_weight_stream_t * stream,
                                               int32_t layer_idx, uint32_t index,
                                               const char ** name_out,
                                               size_t * size_bytes_out,
                                               uint32_t * n_dim_out,
                                               uint64_t * shape_out);
int64_t  llama_weight_stream_block_tensor(llama_weight_stream_t * stream,
                                          int32_t layer_idx, uint32_t index,
                                          void * dst, size_t dst_size);

// Copy one expert slice of a 3D tensor from the mmap into dst. For a tensor
// "blk.L.ffn_gate_exps.weight" with shape [in_dim, out_dim, n_expert], copies
// expert expert_idx's slice (size_bytes / n_expert bytes) into dst. Returns
// bytes copied or -1 on failure. The caller must size dst to per_expert_bytes.
int64_t  llama_weight_stream_expert_slice(llama_weight_stream_t * stream,
                                          int32_t layer, uint32_t tensor_index,
                                          int32_t expert_idx,
                                          void * dst, size_t dst_size);

size_t   llama_weight_stream_file_size(const llama_weight_stream_t * stream);

// Async prefetch: memcpy the layer's bytes from the mmap into `dst`
// on a background thread. The caller owns `dst` (typically an IOSurface
// slot) and must keep it alive until wait. Returns NULL on failure
// (reason logged; caller should fall back to sync). The returned handle
// must be consumed exactly once via llama_weight_stream_prefetch_wait
// (which blocks, returns bytes on success or -1 on failure, and frees
// the handle). If the caller wants to cancel, call
// llama_weight_stream_prefetch_free (non-blocking, frees).
llama_weight_stream_prefetch_t * llama_weight_stream_prefetch_async(
        llama_weight_stream_t * stream, int32_t layer_idx,
        void * dst, size_t dst_size);
int64_t  llama_weight_stream_prefetch_wait(llama_weight_stream_prefetch_t * prefetch);
void     llama_weight_stream_prefetch_free(llama_weight_stream_prefetch_t * prefetch);

// Helper: total bytes for a layer (sum of blk.L.* tensors). Returns 0
// if the layer has no tensors or the stream is NULL. Useful for sizing
// the IOSurface slot before the first prefetch.
size_t   llama_weight_stream_layer_bytes(const llama_weight_stream_t * stream,
                                         int32_t layer_idx);

#ifdef __cplusplus
}
#endif
