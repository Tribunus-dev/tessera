#pragma once
#include <openvino/pass/graph_rewrite.hpp>

namespace ov {
namespace frontend {
namespace ggml {
namespace pass {

// MatcherPass that collapses the FrontEnd's Tile640 subgraph
//   (F16 Constant[ Tile640HostDequant ] -> Transpose -> MatMul -> Transpose -> Convert)
// into a single Tile640Fused node. Mirrors fuse_to_sdpa.cpp / squeeze_matmul.cpp.
// Register in translate_session.cpp: manager.register_pass<FuseTile640Fused>();
class FuseTile640Fused : public ov::pass::MatcherPass {
public:
    FuseTile640Fused();
};

} // pass
} // ggml
} // frontend
} // ov
