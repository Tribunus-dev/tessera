import XCTest
@testable import TesseraCore

/// Rewriting formula references when rows or columns are inserted or
/// deleted.
///
/// This is the failure mode worth the most tests: an unadjusted formula
/// does not error, it computes a plausible number over the wrong cells.
/// The expectations below are the observable behaviour of any
/// spreadsheet, derived from the rules rather than from an
/// implementation.
final class FormulaReferenceAdjusterTests: XCTestCase {

    private func adjust(_ source: String, _ edit: StructuralEdit) -> String {
        FormulaReferenceAdjuster.adjust(source, for: edit)
    }

    // MARK: - Insert rows

    func testInsertAboveShiftsReferenceDown() {
        XCTAssertEqual(adjust("=A5", .insertRows(at: 0, count: 1)), "=A6")
    }

    func testInsertBelowLeavesReferenceAlone() {
        XCTAssertEqual(adjust("=A5", .insertRows(at: 9, count: 1)), "=A5")
    }

    /// `$` marks a reference absolute for COPYING, not for structural
    /// edits: the cell physically moved, so the reference moves with it.
    func testAbsoluteReferenceStillShifts() {
        XCTAssertEqual(adjust("=$A$5", .insertRows(at: 0, count: 1)), "=$A$5".replacingOccurrences(of: "5", with: "6"))
    }

    func testInsertShiftsByTheRowCount() {
        XCTAssertEqual(adjust("=A5", .insertRows(at: 0, count: 3)), "=A8")
    }

