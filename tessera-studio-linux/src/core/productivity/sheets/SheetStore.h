#pragma once
#include "Sheet.h"
#include "core/data/DataLayer.h"
#include <vector>

namespace tessera {
class SheetStore {
public:
    explicit SheetStore(DataLayer* dl): dl_(dl) {}
    Sheet upsert(const Sheet& s);
    bool setCell(const std::string& id, int row, int col, const std::string& value);
    std::vector<Sheet> list(int limit=50);
    Sheet* get(const std::string& id);
private:
    void appendReceipt(const std::string& id, SheetReceiptType t, const std::string& payload);
    DataLayer* dl_; std::vector<Sheet> cache_;
};
} // namespace tessera
