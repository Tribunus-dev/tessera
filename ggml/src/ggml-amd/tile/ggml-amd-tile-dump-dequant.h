//
// ggml-amd-tile-dump-dequant.h
//
// Tessera Layer 1 dequant sidecar helper for the HIP backend.
// Materializes the T640-dequantized F32 weight on device, copies it
// to host, and writes it to the sidecar via tessera_debug API.
//

#ifndef GGML_AMD_TILE_DUMP_DEQUANT_H
#define GGML_AMD_TILE_DUMP_DEQUANT_H

#include <hip/hip_runtime.h>

struct ggml_tensor;

#ifdef __cplusplus
extern "C" {
#endif

// Dump the T640-dequantized weight for `op` (a GGML_OP_TILE640_MATMUL or
// GGML_OP_TILE640_MATMUL_ID node) to the sidecar. `row_width` is in_dim;
// `n_rows` is the number of weight rows (out_dim for MATMUL, n_experts*out_dim
// for MATMUL_ID). `name` identifies the tensor in the sidecar directory.
//
// The hook launches the dequant kernel on `stream`, synchronizes, copies
// the result to host, and writes it via tessera_debug::open_dequant_writer.
// No-op when the dequant debug hook is not enabled.
void ggml_amd_hip_dump_dequant_tile640(
        hipStream_t stream,
        const struct ggml_tensor * op,
        int64_t row_width,
        int64_t n_rows,
        const char * name);

#ifdef __cplusplus
}
#endif

#endif // GGML_AMD_TILE_DUMP_DEQUANT_H
