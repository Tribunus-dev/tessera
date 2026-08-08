import Foundation

// MARK: - SheetReceiptType

/// The set of receipt types ``SheetStore`` emits. The string values
/// are what show up in `graph_receipts.receipt_type`; the enum
/// keeps the call sites self-documenting and makes the receipt
/// vocabulary searchable. Mirrors the ``NoteReceiptType`` /
/// ``DocReceiptType`` taxonomy shapes.
public enum SheetReceiptType: String, Codable, Sendable, CaseIterable {
    /// A sheet was created or fully upserted.
    case upsert = "sheet_upsert"
    /// The sheet's body AST was replaced (bulk grid write).
    case updateBody = "sheet_body_changed"
    /// A single cell value was set.
    case setCell = "sheet_cell_changed"
    /// A row was inserted into the grid.
    case insertRow = "sheet_row_inserted"
    /// A row was deleted from the grid.
    case deleteRow = "sheet_row_deleted"
    /// A column was inserted.
    case insertColumn = "sheet_column_inserted"
    /// A column was deleted.
    case deleteColumn = "sheet_column_deleted"
    /// The sheet was archived.
    case archive = "sheet_archived"
    /// The sheet was unarchived (restored from archive).
    case unarchive = "sheet_unarchived"
    /// The sheet was moved to trash (soft delete).
    case trash = "sheet_trashed"
    /// The sheet was restored from trash.
    case restore = "sheet_restored"
    /// The sheet was hard-deleted.
    case delete = "sheet_delete"
    /// The sheet was marked as favorite.
    case favorite = "sheet_favorited"
    /// The sheet was unmarked as favorite.
    case unfavorite = "sheet_unfavorited"
    /// The sheet's full tag list was set.
    case tagChange = "sheet_tags_changed"
    /// A single tag was added.
    case tagAdded = "sheet_tag_added"
    /// A single tag was removed.
    case tagRemoved = "sheet_tag_removed"
    /// A link to another graph entity was created.
    case link = "sheet_link_created"
    /// A link was removed.
    case unlink = "sheet_link_deleted"
    /// The sheet was imported from an external format
    /// (openpyxl XLSX, CSV).
    case `import` = "sheet_imported"
}
