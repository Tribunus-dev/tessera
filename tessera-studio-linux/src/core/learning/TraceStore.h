#pragma once
#include <string>
#include <vector>
#include <set>
#include <mutex>

namespace tessera {

struct RuntimeSessionSummary {
    std::string sid;
    int records = 0;
    int accepted = 0;
    int drafted = 0;
    double acceptanceRate() const { return drafted ? (double)accepted / drafted : 0.0; }
};

struct RuntimeCaptureSummary {
    int totalRecords = 0;
    int totalBytes = 0;
    std::vector<RuntimeSessionSummary> sessions;
};

// File-backed trace store under XDG_DATA_HOME/tessera/traces
// Mirrors TesseraTraceStore (spec §8, llama.tessera.spec.v1)
class TraceStore {
public:
    explicit TraceStore(const std::string &dir = defaultDirectory());

    static std::string defaultDirectory();
    std::string directoryPath() const { return dir_; }

    // Append runtime records (each already JSON line with provenance=runtime, sid)
    // Returns stored file path or empty if nothing written
    std::string appendRuntime(const std::vector<std::string> &records, const std::set<std::string> &exemptSids = {});

    std::vector<std::string> traceFiles() const;
    std::vector<std::string> runtimeFiles() const;
    int totalRecords() const;
    int purge(); // files removed
    int purgeTrainingData(); // records removed (purgeable contract)
    int purgeSession(const std::string &sid); // records removed

    // Budget/retention (no-op until threshold, honest)
    int trimRuntimeToBudget(int budgetBytes = 200*1024*1024, const std::set<std::string> &exemptSids = {});
    int trimExpired(int retentionDays, const std::set<std::string> &exemptSids = {});

    RuntimeCaptureSummary runtimeSummary() const;

private:
    std::string dir_;
    mutable std::mutex mu_;
    mutable int cachedCount_ = -1;

    static std::string datedStem(const std::string &prefix);
    static int countRecordsInFile(const std::string &path);
    std::vector<std::string> traceFilesUnlocked() const;
};

} // namespace tessera
