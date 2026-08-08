// gguf_weight_stream.mm — Phase 2 ANE runtime: per-layer GGUF -> IOSurface
// weight streamer (implementation).
//
// See gguf_weight_stream.h for the public API and lifecycle.
// This file is the .mm side: mmap the unified GGUF, parse
// the v3 header once, expose per-layer reads as zero-copy
// memcpy from the mmap'd region into the caller-provided
// IOSurface slot.
//
// What this file does NOT do (yet):
//   - Per-layer streaming (slice 1 stubs it; slice 2 implements)
//   - Wire into the dispatch (slice 3)
//   - Async prefetch (slice 4)
//
// What this file DOES (slice 1):
//   - open(path) opens the GGUF, mmaps it read-only, parses
//     the v3 header (magic, version, n_tensors, n_kv, kv[],
//     tensor_info[]) into a sorted name -> (offset, size_bytes)
//     map.
//   - close(stream) munmaps + closes the fd.
//   - stream_layer() is a stub that returns -1 with a
//     "not implemented" log. The map is built; the read path
//     is slice 2.
//
// The parser is hand-rolled and minimal. We don't depend on
// ggml's gguf.c reader (the ggml-ane backend is a leaf and
// uses ggml.h only for the buffer/tensor types). The GGUF
// v3 format is documented at
// https://github.com/ggml-org/ggml/blob/master/docs/gguf.md
// and the fields we parse are stable.

#include "gguf_weight_stream.h"

#include "ggml.h"
#include "ggml-impl.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

// GGUF v3 constants. Magic is 'GGUF' little-endian (= 0x46554747).
// The names are ANE-prefixed to avoid colliding with the
// gguf.h macros (GGUF_MAGIC is a macro there).
static const uint32_t ANE_GGUF_MAGIC   = 0x46554747u;
static const uint32_t ANE_GGUF_VERSION = 3u;
// Default tensor alignment. GGUF v3 supports per-tensor alignment
// in the tensor_info; the tessera conversion tool emits the
// default (32 bytes) for every tensor, so we use the same
// constant for the data section's start alignment.
static const uint64_t ANE_GGUF_DEFAULT_ALIGNMENT = 32u;

// Read a little-endian primitive from a byte stream. The
// caller is responsible for bounds checking (we read the
// header from a mmap'd file that's at least file_size long).
static inline uint32_t read_u32(const uint8_t * p) {
    return  (uint32_t) p[0]
         | ((uint32_t) p[1] << 8)
         | ((uint32_t) p[2] << 16)
         | ((uint32_t) p[3] << 24);
}

static inline uint64_t read_u64(const uint8_t * p) {
    return  (uint64_t) p[0]
         | ((uint64_t) p[1] << 8)
         | ((uint64_t) p[2] << 16)
         | ((uint64_t) p[3] << 24)
         | ((uint64_t) p[4] << 32)
         | ((uint64_t) p[5] << 40)
         | ((uint64_t) p[6] << 48)
         | ((uint64_t) p[7] << 56);
}

// Read a GGUF string: uint64 length, then `length` bytes
// (NOT NUL-terminated). Returns the parsed string and
// advances `*pos`.
static bool read_gguf_string(const uint8_t * base,
                             size_t file_size,
                             size_t * pos,
                             std::string * out) {
    if (*pos + 8 > file_size) return false;
    const uint64_t length = read_u64(base + *pos);
    *pos += 8;
    if (*pos + length > file_size) return false;
    out->assign(reinterpret_cast<const char *>(base + *pos),
                static_cast<size_t>(length));
    *pos += static_cast<size_t>(length);
    return true;
}

