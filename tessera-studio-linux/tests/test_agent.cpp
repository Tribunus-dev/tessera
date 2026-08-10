#include "../src/core/agent/Agent.h"
#include "../src/core/provider.h"
#include "../src/core/data/DataLayer.h"
#include <cassert>
#include <string>
int main(){
    // Placeholder provider echo
    auto *p = tessera::make_provider_placeholder();
    tessera::AgentLoop loop(3);
    loop.set_provider(p);
    loop.run_one_turn("hello");
    assert(!loop.last_buffer().empty());
    // run with maxIterations 10 (default) should handle tool deny
    tessera::AgentLoop loop2;
    assert(loop2.maxIterations()==10);
    loop2.set_provider(tessera::make_provider_placeholder());
    loop2.run("please use tool {\"tool\":\"desktop\",\"args\":\"wipe /\"}", 2);
    std::string buf = loop2.last_buffer();
    assert(buf.find("denied")!=std::string::npos || buf.find("needs approval")!=std::string::npos);
    // circuit breaker (internal count >=3)
    tessera::DenialCircuitBreaker brk;
    brk.record(true); brk.record(true); brk.record(true);
    assert(brk.should_break(3)==true);
    assert(brk.should_break(0)==true); // count still 3, any threshold passes
    brk.record(false); // reset
    assert(brk.should_break(3)==false);
    assert(brk.should_break(0)==false);
    // ApprovalEngine
    tessera::ApprovalEngine eng;
    assert(eng.decide({"browser","file://etc/passwd"})==tessera::SafetyDecision::Ask);
    assert(eng.decide({"desktop","rm -rf /"})==tessera::SafetyDecision::Ask);
    assert(eng.decide({"chat","hello"})==tessera::SafetyDecision::Allow);
    delete p;
    return 0;
}
