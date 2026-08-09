// llama-weight-pool.cpp - 2-slot IOSurface weight pool implementation
//
// Phase 1 (synchronous fill): ensure_layer blocks on the memcpy.
// Phase 2 (background fill thread): a fill thread runs ahead of the encoder,
// refilling slot[(L+1)%2] while the GPU computes layer L. ensure_layer
// returns immediately when the fill thread has already filled the slot.

#include "llama-weight-pool.h"
#include "llama-model.h"
#include "llama-weight-stream.h"

#include "ggml-ane.h"
#include "ggml-backend.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

#if defined(__APPLE__) && defined(GGML_USE_ANE)
#define LLAMA_WEIGHT_POOL_SUPPORTED 1
#else
#define LLAMA_WEIGHT_POOL_SUPPORTED 0
#endif

// One entry per tensor in a layer's name-sorted layout. The stream writes
// tensors in this order (ggml-ane.mm:968-978), so offsets are cumulative.
struct pool_tensor_entry {
    std::string suffix;   // e.g. "ffn_down.weight" (after "blk.L.")
    size_t      offset;   // within slot
    size_t      size;
};

struct llama_weight_pool {
    llama_weight_stream_t * stream     = nullptr;
    int32_t                n_layer     = 0;
    size_t                 slot_bytes  = 0;

    ggml_backend_buffer_t  slot_buf[2] = {nullptr, nullptr};
    void *                 slot_base[2] = {nullptr, nullptr};
    bool                   uses_iosurface = false;

    // Last layer filled into each slot, or -1 if stale. ensure_layer skips
    // the memcpy when slot[L%2] already holds L (decode M=1 hits this).
    // Atomic: read unlocked in ensure_layer's fast path, written under
    // fill_mtx by the fill thread.
    std::atomic<int32_t>   slot_layer[2] = {ATOMIC_VAR_INIT(-1), ATOMIC_VAR_INIT(-1)};

    // GPU sync callback. Called before refilling a slot the GPU may still be
    // reading (slot reuse across layers L and L+2). Phase 2 replaces the
    // coarse sync with a shared-event wait.
    void *                 sync_ud  = nullptr;
    llama_weight_pool_sync_fn sync_fn = nullptr;

    // Per-tensor layout shared across all layers (built from layer 0).
    std::vector<pool_tensor_entry> layout;

    // Phase 2: background fill thread state.
    std::thread            fill_thread;
    std::mutex             fill_mtx;
    std::condition_variable fill_cv;       // signals: fill_needed changed
    std::condition_variable ensure_cv;     // signals: fill_ready changed
    int32_t                fill_needed = -1; // protected by fill_mtx
    std::atomic<int32_t>   fill_ready  = {-1}; // highest layer fully in its slot
    std::atomic<bool>      fill_shutdown = {false};
    std::atomic<bool>      fill_running  = {false};

    // Host-driven prefetch claim. When the Metal encoder issues an explicit
    // prefetch_async for layer L, it sets host_claim_layer = L so the fill
    // thread skips L in its dense loop (the two paths never write the same
    // slot concurrently). Cleared to -1 after prefetch_wait publishes
    // slot_layer[L%2] = L. Atomic CAS claims the layer; no mutex needed
    // because slot_layer is already atomic with release/acquire ordering.
    std::atomic<int32_t>   host_claim_layer = {-1};

    // Phase MoE-2: per-layer expert ID history from the previous chunk's
    // routing. The fill thread uses this to pre-fill expert slices before
    // the encoder asks for them. Key: layer * 4 + tensor_suffix_hash.
    // Value: the expert IDs that layer's tensor used last chunk.
    struct moe_hint {
        int32_t layer;
        std::string suffix;
        std::vector<int32_t> expert_ids;
        bool filled = false; // has the fill thread processed this hint?
    };
    std::vector<moe_hint>  moe_hints;
    std::atomic<bool>      moe_hints_ready {false};
};

// Sensitive MoE tensors that must NOT be streamed (stay resident on MTL0).
// The router (ffn_gate_inp) is the MoE analogue of attn_output — quantizing
// or streaming it collapses routing fidelity. exp_probs_b is the router bias.
// gate_tid2eid is the DeepSeek-V4 hash token->expert map.
static bool is_sensitive_moe_tensor(const std::string & suffix) {
    if (suffix.find("ffn_gate_inp") != std::string::npos) return true;
    if (suffix.find("exp_probs_b")  != std::string::npos) return true;
    if (suffix.find("ffn_gate_tid2eid") != std::string::npos) return true;
    return false;
}

