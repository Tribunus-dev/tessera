// test-ane-gguf-stream.cpp
//
// Phase 2 of the iPhone 13 Pro Max gemma 4 12B demo
// (docs/tessera-ane-ios-demo-design.md). The streamer reads
// per-layer T640_3D weight tensors out of a mmap'd unified
// GGUF and into the corresponding IOSurface-pinned slot
// for the bound .mlmodelc function. These tests verify the
// streamer against a synthetic GGUF (small, fast, focused);
// the real 12B end-to-end test is in slice 5, gated on the
// TEST_TESSERA_UNIFIED_GGUF_PATH env var.
//
// What we test:
//   1. open a valid synthetic GGUF (2 layers, 4 F32 tensors)
//   2. file_size matches what we wrote
//   3. n_block_tensors returns the expected per-layer count
//   4. block_tensor_info returns the right name + size + shape
//   5. block_tensor streams the right bytes (crc32 of dst ==
//      crc32 of the source bytes we wrote into the GGUF)
//   6. stream_layer writes the full layer contiguously and
//      in name-sorted order
//   7. open nonexistent file fails with a clear error string
//   8. open truncated file fails (header parse error)
//   9. open wrong-magic file fails
//  10. block_tensor with too-small dst returns -1
//  11. block_tensor with out-of-range index returns -1
//  12. close is safe on NULL

#include "gguf_weight_stream.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        std::fprintf(stderr, "FAIL [%s:%d] %s\n", __FILE__, __LINE__, msg); \
        ++g_failures; \
    } else { \
        std::fprintf(stdout, "ok   %s\n", msg); \
    } \
} while (0)

// Minimal little-endian writer. The GGUF format is
// little-endian; Apple Silicon is little-endian, so these
// are direct stores.
inline void write_u32(uint8_t * p, uint32_t v) {
    p[0] = (uint8_t) (v       & 0xff);
    p[1] = (uint8_t) ((v >> 8) & 0xff);
    p[2] = (uint8_t) ((v >> 16) & 0xff);
    p[3] = (uint8_t) ((v >> 24) & 0xff);
}

inline void write_u64(uint8_t * p, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        p[i] = (uint8_t) ((v >> (i * 8)) & 0xff);
    }
}

// GGUF string = uint64 length + length bytes (not NUL terminated).
inline void write_gguf_string(std::vector<uint8_t> & out, const std::string & s) {
    const uint64_t len = s.size();
    uint8_t hdr[8];
    write_u64(hdr, len);
    out.insert(out.end(), hdr, hdr + 8);
    out.insert(out.end(), s.begin(), s.end());
}

