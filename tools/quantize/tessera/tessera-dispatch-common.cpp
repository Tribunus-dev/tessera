//
// tessera-dispatch-common.cpp
//
// Pipeline refactor phase 4: helpers shared by every dispatch module
// (tessera-dispatch.cpp, -gaprep.cpp, -walk.cpp, -acceptance.cpp,
// -db.cpp, -l5.cpp). Moved out of tessera-dispatch.cpp so the split
// modules can call these without duplicating the logic; declarations
// live in tessera-dispatch-internal.h.
//

#include "tessera-dispatch-internal.h"

#include "tessera-regime.h"
#include "tessera-imatrix.h"
#include "tessera-mm-imatrix.h"
#include "tessera-mm-awq.h"

#include "ggml.h"

#include <cmath>
#include <cstring>

std::vector<uint8_t> ts_to_bytes_u32(const std::vector<uint32_t> & v) {
    std::vector<uint8_t> out(v.size() * sizeof(uint32_t));
    std::memcpy(out.data(), v.data(), out.size());
    return out;
}

std::vector<uint8_t> ts_to_bytes_u16(const std::vector<uint16_t> & v) {
    std::vector<uint8_t> out(v.size() * sizeof(uint16_t));
    std::memcpy(out.data(), v.data(), out.size());
    return out;
}

std::vector<uint8_t> ts_to_bytes_i8(const std::vector<int8_t> & v) {
    std::vector<uint8_t> out(v.size() * sizeof(int8_t));
    std::memcpy(out.data(), v.data(), out.size());
    return out;
}

std::vector<uint8_t> ts_to_bytes_i32(const std::vector<int32_t> & v) {
    std::vector<uint8_t> out(v.size() * sizeof(int32_t));
    std::memcpy(out.data(), v.data(), out.size());
    return out;
}

// A tensor is quantizable if it is a 2D or 3D F32/F16 weight matrix
// whose name maps to a known tensor family (attn, ffn, etc).
bool ts_is_quantizable(const char * name, enum ggml_type type, int n_dims) {
    // Accept any type that has a dequant path. This lets the pipeline consume
    // any source GGUF format (f32, f16, q8_0, q4_0, etc) since ts_tensor_to_f32
    // uses the generic ggml type-traits dequant. Skip the destination type
    // (TESSERA_T640) to avoid re-quantizing an already-quantized model.
    if (type == GGML_TYPE_TESSERA_T640) {
        return false;
    }
    if (type != GGML_TYPE_F32 && type != GGML_TYPE_F16) {
        const struct ggml_type_traits * traits = ggml_get_type_traits(type);
        if (!traits || !traits->to_float) {
            return false;
        }
    }
    if (n_dims != 2 && n_dims != 3) {
        return false;
    }
    std::string family = ts_regime_infer_family(name);
    if (family.empty() || family == "other") {
        return false;
    }
    return true;
}

// Convert a ggml tensor's data to a flat F32 buffer.
// Handles F32 (copy) and F16 (convert). Returns empty on unsupported type.
std::vector<float> ts_tensor_to_f32(const struct ggml_tensor * t) {
    const int64_t n = ggml_nelements(t);
    std::vector<float> out((size_t)n);

    if (t->data == nullptr) {
        out.clear();
        return out;
    }
    if (t->type == GGML_TYPE_F32) {
        std::memcpy(out.data(), t->data, (size_t)n * sizeof(float));
    } else {
        // Generic dequant path via the type traits table. Handles F16, Q8_0,
        // and any other registered ggml type. This lets the pipeline consume
        // any source GGUF format, not just f16/f32.
        const struct ggml_type_traits * traits = ggml_get_type_traits(t->type);
        if (traits && traits->to_float) {
            traits->to_float(t->data, out.data(), n);
        } else {
            out.clear();
        }
    }
    return out;
}

// Resolve per-channel AWQ activation scales for one tensor.
// Priority: (1) imatrix lookup, (2) mean |activation| derived from the
// calibration corpus when its width matches the tensor in_dim. Returns
// nullptr when neither source is available (AWQ scaling disabled). When the
// corpus path is used the result points into *scratch, which the caller must
// keep alive for as long as the returned pointer is needed.
const float * ts_dispatch_act_scales(
        const ts_imatrix * imatrix, const char * name, int64_t in_dim,
        const float * calib_X, int64_t calib_in_dim, int64_t calib_n_tokens,
        std::vector<float> * scratch) {
    if (imatrix != nullptr) {
        int64_t dim = 0;
        const float * a = ts_imatrix_lookup(imatrix, name, &dim);
        if (a != nullptr && dim == in_dim) {
            return a;
        }
    }
    if (calib_X != nullptr && calib_in_dim == in_dim && calib_n_tokens > 0) {
        scratch->assign((size_t)in_dim, 0.0f);
        for (int64_t t = 0; t < calib_n_tokens; t++) {
            const float * row = calib_X + (size_t)t * in_dim;
            for (int64_t c = 0; c < in_dim; c++) {
                (*scratch)[(size_t)c] += std::fabs(row[c]);
            }
        }
        for (int64_t c = 0; c < in_dim; c++) {
            (*scratch)[(size_t)c] /= (float)calib_n_tokens;
        }
        return scratch->data();
    }
    return nullptr;
}

// Resolve a tensor's operative modality against the multimodal imatrix.
// Prefers the name-inferred modality when the imatrix has data for it, else
// the first present modality, else text. Returns the MM entry (nullptr when
// the tensor is absent from the imatrix) and writes the chosen modality.
const ts_mm_imatrix_entry * ts_dispatch_mm_resolve(
        const ts_mm_imatrix * mm, const char * name, int inferred, int * modality) {
    const ts_mm_imatrix_entry * en = ts_mm_imatrix_entry_get(mm, name);
    if (en == nullptr) {
        *modality = inferred;
        return nullptr;
    }
    if (inferred >= 0 && inferred < TS_MODALITY_COUNT && en->has_modality[inferred]) {
        *modality = inferred;
        return en;
    }
    for (int m = 0; m < TS_MODALITY_COUNT; m++) {
        if (en->has_modality[m]) {
            *modality = m;
            return en;
        }
    }
    *modality = 0;
    return en;
}

// Run the per-modality AWQ alpha search for one tensor against the multimodal
// imatrix. Only modalities whose per-channel array length matches in_dim are
// usable as AWQ scales. Returns 0 on success and fills *result.
int ts_dispatch_mm_awq(const ts_mm_imatrix * mm, const char * name,
                       const float * weights, int64_t out_dim, int64_t in_dim,
                       ts_mm_awq_result * result) {
    const float * act_mm[3] = { nullptr, nullptr, nullptr };
    for (int m = 0; m < TS_MODALITY_COUNT; m++) {
        int64_t d = 0;
        const float * a = ts_mm_imatrix_act_scales(mm, name, (ts_modality)m, &d);
        if (a != nullptr && d == in_dim) {
            act_mm[m] = a;
        }
    }
    ts_mm_awq_params mp = ts_mm_awq_default_params();
    mp.error_on_missing = false;   // partial modalities -> text fallback (M8)
    std::string merr;
    return ts_mm_awq_compute(weights, act_mm, nullptr, nullptr, nullptr,
                             out_dim, in_dim, &mp, result, &merr);
}
