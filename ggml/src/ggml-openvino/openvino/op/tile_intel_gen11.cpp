#include "tile_intel_gen11.h"
#include "ggml-common.h"
#include "ggml-quants.h"
#include "../host_tune.h"
#include "../node_context.h"
#include "../op_table.h"
#include "../utils.h"
#include <openvino/op/constant.hpp>
#include <openvino/op/convert.hpp>
#include <openvino/op/gather.hpp>
#include <openvino/op/matmul.hpp>
#include <openvino/op/reshape.hpp>
#include <openvino/op/transpose.hpp>

namespace ov {
namespace frontend {
namespace ggml {
namespace op {
static std::shared_ptr<ov::op::v0::Constant> const_i64_vec_g11(const std::vector<int64_t> & v) {
    return ov::op::v0::Constant::create(ov::element::i64, ov::Shape{v.size()}, v);
}
} // op
} // ggml
} // frontend
} // ov

namespace ov {
namespace op {
namespace v0 {

TileIntelGen11Fused::TileIntelGen11Fused(const Output<Node> & p, const Output<Node> & ps, const Output<Node> & ls, const Output<Node> & off, const Output<Node> & cols, const Output<Node> & vals, const Output<Node> & act, int64_t od, int64_t id, int tile, bool moe)
: Op({p,ps,ls,off,cols,vals,act}), m_out_dim(od), m_in_dim(id), m_tile(tile), m_is_moe(moe) {
    constructor_validate_and_infer_types();
}
void TileIntelGen11Fused::validate_and_infer_types() {
    auto ps = get_input_partial_shape(6);
    if (ps.rank().is_static() && ps[0].is_static())
        set_output_type(0, get_input_element_type(6), PartialShape{Dimension(m_out_dim), ps[1]});
    else
        set_output_type(0, get_input_element_type(6), PartialShape::dynamic());
}
std::shared_ptr<Node> TileIntelGen11Fused::clone_with_new_inputs(const OutputVector & n) const {
    return std::make_shared<TileIntelGen11Fused>(n[0],n[1],n[2],n[3],n[4],n[5],n[6], m_out_dim, m_in_dim, m_tile, m_is_moe);
}
bool TileIntelGen11Fused::visit_attributes(AttributeVisitor & v) {
    v.on_attribute("out_dim", m_out_dim);
    v.on_attribute("in_dim", m_in_dim);
    v.on_attribute("tile", m_tile);
    v.on_attribute("is_moe", m_is_moe);
    return true;
}
bool TileIntelGen11Fused::evaluate(TensorVector & outputs, const TensorVector & inputs) const {
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
    float * out = static_cast<float*>(outputs[0].data());
    int TILE_L1 = ov::frontend::ggml::ov_get_cpu_tile();
    if (TILE_L1 < 16) TILE_L1 = 16;
    int TILE_L2 = TILE_L1 * 4;
    if (TILE_L2 > 256) TILE_L2 = 256;
    std::vector<float> w(out_dim * in_dim);
    for (int64_t r = 0; r < out_dim; ++r) {
        const uint32_t * pr = packed + r * (m_tile == 1024 ? ((in_dim + 1023) / 1024) * TILE1024_WORDS_PER_PAGE : ((in_dim + 511) / 512) * TILE512_WORDS_PER_PAGE);
        const ggml_fp16_t * psr = ps + r * (m_tile == 1024 ? (in_dim + 1023) / 1024 : (in_dim + 511) / 512);
        const int8_t * lsr = ls + r * (m_tile == 1024 ? ((in_dim + 1023) / 1024) * TILE1024_LANES_PER_PAGE : ((in_dim + 511) / 512) * TILE512_LANES_PER_PAGE);
        for (int64_t c = 0; c < in_dim; ++c) w[r * in_dim + c] = 0;
        int pages = m_tile == 1024 ? (int)((in_dim + TILE1024_PAGE_SIZE - 1) / TILE1024_PAGE_SIZE) : (int)((in_dim + TILE512_PAGE_SIZE - 1) / TILE512_PAGE_SIZE);
        for (int p = 0; p < pages; ++p) {
            float pm = ggml_fp16_to_fp32(psr[p]);
            int lanes = m_tile == 1024 ? TILE1024_LANES_PER_PAGE : TILE512_LANES_PER_PAGE;
            int page_size = m_tile == 1024 ? TILE1024_PAGE_SIZE : TILE512_PAGE_SIZE;
            for (int l = 0; l < lanes; ++l) {
                float sc = pm * (lsr[p * lanes + l] * (1.0f / 127.0f));
                for (int wi = 0; wi < 2; ++wi) {
                    uint32_t word = pr[p * (m_tile == 1024 ? TILE1024_WORDS_PER_PAGE : TILE512_WORDS_PER_PAGE) + l * 2 + wi];
                    for (int d = 0; d < 16; ++d) {
                        int col = p * page_size + l * 32 + wi * 16 + d;
                        if (col >= in_dim) break;
                        uint32_t bits = (word >> (d * 2)) & 3u;
                        w[r * in_dim + col] = bits == 1 ? sc : bits == 2 ? -sc : 0;
                    }
                }
            }
        }
        if (off && cols && vals) {
            int32_t lo = off[r], hi = off[r + 1];
            for (int32_t k = lo; k < hi; ++k) {
                int32_t c = cols[k];
                if (c >= 0 && c < in_dim) w[r * in_dim + c] = ggml_fp16_to_fp32(vals[k]);
            }
        }
    }
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
    for (int64_t i = 0; i < out_dim; ++i) {
        const float * wr = w.data() + i * in_dim;
        for (size_t j = 0; j < n_tokens; ++j) {
#if defined(__AVX512F__)
            __m512 acc = _mm512_setzero_ps();
            for (int64_t kb = 0; kb < in_dim; kb += TILE_L2) {
                int64_t ke = std::min<int64_t>(kb + TILE_L2, in_dim);
                for (int64_t k = kb; k < ke; k += TILE_L1) {
                    int64_t ke2 = std::min<int64_t>(k + TILE_L1, ke);
                    int64_t kk = k;
                    for (; kk + 16 <= ke2; kk += 16) {
                        __m512 aw = _mm512_loadu_ps(wr + kk);
                        __m512 bw;
                        if (act_type == element::f16) {
                            alignas(64) float tmp[16];
                            const ggml_fp16_t* ap = reinterpret_cast<const ggml_fp16_t*>(act_raw) + kk * n_tokens + j;
                            for (int t = 0; t < 16; ++t) tmp[t] = ggml_fp16_to_fp32(ap[t * n_tokens]);
                            bw = _mm512_loadu_ps(tmp);
                        } else {
                            alignas(64) float tmp[16];
                            const float* ap = reinterpret_cast<const float*>(act_raw) + kk * n_tokens + j;
                            for (int t = 0; t < 16; ++t) tmp[t] = ap[t * n_tokens];
                            bw = _mm512_loadu_ps(tmp);
                        }
                        acc = _mm512_fmadd_ps(aw, bw, acc);
                    }
                    for (; kk < ke2; ++kk) {
                        float a = wr[kk];
                        float b = act_type == element::f16 ? ggml_fp16_to_fp32(reinterpret_cast<const ggml_fp16_t*>(act_raw)[kk * n_tokens + j]) : reinterpret_cast<const float*>(act_raw)[kk * n_tokens + j];
                        acc = _mm512_add_ps(acc, _mm512_set1_ps(a * b));
                    }
                }
            }
            out[i * n_tokens + j] = _mm512_reduce_add_ps(acc);
#else
            double s = 0;
            for (int64_t k = 0; k < in_dim; ++k) {
                float a = wr[k];
                float b = act_type == element::f16 ? ggml_fp16_to_fp32(reinterpret_cast<const ggml_fp16_t*>(act_raw)[k * n_tokens + j]) : reinterpret_cast<const float*>(act_raw)[k * n_tokens + j];
                s += a * b;
            }
            out[i * n_tokens + j] = (float)s;
#endif
        }
    }
    return true;
}
bool TileIntelGen11Fused::has_evaluate() const { return true; }

} // v0
} // op
} // ov

