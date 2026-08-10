//
// ttt-reader.cpp
//
// Tessera tile-neutral safetensors reader implementation. Loads a standard
// HuggingFace-compatible directory (config.json + model.safetensors, or
// sharded model-NNNNN-of-NNNNN.safetensors + model.safetensors.index.json)
// back into a ts_ternary_model, either as a full load (ts_read_ttt) or one
// tensor at a time (ts_ttt_tensor_stream).
//
// The safetensors binary format read here mirrors the writer's emit step:
//   [u64 LE header_length][JSON header bytes][raw data bytes]
// The JSON header maps each tensor name to {dtype, shape, data_offsets},
// where data_offsets are byte offsets relative to the start of the data
// section. We parse each shard's header once, then read each array by
// seeking to data_section_off + data_offsets[0] within the right shard.
//
// See ttt-reader.h for the API contract and ttt-writer.cpp for the writer
// side of the format.
//

#include "ttt-reader.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using json = nlohmann::json;

// ---- helpers -------------------------------------------------------------

namespace {

// Read the entire file at `path` into `out`. Returns true on success.
bool ts_read_whole_file(const std::string & path, std::string & out) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return false;
    const std::streamoff size = f.tellg();
    if (size < 0) return false;
    f.seekg(0, std::ios::beg);
    out.resize((size_t) size);
    if (size > 0) {
        f.read(&out[0], size);
    }
    return f.good() || f.eof();
}

// Parsed descriptor for one safetensors array.
struct st_entry {
    std::string dtype;
    std::vector<int64_t> shape;
    int64_t data_start;  // byte offset within the data section of its shard
    int64_t nbytes;
    std::string shard;   // filename of the owning shard ("" for single file)
};

// Parsed safetensors header for one shard + the absolute byte offset of its
// data section. Kept small so it can be shared across many tensor reads
// without re-parsing.
struct st_header {
    // name -> entry
    std::map<std::string, st_entry> entries;
    // Absolute file offset where the raw data section begins
    // (= 8 + header_length).
    int64_t data_section_off = 0;
};

// Parse a safetensors file's header from an open stream positioned anywhere.
// On success, fills `out` and returns 0. `file_size` is the stat'd size,
// used only for the basic sanity check that the declared header length fits
// in the file.
int ts_parse_safetensors_header(std::ifstream & f,
                                int64_t file_size,
                                st_header & out,
                                const std::string & shard_name,
                                std::string & err) {
    char len_buf[8];
    f.clear();
    f.seekg(0, std::ios::beg);
    f.read(len_buf, 8);
    if (!f || f.gcount() != 8) {
        err = "safetensors: truncated header length prefix";
        return 1;
    }
    uint64_t header_len = 0;
    for (int i = 0; i < 8; i++) {
        header_len |= ((uint64_t) (uint8_t) len_buf[i]) << (8 * i);
    }
    if (file_size >= 0 && (int64_t) (8 + header_len) > file_size) {
        err = "safetensors: declared header length exceeds file size";
        return 1;
    }

    std::string header_str;
    header_str.resize((size_t) header_len);
    if (header_len > 0) {
        f.read(&header_str[0], (std::streamsize) header_len);
        if (!f || f.gcount() != (std::streamsize) header_len) {
            err = "safetensors: truncated header";
            return 1;
        }
    }

    json j;
    try {
        j = json::parse(header_str);
    } catch (const std::exception & e) {
        err = std::string("safetensors: invalid JSON header: ") + e.what();
        return 1;
    }

    out.data_section_off = (int64_t) (8 + header_len);
    for (auto it = j.begin(); it != j.end(); ++it) {
        // The optional top-level __metadata__ key carries file-level metadata;
        // it is not a tensor and must be skipped.
        if (it.key() == "__metadata__") continue;
        const json & te = it.value();
        if (!te.is_object() || !te.contains("dtype") || !te.contains("data_offsets")) {
            // Ignore anything that doesn't look like a tensor entry rather
            // than failing hard; the writer's header only ever contains
            // tensors + __metadata__, so this is defensive.
            continue;
        }
        st_entry e;
        e.dtype = te["dtype"].get<std::string>();
        e.shard = shard_name;
        if (te.contains("shape") && te["shape"].is_array()) {
            for (const auto & s : te["shape"]) {
                e.shape.push_back(s.get<int64_t>());
            }
        }
        const auto & offs = te["data_offsets"];
        if (!offs.is_array() || offs.size() != 2) {
            err = "safetensors: bad data_offsets for " + it.key();
            return 1;
        }
        e.data_start = offs[0].get<int64_t>();
        e.nbytes     = offs[1].get<int64_t>() - e.data_start;
        out.entries[it.key()] = std::move(e);
    }
    return 0;
}

