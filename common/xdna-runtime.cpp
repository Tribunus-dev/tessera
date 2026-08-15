//
// xdna-runtime.cpp
//
// AMD XDNA (Ryzen AI NPU) device runtime on the amdxdna DRM UAPI. See
// xdna-runtime.h for the contract. The accel nodes (/dev/accel/accelN)
// are not DRM render nodes, so libdrm enumeration does not see them;
// everything here is plain open() + ioctl() against amdxdna_accel.h,
// which is the same path XRT's aie shim takes minus XRT itself.
//

#include "xdna-runtime.h"

#include "log.h"

#include <drm/amdxdna_accel.h>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

namespace {

constexpr int g_xdna_max_nodes = 8;

std::string xdna_node_path(int index) {
    return "/dev/accel/accel" + std::to_string(index);
}

// Copy a fixed-width char field that may not be NUL-terminated.
std::string xdna_field(const char * src, size_t cap) {
    return std::string(src, strnlen(src, cap));
}

int xdna_get_info(int fd, uint32_t param, void * buf, uint32_t size) {
    amdxdna_drm_get_info args = {};
    args.param        = param;
    args.buffer_size  = size;
    args.buffer       = (uint64_t) (uintptr_t) buf;
    return ioctl(fd, DRM_IOCTL_AMDXDNA_GET_INFO, &args);
}

bool xdna_query_identity(int fd, common_xdna_device_info * info) {
    amdxdna_drm_query_aie_version version = {};
    if (xdna_get_info(fd, DRM_AMDXDNA_QUERY_AIE_VERSION, &version, sizeof(version)) != 0) {
        LOG_ERR("%s: QUERY_AIE_VERSION failed: %s\n", __func__, strerror(errno));
        return false;
    }
    info->aie_major = version.major;
    info->aie_minor = version.minor;

    amdxdna_drm_query_firmware_version fw = {};
    if (xdna_get_info(fd, DRM_AMDXDNA_QUERY_FIRMWARE_VERSION, &fw, sizeof(fw)) != 0) {
        LOG_ERR("%s: QUERY_FIRMWARE_VERSION failed: %s\n", __func__, strerror(errno));
        return false;
    }
    info->fw_major = fw.major;
    info->fw_minor = fw.minor;
    info->fw_patch = fw.patch;
    info->fw_build = fw.build;

    amdxdna_drm_query_aie_metadata md = {};
    if (xdna_get_info(fd, DRM_AMDXDNA_QUERY_AIE_METADATA, &md, sizeof(md)) != 0) {
        LOG_ERR("%s: QUERY_AIE_METADATA failed: %s\n", __func__, strerror(errno));
        return false;
    }
    info->col_size   = md.col_size;
    info->cols       = md.cols;
    info->rows       = md.rows;
    info->core_rows  = md.core.row_count;
    info->mem_rows   = md.mem.row_count;
    info->shim_rows  = md.shim.row_count;

    amdxdna_drm_query_clock_metadata clk = {};
    if (xdna_get_info(fd, DRM_AMDXDNA_QUERY_CLOCK_METADATA, &clk, sizeof(clk)) != 0) {
        LOG_ERR("%s: QUERY_CLOCK_METADATA failed: %s\n", __func__, strerror(errno));
        return false;
    }
    info->npu_clock_mhz = clk.mp_npu_clock.freq_mhz;
    info->h_clock_mhz   = clk.h_clock.freq_mhz;

    return true;
}

// Returns the first accel node that opens, or -1.
int xdna_open_node(std::string * node_path) {
    for (int i = 0; i < g_xdna_max_nodes; i++) {
        const std::string path = xdna_node_path(i);
        const int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            if (node_path) {
                *node_path = path;
            }
            return fd;
        }
    }
    return -1;
}

