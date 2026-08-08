#pragma once
#include <string>
#include <vector>
#include <set>
#include <mutex>

namespace tessera {

// Device-local curation verdict ledger under XDG_DATA_HOME/tessera/curation-ledger.jsonl
// Spec §12.4, schema llama.tessera.curation.v1 — append-only, latest-wins
struct CurationEntry {
    std::string sid;
    std::string verdict; // promoted | quarantined | dropped | purged
    std::string reason;
    double acceptance = 0;
    int tokens = 0;
};

class CurationLedger {
public:
    explicit CurationLedger(const std::string &dir = defaultDir());
    static std::string defaultDir();
    static std::string defaultPath();

    void append(const CurationEntry &e);
    std::vector<CurationEntry> entries() const;
    std::vector<CurationEntry> quarantined() const;
    std::set<std::string> quarantinedSids() const;
    void markPurged(const std::string &sid);

private:
    std::string dir_;
    std::string path_;
    mutable std::mutex mu_;
    static std::string nowIso();
};

} // namespace tessera
