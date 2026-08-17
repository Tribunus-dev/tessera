# AMD Tile Format Spec - Tessera

(Author: tessera spec pass, 2026-08-15. Companion to
`.zcode/xdna-research/tile640-surface-map.md` and
`.zcode/xdna-research/amd-tile-survey.md`. Builds on the stub at
`docs/backend/AMD.md:46-69`.)

## 1. Executive summary

Apple's `Tile640` (`ggml/src/ggml-common.h:181-193`) is a per-row tile
where each "page" along the K axis is 640 elements, organized as 32
lanes x 20 elements per lane. The packing kind is `TS_PACK_RADIX243`
(5 trits per group, 4 groups per lane; `ggml-common.h:223-225`). It is
a single on-disk wire format portable across Metal, CUDA, and HIP
because the layout is hardware-agnostic: a row of 32 lanes x 20
elements can be dequantized into the lane registers of any matrix
instruction by an appropriate kernel.

For AMD, this stops working. AMD GPU matrix instructions are not
uniform: GCN has none, RDNA 1/2 have packed-math DOT4 / DOT8 (not a
real tile), RDNA 3+ has WMMA with fixed lane mapping, CDNA has MFMA
with a different fixed lane mapping, and CDNA 4 adds microscaled
FP4/FP6/FP8 (`amd-tile-survey.md:697-783`). Each arch has a native
`[M, N, K]` shape the hardware accepts in exactly one lane mapping.
If the wire format is laid out for the wrong shape, the kernel pays a
`v_permlane` or `ds_permute` cost per element to re-shuffle it into
the lane mapping the instruction expects.

The Tile640 radix-243 packing does not even use INT8 lanes (it packs
five ternary values into ten bits). On an RDNA 3 WMMA `INT8` instruction
- where the lane mapping expects one INT8 element per byte, 16 K
elements per tile - the radix-243 wire format is the wrong primitive.
The Triton dequant un-packs each u32 word, expands the ternary, and
then re-packs it into an `int8` lane-resident form before WMMA
consumes it. This works but wastes registers and issue slots.

This spec defines a family of per-arch tile wire formats that the
client packer (`tools/quantize/quantize.cpp --tessera-pack` ->
`tools/quantize/tessera/tessera-quant.cpp:1150-1206`) emits in
parallel with the existing Tile640 Apple path. The wire formats share
the 7-subtensor cluster convention from
`tools/quantize/tessera/tessera-gguf-writer.cpp:64-136` so the
loader-side lookup logic does not change, but the `packed` sub-tensor
shape and dtype change per arch to match the arch's native matrix
instruction. The neutral transport (`tile640-surface-map.md:14-58`)
stays unchanged; only the client pack step is per-arch.

The existing AMD stub at `docs/backend/AMD.md:46-69` proposes a
single `TILE_AMD` wire format with `QK_AMD = 64`, CK-friendly
`bpreshuffle` blocked-K layout, and a `amd.tile.arch` enum of
`gfx1201 | gfx1151 | gfx942`. That single-format proposal is correct in
spirit but wrong in detail: the same wire cannot satisfy CDNA MFMA
`[32, 32, 16]`, RDNA 3 WMMA `[16, 16, 16]`, and RDNA 4 WMMA
`[16, 16, 32]`. The kernel pays either way, but on the wrong
instruction the cost is the matrix throughput, not a constant. This
spec extends the stub into 10 per-arch formats (GCN / RDNA 1 / 2 / 3 /
3.5 / 4 / CDNA 1 / 2 / 3 / 4), keeps the `amd.tile.*` metadata
namespace, replaces `QK_AMD = 64` with per-arch values, and adds an
`amd.tile.mfma.shape` / `amd.tile.wmma.shape` field for the
wire-to-instruction mapping.

## 2. Tile format naming + dispatch table

Naming convention: `Tile-{ARCH_FAMILY}-{SHAPE}-{QUANT}`. The
`{ARCH_FAMILY}` is one of `GCN`, `RDNA1`, `RDNA2`, `RDNA3`, `RDNA4`,
`CDNA1`, `CDNA2`, `CDNA3`, `CDNA4`, `RDNA35`. The `{SHAPE}` is the
native `[M, N, K]` of the chosen matrix instruction. The `{QUANT}` is
the lane-resident type (`f16`, `bf16`, `i8`, `i4`, `fp8`, `bf8`,
`f8f6f4-ms`). The `{shape}` placeholder that is used as the per-arch
recommended tile in `amd-tile-survey.md:822-835` becomes the
shipped wire-format row in this spec.

The dispatch table mirrors the per-arch recommendation in
`amd-tile-survey.md:822-835` but adds the wire-format specifics
(`QK_AMD`, cluster sub-tensor count, GGUF keys):

| Arch family       | gfx targets                  | Native matrix inst                      | Tile wire name                            | QK_AMD | Cluster layout   | GGUF keys                                                                                  |
|-------------------|------------------------------|------------------------------------------|-------------------------------------------|--------|------------------|--------------------------------------------------------------------------------------------|
| GCN (legacy)      | gfx600..gfx900               | none (scalar ALU + LDS)                 | `Tile-GCN-1x1xK-f16`                      | 32     | LDS-resident     | `amd.tile.arch=GCN`, `amd.tile.shape=1x1`, `amd.tile.quant=f16`                            |
| RDNA 1            | gfx1010/1011/1012            | `V_DOT4_*` (packed math, no tile)       | `Tile-RDNA1-4x4x4-i8` / `Tile-RDNA1-4x4x4-f16` | 4      | packed-math      | `amd.tile.arch=RDNA1`, `amd.tile.dot.width=4`, `amd.tile.quant=i8|f16`                     |
| RDNA 2            | gfx1030/1031/1032            | `V_DOT8_*` (packed math)                | `Tile-RDNA2-8x8x8-i8` / `Tile-RDNA2-8x8x8-f16` | 8      | packed-math      | `amd.tile.arch=RDNA2`, `amd.tile.dot.width=8`, `amd.tile.quant=i8|f16|bf16`                |
| RDNA 3            | gfx1100/1101/1102            | `V_WMMA_*` 16x16x16                     | `Tile-RDNA3-16x16x16-i8` / `-f16` / `-bf16` / `-i4` | 16     | 7-subtensor, K-major packed INT8 lanes | `amd.tile.arch=RDNA3`, `amd.tile.wmma.shape=16x16x16`, `amd.tile.quant=i8|f16|bf16|i4` |
| RDNA 4            | gfx1200/1201                 | `V_WMMA_*` 16x16x32 + FP8 + `SWMMAC`    | `Tile-RDNA4-16x16x32-i8` / `-f16` / `-fp8` / `-bf8` / `Tile-RDNA4-16x16x64-i4` | 32 or 64 | 7-subtensor, K-major packed INT8 lanes | `amd.tile.arch=RDNA4`, `amd.tile.wmma.shape=16x16x32|16x16x64|16x16x16`, `amd.tile.quant=...` |
| CDNA 1            | gfx908                       | MFMA 32x32x8 / 16x16x16                 | `Tile-CDNA1-32x32x8-f16` / `-i8` / `-bf16` | 8      | 7-subtensor, MFMA lane map | `amd.tile.arch=CDNA1`, `amd.tile.mfma.shape=32x32x8|16x16x16`, `amd.tile.quant=f16|i8|bf16` |
| CDNA 2            | gfx90a                       | MFMA 32x32x8 BF16_1K + 16x16x16 BF16    | `Tile-CDNA2-32x32x8-f16` / `-bf16` / `-i8` | 8      | 7-subtensor, MFMA lane map | `amd.tile.arch=CDNA2`, `amd.tile.mfma.shape=32x32x8|16x16x16`, `amd.tile.quant=...`       |
| CDNA 3            | gfx942                       | MFMA 32x32x16 + FP8 + SMFMAC            | `Tile-CDNA3-32x32x16-f16` / `-i8` / `-fp8` | 16     | 7-subtensor, MFMA lane map | `amd.tile.arch=CDNA3`, `amd.tile.mfma.shape=32x32x16|16x16x32`, `amd.tile.quant=...`     |
| CDNA 4            | gfx950                       | MFMA 32x32x16/32 + scaled FP4/FP6/FP8   | `Tile-CDNA4-32x32x16-f16` / `Tile-CDNA4-32x32x32-i8` / `Tile-CDNA4-16x16x128-f8f6f4-ms` | 16 / 32 / 128 | 7-subtensor + microscale sub-tensor | `amd.tile.arch=CDNA4`, `amd.tile.mfma.shape=...`, `amd.tile.quant=...`, `amd.tile.scale=microscale` |
| RDNA 3.5 iGPU     | gfx1103/1150/1151 (Strix)    | reuses RDNA3 WMMA                       | `Tile-RDNA3-16x16x16-i8` (alias)          | 16     | reuses Tile-RDNA3 | `amd.tile.arch=RDNA35`, `amd.tile.parent=RDNA3` (aliasing key)                            |

Naming ties:

- `Tile-RDNA35-*` is **not** a separate wire format. RDNA 3.5 iGPU
  silicon shares the matrix ISA with RDNA 3 (`amd-tile-survey.md:441-479`).
  Strix Point / Strix Halo / Phoenix emit the `Tile-RDNA3-16x16x16-*`
  wire; the `amd.tile.arch=RDNA35` key is informational only and
  marks the iGPU variant so the runtime can prefer the LDS-resident
  kernel over the VRAM-staged one (system memory bandwidth is the
  bottleneck on iGPU). Rembrandt (`gfx1035`) is the exception: it is
  ISA-identical to RDNA 2 (`amd-tile-survey.md:457-459`) and emits
  `Tile-RDNA2-8x8x8-*`; the `amd.tile.arch=RDNA35` key on
  `gfx1035` is a misleading tie and the spec says: write
  `amd.tile.arch=RDNA2` on Rembrandt regardless of marketing name.
- `Tile-ROCm-*` (portable, `amd-tile-survey.md:802-820`) is the
  cross-arch "tile that works on every CDNA arch". This spec does
  not ship it; the kernel that targets MFMA `[32, 32, 8]` FP16 on
  every CDNA arch is selected by the runtime from the per-arch
  `amd.tile.arch` key. The portable `Tile-ROCm-*` name remains
  reserved for a future release that emits a single binary across
  archs.

The `amd.tile.version` field is bumped to `2` when the GGUF carries
one of these AMD-family tiles; Tile640 wire (the existing production
format) keeps `tessera.version=1` and does not set `amd.tile.*`.
A v2 client reading a v1 GGUF ignores the absent keys; a v1 client
reading a v2 GGUF rejects with `TENSOR_NOT_REQUIRED` style "unknown
type" because the `<name>.weight_packed` sub-tensor's dtype is no
longer `GGML_TYPE_I32` (the AMD wires use `GGML_TYPE_I8` for RDNA 3+
INT8 wires; see per-arch sections below).

## 3. Per-arch design

Each subsection: hardware recap; tile shape + packing; quant type
mapping; cluster layout; GGUF metadata; ggml-side changes; CK
dispatch; caveats. Citations point at
`.zcode/xdna-research/amd-tile-survey.md` line ranges per arch.

### 3.1 Tile-GCN

#### Hardware recap

GCN legacy (`amd-tile-survey.md:86-141`) has no matrix instruction.
Linear algebra is LDS-resident `ds_read_b32/b64/b128` plus scalar
`v_mul_f32` / `v_mad_f32` / `v_pk_add_f16` (Vega only). INT8 / FP8
not native matrix types; quantization requires dequantize-to-FP16 in
registers then FMA. GCN LDS is 64 KiB / CU, 32 banks, 4-byte words,
64-byte conflict granularity.

#### Tile shape + packing choice

`Tile-GCN-1x1xK-f16` is a scalar-ALU convention, not a hardware tile
- a software LDS layout convention aligning a contiguous `K`-element
run of one row to a 64-byte boundary. Recommended `K = 32` matches 8
LDS `b32` reads and `v_pk_add_f16` two-pair math on Vega.
`QK_AMD = 32` (no hardware constraint; chosen for power-of-two
shift-mask dequant). `packed` is a flat FP16 array
`[out_dim * in_dim]`. Trits + outliers transport resolves into FP16
at GGUF build time; no radix-243, no per-page scaling. The one
AMD-family tile that does NOT use the Apple 7-subtensor convention.

#### Quant type mapping

