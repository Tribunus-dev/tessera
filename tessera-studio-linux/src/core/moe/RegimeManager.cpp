#include "RegimeManager.h"

namespace tessera::moe {

RegimeManager::RegimeManager(DeviceRegistry *reg): reg_(reg ? reg : &DeviceRegistry::instance()) {}

Regime RegimeManager::select(int seq_len,int batch,bool low_power,const LogicalQueue &preferred) {
    Regime r;
    r.apex = apex_;
    r.prefetcher = prefetcher_;
    r.cas = cas_;

    if (low_power) {
        r.kind = RegimeKind::Efficient;
        r.queue = reg_->pick_for_decode(); // NPU/iGPU
        r.tile = r.queue.tile;
        r.dtype = r.queue.dtype;
        r.router = RouterKind::Stable;
        return r;
    }

    if (seq_len > 512 || batch > 4) {
        r.kind = RegimeKind::Prefill;
        // MatrixQueue if shape suits
        r.queue = preferred.id.empty() ? reg_->pick_for_prefill(seq_len, 4096, seq_len*batch) : preferred;
        r.router = RouterKind::TopK;
    } else {
        r.kind = RegimeKind::Decode;
        r.queue = reg_->pick_for_decode();
        r.router = RouterKind::Stable;
    }

    // Ternary KV standard: tile comes from queue (T256 vector-packed legacy, T512 WMMA), dtype from queue
    r.tile = r.queue.tile;
    r.dtype = r.queue.dtype;

    // Low-power forces Lean tier
    if (low_power && r.apex == ApexTier::Quality) r.apex = ApexTier::Balanced;

    return r;
}

} // namespace tessera::moe
