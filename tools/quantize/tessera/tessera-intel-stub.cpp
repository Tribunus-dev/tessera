//
// tessera-intel-stub.cpp
// No-op stubs for Intel SYCL dispatch on platforms where SYCL is
// unavailable. Mirrors tessera-metal-stub.cpp contract. ts_intel_available()
// returns 0 so ts_quantize_2d falls back to BLAS/scalar.

#include "tessera-intel.h"

extern "C" {

int ts_intel_available(void) { return 0; }
int ts_intel_init(void) { return 1; }
void ts_intel_shutdown(void) {}

int ts_intel_device_count(void) { return 0; }
const char* ts_intel_device_name(int) { return ""; }

ts_intel_weights_t* ts_intel_upload_weights(const float*, const float*, int64_t, int64_t) { return nullptr; }
void ts_intel_release_weights(ts_intel_weights_t*) {}

int ts_intel_scale_clip_ternarize(ts_intel_weights_t*, const float*, float, float*, float*, int8_t*, float*) { return 1; }
int ts_intel_dequant_mse_recon(ts_intel_weights_t*, const int8_t*, const uint16_t*, const int8_t*, const int32_t*, int64_t, const float*, const float*, float*, float*) { return 1; }
int ts_intel_awq_grid_search(ts_intel_weights_t*, const float*, int64_t, float*) { return 1; }

} // extern "C"
