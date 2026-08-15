//
// xdna-runtime-stub.cpp
//
// Non-Linux fallback for the AMD XDNA NPU API declared in xdna-runtime.h.
// The real implementation (xdna-runtime.cpp) needs the amdxdna DRM UAPI
// (drm/amdxdna_accel.h) and is only compiled on Linux when that header
// is present. This stub keeps the symbols resolvable everywhere else:
// every entry point returns the header's "no NPU" value, and no caller
// treats that as fatal.
//

#include "xdna-runtime.h"

bool common_xdna_available() {
    return false;
}

bool common_xdna_device_query(common_xdna_device_info * /*info*/) {
    return false;
}

common_xdna_device * common_xdna_device_open() {
    return nullptr;
}

void common_xdna_device_close(common_xdna_device * /*device*/) {
}

const common_xdna_device_info * common_xdna_device_get_info(const common_xdna_device * /*device*/) {
    return nullptr;
}

bool common_xdna_context_create(common_xdna_device * /*device*/, common_xdna_context ** /*out*/) {
    return false;
}

void common_xdna_context_destroy(common_xdna_context * /*context*/) {
}

common_xdna_bo * common_xdna_bo_alloc(
        common_xdna_device * /*device*/,
        uint64_t /*bytes*/,
        common_xdna_bo_kind /*kind*/) {
    return nullptr;
}

void common_xdna_bo_free(common_xdna_bo * /*bo*/) {
}

void * common_xdna_bo_map(common_xdna_bo * /*bo*/) {
    return nullptr;
}

uint64_t common_xdna_bo_device_addr(const common_xdna_bo * /*bo*/) {
    return 0;
}

uint64_t common_xdna_bo_size(const common_xdna_bo * /*bo*/) {
    return 0;
}

bool common_xdna_bo_sync(const common_xdna_bo * /*bo*/, bool /*from_device*/) {
    return false;
}

bool common_xdna_xclbin_inspect(const std::string & /*path*/, common_xdna_xclbin_info * /*out*/) {
    return false;
}
