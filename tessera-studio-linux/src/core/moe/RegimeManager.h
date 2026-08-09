#pragma once
// RegimeManager — selects ApexTier + RouterKind + Prefetcher + CasMoE per logical queue and regime {prefill,decode,efficient}
#include "MoE.h"
#include "DeviceRegistry.h"
#include <string>

namespace tessera::moe {

enum class RegimeKind { Prefill, Decode, Efficient };

struct Regime {
    RegimeKind kind = RegimeKind::Prefill;
    ApexTier apex = ApexTier::Balanced;
    RouterKind router = RouterKind::TopK;
    std::string prefetcher = "SpecPrefetch"; // none/SpecPrefetch/SP-MoE/CORM-predictor
    CasPolicy cas;                            // enabled
    LogicalQueue queue;                       // chosen Vector/Matrix queue
    int tile = 256;
    std::string dtype;
};

class RegimeManager {
public:
    explicit RegimeManager(DeviceRegistry *reg = nullptr);

    // Select regime from seq_len/batch/power + caps
    Regime select(int seq_len, int batch, bool low_power, const LogicalQueue &preferred = {});

    // Settings from GSettings
    void set_apex(ApexTier t) { apex_ = t; }
    void set_prefetcher(const std::string &s) { prefetcher_ = s; }
    void set_cas(const CasPolicy &c) { cas_ = c; }

private:
    DeviceRegistry *reg_;
    ApexTier apex_ = ApexTier::Balanced;
    std::string prefetcher_ = "SpecPrefetch";
    CasPolicy cas_;
};

} // namespace tessera::moe
