# Tessera Productivity — Sheets Material Surface

> B2 of the 3-material B wave (Docs / Sheets / Slides). Sheets is the
> openpyxl/CSV-style spreadsheet surface — `entity_type='document'`
> `subtype='sheet'` — stored as a `Sheet` JSON blob in
> `graph_entities.body`. The sheet's grid IS the Block AST table
> blocks (spec §4.1): a sheet is a document whose AST is mostly
> `table` blocks. Companion to the productivity design spec §4
> (Block AST table/tableCell), §5 (Mutation), §9 (Editor),
> §10 (Import/Export), §12.1/12.12 (Materials).

---

## 1. Entity model

```swift
struct Sheet: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var body: DocumentAST          // spec §4 — the table block tree
    var columns: [SheetColumn]     // spreadsheet-level column semantics
    var isArchived: Bool
    var isTrashed: Bool            // soft delete; hard delete removes the row
    var isFavorite: Bool
    var tags: [String]             // normalized lowercase, deduped
    var linkedEntityIDs: [UUID]    // denormalized cache of entity_links
    var createdAt: Date
    var updatedAt: Date

    static let entityType = "document"
    static let subtype    = "sheet"
}

struct SheetColumn: Codable, Sendable, Hashable {
    var label: String              // column header (A, B, ..., or user label)
    var width: Double?             // optional pixel hint
    var type: SheetColumnType      // text | number | date | checkbox
}
enum SheetColumnType: String, Codable, Sendable, Hashable, CaseIterable {
    case text, number, date, checkbox
}
```

* Helpers mirror `Note`/`Doc`: `displayTitle` (explicit title → first
  heading → "Untitled"), `snippet(maxLength:)`, `plainText(of:)`,
  `wordCount`, `normalizeTags`, `firstHeadingText`.
* Grid helpers: `rowCount` / `columnCount` / `cellCount` derived from
  the primary table block's `attributes["rows"]` / `attributes["cols"]`
  plus the `columns` array. `cellText(row:col:)` and `tableCellIDs`
  expose the row-major cell list. `Sheet.makeBlank(title:rows:cols:)`
  builds a blank sheet with empty `tableCell` blocks and labeled
  columns (A, B, ...).
* `jsonData()` / `from(jsonData:)` use sorted keys + ISO-8601 for
  deterministic bytes; `jsonDataString()` / `from(jsonDataString:)`
  bridge to the data layer's `String` body.

## 2. Storage

One `graph_entities` row per sheet:

```
entity_type = 'document', subtype = 'sheet', label = displayTitle,
body = Sheet JSON
```

Migration `0011_sheets.sql` — three partial indexes, all
`IF NOT EXISTS`, narrow `WHERE entity_type='document' AND subtype='sheet'`:

* `idx_entities_sheet_updated` on `(entity_type, updated_at DESC)` — the All list.
* `idx_entities_sheet_favorite` with `AND (body->>'isFavorite')='true'` — Favorites.
* `idx_entities_sheet_archived` with `AND (body->>'isArchived')='true'` — Archived.

`0010` is Docs, `0012` is reserved for Slides — verify before choosing
a number. Follows the 0007 conventions (IF NOT EXISTS, no transaction
wrapper, idempotent re-apply).

## 3. Mutations + receipt taxonomy

Every mutation goes through `TesseraDataLayer` only — no raw SQL outside
the migration. Each emits a signed receipt (`SheetReceiptType`):

| Case | Receipt | Trigger |
|------|---------|---------|
| `upsert` | `sheet_upsert` | create / full replace |
| `updateBody` | `sheet_body_changed` | replace `DocumentAST` (bulk grid write) |
| `setCell` | `sheet_cell_changed` | single cell edit |
| `insertRow` / `deleteRow` | `sheet_row_inserted` / `sheet_row_deleted` | row mutations |
| `insertColumn` / `deleteColumn` | `sheet_column_inserted` / `sheet_column_deleted` | column mutations |
| `archive` / `unarchive` | `sheet_archived` / `sheet_unarchived` | archive toggle |
| `trash` / `restore` | `sheet_trashed` / `sheet_restored` | soft delete |
| `delete` | `sheet_delete` | hard delete |
| `favorite` / `unfavorite` | `sheet_favorited` / `sheet_unfavorited` | star |
| `tagChange` / `tagAdded` / `tagRemoved` | `sheet_tags_changed` / `sheet_tag_added` / `sheet_tag_removed` | tags |
| `link` / `unlink` | `sheet_link_created` / `sheet_link_deleted` | graph edges |
| `import` | `sheet_imported` | importer path (openpyxl / CSV) |

