//
// ggml-amd-tile-dump-dequant.cpp
//
// Tessera Layer 1 dequant sidecar helper for the HIP backend.
// See cuda-dump-dequant.cu and metal-dump-dequant.mm for the reference
// pattern. This implementation launches the T640 dequant kernel on the
// HIP stream, synchronizes, copies the result to host, and writes it
// to the sidecar via tessera_debug API.
//

#include "ggml-amd-tile-dump-dequant.h"
#include "ggml-amd-tile-hip.h"

#include "ggml.h"
#include "tessera-debug.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <vector>

void ggml_amd_hip_dump_dequant_tile640(
        hipStream_t stream,
        const struct ggml_tensor * op,
        int64_t row_width,
        int64_t n_rows,
        const char * name) {

    // Gate: no-op when the dequant sidecar is disabled.
    if (!tessera_debug::dequant_debug_enabled()) {
        return;
    }
    if (op == nullptr || name == nullptr) {
        return;
    }
    if (row_width <= 0 || n_rows <= 0) {
        return;
    }

    // Six Tile640 weight components: src[0..5].
    if (op->src[0] == nullptr || op->src[0]->data == nullptr) return;
    if (op->src[1] == nullptr || op->src[1]->data == nullptr) return;
    if (op->src[2] == nullptr || op->src[2]->data == nullptr) return;
    if (op->src[3] == nullptr || op->src[3]->data == nullptr) return;
    if (op->src[4] == nullptr || op->src[4]->data == nullptr) return;
    if (op->src[5] == nullptr || op->src[5]->data == nullptr) return;

    const int64_t n_elements = row_width * n_rows;
    const int64_t out_bytes  = n_elements * sizeof(float);

    // Allocate device scratch buffer.
    float * d_dst = nullptr;
    hipError_t err = hipMalloc(&d_dst, out_bytes);
    if (err != hipSuccess) {
        fprintf(stderr, "hip-dump-dequant-t640: '%s' failed to allocate %lld-byte buffer; skipping\n",
                name, (long long) out_bytes);
        return;
    }

    // Wall-clock timing for the v3 per-row meta strip.
    const auto t0 = std::chrono::steady_clock::now();

    // Launch the dequant kernel.
    ggml_amd_hip_tile640_dequant(
        stream,
        op->src[0]->data,  // packed
        op->src[1]->data,  // page_scales
        op->src[2]->data,  // lane_scales
        op->src[3]->data,  // outlier_row_offsets
        op->src[4]->data,  // outlier_cols
        op->src[5]->data,  // outlier_vals
        d_dst,
        (int) row_width,
        (int) n_rows);

    // Synchronize to ensure the kernel completes before the D2H copy.
    err = hipStreamSynchronize(stream);
    if (err != hipSuccess) {
        fprintf(stderr, "hip-dump-dequant-t640: '%s' kernel failed; skipping\n", name);
        hipFree(d_dst);
        return;
    }

    const auto t1 = std::chrono::steady_clock::now();
    const uint64_t total_ns =
        (uint64_t) std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
    const uint64_t per_row_ns = n_rows > 0 ? (total_ns / (uint64_t) n_rows) : 0;

    // Copy device buffer to host.
    std::vector<float> h_dst(n_elements);
    err = hipMemcpy(h_dst.data(), d_dst, out_bytes, hipMemcpyDeviceToHost);
    hipFree(d_dst);

    if (err != hipSuccess) {
        fprintf(stderr, "hip-dump-dequant-t640: '%s' D2H copy failed; skipping\n", name);
        return;
    }

    // kernel_id for the v3 per-row meta: a stable identifier for the HIP T640 dequant.
    const uint32_t kernel_id = 0x48495036; // "HIP6" in ASCII

    // Sidecar write.
    const int64_t stride = tessera_debug::dequant_stride();
    const int64_t captured_rows = (n_rows + stride - 1) / stride;

    tessera_debug::open_dequant_writer(name, captured_rows, row_width);
    int64_t out_r = 0;
    for (int64_t r = 0; r < n_rows; r += stride, out_r++) {
        tessera_debug::write_dequant_row(out_r, h_dst.data() + r * row_width, row_width);
        tessera_debug::set_dequant_row_meta(out_r, per_row_ns, kernel_id, /*dispatch_count=*/1);
    }
    tessera_debug::close_dequant_writer();

    // L1.5 FP16-reference sidecar: in W4A4 mode with F16 dtype (the default),
    // the L1.5 ground truth is the GPU's dequantized F32 weight cast to FP16.
    if (tessera_debug::dequant_w4a4_enabled() && tessera_debug::l15_dtype_is_f16()) {
        // The F16 L1.5 reference is no longer written by the runtime hook.
        // The dispatch's calibration-time capture produces F16 of the ORIGINAL
        // weight, which is the actual FP16 ground truth. The runtime hook's
        // L1.5 write path is preserved as a no-op for back-compat.
        //
        // If a legacy workflow needs the round-trip F16 L1.5, set
        // TESSERA_L15_RUNTIME_ROUNDTRIP=1 in the env to re-enable this path.
        if (std::getenv("TESSERA_L15_RUNTIME_ROUNDTRIP") != nullptr) {
            tessera_debug::open_fp16_reference_writer(name, captured_rows, row_width);
            out_r = 0;
            for (int64_t r = 0; r < n_rows; r += stride, out_r++) {
                const float * row = h_dst.data() + r * row_width;
                uint16_t stack_buf[256];
                uint16_t * fp16_row;
                std::vector<uint16_t> heap_buf;
                if ((size_t) row_width <= 256) {
                    fp16_row = stack_buf;
                } else {
                    heap_buf.resize((size_t) row_width);
                    fp16_row = heap_buf.data();
                }
                for (int64_t c = 0; c < row_width; c++) {
                    fp16_row[c] = (uint16_t) ggml_fp32_to_fp16(row[c]);
                }
                tessera_debug::write_fp16_reference_row(out_r, fp16_row, row_width);
                tessera_debug::set_fp16_reference_row_meta(out_r, per_row_ns,
                                                           kernel_id,
                                                           /*dispatch_count=*/1);
            }
            tessera_debug::close_fp16_reference_writer();
        }
    }
}
