#include "ggml-amd-internal.h"
#include "ggml.h"

#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <vector>
#include <string>
#include <cctype>

extern void ggml_amd_fence_release(struct ggml_amd_fence * fence);
extern int ggml_amd_fence_wait(struct ggml_amd_fence * fence, int timeout_ms);

#ifdef __linux__
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>
#endif

namespace {

std::vector<std::string> ggml_amd_dma_heap_paths(void) {
#ifdef __linux__
    const char * env_paths = std::getenv("GGML_AMD_DMA_HEAP_PATH");
    if (env_paths && env_paths[0]) {
        std::vector<std::string> paths;
        std::string current;
        const char * cursor = env_paths;
        while (*cursor) {
            if (std::isspace(static_cast<unsigned char>(*cursor)) || *cursor == ':' || *cursor == ',') {
                if (!current.empty()) {
                    paths.push_back(current);
                    current.clear();
                }
                ++cursor;
                continue;
            }
            current.push_back(*cursor);
            ++cursor;
        }

        if (!current.empty()) {
            paths.push_back(current);
        }

        if (!paths.empty()) {
            return paths;
        }
    }

    return {"/dev/dma_heap/system"};
#else
    return {};
#endif
}

}

static int ggml_amd_dma_heap_alloc(size_t size, size_t alignment) {
#ifdef __linux__
    (void)alignment;
    const auto heap_paths = ggml_amd_dma_heap_paths();
    for (const auto & heap_path : heap_paths) {
        const int fd = open(heap_path.c_str(), O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            continue;
        }

        struct dma_heap_allocation_data alloc_data = {};
        alloc_data.len = size;
        alloc_data.fd = 0;
        alloc_data.fd_flags = O_RDWR | O_CLOEXEC;
        alloc_data.heap_flags = 0;

        const int status = ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &alloc_data);
        close(fd);
        if (status == 0) {
            return alloc_data.fd;
        }
    }

    return -1;
#else
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
    alloc->external_handle_kind = GGML_AMD_EXTERNAL_HANDLE_KIND_NONE;
    alloc->producer_context = nullptr;
    alloc->producer_cleanup = nullptr;
    alloc->ref_count = 1;
    memset(&alloc->last_writer, 0, sizeof(alloc->last_writer));
    alloc->last_writer.kind = GGML_AMD_FENCE_NONE;
    alloc->last_writer.sync_file_fd = -1;

    switch (domain) {
        case GGML_AMD_DOMAIN_SHARED_SYSTEM:
            alloc->dma_buf_fd = ggml_amd_dma_heap_alloc(size, alignment);
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_OWNED;
            alloc->external_handle_kind = GGML_AMD_EXTERNAL_HANDLE_KIND_UNKNOWN;
            break;
        case GGML_AMD_DOMAIN_GPU_LOCAL_EXPORTABLE:
            alloc->dma_buf_fd = -1;
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_OWNED;
            alloc->external_handle_kind = GGML_AMD_EXTERNAL_HANDLE_KIND_NONE;
            break;
        case GGML_AMD_DOMAIN_PROVIDER_PRIVATE:
            alloc->dma_buf_fd = -1;
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_BORROWED;
            alloc->external_handle_kind = GGML_AMD_EXTERNAL_HANDLE_KIND_NONE;
            break;
        case GGML_AMD_DOMAIN_IMPORTED_EXTERNAL:
            alloc->dma_buf_fd = -1;
            alloc->fd_ownership = GGML_AMD_FD_OWNERSHIP_BORROWED;
            alloc->external_handle_kind = GGML_AMD_EXTERNAL_HANDLE_KIND_UNKNOWN;
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

    void * cpu_mapping = nullptr;
    int dma_buf_fd = -1;
    enum ggml_amd_fd_ownership fd_ownership = GGML_AMD_FD_OWNERSHIP_BORROWED;
    enum ggml_amd_coherency coherency = GGML_AMD_COHERENCY_CPU_ONLY;
    struct ggml_amd_fence last_writer = {};
    void (*producer_cleanup)(void * context) = nullptr;
    void * producer_context = nullptr;

    {
        std::lock_guard<std::mutex> lock(alloc->mutex);
        alloc->ref_count--;

        if (alloc->ref_count > 0) {
            return;
        }

        cpu_mapping = alloc->cpu_mapping;
        alloc->cpu_mapping = nullptr;
        dma_buf_fd = alloc->dma_buf_fd;
        alloc->dma_buf_fd = -1;
        fd_ownership = alloc->fd_ownership;
        coherency = alloc->coherency;
        last_writer = alloc->last_writer;
        producer_cleanup = alloc->producer_cleanup;
        producer_context = alloc->producer_context;
        memset(&alloc->last_writer, 0, sizeof(alloc->last_writer));
        alloc->last_writer.kind = GGML_AMD_FENCE_NONE;
        alloc->last_writer.sync_file_fd = -1;
        alloc->producer_cleanup = nullptr;
        alloc->producer_context = nullptr;
    }

    if (cpu_mapping) {
        if (coherency == GGML_AMD_COHERENCY_SHARED && dma_buf_fd >= 0) {
            ggml_amd_sync_fd(dma_buf_fd, 0);
        }
        ggml_amd_munmap_fd(cpu_mapping, alloc->size);
    }

    ggml_amd_fence_release(&last_writer);
    if (producer_cleanup) {
        producer_cleanup(producer_context);
    }

#ifdef __linux__
    if (dma_buf_fd >= 0 && fd_ownership != GGML_AMD_FD_OWNERSHIP_BORROWED) {
        close(dma_buf_fd);
    }
#else
    (void)dma_buf_fd;
    (void)fd_ownership;
#endif
    delete alloc;
}