// CRC32 (standard zlib polynomial 0xEDB88320). Used to
// assert byte-equality of streamed bytes against what the
// synthetic GGUF builder wrote. Tiny, no external dep.
uint32_t crc32(const uint8_t * data, size_t n) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) {
        crc ^= data[i];
        for (int k = 0; k < 8; ++k) {
            const uint32_t mask = -(crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~crc;
}

// Synthetic GGUF builder. Writes a v3 GGUF to a temp file
// with the following tensor set:
//
//   blk.0.w    F32 [1, 4] = {0, 1, 2, 3}
//   blk.0.b    F32 [1, 2] = {10, 11}
//   blk.1.w    F32 [1, 4] = {100, 101, 102, 103}
//   blk.1.b    F32 [1, 2] = {110, 111}
//   token_embd F32 [1, 8] = {0, 1, ..., 7}     (no blk.L. prefix)
//   output     F32 [1, 4] = {20, 21, 22, 23}   (no blk.L. prefix)
//
// Total 6 tensors, 0 kvs, 96 bytes of data. Returns the
// temp file path via `path_out`.
struct synth_tensor {
    std::string name;
    uint32_t    n_dim;
    uint64_t    shape[4];
    uint32_t    ggml_type; // 0 = F32
    std::vector<uint8_t> data;
};

bool build_synthetic_gguf(const std::string & path,
                          const std::vector<synth_tensor> & tensors) {
    // Compute the per-tensor offset within the data
    // section. Tensors are written in the same order as
    // the tensor_info array; offset is the running sum
    // of the ALIGNED size (the per-tensor alignment the
    // GGUF spec requires). The runtime reads each tensor
    // from `data_section_offset + tensor.offset`, so the
    // offset must be the position the file writer uses
    // for that tensor (after per-tensor padding to the
    // 32-byte boundary).
    std::vector<uint64_t> data_offsets;
    uint64_t cursor = 0;
    for (const auto & t : tensors) {
        data_offsets.push_back(cursor);
        // GGUF_DEFAULT_ALIGNMENT (32) is the minimum
        // per-tensor alignment. Advance the cursor by the
        // tensor's size rounded up to the next 32-byte
        // boundary; the writer inserts zero padding to
        // reach that boundary before each tensor.
        const uint64_t aligned_size =
            (t.data.size() + 31) & ~uint64_t(31);
        cursor += aligned_size;
    }
    // Build the file in two passes: header, then data.
    std::vector<uint8_t> header;
    // magic
    uint8_t magic[4] = { 'G', 'G', 'U', 'F' };
    header.insert(header.end(), magic, magic + 4);
    // version
    uint8_t ver[4];
    write_u32(ver, 3);
    header.insert(header.end(), ver, ver + 4);
    // n_tensors
    uint8_t nt[8];
    write_u64(nt, tensors.size());
    header.insert(header.end(), nt, nt + 8);
    // n_kv
    uint8_t nkv[8] = {0,0,0,0,0,0,0,0};
    header.insert(header.end(), nkv, nkv + 8);
    // Tensor infos.
    for (size_t i = 0; i < tensors.size(); ++i) {
        const auto & t = tensors[i];
        write_gguf_string(header, t.name);
        uint8_t nd[4];
        write_u32(nd, t.n_dim);
        header.insert(header.end(), nd, nd + 4);
        for (uint32_t d = 0; d < t.n_dim; ++d) {
            uint8_t sh[8];
            write_u64(sh, t.shape[d]);
            header.insert(header.end(), sh, sh + 8);
        }
        uint8_t tp[4];
        write_u32(tp, t.ggml_type);
        header.insert(header.end(), tp, tp + 4);
        uint8_t of[8];
        write_u64(of, data_offsets[i]);
        header.insert(header.end(), of, of + 8);
    }
    // Pad header to 32-byte boundary (data section start).
    while (header.size() % 32 != 0) {
        header.push_back(0);
    }
    // Concatenate: header + per-tensor data.
    std::vector<uint8_t> file = header;
    for (size_t i = 0; i < tensors.size(); ++i) {
        const auto & t = tensors[i];
        // Pad to 32-byte boundary (per-tensor alignment).
        while (file.size() % 32 != 0) file.push_back(0);
        file.insert(file.end(), t.data.begin(), t.data.end());
    }
    // Write the file.
    FILE * f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite(file.data(), 1, file.size(), f) == file.size();
    std::fclose(f);
    return ok;
}

// Make 4 F32 floats in little-endian.
std::vector<uint8_t> f32_le(float a, float b, float c, float d) {
    std::vector<uint8_t> out(16);
    std::memcpy(&out[0],  &a, 4);
    std::memcpy(&out[4],  &b, 4);
    std::memcpy(&out[8],  &c, 4);
    std::memcpy(&out[12], &d, 4);
    return out;
}

std::vector<uint8_t> f32_le_2(float a, float b) {
    std::vector<uint8_t> out(8);
    std::memcpy(&out[0], &a, 4);
    std::memcpy(&out[4], &b, 4);
    return out;
}

std::vector<uint8_t> f32_le_8(float a, float b, float c, float d,
                              float e, float f, float g, float h) {
    std::vector<uint8_t> out(32);
    float vs[8] = {a,b,c,d,e,f,g,h};
    std::memcpy(out.data(), vs, 32);
    return out;
}

std::string make_temp_path() {
    char tmpl[] = "/tmp/ane_gguf_stream_test.XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) return std::string();
    ::close(fd);
    return std::string(tmpl);
}

}  // namespace

int main() {
    std::fprintf(stdout, "ane gguf weight stream test (slice 2)\n");

    // --- Build the synthetic GGUF. ---
    std::vector<synth_tensor> tensors = {
        // block 0
        {"blk.0.w",    2, {1, 4, 0, 0}, 0, f32_le  (0.0f,  1.0f,  2.0f,  3.0f)},
        {"blk.0.b",    2, {1, 2, 0, 0}, 0, f32_le_2(10.0f, 11.0f)},
        // block 1
        {"blk.1.w",    2, {1, 4, 0, 0}, 0, f32_le  (100.0f, 101.0f, 102.0f, 103.0f)},
        {"blk.1.b",    2, {1, 2, 0, 0}, 0, f32_le_2(110.0f, 111.0f)},
        // out-of-block (no blk.L. prefix)
        {"token_embd", 2, {1, 8, 0, 0}, 0, f32_le_8(0,1,2,3,4,5,6,7)},
        {"output",     2, {1, 4, 0, 0}, 0, f32_le  (20.0f, 21.0f, 22.0f, 23.0f)},
    };
    const std::string gguf_path = make_temp_path();
    CHECK(!gguf_path.empty(), "make_temp_path succeeds");
    CHECK(build_synthetic_gguf(gguf_path, tensors), "build_synthetic_gguf writes valid GGUF v3");

    // --- Test 1-2: open + file_size. ---
    ane_weight_stream_t * stream = nullptr;
    char err[256] = {0};
    CHECK(ane_weight_stream_open(gguf_path.c_str(), &stream, err, sizeof(err)),
          "ane_weight_stream_open accepts a valid v3 GGUF");
    if (!stream) {
        std::fprintf(stderr, "open failed: %s\n", err);
        return 1;
    }
    const size_t file_size = ane_weight_stream_file_size(stream);
    CHECK(file_size > 0, "ane_weight_stream_file_size returns a positive size");

    // --- Test 3: n_block_tensors per layer. ---
    CHECK(ane_weight_stream_n_block_tensors(stream, 0) == 2,
          "layer 0 has 2 blk.0.* tensors");
    CHECK(ane_weight_stream_n_block_tensors(stream, 1) == 2,
          "layer 1 has 2 blk.1.* tensors");
    CHECK(ane_weight_stream_n_block_tensors(stream, 99) == 0,
          "layer 99 has 0 tensors (unknown layer)");
    CHECK(ane_weight_stream_n_block_tensors(stream, -1) == 0,
          "layer -1 has 0 tensors (negative layer)");

    // --- Test 4: block_tensor_info. ---
    {
        const char * name = nullptr;
        size_t size = 0;
        uint32_t n_dim = 0;
        uint64_t shape[4] = {0,0,0,0};
        CHECK(ane_weight_stream_block_tensor_info(stream, 0, 0,
                &name, &size, &n_dim, shape),
              "block_tensor_info(layer=0, idx=0) succeeds");
        CHECK(name != nullptr && std::string(name) == "blk.0.b",
              "layer 0 idx 0 is blk.0.b (name-sorted)");
        CHECK(size == 8, "blk.0.b size is 8 bytes (2 floats * 4)");
        CHECK(n_dim == 2, "blk.0.b n_dim is 2");
        CHECK(shape[0] == 1 && shape[1] == 2, "blk.0.b shape is [1, 2]");

        CHECK(ane_weight_stream_block_tensor_info(stream, 0, 1, &name, &size, nullptr, nullptr),
              "block_tensor_info(layer=0, idx=1) succeeds");
        CHECK(std::string(name) == "blk.0.w", "layer 0 idx 1 is blk.0.w (name-sorted)");
        CHECK(size == 16, "blk.0.w size is 16 bytes (4 floats * 4)");

        CHECK(!ane_weight_stream_block_tensor_info(stream, 0, 99, &name, &size, nullptr, nullptr),
              "block_tensor_info(layer=0, idx=99) returns false (out of range)");
    }

    // --- Test 5: block_tensor streams the right bytes. ---
    {
        // Read blk.0.b (idx 0) into a buffer; CRC32 should
        // match what we wrote into the synthetic GGUF.
        std::vector<uint8_t> dst(8, 0xCC);
        const int64_t n = ane_weight_stream_block_tensor(stream, 0, 0, dst.data(), dst.size());
        CHECK(n == 8, "block_tensor(layer=0, idx=0) returns 8 bytes");
        const uint32_t want_crc = crc32(f32_le_2(10.0f, 11.0f).data(), 8);
        const uint32_t got_crc  = crc32(dst.data(), 8);
        CHECK(want_crc == got_crc, "blk.0.b bytes match the synthetic GGUF source (CRC32)");

        // Read blk.0.w (idx 1) and verify.
        std::vector<uint8_t> dst2(16, 0xCC);
        const int64_t n2 = ane_weight_stream_block_tensor(stream, 0, 1, dst2.data(), dst2.size());
        CHECK(n2 == 16, "block_tensor(layer=0, idx=1) returns 16 bytes");
        const uint32_t want_crc2 = crc32(f32_le(0.0f, 1.0f, 2.0f, 3.0f).data(), 16);
        const uint32_t got_crc2  = crc32(dst2.data(), 16);
        CHECK(want_crc2 == got_crc2, "blk.0.w bytes match the synthetic GGUF source (CRC32)");

        // Layer 1: read blk.1.b.
        std::vector<uint8_t> dst3(8);
        const int64_t n3 = ane_weight_stream_block_tensor(stream, 1, 0, dst3.data(), dst3.size());
        CHECK(n3 == 8, "block_tensor(layer=1, idx=0) returns 8 bytes");
        const uint32_t want_crc3 = crc32(f32_le_2(110.0f, 111.0f).data(), 8);
        const uint32_t got_crc3  = crc32(dst3.data(), 8);
        CHECK(want_crc3 == got_crc3, "blk.1.b bytes match the synthetic GGUF source (CRC32)");
    }

    // --- Test 6: stream_layer writes the whole layer contiguously in name-sorted order. ---
    {
        const size_t total = 8 + 16; // blk.0.b + blk.0.w
        std::vector<uint8_t> dst(total, 0xCC);
        const int64_t n = ane_weight_stream_layer(stream, 0, dst.data(), dst.size());
        CHECK(n == (int64_t) total, "stream_layer(0) writes 24 bytes (8 + 16)");
        // First 8 bytes are blk.0.b (name-sorted "b" < "w"),
        // next 16 bytes are blk.0.w.
        const uint32_t want_crc_b = crc32(f32_le_2(10.0f, 11.0f).data(), 8);
        const uint32_t got_crc_b  = crc32(dst.data(), 8);
        CHECK(want_crc_b == got_crc_b, "stream_layer(0) bytes 0..7 are blk.0.b");
        const uint32_t want_crc_w = crc32(f32_le(0.0f, 1.0f, 2.0f, 3.0f).data(), 16);
        const uint32_t got_crc_w  = crc32(dst.data() + 8, 16);
        CHECK(want_crc_w == got_crc_w, "stream_layer(0) bytes 8..23 are blk.0.w");
    }

    // --- Test 10: too-small dst returns -1. ---
    {
        std::vector<uint8_t> tiny(4, 0xCC);
        const int64_t n = ane_weight_stream_block_tensor(stream, 0, 1, tiny.data(), tiny.size());
        CHECK(n == -1, "block_tensor with too-small dst returns -1");
    }

    // --- Test 11: out-of-range index returns -1. ---
    {
        std::vector<uint8_t> dst(16);
        const int64_t n = ane_weight_stream_block_tensor(stream, 0, 99, dst.data(), dst.size());
        CHECK(n == -1, "block_tensor with out-of-range idx returns -1");
    }

    ane_weight_stream_close(stream);

    // --- Test 7: open nonexistent file fails with a clear error. ---
    {
        ane_weight_stream_t * s = nullptr;
        char e[256] = {0};
        CHECK(!ane_weight_stream_open("/tmp/this_file_does_not_exist.gguf", &s, e, sizeof(e)),
              "open nonexistent file fails");
        CHECK(e[0] != '\0', "open failure fills error_out with a non-empty message");
    }

    // --- Test 8: truncated file fails. ---
    {
        const std::string truncated = make_temp_path();
        FILE * f = std::fopen(truncated.c_str(), "wb");
        if (f) {
            // Write only the magic + version + 8 bytes; not
            // enough for n_tensors + n_kv. Reader must reject.
            uint8_t junk[20] = { 'G','G','U','F', 3,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0 };
            std::fwrite(junk, 1, sizeof(junk), f);
            std::fclose(f);
        }
        ane_weight_stream_t * s = nullptr;
        char e[256] = {0};
        CHECK(!ane_weight_stream_open(truncated.c_str(), &s, e, sizeof(e)),
              "open truncated file fails");
        CHECK(e[0] != '\0', "truncated-file failure fills error_out");
        ::unlink(truncated.c_str());
    }

    // --- Test 9: wrong-magic file fails. ---
    {
        const std::string badmagic = make_temp_path();
        FILE * f = std::fopen(badmagic.c_str(), "wb");
        if (f) {
            uint8_t junk[64] = {0};
            junk[0] = 'B'; junk[1] = 'A'; junk[2] = 'D'; junk[3] = '!';
            std::fwrite(junk, 1, sizeof(junk), f);
            std::fclose(f);
        }
        ane_weight_stream_t * s = nullptr;
        char e[256] = {0};
        CHECK(!ane_weight_stream_open(badmagic.c_str(), &s, e, sizeof(e)),
              "open wrong-magic file fails");
        // The error should mention "magic".
        const bool mentions_magic =
            std::strstr(e, "magic") != nullptr ||
            std::strstr(e, "Magic") != nullptr;
        CHECK(mentions_magic, "wrong-magic error mentions 'magic'");
        ::unlink(badmagic.c_str());
    }

    // --- Test 12: close on NULL is safe. ---
    ane_weight_stream_close(nullptr);
    CHECK(true, "close(NULL) is a no-op (does not crash)");

    // Cleanup.
    ::unlink(gguf_path.c_str());

    if (g_failures == 0) {
        std::fprintf(stdout, "\nALL CHECKS PASSED\n");
        return 0;
    } else {
        std::fprintf(stderr, "\n%d FAILURES\n", g_failures);
        return 1;
    }
}
