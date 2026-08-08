#pragma once
#include <openvino/op/op.hpp>
namespace ov { namespace op { namespace v0 {
class TileIntelGen11Fused : public ov::op::Op {
public:
    OPENVINO_OP("TileIntelGen11Fused", "opset1");
    TileIntelGen11Fused() = default;
    TileIntelGen11Fused(const Output<Node> & packed, const Output<Node> & page_scales,
                 const Output<Node> & lane_scales, const Output<Node> & outlier_offsets,
                 const Output<Node> & outlier_cols, const Output<Node> & outlier_vals,
                 const Output<Node> & activation, int64_t out_dim, int64_t in_dim, int tile = 512, bool is_moe=false);
    void validate_and_infer_types() override;
    std::shared_ptr<Node> clone_with_new_inputs(const OutputVector & n) const override;
    bool visit_attributes(AttributeVisitor & v) override;
    bool evaluate(TensorVector & out, const TensorVector & in) const override;
    bool has_evaluate() const override;
private:
    int64_t m_out_dim=0; int64_t m_in_dim=0; int m_tile=512; bool m_is_moe=false;
};
} } }
