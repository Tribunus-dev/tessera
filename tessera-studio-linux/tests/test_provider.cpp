#include "../src/core/provider.h"
#include <cassert>
#include <string>
int main(){
    // Placeholder provider should stream echo and signal done
    auto *p=tessera::make_provider_placeholder();
    bool done=false;
    std::string acc;
    p->send("hi", [&](const std::string &d, bool ddone){ acc+=d; done=ddone; }, [](auto){ assert(false && "should not error"); });
    assert(done);
    assert(acc.find("hi")!=std::string::npos);
    delete p;
    // Cloud provider without key should return hint, not crash
    auto *c = tessera::make_provider_for_cloud("openai", "gpt-4o-mini");
    bool c_done=false;
    c->send("test", [&](const std::string&, bool d){ c_done=d; }, [](auto){});
    assert(c_done);
    delete c;
    // On-device with empty path should fallback to placeholder, not crash
    auto *o = tessera::make_provider_on_device("", 0, 0);
    bool o_done=false;
    o->send("hello", [&](const std::string&, bool d){ o_done=d; }, [](auto){});
    assert(o_done);
    delete o;
    return 0;
}