Transport's `{trits, awq_scale, page_scales, lane_scales, outliers}`
all map natively: packer dequantizes once at build and writes raw
FP16. Outlier side-channel collapses into the FP16 stream with
outlier values at CSR positions and zeros elsewhere. `act_scale`
applies to the input activation at compute time. No CPU-side dequant
emulation; everything is FP16 from the start.

#### Cluster tensor layout

7-subtensor collapses to 5 (the 2 scale suffixes drop): `_packed`
(`GGML_TYPE_F16`, `[out_dim * in_dim]`), `_outlier_row_offsets`
(`GGML_TYPE_I32`, `[out_dim + 1]`), `_outlier_cols` (`GGML_TYPE_I32`,
`[nnz]`), `_outlier_vals` (`GGML_TYPE_F16`, `[nnz]`), `_act_scale`
(`GGML_TYPE_F16`, `[in_dim]`, optional). Suffix convention preserved
so the loader probe `_packed` exists -> cluster works unchanged.

#### GGUF metadata extension

`amd.tile.arch = "GCN"`, `amd.tile.shape = "1x1x32"`,
`amd.tile.quant = "f16"`, `amd.tile.version = 2`,
`amd.tile.block = 32`.

#### ggml-side changes

`GGML_TYPE_TESSERA_T_GCN = 60` (next free enum slot after
`GGML_TYPE_TESSERA_T640 = 43` / `T640_3D = 44` / `T512 = 45` /
`T1024 = 46`; `ggml/include/ggml.h:433-436`). `GGML_OP_TILE_GCN_MATMUL
= 280` (peer of `GGML_OP_TILE640_*`). Dequant row
`dequantize_row_tessera_t_gcn` in `ggml/src/ggml-quants.h` next to
`dequantize_row_tessera_t640` (`ggml/src/ggml.c:945-960`) is a no-op
copy. Op handler `ggml_compute_forward_tile_gcn_matmul` in
`ggml/src/ggml-cpu/ops.cpp` (peer of `tile640_*` at line 11199).

#### CK / kernel dispatch

GCN does not use composable_kernel. Op handler is the scalar CPU
fallback. The stub at `ggml/src/ggml-amd/tile/tile_amd_matmul.cpp`
(12 lines, see `docs/backend/AMD.md:67`) is the right place for the
GCN scalar path when a HIP build runs on a GCN-class GPU (does not
happen in 2026 production).

#### Caveats

GCN pre-Vega (`gfx600..gfx803`) does not have `V_PK_*` packed math
(`amd-tile-survey.md:133-135`); on those targets the packer writes
FP32 because there is no hardware FP16 multiply. Add the sub-form
`Tile-GCN-1x1x32-f32` for `gfx803` and earlier. INT8 GEMM on GCN is
impractical at FP16 parity; the INT8 path is documented but not
shipped.

### 3.2 Tile-RDNA1 / 3.3 Tile-RDNA2 (legacy packed-math)

RDNA 1 (`amd-tile-survey.md:148-211`) and RDNA 2
(`amd-tile-survey.md:218-272`) share the same architecture: packed-math
DOT, no real tile instruction, no MFMA / WMMA, wave32, 8-wide K free
tile dimension, INT8 -> INT32 accumulator, no FP8 / INT4. The only
delta is the DOT width (DOT4 on RDNA 1, DOT8 on RDNA 2) and BF16
support (gfx1012-only on RDNA 1, all RDNA 2 parts).

#### Tile shape + packing choice

`Tile-RDNA1-4x4x4-i8|f16|bf16` (`QK_AMD = 4`),
`Tile-RDNA2-8x8x8-i8|f16|bf16` (`QK_AMD = 8`). Wire is lane-major,
INT8 per byte for INT8, 16-bit slot for FP16 / BF16; shape
`[out_dim * in_dim]`. M=4 / N=4 (RDNA 1) or M=8 / N=8 (RDNA 2)
achieved by `v_permlane` swaps. Lane-to-tile mapping is a software
convention, not a hardware constraint.

#### Quant type mapping

INT8 / FP16 map natively via DOT4 / DOT8. BF16: gfx1012-only on
RDNA 1; all RDNA 2 parts (`amd-tile-survey.md:209-211,247`). FP8
transport dequantized to FP16 in packer. INT4 transport packed
2-per-byte INT8 in wire (no native INT4 DOT on RDNA 1 / 2).

#### Cluster tensor layout

7-subtensor convention. `_packed` is `GGML_TYPE_I8` /
`GGML_TYPE_F16` / `GGML_TYPE_BF16`. `_page_scales` /
`_lane_scales` are zero placeholders (DOT K=4/8 no benefit).
Outlier CSR + act_scale verbatim.

#### GGUF metadata extension

RDNA 1: `amd.tile.arch = "RDNA1"`, `amd.tile.shape = "4x4x4"`,
`amd.tile.dot.width = 4`,
`amd.tile.quant = "i8" | "f16" | "bf16"` (gfx1012 only for bf16),
`amd.tile.version = 2`.

RDNA 2: `amd.tile.arch = "RDNA2"`, `amd.tile.shape = "8x8x8"`,
`amd.tile.dot.width = 8`,
`amd.tile.quant = "i8" | "f16" | "bf16"`, `amd.tile.version = 2`.

#### ggml-side changes

`GGML_TYPE_TESSERA_T_RDNA1 = 61`, `GGML_TYPE_TESSERA_T_RDNA2 = 62`.
Dequant rows `dequantize_row_tessera_t_rdna1` /
`_rdna2` are identity for INT8 / FP16 / BF16; BF16 on gfx1012 is
INT16 -> FP16 unpacks of 4 packed pairs. Op handlers
`ggml_compute_forward_tile_rdna1_matmul` /
`_rdna2_matmul` in `ggml-cpu/ops.cpp`.

#### CK / kernel dispatch

CK does not target RDNA 1 / 2. HIP kernels
`tile_amd_matmul_rdna1.cpp` /
`tile_amd_matmul_rdna2.cpp` emit `v_dot4_*` / `v_dot8_*` directly.
`DeviceGemm::Wmma<...>` is the closest CK match but does not match
DOT semantics; spec recommends writing the HIP kernel directly.

#### Caveats

DOT4 / DOT8 are packed math, not tile instructions; "Tile-RDNA?-*-*-*"
names are naming conventions. Wave64 emulation on wave32 hardware
requires two waves cooperating via LDS (how composable_kernel achieves
larger M/N on RDNA 2 per `amd-tile-survey.md:264-266`). INT8 GEMM on
RDNA 2 is half the throughput of INT8 GEMM on RDNA 3 WMMA because K
is 8 vs 16. BF16 only on gfx1012 (RDNA 1); packer must query
`amd.tile.gfx` and emit the correct quant or refuse to write.

### 3.4 Tile-RDNA3

#### Hardware recap

RDNA 3 (`amd-tile-survey.md:277-359`) introduces true WMMA
`V_WMMA_*` at `[16, 16, 16]` for FP16 / BF16 / INT8 / INT4 with F32
or INT32 accumulator. Wave32, dual-issue capable (effective 64-wide
for 16-bit ops per `amd-tile-survey.md:344-349`). VGPR usage per wave:
8/8/8 for FP16/BF16; 4/4/8 for INT8; 2/2/8 for INT4. OPSEL bit
selects which 16-bit half of the 32-bit VGPR is live. No FP8 on
GFX11, no TF32.

#### Tile shape + packing choice

`Tile-RDNA3-16x16x16-i8` / `-f16` / `-bf16` / `-i4`. `QK_AMD = 16`.
FIRST AMD-family tile where the wire matches a real hardware tile
instruction: packer writes INT8 (or FP16/BF16) values directly into
the WMMA lane layout, kernel emits a single WMMA without reshuffling.
Wire follows the AMD-published WMMA lane mapping for `[16, 16, 16]`:
each lane holds 8 elements of the 16x16 result tile (32 lanes x 8 =
256 result elements). Packer uses the RDNA 3 ISA Reference's
lane-to-element table for `[16, 16, 16]` INT8 / FP16 / BF16 / INT4
to scatter trits into the per-lane slots.

#### Quant type mapping

INT8 / FP16 / BF16 / INT4 all map natively via WMMA. FP8 transport
must be dequantized to FP16 before the wire (no FP8 WMMA on GFX11).
TF32 transport must be dequantized to FP32. INT4 transport is packed
2-per-byte INT8 at the wire level; the WMMA intrinsic
`wmma_i32_16x16x16_iu4` decodes the packed INT4 internally
(`amd-tile-survey.md:354-355`).

#### Cluster tensor layout

7-subtensor convention. `_packed` is `GGML_TYPE_I8` /
`GGML_TYPE_F16` / `GGML_TYPE_BF16` per the WMMA operand type.
`_page_scales` is f16 per WMMA-tile (16x16), `_lane_scales` is int8
per WMMA-lane (32 lanes per tile). Similar to Tile640's per-page /
per-lane scale fit (`tile640-surface-map.md:175-179`).

#### GGUF metadata extension

`amd.tile.arch = "RDNA3"`, `amd.tile.wmma.shape = "16x16x16"`,
`amd.tile.quant = "i8" | "f16" | "bf16" | "i4"`,
`amd.tile.version = 2`,
`amd.tile.lane_map = "rdna3-wmma-16x16x16"`.

#### ggml-side changes

`GGML_TYPE_TESSERA_T_RDNA3 = 63`. Dequant row
`dequantize_row_tessera_t_rdna3` applies page/lane scale then
casts to the WMMA operand type. Op handler
`ggml_compute_forward_tile_rdna3_matmul` (CPU reference; production
path is HIP/CK in `ggml-amd/tile/`).

#### CK / kernel dispatch

`composable_kernel::DeviceGemm::Wmma<ck::half_t, ...>` for FP16 /
BF16; `composable_kernel::DeviceGemm::Wmma<int8_t, ...>` for INT8.
RDNA3 WMMA pipeline gated on `hipDeviceGetAttribute` returning
`gfx1100` family; CK header
`composable_kernel/include/ck/tile_program/tile_program.hpp`.

#### Caveats

OPSEL on GFX11 selects which 16-bit half of the 32-bit VGPR is the
live tile; other half preserved on read for tied and undefined for
non-tied (`amd-tile-survey.md:350-352`). Packer must know tied vs
non-tied; for non-tied FP16 WMMA (f32 accum) OPSEL must be 0 and
the wire uses the full 32-bit VGPR slot. INT4 is WMMA-only; no INT4
DOT on RDNA 3. Dual-issue throughput (`amd-tile-survey.md:344-349`)
means the per-wave effective rate is 2x per-SIMD, but the wire
layout does not change.

### 3.5 Tile-RDNA4

#### Hardware recap

RDNA 4 (`amd-tile-survey.md:362-438`) extends WMMA: K doubled to 32
for FP16 / BF16 / INT8, quadrupled to 64 for INT4; FP8 (e4m3, e5m2)
WMMA at K=16; SWMMAC sparse with A-side 2:4 structure. OPSEL is gone
on GFX12 - all WMMA operands use the full 32-bit VGPR slot
(`amd-tile-survey.md:428`). LDS doubled to 256 KiB / CU. Lane-to-tile
mapping differs from RDNA 3; a kernel tuned for RDNA 3 WMMA cannot
be reused on RDNA 4 without remapping.

#### Tile shape + packing choice

`Tile-RDNA4-16x16x32-i8` / `-f16` / `-bf16` for K=32;
`Tile-RDNA4-16x16x64-i4` for INT4; `Tile-RDNA4-16x16x16-fp8` / `-bf8`
for FP8 / BF8. `QK_AMD = 32` for K=32, 64 for INT4, 16 for FP8. Wire
follows the GFX12 lane mapping from the AMD RDNA 4 ISA Reference.
For sparse `Tile-RDNA4-sparse-16x16x32-i8` (SWMMAC), the wire
carries an additional sparsity index per row of A; the cluster gains
an `_outlier_row_index` sub-tensor.

#### Quant type mapping

FP16 / BF16 / INT8 / INT4 / FP8 / BF8 all map natively via WMMA.
FP8 is the new RDNA 4 capability. SWMMAC requires 2:4 structured
sparsity in A; packer structures the trit transport into 2:4 sparse
blocks before the wire (no native sparse primitive on trits;
sparsity imposed at pack time).

#### Cluster tensor layout

7-subtensor convention (8 for sparse). `_packed` is
`GGML_TYPE_F8_E4M3` / `GGML_TYPE_F8_E5M2` / `GGML_TYPE_I8` /
`GGML_TYPE_F16` / `GGML_TYPE_BF16` per the chosen tile. Sparse
variant adds `<name>.weight_outlier_row_index` (int8, 2 per row) as
8th sub-tensor. Loader probes for the `_outlier_row_index` suffix and
routes to SWMMAC kernel if present.

