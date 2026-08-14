//
// ggml-amd-hip.h
//
// Public interface for the HIP provider's T640 compute functions.
// These functions dispatch T640 operations on the HIP stream.
//

#ifndef GGML_AMD_HIP_H
#define GGML_AMD_HIP_H

#include "../ggml-amd-provider.h"
#include "ggml.h"

#ifdef __cplusplus
extern "C" {
#endif

// Probe the HIP provider. Returns true if HIP is available and at least
// one device is found.
bool ggml_amd_hip_probe(struct ggml_amd_provider * provider, struct ggml_amd_probe_result * result);

#ifdef GGML_AMD_HIP
#ifdef __HIP_PLATFORM_AMD__

// Compute functions for T640 operations. Each function dispatches the
// corresponding HIP kernel on the provider's stream.
//
// These are standalone dispatch functions for testing and future integration.
// The actual compute path will go through ggml_backend, which will call
// these functions (or equivalent) based on the op type.

ggml_status ggml_amd_hip_compute_tile640_dequant(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst);

ggml_status ggml_amd_hip_compute_tile640_matmul(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst);

ggml_status ggml_amd_hip_compute_tile640_matmul_id(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst);

ggml_status ggml_amd_hip_compute_tile640_get_rows(
        struct ggml_amd_provider * provider,
        struct ggml_tensor * dst);

#endif // __HIP_PLATFORM_AMD__
#endif // GGML_AMD_HIP

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_HIP_H