// A tensor is streamable if its suffix contains "ffn_" (covers dense
// ffn_gate/up/down and MoE ffn_*_exps) AND it is not a sensitive MoE tensor.
// Attention, norms, and embeddings are not streamable — they stay resident.
static bool is_streamable_ffn(const std::string & suffix) {
    if (suffix.find("ffn_") == std::string::npos) return false;
    if (is_sensitive_moe_tensor(suffix)) return false;
    return true;
}

// Build the layer layout from the streamer's block_tensor_info for layer 0.
// Only streamable FFN tensors are included; attention/norms/sensitive-MoE
// tensors are excluded so the slot is sized for FFN weights only.
// The layout (suffix -> offset, size) is identical for every layer because
// the streamer uses the same name-sorted order per block.
static bool pool_build_layout(llama_weight_pool_t * pool, char * err, size_t es) {
    const int32_t probe_layer = 0;
    const uint32_t n = llama_weight_stream_n_block_tensors(pool->stream, probe_layer);
    if (n == 0) {
        if (err && es) std::snprintf(err, es, "streamer reports 0 tensors for layer 0");
        return false;
    }
    pool->layout.clear();
    pool->layout.reserve(n);
    size_t cursor = 0;
    for (uint32_t i = 0; i < n; ++i) {
        const char * name = nullptr;
        size_t sz = 0;
        if (!llama_weight_stream_block_tensor_info(pool->stream, probe_layer, i,
                &name, &sz, nullptr, nullptr)) {
            if (err && es) std::snprintf(err, es, "block_tensor_info failed at layer 0 idx %u", i);
            return false;
        }
        std::string suffix = name ? std::string(name) : std::string();
        const std::string prefix = "blk.0.";
        if (suffix.rfind(prefix, 0) == 0) {
            suffix = suffix.substr(prefix.size());
        }
        // Only include streamable FFN tensors in the layout. This keeps the
        // slot sized for FFN weights (dense or MoE expert), not attention.
        if (!is_streamable_ffn(suffix)) continue;
        pool->layout.push_back({suffix, cursor, sz});
        cursor += sz;
    }
    if (pool->layout.empty()) {
        if (err && es) std::snprintf(err, es, "no streamable FFN tensors found in layer 0");
        return false;
    }
    return true;
}

bool llama_weight_pool_open(const char * gguf_path,
                            int32_t n_layer,
                            llama_weight_pool_t ** pool_out,
                            char * err_out, size_t err_out_size) {
    if (!pool_out) return false;
    *pool_out = nullptr;
    if (!gguf_path || n_layer <= 0) {
        if (err_out && err_out_size) std::snprintf(err_out, err_out_size, "invalid args");
        return false;
    }
#if LLAMA_WEIGHT_POOL_SUPPORTED
    llama_weight_stream_t * ws = nullptr;
    char err[512] = {};
    if (!llama_weight_stream_open(gguf_path, &ws, err, sizeof(err)) || !ws) {
        if (err_out && err_out_size) {
            std::snprintf(err_out, err_out_size, "weight_stream_open: %s", err[0] ? err : "failed");
        }
        return false;
    }
    auto * pool = new (std::nothrow) llama_weight_pool_t();
    if (!pool) {
        llama_weight_stream_close(ws);
        if (err_out && err_out_size) std::snprintf(err_out, err_out_size, "pool alloc failed");
        return false;
    }
    pool->stream = ws;
    pool->n_layer = n_layer;

    if (!pool_build_layout(pool, err, sizeof(err))) {
        llama_weight_stream_close(ws);
        delete pool;
        if (err_out && err_out_size) std::snprintf(err_out, err_out_size, "%s", err);
        return false;
    }

    // Slot size = sum of streamable FFN tensor sizes (from the filtered layout).
    // For dense this is gate+up+down; for MoE it includes the 3D expert tensors.
    // All layers have the same layout (same tensor names/shapes per blk.N.*),
    // so the layer-0 layout sum is the slot size for every layer.
    size_t max_bytes = 0;
    for (const auto & e : pool->layout) {
        max_bytes += e.size;
    }
    if (max_bytes == 0) {
        llama_weight_stream_close(ws);
        delete pool;
        if (err_out && err_out_size) std::snprintf(err_out, err_out_size, "max_layer_bytes = 0");
        return false;
    }
    pool->slot_bytes = max_bytes;

    // Allocate two IOSurface slots. The Metal encoder zero-copies these via
    // newBufferWithBytesNoCopy (ggml-ane.mm:3527), so the data plane stays
    // shared between CPU refill and GPU MUL_MAT. IOSurface alloc failure is
    // a hard error: there is no viable fallback (bulk residency OOMs, and
    // malloc slots cannot be zero-copied to Metal). The caller falls back
    // to the bulk load path by treating open failure as "pool disabled".
    ggml_backend_buffer_t ba = ggml_backend_ane_iosurface_buffer_alloc(max_bytes);
    ggml_backend_buffer_t bb = ggml_backend_ane_iosurface_buffer_alloc(max_bytes);
    if (!ba || !bb) {
        if (ba) ggml_backend_buffer_free(ba);
        if (bb) ggml_backend_buffer_free(bb);
        llama_weight_stream_close(ws);
        delete pool;
        if (err_out && err_out_size) {
            std::snprintf(err_out, err_out_size, "IOSurface slot alloc failed (%zu bytes)", max_bytes);
        }
        return false;
    }
    pool->slot_buf[0] = ba;
    pool->slot_buf[1] = bb;
    pool->slot_base[0] = ggml_backend_buffer_get_base(ba);
    pool->slot_base[1] = ggml_backend_buffer_get_base(bb);
    pool->uses_iosurface = true;
    pool->slot_layer[0] = -1;
    pool->slot_layer[1] = -1;
    *pool_out = pool;
    return true;
#else
    if (err_out && err_out_size) {
        std::snprintf(err_out, err_out_size, "weight pool requires Apple GGML_USE_ANE build");
    }
    return false;
#endif
}

