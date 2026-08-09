# Intel Parallel Lane — Tessera Calibration & Quant

This document describes the Intel Linux parallel lane added alongside the
Apple Silicon lane. Apple code is untouched; Intel lane activates when
`platform.system() != Darwin` on `x86_64`.

## Lane Map

| Apple | Intel | Residency |
|---|---|---|
| `Accelerate cblas_sgemm` (`apple_accelerate_matmul.cpp`) | `MKL/OpenBLAS cblas_sgemm` (`intel_mkl_matmul.cpp`) | CPU SIMD (AMX/AVX-512) |
| `MPS MPSMatrixMultiplication` (`apple_metal_matmul.mm`) | `SYCL USM` (`intel_sycl_matmul.cpp`) | iGPU USM Shared zero-copy, like Metal Shared |
| `tessera-metal.metal` kernels `sct/dmr/awq_grid` | `tessera-intel.cpp/.h` SYCL `parallel_for` | dGPU device private (weights duplicated to VRAM, activations via buffers) |
| `ANE CoreML` (`apple_ane_quantizer.mm`) `CPUAndNeuralEngine` | `OpenVINO` `NPU,GPU,CPU` hetero (`intel_npu_quantizer.py`) | NPU fixed rows 64/256/1024, hetero fallback |

## Memory Model

- **iGPU (integrated)**: `sycl::malloc_shared` — host `mmap` view is also
  GPU-visible, no copy, identical to `MTLResourceStorageModeShared`.
- **dGPU (discrete)**: `sycl::malloc_device` — weights duplicated once per
  layer to VRAM (blit), subsequent candidate evals read device memory.
  Only activation tiles `4096x4096 ~64MB` cross PCIe per chunk.
- **Heterogeneous**: `intel_sharding.py` `sharded_chunked_matmul` splits
  chunks round-robin `igpu:chunk0, dgpu:chunk1...` across queues.

## Presets

- `x64-linux-intel` — `GGML_BLAS=ON` + `GGML_SYCL=ON` + `GGML_OPENVINO=ON`
- `x64-linux-intel-mkl` — `Intel10_64lp` + `icx/icpx` for MKL lane

## Probing

```sh
python3 -c "from tools.tessera.calibration_metal import get_matmul_backend_name; print(get_matmul_backend_name())"
python3 -c "from tools.tessera.intel_sharding import describe_residency; print(describe_residency())"
python3 -c "from tools.tessera.intel_npu_quantizer import is_available; print(is_available())"
```
