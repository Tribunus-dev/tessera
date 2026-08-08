#pragma once
#include "Doc.h"
#include "core/data/DataLayer.h"
#include <string>
#include <vector>

namespace tessera {

// DocStore: seam to DataLayer, enforces receipt invariant. Mirrors DocStore.swift.
class DocStore {
public:
    explicit DocStore(DataLayer* dl) : dl_(dl) {}

    Doc upsert(const Doc& doc);
    bool trash(const std::string& id, bool trashed);
    bool archive(const std::string& id, bool archived);
    bool favorite(const std::string& id, bool fav);
    bool setTags(const std::string& id, const std::vector<std::string>& tags);
    bool link(const std::string& id, const std::string& targetId);
    std::vector<Doc> list(int limit = 50);
    Doc* get(const std::string& id);

private:
    void appendReceipt(const std::string& entityId, DocReceiptType type, const std::string& payloadJson);
    DataLayer* dl_;
    std::vector<Doc> cache_;
};

} // namespace tessera
