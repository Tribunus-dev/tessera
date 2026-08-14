//
// tessera-activation-sidecar.cpp
//
// See tessera-activation-sidecar.h for the format and design notes.
//

#include "tessera-activation-sidecar.h"
#include "tessera-debug.h"
#include "tessera-sidecar-v3.h"

#include <cstdio>
#include <filesystem>
#include <fstream>

namespace {

// Per-row v3 metadata strip layout (24 bytes/row: timing_ns u64,
// kernel_id u32, dispatch_count u32, reserved u64), matching
// ts_sidecar_v3_row_meta exactly. Written as all-zero here since kernel
// timing does not apply to a captured activation sample.
struct row_v3_meta_zero {
    uint64_t timing_ns      = 0;
    uint32_t kernel_id      = 0;
    uint32_t dispatch_count = 0;
    uint64_t reserved       = 0;
};

}  // namespace

int ts_activation_sidecar_write(const char * dir, const char * tensor_name,
                                const char * suffix,
                                int64_t rows, int64_t cols,
                                const uint16_t * data_f16,
                                std::string * err_msg) {
    if (dir == nullptr || tensor_name == nullptr || suffix == nullptr ||
        rows <= 0 || cols <= 0 || data_f16 == nullptr) {
        if (err_msg) *err_msg = "invalid arguments";
        return -1;
    }

    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec) {
        if (err_msg) *err_msg = "failed to create dir '" + std::string(dir) +
                                 "': " + ec.message();
        return -1;
    }

    const std::filesystem::path out_path =
        std::filesystem::path(dir) / (std::string(tensor_name) + suffix);

    std::ofstream ofs(out_path, std::ios::binary | std::ios::out | std::ios::trunc);
    if (!ofs.is_open()) {
        if (err_msg) *err_msg = "failed to open '" + out_path.string() + "' for writing";
        return -1;
    }

    // 56-byte v3 header, byte-for-byte matching common/tessera-debug/
    // tessera-debug.cpp's sidecar_open_impl (see this file's header
    // comment for the offset derivation). outlier_threshold and
    // outlier_count_total are meaningless for activation samples; both
    // are written as zero (not "patched" at close, since there is
    // nothing to accumulate).
    ofs.write(tessera_debug::DEQUANT_FILE_MAGIC, 4);
    const uint32_t version = tessera_debug::DEQUANT_FILE_VERSION;
    ofs.write(reinterpret_cast<const char *>(&version), sizeof(version));
    ofs.write(reinterpret_cast<const char *>(&rows), sizeof(rows));
    ofs.write(reinterpret_cast<const char *>(&cols), sizeof(cols));
    const uint32_t dtype = tessera_debug::DEQUANT_DTYPE_F16;
    ofs.write(reinterpret_cast<const char *>(&dtype), sizeof(dtype));
    const float   outlier_threshold = 0.0f;
    const int64_t outlier_count_total = 0;
    ofs.write(reinterpret_cast<const char *>(&outlier_threshold), sizeof(outlier_threshold));
    ofs.write(reinterpret_cast<const char *>(&outlier_count_total), sizeof(outlier_count_total));
    const uint32_t fp_env_zero[4] = {0, 0, 0, 0};  // accumulator/rounding/denormal/backend
    ofs.write(reinterpret_cast<const char *>(fp_env_zero), sizeof(fp_env_zero));

    // Per-row outlier-count strip (rows * 4 bytes), all zero.
    {
        const std::vector<int32_t> zeros((size_t) rows, 0);
        ofs.write(reinterpret_cast<const char *>(zeros.data()),
                  (std::streamsize) (zeros.size() * sizeof(int32_t)));
    }
    // Per-row v3 meta strip (rows * 24 bytes), all zero.
    {
        const std::vector<row_v3_meta_zero> zeros((size_t) rows);
        ofs.write(reinterpret_cast<const char *>(zeros.data()),
                  (std::streamsize) (zeros.size() * sizeof(row_v3_meta_zero)));
    }

    // Data block: rows * cols F16 values, row-major.
    ofs.write(reinterpret_cast<const char *>(data_f16),
              (std::streamsize) (rows * cols * (int64_t) sizeof(uint16_t)));

    if (!ofs) {
        if (err_msg) *err_msg = "write failed for '" + out_path.string() + "'";
        return -1;
    }
    return 0;
}

int ts_activation_sidecar_load(const char * dir, const char * tensor_name,
                               const char * suffix,
                               std::vector<float> * out_data,
                               int64_t * out_rows, int64_t * out_cols) {
    if (dir == nullptr || tensor_name == nullptr || suffix == nullptr || out_data == nullptr) {
        return -1;
    }
    const std::filesystem::path path =
        std::filesystem::path(dir) / (std::string(tensor_name) + suffix);

    ts_sidecar_v3 sc;
    std::string err;
    if (ts_sidecar_v3_read(path.string().c_str(), &sc, &err) != 0) {
        return -1;  // missing file or parse failure -- "no capture data"
    }
    if (sc.header.dtype != tessera_debug::DEQUANT_DTYPE_F16) {
        std::fprintf(stderr,
                     "tessera-activation-sidecar: '%s' has unexpected dtype %u (expected F16)\n",
                     path.string().c_str(), sc.header.dtype);
        return -1;
    }

    *out_data = std::move(sc.data);
    if (out_rows) *out_rows = sc.header.rows;
    if (out_cols) *out_cols = sc.header.cols;
    return 0;
}
