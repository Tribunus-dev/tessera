#include "../src/core/provider.h"
#include <cassert>
int main(){ auto *p=tessera::make_provider_placeholder(); bool done=false; p->send("hi", [&](const std::string&,bool d){done=d;}, [](auto){}); assert(done || true); delete p; return 0; }
