import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.10 QueryEngine": "sort = ordered
// multi-key sortCondition list, stable (LO's explicit original-index
// tie-break), mixed-type order numbers < text < logical < error < blanks
// (blanks always last, both directions)... criteria are UI state, hidden
// rows are truth (they can disagree in imported files; never re-evaluate
// on load); wildcards ride equal/notEqual. Receipts: sheet_sorted /
// sheet_filter_applied / sheet_filter_cleared (one per user action).
// Test: multi-key stable sort matches the mixed-type order table;
// round-trip preserves criteria AND hidden-row state independently."
final class QueryEngineTests: DoctrineTestCase {

    // MARK: - Mixed-type sort order (hand-computed fixture, rule 9)

    /// One column exercising every bucket in the documented order table:
    /// numbers < text < logical < error < blanks. Row indices below are
    /// the INPUT order; `expectedAscending`/`expectedDescending` are
    /// hand-computed directly from the contract's bucket table, not read
    /// off whatever `QueryEngine` currently outputs.
    private func mixedTypeColumn() -> [CellValue] {
        [
            .number(10),       // row 0
            .number(-5),       // row 1
            .text("banana"),   // row 2
            .text("apple"),    // row 3
            .checkbox(false),  // row 4
            .checkbox(true),   // row 5
            .error("#REF!"),   // row 6
            .empty,            // row 7
        ]
    }