// Read one array's raw bytes from an open stream. The stream must already be
// open on the shard owning this entry; we seek to data_section_off + data_start.
// Returns true on success and reads nbytes into dst.
bool ts_read_array(std::ifstream & f,
                   int64_t data_section_off,
                   const st_entry & e,
                   void * dst,
                   std::string & err) {
    if (e.nbytes == 0) {
        return true;
    }
    f.clear();
    f.seekg((std::streamoff) (data_section_off + e.data_start), std::ios::beg);
    if (!f) {
        err = "safetensors: seek failed";
        return false;
    }
    f.read(static_cast<char *>(dst), (std::streamsize) e.nbytes);
    if (!f || f.gcount() != (std::streamsize) e.nbytes) {
        err = "safetensors: short read";
        return false;
    }
    return true;
}

// Lookup-or-default for a header entry. Returns nullptr when the key is
// absent (e.g. optional act_scale).
const st_entry * ts_find(const std::map<std::string, st_entry> & h, const std::string & key) {
    auto it = h.find(key);
    return it == h.end() ? nullptr : &it->second;
}

// Templated read helper: read an array of T into the destination vector,
// validating that nbytes matches shape * sizeof(T). The shape is already
// known per-tensor from config.json, so this just reads the raw bytes; the
// dtype/size check is a defensive guard against a malformed header.
template <typename T>
bool ts_read_typed(std::ifstream & f,
                   int64_t data_section_off,
                   const st_entry & e,
                   std::vector<T> & out,
                   std::string & err) {
    if ((size_t) e.nbytes % sizeof(T) != 0) {
        err = "size mismatch for array (" + std::to_string(e.nbytes) +
              " bytes not divisible by " + std::to_string(sizeof(T)) + ")";
        return false;
    }
    out.resize((size_t) e.nbytes / sizeof(T));
    return ts_read_array(f, data_section_off, e, out.data(), err);
}

