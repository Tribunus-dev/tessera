#include "../src/core/learning/TraceStore.h"
#include <cassert>
#include <filesystem>
#include <string>
#include <vector>
#include <unistd.h>
namespace fs=std::filesystem;
int main(){
    std::string dir="/tmp/tessera-test-traces-" + std::to_string(getpid());
    tessera::TraceStore ts(dir);
    assert(ts.traceFiles().empty());
    assert(ts.totalRecords()==0);
    std::vector<std::string> recs={"{\"provenance\":\"runtime\",\"sid\":\"s1\",\"prompt\":\"hi\"}","{\"provenance\":\"runtime\",\"sid\":\"s1\",\"prompt\":\"hi2\"}"};
    std::string f = ts.appendRuntime(recs, {});
    assert(!f.empty());
    assert(fs::exists(f));
    assert(ts.totalRecords()==2);
    assert(ts.runtimeFiles().size()==1);
    auto sum = ts.runtimeSummary();
    assert(sum.totalRecords==2);
    assert(sum.sessions.size()==1);
    // purge session
    int rm = ts.purgeSession("s1");
    assert(rm==2);
    assert(ts.totalRecords()==0);
    // append again and purge all
    ts.appendRuntime(recs, {});
    assert(ts.totalRecords()==2);
    int purged = ts.purge();
    assert(purged==1);
    assert(ts.totalRecords()==0);
    // budget trim
    ts.appendRuntime(recs, {});
    ts.appendRuntime(recs, {});
    int trimmed = ts.trimRuntimeToBudget(1, {}); // force trim to 1 byte
    assert(trimmed>=1);
    // expired trim none
    int exp = ts.trimExpired(9999, {});
    assert(exp==0);
    // cleanup
    ts.purge();
    fs::remove_all(dir);
    return 0;
}
