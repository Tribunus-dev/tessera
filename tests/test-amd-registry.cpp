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

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

static void test_registry_valid(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    CHECK(reg != nullptr, "ggml_backend_amd_reg() returns non-null");
    CHECK(reg->iface.get_name != nullptr, "registry has get_name");
    CHECK(reg->iface.get_device_count != nullptr, "registry has get_device_count");
    CHECK(reg->iface.get_device != nullptr, "registry has get_device");
}

static void test_registry_name(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    const char * name = reg->iface.get_name(reg);
    CHECK(name != nullptr, "registry name is non-null");
    CHECK(name != nullptr && strcmp(name, "AMD") == 0, "registry name is 'AMD'");
}

static void test_device_count(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = reg->iface.get_device_count(reg);
    // Count can be 0 on systems without AMD hardware
    CHECK(count >= 0, "device count is non-negative");

    std::fprintf(stdout, "     device count: %zu\n", count);
}

static void test_device_names(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = reg->iface.get_device_count(reg);
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = reg->iface.get_device(reg, i);
        CHECK(dev != nullptr, "device is non-null");

        if (dev && dev->iface.get_name) {
            const char * name = dev->iface.get_name(dev);
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

    size_t count = reg->iface.get_device_count(reg);
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = reg->iface.get_device(reg, i);
        if (dev) {
            bool is_amd = ggml_backend_dev_is_amd(dev);
            CHECK(is_amd, "ggml_backend_dev_is_amd() returns true for AMD device");
        }
    }
}

static void test_backend_is_amd(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = reg->iface.get_device_count(reg);
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = reg->iface.get_device(reg, i);
        if (dev && dev->iface.init_backend) {
            ggml_backend_t backend = dev->iface.init_backend(dev, nullptr);
            // init_backend may return nullptr if not fully implemented
            if (backend) {
                bool is_amd = ggml_backend_is_amd(backend);
                CHECK(is_amd, "ggml_backend_is_amd() returns true for AMD backend");
            }
        }
    }
}

static void test_device_out_of_bounds(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = reg->iface.get_device_count(reg);
    ggml_backend_dev_t dev = reg->iface.get_device(reg, count);
    CHECK(dev == nullptr, "out-of-bounds device index returns nullptr");

    dev = reg->iface.get_device(reg, count + 100);
    CHECK(dev == nullptr, "far out-of-bounds device index returns nullptr");
}

static void test_proc_address(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    if (reg->iface.get_proc_address) {
        void * fn = reg->iface.get_proc_address(reg, "ggml_backend_is_amd");
        CHECK(fn != nullptr, "get_proc_address('ggml_backend_is_amd') returns non-null");
        CHECK(fn == (void *)ggml_backend_is_amd, "get_proc_address returns correct function pointer");

        fn = reg->iface.get_proc_address(reg, "nonexistent_function");
        CHECK(fn == nullptr, "get_proc_address('nonexistent_function') returns nullptr");
    }
}

#ifdef GGML_AMD_HIP
static void test_hip_provider_present(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    // On systems with HIP, we expect at least one device
    size_t count = reg->iface.get_device_count(reg);
    CHECK(count > 0, "HIP provider present -> at least one device");
}
#endif

#ifdef GGML_AMD_VULKAN
static void test_vulkan_provider_present(void) {
    ggml_backend_reg_t reg = ggml_backend_amd_reg();
    if (!reg) return;

    size_t count = reg->iface.get_device_count(reg);
    CHECK(count > 0, "Vulkan provider present -> at least one device");
}
#endif

int main(void) {
    std::fprintf(stdout, "=== test-amd-registry ===\n");

    test_registry_valid();
    test_registry_name();
    test_device_count();
    test_device_names();
    test_dev_is_amd();
    test_backend_is_amd();
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
