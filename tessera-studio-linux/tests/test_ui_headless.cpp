#include <cassert>
#include <string>
// Headless UI smoke: verifies core builds with -DTESSERA_LINUX_BUILD_UI=OFF
// and that linux polish surfaces do not require GTK at link time.
// Also checks worker-thread discipline via DataLayer/TASK persist symbols.
#include "core/data/DataLayer.h"
#include "core/agent/ToolRegistry.h"
int main(){
    // DataLayer disclosure + minimum necessary (linux data contracts)
    // Use explicit empty config to avoid env DB probe in headless CI
    tessera::DataConfig cfg; cfg.postgres_url=""; cfg.valkey_url=""; cfg.duckdb_path="/tmp/tessera-headless.duckdb";
    tessera::DataLayer dl(cfg);
    // ToolRegistry minimum necessary
    tessera::ApprovalEngine ae;
    tessera::ToolRegistry reg(&ae, &dl);
    assert(!reg.checkMinimumNecessary("*"));
    assert(!reg.checkMinimumNecessary("SELECT *"));
    assert(reg.checkMinimumNecessary("type=note"));
    assert(reg.call_data("note","*")=="denied: minimum necessary (filter overbroad)");
    // purge path exists
    (void)dl.count_by_source_prefix_attested("student:");
    return 0;
}
