#include "../ggml-amd-internal.h"
#include "../ggml-amd-provider.h"
#include "ggml.h"

#include <algorithm>
#include <cstring>
#include <vector>

#ifdef __linux__
#include <unistd.h>
#endif

#ifdef GGML_AMD_VULKAN

#include <vulkan/vulkan.h>

struct ggml_amd_vulkan_import_owner {
    VkDevice device;
    VkBuffer buffer;
    VkDeviceMemory memory;
    int fd;
};

struct ggml_amd_vulkan_context {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    uint32_t queue_family_index;
    bool initialized;
    PFN_vkGetMemoryFdKHR get_memory_fd;
};

struct ggml_amd_vulkan_export_owner {
    VkDevice device;
    VkBuffer buffer;
    VkDeviceMemory memory;
};

static bool ggml_amd_vulkan_has_extension(
    const char * extension_name,
    uint32_t count,
    const char * const * names) {

    for (uint32_t i = 0; i < count; ++i) {
        if (strcmp(extension_name, names[i]) == 0) {
            return true;
        }
    }
    return false;
}

static bool ggml_amd_vulkan_init_context(ggml_amd_vulkan_context & ctx) {
    VkApplicationInfo app_info = {};
    app_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "ggml-amd-vulkan";
    app_info.apiVersion = VK_API_VERSION_1_1;

    VkInstanceCreateInfo instance_info = {};
    instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.pApplicationInfo = &app_info;

    if (vkCreateInstance(&instance_info, nullptr, &ctx.instance) != VK_SUCCESS) {
        return false;
    }

    uint32_t physical_count = 0;
    if (vkEnumeratePhysicalDevices(ctx.instance, &physical_count, nullptr) != VK_SUCCESS || physical_count == 0) {
        return false;
    }

    std::vector<VkPhysicalDevice> physical_devices(physical_count, nullptr);
    if (vkEnumeratePhysicalDevices(ctx.instance, &physical_count, physical_devices.data()) != VK_SUCCESS) {
        return false;
    }

    VkPhysicalDevice selected_device = VK_NULL_HANDLE;
    uint32_t selected_family = 0;
    std::vector<const char *> required_device_exts {
        VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    };

    for (VkPhysicalDevice device : physical_devices) {
        VkPhysicalDeviceProperties props = {};
        vkGetPhysicalDeviceProperties(device, &props);
        if (props.vendorID != 0x1002) {
            continue;
        }

        uint32_t queue_family_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nullptr);
        std::vector<VkQueueFamilyProperties> queue_families(queue_family_count);
        vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.data());

        uint32_t compute_family = UINT32_MAX;
        for (uint32_t i = 0; i < queue_family_count; ++i) {
            if ((queue_families[i].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0 && queue_families[i].queueCount > 0) {
                compute_family = i;
                break;
            }
        }

        if (compute_family == UINT32_MAX) {
            continue;
        }

        uint32_t ext_count = 0;
        vkEnumerateDeviceExtensionProperties(device, nullptr, &ext_count, nullptr);
        std::vector<VkExtensionProperties> extensions(ext_count);
        vkEnumerateDeviceExtensionProperties(device, nullptr, &ext_count, extensions.data());

        std::vector<const char *> extension_names;
        extension_names.reserve(ext_count);
        for (const auto & ext : extensions) {
            extension_names.push_back(ext.extensionName);
        }

        bool has_required = true;
        for (const char * required_ext : required_device_exts) {
            if (!ggml_amd_vulkan_has_extension(required_ext, ext_count, extension_names.data())) {
                has_required = false;
                break;
            }
        }
        if (!has_required) {
            continue;
        }

        selected_device = device;
        selected_family = compute_family;
        break;
    }

    if (selected_device == VK_NULL_HANDLE) {
        return false;
    }

    float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_create = {};
    queue_create.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_create.queueFamilyIndex = selected_family;
    queue_create.queueCount = 1;
    queue_create.pQueuePriorities = &queue_priority;

    VkDeviceCreateInfo device_info = {};
    device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_create;
    device_info.enabledExtensionCount = static_cast<uint32_t>(required_device_exts.size());
    device_info.ppEnabledExtensionNames = required_device_exts.data();

    VkDevice device = VK_NULL_HANDLE;
    if (vkCreateDevice(selected_device, &device_info, nullptr, &device) != VK_SUCCESS) {
        return false;
    }

    const auto get_memory_fd = reinterpret_cast<PFN_vkGetMemoryFdKHR>(
        vkGetDeviceProcAddr(device, "vkGetMemoryFdKHR"));
    if (!get_memory_fd) {
        vkDestroyDevice(device, nullptr);
        return false;
    }

    ctx.physical_device = selected_device;
    ctx.queue_family_index = selected_family;
    ctx.device = device;
    ctx.get_memory_fd = get_memory_fd;
    ctx.initialized = true;
    return true;
}

