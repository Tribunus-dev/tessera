#pragma once
#include <cstddef>
#include <string>
#include <vector>

namespace ov {
namespace frontend {
namespace ggml {

// Any-host cache/timing auto-tune for OpenVINO (CPU L1/L2/L3 + GPU EU/SLM)
// Called once at ov_graph_compute init. Uses lscpu / sysconf + clGetDeviceInfo
// + GGML_OPENVINO_PROFILING ov_raw_infer_total to pick tile/WG.
// Mirrors Apple regime-router but for host cache, not accel path.
// Flex: single T512 canonical across Intel gens; Gen11 gets scalar fallback
// while Xe-HPG/Xe2/Xe3 parametrize 16x32 vs 32x32 via this struct.
struct OvHostTune {
    int l1_kb = 32;      // per-core L1d
    int l2_kb = 512;     // per-core L2
    int l3_kb = 8192;    // shared L3
    int gpu_eus = 64;    // Gen11 Iris Plus G7
    int gpu_slm_kb = 64;
    int cpu_tile = 64;   // F32 64x64 = 16KB fits L1/2
    int gpu_tile = 64;
    int wg_size = 16;    // sub_group 16
    int wg_count = 64*7; // EU*threads
    // Intel flex tile (parametrized kernel)
    int intel_tile_lanes = 16; // 16=>16x32 (Xe-HPG/Gen11), 32=>32x32 (Xe2/Xe3)
    int intel_tile_m = 16;
    int intel_tile_n = 32;
    int intel_tile_k = 32;
    int intel_sg_size = 16; // subgroup 8/16/32 (Gen11 supports 8,16,32)
    std::string gpu_name = "Intel(R) Iris(R) Plus Graphics";
    std::string gpu_ip_version = "12.0"; // Gen11=11.0, Xe-HPG=12.70, Xe2=20.x
    bool gpu_is_gen11 = true;
    bool gpu_has_xmx = false;
    bool gpu_has_dpas = false;
};

struct OvIntelFlex {
    int lanes = 16;
    int m = 16;
    int n = 32;
    bool is_xmx = false;
    bool is_gen11_fallback = false;
};

const OvHostTune & ov_get_host_tune();
OvIntelFlex ov_get_intel_flex(); // flex view for current host
int ov_get_cpu_tile(); // 64 for 32KB L1, 128 for 64KB
int ov_get_gpu_tile();
int ov_get_gpu_wg_size();
bool ov_gpu_is_gen11();
bool ov_gpu_has_xmx();

} // ggml
} // frontend
} // ov
