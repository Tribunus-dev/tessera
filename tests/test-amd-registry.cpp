// test-amd-registry.cpp
//
// Test ggml-amd device enumeration and stable identities.
//
// What this exercises:
//  1. ggml_backend_amd_reg() returns a valid registry
//  2. ggml_backend_reg_get_device_count() returns a count
//  3. Each device has a name starting with "AMD"
//  4. ggml_backend_dev_is_amd() returns true for AMD devices
//  5. ggml_backend_is_amd() returns true for AMD backends
//
// Hardware-dependent tests are gated with #ifdef GGML_AMD_HIP etc.
// The registry itself is always available (returns 0 devices on
// systems without AMD hardware).

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-amd.h"
#include "ggml-backend-impl.h"
#include "ggml-amd-internal.h"
#ifdef GGML_AMD_HIP
#include "providers/ggml-amd-hip.h"
#endif

#include <cassert>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>

#ifdef GGML_AMD_HIP
#ifdef __linux__
#ifdef __HIP_PLATFORM_AMD__
#include <hip/hip_runtime.h>
#endif
#endif
#endif

static int g_failures = 0;

extern void ggml_amd_config_init(struct ggml_amd_reg_context * ctx);
extern struct ggml_amd_allocation * ggml_amd_allocation_create(
    enum ggml_amd_memory_domain domain,
    size_t size,
    size_t alignment,
    enum ggml_amd_coherency coherency);

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

struct amd_env_var {
    const char * name;
    bool was_set;
    std::string value;
};

static amd_env_var amd_env_save(const char * name) {
    const char * value = std::getenv(name);
    return { name, value != nullptr, value ? value : "" };
}

static void amd_env_restore(const amd_env_var & env) {
    if (env.was_set) {
        setenv(env.name, env.value.c_str(), 1);
    } else {
        unsetenv(env.name);
    }
}

static void test_config_parse(void) {
    const amd_env_var provider = amd_env_save("GGML_AMD_PROVIDER");
    const amd_env_var kv_home = amd_env_save("GGML_AMD_KV_HOME");
    const amd_env_var xdna = amd_env_save("GGML_AMD_XDNA");
    const amd_env_var vulkan_fallback = amd_env_save("GGML_AMD_VULKAN_FALLBACK");

    unsetenv("GGML_AMD_PROVIDER");
    unsetenv("GGML_AMD_KV_HOME");
    unsetenv("GGML_AMD_XDNA");
    unsetenv("GGML_AMD_VULKAN_FALLBACK");

    ggml_amd_reg_context defaults = {};
    ggml_amd_config_init(&defaults);
    CHECK(defaults.provider == "auto", "default provider is auto");
    CHECK(defaults.kv_home == "auto", "default KV home is auto");
    CHECK(!defaults.xdna_enabled, "XDNA is disabled by default");
    CHECK(defaults.vulkan_fallback, "Vulkan fallback is enabled by default");

    setenv("GGML_AMD_PROVIDER", "hip", 1);
    setenv("GGML_AMD_KV_HOME", "cpu", 1);
    setenv("GGML_AMD_XDNA", "on", 1);
    setenv("GGML_AMD_VULKAN_FALLBACK", "0", 1);

    ggml_amd_reg_context explicit_config = {};
    ggml_amd_config_init(&explicit_config);
    CHECK(explicit_config.provider == "hip", "explicit HIP provider is retained");
    CHECK(explicit_config.kv_home == "cpu", "explicit CPU KV home is retained");
    CHECK(explicit_config.xdna_enabled, "XDNA opt-in is retained");
    CHECK(!explicit_config.vulkan_fallback, "Vulkan fallback opt-out is retained");

    setenv("GGML_AMD_PROVIDER", "invalid", 1);
    setenv("GGML_AMD_KV_HOME", "invalid", 1);
    setenv("GGML_AMD_XDNA", "invalid", 1);

    ggml_amd_reg_context invalid_config = {};
    ggml_amd_config_init(&invalid_config);
    CHECK(invalid_config.provider == "auto", "invalid provider falls back to auto");
    CHECK(invalid_config.kv_home == "auto", "invalid KV home falls back to auto");
    CHECK(!invalid_config.xdna_enabled, "invalid XDNA value remains disabled");

    amd_env_restore(provider);
    amd_env_restore(kv_home);
    amd_env_restore(xdna);
    amd_env_restore(vulkan_fallback);
}

static void test_registry_valid(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    CHECK(reg != nullptr, "ggml_backend_amd_reg() returns non-null");
    CHECK(ggml_backend_reg_name(reg) != nullptr, "registry has a name");
}