`SheetStore` wraps the data layer (struct, no mutable state). `list(...)`
filters by `subtype='sheet'` in memory because the data layer's
`listByEntityType` filters on `entity_type` only — the subtype split
is the same pattern as `NoteStore`/`DocStore`.

**Grid mutations** (`setCell`, `insertRow`, `deleteRow`,
`insertColumn`, `deleteColumn`) operate on the primary table block
(the first `table` in `rootChildren`). Rows/cols are 0-indexed;
deleting the last row or column is refused with a typed error.

## 4. Import / export

| Direction | Formats | Notes |
|-----------|---------|-------|
| Import | XLSX via `openpyxl` | Cell values + formulas as text + basic formatting; each sheet tab becomes one `Sheet` row (or one table block per tab). |
| Import | CSV | One file = one `Sheet`; header row becomes column labels. |
| Export | XLSX via `openpyxl` | Serialize the `Sheet`'s table blocks to a workbook; column labels + widths + types are preserved. |
| Export | CSV | First table only; column headers from `SheetColumn.label`. |

The import is one CLI invocation per file (`tools/tessera/import_sheet.py`
in a follow-up worker), emitting one `graph_entity` + one
`sheet_imported` receipt per sheet tab.

**Punted:** formulas (stored as text, not re-evaluated), conditional
formatting, cell merges, charts, pivot tables, real-time collaborative
editing. Formulas as live evaluation and conditional formatting are v2;
the sheet is a static grid in v1.

## 5. View layer

**macOS** (`TesseraStudioMac/Views/Sheets/`):
* `SheetsListView` — `NavigationSplitView` with three columns: sidebar
  (All / Favorites / Archived / Trash + tag chips), middle (sheet rows),
  detail (`SheetDetailView`). Searchable; "New Sheet" creates a blank
  10x6 grid and selects it.
* `SheetDetailView` — title field + metadata row (rows x cols, cell
  count, updated at) + tag bar + action row (favorite / archive / trash
  / Link…) + grid + linked entities.
* `SheetGridView` — column headers (A, B, … or custom labels) + row
  indices + cell editors (single tap selects, double tap edits, TextField
  on commit calls `SheetStore.setCell`). Row/column add/remove via the
  header affordances and per-row menu. Uses `Grid` so column widths
  track. No new editor engine — table blocks are rendered inline.

**iOS** (`TessercaStudioiOS/Views/Sheets/`):
* `SheetsListView_iOS` — `NavigationStack` + segmented filter tabs +
  searchable list; `.navigationDestination` pushes the detail.
* `SheetDetailView_iOS` — title + metadata + tag bar + action row +
  horizontally-scrollable grid + linked entities. Delete via
  `.confirmationDialog`.

## 6. View-models

* `SheetsViewModel` (`@MainActor ObservableObject`) — published
  `allSheets`, `rows: [SheetRow]`, `filter: SheetListFilter`,
  `selectedSheetID`, `activeTag`, `searchText`, `isLoading`,
  `loadError`, `isChatDriven`, plus grid editing state
  (`selectedCell: SheetCellCoord?`, `editingCell`, `editingText`).
  Filter + local search are in-memory (v1), pushed to
  `hybrid_search` in v2.
* `SheetEditorViewModel` — the detail editor: title + grid editing +
  row/column mutations + archive/trash/favorite + tags + linking.
* `SheetGridViewModel` — lightweight grid state (column headers, row
  count, cell text, selection) owned by the detail view.
* `SheetListFilter` — `all` / `favorites` / `archived` / `trash`,
  with `displayName`, `systemImage`, and `apply(to:)`.
* `SheetRow` — flattened row with `relativeTime` (same ladder as
  `NoteRow`/`DocRow`: just now, N min ago, N hr ago, yesterday,
  N days ago, N weeks ago, formatted date).

## 7. Tests

At least 6 XCTest files under `Tests/TesseraCoreTests/Productivity/Materials/Sheets/`:
`SheetTests`, `SheetStoreTests`, `SheetsViewModelTests`,
`SheetGridViewModelTests`, `SheetReceiptTypeTests`,
`SheetMigrationTests`. All pass with `swift test` from
`TesseraStudio/`.

## 8. Punted (v1)

* **Formulas** — cell values are plain text; formula evaluation is v2.
* **Conditional formatting** — v2.
* **Cell merges** — v2.
* **Charts / pivot tables** — v2.
* **Real-time collaborative editing** — v2.
* **Per-sheet `hybrid_search`** — v1 is in-memory title + body + tag filter.
* **Live-update relative time** (`TimelineView`) — v2.
