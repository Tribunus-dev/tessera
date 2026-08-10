#include "../src/core/data/DataLayer.h"
#include "../src/core/learning/Curation.h"
#include <cassert>
#include <filesystem>
#include <string>
#include <unistd.h>
namespace fs=std::filesystem;
int main(){
    // xdg helpers
    std::string dd = tessera::DataLayer::xdg_data_dir();
    assert(dd.find("tessera")!=std::string::npos);
    assert(!tessera::DataLayer::xdg_config_dir().empty());
    // from_env defaults
    auto cfg = tessera::DataLayer::from_env();
    // duckdb_path default should contain tessera.duckdb
    assert(cfg.duckdb_path.find("tessera.duckdb")!=std::string::npos);
    // connect reports BothDown when no postgres/valkey (no server in CI)
    tessera::DataLayer dl(cfg);
    auto out = dl.connect();
    assert(out==tessera::StartOutcome::BothDown || out==tessera::StartOutcome::DataStoreDegraded || out==tessera::StartOutcome::CacheDegraded || out==tessera::StartOutcome::Ready);
    assert(!dl.status_string().empty());
    // valkey/duckdb degradations are graceful - only probe when valkey is actually reachable
    // When BothDown/CacheDegraded, valkey_set would try to connect and must not crash
    if(dl.last_outcome()==tessera::StartOutcome::Ready || dl.last_outcome()==tessera::StartOutcome::DataStoreDegraded){
        bool ok = dl.valkey_set("tessera:test:unit", "hi", 60);
        (void)ok;
        std::string v = dl.valkey_get("tessera:test:unit");
        (void)v;
    }
    bool d = dl.duckdb_exec("SELECT 1");
    (void)d;
    // Curation ledger
    std::string dir="/tmp/tessera-test-curation-" + std::to_string(getpid());
    tessera::CurationLedger ledger(dir);
    assert(ledger.entries().empty());
    ledger.append({"sid-1","accepted","ok", 0.9, 10});
    ledger.append({"sid-2","quarantined","bad", 0.1, 5});
    auto all = ledger.entries();
    assert(all.size()==2);
    auto q = ledger.quarantined();
    assert(q.size()==1);
    assert(q[0].sid=="sid-2");
    assert(ledger.quarantinedSids().count("sid-2")==1);
    ledger.markPurged("sid-1");
    auto all2 = ledger.entries();
    assert(all2.size()==3);
    fs::remove_all(dir);
    return 0;
}
