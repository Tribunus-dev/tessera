#pragma once

//
// ttt-writer.h
//
// Tessera tile-neutral safetensors writer. Serializes a ts_ternary_model to
// a standard HuggingFace-compatible directory:
//   <out_dir>/config.json              (typed HF model config)
//   <out_dir>/model.safetensors        (single file, or sharded)
//   <out_dir>/model-00001-of-0000N.safetensors + model.safetensors.index.json
//   <out_dir>/tokenizer.json           (only if tokenizer_path non-empty)
//   <out_dir>/chat_template.jinja      (only if chat_template_path non-empty)
//
// The artifact is plain safetensors that any HF tooling can load: no custom
// reader is required. The safetensors binary format is the standard one
// (8-byte LE header length, JSON header describing each tensor's
// dtype/shape/data_offsets, then the raw bytes).
//
// config.json is a standard HF model config: typed hparams (integers emitted
// as JSON integers, not strings), `architectures`, `model_type`, and a
// `ternary_tensors` dict mapping each tensor name to {out_dim, in_dim}.
//
// Two entry points are provided:
//   - ts_write_ttt           loads the whole ts_ternary_model into RAM; fine
//                            for small models.
//   - ts_write_ttt_stream    pulls one tensor at a time from a callback, so
//                            RSS stays bounded by one tensor regardless of
//                            model size. The callback spools each tensor's
//                            arrays to a temp file, then the writer emits the
//                            final safetensors shard(s) from the spool. This
//                            is the path the export-ternary handler uses so a
//                            35 GB ternary model does not OOM a 17 GB host.
//
// See tessera-ternary.h for the struct definitions and
// docs/tile-neutral-export-design.md for the architecture.
//

#include <cstdint>
#include <functional>
#include <string>

#include "tessera-ternary.h"

// Write a ternary model to a standard HF-compatible directory. Creates the
// directory if it doesn't exist. Streams one tensor at a time to bound RAM.
// Copies tokenizer_path and chat_template_path into the directory if non-empty
// (as tokenizer.json and chat_template.jinja respectively).
//
// The directory layout written is:
//   <out_dir>/config.json
//   <out_dir>/model.safetensors           (when total tensor data <= 5 GiB)
//   <out_dir>/model-00001-of-0000N.safetensors + model.safetensors.index.json
//                                         (when total tensor data >  5 GiB)
//   <out_dir>/tokenizer.json              (only if tokenizer_path non-empty)
//   <out_dir>/chat_template.jinja         (only if chat_template_path non-empty)
//
// For each tensor <name> in model.tensors, the safetensors file(s) carry:
//   <name>.trits                 I8  [out_dim * in_dim]
//   <name>.outlier_row_offsets    I32 [out_dim + 1]
//   <name>.outlier_cols           I32 [nnz]
//   <name>.outlier_vals           F16 [nnz]
//   <name>.awq_scale              F32 [in_dim]
//   <name>.awq_input_scale        F32 [in_dim]
//   <name>.core                   F32 [out_dim * in_dim]
//   <name>.act_scale              F16 [in_dim]   (only if non-empty)
//   <name>.global_amp             F32 scalar (1-element tensor)
//   <name>.best_alpha             F32 scalar (1-element tensor)
//
// When sharded, a tensor's arrays always land in the same shard so a
// streaming reader only needs to touch one shard per tensor.
//
// Returns 0 on success, non-zero on error.
int ts_write_ttt(const ts_ternary_model & model,
                 const std::string & out_dir,
                 const std::string & tokenizer_path = "",
                 const std::string & chat_template_path = "");

// Streaming tensor source for ts_write_ttt_stream. Each call fills `tensor`
// with the next tensor's arrays and returns its name; returning an empty name
// signals end-of-stream. The buffers in `tensor` are only valid until the
// next call: ts_write_ttt_stream spools each tensor's bytes to a temp file
// before invoking the source again, so the caller may reuse or clear the
// buffer between yields. This mirrors the ts_ttt_tensor_stream::next contract
// on the reader side, so a source backed by the reader can round-trip a
// directory without holding two copies of any tensor.
using ts_ttt_tensor_source = std::function<std::string(ts_ternary_tensor & tensor)>;

// Streaming variant of ts_write_ttt for models too large to materialize in
// RAM. Pulls one tensor at a time from `source`, spools each tensor's raw
// arrays to a sibling temp file (<out_dir>/.model.safetensors.spool), then
// emits the final safetensors shard(s) from the spool and removes it. The
// arch + hparams are supplied up front so config.json can be written without
// buffering every tensor. The per-tensor inventory in config.json is built
// from the stream itself.
//
// The on-disk layout and per-tensor array set are identical to ts_write_ttt;
// the two writers produce byte-equivalent directories for the same input.
// The spool file holds at most one copy of the model's ternary data on disk
// during the write; RSS stays bounded by one tensor's arrays.
//
// Returns 0 on success, non-zero on error.
int ts_write_ttt_stream(const ts_ttt_tensor_source & source,
                        const std::string & arch,
                        const std::map<std::string, std::string> & hparams,
                        const std::string & out_dir,
                        const std::string & tokenizer_path = "",
                        const std::string & chat_template_path = "");