// Match a layout entry to a full tensor name. Returns index or -1.
// "ffn_gate.weight" matches "blk.7.ffn_gate.weight".
static int layout_find(const llama_weight_pool_t * pool, const char * tensor_name) {
    if (!tensor_name) return -1;
    const std::string s = tensor_name;
    const size_t dot = s.find('.', 4); // skip "blk."
    if (dot == std::string::npos) return -1;
    const std::string suffix = s.substr(dot + 1);
    for (size_t i = 0; i < pool->layout.size(); ++i) {
        if (pool->layout[i].suffix == suffix) return (int) i;
    }
    return -1;
}

int llama_weight_pool_alias_tensors(llama_weight_pool_t * pool,
                                    llama_weight_pool_alias_fn alias_fn,
                                    void * user_data) {
    if (!pool || !alias_fn) return -1;
    int n_aliased = 0;
    for (int32_t l = 0; l < pool->n_layer; ++l) {
        const int slot = l % 2;
        char name[128];
        for (const auto & e : pool->layout) {
            std::snprintf(name, sizeof(name), "blk.%d.%s", l, e.suffix.c_str());
            llama_weight_pool_alias_info info;
            info.tensor_name = name;
            info.layer       = l;
            info.slot_index  = slot;
            info.slot_base   = pool->slot_base[slot];
            info.slot_buffer = pool->slot_buf[slot]; // always set: open hard-errors on IOSurface alloc failure
            info.offset      = e.offset;
            info.size        = e.size;
            if (alias_fn(info, user_data)) {
                n_aliased++;
            }
        }
    }
    return n_aliased;
}

