//
// tessera-amd.cpp
//
// Bridge between the tessera CLI (common_tessera_params AMD fields) and
// the ggml-amd backend's GGML_AMD_* environment variables. See
// tessera-amd.h for the contract.
//
// The env vars are set unconditionally for string fields with a non-empty
// value; empty strings are skipped so the backend's own defaults apply.
// Boolean fields (amd_xdna, amd_vulkan_fallback) are always set because
// they have a meaningful default (off/on).
//

#include "tessera-amd.h"
#include "tessera-args.h"

#include <cstdlib>
#include <string>

// setenv is POSIX; on Windows use _putenv_s. The ggml-amd backend is
// Linux-only for now (HIP / Vulkan / XDNA are all Linux-first), so the
// POSIX path is the hot path.
#if defined(_WIN32)
#define TS_SETENV(k, v) _putenv_s((k), (v))
#else
#define TS_SETENV(k, v) setenv((k), (v), /*overwrite=*/1)
#endif

static void ts_amd_set_if_nonempty(const char * env_key, const std::string & value) {
    if (!value.empty()) {
        TS_SETENV(env_key, value.c_str());
    }
}

void tessera_amd_apply_config(const common_tessera_params & params) {
    // String fields: set only when non-empty so the backend's own
    // defaults (compiled-in or env-probed) apply for unset fields.
    ts_amd_set_if_nonempty("GGML_AMD_PROVIDER",       params.amd_provider);
    ts_amd_set_if_nonempty("GGML_AMD_MODE",           params.amd_mode);
    ts_amd_set_if_nonempty("GGML_AMD_KV_HOME",        params.amd_kv_home);
    ts_amd_set_if_nonempty("GGML_AMD_CACHE_DIR",      params.amd_cache_dir);
    ts_amd_set_if_nonempty("GGML_AMD_METRICS",        params.amd_metrics_path);

    // Boolean fields: always set (they have a meaningful default).
    TS_SETENV("GGML_AMD_XDNA",             params.amd_xdna ? "on" : "off");
    TS_SETENV("GGML_AMD_VULKAN_FALLBACK",  params.amd_vulkan_fallback ? "1" : "0");
}
