//
// tessera-dispatch-l15.cpp
//
// L1.5 FP16 reference capture (§3 of docs/l1-l6-telemetry-refinements-spec.md).
// See tessera-dispatch.h for the contract.
//
// The L1.5 sidecar is the FP16 ground truth that the kernel's dequant
// output is compared against. The legacy runtime-hook path produced it
// by converting the F32 dequant output to FP16 (a round-trip), which
// collapsed L3's per-row cosine to ~1.0 by construction. This module
// replaces that with a calibration-time capture: for each 2D weight
// tensor in the input GGUF, write F16 of the ORIGINAL (BF16/FP16)
// weight to the L1.5 sidecar directory.
//
// The F16 cast is done row-by-row via ggml_fp32_to_fp16_row. The
// per-row outlier count and timing strip are populated identically to
// the L1 sidecar's (kernel_id = 0 for unquantized; dispatch_count = 0
// because this is a calibration-time pass, not a runtime hook — the L6
// fitness treats kernel_id==0 as "calibration reference" and
// dispatch_count==0 as "no runtime cost").
//

#include "tessera-dispatch.h"

#include "tessera-debug.h"

#include "ggml.h"
#include "gguf.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

// True when the tensor is a 2D weight that L1.5 capture should produce
// a sidecar for. Skips 1D tensors (norms, biases), 3D+ tensors
// (expert stacks, embeddings, image patches), and quantized input
// (the dispatch expects a BF16/FP16 source GGUF).
bool is_l15_capture_target(const struct ggml_tensor * t) {
    if (t == nullptr) {
        return false;
    }
    // ggml_tensor::name is a fixed-size char array (GGML_MAX_NAME);
    // the empty-name check is the closest equivalent to a null check.
    if (t->name[0] == '\0') {
        return false;
    }
    if (ggml_is_quantized(t->type)) {
        return false;
    }
    if (t->type != GGML_TYPE_F16 && t->type != GGML_TYPE_BF16 &&
        t->type != GGML_TYPE_F32) {
        return false;
    }
    if (ggml_n_dims(t) != 2) {
        return false;
    }
    if (t->data == nullptr) {
        return false;
    }
    return true;
}

}  // namespace