static void test_registry_name(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    const char * name = ggml_backend_reg_name(reg);
    CHECK(name != nullptr, "registry name is non-null");
    CHECK(name != nullptr && strcmp(name, "AMD") == 0, "registry name is 'AMD'");
}

static void test_device_count(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = ggml_backend_reg_dev_count(reg);
    std::fprintf(stdout, "     device count: %zu\n", count);
}

static void test_device_names(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = ggml_backend_reg_dev_count(reg);
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, i);
        CHECK(dev != nullptr, "device is non-null");

        if (dev) {
            const char * name = ggml_backend_dev_name(dev);
            CHECK(name != nullptr, "device name is non-null");
            if (name) {
                bool starts_with_amd = strncmp(name, "AMD", 3) == 0;
                CHECK(starts_with_amd, "device name starts with 'AMD'");
                std::fprintf(stdout, "     device %zu: %s\n", i, name);
            }
        }
    }
}

static void test_dev_is_amd(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = ggml_backend_reg_dev_count(reg);
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, i);
        if (dev) {
            bool is_amd = ggml_backend_dev_is_amd(dev);
            CHECK(is_amd, "ggml_backend_dev_is_amd() returns true for AMD device");
        }
    }
}

static void test_backend_is_amd(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = ggml_backend_reg_dev_count(reg);
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, i);
        if (dev) {
            ggml_backend_t backend = ggml_backend_dev_init(dev, nullptr);
            CHECK(backend != nullptr, "AMD device initializes a backend");
            if (backend) {
                CHECK(ggml_backend_is_amd(backend), "ggml_backend_is_amd() returns true for AMD backend");
                ggml_backend_free(backend);
            }
        }
    }
}

static void test_device_buffer_round_trip(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg || ggml_backend_reg_dev_count(reg) == 0) {
        std::fprintf(stdout, "     device buffer round-trip skipped (no AMD device)\n");
        return;
    }

    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, 0);
    ggml_backend_t backend = ggml_backend_dev_init(dev, nullptr);
    CHECK(backend != nullptr, "AMD backend initializes for buffer transfer");
    if (!backend) {
        return;
    }

    struct ggml_init_params params = {
        /* .mem_size   = */ 64 * 1024,
        /* .mem_buffer = */ nullptr,
        /* .no_alloc   = */ true,
    };
    struct ggml_context * ctx = ggml_init(params);
    CHECK(ctx != nullptr, "ggml context initializes for AMD buffer transfer");
    if (!ctx) {
        ggml_backend_free(backend);
        return;
    }

    struct ggml_tensor * tensor = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, 4);
    ggml_backend_buffer_t buffer = ggml_backend_alloc_ctx_tensors(ctx, backend);
    CHECK(buffer != nullptr, "AMD device buffer allocates");
    if (buffer) {
        const int32_t input[4] = { 7, -3, 42, 0 };
        int32_t output[4] = {};
        ggml_backend_tensor_set(tensor, input, 0, sizeof(input));
        ggml_backend_tensor_get(tensor, output, 0, sizeof(output));
        CHECK(std::memcmp(input, output, sizeof(input)) == 0, "AMD device buffer round-trips host data");
        ggml_backend_buffer_free(buffer);
    }

    ggml_free(ctx);
    ggml_backend_free(backend);
}

static struct ggml_amd_device_context * find_amd_device_context_for_provider(
    ggml_backend_reg_t reg,
    const char * provider_name) {
    if (!reg || !provider_name) {
        return nullptr;
    }

    const size_t count = ggml_backend_reg_dev_count(reg);
    for (size_t i = 0; i < count; ++i) {
        ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, i);
        if (!dev) {
            continue;
        }
        auto device_ctx = (struct ggml_amd_device_context *)dev->context;
        if (!device_ctx || !device_ctx->provider || !device_ctx->provider->iface || !device_ctx->provider->iface->name) {
            continue;
        }
        if (std::strcmp(device_ctx->provider->iface->name, provider_name) == 0) {
            return device_ctx;
        }
    }

    return nullptr;
}