#### GGUF metadata extension

`amd.tile.arch = "RDNA4"`,
`amd.tile.wmma.shape = "16x16x32" | "16x16x64" | "16x16x16"`,
`amd.tile.quant = "f16" | "bf16" | "i8" | "i4" | "fp8" | "bf8"`,
`amd.tile.sparse = "swmmac-2:4"` (when present),
`amd.tile.version = 2`,
`amd.tile.lane_map = "rdna4-wmma-..."` (per shape variant).

#### ggml-side changes

`GGML_TYPE_TESSERA_T_RDNA4 = 64`. Dequant row
`dequantize_row_tessera_t_rdna4` applies page/lane scale then casts
to FP8 / FP16 / BF16 / INT8 / INT4. Op handlers
`ggml_compute_forward_tile_rdna4_matmul` / `_matmul_sparse`.

#### CK / kernel dispatch

CK `DeviceGemm::Wmma<ck::fp8_e4m3_t, ...>` for FP8. CK sparse SWMMAC
gated on the `swmmac` CK tile program; if CK does not yet expose
SWMMAC, HIP fallback `tile_amd_matmul_rdna4_sparse.cpp` emits
`v_swmmac_*` directly.

#### Caveats

OPSEL is gone on GFX12. Packer MUST set OPSEL=0 implicitly by not
emitting tied variants (AMD ISA Reference marks tied variants as
deprecated on GFX12). Lane mapping for K=32 differs from RDNA 3
K=16; do not reuse RDNA 3 tuned kernels. FP8 on RDNA 4 is the first
consumer FP8 on AMD; SWMMAC sparsity is mandatory 2:4 structured -
packer must restructure trits to satisfy this or refuse to write
the sparse wire.

### 3.6 Tile-RDNA35 (alias)

RDNA 3.5 (`amd-tile-survey.md:441-479`) is process-shrunk RDNA 2 or
RDNA 3 silicon at the gfx target level: Strix Point / Strix Halo are
RDNA 3 (`gfx1150`/`gfx1151`); Phoenix is RDNA 3 (`gfx1103`);
Rembrandt is RDNA 2 (`gfx1035`). Matrix ISA identical to parent
arch. No new wire format. Strix Point / Strix Halo / Phoenix emit
`Tile-RDNA3-16x16x16-*`. Rembrandt emits `Tile-RDNA2-8x8x8-*`. Packer
selects wire based on gfx target: `gfx1103`/`gfx1150`/`gfx1151` ->
RDNA3 wire; `gfx1035` -> RDNA2 wire. The `amd.tile.arch = "RDNA35"`
key is informational; the wire is the parent's.

GGUF metadata: `amd.tile.arch = "RDNA35"`,
`amd.tile.parent = "RDNA3" | "RDNA2"`, `amd.tile.igpu = true`,
`amd.tile.version = 2`. Loader reads `amd.tile.parent` and routes to
the parent's dequant row function. No new `GGML_TYPE` enum value;
reuses `GGML_TYPE_TESSERA_T_RDNA3` (`=63`) or
`GGML_TYPE_TESSERA_T_RDNA2` (`=62`). Runtime selects the LDS-resident
build via a `RDNA35` flag passed to the kernel launcher. CK tile
program does not know about `RDNA35`; dispatch is on
`amd.tile.parent`.

Caveats: Rembrandt (`gfx1035`) is the trap - marketing name is
"RDNA 3.5" but ISA is RDNA 2, so the wire must be RDNA 2. Packer
must query the gfx target, not the marketing name. iGPU shared
memory bandwidth means the VRAM-staged Tile-RDNA3 wire will be
cache-bound on Strix Halo; runtime kernel selection must prefer
the LDS-resident variant when `amd.tile.igpu=true`.

### 3.7 Tile-CDNA1 / 3.8 Tile-CDNA2 (pre-FP8 MFMA)

CDNA 1 (`amd-tile-survey.md:482-556`) on `gfx908` (MI100) introduces
MFMA at `[32, 32, K]` for K=1/2/4/8 in FP32 / FP16 / BF16 / INT8 and
`[16, 16, K]` for K=4/16. CDNA 2 (`amd-tile-survey.md:559-611`) on
`gfx90a` (MI250X / MI210) adds MFMA `_1k` (single-pass BF16) variants
matching FP16 K (`amd-tile-survey.md:601-604`), and FP64 MFMA (not
used for LLM). Both archs share wave64, 4 SIMDs / CU, 512 VGPRs / SIMD,
64 KiB LDS / CU, 32 banks, no FP8, no INT4 native MFMA.

#### Tile shape + packing choice

CDNA 1: `Tile-CDNA1-32x32x8-f16` (FP16 F32 accum; standard HF tile),
`-32x32x8-i8`, `-32x32x4-bf16` (BF16 K halved vs FP16 per
`amd-tile-survey.md:548-550`), `-16x16x16-i8` (K=16 INT8).
`QK_AMD = 8` for FP16 / INT8, 4 for BF16, 16 for the 16x16x16. CDNA 2:
`Tile-CDNA2-32x32x8-f16` (carryover), `-32x32x8-bf16` (BF16 K=8 via
`_1k` single-pass), `-16x16x16-bf16` (BF16 K=16 matching FP16 shape),
`-32x32x8-i8`. `QK_AMD = 8` for `[32, 32, 8]`, 16 for `[16, 16, 16]`.
Wire follows gfx908 / gfx90a MFMA lane mappings per the respective ISA
Reference.

#### Quant type mapping

FP16 / BF16 / INT8 map natively via MFMA on both archs. On CDNA 2
BF16 at full K=8 / K=16 is native (no emulation). FP8 transport
must be dequantized to FP16. INT4 transport packed 2-per-byte INT8
and shifted at MFMA time (no native INT4 MFMA on either arch).

#### Cluster tensor layout

7-subtensor convention. `_packed` is `GGML_TYPE_F16` /
`GGML_TYPE_I8` / `GGML_TYPE_BF16` per chosen tile. `_page_scales` is
f16 per MFMA-tile (32x32 output, K=8 inner). `_lane_scales` is int8
per MFMA-lane (64 lanes per tile, each holding 8 elements of A and
8 of B).

#### GGUF metadata extension

CDNA 1: `amd.tile.arch = "CDNA1"`,
`amd.tile.mfma.shape = "32x32x8" | "32x32x4" | "16x16x16"`,
`amd.tile.quant = "f16" | "i8" | "bf16"`, `amd.tile.version = 2`,
`amd.tile.lane_map = "cdna1-mfma-..."`. CDNA 2: `amd.tile.arch =
"CDNA2"`, `amd.tile.mfma.shape = "32x32x8" | "16x16x16"`,
`amd.tile.quant = "f16" | "bf16" | "i8"`, `amd.tile.version = 2`,
`amd.tile.lane_map = "cdna2-mfma-..."`.

#### ggml-side changes

`GGML_TYPE_TESSERA_T_CDNA1 = 65`, `GGML_TYPE_TESSERA_T_CDNA2 = 66`.
Dequant rows `dequantize_row_tessera_t_cdna1` / `_cdna2` apply
page/lane scale then cast to MFMA operand type. Op handlers
`ggml_compute_forward_tile_cdna1_matmul` / `_cdna2_matmul`.

#### CK / kernel dispatch

CK `DeviceMFMA::Rowwise<ck::half_t, ck::half_t, ck::fp32_t, ...>`
for FP16 / BF16; `DeviceMFMA::Rowwise<int8_t, int8_t, ck::int32_t,
...>` for INT8. CK header
`composable_kernel/include/ck/tile_program/block_tile_program.hpp`
provides the static shape. MI100 / MI250X are in CK's tested-target
list. For MI250X GCD split, see
`composable_kernel/example/24_grouped_gemm` for the multi-device
pattern.

#### Caveats

MFMA on gfx908 / gfx90a is wave64 with a specific lane-to-tile-element
mapping (`amd-tile-survey.md:543-546`). The wire MUST follow this
mapping; any permlane cost is paid at every matmul. BF16 K is halved
vs FP16 at the same shape on gfx908 (`amd-tile-survey.md:548-550`)
but matches on gfx90a via `_1k`. LDS is 64 KiB / CU (smaller than
RDNA); tile staging must be careful with LDS pressure at large M/N.
MI250X 2-GCD: matmul needs explicit cross-GCD coordination via xGMI
peer-to-peer (`amd-tile-survey.md:608-610`). Wire format is per-GCD;
cross-GCD reduction is the runtime's responsibility. The `_1k` BF16
variants are the single-pass form; gfx908 BF16 emulation is slower
per `amd-tile-survey.md:602-604`.

### 3.9 Tile-CDNA3

#### Hardware recap

CDNA 3 (`amd-tile-survey.md:614-694`) on `gfx942` (MI300X): adds
FP8 (e4m3, e5m2) MFMA at `[16, 16, 32]` and `[32, 32, 16]` with
cross variants (fp8/fp8, fp8/bf8, bf8/fp8, bf8/bf8); adds SMFMAC
sparse MFMA with A-side 2:4 structure; doubles INT8 K to 32 at
`[16, 16, 32]`. xf32 ("extended FP32") for HPC tensor cores (not
relevant for LLM). MI300X has 6 chiplets (3 CCDs + HBM stacks via
fan-out packaging); MFMA runs only on CCDs (XCDs).

#### Tile shape + packing choice

`Tile-CDNA3-32x32x16-f16` / `-bf16` / `-i8` / `-fp8`,
`Tile-CDNA3-16x16x32-i8`, `Tile-CDNA3-16x16x8-xf32`,
`Tile-CDNA3-sparse-32x32x16-f16` (SMFMAC sparse). `QK_AMD = 16` for
`[32, 32, 16]`, 32 for `[16, 16, 32]`, 8 for xf32. Wire layout is
the gfx942 MFMA lane mapping; sparse variant carries an additional
sparsity index per row of A (the SMFMAC `index` parameter).

#### Quant type mapping

FP16 / BF16 / INT8 map natively; K-doubled INT8 (`[16, 16, 32]`) is
new on gfx942. FP8 / BF8 map natively with cross variants. xf32
maps natively for HPC. INT4 is packed 2-per-byte INT8 at MFMA time
(no native INT4 MFMA on gfx942 per `amd-tile-survey.md:684-687`).
Sparse via SMFMAC requires 2:4 structured sparsity.

#### Cluster tensor layout

7-subtensor convention; 8 for sparse. `_packed` is `GGML_TYPE_F16`
/ `GGML_TYPE_BF16` / `GGML_TYPE_I8` / `GGML_TYPE_F8_E4M3` /
`GGML_TYPE_F8_E5M2`. Sparse variant adds
`<name>.weight_outlier_row_index` (int8, 2 per row) as the 8th.

#### GGUF metadata extension

`amd.tile.arch = "CDNA3"`,
`amd.tile.mfma.shape = "32x32x16" | "16x16x32" | "16x16x8"`,
`amd.tile.quant = "f16" | "bf16" | "i8" | "fp8" | "bf8" | "xf32"`,
`amd.tile.sparse = "smfmac-2:4"` (when sparse),
`amd.tile.version = 2`, `amd.tile.lane_map = "cdna3-mfma-..."`.

#### ggml-side changes

`GGML_TYPE_TESSERA_T_CDNA3 = 67`. Dequant row
`dequantize_row_tessera_t_cdna3`. Op handlers
`ggml_compute_forward_tile_cdna3_matmul` and `..._matmul_sparse`.

#### CK / kernel dispatch

CK `DeviceMFMA::Rowwise<ck::fp8_e4m3_t, ck::fp8_e4m3_t, ck::fp32_t,
32, 32, 16, ...>` for FP8; `DeviceMFMA::Rowwise<ck::int8_t, ..., 32,
32, 16, ...>` for INT8. CK sparse SMFMAC is exposed as
`DeviceMFMA::Sparse<...>`; check
`composable_kernel/include/ck/tile_program/sp_tile_program.hpp`.

#### Caveats

FP8 cross variants: any (A_fp8, B_fp8 / B_bf8 / A_bf8, B_fp8 /
A_bf8, B_bf8) combination is a distinct intrinsic
(`amd-tile-survey.md:680-683`). Packer must select the combination
based on the B-side quant metadata. INT4 is packed into INT8 at
MFMA level. SMFMAC requires the sparsity index per row of A; the
wire carries this index. MI300X has 4 XCDs and HBM shared via Infinity
Fabric (`amd-tile-survey.md:690-693`); the runtime partitions the
matmul across XCDs.