// --- xclbin2 container (XRT xclbinutil / MLIR-AIE flavor) ---
//
// Layout verified against ggml/src/ggml-amd/xdna/kernels/xdna_kernels.xclbin:
// a fixed axlf prefix (magic / cipher / key block / unique id / header)
// followed in-line by the section table, with section bodies packed
// after it. Field order follows XRT's axlf format; section records use
// the compact 40-byte form with a 20-byte name field.

enum xdna_xclbin_section_kind : uint32_t {
    XDNA_XCLBIN_SEC_EMBEDDED_METADATA  = 2,
    XDNA_XCLBIN_SEC_MEM_TOPOLOGY       = 6,
    XDNA_XCLBIN_SEC_CONNECTIVITY       = 7,
    XDNA_XCLBIN_SEC_IP_LAYOUT          = 8,
    XDNA_XCLBIN_SEC_GROUP_TOPOLOGY     = 26,
    XDNA_XCLBIN_SEC_GROUP_CONNECTIVITY = 27,
    XDNA_XCLBIN_SEC_AIE_PARTITION      = 32,
};

#pragma pack(push, 1)
struct xdna_axlf {
    char     magic[8];          // "xclbin2\0"
    uint8_t  cipher[32];
    uint8_t  key_block[256];
    uint64_t unique_id;
    // header
    uint64_t length;            // total file size
    uint64_t time_stamp;
    uint64_t feature_rom_timestamp;
    uint16_t version_patch;
    uint8_t  version_major;
    uint8_t  version_minor;
    uint32_t mode;
    uint8_t  interface_uuid[16];
    char     platform_vbnv[64];
    uint8_t  xclbin_uuid[16];
    char     debug_bin[16];
    uint32_t num_sections;
    uint32_t pad;
    // section table (xdna_xclbin_section[num_sections]) follows in-line
};

struct xdna_xclbin_section {    // 40 bytes
    uint32_t kind;
    char     name[20];
    uint64_t offset;
    uint64_t size;
};

struct xdna_xclbin_mem_data {   // 40 bytes, MEM_TOPOLOGY / GROUP_TOPOLOGY
    uint8_t  type;
    uint8_t  used;
    uint8_t  pad[6];
    uint64_t size_kb;
    uint64_t base_address;
    char     tag[16];
};

struct xdna_xclbin_topology {   // leads the mem_data array
    int32_t  count;
    uint8_t  pad[4];
};

struct xdna_xclbin_ip_data {    // 80 bytes, IP_LAYOUT
    uint8_t  type;
    uint8_t  pad[3];
    uint8_t  subtype;
    uint8_t  functional;
    uint16_t kernel_id;
    uint64_t base_address;
    char     name[64];
};

struct xdna_xclbin_ip_layout {  // leads the ip_data array
    int32_t  count;
    uint8_t  pad[4];
};
#pragma pack(pop)

static_assert(sizeof(xdna_axlf)             == 456, "axlf prefix drifted from the xclbin2 layout");
static_assert(sizeof(xdna_xclbin_section)   == 40,  "section record drifted from the xclbin2 layout");
static_assert(sizeof(xdna_xclbin_mem_data)  == 40,  "mem_data drifted from the xclbin2 layout");
static_assert(sizeof(xdna_xclbin_ip_data)   == 80,  "ip_data drifted from the xclbin2 layout");

constexpr size_t g_xdna_xclbin_max_bytes = 256u << 20;  // sanity cap, artifacts are ~tens of KB

bool xdna_read_file(const std::string & path, std::vector<uint8_t> * out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    in.seekg(0, std::ios::end);
    const std::streamoff len = in.tellg();
    if (len <= 0 || (size_t) len > g_xdna_xclbin_max_bytes) {
        return false;
    }
    in.seekg(0, std::ios::beg);
    out->resize((size_t) len);
    in.read((char *) out->data(), len);
    return (bool) in;
}

