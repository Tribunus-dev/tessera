#include "ggml-amd-internal.h"
#include "providers/ggml-amd-hip.h"
#include "ggml.h"

#include <cstring>
#include <cstdio>

extern ggml_backend_buffer_type_t ggml_amd_buffer_type(ggml_backend_dev_t device);
extern ggml_backend_buffer_type_t ggml_amd_host_buffer_type(ggml_backend_dev_t device);

struct ggml_amd_backend_context {
    ggml_backend_dev_t device;
};

static const char * ggml_amd_backend_get_name(ggml_backend_t backend) {
    return backend->device->iface.get_name(backend->device);
}

static void ggml_amd_backend_free(ggml_backend_t backend) {
    delete (struct ggml_amd_backend_context *)backend->context;
    delete backend;
}

static enum ggml_status ggml_amd_backend_graph_compute(ggml_backend_t backend, struct ggml_cgraph * cgraph) {
    if (!backend || !backend->context) {
        return GGML_STATUS_FAILED;
    }

    auto ctx = (struct ggml_amd_backend_context *)backend->context;
    auto device_ctx = (struct ggml_amd_device_context *)ctx->device->context;
    if (ggml_amd_hip_is_provider(device_ctx->provider)) {
        return ggml_amd_hip_graph_compute(device_ctx->provider, cgraph);
    }

    return GGML_STATUS_FAILED;
}

static ggml_guid_t ggml_amd_backend_guid(void) {
    static ggml_guid guid = { 0x17, 0x5e, 0x3a, 0x4f, 0x42, 0x6b, 0x4c, 0xdb, 0xa3, 0x4a, 0x91, 0x01, 0xc9, 0x52, 0x5f, 0xe8 };
    return &guid;
}

static const struct ggml_backend_i ggml_amd_backend_i = {
    .get_name = ggml_amd_backend_get_name,
    .free = ggml_amd_backend_free,
    .set_tensor_async = nullptr,
    .get_tensor_async = nullptr,
    .set_tensor_2d_async = nullptr,
    .get_tensor_2d_async = nullptr,
    .cpy_tensor_async = nullptr,
    .synchronize = nullptr,
    .graph_plan_create = nullptr,
    .graph_plan_free = nullptr,
    .graph_plan_update = nullptr,
    .graph_plan_compute = nullptr,
    .graph_compute = ggml_amd_backend_graph_compute,
    .event_record = nullptr,
    .event_wait = nullptr,
    .graph_optimize = nullptr,
};

static const char * ggml_amd_device_type_name(enum ggml_amd_device_type type) {
    switch (type) {
        case GGML_AMD_DEVICE_CPU: return "CPU";
        case GGML_AMD_DEVICE_IGPU: return "IGPU";
        case GGML_AMD_DEVICE_DGPU: return "DGPU";
        case GGML_AMD_DEVICE_NPU: return "NPU";
        case GGML_AMD_DEVICE_HETERO: return "HETERO";
        default: return "UNKNOWN";
    }
}

static void ggml_amd_device_get_name(struct ggml_amd_device_context * ctx, char * out, size_t size) {
    snprintf(out, size, "AMD%d-%s", ctx->device_index, ggml_amd_device_type_name(ctx->type));
}

static void ggml_amd_device_get_description(struct ggml_amd_device_context * ctx, char * out, size_t size) {
    if (ctx->description.empty()) {
        snprintf(out, size, "AMD %s", ggml_amd_device_type_name(ctx->type));
    } else {
        snprintf(out, size, "%s", ctx->description.c_str());
    }
}

static const char * ggml_amd_device_get_name_static(ggml_backend_dev_t dev) {
    struct ggml_amd_device_context * ctx = (struct ggml_amd_device_context *)dev->context;
    static thread_local char name[64];
    ggml_amd_device_get_name(ctx, name, sizeof(name));
    return name;
}

static const char * ggml_amd_device_get_description_static(ggml_backend_dev_t dev) {
    struct ggml_amd_device_context * ctx = (struct ggml_amd_device_context *)dev->context;
    static thread_local char desc[256];
    ggml_amd_device_get_description(ctx, desc, sizeof(desc));
    return desc;
}

static void ggml_amd_device_get_memory(ggml_backend_dev_t dev, size_t * free_mem, size_t * total_mem) {
    struct ggml_amd_device_context * ctx = (struct ggml_amd_device_context *)dev->context;
    if (ctx->provider && ctx->provider->iface && ctx->provider->iface->query_memory) {
        struct ggml_amd_memory_info info;
        ctx->provider->iface->query_memory(ctx->provider, &info);
        *free_mem = info.free_bytes;
        *total_mem = info.total_bytes;
    } else {
        *free_mem = 0;
        *total_mem = 0;
    }
}

