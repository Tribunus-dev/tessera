# ggml-amd — unified AMD backend + TILE_AMD layout — Final

> **Status: Final** — Q1-6 decisions locked plus TILE_AMD AMD-layout GGUF spec for Strix Halo 128GB + R9700 32GB hetero inference. See `.agents/plans/2026-08-08-tile-amd-hetro.md`.

## Overview

`ggml-amd` absorbs `ggml-hip`, `ggml-vulkan` (Vulkan path), `ggml-zendnn`, plus AITER CK kernels, Tessera `TILE640` lineage, and FastFlow DFF into one `ggml/src/ggml-amd` hetero backend. Prior fragmentation:

* `ggml-hip` — 158 lines, `GLOB ../ggml-cuda/*.cu` + `enable_language(HIP)` (`ggml/src/ggml-hip/CMakeLists.txt`)
* `ggml-vulkan` — 19,146 lines `ggml-vulkan.cpp` + `vulkan-shaders/` + `cmake/host-toolchain.cmake.in`, vendor-agnostic SPIR-V via `glslc`/`SPIRV-Headers` (`ggml/src/ggml-vulkan/CMakeLists.txt`)
* `ggml-zendnn` — single `ggml-zendnn.cpp` `703` lines `zendnnl::lowoha::matmul_direct` (`ggml/src/ggml-zendnn/CMakeLists.txt` `ExternalProject_Add ZenDNN WW19`)
* `ggml-openvino` — `5.8k` + `9.6k` `openvino/op/*.cpp` with `openvino/op_table.cpp` Tile640 mapping — Intel-only template

Fetched: `/home/juliantores/dev/fastflow` (`ff/farm.hpp`/`ff/a2a.hpp`/`ff/dff.hpp` + `MTCL`) + `/home/juliantores/dev/aiter` (`csrc/ck_gemm_*`, `aiter_tensor.h`) + `/home/juliantores/dev/ROCm`.

Target: Strix Halo `128GB` UMA (`Zen5 16c` + `RDNA3.5 40CU gfx1151` + `XDNA2 50 TOPS npu2`) + `R9700 32GB gfx1201 RDNA4` — full CPU + NPU + iGPU + dGPU hetero via one `GGML_AMD` backend.

## Q1 — Scope

**Unified monolith (AITER + FastFlow) inside `ggml-amd`.**

`ggml-amd` owns kernel layer (HIP/CK) and distribution layer (FastFlow DFF/A2A/farm). Alternative `hip + optional AITER dlopen` rejected per grill.

## Q2 — Kernel ownership

**Vendor in-tree CK.**

Copy minimal `CK` from `aiter/csrc` (`ck_gemm_a8w8`, `ck_gemm_moe_2stages`, `fmha`) into `ggml-amd/ck/`, maintain in-tree like `ggml-cuda` (67 `.cu`) and `ggml-openvino/op`. No `ExternalProject_Add(aiter)`.

## Q3 — Tile640 parity -> TILE_AMD

**Port `TILE640/512/1024` lineage as `TILE_AMD` now in v1** — see TILE_AMD spec below.

## Q4 — ZenDNN

**Merge into `ggml-amd`.** `ggml-zendnn.cpp` -> `ggml-amd-zendnn.cpp`, one backend for `gfx942/950` + `gfx1201` GPU + Zen4/5 CPU.

## Q5 — Fabric

**FastFlow primary** (`ff::Pipe`/`ff::Farm`/`ff::A2A` + `dff_run` TCP/MPI + `MTCL`); `aiter` `custom_all_reduce.h` as kernel only.

## Q6 — Vulkan

**Absorb `ggml-vulkan` onto `ggml-amd`.** `ggml-amd-vulkan.cpp` (19k), `vulkan-shaders/`, `cmake/host-toolchain.cmake.in` vendored. Runtime select: `HIP/CK` if `ROCM_PATH` + `gfx942/950/1201`, else `Vulkan` `SPIR-V` for `gfx1151` RDNA consumer.

## TILE_AMD — AMD-layout GGUF spec (like TILE640 for OpenVINO)

### Goal

One AMD-layout GGUF that `ggml-amd` hetero can split across `Strix Halo` + `R9700`, mirroring `TILE640` for `ggml-openvino` (`openvino/op/tile640_matmul.cpp:553`).

### Contract

