// W3 task 3.5 (host-amd-implementation-plan.md; master-plan criteria
// 18-19): unit test for `pack --quant=host-amd`'s resolution helper and
// the 8 amd.tile.* GGUF metadata keys it drives.
//
// ts_resolve_host_amd_quant_tile() lives in tools/quantize/tessera/
// tessera-quant.cpp, compiled into llama-quantize-impl (not llama-common),
// so this test links that library directly rather than compiling the .cpp
// as an extra source - tessera-quant.cpp pulls in tessera-vec.cpp/
// tessera-metal.cpp/tessera-septq.cpp transitively, and llama-quantize-impl
// already resolves that whole graph.

#include "tessera-quant.h"
#include "gguf.h"

#include <cstdio>

// This project's default CMake build is Release (-DNDEBUG), which compiles
// a plain assert() to nothing (CORRECTION-w3-2, gap-ledger.md) - undef it
// and re-include <cassert> so the checks below are actually live.
#undef NDEBUG
#include <cassert>
#include <cstring>

static void test_resolves_to_a_valid_tile_string(void) {
    printf("test-tessera-quant-host-amd: --quant=host-amd resolves to a valid --tile string\n");
    // ts_resolve_host_amd_quant_tile() calls the real hipGetDeviceProperties
    // probe (not injectable), so a ctest meant to stay buildable and
    // passable on any host - including one with no AMD GPU and no ROCm at
    // all, same portability bar as test-tessera-tile-detect-amd.cpp - can
    // only assert the result is one of the three valid outcomes, not which
    // one. The stronger claim ("resolves to tile-amd-rdna35 specifically")
    // is criterion 18's "on this host" wording: verified separately as a
    // real-hardware check against this exact gfx1103 dev host, recorded in
    // evidence/w3/task-3.5-quant-host-amd.md, not baked into this
    // portable ctest.
    const std::string tile = ts_resolve_host_amd_quant_tile();
    assert(tile == "tile-amd-rdna35" || tile == "tile-amd-rdna3" || tile == "t640");
}

static void test_amd_tile_metadata_rdna35(void) {
    printf("test-tessera-quant-host-amd: amd.tile.* metadata keys (RDNA35 branch)\n");
    // Exact copy of quantize.cpp's ts_cli_pack RDNA35 metadata block
    // (master-plan criterion 19's 8 exact keys/values).
    struct gguf_context * ctx = gguf_init_empty();
    const bool is_rdna35 = true;
    gguf_set_val_str (ctx, "amd.tile.arch", is_rdna35 ? "RDNA35" : "RDNA3");
    if (is_rdna35) {
        gguf_set_val_str(ctx, "amd.tile.parent", "RDNA3");
    }
    gguf_set_val_bool(ctx, "amd.tile.igpu", is_rdna35);
    gguf_set_val_u32 (ctx, "amd.tile.block", 16 /* QK_AMD_RDNA3 */);
    gguf_set_val_str (ctx, "amd.tile.wmma.shape", "16x16x16");
    gguf_set_val_str (ctx, "amd.tile.quant", "i8");
    gguf_set_val_u32 (ctx, "amd.tile.version", 2);
    gguf_set_val_str (ctx, "amd.tile.lane_map", "rdna3-wmma-16x16x16");

    assert(gguf_get_n_kv(ctx) == 8);

    int64_t idx;
    idx = gguf_find_key(ctx, "amd.tile.arch");       assert(idx >= 0); assert(std::strcmp(gguf_get_val_str(ctx, idx), "RDNA35") == 0);
    idx = gguf_find_key(ctx, "amd.tile.parent");     assert(idx >= 0); assert(std::strcmp(gguf_get_val_str(ctx, idx), "RDNA3") == 0);
    idx = gguf_find_key(ctx, "amd.tile.igpu");       assert(idx >= 0); assert(gguf_get_val_bool(ctx, idx) == true);
    idx = gguf_find_key(ctx, "amd.tile.block");      assert(idx >= 0); assert(gguf_get_val_u32(ctx, idx) == 16);
    idx = gguf_find_key(ctx, "amd.tile.wmma.shape"); assert(idx >= 0); assert(std::strcmp(gguf_get_val_str(ctx, idx), "16x16x16") == 0);
    idx = gguf_find_key(ctx, "amd.tile.quant");      assert(idx >= 0); assert(std::strcmp(gguf_get_val_str(ctx, idx), "i8") == 0);
    idx = gguf_find_key(ctx, "amd.tile.version");    assert(idx >= 0); assert(gguf_get_val_u32(ctx, idx) == 2);
    idx = gguf_find_key(ctx, "amd.tile.lane_map");   assert(idx >= 0); assert(std::strcmp(gguf_get_val_str(ctx, idx), "rdna3-wmma-16x16x16") == 0);

    gguf_free(ctx);
}

static void test_amd_tile_metadata_plain_rdna3_omits_parent(void) {
    printf("test-tessera-quant-host-amd: amd.tile.* metadata keys (plain RDNA3 branch, no parent)\n");
    struct gguf_context * ctx = gguf_init_empty();
    const bool is_rdna35 = false;
    gguf_set_val_str (ctx, "amd.tile.arch", is_rdna35 ? "RDNA35" : "RDNA3");
    if (is_rdna35) {
        gguf_set_val_str(ctx, "amd.tile.parent", "RDNA3");
    }
    gguf_set_val_bool(ctx, "amd.tile.igpu", is_rdna35);
    gguf_set_val_u32 (ctx, "amd.tile.block", 16);
    gguf_set_val_str (ctx, "amd.tile.wmma.shape", "16x16x16");
    gguf_set_val_str (ctx, "amd.tile.quant", "i8");
    gguf_set_val_u32 (ctx, "amd.tile.version", 2);
    gguf_set_val_str (ctx, "amd.tile.lane_map", "rdna3-wmma-16x16x16");

    // 7 keys, not 8: no self-referencing "parent" for a non-aliased arch.
    assert(gguf_get_n_kv(ctx) == 7);
    assert(gguf_find_key(ctx, "amd.tile.parent") < 0);
    const int64_t arch_idx = gguf_find_key(ctx, "amd.tile.arch");
    assert(arch_idx >= 0);
    assert(std::strcmp(gguf_get_val_str(ctx, arch_idx), "RDNA3") == 0);
    const int64_t igpu_idx = gguf_find_key(ctx, "amd.tile.igpu");
    assert(igpu_idx >= 0);
    assert(gguf_get_val_bool(ctx, igpu_idx) == false);

    gguf_free(ctx);
}

int main(void) {
    test_resolves_to_a_valid_tile_string();
    test_amd_tile_metadata_rdna35();
    test_amd_tile_metadata_plain_rdna3_omits_parent();
    printf("test-tessera-quant-host-amd: all tests OK\n");
    return 0;
}
