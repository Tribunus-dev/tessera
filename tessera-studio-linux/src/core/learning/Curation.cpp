#include "Curation.h"
#include "core/data/DataLayer.h"
#include <filesystem>
#include <fstream>
#include <sstream>
#include <chrono>
#include <iomanip>
#include <set>

namespace fs = std::filesystem;
namespace tessera {

std::string CurationLedger::defaultDir() { return DataLayer::xdg_data_dir(); }
std::string CurationLedger::defaultPath() { return defaultDir() + "/curation-ledger.jsonl"; }

std::string CurationLedger::nowIso() {
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{}; gmtime_r(&t, &tm);
    std::ostringstream oss; oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
    return oss.str();
}

CurationLedger::CurationLedger(const std::string &dir) : dir_(dir.empty()?defaultDir():dir), path_(dir_ + "/curation-ledger.jsonl") {
    fs::create_directories(dir_);
}

void CurationLedger::append(const CurationEntry &e) {
    std::lock_guard<std::mutex> lk(mu_);
    std::ofstream f(path_, std::ios::app);
    if (!f) return;
    f << "{\"schema\":\"llama.tessera.curation.v1\",\"sid\":\"" << e.sid << "\",\"verdict\":\"" << e.verdict
      << "\",\"reason\":\"" << e.reason << "\",\"acceptance\":" << e.acceptance
      << ",\"tokens\":" << e.tokens << ",\"ts\":\"" << nowIso() << "\"}\n";
}

std::vector<CurationEntry> CurationLedger::entries() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::vector<CurationEntry> out;
    std::ifstream f(path_);
    if (!f) return out;
    std::string line;
    while (std::getline(f,line)) {
        if (line.empty() || line.find("llama.tessera.curation.v1")==std::string::npos) continue;
        auto get = [&](const char* key)->std::string{
            std::string k="\""; k+=key; k+="\":\"";
            auto p=line.find(k); if(p==std::string::npos) return "";
            p+=k.size(); auto q=line.find("\"",p); if(q==std::string::npos) return ""; return line.substr(p,q-p);
        };
        CurationEntry e;
        e.sid = get("sid");
        e.verdict = get("verdict");
        e.reason = get("reason");
        // acceptance/tokens parsing omitted for brevity
        if (!e.sid.empty()) out.push_back(e);
    }
    return out;
}

std::vector<CurationEntry> CurationLedger::quarantined() const {
    auto all = entries();
    std::vector<CurationEntry> q;
    for (auto &e: all) if (e.verdict=="quarantined") q.push_back(e);
    return q;
}
std::set<std::string> CurationLedger::quarantinedSids() const {
    std::set<std::string> s;
    for (auto &e: quarantined()) s.insert(e.sid);
    return s;
}
void CurationLedger::markPurged(const std::string &sid) {
    if (sid.empty()) return;
    append({sid, "purged", "user-purge", 0, 0});
}

} // namespace tessera
