#pragma once
#include <string>
#include <vector>

namespace tessera {

enum class SheetColumnType { text, number, date, checkbox };
struct SheetColumn { std::string label; double width = 0; SheetColumnType type = SheetColumnType::text; };
struct Sheet {
    static constexpr const char* entityType = "document";
    static constexpr const char* subtype = "sheet";
    std::string id, title, body; // body is DocumentAST table JSON
    std::vector<SheetColumn> columns;
    bool isArchived=false, isTrashed=false, isFavorite=false;
    std::vector<std::string> tags, linkedEntityIDs;
    std::string createdAt, updatedAt;
    std::string displayTitle() const { return title.empty()?"Untitled Sheet":title; }
};
enum class SheetReceiptType { upsert, cell, row, column, archive, trash, favorite, tag, link, import };
inline std::string sheetReceiptTypeString(SheetReceiptType t){
    switch(t){ case SheetReceiptType::upsert: return "sheet_upsert"; case SheetReceiptType::cell: return "sheet_cell"; case SheetReceiptType::row: return "sheet_row"; case SheetReceiptType::column: return "sheet_column"; case SheetReceiptType::archive: return "sheet_archive"; case SheetReceiptType::trash: return "sheet_trash"; case SheetReceiptType::favorite: return "sheet_favorite"; case SheetReceiptType::tag: return "sheet_tag"; case SheetReceiptType::link: return "sheet_link"; case SheetReceiptType::import: return "sheet_import"; } return "sheet_upsert";
}

} // namespace tessera
