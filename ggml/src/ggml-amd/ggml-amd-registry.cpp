#include "ggml-amd-internal.h"
#include "ggml.h"
#include "ggml-amd.h"

#include <cstring>
#include <mutex>

extern void ggml_amd_config_init(struct ggml_amd_reg_context * ctx);
extern void ggml_amd_probe_all_providers(struct ggml_amd_reg_context * ctx);
extern ggml_backend_dev_t ggml_amd_create_device(struct ggml_amd_device_context * ctx, ggml_backend_reg_t reg);

static const char * ggml_amd_reg_get_name(ggml_backend_reg_t reg) {
    (void)reg;
    return "AMD";
}

static size_t ggml_amd_reg_get_device_count(ggml_backend_reg_t reg) {
    struct ggml_amd_reg_context * ctx = (struct ggml_amd_reg_context *)reg->context;
    return ctx->devices.size();
}

static ggml_backend_dev_t ggml_amd_reg_get_device(ggml_backend_reg_t reg, size_t index) {
    struct ggml_amd_reg_context * ctx = (struct ggml_amd_reg_context *)reg->context;
    if (index >= ctx->devices.size()) {
        return nullptr;
    }
    return ctx->devices[index];
}

static void * ggml_amd_reg_get_proc_address(ggml_backend_reg_t reg, const char * name) {
    (void)reg;
    if (strcmp(name, "ggml_backend_is_amd") == 0) {
        return (void *)ggml_backend_is_amd;
    }
    return nullptr;
}

static const struct ggml_backend_reg_i ggml_amd_reg_i = {
    .get_name = ggml_amd_reg_get_name,
    .get_device_count = ggml_amd_reg_get_device_count,
    .get_device = ggml_amd_reg_get_device,
    .get_proc_address = ggml_amd_reg_get_proc_address,
};

ggml_backend_reg_t ggml_backend_amd_reg(void) {
    static std::mutex mutex;
    static ggml_backend_reg reg;
    static bool initialized = false;

    std::lock_guard<std::mutex> lock(mutex);

    if (!initialized) {
        auto ctx = std::make_unique<ggml_amd_reg_context>();
        ggml_amd_config_init(ctx.get());
        ggml_amd_probe_all_providers(ctx.get());

        for (size_t i = 0; i < ctx->providers.size(); i++) {
            auto dev_ctx = std::make_unique<ggml_amd_device_context>();
            dev_ctx->device_index = (int)i;
            dev_ctx->type = ctx->providers[i]->device_type;
            dev_ctx->provider = ctx->providers[i].get();

            ggml_backend_dev_t dev = ggml_amd_create_device(dev_ctx.get(), &reg);
            if (!dev) {
                continue;
            }

            ctx->devices.push_back(dev);
            ctx->device_contexts.push_back(std::move(dev_ctx));
        }

        reg = ggml_backend_reg{
            /*.api_version = */ GGML_BACKEND_API_VERSION,
            /*.iface       = */ ggml_amd_reg_i,
            /*.context     = */ ctx.get(),
        };

        ctx.release();
        initialized = true;
    }

    return &reg;
}

bool ggml_backend_is_amd(ggml_backend_t backend) {
    return backend && backend->device && backend->device->reg && backend->device->reg->iface.get_name == ggml_amd_reg_get_name;
}

bool ggml_backend_dev_is_amd(ggml_backend_dev_t device) {
    return device && device->reg && device->reg->iface.get_name == ggml_amd_reg_get_name;
}
