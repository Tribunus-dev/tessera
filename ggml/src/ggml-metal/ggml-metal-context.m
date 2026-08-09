#import "ggml-metal-context.h"

#import "ggml-impl.h"
#import "ggml-backend-impl.h"

#import "ggml-metal-impl.h"
#import "ggml-metal-common.h"
#import "ggml-metal-ops.h"

#import <Foundation/Foundation.h>

#import <Metal/Metal.h>

#include <stdlib.h>

// Forward-declare the MTLSharedEvent helpers (defined in ggml-metal-event.mm)
// so context.m can encode GPU-side signal/wait for fence-based slot sync.
struct ggml_mtl_shared_event;
typedef struct ggml_mtl_shared_event * ggml_mtl_shared_event_t;
GGML_BACKEND_API void ggml_mtl_shared_event_encode_signal(ggml_mtl_shared_event_t event, void * cmd_buf, uint64_t value);
GGML_BACKEND_API void ggml_mtl_shared_event_encode_wait  (ggml_mtl_shared_event_t event, void * cmd_buf, uint64_t value);

#undef MIN
#undef MAX
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

// max number of MTLCommandBuffer used to submit a graph for processing
#define GGML_METAL_MAX_COMMAND_BUFFERS 8

struct ggml_metal_command_buffer {
    id<MTLCommandBuffer> obj;
};

struct ggml_metal {
    char name[128];

    ggml_metal_device_t  dev;
    ggml_metal_library_t lib;

    ggml_metal_event_t ev_cpy; // for async copies

    dispatch_queue_t d_queue;

    // additional, inference-time compiled pipelines
    ggml_metal_pipelines_t pipelines_ext;

    bool use_fusion;
    bool use_concurrency;
    bool use_graph_optimize;

    int debug_graph;
    int debug_fusion;

    // how many times a given op was fused
    uint64_t fuse_cnt[GGML_OP_COUNT];

    // capture state
    int capture_compute;
    bool capture_started;

    id<MTLCaptureScope> capture_scope;

    // command buffer state
    int n_cb;           // number of extra threads used to submit the command buffers
    int n_nodes_0;      // number of nodes submitted by the main thread
    int n_nodes_1;      // remaining number of nodes submitted by the n_cb threads
    int n_nodes_per_cb;

    struct ggml_cgraph * gf;

    // the callback given to the thread pool
    void (^encode_async)(size_t ith);

    // n_cb command buffers + 1 used by the main thread
    struct ggml_metal_command_buffer cmd_bufs[GGML_METAL_MAX_COMMAND_BUFFERS + 1];

    // extra command buffers for things like getting, setting and copying tensors
    NSMutableArray * cmd_bufs_ext;

    // the last command buffer queued into the Metal queue with operations relevant to the current Metal backend
    id<MTLCommandBuffer> cmd_buf_last;

    // In-flight host-driven prefetch (opaque handle + the layer it targets).
    // NULL when no prefetch is pending. Issued after a dense segment's command
    // buffer commits, waited on before the next segment's ensure, drained at
    // graph end. Owned by the model; the Metal context holds a working copy.
    void *   prefetch_inflight;
    int32_t  prefetch_layer;

    // abort ggml_metal_graph_compute if callback returns true
    ggml_abort_callback abort_callback;
    void *              abort_callback_data;

    // error state - set when a command buffer fails during synchronize
    // once set, graph_compute will return GGML_STATUS_FAILED until the backend is recreated
    bool has_error;
};

ggml_metal_t ggml_metal_init(ggml_metal_device_t dev) {
    GGML_LOG_INFO("%s: allocating\n", __func__);

#if TARGET_OS_OSX && !GGML_METAL_NDEBUG
    // Show all the Metal device instances in the system
    NSArray * devices = MTLCopyAllDevices();
    for (id<MTLDevice> device in devices) {
        GGML_LOG_INFO("%s: found device: %s\n", __func__, [[device name] UTF8String]);
    }
    [devices release]; // since it was created by a *Copy* C method
#endif

    // init context
    ggml_metal_t res = calloc(1, sizeof(struct ggml_metal));

    id<MTLDevice> device = ggml_metal_device_get_obj(dev);

    GGML_LOG_INFO("%s: picking default device: %s\n", __func__, [[device name] UTF8String]);

    // TODO: would it be better to have one queue for the backend and one queue for the device?
    //       the graph encoders and async ops would use the backend queue while the sync ops would use the device queue?
    //res->queue = [device newCommandQueue]; [TAG_QUEUE_PER_BACKEND]
    id<MTLCommandQueue> queue = ggml_metal_device_get_queue(dev);
    if (queue == nil) {
        GGML_LOG_ERROR("%s: error: failed to create command queue\n", __func__);
        return NULL;
    }

    res->dev = dev;
    res->lib = ggml_metal_device_get_library(dev);
    if (res->lib == NULL) {
        GGML_LOG_WARN("%s: the device does not have a precompiled Metal library - this is unexpected\n", __func__);
        GGML_LOG_WARN("%s: will try to compile it on the fly\n", __func__);

        res->lib = ggml_metal_library_init(dev);
        if (res->lib == NULL) {
            GGML_LOG_ERROR("%s: error: failed to initialize the Metal library\n", __func__);

            free(res);

            return NULL;
        }
    }

    res->ev_cpy = ggml_metal_device_event_init(dev);

    const struct ggml_metal_device_props * props_dev = ggml_metal_device_get_props(dev);

    snprintf(res->name, sizeof(res->name), "%s", props_dev->name);

    res->d_queue = dispatch_queue_create("ggml-metal", DISPATCH_QUEUE_CONCURRENT);

    res->use_fusion      = getenv("GGML_METAL_FUSION_DISABLE") == nil;
    res->use_concurrency = getenv("GGML_METAL_CONCURRENCY_DISABLE") == nil;

    {
        const char * val = getenv("GGML_METAL_GRAPH_DEBUG");
        res->debug_graph = val ? atoi(val) : 0;
    }

    {
        const char * val = getenv("GGML_METAL_FUSION_DEBUG");
        res->debug_fusion = val ? atoi(val) : 0;
    }

    res->use_graph_optimize = true;

    if (getenv("GGML_METAL_GRAPH_OPTIMIZE_DISABLE") != NULL) {
        res->use_graph_optimize = false;
    }

    memset(res->fuse_cnt, 0, sizeof(res->fuse_cnt));

    GGML_LOG_INFO("%s: use fusion         = %s\n", __func__, res->use_fusion         ? "true" : "false");
    GGML_LOG_INFO("%s: use concurrency    = %s\n", __func__, res->use_concurrency    ? "true" : "false");
    GGML_LOG_INFO("%s: use graph optimize = %s\n", __func__, res->use_graph_optimize ? "true" : "false");

    res->capture_compute = 0;
    res->capture_started = false;
    res->capture_scope = nil;

    {
        const char * val = getenv("GGML_METAL_CAPTURE_COMPUTE");
        if (val) {
            res->capture_compute = atoi(val);
        }
    }

    res->has_error = false;

    res->gf = nil;
    res->encode_async = nil;
    for (int i = 0; i < GGML_METAL_MAX_COMMAND_BUFFERS; ++i) {
        res->cmd_bufs[i].obj = nil;
    }

    res->cmd_bufs_ext = [[NSMutableArray alloc] init];

    res->cmd_buf_last = nil;

    res->prefetch_inflight = NULL;
    res->prefetch_layer    = -1;

    res->pipelines_ext = ggml_metal_pipelines_init();

    return res;
}

