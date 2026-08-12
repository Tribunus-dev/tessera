import Foundation
import SwiftUI

// MARK: - SheetsViewModel

/// The view-model for the Sheets surface (the Excel/openpyxl-style
/// spreadsheet list + grid). Owns the filtered list, the selection,
/// the search/tag/archived/trash states, the grid editing state
/// (selectedCell, editingCell), and the chat-panel integration.
///
/// `@MainActor` so all `@Published` writes happen on the main
/// thread (SwiftUI's expectation). The data layer facade is an
/// actor; we hop to it for the reads/writes.
///
/// **Loading.** The view calls `refresh()` on appear and after
/// every mutation. The model reads the sheet list from the data
/// layer, applies the filter, and re-projects the rows with the
/// partial index (migration 0011) so the listing stays O(log n).
@MainActor
public final class SheetsViewModel: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var allSheets: [Sheet] = []
    @Published public private(set) var rows: [SheetRow] = []
    @Published public var filter: SheetListFilter = .all
    @Published public var selectedSheetID: UUID?
    @Published public var activeTag: String?
    @Published public var searchText: String = ""
    @Published public var isLoading: Bool = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var isChatDriven: Bool = false

    /// Grid editing state: which cell is selected (row, col) in the
    /// primary table. nil when no sheet is selected or the sheet has
    /// no table.
    @Published public var selectedCell: SheetCellCoord?
    @Published public var editingCell: SheetCellCoord?
    @Published public var editingText: String = ""

    @Published public private(set) var editor: SheetEditorViewModel?

    // MARK: - Dependencies

    public let store: SheetStore
    public let dataLayer: TesseraDataLayer
    public let userID: UserID

    public init(
        store: SheetStore,
        dataLayer: TesseraDataLayer,
        userID: UserID = UUID()
    ) {
        self.store = store
        self.dataLayer = dataLayer
        self.userID = userID
    }

    // MARK: - Lifecycle

    public func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let sheets = try await store.list(limit: 1000)
            allSheets = sheets
            applyFilter()
        } catch {
            loadError = String(describing: error)
        }
        isLoading = false
    }

    public func applyFilter() {
        var filtered = filter.apply(to: allSheets)
        if let tag = activeTag {
            filtered = filtered.filter { $0.tags.contains(tag) }
        }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            filtered = filtered.filter { sheet in
                let hay = "\(sheet.title.lowercased()) \(sheet.tags.joined(separator: " ")) \(sheet.snippet(maxLength: 1000).lowercased())"
                return hay.contains(needle)
            }
        }
        rows = filtered.map { SheetRow(sheet: $0) }
    }

    public func setAllSheetsForTesting(_ sheets: [Sheet]) {
        allSheets = sheets
        applyFilter()
    }

    public func applyLocalSearch(_ needle: String) {
        searchText = needle
        applyFilter()
    }

    public var allTags: [String] {
        var seen: Set<String> = []
        for sheet in allSheets { for tag in sheet.tags { seen.insert(tag) } }
        return seen.sorted()
    }

    // MARK: - Selection

    public func select(_ sheetID: UUID?) {
        selectedSheetID = sheetID
        selectedCell = nil
        editingCell = nil
        if let sheetID, let sheet = allSheets.first(where: { $0.id == sheetID }) {
            editor = SheetEditorViewModel(sheet: sheet, store: store, userID: userID)
        } else {
            editor = nil
        }
    }

    // MARK: - Grid selection

    public func selectCell(_ coord: SheetCellCoord?) {
        selectedCell = coord
    }

    public func beginEditingCell(_ coord: SheetCellCoord) {
        guard let sheet = allSheets.first(where: { $0.id == selectedSheetID }) else { return }
        editingCell = coord
        editingText = sheet.cellText(row: coord.row, col: coord.col)
    }

    public func commitEditingCell() async {
        guard let coord = editingCell,
              let sheetID = selectedSheetID else {
            editingCell = nil
            return
        }
        let text = editingText
        editingCell = nil
        do {
            let updated = try await store.setCell(row: coord.row, col: coord.col, value: text, for: sheetID)
            if let idx = allSheets.firstIndex(where: { $0.id == sheetID }) {
                allSheets[idx] = updated
                applyFilter()
                editor?.refresh(with: updated)
            }
        } catch {
            loadError = String(describing: error)
        }
    }

    public func cancelEditingCell() {
        editingCell = nil
    }

    // MARK: - CRUD

    @discardableResult
    public func createSheet(
        title: String,
        rows: Int = 10,
        cols: Int = 6,
        tags: [String] = []
    ) async throws -> Sheet {
        let now = Date()
        var sheet = Sheet.makeBlank(title: title, rows: rows, cols: cols)
        // Use a fresh id + timestamps so every creation is unique.
        sheet = Sheet(
            id: UUID(),
            title: title,
            body: sheet.body,
            columns: sheet.columns,
            tags: Sheet.normalizeTags(tags),
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.upsert(sheet)
        await refresh()
        return sheet
    }

    @discardableResult
    public func createSheetFromAST(
        title: String,
        body: DocumentAST,
        columns: [SheetColumn] = [],
        tags: [String] = []
    ) async throws -> Sheet {
        let now = Date()
        let sheet = Sheet(
            id: UUID(),
            title: title,
            body: body,
            columns: columns,
            tags: Sheet.normalizeTags(tags),
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.upsert(sheet)
        await refresh()
        return sheet
    }

    public func deleteSelected() async {
        guard let id = selectedSheetID else { return }
        do {
            _ = try await store.delete(id: id)
            selectedSheetID = nil
            editor = nil
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Chat-panel integration

    @discardableResult
    public func chatCreateSheet(
        title: String,
        rows: Int = 10,
        cols: Int = 6,
        tags: [String] = []
    ) async throws -> Sheet {
        isChatDriven = true
        defer { isChatDriven = false }
        return try await createSheet(title: title, rows: rows, cols: cols, tags: tags)
    }

    @discardableResult
    public func chatEditSheet(
        sheetID: UUID,
        apply: (SheetStore) async throws -> Sheet
    ) async throws -> Sheet {
        isChatDriven = true
        defer { isChatDriven = false }
        let updated = try await apply(store)
        await refresh()
        if selectedSheetID == sheetID, let editor {
            editor.refresh(with: updated)
        }
        return updated
    }

    // MARK: - Tag chip

    public func setActiveTag(_ tag: String?) {
        activeTag = tag
        applyFilter()
    }
}

// MARK: - SheetCellCoord

/// A 0-indexed (row, col) coordinate in the sheet's primary table.
public struct SheetCellCoord: Hashable, Sendable, Equatable {
    public let row: Int
    public let col: Int
    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

// MARK: - SheetListFilter

public enum SheetListFilter: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case favorites
    case archived
    case trash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .archived: return "Archived"
        case .trash: return "Trash"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "tablecells"
        case .favorites: return "star.fill"
        case .archived: return "archivebox"
        case .trash: return "trash"
        }
    }

    public func apply(to sheets: [Sheet]) -> [Sheet] {
        switch self {
        case .all:
            return sheets.filter { !$0.isTrashed && !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
        case .favorites:
            return sheets.filter { $0.isFavorite && !$0.isTrashed && !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
        case .archived:
            return sheets.filter { $0.isArchived && !$0.isTrashed }
                .sorted { $0.updatedAt > $1.updatedAt }
        case .trash:
            return sheets.filter { $0.isTrashed }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

// MARK: - SheetRow

public struct SheetRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let snippet: String
    public let tags: [String]
    public let updatedAt: Date
    public let relativeTime: String
    public let isFavorite: Bool
    public let isArchived: Bool
    public let isTrashed: Bool
    public let rowCount: Int
    public let columnCount: Int
    public let cellCount: Int

    public init(sheet: Sheet, now: Date = Date()) {
        self.id = sheet.id
        self.title = sheet.displayTitle
        self.snippet = sheet.snippet(maxLength: 200)
        self.tags = sheet.tags
        self.updatedAt = sheet.updatedAt
        self.relativeTime = SheetRow.relativeTimeString(for: sheet.updatedAt, now: now)
        self.isFavorite = sheet.isFavorite
        self.isArchived = sheet.isArchived
        self.isTrashed = sheet.isTrashed
        self.rowCount = sheet.rowCount
        self.columnCount = sheet.columnCount
        self.cellCount = sheet.cellCount
    }

    public static func relativeTimeString(for date: Date, now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 0 { return "just now" }
        if delta < 60 { return "just now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(delta / 3600)
        if hours < 24 { return "\(hours) hr ago" }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let days = Int(delta / 86400)
        if days < 14 { return "\(days) days ago" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks) weeks ago" }
        let formatter = DateFormatter()
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = isCurrentYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - SheetEditorViewModel

@MainActor
public final class SheetEditorViewModel: ObservableObject {

    @Published public private(set) var sheet: Sheet
    @Published public private(set) var document: DocumentAST
    @Published public var draftTitle: String
    @Published public var draftTag: String
    @Published public var isSaving: Bool = false
    @Published public private(set) var lastError: String?

    /// Grid editing state for the detail view's inline grid.
    @Published public var selectedCell: SheetCellCoord?
    @Published public var editingCell: SheetCellCoord?
    @Published public var editingText: String = ""

    public let store: SheetStore
    public let userID: UserID

    public init(sheet: Sheet, store: SheetStore, userID: UserID) {
        self.sheet = sheet
        self.document = sheet.body
        self.draftTitle = sheet.title
        self.draftTag = ""
        self.store = store
        self.userID = userID
    }

    public func refresh(with sheet: Sheet) {
        self.sheet = sheet
        self.document = sheet.body
        self.draftTitle = sheet.title
    }

    // MARK: - Title

    public func commitTitle() async {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != sheet.title else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var updated = sheet
            updated.title = trimmed
            updated.updatedAt = Date()
            _ = try await store.upsert(updated)
            self.sheet = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Cell

    public func selectCell(_ coord: SheetCellCoord?) {
        selectedCell = coord
    }

    public func beginEditingCell(_ coord: SheetCellCoord) {
        editingCell = coord
        editingText = sheet.cellText(row: coord.row, col: coord.col)
    }

    public func commitEditingCell() async {
        guard let coord = editingCell else { return }
        let text = editingText
        editingCell = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.setCell(row: coord.row, col: coord.col, value: text, for: sheet.id)
            self.sheet = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    public func cancelEditingCell() {
        editingCell = nil
    }

    // MARK: - Keyboard navigation (Excel muscle memory: Tab/Enter/arrows)

    /// Move selection in a direction without committing any in-progress edit.
    public func moveSelection(_ direction: Direction) {
        guard let current = selectedCell ?? editingCell else { return }
        switch direction {
        case .up:
            if current.row > 0 {
                selectedCell = SheetCellCoord(row: current.row - 1, col: current.col)
            }
        case .down:
            if current.row < sheet.rowCount - 1 {
                selectedCell = SheetCellCoord(row: current.row + 1, col: current.col)
            }
        case .left:
            if current.col > 0 {
                selectedCell = SheetCellCoord(row: current.row, col: current.col - 1)
            }
        case .right:
            if current.col < sheet.columnCount - 1 {
                selectedCell = SheetCellCoord(row: current.row, col: current.col + 1)
            }
        }
    }

    /// Commit any in-progress edit and move selection in a direction.
    /// Used for Tab / Shift+Tab / Enter / Shift+Enter.
    /// Returns the new selected cell so the grid can scroll to it.
    @discardableResult
    public func commitAndMove(_ direction: Direction) async -> SheetCellCoord? {
        if editingCell != nil {
            await commitEditingCell()
        }
        moveSelection(direction)
        return selectedCell
    }

    /// F2: toggle between select mode and edit mode on the selected cell.
    public func toggleEditMode() {
        if let coord = selectedCell {
            if editingCell == coord {
                editingCell = nil
            } else {
                beginEditingCell(coord)
            }
        }
    }

    public enum Direction {
        case up, down, left, right
    }

    // MARK: - Rows / Columns

    public func insertRow(at index: Int) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.insertRow(at: index, for: sheet.id)
            self.sheet = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    public func deleteRow(at index: Int) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.deleteRow(at: index, for: sheet.id)
            self.sheet = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    public func insertColumn(at index: Int) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.insertColumn(at: index, for: sheet.id)
            self.sheet = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    public func deleteColumn(at index: Int) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.deleteColumn(at: index, for: sheet.id)
            self.sheet = updated
            self.document = updated.body
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Archive / Trash / Favorite

    public func toggleArchived() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = sheet.isArchived
                ? try await store.unarchive(sheet.id)
                : try await store.archive(sheet.id)
            self.sheet = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func toggleTrashed() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = sheet.isTrashed
                ? try await store.restore(sheet.id)
                : try await store.trash(sheet.id)
            self.sheet = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func toggleFavorite() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = sheet.isFavorite
                ? try await store.unfavorite(sheet.id)
                : try await store.favorite(sheet.id)
            self.sheet = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Tags

    public func addDraftTag() async {
        let normalized = Sheet.normalizeTags([draftTag])
        guard let first = normalized.first else { return }
        guard !sheet.tags.contains(first) else {
            draftTag = ""
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.addTag(first, to: sheet.id)
            self.sheet = updated
            self.draftTag = ""
        } catch {
            lastError = String(describing: error)
        }
    }

    public func removeTag(_ tag: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.removeTag(tag, from: sheet.id)
            self.sheet = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Linking

    public func link(to otherEntityID: UUID, linkType: String = "related_to") async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await store.link(sheetID: sheet.id, to: otherEntityID, linkType: linkType)
            if let fresh = try await store.get(id: sheet.id) {
                self.sheet = fresh
                self.document = fresh.body
            }
        } catch {
            lastError = String(describing: error)
        }
    }
}

// MARK: - SheetGridViewModel

/// Lightweight view-model for the grid itself (column headers, row
/// indices, cell editing). The detail view owns an instance of this;
/// the list view's `SheetsViewModel` owns the cell selection for
/// the global grid state.
@MainActor
public final class SheetGridViewModel: ObservableObject {

    @Published public var sheet: Sheet
    @Published public var selectedCell: SheetCellCoord?
    @Published public var editingCell: SheetCellCoord?
    @Published public var editingText: String = ""

    public init(sheet: Sheet) {
        self.sheet = sheet
    }

    public func updateSheet(_ sheet: Sheet) {
        self.sheet = sheet
        // Clear selection that is now out of bounds.
        if let coord = selectedCell,
           coord.row >= sheet.rowCount || coord.col >= sheet.columnCount {
            selectedCell = nil
        }
        if let coord = editingCell,
           coord.row >= sheet.rowCount || coord.col >= sheet.columnCount {
            editingCell = nil
        }
    }

    public var rowCount: Int { sheet.rowCount }
    public var columnCount: Int { sheet.columnCount }
    public var columnLabels: [String] {
        sheet.columns.enumerated().map { idx, col in
            col.label.isEmpty ? Self.defaultLabel(index: idx) : col.label
        }
    }

    public func selectCell(_ coord: SheetCellCoord?) {
        selectedCell = coord
    }

    public func beginEditing(_ coord: SheetCellCoord) {
        editingCell = coord
        editingText = sheet.cellText(row: coord.row, col: coord.col)
    }

    public func cellText(row: Int, col: Int) -> String {
        sheet.cellText(row: row, col: col)
    }

    private static func defaultLabel(index: Int) -> String {
        var label = ""
        var n = index
        repeat {
            label = String(UnicodeScalar(65 + n % 26)!) + label
            n = n / 26 - 1
        } while n >= 0
        return label
    }
}