void ggml_amd_allocation_retain(struct ggml_amd_allocation * alloc) {
    if (!alloc) {
        return;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);
    alloc->ref_count++;
}

void ggml_amd_allocation_set_cleanup(
    struct ggml_amd_allocation * alloc,
    void * producer_context,
    void (*producer_cleanup)(void * context)) {
    if (!alloc) {
        return;
    }

    std::lock_guard<std::mutex> lock(alloc->mutex);
    alloc->producer_context = producer_context;
    alloc->producer_cleanup = producer_cleanup;
}

struct ggml_amd_allocation * ggml_amd_allocation_wrap_external_fd(
    int fd,
    size_t size,
    size_t alignment,
    enum ggml_amd_external_handle_kind external_handle_kind,
    enum ggml_amd_fd_ownership fd_ownership,
    enum ggml_amd_coherency coherency) {
    if (fd < 0) {
        return nullptr;
    }

    auto alloc = new ggml_amd_allocation();
    alloc->size = size;
    alloc->alignment = alignment;
    alloc->domain = GGML_AMD_DOMAIN_IMPORTED_EXTERNAL;
    alloc->coherency = coherency;
    alloc->external_handle_kind = external_handle_kind;
    alloc->producer_context = nullptr;
    alloc->producer_cleanup = nullptr;
    alloc->cpu_mapping = nullptr;
    alloc->generation = 0;
    alloc->ref_count = 1;
    memset(&alloc->last_writer, 0, sizeof(alloc->last_writer));
    alloc->last_writer.kind = GGML_AMD_FENCE_NONE;
    alloc->last_writer.sync_file_fd = -1;
    alloc->dma_buf_fd = fd;
    alloc->fd_ownership = fd_ownership;
    return alloc;
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

    if (alloc->last_writer.kind != GGML_AMD_FENCE_NONE && alloc->last_writer.kind != GGML_AMD_FENCE_HOST) {
        // Cache synchronization does not establish producer completion.
        if (ggml_amd_fence_wait(&alloc->last_writer, -1) != 0) {
            return nullptr;
        }
        ggml_amd_fence_release(&alloc->last_writer);
    }

    if (alloc->coherency == GGML_AMD_COHERENCY_SHARED && ggml_amd_sync_fd(alloc->dma_buf_fd, 1) != 0) {
        return nullptr;
    }

    void * ptr = ggml_amd_mmap_fd(alloc->dma_buf_fd, alloc->size);
    if (!ptr) {
        if (alloc->coherency == GGML_AMD_COHERENCY_SHARED) {
            ggml_amd_sync_fd(alloc->dma_buf_fd, 0);
        }
        return nullptr;
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

    if (alloc->coherency == GGML_AMD_COHERENCY_SHARED) {
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