int llama_weight_pool_ensure_layer(llama_weight_pool_t * pool, int32_t layer) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || layer < 0 || layer >= pool->n_layer) return -1;
    const int slot = layer % 2;

    // Fast path: slot already holds the requested layer (decode M=1 reuse,
    // or the fill thread got here first). Atomic load for thread safety.
    if (pool->slot_layer[slot].load(std::memory_order_acquire) == layer) {
        return slot;
    }

    // Phase 2: if the fill thread is running, wait for it to fill this layer
    // (or up to it). The fill thread updates slot_layer + fill_ready under
    // fill_mtx and notifies ensure_cv.
    if (pool->fill_running.load(std::memory_order_acquire)) {
        std::unique_lock<std::mutex> lk(pool->fill_mtx);
        // Poke the fill thread if it's idling below our needed layer.
        if (pool->fill_needed < layer) {
            pool->fill_needed = layer;
            pool->fill_cv.notify_one();
        }
        // Wait until the fill thread has filled our layer (or the slot_layer
        // array shows it, which the fill thread sets before notifying).
        if (!pool->ensure_cv.wait_for(lk, std::chrono::seconds(30), [&] {
            return pool->slot_layer[slot].load(std::memory_order_relaxed) == layer ||
                   pool->fill_ready.load(std::memory_order_relaxed) >= layer ||
                   pool->fill_shutdown.load(std::memory_order_relaxed);
        })) {
            fprintf(stderr, "weight pool: ensure_layer %d timed out (fill_ready=%d slot_layer[%d]=%d)\n",
                layer, pool->fill_ready.load(), slot, pool->slot_layer[slot].load());
        }
        if (pool->slot_layer[slot].load(std::memory_order_acquire) == layer) {
            return slot;
        }
        // Fall through to synchronous fill if the thread shut down or failed.
    }

    // Phase 1 fallback / Phase 2 synchronous path: fill inline.
    // Slot reuse guard: if this slot holds a prior layer's data, the GPU may
    // still be reading it. Wait for the fence before refill.
    if (pool->slot_layer[slot].load(std::memory_order_acquire) >= 0 && pool->sync_fn) {
        const int32_t prev = pool->slot_layer[slot].load(std::memory_order_acquire);
        pool->sync_fn(pool->sync_ud, prev);
    }
    const int64_t wrote = llama_weight_stream_layer(
            pool->stream, layer, pool->slot_base[slot], pool->slot_bytes);
    if (wrote < 0) {
        return -1;
    }
    pool->slot_layer[slot].store(layer, std::memory_order_release);
    return slot;
#else
    GGML_UNUSED(pool);
    GGML_UNUSED(layer);
    return -1;
#endif
}

void llama_weight_pool_set_sync_fn(llama_weight_pool_t * pool,
                                   void * user_data,
                                   llama_weight_pool_sync_fn sync_fn) {
    if (!pool) return;
    pool->sync_ud = user_data;
    pool->sync_fn = sync_fn;
}

void llama_weight_pool_poke_prefetch(llama_weight_pool_t * pool, int32_t layer) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || !pool->fill_running.load(std::memory_order_acquire) ||
        layer < 0 || layer >= pool->n_layer) return;
    {
        std::lock_guard<std::mutex> lk(pool->fill_mtx);
        if (pool->fill_needed < layer) {
            pool->fill_needed = layer;
        }
    }
    pool->fill_cv.notify_one();
#else
    GGML_UNUSED(pool);
    GGML_UNUSED(layer);
#endif
}

// Host-driven prefetch: claim layer L, guard on the GPU fence for the slot's
// previous occupant, then issue the async memcpy into slot[L%2]. The fill
// thread observes the claim (host_claim_layer) and skips L so the two paths
// never write the same slot concurrently. Returns an opaque handle the caller
// passes to llama_weight_pool_prefetch_wait, or nullptr if the layer is out
// of range or already claimed.
llama_weight_stream_prefetch_t * llama_weight_pool_prefetch_async(
        llama_weight_pool_t * pool, int32_t layer) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || layer < 0 || layer >= pool->n_layer) return nullptr;
    const int slot = layer % 2;
    // Claim the layer so the fill thread skips it. CAS avoids racing a second
    // host prefetch for the same layer.
    int32_t expected = -1;
    if (!pool->host_claim_layer.compare_exchange_strong(expected, layer,
            std::memory_order_acq_rel)) {
        return nullptr; // another host prefetch is in flight
    }
    // Guard: wait for the GPU to finish reading this slot's previous content
    // before issuing the memcpy. Mirrors the fill-thread guard at the dense
    // loop and ensure_layer's synchronous path. The sync callback blocks the
    // host until the MTLSharedEvent for the previous occupant signals.
    if (pool->slot_layer[slot].load(std::memory_order_acquire) >= 0 && pool->sync_fn) {
        const int32_t prev = pool->slot_layer[slot].load(std::memory_order_acquire);
        pool->sync_fn(pool->sync_ud, prev);
    }
    return llama_weight_stream_prefetch_async(
            pool->stream, layer, pool->slot_base[slot], pool->slot_bytes);
#else
    GGML_UNUSED(pool);
    GGML_UNUSED(layer);
    return nullptr;
#endif
}