// Skip a GGUF kv entry. The value type enum is at
// https://github.com/ggml-org/ggml/blob/master/docs/gguf.md#file-structure
// (uint8/16/32/64, int8/16/32/64, f16/32/64, string, array, bool).
// We don't read the values; the streaming path only needs
// the tensor_info section.
static bool skip_gguf_kv(const uint8_t * base,
                         size_t file_size,
                         size_t * pos) {
    // key
    std::string key;
    if (!read_gguf_string(base, file_size, pos, &key)) return false;
    if (*pos + 4 > file_size) return false;
    const uint32_t vtype = read_u32(base + *pos);
    *pos += 4;
    // GGUF KV type enum — must match ggml/include/gguf.h (0..12).
    // UINT8=0 INT8=1 UINT16=2 INT16=3 UINT32=4 INT32=5 FLOAT32=6 BOOL=7
    // STRING=8 ARRAY=9 UINT64=10 INT64=11 FLOAT64=12
    switch (vtype) {
        case 0: // GGUF_TYPE_UINT8
        case 1: // GGUF_TYPE_INT8
        case 7: // GGUF_TYPE_BOOL
            *pos += 1; return true;
        case 2: // GGUF_TYPE_UINT16
        case 3: // GGUF_TYPE_INT16
            *pos += 2; return true;
        case 4: // GGUF_TYPE_UINT32
        case 5: // GGUF_TYPE_INT32
        case 6: // GGUF_TYPE_FLOAT32
            *pos += 4; return true;
        case 10: // GGUF_TYPE_UINT64
        case 11: // GGUF_TYPE_INT64
        case 12: // GGUF_TYPE_FLOAT64
            *pos += 8; return true;
        case 8: // GGUF_TYPE_STRING
            return read_gguf_string(base, file_size, pos, &key);
        case 9: // GGUF_TYPE_ARRAY
        {
            if (*pos + 12 > file_size) return false;
            const uint32_t  elem_type = read_u32(base + *pos);
            const uint64_t n_elems    = read_u64(base + *pos + 4);
            *pos += 12;
            if (elem_type == 8) { // GGUF_TYPE_STRING array — variable-length entries
                for (uint64_t i = 0; i < n_elems; ++i) {
                    std::string tmp;
                    if (!read_gguf_string(base, file_size, pos, &tmp)) return false;
                }
                return true;
            }
            const size_t elem_size =
                elem_type == 0 || elem_type == 1 || elem_type == 7  ? 1 :
                elem_type == 2 || elem_type == 3                     ? 2 :
                elem_type == 4 || elem_type == 5 || elem_type == 6  ? 4 :
                elem_type == 10 || elem_type == 11 || elem_type == 12 ? 8 : 0;
            if (elem_size == 0) return false; // unknown array element
            if (n_elems > SIZE_MAX / (elem_size ? elem_size : 1)) return false;
            *pos += n_elems * elem_size;
            return *pos <= file_size;
        }
        default:
            return false;
    }
}

// Tensor info parsed from the GGUF header. We keep the
// fields the streaming path needs (name, offset within
// data section, byte size).
struct ane_gguf_tensor_info {
    uint64_t offset;       // offset from data section start
    uint64_t size_bytes;   // total bytes on disk
    uint32_t n_dim;
    uint64_t shape[4];
    uint32_t ggml_type;    // raw enum (we don't decode it; the
                           // byte size is precomputed at parse time)
};

struct ane_weight_stream_t {
    int      fd          = -1;
    void *   mmap_base   = nullptr;
    size_t   mmap_size   = 0;
    uint64_t data_section_offset = 0; // file position of data section start
    // Sorted map for O(log n) lookup by tensor name.
    std::map<std::string, ane_gguf_tensor_info> tensors;
};

