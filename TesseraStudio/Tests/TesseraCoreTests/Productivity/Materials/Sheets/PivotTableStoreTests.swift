import XCTest
@testable import TesseraCore

// MARK: - PivotTableStoreTests
//
// Contract: sota-p2-core-report.md section 2.2 ("PivotTableStore -
// Calc"), P2a slice ("steps 1-3 + pipeline + tabular layout + grand
// totals"):
//   "Pipeline: source range -> column vectors -> page filtering ->
//   group-key derivation (member sort via QueryEngine mixed-type
//   order) -> row x column lattice -> per-data-field aggregation (all
//   12 SheetPivotAggregation cases) -> subtotal/grand rows per layout
//   -> PivotResultGrid ... Store pure; SheetStore the only writer."
//   "Tests: legacy P0 JSON fixture decodes to identical semantics;
//   aggregation matrix (12 functions) vs hand-computed grid; ...
//   QueryEngine reuse via shared mixed-type-order vectors." Plus the
//   track brief's own required list: "aggregation matrix ...; a page-
//   filtering test; a group-key-sort test using QueryEngine's
//   mixed-type order."
//
// Per-field subtotal rows, sort/autoShow/reference modes, and
// PivotGroupSpec-based grouping are P2b (see `SheetPivotField`'s doc
// comment in SheetPivotDefinition.swift) - this file exercises P2a's
// tabular-layout + grand-total pipeline only.

final class PivotTableStoreTests: DoctrineTestCase {

    // MARK: - Fixture builders

    private func makeSheet(columns: [String], rows: [[CellValue]]) -> Sheet {
        var sheet = Sheet.makeBlank(title: "t", rows: rows.count, cols: columns.count)
        for (i, label) in columns.enumerated() {
            sheet.columns[i].label = label
        }
        for (r, rowValues) in rows.enumerated() {
            for (c, value) in rowValues.enumerated() {
                sheet = sheet.settingCellValue(row: r, col: c, value)
            }
        }
        return sheet
    }

    private func number(_ value: CellValue, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard case .number(let n) = value else {
            XCTFail("expected .number, got \(value)", file: file, line: line)
            return .nan
        }
        return n
    }

    // MARK: - Aggregation matrix (required test): 12 functions vs hand-computed grid

    /// Region "A" = [10, 20, 30], Region "B" = [5, 15].
    private func regionRevenueSheet() -> Sheet {
        makeSheet(
            columns: ["Region", "Revenue"],
            rows: [
                [.text("A"), .number(10)],
                [.text("A"), .number(20)],
                [.text("A"), .number(30)],
                [.text("B"), .number(5)],
                [.text("B"), .number(15)],
            ]
        )
    }

