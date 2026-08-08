#include "ggml-ane.h"

#include "ggml.h"
#include "ggml-impl.h"
#include "ggml-backend-impl.h"
#include "gguf_weight_stream.h"
// Regime router: learned per-(family, shape) path-preference
// override of the static TILE640 cost model in ggml-quants.h.
// The router is a static-include lookup table in
// ggml-regime-router.h with the generated policy in
// ggml-regime-router.gen.h. The router is a strict no-op when
// the calibration runner has not yet produced any entries: the
// lookup helpers fall back to ts_t640_*_accel_wins on FAM_OTHER
// / out-of-range shape_bucket / no matching entry.
// See docs/ane-backend-deep-study.md Part 6.10 for the design.
#include "ggml-regime-router.h"
#include "ggml-regime-router.gen.h"

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

// TILE640 host dequant + batched helpers (ggml-quants.c):
// dequantize_row_tessera_t640 (flat row buffer),
// dequantize_row_tessera_t640_with_meta (pre-decoded meta),
// ts_decode_per_row_meta / ts_apply_outlier_addback (batched,
// accel + scalar paths selected per call), and the accel
// feature flag. The GGML_OP_TILE640_MATMUL path below dequants
// the weight on the host into the bundle's pinned fp16 slot.
#include "ggml-quants.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// ane-state.h lives in common/ (the llama.cpp-side runtime) and is
// shared with the conversion tool's manifest schema. ggml-ane is a
// leaf backend and does not link common/, so we include the header
// by relative path from ggml/src/ggml-ane/. The manifest is the
// contract between the conversion tool (tools/ane-mtp/) and the
// runtime (ggml-ane + common/ane-mtp.mm + the future
// common/ane-pump.mm); see tools/ane-mtp/state_layout.py for the
// JSON side and tools/ane-mtp/test_state_layout.py for the
// 24-test unit suite.
#include "../../../common/ane-state.h"
#include "../../../common/ane-state-layout.h"

#define GGML_ANE_NAME "ANE"

// IOSurface page alignment used by common/ane-mtp.mm. All ANE tensor I/O goes
// through IOSurface shared memory, so every allocation must be a multiple of
// this page size.
static const size_t GGML_ANE_PAGE = 16 * 1024;

// Minimum IOSurface allocation. Orion constraint #4: allocations below ~49 KB
// compile but fail at evaluation (ANE error 0x1d). 64 KB is the next 16 KB
// page multiple that clears the 49 KB floor, so use it for every buffer.
static const size_t GGML_ANE_MIN_ALLOC = 64 * 1024;

// Round `size` up to the IOSurface page, then enforce the 64 KB ANE floor.
static size_t ggml_ane_round_size(size_t size) {
    size_t rounded = ((size + GGML_ANE_PAGE - 1) / GGML_ANE_PAGE) * GGML_ANE_PAGE;
    if (rounded < GGML_ANE_MIN_ALLOC) {
        rounded = GGML_ANE_MIN_ALLOC;
    }
    return rounded;
}

// forward declaration
static bool ggml_backend_buffer_is_ane(ggml_backend_buffer_t buffer);

////////////////////////////////////////////////////////////////////////////////
// buffer context: one locked IOSurface per ggml_backend_buffer
////////////////////////////////////////////////////////////////////////////////

struct ggml_backend_ane_buffer_context {
    IOSurfaceRef surface = nullptr;
    void *       base    = nullptr;
    size_t       size    = 0;

    ~ggml_backend_ane_buffer_context() {
        if (surface) {
            IOSurfaceUnlock(surface, 0, nullptr);
            CFRelease(surface);
            surface = nullptr;
        }
        base = nullptr;
    }
};

static ggml_backend_ane_buffer_context * ggml_backend_ane_buffer_context_alloc(size_t size) {
    size_t rounded = ggml_ane_round_size(size);

    // Flat 1 x rounded IOSurface, matching common/ane-mtp.mm. The ANE reads a
    // flat allocation as packed [1, C, 1, S] (Orion #20); the host writes
    // packed data at the buffer start and the ANE compiler manages the rest.
    NSDictionary * properties = @{
        (id) kIOSurfaceWidth:          @(rounded),
        (id) kIOSurfaceHeight:         @1,
        (id) kIOSurfaceBytesPerElement:@1,
        (id) kIOSurfaceBytesPerRow:    @(rounded),
        (id) kIOSurfaceAllocSize:      @(rounded),
    };

    IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef) properties);
    if (!surface) {
        GGML_LOG_ERROR("%s: IOSurfaceCreate failed for %zu bytes\n", __func__, rounded);
        return nullptr;
    }

    if (IOSurfaceLock(surface, 0, nullptr) != kIOReturnSuccess) {
        GGML_LOG_ERROR("%s: IOSurfaceLock failed\n", __func__);
        CFRelease(surface);
        return nullptr;
    }

    void * base = IOSurfaceGetBaseAddress(surface);
    if (!base) {
        GGML_LOG_ERROR("%s: IOSurfaceGetBaseAddress returned null\n", __func__);
        IOSurfaceUnlock(surface, 0, nullptr);
        CFRelease(surface);
        return nullptr;
    }

    auto * ctx = new ggml_backend_ane_buffer_context;
    ctx->surface = surface;
    ctx->base    = base;
    ctx->size    = rounded;
    return ctx;
}

////////////////////////////////////////////////////////////////////////////////
// buffer vtable
////////////////////////////////////////////////////////////////////////////////

static void ggml_backend_ane_buffer_free_buffer(ggml_backend_buffer_t buffer) {
    ggml_backend_ane_buffer_context * ctx = (ggml_backend_ane_buffer_context *) buffer->context;
    delete ctx;
}

static void * ggml_backend_ane_buffer_get_base(ggml_backend_buffer_t buffer) {
    ggml_backend_ane_buffer_context * ctx = (ggml_backend_ane_buffer_context *) buffer->context;
    return ctx->base;
}

static void ggml_backend_ane_buffer_set_tensor(ggml_backend_buffer_t buffer, ggml_tensor * tensor, const void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor));
    GGML_UNUSED(buffer);

    // offset is relative to the tensor, not the buffer. tensor->data already
    // points at this tensor's slot inside the locked IOSurface, so write there.
    // The IOSurface stays locked for the buffer lifetime; ordering against ANE
    // reads is the caller's responsibility (via the event vtable, later).
    memcpy((char *) tensor->data + offset, data, size);
}

static void ggml_backend_ane_buffer_get_tensor(ggml_backend_buffer_t buffer, const ggml_tensor * tensor, void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor));
    GGML_UNUSED(buffer);

    memcpy(data, (const char *) tensor->data + offset, size);
}

static void ggml_backend_ane_buffer_memset_tensor(ggml_backend_buffer_t buffer, ggml_tensor * tensor, uint8_t value, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor));
    GGML_UNUSED(buffer);

    memset((char *) tensor->data + offset, value, size);
}

static bool ggml_backend_ane_buffer_cpy_tensor(ggml_backend_buffer_t buffer, const ggml_tensor * src, ggml_tensor * dst) {
    // Slice 1 only needs the host-visible memcpy path. dst lives in this ANE
    // buffer; src may be in any buffer type. ANE-to-ANE copies are also served
    // by this path because both sides are CPU-mapped while locked.
    GGML_UNUSED(buffer);

    if (!ggml_are_same_shape(src, dst)) {
        return false;
    }

    size_t nbytes = ggml_nbytes(src);
    // ggml_backend_buffer_get_base handles views via the buffer context.
    memcpy((char *) dst->data, src->data, nbytes);
    return true;
}

static void ggml_backend_ane_buffer_clear(ggml_backend_buffer_t buffer, uint8_t value) {
    ggml_backend_ane_buffer_context * ctx = (ggml_backend_ane_buffer_context *) buffer->context;
    memset(ctx->base, value, ctx->size);
}

static ggml_backend_buffer_i ggml_backend_ane_buffer_i = {
    /* .free_buffer   = */ ggml_backend_ane_buffer_free_buffer,
    /* .get_base      = */ ggml_backend_ane_buffer_get_base,
    /* .init_tensor   = */ NULL,
    /* .memset_tensor = */ ggml_backend_ane_buffer_memset_tensor,
    /* .set_tensor    = */ ggml_backend_ane_buffer_set_tensor,
    /* .get_tensor    = */ ggml_backend_ane_buffer_get_tensor,
    /* .set_tensor_2d = */ NULL,
    /* .get_tensor_2d = */ NULL,
    /* .cpy_tensor    = */ ggml_backend_ane_buffer_cpy_tensor,
    /* .clear         = */ ggml_backend_ane_buffer_clear,
    /* .reset         = */ NULL,
};

static bool ggml_backend_buffer_is_ane(ggml_backend_buffer_t buffer) {
    return buffer->iface.free_buffer == ggml_backend_ane_buffer_free_buffer;
}

////////////////////////////////////////////////////////////////////////////////
// buffer type
////////////////////////////////////////////////////////////////////////////////

static const char * ggml_backend_ane_buffer_type_get_name(ggml_backend_buffer_type_t buft) {
    return GGML_ANE_NAME;

    GGML_UNUSED(buft);
}

static ggml_backend_buffer_t ggml_backend_ane_buffer_type_alloc_buffer(ggml_backend_buffer_type_t buft, size_t size) {
    ggml_backend_ane_buffer_context * ctx = ggml_backend_ane_buffer_context_alloc(size);
    if (!ctx) {
        return nullptr;
    }

    // Report the requested size (not the IOSurface-rounded size) so the
    // allocator bookkeeping matches what callers asked for. The backing store
    // is always at least GGML_ANE_MIN_ALLOC.
    return ggml_backend_buffer_init(buft, ggml_backend_ane_buffer_i, ctx, size);
}

static size_t ggml_backend_ane_buffer_type_get_alignment(ggml_backend_buffer_type_t buft) {
    // IOSurface allocations are page aligned and the first tensor in a buffer
    // is placed at the buffer base, so tensor offsets within a buffer must
    // also be page aligned.
    return GGML_ANE_PAGE;

    GGML_UNUSED(buft);
}

static size_t ggml_backend_ane_buffer_type_get_max_size(ggml_backend_buffer_type_t buft) {
    return SIZE_MAX;

    GGML_UNUSED(buft);
}

static size_t ggml_backend_ane_buffer_type_get_alloc_size(ggml_backend_buffer_type_t buft, const ggml_tensor * tensor) {
    // Tensor-local allocation size follows ggml's default (the tensor's byte
    // footprint). The 64 KB floor and page rounding are applied once when the
    // containing buffer is allocated.
    return ggml_nbytes(tensor);

    GGML_UNUSED(buft);
}

static bool ggml_backend_ane_buffer_type_is_host(ggml_backend_buffer_type_t buft) {
    // IOSurface backing is not in the standard CPU address space without an
    // explicit lock/map. Returning false keeps the scheduler from assuming
    // zero-cost host access (deep-study Section 4.5 recommendation 4).
    return false;

    GGML_UNUSED(buft);
}

static ggml_backend_buffer_type_t ggml_backend_ane_buffer_type(void) {
    static ggml_backend_buffer_type buft;
    static bool initialized = false;

    {
        static std::mutex mutex;
        std::lock_guard<std::mutex> lock(mutex);

        if (!initialized) {
            buft = {
                /* .iface = */ {
                    /* .get_name       = */ ggml_backend_ane_buffer_type_get_name,
                    /* .alloc_buffer   = */ ggml_backend_ane_buffer_type_alloc_buffer,
                    /* .get_alignment  = */ ggml_backend_ane_buffer_type_get_alignment,
                    /* .get_max_size   = */ ggml_backend_ane_buffer_type_get_max_size,
                    /* .get_alloc_size = */ ggml_backend_ane_buffer_type_get_alloc_size,
                    /* .is_host        = */ ggml_backend_ane_buffer_type_is_host,
                },
                /* .device  = */ nullptr, // wired in during device init
                /* .context = */ nullptr,
            };

            initialized = true;
        }
    }

    return &buft;
}

////////////////////////////////////////////////////////////////////////////////
// Core ML program runner
//
// Self-contained Core ML loader + predictor. It reuses the IOSurface-backed
// arena and MLMultiArray wrapping patterns from common/ane-mtp.mm but does
// not call into common_ane_mtp_* because those are coupled to llama_context
// and GGUF embedding at the wrong layer for a ggml backend. The ggml-ane
// dylib links only libggml-base and system frameworks (Foundation, IOSurface,
// CoreML, Accelerate); linking common/llama here would invert the dependency
// graph (a leaf backend depending on the high-level application libraries).
//
// One program = one compiled .mlmodelc directory, one Core ML function, and
// its own serial dispatch queue for ordering predictions (deep-study Section
// 4.3.2). Inputs/outputs are materialized in the host-mapped IOSurface arena
// and wrapped zero-copy into MLMultiArray with a nil deallocator.

static size_t ggml_ane_multi_array_element_size(MLMultiArrayDataType type) {
    switch (type) {
        case MLMultiArrayDataTypeFloat16: return sizeof(ggml_fp16_t);
        case MLMultiArrayDataTypeFloat32: return sizeof(float);
        case MLMultiArrayDataTypeInt32:   return sizeof(int32_t);
        default:                          return 0;
    }
}

static NSArray<NSNumber *> * ggml_ane_contiguous_strides(NSArray<NSNumber *> * shape) {
    NSMutableArray<NSNumber *> * result = [NSMutableArray arrayWithCapacity:shape.count];
    NSUInteger stride = 1;
    for (NSInteger i = (NSInteger) shape.count - 1; i >= 0; --i) {
        [result insertObject:@(stride) atIndex:0];
        stride *= shape[(NSUInteger) i].unsignedIntegerValue;
    }
    return result;
}

static size_t ggml_ane_shape_count(NSArray<NSNumber *> * shape) {
    size_t count = 1;
    for (NSNumber * dimension in shape) {
        count *= dimension.unsignedIntegerValue;
    }
    return count;
}

// Flat host-mapped arena slot. IOSurface backing satisfies the ANE 64-byte
// alignment and 49 KB floor (Orion constraints #4 and #20). Reuses the
// reserve-on-grow policy from common_ane_mtp_arena_buffer.
//
// (Kept for the elementwise/Accelerate path in graph_compute; the bundle
// dispatch path uses the pinned-slot state below.)
struct ggml_ane_arena_slot {
    IOSurfaceRef surface = nullptr;
    void *       data    = nullptr;
    size_t       capacity = 0;

    ~ggml_ane_arena_slot() {
        if (surface) {
            IOSurfaceUnlock(surface, 0, nullptr);
            CFRelease(surface);
            surface = nullptr;
        }
        data = nullptr;
    }

    bool reserve(size_t size) {
        if (capacity >= size) {
            return true;
        }
        size_t rounded = ((size + GGML_ANE_PAGE - 1) / GGML_ANE_PAGE) * GGML_ANE_PAGE;
        if (rounded < GGML_ANE_MIN_ALLOC) {
            rounded = GGML_ANE_MIN_ALLOC;
        }
        NSDictionary * properties = @{
            (id) kIOSurfaceWidth:          @(rounded),
            (id) kIOSurfaceHeight:         @1,
            (id) kIOSurfaceBytesPerElement:@1,
            (id) kIOSurfaceBytesPerRow:    @(rounded),
            (id) kIOSurfaceAllocSize:      @(rounded),
        };
        IOSurfaceRef replacement = IOSurfaceCreate((CFDictionaryRef) properties);
        if (!replacement || IOSurfaceLock(replacement, 0, nullptr) != kIOReturnSuccess) {
            if (replacement) {
                CFRelease(replacement);
            }
            return false;
        }
        void * replacement_data = IOSurfaceGetBaseAddress(replacement);
        if (!replacement_data) {
            IOSurfaceUnlock(replacement, 0, nullptr);
            CFRelease(replacement);
            return false;
        }
        if (surface) {
            IOSurfaceUnlock(surface, 0, nullptr);
            CFRelease(surface);
        }
        surface = replacement;
        data    = replacement_data;
        capacity = rounded;
        return true;
    }
};

// Multifunction IOSurface-mapped stateful ANE program.
//
// The .mlmodelc is loaded as a stateless Core ML model. All "state"
// lives in a single IOSurface (the state_buffer below) whose layout
// is described by the ane_state_layout_v1 manifest emitted by the
// conversion tool. Each declared slot is pinned at load to a
// deterministic offset in that IOSurface as an MLMultiArray with
// deallocator:nil (zero-copy, see common/ane-mtp.mm's wrap_multi_array
// for the canonical pattern). The dispatch path uses Core ML's
// MLPredictionOptions.outputBackings to make Core ML write outputs
// directly into our pinned slots, skipping the result memcpy entirely.
//
// This replaces the per-function MLState + keepalive_state + 5s re-warm
// timer pattern of common/ane-mtp.mm (lines 842-880 in the multifunction
// case) and makes the state visible to Metal and CPU (zero-copy) so
// the E-core pump can coordinate ANE-Metal handoffs through the same
// canonical memory. See the architecture call in the session
// "proceed to implement it in full": one IOSurface, many readers,
// lock-free coordination via MTLSharedEvent.
struct ggml_backend_ane_program {
    // The Core ML model. Loaded stateless; state is in state_buffer
    // below. Retained in load(), released in the destructor (the
    // autoreleased-return + MRC + @autoreleasepool-drain dance that
    // the W1 commit fixed).
    MLModel *          model        = nil;

    // One serial dispatch queue per program. The multifunction case
    // (multiple functions in one .mlmodelc) will replace this with
    // per-function queues when the E-core pump lands; the W0/W1
    // single-function case keeps one queue at the program level.
    dispatch_queue_t   queue        = nullptr;

    // The parsed manifest. Owned by the program; freed in the
    // destructor. The manifest is the source of truth for the
    // IOSurface size, slot offsets, and which slots the bound
    // function reads/writes.
    ane_state_layout_v1_t layout;
    // True once the manifest has been parsed and validated.
    bool                  layout_loaded = false;

    // The single state IOSurface. All pinned slots live inside
    // this surface. Released by the destructor. We allocate via
    // ggml_backend_ane_iosurface_buffer_alloc (the existing
    // cross-backend IOSurface primitive) so the same surface can
    // be shared with Metal later.
    ggml_backend_buffer_t state_buffer = nullptr;
    void *                state_base   = nullptr;
    size_t                state_size   = 0;

    // Pinned MLMultiArray wrappers, one per manifest slot, at the
    // slot's offset inside state_buffer. Each wraps an IOSurface
    // subregion with deallocator:nil so Core ML reads/writes
    // through the same IOSurface pages the host uses. Index =
    // slot_id from the manifest; pinned_slots[i] corresponds to
    // layout.slots[i]. Released in the destructor.
    MLMultiArray *        pinned_slots[ANE_STATE_SLOTS_MAX] = {};

    // The bound function (index into layout.functions[]). The load
    // call's function_name parameter selects which manifest function
    // is bound; for the W0 single-function case it's "main".
    uint32_t              active_function_id = UINT32_MAX;

    // Scratch buffer for warmup inputs (zeroed, allocated once, freed
    // in the destructor). We allocate fresh IOSurface memory for
    // the warmup inputs so the pinned state slots stay zeroed from
    // before-load (the first real dispatch will overwrite them).
    void *                warmup_scratch  = nullptr;
    size_t                warmup_scratch_size = 0;