// Block until the prefetch completes, then publish slot_layer[slot] = layer
// (atomic release) so ensure_layer's fast path hits. Clears the host claim.
// Returns the bytes written, or -1 on failure.
int64_t llama_weight_pool_prefetch_wait(llama_weight_pool_t * pool,
                                        llama_weight_stream_prefetch_t * pre,
                                        int32_t layer) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || !pre || layer < 0 || layer >= pool->n_layer) {
        if (pre) llama_weight_stream_prefetch_free(pre);
        if (pool) pool->host_claim_layer.store(-1, std::memory_order_release);
        return -1;
    }
    const int64_t r = llama_weight_stream_prefetch_wait(pre);
    const int slot = layer % 2;
    if (r >= 0) {
        // Publish under no mutex: slot_layer is atomic, and the fill thread
        // observed host_claim_layer == layer so it skipped this slot. Other
        // readers (ensure_layer) do an acquire load, so the release store
        // here makes the memcpy bytes visible.
        pool->slot_layer[slot].store(layer, std::memory_order_release);
        // Bump fill_ready so the fill thread does not re-fill below this.
        int32_t cur_ready = pool->fill_ready.load(std::memory_order_relaxed);
        while (cur_ready < layer &&
               !pool->fill_ready.compare_exchange_weak(cur_ready, layer, std::memory_order_release)) {
            // cur_ready refreshed by CAS; retry until we raise it or lose to a higher value.
        }
        if (pool->fill_running.load(std::memory_order_acquire)) {
            std::lock_guard<std::mutex> lk(pool->fill_mtx);
            pool->ensure_cv.notify_all();
        }
    }
    pool->host_claim_layer.store(-1, std::memory_order_release);
    return r;
#else
    GGML_UNUSED(pool);
    GGML_UNUSED(pre);
    GGML_UNUSED(layer);
    return -1;
#endif
}

// Cancel an in-flight prefetch (decode->prefill transition, early exit).
// Waits for the current chunk to finish so the background thread does not
// outlive its dst buffer, then clears the claim.
void llama_weight_pool_prefetch_cancel(llama_weight_pool_t * pool,
                                       llama_weight_stream_prefetch_t * pre,
                                       int32_t layer) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (pool && layer >= 0 && layer < pool->n_layer) {
        pool->host_claim_layer.store(-1, std::memory_order_release);
    }
    if (pre) llama_weight_stream_prefetch_free(pre); // cancel-safe after D3
    GGML_UNUSED(pool);
#else
    GGML_UNUSED(pool);
    GGML_UNUSED(pre);
    GGML_UNUSED(layer);
#endif
}

// Find a layout entry by suffix. Returns index or -1.
static int layout_find_suffix(const llama_weight_pool_t * pool, const char * suffix) {
    if (!pool || !suffix) return -1;
    const std::string s = suffix;
    for (size_t i = 0; i < pool->layout.size(); ++i) {
        if (pool->layout[i].suffix == s) return (int) i;
    }
    return -1;
}

