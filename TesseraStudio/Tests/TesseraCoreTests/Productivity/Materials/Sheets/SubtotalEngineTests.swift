import XCTest
@testable import TesseraCore

// Contract source: TesseraStudio/docs/.scratch/sota-p2-core-report.md
// section "2.7 Subtotals - Calc": "SubtotalDescriptor {groupByColumn,
// perColumnFunctions [(column, aggregation)], replaceExisting,
// summaryBelow}; nesting produces outline levels 1..7." / "Pipeline:
// descriptor -> group boundaries (display-text equality) -> insert
// real =SUBTOTAL(fn, range) rows -> assign outline levels." / "Tests:
// ... SubtotalEngine's outline-level assignment against a 2-level
// nesting fixture." `SubtotalEngine.plan` is pure (Sheet + descriptor
// -> SubtotalPlan, no mutation, no SheetStore) - every test below
// calls it directly.
final class SubtotalEngineTests: DoctrineTestCase {

    // MARK: - Fixture builder

    /// A blank `rows` x `cols` sheet with `columns[col][row]` written
    /// into each cell via `settingCellText` - the same raw stored
    /// inline-run text `Sheet.cellText`/`SheetStore.applyFilter`'s
    /// `displayText` closure both read (see SubtotalEngine.swift's
    /// `plan` doc comment).
    private func makeSheet(rows: Int, columns: [[String]]) -> Sheet {
        var sheet = Sheet.makeBlank(title: "t", rows: rows, cols: columns.count)
        for (col, values) in columns.enumerated() {
            for (row, text) in values.enumerated() {
                sheet = sheet.settingCellText(row: row, col: col, text)
            }
        }
        return sheet
    }

    // MARK: - Group boundaries + insertion positions

