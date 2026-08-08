#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace ov {
namespace frontend {
namespace ggml {

// Per-host regime router cache + auth-gated profiling.
// Fingerprint is a hash of CPU model + cache sizes + AVX level + GPU EU/SLM
// so a policy calibrated on M1 does not pollute an icelake-server host.
std::string ov_regime_host_fingerprint();

// Auth gate for profiling/calibration: only when TESSERA_AUTH_TOKEN
// (or GGML_OPENVINO_AUTH_TOKEN) matches the expected value is per-host
// calibration allowed to run or be loaded. Prevents untrusted profiling
// from tainting the router. Kept as opt-in for fleet/prod.
bool ov_auth_profiling_enabled();

// Auto gate: per-host calibration runs automatically on first miss
// without a token (dev/laptop default). Env GGML_OPENVINO_AUTO_PROFILE=0
// disables it; GGML_OPENVINO_REQUIRE_AUTH=1 makes auto require auth.
bool ov_auto_profiling_enabled();

// Heterogeneous device for the router (true heterogeneous = bench all
// devices together). Scalar = C fallback, CPU = AVX-512, GPU = Level Zero
// DPAS/XMX, NPU = Intel NPU.
enum class OvRegimeDevice : uint8_t { Scalar = 0, CPU = 1, GPU = 2, NPU = 3 };

// Try to load a host-specific policy file. Returns true and sets
// out_path if a cached file for this fingerprint exists in cache_dir
// (or XDG_CACHE_HOME / ~/.cache/tessera). The caller can then
// dlopen or parse the file to override kRegimePolicy.
bool ov_regime_host_try_load(std::string & out_path);

// Heterogeneous lookup: returns the device that won the per-host bench
// for this (family, shape_bucket). Falls back to CPU accel vs scalar
// when no host cache exists.
OvRegimeDevice ov_regime_host_lookup_device(int family, int shape_bucket, const char * kind); // kind="outlier" or "meta"

// Comprehensive per-op hetero entry: which device each TILE640 op
// should run on for this (family, shape). Bench covers all 5 ops
// together so you can see exactly outlier/meta/dequant/act_scale/matmul.
struct OvHeteroComprehensiveEntry {
    int family;
    int bucket;
    OvRegimeDevice dev_outlier;
    OvRegimeDevice dev_meta;
    OvRegimeDevice dev_dequant;
    OvRegimeDevice dev_act_scale;
    OvRegimeDevice dev_matmul;
};
bool ov_hetero_try_load_comprehensive(std::vector<OvHeteroComprehensiveEntry> & out);
void ov_hetero_print_table(); // prints family×bucket → device per op

// Ensure a host calibration file exists: if missing and auth is
// enabled, run a lightweight bench (median of ts_* accel vs scalar)
// and emit a .bin cache file. Returns true if a file now exists.
bool ov_regime_host_ensure_calibrated();

} // ggml
} // frontend
} // ov
