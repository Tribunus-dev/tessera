#include "ggml-amd-internal.h"
#include "ggml.h"

#include <atomic>
#include <string>
#include <mutex>
#include <cstdio>

struct ggml_amd_metrics {
    std::atomic<size_t> queue_time_ns{0};
    std::atomic<size_t> execution_time_ns{0};
    std::atomic<size_t> imported_bytes{0};
    std::atomic<size_t> resident_bytes{0};
    std::atomic<size_t> fallback_count{0};
    std::atomic<size_t> copy_bytes{0};
    std::atomic<size_t> shared_bytes{0};
    std::atomic<size_t> fence_wait_ns{0};
    std::atomic<size_t> cache_hits{0};
    std::atomic<size_t> cache_misses{0};
    std::atomic<size_t> kv_migration_count{0};
    std::string kv_home;
    std::string fallback_reason;
    std::mutex mutex;
};

struct ggml_amd_metrics * ggml_amd_metrics_create(void) {
    return new ggml_amd_metrics();
}

void ggml_amd_metrics_destroy(struct ggml_amd_metrics * metrics) {
    delete metrics;
}

void ggml_amd_metrics_record_queue_time(struct ggml_amd_metrics * metrics, size_t ns) {
    if (metrics) {
        metrics->queue_time_ns += ns;
    }
}

void ggml_amd_metrics_record_execution_time(struct ggml_amd_metrics * metrics, size_t ns) {
    if (metrics) {
        metrics->execution_time_ns += ns;
    }
}

void ggml_amd_metrics_record_import(struct ggml_amd_metrics * metrics, size_t bytes) {
    if (metrics) {
        metrics->imported_bytes += bytes;
    }
}

void ggml_amd_metrics_record_resident(struct ggml_amd_metrics * metrics, size_t bytes) {
    if (metrics) {
        metrics->resident_bytes = bytes;
    }
}

void ggml_amd_metrics_record_fallback(struct ggml_amd_metrics * metrics, const char * reason) {
    if (metrics) {
        metrics->fallback_count++;
        std::lock_guard<std::mutex> lock(metrics->mutex);
        if (reason) {
            metrics->fallback_reason = reason;
        }
    }
}

void ggml_amd_metrics_record_copy(struct ggml_amd_metrics * metrics, size_t bytes) {
    if (metrics) {
        metrics->copy_bytes += bytes;
    }
}

void ggml_amd_metrics_record_shared(struct ggml_amd_metrics * metrics, size_t bytes) {
    if (metrics) {
        metrics->shared_bytes += bytes;
    }
}

void ggml_amd_metrics_record_fence_wait(struct ggml_amd_metrics * metrics, size_t ns) {
    if (metrics) {
        metrics->fence_wait_ns += ns;
    }
}

void ggml_amd_metrics_record_cache_hit(struct ggml_amd_metrics * metrics) {
    if (metrics) {
        metrics->cache_hits++;
    }
}

void ggml_amd_metrics_record_cache_miss(struct ggml_amd_metrics * metrics) {
    if (metrics) {
        metrics->cache_misses++;
    }
}

void ggml_amd_metrics_record_kv_migration(struct ggml_amd_metrics * metrics) {
    if (metrics) {
        metrics->kv_migration_count++;
    }
}

void ggml_amd_metrics_set_kv_home(struct ggml_amd_metrics * metrics, const char * home) {
    if (metrics && home) {
        std::lock_guard<std::mutex> lock(metrics->mutex);
        metrics->kv_home = home;
    }
}

void ggml_amd_metrics_dump(struct ggml_amd_metrics * metrics, FILE * out) {
    if (!metrics || !out) {
        return;
    }

    std::lock_guard<std::mutex> lock(metrics->mutex);

    fprintf(out, "{\n");
    fprintf(out, "  \"queue_time_ns\": %zu,\n", metrics->queue_time_ns.load());
    fprintf(out, "  \"execution_time_ns\": %zu,\n", metrics->execution_time_ns.load());
    fprintf(out, "  \"imported_bytes\": %zu,\n", metrics->imported_bytes.load());
    fprintf(out, "  \"resident_bytes\": %zu,\n", metrics->resident_bytes.load());
    fprintf(out, "  \"fallback_count\": %zu,\n", metrics->fallback_count.load());
    fprintf(out, "  \"fallback_reason\": \"%s\",\n", metrics->fallback_reason.c_str());
    fprintf(out, "  \"copy_bytes\": %zu,\n", metrics->copy_bytes.load());
    fprintf(out, "  \"shared_bytes\": %zu,\n", metrics->shared_bytes.load());
    fprintf(out, "  \"fence_wait_ns\": %zu,\n", metrics->fence_wait_ns.load());
    fprintf(out, "  \"cache_hits\": %zu,\n", metrics->cache_hits.load());
    fprintf(out, "  \"cache_misses\": %zu,\n", metrics->cache_misses.load());
    fprintf(out, "  \"kv_migration_count\": %zu,\n", metrics->kv_migration_count.load());
    fprintf(out, "  \"kv_home\": \"%s\"\n", metrics->kv_home.c_str());
    fprintf(out, "}\n");
}