    private func buildSingleFunctionGrid(_ function: SheetPivotAggregation) throws -> PivotResultGrid {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 4,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: function),
            ],
            columnGrand: false, rowGrand: false
        )
        return try PivotTableStore.build(sheet: regionRevenueSheet(), definition: definition)
    }

    func testAggregationMatrixAllTwelveFunctionsAgainstHandComputedValues() throws {
        // Hand-computed from the documented formulas (mean/sumOfSquares/
        // sample-vs-population denominator), not read off the
        // implementation - the irrational cases are expressed as the
        // textbook formula in Swift rather than typed-out decimals, so
        // no precision is lost transcribing them by hand.
        let expected: [SheetPivotAggregation: (a: Double, b: Double)] = [
            .sum: (60, 20),
            .count: (3, 2),
            .countNumbers: (3, 2),
            .average: (20, 10),
            .min: (10, 5),
            .max: (30, 15),
            .product: (6000, 75),
            .median: (20, 10),
            .stdDev: (10, (50.0).squareRoot()),          // sample: sumSq/(n-1), sqrt
            .variance: (100, 50),                          // sample: sumSq/(n-1)
            .stdDevP: ((200.0 / 3.0).squareRoot(), 5),      // population: sumSq/n, sqrt
            .varianceP: (200.0 / 3.0, 25),                  // population: sumSq/n
        ]
        XCTAssertEqual(Set(expected.keys), Set(SheetPivotAggregation.allCases), "every one of the 12 cases must have a hand-computed expectation")

        for function in SheetPivotAggregation.allCases {
            guard let (a, b) = expected[function] else {
                XCTFail("missing hand-computed expectation for \(function)")
                continue
            }
            let grid = try buildSingleFunctionGrid(function)
            XCTAssertEqual(grid.rows.count, 3, "\(function): 1 header row + 2 group rows (grand totals off)")
            XCTAssertEqual(grid.columnCount, 2, "\(function): 1 row-label column + 1 data column")
            XCTAssertEqual(grid.rows[1][0], .text("A"), "\(function) group order")
            XCTAssertEqual(number(grid.rows[1][1]), a, accuracy: 1e-9, "\(function) group A")
            XCTAssertEqual(grid.rows[2][0], .text("B"), "\(function) group order")
            XCTAssertEqual(number(grid.rows[2][1]), b, accuracy: 1e-9, "\(function) group B")
        }
    }

    /// `.stdDev`/`.variance` (sample, n-1 denominator) on a single-value
    /// group is a degenerate divide-by-zero - matches Excel's STDEV/VAR
    /// returning `#DIV/0!` on a single-cell range. The population
    /// variants have no such case (denominator is n, not n-1).
    func testSampleStdDevAndVarianceReturnDivByZeroErrorForASingleValueGroup() throws {
        let sheet = makeSheet(columns: ["Region", "Revenue"], rows: [[.text("A"), .number(10)]])
        for function: SheetPivotAggregation in [.stdDev, .variance] {
            let definition = SheetPivotDefinition(
                name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 0,
                fields: [
                    SheetPivotField(fieldName: "Region", orientation: .row),
                    SheetPivotField(fieldName: "Revenue", orientation: .data, function: function),
                ],
                columnGrand: false, rowGrand: false
            )
            let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
            XCTAssertEqual(grid.rows[1][1], .error("#DIV/0!"), "\(function) on n=1")
        }
    }

    /// A group with zero numeric values (e.g. a wholly blank data cell)
    /// is `.empty`, not `.number(0)` or an error - it is genuinely "no
    /// data", matching how a real blank pivot cell reads.
    func testAggregateOnNoNumericValuesReturnsEmptyNotZero() {
        XCTAssertEqual(PivotTableStore.aggregate(.sum, values: [.empty, .text("x")]), .empty)
        XCTAssertEqual(PivotTableStore.aggregate(.average, values: []), .empty)
        // .count/.countNumbers are the two exceptions - they correctly
        // answer 0 rather than reading as "no data".
        XCTAssertEqual(PivotTableStore.aggregate(.count, values: []), .number(0))
        XCTAssertEqual(PivotTableStore.aggregate(.countNumbers, values: [.text("x")]), .number(0))
    }

    // MARK: - Page filtering (required test)

    func testPageFieldMembersFilterSourceRowsBeforeEveryAggregationStage() throws {
        let sheet = makeSheet(
            columns: ["Region", "Category", "Revenue"],
            rows: [
                [.text("East"), .text("Retail"), .number(100)],
                [.text("East"), .text("Wholesale"), .number(200)],
                [.text("West"), .text("Retail"), .number(300)],
                [.text("West"), .text("Wholesale"), .number(400)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 3,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Category", orientation: .page, members: [SheetPivotFieldMember(name: "Retail", visible: true)]),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: true
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)

        XCTAssertEqual(grid.rows.count, 4, "1 header + East + West + Grand Total")
        XCTAssertEqual(grid.rows[1], [.text("East"), .number(100)])
        XCTAssertEqual(grid.rows[2], [.text("West"), .number(300)])
        XCTAssertEqual(
            grid.rows[3], [.text("Grand Total"), .number(400)],
            "Wholesale rows (200 + 400) must be excluded from the grand total too - filtering happens before grouping, not just before the visible rows"
        )
    }

    func testPageFieldWithNoMembersAppliesNoFilter() throws {
        let sheet = makeSheet(
            columns: ["Region", "Category", "Revenue"],
            rows: [
                [.text("East"), .text("Retail"), .number(100)],
                [.text("East"), .text("Wholesale"), .number(200)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 1,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Category", orientation: .page),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(grid.rows[1], [.text("East"), .number(300)], "empty members list = \"(All)\" - no filtering")
    }

    // MARK: - Group-key sort via QueryEngine's mixed-type order (required test)

    func testGroupKeySortUsesQueryEnginesMixedTypeOrder() throws {
        // Deliberately NOT pre-sorted in the source - proves the engine
        // actually reorders rather than happening to preserve input
        // order. QueryEngine's documented bucket order: numbers < text
        // < logical < error < blanks (QueryEngine.swift's `sortRank`).
        let sheet = makeSheet(
            columns: ["Key", "Value"],
            rows: [
                [.empty, .number(50)],
                [.checkbox(true), .number(30)],
                [.number(5), .number(10)],
                [.error("#REF!"), .number(40)],
                [.text("Zebra"), .number(20)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 4,
            fields: [
                SheetPivotField(fieldName: "Key", orientation: .row),
                SheetPivotField(fieldName: "Value", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)

        XCTAssertEqual(grid.rows.count, 6, "1 header + 5 distinct keys")
        XCTAssertEqual(grid.rows[1], [.number(5), .number(10)], "numbers sort first")
        XCTAssertEqual(grid.rows[2], [.text("Zebra"), .number(20)], "text second")
        XCTAssertEqual(grid.rows[3], [.checkbox(true), .number(30)], "logical third")
        XCTAssertEqual(grid.rows[4], [.error("#REF!"), .number(40)], "error fourth")
        XCTAssertEqual(grid.rows[5], [.empty, .number(50)], "blanks always last")
    }

    // MARK: - Row x column lattice + grand totals (P2a headline deliverable)

    func testFullRowColumnLatticeWithGrandTotals() throws {
        let sheet = makeSheet(
            columns: ["Region", "Quarter", "Revenue"],
            rows: [
                [.text("East"), .text("Q1"), .number(10)],
                [.text("East"), .text("Q2"), .number(20)],
                [.text("West"), .text("Q1"), .number(30)],
                [.text("West"), .text("Q2"), .number(40)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 3,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Quarter", orientation: .column),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: true, rowGrand: true
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)

        XCTAssertEqual(grid.headerRowCount, 2)
        XCTAssertEqual(grid.headerColumnCount, 1)
        XCTAssertEqual(grid.rowCount, 5, "2 header rows + East + West + Grand Total")
        XCTAssertEqual(grid.columnCount, 4, "1 row-label column + Q1 + Q2 + Grand Total")

        XCTAssertEqual(grid.rows[0], [.empty, .text("Q1"), .text("Q2"), .text("Grand Total")])
        XCTAssertEqual(grid.rows[1], [.text("Region"), .text("Sum of Revenue"), .text("Sum of Revenue"), .text("Sum of Revenue")])
        XCTAssertEqual(grid.rows[2], [.text("East"), .number(10), .number(20), .number(30)])
        XCTAssertEqual(grid.rows[3], [.text("West"), .number(30), .number(40), .number(70)])
        XCTAssertEqual(grid.rows[4], [.text("Grand Total"), .number(40), .number(60), .number(100)])
    }

    // MARK: - repeatItemLabels (fully implemented at P2a)

    private func regionRepSheet() -> Sheet {
        makeSheet(
            columns: ["Region", "Rep", "Revenue"],
            rows: [
                [.text("East"), .text("Ann"), .number(10)],
                [.text("East"), .text("Bob"), .number(20)],
                [.text("West"), .text("Ann"), .number(30)],
            ]
        )
    }

    func testRepeatItemLabelsDefaultsToFalseAndBlanksContinuationRows() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionRepSheet(), definition: definition)

        XCTAssertEqual(grid.rows[0], [.text("Region"), .text("Rep"), .text("Sum of Revenue")])
        XCTAssertEqual(grid.rows[1], [.text("East"), .text("Ann"), .number(10)])
        XCTAssertEqual(grid.rows[2], [.empty, .text("Bob"), .number(20)], "Region repeats East -> blanked; Rep changes -> shown")
        XCTAssertEqual(grid.rows[3], [.text("West"), .text("Ann"), .number(30)], "new Region group -> both levels shown even though Rep=\"Ann\" repeats the FIRST group's Rep value")
    }

    func testRepeatItemLabelsTrueShowsTheLabelOnEveryRow() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row, repeatItemLabels: true),
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionRepSheet(), definition: definition)
        XCTAssertEqual(grid.rows[2], [.text("East"), .text("Bob"), .number(20)], "repeatItemLabels: true on Region keeps it visible on the continuation row")
    }

    // MARK: - ignoreEmptyRows

    func testIgnoreEmptyRowsExcludesWhollyBlankSourceRows() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [
                [.text("East"), .number(10)],
                [.empty, .empty],
                [.text("West"), .number(20)],
            ]
        )
        let withoutIgnoring = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 2,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false, ignoreEmptyRows: false
        )
        let gridWithBlank = try PivotTableStore.build(sheet: sheet, definition: withoutIgnoring)
        XCTAssertEqual(gridWithBlank.rows.count, 4, "1 header + East + West + the blank-key group")

        var ignoring = withoutIgnoring
        ignoring.ignoreEmptyRows = true
        let gridWithoutBlank = try PivotTableStore.build(sheet: sheet, definition: ignoring)
        XCTAssertEqual(gridWithoutBlank.rows.count, 3, "1 header + East + West - the blank row never enters grouping")
        XCTAssertEqual(gridWithoutBlank.rows[1], [.text("East"), .number(10)])
        XCTAssertEqual(gridWithoutBlank.rows[2], [.text("West"), .number(20)])
    }

    // MARK: - Error paths (trap guards)

    func testBuildThrowsUnknownFieldWhenAFieldNamesNoMatchingColumn() {
        let sheet = makeSheet(columns: ["Region", "Revenue"], rows: [[.text("A"), .number(1)]])
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 0,
            fields: [
                SheetPivotField(fieldName: "Bogus", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ]
        )
        XCTAssertThrowsError(try PivotTableStore.build(sheet: sheet, definition: definition)) { error in
            XCTAssertEqual(error as? PivotTableStoreError, .unknownField("Bogus"))
        }
    }

    func testBuildThrowsNoDataFieldsWhenNoFieldHasDataOrientation() {
        let sheet = makeSheet(columns: ["Region", "Revenue"], rows: [[.text("A"), .number(1)]])
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 0,
            fields: [SheetPivotField(fieldName: "Region", orientation: .row)]
        )
        XCTAssertThrowsError(try PivotTableStore.build(sheet: sheet, definition: definition)) { error in
            XCTAssertEqual(error as? PivotTableStoreError, .noDataFields)
        }
    }

    func testBuildThrowsInvalidSourceRangeForANegativeCoordinate() {
        let sheet = makeSheet(columns: ["Region", "Revenue"], rows: [[.text("A"), .number(1)]])
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: -1, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 0,
            fields: [SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum)]
        )
        XCTAssertThrowsError(try PivotTableStore.build(sheet: sheet, definition: definition)) { error in
            XCTAssertEqual(error as? PivotTableStoreError, .invalidSourceRange)
        }
    }

    func testBuildThrowsFieldOutsideSourceRangeWhenAFieldColumnLiesOutsideTheSourceRectangle() {
        let sheet = makeSheet(
            columns: ["Region", "Revenue", "Extra"],
            rows: [[.text("A"), .number(1), .text("x")]]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 0, // "Extra" (col 2) is outside [0,1]
            fields: [
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
                SheetPivotField(fieldName: "Extra", orientation: .row),
            ]
        )
        XCTAssertThrowsError(try PivotTableStore.build(sheet: sheet, definition: definition)) { error in
            XCTAssertEqual(error as? PivotTableStoreError, .fieldOutsideSourceRange("Extra"))
        }
    }

    // MARK: - Determinism (doctrine rule 4)

    func testBuildIsDeterministicAcrossTwoIndependentRuns() throws {
        let sheet = regionRevenueSheet()
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 4,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ]
        )
        let first = try PivotTableStore.build(sheet: sheet, definition: definition)
        let second = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(first, second)
    }
}