int ts_dispatch_capture_l15_references(
    const struct gguf_context * on_input,
    struct ggml_context * ggml_ctx,
    const std::string & sidecar_dir,
    int64_t stride,
    std::string * err_msg) {
    if (on_input == nullptr || ggml_ctx == nullptr) {
        if (err_msg) *err_msg = "ts_dispatch_capture_l15_references: null input";
        return 1;
    }
    if (sidecar_dir.empty()) {
        // No sidecar dir configured. Treat as a no-op (the L1.5 file
        // is a calibration-time convenience; nothing breaks if it
        // isn't written).
        return 0;
    }
    if (!tessera_debug::dequant_w4a4_enabled()) {
        // W4A4 mode is the L1.5 trigger. Without it, the dispatch
        // never reads the L1.5 sidecar (L3 is gated on the same flag).
        return 0;
    }
    if (!tessera_debug::l15_dtype_is_f16()) {
        // The F32 legacy path is handled by the runtime hook's
        // auto-populate branch; calibration-time F32 capture would
        // duplicate work.
        return 0;
    }
    if (stride <= 0) {
        stride = 1;
    }

    // Configure the L1.5 sidecar directory and dtype. set_dequant_dir
    // is the runtime hook's config; the dispatch is the calibration-
    // time writer so it sets the same global before calling the
    // open_fp16_reference_writer entry point. set_l15_dtype is the
    // dtype selector; "f16" was already verified above.
    tessera_debug::set_dequant_dir(sidecar_dir);
    tessera_debug::set_l15_dtype("f16");

    const int64_t n_tensors = gguf_get_n_tensors(on_input);
    int n_captured = 0;
    int n_skipped  = 0;
    int n_failed   = 0;

    for (int64_t i = 0; i < n_tensors; i++) {
        const char * tname = gguf_get_tensor_name(on_input, i);
        if (tname == nullptr) {
            continue;
        }
        struct ggml_tensor * t = ggml_get_tensor(ggml_ctx, tname);
        if (!is_l15_capture_target(t)) {
            n_skipped++;
            continue;
        }

        // ggml 2D weight convention: ne[0] = K (cols), ne[1] = N (rows).
        // The L1 sidecar uses (rows, cols) = (ne[1], ne[0]) for the
        // per-row strip; match that for the L1.5 so the L3 cosine
        // reader sees the same row index.
        const int64_t cols = t->ne[0];
        const int64_t rows = t->ne[1];
        const int64_t captured_rows = (rows + stride - 1) / stride;
        const int64_t nelems = (int64_t) ggml_nelements(t);

        // The open function returns void; the L1.5 file is created
        // lazily in write_fp16_reference_row. We open unconditionally
        // and rely on the writer's invariant (open + N writes + close
        // per tensor). Failure of an open is treated as a hard error
        // for the row, but we still attempt the writes (the writer
        // may still produce a valid file if the env was misconfigured
        // mid-run).
        tessera_debug::open_fp16_reference_writer(tname, captured_rows, cols);

        // F32 staging buffer (one row at a time). ggml_fp32_to_fp16_row
        // needs an F32 input; we stage the row in F32 regardless of the
        // source dtype (the F32 -> F16 path is the same shape for all
        // input dtypes; the source conversion is via ggml_bf16_to_fp32
        // or ggml_fp16_to_fp32 per element).
        std::vector<float>   f32_row((size_t) cols, 0.0f);
        std::vector<uint16_t> fp16_row((size_t) cols, 0);

        int64_t out_r = 0;
        for (int64_t r = 0; r < rows; r += stride, out_r++) {
            // Fill f32_row from the source. The mmap'd region is
            // row-major (ne[0] floats per row, ne[1] rows for a 2D
            // tensor).
            const char * src = (const char *) t->data + (size_t) r * (size_t) cols * ggml_type_size(t->type);
            if (t->type == GGML_TYPE_F32) {
                std::memcpy(f32_row.data(), src, (size_t) cols * sizeof(float));
            } else if (t->type == GGML_TYPE_F16) {
                const ggml_fp16_t * src16 = (const ggml_fp16_t *) src;
                for (int64_t c = 0; c < cols; c++) {
                    f32_row[(size_t) c] = ggml_fp16_to_fp32(src16[c]);
                }
            } else {  // GGML_TYPE_BF16
                const ggml_bf16_t * srcbf = (const ggml_bf16_t *) src;
                for (int64_t c = 0; c < cols; c++) {
                    f32_row[(size_t) c] = ggml_bf16_to_fp32(srcbf[c]);
                }
            }

            // F32 -> F16 with proper rounding.
            ggml_fp32_to_fp16_row(f32_row.data(), fp16_row.data(), cols);

            // kernel_id = 0 marks the row as "calibration reference",
            // not a runtime dequant output. The L6 fitness and L3
            // reader can distinguish (kernel_id != 0 means runtime).
            // dispatch_count = 0 because there is no runtime kernel
            // cost associated with this row.
            tessera_debug::write_fp16_reference_row(out_r, fp16_row.data(), cols);
            tessera_debug::set_fp16_reference_row_meta(out_r,
                /*timing_ns=*/0,
                /*kernel_id=*/0,
                /*dispatch_count=*/0);
        }
        tessera_debug::close_fp16_reference_writer();
        n_captured++;
        (void) nelems;
    }

    if (n_failed > 0 && err_msg) {
        *err_msg = "ts_dispatch_capture_l15_references: " + std::to_string(n_failed) +
                   " tensors failed to open the L1.5 sidecar (out of " +
                   std::to_string(n_tensors) + " total; " + std::to_string(n_captured) +
                   " captured, " + std::to_string(n_skipped) + " skipped)";
    }
    return n_failed > 0 ? 1 : 0;
}