static void test_hip_dma_buf_import(void) {
    const char * dma_heap_paths = std::getenv("GGML_AMD_DMA_HEAP_PATH");
    auto dma_heap_candidates = ggml_amd_dma_heap_paths();

    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) {
        std::fprintf(stdout, "     HIP dma-buf import skipped (no AMD device)\n");
        return;
    }

    auto device_ctx = find_amd_device_context_for_provider(reg, "hip");
    if (!device_ctx) {
        std::fprintf(stdout, "     HIP dma-buf import skipped (no HIP provider)\n");
        return;
    }

    if (!device_ctx || !device_ctx->provider || !device_ctx->provider->iface ||
        !device_ctx->provider->iface->import_allocation || !device_ctx->provider->iface->release_import) {
        CHECK(false, "AMD device exposes HIP dma-buf import callbacks");
        return;
    }

    struct ggml_amd_import * import = nullptr;
    struct ggml_amd_allocation * allocation = nullptr;

    ggml_status status = GGML_STATUS_FAILED;
    const char * successful_heap = nullptr;
    std::string failed_heap;
    size_t allocation_attempts = 0;
    bool saw_supported_candidate = false;
    for (const auto & heap_path : dma_heap_candidates) {
        ggml_amd_dma_heap_set_preferred_path(heap_path.c_str());

        if (allocation) {
            ggml_amd_allocation_release(allocation);
            allocation = nullptr;
        }
        allocation = ggml_amd_allocation_create(
            GGML_AMD_DOMAIN_SHARED_SYSTEM, 4096, 4096, GGML_AMD_COHERENCY_SHARED);
        if (!allocation) {
            failed_heap = heap_path;
            continue;
        }
        ++allocation_attempts;

        const bool supports_import = device_ctx->provider->iface->supports_import(
            device_ctx->provider, allocation);
        if (supports_import) {
            saw_supported_candidate = true;
        }
        if (!supports_import) {
            ggml_amd_allocation_release(allocation);
            allocation = nullptr;
            continue;
        }

        import = nullptr;
        status = device_ctx->provider->iface->import_allocation(device_ctx->provider, allocation, &import);
        if (status == GGML_STATUS_SUCCESS && import != nullptr) {
            successful_heap = heap_path.c_str();
            break;
        }

        if (import) {
            device_ctx->provider->iface->release_import(device_ctx->provider, import);
            import = nullptr;
        }
    }

    ggml_amd_dma_heap_set_preferred_path(nullptr);

    if (allocation) {
        ggml_amd_allocation_release(allocation);
        allocation = nullptr;
    }

    if (!saw_supported_candidate) {
        std::fprintf(stdout, "     HIP dma-buf import skipped (shared-system support not enabled by backend)\n");
        if (allocation_attempts > 0) {
            std::fprintf(stdout, "     Shared-system allocations created: %zu\n", allocation_attempts);
        } else {
            std::fprintf(stdout, "     No shared-system allocations were created\n");
        }
        return;
    }

    CHECK(status == GGML_STATUS_SUCCESS && import != nullptr, "HIP imports a system dma-buf");
    if (status != GGML_STATUS_SUCCESS || import == nullptr) {
#ifdef __HIP_PLATFORM_AMD__
        const auto last_error = static_cast<hipError_t>(ggml_amd_hip_get_last_import_error());
        std::fprintf(stderr, "     HIP import failed: last_error=%d %s\n", static_cast<int>(last_error), hipGetErrorString(last_error));
        std::fprintf(stderr, "     GGML_AMD_DMA_HEAP_PATH=%s\n", dma_heap_paths ? dma_heap_paths : "<unset>");
        std::fprintf(stderr, "     Shared-system allocation attempts: %zu\n", allocation_attempts);
        if (allocation_attempts == 0) {
            std::fprintf(stderr, "     No shared-system allocations created for any candidate\n");
        }
        if (!failed_heap.empty()) {
            std::fprintf(stderr, "     Last failed heap: %s\n", failed_heap.c_str());
        }
        if (!dma_heap_candidates.empty()) {
            std::fprintf(stderr, "     Tested %zu dma-heap candidate(s)\n", dma_heap_candidates.size());
            for (size_t i = 0; i < dma_heap_candidates.size(); ++i) {
                std::fprintf(stderr, "      %zu) %s\n", i + 1, dma_heap_candidates[i].c_str());
            }
        }
#else
        std::fprintf(stderr, "     HIP import failed on non-HIP runtime build\n");
#endif
        return;
    }
    if (import) {
        device_ctx->provider->iface->release_import(device_ctx->provider, import);
        import = nullptr;
    }
    if (successful_heap) {
        std::fprintf(stdout, "     HIP dma-buf import succeeded via %s\n", successful_heap);
    }
    ggml_amd_allocation_release(allocation);
}

