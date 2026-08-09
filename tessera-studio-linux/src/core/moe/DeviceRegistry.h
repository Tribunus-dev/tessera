#pragma once
// DeviceRegistry — dual LogicalQueues per PhysicalDevice (Vector + Matrix)
// Each HIP/MUSA/CUDA/Vulkan physical device exposes VectorQueue (T256 packed float4/half2) + MatrixQueue (T512 WMMA mma.sync 16x16)
#include "../hardware/HardwareProber.h"
#include <string>
#include <vector>
#include <optional>

namespace tessera::moe {

enum class QueueKind { Vector, Matrix };

struct LogicalQueue {
    std::string id;               // "vulkan:0:vector" / "cuda:0:matrix"
    QueueKind kind = QueueKind::Vector;
    int tile = 256;               // T256 packed vs T512 WMMA
    std::string dtype;            // f32/f16/bf16
    bool hasWMMA = false;
    void *native_queue = nullptr; // VkQueue / hipStream_t / musaQueue / cudaStream_t
};

struct PhysicalDevice {
    std::string name;             // "Radeon VII" / "Arc A770"
    std::string phys_id;          // "vulkan:0" / "hip:0"
    tessera::hardware::DeviceCaps caps;
    LogicalQueue vector_queue;
    LogicalQueue matrix_queue;
};

class DeviceRegistry {
public:
    static DeviceRegistry &instance();

    // Probe and build dual queues for all backends (Vulkan + HIP/MUSA/CUDA opt-in + OpenVINO + CPU)
    void probe();

    std::vector<PhysicalDevice> devices() const;
    std::vector<LogicalQueue> all_queues() const;
    std::optional<PhysicalDevice> find(const std::string &phys_id) const;
    std::optional<LogicalQueue> find_queue(const std::string &queue_id) const;

    // Pick queues for prefill vs decode
    LogicalQueue pick_for_prefill(int M, int N, int K) const; // Matrix if M%16==0 && N%16==0 && M*N*K>2M && hasWMMA
    LogicalQueue pick_for_decode() const;

private:
    std::vector<PhysicalDevice> devices_;
};

} // namespace tessera::moe