int llama_weight_pool_ensure_experts(llama_weight_pool_t * pool,
                                     int32_t layer,
                                     const char * tensor_suffix,
                                     const int32_t * expert_ids,
                                     int32_t n_experts_used) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || !tensor_suffix || !expert_ids || n_experts_used <= 0) return -1;
    if (layer < 0 || layer >= pool->n_layer) return -1;

    // Find the tensor in the layout to get its offset and size.
    const int layout_idx = layout_find_suffix(pool, tensor_suffix);
    if (layout_idx < 0) return -1;
    const auto & entry = pool->layout[layout_idx];

    // Resolve the tensor index in the stream (for the per-expert slice API).
    // The stream's block_tensor indices include ALL blk.L.* tensors (not just
    // FFN), so we must find the stream index that corresponds to this suffix.
    const uint32_t n_stream = llama_weight_stream_n_block_tensors(pool->stream, layer);
    uint32_t stream_idx = UINT32_MAX;
    for (uint32_t i = 0; i < n_stream; ++i) {
        const char * name = nullptr;
        size_t sz = 0;
        if (!llama_weight_stream_block_tensor_info(pool->stream, layer, i,
                &name, &sz, nullptr, nullptr)) continue;
        // Check if this tensor's suffix matches.
        if (!name) continue;
        std::string full = name;
        const size_t dot = full.find('.', 4); // skip "blk."
        if (dot == std::string::npos) continue;
        if (full.substr(dot + 1) == tensor_suffix) {
            stream_idx = i;
            break;
        }
    }
    if (stream_idx == UINT32_MAX) return -1;

    // Get n_expert from the tensor shape (shape[2] for a 3D tensor).
    uint32_t n_dim = 0;
    uint64_t shape[4] = {};
    if (!llama_weight_stream_block_tensor_info(pool->stream, layer, stream_idx,
            nullptr, nullptr, &n_dim, shape)) return -1;
    if (n_dim < 3 || shape[2] == 0) return -1;
    const int32_t n_expert = (int32_t) shape[2];
    const size_t per_expert_bytes = entry.size / n_expert;

    const int slot = layer % 2;

    // Slot reuse guard: wait for the GPU to finish reading this slot if it
    // was previously filled with different content.
    if (pool->slot_layer[slot].load(std::memory_order_acquire) >= 0 && pool->sync_fn) {
        const int32_t prev = pool->slot_layer[slot].load(std::memory_order_acquire);
        pool->sync_fn(pool->sync_ud, prev);
    }

    // Sparse fill: copy only the active expert slices into the slot at their
    // natural per-expert offset. The slot's per-expert offset within the
    // tensor's region is: entry.offset + expert_id * per_expert_bytes.
    char * slot_ptr = (char *) pool->slot_base[slot];
    for (int32_t i = 0; i < n_experts_used; ++i) {
        const int32_t eid = expert_ids[i];
        if (eid < 0 || eid >= n_expert) continue;
        char * dst = slot_ptr + entry.offset + (size_t) eid * per_expert_bytes;
        const int64_t got = llama_weight_stream_expert_slice(
                pool->stream, layer, stream_idx, eid, dst, per_expert_bytes);
        if (got < 0) {
            fprintf(stderr, "weight pool: expert_slice layer %d expert %d failed\n", layer, eid);
            return -1;
        }
    }

    pool->slot_layer[slot].store(layer, std::memory_order_release);
    return 0;
#else
    GGML_UNUSED(pool); GGML_UNUSED(layer); GGML_UNUSED(tensor_suffix);
    GGML_UNUSED(expert_ids); GGML_UNUSED(n_experts_used);
    return -1;
#endif
}

void llama_weight_pool_poke_expert_prefetch(llama_weight_pool_t * pool,
                                            int32_t layer,
                                            const char * tensor_suffix,
                                            const int32_t * expert_ids,
                                            int32_t n_experts_used) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || !pool->fill_running.load(std::memory_order_acquire) ||
        !tensor_suffix || !expert_ids || n_experts_used <= 0) return;
    {
        std::lock_guard<std::mutex> lk(pool->fill_mtx);
        // Record/update the hint for this (layer, suffix). The fill thread
        // will pre-fill these expert slices on the next prefetch cycle.
        std::string sfx(tensor_suffix);
        bool found = false;
        for (auto & h : pool->moe_hints) {
            if (h.layer == layer && h.suffix == sfx) {
                h.expert_ids.assign(expert_ids, expert_ids + n_experts_used);
                h.filled = false;
                found = true;
                break;
            }
        }
        if (!found) {
            pool->moe_hints.push_back({layer, sfx,
                std::vector<int32_t>(expert_ids, expert_ids + n_experts_used), false});
        }
    }
    pool->fill_cv.notify_one();
#else
    GGML_UNUSED(pool); GGML_UNUSED(layer); GGML_UNUSED(tensor_suffix);
    GGML_UNUSED(expert_ids); GGML_UNUSED(n_experts_used);
#endif
}

