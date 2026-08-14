#include "ggml-amd-internal.h"
#include "providers/ggml-amd-hip.h"
#include "ggml-impl.h"
#include "ggml.h"

#include <cstring>
#include <map>
#include <memory>

extern struct ggml_amd_allocation * ggml_amd_allocation_create(
    enum ggml_amd_memory_domain domain,
    size_t size,
    size_t alignment,
    enum ggml_amd_coherency coherency);

extern void ggml_amd_allocation_release(struct ggml_amd_allocation * alloc);
extern void * ggml_amd_allocation_map_cpu(struct ggml_amd_allocation * alloc);
extern void ggml_amd_allocation_unmap_cpu(struct ggml_amd_allocation * alloc);
extern int ggml_amd_allocation_dup_fd(struct ggml_amd_allocation * alloc);

struct ggml_amd_buffer_context {
    struct ggml_amd_allocation * allocation;
    struct ggml_amd_provider * provider;
    void * device_base;
    void * fallback_base;
    size_t offset;
    size_t size;
};

struct ggml_amd_buffer_type_context {
    ggml_backend_dev_t device;
    bool is_host;
};

struct ggml_amd_buffer_types {
    std::unique_ptr<ggml_amd_buffer_type_context> device_context;
    std::unique_ptr<ggml_backend_buffer_type> device_type;
    std::unique_ptr<ggml_amd_buffer_type_context> host_context;
    std::unique_ptr<ggml_backend_buffer_type> host_type;
};

bool ggml_amd_buffer_is_hip_device_tensor(const struct ggml_tensor * tensor);

static void ggml_amd_buffer_free_buffer(ggml_backend_buffer_t buffer) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx) {
        if (ctx->allocation) {
            ggml_amd_allocation_unmap_cpu(ctx->allocation);
            ggml_amd_allocation_release(ctx->allocation);
        }
        if (ctx->device_base) {
            ggml_amd_hip_free(ctx->provider, ctx->device_base);
        }
        if (ctx->fallback_base) {
            ggml_aligned_free(ctx->fallback_base, ctx->size);
        }
        delete ctx;
    }
}

static void * ggml_amd_buffer_get_base(ggml_backend_buffer_t buffer) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (!ctx) {
        return nullptr;
    }
    void * base = ctx->device_base ? ctx->device_base : ctx->fallback_base;
    if (ctx->allocation) {
        base = ggml_amd_allocation_map_cpu(ctx->allocation);
    }
    if (!base) {
        return nullptr;
    }
    return (char *)base + ctx->offset;
}

static ggml_status ggml_amd_buffer_init_tensor(ggml_backend_buffer_t buffer, struct ggml_tensor * tensor) {
    (void)buffer;
    (void)tensor;
    return GGML_STATUS_SUCCESS;
}

static void ggml_amd_buffer_memset_tensor(ggml_backend_buffer_t buffer, struct ggml_tensor * tensor, uint8_t value, size_t offset, size_t size) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx && ctx->device_base) {
        GGML_ASSERT(ggml_amd_hip_memset(ctx->provider, (char *)tensor->data + offset, value, size));
        return;
    }
    memset((char *)tensor->data + offset, value, size);
}

static void ggml_amd_buffer_set_tensor(ggml_backend_buffer_t buffer, struct ggml_tensor * tensor, const void * data, size_t offset, size_t size) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx && ctx->device_base) {
        GGML_ASSERT(ggml_amd_hip_set(ctx->provider, (char *)tensor->data + offset, data, size));
        return;
    }
    memcpy((char *)tensor->data + offset, data, size);
}

static void ggml_amd_buffer_get_tensor(ggml_backend_buffer_t buffer, const struct ggml_tensor * tensor, void * data, size_t offset, size_t size) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx && ctx->device_base) {
        GGML_ASSERT(ggml_amd_hip_get(ctx->provider, data, (const char *)tensor->data + offset, size));
        return;
    }
    memcpy(data, (const char *)tensor->data + offset, size);
}

static bool ggml_amd_buffer_cpy_tensor(ggml_backend_buffer_t buffer, const struct ggml_tensor * src, struct ggml_tensor * dst) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx && ctx->device_base && ggml_amd_buffer_is_hip_device_tensor(src)) {
        GGML_ASSERT(ggml_amd_hip_copy(ctx->provider, dst->data, src->data, ggml_nbytes(src)));
        return true;
    }

    std::vector<uint8_t> host(ggml_nbytes(src));
    ggml_backend_tensor_get(src, host.data(), 0, host.size());
    ggml_amd_buffer_set_tensor(buffer, dst, host.data(), 0, host.size());
    return true;
}

static void ggml_amd_buffer_clear(ggml_backend_buffer_t buffer, uint8_t value) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx && ctx->device_base) {
        GGML_ASSERT(ggml_amd_hip_memset(ctx->provider, ctx->device_base, value, buffer->size));
        return;
    }
    void * base = ggml_amd_buffer_get_base(buffer);
    if (base) {
        memset(base, value, buffer->size);
    }
}

static void ggml_amd_buffer_reset(ggml_backend_buffer_t buffer) {
    (void)buffer;
}

static const struct ggml_backend_buffer_i ggml_amd_buffer_i = {
    .free_buffer = ggml_amd_buffer_free_buffer,
    .get_base = ggml_amd_buffer_get_base,
    .init_tensor = ggml_amd_buffer_init_tensor,
    .memset_tensor = ggml_amd_buffer_memset_tensor,
    .set_tensor = ggml_amd_buffer_set_tensor,
    .get_tensor = ggml_amd_buffer_get_tensor,
    .set_tensor_2d = nullptr,
    .get_tensor_2d = nullptr,
    .cpy_tensor = ggml_amd_buffer_cpy_tensor,
    .clear = ggml_amd_buffer_clear,
    .reset = ggml_amd_buffer_reset,
};

