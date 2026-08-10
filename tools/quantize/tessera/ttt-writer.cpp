//
// ttt-writer.cpp
//
// Tessera tile-neutral safetensors writer implementation. Serializes a
// ts_ternary_model to a standard HuggingFace-compatible directory:
// config.json + model.safetensors (+ optional tokenizer.json /
// chat_template.jinja), sharded when the total tensor data exceeds 5 GiB.
//
// The safetensors binary format is:
//   [u64 LE header_length][JSON header bytes][raw data bytes]
// The JSON header maps each tensor name to
//   {"dtype": "I8"|"I32"|"F16"|"F32", "shape": [dims...],
//    "data_offsets": [start, end]}
// where data_offsets are byte offsets RELATIVE TO THE START OF THE DATA
// SECTION (i.e. after the 8-byte length prefix + header). Per-shard data
// offsets are independent (each shard's data section starts at 0).
//
// config.json is a standard HF model config with typed hparams (integers
// emitted as JSON integers, not strings), plus a `ternary_tensors` dict.
//
// See ttt-writer.h for the API contract and docs/tile-neutral-export-design.md
// for the architecture.
//

#include "ttt-writer.h"

#include <nlohmann/json.hpp>

#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <system_error>
#include <vector>

#if defined(_WIN32)
#  include <io.h>      // _access
#  include <direct.h>  // _mkdir
#endif

using json = nlohmann::json;

// ---- helpers -------------------------------------------------------------