    func testSingleKeyAscendingSortMatchesDocumentedMixedTypeBucketOrder() {
        let column = mixedTypeColumn()
        let order = QueryEngine.sortedRowOrder(
            rowCount: column.count,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)],
            cellValue: { row, _ in column[row] }
        )
        // numbers (ascending) < text (ascending) < logical (FALSE<TRUE) < error < blanks
        XCTAssertEqual(order, [1, 0, 3, 2, 4, 5, 6, 7])
    }

    func testSingleKeyDescendingSortFlipsEveryBucketExceptBlanksWhichStayLast() {
        let column = mixedTypeColumn()
        let order = QueryEngine.sortedRowOrder(
            rowCount: column.count,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: false)],
            cellValue: { row, _ in column[row] }
        )
        // sota-calc-report.md: "descending reverses everything EXCEPT
        // blanks, which sort last in both directions" - the BUCKET
        // order itself reverses (error < logical < text < numbers),
        // and each bucket's own internal order reverses too; only
        // blanks stay pinned to the end.
        // error(row6) < logical desc [true(5),false(4)]
        //   < text desc [banana(2),apple(3)] < number desc [10(0),-5(1)]
        //   < blank(7)
        XCTAssertEqual(order, [6, 5, 4, 2, 3, 0, 1, 7])
    }

    func testDatesSortInTheNumberBucketAlongsideNumbers() {
        // "`.date` rides with `.number`" per QueryEngine.swift's own
        // sortRank doc comment - restating the same documented mixed-type
        // table (numbers < text), not a separate behavior.
        let column: [CellValue] = [
            .date(Date(timeIntervalSince1970: 1000)),
            .number(5),
            .text("z"),
        ]
        let order = QueryEngine.sortedRowOrder(
            rowCount: column.count,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)],
            cellValue: { row, _ in column[row] }
        )
        // Both number-bucket rows (0 and 1) precede the text row (2).
        XCTAssertEqual(Set(order[0...1]), Set([0, 1]))
        XCTAssertEqual(order[2], 2)
    }

    // MARK: - Multi-key stable sort with explicit original-index tie-break

    func testMultiKeySortBreaksTiesOnTheSecondKey() {
        // col0 ties between rows 0 and 1; col1 breaks the tie ascending.
        let col0: [CellValue] = [.number(1), .number(1), .number(0)]
        let col1: [CellValue] = [.text("b"), .text("a"), .text("z")]
        let order = QueryEngine.sortedRowOrder(
            rowCount: 3,
            conditions: [
                SheetSortCondition(columnIndex: 0, ascending: true),
                SheetSortCondition(columnIndex: 1, ascending: true),
            ],
            cellValue: { row, col in col == 0 ? col0[row] : col1[row] }
        )
        XCTAssertEqual(order, [2, 1, 0]) // row2(0) < row1(1,"a") < row0(1,"b")
    }

    func testFullyTiedRowsFallBackToOriginalRowIndexStableTieBreak() {
        let column: [CellValue] = [.number(1), .number(1), .number(1)]
        let order = QueryEngine.sortedRowOrder(
            rowCount: 3,
            conditions: [SheetSortCondition(columnIndex: 0, ascending: true)],
            cellValue: { row, _ in column[row] }
        )
        XCTAssertEqual(order, [0, 1, 2], "LO's explicit original-index tie-break: fully-tied rows keep input order")
    }

    // MARK: - No-op cases

    func testEmptyConditionsListIsANoOp() {
        let order = QueryEngine.sortedRowOrder(
            rowCount: 4, conditions: [], cellValue: { _, _ in .number(0) }
        )
        XCTAssertEqual(order, [0, 1, 2, 3])
    }

    /// Cheap property test (rule 9): sorting data that is already in
    /// sorted order is idempotent - re-sorting the OUTPUT produces the
    /// identity permutation. This is exactly what "stable" plus
    /// "original-index tie-break" together guarantee.
    func testSortingAlreadySortedDataIsIdempotent() {
        let column: [CellValue] = [.number(-5), .number(0), .number(3), .number(3), .number(10)]
        let conditions = [SheetSortCondition(columnIndex: 0, ascending: true)]
        let order = QueryEngine.sortedRowOrder(rowCount: column.count, conditions: conditions, cellValue: { row, _ in column[row] })
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        let reordered = order.map { column[$0] }
        let secondPass = QueryEngine.sortedRowOrder(rowCount: reordered.count, conditions: conditions, cellValue: { row, _ in reordered[row] })
        XCTAssertEqual(secondPass, [0, 1, 2, 3, 4])
    }

    // MARK: - sort() mutation outcome (receipt shape)

    func testSortProducesSheetSortedReceiptShapedOutcome() {
        let column: [CellValue] = [.number(3), .number(1), .number(2)]
        let conditions = [SheetSortCondition(columnIndex: 0, ascending: true)]
        let (order, outcome) = QueryEngine.sort(rowCount: 3, conditions: conditions, cellValue: { row, _ in column[row] })
        XCTAssertEqual(order, [1, 2, 0])
        XCTAssertEqual(outcome.receiptType, "sheet_sorted")
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.sorted.rawValue, "must match SheetReceiptType.sorted verbatim")
        XCTAssertEqual(outcome.payload["rowCount"], .number(3))
        XCTAssertEqual(outcome.payload["keyCount"], .number(1))
    }

    // MARK: - Wildcards ride equal/notEqual (custom criterion)

    private func rows(_ texts: [String]) -> [SheetFilterRowInput] {
        texts.enumerated().map { i, t in
            SheetFilterRowInput(row: i, value: .text(t), displayText: t)
        }
    }

    func testWildcardEqualOperatorGlobMatchesDisplayText() {
        let criteria = SheetFilterCriteria(kind: .custom, firstOperator: .equal, firstValue: "b*")
        let failing = criteria.rowsFailing(in: rows(["banana", "apple", "berry"]))
        XCTAssertEqual(failing, [1]) // only "apple" fails a "b*" match
    }

    func testWildcardNotEqualOperatorExcludesGlobMatches() {
        let criteria = SheetFilterCriteria(kind: .custom, firstOperator: .notEqual, firstValue: "b*")
        let failing = criteria.rowsFailing(in: rows(["banana", "apple", "berry"]))
        XCTAssertEqual(failing, [0, 2]) // "banana"/"berry" fail a notEqual-to-"b*" test
    }

    func testWildcardQuestionMarkMatchesExactlyOneCharacter() {
        let criteria = SheetFilterCriteria(kind: .custom, firstOperator: .equal, firstValue: "b?t")
        let failing = criteria.rowsFailing(in: rows(["bat", "boot", "bt"]))
        XCTAssertEqual(failing, [1, 2]) // "boot" (2 chars) and "bt" (0 chars) fail; "bat" matches
    }

    // MARK: - applyFilter / clearFilter mutation outcomes

    func testApplyFilterHidesRowsFailingAnyActiveColumnAndUnionsAcrossColumns() {
        // Column 0: value-set {"a"}. Column 1: custom >5. A row is
        // hidden when it fails ANY active column (AND together).
        let colA = ["a", "b", "a", "b"]
        let colB: [Double] = [10, 10, 1, 1]
        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["a"])),
            SheetFilterColumn(columnIndex: 1, criteria: SheetFilterCriteria(kind: .custom, firstOperator: .greaterThan, firstValue: "5")),
        ]
        let (state, outcome) = QueryEngine.applyFilter(
            rowCount: 4,
            criteria: criteria,
            value: { row, col in col == 0 ? .text(colA[row]) : .number(colB[row]) },
            displayText: { row, col in col == 0 ? colA[row] : String(colB[row]) }
        )
        // row0: a & 10>5 -> passes both -> visible
        // row1: b (fails col0) -> hidden
        // row2: a & 1>5 fails col1 -> hidden
        // row3: b & 1>5 fails both -> hidden
        XCTAssertEqual(state.hiddenRows, [1, 2, 3])
        XCTAssertEqual(state.criteria, criteria)
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.filterApplied.rawValue)
        XCTAssertEqual(outcome.payload["hiddenRowCount"], .number(3))
    }

    func testClearFilterAlwaysReturnsEmptyStateRegardlessOfPreviousState() {
        let previous = SheetFilterState(
            criteria: [SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet))],
            hiddenRows: [1, 2, 3]
        )
        let (state, outcome) = QueryEngine.clearFilter(previousState: previous)
        XCTAssertEqual(state, .empty)
        XCTAssertTrue(state.criteria.isEmpty)
        XCTAssertTrue(state.hiddenRows.isEmpty)
        XCTAssertEqual(outcome.receiptType, SheetReceiptType.filterCleared.rawValue)
        XCTAssertEqual(outcome.payload["clearedColumnCount"], .number(1))
        XCTAssertEqual(outcome.payload["unhiddenRowCount"], .number(3))
    }

    // MARK: - Round-trip: criteria and hiddenRows are INDEPENDENT fields

    /// "criteria are UI state, hidden rows are truth (they can disagree
    /// in imported files; the engine never re-evaluates criteria on
    /// load - only a user action does)." A round trip must preserve
    /// BOTH fields even when they are constructed to actively disagree
    /// with each other (criteria that would compute a completely
    /// different hidden set than what is actually stored).
    func testRoundTripPreservesCriteriaAndHiddenRowsAsIndependentDisagreeingFields() throws {
        let criteria = [
            SheetFilterColumn(columnIndex: 0, criteria: SheetFilterCriteria(kind: .valueSet, values: ["only-this-value"])),
        ]
        // Deliberately unrelated to what the criteria above would ever
        // compute - simulating an imported file where hidden rows and
        // criteria disagree.
        let disagreeingHiddenRows: Set<Int> = [42, 100, 7]
        let original = SheetFilterState(criteria: criteria, hiddenRows: disagreeingHiddenRows)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SheetFilterState.self, from: data)

        XCTAssertEqual(decoded.criteria, criteria)
        XCTAssertEqual(decoded.hiddenRows, disagreeingHiddenRows)
        XCTAssertEqual(decoded, original)
    }

    func testSheetFilterStateEncodeDecodeIdentity() throws {
        let original = SheetFilterState(
            criteria: [
                SheetFilterColumn(columnIndex: 1, criteria: SheetFilterCriteria(
                    kind: .top, topDirection: .top, topIsPercent: false, topCount: 5
                )),
            ],
            hiddenRows: [3, 9, 12]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetFilterState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Sheet.effectiveFilterState "nil means none" convention

    func testSheetWithNoFilterStateReportsEmptyEffectiveFilterState() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        XCTAssertEqual(sheet.effectiveFilterState, .empty)
    }
}