### 3.10 Tile-CDNA4

#### Hardware recap

CDNA 4 (`amd-tile-survey.md:697-782`) on `gfx950` (MI350X / MI355X):
K-doubled FP16/BF16/INT8; introduces `mfma_scale_f32_*_f8f6f4`
microscaled MFMA at `[16, 16, 128]` and `[32, 32, 64]` where each
block has its own FP8 (E8M0) scale; SMFMAC sparse K-doubled.
LDS = 160 KiB / CU, 64 banks (doubled from gfx942). VGPR/SIMD
unchanged at 512. Bank-count change means layouts tuned for 32-bank
gfx942 need re-tuning for 64-bank gfx950.

#### Tile shape + packing choice

`Tile-CDNA4-32x32x16-f16` / `-bf16`, `Tile-CDNA4-32x32x32-i8`,
`Tile-CDNA4-16x16x32-fp8`, `Tile-CDNA4-16x16x64-i4` (INT4 K=64 via
INT8 packing), `Tile-CDNA4-16x16x128-f8f6f4-ms` (microscaled
FP4/FP6/FP8 K=128). `QK_AMD = 16` for `[32, 32, 16]`, 32 for
`[32, 32, 32]`, 32 for `[16, 16, 32]` FP8, 64 for `[16, 16, 64]` INT4,
128 for the microscaled family. Microscaled variant is the headline
tile: each 32-element block carries a per-block FP8 (E8M0) scale.

#### Quant type mapping

FP16 / BF16 / INT8 / FP8 / BF8 all map natively. INT4 is packed
2-per-byte INT8 (no native INT4 MFMA on gfx950). FP4 (e2m1) / FP6
(e2m3, e3m2) are NEW: the microscaled MFMA `mfma_scale_*_f8f6f4`
takes a per-block-modulated mix of FP4 / FP6 / FP8 with FP8 (E8M0)
scales (`amd-tile-survey.md:738-743`). Packer must select the matrix
element format per block and emit the corresponding `ModMatrixFmt`
encoding.

#### Cluster tensor layout

7-subtensor convention; 8 for sparse or microscaled. Microscaled
variant adds `<name>.weight_block_scales` (f16 / E8M0, one per
32-element block) as the 8th. Sparse variant adds
`<name>.weight_outlier_row_index` (int8) as its 8th. The two 8ths
can co-exist (microscaled + sparse) for a 9-subtensor cluster.

#### GGUF metadata extension

`amd.tile.arch = "CDNA4"`,
`amd.tile.mfma.shape = "32x32x16" | "32x32x32" | "16x16x32" | "16x16x64" | "16x16x128"`,
`amd.tile.quant = "f16" | "bf16" | "i8" | "i4" | "fp8" | "bf8" | "f8f6f4-ms"`,
`amd.tile.scale = "microscale" | "none"`,
`amd.tile.sparse = "smfmac-2:4" | "none"`, `amd.tile.version = 2`,
`amd.tile.lane_map = "cdna4-mfma-..."`,
`amd.tile.scale_block_size = 32`.

#### ggml-side changes

`GGML_TYPE_TESSERA_T_CDNA4 = 68`. Dequant row
`dequantize_row_tessera_t_cdna4` includes microscale block-scale
application when `amd.tile.scale=microscale`. Op handlers
`ggml_compute_forward_tile_cdna4_matmul` / `_matmul_sparse` /
`_matmul_microscale`.

#### CK / kernel dispatch

CK `DeviceMFMA::Rowwise<ck::bf16_t, ..., 32, 32, 16, ...>` for BF16
K=16. CK `DeviceMFMA::Scaled<...>` for the microscaled family (check
`composable_kernel` master for the `Scaled` tile program introduced
for gfx950). If CK does not yet expose `Scaled`, HIP fallback
`tile_amd_matmul_cdna4_microscale.cpp` emits `v_mfma_scale_*_f8f6f4`
directly.

#### Caveats

LDS bank count doubled (32 -> 64) on gfx950; layouts tuned for 32
banks need re-tuning (`amd-tile-survey.md:770-772`). Microscaled
intrinsics require per-block FP8 (E8M0) scales stored alongside the
matrix data; the tile-format layer carries the scales
(`amd-tile-survey.md:774-776`). FP4 / FP6 with microscaling is the
first AMD GPU with native sub-FP8 precision matrix math.

## 4. Cluster tensor convention

The Apple convention (`tessera-gguf-writer.cpp:64-136`) is 7
sub-tensors per weight, with suffixes: `_packed`, `_page_scales`,
`_lane_scales`, `_outlier_row_offsets`, `_outlier_cols`,
`_outlier_vals`, `_act_scale`. The AMD wires reuse this convention
so the loader-side probe logic (`create_tensor_or_tile640`) does not
change. Per-arch divergence:

| Suffix                        | Apple (T640) | GCN       | RDNA1/2          | RDNA3+ (incl. RDNA4, RDNA35) | CDNA1/2  | CDNA3 / CDNA4   |
|-------------------------------|--------------|-----------|------------------|-------------------------------|----------|-----------------|
| `_packed`                     | i32          | f16 / f32 | i8 / f16 / bf16  | i8 / f16 / bf16 / i4 / fp8 / bf8 | f16 / bf16 / i8 | adds fp8 / bf8 / xf32 / f8f6f4-ms |
| `_page_scales`                | f16          | **drop**  | placeholder f16  | f16                           | f16      | f16             |
| `_lane_scales`                | i8           | **drop**  | placeholder i8   | i8                            | i8       | i8              |
| `_outlier_row_offsets`        | i32          | i32       | i32              | i32                           | i32      | i32             |
| `_outlier_cols`               | i32          | i32       | i32              | i32                           | i32      | i32             |
| `_outlier_vals`               | f16          | f16       | f16              | f16                           | f16      | f16             |
| `_act_scale`                  | f16          | f16       | f16              | f16                           | f16      | f16             |
| `_outlier_row_index` (sparse) | n/a          | n/a       | n/a              | added for RDNA4 SWMMAC        | n/a      | added for CDNA3 SMFMAC, CDNA4 SMFMAC |
| `_block_scales` (microscaled) | n/a          | n/a       | n/a              | n/a                           | n/a      | added for CDNA4 `mfma_scale_*` |

Notes:

- `_packed` dtype changes from `GGML_TYPE_I32` (Apple radix-243) to
  the arch-native type. The loader probes `_packed` dtype to decide
  which dequant row function to call. A v1 client that does not know
  about the AMD `GGML_TYPE_*` values rejects with "unknown type" - this
  is the intended backward-compat boundary.
- `_page_scales` / `_lane_scales` are zero-filled placeholders on
  archs where coarse scales do not help (GCN, RDNA 1/2). The loader
  probes for the suffix's existence, not its content.
- `_outlier_row_index` is the SWMMAC / SMFMAC sparsity index: 2 bytes
  per row of A, encoding the positions of the 2 non-zero elements in
  each 4-element block (2:4 structured). Wire dtype `GGML_TYPE_I8`.
- `_block_scales` is the CDNA 4 microscale: one FP8 (E8M0) value per
  32-element block. Wire dtype `GGML_TYPE_F8_E8M0` (new type, see
  Open Question vi).
- `_packed` for `Tile-GCN-1x1xK-f32` (pre-Vega) is `GGML_TYPE_F32`,
  not F16, because there is no hardware FP16 multiply. Cluster suffix
  convention still applies.

The 7-subtensor convention is preserved on every arch for two
reasons: (1) the loader-side `create_tensor_or_tile640` probe is
suffix-based and not shape-based, so uniform suffix names are the
cheapest extension; (2) a v2 client reading a v1 GGUF (Apple Tile640)
already understands all 7 suffixes, so backward compat is symmetric.

## 5. Dispatch layer

The dispatch today (`quantize.cpp:1315-1345`) is 4-string enum
`t640 | t512 | t1024 | auto`. The detection today
(`tile-detect.cpp:68-112`) probes only Apple Metal
(`MTLGPUFamilyApple7..16`). The AMD dispatch extends both.

### 5.1 CLI dispatch

`ts_cli_pack` at `quantize.cpp:1315-1345` grows the `if/else` chain
to:

```
tile == "t640"        -> ts_tile_config_t640()
tile == "t512"        -> ts_tile_config_t512()
tile == "t1024"       -> ts_tile_config_t1024()
tile == "tile-amd-cdna2"     -> ts_tile_config_amd_cdna2()
tile == "tile-amd-cdna3"     -> ts_tile_config_amd_cdna3()
tile == "tile-amd-cdna4"     -> ts_tile_config_amd_cdna4()
tile == "tile-amd-rdna3"     -> ts_tile_config_amd_rdna3()
tile == "tile-amd-rdna4"     -> ts_tile_config_amd_rdna4()
tile == "tile-amd-cdna1"     -> ts_tile_config_amd_cdna1()
tile == "tile-amd-rdna2"     -> ts_tile_config_amd_rdna2()
tile == "tile-amd-rdna1"     -> ts_tile_config_amd_rdna1()
tile == "tile-amd-rdna35"    -> ts_tile_config_amd_rdna35()
tile == "tile-amd-gcn"       -> ts_tile_config_amd_gcn()
tile == "auto"               -> ts_detect_tile_config(); auto_detect=true;
```

The 12 `ts_tile_config_amd_*` factories live in
`ggml/src/ggml-common.h` next to the existing `ts_tile_config_t640`
factories (`ggml-common.h:235-261`). Each factory returns a
`ts_tile_config` with `packing = TS_PACK_AMD_<arch>` (new enum cases
added to `ts_packing_kind` at `ggml-common.h:222-225`). The
`tessera.tile.geometry` GGUF string metadata at
`quantize.cpp:1368-1369` is extended to write
`tile-amd-{cdna2,cdna3,...}` for the AMD wires.

### 5.2 Detection layer (auto)

`ts_detect_tile_config` at `tile-detect.cpp:68-112` grows from
Apple-only to AMD + Apple + Intel. The detection order:

1. Probe HIP (`hipDeviceGetCount`, `hipDeviceGet`, `hipDeviceGetAttribute
   hipDeviceAttributeGcnArch` / `hipDeviceAttributeName`). If a HIP
   device is present, dispatch to the AMD family of factories. If
   multiple HIP devices are present, prefer the discrete dGPU (skip
   iGPU unless no dGPU).
2. Probe Metal (`ggml_backend_metal_init` +
   `ggml_backend_metal_supports_family`). If a Metal device is present,
   dispatch to Apple or Intel based on the family.
3. Probe CUDA (the existing CUDA detection at `ggml-cuda.cu:2345-2350`
   is opaque to `ts_detect_tile_config`; `tile-detect.cpp` only knows
   about Metal today). The Tile640 wire works on CUDA via the existing
   `tile640-interleaved.cu`; no new AMD detection is needed for CUDA.
4. Fallback: `ts_tile_config_t640()`.

The HIP detection code lives in `tile-detect.cpp` next to
`ts_detect_apple_family` at line 42. New function
`ts_detect_amd_arch()` returns the gfx target string (`gfx942`,
`gfx1201`, etc.) and the dispatch maps gfx to `ts_tile_config_amd_*`.
Uses `hipDeviceGetAttribute` with `hipDeviceAttributeGcnArch` (ROCm
5.2+); for older ROCm, fall back to parsing `hipDeviceGetName` and a
hardcoded mapping table (Navi 31 -> gfx1100, etc.).

### 5.3 Multi-device case (Strix Halo + R9700)

The trap case: a workstation with both an integrated RDNA 3.5
(Strix Halo, gfx1151) and a discrete RDNA 4 (R9700, gfx1201). The
HIP runtime exposes both as `hipDevice_t` entries 0 and 1. The
detection layer must:

1. Probe all HIP devices, get the gfx target per device.
2. Pick the most capable matrix-instruction-supporting arch.
   R9700 (RDNA 4) > Strix Halo (RDNA 3.5) for matrix throughput.
3. The wire emitted by the packer is for the picked arch.
4. The runtime (HIP loader) knows the wire and dispatches the kernel
   to the picked device. If the model is too large for the picked
   device's VRAM (Strix Halo has 128 GB unified but slower than
   R9700's 32 GB GDDR7), the user can re-pack with
   `--tile=tile-amd-rdna35` for the iGPU-only path.