namespace {

// Above this total tensor byte count the writer splits into
// model-00001-of-0000N.safetensors shards of at most this size, plus a
// model.safetensors.index.json. The HF default shard size is ~5 GiB.
constexpr int64_t TS_SHARD_SIZE = (int64_t) 5 * 1024 * 1024 * 1024;

// mkdir -p equivalent that ignores EEXIST. Uses the POSIX mkdir walk from
// tessera-higgs-cache.cpp; on Windows _mkdir has no separate mode arg.
void ts_mkdirs(const std::string & path) {
    std::string cur;
    for (size_t i = 0; i < path.size(); i++) {
        cur += path[i];
        if (path[i] == '/' || i + 1 == path.size()) {
#if defined(_WIN32)
            _mkdir(cur.c_str());
#else
            mkdir(cur.c_str(), 0755);
#endif
        }
    }
}

// Copy a source file to a destination path verbatim. Returns true on success.
bool ts_copy_file(const std::string & src, const std::string & dst) {
    std::ifstream in(src, std::ios::binary);
    if (!in) return false;
    std::ofstream out(dst, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out << in.rdbuf();
    return out.good();
}

// Write a little-endian u64 (the safetensors header length prefix).
void ts_write_u64_le(std::ofstream & f, uint64_t v) {
    char b[8];
    for (int i = 0; i < 8; i++) {
        b[i] = (char) ((v >> (8 * i)) & 0xFF);
    }
    f.write(b, 8);
}

// One flat array contribution to the safetensors file. We collect these
// per-tensor into an offset table, then emit header + data in two passes.
struct array_entry {
    std::string key;        // safetensors tensor name, e.g. "blk.0.attn_q.weight.trits"
    std::string dtype;      // "I8" / "I32" / "F16" / "F32"
    std::vector<int64_t> shape;
    const void * data;      // raw bytes (native LE, matching safetensors)
    int64_t nbytes;
};

// Append one of the model's array buffers to the entries vector with the
// matching dtype + shape. Templated so we get the element size + the right
// dtype string without macro duplication.
template <typename T>
void ts_add_array(std::vector<array_entry> & out,
                  const std::string & key,
                  const std::string & dtype,
                  const std::vector<T> & buf,
                  std::vector<int64_t> shape) {
    array_entry e;
    e.key    = key;
    e.dtype  = dtype;
    e.shape  = std::move(shape);
    e.data   = buf.data();
    e.nbytes = (int64_t) buf.size() * (int64_t) sizeof(T);
    out.push_back(std::move(e));
}

// Specialization for the scalar float fields (global_amp / best_alpha): they
// are 1-element F32 tensors backed by a pointer to the float field itself
// (the model outlives the write call).
void ts_add_scalar(std::vector<array_entry> & out,
                   const std::string & key,
                   const float * p) {
    array_entry e;
    e.key    = key;
    e.dtype  = "F32";
    e.shape  = std::vector<int64_t>{1};
    e.data   = p;
    e.nbytes = (int64_t) sizeof(float);
    out.push_back(std::move(e));
}

// Collect every array for one ternary tensor, in the fixed order documented
// in ttt-writer.h. Skip arrays that are allowed to be empty (act_scale).
void ts_collect_arrays(const std::string & name,
                       const ts_ternary_tensor & t,
                       std::vector<array_entry> & out) {
    const int64_t n_elems = t.n_elements();
    const int64_t in_dim  = t.in_dim;
    const int64_t out_dim = t.out_dim;
    const int64_t nnz     = (int64_t) t.outlier_cols.size();

    ts_add_array(out, name + ".trits",               "I8",  t.trits,                 {n_elems});
    ts_add_array(out, name + ".outlier_row_offsets", "I32", t.outlier_row_offsets,   {out_dim + 1});
    ts_add_array(out, name + ".outlier_cols",        "I32", t.outlier_cols,          {nnz});
    ts_add_array(out, name + ".outlier_vals",        "F16", t.outlier_vals,          {nnz});
    ts_add_array(out, name + ".awq_scale",           "F32", t.awq_scale,             {in_dim});
    ts_add_array(out, name + ".awq_input_scale",     "F32", t.awq_input_scale,       {in_dim});

    // core is NOT shipped: the transport artifact carries trits + global_amp
    // + outliers, which is sufficient for the packer to reconstruct page/lane
    // scales for any tile geometry. This keeps the transport at ~half the BF16
    // size instead of 2.5x.
    // (empty when AWQ alpha resolved to 0). The reader treats its absence as
    // "no act_scale" and leaves the vector empty.
    if (!t.act_scale.empty()) {
        ts_add_array(out, name + ".act_scale", "F16", t.act_scale, {in_dim});
    }

    ts_add_scalar(out, name + ".global_amp", &t.global_amp);
    ts_add_scalar(out, name + ".best_alpha", &t.best_alpha);
}

// Build the safetensors JSON header for the supplied entries (a single shard
// or the whole file). Populates each entry's data_offsets (cumulative byte
// offset within this shard's data section) and returns the serialized header
// string. The caller controls the iteration range so the same routine serves
// the single-file and sharded paths.
std::string ts_build_safetensors_header(std::vector<array_entry>::iterator begin,
                                        std::vector<array_entry>::iterator end) {
    json header = json::object();
    // The optional top-level __metadata__ key is a safetensors convention for
    // arbitrary file-level metadata. The safetensors spec requires every
    // metadata value to be a STRING (the Rust model is HashMap<String, String>);
    // an integer value causes the official reader to reject the whole header.
    // We stamp the format id + version so a reader can identify a tessera
    // safetensors file by its header alone, even without the sibling config.json.
    header["__metadata__"] = {
        {"format",  "tessera-ternary-transport"},
        {"version", "1"},
    };

    int64_t cursor = 0;
    for (auto it = begin; it != end; ++it) {
        json te = json::object();
        te["dtype"] = it->dtype;
        te["shape"] = it->shape;
        const int64_t start = cursor;
        const int64_t end   = cursor + it->nbytes;
        te["data_offsets"] = json::array({start, end});
        header[it->key] = std::move(te);
        cursor = end;
    }
    // safetensors requires the JSON header to end with exactly one trailing
    // 0x0A (newline); the reference Rust writer rejects anything else. We
    // let nlohmann/json emit compact JSON, then ensure the trailing newline.
    std::string s = header.dump();
    s.push_back('\n');
    return s;
}

// Write [u64 header_len][header bytes][raw data bytes for every entry] to
// the file at path. Iterates [begin, end). Streams each entry's data directly
// from its data pointer so the only in-RAM buffering is the header string.
int ts_emit_safetensors(const std::string & path,
                        std::vector<array_entry>::iterator begin,
                        std::vector<array_entry>::iterator end,
                        std::string & err) {
    std::string header = ts_build_safetensors_header(begin, end);
    const uint64_t header_len = (uint64_t) header.size();

    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) {
        err = "cannot open " + path + " for writing";
        return 1;
    }

    ts_write_u64_le(f, header_len);
    f.write(header.data(), (std::streamsize) header_len);

    for (auto it = begin; it != end; ++it) {
        if (it->nbytes > 0) {
            if (!it->data) {
                err = "internal error: null data pointer for " + it->key;
                return 1;
            }
            f.write(static_cast<const char *>(it->data), (std::streamsize) it->nbytes);
        }
        if (!f.good()) {
            err = "write error while emitting " + it->key;
            return 1;
        }
    }
    return 0;
}

// Promote a GGUF-KV-style stringified value to a typed JSON node so config.json
// hparams come out as proper integers/floats/bools. Mirrors the inverse of
// ts_pack_set_hparam in quantize.cpp: bool first, then integer, then float,
// else leave as string. nlohmann::json infers integer vs floating from the
// parsed value: a parsed long long becomes JSON number (integer form), a parsed
// double with a fractional part becomes JSON number (float form).
json ts_hparam_to_json(const std::string & v) {
    if (v == "true")  return true;
    if (v == "false") return false;
    {
        char * end = nullptr;
        errno = 0;
        const long long iv = std::strtoll(v.c_str(), &end, 10);
        if (end != v.c_str() && *end == '\0' && errno == 0 &&
            iv >= LLONG_MIN && iv <= LLONG_MAX) {
            return (int64_t) iv;
        }
    }
    {
        char * end = nullptr;
        const double dv = std::strtod(v.c_str(), &end);
        if (end != v.c_str() && *end == '\0' && std::isfinite(dv)) {
            return dv;
        }
    }
    return v;
}

// Build the config.json contents for the model as a standard HF model config.
// `tensors_json` is the already-built ternary_tensors inventory (a JSON
// object mapping each tensor name to {out_dim, in_dim}); the caller supplies
// it so the streaming path can build it incrementally without ever holding
// the whole ts_ternary_model. hparams values are strings (GGUF KV style); we
// promote numerics to typed JSON so the file reads as a real model config.
std::string ts_build_config_json(const std::string & arch,
                                 const std::map<std::string, std::string> & hparams,
                                 const json & tensors_json) {
    json cfg = json::object();

    // Standard HF model config keys.
    cfg["architectures"] = json::array({"TesseraTernary"});
    cfg["model_type"]    = "tessera-ternary";
    cfg["auto_map"]      = json::object();
    // tessera format provenance: not standard HF, but useful for tooling and
    // harmless to generic readers (HF ignores unknown top-level keys).
    cfg["tessera_format"] = "tessera-ternary-transport";
    cfg["tessera_version"] = (int64_t) 1;
    if (!arch.empty()) {
        cfg["tessera_arch"] = arch;
    }

    // Promote GGUF KV hparams to typed top-level keys so standard HF tooling
    // sees integer model dimensions. GGUF KV keys are dotted (e.g.
    // "llama.context_length", "general.architecture") so they cannot collide
    // with the structural keys added above. The reader re-collects them by
    // ignoring that fixed structural set, so the round-trip back into the
    // pack path's GGUF header is lossless.
    for (const auto & kv : hparams) {
        cfg[kv.first] = ts_hparam_to_json(kv.second);
    }

    cfg["ternary_tensors"] = tensors_json;

    return cfg.dump(2);
}

// Build the config.json contents from a fully-materialized model. Convenience
// wrapper around the (arch, hparams, tensors_json) overload for callers that
// already have the whole ts_ternary_model in RAM.
std::string ts_build_config_json(const ts_ternary_model & model) {
    json tensors = json::object();
    for (const auto & kv : model.tensors) {
        json te = json::object();
        te["out_dim"] = kv.second.out_dim;
        te["in_dim"]  = kv.second.in_dim;
        tensors[kv.first] = std::move(te);
    }
    return ts_build_config_json(model.arch, model.hparams, tensors);
}

// Zero-pad n to width w (e.g. w=5, n=1 -> "00001").
std::string ts_padded(int n, int w) {
    std::string s = std::to_string(n);
    if ((int) s.size() < w) {
        s = std::string(w - s.size(), '0') + s;
    }
    return s;
}

} // anonymous namespace