// Read one ternary tensor's arrays from the open stream. The tensor name
// is the GGUF-style name (e.g. "blk.0.attn_q.weight"); the safetensors keys
// are <name>.trits etc. out_dim / in_dim are taken from the inventory
// (config.json), not from the array shapes, so the caller must populate
// them on the tensor before calling this. `headers` is the full
// array-key -> entry map (across all shards in the merged view); the
// caller is responsible for opening the shard owning each entry before the
// read.
bool ts_read_tensor_arrays(std::ifstream & f,
                           const st_header & shard_header,
                           const std::map<std::string, st_entry> & merged,
                           const std::string & name,
                           ts_ternary_tensor & t,
                           std::string & err) {
    const int64_t n_elems = t.n_elements();
    const int64_t out_dim = t.out_dim;
    const int64_t in_dim  = t.in_dim;
    const int64_t expect_row_offsets = out_dim + 1;
    const int64_t expect_awq        = in_dim;

    if (const st_entry * e = ts_find(merged, name + ".trits")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.trits, err)) return false;
        if ((int64_t) t.trits.size() != n_elems) {
            err = "trits size mismatch for " + name;
            return false;
        }
    }
    if (const st_entry * e = ts_find(merged, name + ".outlier_row_offsets")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.outlier_row_offsets, err)) return false;
        if ((int64_t) t.outlier_row_offsets.size() != expect_row_offsets) {
            err = "outlier_row_offsets size mismatch for " + name;
            return false;
        }
    }
    if (const st_entry * e = ts_find(merged, name + ".outlier_cols")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.outlier_cols, err)) return false;
    }
    if (const st_entry * e = ts_find(merged, name + ".outlier_vals")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.outlier_vals, err)) return false;
        if (t.outlier_vals.size() != t.outlier_cols.size()) {
            err = "outlier_vals/cols size mismatch for " + name;
            return false;
        }
    }
    if (const st_entry * e = ts_find(merged, name + ".awq_scale")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.awq_scale, err)) return false;
        if ((int64_t) t.awq_scale.size() != expect_awq) {
            err = "awq_scale size mismatch for " + name;
            return false;
        }
    }
    if (const st_entry * e = ts_find(merged, name + ".awq_input_scale")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.awq_input_scale, err)) return false;
        if ((int64_t) t.awq_input_scale.size() != expect_awq) {
            err = "awq_input_scale size mismatch for " + name;
            return false;
        }
    }
    // core is optional: the tile-neutral transport format does NOT ship it
    // (the packer reconstructs magnitudes from trits + global_amp). Legacy
    // artifacts that do carry it can still be read; the packer uses it when
    // present and falls back to the global_amp approximation when absent.
    if (const st_entry * e = ts_find(merged, name + ".core")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.core, err)) return false;
    }
    // act_scale is optional: absence => leave the vector empty.
    if (const st_entry * e = ts_find(merged, name + ".act_scale")) {
        if (!ts_read_typed(f, shard_header.data_section_off, *e, t.act_scale, err)) return false;
        if ((int64_t) t.act_scale.size() != in_dim) {
            err = "act_scale size mismatch for " + name;
            return false;
        }
    }
    if (const st_entry * e = ts_find(merged, name + ".global_amp")) {
        float v = 0.0f;
        if (!ts_read_array(f, shard_header.data_section_off, *e, &v, err)) return false;
        t.global_amp = v;
    }
    if (const st_entry * e = ts_find(merged, name + ".best_alpha")) {
        float v = 0.0f;
        if (!ts_read_array(f, shard_header.data_section_off, *e, &v, err)) return false;
        t.best_alpha = v;
    }
    return true;
}

// Parse the safetensors directory's config.json: arch, hparams, and the
// tensor inventory (ordered vector of {name, out_dim, in_dim}). config.json
// is a standard HF model config with typed hparams; the structural keys we
// set in the writer are ignored when collecting hparams so the round-trip
// back to GGUF KV pairs is well-defined.
struct cfg_tensor { std::string name; int64_t out_dim; int64_t in_dim; };

// Top-level keys the writer emits that are NOT GGUF hparams. Anything else
// at the top level is treated as a GGUF KV (stringified for the model's
// std::map<std::string,std::string>).
const std::set<std::string> & ts_structural_keys() {
    static const std::set<std::string> s = {
        "architectures",
        "model_type",
        "auto_map",
        "tessera_format",
        "tessera_version",
        "tessera_arch",
        "ternary_tensors",
    };
    return s;
}

// Stringify a typed JSON hparam value back to the GGUF KV string form.
// Mirrors ts_hparam_to_json in the writer: integers/floats/bools render in
// their canonical decimal form.
std::string ts_json_to_hparam(const json & v) {
    if (v.is_boolean()) {
        return v.get<bool>() ? "true" : "false";
    }
    if (v.is_number_integer() || v.is_number_unsigned()) {
        return std::to_string(v.get<int64_t>());
    }
    if (v.is_number_float()) {
        return std::to_string(v.get<double>());
    }
    if (v.is_string()) {
        return v.get<std::string>();
    }
    // Arrays/objects are not hparams; serialize their JSON form defensively.
    return v.dump();
}