void llama_weight_pool_start(llama_weight_pool_t * pool) {
#if LLAMA_WEIGHT_POOL_SUPPORTED
    if (!pool || pool->fill_running.load()) return;

    // The fill thread runs ahead of the encoder: when fill_needed is set to
    // layer L, it fills slot[L%2] (after syncing the GPU if reusing), updates
    // slot_layer + fill_ready, and notifies ensure_cv. It idles until
    // fill_needed advances or shutdown is requested.
    pool->fill_thread = std::thread([pool]() {
        std::unique_lock<std::mutex> lk(pool->fill_mtx);
        pool->fill_running.store(true, std::memory_order_release);
        pool->fill_cv.notify_all(); // wake pool_start's wait

        while (!pool->fill_shutdown.load(std::memory_order_relaxed)) {
            // Wait for work: either dense fill_needed or MoE hints.
            pool->fill_cv.wait(lk, [&] {
                if (pool->fill_shutdown.load(std::memory_order_relaxed)) return true;
                if (pool->fill_needed >= 0) return true;
                for (const auto & h : pool->moe_hints) {
                    if (!h.filled) return true;
                }
                return false;
            });
            if (pool->fill_shutdown.load(std::memory_order_relaxed)) break;

            // Dense fill path.
            if (pool->fill_needed >= 0) {
                const int32_t target = pool->fill_needed;
                for (int32_t l = std::max(0, pool->fill_ready.load(std::memory_order_relaxed) + 1);
                     l <= target && l < pool->n_layer; ++l) {
                    const int s = l % 2;
                    if (pool->slot_layer[s].load(std::memory_order_relaxed) == l) continue;
                    // Skip layers the host-driven prefetch has claimed; the
                    // host owns the slot for those and will publish slot_layer
                    // itself via prefetch_wait.
                    if (pool->host_claim_layer.load(std::memory_order_acquire) == l) continue;
                    if (pool->slot_layer[s].load(std::memory_order_relaxed) >= 0 && pool->sync_fn) {
                        const int32_t prev = pool->slot_layer[s].load(std::memory_order_relaxed);
                        lk.unlock();
                        pool->sync_fn(pool->sync_ud, prev);
                        lk.lock();
                    }
                    const int64_t wrote = llama_weight_stream_layer(
                            pool->stream, l, pool->slot_base[s], pool->slot_bytes);
                    if (wrote < 0) {
                        fprintf(stderr, "weight pool fill thread: layer %d failed\n", l);
                        pool->fill_shutdown.store(true, std::memory_order_release);
                        pool->ensure_cv.notify_all();
                        return;
                    }
                    pool->slot_layer[s].store(l, std::memory_order_release);
                    pool->fill_ready.store(l, std::memory_order_release);
                    pool->ensure_cv.notify_all();
                }
                pool->fill_needed = -1;
            }

            // MoE hint processing: pre-fill expert slices for layers the
            // encoder will need next, using the previous chunk's routing.
            for (auto & h : pool->moe_hints) {
                if (h.filled) continue;
                // The hint's expert IDs predict what ensure_experts will ask
                // for. Pre-fill them now so ensure_experts is a cache hit.
                // Done outside the lock (ensure_experts blocks on mmap + fence).
                int32_t layer = h.layer;
                std::string suffix = h.suffix;
                std::vector<int32_t> ids = h.expert_ids;
                h.filled = true;
                lk.unlock();
                llama_weight_pool_ensure_experts(pool, layer, suffix.c_str(),
                                                 ids.data(), (int32_t) ids.size());
                lk.lock();
            }
        }
    });

    // Wait for the thread to be ready (fill_running set under the lock).
    {
        std::unique_lock<std::mutex> lk(pool->fill_mtx);
        pool->fill_cv.wait(lk, [&] { return pool->fill_running.load(); });
    }
#else
    GGML_UNUSED(pool);
#endif
}

void llama_weight_pool_close(llama_weight_pool_t * pool) {
    if (!pool) return;
#if LLAMA_WEIGHT_POOL_SUPPORTED
    // Signal the fill thread to shut down and join it.
    if (pool->fill_running.load()) {
        {
            std::lock_guard<std::mutex> lk(pool->fill_mtx);
            pool->fill_shutdown.store(true, std::memory_order_release);
            pool->fill_cv.notify_all();
            pool->ensure_cv.notify_all();
        }
        if (pool->fill_thread.joinable()) {
            pool->fill_thread.join();
        }
    }
    if (pool->slot_buf[0]) ggml_backend_buffer_free(pool->slot_buf[0]);
    if (pool->slot_buf[1]) ggml_backend_buffer_free(pool->slot_buf[1]);
    if (pool->stream) llama_weight_stream_close(pool->stream);
#endif
    delete pool;
}

size_t llama_weight_pool_slot_bytes(const llama_weight_pool_t * pool) {
    return pool ? pool->slot_bytes : 0;
}

bool llama_weight_pool_uses_iosurface(const llama_weight_pool_t * pool) {
    return pool ? pool->uses_iosurface : false;
}

ggml_backend_buffer_t llama_weight_pool_slot_buffer(
        const llama_weight_pool_t * pool, int slot_index) {
    if (!pool || slot_index < 0 || slot_index > 1) return nullptr;
    return pool->slot_buf[slot_index];
}

bool llama_model_weight_pool_enabled(const struct llama_model * model) {
    if (!model) return false;
    return model->weight_pool_enabled();
}
