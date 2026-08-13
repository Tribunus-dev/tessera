import XCTest
@testable import TesseraCore

/// The calculation layer that connects the Sheets surface to the
/// formula engine.
///
/// Before this the two were unconnected: the grid stored literal text
/// and `SheetEngine` was reachable only from its own tests. The
/// contract here is the one every spreadsheet has - the document keeps
/// the SOURCE text, the grid shows the COMPUTED value - and these tests
/// pin both halves.
@MainActor
final class SheetWorkbookTests: XCTestCase {

    private var workbook: SheetWorkbook!

    override func setUp() {
        super.setUp()
        workbook = SheetWorkbook()
    }

    // MARK: - Editing

    func testLiteralNumberIsTyped() {
        workbook.apply(text: "42", row: 0, col: 0)
        XCTAssertEqual(workbook.value(row: 0, col: 0), .number(42))
    }

    func testLiteralTextStaysText() {
        workbook.apply(text: "Widget", row: 0, col: 0)
        XCTAssertEqual(workbook.value(row: 0, col: 0), .string("Widget"))
    }

    /// The whole point: a formula computes.
    func testFormulaComputes() {
        workbook.apply(text: "10", row: 0, col: 0)
        workbook.apply(text: "20", row: 1, col: 0)
        workbook.apply(text: "=SUM(A1:A2)", row: 2, col: 0)
        XCTAssertEqual(workbook.displayText(row: 2, col: 0), "30")
    }

    /// Editing a precedent must update the dependent - this is what the
    /// dependency graph is for, and it never ran in the product before.
    func testDependentRecalculatesWhenPrecedentChanges() {
        workbook.apply(text: "10", row: 0, col: 0)
        workbook.apply(text: "=A1*2", row: 1, col: 0)
        XCTAssertEqual(workbook.displayText(row: 1, col: 0), "20")

        workbook.apply(text: "50", row: 0, col: 0)
        XCTAssertEqual(workbook.displayText(row: 1, col: 0), "100")
    }

    /// A bare "=" is text, not an empty formula.
    func testBareEqualsIsText() {
        workbook.apply(text: "=", row: 0, col: 0)
        XCTAssertEqual(workbook.value(row: 0, col: 0), .string("="))
    }

    /// A circular reference shows #REF! rather than blanking the cell.
    func testCircularReferenceShowsRefError() {
        workbook.apply(text: "=A1+1", row: 0, col: 0)
        XCTAssertEqual(workbook.value(row: 0, col: 0), .error(.referenceInvalid))
    }

    /// A rejected formula reports false so the caller knows, but the
    /// caller still persists the text the user typed.
    func testRejectedFormulaReturnsFalse() {
        XCTAssertFalse(workbook.apply(text: "=A1+1", row: 0, col: 0))
        XCTAssertTrue(workbook.apply(text: "=1+1", row: 1, col: 0))
    }

    /// Recalculation can touch cells far from the edit, so the grid
    /// needs a signal that is not the edited coordinate.
    func testRevisionAdvancesOnEveryEdit() {
        let before = workbook.revision
        workbook.apply(text: "1", row: 0, col: 0)
        XCTAssertGreaterThan(workbook.revision, before)
    }

    // MARK: - Hydration

    /// Loading a stored sheet must reproduce its calculated state.
    func testHydrateComputesStoredFormulas() {
        var sheet = Sheet.makeBlank(title: "Model", rows: 4, cols: 2)
        sheet = setText(sheet, row: 0, col: 0, "10")
        sheet = setText(sheet, row: 1, col: 0, "20")
        sheet = setText(sheet, row: 2, col: 0, "=SUM(A1:A2)")

        workbook.hydrate(from: sheet)
        XCTAssertEqual(workbook.displayText(row: 2, col: 0), "30")
    }

    /// A formula placed ABOVE its inputs must still compute. A single
    /// hydration pass would evaluate it against blanks and cache 0.
    func testHydrateHandlesForwardReferences() {
        var sheet = Sheet.makeBlank(title: "Model", rows: 4, cols: 2)
        sheet = setText(sheet, row: 0, col: 0, "=SUM(A2:A3)")
        sheet = setText(sheet, row: 1, col: 0, "5")
        sheet = setText(sheet, row: 2, col: 0, "7")

        workbook.hydrate(from: sheet)
        XCTAssertEqual(workbook.displayText(row: 0, col: 0), "12")
    }

    /// Reloading replaces state rather than merging into it.
    func testHydrateReplacesPreviousState() {
        workbook.apply(text: "999", row: 0, col: 0)
        let sheet = Sheet.makeBlank(title: "Fresh", rows: 2, cols: 2)
        workbook.hydrate(from: sheet)
        XCTAssertEqual(workbook.value(row: 0, col: 0), .null)
    }

    /// A stored formula that no longer parses shows #REF!, not a blank -
    /// a blank cell reads as data loss.
    func testHydrateMarksUnparseableFormula() {
        var sheet = Sheet.makeBlank(title: "Model", rows: 2, cols: 2)
        sheet = setText(sheet, row: 0, col: 0, "=SUM(")
        workbook.hydrate(from: sheet)
        if case .error = workbook.value(row: 0, col: 0) {} else {
            XCTFail("expected an error value, got \(workbook.value(row: 0, col: 0))")
        }
    }

    func testUnloadClearsState() {
        workbook.apply(text: "5", row: 0, col: 0)
        workbook.unload()
        XCTAssertEqual(workbook.value(row: 0, col: 0), .null)
        XCTAssertNil(workbook.sheetID)
    }

    // MARK: - Source versus display

    /// The grid shows the computed value; the document keeps the source.
    /// Storing the computed value instead would turn every formula into
    /// a literal on the next save.
    func testDisplayIsComputedWhileSourceStaysInTheDocument() {
        var sheet = Sheet.makeBlank(title: "Model", rows: 3, cols: 2)
        sheet = setText(sheet, row: 0, col: 0, "6")
        sheet = setText(sheet, row: 1, col: 0, "=A1*7")
        workbook.hydrate(from: sheet)

        XCTAssertEqual(workbook.displayText(row: 1, col: 0), "42")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "=A1*7", "the document must keep the formula")
    }

    func testHasFormulaDistinguishesFormulaFromLiteral() {
        workbook.apply(text: "=1+1", row: 0, col: 0)
        workbook.apply(text: "2", row: 1, col: 0)
        XCTAssertTrue(workbook.hasFormula(row: 0, col: 0))
        XCTAssertFalse(workbook.hasFormula(row: 1, col: 0))
    }

    // MARK: - Literal typing

    func testLiteralTypingMatchesSpreadsheetConventions() {
        XCTAssertEqual(SheetWorkbook.literal("42"), .number(42))
        XCTAssertEqual(SheetWorkbook.literal("3.5"), .number(3.5))
        XCTAssertEqual(SheetWorkbook.literal("TRUE"), .bool(true))
        XCTAssertEqual(SheetWorkbook.literal("false"), .bool(false))
        XCTAssertEqual(SheetWorkbook.literal(""), .null)
        XCTAssertEqual(SheetWorkbook.literal("Widget"), .string("Widget"))
    }

    // MARK: - Helpers

    /// Write literal text into a sheet's grid, as the store persists it,
    /// without needing the data layer.
    private func setText(_ sheet: Sheet, row: Int, col: Int, _ text: String) -> Sheet {
        sheet.settingCellText(row: row, col: col, text)
    }
}