int ts_parse_config(const std::string & cfg_text,
                    std::string & arch,
                    std::map<std::string, std::string> & hparams,
                    std::vector<cfg_tensor> & tensors,
                    std::string & err) {
    json j;
    try {
        j = json::parse(cfg_text);
    } catch (const std::exception & e) {
        err = std::string("config.json: invalid JSON: ") + e.what();
        return 1;
    }

    // Identify a tessera config either by the explicit tessera_format marker
    // or by the HF model_type. The reader stays usable on configs written by
    // either the new (HF-style) or old (custom) writer.
    const bool has_marker =
        (j.contains("tessera_format") &&
         j["tessera_format"] == "tessera-ternary-transport") ||
        (j.contains("format") &&
         j["format"] == "tessera-ternary-transport");
    const bool is_hf =
        j.contains("model_type") && j["model_type"] == "tessera-ternary";
    if (!has_marker && !is_hf) {
        err = "config.json: not a tessera-ternary config "
              "(missing tessera_format / model_type)";
        return 1;
    }

    // arch: prefer the explicit tessera_arch; fall back to the legacy
    // "arch" key (old writer); fall back to general.architecture hparam.
    if (j.contains("tessera_arch") && j["tessera_arch"].is_string()) {
        arch = j["tessera_arch"].get<std::string>();
    } else if (j.contains("arch") && j["arch"].is_string()) {
        arch = j["arch"].get<std::string>();
    }

    if (is_hf) {
        // Standard HF layout: every top-level key that is not a structural
        // key is a GGUF hparam. GGUF keys are dotted so they never collide
        // with the structural set.
        const auto & skip = ts_structural_keys();
        for (auto it = j.begin(); it != j.end(); ++it) {
            if (skip.count(it.key())) continue;
            if (!it.value().is_primitive()) continue;
            hparams[it.key()] = ts_json_to_hparam(it.value());
        }
    } else if (j.contains("hparams") && j["hparams"].is_object()) {
        // Legacy writer layout (config.json::hparams object of strings).
        for (auto it = j["hparams"].begin(); it != j["hparams"].end(); ++it) {
            if (it.value().is_string()) {
                hparams[it.key()] = it.value().get<std::string>();
            } else if (it.value().is_primitive()) {
                hparams[it.key()] = ts_json_to_hparam(it.value());
            }
        }
    }
    if (arch.empty()) {
        auto it = hparams.find("general.architecture");
        if (it != hparams.end()) arch = it->second;
    }

    // Tensor inventory: new layout uses ternary_tensors; the legacy layout
    // used "tensors". Accept either.
    const char * inv_key = nullptr;
    if (j.contains("ternary_tensors") && j["ternary_tensors"].is_object()) {
        inv_key = "ternary_tensors";
    } else if (j.contains("tensors") && j["tensors"].is_object()) {
        inv_key = "tensors";
    }
    if (inv_key) {
        const json & inv = j[inv_key];
        for (auto it = inv.begin(); it != inv.end(); ++it) {
            cfg_tensor t;
            t.name    = it.key();
            const json & te = it.value();
            t.out_dim = te.value("out_dim", (int64_t) 0);
            t.in_dim  = te.value("in_dim",  (int64_t) 0);
            tensors.push_back(std::move(t));
        }
    }
    return 0;
}

int64_t ts_file_size(std::ifstream & f) {
    f.clear();
    f.seekg(0, std::ios::end);
    const std::streamoff sz = f.tellg();
    return sz < 0 ? 0 : (int64_t) sz;
}

// Describe the safetensors layout of a directory: either a single
// model.safetensors or the shards named by model.safetensors.index.json.
// Holds the merged array-key -> entry map plus, for sharded layouts, the
// per-shard headers and the set of shard filenames (in index order).
struct st_layout {
    bool sharded = false;
    // Single-file: the one shard filename relative to the dir.
    // Sharded: shard filenames in declaration order from the index.
    std::vector<std::string> shard_files;
    // array key -> entry (entry.shard names the owning shard file).
    std::map<std::string, st_entry> merged;
    // shard filename -> parsed header (lazy for the streaming path).
    std::map<std::string, st_header> headers;
};

// Join a directory and a relative filename, tolerating a trailing slash.
std::string ts_join(const std::string & dir, const std::string & name) {
    const std::string sep = (dir.back() == '/') ? "" : "/";
    return dir + sep + name;
}

