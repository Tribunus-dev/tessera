//
// ggml-mtl-shared-events.mm
//
// Cross-backend MTLSharedEvent implementation (the control plane for
// lock-free CPU/Metal/ANE dispatch).
//
// Apple MTLSharedEvent is a cross-process counter: any thread (CPU or
// Metal GPU command buffer) can increment the value, and any thread
// can wait for it to reach a target value. This is the cross-backend
// primitive that ties the data plane (ggml_backend_ane_iosurface_buffer_t)
// to a producer/consumer handshake. The dispatch layer encodes
// wait(value) and signal(value) into a Metal command buffer for fully
// on-GPU synchronization, and the CPU side uses the same event to
// gate the ANE leg (ANE itself does not consume MTLSharedEvent; the
// CPU is the sequencer for ANE-Metal handoffs).
//
// This file is .mm so it can include Metal/Metal.h. The .c-style API
// in ggml-metal.h is implemented here.
//
// Compiled into the SHARED library `ggml-mtl-shared-events` (NOT
// the `ggml-metal` MODULE) so the symbols are available to
// llama-common via a normal link dependency. ggml-metal itself
// links to this shared lib (PRIVATE) to use the same functions;
// MODULE_LIBRARY runtime loading resolves them from the already-
// loaded shared lib (llama-common loads it at process startup,
// ggml-metal is dlopen'd later by ggml).
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "ggml-metal.h"

#include <atomic>
#include <cstdlib>

struct ggml_mtl_shared_event {
    id<MTLSharedEvent> mtl_event;
    // Cross-thread cached value for the CPU side. Apple's
    // [event signaledValue] is itself thread-safe and lock-free; we
    // only cache it here as a hint for the try_wait fast path. The
    // authoritative value lives in the underlying MTLSharedEvent.
    std::atomic<uint64_t> cached_value;
};

GGML_BACKEND_API ggml_mtl_shared_event_t ggml_mtl_shared_event_new(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return nullptr;
    }
    // The `supportsSharedEvents` query is on MTLDevice but is not
    // reliably exposed on every device class (notably the simulator's
    // AGX device; Apple does not document the simulation contract for
    // shared events). We treat the absence of the selector as "try
    // anyway"; if `newSharedEvent` returns nil we surface that as
    // the failure mode.
    id<MTLSharedEvent> event = nil;
    if ([device respondsToSelector:@selector(newSharedEvent)]) {
        event = [device newSharedEvent];
    }
    if (!event) {
        return nullptr;
    }
    auto * wrapper = new ggml_mtl_shared_event;
    wrapper->mtl_event = event;
    wrapper->cached_value.store(0);
    return wrapper;
}

GGML_BACKEND_API void ggml_mtl_shared_event_free(ggml_mtl_shared_event_t event) {
    if (!event) {
        return;
    }
    // The mtl_event is a bridged id<MTLSharedEvent>; CFBridgingRetain
    // was not used at construction (newSharedEvent returns +1 retain),
    // so we release it directly.
    [event->mtl_event release];
    delete event;
}

GGML_BACKEND_API void ggml_mtl_shared_event_signal(ggml_mtl_shared_event_t event, uint64_t value) {
    if (!event) {
        return;
    }
    [event->mtl_event setSignaledValue:value];
    event->cached_value.store(value, std::memory_order_release);
}

GGML_BACKEND_API void ggml_mtl_shared_event_wait(ggml_mtl_shared_event_t event, uint64_t value) {
    if (!event) {
        return;
    }
    // The single-argument `waitUntilSignaledValue:` is iOS 16.0+ /
    // macOS 13.0+. On older systems the API takes a timeout in
    // milliseconds. Use the verbose form which is portable; the
    // timeout is large (effectively forever) so the behavior matches
    // the single-arg form for our purposes.
    if ([event->mtl_event respondsToSelector:@selector(waitUntilSignaledValue:)]) {
        [event->mtl_event waitUntilSignaledValue:value];
    } else {
        // 30s timeout: long enough to be "effectively forever" for
        // any reasonable producer; the Metal docs treat anything
        // beyond a few seconds as a hang.
        constexpr uint64_t kTimeoutMs = 30ULL * 1000ULL * 1000ULL;
        [event->mtl_event waitUntilSignaledValue:value timeoutMS:kTimeoutMs];
    }
    event->cached_value.store(value, std::memory_order_release);
}

