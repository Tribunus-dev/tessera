#include "../src/core/ops/Capacity.h"
#include <cassert>
#include <string>
int main(){
    auto cap = tessera::gather_capacity();
    assert(!cap.cpu_model.empty());
    assert(cap.ram_total_mb > 0);
    assert(cap.cpu_threads >= cap.cpu_cores);
    auto fits = tessera::community_fits(cap);
    assert(!fits.empty());
    assert(fits.size() == 10);
    for(auto &f: fits){
        assert(!f.id.empty());
        assert(f.size_mb > 0);
        assert(f.badge=="green" || f.badge=="amber" || f.badge=="red");
        assert(f.est_tok_s >= 0);
    }
    auto summary = cap.summary();
    assert(!summary.empty());
    // estimate tokens per sec scales with model size
    double small = tessera::estimate_tokens_per_sec(cap, 2ULL*1024*1024*1024);
    double large = tessera::estimate_tokens_per_sec(cap, 10ULL*1024*1024*1024);
    assert(small > large);
    return 0;
}
