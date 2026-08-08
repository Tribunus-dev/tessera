#include "fuse_tile640.h"
#include "../op/tile640_fused.h"
#include <openvino/core/graph_util.hpp>
#include <openvino/core/rt_info.hpp>
#include <openvino/op/constant.hpp>
#include <openvino/op/convert.hpp>
#include <openvino/op/matmul.hpp>
#include <openvino/op/transpose.hpp>
#include <openvino/pass/pattern/op/label.hpp>
#include <openvino/pass/pattern/op/pattern.hpp>
#include <openvino/pass/pattern/op/wrap_type.hpp>

namespace ov {
namespace frontend {
namespace ggml {
namespace pass {

FuseTile640Fused::FuseTile640Fused() {
    // Pattern:  Tile640 MatMul subgraph as emitted by translate_tile640_matmul:
    //   weight_const[F16] = Constant (host-dequant)
    //   B_t = Transpose(B)  (or Reshape)
    //   mm = MatMul(B_t, weight_const.T)
    //   out = Transpose(mm) -> Convert
    // We label the weight Constant and the activation to reconstruct Tile640Fused attrs.
    auto w = ov::pass::pattern::wrap_type<ov::op::v0::Constant>();
    auto act = ov::pass::pattern::any_input();
    auto act_t = ov::pass::pattern::wrap_type<ov::op::v1::Transpose>({act});
    auto mm = ov::pass::pattern::wrap_type<ov::op::v0::MatMul>({act_t, w});
    auto out_t = ov::pass::pattern::wrap_type<ov::op::v1::Transpose>({mm});
    // Optional final Convert to f32
    auto out = ov::pass::pattern::wrap_type<ov::op::v0::Convert>({out_t});

    const auto callback = [=](ov::pass::pattern::Matcher & m) {
        auto & pmap = m.get_pattern_value_map();
        // Keep the original 7-input form; here we fuse the already-lowered F16 path
        // into a single node so WeightlessCacheAttribute + NPUW can treat it as one
        // cache entry (same trick as MarkCompressedFloatConstants in translate_session.cpp:260).
        auto matmul = ov::as_type_ptr<ov::op::v0::MatMul>(pmap.at(mm).get_node_shared_ptr());
        if (!matmul) return false;
        // Replace mm+transposes+convert with Tile640Fused placeholder (6 dummy weight inputs + act)
        // Dummy inputs keep the 7-arity; real lowering would forward the original 6 Constants.
        // For the skeleton we just keep act and reuse w as packed; the other 5 are w as well.
        auto act_node = pmap.at(act);
        auto w_node = pmap.at(w);
        // out_dim/in_dim from Constant shape
        auto w_const = ov::as_type_ptr<ov::op::v0::Constant>(w_node.get_node_shared_ptr());
        if (!w_const) return false;
        auto w_shape = w_const->get_shape(); // [out_dim, in_dim]
        if (w_shape.size() < 2) return false;
        auto fused = std::make_shared<ov::op::v0::Tile640Fused>(
            w_node, w_node, w_node, w_node, w_node, w_node, act_node,
            (int64_t)w_shape[0], (int64_t)w_shape[1], false);
        auto convert = ov::as_type_ptr<ov::op::v0::Convert>(pmap.at(out).get_node_shared_ptr());
        auto target = convert ? std::static_pointer_cast<ov::Node>(convert) : pmap.at(out_t).get_node_shared_ptr();
        ov::replace_node(target, fused);
        return true;
    };

    auto m = std::make_shared<ov::pass::pattern::Matcher>(out, "FuseTile640Fused");
    register_matcher(m, callback);
}

} // pass
} // ggml
} // frontend
} // ov
