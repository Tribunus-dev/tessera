#pragma once
// TilingRepacker — shards (ternary + int8 lane + f16 page + 2% sparse) -> per-device GGUF view
// Quantized shards canonical in RAM, repacked views cached by (modelHash,tile,dtype,driverVersion) in XDG_DATA_HOME/tessera/models/<model>-<tile>-<dtype>.gguf
// Shares TILE constants with tools/tile640/quantize_v3.py (640/512/256) - permute+cast seconds, no GA
#include <string>
#include <cstdint>
#include <optional>

namespace tessera::hardware {

struct RepackRequest {
    std::string shards_path;      // XDG_CACHE/tessera/shards/<model>/
    std::string model_hash;       // sha256 of shards
    int tile = 256;               // 256 legacy vector-packed, 512 WMMA, 640 Apple
    std::string dtype;            // f32 / f16 / bf16
    std::string driver_version;   // for cache key invalidation
};

struct RepackResult {
    std::string gguf_path;        // XDG_DATA_HOME/tessera/models/<model>-<tile>-<dtype>.gguf
    bool from_cache = false;
    uint64_t bytes = 0;
    std::string layout_tag;       // tessera.layout
};

class TilingRepacker {
public:
    // Sync repack: mmap shards -> permute pages -> write GGUF header tessera.layout=<tile> + dtype tag -> fsync -> unlink shards if requested
    static RepackResult repack(const RepackRequest &req, bool unlink_shards = false);

    // Cache lookup only
    static std::optional<RepackResult> cached(const RepackRequest &req);

    // GGUF cache dir: XDG_DATA_HOME/tessera/models/
    static std::string cache_dir();
    static std::string cache_path(const RepackRequest &req);

    // Verify GGUF header layout tag
    static bool verify(const std::string &gguf_path, int expected_tile);
};

} // namespace tessera::hardware
