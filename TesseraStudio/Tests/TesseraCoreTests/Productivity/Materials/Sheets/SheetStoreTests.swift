import XCTest
@testable import TesseraCore

/// Unit tests for ``SheetStore`` parts that do not need a live
/// Postgres connection. The end-to-end upsert -> receipt -> fetch
/// flow is exercised by the integration test (env-gated on
/// `TESSERA_DB_INTEGRATION=1`).
final class SheetStoreTests: XCTestCase {

    // MARK: - Receipt types

    func testReceiptTypesAreStable() {
        XCTAssertEqual(SheetReceiptType.upsert.rawValue, "sheet_upsert")
        XCTAssertEqual(SheetReceiptType.updateBody.rawValue, "sheet_body_changed")
        XCTAssertEqual(SheetReceiptType.setCell.rawValue, "sheet_cell_changed")
        XCTAssertEqual(SheetReceiptType.insertRow.rawValue, "sheet_row_inserted")
        XCTAssertEqual(SheetReceiptType.deleteRow.rawValue, "sheet_row_deleted")
        XCTAssertEqual(SheetReceiptType.insertColumn.rawValue, "sheet_column_inserted")
        XCTAssertEqual(SheetReceiptType.deleteColumn.rawValue, "sheet_column_deleted")
        XCTAssertEqual(SheetReceiptType.archive.rawValue, "sheet_archived")
        XCTAssertEqual(SheetReceiptType.unarchive.rawValue, "sheet_unarchived")
        XCTAssertEqual(SheetReceiptType.trash.rawValue, "sheet_trashed")
        XCTAssertEqual(SheetReceiptType.restore.rawValue, "sheet_restored")
        XCTAssertEqual(SheetReceiptType.delete.rawValue, "sheet_delete")
        XCTAssertEqual(SheetReceiptType.favorite.rawValue, "sheet_favorited")
        XCTAssertEqual(SheetReceiptType.unfavorite.rawValue, "sheet_unfavorited")
        XCTAssertEqual(SheetReceiptType.tagChange.rawValue, "sheet_tags_changed")
        XCTAssertEqual(SheetReceiptType.tagAdded.rawValue, "sheet_tag_added")
        XCTAssertEqual(SheetReceiptType.tagRemoved.rawValue, "sheet_tag_removed")
        XCTAssertEqual(SheetReceiptType.link.rawValue, "sheet_link_created")
        XCTAssertEqual(SheetReceiptType.unlink.rawValue, "sheet_link_deleted")
        XCTAssertEqual(SheetReceiptType.import.rawValue, "sheet_imported")
        XCTAssertEqual(SheetReceiptType.setCellFormat.rawValue, "sheet_cell_format_changed")
        XCTAssertEqual(SheetReceiptType.setProtection.rawValue, "sheet_protection_changed")
        XCTAssertEqual(SheetReceiptType.defineNamedRange.rawValue, "sheet_named_range_defined")
        XCTAssertEqual(SheetReceiptType.undefineNamedRange.rawValue, "sheet_named_range_undefined")
        XCTAssertEqual(SheetReceiptType.sorted.rawValue, "sheet_sorted")
        XCTAssertEqual(SheetReceiptType.filterApplied.rawValue, "sheet_filter_applied")
        XCTAssertEqual(SheetReceiptType.filterCleared.rawValue, "sheet_filter_cleared")
    }

    /// `SheetStore.sortRange`/`.applyFilter`/`.clearFilter` append
    /// `outcome.receiptType` straight from `QueryEngine.ReceiptType`
    /// rather than reconstructing a `SheetReceiptType` - these two
    /// vocabularies must never drift apart.
    func testQueryReceiptTypesMatchQueryEngineReceiptTypeConstants() {
        XCTAssertEqual(SheetReceiptType.sorted.rawValue, QueryEngine.ReceiptType.sorted)
        XCTAssertEqual(SheetReceiptType.filterApplied.rawValue, QueryEngine.ReceiptType.filterApplied)
        XCTAssertEqual(SheetReceiptType.filterCleared.rawValue, QueryEngine.ReceiptType.filterCleared)
    }

    // MARK: - Query (sort/filter): Sheet.effectiveFilterState

    func testEffectiveFilterStateDefaultsToEmptyWhenNil() {
        let sheet = Sheet(title: "x", body: .empty)
        XCTAssertNil(sheet.filterState)
        XCTAssertEqual(sheet.effectiveFilterState, .empty)
    }