void ggml_metal_free(ggml_metal_t ctx) {
    GGML_LOG_INFO("%s: deallocating\n", __func__);

    for (int i = 0; i < GGML_METAL_MAX_COMMAND_BUFFERS; ++i) {
        if (ctx->cmd_bufs[i].obj) {
            [ctx->cmd_bufs[i].obj release];
        }
    }

    for (int i = 0; i < (int) ctx->cmd_bufs_ext.count; ++i) {
        if (ctx->cmd_bufs_ext[i]) {
            [ctx->cmd_bufs_ext[i] release];
        }
    }

    [ctx->cmd_bufs_ext removeAllObjects];
    [ctx->cmd_bufs_ext release];

    if (ctx->pipelines_ext) {
        ggml_metal_pipelines_free(ctx->pipelines_ext);
        ctx->pipelines_ext = nil;
    }

    if (ctx->debug_fusion > 0) {
        GGML_LOG_DEBUG("%s: fusion stats:\n", __func__);
        for (int i = 0; i < GGML_OP_COUNT; i++) {
            if (ctx->fuse_cnt[i] == 0) {
                continue;
            }

            // note: cannot use ggml_log here
            GGML_LOG_DEBUG("%s: - %s: %" PRIu64 "\n", __func__, ggml_op_name((enum ggml_op) i), ctx->fuse_cnt[i]);
        }
    }

    Block_release(ctx->encode_async);

    //[ctx->queue release]; // [TAG_QUEUE_PER_BACKEND]

    dispatch_release(ctx->d_queue);

    ggml_metal_device_event_free(ctx->dev, ctx->ev_cpy);

    free(ctx);
}

const char * ggml_metal_get_name(ggml_metal_t ctx) {
    return ctx->name;
}

void ggml_metal_synchronize(ggml_metal_t ctx) {
    // wait for any backend operations to finish
    if (ctx->cmd_buf_last) {
        [ctx->cmd_buf_last waitUntilCompleted];
        ctx->cmd_buf_last = nil;
    }

    // check status of all command buffers
    {
        const int n_cb = ctx->n_cb;

        for (int cb_idx = 0; cb_idx <= n_cb; ++cb_idx) {
            id<MTLCommandBuffer> cmd_buf = ctx->cmd_bufs[cb_idx].obj;
            if (!cmd_buf) {
                continue;
            }

            MTLCommandBufferStatus status = [cmd_buf status];
            if (status != MTLCommandBufferStatusCompleted) {
                GGML_LOG_ERROR("%s: error: command buffer %d failed with status %d\n", __func__, cb_idx, (int) status);
                if (status == MTLCommandBufferStatusError) {
                    GGML_LOG_ERROR("error: %s\n", [[cmd_buf error].localizedDescription UTF8String]);
                }
                ctx->has_error = true;
                return;
            }
        }
    }

    // release any completed extra command buffers
    if (ctx->cmd_bufs_ext.count > 0) {
        for (size_t i = 0; i < ctx->cmd_bufs_ext.count; ++i) {
            id<MTLCommandBuffer> cmd_buf = ctx->cmd_bufs_ext[i];

            MTLCommandBufferStatus status = [cmd_buf status];
            if (status != MTLCommandBufferStatusCompleted) {
                GGML_LOG_ERROR("%s: error: command buffer %d failed with status %d\n", __func__, (int) i, (int) status);
                if (status == MTLCommandBufferStatusError) {
                    GGML_LOG_ERROR("error: %s\n", [[cmd_buf error].localizedDescription UTF8String]);
                }

                // release this and all remaining command buffers before returning
                for (size_t j = i; j < ctx->cmd_bufs_ext.count; ++j) {
                    [ctx->cmd_bufs_ext[j] release];
                }
                [ctx->cmd_bufs_ext removeAllObjects];

                ctx->has_error = true;
                return;
            }

            [cmd_buf release];
        }

        [ctx->cmd_bufs_ext removeAllObjects];
    }
}

static struct ggml_metal_buffer_id ggml_metal_get_buffer_id(const struct ggml_tensor * t) {
    if (!t) {
        return (struct ggml_metal_buffer_id) { nil, 0 };
    }

    ggml_backend_buffer_t buffer = t->view_src ? t->view_src->buffer : t->buffer;