    func testSingleGroupProducesOneSummaryRowAndOneGrandTotalRow() {
        // One group ("East" x3) - the grand total joins unconditionally
        // per SubtotalEngine's own doc comment, even though its range
        // is identical to the lone group's.
        let sheet = makeSheet(rows: 3, columns: [
            ["East", "East", "East"],
            ["10", "20", "30"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan.groupCount, 1)
        XCTAssertEqual(plan.insertions.count, 2, "one group summary row + one grand total row")
        XCTAssertEqual(plan.insertions.filter { $0.isGrandTotal }.count, 1)
    }

    func testMultipleGroupsProduceOneSummaryRowPerGroupPlusOneGrandTotal() {
        let sheet = makeSheet(rows: 5, columns: [
            ["East", "East", "West", "West", "West"],
            ["10", "20", "1", "2", "3"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan.groupCount, 2)
        XCTAssertEqual(plan.insertions.count, 3, "two group summary rows + one grand total row")
        XCTAssertEqual(plan.insertions.filter { $0.isGrandTotal }.count, 1)
    }

    func testNonContiguousEqualLabelsFormSeparateGroups() {
        // "East" appears at rows 0 and 2, but row 1 is "West" in
        // between - these are two SEPARATE one-row groups, not one
        // merged "East" group, because grouping only ever looks at
        // contiguous runs (matching Excel/LO's pre-sort precondition -
        // see SubtotalEngine.groupBoundaries's doc comment).
        let sheet = makeSheet(rows: 3, columns: [
            ["East", "West", "East"],
            ["10", "20", "30"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan.groupCount, 3, "East, West, East as three separate contiguous runs")
    }

    func testSummaryBelowTruePlacesEachSummaryRowImmediatelyAfterItsGroupAndGrandTotalAtTheEnd() throws {
        let sheet = makeSheet(rows: 4, columns: [
            ["East", "East", "West", "West"],
            ["1", "2", "3", "4"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)],
            summaryBelow: true
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        let groupInsertions = plan.insertions.filter { !$0.isGrandTotal }.sorted { $0.beforeOriginalRow < $1.beforeOriginalRow }
        XCTAssertEqual(groupInsertions.map { $0.beforeOriginalRow }, [2, 4], "East group (rows 0-1) summary before row 2; West group (rows 2-3) summary after the last original row")
        let grandTotal = try XCTUnwrap(plan.insertions.first { $0.isGrandTotal })
        XCTAssertEqual(grandTotal.beforeOriginalRow, 4, "grand total appends after the last original row")
    }

    func testSummaryBelowFalsePlacesEachSummaryRowImmediatelyBeforeItsGroupAndGrandTotalAtTheTop() throws {
        let sheet = makeSheet(rows: 4, columns: [
            ["East", "East", "West", "West"],
            ["1", "2", "3", "4"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)],
            summaryBelow: false
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        let groupInsertions = plan.insertions.filter { !$0.isGrandTotal }.sorted { $0.beforeOriginalRow < $1.beforeOriginalRow }
        XCTAssertEqual(groupInsertions.map { $0.beforeOriginalRow }, [0, 2], "East group summary before row 0; West group summary before row 2")
        let grandTotal = try XCTUnwrap(plan.insertions.first { $0.isGrandTotal })
        XCTAssertEqual(grandTotal.beforeOriginalRow, 0, "grand total inserts at the very top")
    }

    func testInsertionsAreSortedAscendingByBeforeOriginalRow() {
        let sheet = makeSheet(rows: 4, columns: [
            ["East", "East", "West", "West"],
            ["1", "2", "3", "4"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        let positions = plan.insertions.map { $0.beforeOriginalRow }
        XCTAssertEqual(positions, positions.sorted())
    }

    // MARK: - Summary row content

    func testSummaryRowFormulaTextIsARealSubtotalFormulaOverTheGroupsOriginalRowRange() throws {
        let sheet = makeSheet(rows: 3, columns: [
            ["East", "East", "East"],
            ["10", "20", "30"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        let groupSummary = try XCTUnwrap(plan.insertions.first { !$0.isGrandTotal })
        XCTAssertEqual(groupSummary.cellTexts[1], "=SUBTOTAL(9,B1:B3)")
    }

    func testSummaryRowGroupByColumnCellCarriesTheLabelPlusTotalSuffix() throws {
        let sheet = makeSheet(rows: 2, columns: [
            ["East", "East"],
            ["10", "20"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        let groupSummary = try XCTUnwrap(plan.insertions.first { !$0.isGrandTotal })
        XCTAssertEqual(groupSummary.cellTexts[0], "East Total")
        let grandTotal = try XCTUnwrap(plan.insertions.first { $0.isGrandTotal })
        XCTAssertEqual(grandTotal.cellTexts[0], "Grand Total")
    }

    func testMultiplePerColumnFunctionsEachGetTheirOwnFormulaWithTheirOwnFunctionNum() throws {
        let sheet = makeSheet(rows: 2, columns: [
            ["East", "East"],
            ["10", "20"],
            ["1", "2"],
        ])
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [
                SubtotalColumnFunction(columnIndex: 1, function: .sum),
                SubtotalColumnFunction(columnIndex: 2, function: .average),
            ]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        let groupSummary = try XCTUnwrap(plan.insertions.first { !$0.isGrandTotal })
        XCTAssertEqual(groupSummary.cellTexts[1], "=SUBTOTAL(9,B1:B2)")
        XCTAssertEqual(groupSummary.cellTexts[2], "=SUBTOTAL(1,C1:C2)")
    }

    // MARK: - Outline levels: first pass

    func testFirstPassPutsDetailRowsAtLevelOneAndSummaryRowsAtLevelZero() {
        let sheet = makeSheet(rows: 4, columns: [
            ["East", "East", "West", "West"],
            ["1", "2", "3", "4"],
        ])
        XCTAssertTrue(sheet.effectiveRowOutlineLevels.isEmpty, "fresh sheet has no outline yet")
        let descriptor = SubtotalDescriptor(
            groupByColumn: 0,
            perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)]
        )
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        for row in 0..<4 {
            XCTAssertEqual(plan.existingRowLevels[row], 1, "row \(row) is a detail row, bumped from the implicit level 0 to 1")
        }
        for insertion in plan.insertions {
            XCTAssertEqual(insertion.outlineLevel, 0, "every newly-inserted summary/grand-total row sits at the shallowest level on a first pass")
        }
    }

    // MARK: - Outline levels: 2-level nesting fixture (design contract's named test)

    /// Simulates a sheet AFTER a first subtotal pass has already been
    /// applied and its plan executed: 4 detail rows (level 1) plus 2
    /// group-summary rows (level 0) already physically present, laid
    /// out as [detail, detail, summary, detail, detail, summary].
    /// Column 1 (the SECOND pass's groupByColumn) is deliberately
    /// IDENTICAL across every one of the 6 rows ("All"), so the second
    /// pass groups the whole sheet into one outer group regardless of
    /// whether a summary row's other columns are blank - isolating
    /// this test to exactly what the design contract asks for
    /// ("SubtotalEngine's outline-level assignment"), not grouping's
    /// interaction with blank cells (a separate, untested concern).
    private func twoLevelNestingFixture() -> Sheet {
        var sheet = Sheet.makeBlank(title: "t", rows: 6, cols: 2)
        let regionColumn = ["East", "East", "East Total", "West", "West", "West Total"]
        let groupColumn = ["All", "All", "All", "All", "All", "All"]
        for row in 0..<6 {
            sheet = sheet.settingCellText(row: row, col: 0, regionColumn[row])
            sheet = sheet.settingCellText(row: row, col: 1, groupColumn[row])
        }
        sheet.rowOutlineLevels = [0: 1, 1: 1, 2: 0, 3: 1, 4: 1, 5: 0]
        return sheet
    }

    func testSecondPassOverAnAlreadySubtotaledSheetBumpsEveryExistingRowByOneLevel() {
        let sheet = twoLevelNestingFixture()
        let descriptor = SubtotalDescriptor(groupByColumn: 1, perColumnFunctions: [SubtotalColumnFunction(columnIndex: 0, function: .count)])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)

        // Former detail rows (0,1,3,4 - originally level 1) bump to 2;
        // former summary rows (2,5 - originally level 0) bump to 1.
        XCTAssertEqual(plan.existingRowLevels[0], 2)
        XCTAssertEqual(plan.existingRowLevels[1], 2)
        XCTAssertEqual(plan.existingRowLevels[2], 1)
        XCTAssertEqual(plan.existingRowLevels[3], 2)
        XCTAssertEqual(plan.existingRowLevels[4], 2)
        XCTAssertEqual(plan.existingRowLevels[5], 1)
    }

    func testSecondPassNewSummaryRowSitsAtTheShallowestPreBumpLevelWithinItsGroup() throws {
        let sheet = twoLevelNestingFixture()
        let descriptor = SubtotalDescriptor(groupByColumn: 1, perColumnFunctions: [SubtotalColumnFunction(columnIndex: 0, function: .count)])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)

        // Single group spans all 6 rows (column 1 is "All" throughout);
        // the pre-bump levels within it are {1,1,0,1,1,0} - minimum 0 -
        // so the new pass's own summary row for that group lands at 0,
        // the classic outermost/grand-total tier.
        XCTAssertEqual(plan.groupCount, 1)
        let groupSummary = try XCTUnwrap(plan.insertions.first { !$0.isGrandTotal })
        XCTAssertEqual(groupSummary.outlineLevel, 0)
    }

    func testSecondPassProducesTheClassicThreeTierOutlineShape() {
        // Restated as one assertion over the full level set: detail
        // rows at 2, the first pass's summary rows at 1, the new
        // pass's own summary/grand-total rows at 0 - SubtotalPlan's own
        // header names this "the classic 3-tier shape."
        let sheet = twoLevelNestingFixture()
        let descriptor = SubtotalDescriptor(groupByColumn: 1, perColumnFunctions: [SubtotalColumnFunction(columnIndex: 0, function: .count)])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)

        let detailLevels = Set([0, 1, 3, 4].compactMap { plan.existingRowLevels[$0] })
        let firstPassSummaryLevels = Set([2, 5].compactMap { plan.existingRowLevels[$0] })
        let newSummaryLevels = Set(plan.insertions.map { $0.outlineLevel })
        XCTAssertEqual(detailLevels, [2])
        XCTAssertEqual(firstPassSummaryLevels, [1])
        XCTAssertEqual(newSummaryLevels, [0])
    }

    // MARK: - Guard clauses / no-op shape

    func testEmptySheetProducesAnEmptyPlan() {
        let sheet = Sheet.makeBlank(title: "t", rows: 0, cols: 2)
        let descriptor = SubtotalDescriptor(groupByColumn: 0, perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan, .empty)
    }

    func testDescriptorWithNoPerColumnFunctionsProducesAnEmptyPlan() {
        let sheet = makeSheet(rows: 2, columns: [["East", "East"]])
        let descriptor = SubtotalDescriptor(groupByColumn: 0, perColumnFunctions: [])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan, .empty)
    }

    func testNegativeGroupByColumnProducesAnEmptyPlanInsteadOfTrapping() {
        let sheet = makeSheet(rows: 2, columns: [["East", "East"], ["1", "2"]])
        let descriptor = SubtotalDescriptor(groupByColumn: -1, perColumnFunctions: [SubtotalColumnFunction(columnIndex: 1, function: .sum)])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan, .empty)
    }

    func testNegativePerColumnFunctionColumnIndexProducesAnEmptyPlanInsteadOfTrapping() {
        let sheet = makeSheet(rows: 2, columns: [["East", "East"], ["1", "2"]])
        let descriptor = SubtotalDescriptor(groupByColumn: 0, perColumnFunctions: [SubtotalColumnFunction(columnIndex: -1, function: .sum)])
        let plan = SubtotalEngine.plan(for: sheet, descriptor: descriptor)
        XCTAssertEqual(plan, .empty)
    }

    // MARK: - Sheet.effective* "nil means default" convention

    func testSheetWithNoOutlineStateReportsEmptyEffectiveRowOutlineLevels() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        XCTAssertEqual(sheet.effectiveRowOutlineLevels, [:])
    }

    func testSheetWithNoOutlineStateReportsSummaryBelowTrueByDefault() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        XCTAssertTrue(sheet.effectiveOutlineSummaryBelow)
    }

    func testExplicitOutlineSummaryBelowFalseOverridesTheDefault() {
        var sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        sheet.outlineSummaryBelow = false
        XCTAssertFalse(sheet.effectiveOutlineSummaryBelow)
    }
}