The detection layer does NOT auto-split the matmul across iGPU and
dGPU; that is a future hetero feature (`docs/backend/AMD.md:1-3`
references the plan `.agents/plans/2026-08-08-tile-amd-hetro.md` but
it is W1-7 and not in this spec). For now: one wire per GGUF, picked
at pack time.

## 6. Trit -> arch-native translation

The neutral transport (`tile640-surface-map.md:14-58`) carries
trits (`{-1, 0, +1}`, `GGML_TYPE_I8`), outlier CSR
(`outlier_row_offsets`, `outlier_cols`, `outlier_vals`), and three
host-side scale vectors (`awq_scale`, `awq_input_scale`,
`act_scale`). The packer reads the trits and writes the arch-native
wire. The translation from trits to wire is the core algorithm
change.

### 6.1 Common recipe

For every AMD arch, the packer:

1. Reads `trits[r, c]` for each element.
2. Applies the outlier side-channel: where an outlier exists
   (`outlier_row_offsets[r] <= i < outlier_row_offsets[r+1]`),
   the trit is zeroed and the outlier value
   `outlier_vals[k] * awq_scale[c]` is the effective magnitude.
3. Computes the per-arch block scale: `QK_AMD` elements along K
   share a single scale.
4. Casts to the arch-native wire: INT8 / FP16 / BF16 / INT4 / FP8 /
   BF8.
5. Stores in the lane order mandated by the AMD ISA Reference for
   the chosen matrix instruction.

### 6.2 Per-arch translation

#### Tile-GCN-1x1x32-f16

Trit -> FP16 directly. `wire[r, c] = (trits[r, c] == 0 ?
outlier_value[r, c] : trits[r, c] * page_max[r, c / 32]) * lane_scale[r,
c / 32] / 127 * awq_scale[c]`. Wire dtype `GGML_TYPE_F16`. No
radix-243, no per-page scale (page scales are zero placeholders).

#### Tile-RDNA1-4x4x4-i8 / Tile-RDNA2-8x8x8-i8

Trit -> INT8 directly, then the DOT4 / DOT8 lane mapping is applied.
The K-elements per lane are stored in lane-major order: lane 0 holds
trits[r, c..c+K-1], lane 1 holds trits[r, c+K..c+2K-1], etc. Wire
dtype `GGML_TYPE_I8`. Per-page and per-lane scales are zero
placeholders. BF16 wire: dtype `GGML_TYPE_BF16`.

#### Tile-RDNA3-16x16x16-i8 / Tile-RDNA4-16x16x32-i8

The first archs where the wire matches the WMMA lane mapping. Packer
scatters trits into the WMMA `[16, 16, K]` lane slots per the AMD
RDNA 3 / RDNA 4 ISA Reference's lane-to-element table. `_packed` is
`GGML_TYPE_I8` with the WMMA lane order (K=16 for RDNA 3, K=32 for
RDNA 4 - lane table differs). Per-page scale: f16, one per
`[16, 16]` output tile column. Per-lane scale: int8, one per WMMA
lane (32 per tile). Dequant at compute time:
`int8_value = trit * page_max * lane_scale / 127 * awq_scale`. For
FP16 / BF16 wires, same logic but `_packed` dtype is `GGML_TYPE_F16`
/ `GGML_TYPE_BF16` and the WMMA lane mapping is for 16-bit operands.
For FP8 wires (`Tile-RDNA4-16x16x16-fp8`), the packer converts the
magnitude-scaled INT8 -> FP8 (e4m3) before the wire; wire dtype is
`GGML_TYPE_F8_E4M3`. For sparse wires (RDNA 4 SWMMAC), the packer
first structures trits into 2:4 sparse blocks, then writes the sparse
index per row of A as `_outlier_row_index`.

#### Tile-CDNA1 / CDNA2 / CDNA3 (MFMA)

Packer scatters trits into the MFMA `[M, N, K]` lane slots per the
CDNA ISA Reference (gfx908, gfx90a, gfx942 respectively). `_packed`
dtype is `GGML_TYPE_F16` / `GGML_TYPE_BF16` / `GGML_TYPE_I8` /
`GGML_TYPE_F8_E4M3` / `GGML_TYPE_F8_E5M2` per the chosen tile. Per
MFMA-tile: `_page_scales` is f16; per MFMA-lane: `_lane_scales` is
int8 (64 lanes per tile on CDNA). For CDNA 3 FP8, the packer picks
the (A_quant, B_quant) cross variant based on `amd.tile.quant_a` and
`amd.tile.quant_b` (new metadata keys when the cross variants are in
use). For sparse wires (CDNA 3 SMFMAC), the packer structures trits
into 2:4 sparse blocks and writes `_outlier_row_index`.

#### Tile-CDNA4-16x16x128-f8f6f4-ms (microscaled)

The packer: (1) groups K=128 elements into 32-element blocks (4
blocks per tile row); (2) for each block, computes the per-block
FP8 (E8M0) scale as the maximum absolute value divided by the FP8
(e4m3 / e5m2) max; (3) quantizes each element to the
per-block-modulated FP4 / FP6 / FP8 (the `ModMatrixFmt` field per
`amd-tile-survey.md:743`); (4) writes the per-block scale as
`_block_scales`; (5) writes the quantized elements as `_packed`
with the MFMA `[16, 16, 128]` microscaled lane mapping. The MFMA
`mfma_scale_f32_16x16x128_f8f6f4` intrinsic
(`amd-tile-survey.md:725-728`) takes the matrix data and the
block-scale vector as separate arguments; the wire format exposes
both.

### 6.3 What stays host-side

The `awq_scale` and `awq_input_scale` and `act_scale` vectors stay
host-side. They are not packed into the wire; they are written as the
`_act_scale` sub-tensor (carried verbatim from the transport, same
as the Apple path per `tile640-surface-map.md:48-56`). The `core`
and `global_amp` are also host-side: the packer uses them to fit the
per-page / per-lane scales but does not write them to the GGUF.

## 7. Code change summary

### 7.1 `ggml/src/ggml-common.h`

- Add `ts_packing_kind` cases `TS_PACK_AMD_GCN`, `TS_PACK_AMD_RDNA1`,
  `_RDNA2`, `_RDNA3`, `_RDNA4`, `_CDNA1`, `_CDNA2`, `_CDNA3`,
  `_CDNA4` (extending the enum at line 222-225).
- Add `ts_tile_config_amd_gcn()`, `_rdna1()`, `_rdna2()`, `_rdna3()`,
  `_rdna4()`, `_cdna1()`, `_cdna2()`, `_cdna3()`, `_cdna4()`,
  `_rdna35()` factories (peer of `_t640`/`_t512`/`_t1024` at line
  235-261). Each returns a `ts_tile_config` with the per-arch
  page/lane geometry and the new `packing` enum value.
- Add an `arch_target` field to `ts_tile_config` (optional; see
  Open Question v): an enum of the 10 archs. The Apple
  `ts_tile_config_t640()` returns `arch_target = TS_ARCH_APPLE`.

### 7.2 `ggml/include/ggml.h`

- Add `GGML_TYPE_TESSERA_T_GCN = 60` through `GGML_TYPE_TESSERA_T_CDNA4 = 68` (peer of `T640 = 43` / `T640_3D = 44` / `T512 = 45` / `T1024 = 46` at line 433-436). See Open Question i for the alternative of collapsing to one typed tensor.
- Add `GGML_OP_TILE_*_MATMUL` op enum cases (peer of `TILE640_*` at line 590-593; one per arch).

### 7.3 `ggml/src/ggml-quants.h` + `ggml/src/ggml.c`

- Add `dequantize_row_tessera_t_{gcn,rdna1,rdna2,rdna3,rdna4,cdna1,cdna2,cdna3,cdna4}` declarations (peer of `dequantize_row_tessera_t640` at line 945-960).
- Add `quantize_row_tessera_t_*_ref` reference quantization functions for the GA quantizer (`docs/backend/AMD.md:63`).
- Add `is_quantized` row entries pointing at the new dequant functions.

### 7.4 `ggml/src/ggml-cpu/ops.cpp`

- Add `ggml_compute_forward_tile_{gcn,rdna1,...,cdna4}_matmul` (peer of `ggml_compute_forward_tile640_*` at line 11199). These are the scalar CPU reference paths used for correctness validation and for non-AMD fallback.

### 7.5 `ggml/src/ggml-amd/tile/`

Extend the stub at `tile_amd_matmul.cpp` (12 lines, see `docs/backend/AMD.md:67`) into per-arch files: `tile_amd_matmul_{gcn,rdna1,rdna2,rdna3,rdna4,rdna4_sparse,cdna1,cdna2,cdna3,cdna3_sparse,cdna4,cdna4_microscale}.cpp`. **All AMD tile kernels in this directory are tessera-original.** No AITER / vLLM `.cu` or `.h` is vendored; the AITER gfx1103 work at `/home/x/vllm-aiter-gfx1103/` is studied as a reference only (tile geometry, Triton tile-config heuristics, RMSNorm interleaved-load fix, runtime-gate pattern), not lifted. The headline GEMM primitive for every arch comes from Composable Kernel's `DeviceGemm` family (MIT, vendored per Section 9(vi)). For Tile-RDNA3 that is `composable_kernel::DeviceGemm::Wmma<int8_t|half_t|bf16_t, 16, 16, 16, ...>` via the `ck_tile/core/arch/mma/wmma/wmma_gfx11.hpp:56` wrapper. `tile_amd_matmul_ck()` is the common dispatcher; per-arch `#ifdef`s select the implementation based on the detected gfx target.

### 7.6 `tools/quantize/tessera/tessera-quant.cpp`

Extend `ts_pack_ternary_to_tile` at line 1150-1206 with a `switch (config.packing)` dispatch into per-arch helpers: `ts_pack_ternary_to_tile_{gcn,rdna1,rdna2,rdna3,rdna4,rdna35,cdna1,cdna2,cdna3,cdna4}`. Each reads `tn.trits` + `tn.outlier_*` + `tn.awq_scale` and writes `result->packed` (and the per-arch page/lane scales) in the arch-native layout.

### 7.7 `tools/quantize/tessera/tessera-gguf-writer.cpp`

Extend `ts_gguf_write_tensor_cluster` at line 64-136 with the AMD `amd.tile.*` metadata writes. The cluster tensor dtypes are decided by the `ts_tile_config.packing` field. The 7-subtensor convention is preserved (per Section 4). Optional `_outlier_row_index` and `_block_scales` sub-tensors emit only for sparse / microscaled wires.

### 7.8 `tools/quantize/tessera/tile-detect.cpp`

Add `ts_detect_amd_arch()` next to `ts_detect_apple_family` at line 42. The function probes HIP devices via `hipDeviceGetCount` / `hipDeviceGetAttribute(..., hipDeviceAttributeGcnArch)` and returns the gfx target string. Extend `ts_detect_tile_config` at line 68 to dispatch on HIP first, Apple Metal second, T640 last.

### 7.9 `tools/quantize/quantize.cpp`

Extend the `if/else` chain at line 1330-1345 with the 12 new `tile == "tile-amd-*"` cases. Extend `tessera.tile.geometry` write at line 1368-1369 with the `tile-amd-*` string values.

### 7.10 `ggml/src/ggml-amd/ggml-amd.cpp`

Replace the `op_table_amd` at `docs/backend/AMD.md:69` with a
registry-driven dispatcher. `ggml_compute_forward_tile_*_matmul`
op handlers consult `tile_amd_op_registry_lookup(arch_target,
dtype, sparse?, microscale?, M, N, K)` instead of running a
compile-time `__gfx1103__` / `__gfx94__` ifdef cascade. The
returned function pointer is invoked with
`(A_packed, B, C, scales, M, N, K)`. The CSV
`tools/quantize/tessera/configs/tile_amd_kernels.csv` (Section
8.1a) populates the registry's data tables at first GPU init.

For archs that don't yet have CSV rows (CDNA1 / CDNA2 / RDNA1 /
RDNA2 / GCN / RDNA35), the dispatcher falls back to the scalar
CPU reference path in `ggml-cpu/ops.cpp:11199` rather than the
empty registry. This makes the empty-CSV Wave A.1 state safe to
ship and matches the Section 9(iv) fall-through contract.

The registry key structure and CSV schema are specified in
Section 11.8; the `arch_target` resolution comes from
`tile-detect.cpp`'s `ts_detect_amd_arch` (§7.8).

## 8. Rollout phasing