// ---- public API ----------------------------------------------------------

int ts_write_ttt(const ts_ternary_model & model,
                 const std::string & out_dir,
                 const std::string & tokenizer_path,
                 const std::string & chat_template_path) {
    if (out_dir.empty()) {
        fprintf(stderr, "ts_write_ttt: empty output directory\n");
        return 1;
    }

    // Create the directory if it doesn't exist. Ignore EEXIST (ts_mkdirs
    // already does). The trailing slash is tolerated by the walk.
    ts_mkdirs(out_dir);

    const std::string sep = (out_dir.back() == '/') ? "" : "/";
    const std::string cfg_path   = out_dir + sep + "config.json";
    const std::string tok_path   = out_dir + sep + "tokenizer.json";
    const std::string chat_path  = out_dir + sep + "chat_template.jinja";

    // config.json
    {
        const std::string cfg = ts_build_config_json(model);
        std::ofstream f(cfg_path, std::ios::binary | std::ios::trunc);
        if (!f) {
            fprintf(stderr, "ts_write_ttt: cannot open %s for writing\n", cfg_path.c_str());
            return 1;
        }
        f.write(cfg.data(), (std::streamsize) cfg.size());
        if (!f.good()) {
            fprintf(stderr, "ts_write_ttt: write error on %s\n", cfg_path.c_str());
            return 1;
        }
    }

    // tokenizer.json + chat_template.jinja (verbatim copies if provided)
    if (!tokenizer_path.empty()) {
        if (!ts_copy_file(tokenizer_path, tok_path)) {
            fprintf(stderr, "ts_write_ttt: cannot copy tokenizer %s -> %s\n",
                    tokenizer_path.c_str(), tok_path.c_str());
            return 1;
        }
    }
    if (!chat_template_path.empty()) {
        if (!ts_copy_file(chat_template_path, chat_path)) {
            fprintf(stderr, "ts_write_ttt: cannot copy chat template %s -> %s\n",
                    chat_template_path.c_str(), chat_path.c_str());
            return 1;
        }
    }

    // safetensors: collect every per-tensor array, compute offsets, then
    // emit either a single model.safetensors or sharded
    // model-NNNNN-of-NNNNN.safetensors + model.safetensors.index.json.
    // Empty arrays are legal in safetensors (start == end), so we don't drop
    // them: the reader needs the keys present to know which buffers a tensor
    // has. The only exception is act_scale, whose ABSENCE signals
    // "no act_scale" (see ts_collect_arrays).
    //
    // A tensor's arrays are kept contiguous in the entries vector and never
    // split across shards, so a streaming reader only touches one shard per
    // tensor.
    std::vector<array_entry> entries;
    entries.reserve(model.tensors.size() * 9);
    // Per-tensor [begin, end) range into `entries` and its summed byte size,
    // used to keep each tensor's arrays in a single shard.
    struct tensor_range { int64_t begin; int64_t end; int64_t bytes; };
    std::vector<tensor_range> tensor_ranges;
    tensor_ranges.reserve(model.tensors.size());
    for (const auto & kv : model.tensors) {
        const int64_t begin = (int64_t) entries.size();
        ts_collect_arrays(kv.first, kv.second, entries);
        const int64_t end = (int64_t) entries.size();
        int64_t bytes = 0;
        for (int64_t k = begin; k < end; k++) bytes += entries[k].nbytes;
        tensor_ranges.push_back({begin, end, bytes});
    }

    // Total raw data size drives the single-vs-sharded decision.
    int64_t total_size = 0;
    for (const auto & e : entries) {
        total_size += e.nbytes;
    }

    std::string err;
    if (total_size <= TS_SHARD_SIZE) {
        // Single file. The standard HF name is model.safetensors.
        const std::string st_path = out_dir + sep + "model.safetensors";
        if (ts_emit_safetensors(st_path, entries.begin(), entries.end(), err) != 0) {
            fprintf(stderr, "ts_write_ttt: %s\n", err.c_str());
            return 1;
        }
        return 0;
    }

    // Sharded. Group whole tensors into shards: keep accumulating tensors
    // while the shard is empty OR the next tensor fits in the remaining
    // budget. A tensor larger than the cap lands in its own shard (we always
    // make progress because the first tensor in a shard is admitted
    // unconditionally). A tensor's arrays never straddle two shards.
    std::vector<std::pair<int64_t, int64_t>> shard_ranges;  // [entry_begin, entry_end)
    {
        int64_t shard_begin = 0;     // entry index where the current shard starts
        int64_t shard_bytes = 0;     // bytes accumulated in the current shard
        for (int64_t ti = 0; ti < (int64_t) tensor_ranges.size(); ti++) {
            const tensor_range & tr = tensor_ranges[ti];
            // first tensor in an empty shard is always admitted, so a single
            // tensor larger than the cap still gets its own shard.
            const bool first_in_shard = (tr.begin == shard_begin);
            if (!first_in_shard && shard_bytes + tr.bytes > TS_SHARD_SIZE) {
                // flush the current shard at this tensor's boundary.
                shard_ranges.emplace_back(shard_begin, tr.begin);
                shard_begin = tr.begin;
                shard_bytes = 0;
            }
            shard_bytes += tr.bytes;
        }
        // flush trailing shard (always non-empty: the loop admits at least
        // the first tensor, and tensor_ranges is non-empty here because
        // total_size > TS_SHARD_SIZE implies at least one tensor).
        shard_ranges.emplace_back(shard_begin, (int64_t) entries.size());
    }
    const int n_shards = (int) shard_ranges.size();

    // Emit each shard file and record the weight_map (array key -> shard
    // filename). Use the HF shard-name convention model-NNNNN-of-NNNNN.
    json weight_map = json::object();
    for (int s = 0; s < n_shards; s++) {
        const std::string fname =
            "model-" + ts_padded(s + 1, 5) + "-of-" + ts_padded(n_shards, 5) + ".safetensors";
        const std::string fpath = out_dir + sep + fname;

        const int64_t sb = shard_ranges[s].first;
        const int64_t se = shard_ranges[s].second;
        if (ts_emit_safetensors(fpath,
                                entries.begin() + sb,
                                entries.begin() + se,
                                err) != 0) {
            fprintf(stderr, "ts_write_ttt: %s\n", err.c_str());
            return 1;
        }
        for (int64_t k = sb; k < se; k++) {
            weight_map[entries[k].key] = fname;
        }
    }

    // model.safetensors.index.json: the standard HF index.
    json index = json::object();
    json metadata = json::object();
    metadata["total_size"] = total_size;
    index["metadata"] = std::move(metadata);
    index["weight_map"] = std::move(weight_map);

    const std::string index_path = out_dir + sep + "model.safetensors.index.json";
    const std::string index_text = index.dump(2) + "\n";
    {
        std::ofstream f(index_path, std::ios::binary | std::ios::trunc);
        if (!f) {
            fprintf(stderr, "ts_write_ttt: cannot open %s for writing\n", index_path.c_str());
            return 1;
        }
        f.write(index_text.data(), (std::streamsize) index_text.size());
        if (!f.good()) {
            fprintf(stderr, "ts_write_ttt: write error on %s\n", index_path.c_str());
            return 1;
        }
    }

    return 0;
}

