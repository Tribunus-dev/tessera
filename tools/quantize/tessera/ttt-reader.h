#pragma once

//
// ttt-reader.h
//
// Tessera tile-neutral safetensors reader. Loads a standard
// HuggingFace-compatible directory (config.json + model.safetensors, or
// sharded model-NNNNN-of-NNNNN.safetensors + model.safetensors.index.json)
// written by ttt-writer back into a ts_ternary_model (full load) or yields
// tensors one at a time via ts_ttt_tensor_stream (streaming, bounded RAM).
//
// The reader uses only the standard safetensors binary format, so it would
// also load any safetensors file produced by HF tooling as long as the keys
// follow the tessera per-array naming convention. No custom on-disk format
// is involved.
//
// See ttt-writer.h for the directory layout and tessera-ternary.h for the
// struct definitions.
//

#include <cstdint>
#include <string>

#include "tessera-ternary.h"

// Read a safetensors directory into a ternary model (full load into RAM).
// Reads config.json (arch + hparams + tensor inventory) then loads every
// tensor's arrays from model.safetensors (or the shards named by
// model.safetensors.index.json). Returns 0 on success, non-zero on error.
//
// For large models prefer ts_ttt_tensor_stream, which yields one tensor at
// a time so the caller (e.g. the client-side tile packer) can process each
// tensor before the next is loaded.
int ts_read_ttt(const std::string & dir, ts_ternary_model & model);

// Streaming reader: yields one tensor at a time. The caller processes each
// tensor (e.g. packs it to a tile) before the next is loaded, bounding RAM
// to one tensor's worth of arrays regardless of model size.
//
// Usage:
//   ts_ttt_tensor_stream s;
//   if (s.open(dir)) { /* error */ }
//   ts_ternary_tensor t;
//   std::string name;
//   while (!(name = s.next(t)).empty()) {
//       // process t (e.g. pack to T640)
//   }
//   s.close();
//
// The stream reads tensors in config.json inventory order. Because a
// tensor's arrays always live in a single shard, the stream keeps at most
// one shard file open at a time and reopens only when the next tensor lives
// in a different shard. The model's arch and hparams are available after
// open() via arch() and hparams().
struct ts_ttt_tensor_stream {
    // Opens the safetensors dir, reads config.json, opens model.safetensors
    // (or the first shard referenced by model.safetensors.index.json), and
    // prepares to iterate tensors. Returns 0 on success, non-zero on error.
    int open(const std::string & dir);

    // Returns the next tensor name + data, or an empty name when done.
    // On a non-empty return, `tensor` is populated with that tensor's
    // arrays; the buffers are reused across calls (cleared at next() entry)
    // so the caller must copy out anything it needs to retain.
    std::string next(ts_ternary_tensor & tensor);

    // Release the open file handle(s). Safe to call multiple times; the
    // destructor also calls it.
    void close();

    // Accessors for metadata read by open(). arch() is empty before open().
    const std::string & arch() const;
    const std::map<std::string, std::string> & hparams() const;

    ~ts_ttt_tensor_stream();
    ts_ttt_tensor_stream();
    ts_ttt_tensor_stream(const ts_ttt_tensor_stream &) = delete;
    ts_ttt_tensor_stream & operator=(const ts_ttt_tensor_stream &) = delete;
    ts_ttt_tensor_stream(ts_ttt_tensor_stream &&) = delete;
    ts_ttt_tensor_stream & operator=(ts_ttt_tensor_stream &&) = delete;

private:
    struct impl;
    impl * p_;
};