namespace ov {
namespace frontend {
namespace ggml {
namespace op {

OutputVector translate_tile512_matmul(const NodeContext & ctx) {
    num_inputs_check(ctx, 7, 7);
    int32_t * op_params = ctx.get_output_op_params();
    int32_t out_dim = op_params ? op_params[0] : 0;
    auto B = process_view_input_new(ctx, 6);
    auto B_shape = ctx.get_input_shape(6).to_shape();
    int64_t in_dim = B_shape.size() >= 1 ? (int64_t)B_shape[0] : 0;
    if (in_dim == 0 || out_dim == 0) {
        auto dummy = ov::op::v0::Constant::create(ov::element::f16, ov::Shape{1, 1}, {0});
        ov::Output<ov::Node> res = std::make_shared<ov::op::v0::MatMul>(B, dummy, false, true);
        return rename_outputs_with_suffix({res}, ctx.get_name());
    }
    auto packed = ctx.get_input(0);
    auto ps = ctx.get_input(1);
    auto ls = ctx.get_input(2);
    auto off = ctx.get_input(3);
    auto cols = ctx.get_input(4);
    auto vals = ctx.get_input(5);
    auto node = std::make_shared<ov::op::v0::TileIntelGen11Fused>(packed, ps, ls, off, cols, vals, B, out_dim, in_dim, 512, false);
    if (node->get_output_element_type(0) != ctx.get_output_type()) {
        auto c = std::make_shared<ov::op::v0::Convert>(node, ctx.get_output_type());
        return rename_outputs_with_suffix({c}, ctx.get_name());
    }
    return rename_outputs_with_suffix({node}, ctx.get_name());
}
OutputVector translate_tile512_matmul_id(const NodeContext & ctx) {
    num_inputs_check(ctx, 8, 9);
    auto B = process_view_input_new(ctx, 6);
    auto ids = process_view_input_new(ctx, 7);
    FRONT_END_OP_CONVERSION_CHECK(false, "TILE512 ID not yet via Gen11 fused");
    return {B, ids};
}
OutputVector translate_tile512_get_rows(const NodeContext & ctx) {
    num_inputs_check(ctx, 7, 7);
    auto ids = process_view_input_new(ctx, 6);
    FRONT_END_OP_CONVERSION_CHECK(false, "TILE512 GET_ROWS not yet");
    return {ids};
}
OutputVector translate_tile512_dequant(const NodeContext & ctx) {
    num_inputs_check(ctx, 6, 6);
    auto packed = ctx.get_input(0);
    FRONT_END_OP_CONVERSION_CHECK(false, "TILE512 DEQUANT via fused");
    return {packed};
}
OutputVector translate_tile1024_matmul(const NodeContext & ctx) {
    num_inputs_check(ctx, 7, 7);
    int32_t * op_params = ctx.get_output_op_params();
    int32_t out_dim = op_params ? op_params[0] : 0;
    auto B = process_view_input_new(ctx, 6);
    auto B_shape = ctx.get_input_shape(6).to_shape();
    int64_t in_dim = B_shape.size() >= 1 ? (int64_t)B_shape[0] : 0;
    if (in_dim == 0 || out_dim == 0) {
        auto dummy = ov::op::v0::Constant::create(ov::element::f16, ov::Shape{1, 1}, {0});
        ov::Output<ov::Node> res = std::make_shared<ov::op::v0::MatMul>(B, dummy, false, true);
        return rename_outputs_with_suffix({res}, ctx.get_name());
    }
    auto packed = ctx.get_input(0);
    auto ps = ctx.get_input(1);
    auto ls = ctx.get_input(2);
    auto off = ctx.get_input(3);
    auto cols = ctx.get_input(4);
    auto vals = ctx.get_input(5);
    auto node = std::make_shared<ov::op::v0::TileIntelGen11Fused>(packed, ps, ls, off, cols, vals, B, out_dim, in_dim, 1024, false);
    if (node->get_output_element_type(0) != ctx.get_output_type()) {
        auto c = std::make_shared<ov::op::v0::Convert>(node, ctx.get_output_type());
        return rename_outputs_with_suffix({c}, ctx.get_name());
    }
    return rename_outputs_with_suffix({node}, ctx.get_name());
}
OutputVector translate_tile1024_matmul_id(const NodeContext & ctx) {
    num_inputs_check(ctx, 8, 9);
    auto B = process_view_input_new(ctx, 6);
    auto ids = process_view_input_new(ctx, 7);
    FRONT_END_OP_CONVERSION_CHECK(false, "TILE1024 ID via Gen11");
    return {B, ids};
}
OutputVector translate_tile1024_get_rows(const NodeContext & ctx) {
    num_inputs_check(ctx, 7, 7);
    auto ids = process_view_input_new(ctx, 6);
    FRONT_END_OP_CONVERSION_CHECK(false, "TILE1024 GET_ROWS");
    return {ids};
}
OutputVector translate_tile1024_dequant(const NodeContext & ctx) {
    num_inputs_check(ctx, 6, 6);
    auto p = ctx.get_input(0);
    FRONT_END_OP_CONVERSION_CHECK(false, "TILE1024 DEQUANT");
    return {p};
}

} // op
} // ggml
} // frontend
} // ov