// Compute the on-disk byte size of one tensor. We only
// handle a small set of ggml types in the streaming path;
// unknown types are sized by n_elements * 1 (the streamer
// will report a size mismatch and the call returns -1).
//
// For T640_3D packed weights, the conversion tool emits
// the per-tensor byte count via `tensor_info.offset` (the
// offset of the next tensor); we can also recover it from
// the dim + dtype. We pick the dim-based path for type
// safety; the type's quantized size table lives in ggml.c
// but we keep this .mm standalone to avoid pulling in
// ggml-quants.c at compile time.
static uint64_t ggml_type_size(uint32_t type, uint64_t n_elems) {
    switch (type) {
        case 0:  return n_elems * 4; // GGML_TYPE_F32
        case 1:  return n_elems * 2; // GGML_TYPE_F16
        case 2:  return n_elems * 4; // GGML_TYPE_Q4_0
        case 3:  return n_elems * 4; // GGML_TYPE_Q4_1
        case 6:  return n_elems * 4; // GGML_TYPE_Q5_0 (block-size approx; unknown types fall through to estimate)
        case 4:  return n_elems * 1; // GGML_TYPE_I8 (legacy alias)
        case 24: return n_elems * 1; // GGML_TYPE_I8
        case 25: return n_elems * 2; // GGML_TYPE_I16
        case 26: return n_elems * 4; // GGML_TYPE_I32
        case 27: return n_elems * 8; // GGML_TYPE_I64
        case 28: return n_elems * 8; // GGML_TYPE_F64
        case 30: return n_elems * 2; // GGML_TYPE_BF16
        // Tessera T640 packed (large enum value; matches
        // the value ggml-quants.h uses for the conversion
        // tool's emitted type). The exact enum depends on
        // the conversion tool; we accept any of the high
        // values as "T640 packed" and let the caller size
        // via the dim shape (page_count * row_bytes).
        default:
            return 0; // unknown -> t640 estimate
    }
}

// Estimate the byte size of a T640_3D packed tensor. The
// conversion tool emits weights at the (n_embd, n_tokens)
// shape, with 32-bit words for packed data, 16-bit for
// page_scales, 8-bit for lane_scales, plus the sparse
// outlier addback region. We size the dense region by the
// page count:
//
//   pages_per_row = ceil(n_embd / 640)
//   words_per_page = 32
//   packed_bytes   = n_tokens * pages_per_row * words_per_page * 4
//   page_scales    = n_tokens * pages_per_row * 2
//   lane_scales    = n_tokens * pages_per_row * words_per_page
//
// The sparse outlier region is appended after the dense
// region; its byte count is `tensor_info.offset_next -
// tensor_info.offset` minus the dense size. We capture the
// raw size in the tensor_info via ggml_type_size == 0 +
// the raw offset (handled at the call site).
//
// For our v1 sizing we just need a sane lower bound; the
// streaming path writes the exact size of each tensor via
// a follow-up tensor_info entry in slice 2.
static uint64_t t640_size_estimate(const ane_gguf_tensor_info * ti) {
    if (ti->n_dim < 2) return 0;
    const uint64_t in_dim  = ti->shape[0];
    const uint64_t n_rows  = ti->shape[1];
    const uint64_t pages   = (in_dim + 639) / 640;
    const uint64_t wpp     = 32;
    const uint64_t packed  = n_rows * pages * wpp * 4;
    const uint64_t scales  = n_rows * pages * (2 + wpp);
    return packed + scales;
}

