#pragma once
#include <openvino/op/op.hpp>
#include <openvino/core/shape.hpp>

namespace ov {
namespace op {
namespace v0 {

// Tessera fused Tile640: 6-weight (packed I32 + F16 page_scales + I8 lane_scales + CSR
// outliers) + activation -> F32. Host dequant already done in the FrontEnd's
// translate_tile640_* (F16 Constant), so the IR node is a single cacheable
// F16 MatMul/Gather with WeightlessCacheAttribute. The NPU plugin can later
// lower it to NPUW Decompress (same hook as Q4_0 in ggml-quants.cpp).
class Tile640Fused : public ov::op::Op {
public:
    OPENVINO_OP("Tile640Fused", "opset1");
    Tile640Fused() = default;
    Tile640Fused(const Output<Node> & packed, const Output<Node> & page_scales,
                 const Output<Node> & lane_scales, const Output<Node> & outlier_offsets,
                 const Output<Node> & outlier_cols, const Output<Node> & outlier_vals,
                 const Output<Node> & activation, int64_t out_dim, int64_t in_dim, bool is_moe = false);
    void validate_and_infer_types() override;
    std::shared_ptr<Node> clone_with_new_inputs(const OutputVector & new_args) const override;
    bool visit_attributes(AttributeVisitor & visitor) override;
    bool evaluate(TensorVector & outputs, const TensorVector & inputs) const override;
    bool has_evaluate() const override;
private:
    int64_t m_out_dim = 0;
    int64_t m_in_dim = 0;
    bool m_is_moe = false;
};

} // v0
} // op
} // ov
