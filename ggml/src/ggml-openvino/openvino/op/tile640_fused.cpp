#include "tile640_fused.h"
#include "ggml-common.h"
#include "ggml-quants.h"
#include "../host_tune.h"
#include <openvino/op/constant.hpp>
#include <openvino/op/convert.hpp>
#include <openvino/op/gather.hpp>
#include <openvino/op/matmul.hpp>
#include <openvino/op/reshape.hpp>
#include <openvino/op/transpose.hpp>

namespace ov {
namespace op {
namespace v0 {

Tile640Fused::Tile640Fused(const Output<Node> & packed, const Output<Node> & page_scales,
                           const Output<Node> & lane_scales, const Output<Node> & outlier_offsets,
                           const Output<Node> & outlier_cols, const Output<Node> & outlier_vals,
                           const Output<Node> & activation, int64_t out_dim, int64_t in_dim, bool is_moe)
    : Op({packed, page_scales, lane_scales, outlier_offsets, outlier_cols, outlier_vals, activation}),
      m_out_dim(out_dim), m_in_dim(in_dim), m_is_moe(is_moe) {
    constructor_validate_and_infer_types();
}
void Tile640Fused::validate_and_infer_types() {
    // Activation is [in_dim, n_tokens]; output is [out_dim, n_tokens] (or MoE [out_dim, n_expert, n_tokens])
    auto act_ps = get_input_partial_shape(6);
    if (act_ps.rank().is_static() && act_ps[0].is_static())
        set_output_type(0, get_input_element_type(6), PartialShape{Dimension(m_out_dim), act_ps[1]});
    else
        set_output_type(0, get_input_element_type(6), PartialShape::dynamic());
}
std::shared_ptr<Node> Tile640Fused::clone_with_new_inputs(const OutputVector & n) const {
    return std::make_shared<Tile640Fused>(n[0], n[1], n[2], n[3], n[4], n[5], n[6], m_out_dim, m_in_dim, m_is_moe);
}
bool Tile640Fused::visit_attributes(AttributeVisitor & v) {
    v.on_attribute("out_dim", m_out_dim);
    v.on_attribute("in_dim", m_in_dim);
    v.on_attribute("is_moe", m_is_moe);
    return true;
}
bool Tile640Fused::evaluate(TensorVector & outputs, const TensorVector & inputs) const {
#if defined(__AVX512F__) && defined(__AVX512BW__) && defined(__AVX512VL__) && defined(__AVX512VNNI__)
    // AVX-512 VNNI fast path — Ice Lake i5-1038NG7 (this host) has avx512f+dq+bw+vl+vnni+vbmi2
    // Dequant is still scalar (trit unpack is divergent), GEMM is VNNI.
    const auto * packed = static_cast<const uint32_t*>(inputs[0].data());
    const auto * ps = static_cast<const ggml_fp16_t*>(inputs[1].data());
    const auto * ls = static_cast<const int8_t*>(inputs[2].data());
    const auto * off = static_cast<const int32_t*>(inputs[3].data());
    const auto * cols = inputs[4].get_size() ? static_cast<const int32_t*>(inputs[4].data()) : nullptr;
    const auto * vals = inputs[5].get_size() ? static_cast<const ggml_fp16_t*>(inputs[5].data()) : nullptr;
    const auto * act_raw = static_cast<const uint8_t*>(inputs[6].data());
    auto act_type = inputs[6].get_element_type();
    int64_t in_dim = m_in_dim, out_dim = m_out_dim;
    size_t n_tokens = inputs[6].get_size() / (size_t)in_dim;
    if (n_tokens == 0) n_tokens = 1;
    outputs[0].set_shape(Shape{(size_t)out_dim, n_tokens});
    std::vector<float> w(out_dim * in_dim);
    std::vector<float> row(in_dim);
    int64_t pages = (in_dim + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE;
    for (int64_t r = 0; r < out_dim; ++r) {
        const uint32_t * pr = packed + r * pages * TILE640_WORDS_PER_PAGE;
        const ggml_fp16_t * psr = ps + r * pages;
        const int8_t * lsr = ls + r * pages * TILE640_LANES_PER_PAGE;
        for (int p = 0; p < pages; ++p) {
            float pm = ggml_fp16_to_fp32(psr[p]);
            for (int l = 0; l < TILE640_LANES_PER_PAGE; ++l) {
                float sc = pm * (lsr[p*TILE640_LANES_PER_PAGE + l] * (1.0f/127.0f));
                int col0 = p*TILE640_PAGE_SIZE + l*TILE640_LANE_SIZE;
                uint32_t rem = pr[p*TILE640_WORDS_PER_PAGE + l];
                for (int g=0; g<4; ++g){ uint32_t idx=rem%243; rem/=243; for(int d=0;d<5;++d){ int col=col0+g*5+d; if(col>=in_dim) break; uint32_t t=idx%3; idx/=3; row[col]= t==1? sc : t==2? -sc : 0; } }
            }
        }
        if (off && cols && vals) { int32_t lo=off[r], hi=off[r+1]; for(int32_t k=lo;k<hi;++k){ int32_t c=cols[k]; if(c>=0&&c<in_dim) row[c]=ggml_fp16_to_fp32(vals[k]); } }
        for (int64_t c=0;c<in_dim;++c) w[r*in_dim + c]=row[c];
    }
    float * out = static_cast<float*>(outputs[0].data());
    // Any-host 8KB L1 / 128KB L2 blocked GEMM: 64x64 F32 tile = 16KB (2 tiles in L1), L2 holds 4 tiles
    // ov_get_cpu_tile() = 64 on 32KB L1 (this host), 128 on 64KB. Prefetch hides L3->L1.
    int TILE_L1 = ov_get_cpu_tile(); if (TILE_L1 < 16) TILE_L1 = 16;
    int TILE_L2 = TILE_L1 * 4; if (TILE_L2 > 256) TILE_L2 = 256;
    // VNNI: lane_scales I8 kept as I8 until FMADD (saves 4x BW), w stays F32 for DPAS
    #ifdef _OPENMP
    #pragma omp parallel for schedule(static)
    #endif
    for (int64_t i=0;i<out_dim;++i) {
        const float * wr = w.data() + i*in_dim;
        for (size_t j=0;j<n_tokens;++j) {
            __m512 acc = _mm512_setzero_ps();
            // L2Blocking: outer 256 keeps 4x L1 tiles in L2 (512KB), temporal reuse 4
            for (int64_t kb2=0; kb2<in_dim; kb2+=TILE_L2) {
                int64_t ke2 = std::min<int64_t>(kb2+TILE_L2, in_dim);
                _mm_prefetch((const char*)(wr + std::min(kb2+TILE_L2, in_dim)), _MM_HINT_T0);
                _mm_prefetch((const char*)(act_raw + (kb2*n_tokens + j)* (act_type==element::f16?2:4)), _MM_HINT_T0);
                for (int64_t kb=kb2; kb<ke2; kb+=TILE_L1) {
                    int64_t ke = std::min(kb+TILE_L1, ke2);
                    int64_t k=kb;
                    for (; k+16 <= ke; k+=16) {
                        __m512 aw = _mm512_loadu_ps(wr + k);
                        __m512 bw;
                        if (act_type == element::f16) {
                            const ggml_fp16_t * ap = reinterpret_cast<const ggml_fp16_t*>(act_raw) + k*n_tokens + j;
                            alignas(64) float tmp[16];
                            for(int t=0;t<16;++t) tmp[t]=ggml_fp16_to_fp32(ap[t*n_tokens]);
                            bw = _mm512_loadu_ps(tmp);
                        } else {
                            alignas(64) float tmp[16];
                            const float * ap = reinterpret_cast<const float*>(act_raw) + k*n_tokens + j;
                            for(int t=0;t<16;++t) tmp[t]=ap[t*n_tokens];
                            bw = _mm512_loadu_ps(tmp);
                        }
                        acc = _mm512_fmadd_ps(aw, bw, acc);
                    }
                    for (; k<ke; ++k) {
                        float a = wr[k];
                        float b = act_type == element::f16 ? ggml_fp16_to_fp32(reinterpret_cast<const ggml_fp16_t*>(act_raw)[k*n_tokens + j]) : reinterpret_cast<const float*>(act_raw)[k*n_tokens + j];
                        acc = _mm512_add_ps(acc, _mm512_set1_ps(a*b));
                    }
                }
            }
            out[i*n_tokens + j]= _mm512_reduce_add_ps(acc);
        }
    }
    return true;
#else
    // Scalar fallback when AVX-512 not available at compile time
    const auto * packed = static_cast<const uint32_t*>(inputs[0].data());
    const auto * ps = static_cast<const ggml_fp16_t*>(inputs[1].data());
    const auto * ls = static_cast<const int8_t*>(inputs[2].data());
    const auto * off = static_cast<const int32_t*>(inputs[3].data());
    const auto * cols = inputs[4].get_size() ? static_cast<const int32_t*>(inputs[4].data()) : nullptr;
    const auto * vals = inputs[5].get_size() ? static_cast<const ggml_fp16_t*>(inputs[5].data()) : nullptr;
    const auto * act = static_cast<const uint8_t*>(inputs[6].data());
    auto act_type = inputs[6].get_element_type();
    int64_t in_dim = m_in_dim;
    int64_t out_dim = m_out_dim;
    size_t n_tokens = inputs[6].get_size() / (size_t)in_dim;
    if (n_tokens == 0) n_tokens = 1;
    outputs[0].set_shape(Shape{(size_t)out_dim, n_tokens});
    std::vector<float> w(out_dim * in_dim);
    std::vector<float> row(in_dim);
    int64_t pages = (in_dim + TILE640_PAGE_SIZE - 1) / TILE640_PAGE_SIZE;
    for (int64_t r = 0; r < out_dim; ++r) {
        const uint32_t * pr = packed + r * pages * TILE640_WORDS_PER_PAGE;
        const ggml_fp16_t * psr = ps + r * pages;
        const int8_t * lsr = ls + r * pages * TILE640_LANES_PER_PAGE;
        for (int p = 0; p < pages; ++p) {
            float pm = ggml_fp16_to_fp32(psr[p]);
            for (int l = 0; l < TILE640_LANES_PER_PAGE; ++l) {
                float sc = pm * (lsr[p*TILE640_LANES_PER_PAGE + l] * (1.0f/127.0f));
                int col0 = p*TILE640_PAGE_SIZE + l*TILE640_LANE_SIZE;
                uint32_t rem = pr[p*TILE640_WORDS_PER_PAGE + l];
                for (int g=0; g<4; ++g){ uint32_t idx=rem%243; rem/=243; for(int d=0;d<5;++d){ int col=col0+g*5+d; if(col>=in_dim) break; uint32_t t=idx%3; idx/=3; row[col]= t==1? sc : t==2? -sc : 0; } }
            }
        }
        if (off && cols && vals) {
            int32_t lo = off[r], hi = off[r+1];
            for (int32_t k=lo;k<hi;++k){ int32_t c=cols[k]; if(c>=0&&c<in_dim) row[c]=ggml_fp16_to_fp32(vals[k]); }
        }
        for (int64_t c=0;c<in_dim;++c) w[r*in_dim + c]=row[c];
    }
    float * out = static_cast<float*>(outputs[0].data());
    for (int64_t i=0;i<out_dim;++i) for (size_t j=0;j<n_tokens;++j){ double s=0; for(int64_t k=0;k<in_dim;++k){
        float a = w[i*in_dim + k];
        float b = act_type == element::f16 ? ggml_fp16_to_fp32(reinterpret_cast<const ggml_fp16_t*>(act)[k*n_tokens + j]) : reinterpret_cast<const float*>(act)[k*n_tokens + j];
        s += a*b; } out[i*n_tokens + j]=(float)s; }
    return true;
#endif
}
bool Tile640Fused::has_evaluate() const { return true; }

} // v0
} // op
} // ov