// Parse the GGUF v3 header. On success, fills `stream` with
// the mmapped file, the data section offset, and the
// sorted tensor map. On failure, logs and returns false
// (error_out filled if non-null).
static bool parse_gguf_header(ane_weight_stream_t * stream,
                              char * error_out,
                              size_t error_out_size) {
    const uint8_t * base = (const uint8_t *) stream->mmap_base;
    size_t pos = 0;

    if (stream->mmap_size < 24) {
        if (error_out) snprintf(error_out, error_out_size,
            "file too small (%zu bytes) for GGUF header", stream->mmap_size);
        return false;
    }
    const uint32_t magic = read_u32(base + pos); pos += 4;
    if (magic != ANE_GGUF_MAGIC) {
        if (error_out) snprintf(error_out, error_out_size,
            "bad magic 0x%08x (expected 0x%08x)", magic, ANE_GGUF_MAGIC);
        return false;
    }
    const uint32_t version = read_u32(base + pos); pos += 4;
    if (version != ANE_GGUF_VERSION) {
        if (error_out) snprintf(error_out, error_out_size,
            "unsupported GGUF version %u (expected %u)", version, ANE_GGUF_VERSION);
        return false;
    }
    const uint64_t n_tensors = read_u64(base + pos); pos += 8;
    const uint64_t n_kv      = read_u64(base + pos); pos += 8;
    if (n_tensors > 100000) {
        if (error_out) snprintf(error_out, error_out_size,
            "n_tensors %llu implausibly large",
            (unsigned long long) n_tensors);
        return false;
    }
    // Skip kvs.
    for (uint64_t i = 0; i < n_kv; ++i) {
        if (!skip_gguf_kv(base, stream->mmap_size, &pos)) {
            if (error_out) snprintf(error_out, error_out_size,
                "failed to skip kv %llu", (unsigned long long) i);
            return false;
        }
    }
    // Tensor infos.
    for (uint64_t i = 0; i < n_tensors; ++i) {
        ane_gguf_tensor_info ti;
        std::string name;
        if (!read_gguf_string(base, stream->mmap_size, &pos, &name)) {
            if (error_out) snprintf(error_out, error_out_size,
                "failed to read tensor name at %llu", (unsigned long long) i);
            return false;
        }
        if (pos + 4 > stream->mmap_size) {
            if (error_out) snprintf(error_out, error_out_size,
                "tensor name at %llu truncated", (unsigned long long) i);
            return false;
        }
        ti.n_dim = read_u32(base + pos); pos += 4;
        if (ti.n_dim > 4) {
            if (error_out) snprintf(error_out, error_out_size,
                "tensor %s n_dim %u > 4", name.c_str(), ti.n_dim);
            return false;
        }
        for (uint32_t d = 0; d < ti.n_dim; ++d) {
            if (pos + 8 > stream->mmap_size) {
                if (error_out) snprintf(error_out, error_out_size,
                    "tensor %s shape truncated at dim %u", name.c_str(), d);
                return false;
            }
            ti.shape[d] = read_u64(base + pos); pos += 8;
        }
        if (pos + 8 > stream->mmap_size) {
            if (error_out) snprintf(error_out, error_out_size,
                "tensor %s dtype/offset truncated", name.c_str());
            return false;
        }
        ti.ggml_type = read_u32(base + pos); pos += 4;
        ti.offset     = read_u64(base + pos); pos += 8;

        // Compute size_bytes. The header doesn't carry the
        // on-disk byte count; we derive it from the type +
        // shape. For T640 packed (unknown ggml_type enum),
        // we use the dense-region estimate; the streaming
        // path sizes each tensor precisely via the
        // end-of-tensor gap.
        uint64_t n_elems = 1;
        for (uint32_t d = 0; d < ti.n_dim; ++d) n_elems *= ti.shape[d];
        ti.size_bytes = ggml_type_size(ti.ggml_type, n_elems);
        if (ti.size_bytes == 0) {
            // Unknown type or T640 packed. Use the estimate.
            ti.size_bytes = t640_size_estimate(&ti);
        }
        if (ti.size_bytes == 0) {
            if (error_out) snprintf(error_out, error_out_size,
                "tensor %s has unknown size (type %u, n_elems %llu)",
                name.c_str(), ti.ggml_type, (unsigned long long) n_elems);
            return false;
        }

        stream->tensors[name] = ti;
    }
    // Data section starts at the next ANE_GGUF_DEFAULT_ALIGNMENT
    // boundary after the header. This is the standard GGUF
    // v3 layout the conversion tool emits.
    stream->data_section_offset =
        (pos + ANE_GGUF_DEFAULT_ALIGNMENT - 1) & ~(ANE_GGUF_DEFAULT_ALIGNMENT - 1);
    if (stream->data_section_offset > stream->mmap_size) {
        if (error_out) snprintf(error_out, error_out_size,
            "data section offset %llu past EOF %zu",
            (unsigned long long) stream->data_section_offset,
            stream->mmap_size);
        return false;
    }
    return true;
}