static ggml_backend_buffer_t ggml_amd_buffer_create(ggml_backend_buffer_type_t buft, struct ggml_amd_allocation * allocation, size_t offset, size_t size) {
    if (!allocation) {
        return nullptr;
    }

    auto ctx = new ggml_amd_buffer_context();
    ctx->allocation = allocation;
    ctx->provider = nullptr;
    ctx->device_base = nullptr;
    ctx->fallback_base = nullptr;
    ctx->offset = offset;
    ctx->size = size;

    return ggml_backend_buffer_init(buft, ggml_amd_buffer_i, ctx, size);
}

static ggml_backend_buffer_t ggml_amd_buffer_type_alloc_buffer(ggml_backend_buffer_type_t buft, size_t size) {
    struct ggml_amd_buffer_type_context * type_ctx = (struct ggml_amd_buffer_type_context *)buft->context;
    struct ggml_amd_device_context * device_ctx = (struct ggml_amd_device_context *)type_ctx->device->context;

    if (!type_ctx->is_host && ggml_amd_hip_is_provider(device_ctx->provider)) {
        void * device_base = ggml_amd_hip_alloc(device_ctx->provider, size);
        if (!device_base) {
            return nullptr;
        }

        auto ctx = new ggml_amd_buffer_context();
        ctx->allocation = nullptr;
        ctx->provider = device_ctx->provider;
        ctx->device_base = device_base;
        ctx->fallback_base = nullptr;
        ctx->offset = 0;
        ctx->size = size;
        return ggml_backend_buffer_init(buft, ggml_amd_buffer_i, ctx, size);
    }

    struct ggml_amd_allocation * allocation = ggml_amd_allocation_create(
        GGML_AMD_DOMAIN_SHARED_SYSTEM,
        size,
        TENSOR_ALIGNMENT,
        GGML_AMD_COHERENCY_SHARED);

    if (allocation && ggml_amd_allocation_map_cpu(allocation)) {
        return ggml_amd_buffer_create(buft, allocation, 0, size);
    }

    if (allocation) {
        ggml_amd_allocation_release(allocation);
    }

    void * fallback_base = ggml_aligned_malloc(size);
    if (!fallback_base) {
        return nullptr;
    }

    auto ctx = new ggml_amd_buffer_context();
    ctx->allocation = nullptr;
    ctx->provider = nullptr;
    ctx->device_base = nullptr;
    ctx->fallback_base = fallback_base;
    ctx->offset = 0;
    ctx->size = size;

    return ggml_backend_buffer_init(buft, ggml_amd_buffer_i, ctx, size);
}

static const char * ggml_amd_buffer_type_get_name(ggml_backend_buffer_type_t buft) {
    struct ggml_amd_buffer_type_context * ctx = (struct ggml_amd_buffer_type_context *)buft->context;
    return ctx->is_host ? "AMD_Host" : "AMD";
}

static size_t ggml_amd_buffer_type_get_alignment(ggml_backend_buffer_type_t buft) {
    (void)buft;
    return TENSOR_ALIGNMENT;
}

static bool ggml_amd_buffer_type_is_host(ggml_backend_buffer_type_t buft) {
    struct ggml_amd_buffer_type_context * ctx = (struct ggml_amd_buffer_type_context *)buft->context;
    return ctx->is_host;
}

static ggml_backend_buffer_type_t ggml_amd_buffer_type_get(ggml_backend_dev_t device, bool is_host) {
    static std::mutex mutex;
    static std::map<ggml_backend_dev_t, ggml_amd_buffer_types> buffer_types;

    std::lock_guard<std::mutex> lock(mutex);
    ggml_amd_buffer_types & types = buffer_types[device];

    std::unique_ptr<ggml_amd_buffer_type_context> & context = is_host ? types.host_context : types.device_context;
    std::unique_ptr<ggml_backend_buffer_type> & type = is_host ? types.host_type : types.device_type;

    if (!type) {
        context = std::make_unique<ggml_amd_buffer_type_context>();
        context->device = device;
        context->is_host = is_host;

        type = std::make_unique<ggml_backend_buffer_type>();
        type->iface = {
            .get_name = ggml_amd_buffer_type_get_name,
            .alloc_buffer = ggml_amd_buffer_type_alloc_buffer,
            .get_alignment = ggml_amd_buffer_type_get_alignment,
            .get_max_size = nullptr,
            .get_alloc_size = nullptr,
            .is_host = ggml_amd_buffer_type_is_host,
        };
        type->device = device;
        type->context = context.get();
    }

    return type.get();
}

ggml_backend_buffer_type_t ggml_amd_buffer_type(ggml_backend_dev_t device) {
    return ggml_amd_buffer_type_get(device, false);
}

ggml_backend_buffer_type_t ggml_amd_host_buffer_type(ggml_backend_dev_t device) {
    return ggml_amd_buffer_type_get(device, true);
}

bool ggml_amd_buffer_is_hip_device_tensor(const struct ggml_tensor * tensor) {
    if (!tensor || !tensor->buffer) {
        return false;
    }

    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)tensor->buffer->context;
    return ctx && ctx->device_base && ggml_amd_hip_is_provider(ctx->provider);
}
