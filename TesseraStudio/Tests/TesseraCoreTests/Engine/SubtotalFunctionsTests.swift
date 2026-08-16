import XCTest
@testable import TesseraCore

// Contract source: TesseraStudio/docs/.scratch/sota-p2-core-report.md
// section "2.7 Subtotals - Calc" (quoting Microsoft's own SUBTOTAL
// reference): "function_num 1-11 INCLUDE manually-hidden rows; 101-111
// EXCLUDE them; filter-hidden rows are excluded by BOTH bands; hidden
// COLUMNS are never excluded horizontally; a nested SUBTOTAL call is
// ignored by the outer one." Tests named in that section: "9 vs 109
// diverge exactly on a hand-built manually-hidden-row fixture; both 9
// and 109 exclude filter-hidden rows; a nested-SUBTOTAL-ignored-by-
// outer fixture."
//
// `SubtotalAggregator.evaluate(functionNum:rows:)` is pure and takes
// its `[SubtotalRowContext]` input directly - no engine, no sheet, no
// live-context wiring involved (see SubtotalFunctions.swift's header
// for the documented, still-open Evaluator-interception gap that live
// wiring would need; these tests exercise the aggregation law itself,
// independent of that gap).
final class SubtotalFunctionsTests: DoctrineTestCase {

    // MARK: - function_num 9 vs 109: manually-hidden rows

