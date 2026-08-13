import XCTest
@testable import TesseraCore

/// EDATE / EOMONTH / YEARFRAC / WORKDAY / NETWORKDAYS.
///
/// Dates in the test formulas are built with `DATE(...)` so they do not
/// depend on any text date format. The chosen dates are deliberately
/// self-evident (2024-01-01 is a Monday) so the expected values can be
/// checked by hand rather than trusted.
final class DateFunctionsTests: XCTestCase {

    private var engine: SheetEngine!

    override func setUp() {
        super.setUp()
        engine = SheetEngine()
    }

    private func value(_ formula: String) throws -> Value {
        let addr = CellAddr(col: 0, row: 0)
        try engine.setFormula(sheet: nil, addr: addr, source: formula)
        return engine.getValue(sheet: nil, addr: addr)
    }

    private func number(_ formula: String, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let v = try value(formula)
        guard case .number(let n) = v else {
            XCTFail("expected a number from \(formula), got \(v)", file: file, line: line)
            return .nan
        }
        return n
    }

    /// Year/month/day of a formula that returns a date.
    private func ymd(_ formula: String, file: StaticString = #filePath, line: UInt = #line) throws -> (Int, Int, Int) {
        let v = try value(formula)
        guard case .date(let d) = v else {
            XCTFail("expected a date from \(formula), got \(v)", file: file, line: line)
            return (0, 0, 0)
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - EDATE

    func testEdateAddsMonths() throws {
        let (y, m, d) = try ymd("=EDATE(DATE(2024,1,15), 1)")
        XCTAssertEqual([y, m, d], [2024, 2, 15])
    }

    func testEdateSubtractsMonths() throws {
        let (y, m, d) = try ymd("=EDATE(DATE(2024,3,15), -2)")
        XCTAssertEqual([y, m, d], [2024, 1, 15])
    }

    /// Rolling from the 31st into a shorter month clamps to its last day.
    func testEdateClampsShortMonth() throws {
        let (y, m, d) = try ymd("=EDATE(DATE(2024,1,31), 1)")
        XCTAssertEqual([y, m, d], [2024, 2, 29], "2024 is a leap year")
    }

    func testEdateCrossesYearBoundary() throws {
        let (y, m, d) = try ymd("=EDATE(DATE(2024,12,10), 2)")
        XCTAssertEqual([y, m, d], [2025, 2, 10])
    }

    // MARK: - EOMONTH

    func testEomonthSameMonth() throws {
        let (y, m, d) = try ymd("=EOMONTH(DATE(2024,1,15), 0)")
        XCTAssertEqual([y, m, d], [2024, 1, 31])
    }

    func testEomonthNextMonthIsLeapAware() throws {
        let (y, m, d) = try ymd("=EOMONTH(DATE(2024,1,1), 1)")
        XCTAssertEqual([y, m, d], [2024, 2, 29])
    }

    func testEomonthNonLeapFebruary() throws {
        let (y, m, d) = try ymd("=EOMONTH(DATE(2023,1,1), 1)")
        XCTAssertEqual([y, m, d], [2023, 2, 28])
    }

    func testEomonthNegativeMonths() throws {
        let (y, m, d) = try ymd("=EOMONTH(DATE(2024,1,15), -3)")
        XCTAssertEqual([y, m, d], [2023, 10, 31])
    }

    // MARK: - YEARFRAC

    /// 30/360 US: 6 whole months (180) plus 29 days = 209/360.
    func testYearfracThirty360Default() throws {
        XCTAssertEqual(try number("=YEARFRAC(DATE(2012,1,1), DATE(2012,7,30))"), 209.0 / 360.0, accuracy: 1e-9)
    }

    /// Half a common year, actual/365.
    func testYearfracActual365() throws {
        // 2023-01-01 to 2023-07-02 is 182 days.
        XCTAssertEqual(try number("=YEARFRAC(DATE(2023,1,1), DATE(2023,7,2), 3)"), 182.0 / 365.0, accuracy: 1e-9)
    }

    func testYearfracActual360() throws {
        XCTAssertEqual(try number("=YEARFRAC(DATE(2023,1,1), DATE(2023,7,2), 2)"), 182.0 / 360.0, accuracy: 1e-9)
    }

    /// A full common year is exactly 1 under actual/actual.
    func testYearfracActualActualFullYear() throws {
        XCTAssertEqual(try number("=YEARFRAC(DATE(2023,1,1), DATE(2024,1,1), 1)"), 1.0, accuracy: 1e-9)
    }

    /// The European variant clamps a 31st on BOTH ends, the US one only
    /// clamps the end when the start was already a 30th.
    func testYearfracEuropeanDiffersFromUS() throws {
        let us = try number("=YEARFRAC(DATE(2024,1,1), DATE(2024,1,31), 0)")
        let european = try number("=YEARFRAC(DATE(2024,1,1), DATE(2024,1,31), 4)")
        XCTAssertEqual(us, 30.0 / 360.0, accuracy: 1e-9)
        XCTAssertEqual(european, 29.0 / 360.0, accuracy: 1e-9)
    }

    /// A reversed pair is the same magnitude - Excel treats it unsigned.
    func testYearfracIgnoresArgumentOrder() throws {
        let forward = try number("=YEARFRAC(DATE(2023,1,1), DATE(2023,7,2), 3)")
        let backward = try number("=YEARFRAC(DATE(2023,7,2), DATE(2023,1,1), 3)")
        XCTAssertEqual(forward, backward, accuracy: 1e-12)
    }

    func testYearfracRejectsUnknownBasis() throws {
        XCTAssertEqual(try value("=YEARFRAC(DATE(2023,1,1), DATE(2023,7,2), 9)"), .error(.numberInvalid))
    }

    // MARK: - WORKDAY

    /// 2024-01-01 is a Monday; four working days later is Friday the 5th.
    func testWorkdayWithinTheWeek() throws {
        let (y, m, d) = try ymd("=WORKDAY(DATE(2024,1,1), 4)")
        XCTAssertEqual([y, m, d], [2024, 1, 5])
    }

    /// The fifth working day skips the weekend to the following Monday.
    func testWorkdaySkipsWeekend() throws {
        let (y, m, d) = try ymd("=WORKDAY(DATE(2024,1,1), 5)")
        XCTAssertEqual([y, m, d], [2024, 1, 8])
    }

    func testWorkdayCountsBackwards() throws {
        // Monday the 8th, back five working days, is Monday the 1st.
        let (y, m, d) = try ymd("=WORKDAY(DATE(2024,1,8), -5)")
        XCTAssertEqual([y, m, d], [2024, 1, 1])
    }

    /// A holiday inside the span pushes the result out by a day.
    func testWorkdaySkipsHolidays() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: 0), value: .date(dateFor(2024, 1, 3)))
        let (y, m, d) = try ymd("=WORKDAY(DATE(2024,1,1), 4, D1)")
        XCTAssertEqual([y, m, d], [2024, 1, 8])
    }

    // MARK: - NETWORKDAYS

    /// Monday to Friday inclusive is five working days.
    func testNetworkdaysFullWeek() throws {
        XCTAssertEqual(try number("=NETWORKDAYS(DATE(2024,1,1), DATE(2024,1,5))"), 5, accuracy: 1e-9)
    }

    /// Extending across the weekend adds nothing.
    func testNetworkdaysExcludesWeekend() throws {
        XCTAssertEqual(try number("=NETWORKDAYS(DATE(2024,1,1), DATE(2024,1,7))"), 5, accuracy: 1e-9)
    }

    func testNetworkdaysIsInclusiveOfBothEnds() throws {
        XCTAssertEqual(try number("=NETWORKDAYS(DATE(2024,1,1), DATE(2024,1,1))"), 1, accuracy: 1e-9)
    }

    func testNetworkdaysSubtractsHolidays() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 3, row: 0), value: .date(dateFor(2024, 1, 3)))
        XCTAssertEqual(try number("=NETWORKDAYS(DATE(2024,1,1), DATE(2024,1,5), D1)"), 4, accuracy: 1e-9)
    }

    /// A reversed pair counts negative, as Excel does.
    func testNetworkdaysReversedIsNegative() throws {
        XCTAssertEqual(try number("=NETWORKDAYS(DATE(2024,1,5), DATE(2024,1,1))"), -5, accuracy: 1e-9)
    }

    // MARK: - Errors

    func testErrorPropagatesThroughDateFunctions() throws {
        engine.setValue(sheet: nil, addr: CellAddr(col: 1, row: 0), value: .number(0))
        try engine.setFormula(sheet: nil, addr: CellAddr(col: 1, row: 1), source: "=1/B1")
        XCTAssertEqual(try value("=EOMONTH(B2, 1)"), .error(.divisionByZero))
    }

    // MARK: - Helpers

    private func dateFor(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar.current.date(from: comps) ?? Date()
    }
}
