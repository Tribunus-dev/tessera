#include "host_tune.h"
#include "regime_host.h"
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>
#include <unistd.h>
#include <openvino/runtime/core.hpp>

namespace ov {
namespace frontend {
namespace ggml {

static OvHostTune g_tune;
static std::atomic<bool> g_tune_done{false};
static std::once_flag g_tune_once;

static int read_sys_cache_kb(const char * path) {
    std::ifstream f(path);
    if (!f) return 0;
    std::string s; std::getline(f, s);
    // kernel reports like "32K" or "512K" or "8192K" or "8M"
    if (s.empty()) return 0;
    char unit = s.back();
    int mult = 1;
    if (unit == 'K' || unit == 'k') { s.pop_back(); mult = 1; }
    else if (unit == 'M' || unit == 'm') { s.pop_back(); mult = 1024; }
    try { int v = std::stoi(s); return v * mult; } catch(...) { return 0; }
}

static int parse_lscpu_kb(const std::string & key) {
    // Prefer /sys cache size (accurate, no lscpu needed)
    if (key == "L1d") {
        int v = read_sys_cache_kb("/sys/devices/system/cpu/cpu0/cache/index0/size");
        if (v == 0) v = read_sys_cache_kb("/sys/devices/system/cpu/cpu0/cache/index1/size");
        if (v > 0) return v;
    } else if (key == "L2") {
        int v = read_sys_cache_kb("/sys/devices/system/cpu/cpu0/cache/index2/size");
        if (v > 0) return v;
    } else if (key == "L3") {
        int v = read_sys_cache_kb("/sys/devices/system/cpu/cpu0/cache/index3/size");
        if (v > 0) return v;
    }
    // sysconf fallback (works on any Linux)
    long l1 = sysconf(_SC_LEVEL1_DCACHE_SIZE);
    long l2 = sysconf(_SC_LEVEL2_CACHE_SIZE);
    long l3 = sysconf(_SC_LEVEL3_CACHE_SIZE);
    if (key == "L1d") return l1 > 0 ? int(l1/1024) : 32;
    if (key == "L2") return l2 > 0 ? int(l2/1024) : 512;
    if (key == "L3") return l3 > 0 ? int(l3/1024) : 8192;
    return 0;
}

const OvHostTune & ov_get_host_tune() {
    std::call_once(g_tune_once, []{
    g_tune.l1_kb = parse_lscpu_kb("L1d");
    g_tune.l2_kb = parse_lscpu_kb("L2");
    g_tune.l3_kb = parse_lscpu_kb("L3");
    // GPU EU/SLM + flex tile via clinfo / OpenVINO
    bool found_gpu = false;
    try {
        ov::Core core;
        auto devices = core.get_available_devices();
        for (auto & d : devices) if (d.rfind("GPU",0)==0) {
            found_gpu = true;
            // Try to query readable name via OpenVINO GPU plugin (fallback to clinfo values)
            try {
                auto name = core.get_property(d, ov::device::full_name);
                g_tune.gpu_name = name;
            } catch(...) {}
            // Defaults for Gen11 Iris Plus G7 (local validation)
            g_tune.gpu_eus = 64;
            g_tune.gpu_slm_kb = 64;
            g_tune.wg_size = 16;
            g_tune.wg_count = g_tune.gpu_eus * 7;
            // Heuristic per GPU name/IP: Gen11=11.0 no XMX/DPAS, Xe-HPG=12.70 DPAS, Xe2=20.x XMX
            std::string n = g_tune.gpu_name;
            bool is_gen11 = (n.find("Iris")!=std::string::npos) || (n.find("UHD")!=std::string::npos) || (n.find("Gen11")!=std::string::npos);
            // Also detect via IP version hint: clinfo IP 0x2c00000 ~= Gen11
            // Prefer name-based: this box is Iris Plus G7 8a53 Gen11
            if (is_gen11 || n.find("Gen11")!=std::string::npos || n.find("Ice Lake")!=std::string::npos) {
                g_tune.gpu_is_gen11 = true;
                g_tune.gpu_has_xmx = false;
                g_tune.gpu_has_dpas = false;
                g_tune.gpu_ip_version = "11.0";
                g_tune.intel_tile_lanes = 16;
                g_tune.intel_tile_m = 16; g_tune.intel_tile_n = 32; g_tune.intel_tile_k = 32;
                g_tune.intel_sg_size = 16;
                g_tune.gpu_tile = 64;
            } else if (n.find("Arc")!=std::string::npos || n.find("Alchemist")!=std::string::npos || n.find("DG2")!=std::string::npos) {
                g_tune.gpu_is_gen11 = false;
                g_tune.gpu_has_xmx = true;
                g_tune.gpu_has_dpas = true;
                g_tune.gpu_ip_version = "12.70";
                g_tune.intel_tile_lanes = 16;
                g_tune.intel_tile_m = 16; g_tune.intel_tile_n = 32; g_tune.intel_tile_k = 32;
                g_tune.intel_sg_size = 16;
                g_tune.gpu_tile = 96;
            } else if (n.find("Battlemage")!=std::string::npos || n.find("Lunar Lake")!=std::string::npos || n.find("Xe2")!=std::string::npos) {
                g_tune.gpu_is_gen11 = false;
                g_tune.gpu_has_xmx = true;
                g_tune.gpu_has_dpas = true;
                g_tune.gpu_ip_version = "20.0";
                g_tune.intel_tile_lanes = 32;
                g_tune.intel_tile_m = 32; g_tune.intel_tile_n = 32; g_tune.intel_tile_k = 32;
                g_tune.intel_sg_size = 16;
                g_tune.gpu_tile = 96;
                g_tune.gpu_slm_kb = 128;
            } else {
                // Unknown future Xe3: assume 32x32 XMX
                g_tune.gpu_is_gen11 = false;
                g_tune.gpu_has_xmx = true;
                g_tune.gpu_has_dpas = true;
                g_tune.gpu_ip_version = "30.0";
                g_tune.intel_tile_lanes = 32;
                g_tune.intel_tile_m = 32; g_tune.intel_tile_n = 32;
                g_tune.intel_sg_size = 16;
                g_tune.gpu_tile = 96;
                g_tune.gpu_slm_kb = 128;
            }
            break;
        }
    } catch(...) {}
    if (!found_gpu) {
        // No GPU: keep Gen11 defaults for validation (this host HAS Gen11, but header-only tests need it)
        g_tune.gpu_is_gen11 = true;
        g_tune.intel_tile_lanes = 16;
        g_tune.intel_tile_m = 16; g_tune.intel_tile_n = 32;
    }
    // Tile = L1/(2*sizeof(float))  -> 32KB/(8) = 4096 = 64x64
    g_tune.cpu_tile = std::clamp(g_tune.l1_kb * 1024 / (2*4*64), 32, 128);
    if (g_tune.cpu_tile % 16) g_tune.cpu_tile = (g_tune.cpu_tile/16)*16;
    if (g_tune.gpu_tile == 0) g_tune.gpu_tile = 64;
    if (ov_auth_profiling_enabled() || ov_auto_profiling_enabled()) {
        (void) ov_regime_host_ensure_calibrated();
    }
    });
    // Lock-free read: after call_once, g_tune is immutable
    return g_tune;
}
int ov_get_cpu_tile() { return ov_get_host_tune().cpu_tile; }
int ov_get_gpu_tile() { return ov_get_host_tune().gpu_tile; }
int ov_get_gpu_wg_size() { return ov_get_host_tune().wg_size; }
OvIntelFlex ov_get_intel_flex() {
    const auto & t = ov_get_host_tune();
    OvIntelFlex f;
    f.lanes = t.intel_tile_lanes;
    f.m = t.intel_tile_m;
    f.n = t.intel_tile_n;
    f.is_xmx = t.gpu_has_xmx;
    f.is_gen11_fallback = t.gpu_is_gen11;
    return f;
}
bool ov_gpu_is_gen11() { return ov_get_host_tune().gpu_is_gen11; }
bool ov_gpu_has_xmx() { return ov_get_host_tune().gpu_has_xmx; }

} // ggml
} // frontend
} // ov