void xdna_parse_mem_topology(const std::vector<uint8_t> & file, const xdna_xclbin_section & sec,
                             std::vector<common_xdna_xclbin_mem> * mems) {
    if (sec.size < sizeof(xdna_xclbin_topology)) {
        return;
    }
    xdna_xclbin_topology topo = {};
    memcpy(&topo, file.data() + sec.offset, sizeof(topo));
    const size_t need = sizeof(xdna_xclbin_topology) + (size_t) topo.count * sizeof(xdna_xclbin_mem_data);
    if (topo.count < 0 || topo.count > 64 || need > sec.size) {
        return;
    }
    for (int32_t i = 0; i < topo.count; i++) {
        xdna_xclbin_mem_data md = {};
        memcpy(&md, file.data() + sec.offset + sizeof(xdna_xclbin_topology) +
                    (size_t) i * sizeof(xdna_xclbin_mem_data), sizeof(md));
        common_xdna_xclbin_mem mem;
        mem.tag          = xdna_field(md.tag, sizeof(md.tag));
        mem.size_kb      = md.size_kb;
        mem.base_address = md.base_address;
        mems->push_back(std::move(mem));
    }
}

void xdna_parse_ip_layout(const std::vector<uint8_t> & file, const xdna_xclbin_section & sec,
                          std::vector<common_xdna_xclbin_kernel> * kernels) {
    if (sec.size < sizeof(xdna_xclbin_ip_layout)) {
        return;
    }
    xdna_xclbin_ip_layout layout = {};
    memcpy(&layout, file.data() + sec.offset, sizeof(layout));
    const size_t need = sizeof(xdna_xclbin_ip_layout) + (size_t) layout.count * sizeof(xdna_xclbin_ip_data);
    if (layout.count < 0 || layout.count > 64 || need > sec.size) {
        return;
    }
    for (int32_t i = 0; i < layout.count; i++) {
        xdna_xclbin_ip_data ip = {};
        memcpy(&ip, file.data() + sec.offset + sizeof(xdna_xclbin_ip_layout) +
                    (size_t) i * sizeof(xdna_xclbin_ip_data), sizeof(ip));
        common_xdna_xclbin_kernel kernel;
        kernel.name      = xdna_field(ip.name, sizeof(ip.name));
        kernel.kernel_id = ip.kernel_id;
        kernel.ip_type   = ip.type;
        kernels->push_back(std::move(kernel));
    }
}

} // anonymous namespace

struct common_xdna_device {
    int fd = -1;
    common_xdna_device_info info;
    // The driver requires a DEV_HEAP BO on the client before a hardware
    // context can be created (aie2_hwctx_init looks up client->dev_heap).
    // The heap is created as a local shmem gem object (type=DEV_HEAP,
    // vaddr=0) and mmap'd to drive amdxdna_gem_obj_mmap -> amdxdna_hmm_register,
    // which sets mem.uva. amdxdna_gem_heap_alloc then uses drm_mm on the heap
    // for subsequent DEV BO allocations.
    uint32_t dev_heap_handle = AMDXDNA_INVALID_BO_HANDLE;
    uint64_t dev_heap_bytes = 0;
    void *   dev_heap_map = nullptr;
};

// AIE 1.1 device local memory pool size for the device heap BO. The
// driver requires args->size to be aligned to dev_mem_size (a power of 2;
// 64 MiB on this generation). Not exposed via the public UAPI query set,
// so it is a per-generation constant rather than a magic number.
constexpr uint64_t g_xdna_dev_heap_bytes = 64ull << 20;

struct common_xdna_context {
    common_xdna_device * device = nullptr;
    uint32_t handle = AMDXDNA_INVALID_CTX_HANDLE;
    uint32_t syncobj_handle = 0;
};

struct common_xdna_bo {
    common_xdna_device * device = nullptr;
    uint32_t handle = AMDXDNA_INVALID_BO_HANDLE;
    uint64_t bytes = 0;
    void * map = nullptr;
    bool map_owned = false;    // true when this runtime mmap'd the view
    uint64_t vaddr = 0;        // driver-provided host view, 0 when mmap needed
    uint64_t map_offset = 0;   // drm fake offset for mmap()
    uint64_t xdna_addr = 0;    // NPU device virtual address
};

