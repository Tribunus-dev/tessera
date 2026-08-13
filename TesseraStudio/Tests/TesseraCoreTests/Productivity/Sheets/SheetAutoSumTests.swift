import XCTest
@testable import TesseraCore

/// AutoSum's range picking - the half that decides WHAT to sum.
///
/// Split from the write so it can be tested without a data layer. The
/// rule mirrors Excel: the contiguous run of numbers directly above the
/// cell, else the run directly to its left, else nothing.
@MainActor
final class SheetAutoSumTests: XCTestCase {

    private func viewModel(_ sheet: Sheet) -> SheetEditorViewModel {
        SheetEditorViewModel(
            sheet: sheet,
            store: SheetStore(dataLayer: TesseraDataLayer()),
            userID: UUID()
        )
    }

    /// Column A holds a label then 1..3; row 4 is where a total goes.
    private func labelledColumn() -> Sheet {
        var sheet = Sheet.makeBlank(title: "Model", rows: 6, cols: 4)
        sheet = sheet.settingCellText(row: 0, col: 0, "Revenue")
        sheet = sheet.settingCellText(row: 1, col: 0, "10")
        sheet = sheet.settingCellText(row: 2, col: 0, "20")
        sheet = sheet.settingCellText(row: 3, col: 0, "30")
        return sheet
    }

    // MARK: - Vertical

    func testSumsTheContiguousRunAbove() {
        let vm = viewModel(labelledColumn())
        XCTAssertEqual(
            vm.autoSumFormula(for: SheetCellCoord(row: 4, col: 0)),
            "=SUM(A2:A4)"
        )
    }

    /// The run stops at the header, so the total sums the figures and
    /// not the word above them.
    func testTheRunStopsAtANonNumericCell() {
        let formula = viewModel(labelledColumn())
            .autoSumFormula(for: SheetCellCoord(row: 4, col: 0))
        XCTAssertFalse(formula?.contains("A1") ?? true, "the label row must be excluded: \(formula ?? "nil")")
    }

    func testTheRunStopsAtABlankCell() {
        var sheet = Sheet.makeBlank(title: "Gap", rows: 6, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "5")
        // row 1 blank
        sheet = sheet.settingCellText(row: 2, col: 0, "7")
        sheet = sheet.settingCellText(row: 3, col: 0, "8")

        XCTAssertEqual(
            viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 4, col: 0)),
            "=SUM(A3:A4)"
        )
    }

    /// A subtotal joins the run like any other number: what matters is
    /// the COMPUTED value, not whether the cell holds a formula.
    func testAFormulaCellExtendsTheRun() {
        var sheet = Sheet.makeBlank(title: "Nested", rows: 6, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "1")
        sheet = sheet.settingCellText(row: 1, col: 0, "2")
        sheet = sheet.settingCellText(row: 2, col: 0, "=A1+A2")

        XCTAssertEqual(
            viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 3, col: 0)),
            "=SUM(A1:A3)"
        )
    }

    // MARK: - Horizontal fallback

    /// Nothing above, numbers to the left: sum the row. This is the
    /// year-total column at the end of a model.
    func testFallsBackToTheRunOnTheLeft() {
        var sheet = Sheet.makeBlank(title: "Row", rows: 3, cols: 6)
        sheet = sheet.settingCellText(row: 0, col: 0, "1")
        sheet = sheet.settingCellText(row: 0, col: 1, "2")
        sheet = sheet.settingCellText(row: 0, col: 2, "3")

        XCTAssertEqual(
            viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 0, col: 3)),
            "=SUM(A1:C1)"
        )
    }

    /// Above wins when both directions have numbers - the column is
    /// what a total under a table means.
    func testAboveWinsOverLeft() {
        var sheet = Sheet.makeBlank(title: "Both", rows: 4, cols: 4)
        sheet = sheet.settingCellText(row: 0, col: 1, "5")
        sheet = sheet.settingCellText(row: 1, col: 0, "9")

        XCTAssertEqual(
            viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 1, col: 1)),
            "=SUM(B1:B1)"
        )
    }

    // MARK: - Nothing to sum

    /// No neighbours: return nil rather than write `=SUM()` the user
    /// then has to delete.
    func testReturnsNilWhenThereIsNothingToSum() {
        let sheet = Sheet.makeBlank(title: "Empty", rows: 4, cols: 4)
        XCTAssertNil(viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 2, col: 2)))
    }

    func testTopLeftCellHasNothingToSum() {
        var sheet = Sheet.makeBlank(title: "Corner", rows: 4, cols: 4)
        sheet = sheet.settingCellText(row: 1, col: 1, "3")
        XCTAssertNil(viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 0, col: 0)))
    }

    func testTextOnlyNeighboursAreNotSummable() {
        var sheet = Sheet.makeBlank(title: "Text", rows: 4, cols: 4)
        sheet = sheet.settingCellText(row: 0, col: 0, "alpha")
        sheet = sheet.settingCellText(row: 1, col: 0, "beta")
        XCTAssertNil(viewModel(sheet).autoSumFormula(for: SheetCellCoord(row: 2, col: 0)))
    }

    // MARK: - The formula actually computes

    /// End to end: the range AutoSum picks evaluates to the total of
    /// the cells it spans.
    func testTheGeneratedFormulaComputesTheTotal() {
        let sheet = labelledColumn()
        let vm = viewModel(sheet)
        let coord = SheetCellCoord(row: 4, col: 0)
        let formula = try? XCTUnwrap(vm.autoSumFormula(for: coord))

        let workbook = SheetWorkbook()
        workbook.hydrate(from: sheet)
        workbook.apply(text: formula ?? "", row: coord.row, col: coord.col)
        XCTAssertEqual(workbook.displayText(row: coord.row, col: coord.col), "60")
    }

    // MARK: - Selected format

    func testSelectedCellFormatTracksTheSelection() {
        let sheet = Sheet.makeBlank(title: "Fmt", rows: 3, cols: 3)
            .settingCellFormat(row: 1, col: 1, SheetCellFormat(numberFormat: .percent))
        let vm = viewModel(sheet)

        XCTAssertEqual(vm.selectedCellFormat, .standard, "no selection reads as standard")
        vm.selectCell(SheetCellCoord(row: 1, col: 1))
        XCTAssertEqual(vm.selectedCellFormat.numberFormat, .percent)
        vm.selectCell(SheetCellCoord(row: 0, col: 0))
        XCTAssertEqual(vm.selectedCellFormat, .standard)
    }
}
