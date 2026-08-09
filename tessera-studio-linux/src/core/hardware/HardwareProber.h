#pragma once
// HardwareProber — probes vkEnumeratePhysicalDevices + ov::Core + sysfs -> {tile,dtype,vram,bw,subgroup,hasWMMA}
// 200ms at first launch, no glslc needed, shares TILE constants with quantize_v3.py
#include <string>
#include <vector>
#include <cstdint>

namespace tessera::hardware {

enum class DType { F32, F16, BF16, INT8, INT4 };

struct DeviceCaps {
    std::string name;          // "Radeon VII" / "Arc A770"
    std::string id;            // "vulkan:0" / "openvino:GPU.0" / "cpu"
    int tile = 256;            // 256 legacy vector-packed, 512 WMMA, 640 Apple
    DType dtype = DType::F32;  // native fastest: f16 2x, bf16 on Xe-HPG, f32 fallback
    uint64_t vram_bytes = 0;
    uint64_t bw_mbps = 0;
    uint32_t subgroup = 32;
    bool hasWMMA = false;
    bool hasCoopMat = false;
    uint32_t shared_kb = 64;
};

class HardwareProber {
public:
    // Probe all: Vulkan physical devices, OpenVINO GPU/NPU/CPU, sysfs fallback
    static std::vector<DeviceCaps> probe();

    // Map caps -> optimal tile/dtype (literature-grounded, not GA)
    static DeviceCaps optimal_for(const DeviceCaps &raw);

    // Convenience: pick best device for prefill vs decode
    static DeviceCaps pick_prefill(const std::vector<DeviceCaps> &all);
    static DeviceCaps pick_decode(const std::vector<DeviceCaps> &all);
};

} // namespace tessera::hardware