bool common_xdna_available() {
    std::string path;
    const int fd = xdna_open_node(&path);
    if (fd < 0) {
        return false;
    }
    close(fd);
    return true;
}

bool common_xdna_device_query(common_xdna_device_info * info) {
    if (!info) {
        return false;
    }
    std::string path;
    const int fd = xdna_open_node(&path);
    if (fd < 0) {
        return false;
    }
    *info = {};
    info->device_node = path;
    const bool ok = xdna_query_identity(fd, info);
    close(fd);
    return ok;
}

// Allocate the per-client device-heap BO (local shmem gem object) and
// mmap it. The mmap is the load-bearing step: it drives amdxdna_gem_obj_mmap
// -> amdxdna_hmm_register which sets abo->mem.uva on first mapping. Without
// the mmap, amdxdna_gem_heap_alloc rejects subsequent DEV BO allocations
// with "Invalid dev heap userptr".
static bool xdna_alloc_heap_bo(common_xdna_device * device) {
    amdxdna_drm_create_bo create = {};
    create.size = g_xdna_dev_heap_bytes;
    create.type = AMDXDNA_BO_DEV_HEAP;
    create.vaddr = 0;  // local shmem, not userptr-imported
    if (ioctl(device->fd, DRM_IOCTL_AMDXDNA_CREATE_BO, &create) != 0) {
        LOG_ERR("%s: CREATE_BO(heap, %llu bytes) failed: %s\n", __func__,
                (unsigned long long) g_xdna_dev_heap_bytes, strerror(errno));
        return false;
    }

    amdxdna_drm_get_bo_info info = {};
    info.handle = create.handle;
    if (ioctl(device->fd, DRM_IOCTL_AMDXDNA_GET_BO_INFO, &info) != 0) {
        LOG_ERR("%s: GET_BO_INFO(heap handle %u) failed: %s\n", __func__,
                create.handle, strerror(errno));
        drm_gem_close gem = {};
        gem.handle = create.handle;
        ioctl(device->fd, DRM_IOCTL_GEM_CLOSE, &gem);
        return false;
    }

    void * map = mmap(nullptr, g_xdna_dev_heap_bytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                      device->fd, (off_t) info.map_offset);
    if (map == MAP_FAILED) {
        LOG_ERR("%s: mmap(heap, %llu bytes) failed: %s\n", __func__,
                (unsigned long long) g_xdna_dev_heap_bytes, strerror(errno));
        drm_gem_close gem = {};
        gem.handle = create.handle;
        ioctl(device->fd, DRM_IOCTL_GEM_CLOSE, &gem);
        return false;
    }

    device->dev_heap_handle = create.handle;
    device->dev_heap_bytes  = g_xdna_dev_heap_bytes;
    device->dev_heap_map    = map;
    return true;
}

static void xdna_release_heap_bo(common_xdna_device * device) {
    if (device->dev_heap_map) {
        munmap(device->dev_heap_map, device->dev_heap_bytes);
        device->dev_heap_map = nullptr;
    }
    if (device->dev_heap_handle != AMDXDNA_INVALID_BO_HANDLE &&
        device->fd >= 0) {
        drm_gem_close gem = {};
        gem.handle = device->dev_heap_handle;
        if (ioctl(device->fd, DRM_IOCTL_GEM_CLOSE, &gem) != 0) {
            LOG_WRN("%s: GEM_CLOSE(heap %u) failed: %s\n", __func__,
                    device->dev_heap_handle, strerror(errno));
        }
        device->dev_heap_handle = AMDXDNA_INVALID_BO_HANDLE;
    }
    device->dev_heap_bytes = 0;
}

