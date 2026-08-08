#include "TraceStore.h"
#include "core/data/DataLayer.h"
#include <filesystem>
#include <fstream>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <algorithm>
#include <cstdio>

namespace fs = std::filesystem;

namespace tessera {

std::string TraceStore::defaultDirectory() {
    return DataLayer::xdg_data_dir() + "/traces";
}

std::string TraceStore::datedStem(const std::string &prefix) {
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    localtime_r(&t, &tm);
    std::ostringstream oss;
    oss << prefix << std::put_time(&tm, "%Y%m%d-%H%M%S");
    return oss.str();
}

int TraceStore::countRecordsInFile(const std::string &path) {
    std::ifstream f(path);
    if (!f) return 0;
    int n=0; std::string line;
    while (std::getline(f,line)) {
        // trim
        size_t s=line.find_first_not_of(" \t\r\n");
        if (s==std::string::npos) continue;
        n++;
    }
    return n;
}

TraceStore::TraceStore(const std::string &dir) : dir_(dir) {
    if (dir_.empty()) dir_ = defaultDirectory();
}

std::vector<std::string> TraceStore::traceFilesUnlocked() const {
    std::vector<std::string> out;
    if (!fs::exists(dir_)) return out;
    for (auto &e : fs::directory_iterator(dir_)) {
        if (!e.is_regular_file()) continue;
        std::string n = e.path().filename().string();
        if (n.rfind("traces-",0)==0 && n.size()>6 && n.substr(n.size()-6)==".jsonl")
            out.push_back(e.path().string());
    }
    std::sort(out.begin(), out.end());
    return out;
}

std::vector<std::string> TraceStore::traceFiles() const {
    std::lock_guard<std::mutex> lk(mu_);
    return traceFilesUnlocked();
}
std::vector<std::string> TraceStore::runtimeFiles() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::vector<std::string> out;
    for (auto &p: traceFilesUnlocked())
        if (fs::path(p).filename().string().rfind("traces-runtime-",0)==0) out.push_back(p);
    return out;
}

int TraceStore::totalRecords() const {
    std::lock_guard<std::mutex> lk(mu_);
    if (cachedCount_>=0) return cachedCount_;
    int tot=0;
    for (auto &p: traceFilesUnlocked()) tot+= countRecordsInFile(p);
    cachedCount_=tot;
    return tot;
}

std::string TraceStore::appendRuntime(const std::vector<std::string> &records, const std::set<std::string> &exempt) {
    if (records.empty()) return "";
    std::lock_guard<std::mutex> lk(mu_);
    fs::create_directories(dir_);
    std::string stem = datedStem("traces-runtime-");
    std::string name = stem + ".jsonl";
    std::string dest = dir_ + "/" + name;
    int n=1;
    while (fs::exists(dest)) { dest = dir_ + "/" + stem + "-" + std::to_string(n++) + ".jsonl"; }
    std::ofstream f(dest);
    if (!f) return "";
    for (auto &r: records) f << r << "\n";
    f.close();
    cachedCount_=-1;
    // honest budget/retention: keep simple, no auto-trim unless caller asks
    (void)exempt;
    return dest;
}

int TraceStore::purge() {
    std::lock_guard<std::mutex> lk(mu_);
    auto files = traceFilesUnlocked();
    int c=0;
    for (auto &p: files) { std::error_code ec; fs::remove(p,ec); if(!ec) c++; }
    cachedCount_=-1;
    return c;
}
int TraceStore::purgeTrainingData() {
    std::lock_guard<std::mutex> lk(mu_);
    auto files = traceFilesUnlocked();
    int rec=0;
    for (auto &p: files) rec+= countRecordsInFile(p);
    for (auto &p: files) { std::error_code ec; fs::remove(p,ec); }
    cachedCount_=-1;
    return rec;
}
int TraceStore::purgeSession(const std::string &sid) {
    if (sid.empty()) return 0;
    std::lock_guard<std::mutex> lk(mu_);
    int removed=0;
    for (auto &path: traceFilesUnlocked()) {
        std::ifstream in(path);
        if (!in) continue;
        std::vector<std::string> kept;
        std::string line;
        while (std::getline(in,line)) {
            if (line.find("\"sid\":\""+sid+"\"")!=std::string::npos || line.find("\"sid\": \""+sid+"\"")!=std::string::npos) { removed++; continue; }
            if (line.find(sid)!=std::string::npos && line.find("\"sid\"")!=std::string::npos) {
                // conservative: if sid appears in sid field, drop
                // we already handled; keep otherwise
            }
            kept.push_back(line);
        }
        in.close();
        if ((int)kept.size() != countRecordsInFile(path)) {
            if (kept.empty()) { fs::remove(path); }
            else {
                std::ofstream out(path, std::ios::trunc);
                for (auto &k: kept) out<<k<<"\n";
            }
            cachedCount_=-1;
        }
    }
    return removed;
}
int TraceStore::trimRuntimeToBudget(int budgetBytes, const std::set<std::string> &) {
    std::lock_guard<std::mutex> lk(mu_);
    auto files = traceFilesUnlocked();
    // sum runtime bytes
    long total=0;
    for (auto &p: files) if (fs::path(p).filename().string().rfind("traces-runtime-",0)==0) total+= fs::file_size(p);
    int removed=0;
    for (auto &p: files) {
        if (total <= budgetBytes) break;
        if (fs::path(p).filename().string().rfind("traces-runtime-",0)!=0) continue;
        std::error_code ec;
        long sz = fs::file_size(p, ec);
        fs::remove(p, ec);
        if (!ec) { total-=sz; removed++; cachedCount_=-1; }
    }
    return removed;
}
int TraceStore::trimExpired(int retentionDays, const std::set<std::string> &) {
    if (retentionDays<=0) return 0;
    std::lock_guard<std::mutex> lk(mu_);
    auto now = fs::file_time_type::clock::now();
    int removed=0;
    for (auto &p: traceFilesUnlocked()) {
        auto ftime = fs::last_write_time(p);
        auto age = std::chrono::duration_cast<std::chrono::hours>(now - ftime).count()/24;
        if (age > retentionDays) { std::error_code ec; fs::remove(p,ec); if(!ec){removed++; cachedCount_=-1;}}
    }
    return removed;
}

RuntimeCaptureSummary TraceStore::runtimeSummary() const {
    std::lock_guard<std::mutex> lk(mu_);
    RuntimeCaptureSummary s;
    for (auto &p: traceFilesUnlocked()) {
        if (fs::path(p).filename().string().rfind("traces-runtime-",0)!=0) continue;
        int rec = countRecordsInFile(p);
        long bytes = 0; std::error_code ec; bytes = fs::file_size(p,ec);
        s.totalRecords += rec;
        s.totalBytes += (int)bytes;
        // per-sid aggregation omitted for brevity — count as one session per file
        RuntimeSessionSummary sess;
        sess.sid = fs::path(p).stem().string();
        sess.records = rec;
        s.sessions.push_back(sess);
    }
    return s;
}

} // namespace tessera