// ---- streaming API -------------------------------------------------------
//
// ts_write_ttt_stream pulls one tensor at a time from `source`, spools each
// tensor's raw arrays to a sibling temp file, then emits the final
// safetensors shard(s) from the spool. The spool holds at most one copy of
// the model's ternary data on disk; RSS stays bounded by one tensor's
// arrays because the source is free to clear its buffer between yields.
//
// The on-disk layout is identical to ts_write_ttt: a single model.safetensors
// for <= 5 GiB of tensor data, else sharded model-NNNNN-of-NNNNN.safetensors
// + model.safetensors.index.json. config.json is written from the arch +
// hparams supplied up front plus the inventory built from the stream.

namespace {

// One spooled array's metadata. The raw bytes live in the spool file at
// [spool_off, spool_off + nbytes). Keeping only the metadata in RAM (no
// data pointer) lets the streaming path hold thousands of arrays cheaply.
struct spool_entry {
    std::string key;
    std::string dtype;
    std::vector<int64_t> shape;
    int64_t nbytes;
    int64_t spool_off;      // byte offset within the spool file
};

// Per-tensor [begin, end) range into the spool entries vector plus the
// summed byte size; mirrors ts_write_ttt's tensor_range so the same shard
// grouping logic applies (a tensor's arrays never straddle two shards).
struct spool_tensor_range {
    int64_t begin;
    int64_t end;
    int64_t bytes;
};

// Emit one shard from the spool: write [u64 header_len][header][data...] to
// `path`, where the data for each entry in [begin, end) is read from the
// spool file at the entry's recorded offset. The header is identical to
// ts_build_safetensors_header's output (built from a transient vector of
// in-memory array_entry views over the spool entries, reusing the existing
// helper so the two paths stay byte-equivalent).
int ts_emit_safetensors_from_spool(const std::string & path,
                                    const std::vector<spool_entry> & entries,
                                    int64_t begin, int64_t end,
                                    const std::string & spool_path,
                                    std::string & err) {
    // Build the header via the same routine the in-memory path uses, by
    // projecting the spool entries into array_entry views. The data pointers
    // are not dereferenced here (the entries only feed dtype/shape/nbytes
    // into the header), so dangling pointers are harmless; we set them to
    // nullptr for clarity.
    std::vector<array_entry> views;
    views.reserve((size_t)(end - begin));
    for (int64_t i = begin; i < end; i++) {
        array_entry e;
        e.key    = entries[(size_t)i].key;
        e.dtype  = entries[(size_t)i].dtype;
        e.shape  = entries[(size_t)i].shape;
        e.data   = nullptr;
        e.nbytes = entries[(size_t)i].nbytes;
        views.push_back(std::move(e));
    }
    std::string header = ts_build_safetensors_header(views.begin(), views.end());
    const uint64_t header_len = (uint64_t) header.size();

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        err = "cannot open " + path + " for writing";
        return 1;
    }
    ts_write_u64_le(out, header_len);
    out.write(header.data(), (std::streamsize) header_len);
    if (!out.good()) {
        err = "write error on header of " + path;
        return 1;
    }