bool ane_weight_stream_open(const char * gguf_path,
                            ane_weight_stream_t ** stream_out,
                            char * error_out,
                            size_t error_out_size) {
    if (error_out && error_out_size > 0) error_out[0] = '\0';
    if (gguf_path == nullptr || stream_out == nullptr) {
        if (error_out) snprintf(error_out, error_out_size,
            "null gguf_path or stream_out");
        return false;
    }
    *stream_out = nullptr;

    int fd = ::open(gguf_path, O_RDONLY);
    if (fd < 0) {
        if (error_out) snprintf(error_out, error_out_size,
            "open(%s) failed: errno %d", gguf_path, errno);
        return false;
    }
    struct stat st;
    if (::fstat(fd, &st) != 0) {
        if (error_out) snprintf(error_out, error_out_size,
            "fstat(%s) failed: errno %d", gguf_path, errno);
        ::close(fd);
        return false;
    }
    if (st.st_size <= 0) {
        if (error_out) snprintf(error_out, error_out_size,
            "%s is empty", gguf_path);
        ::close(fd);
        return false;
    }
    const size_t file_size = (size_t) st.st_size;
    void * base = ::mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED) {
        if (error_out) snprintf(error_out, error_out_size,
            "mmap(%s, %zu) failed: errno %d", gguf_path, file_size, errno);
        ::close(fd);
        return false;
    }
    // We hold the mmap for the stream's lifetime; advise
    // the kernel we'll be reading sequentially across the
    // header + sparse data region. The conversion tool's
    // tensor layout is dense by layer (the runtime streams
    // layer L's tensors contiguously), so sequential read
    // is the right pattern for the data section.
    ::madvise(base, file_size, MADV_SEQUENTIAL);

    auto * stream = new ane_weight_stream_t;
    stream->fd        = fd;
    stream->mmap_base = base;
    stream->mmap_size = file_size;
    if (!parse_gguf_header(stream, error_out, error_out_size)) {
        ::munmap(base, file_size);
        ::close(fd);
        delete stream;
        return false;
    }
    *stream_out = stream;
    GGML_LOG_INFO("ane: opened GGUF weight stream %s (%zu bytes, %zu tensors)\n",
                  gguf_path, file_size, stream->tensors.size());
    return true;
}

void ane_weight_stream_close(ane_weight_stream_t * stream) {
    if (stream == nullptr) return;
    if (stream->mmap_base != nullptr) {
        ::munmap(stream->mmap_base, stream->mmap_size);
    }
    if (stream->fd >= 0) {
        ::close(stream->fd);
    }
    delete stream;
}

size_t ane_weight_stream_file_size(const ane_weight_stream_t * stream) {
    if (stream == nullptr) return 0;
    return stream->mmap_size;
}

// Internal helper: collect the sorted-map iterators for
// layer `layer_idx`'s tensors. Fills `indices_out` (if
// non-null) with the iterators and returns the count. The
// iterators point into `stream->tensors`; the caller must
// not modify the map while the iterators are live. The
// layer-level and per-tensor public APIs both go through
// this helper so the "what counts as blk.L.*" rule is
// defined exactly once.
static uint32_t collect_block_tensor_indices(
        const ane_weight_stream_t * stream,
        int32_t layer_idx,
        std::vector<std::map<std::string, ane_gguf_tensor_info>::const_iterator> * indices_out) {
    if (stream == nullptr) return 0;
    char prefix[32];
    const int n = std::snprintf(prefix, sizeof(prefix), "blk.%d.", layer_idx);
    if (n <= 0 || (size_t) n >= sizeof(prefix)) return 0;
    auto begin = stream->tensors.lower_bound(prefix);
    uint32_t count = 0;
    for (auto it = begin; it != stream->tensors.end(); ++it) {
        if (it->first.compare(0, (size_t) n, prefix) != 0) break;
        if (indices_out) indices_out->push_back(it);
        ++count;
    }
    return count;
}