    // Phase 2 streaming: optional weight stream + per-program
    // cache. The stream is NULL in the legacy path (op->src[0..5]
    // carry the weight bytes in CPU memory, the dispatch reads
    // them directly). When set (via
    // ggml_backend_ane_program_set_weight_stream), the dispatch
    // overrides the op->src[i]->data pointers with bytes read
    // from the streamer's mmap'd GGUF. The cache (cached_layer +
    // cached_offsets + last_streamed_layer) keeps the current
    // layer's bytes warm in CPU memory across consecutive
    // dispatches; decode is M=1 per layer, so the same layer
    // fires N times before the layer index advances and a re-
    // stream is needed. Slice 3 wires the sync path; slice 4
    // adds the async prefetch that keeps the next layer warm
    // while the current layer dispatches.
    ane_weight_stream_t * weight_stream         = nullptr;
    // CPU-side copy of the most recently streamed layer. The
    // size is the max of any layer's total bytes (we recompute
    // it when the streamer is first attached).
    std::vector<uint8_t>  cached_layer_bytes;
    // Per-tensor (name -> (offset, size)) inside cached_layer_bytes,
    // matching the streamer's name-sorted layout. Built by the
    // refresh path; looked up by the dispatch via
    // ane_weight_stream_program_lookup.
    std::unordered_map<std::string, std::pair<size_t, size_t>>
                         cached_lookup;
    int32_t               last_streamed_layer  = -1;

    std::string        source_path;
    std::string        function_name;
    std::atomic<bool>  warm         {false};

    ~ggml_backend_ane_program() {
        // Release the pinned MLMultiArrays first; they reference the
        // IOSurface so they must be released before the buffer.
        for (uint32_t i = 0; i < layout.n_slots; ++i) {
            if (pinned_slots[i] != nil) {
                [pinned_slots[i] release];
                pinned_slots[i] = nil;
            }
        }
        // Free the state IOSurface (releases the IOSurface ref and
        // any internal MTLBuffer / CFObjectRef state).
        if (state_buffer != nullptr) {
            ggml_backend_buffer_free(state_buffer);
            state_buffer = nullptr;
        }
        state_base = nullptr;
        state_size = 0;
        // Free the warmup scratch.
        if (warmup_scratch != nullptr) {
            std::free(warmup_scratch);
            warmup_scratch = nullptr;
        }
        warmup_scratch_size = 0;
        // MRC release path. Order does not matter (model and queue
        // do not retain each other), but we release the queue last
        // because dispatch_release on a serial queue waits for
        // in-flight blocks; the program handle outlives the last
        // in-flight prediction only if no prediction is currently
        // using the queue.
        if (queue) {
            dispatch_release(queue);
            queue = nullptr;
        }
        if (model) {
            [model release];
            model = nil;
        }
    }
};

// Read the ane_state_layout.v1 manifest from a JSON file into the
// C struct. Thin wrapper around the shared reader in
// common/ane-state-layout.h so the multifunction common/ane-mtp.mm
// can use the same code path. The reader is strict: unknown
// versions, missing required fields, and bad slot/function refs
// are rejected. The C-side error string is logged to the ggml
// log so callers don't need to plumb error_out through.
static bool ggml_ane_read_manifest(const char * path, ane_state_layout_v1_t * layout) {
    std::string error;
    if (!ane_layout::read_state_layout(path, layout, &error)) {
        GGML_LOG_ERROR("ane: %s\n", error.c_str());
        return false;
    }
    return true;
}

// Wrap one IOSurface-backed slot as an MLMultiArray with deallocator:nil
// (zero-copy, see common/ane-mtp.mm:wrap_multi_array for the canonical
// pattern). The MLMultiArray's data pointer is state_base + slot.offset;
// its shape and dtype come from the manifest. The returned array is
// owned by the caller and must be released in the program's destructor.
static MLMultiArray * ggml_ane_pin_slot(void * state_base,
                                        const ane_slot_v1_t * slot) {
    NSError * error = nil;
    NSMutableArray<NSNumber *> * shape = [NSMutableArray arrayWithCapacity:slot->n_dim];
    for (uint32_t i = 0; i < slot->n_dim; ++i) {
        [shape addObject:@(slot->shape[i])];
    }
    NSArray<NSNumber *> * strides = ggml_ane_contiguous_strides(shape);
    MLMultiArrayDataType dtype = MLMultiArrayDataTypeFloat32;
    switch (slot->dtype) {
        case ANE_DTYPE_F32: dtype = MLMultiArrayDataTypeFloat32; break;
        case ANE_DTYPE_F16: dtype = MLMultiArrayDataTypeFloat16; break;
        case ANE_DTYPE_I32: dtype = MLMultiArrayDataTypeInt32;   break;
    }
    void * slot_base = (char *) state_base + slot->offset;
    return [[MLMultiArray alloc]
        initWithDataPointer:slot_base
                      shape:shape
                   dataType:dtype
                    strides:strides
                deallocator:nil
                      error:&error];
}

// Warm the loaded function with zeroed inputs sized from the manifest.
// Mirrors warm_model() in common/ane-mtp.mm but uses the pinned state
// slots for inputs (zeroed) and discards the warmup output. A failed
// warmup means the bundle cannot run on this host (wrong OS, ANE
// missing, or a Core ML compile error) and the program must not be
// advertised. This is the only point where we send a Core ML
// prediction through; per-iter dispatch lives in ggml_ane_program_run.
static bool ggml_ane_program_warm(ggml_backend_ane_program * program) {
    @autoreleasepool {
        const ane_function_v1_t * func = &program->layout.functions[program->active_function_id];
        NSError * error = nil;
        NSMutableDictionary<NSString *, MLFeatureValue *> * values = [NSMutableDictionary dictionary];
        for (uint32_t i = 0; i < func->n_inputs; ++i) {
            const uint32_t slot_id = func->input_slot_ids[i];
            const ane_slot_v1_t * slot = &program->layout.slots[slot_id];
            // The pinned slot is the live state. For warmup we want to
            // send a zeroed copy so the real first dispatch isn't
            // polluted by a prior warmup result. We allocate a fresh
            // MLMultiArray for the warmup input (its data is zeroed
            // here; pinned state stays untouched until first real
            // dispatch).
            const size_t esize = ggml_ane_multi_array_element_size(
                program->pinned_slots[slot_id].dataType);
            if (esize == 0) {
                return false;
            }
            if (program->warmup_scratch_size < slot->size_bytes) {
                if (program->warmup_scratch != nullptr) {
                    std::free(program->warmup_scratch);
                }
                program->warmup_scratch = std::malloc(slot->size_bytes);
                program->warmup_scratch_size = slot->size_bytes;
            }
            std::memset(program->warmup_scratch, 0, slot->size_bytes);
            NSMutableArray<NSNumber *> * shape = [NSMutableArray arrayWithCapacity:slot->n_dim];
            for (uint32_t j = 0; j < slot->n_dim; ++j) {
                [shape addObject:@(slot->shape[j])];
            }
            NSArray<NSNumber *> * strides = ggml_ane_contiguous_strides(shape);
            MLMultiArray * warmup_input = [[MLMultiArray alloc]
                initWithDataPointer:program->warmup_scratch
                              shape:shape
                           dataType:program->pinned_slots[slot_id].dataType
                            strides:strides
                        deallocator:nil
                              error:&error];
            if (warmup_input == nil) {
                return false;
            }
            values[[NSString stringWithUTF8String:slot->name]] =
                [MLFeatureValue featureValueWithMultiArray:warmup_input];
        }
        MLDictionaryFeatureProvider * inputs =
            [[MLDictionaryFeatureProvider alloc] initWithDictionary:values error:&error];
        if (inputs == nil) {
            GGML_LOG_ERROR("ane: warmup input provider build failed: %s\n",
                           error.localizedDescription.UTF8String ?: "unknown");
            return false;
        }
        MLPredictionOptions * options = [[MLPredictionOptions alloc] init];
        // The warmup doesn't write to our pinned state slots (we
        // discard the output); the model's internal allocator gives
        // us a throwaway result. Real dispatches use outputBackings.
        id<MLFeatureProvider> output = [program->model
            predictionFromFeatures:inputs
                           options:options
                             error:&error];
        if (output == nil) {
            GGML_LOG_ERROR("ane: warmup prediction failed: %s\n",
                           error.localizedDescription.UTF8String ?: "unknown error");
            return false;
        }
        return true;
    }
}

static ggml_backend_ane_program * ggml_ane_program_load(const char * mlmodelc_dir,
                                                        const char * function_name) {
    if (!mlmodelc_dir || mlmodelc_dir[0] == '\0') {
        return nullptr;
    }
    @autoreleasepool {
        NSString * dir = [NSString stringWithUTF8String:mlmodelc_dir];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            GGML_LOG_ERROR("ane: mlmodelc dir not found: %s\n", mlmodelc_dir);
            return nullptr;
        }
        // Resolve the manifest path. The convention is
        // <bundle-stem>.ane_state.v1.json in the same directory as
        // the .mlmodelc. The bundle stem is the .mlmodelc's
        // directory name (e.g., w0-256x256.mlmodelc -> "w0-256x256").
        NSString * dir_name = [dir lastPathComponent];
        NSString * parent = [dir stringByDeletingLastPathComponent];
        NSString * bundle_stem = [dir_name stringByDeletingPathExtension];
        NSString * manifest_path = [parent
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.ane_state.v1.json", bundle_stem]];

        // Load the manifest. The manifest is REQUIRED (the design
        // is locked: stateless at the Core ML level, stateful via
        // the IOSurface). A missing or bad manifest is a load
        // failure.
        auto * program = new ggml_backend_ane_program;
        if (!ggml_ane_read_manifest(manifest_path.UTF8String,
                                    &program->layout)) {
            GGML_LOG_ERROR("ane: failed to load manifest at %s\n",
                           manifest_path.UTF8String);
            delete program;
            return nullptr;
        }
        program->layout_loaded = true;

        // Resolve the bound function by name. function_name == null
        // or "" means: pick the first function (the W0 single-
        // function case). For multifunction bundles, the caller
        // must specify which function to bind.
        const std::string desired = (function_name != nullptr && function_name[0] != '\0')
            ? std::string(function_name) : std::string();
        for (uint32_t i = 0; i < program->layout.n_functions; ++i) {
            const std::string fname(program->layout.functions[i].name);
            if (desired.empty() || fname == desired) {
                program->active_function_id = i;
                program->function_name = fname;
                break;
            }
        }
        if (program->active_function_id == UINT32_MAX) {
            GGML_LOG_ERROR("ane: no function matching %s in manifest\n",
                           function_name ? function_name : "(default)");
            delete program;
            return nullptr;
        }

        // Allocate the state IOSurface. One buffer of
        // state_size_bytes; every pinned slot lives inside it.
        program->state_buffer = ggml_backend_ane_iosurface_buffer_alloc(
            program->layout.state_size_bytes);
        if (program->state_buffer == nullptr) {
            GGML_LOG_ERROR("ane: failed to allocate state IOSurface (%zu bytes)\n",
                           program->layout.state_size_bytes);
            delete program;
            return nullptr;
        }
        program->state_base = ggml_backend_buffer_get_base(program->state_buffer);
        program->state_size = program->layout.state_size_bytes;

        // Pin each declared slot at its manifest offset as an
        // MLMultiArray wrapping the IOSurface with deallocator:nil.
        // Core ML reads/writes through these arrays; the host
        // (E-core pump, ggml dispatch, Metal via MTLBuffer) reads/
        // writes the same physical pages.
        for (uint32_t i = 0; i < program->layout.n_slots; ++i) {
            program->pinned_slots[i] = ggml_ane_pin_slot(
                program->state_base, &program->layout.slots[i]);
            if (program->pinned_slots[i] == nil) {
                GGML_LOG_ERROR("ane: failed to pin slot %s\n",
                               program->layout.slots[i].name);
                delete program;
                return nullptr;
            }
        }

        // Load the Core ML model. We do this AFTER the manifest
        // and state_buffer so a manifest failure doesn't leave
        // an autoreleased MLModel to dangle. Same MRC retain as
        // before (the W1 commit's fix).
        MLModelConfiguration * config = [[MLModelConfiguration alloc] init];
        config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
        const ane_function_v1_t * func =
            &program->layout.functions[program->active_function_id];
        // functionName is only legal for ML Program models. The
        // W0 spike's matmul is NeuralNetwork; setting functionName
        // there returns "must be nil unless the model type is ML
        // Program" at load time. We gate on the manifest's
        // model_type.
        if (program->layout.model_type == ANE_MODEL_TYPE_ML_PROGRAM &&
                func->core_ml_function_name[0] != '\0') {
            config.functionName =
                [NSString stringWithUTF8String:func->core_ml_function_name];
        }
        NSError * error = nil;
        MLModel * model = [MLModel modelWithContentsOfURL:
            [NSURL fileURLWithPath:dir]
                              configuration:config
                                      error:&error];
        if (model == nil) {
            GGML_LOG_ERROR("ane: failed to load %s: %s\n", mlmodelc_dir,
                           error.localizedDescription.UTF8String ?: "unknown error");
            delete program;
            return nullptr;
        }
        program->model = [model retain];

        program->queue = dispatch_queue_create(
            "org.ggml.ane.backend", DISPATCH_QUEUE_SERIAL);
        program->source_path = mlmodelc_dir;

        // Warm. We send zeroed inputs through the bound function
        // to compile it on the ANE; the result is discarded. The
        // pinned state slots are not modified by the warm (we use
        // a fresh warmup_scratch buffer for warm inputs).
        __block bool ok = false;
        dispatch_sync(program->queue, ^{
            ok = ggml_ane_program_warm(program);
        });
        if (!ok) {
            delete program;
            return nullptr;
        }
        program->warm.store(true);
        return program;
    }
}

// Device-level view of the bound program. The device supports_op
// runs before any backend context exists (weight-placement probes
// at model load, scheduler assignment at graph build), so it cannot
// reach the per-backend program pointer; it reads this instead.
// ggml_backend_ane_set_program keeps it in sync. ANE advertises the
// bundle-gated ops only while a program is bound: honest advertising,
// so the scheduler is free to route to every available device without
// ever handing ANE an op it has no bundle to run.
static std::atomic<ggml_backend_ane_program *> g_ane_bound_program { nullptr };

GGML_BACKEND_API struct ggml_backend_ane_program * ggml_backend_ane_program_load_from_dir(
        const char * mlmodelc_dir, const char * function_name) {
    return ggml_ane_program_load(mlmodelc_dir, function_name);
}

GGML_BACKEND_API void ggml_backend_ane_program_free(struct ggml_backend_ane_program * program) {
    // un-advertise the bundle-gated ops if this was the bound program
    ggml_backend_ane_program * expected = program;
    g_ane_bound_program.compare_exchange_strong(expected, nullptr);
    delete program;
}

// Phase 2 test-only: construct a minimal program with just
// the streaming fields initialized. No .mlmodelc, no Core ML
// model, no warmup. The returned program is only useful for
// the streaming helpers (refresh, lookup, parse_layer); the
// dispatch path will return false because the Core ML model
// isn't loaded. The caller frees the program with
// ggml_backend_ane_program_free.
GGML_BACKEND_API struct ggml_backend_ane_program *
ggml_backend_ane_program_create_empty(void) {
    auto * program = new ggml_backend_ane_program;
    program->weight_stream        = nullptr;
    program->last_streamed_layer  = -1;
    return program;
}

// Phase 2 (iPhone demo): attach a per-program weight stream
// to the program. The stream is held for the program's
// lifetime; ownership stays with the caller (the test or the
// role-aware loader). Passing NULL detaches (the dispatch
// falls back to the legacy op->src[0..5] path).
//
// The stream must remain valid until either
// ggml_backend_ane_program_set_weight_stream(program, NULL)
// is called or the program is freed. The runtime does not
// own the stream and does not close it.
GGML_BACKEND_API void ggml_backend_ane_program_set_weight_stream(
        struct ggml_backend_ane_program * program,
        struct ane_weight_stream_t * stream) {
    if (program == nullptr) return;
    program->weight_stream = stream;
    program->last_streamed_layer = -1;
    program->cached_lookup.clear();
    // The cache buffer is sized to the largest layer's total
    // bytes on first refresh. The dispatch's stream call will
    // grow it as needed (the streamer's stream_layer returns
    // the layer's total bytes; we resize the vector to that).
    program->cached_layer_bytes.clear();
}

// Phase 2: parse the layer index out of a tensor name.
// Returns the layer index (>= 0) on success, or -1 if the
// name doesn't match the `blk.L.` prefix convention. The
// conversion tool emits the trunk's per-layer tensors under
// the `blk.L.<family>.weight[_meta]` convention; the dispatch
// uses this helper to know which layer's stream to refresh
// for the current op.
//
// The parser is intentionally strict: the name must START with
// "blk." followed by digits and a dot. Names like "blk.5."
// (with no family) are accepted (the layer is the index);
// names like "blk.5a.attn_q" are rejected (non-digit after
// the layer number).
static int32_t ane_weight_stream_parse_layer(const char * name) {
    if (name == nullptr) return -1;
    if (name[0] != 'b' || name[1] != 'l' || name[2] != 'k' || name[3] != '.') {
        return -1;
    }
    const char * p = name + 4;
    int32_t layer = 0;
    if (*p < '0' || *p > '9') return -1;
    while (*p >= '0' && *p <= '9') {
        layer = layer * 10 + (*p - '0');
        ++p;
        // Cap at the maximum realistic layer count (4-digit
        // index is 9999; gemma 4 12B has 28 layers, no
        // realistic model is > 1000).
        if (layer > 9999) return -1;
    }
    if (*p != '.') return -1;
    return layer;
}