    // Stream each entry's bytes straight from the spool to the output. We
    // copy in modest chunks so the peak RSS during the emit pass is bounded
    // by the chunk size, not by the largest tensor.
    std::ifstream spool(spool_path, std::ios::binary);
    if (!spool) {
        err = "cannot reopen spool " + spool_path;
        return 1;
    }
    constexpr int64_t CHUNK = 1 << 20;  // 1 MiB copy buffer
    std::vector<char> buf((size_t) CHUNK);
    for (int64_t i = begin; i < end; i++) {
        const spool_entry & se = entries[(size_t)i];
        if (se.nbytes == 0) continue;
        spool.clear();
        spool.seekg((std::streamoff) se.spool_off, std::ios::beg);
        if (!spool) {
            err = "spool seek failed for " + se.key;
            return 1;
        }
        int64_t remaining = se.nbytes;
        while (remaining > 0) {
            const std::streamsize want = (std::streamsize) std::min<int64_t>(CHUNK, remaining);
            spool.read(buf.data(), want);
            if (!spool || spool.gcount() != want) {
                err = "spool short read for " + se.key;
                return 1;
            }
            out.write(buf.data(), want);
            if (!out.good()) {
                err = "write error while emitting " + se.key;
                return 1;
            }
            remaining -= want;
        }
    }
    return 0;
}