uint32_t ane_weight_stream_n_block_tensors(const ane_weight_stream_t * stream,
                                           int32_t layer_idx) {
    return collect_block_tensor_indices(stream, layer_idx, nullptr);
}

bool ane_weight_stream_block_tensor_info(
        const ane_weight_stream_t * stream,
        int32_t layer_idx,
        uint32_t index,
        const char ** name_out,
        size_t * size_bytes_out,
        uint32_t * n_dim_out,
        uint64_t * shape_out) {
    if (stream == nullptr) return false;
    std::vector<std::map<std::string, ane_gguf_tensor_info>::const_iterator> indices;
    const uint32_t n = collect_block_tensor_indices(stream, layer_idx, &indices);
    if (index >= n) return false;
    const auto & it = indices[index];
    if (name_out)       *name_out       = it->first.c_str();
    if (size_bytes_out) *size_bytes_out = (size_t) it->second.size_bytes;
    if (n_dim_out)      *n_dim_out      = it->second.n_dim;
    if (shape_out) {
        for (uint32_t d = 0; d < 4; ++d) {
            shape_out[d] = d < it->second.n_dim
                ? it->second.shape[d] : 0;
        }
    }
    return true;
}

int64_t ane_weight_stream_block_tensor(
        ane_weight_stream_t * stream,
        int32_t layer_idx,
        uint32_t index,
        void * dst,
        size_t dst_size_bytes) {
    if (stream == nullptr || dst == nullptr) {
        GGML_LOG_ERROR("ane: stream_block_tensor: null stream or dst\n");
        return -1;
    }
    std::vector<std::map<std::string, ane_gguf_tensor_info>::const_iterator> indices;
    const uint32_t n = collect_block_tensor_indices(stream, layer_idx, &indices);
    if (index >= n) {
        GGML_LOG_ERROR("ane: stream_block_tensor: index %u out of range "
                       "(layer %d has %u tensors)\n", index, layer_idx, n);
        return -1;
    }
    const auto & it = indices[index];
    const ane_gguf_tensor_info & ti = it->second;
    if (ti.size_bytes > dst_size_bytes) {
        GGML_LOG_ERROR("ane: stream_block_tensor: dst %zu bytes < tensor %s "
                       "size %llu\n", dst_size_bytes, it->first.c_str(),
                       (unsigned long long) ti.size_bytes);
        return -1;
    }
    // Bounds check on the mmap'd region.
    const uint64_t file_pos = stream->data_section_offset + ti.offset;
    if (file_pos + ti.size_bytes > stream->mmap_size) {
        GGML_LOG_ERROR("ane: stream_block_tensor: %s file range "
                       "[%llu, %llu) past EOF %zu\n", it->first.c_str(),
                       (unsigned long long) file_pos,
                       (unsigned long long) (file_pos + ti.size_bytes),
                       stream->mmap_size);
        return -1;
    }
    const uint8_t * src = (const uint8_t *) stream->mmap_base + file_pos;
    std::memcpy(dst, src, (size_t) ti.size_bytes);
    return (int64_t) ti.size_bytes;
}

