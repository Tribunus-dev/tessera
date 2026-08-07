import XCTest
@testable import TesseraCore

@MainActor
final class SheetGridViewModelTests: XCTestCase {

    private func blank(rows: Int, cols: Int) -> Sheet {
        Sheet.makeBlank(title: "T", rows: rows, cols: cols)
    }

    func testInitialGridDimensions() {
        let sheet = blank(rows: 3, cols: 4)
        let vm = SheetGridViewModel(sheet: sheet)
        XCTAssertEqual(vm.rowCount, 3)
        XCTAssertEqual(vm.columnCount, 4)
        XCTAssertNil(vm.selectedCell)
        XCTAssertNil(vm.editingCell)
    }

    func testCellTextViaGridViewModel() {
        let sheet = blank(rows: 2, cols: 2)
        let vm = SheetGridViewModel(sheet: sheet)
        XCTAssertEqual(vm.cellText(row: 0, col: 0), "")
        XCTAssertEqual(vm.cellText(row: 5, col: 5), "")
    }

    func testSelectAndBeginEditing() {
        let sheet = blank(rows: 2, cols: 2)
        let vm = SheetGridViewModel(sheet: sheet)
        let coord = SheetCellCoord(row: 0, col: 1)
        vm.selectCell(coord)
        XCTAssertEqual(vm.selectedCell, coord)
        vm.beginEditing(coord)
        XCTAssertEqual(vm.editingCell, coord)
        XCTAssertEqual(vm.editingText, "")
    }

    func testUpdateSheetClearsOutOfBoundsEditingState() {
        let big = blank(rows: 4, cols: 4)
        let small = blank(rows: 2, cols: 2)
        let vm = SheetGridViewModel(sheet: big)
        vm.selectCell(SheetCellCoord(row: 3, col: 3))
        vm.beginEditing(SheetCellCoord(row: 3, col: 3))
        vm.updateSheet(small)
        XCTAssertNil(vm.selectedCell)
        XCTAssertNil(vm.editingCell)
        XCTAssertEqual(vm.sheet.rowCount, 2)
    }

    func testUpdateSheetPreservesInBoundsSelection() {
        let big = blank(rows: 4, cols: 4)
        let vm = SheetGridViewModel(sheet: big)
        let coord = SheetCellCoord(row: 1, col: 1)
        vm.selectCell(coord)
        vm.updateSheet(big)
        XCTAssertEqual(vm.selectedCell, coord)
    }

    func testCellCoordEqualityAndHashing() {
        let a = SheetCellCoord(row: 1, col: 2)
        let b = SheetCellCoord(row: 1, col: 2)
        let c = SheetCellCoord(row: 2, col: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testSheetColumnCountFallsBackToTable() {
        let sheet = blank(rows: 2, cols: 6)
        let vm = SheetGridViewModel(sheet: sheet)
        XCTAssertEqual(vm.columnCount, 6)
    }

    func testEditorViewModelCellLifecycle() {
        let sheet = blank(rows: 2, cols: 2)
        let store = SheetStore(dataLayer: TesseraDataLayer())
        let vm = SheetEditorViewModel(sheet: sheet, store: store, userID: UUID())
        let coord = SheetCellCoord(row: 0, col: 0)
        vm.selectCell(coord)
        XCTAssertEqual(vm.selectedCell, coord)
        vm.beginEditingCell(coord)
        XCTAssertEqual(vm.editingCell, coord)
        vm.cancelEditingCell()
        XCTAssertNil(vm.editingCell)
    }

    func testEditorViewModelRefreshReplacesDocument() {
        let sheet = blank(rows: 2, cols: 2)
        let store = SheetStore(dataLayer: TesseraDataLayer())
        let vm = SheetEditorViewModel(sheet: sheet, store: store, userID: UUID())
        let updated = Sheet.makeBlank(title: "Updated", rows: 5, cols: 5)
        vm.refresh(with: updated)
        XCTAssertEqual(vm.sheet.title, "Updated")
        XCTAssertEqual(vm.document.blocks.count, updated.body.blocks.count)
        XCTAssertEqual(vm.draftTitle, "Updated")
    }

    func testSheetListFilterApplyAllSorted() {
        let a = Sheet(title: "A", body: .empty, updatedAt: Date(timeIntervalSince1970: 1_000))
        let b = Sheet(title: "B", body: .empty, updatedAt: Date(timeIntervalSince1970: 3_000))
        let c = Sheet(title: "C", body: .empty, updatedAt: Date(timeIntervalSince1970: 2_000))
        let filtered = SheetListFilter.all.apply(to: [a, b, c])
        XCTAssertEqual(filtered.map { $0.title }, ["B", "C", "A"])
    }

    func testSheetRowRelativeTime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sheet = Sheet(title: "T", body: .empty, updatedAt: Date(timeIntervalSince1970: 9_950))
        let row = SheetRow(sheet: sheet, now: now)
        XCTAssertEqual(row.relativeTime, "just now")
        XCTAssertEqual(row.title, "T")
    }
}
