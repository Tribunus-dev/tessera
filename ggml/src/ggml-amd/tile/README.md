# TILE_AMD — AMD-layout blocked GEMM stubs (like TILE640 for OpenVINO)

See `docs/backend/AMD.md` Final and `.agents/plans/2026-08-08-tile-amd-hetro.md`.

Scope: `GGML_TYPE_TILE_AMD` (~36) + `GGML_OP_TILE_AMD_MATMUL|MATMUL_ID|GET_ROWS|DEQUANT`
with `QK_AMD=64` `CK`-friendly `bpreshuffle` `MFMA 16x16` layout (not `AMX tile-N`).
`ggml-amd/tile/tile_amd_matmul.cpp` -> `HIP CK` `gfx1201`/`gfx942`,
`tile_amd.comp` -> `Vulkan` `gfx1151` iGPU, `AIE xclbin` phase 2 (static).

Ground truth: `dequantize_row_tessera_amd` (`ggml-quants.h`) + `ts_decode_per_row_meta_amd`,
consumed by `tile_amd_quantize.py` GA (`ternary_threshold [0.3,3.0]`).