// Copy one expert slice of a 3D tensor. The tensor must have n_dim >= 3;
// the expert slice is size_bytes / shape[2] bytes at offset
// expert_idx * per_expert_bytes within the tensor's on-disk data.
int64_t ane_weight_stream_expert_slice(
        ane_weight_stream_t * stream,
        int32_t layer_idx,
        uint32_t index,
        int32_t expert_idx,
        void * dst,
        size_t dst_size_bytes) {
    if (stream == nullptr || dst == nullptr) {
        GGML_LOG_ERROR("ane: stream_expert_slice: null stream or dst\n");
        return -1;
    }
    std::vector<std::map<std::string, ane_gguf_tensor_info>::const_iterator> indices;
    const uint32_t n = collect_block_tensor_indices(stream, layer_idx, &indices);
    if (index >= n) {
        GGML_LOG_ERROR("ane: stream_expert_slice: index %u out of range\n", index);
        return -1;
    }
    const auto & it = indices[index];
    const ane_gguf_tensor_info & ti = it->second;
    if (ti.n_dim < 3 || ti.shape[2] == 0) {
        GGML_LOG_ERROR("ane: stream_expert_slice: %s is not 3D (n_dim=%u)\n",
                       it->first.c_str(), ti.n_dim);
        return -1;
    }
    const uint64_t per_expert = ti.size_bytes / ti.shape[2];
    if (expert_idx < 0 || (uint64_t) expert_idx >= ti.shape[2]) {
        GGML_LOG_ERROR("ane: stream_expert_slice: expert %d out of range (n_expert=%llu)\n",
                       expert_idx, (unsigned long long) ti.shape[2]);
        return -1;
    }
    if (per_expert > dst_size_bytes) {
        GGML_LOG_ERROR("ane: stream_expert_slice: dst %zu < per_expert %llu\n",
                       dst_size_bytes, (unsigned long long) per_expert);
        return -1;
    }
    const uint64_t file_pos = stream->data_section_offset + ti.offset +
                              (uint64_t) expert_idx * per_expert;
    if (file_pos + per_expert > stream->mmap_size) {
        GGML_LOG_ERROR("ane: stream_expert_slice: %s expert %d past EOF\n",
                       it->first.c_str(), expert_idx);
        return -1;
    }
    const uint8_t * src = (const uint8_t *) stream->mmap_base + file_pos;
    std::memcpy(dst, src, (size_t) per_expert);
    return (int64_t) per_expert;
}

int64_t ane_weight_stream_layer(ane_weight_stream_t * stream,
                                int32_t layer_idx,
                                void * dst_buffer,
                                size_t dst_size_bytes) {
    if (stream == nullptr || dst_buffer == nullptr) {
        GGML_LOG_ERROR("ane: stream_layer: null stream or dst_buffer\n");
        return -1;
    }
    // Layout: name-sorted, contiguous, no padding. The
    // dispatch in slice 3 uses the per-tensor API above for
    // production (each meta tensor into its own IOSurface
    // slot); this layer-level helper is the test-facing API
    // and a convenience for "whole layer in one buffer" use.
    std::vector<std::map<std::string, ane_gguf_tensor_info>::const_iterator> indices;
    const uint32_t n = collect_block_tensor_indices(stream, layer_idx, &indices);
    if (n == 0) {
        GGML_LOG_ERROR("ane: stream_layer: layer %d has no tensors in the GGUF\n",
                       layer_idx);
        return -1;
    }
    // Compute total bytes + per-tensor offsets.
    std::vector<uint64_t> offsets;
    offsets.reserve(n);
    uint64_t cursor = 0;
    for (uint32_t i = 0; i < n; ++i) {
        offsets.push_back(cursor);
        cursor += indices[i]->second.size_bytes;
    }
    if (cursor > dst_size_bytes) {
        GGML_LOG_ERROR("ane: stream_layer: layer %d total %llu bytes > dst %zu\n",
                       layer_idx, (unsigned long long) cursor, dst_size_bytes);
        return -1;
    }
    // Copy each tensor.
    for (uint32_t i = 0; i < n; ++i) {
        const auto & it = indices[i];
        const ane_gguf_tensor_info & ti = it->second;
        const uint64_t file_pos = stream->data_section_offset + ti.offset;
        if (file_pos + ti.size_bytes > stream->mmap_size) {
            GGML_LOG_ERROR("ane: stream_layer: %s file range past EOF\n",
                           it->first.c_str());
            return -1;
        }
        const uint8_t * src = (const uint8_t *) stream->mmap_base + file_pos;
        std::memcpy((uint8_t *) dst_buffer + offsets[i], src, (size_t) ti.size_bytes);
    }
    return (int64_t) cursor;
}
