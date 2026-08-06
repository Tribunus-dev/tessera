// gguf_weight_stream.h — Phase 2 ANE runtime: per-layer GGUF -> IOSurface
// weight streamer for the gemma 4 12B iPhone demo.
//
// This header is the public surface of the per-layer weight
// streamer that drives the multifunction .mlmodelc dispatch
// from a mmap'd unified GGUF. See
// docs/tessera-ane-ios-demo-design.md Phase 2 for the design
// and docs/ane-backend-deep-study.md Part 6.10 (regime
// router) for the dispatch policy this plugs into.
//
// Lifecycle:
//
//     ane_weight_stream_t * stream = NULL;
//     if (!ane_weight_stream_open(gguf_path, &stream, err, sizeof(err))) {
//         // log err
//     }
//     // For each dispatch, when the layer index changes:
//     ane_weight_stream_layer(stream, layer_idx, iosurface_slot, slot_size);
//     // ... ANE dispatch ...
//     ane_weight_stream_close(stream);
//
// In Phase 2 v1, ane_weight_stream_layer is a synchronous,
// single-threaded call: it reads the layer's tensors out of
// the mmap'd GGUF and writes them into the caller-provided
// IOSurface slot. The dispatch in ggml-ane.mm consults a
// per-program cache (last_streamed_layer) and skips the
// call when the layer hasn't changed (the decode hot path,
// M=1, reuses the same layer N times before advancing).
//
// Async prefetch (next-layer pre-stream while the current
// layer dispatches on the ANE) is the Slice 4 follow-on.
// It requires double-buffered weight slots in the manifest
// and a background thread that watches the layer index;
// that work is tracked separately.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle. Allocated by ane_weight_stream_open, freed by
// ane_weight_stream_close.
typedef struct ane_weight_stream_t ane_weight_stream_t;

// Open a unified GGUF for streaming. The file is mmapped
// read-only; the mmap is held for the stream's lifetime.
// The header is parsed once at open and held in memory as
// a sorted map of tensor name -> (offset, n_bytes).
//
// On failure, fills `error_out` (if non-null and
// `error_out_size > 0`) with a NUL-terminated human-readable
// reason. The caller owns the error buffer; pass NULL/0 to
// skip the error string (failures are still signalled by
// the bool return).
//
// The GGUF must conform to the v3 spec (magic == 0x46554747,
// version == 3) which is the format the tessera conversion
// tool emits. Earlier versions are rejected.
bool ane_weight_stream_open(const char * gguf_path,
                            ane_weight_stream_t ** stream_out,
                            char * error_out,
                            size_t error_out_size);

// Close a stream and unmap the file. The stream pointer is
// invalidated; callers must not use it after close. Safe to
// call with a NULL pointer (no-op).
void ane_weight_stream_close(ane_weight_stream_t * stream);

// Stream layer `layer_idx`'s weight tensors into `dst_buffer`.
// `dst_buffer` is caller-owned (typically the IOSurface-pinned
// weight slot's base pointer), at least `dst_size_bytes`.
//
// Returns the number of bytes actually written on success, or
// -1 on failure (reason logged via the ggml log). Failure
// modes include: unknown layer index (no `blk.L.*` tensors
// in the GGUF), layer is larger than the destination, or the
// mmap is missing the tensor's data region.
//
// Slice 1: stubbed; always returns -1 with a "not implemented"
// log. Slice 2 implements the read path; Slice 3 wires it
// into the dispatch.
int64_t ane_weight_stream_layer(ane_weight_stream_t * stream,
                                int32_t layer_idx,
                                void * dst_buffer,
                                size_t dst_size_bytes);

// Diagnostic: file size in bytes of the mmapped GGUF.
// Returns 0 if the stream is NULL.
size_t ane_weight_stream_file_size(const ane_weight_stream_t * stream);

// Diagnostic: number of `blk.L.*` tensors registered at open.
// Useful for tests asserting the streamer found the expected
// per-layer tensor count (e.g. 16 tensors per transformer
// layer for the gemma 4 12B trunk: attn_q/k/v/output,
// ffn_gate/up/down, attn_norm/ffn_norm + per-layer alpha +
// per-row page_scales + per-row lane_scales + per-row
// outlier_row_offsets + per-row outlier_cols +
// per-row outlier_vals). Returns 0 if stream is NULL.
uint32_t ane_weight_stream_n_block_tensors(const ane_weight_stream_t * stream,
                                           int32_t layer_idx);

#ifdef __cplusplus
}
#endif