// Phase 2: refresh the per-program layer cache. Reads the
// given layer's tensors from the streamer into the program's
// CPU cache and rebuilds the per-tensor (offset, size) lookup
// table. Returns true on success, false on failure (reason
// logged via ggml log).
//
// The cache is keyed on (streamer, layer); the caller is
// expected to skip the refresh when the layer hasn't changed
// (the dispatch checks program->last_streamed_layer before
// calling this). The helper does NOT check that invariant;
// it's the caller's responsibility.
static bool ane_weight_stream_program_refresh(
        struct ggml_backend_ane_program * program,
        int32_t layer_idx) {
    if (program == nullptr || program->weight_stream == nullptr) return false;
    if (layer_idx < 0) return false;
    // Build the per-tensor lookup from the streamer's index.
    // The streamer's n_block_tensors tells us how many tensors
    // belong to this layer; we walk the indices to capture
    // (name, size_bytes) for each.
    const uint32_t n = ane_weight_stream_n_block_tensors(
        program->weight_stream, layer_idx);
    if (n == 0) {
        GGML_LOG_ERROR("ane: refresh: layer %d has no tensors in the stream\n",
                       layer_idx);
        return false;
    }
    // Compute the layer's total bytes (sum of all per-tensor
    // sizes). The streamer's stream_layer also reports this
    // but we need the per-tensor breakdown to build the
    // lookup; doing it ourselves avoids a double-pass.
    uint64_t total = 0;
    std::vector<std::pair<std::string, uint64_t>> sizes;
    sizes.reserve(n);
    for (uint32_t i = 0; i < n; ++i) {
        const char * tname = nullptr;
        size_t      tsize  = 0;
        if (!ane_weight_stream_block_tensor_info(
                program->weight_stream, layer_idx, i,
                &tname, &tsize, nullptr, nullptr)) {
            return false;
        }
        sizes.emplace_back(tname ? std::string(tname) : std::string(), tsize);
        total += tsize;
    }
    if (total == 0 || total > SIZE_MAX) {
        GGML_LOG_ERROR("ane: refresh: layer %d has implausible total bytes "
                       "(%llu)\n", layer_idx, (unsigned long long) total);
        return false;
    }
    // Resize the cache buffer if needed.
    if (program->cached_layer_bytes.size() < (size_t) total) {
        program->cached_layer_bytes.resize((size_t) total);
    }
    // Stream into the cache. The streamer's stream_layer
    // writes name-sorted, contiguous bytes matching the
    // per-tensor offsets we compute below.
    const int64_t wrote = ane_weight_stream_layer(
        program->weight_stream, layer_idx,
        program->cached_layer_bytes.data(), (size_t) total);
    if (wrote != (int64_t) total) {
        GGML_LOG_ERROR("ane: refresh: layer %d stream_layer returned %lld, "
                       "expected %llu\n", layer_idx,
                       (long long) wrote, (unsigned long long) total);
        return false;
    }
    // Rebuild the per-tensor lookup. The streamer writes
    // tensors in the same name-sorted order we iterated
    // above, so the offsets match the running sum of sizes.
    program->cached_lookup.clear();
    uint64_t cursor = 0;
    for (const auto & kv : sizes) {
        if (cursor + kv.second > total) {
            GGML_LOG_ERROR("ane: refresh: per-tensor offset overflow for %s\n",
                           kv.first.c_str());
            return false;
        }
        program->cached_lookup[kv.first] =
            std::make_pair((size_t) cursor, (size_t) kv.second);
        cursor += kv.second;
    }
    program->last_streamed_layer = layer_idx;
    return true;
}

// Phase 2: look up a streamed tensor by name. Returns true
// if the name is in the cache; on success, sets *base_out to
// the byte pointer (inside program->cached_layer_bytes) and
// *size_out to the byte count. Returns false if the name
// isn't in the cache (caller should fall back to op->src[i]->
// data in that case).
static bool ane_weight_stream_program_lookup(
        const struct ggml_backend_ane_program * program,
        const char * name,
        const void ** base_out,
        size_t * size_out) {
    if (program == nullptr || name == nullptr || base_out == nullptr) {
        return false;
    }
    auto it = program->cached_lookup.find(name);
    if (it == program->cached_lookup.end()) return false;
    if (size_out) *size_out = it->second.second;
    *base_out = program->cached_layer_bytes.data() + it->second.first;
    return true;
}

// Public C API wrappers (also exposed via ggml-ane.h for tests
// and the role-aware loader). The internal helpers above are
// static; these are the GGML_BACKEND_API entry points.

GGML_BACKEND_API int32_t ggml_backend_ane_program_last_streamed_layer(
        const struct ggml_backend_ane_program * program) {
    if (program == nullptr) return -1;
    return program->last_streamed_layer;
}

GGML_BACKEND_API int32_t ggml_backend_ane_stream_parse_layer(
        const char * name) {
    return ane_weight_stream_parse_layer(name);
}

GGML_BACKEND_API bool ggml_backend_ane_stream_refresh_program(
        struct ggml_backend_ane_program * program,
        int32_t layer_idx) {
    return ane_weight_stream_program_refresh(program, layer_idx);
}

GGML_BACKEND_API bool ggml_backend_ane_stream_program_lookup(
        const struct ggml_backend_ane_program * program,
        const char * name,
        const void ** base_out,
        size_t * size_out) {
    return ane_weight_stream_program_lookup(program, name, base_out, size_out);
}

// Read an MLMultiArray into a host fp32 buffer. The common/ane-mtp.mm variant
// handles non-contiguous strides; we replicate just the contiguous fast path
// because every output we materialize lives in our own contiguous arena.
static void ggml_ane_read_array_fp32(const MLMultiArray * array, float * dst, size_t count) {
    if (array.dataType == MLMultiArrayDataTypeFloat32) {
        std::memcpy(dst, array.dataPointer, count * sizeof(float));
    } else {
        ggml_fp16_to_fp32_row((const ggml_fp16_t *) array.dataPointer, dst, (int64_t) count);
    }
}

static void ggml_ane_write_array_fp32(const float * src, MLMultiArray * array, size_t count) {
    if (array.dataType == MLMultiArrayDataTypeFloat32) {
        std::memcpy(array.dataPointer, src, count * sizeof(float));
    } else {
        ggml_fp32_to_fp16_row(src, (ggml_fp16_t *) array.dataPointer, (int64_t) count);
    }
}

// Typed input: data pointer + host dtype. The runtime converts
// from the host dtype to the slot's dtype (declared by the
// .mlmodelc). Supported host dtypes: fp32, fp16, i32. The
// .mlmodelc's slot dtypes are constrained by the bundle's
// TensorType declarations.
//
// Phase 0 (TILE640_MATMUL) ships the typed path because the
// bundle takes the host-dedequantized weight as fp16 (not
// fp32). The existing fp32-only path is preserved as a thin
// wrapper for the body-op dispatchers (RMS_NORM, SOFT_MAX,
// ROPE, GLU, GET_ROWS, MUL_MAT), which all use fp32 today.
enum ggml_ane_input_dtype {
    GGML_ANE_INPUT_FP32 = 0,
    GGML_ANE_INPUT_FP16 = 1,
    GGML_ANE_INPUT_I32  = 2,
};

struct ggml_ane_typed_input {
    const void * data;
    ggml_ane_input_dtype dtype;
};

// Write a host buffer into a pinned slot, converting from the
// host dtype to the slot's dtype when they differ. For
// dtype matches, it's a straight memcpy; for mismatches, it's
// an elementwise conversion (fp32<->fp16 today; i32 stays
// i32). The conversion happens in the dispatch queue (off
// the per-thread hot path).
static void ggml_ane_write_array_typed(const ggml_ane_typed_input & src,
                                        MLMultiArray * array, size_t count) {
    const MLMultiArrayDataType slot_dtype = array.dataType;
    const size_t slot_esize = ggml_ane_multi_array_element_size(slot_dtype);
    if (src.dtype == GGML_ANE_INPUT_FP32 && slot_dtype == MLMultiArrayDataTypeFloat32) {
        std::memcpy(array.dataPointer, src.data, count * sizeof(float));
        return;
    }
    if (src.dtype == GGML_ANE_INPUT_FP16 && slot_dtype == MLMultiArrayDataTypeFloat16) {
        std::memcpy(array.dataPointer, src.data, count * sizeof(ggml_fp16_t));
        return;
    }
    if (src.dtype == GGML_ANE_INPUT_I32 && slot_dtype == MLMultiArrayDataTypeInt32) {
        std::memcpy(array.dataPointer, src.data, count * sizeof(int32_t));
        return;
    }
    // Mixed dtypes: convert via the existing fp32 helper for
    // fp16<->fp32, or a small i32<->i32 loop. The Phase 0 L1
    // path never hits this branch (the bundle's w/x slots are
    // fp16 and the host supplies fp16 directly). The branch
    // exists for forward-compatibility with mixed-dtype
    // bundles in Phase 0.5.
    if (src.dtype == GGML_ANE_INPUT_FP32 && slot_dtype == MLMultiArrayDataTypeFloat16) {
        ggml_fp32_to_fp16_row((const float *) src.data,
                              (ggml_fp16_t *) array.dataPointer, (int64_t) count);
        return;
    }
    if (src.dtype == GGML_ANE_INPUT_FP16 && slot_dtype == MLMultiArrayDataTypeFloat32) {
        ggml_fp16_to_fp32_row((const ggml_fp16_t *) src.data,
                              (float *) array.dataPointer, (int64_t) count);
        return;
    }
    if (src.dtype == GGML_ANE_INPUT_I32 && slot_dtype == MLMultiArrayDataTypeFloat32) {
        const int32_t * p = (const int32_t *) src.data;
        float * d = (float *) array.dataPointer;
        for (size_t i = 0; i < count; ++i) d[i] = (float) p[i];
        return;
    }
    // Last-resort: zero the slot so a wrong-dtype input does
    // not silently produce garbage. The dispatch policy
    // validates dtypes up front; reaching this branch is a
    // logic error in supports_op / dispatch_op.
    std::memset(array.dataPointer, 0, count * slot_esize);
}

// Run the bound program: feed inputs from the host into the pinned
// state slots, dispatch the bound function with outputBackings set so
// Core ML writes outputs directly into our pinned slots, and read
// the outputs back from those same slots (zero-copy, no result
// memcpy). The function is the one bound at load (program-
// >active_function_id); the inputs/outputs maps are by model-
// declared name and must match the manifest's slot names for the
// bound function. Returns false (with a logged warning) when Core
// ML returns nil; the caller is responsible for falling back to
// Metal/CPU.
//
// Inputs are typed (fp32 / fp16 / i32 host buffers); the runtime
// converts to the slot's declared dtype (the .mlmodelc's
// TensorType). The Phase 0 L1 path passes fp16 for the
// host-dedequantized weight and the fp16 activations; the
// existing fp32 body-op dispatchers wrap their float pointers
// in a typed input and the slot dtype matches.
static bool ggml_ane_program_run(ggml_backend_ane_program * program,
                                 const std::unordered_map<std::string, ggml_ane_typed_input> & inputs,
                                 const std::vector<std::string> & output_names,
                                 const std::unordered_map<std::string, float *> & outputs) {
    if (!program || !program->warm.load() || !program->layout_loaded) {
        return false;
    }
    const ane_function_v1_t * func =
        &program->layout.functions[program->active_function_id];

    __block bool ok = false;
    dispatch_sync(program->queue, ^{
        @autoreleasepool {
            NSError * error = nil;

            // Build the input feature dict from the bound function's
            // manifest input slots. Each pinned slot is the
            // IOSurface-backed MLMultiArray; we memcpy the host
            // buffer (in the host's dtype) into the IOSurface bytes,
            // converting to the slot's dtype when they differ
            // (ggml_ane_write_array_typed handles the common cases
            // without an intermediate buffer).
            NSMutableDictionary<NSString *, MLFeatureValue *> * features =
                [NSMutableDictionary dictionary];
            for (uint32_t i = 0; i < func->n_inputs; ++i) {
                const uint32_t slot_id = func->input_slot_ids[i];
                const ane_slot_v1_t * slot = &program->layout.slots[slot_id];
                MLMultiArray * pinned = program->pinned_slots[slot_id];
                if (pinned == nil) {
                    GGML_LOG_ERROR("ane: input slot %s not pinned\n", slot->name);
                    return;
                }
                const size_t count = (size_t) pinned.count;
                auto it = inputs.find(slot->name);
                if (it != inputs.end() && it->second.data) {
                    ggml_ane_write_array_typed(it->second, pinned, count);
                } else {
                    // No host-side data: leave the slot as-is. The
                    // caller is responsible for ensuring prior calls
                    // have populated STATE-kind slots; for INPUT-kind
                    // slots without a host value, we zero so the
                    // first real dispatch isn't polluted.
                    if (slot->kind == ANE_SLOT_KIND_INPUT) {
                        std::memset(pinned.dataPointer, 0,
                                    count * ggml_ane_multi_array_element_size(
                                        pinned.dataType));
                    }
                }
                features[[NSString stringWithUTF8String:slot->name]] =
                    [MLFeatureValue featureValueWithMultiArray:pinned];
            }

            MLDictionaryFeatureProvider * provider =
                [[MLDictionaryFeatureProvider alloc]
                    initWithDictionary:features error:&error];
            if (provider == nil) {
                GGML_LOG_ERROR("ane: input provider build failed: %s\n",
                               error.localizedDescription.UTF8String ?: "unknown");
                return;
            }

            // Build MLPredictionOptions with outputBackings = pinned
            // output slots. Core ML writes outputs directly into
            // our IOSurface bytes; the result provider's MLMultiArray
            // for each output name will be the SAME pointer as our
            // pinned slot (zero-copy, no result memcpy).
            MLPredictionOptions * options = [[MLPredictionOptions alloc] init];
            NSMutableDictionary<NSString *, MLMultiArray *> * backings =
                [NSMutableDictionary dictionary];
            for (uint32_t i = 0; i < func->n_outputs; ++i) {
                const uint32_t slot_id = func->output_slot_ids[i];
                const ane_slot_v1_t * slot = &program->layout.slots[slot_id];
                MLMultiArray * pinned = program->pinned_slots[slot_id];
                if (pinned == nil) {
                    GGML_LOG_ERROR("ane: output slot %s not pinned\n", slot->name);
                    return;
                }
                backings[[NSString stringWithUTF8String:slot->name]] = pinned;
            }
            options.outputBackings = backings;

            // Stateless dispatch. No usingState: — the design is
            // locked: state lives in our IOSurface, not in Core ML's
            // opaque MLState. If the bundle declares itself
            // stateful (e.g., a multifunction prefill with K/V
            // input slots), those slots are still read/written
            // through the IOSurface, not through an MLState.
            id<MLFeatureProvider> output = [program->model
                predictionFromFeatures:provider
                               options:options
                                 error:&error];
            if (output == nil) {
                // F1 failure mode: prediction-nil means Core ML
                // could not run the function on ANE (or CPU
                // fallback). Caller must retry on another backend.
                // Surface the model error verbatim.
                GGML_LOG_ERROR("ane: Core ML prediction returned nil for %s: %s\n",
                               program->function_name.c_str(),
                               error.localizedDescription.UTF8String ?: "unknown error");
                return;
            }
            // The result's MLMultiArrays are the same pointers as
            // our pinned output slots (outputBackings contract).
            // The outputs map (host dst) is by model-declared name;
            // we copy fp32 host dst out of the pinned slot's bytes
            // (with dtype conversion if the slot is fp16).
            for (const std::string & out_name : output_names) {
                MLMultiArray * arr = [output featureValueForName:
                    [NSString stringWithUTF8String:out_name.c_str()]].multiArrayValue;
                if (arr == nil) {
                    GGML_LOG_ERROR("ane: output %s missing from prediction\n", out_name.c_str());
                    return;
                }
                auto it = outputs.find(out_name);
                if (it != outputs.end() && it->second) {
                    ggml_ane_read_array_fp32(arr, it->second, (size_t) arr.count);
                }
            }
            ok = true;
        }
    });
    return ok;
}

////////////////////////////////////////////////////////////////////////////////
// backend (stream)
////////////////////////////////////////////////////////////////////////////////

// Per-backend context: holds the program currently bound to this instance.
// supports_op is declared below; forward-declared here for graph_compute.
static bool ggml_backend_ane_device_supports_op(ggml_backend_dev_t dev, const ggml_tensor * op);

struct ggml_backend_ane_context {
    // Not owned: the caller owns the program handle and must free it after
    // detaching. Storing a raw pointer keeps the backend struct trivially
    // destructible and avoids a refcount cycle with the program handle.
    std::atomic<ggml_backend_ane_program *> program {nullptr};
};

static const char * ggml_backend_ane_name(ggml_backend_t backend) {
    return GGML_ANE_NAME;

    GGML_UNUSED(backend);
}

static void ggml_backend_ane_free(ggml_backend_t backend) {
    // The bound program (if any) is owned by the caller via the
    // ggml_backend_ane_program handle, not by the backend struct.
    auto * ctx = (ggml_backend_ane_context *) backend->context;
    delete ctx;
    free(backend);
}

static void ggml_backend_ane_synchronize(ggml_backend_t backend) {
    // All compute is dispatched on the per-program serial queue with
    // dispatch_sync, so graph_compute is already synchronous on return.
    GGML_UNUSED(backend);
}

////////////////////////////////////////////////////////////////////////////////
// element-wise compute on the host-mapped IOSurface arena
//
// These ops are ANE-NATIVE per Section 4.1, but routing each one through a
// Core ML dispatch requires a bundle function that fuses it. When no bundle
// is bound we still need the backend to be exercisable, so the simple
// element-wise ops run on Accelerate over the same IOSurface backing that
// Core ML would read. This matches the deep-study "CPU-GLUE via Accelerate"
// fallback (Section 4.3.3) for the compute-shaped subset of native ops.
//
// Tensors in ANE buffers are CPU-mapped for the buffer lifetime, so a direct
// fp32/fp16 view is safe. We always compute in fp32 to avoid the fp16
// overflow failure modes (F10) in norm/activation paths.

static float * ggml_ane_tensor_f32_view(ggml_tensor * tensor, std::vector<float> & scratch) {
    // Returns either the tensor's own data (when already fp32 contiguous) or
    // a scratch buffer of fp32-converted data. Callers must hold the result
    // only across a single op because the scratch is overwritten per call.
    // Returns nullptr for a dtype the elementwise path cannot view; the
    // caller must fail the op loudly instead of miscomputing.
    const size_t n = ggml_nelements(tensor);
    if (tensor->type == GGML_TYPE_F32 && ggml_is_contiguous(tensor)) {
        return (float *) tensor->data;
    }
    scratch.resize(n);
    if (tensor->type == GGML_TYPE_F16) {
        ggml_fp16_to_fp32_row((const ggml_fp16_t *) tensor->data, scratch.data(), (int64_t) n);
    } else if (tensor->type == GGML_TYPE_F32) {
        // Non-contiguous fp32: copy elementwise.
        for (size_t i = 0; i < n; ++i) {
            scratch[i] = ((const float *) tensor->data)[i];
        }
    } else {
        return nullptr;
    }
    return scratch.data();
}

static bool ggml_ane_tensor_write_f32(ggml_tensor * tensor, const float * src) {
    const size_t n = ggml_nelements(tensor);
    if (tensor->type == GGML_TYPE_F32) {
        std::memcpy(tensor->data, src, n * sizeof(float));
    } else if (tensor->type == GGML_TYPE_F16) {
        ggml_fp32_to_fp16_row(src, (ggml_fp16_t *) tensor->data, (int64_t) n);
    } else {
        return false;
    }
    return true;
}