common_xdna_device * common_xdna_device_open() {
    std::string path;
    const int fd = xdna_open_node(&path);
    if (fd < 0) {
        return nullptr;
    }
    common_xdna_device * device = new common_xdna_device();
    device->fd = fd;
    device->info.device_node = path;
    if (!xdna_query_identity(fd, &device->info)) {
        close(fd);
        delete device;
        return nullptr;
    }
    if (!xdna_alloc_heap_bo(device)) {
        // context create would fail without a heap; fail open loudly
        // rather than return a half-initialized device
        LOG_ERR("%s: device heap BO allocation failed; NPU unusable\n", __func__);
        close(fd);
        delete device;
        return nullptr;
    }
    LOG_INF("%s: opened %s (AIE %u.%u, firmware %u.%u.%u.%u, heap %llu MiB)\n",
            __func__, device->info.device_node.c_str(),
            device->info.aie_major, device->info.aie_minor,
            device->info.fw_major, device->info.fw_minor,
            device->info.fw_patch, device->info.fw_build,
            (unsigned long long) device->dev_heap_bytes / (1u << 20));
    return device;
}

void common_xdna_device_close(common_xdna_device * device) {
    if (!device) {
        return;
    }
    xdna_release_heap_bo(device);
    if (device->fd >= 0) {
        close(device->fd);
    }
    delete device;
}

const common_xdna_device_info * common_xdna_device_get_info(const common_xdna_device * device) {
    return device ? &device->info : nullptr;
}

bool common_xdna_context_create(common_xdna_device * device, common_xdna_context ** out) {
    if (!device || device->fd < 0 || !out) {
        return false;
    }
    // The driver does an unconditional copy_from_user on args.qos_p, so
    // the pointer must address a real amdxdna_qos_info. All-zero QoS gives
    // the driver's default priority / gops / fps, which is what the
    // runtime wants when no caller has expressed a preference.
    amdxdna_qos_info qos = {};
    // aie2_hwctx_col_list requires num_tiles = num_col * core_row_count
    // with num_col in [1, total_col]. AIE 1.1 supports 1-column contexts
    // backed by every core row in the column.
    const uint32_t num_tiles = std::max<uint32_t>(1, device->info.core_rows);
    amdxdna_drm_create_hwctx args = {};
    args.qos_p     = (uint64_t) (uintptr_t) &qos;
    args.num_tiles = num_tiles;
    if (ioctl(device->fd, DRM_IOCTL_AMDXDNA_CREATE_HWCTX, &args) != 0) {
        LOG_ERR("%s: CREATE_HWCTX(num_tiles=%u) failed: %s\n",
                __func__, num_tiles, strerror(errno));
        return false;
    }
    common_xdna_context * context = new common_xdna_context();
    context->device         = device;
    context->handle         = args.handle;
    context->syncobj_handle = args.syncobj_handle;
    *out = context;
    return true;
}

void common_xdna_context_destroy(common_xdna_context * context) {
    if (!context) {
        return;
    }
    if (context->device && context->device->fd >= 0 &&
        context->handle != AMDXDNA_INVALID_CTX_HANDLE) {
        amdxdna_drm_destroy_hwctx args = {};
        args.handle = context->handle;
        if (ioctl(context->device->fd, DRM_IOCTL_AMDXDNA_DESTROY_HWCTX, &args) != 0) {
            LOG_WRN("%s: DESTROY_HWCTX failed: %s\n", __func__, strerror(errno));
        }
    }
    delete context;
}

