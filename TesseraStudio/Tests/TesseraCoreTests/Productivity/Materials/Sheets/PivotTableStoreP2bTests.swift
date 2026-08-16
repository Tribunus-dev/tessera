import XCTest
@testable import TesseraCore

// MARK: - PivotTableStoreP2bTests
//
// Contract: sota-p2-core-report.md section 2.2 ("PivotTableStore -
// Calc"), P2b slice ("groups (step 4), sort/autoShow/reference modes,
// outline/compact + styleInfo, fods table:data-pilot-table round-trip
// both directions") plus this track's wave brief (2.2b items a-f) and
// PivotTableStore.swift's own type-header doc comment for the exact
// scope calls this file exercises against (subtotal rows are ROW-AXIS
// ONLY; `.compact` is a table-wide effective mode read off
// `rowFields.first`; `.outline`/`.compact` do not reproduce Excel's
// "outer group gets its own dedicated row" nuance).
//
// P2a's own PivotTableStoreTests.swift is untouched and still exercises
// the tabular + grand-total pipeline exactly as before - this file adds
// P2b-only coverage, never re-derives what that file already pins.

final class PivotTableStoreP2bTests: DoctrineTestCase {

    // MARK: - Fixture builders (mirrors PivotTableStoreTests' own helpers)

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

    // MARK: - Grouping: numeric