// Apply an elementwise op on fp32 views of src[0] (and src[1] for binary ops).
// dst is always written as the destination tensor's dtype.
static bool ggml_ane_compute_elementwise(ggml_tensor * op) {
    ggml_tensor * src0 = op->src[0];
    ggml_tensor * dst  = op;
    const size_t n = ggml_nelements(dst);

    std::vector<float> a_scratch;
    float * a = ggml_ane_tensor_f32_view(src0, a_scratch);
    if (a == nullptr) {
        return false;
    }

    std::vector<float> b_scratch;
    std::vector<float> out(n);

    switch (op->op) {
        case GGML_OP_ADD:
        case GGML_OP_MUL: {
            // Binary elementwise with ggml broadcast: src1 repeats over
            // src0's shape (ggml_can_repeat(src1, src0)), so the src1
            // index along each dim is i % ne1[d]. Fast paths cover the
            // equal-count and scalar cases; the generic loop walks rows.
            ggml_tensor * src1 = op->src[1];
            if (src1 == nullptr || !ggml_can_repeat(src1, src0)) {
                return false;
            }
            float * b = ggml_ane_tensor_f32_view(src1, b_scratch);
            if (b == nullptr) {
                return false;
            }
            const bool mul = (op->op == GGML_OP_MUL);
            const size_t n1 = ggml_nelements(src1);
            if (n1 == n) {
                if (mul) vDSP_vmul(a, 1, b, 1, out.data(), 1, n);
                else     vDSP_vadd(a, 1, b, 1, out.data(), 1, n);
            } else if (n1 == 1) {
                if (mul) vDSP_vsmul(a, 1, b, out.data(), 1, n);
                else     vDSP_vsadd(a, 1, b, out.data(), 1, n);
            } else {
                const int64_t * ne  = src0->ne;
                const int64_t * ne1 = src1->ne;
                for (int64_t i3 = 0; i3 < ne[3]; ++i3) {
                    const int64_t j3 = i3 % ne1[3];
                    for (int64_t i2 = 0; i2 < ne[2]; ++i2) {
                        const int64_t j2 = i2 % ne1[2];
                        for (int64_t i1 = 0; i1 < ne[1]; ++i1) {
                            const int64_t j1 = i1 % ne1[1];
                            const size_t row  = (size_t) ((i3*ne[2] + i2)*ne[1] + i1) * ne[0];
                            const size_t row1 = (size_t) ((j3*ne1[2] + j2)*ne1[1] + j1) * ne1[0];
                            if (ne1[0] == ne[0]) {
                                if (mul) vDSP_vmul(a + row, 1, b + row1, 1, out.data() + row, 1, ne[0]);
                                else     vDSP_vadd(a + row, 1, b + row1, 1, out.data() + row, 1, ne[0]);
                            } else if (ne1[0] == 1) {
                                if (mul) vDSP_vsmul(a + row, 1, b + row1, out.data() + row, 1, ne[0]);
                                else     vDSP_vsadd(a + row, 1, b + row1, out.data() + row, 1, ne[0]);
                            } else {
                                for (int64_t i0 = 0; i0 < ne[0]; ++i0) {
                                    const float bv = b[row1 + (size_t) (i0 % ne1[0])];
                                    out[row + i0] = mul ? a[row + i0]*bv : a[row + i0] + bv;
                                }
                            }
                        }
                    }
                }
            }
        } break;
        case GGML_OP_SCALE: {
            // ggml_scale stores the scalar in op_params[0].
            const float s = ggml_get_op_params_f32(op, 0);
            vDSP_vsmul(a, 1, &s, out.data(), 1, n);
        } break;
        case GGML_OP_CLAMP: {
            // ggml_clamp stores {min, max} in op_params[0..1].
            const float lo = ggml_get_op_params_f32(op, 0);
            const float hi = ggml_get_op_params_f32(op, 1);
            vDSP_vclip(a, 1, &lo, &hi, out.data(), 1, n);
        } break;
        case GGML_OP_REPEAT: {
            // Repeat src0 over dst per the ggml_repeat contract
            // (ggml_can_repeat(src0, dst)); the src0 index along each dim
            // is i % nes[d]. A flat tile is only correct when the repeat
            // is along the outermost non-unit dim, so walk rows instead.
            const int64_t * ne  = dst->ne;
            const int64_t * nes = src0->ne;
            if (!ggml_can_repeat(src0, dst)) {
                return false;
            }
            for (int64_t i3 = 0; i3 < ne[3]; ++i3) {
                const int64_t j3 = i3 % nes[3];
                for (int64_t i2 = 0; i2 < ne[2]; ++i2) {
                    const int64_t j2 = i2 % nes[2];
                    for (int64_t i1 = 0; i1 < ne[1]; ++i1) {
                        const int64_t j1 = i1 % nes[1];
                        const size_t row  = (size_t) ((i3*ne[2] + i2)*ne[1] + i1) * ne[0];
                        const size_t rows = (size_t) ((j3*nes[2] + j2)*nes[1] + j1) * nes[0];
                        if (nes[0] == ne[0]) {
                            std::memcpy(out.data() + row, a + rows, (size_t) ne[0] * sizeof(float));
                        } else {
                            for (int64_t i0 = 0; i0 < ne[0]; ++i0) {
                                out[row + i0] = a[rows + (size_t) (i0 % nes[0])];
                            }
                        }
                    }
                }
            }
        } break;
        case GGML_OP_LEAKY_RELU: {
            // ggml_leaky_relu stores negative_slope in op_params[0].
            const float slope = ggml_get_op_params_f32(op, 0);
            for (size_t i = 0; i < n; ++i) {
                out[i] = a[i] < 0.0f ? a[i] * slope : a[i];
            }
        } break;
        case GGML_OP_SQR:
            vDSP_vsq(a, 1, out.data(), 1, n);
            break;
        case GGML_OP_SQRT:
            vvsqrtf(out.data(), a, (const int *) &n);
            break;
        case GGML_OP_LOG:
            vvlogf(out.data(), a, (const int *) &n);
            break;
        case GGML_OP_SIN:
            vvsinf(out.data(), a, (const int *) &n);
            break;
        case GGML_OP_COS:
            vvcosf(out.data(), a, (const int *) &n);
            break;
        case GGML_OP_UNARY: {
            switch (ggml_get_unary_op(op)) {
                case GGML_UNARY_OP_SILU:    // x * sigmoid(x)
                    for (size_t i = 0; i < n; ++i) {
                        const float s = 1.0f / (1.0f + expf(-a[i]));
                        out[i] = a[i] * s;
                    }
                    break;
                case GGML_UNARY_OP_SIGMOID:
                    for (size_t i = 0; i < n; ++i) {
                        out[i] = 1.0f / (1.0f + expf(-a[i]));
                    }
                    break;
                case GGML_UNARY_OP_TANH:
                    vvtanhf(out.data(), a, (const int *) &n);
                    break;
                case GGML_UNARY_OP_RELU:
                    for (size_t i = 0; i < n; ++i) {
                        out[i] = a[i] < 0.0f ? 0.0f : a[i];
                    }
                    break;
                case GGML_UNARY_OP_EXP:
                    vvexpf(out.data(), a, (const int *) &n);
                    break;
                case GGML_UNARY_OP_ABS:
                    vvfabsf(out.data(), a, (const int *) &n);
                    break;
                case GGML_UNARY_OP_NEG:
                    vDSP_vneg(a, 1, out.data(), 1, n);
                    break;
                case GGML_UNARY_OP_STEP:
                    for (size_t i = 0; i < n; ++i) {
                        out[i] = a[i] > 0.0f ? 1.0f : 0.0f;
                    }
                    break;
                case GGML_UNARY_OP_SGN:
                    for (size_t i = 0; i < n; ++i) {
                        out[i] = a[i] > 0.0f ? 1.0f : (a[i] < 0.0f ? -1.0f : 0.0f);
                    }
                    break;
                // GELU/GELU_ERF/GELU_QUICK/HARDSWISH/HARDSIGMOID/ELU/SOFTPLUS/
                // EXPM1/FLOOR/CEIL/ROUND/TRUNC/XIELU are ANE-BREAKS or not on
                // the native list and are not advertised by supports_op.
                default:
                    return false;
            }
        } break;
        default:
            return false;
    }

    return ggml_ane_tensor_write_f32(dst, out.data());
}

// Copy a leaf tensor's data into `dst` in fp32. Used to feed Core ML inputs.
static bool ggml_ane_gather_input_fp32(ggml_tensor * tensor, std::vector<float> & out) {
    const size_t n = ggml_nelements(tensor);
    out.resize(n);
    if (tensor->type == GGML_TYPE_F32) {
        std::memcpy(out.data(), tensor->data, n * sizeof(float));
    } else if (tensor->type == GGML_TYPE_F16) {
        ggml_fp16_to_fp32_row((const ggml_fp16_t *) tensor->data, out.data(), (int64_t) n);
    } else if (tensor->type == GGML_TYPE_I32) {
        const int32_t * p = (const int32_t *) tensor->data;
        for (size_t i = 0; i < n; ++i) {
            out[i] = (float) p[i];
        }
    } else {
        return false;
    }
    return true;
}

// ANE-vs-Accelerate dispatch policy.
//
// The host-side split: ANE for compute-bound ops whose per-call
// shape matches a function baked into the .mlmodelc, Accelerate
// (vDSP) for elementwise ops and any op whose shape doesn't match
// the bound bundle. The dispatcher in ggml_ane_program_dispatch_op
// checks ANE eligibility per op and either dispatches the bound
// bundle's functionName (when ANE is the better fit) or returns
// false so the scheduler routes the op to ggml-cpu (which uses
// Accelerate via vDSP). The hard rule: ANE is used when ANE is
// faster, not when ANE is available.
//
// Per-op policy (mirrors docs/tessera-ane-ios-demo-design.md,
// Phase 1 table, and Phase 0 Part 6):
//
//   TILE640_MATMUL      -> ANE (L1 path, Phase 0; the dequant
//                         is on the host, the matmul is the
//                         ANE fp16 matmul; shape must match the
//                         bound bundle's baked shape, otherwise
//                         fall through to ggml-cpu/Metal)
//                         The host-side dequant uses the accel
//                         (Accelerate + NEON) path in
//                         ggml-quants.c when
//                         ggml_tessera_t640_accel_enabled() is
//                         true and in_dim >=
//                         GGML_TESSERA_T640_ACCEL_MIN_K (1024);
//                         the scalar path is the documented
//                         fallback. The accel dequant is
//                         1.26-1.66x faster than the scalar
//                         path at in_dim >= 640 on M1 base
//                         (16 GB, ~68 GB/s; the radix-243 trit
//                         decode is the bottleneck); the accel
//                         quant is 1.0-5.1x (small k ties,
//                         large k wins 3-5x because the scalar
//                         path hits DRAM bandwidth on M1 base);
//                         ts_apply_act_scale is 1.0-2.1x
//                         (small/med wins, large k ties). These
//                         three keep static dispatch rules
//                         (accel above the cutoff, scalar
//                         below).
//
//                         Per-call path selection (cost model):
//                         the two batched helpers
//                         (ts_decode_per_row_meta,
//                         ts_apply_outlier_addback) select
//                         their accel/scalar path per call,
//                         decided by the regime router with the
//                         static cost model in ggml-quants.h as
//                         the fallback:
//
//                           ts_apply_outlier_addback:
//                             accel iff n_total in (0, 1024].
//                             The accel NEON bulk fp16->fp32
//                             path is active for n_total
//                             <= 1024 (the 4 KB stack scratch
//                             cap); above that the scalar
//                             convert + scatter runs. On M1
//                             base: 1.66-1.88x at
//                             n_total=51-409 (the iPhone
//                             drafter's single-row tail), ties
//                             at 3264-52224, 1.23x at 208896.
//
//                           ts_decode_per_row_meta:
//                             accel iff n_total_pages
//                             (= n_rows * n_pages) >= 4096.
//                             On M1 base accel wins 1.09x
//                             at 135168+ elems (the vDSP +
//                             NEON bulk calls amortise their
//                             per-call setup tax), but
//                             loses 0.80-0.92x at 528-8448
//                             elems and ties at 33792. The
//                             4096 threshold is conservative
//                             (it routes the 33792-elem tie
//                             to the scalar path to avoid the
//                             per-call tax on the hot path).
//
//                         dequantize_row_tessera_t640_with_meta
//                         consumes the pre-decoded meta arrays
//                         produced by ts_decode_per_row_meta;
//                         the outlier addback scatters into the
//                         dequant output buffer. See
//                         tests/bench-tessera-quants.cpp for
//                         the per-shape numbers and the cost
//                         model constants.
//   MUL_MAT (BF16/fp16)-> ANE if the bound bundle's function matches
//                         the op's shape; otherwise fall through
//                         to Accelerate BLAS (the W0 spike's path
//                         is the canonical case).
//   RMS_NORM            -> ANE (per-row reduction; shape is
//                         bake-time-locked to the .mlmodelc)
//   SOFT_MAX            -> ANE (row softmax)
//   ROPE                -> ANE (gemma 4 variant; falls through
//                         for variants not yet exported as bundle
//                         functions)
//   GLU                 -> ANE for the gemma 4 split-form case;
//                         otherwise fall through
//   GET_ROWS            -> ANE for small vocab (vocab <= 128 in
//                         this spike); larger embed-lookup goes
//                         through the host-side memcpy path
//                         because the IOSurface write is
//                         bandwidth-bound
//   ADD / MUL / SCALE  -> Accelerate (ANE dispatch overhead > vDSP
//                         cost for elementwise; the ggml-ane
//                         backend's ggml_ane_compute_elementwise
//                         path already uses Accelerate on the
//                         IOSurface arena)
//   RESHAPE / VIEW /   -> free, no compute
//   PERMUTE / CONT
//   CPY                -> memcpy on the host-mapped arena
//
// The policy is encoded as a small enum + helper below; each
// dispatch case uses the helper to decide whether to attempt the
// ANE path or return false immediately for the scheduler to route
// to the CPU/Accelerate path.

enum ggml_ane_dispatch_target {
    GGML_ANE_DISPATCH_ANE        = 0, // ANE if a function is available for this op
    GGML_ANE_DISPATCH_ACCELERATE = 1, // always fall through to Accelerate
    GGML_ANE_DISPATCH_NONE       = 2, // not ANE-eligible (unsupported)
};

// TILE640_MATMUL inner-dim tiling policy constants. The dispatch
// splits the inner dim into tiles of `kTile640InnerDimTileSize` when
// in_dim >= `kTile640InnerDimThreshold`. The architect's call: 4096
// threshold + 1024 tile size. The 4096x4096 case becomes 4 tiles of
// (out_dim, 1024) summed in fp32; the 8192 case becomes 8 tiles;
// shapes below 4096 stay as a single dispatch. Tune the two knobs
// here to retune the policy without touching the dispatch code.
static const int64_t kTile640InnerDimThreshold = 4096;
static const int64_t kTile640InnerDimTileSize  = 1024;

// Test instrumentation: count of ANE sub-matmul dispatches in the
// TILE640_MATMUL path. Increments once per tile in the tiled path
// and once per op in the non-tiled path. Read by the parity test
// (tests/test-ane-tile640-matmul.cpp) to assert the tile-vs-no-
// tile dispatch policy (4 dispatches for the 4096x4096 case under
// the 4096-threshold / 1024-tile-size constants).
static std::atomic<uint64_t> g_tile640_ane_dispatch_count{0};

uint64_t ggml_backend_ane_tile640_dispatch_count(void) {
    return g_tile640_ane_dispatch_count.load(std::memory_order_relaxed);
}

void ggml_backend_ane_tile640_dispatch_count_reset(void) {
    g_tile640_ane_dispatch_count.store(0, std::memory_order_relaxed);
}

int64_t ggml_backend_ane_tile640_threshold(void) {
    return kTile640InnerDimThreshold;
}

int64_t ggml_backend_ane_tile640_tile_size(void) {
    return kTile640InnerDimTileSize;
}

static enum ggml_ane_dispatch_target ggml_ane_dispatch_policy(const ggml_tensor * op) {
    switch (op->op) {
        case GGML_OP_MUL_MAT:
        case GGML_OP_TILE640_MATMUL:
        case GGML_OP_RMS_NORM:
        case GGML_OP_SOFT_MAX:
        case GGML_OP_ROPE:
        case GGML_OP_GLU:
        case GGML_OP_GET_ROWS:
            return GGML_ANE_DISPATCH_ANE;
        case GGML_OP_ADD:
        case GGML_OP_MUL:
        case GGML_OP_SCALE:
        case GGML_OP_CLAMP:
        case GGML_OP_REPEAT:
        case GGML_OP_LEAKY_RELU:
        case GGML_OP_SQR:
        case GGML_OP_SQRT:
        case GGML_OP_LOG:
        case GGML_OP_SIN:
        case GGML_OP_COS:
        case GGML_OP_UNARY:
            // Already handled by ggml_ane_compute_elementwise on the
            // IOSurface arena. The dispatch helper should not pick
            // these up; the graph_compute path's elementwise branch
            // serves them via Accelerate.
            return GGML_ANE_DISPATCH_ACCELERATE;
        default:
            return GGML_ANE_DISPATCH_NONE;
    }
}

