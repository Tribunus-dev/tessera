#include "ggml-amd-internal.h"
#include "ggml.h"

#include <cstdlib>
#include <cstring>
#include <string>

static const char * ggml_amd_getenv(const char * name) {
    return std::getenv(name);
}

static enum ggml_amd_scheduler_mode ggml_amd_parse_scheduler_mode(const char * str) {
    if (!str) {
        return GGML_AMD_SCHEDULER_DETERMINISTIC;
    }
    if (strcmp(str, "adaptive") == 0) {
        return GGML_AMD_SCHEDULER_ADAPTIVE;
    }
    if (strcmp(str, "diagnostic") == 0) {
        return GGML_AMD_SCHEDULER_DIAGNOSTIC;
    }
    if (strcmp(str, "single-provider") == 0) {
        return GGML_AMD_SCHEDULER_SINGLE_PROVIDER;
    }
    return GGML_AMD_SCHEDULER_DETERMINISTIC;
}

void ggml_amd_config_init(struct ggml_amd_reg_context * ctx) {
    const char * mode_str = ggml_amd_getenv("GGML_AMD_MODE");
    ctx->scheduler_mode = ggml_amd_parse_scheduler_mode(mode_str);

    const char * cache_dir = ggml_amd_getenv("GGML_AMD_CACHE_DIR");
    if (cache_dir) {
        ctx->cache_dir = cache_dir;
    } else {
        const char * home = ggml_amd_getenv("HOME");
        if (home) {
            ctx->cache_dir = std::string(home) + "/.cache/ggml-amd";
        } else {
            ctx->cache_dir = "/tmp/ggml-amd-cache";
        }
    }

    const char * metrics_path = ggml_amd_getenv("GGML_AMD_METRICS");
    if (metrics_path) {
        ctx->metrics_path = metrics_path;
    }

    ctx->initialized = true;
}
