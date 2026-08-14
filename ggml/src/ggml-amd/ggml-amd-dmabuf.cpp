#include "ggml-amd-internal.h"
#include "ggml.h"

#include <cstring>
#include <cerrno>

#ifdef __linux__
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>
#include <drm/drm.h>
#endif

static int ggml_amd_dma_heap_alloc(size_t size, size_t alignment) {
#ifdef __linux__
    int fd = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }

    struct dma_heap_allocation_data alloc_data = {};
    alloc_data.len = size;
    alloc_data.fd = 0;
    alloc_data.fd_flags = O_RDWR | O_CLOEXEC;
    alloc_data.heap_flags = 0;

    if (ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &alloc_data) < 0) {
        close(fd);
        return -1;
    }

    close(fd);
    return alloc_data.fd;
#else
    (void)size;
    (void)alignment;
    return -1;
#endif
}

static int ggml_amd_gem_alloc_export(int drm_fd, size_t size, size_t alignment) {
#ifdef __linux__
    struct drm_gem_close close_data = {};
    (void)close_data;

    struct drm_prime_handle prime = {};
    prime.handle = 0;
    prime.flags = DRM_CLOEXEC | DRM_RDWR;
    prime.fd = -1;

    if (ioctl(drm_fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime) < 0) {
        return -1;
    }

    return prime.fd;
#else
    (void)drm_fd;
    (void)size;
    (void)alignment;
    return -1;
#endif
}

static void * ggml_amd_mmap_fd(int fd, size_t size) {
#ifdef __linux__
    void * ptr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        return nullptr;
    }
    return ptr;
#else
    (void)fd;
    (void)size;
    return nullptr;
#endif
}

static void ggml_amd_munmap_fd(void * ptr, size_t size) {
#ifdef __linux__
    if (ptr && ptr != MAP_FAILED) {
        munmap(ptr, size);
    }
#else
    (void)ptr;
    (void)size;
#endif
}

static int ggml_amd_sync_fd(int fd, int sync_start) {
#ifdef __linux__
    struct dma_buf_sync sync_data = {};
    sync_data.flags = sync_start ? DMA_BUF_SYNC_START : DMA_BUF_SYNC_END;
    sync_data.flags |= DMA_BUF_SYNC_RW;

    if (ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync_data) < 0) {
        return -1;
    }
    return 0;
#else
    (void)fd;
    (void)sync_start;
    return -1;
#endif
}

struct ggml_amd_allocation * ggml_amd_allocation_create(
    enum ggml_amd_memory_domain domain,
    size_t size,
    size_t alignment,
    enum ggml_amd_coherency coherency) {

    auto alloc = new ggml_amd_allocation();
    alloc->size = size;
    alloc->alignment = alignment;
    alloc->domain = domain;
    alloc->coherency = coherency;
    alloc->cpu_mapping = nullptr;
    alloc->generation = 0;
    alloc->ref_count = 1;
    alloc->last_writer.kind = GGML_AMD_FENCE_NONE;
    alloc->last_writer.sequence = 0;

    switch (domain) {
        case GGML_AMD_DOMAIN_SHARED_SYSTEM:
            alloc->dma_buf_fd = ggml_amd_dma_heap_alloc(size, alignment);
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_OWNED;
            break;
        case GGML_AMD_DOMAIN_GPU_LOCAL_EXPORTABLE:
            alloc->dma_buf_fd = -1;
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_OWNED;
            break;
        case GGML_AMD_DOMAIN_PROVIDER_PRIVATE:
            alloc->dma_buf_fd = -1;
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_BORROWED;
            break;
        case GGML_AMD_DOMAIN_IMPORTED_EXTERNAL:
            alloc->dma_buf_fd = -1;
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_BORROWED;
            break;
    }

    if (alloc->dma_buf_fd < 0 && domain == GGML_AMD_DOMAIN_SHARED_SYSTEM) {
        delete alloc;
        return nullptr;
    }

    return alloc;
}

void ggml_amd_allocation_release(struct ggml_amd_allocation * alloc) {
    if (!alloc) {
        return;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);
    alloc->ref_count--;

    if (alloc->ref_count > 0) {
        return;
    }

    if (alloc->cpu_mapping) {
        ggml_amd_munmap_fd(alloc->cpu_mapping, alloc->size);
    }

    if (alloc->dma_buf_fd >= 0 && alloc->fd_ownership != GGML_AMD_FD_OWNERSHIP_BORROWED) {
        close(alloc->dma_buf_fd);
    }

    delete alloc;
}

void * ggml_amd_allocation_map_cpu(struct ggml_amd_allocation * alloc) {
    if (!alloc) {
        return nullptr;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);

    if (alloc->cpu_mapping) {
        return alloc->cpu_mapping;
    }

    if (alloc->dma_buf_fd < 0) {
        return nullptr;
    }

    if (alloc->coherency != GGML_AMD_COHERENCY_CPU_ONLY && alloc->coherency != GGML_AMD_COHERENCY_SHARED) {
        return nullptr;
    }

    void * ptr = ggml_amd_mmap_fd(alloc->dma_buf_fd, alloc->size);
    if (!ptr) {
        return nullptr;
    }

    if (alloc->last_writer.kind != GGML_AMD_FENCE_NONE && alloc->last_writer.kind != GGML_AMD_FENCE_HOST) {
        ggml_amd_sync_fd(alloc->dma_buf_fd, 1);
    }

    alloc->cpu_mapping = ptr;
    return ptr;
}

void ggml_amd_allocation_unmap_cpu(struct ggml_amd_allocation * alloc) {
    if (!alloc) {
        return;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);

    if (!alloc->cpu_mapping) {
        return;
    }

    if (alloc->coherency != GGML_AMD_COHERENCY_CPU_ONLY) {
        ggml_amd_sync_fd(alloc->dma_buf_fd, 0);
    }

    ggml_amd_munmap_fd(alloc->cpu_mapping, alloc->size);
    alloc->cpu_mapping = nullptr;
}

int ggml_amd_allocation_dup_fd(struct ggml_amd_allocation * alloc) {
#ifdef __linux__
    if (!alloc || alloc->dma_buf_fd < 0) {
        return -1;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);
    return dup(alloc->dma_buf_fd);
#else
    (void)alloc;
    return -1;
#endif
}
