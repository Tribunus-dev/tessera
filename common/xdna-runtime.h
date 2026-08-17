#pragma once

//
// AMD XDNA (Ryzen AI NPU) device runtime - the AMD counterpart of the
// Apple ANE sidecar in ane-mtp.h. Where ane-mtp.h is the product-level
// fused-function surface, this is the device foundation under it:
// amdxdna accel-node open, AIE / firmware / clock queries, hardware
// contexts, buffer objects, and host-side xclbin container inspection.
//
// Implemented in xdna-runtime.cpp on Linux against the amdxdna DRM UAPI
// (drm/amdxdna_accel.h, raw ioctl - no XRT and no libdrm needed). Every
// other platform links xdna-runtime-stub.cpp, which returns the "no
// NPU" values below. All entry points are safe to call when no NPU is
// present.
//

#include <cstdint>
#include <string>
#include <vector>

struct common_xdna_device;
struct common_xdna_context;
struct common_xdna_bo;

struct common_xdna_device_info {
    std::string device_node;   // e.g. /dev/accel/accel0
    uint32_t aie_major = 0;    // AIE generation: 1.1 = XDNA 1, 2.x = XDNA 2
    uint32_t aie_minor = 0;
    uint32_t fw_major = 0;
    uint32_t fw_minor = 0;
    uint32_t fw_patch = 0;
    uint32_t fw_build = 0;
    uint32_t col_size = 0;     // bytes per AIE column
    uint32_t cols = 0;         // AIE array geometry
    uint32_t rows = 0;
    uint32_t core_rows = 0;
    uint32_t mem_rows = 0;
    uint32_t shim_rows = 0;
    uint32_t npu_clock_mhz = 0;
    uint32_t h_clock_mhz = 0;
};

// Buffer object kind; the values mirror enum amdxdna_bo_type in the UAPI.
enum class common_xdna_bo_kind : uint32_t {
    shmem    = 1,   // host-shared memory
    dev_heap = 2,   // device heap backing dev allocations
    dev      = 3,   // device-local memory
    cmd      = 4,   // command buffer
};

// True when at least one amdxdna accel node opens.
bool common_xdna_available();

// Open the first usable accel node and query its identity. False when no
// NPU is present or a query fails.
bool common_xdna_device_query(common_xdna_device_info * info);

common_xdna_device * common_xdna_device_open();  // nullptr when unavailable
void common_xdna_device_close(common_xdna_device * device);
const common_xdna_device_info * common_xdna_device_get_info(const common_xdna_device * device);

bool common_xdna_context_create(common_xdna_device * device, common_xdna_context ** out);
void common_xdna_context_destroy(common_xdna_context * context);

common_xdna_bo * common_xdna_bo_alloc(common_xdna_device * device, uint64_t bytes, common_xdna_bo_kind kind);
void common_xdna_bo_free(common_xdna_bo * bo);
// Host view of the buffer, valid until common_xdna_bo_free. nullptr on
// failure.
void * common_xdna_bo_map(common_xdna_bo * bo);
// NPU device virtual address of the buffer (the value instruction-blob
// relocations are patched with). 0 when unavailable.
uint64_t common_xdna_bo_device_addr(const common_xdna_bo * bo);
uint64_t common_xdna_bo_size(const common_xdna_bo * bo);
// DMA sync. from_device=false pushes host writes toward the NPU; true
// pulls NPU writes back to the host view.
bool common_xdna_bo_sync(const common_xdna_bo * bo, bool from_device);

// Host-side xclbin2 container inspection; no device access. The layout is
// the one XRT xclbinutil emits for MLIR-AIE DPU kernels; parsing fails
// closed on anything else.
struct common_xdna_xclbin_kernel {
    std::string name;           // e.g. "MLIR_AIE:MLIRAIE"
    uint32_t kernel_id = 0;     // DPU kernel id, e.g. 0x901
    uint32_t ip_type = 0;
};

struct common_xdna_xclbin_mem {
    std::string tag;            // e.g. "HOST", "SRAM"
    uint64_t size_kb = 0;
    uint64_t base_address = 0;
};

struct common_xdna_xclbin_info {
    std::string uuid;                          // 32 hex chars
    uint32_t section_count = 0;
    bool has_aie_partition = false;            // device image section present
    uint64_t aie_partition_size = 0;
    std::vector<common_xdna_xclbin_kernel> kernels;   // from IP_LAYOUT
    std::vector<common_xdna_xclbin_mem> mems;         // from MEM_TOPOLOGY
};

bool common_xdna_xclbin_inspect(const std::string & path, common_xdna_xclbin_info * out);
