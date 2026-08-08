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
size_t   llama_weight_stream_file_size(const llama_weight_stream_t * stream);

#ifdef __cplusplus
}
#endif