    return ggml_metal_buffer_get_id(buffer->context, t);
}

void ggml_metal_set_tensor_async(ggml_metal_t ctx, struct ggml_tensor * tensor, const void * data, size_t offset, size_t size) {
    @autoreleasepool {
        // wrap the source data into a Metal buffer
        id<MTLDevice> device = ggml_metal_device_get_obj(ctx->dev);
        id<MTLBuffer> buf_src = [device newBufferWithBytes:data
                                                    length:size
                                                   options:MTLResourceStorageModeShared];

        GGML_ASSERT(buf_src);

        struct ggml_metal_buffer_id bid_dst = ggml_metal_get_buffer_id(tensor);
        if (bid_dst.metal == nil) {
            GGML_ABORT("%s: failed to find buffer for tensor '%s'\n", __func__, tensor->name);
        }

        bid_dst.offs += offset;

        // queue the copy operation into the queue of the Metal context
        // this will be queued at the end, after any currently ongoing GPU operations
        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx->dev);
        id<MTLCommandBuffer> cmd_buf = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];

        [encoder copyFromBuffer:buf_src
                   sourceOffset:0
                       toBuffer:bid_dst.metal
              destinationOffset:bid_dst.offs
                           size:size];

        [encoder endEncoding];
        [cmd_buf commit];
        [buf_src release];

        // do not wait here for completion
        //[cmd_buf waitUntilCompleted];

        // instead, remember a reference to the command buffer and wait for it later if needed
        [ctx->cmd_bufs_ext addObject:cmd_buf];
        ctx->cmd_buf_last = cmd_buf;

        [cmd_buf retain];
    }
}

void ggml_metal_get_tensor_async(ggml_metal_t ctx, const struct ggml_tensor * tensor, void * data, size_t offset, size_t size) {
    @autoreleasepool {
        id<MTLDevice> device = ggml_metal_device_get_obj(ctx->dev);
        id<MTLBuffer> buf_dst = [device newBufferWithBytesNoCopy:data
                                                          length:size
                                                         options:MTLResourceStorageModeShared
                                                     deallocator:nil];

        GGML_ASSERT(buf_dst);

        struct ggml_metal_buffer_id bid_src = ggml_metal_get_buffer_id(tensor);
        if (bid_src.metal == nil) {
            GGML_ABORT("%s: failed to find buffer for tensor '%s'\n", __func__, tensor->name);
        }

        bid_src.offs += offset;

        // queue the copy operation into the queue of the Metal context
        // this will be queued at the end, after any currently ongoing GPU operations
        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx->dev);
        id<MTLCommandBuffer> cmd_buf = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];

        [encoder copyFromBuffer:bid_src.metal
                   sourceOffset:bid_src.offs
                       toBuffer:buf_dst
              destinationOffset:0
                           size:size];

        [encoder endEncoding];
        [cmd_buf commit];
        [buf_dst release];

        // do not wait here for completion
        //[cmd_buf waitUntilCompleted];

        // instead, remember a reference to the command buffer and wait for it later if needed
        [ctx->cmd_bufs_ext addObject:cmd_buf];
        ctx->cmd_buf_last = cmd_buf;

        [cmd_buf retain];
    }
}

bool ggml_metal_cpy_tensor_async(ggml_metal_t ctx_src, ggml_metal_t ctx_dst, const struct ggml_tensor * src, struct ggml_tensor * dst) {
    @autoreleasepool {
        struct ggml_metal_buffer_id bid_src = ggml_metal_get_buffer_id(src);
        struct ggml_metal_buffer_id bid_dst = ggml_metal_get_buffer_id(dst);

        if (bid_src.metal == nil || bid_dst.metal == nil) {
            return false;
        }

        // queue the copy operation into the Metal context
        // this will be queued at the end, after any currently ongoing GPU operations
        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx_src->dev);
        id<MTLCommandBuffer> cmd_buf = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [cmd_buf blitCommandEncoder];

        [encoder copyFromBuffer:bid_src.metal
                   sourceOffset:bid_src.offs
                       toBuffer:bid_dst.metal
              destinationOffset:bid_dst.offs
                           size:ggml_nbytes(src)];

        [encoder endEncoding];

        ggml_metal_event_t ev_cpy = ggml_metal_get_ev_cpy(ctx_src);
        ggml_metal_event_encode_signal(ev_cpy, cmd_buf);

        [cmd_buf commit];

        // do not wait here for completion
        //[cmd_buf waitUntilCompleted];

        // instead, remember a reference to the command buffer and wait for it later if needed
        [ctx_src->cmd_bufs_ext addObject:cmd_buf];
        ctx_src->cmd_buf_last = cmd_buf;

        [cmd_buf retain];

        ggml_metal_event_wait(ctx_dst, ev_cpy);

        return true;
    }
}

enum ggml_status ggml_metal_graph_compute(ggml_metal_t ctx, struct ggml_cgraph * gf);

#ifdef GGML_USE_ANE
// Slice 4.2a: streamed graph compute for IOSurface-backed FFN weights.
//
// The standard graph_compute encodes the whole cgraph into command buffers
// before the GPU executes any of it. With 2 weight slots shared across 48
// layers that is wrong: all per-layer refills would land before execution,
// leaving the GPU reading only the last layer's data.
//
// This path paces compute one layer at a time:
//   1. Scan the cgraph for streamed FFN MUL_MAT nodes (layer boundaries).
//   2. For each segment between boundaries, create a command buffer, encode
//      the segment, and commit (GPU starts asynchronously).
//   3. Before encoding a layer's FFN segment, call the pool's ensure_fn to
//      refill slot[L%2] from the mmap. Before reusing a slot (layer L+2),
//      wait for the command buffer that consumed it (L) to complete.
//
// Non-FFN nodes (attention, norms, etc.) are encoded in the same segment as
// the FFN that follows them, so they run on the same command buffer.
//
// Phase 1: synchronous refill (blocks the encode thread). No overlap yet.
static enum ggml_status ggml_metal_graph_compute_streamed(ggml_metal_t ctx, struct ggml_cgraph * gf) {
    @autoreleasepool {
        ctx->gf = gf;

        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx->dev);
        void * pool = ggml_metal_device_stream_get_pool(ctx->dev);
        ggml_metal_stream_ensure_fn ensure = ggml_metal_device_stream_get_ensure_fn(ctx->dev);
        if (!pool || !ensure) {
            // No pool attached; fall back to the standard path.
            return ggml_metal_graph_compute(ctx, gf);
        }

