import XCTest
@testable import TesseraCore

// MARK: - SheetStoreImportFromDatabaseLogicShadowTests
//
// Doctrine rule 11 ("every gated test has an ungated shadow ... a
// fixture-level test of the SAME logic path minus the actual database
// write") applied to `SheetStore.importFromDatabase`'s own new grid-growth
// logic, the same way `SheetStoreLogicShadowTests.swift` covers every other
// mutation method - except through `SheetStore.growingTable(rows:cols:in:)`
// directly (an `internal`, not `private`, store method - see its own doc
// comment) rather than a public pure `Sheet` method: this wave's
// file-ownership split (see this track's findings file) leaves `Sheet.swift`
// outside this track's file list, so the shadow test reaches the grid-growth
// logic through the one store-internal seam this track DOES own.
//
// `SheetStore` needs a `TesseraDataLayer` to construct (no protocol seam -
// same "no fake to inject" situation `SheetStoreLogicShadowTests.swift`'s
// own header documents), but `growingTable` never touches `self.dataLayer` -
// it is pure `Sheet` value-type manipulation - so a plain,
// never-`.start()`-ed `TesseraDataLayer()` is a safe, inert placeholder here.
final class SheetStoreImportFromDatabaseLogicShadowTests: DoctrineTestCase {

    private func makeStore() -> SheetStore {
        SheetStore(dataLayer: TesseraDataLayer())
    }

    // MARK: - growingTable: no-op when already big enough

    func testGrowingTableIsANoOpWhenTheGridAlreadyMeetsTheRequestedSize() throws {
        let store = makeStore()
        let sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 3)

        let grown = try store.growingTable(rows: 2, cols: 2, in: sheet)

        XCTAssertEqual(grown.rowCount, 3)
        XCTAssertEqual(grown.columnCount, 3)
        XCTAssertEqual(try grown.jsonData(), try sheet.jsonData(), "a no-op grow must leave the sheet byte-identical")
    }

    // MARK: - growingTable: grows rows only

    func testGrowingTableGrowsRowsOnlyWhenColumnsAlreadyFit() throws {
        let store = makeStore()
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)

        let grown = try store.growingTable(rows: 5, cols: 2, in: sheet)

        XCTAssertEqual(grown.rowCount, 5)
        XCTAssertEqual(grown.columnCount, 2)
    }

    // MARK: - growingTable: grows columns only

    func testGrowingTableGrowsColumnsOnlyWhenRowsAlreadyFit() throws {
        let store = makeStore()
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)

        let grown = try store.growingTable(rows: 2, cols: 6, in: sheet)

        XCTAssertEqual(grown.rowCount, 2)
        XCTAssertEqual(grown.columnCount, 6)
        XCTAssertEqual(grown.columns.count, 6, "the columns array must grow to match the new column count")
    }

    // MARK: - growingTable: existing cell content and identity survive a grow

    func testGrowingTablePreservesExistingCellContentAtItsOriginalCoordinate() throws {
        let store = makeStore()
        var sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        sheet = sheet.settingCellText(row: 1, col: 1, "hello")
        let originalCellID = sheet.tableCellIDs[1 * 2 + 1]

        let grown = try store.growingTable(rows: 4, cols: 4, in: sheet)

        XCTAssertEqual(grown.cellText(row: 1, col: 1), "hello", "existing content must not move or vanish on grow")
        let newDims = (rows: grown.rowCount, cols: grown.columnCount)
        XCTAssertEqual(newDims.rows, 4)
        XCTAssertEqual(newDims.cols, 4)
        // Same physical cell block, not a fresh one at the same coordinate -
        // proves the grow COPIES existing children rather than rebuilding
        // the grid from scratch, so anything keyed by that block id
        // (comment anchors, styles) survives the grow untouched.
        XCTAssertEqual(grown.tableCellIDs[1 * 4 + 1], originalCellID)
    }

    // MARK: - growingTable: new cells are blank

    func testGrowingTableNewlyAddedCellsAreBlank() throws {
        let store = makeStore()
        let sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)

        let grown = try store.growingTable(rows: 3, cols: 3, in: sheet)

        for row in 0..<3 {
            for col in 0..<3 where row != 0 || col != 0 {
                XCTAssertEqual(grown.cellText(row: row, col: col), "", "newly added cell (\(row),\(col)) must start blank")
            }
        }
    }

    // MARK: - growingTable: error path (no table at all)

    func testGrowingTableThrowsNoTableWhenTheSheetHasNoPrimaryTable() throws {
        let store = makeStore()
        let sheet = Sheet(title: "t") // body defaults to .empty - no table block at all

        XCTAssertThrowsError(try store.growingTable(rows: 2, cols: 2, in: sheet)) { error in
            guard case SheetStoreError.noTable = error else {
                XCTFail("expected .noTable, got \(error)")
                return
            }
        }
    }
}