    func testEffectiveFilterStateReturnsStoredValue() {
        var sheet = Sheet(title: "x", body: .empty)
        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["A"])),
        ]
        let state = SheetFilterState(criteria: criteria, hiddenRows: [2, 4])
        sheet.filterState = state
        XCTAssertEqual(sheet.effectiveFilterState, state)
    }

    // MARK: - Query (sort/filter): fixture-level row permutation

    /// `SheetStore.sortRange` computes `QueryEngine.sort`'s row
    /// `order` then reorders the primary table's cell-ID children in
    /// whole-row slices (row `r`'s cells occupy `[r*cols, r*cols+cols)`).
    /// This pins that exact slicing algorithm - the piece `sortRange`
    /// adds on top of the already-tested `QueryEngine.sortedRowOrder`
    /// (see `QueryEngineTests.swift`) - against a `Sheet.makeBlank`
    /// fixture, independent of persistence: `sortRange` itself needs a
    /// live data layer to exercise end-to-end (see this item's
    /// openQuestions).
    func testRowPermutationAlgorithmReordersFixtureRowsBySortedValue() {
        var sheet = Sheet.makeBlank(title: "Fixture", rows: 3, cols: 1)
        // Column 0, top to bottom: "C", "A", "B".
        sheet = sheet.settingCellText(row: 0, col: 0, "C")
        sheet = sheet.settingCellText(row: 1, col: 0, "A")
        sheet = sheet.settingCellText(row: 2, col: 0, "B")
        sheet = sheet.settingCellValue(row: 0, col: 0, .text("C"))
        sheet = sheet.settingCellValue(row: 1, col: 0, .text("A"))
        sheet = sheet.settingCellValue(row: 2, col: 0, .text("B"))

        let (order, _) = QueryEngine.sort(
            rowCount: 3,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)],
            cellValue: { row, col in sheet.cellValue(row: row, col: col) }
        )
        XCTAssertEqual(order, [1, 2, 0], "A(1) < B(2) < C(0)")

        // The exact algorithm `SheetStore.sortRange` applies to
        // `table.children`: slice each source row's cell IDs out in
        // `order` and concatenate.
        let tableID = sheet.body.rootChildren.first { sheet.body.blocks[$0]?.type == .table }!
        var table = sheet.body.blocks[tableID]!
        let cols = 1
        var reordered: [UUID] = []
        for r in order {
            let start = r * cols
            reordered.append(contentsOf: table.children[start..<(start + cols)])
        }
        table.children = reordered
        sheet.body.blocks[tableID] = table

        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "A")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "B")
        XCTAssertEqual(sheet.cellText(row: 2, col: 0), "C")
    }

    /// The exact closures `SheetStore.applyFilter` wires
    /// `QueryEngine.applyFilter` through - `Sheet.cellValue` /
    /// `.cellText` / `.cellFormat` - against a fixture sheet, pinning
    /// that a simple `.valueSet` criterion hides the right rows once
    /// read off real `Sheet` cell storage (not a hand-built
    /// `SheetFilterRowInput` array, which is all `QueryEngineTests.swift`
    /// exercises).
    func testApplyFilterWiringComputesHiddenRowsFromSheetCells() {
        var sheet = Sheet.makeBlank(title: "Fixture", rows: 3, cols: 1)
        for (row, text) in [(0, "A"), (1, "B"), (2, "A")] {
            sheet = sheet.settingCellText(row: row, col: 0, text)
            sheet = sheet.settingCellValue(row: row, col: 0, .text(text))
        }

        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["A"])),
        ]
        let (state, outcome) = QueryEngine.applyFilter(
            rowCount: 3,
            criteria: criteria,
            value: { row, col in sheet.cellValue(row: row, col: col) },
            displayText: { row, col in sheet.cellText(row: row, col: col) },
            format: { row, col in sheet.cellFormat(row: row, col: col) }
        )

        XCTAssertEqual(state.hiddenRows, [1], "row 1 (\"B\") is the only row not in the value set")
        XCTAssertEqual(state.criteria, criteria)
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.filterApplied.rawValue)
    }

    /// `SheetStore.clearFilter`'s exact assignment - `sheet.filterState
    /// = QueryEngine.clearFilter(previousState:).state` - resets a
    /// non-empty `filterState` back to `.empty`.
    func testClearFilterResetsFilterStateToEmpty() {
        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["A"])),
        ]
        var sheet = Sheet(title: "x", body: .empty)
        sheet.filterState = SheetFilterState(criteria: criteria, hiddenRows: [1, 2])

        let (state, outcome) = QueryEngine.clearFilter(previousState: sheet.effectiveFilterState)
        sheet.filterState = state

        XCTAssertEqual(sheet.effectiveFilterState, .empty)
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.filterCleared.rawValue)
        XCTAssertEqual(outcome.payload["clearedColumnCount"]?.numberValue, 1)
        XCTAssertEqual(outcome.payload["unhiddenRowCount"]?.numberValue, 2)
    }

    // MARK: - Comments

    /// Pins `SheetStore.addComment`'s exact construction (a
    /// `CommentThread` holding the given anchor/author as a single
    /// root `CommentMessage`, unresolved) and that it survives the
    /// same JSON encode/decode round trip `SheetStore.upsert`/`.get`
    /// perform under the hood - the live-DB write needs a data layer
    /// to exercise end-to-end (see this item's openQuestions, same
    /// caveat as `testRowPermutationAlgorithmReordersFixtureRowsBySortedValue`
    /// above), so this pins the persistence shape at the `Sheet` <->
    /// JSON boundary instead.
    func testAddCommentThreadSurvivesJSONRoundTrip() throws {
        var sheet = Sheet.makeBlank(title: "Fixture", rows: 2, cols: 2)
        let anchor = CommentAnchor.cell(sheetID: sheet.id, row: 0, col: 1)
        let thread = CommentThread(
            id: UUID(),
            anchor: anchor,
            author: "author-1",
            createdAt: Date(),
            messages: [CommentMessage(author: "author-1", text: "needs review")],
            isResolved: false
        )
        sheet = sheet.addingCommentThread(thread)
        XCTAssertEqual(sheet.effectiveCommentThreads.map(\.id), [thread.id])

        let body = try sheet.jsonDataString()
        let reloaded = try Sheet.from(jsonDataString: body)

        let reloadedThread = try XCTUnwrap(reloaded.effectiveCommentThreads.first { $0.id == thread.id })
        XCTAssertEqual(reloadedThread.anchor, anchor)
        XCTAssertEqual(reloadedThread.author, "author-1")
        XCTAssertEqual(reloadedThread.messages.map(\.text), ["needs review"])
        XCTAssertFalse(reloadedThread.isResolved)
    }

    /// `addComment` appends to any existing threads rather than
    /// replacing them - `Sheet.addingCommentThread` is additive, not
    /// a setter.
    func testAddCommentThreadIsAdditive() {
        var sheet = Sheet.makeBlank(title: "Fixture", rows: 1, cols: 1)
        let first = CommentThread(
            id: UUID(),
            anchor: .cell(sheetID: sheet.id, row: 0, col: 0),
            author: "author-1",
            createdAt: Date(),
            messages: [CommentMessage(author: "author-1", text: "first")]
        )
        let second = CommentThread(
            id: UUID(),
            anchor: .cell(sheetID: sheet.id, row: 0, col: 0),
            author: "author-2",
            createdAt: Date(),
            messages: [CommentMessage(author: "author-2", text: "second")]
        )
        sheet = sheet.addingCommentThread(first)
        sheet = sheet.addingCommentThread(second)
        XCTAssertEqual(sheet.effectiveCommentThreads.map(\.id), [first.id, second.id])
    }

    // MARK: - JSON helpers

    func testSheetJSONStringRoundTrip() throws {
        let sheet = Sheet(
            id: UUID(),
            title: "Budget 2026",
            body: .empty,
            tags: ["budget"],
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let body = try sheet.jsonDataString()
        XCTAssertTrue(body.contains("Budget 2026"))
        let parsed = try Sheet.from(jsonDataString: body)
        XCTAssertEqual(parsed, sheet)
    }

    func testInvalidJSONRejected() {
        let bad = "not json at all"
        XCTAssertThrowsError(try Sheet.from(jsonDataString: bad))
    }

    func testInvalidUTF8BodyRejected() {
        let empty = ""
        // Empty string is not valid Sheet JSON -> should throw.
        XCTAssertThrowsError(try Sheet.from(jsonDataString: empty))
    }

    // MARK: - Errors

    func testStoreErrorEquality() {
        let id = UUID()
        XCTAssertEqual(SheetStoreError.sheetNotFound(id: id), SheetStoreError.sheetNotFound(id: id))
        XCTAssertNotEqual(SheetStoreError.sheetNotFound(id: id), SheetStoreError.sheetNotFound(id: UUID()))
        XCTAssertEqual(SheetStoreError.invalidBody(reason: "x"), SheetStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(SheetStoreError.invalidBody(reason: "x"), SheetStoreError.invalidBody(reason: "y"))
        XCTAssertEqual(SheetStoreError.cannotDeleteLastRow, SheetStoreError.cannotDeleteLastRow)
        XCTAssertEqual(SheetStoreError.cannotDeleteLastColumn, SheetStoreError.cannotDeleteLastColumn)
        XCTAssertEqual(SheetStoreError.cellNotFound(row: 1, col: 2), SheetStoreError.cellNotFound(row: 1, col: 2))
        XCTAssertNotEqual(SheetStoreError.cellNotFound(row: 1, col: 2), SheetStoreError.cellNotFound(row: 1, col: 3))
        XCTAssertEqual(
            SheetStoreError.sheetProtected(sheetID: id, reason: "locked"),
            SheetStoreError.sheetProtected(sheetID: id, reason: "locked")
        )
        XCTAssertNotEqual(
            SheetStoreError.sheetProtected(sheetID: id, reason: "locked"),
            SheetStoreError.sheetProtected(sheetID: id, reason: nil)
        )
    }

    func testCellOutOfBoundsEquality() {
        XCTAssertEqual(
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 3, cols: 3),
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 3, cols: 3)
        )
        XCTAssertNotEqual(
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 3, cols: 3),
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 4, cols: 3)
        )
    }

    // MARK: - Construction smoke

    func testSheetStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = SheetStore(dataLayer: dataLayer)
        _ = store
    }
}
