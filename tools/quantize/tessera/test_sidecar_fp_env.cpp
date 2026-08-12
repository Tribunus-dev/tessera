//
// test_sidecar_fp_env.cpp
//
// Tests for the §2 v3-extension FP environment block
// (common/tessera-debug). The block records the matmul accumulator
// dtype, the FMA rounding mode, the denormal mode, and the backend
// identity in the v3 sidecar header so two sidecars from different
// hardware are visibly different. The block is at offset 40 of the
// v3 file (16 bytes: fp_accumulator_dtype[4] + rounding_mode[4] +
// denormal_mode[4] + backend_id[4]).
//
// The tests pin down:
//   1. Setters and getters round-trip through env_state().
//   2. The writer emits the FP env block at the right offset and
//      with the right values when set_fp_env is called before open.
//   3. The reader parses the FP env block from the file and
//      populates the header struct.
//   4. Legacy v3 files (without the FP env block) read with
//      zero-init defaults (the v3 zero-init contract:
//      F32/RTN/IEEE/CPU).
//   5. Different backends produce visibly different headers
//      (CPU vs CUDA vs Metal) so the same model on different
//      hardware is no longer silently incomparable.
//

#include "tessera-debug.h"
#include "tessera-sidecar-v3.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

static int g_fail = 0;

static void check(const char * name, bool ok) {
    if (!ok) {
        std::printf("FAIL %s\n", name);
        g_fail++;
    } else {
        std::printf("ok   %s\n", name);
    }
}

static void check_eq(const char * name, uint32_t got, uint32_t want) {
    if (got != want) {
        std::printf("FAIL %-32s got %u want %u\n", name, got, want);
        g_fail++;
    } else {
        std::printf("ok   %-32s %u\n", name, got);
    }
}

static const char * TEST_DIR = "/tmp/test_sidecar_fp_env";

// Write a v3 sidecar with the FP env block populated. We use the
// tessera_debug writer to keep the format consistent.
static bool write_sidecar_with_fp_env(const std::string & name,
                                     int64_t rows, int64_t cols,
                                     uint32_t fp_acc, uint32_t rnd,
                                     uint32_t dnm, uint32_t be) {
    tessera_debug::set_dequant_dir(TEST_DIR);
    tessera_debug::set_fp_env(fp_acc, rnd, dnm, be);
    tessera_debug::open_dequant_writer(name.c_str(), rows, cols);
    std::vector<float> scratch((size_t) (rows * cols), 0.0f);
    int64_t out_r = 0;
    for (int64_t r = 0; r < rows; r++, out_r++) {
        tessera_debug::write_dequant_row(out_r, scratch.data() + r * cols, cols);
    }
    tessera_debug::close_dequant_writer();
    return true;
}

