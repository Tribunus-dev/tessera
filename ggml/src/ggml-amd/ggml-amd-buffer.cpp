#include "ggml-amd-internal.h"
#include "ggml.h"

#include <cstring>

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
    size_t offset;
    size_t size;
};

static void ggml_amd_buffer_free_buffer(ggml_backend_buffer_t buffer) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (ctx) {
        if (ctx->allocation) {
            ggml_amd_allocation_unmap_cpu(ctx->allocation);
            ggml_amd_allocation_release(ctx->allocation);
        }
        delete ctx;
    }
    delete buffer;
}

static void * ggml_amd_buffer_get_base(ggml_backend_buffer_t buffer) {
    struct ggml_amd_buffer_context * ctx = (struct ggml_amd_buffer_context *)buffer->context;
    if (!ctx || !ctx->allocation) {
        return nullptr;
    }
    void * base = ggml_amd_allocation_map_cpu(ctx->allocation);
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

static void ggml_amd_buffer_set_tensor(ggml_backend_buffer_t buffer, struct ggml_tensor * tensor, const void * data, size_t offset, size_t size) {
    (void)buffer;
    (void)tensor;
    (void)data;
    (void)offset;
    (void)size;
}

static void ggml_amd_buffer_get_tensor(ggml_backend_buffer_t buffer, const struct ggml_tensor * tensor, void * data, size_t offset, size_t size) {
    (void)buffer;
    (void)tensor;
    (void)data;
    (void)offset;
    (void)size;
}

static bool ggml_amd_buffer_cpy_tensor(ggml_backend_buffer_t buffer, const struct ggml_tensor * src, struct ggml_tensor * dst) {
    (void)buffer;
    (void)src;
    (void)dst;
    return false;
}

static void ggml_amd_buffer_clear(ggml_backend_buffer_t buffer, uint8_t value) {
    (void)buffer;
    (void)value;
}

static void ggml_amd_buffer_reset(ggml_backend_buffer_t buffer) {
    (void)buffer;
}

static const struct ggml_backend_buffer_i ggml_amd_buffer_i = {
    .free_buffer = ggml_amd_buffer_free_buffer,
    .get_base = ggml_amd_buffer_get_base,
    .init_tensor = ggml_amd_buffer_init_tensor,
    .set_tensor = ggml_amd_buffer_set_tensor,
    .get_tensor = ggml_amd_buffer_get_tensor,
    .cpy_tensor = ggml_amd_buffer_cpy_tensor,
    .clear = ggml_amd_buffer_clear,
    .reset = ggml_amd_buffer_reset,
};

ggml_backend_buffer_t ggml_amd_buffer_create(struct ggml_amd_allocation * allocation, size_t offset, size_t size) {
    if (!allocation) {
        return nullptr;
    }

    auto ctx = new ggml_amd_buffer_context();
    ctx->allocation = allocation;
    ctx->offset = offset;
    ctx->size = size;

    auto buffer = new ggml_backend_buffer();
    buffer->iface = ggml_amd_buffer_i;
    buffer->buft = nullptr;
    buffer->context = ctx;
    buffer->size = size;
    buffer->usage = GGML_BACKEND_BUFFER_USAGE_ANY;

    return buffer;
}