    /// Hand-computed per `numericGroupLabel`'s own documented formula:
    /// bucket = [start + k*step, start + (k+1)*step).
    func testNumericGroupSpecBucketsValuesIntoStepRangesAndAggregatesPerBucket() throws {
        let sheet = makeSheet(
            columns: ["Score", "Count"],
            rows: [
                [.number(4), .number(1)],   // < 10 bucket
                [.number(12), .number(1)],  // 10-20
                [.number(18), .number(1)],  // 10-20
                [.number(25), .number(1)],  // 20-30
                [.number(99), .number(1)],  // >= 30 (end) -> "30+"
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 4,
            fields: [
                SheetPivotField(fieldName: "Score", orientation: .row, group: .numeric(start: 10, end: 30, step: 10)),
                SheetPivotField(fieldName: "Count", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)

        XCTAssertEqual(grid.rows.count, 5, "1 header + 4 distinct buckets (<10, 10-20, 20-30, 30+)")
        // Compared as a set (not an ordered array): the buckets' text
        // sort order (QueryEngine's mixed-type order over the label
        // STRINGS) is a real, deterministic property this test doesn't
        // need to also pin - `testGroupKeySortUsesQueryEnginesMixedTypeOrder`
        // (PivotTableStoreTests.swift, P2a) already covers that
        // machinery directly.
        let byLabel = Dictionary(uniqueKeysWithValues: grid.rows.dropFirst().map { ($0[0], number($0[1])) })
        XCTAssertEqual(Set(byLabel.keys), [.text("< 10"), .text("10-20"), .text("20-30"), .text("30+")])
        XCTAssertEqual(byLabel[.text("10-20")], 2, "12 and 18 both land in the 10-20 bucket")
        XCTAssertEqual(byLabel[.text("< 10")], 1)
        XCTAssertEqual(byLabel[.text("20-30")], 1)
        XCTAssertEqual(byLabel[.text("30+")], 1)
    }

    // MARK: - Grouping: date

    func testDateGroupSpecCombinesSelectedGranularitiesIntoOneLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let d1 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!
        let d2 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))!
        let d3 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!

        let sheet = makeSheet(
            columns: ["Date", "Amount"],
            rows: [
                [.date(d1), .number(10)],
                [.date(d2), .number(20)],
                [.date(d3), .number(30)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 2,
            fields: [
                SheetPivotField(fieldName: "Date", orientation: .row, group: .date(by: [.years, .months])),
                SheetPivotField(fieldName: "Amount", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)

        XCTAssertEqual(grid.rows.count, 3, "1 header + 2 distinct year-month groups (2026 Jan, 2026 Aug)")
        let labels = Set(grid.rows.dropFirst().map { $0[0] })
        XCTAssertEqual(labels, [.text("2026 Jan"), .text("2026 Aug")])
        // d1 and d2 (both August) sum to 30.
        let augustRow = grid.rows.first { $0[0] == .text("2026 Aug") }!
        XCTAssertEqual(number(augustRow[1]), 30)
    }

    // MARK: - Grouping: explicit members

    func testMembersGroupSpecCollectsDeclaredMembersAndLeavesOthersUngrouped() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [
                [.text("East"), .number(10)],
                [.text("West"), .number(20)],
                [.text("North"), .number(30)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 2,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    group: .members([PivotMemberGroup(name: "Coastal", members: ["East", "West"])])
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)

        XCTAssertEqual(grid.rows.count, 3, "1 header + \"Coastal\" (East+West merged) + ungrouped \"North\"")
        let byLabel = Dictionary(uniqueKeysWithValues: grid.rows.dropFirst().map { ($0[0], $0[1]) })
        XCTAssertEqual(number(byLabel[.text("Coastal")]!), 30, "East (10) + West (20)")
        XCTAssertEqual(number(byLabel[.text("North")]!), 30, "ungrouped member passes through at its own raw value")
    }

    // MARK: - sort: .data mode

    func testDataSortModeOrdersMembersByADataFieldsAggregateNotByName() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [
                [.text("Alpha"), .number(100)],
                [.text("Zeta"), .number(5)],
                [.text("Beta"), .number(50)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 2,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    sort: SheetPivotFieldSort(mode: .data, ascending: false, dataFieldName: "Revenue")
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        // Descending by Revenue: Alpha(100), Beta(50), Zeta(5) - NOT
        // alphabetical (which would be Alpha, Beta, Zeta by coincidence
        // here, so also assert the actual numbers to prove it's really
        // value-driven, not accidentally name-sorted).
        XCTAssertEqual(grid.rows[1][0], .text("Alpha"))
        XCTAssertEqual(grid.rows[2][0], .text("Beta"))
        XCTAssertEqual(grid.rows[3][0], .text("Zeta"))
        XCTAssertEqual(number(grid.rows[1][1]), 100)
        XCTAssertEqual(number(grid.rows[3][1]), 5)
    }

    func testDataSortModeWithUnresolvableDataFieldNameFallsBackToNameOrderRatherThanDroppingRows() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [[.text("Zeta"), .number(1)], [.text("Alpha"), .number(2)]]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    sort: SheetPivotFieldSort(mode: .data, dataFieldName: "NoSuchField")
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(grid.rows.count, 3, "both rows still present - the fallback must not drop anything")
        XCTAssertEqual(grid.rows[1][0], .text("Alpha"), "falls back to name order ascending")
        XCTAssertEqual(grid.rows[2][0], .text("Zeta"))
    }

    // MARK: - sort: .manual mode

    func testManualSortModeOrdersByDeclaredMembersThenUndeclaredInDiscoveryOrder() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [
                [.text("Alpha"), .number(1)],
                [.text("Beta"), .number(2)],
                [.text("Gamma"), .number(3)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 2,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    members: [SheetPivotFieldMember(name: "Gamma"), SheetPivotFieldMember(name: "Alpha")],
                    sort: SheetPivotFieldSort(mode: .manual)
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(grid.rows[1][0], .text("Gamma"), "declared first in members")
        XCTAssertEqual(grid.rows[2][0], .text("Alpha"), "declared second in members")
        XCTAssertEqual(grid.rows[3][0], .text("Beta"), "undeclared - falls after every declared member")
    }

    // MARK: - autoShow: reuses QueryEngine's landed top-N cutoff

    func testAutoShowTopTwoKeepsOnlyTheTwoHighestRankedMembersByTheNamedDataField() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [
                [.text("A"), .number(10)],
                [.text("B"), .number(50)],
                [.text("C"), .number(30)],
                [.text("D"), .number(5)],
            ]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 3,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    autoShow: SheetPivotFieldAutoShow(direction: .top, itemCount: 2, dataFieldName: "Revenue")
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        let kept = Set(grid.rows.dropFirst().map { $0[0] })
        XCTAssertEqual(kept, [.text("B"), .text("C")], "top 2 by Revenue: B(50), C(30) - A and D cut")
    }

    func testAutoShowBottomOneKeepsOnlyTheLowestRankedMember() throws {
        let sheet = makeSheet(
            columns: ["Region", "Revenue"],
            rows: [[.text("A"), .number(10)], [.text("B"), .number(50)], [.text("C"), .number(5)]]
        )
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 2,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    autoShow: SheetPivotFieldAutoShow(direction: .bottom, itemCount: 1, dataFieldName: "Revenue")
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(grid.rows.count, 2, "1 header + the single lowest-ranked member")
        XCTAssertEqual(grid.rows[1][0], .text("C"))
    }

    func testAutoShowDisabledAppliesNoFilter() throws {
        let sheet = makeSheet(columns: ["Region", "Revenue"], rows: [[.text("A"), .number(1)], [.text("B"), .number(2)]])
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    autoShow: SheetPivotFieldAutoShow(enabled: false, itemCount: 1, dataFieldName: "Revenue")
                ),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(grid.rows.count, 3, "disabled autoShow - both members remain")
    }

    // MARK: - Per-field subtotal rows (row axis, gated on layout.mode != .tabular)

    private func regionRepRevenueSheet() -> Sheet {
        makeSheet(
            columns: ["Region", "Rep", "Revenue"],
            rows: [
                [.text("East"), .text("Ann"), .number(10)],
                [.text("East"), .text("Bob"), .number(20)],
                [.text("West"), .text("Ann"), .number(30)],
            ]
        )
    }

    func testTabularLayoutModeDefaultInsertsNoSubtotalRowsEvenThoughSubtotalAutoDefaultsToTrue() throws {
        // Backward-compat/scope-decision guard (findings file): P2a's
        // own tests never set `layout`, so `subtotalAuto`'s true
        // default must NOT start inserting rows under the P2a-default
        // `.tabular` mode - subtotal rows are gated on `.outline`/
        // `.compact` only.
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row), // subtotalAuto defaults true
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionRepRevenueSheet(), definition: definition)
        XCTAssertEqual(grid.rows.count, 4, "1 header + 3 data rows only - no subtotal rows under .tabular")
    }

    func testOutlineLayoutModeWithSubtotalAutoInsertsOneAutoSubtotalRowPerOuterGroup() throws {
        var definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row, layout: SheetPivotFieldLayout(mode: .outline)),
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        definition.fields[0].subtotalAuto = true
        let grid = try PivotTableStore.build(sheet: regionRepRevenueSheet(), definition: definition)

        // subtotalsAtTop defaults true: East's subtotal appears BEFORE
        // its Ann/Bob rows; West's subtotal appears before its own row.
        XCTAssertEqual(grid.rows.count, 6, "1 header + East Total + Ann + Bob + West Total + Ann")
        XCTAssertEqual(grid.rows[1][0], .text("East Total"))
        XCTAssertEqual(number(grid.rows[1][2]), 30, "East Total = Ann(10) + Bob(20)")
        // The FIRST occurrence of a row-combo is never blanked - the
        // blanking decision (`repeatItemLabels`) compares consecutive
        // ROW COMBOS in `rowCombos`' own order, independent of where a
        // subtotal row gets spliced into the OUTPUT; "East" is the
        // outermost group's very first combo, so it shows in full here
        // even though a subtotal row now precedes it.
        XCTAssertEqual(grid.rows[2][0], .text("East"))
        XCTAssertEqual(grid.rows[2][1], .text("Ann"))
        XCTAssertEqual(grid.rows[3][0], .empty, "SECOND combo in the East group - Region blanked as before")
        XCTAssertEqual(grid.rows[3][1], .text("Bob"))
        XCTAssertEqual(grid.rows[4][0], .text("West Total"))
        XCTAssertEqual(number(grid.rows[4][2]), 30)
    }

