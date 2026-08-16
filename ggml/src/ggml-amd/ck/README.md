# Vendored Composable Kernel (ck_tile) subset

Include-only subset of AMD's Composable Kernel, vendored from the clean
upstream checkout in the AITER workspace submodule:

- Source: `/home/x/vllm-aiter-gfx1103/aiter/3rdparty/composable_kernel`
- Pinned commit: `f33252cebe5a52362ec1ee12c124dde7800dda3a`
- License: MIT (see `LICENSE` in this directory; spec 9(vi))

## Subset rationale

This is the exact transitive `#include` closure of
`ck_tile/core/arch/mma/wmma/wmma_gfx11.hpp` (the bf16 16x16x16 WMMA
specialization for gfx11 - `__builtin_amdgcn_wmma_f32_16x16x16_bf16_w32`,
wave32, f32 accumulate - the Wave C tile kernel's primitive), computed via:

```
clang++ --offload-arch=gfx1103 -x hip -M -std=c++20 \
  -I<ck checkout>/include \
  ck_tile/core/arch/mma/wmma/wmma_gfx11.hpp
```

47 headers, entirely within `ck_tile/core/` and `ck_tile/ops/{common,gemm/warp}/`
- no rocPRIM dependency, confirmed. Only the WMMA intrinsic wrapper is used
directly (`amdgcn_mma<bf16_t, bf16_t, fp32_t, 16u, 16u, 16u, ...>`); the
Wave C kernel (`ggml-amd/tile/tile_amd_matmul_rdna3.cpp`) is tessera-original
code built on top of this primitive, not CK's `DeviceGemm` pipeline
framework - matching spec 8.3's "extend the stub into per-arch files"
guidance and the master plan's D2 (per-arch file, not an in-place rewrite).

## Smoke-compile

Verified against the pinned Fedora ROCm 7.1.1 clang-20 toolchain
(`/usr/lib64/rocm/llvm/bin/clang++`) - the workspace itself was built with
the pip rocm_sdk clang-23, so this toolchain delta was the one untested
risk per the master plan's load-bearing risk #1. Compiles clean (one
harmless `#pragma once in main file` warning from compiling the header
directly as a translation unit):

```
clang++ --offload-arch=gfx1103 -x hip -fsyntax-only -std=c++20 \
  -Iggml/src/ggml-amd/ck \
  ggml/src/ggml-amd/ck/ck_tile/core/arch/mma/wmma/wmma_gfx11.hpp
```

## Not vendored

No AITER `.cu`/`.h`/`.py` source is vendored (spec 9(vi)) - the AITER
workspace is a studied reference only (tile geometry, Triton tile-config
heuristics, the RMSNorm interleaved-load fix, the runtime-gate pattern);
those lessons inform tessera-original code, they are not lifted.
