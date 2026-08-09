#include "Dispatcher.h"
#include <algorithm>

namespace tessera::moe {

Dispatcher::Dispatcher(DeviceRegistry *reg, RegimeManager *rm)
    : reg_(reg ? reg : &DeviceRegistry::instance()), rm_(rm ? rm : nullptr) {
    // shard map 4090:32 9070:16 A770:12 VII:4 per plan
    expert_shard_map_ = {32,16,12,4};
}

DispatchResult Dispatcher::route(const Op &op, int seq_len) {
    DispatchResult r; r.op = op;
    // Router -> CPU
    if (op.kind == OpKind::Router) {
        r.queue.id = "cpu:0:vector";
        r.queue.kind = QueueKind::Vector;
        r.queue.tile = 256;
        r.queue.dtype = "f32";
        return r;
    }
    // Dequant/Layernorm -> always VectorQueue (CUDA PK)
    if (op.kind == OpKind::Dequant || op.kind == OpKind::Layernorm) {
        r.queue = reg_->pick_for_decode();
        r.queue.kind = QueueKind::Vector;
        if (r.queue.tile == 512) r.queue.tile = 256; // dequant prefers vector-packed
        return r;
    }

    bool wantMatrix = (op.M%16==0 && op.N%16==0 && int64_t(op.M)*op.N*op.K > 2000000);
    // Attn prefill large -> MatrixQueue on max flops
    if (op.kind == OpKind::AttnPrefill) {
        r.queue = reg_->pick_for_prefill(op.M, op.N, op.K);
        if (!wantMatrix || !r.queue.hasWMMA) r.queue = reg_->pick_for_decode();
        r.via_blit = true;
        return r;
    }
    if (op.kind == OpKind::AttnDecode) {
        r.queue = reg_->pick_for_decode();
        // decode small -> VectorQueue even if hasWMMA
        r.queue.kind = QueueKind::Vector;
        r.queue.tile = 256;
        return r;
    }
    if (op.kind == OpKind::ExpertFFN) {
        // shard by expertId % devices, then size thr -> Matrix vs Vector
        int ndev = reg_->devices().size();
        if (ndev==0) ndev=1;
        int devIdx = op.expert>=0 ? (op.expert % ndev) : (op.layer % ndev);
        auto devs = reg_->devices();
        if (devIdx < (int)devs.size()) {
            auto &pd = devs[devIdx];
            bool useMat = wantMatrix && pd.matrix_queue.hasWMMA;
            r.queue = useMat ? pd.matrix_queue : pd.vector_queue;
        } else {
            r.queue = reg_->pick_for_decode();
        }
        r.via_blit = true;
        return r;
    }
    // default
    r.queue = reg_->pick_for_decode();
    if (seq_len > 512 && wantMatrix && r.queue.hasWMMA) r.queue.kind = QueueKind::Matrix;
    return r;
}

std::vector<DispatchResult> Dispatcher::dispatch_graph(const std::vector<Op> &graph,int seq_len,bool /*low_power*/) {
    std::vector<DispatchResult> out;
    out.reserve(graph.size());
    for (auto &op : graph) out.push_back(route(op, seq_len));
    // 3-stage bounded pipelining: at most 2 tiles in shared + 1 in flight, Dispatcher just tags via_blit
    return out;
}

} // namespace tessera::moe
