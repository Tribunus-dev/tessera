#pragma once
// Dispatcher — per-op routing over dual Vector+Matrix queues, with 3-stage bounded pipelining and fused ternary KV+W
// Keeps weights resident, only ~4MB hiddens cross PCIe via blit-prefetch; VectorQueue dequant overlaps MatrixQueue MMA
#include "MoE.h"
#include "DeviceRegistry.h"
#include "RegimeManager.h"
#include <vector>
#include <functional>

namespace tessera::moe {

enum class OpKind { Router, AttnPrefill, AttnDecode, ExpertFFN, FFN, Dequant, Layernorm, Other };

struct Op {
    OpKind kind = OpKind::Other;
    int M=0,N=0,K=0;          // GEMM shape for cost model
    int layer=0;
    int expert=-1;            // for ExpertFFN
    size_t bytes=0;
};

struct DispatchResult {
    Op op;
    LogicalQueue queue;
    bool via_blit = false;    // blit-prefetch overlap
};

class Dispatcher {
public:
    explicit Dispatcher(DeviceRegistry *reg = nullptr, RegimeManager *rm = nullptr);

    // Per-op routing — dual queue choice: MatrixQueue if M%16==0 && N%16==0 && M*N*K>2M && hasWMMA else VectorQueue
    DispatchResult route(const Op &op, int seq_len);

    // Dispatch whole ggml cgraph (vector<Op> stub) -> per-op queues, with pipeline depth 2-3
    std::vector<DispatchResult> dispatch_graph(const std::vector<Op> &graph, int seq_len, bool low_power = false);

private:
    DeviceRegistry *reg_;
    RegimeManager *rm_;
    std::vector<int> expert_shard_map_; // expertId % devices
};

} // namespace tessera::moe