        // Walk the cgraph and split it into segments at FFN layer boundaries.
        // A segment starts at the node after a boundary and ends at the next
        // boundary (or end of graph). The first segment runs from node 0.
        // Use C arrays (this is a .m file, not ObjC++).
        const int max_segments = gf->n_nodes; // upper bound: at most 1 segment per node
        int * seg_start_arr = (int *) malloc(sizeof(int) * max_segments);
        int * seg_end_arr   = (int *) malloc(sizeof(int) * max_segments);
        int32_t * seg_layer = (int32_t *) malloc(sizeof(int32_t) * max_segments);
        int n_segments = 0;
        int seg_start = 0;
        int32_t cur_layer = -1;
        for (int i = 0; i < gf->n_nodes; ++i) {
            struct ggml_tensor * node = ggml_graph_node(gf, i);
            if (!node) continue;
            int32_t layer = -1;
            if (ggml_metal_op_is_streamed_ffn(node, &layer)) {
                if (layer != cur_layer) {
                    if (cur_layer >= 0) {
                        seg_start_arr[n_segments] = seg_start;
                        seg_end_arr[n_segments]   = i;
                        seg_layer[n_segments]     = cur_layer;
                        n_segments++;
                    }
                    seg_start = i;
                    cur_layer = layer;
                }
            }
        }
        if (cur_layer >= 0) {
            seg_start_arr[n_segments] = seg_start;
            seg_end_arr[n_segments]   = gf->n_nodes;
            seg_layer[n_segments]     = cur_layer;
            n_segments++;
        } else {
            // No streamed FFN in this graph; fall back.
            free(seg_start_arr); free(seg_end_arr); free(seg_layer);
            return ggml_metal_graph_compute(ctx, gf);
        }

        // Track per-slot in-flight command buffers so we can wait before reuse.
        // slot_cb[s] is the command buffer that most recently read slot s.
        id<MTLCommandBuffer> slot_cb[2] = { nil, nil };
        int32_t slot_layer[2] = { -1, -1 };

        bool ok = true;
        // Fence-based sync: the GPU signals event = layer+1 after each
        // segment finishes. Slot reuse encodes a GPU-side wait for the
        // previous layer's signal, so the encode thread never blocks on
        // the CPU. Falls back to CPU waitUntilCompleted when no fence.
        ggml_mtl_shared_event_t fence =
            (ggml_mtl_shared_event_t) ggml_metal_device_stream_get_fence(ctx->dev);