// Resolve the bundle function to dispatch for a given op, by name. The bundle
// must expose inputs/outputs in the alphabetical binding order mandated by
// Orion #3/#19; we look up by the model's own declared names, so the export
// side is responsible for naming. Returns empty if no bundle mapping exists.
static bool ggml_ane_program_dispatch_op(ggml_backend_ane_program * program,
                                         ggml_tensor * op,
                                         std::vector<std::string> & out_names) {
    GGML_UNUSED(out_names);
    if (!program) {
        return false;
    }
    // Tessera's bundle naming convention (conversion-design Section 4):
    //   prefill_sN     -> whole-layer slab (token_ids, positions -> h, k, v)
    //   mtp_predict    -> next-token prediction (h_nextn, token_ids -> tok, conf, h)
    //   dflash_bN      -> draft block
    //   hybrid_bN      -> candidate arbitration
    // A single bound bundle exposes exactly one of these. We do not yet have a
    // per-tensor-name dispatch table from the conversion tool, so the only op
    // we route to a bound bundle today is MUL_MAT (via the W0 spike's
    // "main" function). The activation is op->src[0]; the weight tensor
    // (op->src[1]) is NOT passed to the bundle because the W0 spike bakes
    // the weight into the .mlmodelc. For real models, the bundle would be
    // rebuilt with the model-specific weights (one-time at load), so the
    // per-iteration dispatch never sees the weight from ggml. This is
    // documented as the integration point: once the conversion tool emits
    // Per-op dispatch policy: skip the bundle entirely for ops that
    // the ggml-ane backend's elementwise / layout path already serves
    // (or that we don't support at all). The default case below falls
    // through to a precise per-op shape/function check; this filter
    // keeps the switch compact and documents the policy.
    const enum ggml_ane_dispatch_target policy = ggml_ane_dispatch_policy(op);
    if (policy != GGML_ANE_DISPATCH_ANE) {
        return false;
    }

    switch (op->op) {
        case GGML_OP_MUL_MAT: {
            // Decode (M=1) is the canonical ANE path. The activation is
            // op->src[0] of shape [K], the weight is op->src[1] of shape
            // [K, N] (ggml col-major; the bundle's row-major [N, K] weight
            // occupies the same memory). The bundle expects input "x" and
            // output "y" (the W0 spike's function naming).
            const int64_t K = op->src[0]->ne[0];
            const int64_t N = op->src[1]->ne[1];
            const int64_t M = op->src[0]->ne[1];
            if (M != 1) {
                // Prefill (M>1) is not in the W1 spike scope; the bundle
                // has a fixed-shape single-token matmul. Real prefills go
                // through the layer-slab function (prefill_sN) which is a
                // different op routing in dispatch_op.
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_F32 ||
                op->src[1]->type != GGML_TYPE_F32 ||
                op->type != GGML_TYPE_F32) {
                // The W0 spike's bundle computes in fp16 but accepts fp32
                // inputs and returns fp32 outputs (Core ML precision
                // conversion is internal). Other dtypes would need
                // host-side conversion, which is a follow-on.
                return false;
            }
            // The dispatch shape is implicitly the bundle's baked shape.
            // Query the bundle's input/output shapes from the MLModel
            // description and verify before dispatching so a mismatched
            // ggml graph fails fast instead of running the wrong-sized
            // matmul. The W0 spike bakes (K=256, N=256) into the .mlmodelc
            // and the bundle's MLModelDescription matches.
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            // MLModelDescription exposes inputs/outputs via the
            // inputDescriptionsByName / outputDescriptionsByName dictionaries;
            // there is no -featureDescriptionForName: selector on the
            // description itself. Index the dictionaries directly.
            MLFeatureDescription * x_desc = desc.inputDescriptionsByName[@"x"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!x_desc || x_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            NSArray<NSNumber *> * x_shape = x_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            if (x_shape.count != 1 || y_shape.count != 1 ||
                x_shape[0].longLongValue != K || y_shape[0].longLongValue != N) {
                // Bundle's baked shape does not match the ggml op's
                // shape; refuse the dispatch so the scheduler can route
                // the op to a different backend.
                return false;
            }
            // Build the input/output maps and call the bundle. The
            // bundle's "main" function is the default function name.
            std::unordered_map<std::string, ggml_ane_typed_input> inputs;
            inputs.emplace("x", ggml_ane_typed_input{(const void *) op->src[0]->data, GGML_ANE_INPUT_FP32});
            std::vector<std::string> out_names_vec = { "y" };
            std::unordered_map<std::string, float *> outputs;
            outputs.emplace("y", (float *) op->data);
            const bool ok = ggml_ane_program_run(program, inputs, out_names_vec, outputs);
            if (ok) {
                out_names = std::move(out_names_vec);
            }
            return ok;
        }
        case GGML_OP_RMS_NORM: {
            // Per-row RMSNorm: y = x * rsqrt(mean(x^2) + eps). The
            // W2 body-op spike exports one functionName "main" of
            // shape [K, 1] fp16 (a column vector; matches ggml's
            // per-row reduction over ne[0]). The op's src[0] is
            // the row to norm; the dst is the result. eps is
            // packed in op_params[0] as a single float; we read it
            // for the manifest-side sanity check but the bundle
            // bakes eps at export time (Phase 1 ships a single
            // eps value per .mlmodelc; per-call eps is a follow-on
            // that requires the bundle to expose eps as a bundle
            // input).
            if (op->src[0] == nullptr) {
                return false;
            }
            if (op->ne[1] != 1) {
                // Per-row reduction over ne[0]: only the decode
                // shape [K, 1] is in this spike. Prefill (ne[1] > 1)
                // is multi-row and would require a different bundle
                // function (one row per parallel dispatch); the
                // scheduler routes those to the CPU backend until
                // a multi-row bundle lands.
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_F32 ||
                op->type != GGML_TYPE_F32) {
                // fp32 in / fp32 out (the bundle is internally
                // fp16; Core ML handles the precision conversion).
                // fp16 / quantized are follow-ons.
                return false;
            }
            float eps = 0.0f;
            std::memcpy(&eps, op->op_params, sizeof(float));
            (void) eps; // currently unused: the bundle bakes eps.
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            MLFeatureDescription * x_desc = desc.inputDescriptionsByName[@"x"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!x_desc || x_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            NSArray<NSNumber *> * x_shape = x_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            if (x_shape.count != 2 || y_shape.count != 2 ||
                x_shape[0].longLongValue != op->ne[0] ||
                x_shape[1].longLongValue != op->ne[1] ||
                y_shape[0].longLongValue != op->ne[0] ||
                y_shape[1].longLongValue != op->ne[1]) {
                // Bundle's baked shape does not match the ggml op's
                // shape; refuse the dispatch so the scheduler can
                // route the op to a different backend.
                return false;
            }
            std::unordered_map<std::string, ggml_ane_typed_input> inputs;
            inputs.emplace("x", ggml_ane_typed_input{(const void *) op->src[0]->data, GGML_ANE_INPUT_FP32});
            std::vector<std::string> out_names_vec = { "y" };
            std::unordered_map<std::string, float *> outputs;
            outputs.emplace("y", (float *) op->data);
            const bool ok = ggml_ane_program_run(program, inputs, out_names_vec, outputs);
            if (ok) {
                out_names = std::move(out_names_vec);
            }
            return ok;
        }
        case GGML_OP_SOFT_MAX: {
            // Row softmax: y = exp(x - max(x)) / sum(exp(x - max(x)))
            // computed in fp16 inside the bundle, fp32 in/out at
            // the IOSurface boundary. Same shape constraint as
            // RMS_NORM: per-row over ne[0], M=1 for decode. The
            // W2 body-op spike uses [1, 1024].
            if (op->src[0] == nullptr) {
                return false;
            }
            if (op->ne[1] != 1) {
                // Multi-row softmax (M>1) is prefill; the bundle
                // bakes M=1 for the decode spike. Real prefill
                // softmax goes through the layer-slab function.
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_F32 ||
                op->type != GGML_TYPE_F32) {
                return false;
            }
            // scale and max_bias are packed in op_params by
            // ggml_soft_max_ext; we don't currently expose them
            // to the bundle (Phase 1 ships a vanilla softmax
            // with no scale/max_bias; an op variant with those
            // is a follow-on that would require a second
            // functionName in the bundle).
            float scale = 0.0f;
            float max_bias = 0.0f;
            std::memcpy(&scale, op->op_params, sizeof(float));
            std::memcpy(&max_bias, op->op_params + sizeof(float), sizeof(float));
            (void) scale;
            (void) max_bias;
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            MLFeatureDescription * x_desc = desc.inputDescriptionsByName[@"x"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!x_desc || x_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            NSArray<NSNumber *> * x_shape = x_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            if (x_shape.count != 2 || y_shape.count != 2 ||
                x_shape[0].longLongValue != op->ne[0] ||
                x_shape[1].longLongValue != op->ne[1] ||
                y_shape[0].longLongValue != op->ne[0] ||
                y_shape[1].longLongValue != op->ne[1]) {
                return false;
            }
            std::unordered_map<std::string, ggml_ane_typed_input> inputs;
            inputs.emplace("x", ggml_ane_typed_input{(const void *) op->src[0]->data, GGML_ANE_INPUT_FP32});
            std::vector<std::string> out_names_vec = { "y" };
            std::unordered_map<std::string, float *> outputs;
            outputs.emplace("y", (float *) op->data);
            const bool ok = ggml_ane_program_run(program, inputs, out_names_vec, outputs);
            if (ok) {
                out_names = std::move(out_names_vec);
            }
            return ok;
        }
        case GGML_OP_ROPE: {
            // Rotary position embedding. gemma 4's variant
            // (NORMAL mode, no freq_factors for the spike; the
            // mrope / freq_factors case is a follow-on bundle
            // per the dispatch policy). The bundle takes the
            // activation x of shape [n_dims, 1] and a scalar
            // position (fp32 [1, 1]); it returns y of the same
            // shape. The rotation params (n_dims, freq_base,
            // etc.) are baked into the bundle at export time.
            if (op->src[0] == nullptr || op->src[1] == nullptr) {
                return false;
            }
            if (op->ne[1] != 1) {
                // Single-token decode (M=1). The spike bakes
                // a single position; multi-token prefill is a
                // different shape and lands in the layer-slab
                // function.
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_F32 ||
                op->type != GGML_TYPE_F32) {
                return false;
            }
            // ggml_rope packs its op_params as int32 words at
            // 4-byte stride (see ggml_rope_impl in
            // ggml/src/ggml.c:4229):
            //   [0]    n_past (deprecated, always 0)
            //   [1]    n_dims
            //   [2]    mode (GGML_ROPE_TYPE_*)
            //   [3]    n_ctx (deprecated, always 0)
            //   [4]    n_ctx_orig
            //   [5..9] freq_base / freq_scale / ext_factor /
            //          attn_factor / beta_fast / beta_slow
            //          (as float, read as int32 word)
            //   [11..14] mrope sections (mrope only)
            // The dispatch verifies that the ggml op's n_dims
            // and mode match what the bundle bakes (NORMAL with
            // n_dims = K); other modes / sizes fall through to
            // the CPU path. The bundle's other rotation params
            // (freq_base, etc.) are baked and not re-checked
            // here.
            const int32_t n_dims =
                ggml_get_op_params_i32(op, 1);
            const int32_t mode =
                ggml_get_op_params_i32(op, 2);
            if (n_dims != (int32_t) op->ne[0]) {
                // The bundle bakes a specific n_dims; if the
                // ggml op's n_dims doesn't match, refuse the
                // dispatch so the scheduler routes it elsewhere.
                return false;
            }
            if (mode != GGML_ROPE_TYPE_NORMAL) {
                // NORMAL only in this spike; NEOX / MROPE /
                // VISION / IMROPE fall through.
                return false;
            }
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            MLFeatureDescription * x_desc = desc.inputDescriptionsByName[@"x"];
            MLFeatureDescription * p_desc = desc.inputDescriptionsByName[@"pos"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!x_desc || x_desc.type != MLFeatureTypeMultiArray ||
                !p_desc || p_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            NSArray<NSNumber *> * x_shape = x_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * p_shape = p_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            if (x_shape.count != 2 || y_shape.count != 2 ||
                x_shape[0].longLongValue != op->ne[0] ||
                x_shape[1].longLongValue != op->ne[1] ||
                y_shape[0].longLongValue != op->ne[0] ||
                y_shape[1].longLongValue != op->ne[1]) {
                return false;
            }
            // The position is i32 in the ggml op; the bundle
            // takes fp32 (the bundle is internally fp16, so
            // casting to fp32 then re-casting inside the bundle
            // is a no-op semantically and saves us a per-row
            // int->fp conversion in the dispatch hot path).
            int32_t pos_i = 0;
            if (op->src[1]->type == GGML_TYPE_I32) {
                pos_i = ((const int32_t *) op->src[1]->data)[0];
            } else if (op->src[1]->type == GGML_TYPE_F32) {
                pos_i = (int32_t) ((const float *) op->src[1]->data)[0];
            } else {
                return false;
            }
            float pos_f = static_cast<float>(pos_i);
            std::unordered_map<std::string, ggml_ane_typed_input> inputs;
            inputs.emplace("x", ggml_ane_typed_input{(const void *) op->src[0]->data, GGML_ANE_INPUT_FP32});
            inputs.emplace("pos", ggml_ane_typed_input{(const void *) &pos_f, GGML_ANE_INPUT_FP32});
            std::vector<std::string> out_names_vec = { "y" };
            std::unordered_map<std::string, float *> outputs;
            outputs.emplace("y", (float *) op->data);
            const bool ok = ggml_ane_program_run(program, inputs, out_names_vec, outputs);
            if (ok) {
                out_names = std::move(out_names_vec);
            }
            return ok;
        }
        case GGML_OP_GLU: {
            // Gated linear unit, split form (a, b) -> y =
            // activation(a) * b. The gemma 4 FFN is geglu
            // (GELU activation); a follow-on bundle exposes the
            // swiglu variant. The activation is baked into the
            // bundle; the manifest's role is what the dispatch
            // keys on, not the op's op_params glu_op.
            if (op->src[0] == nullptr) {
                return false;
            }
            // Phase 1 ships the split form (src[1] != nullptr).
            // The non-split form (a is [2*n, ...] and the bundle
            // would have to do the split internally) is a
            // follow-on; the dispatch falls through to CPU for
            // that case.
            if (op->src[1] == nullptr) {
                return false;
            }
            if (op->ne[1] != 1) {
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_F32 ||
                op->src[1]->type != GGML_TYPE_F32 ||
                op->type != GGML_TYPE_F32) {
                return false;
            }
            if (!ggml_are_same_shape(op->src[0], op->src[1])) {
                return false;
            }
            // Verify the bundle bakes GEGLU (the gemma 4
            // variant). swiglu is a follow-on bundle.
            const int32_t glu_op = ggml_get_glu_op(op);
            if (glu_op != GGML_GLU_OP_GEGLU) {
                return false;
            }
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            MLFeatureDescription * g_desc = desc.inputDescriptionsByName[@"gate"];
            MLFeatureDescription * u_desc = desc.inputDescriptionsByName[@"up"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!g_desc || g_desc.type != MLFeatureTypeMultiArray ||
                !u_desc || u_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            NSArray<NSNumber *> * g_shape = g_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            if (g_shape.count != 2 || y_shape.count != 2 ||
                g_shape[0].longLongValue != op->ne[0] ||
                g_shape[1].longLongValue != op->ne[1] ||
                y_shape[0].longLongValue != op->ne[0] ||
                y_shape[1].longLongValue != op->ne[1]) {
                return false;
            }
            std::unordered_map<std::string, ggml_ane_typed_input> inputs;
            inputs.emplace("gate", ggml_ane_typed_input{(const void *) op->src[0]->data, GGML_ANE_INPUT_FP32});
            inputs.emplace("up",   ggml_ane_typed_input{(const void *) op->src[1]->data, GGML_ANE_INPUT_FP32});
            std::vector<std::string> out_names_vec = { "y" };
            std::unordered_map<std::string, float *> outputs;
            outputs.emplace("y", (float *) op->data);
            const bool ok = ggml_ane_program_run(program, inputs, out_names_vec, outputs);
            if (ok) {
                out_names = std::move(out_names_vec);
            }
            return ok;
        }
        case GGML_OP_GET_ROWS: {
            // Token-embedding lookup: out[i, :] = table[ids[i], :]
            // for each i in 0..batch. The Phase 1 spike covers
            // the small-vocab case (vocab <= 128 in the bundled
            // fixture); the production gemma 4 vocab=~256k goes
            // through the ggml-cpu memcpy path per the dispatch
            // policy (ANE-side gather on a 256k-row table is
            // bandwidth-bound and the IOSurface write is the
            // bottleneck).
            if (op->src[0] == nullptr || op->src[1] == nullptr) {
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_F32 ||
                op->src[1]->type != GGML_TYPE_I32 ||
                op->type != GGML_TYPE_F32) {
                return false;
            }
            if (op->src[1]->ne[0] != op->ne[1]) {
                // The number of looked-up rows (ids->ne[0]) must
                // match the bundle's baked batch dim. In ggml's
                // view, the batch dim is op->ne[1] (output is
                // [ne[0]=hidden, ne[1]=batch]).
                return false;
            }
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            MLFeatureDescription * t_desc = desc.inputDescriptionsByName[@"table"];
            MLFeatureDescription * i_desc = desc.inputDescriptionsByName[@"ids"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!t_desc || t_desc.type != MLFeatureTypeMultiArray ||
                !i_desc || i_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            NSArray<NSNumber *> * t_shape = t_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * i_shape = i_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            // The bundle declares the table and output in
            // ggml's column-major view: [hidden, vocab] for the
            // table, [hidden, batch] for the output. The
            // flat data is the same; the shape just matches
            // what ggml_get_rows's output looks like.
            if (t_shape.count != 2 || y_shape.count != 2 ||
                t_shape[0].longLongValue != op->src[0]->ne[0] ||
                t_shape[1].longLongValue != op->src[0]->ne[1] ||
                y_shape[0].longLongValue != op->ne[0] ||
                y_shape[1].longLongValue != op->ne[1] ||
                i_shape.count != 1 ||
                i_shape[0].longLongValue != op->ne[1]) {
                return false;
            }
            std::unordered_map<std::string, ggml_ane_typed_input> inputs;
            inputs.emplace("table", ggml_ane_typed_input{(const void *) op->src[0]->data, GGML_ANE_INPUT_FP32});
            // The bundle's ids input is declared Float32 by
            // CoreML's input schema (the int32 cast happens
            // inside the bundle via mb.cast(ids, int32)). The
            // dispatch must convert the ggml-emitted i32 ids
            // to f32 in-place: allocate a small scratch buffer,
            // cast each element, and pass the buffer to the
            // bundle. For decode (batch=1..small) the cost is
            // negligible.
            const int64_t ids_n = op->src[1]->ne[0];
            std::vector<float> ids_f(ids_n);
            for (int64_t i = 0; i < ids_n; ++i) {
                ids_f[i] = static_cast<float>(
                    ((const int32_t *) op->src[1]->data)[i]);
            }
            inputs.emplace("ids", ggml_ane_typed_input{(const void *) ids_f.data(), GGML_ANE_INPUT_FP32});
            std::vector<std::string> out_names_vec = { "y" };
            std::unordered_map<std::string, float *> outputs;
            outputs.emplace("y", (float *) op->data);
            const bool ok = ggml_ane_program_run(program, inputs, out_names_vec, outputs);
            if (ok) {
                out_names = std::move(out_names_vec);
            }
            return ok;
        }
        case GGML_OP_TILE640_MATMUL: {
            // L1 kernel-direct fidelity: y = W_dequant @ B on the ANE.
            // The Phase 0 spec is the dequant-on-host + ANE matmul
            // path: the dispatch reads the 6 TILE640 weight
            // components (src[0..5]) and the activation (src[6]),
            // dequants the weight on the host via the existing
            // dequantize_row_tessera_t640 (ggml-quants.c), writes
            // the fp16 weight into the bundle's pinned `w` slot,
            // and calls the bundle with the weight and the
            // activation as inputs. The 5-trit-base-243 dequant
            // is on the host; the ANE does the matmul. The fused
            // dequant+matmul on ANE is Phase 0.5 (the MIL graph
            // for the 5-trit-base-243 unpack is ~50 elementwise
            // ops per page; the host dequant is the architect's
            // allowed fallback per the Phase 0 spec's open
            // question).
            //
            // The 7 sources per the L0.5 reference
            // (ggml-metal-ops.cpp:1765-1828):
            //   src[0]  packed              (I32  [out, pages, 32])
            //   src[1]  page_scales         (F16  [out, pages])
            //   src[2]  lane_scales         (I8   [out, pages, 32])
            //   src[3]  outlier_row_offsets (I32  [out + 1])
            //   src[4]  outlier_cols        (I32  [n_outliers])
            //   src[5]  outlier_vals        (F16  [n_outliers])
            //   src[6]  B (activations)     (F16  [in_dim, n_tokens, ...])
            //
            // The per-row meta (page_scales, lane_scales,
            // outlier data) is consumed at runtime: the
            // dispatch reads src[1..5] from the ggml graph on
            // every call and writes them into the bundle's
            // pinned slots. The per-layer alpha is the AWQ
            // exponent applied at quantization time; it is
            // folded into the ternary encoding (the weight
            // itself), not into the per-row meta. With the
            // default ts_quantize_2d parameters the per-row
            // meta is alpha-independent, so a "same weight,
            // different alpha" parity test would be
            // degenerate. The per-row meta plumbing is
            // exercised by the re-run case in the parity
            // test (different seed = different page_scales =
            // different ANE output).
            if (op->src[0] == nullptr || op->src[1] == nullptr ||
                op->src[2] == nullptr || op->src[3] == nullptr ||
                op->src[4] == nullptr || op->src[5] == nullptr ||
                op->src[6] == nullptr) {
                return false;
            }
            if (op->src[0]->type != GGML_TYPE_I32 ||
                op->src[1]->type != GGML_TYPE_F16 ||
                op->src[2]->type != GGML_TYPE_I8  ||
                op->src[3]->type != GGML_TYPE_I32 ||
                op->src[4]->type != GGML_TYPE_I32 ||
                op->src[5]->type != GGML_TYPE_F16 ||
                op->src[6]->type != GGML_TYPE_F16 ||
                op->type        != GGML_TYPE_F32) {
                // The bundle's pinned slot dtypes are fp16 for the
                // weight and activation, fp32 for the output. The
                // dispatch refuses a dtype mismatch so the
                // scheduler can route the op to a different
                // backend (ggml-cpu or ggml-metal).
                return false;
            }
            // The matmul's out_dim is in op_params[0] (the
            // ggml_tile640_matmul wrapper sets it; see ggml.h:2631).
            const int32_t out_dim = ggml_get_op_params_i32(op, 0);
            const int32_t in_dim  = (int32_t) op->src[6]->ne[0];
            const int32_t n_tokens = (int32_t) op->src[6]->ne[1];
            if (out_dim <= 0 || in_dim <= 0 || n_tokens <= 0) {
                return false;
            }
            MLModelDescription * desc = program->model.modelDescription;
            if (!desc) {
                return false;
            }
            // The bundle is shape-locked at export time. The
            // dispatch matches on the bound function's input
            // shape. The bundle is either the full (out_dim,
            // in_dim, n_tokens) fixture (no-tile path, in_dim <
            // kTile640InnerDimThreshold) or the (out_dim,
            // kTile640InnerDimTileSize, n_tokens) sub-fixture
            // (tile path, in_dim >= kTile640InnerDimThreshold).
            // A shape mismatch returns false so the scheduler
            // can route to a backend that has a matching bundle
            // (the production graph would carry one .mlmodelc
            // per shape triple; the Phase 0 spike ships the 5
            // shape combos plus the 2 sub-fixtures).
            MLFeatureDescription * w_desc = desc.inputDescriptionsByName[@"w"];
            MLFeatureDescription * x_desc = desc.inputDescriptionsByName[@"x"];
            MLFeatureDescription * y_desc = desc.outputDescriptionsByName[@"y"];
            if (!w_desc || w_desc.type != MLFeatureTypeMultiArray ||
                !x_desc || x_desc.type != MLFeatureTypeMultiArray ||
                !y_desc || y_desc.type != MLFeatureTypeMultiArray) {
                return false;
            }
            // The bundle declares the weight and activation as
            // fp16 MultiArrays and the output as fp32. The
            // dispatch validates the dtypes too (a bundle
            // declared with a different precision would
            // silently mismatch the slot's dataType; surfacing
            // it here is a fail-fast).
            if (w_desc.multiArrayConstraint.dataType != MLMultiArrayDataTypeFloat16 ||
                x_desc.multiArrayConstraint.dataType != MLMultiArrayDataTypeFloat16 ||
                y_desc.multiArrayConstraint.dataType != MLMultiArrayDataTypeFloat32) {
                return false;
            }
            // Phase 0 (tiling): if in_dim >= kTile640InnerDimThreshold,
            // the dispatch splits the inner dim into tiles of
            // kTile640InnerDimTileSize. The bound bundle is expected
            // to be the (out_dim, kTile640InnerDimTileSize, n_tokens)
            // sub-fixture; the dispatch iterates over N_tiles =
            // ceil(in_dim / kTile640InnerDimTileSize) sub-matmuls,
            // each one a (out_dim, kTile640InnerDimTileSize) slice of
            // the full weight. The per-tile fp16 outputs are cast to
            // fp32 and summed; the final Y is the fp32 sum. The
            // 4096x4096 case becomes 4 tiles of (4096, 1024); the
            // 8192 case becomes 8 tiles; shapes below 4096 stay as
            // a single dispatch. See docs/ane-backend-deep-study.md
            // Part 6.6 for the work-around rationale.
            const bool tile_path = (in_dim >= kTile640InnerDimThreshold);
            const int32_t sub_in_dim = tile_path
                ? (int32_t) kTile640InnerDimTileSize : in_dim;
            NSArray<NSNumber *> * w_shape = w_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * x_shape = x_desc.multiArrayConstraint.shape;
            NSArray<NSNumber *> * y_shape = y_desc.multiArrayConstraint.shape;
            if (w_shape.count != 2 || x_shape.count != 2 || y_shape.count != 2 ||
                w_shape[0].longLongValue != out_dim ||
                w_shape[1].longLongValue != sub_in_dim ||
                x_shape[0].longLongValue != sub_in_dim ||
                x_shape[1].longLongValue != n_tokens ||
                y_shape[0].longLongValue != out_dim ||
                y_shape[1].longLongValue != n_tokens) {
                return false;
            }
            // Phase 0: dequant the TILE640 weight on the host
            // into a stack fp16 buffer. The dequant uses
            // dequantize_row_tessera_t640 (ggml-quants.c) row
            // by row. The outlier addback is applied in fp32
            // (matching the L0.5 reference's behaviour per
            // test_b5_tile640_metal_dequant.cpp:343-349).
            //
            // For the accel (Accelerate + NEON) path, the
            // dispatch hoists the per-row meta decode + outlier
            // addback out of the per-row dequant loop:
            //   1. ts_decode_per_row_meta: one call for the
            //      whole TILE of meta (out_dim * pages_per_row
            //      page_scales + out_dim * pages_per_row * 32
            //      lane_scales). Amortises the vDSP setup cost
            //      across the whole tile.
            //   2. per-row dequant with the pre-decoded meta
            //      (dequantize_row_tessera_t640_with_meta takes
            //      the pre-decoded page_max + lane_scale arrays
            //      as separate inputs; the per-row dequant
            //      skips the inline meta decode).
            //   3. ts_apply_outlier_addback: one call for the
            //      whole BUFFER of outliers (out_dim rows,
            //      n_total outliers). Amortises the NEON
            //      bulk-convert setup across the whole buffer.
            //
            // For the scalar path (accel disabled or k < MIN_K),
            // the dispatch falls back to the per-row scalar
            // loop with the flat [packed | page_scales |
            // lane_scales] row buffer.
            std::vector<ggml_fp16_t> weight_fp16((size_t) out_dim * in_dim);
            const int64_t pages_per_row = (in_dim + 639) / 640;
            const int64_t words_per_page = 32;
            // Default: read the T640_3D meta tensors from the
            // op's source pointers (the standard ggml path; the
            // weight bytes are in CPU memory as ggml tensors).
            const int32_t * packed = (const int32_t *) op->src[0]->data;
            const ggml_fp16_t * page_scales = (const ggml_fp16_t *) op->src[1]->data;
            const int8_t * lane_scales = (const int8_t *) op->src[2]->data;
            const int32_t * outlier_row_offsets = (const int32_t *) op->src[3]->data;
            const int32_t * outlier_cols = (const int32_t *) op->src[4]->data;
            const ggml_fp16_t * outlier_vals = (const ggml_fp16_t *) op->src[5]->data;
            // Phase 2 (iPhone demo): if the program has a
            // weight stream attached, override the meta tensor
            // pointers with bytes read from the mmap'd GGUF.
            // The cache is refreshed only on layer-index change
            // (decode M=1 reuses the same layer N times before
            // the index advances; the cache hit rate during
            // decode is ~99% for batch-1 inference). On a
            // cache miss, the stream copies the layer's bytes
            // into the per-program CPU buffer; on a hit, the
            // pointers just rebind and the dequant runs as
            // before. The legacy path (no stream) is byte-
            // identical to the pre-Phase-2 dispatch.
            if (program->weight_stream != nullptr) {
                const int32_t cur_layer =
                    ane_weight_stream_parse_layer(op->src[0]->name);
                if (cur_layer >= 0 &&
                    cur_layer != program->last_streamed_layer) {
                    if (!ane_weight_stream_program_refresh(
                            program, cur_layer)) {
                        // Refresh failed (layer not in the GGUF
                        // or the mmap range is out of bounds).
                        // The legacy op->src[i]->data pointers
                        // remain valid; the dispatch continues
                        // with them. Slice 3 is fail-soft on
                        // the refresh; the layer-not-found case
                        // is logged so the operator sees it.
                    }
                }
                if (cur_layer >= 0) {
                    const void * base = nullptr;
                    size_t sz = 0;
                    if (op->src[0]->name != nullptr &&
                        ane_weight_stream_program_lookup(
                            program, op->src[0]->name, &base, &sz)) {
                        packed = (const int32_t *) base;
                    }
                    if (op->src[1]->name != nullptr &&
                        ane_weight_stream_program_lookup(
                            program, op->src[1]->name, &base, &sz)) {
                        page_scales = (const ggml_fp16_t *) base;
                    }
                    if (op->src[2]->name != nullptr &&
                        ane_weight_stream_program_lookup(
                            program, op->src[2]->name, &base, &sz)) {
                        lane_scales = (const int8_t *) base;
                    }
                    if (op->src[3]->name != nullptr &&
                        ane_weight_stream_program_lookup(
                            program, op->src[3]->name, &base, &sz)) {
                        outlier_row_offsets = (const int32_t *) base;
                    }
                    if (op->src[4]->name != nullptr &&
                        ane_weight_stream_program_lookup(
                            program, op->src[4]->name, &base, &sz)) {
                        outlier_cols = (const int32_t *) base;
                    }
                    if (op->src[5]->name != nullptr &&
                        ane_weight_stream_program_lookup(
                            program, op->src[5]->name, &base, &sz)) {
                        outlier_vals = (const ggml_fp16_t *) base;
                    }
                }
            }
            const bool use_accel = ggml_tessera_t640_accel_enabled() &&
                                   in_dim >= GGML_TESSERA_T640_ACCEL_MIN_K;
            if (use_accel) {
                // Accel pipeline (per-call path selection):
                //   - dequant: accel per-row (with pre-decoded
                //     meta). Faster than the scalar path at
                //     in_dim >= 1024 (1.30-1.63x on M1 Pro).
                //     Static rule; no per-call decision.
                //   - meta decode: ts_decode_per_row_meta picks
                //     its accel/scalar path per call. On M1 the
                //     static cost model picks scalar for the
                //     typical Phase 0 shapes (the vDSP bulk
                //     calls don't amortise); the regime router
                //     can override per (family, shape).
                //   - outlier addback: ts_apply_outlier_addback
                //     picks its accel/scalar path per call;
                //     accel wins iff n_total in (0, 1024] (the
                //     NEON bulk-convert scratch cap; above it
                //     the scalar convert runs).
                // The with-meta dequant takes pre-decoded meta
                // as separate inputs; ts_decode_per_row_meta
                // produces those arrays. The outlier addback
                // scatters into the dequant output buffer. The
                // per-row fp16 cast is unchanged.
                std::vector<float> weight_f32((size_t) out_dim * in_dim);
                std::vector<float> page_max_f32((size_t) out_dim * pages_per_row);
                std::vector<float> lane_scale_f32(
                    (size_t) out_dim * pages_per_row * TILE640_LANES_PER_PAGE);
                const int64_t n_total_outliers =
                    (int64_t) outlier_row_offsets[out_dim] -
                    (int64_t) outlier_row_offsets[0];
                // Regime router: derive (family, shape_bucket)
                // from the tensor name and the in_dim, then ask
                // the router which path wins for this
                // (family, shape) on both meta and outlier.
                // Fallback is the static cost model (the same
                // ts_t640_*_accel_wins helpers); the router is
                // a strict no-op when it has no data. The
                // router exists so the dispatch can learn
                // per-(family, shape) path preferences from
                // real kernel output instead of static
                // thresholds (M1 Pro data was off by ~10% on
                // M1 base for meta decode at large N; the
                // router's policy table fixes that kind of
                // per-target drift without a code change).
                const int family = ts_regime_infer_family(op->name);
                const int shape_bucket =
                    ts_regime_shape_bucket_for_in_dim(in_dim);
                const bool accel_meta = ts_regime_router_lookup_meta(
                    family, shape_bucket,
                    (int64_t) out_dim, pages_per_row);
                const bool accel_outlier = ts_regime_router_lookup_outlier(
                    family, shape_bucket, n_total_outliers);
                // 1. Meta decode: one batched call for the whole
                // tile; the accel/scalar path is selected by the
                // router decision above.
                ts_decode_per_row_meta(page_scales, lane_scales,
                                       (int64_t) out_dim, pages_per_row,
                                       page_max_f32.data(),
                                       lane_scale_f32.data(),
                                       accel_meta);
                // 2. Per-row dequant with pre-decoded meta
                // (the with-meta dequant takes the packed words
                // + the per-row page_max + lane_scale views
                // from the pre-decoded arrays).
                for (int32_t r = 0; r < out_dim; ++r) {
                    const uint32_t * row_packed = (const uint32_t *) &packed[
                        r * pages_per_row * words_per_page];
                    const float * row_page_max = &page_max_f32[r * pages_per_row];
                    const float * row_lane_scale = &lane_scale_f32[
                        r * pages_per_row * TILE640_LANES_PER_PAGE];
                    float * row_y = &weight_f32[r * in_dim];
                    dequantize_row_tessera_t640_with_meta(row_packed,
                                                          row_page_max,
                                                          row_lane_scale,
                                                          in_dim, row_y);
                }
                // 3. Outlier addback: one batched call for the
                // whole buffer; the accel/scalar path is
                // selected by the router decision above.
                ts_apply_outlier_addback(weight_f32.data(), in_dim,
                                         (int64_t) out_dim,
                                         outlier_row_offsets,
                                         outlier_cols,
                                         outlier_vals,
                                         accel_outlier);
                // 4. Per-row fp16 cast (the bundle's pinned slot
                // dtype is fp16; the dequant is fp32).
                for (int32_t r = 0; r < out_dim; ++r) {
                    for (int32_t c = 0; c < in_dim; ++c) {
                        weight_fp16[(size_t) r * in_dim + c] =
                            ggml_fp32_to_fp16(weight_f32[(size_t) r * in_dim + c]);
                    }
                }
            } else {
                // Scalar path: per-row scalar loop with the flat
                // [packed | page_scales | lane_scales] row
                // buffer. Below the accel cutoff (k < 1024) the
                // vDSP setup cost is larger than the per-row
                // work, so the scalar path wins.
                std::vector<uint8_t> row_bytes(
                    (size_t)(pages_per_row * (words_per_page * 4 + 2 + words_per_page)));
                std::vector<float> row_f32((size_t) in_dim);
                for (int32_t r = 0; r < out_dim; ++r) {
                    row_bytes.clear();
                    // Packed words (32-bit each).
                    for (int64_t p = 0; p < pages_per_row; ++p) {
                        for (int64_t l = 0; l < words_per_page; ++l) {
                            const uint32_t v = (uint32_t) packed[
                                (r * pages_per_row + p) * words_per_page + l];
                            row_bytes.insert(row_bytes.end(),
                                             (const uint8_t *) &v,
                                             (const uint8_t *) &v + 4);
                        }
                    }
                    // Page scales (16-bit each, fp16).
                    for (int64_t p = 0; p < pages_per_row; ++p) {
                        const uint16_t s = (uint16_t) page_scales[
                            r * pages_per_row + p];
                        row_bytes.insert(row_bytes.end(),
                                         (const uint8_t *) &s,
                                         (const uint8_t *) &s + 2);
                    }
                    // Lane scales (8-bit each, int8).
                    for (int64_t p = 0; p < pages_per_row; ++p) {
                        for (int64_t l = 0; l < words_per_page; ++l) {
                            const int8_t s = lane_scales[
                                (r * pages_per_row + p) * words_per_page + l];
                            row_bytes.push_back((uint8_t) s);
                        }
                    }
                    dequantize_row_tessera_t640(row_bytes.data(),
                                                row_f32.data(), in_dim);
                    // Sparse outlier addback (fp32; matches the
                    // GPU kernel's outlier path).
                    const int32_t lo = outlier_row_offsets[r];
                    const int32_t hi = outlier_row_offsets[r + 1];
                    for (int32_t k = lo; k < hi; ++k) {
                        const int32_t col = outlier_cols[k];
                        if (col >= 0 && col < in_dim) {
                            row_f32[col] = ggml_fp16_to_fp32(outlier_vals[k]);
                        }
                    }
                    // Cast to fp16 for the bundle's pinned slot.
                    for (int32_t c = 0; c < in_dim; ++c) {
                        weight_fp16[(size_t) r * in_dim + c] =
                            ggml_fp32_to_fp16(row_f32[(size_t) c]);
                    }
                }
            }

            if (!tile_path) {
                // No-tile path: in_dim < kTile640InnerDimThreshold.
                // The bound bundle is the (out_dim, in_dim, n_tokens)
                // full fixture; a single ANE dispatch computes the
                // matmul. The fp16 output is written to op->data as
                // fp32 (the bundle's y dtype is fp32, the dispatch
                // declares op->type == GGML_TYPE_F32, so the
                // precision is preserved end-to-end).
                std::unordered_map<std::string, ggml_ane_typed_input> inputs;
                inputs.emplace("w", ggml_ane_typed_input{
                    (const void *) weight_fp16.data(), GGML_ANE_INPUT_FP16});
                inputs.emplace("x", ggml_ane_typed_input{
                    (const void *) op->src[6]->data, GGML_ANE_INPUT_FP16});
                std::vector<std::string> out_names_vec = { "y" };
                std::unordered_map<std::string, float *> outputs;
                outputs.emplace("y", (float *) op->data);
                g_tile640_ane_dispatch_count.fetch_add(1, std::memory_order_relaxed);
                const bool ok = ggml_ane_program_run(program, inputs,
                                                      out_names_vec, outputs);
                if (ok) {
                    out_names = std::move(out_names_vec);
                }
                return ok;
            }

            // Tile path: in_dim >= kTile640InnerDimThreshold.
            // The bound bundle is the (out_dim, sub_in_dim,
            // n_tokens) sub-fixture. The dispatch iterates over
            // N_tiles = ceil(in_dim / sub_in_dim) sub-matmuls.
            // For each tile, the dispatch:
            //   1. Slices weight_fp16[:, t*sub_in_dim : min((t+1)*sub_in_dim, in_dim))
            //      into a tile_weight [out_dim, sub_in_dim] (zero-padded
            //      for the last partial tile).
            //   2. Slices B[t*sub_in_dim : min((t+1)*sub_in_dim, in_dim), :] into
            //      a tile_B [sub_in_dim, n_tokens] (zero-padded for the
            //      last partial tile).
            //   3. Calls the bound bundle with tile_weight + tile_B
            //      as inputs, writes the fp16 output to a per-tile
            //      scratch buffer, then casts to fp32 and adds to
            //      the fp32 accumulator.
            // The accumulator is the final Y, written to op->data
            // (op->type == GGML_TYPE_F32). The N_tiles sub-matmul
            // outputs each contribute ~sqrt(sub_in_dim) fp16
            // accumulation error; the fp32 sum bounds the total
            // error to ~sqrt(N_tiles * sub_in_dim) which is well
            // within the spec's 1e-1 rel err bar.
            //
            // The fp32 sum accumulator is the ANE fp16 output cast
            // to fp32 before accumulation. The sum is in fp32 to
            // avoid fp16 overflow across N_tiles sub-matmul
            // accumulations (4 tiles of 1024-element fp16 sums can
            // reach ~2*sqrt(1024)*max_per_elt ~ 64x max_per_elt,
            // within fp16 range but the ANE's fp16 accumulate is
            // the precision bottleneck; the fp32 sum restores the
            // spec's precision budget).
            const int32_t N_tiles = (in_dim + (int32_t) kTile640InnerDimTileSize - 1)
                                    / (int32_t) kTile640InnerDimTileSize;
            std::vector<float> y_accum((size_t) out_dim * n_tokens, 0.0f);
            std::vector<ggml_fp16_t> tile_weight(
                (size_t) out_dim * sub_in_dim, ggml_fp16_t{0});
            std::vector<ggml_fp16_t> tile_B(
                (size_t) sub_in_dim * n_tokens, ggml_fp16_t{0});
            // Bundle output is fp32 (the bundle's y dtype); the
            // dispatch routes it through a fp16 scratch first to
            // match the bundle's contract, then casts to fp32 for
            // the sum.
            std::vector<ggml_fp16_t> y_tile_fp16(
                (size_t) out_dim * n_tokens, ggml_fp16_t{0});
            // fp32 destination for the bundle's fp16 output.
            std::vector<float> y_tile_fp32((size_t) out_dim * n_tokens, 0.0f);
            const ggml_fp16_t * B_full = (const ggml_fp16_t *) op->src[6]->data;
            for (int32_t t = 0; t < N_tiles; ++t) {
                const int32_t col_start = t * (int32_t) kTile640InnerDimTileSize;
                const int32_t col_end = std::min(
                    col_start + (int32_t) kTile640InnerDimTileSize, in_dim);
                const int32_t col_count = col_end - col_start;
                // Build tile_weight [out_dim, sub_in_dim] by strided
                // copy from weight_fp16 [out_dim, in_dim]. The
                // last tile is zero-padded when col_count < sub_in_dim.
                for (int32_t r = 0; r < out_dim; ++r) {
                    ggml_fp16_t * dst = &tile_weight[(size_t) r * sub_in_dim];
                    const ggml_fp16_t * src =
                        &weight_fp16[(size_t) r * in_dim + col_start];
                    for (int32_t c = 0; c < col_count; ++c) {
                        dst[c] = src[c];
                    }
                    for (int32_t c = col_count; c < sub_in_dim; ++c) {
                        dst[c] = ggml_fp16_t{0};
                    }
                }
                // Build tile_B [sub_in_dim, n_tokens] by strided
                // copy from B_full [in_dim, n_tokens]. The last
                // tile is zero-padded when col_count < sub_in_dim.
                for (int32_t c = 0; c < col_count; ++c) {
                    for (int32_t k = 0; k < n_tokens; ++k) {
                        tile_B[(size_t) c * n_tokens + k] =
                            B_full[(size_t) (col_start + c) * n_tokens + k];
                    }
                }
                for (int32_t c = col_count; c < sub_in_dim; ++c) {
                    for (int32_t k = 0; k < n_tokens; ++k) {
                        tile_B[(size_t) c * n_tokens + k] = ggml_fp16_t{0};
                    }
                }
                // The bundle's y dtype is fp32; write directly
                // into y_tile_fp32, not through a fp16 scratch.
                // (The fp16 scratch was a vestigial intermediate
                // from an earlier draft; the fp32 destination is
                // the bundle's actual contract.)
                std::unordered_map<std::string, ggml_ane_typed_input> inputs;
                inputs.emplace("w", ggml_ane_typed_input{
                    (const void *) tile_weight.data(), GGML_ANE_INPUT_FP16});
                inputs.emplace("x", ggml_ane_typed_input{
                    (const void *) tile_B.data(), GGML_ANE_INPUT_FP16});
                std::vector<std::string> out_names_vec = { "y" };
                std::unordered_map<std::string, float *> outputs;
                outputs.emplace("y", y_tile_fp32.data());
                g_tile640_ane_dispatch_count.fetch_add(1, std::memory_order_relaxed);
                const bool ok = ggml_ane_program_run(program, inputs,
                                                      out_names_vec, outputs);
                if (!ok) {
                    return false;
                }
                // Accumulate y_tile_fp32 into y_accum (fp32
                // throughout; the per-tile fp16 multiply+accumulate
                // happens inside the bundle, the cross-tile sum is
                // fp32).
                for (int64_t i = 0; i < (int64_t) out_dim * n_tokens; ++i) {
                    y_accum[(size_t) i] += y_tile_fp32[(size_t) i];
                }
                (void) y_tile_fp16;  // (unused; fp32 destination is the bundle's contract)
            }
            // Write the fp32 accumulator to op->data. The op's
            // declared type is GGML_TYPE_F32 (validated at the
            // top of this case), so the fp32 sum is the
            // dispatch's output contract.
            std::memcpy(op->data, y_accum.data(),
                        (size_t) out_dim * n_tokens * sizeof(float));
            out_names = std::vector<std::string>{ "y" };
            return true;
        }
        default:
            return false;
    }
}

static enum ggml_status ggml_backend_ane_graph_compute(ggml_backend_t backend, ggml_cgraph * cgraph) {
    ggml_backend_ane_context * ctx = (ggml_backend_ane_context *) backend->context;
    ggml_backend_ane_program * program = ctx ? ctx->program.load() : nullptr;

    // F16 thermal telemetry: a serious-or-worse thermal state means the ANE
    // is throttling and throughput will be unpredictable. We do not auto-
    // switch to Metal here (the scheduler owns backend selection); this is a
    // logged signal only, matching the deep-study Slice 4 recommendation.
    if (@available(macOS 10.15, iOS 11.0, *)) {
        NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
        if (state >= NSProcessInfoThermalStateSerious) {
            GGML_LOG_WARN("ane: thermal state %ld >= serious; expect ANE throttling\n",
                           (long) state);
        }
    }

    const int n_nodes = cgraph->n_nodes;
    bool saw_bundle_dispatch = false;

    for (int i = 0; i < n_nodes; ++i) {
        ggml_tensor * node = cgraph->nodes[i];

        // Validate that we advertised this op; supports_op is the contract.
        if (!ggml_backend_ane_device_supports_op(backend->device, node)) {
            GGML_LOG_ERROR("ane: op %s not supported; refusing to run graph "
                           "(scheduler should have routed it elsewhere)\n",
                           ggml_op_name(node->op));
            return GGML_STATUS_FAILED;
        }

        // First, ask the bound bundle whether it wants this op. Only a small,
        // explicitly-bundle-mapped set is dispatched through Core ML today:
        // MUL_MAT is the W1 spike's path. dispatch_op reads op->src[0] and
        // op->src[1], calls the bundle with the activation as the bundle
        // input, and writes the bundle output into op. The bundle's weight
        // is baked (W0 spike convention); for a real model the .mlmodelc
        // is rebuilt with the model-specific weights at load time.
        std::vector<std::string> out_names;
        if (ggml_ane_program_dispatch_op(program, node, out_names)) {
            saw_bundle_dispatch = true;
            // Bundle dispatched; the op's data is already populated.
            continue;
        }

        // No bundle mapping: fall through to the elementwise Accelerate path.
        // This covers the compute-shaped ANE-NATIVE ops (ADD, MUL, SCALE,
        // CLAMP, REPEAT, LEAKY_RELU, and the UNARY variants SILU/SIGMOID/
        // TANH/RELU/EXP/LOG/ABS/NEG/STEP/SQR/SQRT). View ops are no-ops:
        // they set view_src and alias the source buffer, so no data
        // movement is needed. GGML_OP_NONE marks leaf/data tensors
        // (weights); no compute. CONT is NOT a view (no view_src, own
        // buffer) and is not advertised; if it ever reaches here it falls
        // through to the loud "no compute path" error below instead of
        // being silently skipped.
        if (node->op == GGML_OP_NONE ||
            node->op == GGML_OP_RESHAPE ||
            node->op == GGML_OP_VIEW ||
            node->op == GGML_OP_TRANSPOSE ||
            node->op == GGML_OP_PERMUTE) {
            continue;
        }

        if (node->op == GGML_OP_CPY) {
            // Type/shape conversion copy on the host-mapped arena. CAST is not
            // a standalone op in this ggml version; it lowers to CPY.
            std::vector<float> tmp;
            if (!ggml_ane_gather_input_fp32(node->src[0], tmp) ||
                !ggml_ane_tensor_write_f32(node, tmp.data())) {
                GGML_LOG_ERROR("ane: CPY unsupported dtype %s -> %s\n",
                               ggml_type_name(node->src[0]->type),
                               ggml_type_name(node->type));
                return GGML_STATUS_FAILED;
            }
            continue;
        }

        if (ggml_ane_compute_elementwise(node)) {
            continue;
        }

        // Reached an op we advertised but did not implement. This is a logic
        // error in supports_op; surface it loudly rather than producing
        // silently-wrong data (F-mode failures are far worse than a crash).
        GGML_LOG_ERROR("ane: advertised op %s (node '%s') has no compute path\n",
                       ggml_op_name(node->op), node->name);
        return GGML_STATUS_FAILED;
    }

    GGML_UNUSED(saw_bundle_dispatch);
    return GGML_STATUS_SUCCESS;
}

static ggml_backend_i ggml_backend_ane_i = {
    /* .get_name                = */ ggml_backend_ane_name,
    /* .free                    = */ ggml_backend_ane_free,
    /* .set_tensor_async        = */ NULL,
    /* .get_tensor_async        = */ NULL,
    /* .set_tensor_2d_async     = */ NULL,
    /* .get_tensor_2d_async     = */ NULL,
    /* .cpy_tensor_async        = */ NULL,
    /* .synchronize             = */ ggml_backend_ane_synchronize,
    /* .graph_plan_create       = */ NULL,
    /* .graph_plan_free         = */ NULL,
    /* .graph_plan_update       = */ NULL,
    /* .graph_plan_compute      = */ NULL,
    /* .graph_compute           = */ ggml_backend_ane_graph_compute,
    /* .event_record            = */ NULL,
    /* .event_wait              = */ NULL,
    /* .graph_optimize          = */ NULL,
};

static ggml_guid_t ggml_backend_ane_guid(void) {
    static ggml_guid guid = { 0xa1, 0xe0, 0x4a, 0x1c, 0x7f, 0x92, 0x4d, 0x0e,
                              0xa6, 0xb3, 0x21, 0x55, 0xc8, 0x07, 0x3e, 0x1a };
    return &guid;
}

static ggml_backend_t ggml_backend_ane_alloc(ggml_backend_dev_t dev) {
    ggml_backend_t backend = (ggml_backend_t) malloc(sizeof(ggml_backend));
    auto * ctx = new ggml_backend_ane_context;

    *backend = {
        /* .guid      = */ ggml_backend_ane_guid(),
        /* .interface = */ ggml_backend_ane_i,
        /* .device    = */ dev,
        /* .context   = */ ctx,
    };

    return backend;
}

GGML_BACKEND_API bool ggml_backend_ane_set_program(
        ggml_backend_t backend, struct ggml_backend_ane_program * program) {
    if (!ggml_backend_is_ane(backend)) {
        return false;
    }
    auto * ctx = (ggml_backend_ane_context *) backend->context;
    if (!ctx) {
        return false;
    }
    // The previously bound program (if any) is not freed here; ownership stays
    // with the caller. Only one program may be bound per backend at a time.
    ctx->program.store(program);
    // keep the device-level supports_op view in sync
    g_ane_bound_program.store(program);
    return true;
}

bool ggml_backend_is_ane(ggml_backend_t backend) {
    return backend != nullptr && ggml_guid_matches(backend->guid, ggml_backend_ane_guid());
}

////////////////////////////////////////////////////////////////////////////////
// backend device
////////////////////////////////////////////////////////////////////////////////

static const char * ggml_backend_ane_device_get_name(ggml_backend_dev_t dev) {
    return GGML_ANE_NAME;

    GGML_UNUSED(dev);
}

static const char * ggml_backend_ane_device_get_description(ggml_backend_dev_t dev) {
    return "CoreML (ANE-first, iOS)";

    GGML_UNUSED(dev);
}

static void ggml_backend_ane_device_get_memory(ggml_backend_dev_t dev, size_t * free, size_t * total) {
    // The ANE shares unified memory with the host; we do not yet have an
    // accurate per-device accounting. Report zeros so the scheduler does not
    // reserve buffers against a fictitious budget.
    if (free)  { *free  = 0; }
    if (total) { *total = 0; }

    GGML_UNUSED(dev);
}

static enum ggml_backend_dev_type ggml_backend_ane_device_get_type(ggml_backend_dev_t dev) {
    // Treat the ANE as an accelerator: the backend is intended to run alongside
    // the CPU backend (weights/tensors copied in/out), not as a standalone GPU.
    return GGML_BACKEND_DEVICE_TYPE_ACCEL;

    GGML_UNUSED(dev);
}

static void ggml_backend_ane_device_get_props(ggml_backend_dev_t dev, ggml_backend_dev_props * props) {
    props->name        = ggml_backend_ane_device_get_name(dev);
    props->description = ggml_backend_ane_device_get_description(dev);
    props->type        = ggml_backend_ane_device_get_type(dev);

    ggml_backend_ane_device_get_memory(dev, &props->memory_free, &props->memory_total);

    props->device_id = nullptr;
    props->caps = {
        /* .async                = */ false,
        /* .host_buffer          = */ false,
        /* .buffer_from_host_ptr = */ false,
        /* .events               = */ false,
    };
}

static ggml_backend_t ggml_backend_ane_device_init_backend(ggml_backend_dev_t dev, const char * params) {
    GGML_UNUSED(params);
    return ggml_backend_ane_alloc(dev);
}

static ggml_backend_buffer_type_t ggml_backend_ane_device_get_buffer_type(ggml_backend_dev_t dev) {
    // Default placement for the ANE lane: IOSurface-backed buffers. They are
    // CPU-readable (the IOSurface base stays locked) and wrap zero-copy as
    // MTLBuffers, so tensors placed here cross the ANE<->Metal boundary
    // without copies. The portable singleton keeps device == nullptr; the
    // (dev, buft) pairing in the caller's buft list carries the device
    // association. Set GGML_ANE_NO_IOSURFACE_DEFAULT=1 to fall back to the
    // private ANE heap.
    static const bool use_iosurface = []() {
        const char * env = getenv("GGML_ANE_NO_IOSURFACE_DEFAULT");
        return !(env && env[0] != '\0' && env[0] != '0');
    }();

    if (use_iosurface) {
        return ggml_backend_ane_iosurface_buffer_type();
    }

    ggml_backend_buffer_type_t buft = ggml_backend_ane_buffer_type();
    buft->device = dev;
    return buft;
}

// The Accelerate elementwise path (ggml_ane_compute_elementwise) views
// every operand as a flat contiguous fp32 array. Advertise an elementwise
// op only when the compute path can actually serve it: contiguous F32/F16
// operands (the two dtypes ggml_ane_tensor_f32_view converts). Anything
// else routes to CPU/Metal instead of failing at graph_compute.
static bool ggml_ane_elementwise_servable(const ggml_tensor * op) {
    const ggml_tensor * t[3] = { op, op->src[0], op->src[1] };
    for (size_t i = 0; i < 3; ++i) {
        if (t[i] == nullptr) {
            continue;
        }
        if (!ggml_is_contiguous(t[i])) {
            return false;
        }
        if (t[i]->type != GGML_TYPE_F32 && t[i]->type != GGML_TYPE_F16) {
            return false;
        }
    }
    return true;
}

static bool ggml_ane_supported_tensor_type(enum ggml_type type) {
    // The elementwise/Accelerate path and the fp16 IOSurface->MLMultiArray
    // wrapping both need one of these host-convertible dtypes.
    // GGML_TYPE_I8 is included for the TILE640_MATMUL path
    // (the lane_scales are int8 and are consumed by the
    // dispatch's host dequant; the slot is never written to
    // the bundle's pinned IOSurface, so the dtype
    // conversion in ggml_ane_write_array_* is never called
    // for I8).
    switch (type) {
        case GGML_TYPE_F32:
        case GGML_TYPE_F16:
        case GGML_TYPE_I32:
        case GGML_TYPE_I8:
            return true;
        default:
            return false;
    }
}

// supports_op per deep-study Section 4.1.
//
// Two classes of ops are advertised:
//   1. Ops with a compute path that needs no bundle: the layout/no-op
//      group (NONE, RESHAPE, VIEW, ...), CPY, and the Accelerate
//      elementwise set (ggml_ane_compute_elementwise). Each is gated on
//      the exact contract its compute path implements (dtype/layout for
//      elementwise and CPY) so the scheduler can route them to ANE on
//      any host without ever handing over an unservable node.
//   2. Bundle-gated ops (MUL_MAT, RMS_NORM, SOFT_MAX, ROPE, GLU,
//      GET_ROWS, TILE640_MATMUL): true only while a program is bound
//      (g_ane_bound_program). dispatch_op does the precise shape/dtype
//      match against the bundle and rejects mismatches. Advertising
//      them without a bundle would make graph_compute fail at the
//      "no compute path" check and would pull weights into the ANE
//      buffer at load for a backend that cannot serve their consumers.
//
// GELU decision (Section 4.2.3): the loaded Core ML bundle already bakes in
// the tanh approximation, so GELU itself stays ANE-BREAKS here and the
// scheduler routes it to CPU/Metal. When the bundle handles a GELU-bearing
// graph it does so internally, not via this ggml op.
static bool ggml_backend_ane_device_supports_op(ggml_backend_dev_t dev, const ggml_tensor * op) {
    GGML_UNUSED(dev);

    if (!ggml_ane_supported_tensor_type(op->type)) {
        return false;
    }
    for (size_t i = 0; i < GGML_MAX_SRC; ++i) {
        if (op->src[i] != nullptr && !ggml_ane_supported_tensor_type(op->src[i]->type)) {
            return false;
        }
    }

    switch (op->op) {
        // Leaf/data tensors (model weights, graph inputs). No compute;
        // every backend that can hold the buffer owns them. Required so
        // the scheduler can assign weights placed in the ANE buffer
        // (ggml_backend_sched_backend_from_buffer checks supports_op for
        // the tensor's own op, and leaves carry GGML_OP_NONE). Same
        // convention as Metal/CUDA.
        case GGML_OP_NONE:
            return true;

        // Bundle-gated ops. Each dispatches to the bound program's
        // functionName; dispatch_op does the precise shape/dtype check
        // and rejects mismatches. Advertised only while a program is
        // actually bound (g_ane_bound_program, kept in sync by
        // ggml_backend_ane_set_program): without a bundle ANE has no
        // compute path for these, and advertising them anyway would
        // pull weights into the ANE buffer at load and ops into ANE at
        // schedule time, then fail graph_compute. With a program bound
        // the router considers ANE alongside every other device, per
        // the dispatch rule "ANE when ANE is faster, not when ANE is
        // available".
        case GGML_OP_MUL_MAT:
        case GGML_OP_RMS_NORM:
        case GGML_OP_SOFT_MAX:
        case GGML_OP_ROPE:
        case GGML_OP_GLU:
        case GGML_OP_GET_ROWS:
        case GGML_OP_TILE640_MATMUL:
            return g_ane_bound_program.load(std::memory_order_relaxed) != nullptr;

        // ANE-NATIVE elementwise ops with an Accelerate implementation.
        // Gated on exactly what the compute path can serve (contiguous
        // F32/F16 operands; ggml_ane_elementwise_servable), so a routed
        // op never reaches graph_compute without a compute path.
        case GGML_OP_ADD:
        case GGML_OP_MUL:
        case GGML_OP_SCALE:
        case GGML_OP_CLAMP:
        case GGML_OP_REPEAT:
        case GGML_OP_LEAKY_RELU:
        case GGML_OP_SQR:
        case GGML_OP_SQRT:
        case GGML_OP_LOG:
        case GGML_OP_SIN:
        case GGML_OP_COS:
            return ggml_ane_elementwise_servable(op);

        // ANE-NATIVE layout ops. Views and reshapes carry their own
        // metadata and share the source buffer (ggml sets view_src for
        // them and the allocator aliases the buffer), so no compute is
        // needed. CONT is deliberately NOT here: it has no view_src, so
        // the allocator gives it its own buffer, and it needs a real
        // strided copy to fill it. Advertising it without a copy path
        // leaves that buffer unwritten and silently corrupts every
        // consumer (CPU-GLUE in the deep-study op table; CPU runs it).
        case GGML_OP_RESHAPE:
        case GGML_OP_VIEW:
        case GGML_OP_TRANSPOSE:
        case GGML_OP_PERMUTE:
            return true;

        // Type conversion is expressed via CPY on the host-mapped arena
        // (CAST is not a standalone op in this ggml version). Servable
        // when the gather/write dtypes line up: the gather reads
        // F32/F16/I32 and the write covers F32/F16.
        case GGML_OP_CPY: {
            const ggml_tensor * src = op->src[0];
            if (src == nullptr || !ggml_is_contiguous(src) || !ggml_is_contiguous(op)) {
                return false;
            }
            const bool src_ok = src->type == GGML_TYPE_F32 ||
                                src->type == GGML_TYPE_F16 ||
                                src->type == GGML_TYPE_I32;
            const bool dst_ok = op->type == GGML_TYPE_F32 ||
                                op->type == GGML_TYPE_F16;
            return src_ok && dst_ok;
        }

        // ANE-NATIVE unary ops (silu, sigmoid, tanh, exp, abs, relu, neg,
        // step, sgn). GELU/GELU_ERF/GELU_QUICK are ANE-BREAKS (handled in the
        // bundle, not here) so only the safe subset of UNARY is taken.
        case GGML_OP_UNARY:
            if (!ggml_ane_elementwise_servable(op)) {
                return false;
            }
            switch (ggml_get_unary_op(op)) {
                case GGML_UNARY_OP_SILU:
                case GGML_UNARY_OP_SIGMOID:
                case GGML_UNARY_OP_TANH:
                case GGML_UNARY_OP_RELU:
                case GGML_UNARY_OP_EXP:
                case GGML_UNARY_OP_ABS:
                case GGML_UNARY_OP_NEG:
                case GGML_UNARY_OP_STEP:
                case GGML_UNARY_OP_SGN:
                    return true;
                default:
                    return false;
            }

        // Everything else is ANE-BREAKS or CPU-GLUE per Section 4.1 and is
        // left for the scheduler to route to CPU/Metal. The notable omissions
        // by design: CONCAT, FLASH_ATTN_EXT, TESSERA_PAGED_ATTN, TILE640_*,
        // DIAG_MASK_INF, GELU, ARGSORT, TOP_K, SLICE, PAD, SSM_*, RWKV_*.
        default:
            return false;
    }
}

static bool ggml_backend_ane_device_supports_buft(ggml_backend_dev_t dev, ggml_backend_buffer_type_t buft) {
    // The IOSurface type is portable (buft->device == nullptr): the ANE
    // program consumes its bytes through the weight-stream/host paths, so
    // accepting it here keeps scheduler-visible tensors on the shared
    // buffer instead of forcing a CPY into the ANE buft.
    if (buft == ggml_backend_ane_iosurface_buffer_type()) {
        return true;
    }
    return buft->device == dev &&
           buft->iface.get_name == ggml_backend_ane_buffer_type_get_name;

    GGML_UNUSED(dev);
}

static ggml_backend_device_i ggml_backend_ane_device_i = {
    /* .get_name             = */ ggml_backend_ane_device_get_name,
    /* .get_description      = */ ggml_backend_ane_device_get_description,
    /* .get_memory           = */ ggml_backend_ane_device_get_memory,
    /* .get_type             = */ ggml_backend_ane_device_get_type,
    /* .get_props            = */ ggml_backend_ane_device_get_props,
    /* .init_backend         = */ ggml_backend_ane_device_init_backend,
    /* .get_buffer_type      = */ ggml_backend_ane_device_get_buffer_type,
    /* .get_host_buffer_type = */ NULL,
    /* .buffer_from_host_ptr = */ NULL,
    /* .supports_op          = */ ggml_backend_ane_device_supports_op,
    /* .supports_buft        = */ ggml_backend_ane_device_supports_buft,
    /* .offload_op           = */ NULL,
    /* .event_new            = */ NULL,
    /* .event_free           = */ NULL,
    /* .event_synchronize    = */ NULL,
};

////////////////////////////////////////////////////////////////////////////////
// backend registry
////////////////////////////////////////////////////////////////////////////////

struct ggml_backend_ane_reg {
    std::vector<ggml_backend_dev_t> devices;
};

typedef struct ggml_backend_ane_reg * ggml_backend_ane_reg_t;

static ggml_backend_ane_reg_t ggml_backend_ane_reg_init(void) {
    return new struct ggml_backend_ane_reg;
}

struct ggml_backend_ane_reg_deleter {
    void operator()(ggml_backend_ane_reg_t ctx) const {
        delete ctx;
    }
};

typedef std::unique_ptr<struct ggml_backend_ane_reg, ggml_backend_ane_reg_deleter> ggml_backend_ane_reg_ptr;

static const char * ggml_backend_ane_reg_get_name(ggml_backend_reg_t reg) {
    return GGML_ANE_NAME;

    GGML_UNUSED(reg);
}

static size_t ggml_backend_ane_reg_device_count(ggml_backend_reg_t reg) {
    ggml_backend_ane_reg_t ctx = (ggml_backend_ane_reg_t) reg->context;
    return ctx->devices.size();
}

static ggml_backend_dev_t ggml_backend_ane_reg_device_get(ggml_backend_reg_t reg, size_t index) {
    ggml_backend_ane_reg_t ctx = (ggml_backend_ane_reg_t) reg->context;
    GGML_ASSERT(index < ctx->devices.size());
    return ctx->devices[index];
}

static void * ggml_backend_ane_get_proc_address(ggml_backend_reg_t reg, const char * name) {
    GGML_UNUSED(reg);
    GGML_UNUSED(name);
    return nullptr;
}

static ggml_backend_reg_i ggml_backend_ane_reg_i = {
    /* .get_name         = */ ggml_backend_ane_reg_get_name,
    /* .get_device_count = */ ggml_backend_ane_reg_device_count,
    /* .get_device       = */ ggml_backend_ane_reg_device_get,
    /* .get_proc_address = */ ggml_backend_ane_get_proc_address,
};

// Single logical ANE device. The public Core ML path exposes one neural
// engine; there is no multi-device enumeration the way Metal has.
static ggml_backend_dev_t ggml_backend_ane_device_init(ggml_backend_reg_t reg) {
    return new ggml_backend_device {
        /* .iface   = */ ggml_backend_ane_device_i,
        /* .reg     = */ reg,
        /* .context = */ nullptr,
    };
}

ggml_backend_reg_t ggml_backend_ane_reg(void) {
    static ggml_backend_reg reg;
    static bool initialized = false;

    {
        static std::mutex mutex;
        std::lock_guard<std::mutex> lock(mutex);

        if (!initialized) {
            static ggml_backend_ane_reg_ptr reg_ctx(ggml_backend_ane_reg_init());
            static std::vector<std::unique_ptr<ggml_backend_device>> devs;

            auto * dev = ggml_backend_ane_device_init(&reg);
            devs.emplace_back(dev);
            reg_ctx->devices.push_back(dev);

            reg = {
                /* .api_version = */ GGML_BACKEND_API_VERSION,
                /* .iface       = */ ggml_backend_ane_reg_i,
                /* .context     = */ reg_ctx.get(),
            };
        }

        initialized = true;
    }

    return &reg;
}

GGML_BACKEND_DL_IMPL(ggml_backend_ane_reg)

////////////////////////////////////////////////////////////////////////////////
// Cross-backend IOSurface buffer (the data plane for lock-free CPU/Metal/ANE
// dispatch). Distinct from `ggml_backend_ane_buffer_context` (above) which
// is owned by the ANE backend. This buffer is portable across all three
// backends: CPU and BLAS accept it because is_host reports the locked base
// truthfully, Metal accepts it and wraps the surface as an MTLBuffer at
// encode time (ggml_metal_get_buffer_id), and the ANE device accepts it in
// supports_buft. With every consumer advertising the type,
// ggml_backend_sched places tensors here without inserting cross-backend
// CPY/DUP nodes.
////////////////////////////////////////////////////////////////////////////////

struct ggml_backend_ane_iosurface_buffer_context {
    IOSurfaceRef surface = nullptr;     // retained; locked for the buffer's lifetime
    void *       base    = nullptr;     // locked base address (CPU view)
    size_t       size    = 0;           // requested (rounded) size in bytes
    void *       mtl_buffer = nullptr;   // lazily-created MTLBuffer (Metal view)

    ~ggml_backend_ane_iosurface_buffer_context() {
        if (mtl_buffer) {
            // The MTLBuffer is created via newBufferWithBytesNoCopy so it
            // shares the IOSurface's memory; we released it but the
            // IOSurface still owns the bytes. The MTLBuffer's lifetime
            // is independent of the IOSurface's. We just drop our
            // reference here; the IOSurface release below stays correct.
            CFRelease(mtl_buffer);
            mtl_buffer = nullptr;
        }
        if (surface) {
            IOSurfaceUnlock(surface, 0, nullptr);
            CFRelease(surface);
            surface = nullptr;
        }
        base = nullptr;
    }
};

static void ggml_backend_ane_iosurface_buffer_free_buffer(ggml_backend_buffer_t buffer) {
    auto * ctx = (ggml_backend_ane_iosurface_buffer_context *) buffer->context;
    delete ctx;
}

static void * ggml_backend_ane_iosurface_buffer_get_base(ggml_backend_buffer_t buffer) {
    auto * ctx = (ggml_backend_ane_iosurface_buffer_context *) buffer->context;
    return ctx->base;
}

static void ggml_backend_ane_iosurface_buffer_memset_tensor(ggml_backend_buffer_t buffer,
                                                           ggml_tensor * tensor,
                                                           uint8_t value, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor));
    memset((char *) tensor->data + offset, value, size);
}

static void ggml_backend_ane_iosurface_buffer_set_tensor(ggml_backend_buffer_t buffer,
                                                          ggml_tensor * tensor,
                                                          const void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor));
    memcpy((char *) tensor->data + offset, data, size);
}

static void ggml_backend_ane_iosurface_buffer_get_tensor(ggml_backend_buffer_t buffer,
                                                          const ggml_tensor * tensor,
                                                          void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset + size <= ggml_nbytes(tensor));
    memcpy(data, (const char *) tensor->data + offset, size);
}

static void ggml_backend_ane_iosurface_buffer_clear(ggml_backend_buffer_t buffer, uint8_t value) {
    auto * ctx = (ggml_backend_ane_iosurface_buffer_context *) buffer->context;
    memset(ctx->base, value, ctx->size);
}

static size_t ggml_backend_ane_iosurface_buffer_type_get_alloc_size(ggml_backend_buffer_type_t buft, const struct ggml_tensor * tensor) {
    return ggml_nbytes(tensor);

    GGML_UNUSED(buft);
}

static ggml_backend_buffer_i ggml_backend_ane_iosurface_buffer_i = {
    /* .free_buffer   = */ ggml_backend_ane_iosurface_buffer_free_buffer,
    /* .get_base      = */ ggml_backend_ane_iosurface_buffer_get_base,
    /* .init_tensor   = */ NULL,
    /* .memset_tensor = */ ggml_backend_ane_iosurface_buffer_memset_tensor,
    /* .set_tensor    = */ ggml_backend_ane_iosurface_buffer_set_tensor,
    /* .get_tensor    = */ ggml_backend_ane_iosurface_buffer_get_tensor,
    /* .set_tensor_2d = */ NULL,
    /* .get_tensor_2d = */ NULL,
    /* .cpy_tensor    = */ NULL,  // copies go through the CPU view (set/get)
    /* .clear         = */ ggml_backend_ane_iosurface_buffer_clear,
    /* .reset         = */ NULL,
};

static const char * ggml_backend_ane_iosurface_buffer_type_get_name(ggml_backend_buffer_type_t buft) {
    return "ANE_IOSURFACE";

    GGML_UNUSED(buft);
}

static ggml_backend_buffer_t ggml_backend_ane_iosurface_buffer_type_alloc_buffer(
        ggml_backend_buffer_type_t buft, size_t size) {
    const size_t rounded = ggml_ane_round_size(size);

    NSDictionary * properties = @{
        (id) kIOSurfaceWidth:          @(rounded),
        (id) kIOSurfaceHeight:         @1,
        (id) kIOSurfaceBytesPerElement:@1,
        (id) kIOSurfaceBytesPerRow:    @(rounded),
        (id) kIOSurfaceAllocSize:      @(rounded),
    };
    IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef) properties);
    if (!surface) {
        GGML_LOG_ERROR("%s: IOSurfaceCreate failed for %zu bytes\n", __func__, rounded);
        return nullptr;
    }
    if (IOSurfaceLock(surface, 0, nullptr) != kIOReturnSuccess) {
        GGML_LOG_ERROR("%s: IOSurfaceLock failed\n", __func__);
        CFRelease(surface);
        return nullptr;
    }
    void * base = IOSurfaceGetBaseAddress(surface);
    if (!base) {
        GGML_LOG_ERROR("%s: IOSurfaceGetBaseAddress returned null\n", __func__);
        IOSurfaceUnlock(surface, 0, nullptr);
        CFRelease(surface);
        return nullptr;
    }

    auto * ctx = new ggml_backend_ane_iosurface_buffer_context;
    ctx->surface = surface;
    ctx->base    = base;
    ctx->size    = rounded;
    return ggml_backend_buffer_init(buft, ggml_backend_ane_iosurface_buffer_i, ctx, size);
}