common_xdna_bo * common_xdna_bo_alloc(common_xdna_device * device, uint64_t bytes, common_xdna_bo_kind kind) {
    if (!device || device->fd < 0 || bytes == 0) {
        return nullptr;
    }
    // The device-heap BO is owned by the device, not callers; exposing it
    // through the public alloc path would invite double-GEM_CLOSE.
    if (kind == common_xdna_bo_kind::dev_heap) {
        LOG_ERR("%s: dev_heap BO is allocated internally by the runtime\n", __func__);
        return nullptr;
    }
    // DEV BOs are carved out of the device heap. Reject sizes that the
    // driver would reject anyway so the error reaches the caller as
    // ENOSPC-style validation, not as an opaque ioctl failure.
    if (kind == common_xdna_bo_kind::dev &&
        (device->dev_heap_handle == AMDXDNA_INVALID_BO_HANDLE || bytes > device->dev_heap_bytes)) {
        LOG_ERR("%s: DEV BO %llu bytes exceeds heap %llu bytes\n", __func__,
                (unsigned long long) bytes, (unsigned long long) device->dev_heap_bytes);
        return nullptr;
    }
    amdxdna_drm_create_bo create = {};
    create.size = bytes;
    create.type = (uint32_t) kind;
    if (ioctl(device->fd, DRM_IOCTL_AMDXDNA_CREATE_BO, &create) != 0) {
        LOG_ERR("%s: CREATE_BO(%llu bytes, kind %u) failed: %s\n", __func__,
                (unsigned long long) bytes, (unsigned) kind, strerror(errno));
        return nullptr;
    }

    amdxdna_drm_get_bo_info info = {};
    info.handle = create.handle;
    if (ioctl(device->fd, DRM_IOCTL_AMDXDNA_GET_BO_INFO, &info) != 0) {
        LOG_ERR("%s: GET_BO_INFO(handle %u) failed: %s\n", __func__, create.handle, strerror(errno));
        drm_gem_close gem = {};
        gem.handle = create.handle;
        ioctl(device->fd, DRM_IOCTL_GEM_CLOSE, &gem);
        return nullptr;
    }

    common_xdna_bo * bo = new common_xdna_bo();
    bo->device     = device;
    bo->handle     = create.handle;
    bo->bytes      = bytes;
    bo->vaddr      = info.vaddr;
    bo->map_offset = info.map_offset;
    bo->xdna_addr  = info.xdna_addr;
    return bo;
}

void common_xdna_bo_free(common_xdna_bo * bo) {
    if (!bo) {
        return;
    }
    if (bo->device && bo->device->fd >= 0 && bo->handle != AMDXDNA_INVALID_BO_HANDLE) {
        // amdxdna has no DESTROY_BO; BOs are GEM objects released via
        // the generic drm close ioctl
        drm_gem_close gem = {};
        gem.handle = bo->handle;
        if (ioctl(bo->device->fd, DRM_IOCTL_GEM_CLOSE, &gem) != 0) {
            LOG_WRN("%s: GEM_CLOSE(handle %u) failed: %s\n", __func__, bo->handle, strerror(errno));
        }
    }
    if (bo->map_owned && bo->map) {
        munmap(bo->map, bo->bytes);
    }
    delete bo;
}

void * common_xdna_bo_map(common_xdna_bo * bo) {
    if (!bo) {
        return nullptr;
    }
    if (bo->map) {
        return bo->map;
    }
    // vaddr is the sentinel AMDXDNA_INVALID_ADDR (~0UL) when the driver
    // has no userspace mapping for this BO (the common case for SHMEM and
    // for DEV BOs that were never DMA-pinned). Treating it as a valid
    // pointer would hand callers an unmappable address; fall through to
    // mmap() of map_offset instead.
    if (bo->vaddr != 0 && bo->vaddr != AMDXDNA_INVALID_ADDR) {
        bo->map = (void *) (uintptr_t) bo->vaddr;
        bo->map_owned = false;
        return bo->map;
    }
    if (bo->device && bo->device->fd >= 0) {
        void * ptr = mmap(nullptr, bo->bytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                          bo->device->fd, (off_t) bo->map_offset);
        if (ptr != MAP_FAILED) {
            bo->map = ptr;
            bo->map_owned = true;
            return bo->map;
        }
        LOG_ERR("%s: mmap(handle %u, %llu bytes) failed: %s\n", __func__,
                bo->handle, (unsigned long long) bo->bytes, strerror(errno));
    }
    return nullptr;
}