        for (int si = 0; si < n_segments; ++si) {
            const int seg_lo = seg_start_arr[si];
            const int seg_hi = seg_end_arr[si];
            const int32_t seg_lyr = seg_layer[si];
            const int slot = seg_lyr % 2;

            // Release the previous cmd_buf for this slot (fix retain leak).
            // The GPU-side fence handles ordering; we only need the cmd_buf
            // reference for the final status check.
            if (slot_cb[slot]) {
                [slot_cb[slot] release];
                slot_cb[slot] = nil;
            }

            // Drain any in-flight host-driven prefetch targeting this layer.
            // prefetch_wait publishes slot_layer[L%2] = L (release) so the
            // ensure() fast path below hits without a re-memcpy. Falls through
            // to ensure() which handles both the cache-hit and the synchronous
            // fill-thread / inline-memcpy fallbacks.
            if (ctx->prefetch_inflight && ctx->prefetch_layer == seg_lyr) {
                ggml_metal_stream_prefetch_wait_fn wait_fn =
                    ggml_metal_device_stream_get_prefetch_wait_fn(ctx->dev);
                if (wait_fn) {
                    (void) wait_fn(pool, ctx->prefetch_inflight, ctx->prefetch_layer);
                }
                ctx->prefetch_inflight = NULL;
                ctx->prefetch_layer    = -1;
            }

            // Refill the slot with this layer's bytes. The fill thread (Phase
            // 2) may have already prefetched it; ensure_layer is a cache hit
            // in that case. The fill thread's own slot-reuse guard uses the
            // fence's CPU-side wait via sync_fn.
            //
            // MoE two-pass: if this segment contains MUL_MAT_ID nodes, the
            // expert IDs are computed on GPU (router pass) and are not
            // available at encode time. Split the segment: encode+commit+wait
            // the router pass (nodes before the first MUL_MAT_ID), read the
            // expert IDs from src[2]->data, sparse-fill the active expert
            // slices, then encode the expert pass.
            ggml_metal_stream_ensure_experts_fn ensure_experts =
                ggml_metal_device_stream_get_ensure_experts_fn(ctx->dev);

            // Scan for the first MUL_MAT_ID node in this segment.
            int mul_mat_id_idx = -1;
            if (ensure_experts) {
                for (int i = seg_lo; i < seg_hi; ++i) {
                    struct ggml_tensor * node = ggml_graph_node(gf, i);
                    if (node && node->op == GGML_OP_MUL_MAT_ID) {
                        mul_mat_id_idx = i;
                        break;
                    }
                }
            }

            if (mul_mat_id_idx >= 0) {
                // --- MoE two-pass ---

                // Sub-segment 1: router pass [seg_lo, mul_mat_id_idx).
                // Encode, commit, and wait — the CPU needs the expert IDs.
                if (mul_mat_id_idx > seg_lo) {
                    id<MTLCommandBuffer> router_cb = [queue commandBufferWithUnretainedReferences];
                    [router_cb retain];
                    if (fence) {
                        const int32_t prev_in_slot = seg_lyr - 2;
                        if (prev_in_slot >= 0) {
                            ggml_mtl_shared_event_encode_wait(fence, router_cb, (uint64_t)(prev_in_slot + 1));
                        }
                    }
                    ggml_metal_op_t router_op = ggml_metal_op_init(
                        ctx->dev, router_cb, gf,
                        seg_lo, mul_mat_id_idx,
                        ctx->use_fusion, ctx->use_concurrency,
                        ctx->capture_compute >= 0, ctx->debug_graph, ctx->debug_fusion);
                    for (int idx = 0; idx < ggml_metal_op_n_nodes(router_op); ++idx) {
                        const int res = ggml_metal_op_encode(router_op, idx);
                        if (res == 0) break;
                        idx += res - 1;
                    }
                    ggml_metal_op_free(router_op);
                    [router_cb enqueue];
                    [router_cb commit];
                    [router_cb waitUntilCompleted]; // CPU blocks until router done
                    MTLCommandBufferStatus rst = [router_cb status];
                    if (rst != MTLCommandBufferStatusCompleted) {
                        GGML_LOG_ERROR("%s: MoE router pass layer %d failed (status %lu)\n",
                                       __func__, seg_lyr, (unsigned long) rst);
                        ctx->has_error = true;
                        ok = false;
                        [router_cb release];
                        break;
                    }
                    [router_cb release];
                }

                // Collect the UNION of expert IDs across every MUL_MAT_ID node
                // in [mul_mat_id_idx, seg_hi). Each node's src[2] is
                // [n_expert_used, n_tokens] I32. Reading only the first node's
                // IDs would miss experts that other nodes in the same expert
                // pass route to, leaving their slot slices stale. The dedup
                // is O(n_ids * n_unique) — n_ids is small (top-k * n_tokens,
                // top-k typically 2-16) and n_unique <= n_expert.
                int32_t unique_ids[256];
                int n_unique = 0;
                for (int i = mul_mat_id_idx; i < seg_hi; ++i) {
                    struct ggml_tensor * node = ggml_graph_node(gf, i);
                    if (!node || node->op != GGML_OP_MUL_MAT_ID) continue;
                    struct ggml_tensor * ids_tensor = node->src[2];
                    if (!ids_tensor || !ids_tensor->data) {
                        GGML_LOG_ERROR("%s: MoE layer %d — expert IDs not available for node %d\n",
                                       __func__, seg_lyr, i);
                        ok = false;
                        break;
                    }
                    const int32_t * ids_data = (const int32_t *) ids_tensor->data;
                    const int n_ids = (int)(ids_tensor->ne[0] * ids_tensor->ne[1]);
                    for (int k = 0; k < n_ids && n_unique < 256; ++k) {
                        int32_t id = ids_data[k];
                        bool found = false;
                        for (int j = 0; j < n_unique; ++j) {
                            if (unique_ids[j] == id) { found = true; break; }
                        }
                        if (!found) unique_ids[n_unique++] = id;
                    }
                }
                if (!ok) break;

                // Sparse-fill: for each unique MoE weight tensor in the expert
                // pass, call ensure_experts with the active expert IDs. We
                // collect unique weight suffixes from the MUL_MAT_ID nodes.
                // The slot reuse guard is handled inside ensure_experts.
                for (int i = mul_mat_id_idx; i < seg_hi; ++i) {
                    struct ggml_tensor * node = ggml_graph_node(gf, i);
                    if (!node || node->op != GGML_OP_MUL_MAT_ID) continue;
                    if (!node->src[0] || !node->src[0]->name[0]) continue;
                    // Extract the suffix from "blk.L.<suffix>" — skip "blk.N."
                    const char * name = node->src[0]->name;
                    const char * suffix = name;
                    if (name[0]=='b'&&name[1]=='l'&&name[2]=='k'&&name[3]=='.') {
                        const char * p = name + 4;
                        while (*p >= '0' && *p <= '9') ++p;
                        if (*p == '.') suffix = p + 1;
                    }
                    if (ensure_experts(pool, seg_lyr, suffix, unique_ids, n_unique) < 0) {
                        GGML_LOG_ERROR("%s: MoE ensure_experts layer %d %s failed\n",
                                       __func__, seg_lyr, suffix);
                        ok = false;
                        break;
                    }
                    // Phase MoE-2: poke the fill thread to prefetch these
                    // expert IDs for the next chunk (temporal routing hint).
                    // The fill thread pre-fills the same experts so the next
                    // ensure_experts is a cache hit if routing is stable.
                    ggml_metal_stream_poke_experts_fn poke_ex =
                        ggml_metal_device_stream_get_poke_experts_fn(ctx->dev);
                    if (poke_ex) {
                        poke_ex(pool, seg_lyr, suffix, unique_ids, n_unique);
                    }
                }
                if (!ok) break;
                slot_layer[slot] = seg_lyr;

                // Sub-segment 2: expert pass [mul_mat_id_idx, seg_hi).
                id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
                [cmd_buf retain];
                // Symmetric GPU-side slot-reuse wait. The dense branch and the
                // MoE router branch both encode this before reusing a slot;
                // ensure_experts already CPU-waits via sync_fn, but encoding
                // the GPU wait here is defense-in-depth so a future change to
                // ensure_experts (e.g. making it non-blocking) cannot race
                // this command buffer with layer seg_lyr-2's in-flight read.
                if (fence) {
                    const int32_t prev_in_slot = seg_lyr - 2;
                    if (prev_in_slot >= 0) {
                        ggml_mtl_shared_event_encode_wait(fence, cmd_buf, (uint64_t)(prev_in_slot + 1));
                    }
                }
                ggml_metal_op_t ctx_op = ggml_metal_op_init(
                    ctx->dev, cmd_buf, gf,
                    mul_mat_id_idx, seg_hi,
                    ctx->use_fusion, ctx->use_concurrency,
                    ctx->capture_compute >= 0, ctx->debug_graph, ctx->debug_fusion);
                for (int idx = 0; idx < ggml_metal_op_n_nodes(ctx_op); ++idx) {
                    const int res = ggml_metal_op_encode(ctx_op, idx);
                    if (res == 0) break;
                    idx += res - 1;
                }
                ggml_metal_op_free(ctx_op);
                if (fence) {
                    ggml_mtl_shared_event_encode_signal(fence, cmd_buf, (uint64_t)(seg_lyr + 1));
                }
                [cmd_buf enqueue];
                [cmd_buf commit];
                ctx->cmd_buf_last = cmd_buf;
                slot_cb[slot] = cmd_buf;

            } else {
                // --- Dense (no MUL_MAT_ID) — original path ---
                if (ensure(pool, seg_lyr) < 0) {
                    GGML_LOG_ERROR("%s: weight pool ensure_layer %d failed\n", __func__, seg_lyr);
                    ok = false;
                    break;
                }
                slot_layer[slot] = seg_lyr;

                id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
                [cmd_buf retain];
                if (fence) {
                    const int32_t prev_in_slot = seg_lyr - 2;
                    if (prev_in_slot >= 0) {
                        ggml_mtl_shared_event_encode_wait(fence, cmd_buf, (uint64_t)(prev_in_slot + 1));
                    }
                }
                ggml_metal_op_t ctx_op = ggml_metal_op_init(
                    ctx->dev, cmd_buf, gf,
                    seg_lo, seg_hi,
                    ctx->use_fusion, ctx->use_concurrency,
                    ctx->capture_compute >= 0, ctx->debug_graph, ctx->debug_fusion);
                for (int idx = 0; idx < ggml_metal_op_n_nodes(ctx_op); ++idx) {
                    const int res = ggml_metal_op_encode(ctx_op, idx);
                    if (res == 0) break;
                    idx += res - 1;
                }
                ggml_metal_op_free(ctx_op);
                if (fence) {
                    ggml_mtl_shared_event_encode_signal(fence, cmd_buf, (uint64_t)(seg_lyr + 1));
                }
                [cmd_buf enqueue];
                [cmd_buf commit];
                ctx->cmd_buf_last = cmd_buf;
                slot_cb[slot] = cmd_buf;
            }

            // After committing this layer's command buffer, prefetch the next
            // layer's bytes so they are ready when the loop reaches it. Prefers
            // the host-driven prefetch API (explicit async memcpy with fence
            // guard + slot publish) when wired; falls back to the fill-thread
            // poke when prefetch_async is unavailable or the claim is lost.
            if (si + 1 < n_segments) {
                const int32_t next_lyr = seg_layer[si + 1];
                ggml_metal_stream_prefetch_async_fn prefetch_async =
                    ggml_metal_device_stream_get_prefetch_async_fn(ctx->dev);
                if (prefetch_async) {
                    // Drain any stale in-flight prefetch before issuing a new one.
                    if (ctx->prefetch_inflight) {
                        ggml_metal_stream_prefetch_cancel_fn cancel_fn =
                            ggml_metal_device_stream_get_prefetch_cancel_fn(ctx->dev);
                        if (cancel_fn) {
                            cancel_fn(pool, ctx->prefetch_inflight, ctx->prefetch_layer);
                        }
                        ctx->prefetch_inflight = NULL;
                        ctx->prefetch_layer    = -1;
                    }
                    void * h = prefetch_async(pool, next_lyr);
                    if (h) {
                        ctx->prefetch_inflight = h;
                        ctx->prefetch_layer    = next_lyr;
                    } else {
                        // Layer out of range or already claimed: fall back to poke.
                        ggml_metal_stream_poke_fn poke = ggml_metal_device_stream_get_poke_fn(ctx->dev);
                        if (poke) poke(pool, next_lyr);
                    }
                } else {
                    ggml_metal_stream_poke_fn poke = ggml_metal_device_stream_get_poke_fn(ctx->dev);
                    if (poke) poke(pool, next_lyr);
                }
            }
        }