static size_t ggml_backend_ane_iosurface_buffer_type_get_alignment(ggml_backend_buffer_type_t buft) {
    return GGML_ANE_PAGE;

    GGML_UNUSED(buft);
}

static size_t ggml_backend_ane_iosurface_buffer_type_get_max_size(ggml_backend_buffer_type_t buft) {
    return SIZE_MAX;

    GGML_UNUSED(buft);
}

static bool ggml_backend_ane_iosurface_buffer_type_is_host(ggml_backend_buffer_type_t buft) {
    // Truthful: the IOSurface base address is locked for the buffer's
    // lifetime (IOSurfaceLock in alloc_buffer) and directly
    // readable/writable from the CPU. Reporting host memory is what lets
    // the CPU and BLAS backends accept the type from supports_buft and
    // operate on it in place.
    return true;

    GGML_UNUSED(buft);
}

GGML_BACKEND_API ggml_backend_buffer_type_t ggml_backend_ane_iosurface_buffer_type(void) {
    static ggml_backend_buffer_type buft;
    static bool initialized = false;

    {
        static std::mutex mutex;
        std::lock_guard<std::mutex> lock(mutex);

        if (!initialized) {
            buft = {
                /* .iface = */ {
                    /* .get_name       = */ ggml_backend_ane_iosurface_buffer_type_get_name,
                    /* .alloc_buffer   = */ ggml_backend_ane_iosurface_buffer_type_alloc_buffer,
                    /* .get_alignment  = */ ggml_backend_ane_iosurface_buffer_type_get_alignment,
                    /* .get_max_size   = */ ggml_backend_ane_iosurface_buffer_type_get_max_size,
                    /* .get_alloc_size = */ ggml_backend_ane_iosurface_buffer_type_get_alloc_size,
                    /* .is_host        = */ ggml_backend_ane_iosurface_buffer_type_is_host,
                },
                /* .device  = */ nullptr, // portable across backends, not device-owned
                /* .context = */ nullptr,
            };

            initialized = true;
        }
    }

    return &buft;
}