    /// [10, 20(manually hidden), 30]. 9 includes the hidden row (60);
    /// 109 excludes it (40) - the two must diverge by EXACTLY the
    /// hidden row's own value, not merely "be different."
    func testFunctionNum9And109DivergeExactlyOnAManuallyHiddenRow() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(10)),
            SubtotalRowContext(value: .number(20), isManuallyHidden: true),
            SubtotalRowContext(value: .number(30)),
        ]
        let including = SubtotalAggregator.evaluate(functionNum: 9, rows: rows)
        let excluding = SubtotalAggregator.evaluate(functionNum: 109, rows: rows)
        XCTAssertEqual(including, .number(60), "1-11 includes manually-hidden rows")
        XCTAssertEqual(excluding, .number(40), "101-111 excludes manually-hidden rows")
        guard case .number(let a) = including, case .number(let b) = excluding else {
            return XCTFail("expected both results to be numbers")
        }
        XCTAssertEqual(a - b, 20, "the two bands diverge by exactly the hidden row's own value")
    }

    /// A row with NO manually-hidden rows present must produce IDENTICAL
    /// results for the 9/109 pair - the bands only diverge when there is
    /// something to exclude.
    func testFunctionNum9And109AgreeWhenNoRowIsManuallyHidden() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(1)),
            SubtotalRowContext(value: .number(2)),
            SubtotalRowContext(value: .number(3)),
        ]
        XCTAssertEqual(
            SubtotalAggregator.evaluate(functionNum: 9, rows: rows),
            SubtotalAggregator.evaluate(functionNum: 109, rows: rows)
        )
    }

    // MARK: - Filter-hidden rows excluded by BOTH bands

    func testFilterHiddenRowsAreExcludedByBothFunctionNum9And109() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(10)),
            SubtotalRowContext(value: .number(20), isFilterHidden: true),
            SubtotalRowContext(value: .number(30)),
        ]
        let including = SubtotalAggregator.evaluate(functionNum: 9, rows: rows)
        let excluding = SubtotalAggregator.evaluate(functionNum: 109, rows: rows)
        XCTAssertEqual(including, .number(40), "filter-hidden excluded even under the 1-11 band")
        XCTAssertEqual(excluding, .number(40), "filter-hidden excluded under the 101-111 band too")
        XCTAssertEqual(including, excluding, "the law's one symmetric exclusion")
    }

    /// A row that is BOTH filter-hidden and manually-hidden is still
    /// excluded exactly once by 9 (via the filter-hidden path alone,
    /// since 9 does not otherwise exclude manually-hidden rows) and by
    /// 109 (via either path) - the two bands must still agree.
    func testRowHiddenByBothMechanismsIsExcludedByEitherBand() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(10)),
            SubtotalRowContext(value: .number(20), isManuallyHidden: true, isFilterHidden: true),
            SubtotalRowContext(value: .number(30)),
        ]
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 9, rows: rows), .number(40))
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 109, rows: rows), .number(40))
    }

    // MARK: - Nested SUBTOTAL ignored by the outer call

    /// [10, 999(nested SUBTOTAL cell), 30]. The nested cell's value is
    /// deliberately a large distractor - if it leaked into the
    /// aggregate, the assertion below would catch it immediately.
    /// Ignored REGARDLESS of function_num band (unconditional on
    /// manually-hidden/filter-hidden status).
    func testNestedSubtotalCellIsIgnoredByTheOuterCallUnderBothBands() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(10)),
            SubtotalRowContext(value: .number(999), isNestedSubtotal: true),
            SubtotalRowContext(value: .number(30)),
        ]
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 9, rows: rows), .number(40))
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 109, rows: rows), .number(40))
    }

    /// A nested SUBTOTAL cell that is ALSO (incidentally) manually
    /// hidden must still be excluded exactly once, not double-counted
    /// as "already excluded twice" in some way that would change the
    /// result - the excluded set is still just {that one row}.
    func testNestedSubtotalCellThatIsAlsoManuallyHiddenIsStillExcludedExactlyOnce() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(10)),
            SubtotalRowContext(value: .number(999), isManuallyHidden: true, isNestedSubtotal: true),
            SubtotalRowContext(value: .number(30)),
        ]
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 9, rows: rows), .number(40))
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 109, rows: rows), .number(40))
    }

    // MARK: - Hidden columns never excluded horizontally

    /// `SubtotalRowContext` carries no "isColumnHidden" flag at all -
    /// this is what makes horizontal exclusion structurally impossible,
    /// not merely untested. Demonstrated here with a 2-column-wide
    /// block flattened into row-context order (matching how
    /// `ColumnSlice.flattenArrays` - SubtotalFunctions.swift's generic
    /// dispatch path - would present a 2D range): nothing about which
    /// "column" a value nominally came from changes the aggregate.
    func testAllValuesInAWideRangeParticipateRegardlessOfNominalColumn() {
        // Row-major 2 rows x 2 cols: [[1,2],[3,4]] flattened.
        let rows: [SubtotalRowContext] = [1, 2, 3, 4].map { SubtotalRowContext(value: .number(Double($0))) }
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 9, rows: rows), .number(10))
    }

    // MARK: - Per-function_num correctness (all 11 kinds, 1-11 band)

    private func numberRows(_ values: [Double]) -> [SubtotalRowContext] {
        values.map { SubtotalRowContext(value: .number($0)) }
    }

    func testAverage() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 1, rows: numberRows([2, 4, 6])), .number(4))
    }

    func testCountCountsOnlyNumericCells() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(1)),
            SubtotalRowContext(value: .string("text")),
            SubtotalRowContext(value: .number(2)),
        ]
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 2, rows: rows), .number(2))
    }

    func testCountACountsEveryNonEmptyCellIncludingText() {
        let rows: [SubtotalRowContext] = [
            SubtotalRowContext(value: .number(1)),
            SubtotalRowContext(value: .string("text")),
            SubtotalRowContext(value: .null),
        ]
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 3, rows: rows), .number(2))
    }

    func testMax() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 4, rows: numberRows([3, 9, 1])), .number(9))
    }

    func testMin() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 5, rows: numberRows([3, 9, 1])), .number(1))
    }

    func testProduct() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 6, rows: numberRows([2, 3, 4])), .number(24))
    }

    func testSampleStandardDeviation() {
        // [2,4,6]: mean 4, sample variance ((4+0+4)/2)=4, stdev=2.
        guard case .number(let result) = SubtotalAggregator.evaluate(functionNum: 7, rows: numberRows([2, 4, 6])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(result, 2, accuracy: 1e-9)
    }

    func testPopulationStandardDeviation() {
        // [2,4,6]: mean 4, population variance (4+0+4)/3=2.666..., stdevp=sqrt(2.666...).
        guard case .number(let result) = SubtotalAggregator.evaluate(functionNum: 8, rows: numberRows([2, 4, 6])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(result, (8.0 / 3.0).squareRoot(), accuracy: 1e-9)
    }

    func testSum() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 9, rows: numberRows([1, 2, 3])), .number(6))
    }

    func testSampleVariance() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 10, rows: numberRows([2, 4, 6])), .number(4))
    }

    func testPopulationVariance() {
        guard case .number(let result) = SubtotalAggregator.evaluate(functionNum: 11, rows: numberRows([2, 4, 6])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(result, 8.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - 101-111 band selects the SAME function as 1-11

    func testFunctionNum101SelectsAverageJustLikeFunctionNum1() {
        let rows = numberRows([2, 4, 6])
        XCTAssertEqual(
            SubtotalAggregator.evaluate(functionNum: 101, rows: rows),
            SubtotalAggregator.evaluate(functionNum: 1, rows: rows)
        )
    }

    // MARK: - Error paths

    func testOutOfRangeFunctionNumIsNumberInvalidError() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 12, rows: numberRows([1, 2])), .error(.numberInvalid))
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 0, rows: numberRows([1, 2])), .error(.numberInvalid))
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 112, rows: numberRows([1, 2])), .error(.numberInvalid))
    }

    func testAverageOverNoNumbersIsDivisionByZeroError() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 1, rows: []), .error(.divisionByZero))
    }

    func testSampleStandardDeviationOverFewerThanTwoNumbersIsDivisionByZeroError() {
        XCTAssertEqual(SubtotalAggregator.evaluate(functionNum: 7, rows: numberRows([5])), .error(.divisionByZero))
    }

    // MARK: - FunctionRegistry registration (generic dispatch path)

    func testSUBTOTALIsRegisteredInFunctionRegistry() {
        XCTAssertTrue(FunctionRegistry.shared.contains("SUBTOTAL"))
        XCTAssertNotNil(FunctionRegistry.shared.lookup("subtotal"), "lookup is case-insensitive")
    }

    func testSUBTOTALIsNotRegisteredAsVolatile() {
        guard let fn = FunctionRegistry.shared.lookup("SUBTOTAL") else {
            return XCTFail("SUBTOTAL must be registered")
        }
        guard case .notVolatile = fn.signature.volatility else {
            return XCTFail("SUBTOTAL is not on Excel's volatile-function list")
        }
    }

    /// The generic dispatch path (see SubtotalFunctions.swift's header)
    /// has no row-hidden/nested context - every candidate cell is
    /// necessarily visible and non-nested. Over a plain range with no
    /// hidden rows or nested SUBTOTAL cells involved, that is exactly
    /// correct, and this is the path a real `=SUBTOTAL(9, A1:A3)`
    /// formula runs through today.
    func testSUBTOTALGenericDispatchAggregatesAFlattenedRangeCorrectly() throws {
        let fn = try XCTUnwrap(FunctionRegistry.shared.lookup("SUBTOTAL"))
        let range = Value.array(rows: 3, cols: 1, flat: [.number(10), .number(20), .number(30)])
        let result = try fn.call([.number(9), range])
        XCTAssertEqual(result, .number(60))
    }

    func testSUBTOTALGenericDispatchAcceptsMultipleRefArguments() throws {
        let fn = try XCTUnwrap(FunctionRegistry.shared.lookup("SUBTOTAL"))
        let result = try fn.call([.number(9), .number(1), .number(2), .number(3)])
        XCTAssertEqual(result, .number(6))
    }

    func testSUBTOTALGenericDispatchPropagatesAnErrorArgument() throws {
        let fn = try XCTUnwrap(FunctionRegistry.shared.lookup("SUBTOTAL"))
        let result = try fn.call([.number(9), .error(.divisionByZero)])
        XCTAssertEqual(result, .error(.divisionByZero))
    }
}