The rollout mirrors production-relevance ordering: CDNA 2 MI250X /
MI210 first (most shipped today), then consumer dGPUs (RDNA 3 /
RDNA 4), then latest CDNA (MI300X / MI355X), then legacy archs.

### 8.1 Wave A: dispatch + detection (P0)

Ship: extend `ts_tile_config` with `arch_target` (or keep `packing` as dispatcher; see Open Question v); extend `tile-detect.cpp` with HIP detection (`ts_detect_amd_arch`); extend `quantize.cpp:1315-1345` with the 12 new `tile-amd-*` options; extend `ts_gguf_write_tensor_cluster` with the `amd.tile.*` metadata writes. No actual tile kernels; the user can `--tile=tile-amd-cdna2` and get a GGUF that says "I am Tile-CDNA2" but the runtime falls back to the scalar CPU path because there is no CK kernel yet. Acceptance: pack a 1-layer model with each of the 12 `tile-amd-*` options; the GGUF has the right `amd.tile.arch` / `amd.tile.mfma.shape` / `amd.tile.quant` keys; the v1 loader (Tile640-only) rejects the AMD GGUF with "unknown type" on `_packed`.

**Wave A also ships the op registry + CSV skeleton** (Section
7.5 / 7.10 / 11.8). The detector hands the runtime an `arch_target`
+ `(dtype, sparse, microscale, M, N, K)` tuple; the dispatcher
queries the registry; the registry reads from the empty CSV and
falls back to the scalar reference path. From Wave B onward, CSV
rows appear as the autotune sweep fills them in.

### 8.1a Wave A.1: op registry + CSV skeleton

Independent sub-wave that has to ship before any kernel that
wants to dispatch across `(arch, dtype, shape)` combinations.
Three artifacts:

1. `ggml-amd/registry/tile_amd_op_registry.{h,cpp}` — C-side
   keyed lookup. Header key is
   `(arch_target, dtype, sparse, microscale, M, N, K)`. Returns
   a `tile_amd_kernel_t` function pointer plus a precompiled
   binary path. Mirrors AITER's `SMEM_CAPACITY_MAP` gating shape
   (study reference: `aiter/aiter/ops/flydsl/utils.py:79-84`).
2. `tools/quantize/tessera/configs/tile_amd_kernels.csv` —
   per-arch measurement table. Columns:
   `arch, dtype, sparse, microscale, M, N, K, BM, BN, BK, stages,
   epilog, kernelName, anchor_hash`. Empty in Wave A.1;
   populated by Wave B-I measurement campaigns. Mirrors the
   shape of AITER's
   `aiter/aiter/configs/model_configs/gptoss_a16w4_tuned_fmoe.csv:2`
   (study reference). `anchor_hash` is a content fingerprint of
   the `(arch, dtype, ...)` row used to know when a re-tune is
   needed.
3. `tools/quantize/tessera/scripts/build_amd_kernels.py` — AOT
   precompile driver. Reads the CSV, instantiates the CK
   pipeline per `(arch, dtype, shape)` row, and produces
   per-arch `.bin` artifacts that the runtime loads. Mirrors
   the shape of AITER's `FLYDSL_GPU_ARCH` cross-compile env
   pattern at `aiter/aot/flydsl/moe.py:1034-1045` (study
   reference).

Wave A.1 does not vend AITER source. The mirroring is structural
("one CSV row -> one compiled kernel binary"), not code.

### 8.2 Wave B: Tile-CDNA2 (P1)

Ship `Tile-CDNA2-32x32x8-f16` / `-bf16` / `-i8` packs and kernels, CK `DeviceMFMA::Rowwise<ck::half_t, ..., 32, 32, 8, ...>` for FP16 (equivalent for BF16 / INT8), `GGML_TYPE_TESSERA_T_CDNA2 = 66` + dequant + op handler. **Wave B is also the first wave that fills in `tile_amd_kernels.csv` rows for gfx90a**; the autotune sweep runs once per dtype × shape combination and the results are committed alongside the kernel source. Acceptance: pack a small model with `--tile=tile-amd-cdna2`, load via `ggml-amd` backend, run a forward pass on MI250X, compare cosine / Frobenius against the BF16 reference (`docs/PROJECT-STATUS.md` Layer 4/5 criteria). Target: parity within 1% relative Frobenius; throughput at least 1.5x of scalar fallback.

### 8.3 Wave C: Tile-RDNA3 (P1)

Ship `Tile-RDNA3-16x16x16-i8` / `-f16` / `-bf16` / `-i4`, HIP / CK
WMMA pipelines, `GGML_TYPE_TESSERA_T_RDNA3 = 63`. **Implementation
source: tessera-original kernels built on top of Composable Kernel.**
The headline GEMM is a tessera file in `ggml-amd/tile/tile_amd_matmul_rdna3.cpp`
that wraps `composable_kernel::DeviceGemm::Wmma<...>` routed via the
`wmma_gfx11.hpp:56` wrapper. Trit -> INT8 / FP16 / BF16 / INT4
packing (Section 6.2) and the per-tile / per-lane scale fit are
written from scratch in `tools/quantize/tessera/tessera-quant.cpp`.

**Reference study only:** the AITER gfx1103 joint workspace at
`/home/x/vllm-aiter-gfx1103/` is consulted as a published record of
how RDNA3 was solved end-to-end. We do NOT vendor any AITER
`.cu` / `.h` / `.py` source. Specifically we read for guidance:

1. The four first-class gfx1103 ops +
   `turboquant_k3v4_gfx1103.cu` for what a finished RDNA3 kernel
   stack looks like (tile geometry, fused activations, scratch
   buffers).
2. The Triton RDNA3 attention configs in
   `aiter/aiter/ops/triton/attention/unified_attention.py:65-140`
   and `aiter/aiter/ops/triton/configs/gemm/gfx1103-GEMM-A16W16*.json`
   for measured `BLOCK_M` / `TILE_SIZE` / `num_warps` /
   `num_stages_2d` / `waves_per_eu` defaults under the 12-CU /
   64-KB-LDS / UMA-DDR5 gfx1103 constraint
   (`unified_attention.py:90-98`).
3. The runtime-gate pattern
   `gfx1103_*_supported() => get_gfx_runtime() == "gfx1103"` at
   `aiter/aiter/ops/fp8_gfx1103.py:33` for the architecture
   check; tessera mirrors the same `#ifdef __gfx11__` (covered by
   `composable_kernel/include/ck/ck.hpp:70-74`) plus a runtime
   `get_gfx_runtime()` call when dispatch falls back from
   compile-time `__gfx1103__`.
4. The RMSNorm interleaved-load disable on GFX11
   (`aiter/aiter/ops/rmsnorm.py:388-403`): the prior AITER
   interleaved-store kernel corrupted every 8th element on gfx1103.
   Tessera's RMSNorm/quant fusion, if any, must gate the
   interleaved variant off under `__gfx11__`.

Acceptance: same as Wave B but on RX 7900 XTX. Throughput target:
2x scalar fallback. Plus: parity against the scalar CPU reference
(`ggml-cpu/ops.cpp:11199`) within 1% relative Frobenius; L1/L2/L6
audit gates per `docs/PROJECT-STATUS.md`.

**Gap noted for Wave H:** AITER covers **gfx1103 only**, not
`gfx1150-1153` (RDNA35). Wave C ships gfx1103 + the
compile-time `__gfx11__` family; Wave H (Section 8.8) tests the
same kernel on RDNA35 and patches the C-distribution permutation
differences flagged at
`composable_kernel/include/ck_tile/ops/fmha/block/block_dropout.hpp:67`
and
`composable_kernel/include/ck_tile/core/arch/mma/mma_wavewise.hpp:1519`.

### 8.4 Wave D: Tile-CDNA3 (P1)

Ship `Tile-CDNA3-32x32x16-f16` / `-i8` / `-fp8` / `-bf8` + sparse, CK `DeviceMFMA::Rowwise<ck::fp8_e4m3_t, ..., 32, 32, 16, ...>`, sparse SMFMAC kernel, `GGML_TYPE_TESSERA_T_CDNA3 = 67`. Acceptance: on MI300X. FP8 path is headline; INT8 path must be at least parity with scalar fallback.

### 8.5 Wave E: Tile-CDNA4 (P1)

Ship `Tile-CDNA4-32x32x16-f16` / `-bf16` / `-i8` / `-fp8` + sparse + microscaled, 8th sub-tensor `_block_scales`, `GGML_TYPE_TESSERA_T_CDNA4 = 68` + `_microscale` op handler. Acceptance: on MI355X. Microscaled FP4/FP6 path is headline; FP16 path must be parity.

### 8.6 Wave F: Tile-RDNA4 (P1)

Ship `Tile-RDNA4-16x16x32-i8` / `-f16` / `-bf16` / `-fp8` / `-bf8` + sparse, `GGML_TYPE_TESSERA_T_RDNA4 = 64`. Acceptance: on RX 9070 XT. FP8 is new for AMD consumer; INT8 K=32 is new for RDNA.

### 8.7 Wave G: Tile-RDNA2 / Tile-RDNA1 (P2)

Ship the legacy consumer packed-math wires. RDNA 2 first (more common), RDNA 1 second. Acceptance: on RX 6900 XT (RDNA 2) and RX 5700 XT (RDNA 1).

### 8.8 Wave H: Tile-RDNA35 (P2)

Ship the alias wire for Strix Halo / Strix Point / Phoenix / Rembrandt. Acceptance: on Strix Halo (gfx1151) and Rembrandt (gfx1035). The Rembrandt case must select the RDNA 2 wire (`amd.tile.parent = RDNA2`) per Section 3.6 caveat.

### 8.9 Wave I: Tile-GCN (P3)

Ship the scalar ALU wire for legacy GCN. Last priority because no production LLM inference runs on GCN in 2026. Acceptance: on a Polaris / Vega part if available; otherwise the acceptance test is the GGUF being readable by the scalar CPU path with correct numeric output.

## 9. Open questions

### (i) Single typed tensor vs 7-subtensor cluster

The Apple path (`tessera-gguf-writer.cpp:64-136`) uses 7 sub-tensors
per weight with the suffix convention. The AMD paths in this spec
reuse the convention (Section 4) for loader-side probe compatibility.
Alternative: collapse the cluster into a single typed tensor (one per
arch, dtype = the arch-native wire) plus the outlier CSR as separate
sub-tensors. Pro: simpler loader, fewer GGUF entries, no
suffix-convention drift. Con: cluster writer and repoint helper
(`tessera-gguf-writer.cpp:138-182`) both need rewrite; Apple path
cannot adopt single-tensor form without losing backward compat with
v1 Tile640 GGUFs. Decision deferred to Wave A. Spec recommendation:
keep the 7-subtensor convention for symmetry with Apple; 8th and 9th
sub-tensors for sparse / microscaled are additive.

### (ii) `*-dsa` KV-cache sparsity interaction

The `*-dsa` (DeepSeek Sparse Attention) variants (`src/dsa*`) and
`*-dsv4` use sparse KV cache lookups. The tile format stores the
weight matrix, not the KV cache, so there is no direct interaction.
At the matmul level: WMMA / MFMA tile shapes are static `[M, N, K]`
and assume dense A and B operands. `*-dsa` sparsity is in the KV
cache access pattern, not in the matmul operands. Tile format does
not need to change.

### (iii) `QK_AMD = 64` per-arch vs single value

The existing stub (`docs/backend/AMD.md:54-58`) proposes
`QK_AMD = 64` as a single value for all AMD archs. This spec
rejects that: the value must be a multiple of the K dimension of the
chosen matrix instruction (`amd-tile-survey.md:825-835` per-arch
recommendation), which varies from 4 (RDNA 1 DOT4) to 128 (CDNA 4
microscaled MFMA). A `QK_AMD = 64` would be the right block size
for the CDNA 4 INT8 K=64 path but wrong for RDNA 1 (K=4). Decision:
per-arch `QK_AMD` values per Section 2 dispatch table. The
`amd.tile.block` GGUF key carries the per-arch value.

### (iv) CK header / template dependencies

CK library functions this spec references are in
`composable_kernel/include/ck/tile_program/` (master, 2026-08-15):
`block_tile_program.hpp` for `DeviceMFMA::Rowwise`; `tile_program.hpp`
for `DeviceGemm::Wmma`; `sp_tile_program.hpp` for
`DeviceMFMA::Sparse` (SMFMAC); `scaled_tile_program.hpp` for
`DeviceMFMA::Scaled` (CDNA 4 microscaled) - if this header does not
exist yet, the HIP fallback emits `v_mfma_scale_*_f8f6f4` directly.
CK source is vendored into `ggml-amd/ck/` per `docs/backend/AMD.md:28`
(Q2 decision). Missing headers block the corresponding wave.