#ifdef GGML_AMD_VULKAN
static void test_vulkan_to_hip_dma_buf_import(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) {
        std::fprintf(stdout, "     Vulkan->HIP dma-buf import skipped (no AMD device)\n");
        return;
    }

    auto hip_ctx = find_amd_device_context_for_provider(reg, "hip");
    auto vulkan_ctx = find_amd_device_context_for_provider(reg, "vulkan");
    if (!hip_ctx || !vulkan_ctx) {
        std::fprintf(stdout, "     Vulkan->HIP dma-buf import skipped (provider missing)\n");
        return;
    }

    if (!hip_ctx->provider->iface || !vulkan_ctx->provider->iface ||
        !hip_ctx->provider->iface->supports_import ||
        !hip_ctx->provider->iface->import_allocation ||
        !hip_ctx->provider->iface->release_import) {
        CHECK(false, "AMD registry exposes Vulkan and HIP provider interfaces");
        return;
    }

    struct ggml_amd_allocation * exported = ggml_amd_vulkan_create_exportable_allocation(
        vulkan_ctx->provider,
        4096,
        4096);
    if (!exported) {
        std::fprintf(stdout, "     Vulkan->HIP dma-buf import skipped (Vulkan export allocation unavailable)\n");
        return;
    }

    const bool supports_import = hip_ctx->provider->iface->supports_import(hip_ctx->provider, exported);
    if (!supports_import) {
        std::fprintf(stdout, "     Vulkan->HIP dma-buf import skipped (backend reports unsupported on this build/runtime)\n");
        ggml_amd_allocation_release(exported);
        return;
    }

    struct ggml_amd_import * import = nullptr;
    const ggml_status status = hip_ctx->provider->iface->import_allocation(
        hip_ctx->provider,
        exported,
        &import);
    CHECK(status == GGML_STATUS_SUCCESS && import != nullptr, "HIP imports Vulkan-exported dma-buf");
    if (status != GGML_STATUS_SUCCESS || import == nullptr) {
#ifdef __HIP_PLATFORM_AMD__
        const auto last_error = static_cast<hipError_t>(ggml_amd_hip_get_last_import_error());
        std::fprintf(stderr, "     HIP Vulkan->HIP dma-buf import failed: last_error=%d %s\n", static_cast<int>(last_error), hipGetErrorString(last_error));
#else
        std::fprintf(stderr, "     HIP Vulkan->HIP dma-buf import failed on non-HIP runtime build\n");
#endif
        ggml_amd_allocation_release(exported);
        return;
    }
    if (import) {
        hip_ctx->provider->iface->release_import(hip_ctx->provider, import);
    }
    ggml_amd_allocation_release(exported);
}
#endif

static void test_device_out_of_bounds(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = ggml_backend_reg_dev_count(reg);
    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, count);
    CHECK(dev == nullptr, "out-of-bounds device index returns nullptr");

    dev = ggml_backend_reg_dev_get(reg, count + 100);
    CHECK(dev == nullptr, "far out-of-bounds device index returns nullptr");
}

static void test_proc_address(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    void * fn = ggml_backend_reg_get_proc_address(reg, "ggml_backend_is_amd");
    CHECK(fn != nullptr, "get_proc_address('ggml_backend_is_amd') returns non-null");
    CHECK(fn == (void *)ggml_backend_is_amd, "get_proc_address returns correct function pointer");

    fn = ggml_backend_reg_get_proc_address(reg, "nonexistent_function");
    CHECK(fn == nullptr, "get_proc_address('nonexistent_function') returns nullptr");
}

#ifdef GGML_AMD_HIP
static void test_hip_provider_present(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    // On systems with HIP, we expect at least one device
    size_t count = ggml_backend_reg_dev_count(reg);
    CHECK(count > 0, "HIP provider present -> at least one device");
}
#endif

#ifdef GGML_AMD_VULKAN
static void test_vulkan_provider_present(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = ggml_backend_reg_dev_count(reg);
    CHECK(count > 0, "Vulkan provider present -> at least one device");
}
#endif

int main(void) {
    std::fprintf(stdout, "=== test-amd-registry ===\n");

    test_registry_valid();
    test_registry_name();
    test_config_parse();
    test_device_count();
    test_device_names();
    test_dev_is_amd();
    test_backend_is_amd();
    test_device_buffer_round_trip();
    test_hip_dma_buf_import();
#ifdef GGML_AMD_VULKAN
    test_vulkan_to_hip_dma_buf_import();
#endif
    test_device_out_of_bounds();
    test_proc_address();

#ifdef GGML_AMD_HIP
    test_hip_provider_present();
#endif

#ifdef GGML_AMD_VULKAN
    test_vulkan_provider_present();
#endif

    std::fprintf(stdout, "\n");
    if (g_failures == 0) {
        std::fprintf(stdout, "PASS: all tests passed\n");
        return 0;
    } else {
        std::fprintf(stderr, "FAIL: %d test(s) failed\n", g_failures);
        return 1;
    }
}