// Append one raw byte range to the spool file, returning the byte offset
// where it landed. Returns -1 on write failure and sets err.
int64_t ts_spool_write(std::ofstream & spool,
                       const void * data, int64_t nbytes,
                       std::string & err) {
    if (nbytes == 0) {
        const std::streamoff pos = spool.tellp();
        return pos < 0 ? 0 : (int64_t) pos;
    }
    const std::streamoff off = spool.tellp();
    if (off < 0) {
        err = "spool: tellp failed";
        return -1;
    }
    spool.write(static_cast<const char *>(data), (std::streamsize) nbytes);
    if (!spool.good()) {
        err = "spool: write failed";
        return -1;
    }
    return (int64_t) off;
}

// spool_entry analog of ts_add_array: append one of the tensor's in-memory
// buffers to the spool and record its metadata. Mirrors the in-memory
// ts_add_array so the two paths produce identical headers.
template <typename T>
void ts_spool_add_array(std::ofstream & spoolf,
                        std::vector<spool_entry> & out,
                        const std::string & key,
                        const std::string & dtype,
                        const std::vector<T> & buf,
                        std::vector<int64_t> shape,
                        std::string & err,
                        bool & ok) {
    if (!ok) return;
    spool_entry e;
    e.key    = key;
    e.dtype  = dtype;
    e.shape  = std::move(shape);
    e.nbytes = (int64_t) buf.size() * (int64_t) sizeof(T);
    e.spool_off = ts_spool_write(spoolf, buf.data(), e.nbytes, err);
    if (e.spool_off < 0) {
        ok = false;
        return;
    }
    out.push_back(std::move(e));
}

// spool_entry analog of ts_add_scalar: the global_amp/best_alpha fields are
// 1-element F32 tensors backed by a pointer to the float field. Spool the
// single float and record the metadata.
void ts_spool_add_scalar(std::ofstream & spoolf,
                         std::vector<spool_entry> & out,
                         const std::string & key,
                         const float * p,
                         std::string & err,
                         bool & ok) {
    if (!ok) return;
    spool_entry e;
    e.key    = key;
    e.dtype  = "F32";
    e.shape  = std::vector<int64_t>{1};
    e.nbytes = (int64_t) sizeof(float);
    e.spool_off = ts_spool_write(spoolf, p, e.nbytes, err);
    if (e.spool_off < 0) {
        ok = false;
        return;
    }
    out.push_back(std::move(e));
}