### (v) Per-arch dispatch key in `ts_tile_config`

The current `ts_tile_config` (`ggml-common.h:227-233`) carries
`packing` (an enum with 2 cases today). Extension options:

- (a) Extend `packing` with 11 new cases (one per AMD arch). Pro:
  keeps the struct unchanged. Con: overloads `packing` with arch
  semantics; future per-arch packing variants for the same arch
  would need a new field.
- (b) Add `arch_target` field to `ts_tile_config` as a new enum
  (`TS_ARCH_APPLE | TS_ARCH_INTEL | TS_ARCH_AMD_GCN | ... |
  TS_ARCH_AMD_CDNA4`). Pro: orthogonal to packing. Con: struct
  extension is a wire-format change for any saved `ts_tile_config`
  (none exist outside the running process today).

**Decision (binding, 2026-08-15): option (b).** The tessera AMD
registry architecture (Section 11.8) makes `arch_target`
first-class so the dispatcher can key on
`(arch_target, dtype, sparse, microscale, M, N, K)`. The
struct extension is safe (no saved `ts_tile_config` outside the
running process) and the orthogonal separation between
`packing` (wire format) and `arch_target` (dispatch target) is
the only sustainable shape as the per-arch family grows from 10
to 10+ entries with combinatorially-many dtype / sparse /
microscale variants.

### (vi) Licensing for CK + the AITER reference posture

CK is licensed MIT
(`composable_kernel/LICENSE:9-10`: `SPDX-License-Identifier: MIT,
Copyright (c) 2018-2025, Advanced Micro Devices, Inc. All rights
reserved.`). The earlier Apache 2.0 attribution in this spec was
incorrect; CK has been MIT since the rocm-libraries relicense in
2024. MIT is fully compatible with tessera's `LICENSE-TESSERA`
noncommercial + upstream MIT (`AGENTS.md` header). The vendoring
decision (`docs/backend/AMD.md:27-28`) keeps CK in-tree under
`ggml-amd/ck/`; no `ExternalProject_Add(aiter)`.

The AITER gfx1103 work is **referenced, not vendored** (Section
11). Concretely: no AITER `.cu`, `.h`, or `.py` is copied into
the tessera tree, so there is no `Copyright (C) 2024-2026,
Advanced Micro Devices, Inc.` line in
`ggml-amd/THIRDPARTY-NOTICES` and no FlyDSL Apache-2.0 subset to
reconcile with `LICENSE-TESSERA`. The AITER workspace is a
published reference at `/home/x/vllm-aiter-gfx1103/`, and the
mapping in `/home/x/vllm-aiter-gfx1103/MAP.md` records the
lessons we took from it (RMSNorm interleaved-load fix, Triton
12-CU / 64-KB-LDS tuning, runtime-gate pattern). Those lessons
guide tessera's original code; they do not create a distribution
obligation.

CK FP8 type names (`ck::fp8_e4m3_t`, `ck::fp8_e5m2_t`,
`ck::fp8_e8m0_t`) live in
`composable_kernel/include/ck/utility/data_type.hpp`; GGML side
needs matching enum values (`GGML_TYPE_F8_E4M3`,
`GGML_TYPE_F8_E5M2`, `GGML_TYPE_F8_E8M0`). Adding these to
`ggml/include/ggml.h` is part of Wave E.

### (vii) Backward compat

- A v1 client (Apple Tile640 only) reading a v2 GGUF (AMD wire) sees
  `<name>.weight_packed` with dtype `GGML_TYPE_I8` / `GGML_TYPE_F16`
  / etc., which the v1 client's enum does not know. Loader rejects
  with `TENSOR_NOT_REQUIRED` style "unknown type". This is the
  intended boundary: AMD tiles are explicitly tagged with
  `amd.tile.arch` and a v1 client is expected to refuse.
- A v2 client (Tile640 + Tile-AMD) reading a v1 GGUF (Apple Tile640)
  sees the Apple 7-subtensor cluster with dtype `GGML_TYPE_I32` on
  `_packed`. v2 client recognizes `GGML_TYPE_TESSERA_T640 = 43` and
  uses the existing Tile640 path. New `amd.tile.*` keys are absent
  on v1 GGUFs and the v2 client tolerates the absence.
- `tessera.version` GGUF key bumped to 2 when any `amd.tile.*` key
  is present; v1 GGUFs have `tessera.version = 1`.

The v1 / v2 boundary is: any `amd.tile.*` key implies v2; absence
implies v1 Apple Tile640.

## 10. References

### Tessera-side

- `.zcode/xdna-research/tile640-surface-map.md:14-58` - neutral
  transport struct + on-disk shape
- `.zcode/xdna-research/tile640-surface-map.md:101-229` - Tile640
  (Apple) wire format, GGUF metadata, cluster writer shape
- `.zcode/xdna-research/tile640-surface-map.md:231-323` - current
  AMD / Intel dispatch (stub) and tile status
- `.zcode/xdna-research/amd-tile-survey.md` - per-arch:
  `:86-141` GCN, `:148-211` RDNA 1, `:218-272` RDNA 2,
  `:277-359` RDNA 3, `:362-438` RDNA 4, `:441-479` RDNA 3.5,
  `:482-556` CDNA 1, `:559-611` CDNA 2, `:614-694` CDNA 3,
  `:697-782` CDNA 4, `:822-835` summary, `:856-905` source docs
- `docs/backend/AMD.md:1-3` - hetero-inference context
- `docs/backend/AMD.md:46-69` - existing TILE_AMD stub spec (this
  document extends it)
- `docs/backend/AMD.md:54-58` - `QK_AMD = 64` proposal (rejected in
  favor of per-arch values; see Open Question iii)
- `ggml/src/ggml-common.h:181-205` - T640 / T512 / T1024 constants
- `ggml/src/ggml-common.h:222-261` - `ts_packing_kind` enum,
  `ts_tile_config` struct, factories
- `ggml/include/ggml.h:433-436` - `GGML_TYPE_TESSERA_T*` enum
- `ggml/include/ggml.h:590-593` - `GGML_OP_TILE*` enum
- `ggml/src/ggml.c:945-960` - `dequantize_row_tessera_t640`
- `ggml/src/ggml-cuda/tile640-interleaved.cu:35-435` - existing
  AMD-side Tile640 port (HIP/CUDA)
- `ggml/src/ggml-cuda.cu:2345-2350` - dispatch hook
- `ggml/src/ggml-cpu/ops.cpp:11199` - CPU reference path
- `ggml/src/ggml-amd/tile/tile_amd_matmul.cpp` (12 lines, see
  `docs/backend/AMD.md:67`) - AMD stub to extend
- `ggml/src/ggml-amd/tile/tile_amd.comp` (7 lines, see
  `docs/backend/AMD.md:68`) - Vulkan SPIR-V stub
- `tools/quantize/quantize.cpp:1315-1345` - `ts_cli_pack` dispatch
- `tools/quantize/quantize.cpp:1365-1378` - GGUF metadata writes
- `tools/quantize/tessera/tessera-gguf-writer.cpp:28-62` -
  `ts_gguf_write_metadata`
- `tools/quantize/tessera/tessera-gguf-writer.cpp:64-136` -
  `ts_gguf_write_tensor_cluster` (7-subtensor convention)
- `tools/quantize/tessera/tessera-gguf-writer.cpp:138-182` - repoint
  helper
- `tools/quantize/tessera/tessera-quant.cpp:1150-1206` -
  `ts_pack_ternary_to_tile` (entry point extended)
- `tools/quantize/tessera/tessera-quant.cpp:497-502` - `TS_PACK_2BIT`
  assert-fail (Intel T512/T1024 unimplemented)
- `tools/quantize/tessera/tile-detect.cpp:42-66` -
  `ts_detect_apple_family`
- `tools/quantize/tessera/tile-detect.cpp:68-112` -
  `ts_detect_tile_config` (extended with HIP probe)
- `tools/quantize/tessera/tessera-ternary.h:38-59` - neutral
  transport struct (`ts_ternary_tensor`)
- `tools/quantize/tessera/ttt-writer.h:48-67` - safetensors on-disk
  shape
- `tools/quantize/tessera/tessera-format.h:36-45` -
  `ts_format_spec_default` (T640 production format reference)

### External

- `llvm/include/llvm/IR/IntrinsicsAMDGPU.td`:
  - `:3093-3108` GFX11 WMMA, `:3210-3225` GFX12 WMMA
  - `:3604-3629` GFX908 MFMA, `:3631-3641` GFX90A MFMA
  - `:3674-3725` GFX940/942 MFMA, `:3773-3797` GFX950 MFMA+scale
  - `:4213-4292` future GFX1250 WMMA
- `composable_kernel/include/ck/utility/amd_arch.hpp` (master,
  2026-08-15): `get_lds_size<gfx950_t>` = 160 KiB,
  `get_n_lds_banks<gfx950_t>` = 64, `get_max_vgpr_count<gfx9_t>` = 512
- AMD ISA Reference Guides: RDNA 2 (gfx1030), RDNA 3 (gfx1100),
  CDNA 2 (gfx90a), CDNA 3 (gfx942), CDNA 4 / MI355X (gfx950)
- ROCm `composable_kernel` master, 2026-08-15; MIT
  (`https://github.com/ROCm/composable_kernel/blob/develop/LICENSE`,
  SPDX: `MIT`, Copyright 2018-2025 AMD)
- ROCm Documentation: `https://rocm.docs.amd.com`
- AITER upstream: `ROCm/aiter @ a43694f18`; MIT
  (`https://github.com/ROCm/aiter/blob/main/LICENSE`)
- Joint workspace: `/home/x/vllm-aiter-gfx1103/` (vllm+aiter
  joint snapshot, gfx1103-specific work as one overlay commit
  `26634fbe6`; tessera references this for lessons, does NOT
  vendor any source from it - see Section 11)
- Joint workspace mapping report: `vllm-aiter-gfx1103/MAP.md`
  (generated 2026-08-15; records what was studied, the
  lessons taken, and what is intentionally NOT vendored)
- CK gfx11 WMMA wrapper:
  `composable_kernel/include/ck_tile/core/arch/mma/wmma/wmma_gfx11.hpp:56`
- CK gfx12 WMMA wrapper:
  `composable_kernel/include/ck_tile/core/arch/mma/wmma/wmma_gfx12.hpp:355`
- CK MFMA path:
  `composable_kernel/include/ck_tile/core/arch/mma/mfma/`
- CK arch family macros: `composable_kernel/include/ck/ck.hpp:54-97`

## 11. AITER / vLLM gfx1103 reference posture

This section records how tessera treats the joint AITER+vLLM
gfx1103 workspace at `/home/x/vllm-aiter-gfx1103/`. The full
mapping report is at `/home/x/vllm-aiter-gfx1103/MAP.md`; this
section is the binding spec-side summary.

### 11.1 Posture

**Study, then write our own.** Tessera does NOT vendor, copy,
"lift", or fork any AITER / vLLM `.cu`, `.h`, or `.py` source.
The AITER gfx1103 work is read for guidance on tile geometry,
Triton autotune heuristics, runtime-gate patterns, and correctness
bug fixes, then closed. Every tessera AMD tile kernel is
tessera-original, built on top of Composable Kernel's
`DeviceGemm` family (MIT, vendored per Section 9(vi)).

This matches the no-versioned-implementations rule
(`AGENTS.md`) and the no-versioned-AMD-tile rule the rest of this
spec assumes: there is no AITER-shaped parallel implementation
running alongside the tessera-original one.

### 11.2 What we read from AITER

The four AITER gfx1103 first-class ops + TurboQuant k3/v4 +
Triton RDNA3 attention configs are consulted at:

- `aiter/csrc/kernels/attention_gfx1103.cu` (16 KB)
- `aiter/csrc/kernels/fp8_gfx1103.cu` (14 KB)
- `aiter/csrc/kernels/mamba_gfx1103.cu` (48 KB)
- `aiter/csrc/kernels/turboquant_k3v4_gfx1103.cu` (62 KB)
- `aiter/aiter/ops/fp8_gfx1103.py:33` (runtime-gate pattern)
- `aiter/aiter/ops/rmsnorm.py:388-403` (interleaved-load fix)
- `aiter/aiter/ops/triton/attention/unified_attention.py:65-140` (tile configs)
- `aiter/aiter/ops/triton/configs/gemm/gfx1103-GEMM-A16W16*.json` (GEMM autotune)

