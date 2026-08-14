#pragma once

//
// tessera-activation-sidecar.h
//
// Real per-tensor activation capture sidecar: writer + reader for the
// train/heldout activation samples produced by llama-imatrix's
// --activation-capture mode (pipeline refactor stage 5) and consumed by
// ts_dispatch_run_gaprep (stage 3) as ts_awq_layer::train_activations /
// heldout_activations.
//
// One file per tensor per split, in a directory (matching the L1/L1.5
// sidecar convention, tools/quantize/tessera/tessera-dispatch-l15.cpp --
// a directory of per-tensor files, not one shared archive, so "no
// capture data for this tensor" is a natural missing-file case and
// on-demand per-tensor loading needs no seek table):
//   <dir>/<tensor_name>.act_train.f16
//   <dir>/<tensor_name>.act_heldout.f16
//
// On-disk format: v3-compatible with common/tessera-debug/
// tessera-sidecar-v3.h's reader (ts_sidecar_v3_read) -- same header
// layout (magic/version/rows/cols/dtype/outlier_threshold/
// outlier_count_total/fp_env), same-shaped per-row outlier-count and
// per-row-meta strips. Neither outlier counts nor kernel-timing meta
// apply to captured activation samples, so both strips are always
// written as zero here; ts_sidecar_v3_read still parses the file
// correctly since it does not require those fields to be non-zero.
//
// Written in one shot (all rows already assembled in memory --
// activation-capture's bounded reservoir sample is small, default 512
// train / 128 heldout rows -- unlike the L1/L1.5 dequant hooks this
// format was designed for, which stream row-by-row from a live kernel
// callback), so this is a single write/read call rather than the L1.5
// writer's stateful open/write-row/close sequence.
//

#include <cstdint>
#include <string>
#include <vector>

// Write `rows` x `cols` F16 values (row-major, already-converted F16
// bit patterns) to <dir>/<tensor_name><suffix> as a v3-format-compatible
// sidecar. Creates `dir` if it does not already exist. Returns 0 on
// success, -1 on error (err_msg, if non-null, receives a description).
int ts_activation_sidecar_write(const char * dir, const char * tensor_name,
                                const char * suffix,
                                int64_t rows, int64_t cols,
                                const uint16_t * data_f16,
                                std::string * err_msg);

// Load <dir>/<tensor_name><suffix> into `out_data` (F16 on disk, upcast
// to F32 by ts_sidecar_v3_read). Returns 0 on success (out_data resized
// to rows*cols, *out_rows/*out_cols set to the file's shape) or nonzero
// when the file is missing, fails to parse, or its dtype is not F16
// (out_data left untouched). Both a missing file and a parse failure
// are treated by callers as "no capture data for this tensor," not an
// error to propagate -- ts_dispatch_run_gaprep's fallback to the
// diagonal weight-space error handles that case with no other changes.
int ts_activation_sidecar_load(const char * dir, const char * tensor_name,
                               const char * suffix,
                               std::vector<float> * out_data,
                               int64_t * out_rows, int64_t * out_cols);
