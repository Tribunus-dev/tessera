#include "../src/core/moe/MoE.h"
#include <cassert>
#include <vector>
int main(){
    using namespace tessera::moe;
    TokenState tok; tok.pos=42; tok.hidden={0.1f, -0.2f, 0.3f};
    // Top-K
    TopKRouter top(123);
    auto r1 = top.route(tok, 8, 2);
    assert(r1.experts.size()==2);
    assert(r1.scores.size()==2);
    assert(r1.aux_loss > 0);
    // Deterministic: same pos+hidden -> same experts
    auto r1b = top.route(tok, 8, 2);
    assert(r1.experts==r1b.experts);
    // Soft router
    SoftRouter soft;
    auto r2 = soft.route(tok, 8, 2);
    assert(r2.experts.size()==2);
    // Stable router frozen cache
    StableRouter stable(0.1f, true);
    auto r3 = stable.route(tok, 8, 2);
    auto r3b = stable.route(tok, 8, 2);
    assert(r3.experts==r3b.experts);
    // APEX tiers
    auto all = ApexPlan::all();
    assert(all.size()==5);
    for(auto &p: all){
        auto s = p.to_tensor_type_file();
        assert(s.find("APEX")!=std::string::npos);
        assert(s.find("routed:")!=std::string::npos);
        assert(p.size_gb > 10);
    }
    auto bal = ApexPlan::for_tier(ApexTier::Balanced);
    assert(bal.tier==ApexTier::Balanced);
    assert(bal.label.find("Balanced")!=std::string::npos);
    // Different tiers have different tensor types
    auto q = ApexPlan::for_tier(ApexTier::Quality);
    auto mini = ApexPlan::for_tier(ApexTier::Mini);
    assert(q.tensor_types != mini.tensor_types);
    return 0;
}