    /// A range that SPANS the insertion point grows to include it.
    func testInsertInsideRangeGrowsIt() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .insertRows(at: 2, count: 1)), "=SUM(A1:A6)")
    }

    /// A range entirely below the insertion moves wholesale.
    func testInsertAboveRangeShiftsWholeRange() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .insertRows(at: 0, count: 1)), "=SUM(A2:A6)")
    }

    func testInsertBelowRangeLeavesItAlone() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .insertRows(at: 9, count: 1)), "=SUM(A1:A5)")
    }

    // MARK: - Delete rows

    func testDeleteAboveShiftsReferenceUp() {
        XCTAssertEqual(adjust("=A5", .deleteRows(at: 0, count: 1)), "=A4")
    }

    func testDeleteBelowLeavesReferenceAlone() {
        XCTAssertEqual(adjust("=A5", .deleteRows(at: 9, count: 1)), "=A5")
    }

    /// Deleting the referenced cell is #REF!, permanently. Quietly
    /// pointing somewhere else would keep computing a wrong answer.
    func testDeletingTheReferencedRowIsRefError() {
        XCTAssertEqual(adjust("=A5", .deleteRows(at: 4, count: 1)), "=#REF!")
    }

    /// A partially-deleted range clamps to what survives.
    func testDeletingPartOfARangeClampsIt() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .deleteRows(at: 0, count: 2)), "=SUM(A1:A3)")
    }

    func testDeletingTheTailOfARangeClampsIt() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .deleteRows(at: 3, count: 2)), "=SUM(A1:A3)")
    }

    /// Deleting the whole range is #REF! - there is nothing left to sum.
    func testDeletingAnEntireRangeIsRefError() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .deleteRows(at: 0, count: 5)), "=SUM(#REF!)")
    }

    func testDeleteBelowRangeLeavesItAlone() {
        XCTAssertEqual(adjust("=SUM(A1:A5)", .deleteRows(at: 9, count: 1)), "=SUM(A1:A5)")
    }

    func testDeleteAboveRangeShiftsWholeRange() {
        XCTAssertEqual(adjust("=SUM(A3:A5)", .deleteRows(at: 0, count: 2)), "=SUM(A1:A3)")
    }

    // MARK: - Columns

    func testInsertColumnShiftsReferenceRight() {
        XCTAssertEqual(adjust("=B1", .insertColumns(at: 0, count: 1)), "=C1")
    }

    func testDeleteColumnShiftsReferenceLeft() {
        XCTAssertEqual(adjust("=C1", .deleteColumns(at: 0, count: 1)), "=B1")
    }

    func testDeletingTheReferencedColumnIsRefError() {
        XCTAssertEqual(adjust("=C1", .deleteColumns(at: 2, count: 1)), "=#REF!")
    }

    func testInsertInsideColumnRangeGrowsIt() {
        XCTAssertEqual(adjust("=SUM(A1:C1)", .insertColumns(at: 1, count: 1)), "=SUM(A1:D1)")
    }

    /// A row edit must not disturb columns.
    func testRowEditLeavesColumnsAlone() {
        XCTAssertEqual(adjust("=SUM(B2:D2)", .insertRows(at: 0, count: 1)), "=SUM(B3:D3)")
    }

    // MARK: - What must NOT be rewritten

    /// A function whose name ends in digits scans as a reference right
    /// up to the parenthesis. `LOG10(` is column LOG, row 10.
    func testFunctionNameEndingInDigitsIsNotAReference() {
        XCTAssertEqual(adjust("=LOG10(A5)", .insertRows(at: 0, count: 1)), "=LOG10(A6)")
    }

    /// A defined name that looks like a reference is left alone. Real
    /// columns are at most three letters (XFD).
    func testLongNameIsNotTreatedAsAReference() {
        XCTAssertEqual(adjust("=Sales2024", .insertRows(at: 0, count: 1)), "=Sales2024")
    }

    /// Text inside quotes is text, even when it spells a reference.
    func testReferenceInsideAStringLiteralIsUntouched() {
        XCTAssertEqual(adjust("=\"A5 is here\"", .insertRows(at: 0, count: 1)), "=\"A5 is here\"")
    }

    func testMixedLiteralAndReference() {
        XCTAssertEqual(
            adjust("=CONCAT(\"A5\", A5)", .insertRows(at: 0, count: 1)),
            "=CONCAT(\"A5\", A6)"
        )
    }

    /// Numbers are not references.
    func testPlainNumbersAreUntouched() {
        XCTAssertEqual(adjust("=1+2*3", .insertRows(at: 0, count: 1)), "=1+2*3")
    }

    /// Formatting, spacing and number spelling must survive: the formula
    /// is text the user wrote and expects back.
    func testFormattingIsPreserved() {
        XCTAssertEqual(
            adjust("= SUM( A1 : A5 ) + 1", .insertRows(at: 9, count: 1)),
            "= SUM( A1 : A5 ) + 1"
        )
    }

    // MARK: - Sheet-qualified references

    func testSheetQualifiedReferenceShifts() {
        XCTAssertEqual(adjust("=Sheet2!A5", .insertRows(at: 0, count: 1)), "=Sheet2!A6")
    }

    func testQuotedSheetNameIsPreserved() {
        XCTAssertEqual(adjust("='My Sheet'!A5", .insertRows(at: 0, count: 1)), "='My Sheet'!A6")
    }

    // MARK: - Realistic formulas

    func testRealisticFormulaAdjustsEveryReference() {
        XCTAssertEqual(
            adjust("=SUM(B2:B10)/COUNT(B2:B10)+C1", .insertRows(at: 0, count: 1)),
            "=SUM(B3:B11)/COUNT(B3:B11)+C2"
        )
    }

    /// The adjusted formula must still parse and evaluate.
    @MainActor
    func testAdjustedFormulaStillComputes() throws {
        let engine = SheetEngine()
        for row in 0..<3 {
            engine.setValue(sheet: nil, addr: CellAddr(col: 0, row: row), value: .number(Double(row + 1)))
        }
        let adjusted = adjust("=SUM(A1:A3)", .insertRows(at: 0, count: 1))
        XCTAssertEqual(adjusted, "=SUM(A2:A4)")

        // Shift the data down to match, then evaluate.
        let shifted = SheetEngine()
        for row in 1..<4 {
            shifted.setValue(sheet: nil, addr: CellAddr(col: 0, row: row), value: .number(Double(row)))
        }
        try shifted.setFormula(sheet: nil, addr: CellAddr(col: 2, row: 0), source: adjusted)
        XCTAssertEqual(shifted.getValue(sheet: nil, addr: CellAddr(col: 2, row: 0)), .number(6))
    }
}