static void ggml_amd_vulkan_destroy_context(ggml_amd_vulkan_context & ctx) {
    if (ctx.device != VK_NULL_HANDLE) {
        vkDestroyDevice(ctx.device, nullptr);
        ctx.device = VK_NULL_HANDLE;
    }
    if (ctx.instance != VK_NULL_HANDLE) {
        vkDestroyInstance(ctx.instance, nullptr);
        ctx.instance = VK_NULL_HANDLE;
    }
    ctx.initialized = false;
}

static bool ggml_amd_vulkan_context_ensure(struct ggml_amd_provider * provider) {
    if (!provider || !provider->context) {
        return false;
    }

    auto & ctx = *static_cast<ggml_amd_vulkan_context *>(provider->context);
    if (ctx.initialized) {
        return true;
    }

    if (!ggml_amd_vulkan_init_context(ctx)) {
        ggml_amd_vulkan_destroy_context(ctx);
        return false;
    }

    return true;
}

static bool ggml_amd_vulkan_select_memory_type(
    VkPhysicalDevice physical_device,
    VkMemoryRequirements requirements,
    uint32_t * out_index) {

    VkPhysicalDeviceMemoryProperties mem_props = {};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_props);

    for (uint32_t i = 0; i < mem_props.memoryTypeCount; ++i) {
        const VkMemoryType & mem_type = mem_props.memoryTypes[i];
        if ((requirements.memoryTypeBits & (1u << i)) == 0) {
            continue;
        }
        if ((mem_type.propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
            *out_index = i;
            return true;
        }
    }

    for (uint32_t i = 0; i < mem_props.memoryTypeCount; ++i) {
        const VkMemoryType & mem_type = mem_props.memoryTypes[i];
        if ((requirements.memoryTypeBits & (1u << i)) != 0 &&
            (mem_type.propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
            *out_index = i;
            return true;
        }
    }

    return false;
}

static void ggml_amd_vulkan_release_allocation_owner(void * context) {
    auto owner = (ggml_amd_vulkan_export_owner *)context;
    if (!owner) {
        return;
    }

    if (owner->device != VK_NULL_HANDLE) {
        if (owner->buffer != VK_NULL_HANDLE) {
            vkDestroyBuffer(owner->device, owner->buffer, nullptr);
        }
        if (owner->memory != VK_NULL_HANDLE) {
            vkFreeMemory(owner->device, owner->memory, nullptr);
        }
    }
    delete owner;
}

static void ggml_amd_vulkan_release_import_owner(void * context) {
    auto owner = (ggml_amd_vulkan_import_owner *)context;
    if (!owner) {
        return;
    }

    if (owner->device != VK_NULL_HANDLE) {
        if (owner->buffer != VK_NULL_HANDLE) {
            vkDestroyBuffer(owner->device, owner->buffer, nullptr);
        }
        if (owner->memory != VK_NULL_HANDLE) {
            vkFreeMemory(owner->device, owner->memory, nullptr);
        }
    }
    if (owner->fd >= 0) {
        close(owner->fd);
    }
    delete owner;
}

static ggml_status ggml_amd_vulkan_allocate_exportable(
    struct ggml_amd_provider * provider,
    size_t size,
    size_t alignment,
    struct ggml_amd_allocation ** out_allocation) {

    if (!provider || !out_allocation || size == 0) {
        return GGML_STATUS_FAILED;
    }

    auto ctx = (ggml_amd_vulkan_context *)provider->context;
    if (!ctx) {
        return GGML_STATUS_FAILED;
    }

    if (!ggml_amd_vulkan_context_ensure(provider)) {
        return GGML_STATUS_FAILED;
    }

    if (alignment == 0) {
        alignment = 1;
    }

    const size_t aligned_size = (size + alignment - 1) / alignment * alignment;

    VkExternalMemoryBufferCreateInfo external_buffer = {};
    external_buffer.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
    external_buffer.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;

    VkBufferCreateInfo buffer_info = {};
    buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.pNext = &external_buffer;
    buffer_info.size = aligned_size;
    buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    VkBuffer buffer = VK_NULL_HANDLE;
    if (vkCreateBuffer(ctx->device, &buffer_info, nullptr, &buffer) != VK_SUCCESS) {
        return GGML_STATUS_FAILED;
    }

    VkMemoryRequirements requirements = {};
    vkGetBufferMemoryRequirements(ctx->device, buffer, &requirements);

    uint32_t memory_type = 0;
    if (!ggml_amd_vulkan_select_memory_type(ctx->physical_device, requirements, &memory_type)) {
        vkDestroyBuffer(ctx->device, buffer, nullptr);
        return GGML_STATUS_FAILED;
    }

    VkExportMemoryAllocateInfo export_info = {};
    export_info.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
    export_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;

    VkMemoryAllocateInfo alloc_info = {};
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.pNext = &export_info;
    alloc_info.allocationSize = requirements.size;
    alloc_info.memoryTypeIndex = memory_type;

    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkResult error = vkAllocateMemory(ctx->device, &alloc_info, nullptr, &memory);
    if (error != VK_SUCCESS) {
        vkDestroyBuffer(ctx->device, buffer, nullptr);
        return GGML_STATUS_FAILED;
    }

    error = vkBindBufferMemory(ctx->device, buffer, memory, 0);
    if (error != VK_SUCCESS) {
        vkFreeMemory(ctx->device, memory, nullptr);
        vkDestroyBuffer(ctx->device, buffer, nullptr);
        return GGML_STATUS_FAILED;
    }

    VkMemoryGetFdInfoKHR fd_info = {};
    fd_info.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
    fd_info.pNext = nullptr;
    fd_info.memory = memory;
    fd_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;

    int fd = -1;
    error = ctx->get_memory_fd(ctx->device, &fd_info, &fd);
    if (error != VK_SUCCESS) {
        vkFreeMemory(ctx->device, memory, nullptr);
        vkDestroyBuffer(ctx->device, buffer, nullptr);
        return GGML_STATUS_FAILED;
    }

    auto allocation = ggml_amd_allocation_wrap_external_fd(
        fd,
        aligned_size,
        alignment,
        GGML_AMD_EXTERNAL_HANDLE_KIND_VULKAN_OPAQUE_FD,
        GGML_AMD_FD_OWNERSHIP_OWNED,
        GGML_AMD_COHERENCY_GPU_ONLY);
    if (!allocation) {
        if (ctx->get_memory_fd) {
            close(fd);
        }
        vkFreeMemory(ctx->device, memory, nullptr);
        vkDestroyBuffer(ctx->device, buffer, nullptr);
        return GGML_STATUS_FAILED;
    }

    auto owner = new ggml_amd_vulkan_export_owner();
    owner->device = ctx->device;
    owner->buffer = buffer;
    owner->memory = memory;
    ggml_amd_allocation_set_cleanup(allocation, owner, ggml_amd_vulkan_release_allocation_owner);
    *out_allocation = allocation;
    return GGML_STATUS_SUCCESS;
}

static bool ggml_amd_vulkan_probe_impl(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    auto ctx = new ggml_amd_vulkan_context();
    ctx->instance = VK_NULL_HANDLE;
    ctx->physical_device = VK_NULL_HANDLE;
    ctx->device = VK_NULL_HANDLE;
    ctx->queue_family_index = 0;
    ctx->initialized = false;
    ctx->get_memory_fd = nullptr;
    provider->context = ctx;

    if (!ggml_amd_vulkan_context_ensure(provider)) {
        provider->context = nullptr;
        ggml_amd_vulkan_destroy_context(*ctx);
        delete ctx;
        return false;
    }

    if (result) {
        VkPhysicalDeviceProperties props = {};
        vkGetPhysicalDeviceProperties(ctx->physical_device, &props);
        VkPhysicalDeviceMemoryProperties mem_props = {};
        vkGetPhysicalDeviceMemoryProperties(ctx->physical_device, &mem_props);

        uint64_t memory_total = 0;
        for (uint32_t i = 0; i < mem_props.memoryHeapCount; ++i) {
            if ((mem_props.memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
                memory_total += mem_props.memoryHeaps[i].size;
            }
        }

        result->provider_name = "vulkan";
        result->device_name = props.deviceName;
        result->device_arch = "vulkan";
        result->pci_domain = 0;
        result->pci_bus = 0;
        result->pci_device = 0;
        result->pci_function = 0;
        result->memory_total = memory_total;
        result->memory_free = memory_total;
        result->supports_external_memory = 1;
        result->supports_dma_buf_import = 1;
    }

    return true;
}

static bool ggml_amd_vulkan_supports_op_impl(struct ggml_amd_provider * provider, const struct ggml_tensor * op) {
    (void)provider;
    (void)op;
    return false;
}

static bool ggml_amd_vulkan_supports_import_impl(struct ggml_amd_provider * provider, struct ggml_amd_allocation * alloc) {
    if (!provider || !provider->context || !alloc || alloc->dma_buf_fd < 0) {
        return false;
    }
    if (alloc->external_handle_kind == GGML_AMD_EXTERNAL_HANDLE_KIND_NONE) {
        return false;
    }
    if (alloc->coherency != GGML_AMD_COHERENCY_GPU_ONLY && alloc->coherency != GGML_AMD_COHERENCY_SHARED) {
        return false;
    }
    if (alloc->external_handle_kind == GGML_AMD_EXTERNAL_HANDLE_KIND_UNKNOWN) {
#if !defined(VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT) && !defined(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT)
        return false;
#endif
    }
    if (alloc->external_handle_kind != GGML_AMD_EXTERNAL_HANDLE_KIND_UNKNOWN &&
        alloc->external_handle_kind != GGML_AMD_EXTERNAL_HANDLE_KIND_VULKAN_OPAQUE_FD) {
        return false;
    }

    return alloc->domain == GGML_AMD_DOMAIN_IMPORTED_EXTERNAL ||
           alloc->domain == GGML_AMD_DOMAIN_SHARED_SYSTEM ||
           alloc->domain == GGML_AMD_DOMAIN_GPU_LOCAL_EXPORTABLE;
}

static ggml_status ggml_amd_vulkan_import_allocation_impl(
    struct ggml_amd_provider * provider,
    struct ggml_amd_allocation * alloc,
    struct ggml_amd_import ** out_import) {
    auto ctx = static_cast<ggml_amd_vulkan_context *>(provider ? provider->context : nullptr);
    if (!ctx || !alloc || !out_import || alloc->dma_buf_fd < 0 || alloc->size == 0) {
        return GGML_STATUS_FAILED;
    }
    *out_import = nullptr;
    if (!ggml_amd_vulkan_context_ensure(provider)) {
        return GGML_STATUS_FAILED;
    }
    if (!ggml_amd_vulkan_supports_import_impl(provider, alloc)) {
        return GGML_STATUS_FAILED;
    }

    if (!provider->iface) {
        return GGML_STATUS_FAILED;
    }

    const auto alignment = alloc->alignment == 0 ? 1 : alloc->alignment;
    const size_t aligned_size = (alloc->size + alignment - 1) / alignment * alignment;

    VkExternalMemoryHandleTypeFlagBits handle_types[3] = {};
    int handle_type_count = 0;
    const bool explicit_opaque = alloc->external_handle_kind == GGML_AMD_EXTERNAL_HANDLE_KIND_VULKAN_OPAQUE_FD;
#if defined(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT)
    if (!explicit_opaque) {
        handle_types[handle_type_count++] = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    }
#endif
#if defined(VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT)
    handle_types[handle_type_count++] = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
#endif
#if defined(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT)
    if (explicit_opaque) {
        handle_types[handle_type_count++] = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    }
#endif

    if (handle_type_count == 0) {
        return GGML_STATUS_FAILED;
    }

    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    int active_fd = -1;
    bool imported = false;

    for (int attempt = 0; attempt < handle_type_count; ++attempt) {
        const auto handle_type = handle_types[attempt];
        active_fd = ggml_amd_allocation_dup_fd(alloc);
        if (active_fd < 0) {
            break;
        }

        VkExternalMemoryBufferCreateInfo external_buffer = {};
        external_buffer.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
        external_buffer.handleTypes = handle_type;

        VkBufferCreateInfo buffer_info = {};
        buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_info.pNext = &external_buffer;
        buffer_info.size = aligned_size;
        buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

        if (vkCreateBuffer(ctx->device, &buffer_info, nullptr, &buffer) != VK_SUCCESS) {
            close(active_fd);
            active_fd = -1;
            continue;
        }

        VkMemoryRequirements requirements = {};
        vkGetBufferMemoryRequirements(ctx->device, buffer, &requirements);

        uint32_t memory_type = 0;
        if (!ggml_amd_vulkan_select_memory_type(ctx->physical_device, requirements, &memory_type)) {
            vkDestroyBuffer(ctx->device, buffer, nullptr);
            buffer = VK_NULL_HANDLE;
            close(active_fd);
            active_fd = -1;
            continue;
        }

        VkImportMemoryFdInfoKHR import_info = {};
        import_info.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR;
        import_info.handleType = handle_type;
        import_info.fd = active_fd;
        import_info.pNext = nullptr;

        VkResult error = VK_ERROR_UNKNOWN;
        VkMemoryAllocateInfo alloc_info = {};
        alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.pNext = &import_info;
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = memory_type;

        error = vkAllocateMemory(ctx->device, &alloc_info, nullptr, &memory);
        if (error != VK_SUCCESS) {
            vkDestroyBuffer(ctx->device, buffer, nullptr);
            buffer = VK_NULL_HANDLE;
            close(active_fd);
            active_fd = -1;
            continue;
        }

        error = vkBindBufferMemory(ctx->device, buffer, memory, 0);
        if (error != VK_SUCCESS) {
            vkFreeMemory(ctx->device, memory, nullptr);
            memory = VK_NULL_HANDLE;
            vkDestroyBuffer(ctx->device, buffer, nullptr);
            buffer = VK_NULL_HANDLE;
            close(active_fd);
            active_fd = -1;
            continue;
        }

        imported = true;
        break;
    }

    if (!imported || buffer == VK_NULL_HANDLE || memory == VK_NULL_HANDLE) {
        if (buffer != VK_NULL_HANDLE) {
            vkDestroyBuffer(ctx->device, buffer, nullptr);
        }
        if (memory != VK_NULL_HANDLE) {
            vkFreeMemory(ctx->device, memory, nullptr);
        }
        if (active_fd >= 0) {
            close(active_fd);
        }
        return GGML_STATUS_FAILED;
    }

    auto owner = new ggml_amd_vulkan_import_owner();
    owner->device = ctx->device;
    owner->buffer = buffer;
    owner->memory = memory;
    owner->fd = active_fd;

    auto import = new ggml_amd_import();
    import->allocation = alloc;
    import->provider = provider;
    import->native_handle = owner;
    import->ref_count = 1;
    ggml_amd_allocation_retain(alloc);

    *out_import = import;
    return GGML_STATUS_SUCCESS;
}

static void ggml_amd_vulkan_release_import_impl(struct ggml_amd_provider * provider, struct ggml_amd_import * import) {
    (void)provider;
    if (!import) {
        return;
    }

    if (import->native_handle) {
        ggml_amd_vulkan_release_import_owner(import->native_handle);
    }
    ggml_amd_allocation_release(import->allocation);
    delete import;
}

static ggml_status ggml_amd_vulkan_submit_region_impl(
    struct ggml_amd_provider * provider,
    struct ggml_amd_region * region,
    struct ggml_amd_fence * fence) {
    (void)provider;
    (void)region;
    (void)fence;
    return GGML_STATUS_FAILED;
}

static ggml_status ggml_amd_vulkan_wait_fence_impl(struct ggml_amd_provider * provider, struct ggml_amd_fence * fence) {
    (void)provider;
    (void)fence;
    return GGML_STATUS_FAILED;
}

static void ggml_amd_vulkan_query_memory_impl(struct ggml_amd_provider * provider, struct ggml_amd_memory_info * info) {
    (void)provider;
    if (info) {
        info->total_bytes = 0;
        info->free_bytes = 0;
        info->resident_bytes = 0;
        info->imported_bytes = 0;
    }
}

static const struct ggml_amd_provider_i ggml_amd_vulkan_provider_i = {
    .name = "vulkan",
    .probe = ggml_amd_vulkan_probe_impl,
    .supports_op = ggml_amd_vulkan_supports_op_impl,
    .supports_import = ggml_amd_vulkan_supports_import_impl,
    .import_allocation = ggml_amd_vulkan_import_allocation_impl,
    .release_import = ggml_amd_vulkan_release_import_impl,
    .submit_region = ggml_amd_vulkan_submit_region_impl,
    .wait_fence = ggml_amd_vulkan_wait_fence_impl,
    .query_memory = ggml_amd_vulkan_query_memory_impl,
};

bool ggml_amd_vulkan_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    provider->iface = &ggml_amd_vulkan_provider_i;
    return ggml_amd_vulkan_probe_impl(provider, result);
}

struct ggml_amd_allocation * ggml_amd_vulkan_create_exportable_allocation(
    struct ggml_amd_provider * provider,
    size_t size,
    size_t alignment) {
    struct ggml_amd_allocation * allocation = nullptr;
    ggml_amd_vulkan_allocate_exportable(provider, size, alignment, &allocation);
    return allocation;
}

#else

struct ggml_amd_allocation * ggml_amd_vulkan_create_exportable_allocation(
    struct ggml_amd_provider * provider,
    size_t size,
    size_t alignment) {
    (void)provider;
    (void)size;
    (void)alignment;
    return nullptr;
}

bool ggml_amd_vulkan_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result) {
    (void)provider;
    (void)result;
    return false;
}

#endif