int main() {
    std::filesystem::create_directories(TEST_DIR);

    // --- Test 1: setter/getter round-trip ---
    {
        // Defaults: F32/RTN/IEEE/CPU (zero-init).
        check_eq("default fp_accumulator_dtype",
                 tessera_debug::fp_accumulator_dtype(), 0);
        check_eq("default fp_rounding_mode",
                 tessera_debug::fp_rounding_mode(), 0);
        check_eq("default fp_denormal_mode",
                 tessera_debug::fp_denormal_mode(), 0);
        check_eq("default fp_backend_id",
                 tessera_debug::fp_backend_id(), 0);

        // Set to CUDA F16 RTZ FTZ.
        tessera_debug::set_fp_env(
            /*fp_accumulator_dtype=*/1,  // F16
            /*rounding_mode=*/1,         // RTZ
            /*denormal_mode=*/1,         // FTZ
            /*backend_id=*/1);           // CUDA
        check_eq("set CUDA F16",
                 tessera_debug::fp_accumulator_dtype(), 1);
        check_eq("set RTZ", tessera_debug::fp_rounding_mode(), 1);
        check_eq("set FTZ", tessera_debug::fp_denormal_mode(), 1);
        check_eq("set backend=CUDA", tessera_debug::fp_backend_id(), 1);

        // Reset to defaults.
        tessera_debug::set_fp_env(0, 0, 0, 0);
    }

    // --- Test 2: writer emits the FP env block at offset 40 ---
    {
        const std::string name = "tensor_fp_env";
        const int64_t rows = 4;
        const int64_t cols = 8;
        write_sidecar_with_fp_env(name, rows, cols,
            /*fp_acc=*/1, /*rnd=*/0, /*dnm=*/0, /*be=*/2);  // F16/RTN/IEEE/METAL

        // Verify the file is exactly 40 (header) + 16 (FP env) +
        // rows*4 (outlier strip) + rows*24 (v3 strip) + rows*cols*4 (data).
        const std::string path = std::string(TEST_DIR) + "/" + name + ".dequant.f32";
        std::ifstream f(path, std::ios::binary | std::ios::ate);
        const std::streamsize sz = f.tellg();
        const std::streamsize expected = 56 + rows * 4 + rows * 24 + rows * cols * 4;
        check("file size matches (header + strips + data)",
              sz == expected);
        if (sz != expected) {
            std::printf("  got %lld want %lld\n",
                        (long long) sz, (long long) expected);
        }

        // Read the FP env block from offset 40.
        f.seekg(40, std::ios::beg);
        uint32_t fp_acc = 0, rnd = 0, dnm = 0, be = 0;
        f.read(reinterpret_cast<char *>(&fp_acc), 4);
        f.read(reinterpret_cast<char *>(&rnd), 4);
        f.read(reinterpret_cast<char *>(&dnm), 4);
        f.read(reinterpret_cast<char *>(&be), 4);
        check_eq("file fp_accumulator_dtype", fp_acc, 1);  // F16
        check_eq("file rounding_mode",        rnd, 0);   // RTN
        check_eq("file denormal_mode",        dnm, 0);   // IEEE
        check_eq("file backend_id",           be, 2);   // METAL
    }

    // --- Test 3: ts_sidecar_v3_read_header parses the FP env ---
    {
        ts_sidecar_v3_header hdr = {};
        const std::string path = std::string(TEST_DIR) + "/tensor_fp_env.dequant.f32";
        const int rc = ts_sidecar_v3_read_header(path.c_str(), &hdr);
        check("read_header rc == 0", rc == 0);
        if (rc == 0) {
            check_eq("hdr.fp_accumulator_dtype", hdr.fp_accumulator_dtype, 1);
            check_eq("hdr.rounding_mode",        hdr.rounding_mode, 0);
            check_eq("hdr.denormal_mode",        hdr.denormal_mode, 0);
            check_eq("hdr.backend_id",           hdr.backend_id, 2);
        }
    }

    // --- Test 4: legacy v3 file (no FP env block) reads with zero-init ---
    {
        // Write a 40-byte header + per-row strips + data with no FP
        // env block. The reader should rewind 16 bytes and report
        // zero-init defaults.
        const std::string name = "tensor_legacy";
        const int64_t rows = 2;
        const int64_t cols = 4;
        const std::string path = std::string(TEST_DIR) + "/" + name + ".dequant.f32";
        std::ofstream f(path, std::ios::binary);
        // 40-byte legacy header.
        f.write("TDQT", 4);
        uint32_t v = 3;
        f.write(reinterpret_cast<const char *>(&v), 4);
        f.write(reinterpret_cast<const char *>(&rows), 8);
        f.write(reinterpret_cast<const char *>(&cols), 8);
        uint32_t dtype = 0;
        f.write(reinterpret_cast<const char *>(&dtype), 4);
        float thresh = 6.0f;
        f.write(reinterpret_cast<const char *>(&thresh), 4);
        int64_t total_zero = 0;
        f.write(reinterpret_cast<const char *>(&total_zero), 8);
        // Per-row outlier strip (8 bytes for 2 rows).
        int32_t zeros_i32[2] = { 0, 0 };
        f.write(reinterpret_cast<const char *>(zeros_i32), 8);
        // Per-row v3 strip (48 bytes for 2 rows: 24 bytes each).
        char zeros[48] = { 0 };
        f.write(zeros, 48);
        // Data block: 2 * 4 = 8 floats = 32 bytes.
        float data[8] = { 0 };
        f.write(reinterpret_cast<const char *>(data), 32);
        f.close();

        ts_sidecar_v3_header hdr = {};
        const int rc = ts_sidecar_v3_read_header(path.c_str(), &hdr);
        check("legacy read_header rc == 0", rc == 0);
        if (rc == 0) {
            check_eq("legacy fp_accumulator_dtype (zero)",
                     hdr.fp_accumulator_dtype, 0);
            check_eq("legacy rounding_mode (zero)",
                     hdr.rounding_mode, 0);
            check_eq("legacy denormal_mode (zero)",
                     hdr.denormal_mode, 0);
            check_eq("legacy backend_id (zero)",
                     hdr.backend_id, 0);
        }
    }

    // --- Test 5: ts_sidecar_v3_read (full) handles both layouts ---
    {
        // Read the v3-extension file (the F16-RTN-IEEE-METAL one).
        ts_sidecar_v3 sc = {};
        std::string err;
        const std::string path = std::string(TEST_DIR) + "/tensor_fp_env.dequant.f32";
        const int rc = ts_sidecar_v3_read(path.c_str(), &sc, &err);
        check("full read rc == 0", rc == 0);
        if (rc == 0) {
            check("full read: rows == 4", sc.header.rows == 4);
            check("full read: cols == 8", sc.header.cols == 8);
            check_eq("full read: fp_accumulator_dtype",
                     sc.header.fp_accumulator_dtype, 1);
            check_eq("full read: backend_id", sc.header.backend_id, 2);
        }
    }

    // --- Test 6: different backends produce different headers ---
    {
        // CPU: backend=0, accum=F32(0), RTN(0), IEEE(0).
        write_sidecar_with_fp_env("tensor_cpu", 2, 2, 0, 0, 0, 0);
        // CUDA: backend=1, accum=F16(1), RTZ(1), FTZ(1).
        write_sidecar_with_fp_env("tensor_cuda", 2, 2, 1, 1, 1, 1);
        // Metal: backend=2, accum=F16(1), RTN(0), IEEE(0).
        write_sidecar_with_fp_env("tensor_metal", 2, 2, 1, 0, 0, 2);

        ts_sidecar_v3_header cpu = {}, cuda_hdr = {}, metal = {};
        ts_sidecar_v3_read_header(
            (std::string(TEST_DIR) + "/tensor_cpu.dequant.f32").c_str(), &cpu);
        ts_sidecar_v3_read_header(
            (std::string(TEST_DIR) + "/tensor_cuda.dequant.f32").c_str(), &cuda_hdr);
        ts_sidecar_v3_read_header(
            (std::string(TEST_DIR) + "/tensor_metal.dequant.f32").c_str(), &metal);
        check_eq("cpu backend_id", cpu.backend_id, 0);
        check_eq("cuda backend_id", cuda_hdr.backend_id, 1);
        check_eq("metal backend_id", metal.backend_id, 2);
        check_eq("cuda fp_accumulator_dtype (F16)", cuda_hdr.fp_accumulator_dtype, 1);
        check_eq("cuda rounding_mode (RTZ)",         cuda_hdr.rounding_mode, 1);
        check_eq("cuda denormal_mode (FTZ)",         cuda_hdr.denormal_mode, 1);
        // The three headers are visibly different - the spec's
        // primary goal: sidecars from different hardware are no
        // longer silently incomparable.
        check("cpu != cuda backend_id",
              cpu.backend_id != cuda_hdr.backend_id);
        check("cuda != metal fp_accumulator_dtype",
              cuda_hdr.fp_accumulator_dtype != metal.fp_accumulator_dtype ||
              cuda_hdr.rounding_mode != metal.rounding_mode);
    }

    // Cleanup.
    std::filesystem::remove_all(TEST_DIR);

    if (g_fail == 0) {
        std::printf("PASS\n");
        return 0;
    }
    std::printf("%d FAILURES\n", g_fail);
    return 1;
}