        // Drain any in-flight prefetch at graph end (decode->prefill transition
        // or early exit). cancel waits for the background memcpy so it does not
        // outlive its dst slot buffer, then clears the handle.
        if (ctx->prefetch_inflight) {
            ggml_metal_stream_prefetch_cancel_fn cancel_fn =
                ggml_metal_device_stream_get_prefetch_cancel_fn(ctx->dev);
            if (cancel_fn) {
                cancel_fn(pool, ctx->prefetch_inflight, ctx->prefetch_layer);
            }
            ctx->prefetch_inflight = NULL;
            ctx->prefetch_layer    = -1;
        }

        // Wait for the final command buffers to complete so status is checked.
        for (int s = 0; s < 2; ++s) {
            if (slot_cb[s]) {
                [slot_cb[s] waitUntilCompleted];
                MTLCommandBufferStatus st = [slot_cb[s] status];
                if (st != MTLCommandBufferStatusCompleted) {
                    GGML_LOG_ERROR("%s: streamed final cmd_buf slot %d failed (status %lu)\n",
                                   __func__, s, (unsigned long) st);
                    if (st == MTLCommandBufferStatusError) {
                        GGML_LOG_ERROR("error: %s\n", [slot_cb[s].error.localizedDescription UTF8String]);
                    }
                    ctx->has_error = true;
                    ok = false;
                }
                [slot_cb[s] release];
                slot_cb[s] = nil;
            }
        }

        // Reset the device's last-streamed-layer cache for the next graph.
        ggml_metal_device_stream_set_last_layer(ctx->dev, -1);

        free(seg_start_arr); free(seg_end_arr); free(seg_layer);

