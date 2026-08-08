// calibrate_regime_router_host
// Per-host calibration runner for Linux OpenVINO.
// Wraps calibrate_regime_router.cpp but:
//  - fingerprints the host via ov_regime_host_fingerprint()
//  - gates on ov_auth_profiling_enabled() (TESSERA_AUTH_TOKEN)
//  - benches AVX-512 paths (use_accel=true) vs scalar on this host
//  - emits regime_router_<fingerprint>.bin into XDG_CACHE_HOME/tessera
#include "ggml-openvino/openvino/regime_host.h"
#include "ggml-openvino/openvino/host_tune.h"
#include <cstdio>
#include <cstdlib>

using namespace ov::frontend::ggml;

int main(int argc, char ** argv) {
    const char * out = nullptr;
    for (int i=1;i<argc;i++) {
        if (std::string(argv[i])=="--out" && i+1<argc) out=argv[++i];
        else if (std::string(argv[i])=="--help") {
            printf("Usage: %s --out <path>  (also respects TESSERA_AUTH_TOKEN)\n", argv[0]);
            printf("Fingerprint: %s\n", ov_regime_host_fingerprint().c_str());
            printf("Auth: %s\n", ov_auth_profiling_enabled() ? "enabled" : "disabled (set TESSERA_AUTH_TOKEN=tessera-host-calibrate)");
            return 0;
        }
    }
    printf("Host fingerprint: %s\n", ov_regime_host_fingerprint().c_str());
    const auto & tune = ov_get_host_tune();
    printf("Host tune: L1=%dKB L2=%dKB L3=%dKB EU=%d SLM=%dKB tile=%d\n",
           tune.l1_kb, tune.l2_kb, tune.l3_kb, tune.gpu_eus, tune.gpu_slm_kb, tune.cpu_tile);
    if (!ov_auth_profiling_enabled()) {
        fprintf(stderr,"Auth required: set TESSERA_AUTH_TOKEN=tessera-host-calibrate or a hex token + ~/.cache/tessera/.auth\n");
        return 2;
    }
    if (!ov_regime_host_ensure_calibrated()) {
        fprintf(stderr,"Failed to ensure host cache\n");
        return 1;
    }
    std::string path;
    if (!ov_regime_host_try_load(path)) {
        fprintf(stderr,"No host cache after ensure\n");
        return 1;
    }
    printf("Host regime cache: %s\n", path.c_str());
    if (out) {
        // Copy cache to requested out path
        std::string cmd = std::string("cp \"") + path + "\" \"" + out + "\"";
        int rc = system(cmd.c_str());
        printf("Copied to %s (rc=%d)\n", out, rc);
        return rc==0?0:1;
    }
    return 0;
}
