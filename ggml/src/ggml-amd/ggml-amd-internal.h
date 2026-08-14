#ifndef GGML_AMD_INTERNAL_H
#define GGML_AMD_INTERNAL_H

#include "ggml-amd-types.h"
#include "ggml-amd-provider.h"
#include "ggml-backend-impl.h"
#include "ggml.h"

#include <vector>
#include <string>
#include <mutex>
#include <memory>

#ifdef __cplusplus
extern "C" {
#endif

struct ggml_amd_allocation {
    int dma_buf_fd;
    size_t size;
    size_t alignment;
    void * cpu_mapping;
    enum ggml_amd_memory_domain domain;
    enum ggml_amd_coherency coherency;
    enum ggml_amd_fd_ownership fd_ownership;
    struct ggml_amd_fence last_writer;
    uint64_t generation;
    int ref_count;
    std::vector<struct ggml_amd_import *> imports;
    std::mutex mutex;
};

struct ggml_amd_import {
    struct ggml_amd_allocation * allocation;
    struct ggml_amd_provider * provider;
    void * native_handle;
    int ref_count;
};

struct ggml_amd_region {
    int node_start;
    int node_end;
    struct ggml_amd_provider * provider;
    struct ggml_tensor ** inputs;
    int n_inputs;
    struct ggml_tensor ** outputs;
    int n_outputs;
    struct ggml_tensor ** state_tensors;
    int n_state_tensors;
    enum ggml_amd_phase phase;
};

struct ggml_amd_device_context {
    int device_index;
    std::string name;
    std::string description;
    enum ggml_amd_device_type type;
    int pci_domain;
    int pci_bus;
    int pci_device;
    int pci_function;
    std::string vendor_id;
    std::string device_id;
    std::string hsauuid;
    struct ggml_amd_provider * provider;
};

struct ggml_amd_reg_context {
    std::vector<ggml_backend_dev_t> devices;
    std::vector<std::unique_ptr<ggml_amd_device_context>> device_contexts;
    std::vector<std::unique_ptr<ggml_amd_provider>> providers;
    enum ggml_amd_scheduler_mode scheduler_mode;
    std::string cache_dir;
    std::string metrics_path;
    bool initialized;
};

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_INTERNAL_H
