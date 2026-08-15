import XCTest
@testable import TesseraCore

/// `QueryEngine` (P1 1.10): sort, filter criteria, and autofilter for
/// the Sheets material. `SheetWorkbook`/`SheetStore` don't wire this
/// in yet - this ships and tests the model + pure algorithms
/// themselves, matching how `SheetValidationRule`/`SheetConditionalFormat`
/// shipped ahead of their own evaluation call sites.
final class QueryEngineTests: XCTestCase {

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return utcCalendar().date(from: comps)!
    }

    // MARK: - Mixed-type sort order

    /// One of each bucket, deliberately out of order and with two
    /// blanks and two entries per non-blank bucket so ties within a
    /// bucket exercise the real comparator, not just bucket placement.
    private func mixedColumn() -> [Int: CellValue] {
        [
            0: .text("banana"),
            1: .number(10),
            2: .empty,
            3: .checkbox(true),
            4: .error("#DIV/0!"),
            5: .number(2),
            6: .checkbox(false),
            7: .text("apple"),
            8: .empty,
            9: .error("#N/A"),
        ]
    }

    func testAscendingMixedTypeOrder() {
        let column = mixedColumn()
        let order = QueryEngine.sortedRowOrder(
            rowCount: column.count,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)]
        ) { row, _ in column[row]! }

        // numbers(2,10) < text(apple,banana) < logical(FALSE,TRUE) <
        // errors(#DIV/0!,#N/A) < blanks(original-index tie-break).
        XCTAssertEqual(order, [5, 1, 7, 0, 6, 3, 4, 9, 2, 8])
    }

    func testDescendingMixedTypeOrderBlanksStillLast() {
        let column = mixedColumn()
        let order = QueryEngine.sortedRowOrder(
            rowCount: column.count,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: false)]
        ) { row, _ in column[row]! }

        // Descending reverses every non-blank bucket AND the bucket
        // order itself (errors < logical < text < numbers) - but
        // blanks stay last regardless, still tie-broken by original index.
        XCTAssertEqual(order, [9, 4, 3, 6, 0, 7, 1, 5, 2, 8])
        XCTAssertEqual(Array(order.suffix(2)), [2, 8], "blanks must sort last even descending")
    }

    func testEmptyConditionsAndEmptyGridAreNoOps() {
        XCTAssertEqual(QueryEngine.sortedRowOrder(rowCount: 5, conditions: []) { _, _ in .empty }, [0, 1, 2, 3, 4])
        XCTAssertEqual(QueryEngine.sortedRowOrder(rowCount: 0, conditions: [SheetSortCondition(columnIndex: 0)]) { _, _ in .empty }, [])
    }

    // MARK: - Multi-key stable sort

    func testMultiKeySortTieBreaksOnSecondaryKeyThenOriginalIndex() {
        // Column 0: department (ties on purpose). Column 1: salary
        // (ties on purpose, once). Row 4 and row 5 tie on BOTH keys -
        // the explicit original-index tie-break must keep 4 before 5.
        let department: [Int: CellValue] = [
            0: .text("Eng"), 1: .text("Sales"), 2: .text("Eng"),
            3: .text("Sales"), 4: .text("Eng"), 5: .text("Eng"),
        ]
        let salary: [Int: CellValue] = [
            0: .number(100), 1: .number(50), 2: .number(200),
            3: .number(50), 4: .number(100), 5: .number(100),
        ]
        let order = QueryEngine.sortedRowOrder(
            rowCount: 6,
            conditions: [
                SheetSortCondition(columnIndex: 0, ascending: true),
                SheetSortCondition(columnIndex: 1, ascending: true),
            ]
        ) { row, col in col == 0 ? department[row]! : salary[row]! }

        // Eng group ascending by salary: [0,4,5] tie at 100 (index
        // tie-break keeps 0 then 4 then 5), then 2 at 200. Sales group:
        // [1,3] tie at 50 (index tie-break keeps 1 then 3).
        XCTAssertEqual(order, [0, 4, 5, 2, 1, 3])
    }

    func testResortingAlreadySortedRangeIsNoOp() {
        let values: [Int: CellValue] = [0: .number(1), 1: .number(2), 2: .number(3)]
        let order = QueryEngine.sortedRowOrder(
            rowCount: 3,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)]
        ) { row, _ in values[row]! }
        XCTAssertEqual(order, [0, 1, 2])
    }

    func testSortMutationReturnsSortedReceiptOutcome() {
        let values: [Int: CellValue] = [0: .number(2), 1: .number(1)]
        let (order, outcome) = QueryEngine.sort(
            rowCount: 2,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)]
        ) { row, _ in values[row]! }

        XCTAssertEqual(order, [1, 0])
        XCTAssertEqual(outcome.receiptType, QueryEngine.ReceiptType.sorted)
        XCTAssertEqual(outcome.receiptType, "sheet_sorted")
        XCTAssertEqual(outcome.payload["rowCount"]?.numberValue, 2)
        XCTAssertEqual(outcome.payload["keyCount"]?.numberValue, 1)
    }

    // MARK: - .valueSet (OR + blanks)

    func testValueSetMatchesOnlyListedValuesAndRespectsIncludeBlanks() {
        let criteria = SheetFilterCriteria(kind: .valueSet, values: ["A", "B"], includeBlanks: true)
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .text("A"), displayText: "A"),
            SheetFilterRowInput(row: 1, value: .text("C"), displayText: "C"),
            SheetFilterRowInput(row: 2, value: .empty, displayText: ""),
        ]
        // Row 1 ("C") is the only one that fails: not in the value
        // set, and not blank.
        XCTAssertEqual(criteria.rowsFailing(in: rows), [1])
    }

    func testValueSetWithoutIncludeBlanksHidesBlankRows() {
        let criteria = SheetFilterCriteria(kind: .valueSet, values: ["A"], includeBlanks: false)
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .text("A"), displayText: "A"),
            SheetFilterRowInput(row: 1, value: .empty, displayText: ""),
        ]
        XCTAssertEqual(criteria.rowsFailing(in: rows), [1])
    }

    // MARK: - .custom (wildcards ride equal/notEqual; AND/OR)

    func testCustomEqualWildcardGlob() {
        let criteria = SheetFilterCriteria(kind: .custom, firstOperator: .equal, firstValue: "A*e")
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .text("Apple"), displayText: "Apple"),
            SheetFilterRowInput(row: 1, value: .text("Banana"), displayText: "Banana"),
            SheetFilterRowInput(row: 2, value: .text("Ace"), displayText: "Ace"),
        ]
        // "A*e" matches "Apple" and "Ace" (case-insensitive), not "Banana".
        XCTAssertEqual(criteria.rowsFailing(in: rows), [1])
    }

    func testCustomNotEqualWildcardSingleChar() {
        let criteria = SheetFilterCriteria(kind: .custom, firstOperator: .notEqual, firstValue: "ca?")
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .text("cat"), displayText: "cat"),
            SheetFilterRowInput(row: 1, value: .text("car"), displayText: "car"),
            SheetFilterRowInput(row: 2, value: .text("cart"), displayText: "cart"),
        ]
        // notEqual "ca?" fails for anything matching the glob (cat,
        // car); "cart" (4 chars) doesn't match "ca?" so it passes.
        XCTAssertEqual(criteria.rowsFailing(in: rows), [0, 1])
    }

    func testCustomPairAndRequiresBothPredicates() {
        let criteria = SheetFilterCriteria(
            kind: .custom,
            firstOperator: .greaterThanOrEqual, firstValue: "10",
            join: .and,
            secondOperator: .lessThanOrEqual, secondValue: "20"
        )
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .number(15), displayText: "15"),
            SheetFilterRowInput(row: 1, value: .number(5), displayText: "5"),
            SheetFilterRowInput(row: 2, value: .number(25), displayText: "25"),
        ]
        XCTAssertEqual(criteria.rowsFailing(in: rows), [1, 2])
    }

    func testCustomPairOrRequiresEitherPredicate() {
        let criteria = SheetFilterCriteria(
            kind: .custom,
            firstOperator: .lessThan, firstValue: "10",
            join: .or,
            secondOperator: .greaterThan, secondValue: "20"
        )
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .number(5), displayText: "5"),
            SheetFilterRowInput(row: 1, value: .number(15), displayText: "15"),
            SheetFilterRowInput(row: 2, value: .number(25), displayText: "25"),
        ]
        XCTAssertEqual(criteria.rowsFailing(in: rows), [1])
    }

    // MARK: - .top (top10/percent)

    func testTopNKeepsAllTiedAtTheCutoff() {
        let criteria = SheetFilterCriteria(kind: .top, topDirection: .top, topIsPercent: false, topCount: 3)
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .number(10), displayText: "10"),
            SheetFilterRowInput(row: 1, value: .number(10), displayText: "10"),
            SheetFilterRowInput(row: 2, value: .number(10), displayText: "10"),
            SheetFilterRowInput(row: 3, value: .number(5), displayText: "5"),
            SheetFilterRowInput(row: 4, value: .number(1), displayText: "1"),
        ]
        // "Top 3" over three tied 10s and two smaller values keeps all
        // three 10s (cutoff-based, not a fixed-size head).
        XCTAssertEqual(criteria.rowsFailing(in: rows), [3, 4])
    }

    func testBottomPercentRoundsUp() {
        let criteria = SheetFilterCriteria(kind: .top, topDirection: .bottom, topIsPercent: true, topCount: 40)
        let rows: [SheetFilterRowInput] = (0..<5).map {
            SheetFilterRowInput(row: $0, value: .number(Double($0)), displayText: "\($0)")
        }
        // 40% of 5 = 2 -> the two smallest (0, 1) pass; 2,3,4 fail.
        XCTAssertEqual(criteria.rowsFailing(in: rows), [2, 3, 4])
    }

    func testTopFiltersNonNumericRowsAlwaysFail() {
        let criteria = SheetFilterCriteria(kind: .top, topDirection: .top, topIsPercent: false, topCount: 5)
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .number(1), displayText: "1"),
            SheetFilterRowInput(row: 1, value: .text("n/a"), displayText: "n/a"),
        ]
        XCTAssertEqual(criteria.rowsFailing(in: rows), [1])
    }

    // MARK: - .dynamic (dated buckets)

    func testDynamicRecurringMonthMatchesAcrossYears() {
        let criteria = SheetFilterCriteria(kind: .dynamic, dynamicPeriod: .month3)
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .date(Self.utcDate(2023, 3, 15)), displayText: ""),
            SheetFilterRowInput(row: 1, value: .date(Self.utcDate(2024, 3, 1)), displayText: ""),
            SheetFilterRowInput(row: 2, value: .date(Self.utcDate(2024, 4, 1)), displayText: ""),
        ]
        // March in any year passes; April fails.
        XCTAssertEqual(criteria.rowsFailing(in: rows), [2])
    }

    func testDynamicThisMonthIsRelativeToReferenceDate() {
        let criteria = SheetFilterCriteria(kind: .dynamic, dynamicPeriod: .thisMonth)
        let referenceDate = Self.utcDate(2024, 6, 15)
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .date(Self.utcDate(2024, 6, 1)), displayText: ""),
            SheetFilterRowInput(row: 1, value: .date(Self.utcDate(2024, 6, 30)), displayText: ""),
            SheetFilterRowInput(row: 2, value: .date(Self.utcDate(2024, 7, 1)), displayText: ""),
            SheetFilterRowInput(row: 3, value: .date(Self.utcDate(2024, 5, 31)), displayText: ""),
        ]
        XCTAssertEqual(criteria.rowsFailing(in: rows, referenceDate: referenceDate), [2, 3])
    }

    // MARK: - .color

    func testColorCriterionMatchesFillOrFont() {
        let fillCriteria = SheetFilterCriteria(kind: .color, colorHex: "#FF0000", colorIsFill: true)
        let redFill = SheetCellFormat(fillHex: "#FF0000")
        let blueFill = SheetCellFormat(fillHex: "#0000FF")
        let rows: [SheetFilterRowInput] = [
            SheetFilterRowInput(row: 0, value: .text("x"), displayText: "x", format: redFill),
            SheetFilterRowInput(row: 1, value: .text("y"), displayText: "y", format: blueFill),
            SheetFilterRowInput(row: 2, value: .text("z"), displayText: "z", format: .standard),
        ]
        XCTAssertEqual(fillCriteria.rowsFailing(in: rows), [1, 2])
    }

    // MARK: - applyFilter / clearFilter (mutation outcomes)

    func testApplyFilterUnionsFailuresAcrossColumnsAndReturnsOutcome() {
        // Column 0 hides row 1 (not "A"); column 1 hides row 2 (< 10).
        let colA: [Int: CellValue] = [0: .text("A"), 1: .text("B"), 2: .text("A")]
        let colB: [Int: CellValue] = [0: .number(10), 1: .number(10), 2: .number(1)]
        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["A"])),
            SheetFilterColumn(columnIndex: 1, criteria: SheetFilterCriteria(
                kind: .custom, firstOperator: .greaterThanOrEqual, firstValue: "10"
            )),
        ]
        let (state, outcome) = QueryEngine.applyFilter(
            rowCount: 3,
            criteria: criteria,
            value: { row, col in col == 0 ? colA[row]! : colB[row]! },
            displayText: { row, col in col == 0 ? colA[row]!.textForDisplayTest : colB[row]!.textForDisplayTest }
        )

        XCTAssertEqual(state.hiddenRows, [1, 2])
        XCTAssertEqual(state.criteria, criteria)
        XCTAssertEqual(outcome.receiptType, "sheet_filter_applied")
        XCTAssertEqual(outcome.payload["hiddenRowCount"]?.numberValue, 2)
    }

    func testClearFilterReturnsEmptyStateAndOutcomeSizedFromPrevious() {
        let previous = SheetFilterState(
            criteria: [SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["A"]))],
            hiddenRows: [1, 2, 3]
        )
        let (state, outcome) = QueryEngine.clearFilter(previousState: previous)

        XCTAssertEqual(state, SheetFilterState.empty)
        XCTAssertTrue(state.criteria.isEmpty)
        XCTAssertTrue(state.hiddenRows.isEmpty)
        XCTAssertEqual(outcome.receiptType, "sheet_filter_cleared")
        XCTAssertEqual(outcome.payload["clearedColumnCount"]?.numberValue, 1)
        XCTAssertEqual(outcome.payload["unhiddenRowCount"]?.numberValue, 3)
    }

    // MARK: - Round trip: criteria and hidden-row state are independent

    /// The load-bearing test for this component's central design law:
    /// criteria are UI state, hidden rows are truth, and they can
    /// legitimately disagree (an imported file's criteria and its
    /// `row@hidden` markers were written by two different code paths).
    /// Construct exactly that disagreement - criteria that would hide
    /// row 0 if evaluated fresh, but a persisted `hiddenRows` that
    /// hides row 1 instead - and prove a JSON round trip preserves the
    /// disagreement rather than silently reconciling it.
    func testFilterStateRoundTripPreservesCriteriaAndHiddenRowsIndependently() throws {
        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["A"])),
        ]
        // If this criteria were re-evaluated against a column where
        // only row 0 is "A", it would hide every OTHER row - not row 1
        // specifically. `hiddenRows` here is deliberately something
        // evaluation would never produce, so an accidental
        // re-derivation on decode would be caught by the assertions
        // below.
        let original = SheetFilterState(criteria: criteria, hiddenRows: [1])

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SheetFilterState.self, from: data)

        XCTAssertEqual(restored.criteria, criteria)
        XCTAssertEqual(restored.hiddenRows, [1])
        XCTAssertEqual(restored, original)
    }

    func testCriteriaRoundTripsForEveryKind() throws {
        let samples: [SheetFilterCriteria] = [
            SheetFilterCriteria(kind: .valueSet, values: ["A", "B"], includeBlanks: true),
            SheetFilterCriteria(kind: .custom, firstOperator: .equal, firstValue: "A*", join: .or, secondOperator: .equal, secondValue: "B*"),
            SheetFilterCriteria(kind: .top, topDirection: .bottom, topIsPercent: true, topCount: 25),
            SheetFilterCriteria(kind: .dynamic, dynamicPeriod: .lastQuarter),
            SheetFilterCriteria(kind: .color, colorHex: "#00FF00", colorIsFill: false),
        ]
        for sample in samples {
            let data = try JSONEncoder().encode(sample)
            let restored = try JSONDecoder().decode(SheetFilterCriteria.self, from: data)
            XCTAssertEqual(restored, sample)
        }
    }
}

private extension CellValue {
    /// Test-only convenience: the plain-text form of a couple of
    /// `CellValue` cases, standing in for the grid's real display-text
    /// projection (which lives on `Sheet`/`SheetValueRenderer`, not
    /// `CellValue` itself).
    var textForDisplayTest: String {
        switch self {
        case .text(let s): return s
        case .number(let n): return String(n)
        default: return ""
        }
    }
}