// Resolve the safetensors layout of a directory. Looks first for
// model.safetensors.index.json (sharded), then for a single
// model.safetensors. Returns 0 on success.
int ts_resolve_layout(const std::string & dir,
                      st_layout & out,
                      std::string & err) {
    const std::string index_path = ts_join(dir, "model.safetensors.index.json");
    if (std::ifstream(index_path)) {
        // Sharded. Parse the index to get the weight_map, then defer header
        // parsing to per-shard open (the streaming path lazily parses only
        // the shards it touches; the full-load path parses all of them).
        std::string text;
        if (!ts_read_whole_file(index_path, text)) {
            err = "cannot read " + index_path;
            return 1;
        }
        json j;
        try {
            j = json::parse(text);
        } catch (const std::exception & e) {
            err = std::string("invalid index json: ") + e.what();
            return 1;
        }
        if (!j.contains("weight_map") || !j["weight_map"].is_object()) {
            err = "index json missing weight_map";
            return 1;
        }
        out.sharded = true;
        // Collect the unique shard filenames in first-seen (= declaration)
        // order so shard_files has a stable iteration order.
        std::map<std::string, int> seen;
        for (auto it = j["weight_map"].begin(); it != j["weight_map"].end(); ++it) {
            const std::string shard = it.value().get<std::string>();
            st_entry e;
            e.shard = shard;
            // data_start/nbytes are filled when the shard header is parsed.
            out.merged[it.key()] = std::move(e);
            if (!seen.count(shard)) {
                seen[shard] = (int) out.shard_files.size();
                out.shard_files.push_back(shard);
            }
        }
        return 0;
    }

    const std::string single = ts_join(dir, "model.safetensors");
    if (std::ifstream(single)) {
        out.sharded = false;
        out.shard_files = { "model.safetensors" };
        // Mark every key as belonging to this shard; offsets come from the
        // header parse.
        return 0;
    }

    // Legacy fallback: a directory written by the old writer used
    // tensors.safetensors. Accept it so a one-off read of an old artifact
    // still works.
    const std::string legacy = ts_join(dir, "tensors.safetensors");
    if (std::ifstream(legacy)) {
        out.sharded = false;
        out.shard_files = { "tensors.safetensors" };
        return 0;
    }

    err = "no model.safetensors (or index) found in " + dir;
    return 1;
}

// Parse the header of one shard (by relative filename) and merge its entries
// into the layout. For the single-file layout the merged map is filled from
// scratch here; for the sharded layout the merged map's entries get their
// offsets/dtypes filled in.
int ts_load_shard_header(const std::string & dir,
                         st_layout & layout,
                         const std::string & shard_name,
                         std::string & err) {
    const std::string path = ts_join(dir, shard_name);
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        err = "cannot open " + path;
        return 1;
    }
    const int64_t fsz = ts_file_size(f);
    st_header h;
    if (ts_parse_safetensors_header(f, fsz, h, shard_name, err) != 0) {
        return 1;
    }
    auto inserted = layout.headers.emplace(shard_name, std::move(h)).first;
    const st_header & hh = inserted->second;

    if (!layout.sharded) {
        // Single-file: the merged map is exactly this header.
        layout.merged = hh.entries;
        return 0;
    }
    // Sharded: copy parsed offsets/dtype into each merged entry that the
    // index assigned to this shard. Then seed any shard-header entries that
    // the index did not list (real-world indices sometimes carry only a
    // subset of keys; the shard file is the source of truth). This keeps the
    // reader correct for both the writer's complete index and a sparse one.
    for (auto & kv : layout.merged) {
        if (kv.second.shard != shard_name) continue;
        auto it = hh.entries.find(kv.first);
        if (it == hh.entries.end()) {
            err = "tensor " + kv.first + " listed in index but absent from " + shard_name;
            return 1;
        }
        kv.second.dtype      = it->second.dtype;
        kv.second.shape      = it->second.shape;
        kv.second.data_start = it->second.data_start;
        kv.second.nbytes     = it->second.nbytes;
    }
    for (const auto & kv : hh.entries) {
        layout.merged.emplace(kv.first, kv.second).first->second.shard = shard_name;
    }
    return 0;
}

} // anonymous namespace

// ---- full-load API -------------------------------------------------------