// Spool every array for one ternary tensor, in the fixed order documented in
// ttt-writer.h. Mirrors ts_collect_arrays so the streaming and in-memory
// paths emit identical keys/shapes/dtypes.
void ts_spool_collect_arrays(std::ofstream & spoolf,
                             const std::string & name,
                             const ts_ternary_tensor & t,
                             std::vector<spool_entry> & out,
                             std::string & err,
                             bool & ok) {
    const int64_t n_elems = t.n_elements();
    const int64_t in_dim  = t.in_dim;
    const int64_t out_dim = t.out_dim;
    const int64_t nnz     = (int64_t) t.outlier_cols.size();

    ts_spool_add_array(spoolf, out, name + ".trits",               "I8",  t.trits,                 {n_elems}, err, ok);
    ts_spool_add_array(spoolf, out, name + ".outlier_row_offsets", "I32", t.outlier_row_offsets,   {out_dim + 1}, err, ok);
    ts_spool_add_array(spoolf, out, name + ".outlier_cols",        "I32", t.outlier_cols,          {nnz}, err, ok);
    ts_spool_add_array(spoolf, out, name + ".outlier_vals",        "F16", t.outlier_vals,          {nnz}, err, ok);
    ts_spool_add_array(spoolf, out, name + ".awq_scale",           "F32", t.awq_scale,             {in_dim}, err, ok);
    ts_spool_add_array(spoolf, out, name + ".awq_input_scale",     "F32", t.awq_input_scale,       {in_dim}, err, ok);

    // core is NOT shipped (see ts_write_ttt comment).
    // (empty when AWQ alpha resolved to 0). The reader treats its absence as
    // "no act_scale" and leaves the vector empty.
    if (!t.act_scale.empty()) {
        ts_spool_add_array(spoolf, out, name + ".act_scale", "F16", t.act_scale, {in_dim}, err, ok);
    }

    ts_spool_add_scalar(spoolf, out, name + ".global_amp", &t.global_amp, err, ok);
    ts_spool_add_scalar(spoolf, out, name + ".best_alpha", &t.best_alpha, err, ok);
}

} // anonymous namespace

