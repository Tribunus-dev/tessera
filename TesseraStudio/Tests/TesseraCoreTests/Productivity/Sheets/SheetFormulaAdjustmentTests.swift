import XCTest
@testable import TesseraCore

/// Grid-level formula adjustment: the pass `SheetStore` runs after a
/// row or column is inserted or deleted.
///
/// The reference RULES are pinned by `FormulaReferenceAdjusterTests`.
/// What matters here is the sweep over the grid - that every formula
/// cell is visited, that literals are left alone, and that the result
/// still calculates.
@MainActor
final class SheetFormulaAdjustmentTests: XCTestCase {

    /// A 6x3 sheet: column A holds 1..4, B1 totals it, B2 references a
    /// single cell, C1 is a literal that happens to look formula-ish.
    private func makeModel() -> Sheet {
        var sheet = Sheet.makeBlank(title: "Model", rows: 6, cols: 3)
        sheet = sheet.settingCellText(row: 0, col: 0, "1")
        sheet = sheet.settingCellText(row: 1, col: 0, "2")
        sheet = sheet.settingCellText(row: 2, col: 0, "3")
        sheet = sheet.settingCellText(row: 3, col: 0, "4")
        sheet = sheet.settingCellText(row: 0, col: 1, "=SUM(A1:A4)")
        sheet = sheet.settingCellText(row: 1, col: 1, "=A4*2")
        sheet = sheet.settingCellText(row: 0, col: 2, "not a formula")
        return sheet
    }

    // MARK: - The sweep

    func testInsertRowRewritesEveryFormula() {
        let adjusted = makeModel().adjustingFormulas(for: .insertRows(at: 0, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 0, col: 1), "=SUM(A2:A5)")
        XCTAssertEqual(adjusted.cellText(row: 1, col: 1), "=A5*2")
    }

    func testDeleteRowRewritesEveryFormula() {
        let adjusted = makeModel().adjustingFormulas(for: .deleteRows(at: 0, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 0, col: 1), "=SUM(A1:A3)")
        XCTAssertEqual(adjusted.cellText(row: 1, col: 1), "=A3*2")
    }

    func testInsertColumnRewritesEveryFormula() {
        let adjusted = makeModel().adjustingFormulas(for: .insertColumns(at: 0, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 0, col: 1), "=SUM(B1:B4)")
    }

    /// Literals must not be touched, including text that resembles one.
    func testLiteralsAreUntouched() {
        let adjusted = makeModel().adjustingFormulas(for: .insertRows(at: 0, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 0, col: 0), "1")
        XCTAssertEqual(adjusted.cellText(row: 0, col: 2), "not a formula")
    }

    /// An edit below everything changes nothing at all.
    func testEditBelowTheDataIsANoOp() {
        let original = makeModel()
        let adjusted = original.adjustingFormulas(for: .insertRows(at: 5, count: 1))
        for row in 0..<original.rowCount {
            for col in 0..<original.columnCount {
                XCTAssertEqual(
                    adjusted.cellText(row: row, col: col),
                    original.cellText(row: row, col: col)
                )
            }
        }
    }

    /// Deleting the referenced cell leaves #REF! rather than a formula
    /// that keeps computing over the wrong data.
    func testDeletingAReferencedRowLeavesRefError() {
        let adjusted = makeModel().adjustingFormulas(for: .deleteRows(at: 3, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 1, col: 1), "=#REF!*2")
    }

    /// A range only partially deleted clamps and keeps working.
    func testPartiallyDeletedRangeClamps() {
        let adjusted = makeModel().adjustingFormulas(for: .deleteRows(at: 3, count: 1))
        XCTAssertEqual(adjusted.cellText(row: 0, col: 1), "=SUM(A1:A3)")
    }

    // MARK: - Still calculates afterwards

    /// The end-to-end point: after an insert, the adjusted model
    /// computes the SAME total, because the references followed the
    /// data. This is what silently broke before.
    func testTotalSurvivesARowInsert() throws {
        // Before: 1+2+3+4 = 10.
        let before = makeModel()
        let workbookBefore = SheetWorkbook()
        workbookBefore.hydrate(from: before)
        XCTAssertEqual(workbookBefore.displayText(row: 0, col: 1), "10")

        // Insert a blank row at the top, shifting the data down, and
        // adjust - exactly what SheetStore.insertRow now does.
        var after = Sheet.makeBlank(title: "Model", rows: 7, cols: 3)
        for row in 0..<4 {
            after = after.settingCellText(row: row + 1, col: 0, String(row + 1))
        }
        after = after.settingCellText(row: 1, col: 1, before.cellText(row: 0, col: 1))
        after = after.adjustingFormulas(for: .insertRows(at: 0, count: 1))

        let workbookAfter = SheetWorkbook()
        workbookAfter.hydrate(from: after)
        XCTAssertEqual(after.cellText(row: 1, col: 1), "=SUM(A2:A5)")
        XCTAssertEqual(workbookAfter.displayText(row: 1, col: 1), "10", "the total must survive the insert")
    }

    /// Without adjustment the same insert produces a WRONG total, which
    /// is the failure this pass exists to prevent.
    func testUnadjustedInsertWouldGiveAWrongTotal() throws {
        var after = Sheet.makeBlank(title: "Model", rows: 7, cols: 3)
        for row in 0..<4 {
            after = after.settingCellText(row: row + 1, col: 0, String(row + 1))
        }
        // The original formula text, left unadjusted.
        after = after.settingCellText(row: 1, col: 1, "=SUM(A1:A4)")

        let workbook = SheetWorkbook()
        workbook.hydrate(from: after)
        // A1 is now blank, A5 is excluded: 1+2+3 = 6, not 10.
        XCTAssertEqual(workbook.displayText(row: 1, col: 1), "6")
    }
}
