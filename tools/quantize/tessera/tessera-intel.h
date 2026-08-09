#pragma once
// tessera-intel.h
// Intel SYCL compute acceleration for the Tessera quantize pipeline
// (parallel lane to tessera-metal.h). Apple Metal lane untouched.
//
// Architecture mirrors Metal: upload weight tensor to device once per layer
// (ts_intel_upload_weights -> per-device private buffers for dGPU, USM Shared
// for iGPU zero-copy), then each candidate eval dispatches SYCL kernels that
// read from device-resident weights. Small results (MSE, best alpha) come back.
// Gated by ts_intel_available() so non-Intel builds compile with stub.

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ts_intel_context ts_intel_context_t;
typedef struct ts_intel_weights ts_intel_weights_t;

// True if Intel SYCL device(s) found and library compiled.
// Mirrors ts_metal_available() contract.
int ts_intel_available(void);
int ts_intel_init(void);
void ts_intel_shutdown(void);

// Device enumeration: igpu (shared), dgpu (private), or both.
int ts_intel_device_count(void);
const char* ts_intel_device_name(int idx); // "igpu" or "dgpu"

// Upload weights once per layer — per-device duplication for dGPU,
// USM Shared alias for iGPU. Null on failure.
ts_intel_weights_t* ts_intel_upload_weights(const float* weights, const float* scales,
                                            int64_t out_dim, int64_t in_dim);
void ts_intel_release_weights(ts_intel_weights_t* w);

// Fused kernels mirroring Metal's three phases:
int ts_intel_scale_clip_ternarize(ts_intel_weights_t* w, const float* wscale, float clip,
                                  float* ws, float* core, int8_t* ternary, float* thresholds);
int ts_intel_dequant_mse_recon(ts_intel_weights_t* w, const int8_t* ternary,
                               const uint16_t* scales_f16, const int8_t* outlier_vals,
                               const int32_t* outlier_idx, int64_t n_outliers,
                               const float* act, const float* act2,
                               float* mse, float* recon);
int ts_intel_awq_grid_search(ts_intel_weights_t* w, const float* act,
                             int64_t n_grid, float* best_alpha);

#ifdef __cplusplus
}
#endif