These inform Wave C's tile-shape choices, the RMSNorm fusion's
`__gfx11__` gate, and the Triton config table under
`ggml-amd/configs/triton/`. They are NOT copied into the
tessera tree.

### 11.3 What the reference study does NOT do

- **No vendoring.** No AITER `.cu` or `.h` is added to
  `ggml-amd/csrc/`.
- **No `THIRDPARTY-NOTICES` entry for AITER.** Tessera ships
  only Composable Kernel as a third-party (MIT, Section 9(vi)).
  AITER is an external reference; reading it does not create a
  distribution obligation when the derivatives are
  tessera-original and the source is not vendored.
- **No Python wrappers.** AITER's `aiter/aiter/ops/*_gfx1103.py`
  Python layer is not ported; tessera's
  `ggml_compute_forward_tile_rdna3_*` op handlers are the
  integration surface.
- **No `.so` artifacts.** The precompiled
  `aiter/aiter/jit/module_*.so` modules are rebuilt from CK +
  tessera-original HIP sources per AGENTS.md provenance.

### 11.4 Carry-over notes from the AITER study

These are correctness lessons that shape how tessera writes the
RDNA3 kernel family from scratch, not line-level ports.

1. **RMSNorm interleaved-load disable on `__gfx11__`**:
   `aiter/aiter/ops/rmsnorm.py:388-403` documents a bug the
   AITER team hit where the prior interleaved-store kernel
   corrupted every 8th element on gfx1103 because of the 64 KB
   LDS constraint. Tessera's RMSNorm / quant fusion must gate
   the interleaved variant off under `__gfx11__` from the start.
2. **Triton 12-CU / 64-KB-LDS / UMA-DDR5 tuning**:
   `aiter/aiter/ops/triton/attention/unified_attention.py:90-98`
   documents that gfx1103 has 12 CUs, 64 KB LDS, and UMA DDR5;
   the CDNA-default `BLOCK_M / TILE_SIZE / num_warps /
   num_stages_2d / waves_per_eu` under-perform by ~3x without
   the gfx1103-specific block.
   `unified_attention.py:99-140` carries the hand-tuned values
   for D in {64, 128, 256}. Tessera reproduces these starting
   points in its own Triton autotune JSON
   (`ggml-amd/configs/triton/unified_attention_gfx1103.json`).
3. **Runtime-gate pattern**:
   `aiter/aiter/ops/fp8_gfx1103.py:33` —
   `gfx1103_*_supported() => get_gfx_runtime() == "gfx1103"`.
   Tessera mirrors the same runtime probe in
   `tile_amd_matmul_rdna3.cpp`; the compile-time `__gfx11__`
   family (`composable_kernel/include/ck/ck.hpp:70-74`) is the
   primary gate, the runtime call is the fallback when the
   dispatch cannot decide at compile time.
4. **AIE kernels stay out of scope.** Tessera's Tile-AMD spec
   is GPU-only; the AITER joint workspace also runs Nemotron
   DFlash / DSpark speculative-decoding ops
   (`gfx1103_dspark_markov_gathered` etc.), which live in
   `aiter/aiter/ops/nvfp4_moe_gfx1103.py:80,98`. Spec-decoding
   integration is a separate tessera decision and not on the
   AMD tile path. The correlation is informational, not a
   coupling.

### 11.5 RDNA35 (Strix Halo) caveat

AITER covers **gfx1103 only**, not `gfx1150-1153` (RDNA35).
Composable Kernel's `__gfx11__` macros cover both archs
(`composable_kernel/include/ck/ck.hpp:70-74`), and the headline
WMMA tile geometry is the same, but two CK comments
(`include/ck_tile/ops/fmha/block/block_dropout.hpp:67` and
`include/ck_tile/core/arch/mma/mma_wavewise.hpp:1519`) flag
sub-arch differences in the C-distribution permutation that
require per-arch verification on gfx1151. Wave C ships gfx1103
+ the `__gfx11__` family compile-time; Wave H (Section 8.8)
tests the same kernel on RDNA35 and patches the C-distribution
permutation as needed.

### 11.6 What this means for the Tile-AMD v1 schedule

The "study, write our own" posture keeps the schedule
realistic: no false head-start from a hypothetical lift, and
no scope creep from reading AITER.

- **Wave C (RDNA3, gfx1103)**: tessera-original
  `tile_amd_matmul_rdna3.cpp` built on CK
  `composable_kernel::DeviceGemm::Wmma<...>`. The per-tile /
  per-lane scale fit (Section 4 table) and the trit -> INT8
  pack (Section 6.2) are tessera code in
  `tools/quantize/tessera/tessera-quant.cpp:1150-1206` extended.
- **Wave D (CDNA3, gfx942)**: same pattern on
  `DeviceMFMA::Rowwise` for FP16 / INT8 and the SMFMAC sparse
  path. No AITER.
- **Wave E (CDNA4, gfx950)**: `DeviceMFMA::Scaled` for the
  microscaled family; no AITER.
- **Wave F (RDNA4, gfx1200 / gfx1201 / gfx1250)**: standalone.
  The AITER FlyDSL subtree is mixed MIT / Apache-2.0 licensed
  and would only matter if tessera wanted to vendor the gfx1250
  grouped-MOE / MXFP4-TDM paths; under "study, write our own"
  it does not enter our tree at all.

### 11.7 Acceptance criteria for Wave C

In addition to the Section 8.3 acceptance criteria:

1. **File-presence check** (post-claim audit pass 1):
   `ggml-amd/tile/tile_amd_matmul_rdna3.cpp` exists and is
   tessera-original (no AITER / vLLM file header, no
   `SPDX-License-Identifier: MIT` import of an AITER file).
2. **No AITER vendor artifacts** (post-claim audit pass 1):
   `git grep -nE 'Copyright \(C\) 2026, Advanced Micro Devices,
   Inc\.' ggml-amd/` returns zero matches, and
   `git grep -nE 'aiter/.*\.(cu|h|py)' ggml-amd/` returns zero
   matches.
3. **Build clean** (post-claim audit pass 2): Wave C
   compiles against Composable Kernel
   `include/ck_tile/...` with no new warnings.
4. **Parity check**: cosine similarity of a 1-layer
   `Tile-RDNA3` forward against the scalar CPU reference path
   (`ggml-cpu/ops.cpp:11199`) within 1% relative Frobenius.
5. **Throughput check**: on RX 7900 XTX, the
   `Tile-RDNA3-16x16x16-i8` path reaches the 2x scalar
   fallback target. (Internal number; AITER is not a
   comparison oracle.)

End of reference-posture section.

## 11.8 AITER-style parameterization architecture

Tessera writes its own AMD tile kernels (Section 11.1) but adopts
the operator-parameterization shape AITER developed for
production-grade multi-arch dispatch. The pattern, not the code,
is the lesson. Nothing from `aiter/aiter/`, `aiter/csrc/`, or
`vllm/csrc/` is vendored; the on-disk structure mirrors AITER's
shape so future maintainers who already know AITER can reason
about tessera quickly.

### 11.8.1 Three pieces, mirroring three AITER mechanisms

| AITER mechanism (study reference) | Tessera mirror (this spec) | Where it lands |
| --- | --- | --- |
| `@compile_ops(...)` op decorators (`aiter/aiter/ops/turboquant.py:28-88`); `SMEM_CAPACITY_MAP` gating (`aiter/aiter/ops/flydsl/utils.py:79-84`) | `ggml-amd/registry/tile_amd_op_registry.{h,cpp}` keyed on `(arch_target, dtype, sparse?, microscale?, M, N, K)` | Section 7.10 |
| `aiter/aiter/configs/model_configs/gptoss_a16w4_tuned_fmoe.csv:2` + per-shape autotune JSON | `tools/quantize/tessera/configs/tile_amd_kernels.csv` — columns `arch, dtype, sparse, microscale, M, N, K, BM, BN, BK, stages, epilog, kernelName, anchor_hash` | Section 8.1a (Wave A.1) |
| AITER's AOT fork-pool at `aiter/aot/flydsl/moe.py:1034-1045` driven by `FLYDSL_GPU_ARCH` | `tools/quantize/tessera/scripts/build_amd_kernels.py` — CSV-driven precompile, one binary per `(arch, dtype, shape)` row | Section 8.1a (Wave A.1) |

### 11.8.2 Why the pattern matters (problem AITER solved that we have)

AMD tile kernels have an `n x shape x dtype` combinatorial
shape space. Naively, every new dtype or quant variant adds a
new `__gfx__` ifdef branch in `tile_amd_matmul.cpp`. AITER's
experience is that this ifdef cascade does not scale: when a
new `(dtype, sparse, microscale)` tuple arrives, the ifdef
chain grows and the dispatcher's switch on `(arch, dtype)`
collapses to a dense matrix of compiled variations.

The CSV-driven registry defers that combinatorial growth to
data: each new tunecap is a CSV row + a build artifact, not a
new C++ branch. The dispatcher stays small
(`tile_amd_op_registry_lookup`); the kernel selection becomes
a hash-table lookup. This is the same economy that prompted
AITER's `model_configs/*.csv` design and is the explicit
reason tessera adopts the shape.

### 11.8.3 What we explicitly do NOT import

The AITER pattern is structural. The following are NOT
considered for vendoring because they are bound to AITER's
runtime, language, or quant regime:

- AITER's `@compile_ops` Python decorator syntax (tessera
  uses a C-side registry; the Python CSV loader is a separate
  tool that does not sit on the runtime path).
- AITER's `mkldnn` / `flydsl` / `mfma_*` codegen templates
  (the corresponding tessera path is `composable_kernel`
  templates, which are MIT-licensed and vendored per
  Section 9(vi)).
- AITER's `kernelName` strings (`gfx950_256x256x32`,
  `gemm_a8w8_bpreshuffle_8wave` etc.) — these are AITER's
  production naming scheme and are not a tessera vocabulary.
- AITER's Nemotron / DFlash / DSpark-specific
  `(dtype, quant, routing)` triples. The tessera CSV is empty
  initially and is filled in by per-wave autotune sweeps with
  whatever triples the tessera pipeline actually needs.

### 11.8.4 Tunecap anchor hash

Each CSV row carries an `anchor_hash` column. The hash
fingerprints the `(arch, dtype, sparse, microscale, M, N, K)`
selection, plus a content fingerprint of the CK template that
the row instantiates. When either side changes, the hash
changes and the build_amd_kernels.py script knows that row
needs a re-measure. This matches the per-test content-hash
cache scheme already shipped for `tools/quantize/tessera/test_all.sh`
and is the project-standard way to express "the measurement
is stale; re-tune".

### 11.8.5 Wave-relative CSV population order

The CSV starts empty. Each wave that ships kernels populates
its arch's rows:

- **Wave A.1**: skeleton only (`arch="RDNA3" dtype="placeholder"`
  row to validate the loader).
- **Wave C (RDNA3)**: `gfx1100..1103 + gfx1150..1153` rows
  for INT8 / FP16 / BF16 / INT4 (no FP8 WMMA on GFX11).
- **Wave D (CDNA3)**: `gfx942` rows for FP16 / BF16 / INT8 /
  FP8 / BF8 + sparse SMFMAC.
- **Wave E (CDNA4)**: `gfx950` rows including the microscaled
  FP4 / FP6 / FP8 family with per-block FP8 scales.
- **Wave F (RDNA4)**: `gfx1200/1201/1250` rows.
- **Wave G (RDNA2 / RDNA1)**: legacy packed-math rows.
- **Wave H (RDNA35)**: same as Wave C, gated by gfx115x
  verification (Section 11.5).
- **Wave I (GCN)**: scalar ALU rows.

The CSV is the single source of truth for "which
`(arch, dtype, shape)` does tessera have a measured kernel
for"; missing rows route to the scalar CPU reference.

### 11.8.6 Resolves Open Question (v)

With the registry in place, `arch_target` becomes a first-class
field on `ts_tile_config` orthogonal to `packing`. `packing`
continues to encode the wire format (Tile-GCN / Tile-RDNA1 / ...
/ Tile-CDNA4); `arch_target` encodes the dispatch target. The
registry's lookup key is `(arch_target, dtype, sparse,
microscale, M, N, K)`; `packing` is held in the cluster tensor
metadata and used to pick the dequant row + GGUF writer
behavior. This is option (b) at Open Question (v). Wave A.1
makes option (b) the binding choice.

End of parameterization section.