        return ok ? GGML_STATUS_SUCCESS : GGML_STATUS_FAILED;
    }
}
#endif

enum ggml_status ggml_metal_graph_compute(ggml_metal_t ctx, struct ggml_cgraph * gf) {
    if (ctx->has_error) {
        GGML_LOG_ERROR("%s: backend is in error state from a previous command buffer failure - recreate the backend to recover\n", __func__);
        return GGML_STATUS_FAILED;
    }

#ifdef GGML_USE_ANE
    // Slice 4.2a: if a weight pool is attached, use the streamed path that
    // paces compute one layer at a time (refill + commit + wait per segment).
    if (ggml_metal_device_stream_get_pool(ctx->dev) != NULL) {
        return ggml_metal_graph_compute_streamed(ctx, gf);
    }
#endif

    // number of nodes encoded by the main thread (empirically determined)
    const int n_main = MAX(64, 0.1*gf->n_nodes);

    // number of threads in addition to the main thread
    const int n_cb = ctx->n_cb;

    // keep the memory wired
    ggml_metal_device_rsets_keep_alive(ctx->dev);

    // submit the ggml compute graph to the GPU by creating command buffers and encoding the ops in them
    // the first n_nodes_0 are encoded and submitted for processing directly by the calling thread
    // while these nodes are processing, we start n_cb threads to enqueue the rest of the nodes
    // each thread creates it's own command buffer and enqueues the ops in parallel
    //
    // tests on M1 Pro and M2 Ultra using LLaMA models, show that optimal values for n_cb are 1 or 2

    @autoreleasepool {
        ctx->gf = gf;

        ctx->n_nodes_0 = MIN(n_main, gf->n_nodes);
        ctx->n_nodes_1 = gf->n_nodes - ctx->n_nodes_0;

        ctx->n_nodes_per_cb = (ctx->n_nodes_1 + ctx->n_cb - 1) / ctx->n_cb;

        if (ctx->capture_compute >= 0) {
            ctx->capture_compute--;
        }

        const bool use_capture = ctx->capture_compute == 0;
        if (use_capture) {
            ctx->capture_compute = -1;

            // make sure all previous computations have finished before starting the capture
            if (ctx->cmd_buf_last) {
                [ctx->cmd_buf_last waitUntilCompleted];
                ctx->cmd_buf_last = nil;
            }

            if (!ctx->capture_started) {
                NSString * path = [NSString stringWithFormat:@"/tmp/perf-metal-%d.gputrace", getpid()];

                GGML_LOG_WARN("%s: capturing graph in %s\n", __func__, [path UTF8String]);

                // create capture scope
                id<MTLDevice> device = ggml_metal_device_get_obj(ctx->dev);
                ctx->capture_scope = [[MTLCaptureManager sharedCaptureManager] newCaptureScopeWithDevice:device];

                MTLCaptureDescriptor * descriptor = [MTLCaptureDescriptor new];
                descriptor.captureObject = ctx->capture_scope;
                descriptor.destination = MTLCaptureDestinationGPUTraceDocument;
                descriptor.outputURL = [NSURL fileURLWithPath:path];

                NSError * error = nil;
                if (![[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:descriptor error:&error]) {
                    GGML_LOG_ERROR("%s: error: unable to start capture '%s'\n", __func__, [[error localizedDescription] UTF8String]);
                } else {
                    [ctx->capture_scope beginScope];
                    ctx->capture_started = true;
                }
            }
        }

        // short-hand
        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx->dev);

        // the main thread commits the first few commands immediately
        // cmd_buf[n_cb]
        {
            id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
            [cmd_buf retain];

            if (ctx->cmd_bufs[n_cb].obj) {
                [ctx->cmd_bufs[n_cb].obj release];
            }
            ctx->cmd_bufs[n_cb].obj = cmd_buf;

            [cmd_buf enqueue];

            ctx->encode_async(n_cb);
        }

        // remember the command buffer for the next iteration
        ctx->cmd_buf_last = ctx->cmd_bufs[n_cb].obj;

        // prepare the rest of the command buffers asynchronously (optional)
        // cmd_buf[0.. n_cb)
        for (int cb_idx = 0; cb_idx < n_cb; ++cb_idx) {
            id<MTLCommandBuffer> cmd_buf = [queue commandBufferWithUnretainedReferences];
            [cmd_buf retain];

            if (ctx->cmd_bufs[cb_idx].obj) {
                [ctx->cmd_bufs[cb_idx].obj release];
            }
            ctx->cmd_bufs[cb_idx].obj = cmd_buf;

            // always enqueue the first two command buffers
            // enqueue all of the command buffers if we don't need to abort
            if (cb_idx < 2 || ctx->abort_callback == NULL) {
                [cmd_buf enqueue];

                // update the pointer to the last queued command buffer
                // this is needed to implement synchronize()
                ctx->cmd_buf_last = cmd_buf;
            }
        }

        dispatch_apply(n_cb, ctx->d_queue, ctx->encode_async);

        // for debugging: block until graph is computed
        //[ctx->cmd_buf_last waitUntilCompleted];

        // enter here only when capturing in order to wait for all computation to finish
        // otherwise, we leave the graph to compute asynchronously
        if (use_capture && ctx->capture_started) {
            // wait for completion and check status of each command buffer
            // needed to detect if the device ran out-of-memory for example (#1881)
            {
                id<MTLCommandBuffer> cmd_buf = ctx->cmd_bufs[n_cb].obj;
                [cmd_buf waitUntilCompleted];

                MTLCommandBufferStatus status = [cmd_buf status];
                if (status != MTLCommandBufferStatusCompleted) {
                    GGML_LOG_INFO("%s: command buffer %d failed with status %lu\n", __func__, n_cb, status);
                    if (status == MTLCommandBufferStatusError) {
                        GGML_LOG_INFO("error: %s\n", [[cmd_buf error].localizedDescription UTF8String]);
                    }

                    return GGML_STATUS_FAILED;
                }
            }

            for (int i = 0; i < n_cb; ++i) {
                id<MTLCommandBuffer> cmd_buf = ctx->cmd_bufs[i].obj;
                [cmd_buf waitUntilCompleted];

                MTLCommandBufferStatus status = [cmd_buf status];
                if (status != MTLCommandBufferStatusCompleted) {
                    GGML_LOG_INFO("%s: command buffer %d failed with status %lu\n", __func__, i, status);
                    if (status == MTLCommandBufferStatusError) {
                        GGML_LOG_INFO("error: %s\n", [[cmd_buf error].localizedDescription UTF8String]);
                    }

                    return GGML_STATUS_FAILED;
                }

                id<MTLCommandBuffer> next_buffer = (i + 1 < n_cb ? ctx->cmd_bufs[i + 1].obj : nil);
                if (!next_buffer) {
                    continue;
                }

                const bool next_queued = ([next_buffer status] != MTLCommandBufferStatusNotEnqueued);
                if (next_queued) {
                    continue;
                }

                if (ctx->abort_callback && ctx->abort_callback(ctx->abort_callback_data)) {
                    GGML_LOG_INFO("%s: command buffer %d aborted", __func__, i);
                    return GGML_STATUS_ABORTED;
                }

                [next_buffer commit];
            }

            [ctx->capture_scope endScope];
            [[MTLCaptureManager sharedCaptureManager] stopCapture];

            ctx->capture_started = false;
        }
    }