GGML_BACKEND_API bool ggml_mtl_shared_event_try_wait(ggml_mtl_shared_event_t event, uint64_t value) {
    if (!event) {
        return false;
    }
    // Fast path: cached value already meets the target.
    if (event->cached_value.load(std::memory_order_acquire) >= value) {
        return true;
    }
    // Slow path: read the authoritative value from the underlying
    // MTLSharedEvent. The MTLSharedEvent's `signaledValue` is a
    // relaxed atomic load; the comparison is correct.
    const uint64_t current = event->mtl_event.signaledValue;
    event->cached_value.store(current, std::memory_order_release);
    return current >= value;
}

GGML_BACKEND_API uint64_t ggml_mtl_shared_event_get_value(ggml_mtl_shared_event_t event) {
    if (!event) {
        return 0;
    }
    const uint64_t current = event->mtl_event.signaledValue;
    event->cached_value.store(current, std::memory_order_release);
    return current;
}

GGML_BACKEND_API void * ggml_mtl_shared_event_get_mtl_event(ggml_mtl_shared_event_t event) {
    if (!event) {
        return nullptr;
    }
    return (__bridge void *) event->mtl_event;
}

GGML_BACKEND_API void ggml_mtl_shared_event_encode_wait(
        ggml_mtl_shared_event_t event, void * cmd_buf, uint64_t value) {
    if (!event || !cmd_buf) {
        return;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>) cmd_buf;
    [cb encodeWaitForEvent:event->mtl_event value:value];
}

GGML_BACKEND_API void ggml_mtl_shared_event_encode_signal(
        ggml_mtl_shared_event_t event, void * cmd_buf, uint64_t value) {
    if (!event || !cmd_buf) {
        return;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>) cmd_buf;
    [cb encodeSignalEvent:event->mtl_event value:value];
}

//
// Weight-stream pool attachment facade.
//
// The setters below live in ggml-metal-device.m because they mutate the
// opaque ggml_metal_device struct, whose layout is private to that file.
// But `llama` needs to call them, and under GGML_BACKEND_DL the metal
// backend is a MODULE_LIBRARY that cannot be linked into another target
// (CMake refuses). Linking it anyway is what broke the default macOS
// configure.
//
// So the shared library carries a linkable facade instead: `llama` links
// these symbols normally, and each one resolves its ggml-metal
// counterpart at first call. RTLD_DEFAULT finds the symbol whether the
// backend was dlopen'd (GGML_BACKEND_DL=ON) or linked statically (OFF),
// so one implementation covers both builds.
//
// The facade names are deliberately distinct from the ggml_metal_*
// symbols they forward to: identical names would let dlsym resolve back
// into this library and recurse forever.
//

#include <dlfcn.h>

namespace {

// Resolve `name` from the process image once and cache it. Returns null
// when the metal backend is not loaded, in which case the forwarders
// below are no-ops -- the correct behavior for a build or run with no
// Metal device.
void * mtl_resolve(const char * name, void ** cache, std::atomic<bool> * tried) {
    if (tried->load(std::memory_order_acquire)) {
        return *cache;
    }
    void * sym = dlsym(RTLD_DEFAULT, name);
    *cache = sym;
    tried->store(true, std::memory_order_release);
    return sym;
}

}  // namespace

GGML_BACKEND_API void ggml_mtl_stream_set_pool(
        void * dev, void * pool,
        void * ensure_fn, void * poke_fn,
        void * ensure_experts_fn, void * poke_experts_fn) {
    static void * fn = nullptr;
    static std::atomic<bool> tried{false};
    using set_pool_t = void (*)(void *, void *, void *, void *, void *, void *);
    auto * f = (set_pool_t) mtl_resolve("ggml_metal_device_stream_set_pool", &fn, &tried);
    if (f) {
        f(dev, pool, ensure_fn, poke_fn, ensure_experts_fn, poke_experts_fn);
    }
}

GGML_BACKEND_API void ggml_mtl_stream_set_prefetch_fns(
        void * dev,
        void * prefetch_async_fn, void * prefetch_wait_fn, void * prefetch_cancel_fn) {
    static void * fn = nullptr;
    static std::atomic<bool> tried{false};
    using set_prefetch_t = void (*)(void *, void *, void *, void *);
    auto * f = (set_prefetch_t) mtl_resolve("ggml_metal_device_stream_set_prefetch_fns", &fn, &tried);
    if (f) {
        f(dev, prefetch_async_fn, prefetch_wait_fn, prefetch_cancel_fn);
    }
}

GGML_BACKEND_API void ggml_mtl_stream_set_fence(void * dev, void * shared_event) {
    static void * fn = nullptr;
    static std::atomic<bool> tried{false};
    using set_fence_t = void (*)(void *, void *);
    auto * f = (set_fence_t) mtl_resolve("ggml_metal_device_stream_set_fence", &fn, &tried);
    if (f) {
        f(dev, shared_event);
    }
}