uint64_t common_xdna_bo_device_addr(const common_xdna_bo * bo) {
    return bo ? bo->xdna_addr : 0;
}

uint64_t common_xdna_bo_size(const common_xdna_bo * bo) {
    return bo ? bo->bytes : 0;
}

bool common_xdna_bo_sync(const common_xdna_bo * bo, bool from_device) {
    if (!bo || !bo->device || bo->device->fd < 0) {
        return false;
    }
    amdxdna_drm_sync_bo args = {};
    args.handle    = bo->handle;
    args.direction = from_device ? SYNC_DIRECT_FROM_DEVICE : SYNC_DIRECT_TO_DEVICE;
    args.offset    = 0;
    args.size      = bo->bytes;
    if (ioctl(bo->device->fd, DRM_IOCTL_AMDXDNA_SYNC_BO, &args) != 0) {
        LOG_ERR("%s: SYNC_BO(handle %u, %s) failed: %s\n", __func__, bo->handle,
                from_device ? "from-device" : "to-device", strerror(errno));
        return false;
    }
    return true;
}

bool common_xdna_xclbin_inspect(const std::string & path, common_xdna_xclbin_info * out) {
    if (!out) {
        return false;
    }
    *out = {};

    std::vector<uint8_t> file;
    if (!xdna_read_file(path, &file)) {
        LOG_ERR("%s: cannot read '%s'\n", __func__, path.c_str());
        return false;
    }
    if (file.size() < sizeof(xdna_axlf)) {
        LOG_ERR("%s: '%s' is smaller than the axlf prefix\n", __func__, path.c_str());
        return false;
    }

    xdna_axlf header = {};
    memcpy(&header, file.data(), sizeof(header));
    if (memcmp(header.magic, "xclbin2", 8) != 0) {
        LOG_ERR("%s: '%s' is not an xclbin2 container\n", __func__, path.c_str());
        return false;
    }
    if (header.length != file.size()) {
        LOG_ERR("%s: '%s' header length %llu != file size %zu\n", __func__, path.c_str(),
                (unsigned long long) header.length, file.size());
        return false;
    }

    const size_t table_off = sizeof(xdna_axlf);
    const size_t table_bytes = (size_t) header.num_sections * sizeof(xdna_xclbin_section);
    if (header.num_sections == 0 || header.num_sections > 128 ||
        table_off + table_bytes > file.size()) {
        LOG_ERR("%s: '%s' section table out of bounds (%u sections)\n", __func__,
                path.c_str(), header.num_sections);
        return false;
    }

    char uuid_buf[33];
    for (int i = 0; i < 16; i++) {
        snprintf(uuid_buf + 2 * i, 3, "%02x", header.xclbin_uuid[i]);
    }
    out->uuid = uuid_buf;
    out->section_count = header.num_sections;

    for (uint32_t i = 0; i < header.num_sections; i++) {
        xdna_xclbin_section sec = {};
        memcpy(&sec, file.data() + table_off + (size_t) i * sizeof(xdna_xclbin_section), sizeof(sec));
        if (sec.size == 0 || sec.offset < table_off + table_bytes ||
            sec.offset + sec.size > file.size()) {
            LOG_ERR("%s: '%s' section %u out of bounds (offset 0x%llx size 0x%llx)\n", __func__,
                    path.c_str(), i, (unsigned long long) sec.offset, (unsigned long long) sec.size);
            return false;
        }
        switch (sec.kind) {
            case XDNA_XCLBIN_SEC_MEM_TOPOLOGY:
                xdna_parse_mem_topology(file, sec, &out->mems);
                break;
            case XDNA_XCLBIN_SEC_IP_LAYOUT:
                xdna_parse_ip_layout(file, sec, &out->kernels);
                break;
            case XDNA_XCLBIN_SEC_AIE_PARTITION:
                out->has_aie_partition = true;
                out->aie_partition_size = sec.size;
                break;
            default:
                break;
        }
    }

    return true;
}