int ts_read_ttt(const std::string & dir, ts_ternary_model & model) {
    if (dir.empty()) {
        fprintf(stderr, "ts_read_ttt: empty directory\n");
        return 1;
    }

    const std::string cfg_path = ts_join(dir, "config.json");

    std::string cfg_text;
    if (!ts_read_whole_file(cfg_path, cfg_text)) {
        fprintf(stderr, "ts_read_ttt: cannot read %s\n", cfg_path.c_str());
        return 1;
    }

    std::vector<cfg_tensor> inv;
    std::string err;
    if (ts_parse_config(cfg_text, model.arch, model.hparams, inv, err) != 0) {
        fprintf(stderr, "ts_read_ttt: %s\n", err.c_str());
        return 1;
    }

    st_layout layout;
    if (ts_resolve_layout(dir, layout, err) != 0) {
        fprintf(stderr, "ts_read_ttt: %s\n", err.c_str());
        return 1;
    }

    // Parse every shard header up front so all merged entries are populated.
    for (const auto & sf : layout.shard_files) {
        if (ts_load_shard_header(dir, layout, sf, err) != 0) {
            fprintf(stderr, "ts_read_ttt: %s\n", err.c_str());
            return 1;
        }
    }

    // Read tensors shard-by-shard so each shard file is opened once. Group
    // the inventory by the shard owning its first array key.
    std::map<std::string, std::vector<const cfg_tensor *>> by_shard;
    for (const auto & c : inv) {
        const std::string key = c.name + ".trits";
        auto it = layout.merged.find(key);
        if (it == layout.merged.end()) {
            fprintf(stderr, "ts_read_ttt: tensor '%s' not in safetensors\n", c.name.c_str());
            return 1;
        }
        by_shard[it->second.shard].push_back(&c);
    }

    model.tensors.clear();
    for (const auto & sf : layout.shard_files) {
        const std::string path = ts_join(dir, sf);
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            fprintf(stderr, "ts_read_ttt: cannot open %s\n", path.c_str());
            return 1;
        }
        const auto h_it = layout.headers.find(sf);
        if (h_it == layout.headers.end()) {
            fprintf(stderr, "ts_read_ttt: internal: missing header for %s\n", sf.c_str());
            return 1;
        }
        const st_header & hh = h_it->second;
        auto it = by_shard.find(sf);
        if (it == by_shard.end()) continue;
        for (const cfg_tensor * cp : it->second) {
            ts_ternary_tensor & t = model.tensors[cp->name];
            t.out_dim = cp->out_dim;
            t.in_dim  = cp->in_dim;
            if (!ts_read_tensor_arrays(f, hh, layout.merged, cp->name, t, err)) {
                fprintf(stderr, "ts_read_ttt: %s\n", err.c_str());
                return 1;
            }
        }
    }

    return 0;
}

// ---- streaming API -------------------------------------------------------

struct ts_ttt_tensor_stream::impl {
    std::string dir;
    std::string arch;
    std::map<std::string, std::string> hparams;
    std::vector<cfg_tensor> inventory;
    st_layout layout;
    std::string cur_shard;       // shard file currently open in `file`
    std::ifstream file;
    size_t next_idx = 0;
    bool open = false;

    // Open `name`'s owning shard in `file`, parsing its header if needed.
    // Returns the shard header, or nullptr on error.
    const st_header * ensure_shard(const std::string & name, std::string & err) {
        const std::string key = name + ".trits";
        auto mit = layout.merged.find(key);
        if (mit == layout.merged.end()) {
            err = "tensor " + name + " not in safetensors";
            return nullptr;
        }
        const std::string & shard = mit->second.shard;
        if (shard.empty()) {
            err = "tensor " + name + " has no shard assignment";
            return nullptr;
        }
        // Parse header lazily on first touch.
        if (!layout.headers.count(shard)) {
            if (ts_load_shard_header(dir, layout, shard, err) != 0) {
                return nullptr;
            }
        }
        // (Re)open the shard file if it changed.
        if (cur_shard != shard) {
            if (file.is_open()) file.close();
            const std::string path = ts_join(dir, shard);
            file.open(path, std::ios::binary);
            if (!file) {
                err = "cannot open " + path;
                return nullptr;
            }
            cur_shard = shard;
        }
        auto hit = layout.headers.find(shard);
        return hit == layout.headers.end() ? nullptr : &hit->second;
    }
};

ts_ttt_tensor_stream::ts_ttt_tensor_stream() : p_(new impl()) {}
ts_ttt_tensor_stream::~ts_ttt_tensor_stream() { close(); }

