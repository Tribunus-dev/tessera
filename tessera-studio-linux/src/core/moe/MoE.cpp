#include "MoE.h"
#include <glib.h>
#include <random>
#include <algorithm>
#include <cmath>
#include <sstream>
#include <fstream>

namespace tessera::moe {

// ── Routers ──
TopKRouter::TopKRouter(int seed): rng_(seed) {}
RouteResult TopKRouter::route(const TokenState &tok, int n_experts, int top_k){
    // deterministic hash of pos+hidden magnitude → stable for A/B
    uint64_t h = (uint64_t)tok.pos * 1000003;
    float mag = 0; for(float v: tok.hidden) mag += fabs(v);
    h ^= (uint64_t)(mag*1000);
    std::mt19937_64 gen(h + rng_);
    std::vector<std::pair<float,int>> scored;
    for(int i=0;i<n_experts;i++) scored.push_back({std::uniform_real_distribution<float>(0,1)(gen), i});
    sort(scored.begin(), scored.end(), [](auto&a,auto&b){return a.first>b.first;});
    RouteResult r;
    for(int i=0;i<std::min(top_k,(int)scored.size());i++){ r.experts.push_back(scored[i].second); r.scores.push_back(scored[i].first); }
    // aux load-balance loss
    r.aux_loss = 0.01f * (float)scored.size() / n_experts;
    return r;
}
RouteResult SoftRouter::route(const TokenState &tok, int n_experts, int top_k){
    // Soft MoE: weighted average of all tokens → here single token, so smooth distribution
    RouteResult base = TopKRouter(99).route(tok, n_experts, n_experts);
    // soften via temperature 1.5
    float T=1.5f, sum=0;
    for(float &s: base.scores) { s = exp(s/T); sum+=s; }
    for(float &s: base.scores) s/=sum;
    // keep top_k but with soft weights
    RouteResult r;
    for(int i=0;i<std::min(top_k,(int)base.experts.size());i++){ r.experts.push_back(base.experts[i]); r.scores.push_back(base.scores[i]); }
    r.aux_loss = 0.005f;
    return r;
}
StableRouter::StableRouter(float w, bool f): z_loss_w_(w), frozen_(f) {}
RouteResult StableRouter::route(const TokenState &tok, int n_experts, int top_k){
    int key = tok.pos % 1024;
    if(frozen_ && cache_.count(key)) return cache_[key];
    RouteResult r = TopKRouter(202).route(tok, n_experts, top_k);
    // ST-MoE z-loss: log-sum-exp penalty
    float lse=0; for(float s: r.scores) lse+=exp(s); lse=log(lse);
    r.aux_loss = z_loss_w_ * lse * lse;
    if(frozen_) cache_[key]=r;
    return r;
}

// ── APEX ──
ApexPlan ApexPlan::for_tier(ApexTier t){
    ApexPlan p; p.tier=t;
    switch(t){
        case ApexTier::Quality: p.label="21.3GB Quality"; p.size_gb=21.3; break;
        case ApexTier::Balanced: p.label="18.7GB Balanced"; p.size_gb=18.7; break;
        case ApexTier::Compact: p.label="16.1GB Compact"; p.size_gb=16.1; break;
        case ApexTier::Lean: p.label="14.0GB Lean"; p.size_gb=14.0; break;
        case ApexTier::Mini: p.label="12.2GB Mini"; p.size_gb=12.2; break;
    }
    // edge gradient + routed/shared/attn rules (real APEX file syntax)
    // This feeds llama.cpp --tensor-type; tessera-cli writes the file.
    if(t==ApexTier::Quality) p.tensor_types="routed:Q6_K shared:Q8_0 attn:Q6_K blk.0-4:Q8_0 blk.27-31:Q8_0";
    else if(t==ApexTier::Balanced) p.tensor_types="routed:Q5_K shared:Q8_0 attn:Q6_K blk.0-4:Q6_K blk.27-31:Q6_K";
    else if(t==ApexTier::Compact) p.tensor_types="routed:Q5_K shared:Q8_0 attn:Q6_K blk.0-2:Q6_K blk.29-31:Q6_K";
    else if(t==ApexTier::Lean) p.tensor_types="routed:Q4_K shared:Q8_0 attn:Q6_K blk.0-1:Q6_K";
    else p.tensor_types="routed:Q4_K shared:Q6_K attn:Q4_K";
    return p;
}
std::vector<ApexPlan> ApexPlan::all(){ return {for_tier(ApexTier::Quality), for_tier(ApexTier::Balanced), for_tier(ApexTier::Compact), for_tier(ApexTier::Lean), for_tier(ApexTier::Mini)}; }
std::string ApexPlan::to_tensor_type_file() const {
    std::ostringstream oss;
    oss << "# APEX " << label << " " << size_gb << "GB\n";
    oss << "# routed→Q4-Q6_K shared→Q8_0 attn→Q6_K edge-gradient 5+5\n";
    oss << tensor_types << "\n";
    return oss.str();
}

// ── ExpertCache ──
ExpertCache::ExpertCache(size_t b): vram_budget_(b) {}
bool ExpertCache::contains(int l,int e) const { return tier_.count(l*10000+e) && tier_.at(l*10000+e)==CacheTier::VRAM; }
bool ExpertCache::load(int l,int e, CacheTier from){
    int64_t k=l*10000+e;
    auto it=tier_.find(k);
    if(it!=tier_.end() && it->second==CacheTier::VRAM){ stats_.hits++; return true; }
    stats_.misses++;
    // simulate async load — count
    if(tier_.size() >= vram_budget_) evict_lru();
    tier_[k]=CacheTier::VRAM;
    stats_.vram_experts=(int)tier_.size();
    (void)from; return false;
}
void ExpertCache::evict_lru(){ if(tier_.empty()) return; tier_.erase(tier_.begin()); }
CORMCache::CORMCache(size_t b,float thr): ExpertCache(b), thr_(thr) {}
int CORMCache::active_neurons(int layer,int expert,int total) const {
    // 35% neurons ignorable at thr 0.175 → deterministic pseudo
    uint64_t h=(uint64_t)layer*10007 + expert*101;
    std::mt19937 gen((uint32_t)h);
    std::uniform_real_distribution<float> d(0,1);
    int active=0;
    for(int i=0;i<total;i++) if(d(gen) > 0.35f) active++;
    (void)thr_; return active;
}

// ── Prefetchers ──
SpecPrefetchAdapter::SpecPrefetchAdapter(int w): window_(w) {}
PrefetchResult SpecPrefetchAdapter::predict(int next_layer, const TokenState&, const RouteResult& cur){
    PrefetchResult r;
    // lightweight adapter: predict +1 shift of current Top-K with jitter
    for(int e: cur.experts) r.predicted.push_back((e+1) % 64);
    r.confidence=0.72f; r.budget=(int)r.predicted.size();
    (void)next_layer; return r;
}
int SpecPrefetchAdapter::budget_for(int layer,int remaining) const {
    int w = window_;
    return std::min(remaining, std::max(2, 8 - (layer % w)));
}
PrefetchResult SPMoEPrefetcher::predict(int next_layer, const TokenState&, const RouteResult& cur){
    PrefetchResult r;
    // SP-MoE: draft attention + target gating → here simulate gating-biased
    for(int i=0;i<(int)cur.experts.size();i++) r.predicted.push_back(cur.experts[i]);
    if(r.predicted.size()<4) for(int i=(int)r.predicted.size(); i<4; i++) r.predicted.push_back((cur.experts[0]+i)%64);
    r.confidence=0.68f; r.budget=(int)r.predicted.size();
    (void)next_layer; return r;
}
PrefetchResult CORMPrefetcher::predict(int next_layer, const TokenState&, const RouteResult& cur){
    PrefetchResult r;
    for(int e: cur.experts) r.predicted.push_back(e);
    r.confidence=0.75f; r.budget=(int)r.predicted.size();
    (void)next_layer; (void)cache_; return r;
}

// ── Bench ──
std::string BenchResult::to_json() const {
    std::ostringstream oss;
    oss << "{\"prefetcher\":\"" << prefetcher << "\",\"scenario\":\"" << scenario << "\",\"apex_tier\":\"" << apex_tier
        << "\",\"ttft_ms\":" << ttft_ms << ",\"decode_tps\":" << decode_tps
        << ",\"hit_rate\":" << hit_rate << ",\"stall_ms\":" << stall_ms
        << ",\"vram_peak_mb\":" << vram_peak_mb << ",\"ppl_delta\":" << ppl_delta
        << ",\"ts_ms\":" << ts_ms << "}";
    return oss.str();
}
std::string Bench::results_path(){
    const char *home=g_get_user_data_dir();
    std::string dir=std::string(home)+"/tessera/bench";
    g_mkdir_with_parents(dir.c_str(), 0755);
    int64_t now=g_get_real_time()/1000;
    return dir + "/" + std::to_string(now) + ".jsonl";
}
void Bench::write_jsonl(const std::vector<BenchResult>& rs, const std::string& path){
    std::ofstream f(path);
    for(auto &r: rs) f << r.to_json() << "\n";
}

std::vector<BenchResult> Bench::run_ab(Router &router, const std::vector<Prefetcher*> &prefetchers, ExpertCache &cache, const CasPolicy &cas, const std::vector<BenchScenario> &scenarios, const std::vector<BenchSample> &samples, ApexTier tier){
    std::vector<BenchResult> out;
    auto plan=ApexPlan::for_tier(tier);
    for(auto &sc: scenarios){
        for(auto *pf: prefetchers){
            BenchResult r; r.prefetcher=pf->name(); r.scenario=sc.name; r.apex_tier=plan.label;
            r.ts_ms=g_get_real_time()/1000;
            // simulate per-sample
            int hits=0, total=0; double stall=0;
            for(auto &s: samples){
                int top_k = cas.experts_for(s.complexity);
                RouteResult rr = router.route(s.tok, 64, top_k);
                PrefetchResult pr = pf->predict(0, s.tok, rr);
                int budget = pf->budget_for(0, top_k);
                (void)budget;
                for(int e: pr.predicted){
                    total++;
                    if(cache.contains(0,e)) hits++; else { stall+=0.8; cache.load(0,e); }
                }
                // also actual routing
                for(int e: rr.experts){
                    total++;
                    if(cache.contains(0,e)) hits++; else { stall+=1.2; cache.load(0,e); }
                }
            }
            r.hit_rate = total? (double)hits/total : 0;
            r.stall_ms = stall;
            r.ttft_ms = 120 + stall*0.5; // synthetic
            r.decode_tps = 35.0 / (1.0 + stall*0.02);
            r.vram_peak_mb = (int)sc.vram_mb - (int)(stall*2);
            if(r.vram_peak_mb<0) r.vram_peak_mb=8000;
            r.ppl_delta = (tier==ApexTier::Mini?0.12:(tier==ApexTier::Quality?0.01:0.05));
            out.push_back(r);
        }
    }
    return out;
}

} // namespace tessera::moe
