// llama-weight-pool.h - 2-slot IOSurface weight pool for per-layer residency
//
// The 23 GiB unified GGUF's FFN weights (blk.L.ffn_gate/up/down, ~450 MiB per
// layer x 48 layers) cannot be bulk-resident in MTL0: the single alloc trips
// recommendedMaxWorkingSetSize (12.4 GiB on M1). This pool keeps two IOSurface
// slots, each sized to the largest layer, and aliases every FFN tensor's
// ->data into one of them. The Metal encoder paces compute one layer at a
// time (Slice 4.2a graph_compute_streamed), refilling the active slot from
// the mmap'd GGUF before each layer's MUL_MAT.
//
// Phase 1 (this file): synchronous fill. ensure_layer blocks on a memcpy
// from the mmap into slot[L%2]. Correctness only - fixes the OOM, no overlap.
// Phase 2 (to follow): a background fill thread keeps the next layer warm
// while the GPU computes the current one.
//
// Layout: the streamer writes a layer's tensors in name-sorted order
// (ggml-ane.mm ane_weight_stream_program_refresh). We mirror that order so a
// single llama_weight_stream_layer call fills all FFN tensors of a layer in
// one contiguous memcpy. Per-tensor offsets within a layer are the same for
// every layer.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ggml_tensor;
struct llama_weight_stream_t;

typedef struct llama_weight_pool llama_weight_pool_t;

// Open the pool over `gguf_path`. Computes max_layer_bytes across all layers,
// allocates two IOSurface slots (or malloc fallback), builds the per-tensor
// layer layout from the stream. Returns false and fills err on failure.
// n_layer bounds the layer index; layers >= n_layer are rejected.
bool llama_weight_pool_open(const char * gguf_path,
                            int32_t n_layer,
                            llama_weight_pool_t ** pool_out,
                            char * err_out, size_t err_out_size);

// Re-point each FFN weight tensor's ->data into the pool's slots.
// For each layer L in [0, n_layer): finds the tensor named base_name (e.g.
// "blk.L.ffn_gate.weight"), sets ->buffer = slot_buf[L%2] and
// ->data = slot_base[L%2] + matching per-tensor offset. Does not allocate.
// Returns the number of tensors aliased, or -1 on a hard error.
//
// alias_fn is called by the pool for each (tensor, layer, slot_index, base,
// offset) tuple it derives; the caller's callback performs the actual
// ->buffer/->data assignment on its own model-layer struct. This keeps the
// pool independent of the llama_layer definition.
struct llama_weight_pool_alias_info {
    const char * tensor_name;   // full GGUF name, e.g. "blk.0.ffn_gate.weight"
    int32_t      layer;
    int          slot_index;    // 0 or 1
    void *       slot_base;
    size_t       offset;        // within slot
    size_t       size;          // tensor size in bytes
    // The ggml_backend_buffer_t for this slot. May be NULL when the pool
    // fell back to malloc (non-IOSurface). When non-NULL, assigning it to
    // tensor->buffer makes the tensor pass ggml_backend_ane_iosurface_buffer_check,
    // which the Metal encoder uses to identify streamable FFN weights.
    struct ggml_backend_buffer * slot_buffer;
};
typedef bool (*llama_weight_pool_alias_fn)(
        struct llama_weight_pool_alias_info info,
        void * user_data);

int llama_weight_pool_alias_tensors(llama_weight_pool_t * pool,
                                    llama_weight_pool_alias_fn alias_fn,
                                    void * user_data);

// Ensure layer L's bytes are in slot[L%2]. Phase 1: blocking memcpy from the
// mmap. Phase 2: non-blocking if already ready, else waits on the fill
// thread. Called by the Metal encoder at each layer transition. Returns the
// slot_index (0/1) holding L's data, or -1 on failure.
//
// Before refilling a slot the GPU may still be reading (slot reuse across
// layers), ensure_layer calls the sync callback registered via
// llama_weight_pool_set_sync_fn. Phase 1 uses a coarse full-GPU sync; Phase 2
// will replace it with a per-layer fence wait.
int llama_weight_pool_ensure_layer(llama_weight_pool_t * pool, int32_t layer);

// Phase 2: poke the fill thread to start prefetching layer L (typically the
// next layer). Non-blocking: returns immediately after setting fill_needed.
// The fill thread fills slot[L%2] in the background while the GPU computes
// the current layer. No-op when the fill thread isn't running (Phase 1).
void llama_weight_pool_poke_prefetch(llama_weight_pool_t * pool, int32_t layer);

// MoE: sparse-fill the slot with only the active expert slices for the named
// 3D tensor. expert_ids is the list of expert IDs the MUL_MAT_ID will read
// (from the router's top-k). The pool memcpy's only those slices from the
// mmap into slot[L%2] at their natural per-expert offset. Inactive slices
// retain stale content but are never read by the kernel. Returns 0 on
// success, -1 on failure.
int llama_weight_pool_ensure_experts(llama_weight_pool_t * pool,
                                     int32_t layer,
                                     const char * tensor_suffix,  // e.g. "ffn_gate_exps.weight"
                                     const int32_t * expert_ids,
                                     int32_t n_experts_used);

// Phase MoE-2: poke the fill thread to prefetch expert slices for the next
// chunk's predicted routing. The hint is derived from the current chunk's
// expert IDs (temporal correlation in routing). Non-blocking. No-op when
// the fill thread isn't running.
void llama_weight_pool_poke_expert_prefetch(llama_weight_pool_t * pool,
                                            int32_t layer,
                                            const char * tensor_suffix,
                                            const int32_t * expert_ids,
                                            int32_t n_experts_used);

// Register a GPU sync callback. Called before refilling a slot the GPU may
// still be reading (slot reuse across layers L and L+2). The callback waits
// for the GPU to finish consuming the layer that previously occupied the
// slot. user_data is opaque to the pool (typically the MTLSharedEvent).
// wait_for_layer is the layer whose GPU completion the callback should wait on.
typedef void (*llama_weight_pool_sync_fn)(void * user_data, int32_t wait_for_layer);
void llama_weight_pool_set_sync_fn(llama_weight_pool_t * pool,
                                   void * user_data,
                                   llama_weight_pool_sync_fn sync_fn);

// Phase 2: start the background fill thread. No-op in Phase 1 (the pool
// fills synchronously in ensure_layer).
void llama_weight_pool_start(llama_weight_pool_t * pool);

// Release the fill thread, slots, and stream. Safe to call once after the
// last graph_compute.
void llama_weight_pool_close(llama_weight_pool_t * pool);

// Accessors for logging and buffer-lifetime management.
size_t   llama_weight_pool_slot_bytes(const llama_weight_pool_t * pool);
bool     llama_weight_pool_uses_iosurface(const llama_weight_pool_t * pool);
// True if a weight pool is active on the model (FFN tensors are streamed
// from 2 IOSurface slots rather than bulk-resident). Used by tools (imatrix)
// to report streaming status without owning the pool.
bool     llama_model_weight_pool_enabled(const struct llama_model * model);
// The slot's ggml_backend_buffer_t (index 0 or 1). The pool retains ownership;
// callers must NOT free. Returns NULL on the malloc fallback or invalid index.
struct ggml_backend_buffer * llama_weight_pool_slot_buffer(
        const llama_weight_pool_t * pool, int slot_index);

#ifdef __cplusplus
}
#endif
