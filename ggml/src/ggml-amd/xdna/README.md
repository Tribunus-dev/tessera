# XDNA (AMD Ryzen AI NPU)

The AMD counterpart of the Apple ANE surface. The ANE foundation is the
`common/ane-mtp.{h,mm}` sidecar runtime (fused-function offload under the
speculative-decoding and server prefill paths), not a ggml op backend; XDNA
follows the same shape. This directory holds the compiled kernel artifacts.
The device runtime lives in `common/xdna-runtime.{h,cpp}` (with
`common/xdna-runtime-stub.cpp` on platforms without the amdxdna UAPI), and
the bring-up test is `common/test_xdna.cpp` (`bin/test-xdna`).

## Artifacts

`kernels/xdna_kernels.xclbin`
: An xclbin2 container in the XRT xclbinutil / MLIR-AIE flavor. One DPU
  kernel instance `MLIR_AIE:MLIRAIE` (kernel id `0x901`, ip type
  `IP_PS_KERNEL`, subtype DPU) with the standard DPU argument convention:
  `opcode` (u64), `instr` (ptr), `ninstr` (u32), `bo0..bo4` (data ptrs).
  Memory banks: `HOST` (64 MB DRAM) and `SRAM` (48 MB). The
  `AIE_PARTITION` section carries the device image (PDI content) that
  milestone 2 loads onto the array.

`kernels/xdna_kernels.insts`
: The DPU instruction blob dispatched through the `instr`/`ninstr`
  arguments. This is the compiled-graph model: the host patches buffer
  device addresses into the instruction stream and submits it; the array
  executes it without per-op host involvement.

## Driver stack

The `amdxdna` kernel driver exposes the NPU as `/dev/accel/accelN`
(accel-class nodes, not DRM render nodes - libdrm enumeration does not see
them). The runtime talks raw `open()`/`ioctl()` against
`drm/amdxdna_accel.h` from the kernel headers: GET_INFO queries, hardware
contexts, buffer objects (GEM-backed), sync, and EXEC_CMD. Neither XRT nor
libdrm is required.

## Milestones

- **M1 (shipped)**: device foundation. `common_xdna_available` /
  `common_xdna_device_query` / `common_xdna_device_open` give every
  consumer the AIE version, firmware version, array geometry, and clock
  metadata. `common_xdna_device_open` allocates and `mmap`s the
  per-client device-heap BO (local-shmem path, 64 MiB on AIE 1.1) so
  subsequent allocations of device-side memory are backed. The BO
  surface covers SHMEM (host-shared) and DEV (carved from the heap) with
  mmap / sync / device-address accessors. Host-side xclbin2 container
  parsing covers the shipped artifact. `test-xdna` PASSes on hardware
  with all of the above plus the host pattern round-trip through a
  to-device SYNC_BO.
- **M2 (next)**: DPU dispatch, gated on three blockers surfaced during M1:
  1. **Heap DMA mapping.** On AIE 1.1 + amdxdna v7.1.y, `CREATE_HWCTX`
     fails inside `aie2_map_host_buf` (firmware opcode `MSG_OP_MAP_HOST_BUFFER`,
     `0x106`, status `0x4000003`) because the local-shmem heap BO has no
     DMA address: `drm_gem_shmem_pin` only allocates backing pages, it
     does not `dma_map_sg`, and the v7.1.y driver never assigns
     `mem.dma_addr` for shmem objects. The userptr (ubuf) path does
     populate a DMA mapping, but its `dma_buf_ops` has no `mmap`, which
     prevents `amdxdna_hmm_register` from setting `mem.uva` and so blocks
     DEV BO allocation. M2 picks one of the two paths (wait for an
     upstream driver fix that DMA-maps shmem objects, or add an internal
     mmap-capable heap path through the ubuf dmabuf_ops) before
     `common_xdna_context_create` can be promoted from best-effort to
     hard-PASS.
  2. **xclbin / PDI load.** The shipped amdxdna UAPI header only carries
     CONFIG_CU and debug-buffer params; PDI loading needs a UAPI revision
     the running kernel does not expose. M2 lands when a UAPI for xclbin
     load is present.
  3. **EXEC_CMD DPU-chain dispatch + `.insts` relocation patching** of
     buffer device addresses, and finally the ANE-style product seam
     (`common_xdna_*` counterparts of the five `ane-mtp.h` entry points
     consumed by `speculative.cpp` and
     `tools/server/server-context.cpp`).

The wider `ggml/src/ggml-amd/` tree remains dormant; nothing here is a
ggml backend yet.
