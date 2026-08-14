#ifndef GGML_AMD_H
#define GGML_AMD_H

#include "ggml.h"
#include "ggml-backend.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifdef GGML_BACKEND_DL
#ifdef GGML_BACKEND_SHARED
#define GGML_AMD_API GGML_BACKEND_API_EXPORT
#else
#define GGML_AMD_API GGML_BACKEND_API_IMPORT
#endif
#else
#define GGML_AMD_API GGML_BACKEND_API
#endif

GGML_AMD_API ggml_backend_reg_t ggml_backend_amd_reg(void);
GGML_AMD_API bool ggml_backend_is_amd(ggml_backend_t backend);
GGML_AMD_API bool ggml_backend_dev_is_amd(ggml_backend_dev_t device);

// Region scheduler integration. Analyzes the graph and assigns tensors
// to the AMD backend based on region formation. Returns the number of
// regions formed, or 0 on error/no AMD support.
GGML_AMD_API int ggml_backend_amd_schedule_graph(
    ggml_backend_sched_t sched,
    ggml_backend_t amd_backend,
    struct ggml_cgraph * graph,
    int phase); // phase: 0 = prefill, 1 = decode

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_H
