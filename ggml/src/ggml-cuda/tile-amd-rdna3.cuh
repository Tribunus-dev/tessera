#include "common.cuh"

// W3 task 3.7 (docs/amd-tile-format-spec.md 3.4): AMD RDNA3 native-WMMA
// tile matmul, HIP backend dispatch. Dequantizes the i8+page/lane-scale
// weight cluster and converts activations to bf16 in device scratch
// buffers, then dispatches the WMMA kernel shared with ggml-amd/tile/
// tile_amd_matmul_rdna3.cpp (tile_amd_matmul_rdna3.cuh). TS_TILE_GPU=0
// forces a non-WMMA scalar GPU fallback instead (same dequantized inputs,
// naive per-element accumulate) - not a CPU round-trip.
void ggml_cuda_op_tile_rdna3_matmul(
        ggml_backend_cuda_context & ctx,
        const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst);