* **Types:** Reserve `GGML_TYPE_TILE_AMD = 36` (after `GGML_TYPE_TQ2_0 = 35` in `ggml/include/ggml.h:424-425`) and `GGML_OP_TILE_AMD_MATMUL` / `..._MATMUL_ID` / `..._GET_ROWS` / `..._DEQUANT` (after `GGML_OP_TILE1024_DEQUANT` `ggml/include/ggml.h:590-593`). `ne[0]/nb[0]/blck_size` contract identical to `ggml_tile640_matmul` (`ggml/src/ggml.c:6417`): `A` packed `TILE_AMD` weight `(K, M)` column-major, `B` row-major `(N, K)`, `C` `(N, M)`.
* **Blocking:** `QK_AMD` block size `64` tentative (MFMA `16x16` friendly; `TILE640_PAGE_SIZE` precedent). `TS_T640_META_DECODE_MIN_N_TOTAL_PAGES` analog `TS_AMD_META_DECODE_MIN` selects accel (`hip` `CK` vs scalar). Open: `32` vs `64` pending `cpu_dump` Frobenius.
* **Packing:** `CK`-friendly `bpreshuffle` blocked `K` layout (from `aiter/csrc/ck_gemm_a8w8_bpreshuffle` precedent), not `AMX tile-N`. Reuse `Vulkan` `vulkan-shaders/dequant_funcs.glsl` for iGPU dequant.
* **Meta:** Per-row `page_scales:fp16` + `lane_scales:int8` -> `page_max_out:fp32` + `lane_scale_out:fp32/127` via `ts_decode_per_row_meta_amd` (like `ggml/src/ggml-quants.h` `dequantize_row_tessera_t640` + `ts_decode_per_row_meta`). `dequantize_row_tessera_amd` ground truth for quantizer GA.
* **GGUF metadata:** `general.quantization_version` bump, `general.type = TILE_AMD`, `amd.tile.block = 64`, `amd.tile.arch = gfx1201|gfx1151|gfx942` (single type, arch hint), `amd.tile.version`. Token `gemma4.attention.sliding_window` overrides reused.
* **Ops:** `ggml_tile_amd_matmul(A, scales, outliers, B)` etc. declared in `ggml/include/ggml.h:2641` block and `ggml/src/ggml-quants.h` `GGML_API`.

### Quantizer

Extend `tools/tessera/tile640_quantize_v3.py` -> `tools/tessera/tile_amd_quantize.py` `quantize_2d_tessera_amd` with `dequantize_row_tessera_amd` kernel fidelity (`docs/PROJECT-STATUS.md` Layer 1/3), same GA dimensions `ternary_threshold [0.3,3.0]` `outlier_fraction` `awq_*`. `conversion/convert_hf_to_gguf.py --outtype tile_amd_auto` emits `*-amd-tile-*.gguf`. Calibrated via `tools/tessera/per_tensor_calibrate.py` `direct` Frobenius (`12-18%` over `importance`).

### Runtime mapping

* `ggml/src/ggml-amd/tile/tile_amd_matmul.cpp` — HIP `CK MFMA` `gfx1201`/`gfx942`
* `ggml/src/ggml-amd/tile/tile_amd.comp` — Vulkan SPIR-V for `gfx1151` iGPU
* `ggml/src/ggml-amd/ggml-amd.cpp` `op_table_amd` — `GGML_OP_TILE_AMD_*` -> `CK` / `Vulkan` / `AIE xclbin` (NPU `static` phase 2, `STATEFUL=0` like `openvino` NPU)

Original `TILE640/512/1024` `ggml_compute_forward_tile640_*` (`ggml/src/ggml-cpu/ops.cpp:11199`) stays for Intel/CPU ref.

## On-disk layout (absorbed, not yet built)

```
ggml/src/ggml-amd/
  ck/README.md               # vendor CK placeholder
  tile/README.md -> tile spec below
  tile/tile_amd_matmul.cpp   # stub (MFMA)
  tile/tile_amd.comp         # stub (Vulkan)
  fastflow/README.md         # DFF placeholder
  ggml-amd-vulkan.cpp        # 19k from ggml-vulkan.cpp
  ggml-amd-zendnn.cpp        # 703 lines
  vulkan-shaders/            # copy of ggml-vulkan shaders
  cmake/host-toolchain.cmake.in
  CMakeLists.txt.{hip,vulkan,zendnn}-src
```

## Constraints

* `hip>=6.1`/`hipblas`/`rocblas`, `Vulkan GLSLC`+`SPIRV-Headers` `CMP0114/0116`, `ZenDNN WW19`, `XRT`/`mlir-aie` phase 2, `CMAKE_HIP_ARCHITECTURES` `gfx942`/`gfx950`/`gfx1201` (+ `gfx1151` Vulkan fallback).
* Upstream `master` rebase — fork 60 ahead on `tessera/integration-upstream-experiments`.

## Risks

* `~33k` + shaders + two upstreams + `AIE` in one backend — largest surface in `ggml/src`.
* `CK gfx1201` MFMA packing wrong -> `NaN` like `PROJECT-STATUS 70-150%` layers 4/8/16/32.
* `HIP gfx1151` preview -> `iGPU` stays `Vulkan` only until stable.

## Validation

* `grep -n TILE_AMD ggml/include/ggml.h && grep tile_amd ggml/src/ggml-quants.h`
* `python tools/tessera/tile_amd_quantize.py --help && convert_hf_to_gguf.py --help | grep tile_amd`
* `cmake -LA -B build | grep GGML_AMD && grep amd CMakePresets.json`
* `llama-bench -m qwen3-8b-tile_amd.gguf --backend amd` vs `tile640` `llama-bench` + `cpu_dump` cosine/Frobenius

## Next steps (plan .agents/plans/2026-08-08-tile-amd-hetro.md W1-7)

Finalize `TILE_AMD` enum, stub `tile/` kernels, then unified `CMakeLists.txt` + `ggml-amd.cpp` hetero dispatch + `CODEOWNERS`.
