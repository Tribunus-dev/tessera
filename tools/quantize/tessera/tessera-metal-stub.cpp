//
// tessera-metal-stub.cpp
//
// No-op stubs for the Metal dispatch entry points on platforms where Metal is
// unavailable (everything except macOS). ts_metal_available() always returns 0,
// so ts_quantize_2d falls back to the vDSP / scalar CPU path. Linked in place
// of tessera-metal.mm by the CMake when APPLE is false.
//

#include "tessera-metal.h"

extern "C" {

int  ts_metal_available(void) { return 0; }
int  ts_metal_init(void)      { return 1; }
void ts_metal_shutdown(void)  {}

ts_metal_weights_t * ts_metal_upload_weights(const float *, const float *,
                                             int64_t, int64_t) {
    return nullptr;
}
void ts_metal_release_weights(ts_metal_weights_t *) {}

int ts_metal_scale_clip_ternarize(ts_metal_weights_t *, const float *, float,
                                  float *, float *, int8_t *, float *) {
    return 1;
}
int ts_metal_dequant_mse_recon(ts_metal_weights_t *, const int8_t *,
                               const uint16_t *, const int8_t *,
                               const int32_t *, int64_t,
                               const float *, const float *,
                               float *, float *) {
    return 1;
}
int ts_metal_awq_grid_search(ts_metal_weights_t *, const float *,
                             int64_t, float *) {
    return 1;
}

// L1 kernel-direct fitness Frobenius ratio shim. The HIP implementation
// in tessera-metal-hip.cpp returns the F64 ratio on success and -1.0 on
// failure; the stub returns -1.0 unconditionally so callers fall through
// to the scalar host path. Same shape as the four stubs above.
double ts_metal_l1_ratio(const float *, const float *, int64_t) {
    return -1.0;
}
// imatrix per-row sum-of-squares shim. Returns 1 so the dense / MoE
// collectors in tools/imatrix/imatrix.cpp fall through to the scalar
// loop. The HIP path (ts_hip_imatrix_sumsq) writes the per-channel sums
// into the host buffer; the stub does nothing.
int ts_metal_imatrix_sumsq(const float *, int64_t, int64_t,
                           float *, int64_t) {
    return 1;
}
// make_qx_quants 19-trial scale sweep shim. Returns 1 so the bridge in
// ggml/src/ggml-quants.c falls through to the scalar 19-trial loop.
int ts_metal_make_qx_quants(const float *, int64_t, float *) {
    return 1;
}

}  // extern "C"