int ts_write_ttt_stream(const ts_ttt_tensor_source & source,
                        const std::string & arch,
                        const std::map<std::string, std::string> & hparams,
                        const std::string & out_dir,
                        const std::string & tokenizer_path,
                        const std::string & chat_template_path) {
    if (out_dir.empty()) {
        fprintf(stderr, "ts_write_ttt_stream: empty output directory\n");
        return 1;
    }
    if (!source) {
        fprintf(stderr, "ts_write_ttt_stream: null tensor source\n");
        return 1;
    }

    ts_mkdirs(out_dir);
    const std::string sep = (out_dir.back() == '/') ? "" : "/";
    const std::string cfg_path   = out_dir + sep + "config.json";
    const std::string tok_path   = out_dir + sep + "tokenizer.json";
    const std::string chat_path  = out_dir + sep + "chat_template.jinja";
    const std::string spool_path = out_dir + sep + ".model.safetensors.spool";

    // tokenizer.json + chat_template.jinja (verbatim copies if provided).
    // Done up front so a failure here aborts before any tensor work.
    if (!tokenizer_path.empty()) {
        if (!ts_copy_file(tokenizer_path, tok_path)) {
            fprintf(stderr, "ts_write_ttt_stream: cannot copy tokenizer %s -> %s\n",
                    tokenizer_path.c_str(), tok_path.c_str());
            return 1;
        }
    }
    if (!chat_template_path.empty()) {
        if (!ts_copy_file(chat_template_path, chat_path)) {
            fprintf(stderr, "ts_write_ttt_stream: cannot copy chat template %s -> %s\n",
                    chat_template_path.c_str(), chat_path.c_str());
            return 1;
        }
    }

    // Spool pass: pull one tensor at a time, append its arrays to the spool
    // file, and record per-array metadata + per-tensor byte ranges. The
    // source is free to clear its buffer between calls, so RSS is bounded by
    // one tensor's arrays. The inventory (config.json's ternary_tensors) is
    // built incrementally alongside the spool.
    std::ofstream spoolf(spool_path, std::ios::binary | std::ios::trunc);
    if (!spoolf) {
        fprintf(stderr, "ts_write_ttt_stream: cannot open spool %s for writing\n",
                spool_path.c_str());
        return 1;
    }

    std::vector<spool_entry> entries;
    std::vector<spool_tensor_range> tensor_ranges;
    json tensors_json = json::object();
    int64_t total_size = 0;
    std::string err;
    bool ok = true;
    int64_t n_tensors = 0;

    ts_ternary_tensor tn;
    while (ok) {
        std::string name = source(tn);
        if (name.empty()) break;

        const int64_t begin = (int64_t) entries.size();
        ts_spool_collect_arrays(spoolf, name, tn, entries, err, ok);
        const int64_t end = (int64_t) entries.size();
        if (!ok) break;

        int64_t bytes = 0;
        for (int64_t k = begin; k < end; k++) bytes += entries[(size_t)k].nbytes;
        tensor_ranges.push_back({begin, end, bytes});
        total_size += bytes;

        json te = json::object();
        te["out_dim"] = tn.out_dim;
        te["in_dim"]  = tn.in_dim;
        tensors_json[name] = std::move(te);
        n_tensors++;
    }

    if (!ok) {
        fprintf(stderr, "ts_write_ttt_stream: %s\n", err.c_str());
        spoolf.close();
        std::remove(spool_path.c_str());
        return 1;
    }
    // Flush + close the spool before reopening for read; an open ofstream
    // is not guaranteed to be readable on all platforms.
    spoolf.flush();
    spoolf.close();

    // config.json (written after the spool pass so the inventory is complete).
    {
        const std::string cfg = ts_build_config_json(arch, hparams, tensors_json);
        std::ofstream f(cfg_path, std::ios::binary | std::ios::trunc);
        if (!f) {
            fprintf(stderr, "ts_write_ttt_stream: cannot open %s for writing\n", cfg_path.c_str());
            std::remove(spool_path.c_str());
            return 1;
        }
        f.write(cfg.data(), (std::streamsize) cfg.size());
        if (!f.good()) {
            fprintf(stderr, "ts_write_ttt_stream: write error on %s\n", cfg_path.c_str());
            std::remove(spool_path.c_str());
            return 1;
        }
    }

    if (n_tensors == 0) {
        // No tensors yielded: config.json is already a valid (empty) record.
        // Remove the empty spool so the output dir is clean.
        std::remove(spool_path.c_str());
        return 0;
    }

    // Emit pass: single file or sharded, mirroring ts_write_ttt's grouping.
    // The data comes from the spool via ts_emit_safetensors_from_spool.
    int rc = 0;
    if (total_size <= TS_SHARD_SIZE) {
        const std::string st_path = out_dir + sep + "model.safetensors";
        if (ts_emit_safetensors_from_spool(st_path, entries,
                                           0, (int64_t) entries.size(),
                                           spool_path, err) != 0) {
            fprintf(stderr, "ts_write_ttt_stream: %s\n", err.c_str());
            rc = 1;
        }
    } else {
        // Group whole tensors into shards (same rule as ts_write_ttt: a
        // tensor's arrays never straddle two shards; a tensor larger than
        // the cap lands in its own shard).
        std::vector<std::pair<int64_t, int64_t>> shard_ranges;
        int64_t shard_begin = 0;
        int64_t shard_bytes = 0;
        for (int64_t ti = 0; ti < (int64_t) tensor_ranges.size(); ti++) {
            const spool_tensor_range & tr = tensor_ranges[(size_t)ti];
            const bool first_in_shard = (tr.begin == shard_begin);
            if (!first_in_shard && shard_bytes + tr.bytes > TS_SHARD_SIZE) {
                shard_ranges.emplace_back(shard_begin, tr.begin);
                shard_begin = tr.begin;
                shard_bytes = 0;
            }
            shard_bytes += tr.bytes;
        }
        shard_ranges.emplace_back(shard_begin, (int64_t) entries.size());
        const int n_shards = (int) shard_ranges.size();

        json weight_map = json::object();
        for (int s = 0; s < n_shards && rc == 0; s++) {
            const std::string fname =
                "model-" + ts_padded(s + 1, 5) + "-of-" + ts_padded(n_shards, 5) + ".safetensors";
            const std::string fpath = out_dir + sep + fname;
            const int64_t sb = shard_ranges[s].first;
            const int64_t se = shard_ranges[s].second;
            if (ts_emit_safetensors_from_spool(fpath, entries, sb, se,
                                               spool_path, err) != 0) {
                fprintf(stderr, "ts_write_ttt_stream: %s\n", err.c_str());
                rc = 1;
                break;
            }
            for (int64_t k = sb; k < se; k++) {
                weight_map[entries[(size_t)k].key] = fname;
            }
        }
        if (rc == 0) {
            json index = json::object();
            json metadata = json::object();
            metadata["total_size"] = total_size;
            index["metadata"] = std::move(metadata);
            index["weight_map"] = std::move(weight_map);
            const std::string index_path = out_dir + sep + "model.safetensors.index.json";
            const std::string index_text = index.dump(2) + "\n";
            std::ofstream f(index_path, std::ios::binary | std::ios::trunc);
            if (!f) {
                fprintf(stderr, "ts_write_ttt_stream: cannot open %s for writing\n", index_path.c_str());
                rc = 1;
            } else {
                f.write(index_text.data(), (std::streamsize) index_text.size());
                if (!f.good()) {
                    fprintf(stderr, "ts_write_ttt_stream: write error on %s\n", index_path.c_str());
                    rc = 1;
                }
            }
        }
    }

    // The spool is a build artifact; always remove it on completion.
    std::remove(spool_path.c_str());
    return rc;
}
