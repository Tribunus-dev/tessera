#pragma once
#include "SlideDeck.h"
#include "core/data/DataLayer.h"
namespace tessera {
class SlideStore {
public:
    explicit SlideStore(DataLayer* dl): dl_(dl) {}
    SlideDeck upsert(const SlideDeck& d);
    std::vector<SlideDeck> list(int limit=50);
    SlideDeck* get(const std::string& id);
private:
    void appendReceipt(const std::string& id, SlideReceiptType t, const std::string& p);
    DataLayer* dl_; std::vector<SlideDeck> cache_;
};
} // namespace tessera