GGML_BACKEND_API ggml_backend_buffer_t ggml_backend_ane_iosurface_buffer_alloc(size_t bytes) {
    return ggml_backend_ane_iosurface_buffer_type_alloc_buffer(
        ggml_backend_ane_iosurface_buffer_type(), bytes);
}

GGML_BACKEND_API bool ggml_backend_ane_iosurface_buffer_check(ggml_backend_buffer_t buffer) {
    return buffer && buffer->iface.free_buffer == ggml_backend_ane_iosurface_buffer_free_buffer;
}

GGML_BACKEND_API void * ggml_backend_ane_iosurface_buffer_get_iosurface(ggml_backend_buffer_t buffer) {
    if (!ggml_backend_ane_iosurface_buffer_check(buffer)) {
        return nullptr;
    }
    auto * ctx = (ggml_backend_ane_iosurface_buffer_context *) buffer->context;
    return (void *) ctx->surface;
}

// Lazily wrap the IOSurface as an MTLBuffer. The wrap uses
// newBufferWithBytesNoCopy so the MTLBuffer shares memory with the
// IOSurface (no copy). The deallocator is nil because the IOSurface
// owns the memory and outlives the MTLBuffer.
GGML_BACKEND_API void * ggml_backend_ane_iosurface_buffer_get_mtl_buffer(ggml_backend_buffer_t buffer) {
    if (!ggml_backend_ane_iosurface_buffer_check(buffer)) {
        return nullptr;
    }
    auto * ctx = (ggml_backend_ane_iosurface_buffer_context *) buffer->context;
    if (ctx->mtl_buffer) {
        return ctx->mtl_buffer;
    }
    // Look up the Metal device. The ggml-ane backend does not own a
    // Metal device; the dispatch layer hands us one through the
    // environment (a future commit wires this through ggml_backend_dev_t
    // discovery). For the lock-free data plane itself, we use the
    // system default Metal device (MTLCreateSystemDefaultDevice).
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        GGML_LOG_ERROR("%s: MTLCreateSystemDefaultDevice returned null\n", __func__);
        return nullptr;
    }
    // The IOSurface must remain alive for as long as the MTLBuffer is
    // live. newBufferWithBytesNoCopy takes a non-retained pointer; we
    // pass NULL as the deallocator and rely on the buffer's own
    // destruction to drop the MTLBuffer (which then no longer
    // references the IOSurface). The IOSurface itself outlives the
    // MTLBuffer because the buffer holds a reference to both.
    id<MTLBuffer> mtl_buf = [device newBufferWithBytesNoCopy:ctx->base
                                                       length:ctx->size
                                                      options:MTLResourceStorageModeShared
                                                  deallocator:nil];
    if (!mtl_buf) {
        GGML_LOG_ERROR("%s: newBufferWithBytesNoCopy failed\n", __func__);
        return nullptr;
    }
    ctx->mtl_buffer = (void *) CFBridgingRetain(mtl_buf);
    return ctx->mtl_buffer;
}