    func testOutlineLayoutModeSubtotalsAtBottomPlacesTheSubtotalRowAfterItsGroup() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    layout: SheetPivotFieldLayout(mode: .outline, subtotalsAtTop: false)
                ),
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionRepRevenueSheet(), definition: definition)
        XCTAssertEqual(grid.rows[1][1], .text("Ann"), "East's detail rows come FIRST")
        XCTAssertEqual(grid.rows[2][1], .text("Bob"))
        XCTAssertEqual(grid.rows[3][0], .text("East Total"), "subtotal AFTER its group")
    }

    func testExplicitSubtotalsListInsertsOneRowPerConfiguredFunctionLabeledByFunctionName() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    subtotals: [.sum, .max],
                    layout: SheetPivotFieldLayout(mode: .outline)
                ),
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionRepRevenueSheet(), definition: definition)
        // 1 header + (Sum + Max subtotal rows for East) + Ann + Bob + (Sum + Max for West) + Ann
        XCTAssertEqual(grid.rows.count, 8)
        XCTAssertEqual(grid.rows[1][0], .text("East Sum"))
        XCTAssertEqual(number(grid.rows[1][2]), 30)
        XCTAssertEqual(grid.rows[2][0], .text("East Max"))
        XCTAssertEqual(number(grid.rows[2][2]), 20, "max(10, 20)")
    }

    // MARK: - .compact layout mode collapses row-header columns to 1

    func testCompactLayoutModeOnTheOutermostRowFieldCollapsesEveryLevelIntoOneIndentedColumn() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2,
            fields: [
                // subtotalAuto: false isolates the compact-COLLAPSE
                // behavior this test targets from subtotal-ROW
                // insertion (a separate, already-covered behavior that
                // `.compact` ALSO gates on, same as `.outline` - see
                // `wantsSubtotal`'s `mode != .tabular` condition).
                SheetPivotField(fieldName: "Region", orientation: .row, subtotalAuto: false, layout: SheetPivotFieldLayout(mode: .compact)),
                SheetPivotField(fieldName: "Rep", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionRepRevenueSheet(), definition: definition)

        XCTAssertEqual(grid.headerColumnCount, 1, "compact mode: one row-labels column, not two")
        XCTAssertEqual(grid.columnCount, 2, "1 label column + 1 data column")
        XCTAssertEqual(grid.rows.count, 4, "1 header + 3 data rows - no subtotal rows (subtotalAuto: false)")
        XCTAssertEqual(grid.rows[1][0], .text("East Ann"), "first combo overall: both levels shown, joined")
        XCTAssertEqual(grid.rows[2][0], .text("  Bob"), "Region blanked (repeats East), Rep shown, indented one level")
        XCTAssertEqual(grid.rows[3][0], .text("West Ann"), "new outer group: both levels shown again")
    }

    // MARK: - reference (show values as) modes

    private func regionQuarterSheet() -> Sheet {
        makeSheet(
            columns: ["Region", "Quarter", "Revenue"],
            rows: [
                [.text("East"), .text("Q1"), .number(10)],
                [.text("East"), .text("Q2"), .number(20)],
                [.text("West"), .text("Q1"), .number(30)],
                [.text("West"), .text("Q2"), .number(40)],
            ]
        )
    }

    func testPercentOfGrandTotalDividesEveryCellByTheOverallSum() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 3,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Quarter", orientation: .column),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum, reference: .percentOfGrandTotal),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionQuarterSheet(), definition: definition)
        // headerRowCount == 2 here (one column field): body rows start
        // at index 2, matching P2a's own
        // testFullRowColumnLatticeWithGrandTotals convention exactly.
        XCTAssertEqual(grid.headerRowCount, 2)
        // Grand total = 100. East/Q1 = 10 -> 0.1.
        XCTAssertEqual(number(grid.rows[2][1]), 0.1, accuracy: 1e-9)
        XCTAssertEqual(number(grid.rows[2][2]), 0.2, accuracy: 1e-9, "East/Q2 = 20/100")
        XCTAssertEqual(number(grid.rows[3][2]), 0.4, accuracy: 1e-9, "West/Q2 = 40/100")
    }

    func testPercentOfRowTotalDividesEachCellByItsOwnRowsTotalAcrossAllColumns() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 3,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Quarter", orientation: .column),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum, reference: .percentOfRowTotal),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionQuarterSheet(), definition: definition)
        // East row total = 30: Q1=10/30, Q2=20/30. Body starts at index
        // 2 (headerRowCount == 2, one column field) - see the grand-
        // total test's own comment.
        XCTAssertEqual(number(grid.rows[2][1]), 10.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(number(grid.rows[2][2]), 20.0 / 30.0, accuracy: 1e-9)
    }

    func testPercentOfColumnTotalDividesEachCellByItsOwnColumnsTotalAcrossAllRows() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 3,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Quarter", orientation: .column),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum, reference: .percentOfColumnTotal),
            ],
            columnGrand: false, rowGrand: false
        )
        let grid = try PivotTableStore.build(sheet: regionQuarterSheet(), definition: definition)
        // Q1 column total = 40: East=10/40, West=30/40. Body starts at
        // index 2 (headerRowCount == 2, one column field).
        XCTAssertEqual(number(grid.rows[2][1]), 10.0 / 40.0, accuracy: 1e-9)
        XCTAssertEqual(number(grid.rows[3][1]), 30.0 / 40.0, accuracy: 1e-9)
    }

    func testReferenceNormalOrNilLeavesTheRawAggregateUntouchedMatchingP2aBehavior() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum, reference: .normal),
            ],
            columnGrand: false, rowGrand: false
        )
        let sheet = makeSheet(columns: ["Region", "Revenue"], rows: [[.text("A"), .number(42)]])
        let grid = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(number(grid.rows[1][1]), 42, "no transform for .normal")
    }

    // MARK: - Determinism (doctrine rule 4) with the full P2b field set engaged

    func testBuildWithGroupingSortAutoShowSubtotalsAndReferenceIsDeterministicAcrossTwoRuns() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 3,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    layout: SheetPivotFieldLayout(mode: .outline),
                    sort: SheetPivotFieldSort(mode: .data, ascending: false, dataFieldName: "Revenue"),
                    autoShow: SheetPivotFieldAutoShow(direction: .top, itemCount: 2, dataFieldName: "Revenue")
                ),
                SheetPivotField(fieldName: "Quarter", orientation: .column),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum, reference: .percentOfGrandTotal),
            ],
            columnGrand: true, rowGrand: true
        )
        let sheet = regionQuarterSheet()
        let first = try PivotTableStore.build(sheet: sheet, definition: definition)
        let second = try PivotTableStore.build(sheet: sheet, definition: definition)
        XCTAssertEqual(first, second)
    }
}
