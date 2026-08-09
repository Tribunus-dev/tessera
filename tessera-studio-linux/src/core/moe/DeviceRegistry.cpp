#include "DeviceRegistry.h"
#include "../hardware/HardwareProber.h"

namespace tessera::moe {

DeviceRegistry &DeviceRegistry::instance() {
    static DeviceRegistry r;
    return r;
}

void DeviceRegistry::probe() {
    devices_.clear();
    auto caps = tessera::hardware::HardwareProber::probe();
    for (auto &c : caps) {
        PhysicalDevice pd;
        pd.name = c.name;
        pd.phys_id = c.id;
        pd.caps = c;
        pd.vector_queue.id = c.id + ":vector";
        pd.vector_queue.kind = QueueKind::Vector;
        pd.vector_queue.tile = 256; // vector-packed T256 for legacy fallback, shared staging
        pd.vector_queue.dtype = "f32";
        if (c.dtype == tessera::hardware::DType::F16) pd.vector_queue.dtype = "f16";
        else if (c.dtype == tessera::hardware::DType::BF16) pd.vector_queue.dtype = "bf16";
        else if (c.dtype == tessera::hardware::DType::INT8) pd.vector_queue.dtype = "int8";
        else if (c.dtype == tessera::hardware::DType::INT4) pd.vector_queue.dtype = "int4";
        pd.vector_queue.hasWMMA = false;

        pd.matrix_queue.id = c.id + ":matrix";
        pd.matrix_queue.kind = QueueKind::Matrix;
        pd.matrix_queue.tile = 512; // WMMA 16x16 path
        pd.matrix_queue.dtype = pd.vector_queue.dtype;
        pd.matrix_queue.hasWMMA = c.hasWMMA && c.hasCoopMat;

        // Apple CPU fallback keeps only vector
        if (c.id.rfind("cpu",0)==0) pd.matrix_queue.hasWMMA = false;

        devices_.push_back(pd);
    }
}

std::vector<PhysicalDevice> DeviceRegistry::devices() const { return devices_; }

std::vector<LogicalQueue> DeviceRegistry::all_queues() const {
    std::vector<LogicalQueue> out;
    for (auto &d : devices_) {
        out.push_back(d.vector_queue);
        if (d.matrix_queue.hasWMMA) out.push_back(d.matrix_queue);
    }
    return out;
}

std::optional<PhysicalDevice> DeviceRegistry::find(const std::string &phys_id) const {
    for (auto &d : devices_) if (d.phys_id==phys_id) return d;
    return std::nullopt;
}

std::optional<LogicalQueue> DeviceRegistry::find_queue(const std::string &qid) const {
    for (auto &q : all_queues()) if (q.id==qid) return q;
    return std::nullopt;
}

LogicalQueue DeviceRegistry::pick_for_prefill(int M,int N,int K) const {
    // Prefer MatrixQueue on max flops device when shape suits WMMA
    bool wantMatrix = (M%16==0 && N%16==0 && int64_t(M)*N*K > 2000000);
    LogicalQueue best{};
    int64_t bestScore=-1;
    for (auto &d : devices_) {
        auto &cand = (wantMatrix && d.matrix_queue.hasWMMA) ? d.matrix_queue : d.vector_queue;
        int64_t score = int64_t(d.caps.bw_mbps) * (cand.hasWMMA?2:1);
        if (score > bestScore) { bestScore=score; best=cand; }
    }
    return best;
}

LogicalQueue DeviceRegistry::pick_for_decode() const {
    // KV owner: max vram*bw (VII HBM wins)
    PhysicalDevice best{};
    int64_t bestScore=-1;
    for (auto &d : devices_) {
        int64_t score = int64_t(d.caps.vram_bytes) * int64_t(d.caps.bw_mbps);
        if (score > bestScore) { bestScore=score; best=d; }
    }
    return best.vector_queue;
}

} // namespace tessera::moe