static enum ggml_backend_dev_type ggml_amd_device_get_type(ggml_backend_dev_t dev) {
    struct ggml_amd_device_context * ctx = (struct ggml_amd_device_context *)dev->context;
    switch (ctx->type) {
        case GGML_AMD_DEVICE_CPU: return GGML_BACKEND_DEVICE_TYPE_CPU;
        case GGML_AMD_DEVICE_IGPU: return GGML_BACKEND_DEVICE_TYPE_IGPU;
        case GGML_AMD_DEVICE_DGPU: return GGML_BACKEND_DEVICE_TYPE_GPU;
        case GGML_AMD_DEVICE_NPU: return GGML_BACKEND_DEVICE_TYPE_ACCEL;
        case GGML_AMD_DEVICE_HETERO: return GGML_BACKEND_DEVICE_TYPE_GPU;
        default: return GGML_BACKEND_DEVICE_TYPE_CPU;
    }
}

static void ggml_amd_device_get_props(ggml_backend_dev_t dev, struct ggml_backend_dev_props * props) {
    props->name = ggml_amd_device_get_name_static(dev);
    props->description = ggml_amd_device_get_description_static(dev);
    ggml_amd_device_get_memory(dev, &props->memory_free, &props->memory_total);
    props->type = ggml_amd_device_get_type(dev);
    props->device_id = nullptr;
    props->caps.async = false;
    props->caps.host_buffer = true;
    props->caps.buffer_from_host_ptr = false;
    props->caps.events = false;
}

static ggml_backend_t ggml_amd_device_init_backend(ggml_backend_dev_t dev, const char * params) {
    (void)params;

    auto ctx = new ggml_amd_backend_context();
    ctx->device = dev;

    return new ggml_backend {
        .guid = ggml_amd_backend_guid(),
        .iface = ggml_amd_backend_i,
        .device = dev,
        .context = ctx,
    };
}

static ggml_backend_buffer_type_t ggml_amd_device_get_buffer_type(ggml_backend_dev_t dev) {
    return ggml_amd_buffer_type(dev);
}

static ggml_backend_buffer_type_t ggml_amd_device_get_host_buffer_type(ggml_backend_dev_t dev) {
    return ggml_amd_host_buffer_type(dev);
}

static ggml_backend_buffer_t ggml_amd_device_buffer_from_host_ptr(ggml_backend_dev_t dev, void * ptr, size_t size, size_t max_tensor_size) {
    (void)dev;
    (void)ptr;
    (void)size;
    (void)max_tensor_size;
    return nullptr;
}

static bool ggml_amd_device_supports_op(ggml_backend_dev_t dev, const struct ggml_tensor * op) {
    (void)dev;
    (void)op;

    struct ggml_amd_device_context * ctx = (struct ggml_amd_device_context *)dev->context;
    return ctx->provider && ctx->provider->iface && ctx->provider->iface->supports_op && ctx->provider->iface->supports_op(ctx->provider, op);
}

static bool ggml_amd_device_supports_buft(ggml_backend_dev_t dev, ggml_backend_buffer_type_t buft) {
    return buft == ggml_amd_buffer_type(dev) || buft == ggml_amd_host_buffer_type(dev);
}

static bool ggml_amd_device_offload_op(ggml_backend_dev_t dev, const struct ggml_tensor * op) {
    (void)dev;
    (void)op;
    return false;
}

static ggml_backend_event_t ggml_amd_device_event_new(ggml_backend_dev_t dev) {
    (void)dev;
    return nullptr;
}

static void ggml_amd_device_event_free(ggml_backend_dev_t dev, ggml_backend_event_t event) {
    (void)dev;
    (void)event;
}

static void ggml_amd_device_event_synchronize(ggml_backend_dev_t dev, ggml_backend_event_t event) {
    (void)dev;
    (void)event;
}

static const struct ggml_backend_device_i ggml_amd_device_i = {
    .get_name = ggml_amd_device_get_name_static,
    .get_description = ggml_amd_device_get_description_static,
    .get_memory = ggml_amd_device_get_memory,
    .get_type = ggml_amd_device_get_type,
    .get_props = ggml_amd_device_get_props,
    .init_backend = ggml_amd_device_init_backend,
    .get_buffer_type = ggml_amd_device_get_buffer_type,
    .get_host_buffer_type = ggml_amd_device_get_host_buffer_type,
    .buffer_from_host_ptr = ggml_amd_device_buffer_from_host_ptr,
    .supports_op = ggml_amd_device_supports_op,
    .supports_buft = ggml_amd_device_supports_buft,
    .offload_op = ggml_amd_device_offload_op,
    .event_new = ggml_amd_device_event_new,
    .event_free = ggml_amd_device_event_free,
    .event_synchronize = ggml_amd_device_event_synchronize,
};

ggml_backend_dev_t ggml_amd_create_device(struct ggml_amd_device_context * ctx, ggml_backend_reg_t reg) {
    ggml_backend_dev_t dev = new ggml_backend_device;
    dev->iface = ggml_amd_device_i;
    dev->reg = reg;
    dev->context = ctx;
    return dev;
}
