// ggml-ane: Apple Neural Engine backend (Core ML public path).
//
// Backend registration + IOSurface-backed buffer type (slice 1) plus op
// dispatch and graph compute (slice 2). Composite transformer ops whose
// decompositions live in pre-compiled .mlmodelc bundles are routed to Core
// ML; simple element-wise native ops also have a host-mapped fallback path
// so the backend is exercisable without a bundle bound.

#pragma once

#include "ggml.h"
#include "ggml-backend.h"
#include "gguf_weight_stream.h"

#include <stddef.h>
#include <stdbool.h>

struct ggml_tensor;
struct ggml_cgraph;
struct ggml_backend_ane_program;

#ifdef __cplusplus
extern "C" {
#endif

// Registry entry exposed to ggml-backend-reg.cpp. Returns the same singleton
// reg on every call; resolves to nullptr on non-Apple-Silicon builds.
GGML_BACKEND_API ggml_backend_reg_t ggml_backend_ane_reg(void);

// True if backend was created by the ANE registry. Mirrors
// ggml_backend_is_metal so callers can identify ANE backends at runtime.
GGML_BACKEND_API bool ggml_backend_is_ane(ggml_backend_t backend);

// Load a pre-compiled Core ML program directory (.mlmodelc) and bind it to
// the ANE backend device. The bundle supplies the composite-op decompositions
// (RMS norm, RoPE, SDPA, TILE640 dequant) and the matmul kernels; until a
// program is bound the backend only accepts simple element-wise native ops.
//
// `function_name` selects a single entry point from a multifunction bundle
// (nullptr/"" loads the default function).
//
// Returns an opaque program handle (refcounted) or nullptr on load/warmup
// failure. The handle is independent of any specific ggml_backend_t; attach
// it to an ANE backend with ggml_backend_ane_set_program.
GGML_BACKEND_API struct ggml_backend_ane_program * ggml_backend_ane_program_load_from_dir(
        const char * mlmodelc_dir,
        const char * function_name);

GGML_BACKEND_API void ggml_backend_ane_program_free(
        struct ggml_backend_ane_program * program);

// Phase 2 test-only: construct a minimal program with the
// streaming fields initialized but no .mlmodelc loaded.
// The returned program is only useful for the streaming
// helpers (refresh, lookup, parse_layer); the dispatch
// path will refuse because the Core ML model is absent.
GGML_BACKEND_API struct ggml_backend_ane_program *
ggml_backend_ane_program_create_empty(void);

// Bind a loaded program to a specific backend instance. Pass nullptr to
// detach. Returns true on success.
GGML_BACKEND_API bool ggml_backend_ane_set_program(
        ggml_backend_t backend,
        struct ggml_backend_ane_program * program);

// Test instrumentation for the TILE640_MATMUL inner-dim tiling path.
// The counter increments once per ANE sub-matmul dispatched (i.e. once
// per tile in the tiled path, once per op in the non-tiled path). The
// reset zeroes the counter. Used by tests/test-ane-tile640-matmul.cpp
// to assert the tile-vs-no-tile dispatch policy (4 dispatches for the
// 4096x4096 case under the 4096-threshold / 1024-tile-size constants).
GGML_BACKEND_API uint64_t ggml_backend_ane_tile640_dispatch_count(void);
GGML_BACKEND_API void ggml_backend_ane_tile640_dispatch_count_reset(void);

// Tiling policy constants (also exposed for tests / future tuning).
// The dispatch splits the inner-dim into tiles of kTile640InnerDimTileSize
// when in_dim >= kTile640InnerDimThreshold. Both knobs are at the top
// of the TILE640_MATMUL dispatch case in ggml-ane.mm.
GGML_BACKEND_API int64_t ggml_backend_ane_tile640_threshold(void);
GGML_BACKEND_API int64_t ggml_backend_ane_tile640_tile_size(void);

// Lock-free data plane: a cross-backend IOSurface-backed buffer.
//
// Allocates an IOSurface that the CPU, Metal, and ANE backends can all
// read and write without copies. This is the data-plane primitive for
// the cross-backend lock-free dispatch (per the prism-engine
// SharedEventContract / Arena pattern, mapped to llama.cpp / ggml).
//
//   bytes: minimum byte count. The actual allocation is rounded up to
//          the ANE-mandated 16 KB page boundary and clamped to the
//          64 KB IOSurface minimum (Orion #4).
//
// The returned buffer's `get_base()` returns the locked CVPixelBuffer
// base address (CPU view). The Metal view is exposed via
// ggml_backend_ane_iosurface_buffer_get_mtl_buffer (lazily created on
// first access; cached for the buffer's lifetime). The ANE view is
// the raw IOSurfaceRef via ggml_backend_ane_iosurface_buffer_get_iosurface.
//
// Returns nullptr on allocation failure. The caller owns the buffer
// and must free it via ggml_backend_buffer_free.
GGML_BACKEND_API ggml_backend_buffer_t ggml_backend_ane_iosurface_buffer_alloc(
        size_t bytes);

// The buffer type behind ggml_backend_ane_iosurface_buffer_alloc. Exposed
// so the CPU, BLAS, Metal, and ANE backends can advertise the type from
// their supports_buft, letting ggml_backend_sched place tensors in it
// without inserting cross-backend copies. The type is process-global and
// not owned by any single device (buft->device == nullptr).
GGML_BACKEND_API ggml_backend_buffer_type_t ggml_backend_ane_iosurface_buffer_type(void);

// Returns true if the buffer is an ANE cross-backend IOSurface buffer.
GGML_BACKEND_API bool ggml_backend_ane_iosurface_buffer_check(
        ggml_backend_buffer_t buffer);

// Get the raw IOSurfaceRef (ANE view) for the buffer. The IOSurface
// is locked for the buffer's lifetime; the returned ref is retained
// by the buffer. Returns NULL if the buffer is not an ANE
// IOSurface-backed buffer.
//
// The IOSurfaceRef can be wrapped as a _ANEIOSurfaceObject (the ANE
// private framework's IOSurface handle) for direct ANE dispatch.
GGML_BACKEND_API void * ggml_backend_ane_iosurface_buffer_get_iosurface(
        ggml_backend_buffer_t buffer);

// Wrap the IOSurface as an MTLBuffer (Metal view). Lazily creates the
// MTLBuffer on first call and caches it. The MTLBuffer shares memory
// with the IOSurface (no copy). The returned MTLBuffer is owned by the
// buffer (released on free). Returns NULL on failure or if the buffer
// is not an ANE IOSurface buffer.
GGML_BACKEND_API void * ggml_backend_ane_iosurface_buffer_get_mtl_buffer(
        ggml_backend_buffer_t buffer);

// Phase 2 (iPhone demo, gguf -> IOSurface weight streaming).
//
// The per-program weight stream lets the TILE640_MATMUL dispatch
// read the layer's packed T640_3D weight + meta tensors from a
// mmap'd unified GGUF instead of from the op's source ggml_tensor
// pointers. The per-program cache keeps the current layer's bytes
// in CPU memory across consecutive dispatches; the cache is
// refreshed only on layer-index change (decode is M=1 per layer,
// so the same layer fires N times before the index advances).
//
// ggml_backend_ane_program_set_weight_stream:
//   Attach a stream to a program. The stream is held for the
//   program's lifetime; the runtime does NOT own it (caller
//   closes it via ane_weight_stream_close after the program is
//   freed). Pass NULL to detach (the dispatch falls back to the
//   legacy op->src[0..5] path).
//
// ggml_backend_ane_program_last_streamed_layer:
//   Diagnostic. Returns the most-recently-streamed layer index,
//   or -1 if no stream is attached or no layer has been streamed
//   yet.
GGML_BACKEND_API void ggml_backend_ane_program_set_weight_stream(
        struct ggml_backend_ane_program * program,
        struct ane_weight_stream_t * stream);
GGML_BACKEND_API int32_t ggml_backend_ane_program_last_streamed_layer(
        const struct ggml_backend_ane_program * program);

// Phase 2 helpers (also exposed for tests):
//
// ggml_backend_ane_stream_parse_layer:
//   Parse the layer index from a tensor name in the
//   `blk.L.<family>[.weight[_meta]]` convention. Returns
//   the layer index (>= 0) on success, or -1 if the name
//   doesn't match the convention.
//
// ggml_backend_ane_stream_refresh_program:
//   Refresh the per-program layer cache for `layer_idx`.
//   Reads the layer's tensors from the program's stream
//   into the program's CPU cache and rebuilds the per-
//   tensor lookup. Returns true on success; false on
//   failure (reason logged). Refreshing for a layer
//   that's already cached is a no-op (the caller is
//   expected to skip when the layer hasn't changed).
//
// ggml_backend_ane_stream_program_lookup:
//   Look up a streamed tensor by name in the program's
//   cache. Returns true on hit (sets *base_out to the
//   cache pointer and *size_out to the byte count);
//   false on miss.
GGML_BACKEND_API int32_t ggml_backend_ane_stream_parse_layer(
        const char * name);
GGML_BACKEND_API bool ggml_backend_ane_stream_refresh_program(
        struct ggml_backend_ane_program * program,
        int32_t layer_idx);
GGML_BACKEND_API bool ggml_backend_ane_stream_program_lookup(
        const struct ggml_backend_ane_program * program,
        const char * name,
        const void ** base_out,
        size_t * size_out);

#ifdef __cplusplus
}
#endif