    return GGML_STATUS_SUCCESS;
}

void ggml_metal_graph_optimize(ggml_metal_t ctx, struct ggml_cgraph * gf) {
    //const int64_t t_start = ggml_time_us();

    if (ctx->use_graph_optimize) {
        ggml_graph_optimize(gf);
    }

    //printf("%s: graph optimize took %.3f ms\n", __func__, (ggml_time_us() - t_start) / 1000.0);
}

void ggml_metal_event_record(ggml_metal_t ctx, ggml_metal_event_t ev) {
    @autoreleasepool {
        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx->dev);
        id<MTLCommandBuffer> cmd_buf = [queue commandBuffer];

        ggml_metal_event_encode_signal(ev, cmd_buf);

        [cmd_buf commit];

        [ctx->cmd_bufs_ext addObject:cmd_buf];
        ctx->cmd_buf_last = cmd_buf;

        [cmd_buf retain];
    }
}

void ggml_metal_event_wait(ggml_metal_t ctx, ggml_metal_event_t ev) {
    @autoreleasepool {
        id<MTLCommandQueue> queue = ggml_metal_device_get_queue(ctx->dev);
        id<MTLCommandBuffer> cmd_buf = [queue commandBuffer];

        ggml_metal_event_encode_wait(ev, cmd_buf);

        [cmd_buf commit];

        [ctx->cmd_bufs_ext addObject:cmd_buf];
        ctx->cmd_buf_last = cmd_buf;

        [cmd_buf retain];
    }
}

ggml_metal_event_t ggml_metal_get_ev_cpy(ggml_metal_t ctx) {
    return ctx->ev_cpy;
}

void ggml_metal_set_n_cb(ggml_metal_t ctx, int n_cb) {
    if (ctx->n_cb != n_cb) {
        ctx->n_cb = MIN(n_cb, GGML_METAL_MAX_COMMAND_BUFFERS);

        if (ctx->n_cb > 2) {
            GGML_LOG_WARN("%s: n_cb = %d, using n_cb > 2 is not recommended and can degrade the performance in some cases\n", __func__, n_cb);
        }
    }

    if (ctx->encode_async) {
        Block_release(ctx->encode_async);
    }

    ctx->encode_async = Block_copy(^(size_t iter) {
        const int cb_idx = iter;
        const int n_cb_l = ctx->n_cb;

        const int n_nodes_0 = ctx->n_nodes_0;
        const int n_nodes_1 = ctx->n_nodes_1;

        const int n_nodes_per_cb = ctx->n_nodes_per_cb;

        int idx_start = 0;
        int idx_end   = n_nodes_0;

        if (cb_idx < n_cb_l) {
            idx_start = n_nodes_0 + (                                         (cb_idx + 0) * n_nodes_per_cb);
            idx_end   = n_nodes_0 + (MIN((cb_idx == n_cb_l - 1) ? n_nodes_1 : (cb_idx + 1) * n_nodes_per_cb, n_nodes_1));
        }

        id<MTLCommandBuffer> cmd_buf = ctx->cmd_bufs[cb_idx].obj;

        ggml_metal_op_t ctx_op = ggml_metal_op_init(
            ctx->dev,
            cmd_buf,
            ctx->gf,
            idx_start,
            idx_end,
            ctx->use_fusion,
            ctx->use_concurrency,
            ctx->capture_compute,
            ctx->debug_graph,
            ctx->debug_fusion);

        for (int idx = 0; idx < ggml_metal_op_n_nodes(ctx_op); ++idx) {
            const int res = ggml_metal_op_encode(ctx_op, idx);
            if (res == 0) {
                break;
            }

            idx += res - 1;
        }

        ggml_metal_op_free(ctx_op);

        if (cb_idx < 2 || ctx->abort_callback == NULL) {
            [cmd_buf commit];
        }
    });
}

void ggml_metal_set_abort_callback(ggml_metal_t ctx, ggml_abort_callback abort_callback, void * user_data) {
    ctx->abort_callback = abort_callback;
    ctx->abort_callback_data = user_data;
}

bool ggml_metal_supports_family(ggml_metal_t ctx, int family) {
    GGML_ASSERT(ctx->dev != nil);

    id<MTLDevice> device = ggml_metal_device_get_obj(ctx->dev);

    return [device supportsFamily:(MTLGPUFamilyApple1 + family - 1)];
}

void ggml_metal_capture_next_compute(ggml_metal_t ctx) {
    ctx->capture_compute = 1;
}
