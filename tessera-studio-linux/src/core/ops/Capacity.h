#pragma once
#include <string>
#include <vector>
#include <optional>
#include <cstdint>

namespace tessera {
struct GpuInfo {
    std::string name;
    std::string api; // vulkan, opencl, cuda, rocm
    uint64_t vram_mb = 0; // 0 = shared
    std::string bus; // pcie, tb4, usb4
    bool is_egpu = false;
};
struct NpuInfo {
    std::string name;
    std::string driver; // openvino-npu, xDNA, etc
    int tops = 0;
    bool present = false;
};
struct LocalCapacity {
    std::string cpu_model;
    int cpu_cores = 0;
    int cpu_threads = 0;
    std::string cpu_isa; // e.g. "AVX-512 + VNni"
    uint64_t ram_total_mb = 0;
    uint64_t ram_avail_mb = 0;
    uint64_t swap_total_mb = 0;
    GpuInfo igpu;
    std::optional<GpuInfo> dgpu;
    std::optional<GpuInfo> egpu;
    std::optional<NpuInfo> npu;
    double bandwidth_gbs = 0; // est ~60 for T2
    std::string summary() const;
};

LocalCapacity gather_capacity();
double estimate_tokens_per_sec(const LocalCapacity &cap, uint64_t model_bytes);
struct ModelFit {
    std::string id; // e.g. "gemma-4-12b Q4_0"
    uint64_t size_mb;
    std::string quant;
    bool fits_ram;
    double est_tok_s;
    std::string badge; // green/amber/red
};
std::vector<ModelFit> community_fits(const LocalCapacity &cap);
}