int ts_ttt_tensor_stream::open(const std::string & dir) {
    if (!p_) return 1;
    if (p_->open) close();

    if (dir.empty()) {
        fprintf(stderr, "ts_ttt_tensor_stream::open: empty directory\n");
        return 1;
    }

    p_->dir = dir;
    const std::string cfg_path = ts_join(dir, "config.json");

    std::string cfg_text;
    if (!ts_read_whole_file(cfg_path, cfg_text)) {
        fprintf(stderr, "ts_ttt_tensor_stream::open: cannot read %s\n", cfg_path.c_str());
        return 1;
    }

    std::string err;
    if (ts_parse_config(cfg_text, p_->arch, p_->hparams, p_->inventory, err) != 0) {
        fprintf(stderr, "ts_ttt_tensor_stream::open: %s\n", err.c_str());
        return 1;
    }

    if (ts_resolve_layout(dir, p_->layout, err) != 0) {
        fprintf(stderr, "ts_ttt_tensor_stream::open: %s\n", err.c_str());
        return 1;
    }

    // Single-file layout: parse the one shard header up front so the merged
    // array-key map is populated before next() looks anything up. Sharded
    // layouts defer per-shard header parsing until the first tensor in each
    // shard is requested, keeping the streaming path's RAM bounded.
    if (!p_->layout.sharded) {
        if (ts_load_shard_header(dir, p_->layout, p_->layout.shard_files.front(), err) != 0) {
            fprintf(stderr, "ts_ttt_tensor_stream::open: %s\n", err.c_str());
            return 1;
        }
    }

    p_->next_idx = 0;
    p_->open = true;
    return 0;
}

std::string ts_ttt_tensor_stream::next(ts_ternary_tensor & tensor) {
    if (!p_ || !p_->open) return std::string();

    if (p_->next_idx >= p_->inventory.size()) {
        return std::string();
    }
    const cfg_tensor & c = p_->inventory[p_->next_idx++];

    // Clear the destination so the caller doesn't see stale buffers from a
    // previous iteration (matches the "buffers are reused across calls"
    // contract in the header). Scalars default back to 0.
    tensor.trits.clear();
    tensor.outlier_row_offsets.clear();
    tensor.outlier_cols.clear();
    tensor.outlier_vals.clear();
    tensor.awq_scale.clear();
    tensor.awq_input_scale.clear();
    tensor.act_scale.clear();
    tensor.core.clear();
    tensor.global_amp = 0.0f;
    tensor.best_alpha = 0.0f;
    tensor.out_dim = c.out_dim;
    tensor.in_dim  = c.in_dim;

    std::string err;
    const st_header * hh = p_->ensure_shard(c.name, err);
    if (hh == nullptr) {
        fprintf(stderr, "ts_ttt_tensor_stream::next: %s\n", err.c_str());
        p_->next_idx = p_->inventory.size();
        return std::string();
    }
    if (!ts_read_tensor_arrays(p_->file, *hh, p_->layout.merged, c.name, tensor, err)) {
        fprintf(stderr, "ts_ttt_tensor_stream::next: %s\n", err.c_str());
        // Mark the stream done so subsequent calls don't retry; the caller
        // already received a partial tensor and an empty-name sentinel next.
        p_->next_idx = p_->inventory.size();
        return std::string();
    }
    return c.name;
}

void ts_ttt_tensor_stream::close() {
    if (!p_) return;
    if (p_->file.is_open()) p_->file.close();
    p_->open = false;
    p_->next_idx = 0;
    p_->inventory.clear();
    p_->layout.merged.clear();
    p_->layout.headers.clear();
    p_->layout.shard_files.clear();
    p_->cur_shard.clear();
    p_->dir.clear();
    p_->arch.clear();
    p_->hparams.clear();
}

const std::string & ts_ttt_tensor_stream::arch() const {
    static const std::string empty;
    return p_ ? p_->arch : empty;
}

const std::map<std::string, std::string> & ts_ttt_tensor_stream::hparams() const {
    static const std::map<std::string, std::string> empty;
    return p_ ? p_->hparams : empty;
}
