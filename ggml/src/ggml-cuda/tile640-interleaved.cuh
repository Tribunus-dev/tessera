#include "common.cuh"

// HIP port of kernel_TILE640_MATMUL_INTERLEAVED. P0 path is bit-exact
// equivalent to the base kernel_TILE640_MATMUL; P1 (drafter) and P2 (KV)
// paths are gated by TESSERA_TILE640_INTERLEAVED and the per-graph
// iargs.drafter_enabled / iargs.kv_enabled flags. Dispatch site must
// populate iargs from op_params; see ggml_cuda_op_tile640_matmul_interleaved.
void ggml_cuda_op_tile640_matmul_interleaved(
        ggml_backend_cuda_context & ctx,
        const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst);
