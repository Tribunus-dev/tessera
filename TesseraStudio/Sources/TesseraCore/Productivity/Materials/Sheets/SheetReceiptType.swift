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
    /// A single cell's presentation (number format, fill, borders) was
    /// set. Distinct from ``setCell`` because it changes nothing a
    /// formula can see: an auditor reading the chain needs to tell a
    /// restyle from a data edit.
    case setCellFormat = "sheet_cell_format_changed"
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
    /// The sheet was locked or unlocked against further cell/format
    /// mutations.
    case setProtection = "sheet_protection_changed"
    /// A named range was defined.
    case defineNamedRange = "sheet_named_range_defined"
    /// A named range was removed.
    case undefineNamedRange = "sheet_named_range_undefined"
    /// A comment thread was added, anchored to a cell (P1 1.22).
    case addComment = "sheet_comment_added"
    /// A reply was appended to an existing comment thread (P2-0).
    case commentReplied = "sheet_comment_replied"
    /// A comment thread was marked resolved (P2-0).
    case commentResolved = "sheet_comment_resolved"
    /// A comment thread was deleted (P2-0).
    case commentDeleted = "sheet_comment_deleted"
    /// A multi-key sort was applied (QueryEngine.sort). Matches
    /// QueryEngine.ReceiptType.sorted verbatim - keep in sync.
    case sorted = "sheet_sorted"
    /// Autofilter criteria were applied (QueryEngine.applyFilter).
    /// Matches QueryEngine.ReceiptType.filterApplied verbatim.
    case filterApplied = "sheet_filter_applied"
    /// Autofilter criteria were cleared (QueryEngine.clearFilter).
    /// Matches QueryEngine.ReceiptType.filterCleared verbatim.
    case filterCleared = "sheet_filter_cleared"
    /// A pivot table definition was created or replaced (P2-A 2.2a).
    case definePivot = "sheet_pivot_defined"
    /// A pivot table's output grid was recomputed and rewritten
    /// (P2-A 2.2a). Identical-grid refresh is a no-op - zero receipts.
    case updatePivot = "sheet_pivot_updated"
    /// A pivot table definition was removed (P2-A 2.2a).
    case removePivot = "sheet_pivot_removed"
    /// A pivot table was explicitly refreshed on demand, distinct from
    /// the implicit recompute `updatePivot` covers (P2-A 2.2a).
    case refreshPivot = "sheet_pivot_refreshed"
    /// SUBTOTAL rows were inserted for a range per a
    /// `SubtotalDescriptor` (P2-A 2.7).
    case applySubtotals = "sheet_subtotals_applied"
    /// A previously-applied subtotal structure was removed, restoring
    /// the range's original contentHash (P2-A 2.7).
    case removeSubtotals = "sheet_subtotals_removed"
    /// An outline group's collapsed/expanded state was toggled - a
    /// hidden-row mutation, not a structural change (P2-A 2.7).
    case toggleOutline = "sheet_outline_toggled"
    /// A goal-seek solve was applied, writing the resolved variable
    /// value (P2-A 2.6).
    case applyGoalSeek = "sheet_goal_seek_applied"
    /// A solver run was applied, writing the resolved variable values
    /// for a feasible model (P2-A 2.6).
    case applySolverRun = "sheet_solver_applied"
    /// A SELECT query result was materialized into a sheet range via
    /// the local database connector (P2-D 2.16, db_import_range).
    /// Payload carries source-file path + content hash + SQL text +
    /// row count - db_query itself (before materialization) never
    /// emits a receipt, per the "no receipt without a mutation" rule.
    case importFromDatabase = "sheet_database_import"
}
