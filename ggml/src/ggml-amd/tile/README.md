# TILE_AMD — AMD-layout blocked GEMM stubs (like TILE640 for OpenVINO)

See `docs/backend/AMD.md` Final and `.agents/plans/2026-08-08-tile-amd-hetro.md`.

Scope: `GGML_TYPE_TILE_AMD` (~36) + `GGML_OP_TILE_AMD_MATMUL|MATMUL_ID|GET_ROWS|DEQUANT`
with `QK_AMD=64` `CK`-friendly `bpreshuffle` `MFMA 16x16` layout (not `AMX tile-N`).
`ggml-amd/tile/tile_amd_matmul.cpp` -> `HIP CK` `gfx1201`/`gfx942`,
`tile_amd.comp` -> `Vulkan` `gfx1151` iGPU, `AIE xclbin` phase 2 (static).

Ground truth: `dequantize_row_tessera_amd` (`ggml-quants.h`) + `ts_decode_per_row_meta_amd`,
consumed by `tile_amd_quantize.py` GA (`ternary_threshold [0.3,3.0]`).

## Lineage note (W3 task 3.6, host-amd-implementation-plan.md)

`tile_amd_matmul.cpp` above is the original 2026-08-08 stub (`QK_AMD=64`
single-value design, since superseded - see
docs/amd-tile-format-spec.md 9(iii)) and is left as-is: a placeholder for
the future gfx1201/gfx942 MFMA path it describes. It is NOT the RDNA3
kernel.

`tile_amd_matmul_rdna3.cpp` (new, same directory) is the actual Wave C
kernel from the current spec (docs/amd-tile-format-spec.md), targeting
gfx1103/gfx1100-1102 via WMMA (not MFMA) on top of the vendored CK subset
in `ggml-amd/ck/`. Different arch family, different instruction class,
different spec generation - kept as a separate file rather than rewriting
the stub in place, per the master plan's D2 ("per-arch file, not an
in-place rewrite").
