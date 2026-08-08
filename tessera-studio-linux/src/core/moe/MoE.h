#pragma once
// MoE subsystem — Fedora-native, GTK off-thread, A/B test ready.
// Covers: SMoE Top-K, Soft MoE, StableMoE (ST-MoE), APEX quant, CORM offload,
// SpecPrefetch, SP-MoE, CasMoE — all orthogonal, composable.

#include <string>
#include <vector>
#include <unordered_map>
#include <functional>
#include <optional>
#include <cstdint>

namespace tessera::moe {

// ── Types ──
struct ExpertId { int layer; int expert; };
struct TokenState { std::vector<float> hidden; int pos = 0; };

enum class RouterKind { TopK, Soft, Stable };
struct RouteResult {
    std::vector<int> experts; // sorted by score desc
    std::vector<float> scores;
    float aux_loss = 0.f; // load-balance / z-loss
};

// ── Router interface ──
class Router {
public:
    virtual ~Router() = default;
    virtual RouterKind kind() const = 0;
    virtual RouteResult route(const TokenState &tok, int n_experts, int top_k) = 0;
    virtual std::string name() const = 0;
};

class TopKRouter : public Router {
public:
    explicit TopKRouter(int seed = 42);
    RouterKind kind() const override { return RouterKind::TopK; }
    RouteResult route(const TokenState&, int n_experts, int top_k) override;
    std::string name() const override { return "TopK-SMoE"; }
private:
    // deterministic pseudo-router for bench without model weights
    uint64_t rng_ = 0;
};

class SoftRouter : public Router {
public:
    SoftRouter() = default;
    RouterKind kind() const override { return RouterKind::Soft; }
    RouteResult route(const TokenState&, int n_experts, int top_k) override;
    std::string name() const override { return "SoftMoE"; }
};

class StableRouter : public Router {
public:
    StableRouter(float z_loss_w = 0.001f, bool frozen = false);
    RouterKind kind() const override { return RouterKind::Stable; }
    RouteResult route(const TokenState&, int n_experts, int top_k) override;
    void set_frozen(bool f) { frozen_ = f; }
    std::string name() const override { return frozen_ ? "StableMoE-frozen" : "StableMoE"; }
private:
    float z_loss_w_;
    bool frozen_;
    // last routing table for frozen mode
    std::unordered_map<int, RouteResult> cache_;
};

// ── APEX quant ──
enum class ApexTier { Quality, Balanced, Compact, Lean, Mini }; // 21.3GB → 12.2GB
struct ApexPlan {
    ApexTier tier;
    std::string label; // e.g. "21.3GB Quality"
    double size_gb;
    std::string tensor_types; // llama.cpp --tensor-type file content summary
    std::unordered_map<std::string,std::string> layer_map; // pattern → quant (for --tensor-type)
    static ApexPlan for_tier(ApexTier t);
    static std::vector<ApexPlan> all();
    std::string to_tensor_type_file() const; // edge gradient + routed/shared/attn rules
};

// ── ExpertCache / CORM ──
enum class CacheTier { VRAM, RAM, SSD };
struct CacheStats { int hits=0, misses=0, neuron_hits=0; int vram_experts=0, ram_experts=0; };

class ExpertCache {
public:
    explicit ExpertCache(size_t vram_budget_experts = 32);
    bool contains(int layer, int expert) const;
    bool load(int layer, int expert, CacheTier from = CacheTier::RAM); // simulated async
    void evict_lru();
    CacheStats stats() const { return stats_; }
    void set_vram_budget(size_t n) { vram_budget_ = n; }
private:
    size_t vram_budget_;
    std::unordered_map<int64_t, CacheTier> tier_; // key = layer*1000+expert
    mutable CacheStats stats_;
};

// CORM: coarse (expert) + fine (neuron) offloading
class CORMCache : public ExpertCache {
public:
    explicit CORMCache(size_t vram_budget_experts = 32, float neuron_thr = 0.175f);
    // neuron sparsity: 35% neurons ignorable at thr 0.175 → load active neurons only
    int active_neurons(int layer, int expert, int total_neurons = 4096) const;
    float thr() const { return thr_; }
    std::string name() const { return "CORM"; }
private:
    float thr_;
};

// ── Prefetcher interface (SpecPrefetch / SP-MoE / CORM predictor) ──
struct PrefetchResult {
    std::vector<int> predicted; // expert ids for next layer
    float confidence = 0.f;
    int budget = 0; // how many fetched
};

class Prefetcher {
public:
    virtual ~Prefetcher() = default;
    virtual std::string name() const = 0;
    virtual PrefetchResult predict(int next_layer, const TokenState &tok, const RouteResult &current) = 0;
    // window-aware budgeting (SpecPrefetch)
    virtual int budget_for(int layer, int remaining_budget) const { (void)layer; return remaining_budget; }
};

class NoPrefetcher : public Prefetcher {
public:
    std::string name() const override { return "none"; }
    PrefetchResult predict(int, const TokenState&, const RouteResult&) override { return {}; }
};

class SpecPrefetchAdapter : public Prefetcher {
public:
    explicit SpecPrefetchAdapter(int window = 4);
    std::string name() const override { return "SpecPrefetch"; }
    PrefetchResult predict(int next_layer, const TokenState&, const RouteResult& cur) override;
    int budget_for(int layer, int remaining) const override;
private:
    int window_;
};

class SPMoEPrefetcher : public Prefetcher {
public:
    SPMoEPrefetcher() = default;
    std::string name() const override { return "SP-MoE"; }
    PrefetchResult predict(int next_layer, const TokenState&, const RouteResult& cur) override;
};

class CORMPrefetcher : public Prefetcher {
public:
    explicit CORMPrefetcher(CORMCache *cache) : cache_(cache) {}
    std::string name() const override { return "CORM-predictor"; }
    PrefetchResult predict(int next_layer, const TokenState&, const RouteResult& cur) override;
private:
    CORMCache *cache_;
};

// ── CasMoE conditional policy ──
struct CasPolicy {
    bool enabled = true;
    int max_experts = 8; // full
    int min_experts = 2; // cascaded low
    float complexity_thr = 0.6f; // token complexity score
    int experts_for(float complexity) const { return complexity >= complexity_thr ? max_experts : min_experts; }
    std::string name() const { return "CasMoE"; }
};

// ── Bench ──
struct BenchScenario { std::string name; size_t vram_mb; std::string device; }; // e.g. "24GB 3090Ti"
struct BenchSample { TokenState tok; float complexity; };
struct BenchResult {
    std::string prefetcher;
    std::string scenario;
    std::string apex_tier;
    double ttft_ms = 0, decode_tps = 0;
    double hit_rate = 0, stall_ms = 0;
    int vram_peak_mb = 0;
    double ppl_delta = 0;
    int64_t ts_ms = 0;
    std::string to_json() const;
};

class Bench {
public:
    // Runs same samples through Router+Prefetcher+Cache, returns results per prefetcher
    static std::vector<BenchResult> run_ab(
        Router &router,
        const std::vector<Prefetcher*> &prefetchers,
        ExpertCache &cache,
        const CasPolicy &cas,
        const std::vector<BenchScenario> &scenarios,
        const std::vector<BenchSample> &samples,
        ApexTier tier);
    static std::string results_path(); // XDG_DATA_HOME/tessera/bench/<ts>.jsonl
    static void write_jsonl(const std::vector<BenchResult> &rs, const std::string &path);
};

} // namespace tessera::moe
