import XCTest
@testable import TesseraCore

// MARK: - DateFunctionsTests
//
// Contract source, same standing as LookupFunctionsTests.swift's own
// header note: no refinement-doc/sota-report spec table exists for
// per-function date-arithmetic semantics. What IS a legitimate contract
// here is each function's own PUBLISHED `FunctionSignature`/
// `FunctionParameter` `description` text, registered in
// `DateFunctions.swift` (quoted inline per test group below) - that
// text is the product's declared, shipped behavioral commitment. Where
// the description text names a concrete rule (YEARFRAC's basis list,
// "reversed pair" being standard Excel NETWORKDAYS/WORKDAY behavior),
// the expected values are hand-computed from that published rule
// against real calendar dates (doctrine rule 9), not read off the
// implementation's output.
//
// TRANSPARENCY NOTE (prime-rule boundary, same disclosure
// LookupFunctionsTests.swift's author made for the same reason): this
// file's dispatch brief required reading `DateFunctions.swift` in full
// (it is inside this track's item-5 coverage-completion scope, and
// `RoundTripCorpus.swift`/other item-4 work in this same session had
// already surfaced it), so the `call` closure bodies were seen before
// these assertions were written. Every expected value below was
// independently hand-computed from the published parameter
// descriptions plus ordinary calendar arithmetic (day-of-week facts
// about real 2023/2024 dates, verified against the real calendar, not
// against what the code produced) - but the clean independence the
// prime rule asks for elsewhere cannot be claimed here. Flagged per the
// doctrine's own spirit rather than presented as contract-pure.
//
// SCOPE, STATED PLAINLY: only EDATE, EOMONTH, WORKDAY, NETWORKDAYS, and
// YEARFRAC basis 0 (US 30/360) are covered. YEARFRAC bases 1
// (actual/actual, leap-day-aware), 2 (actual/360), 3 (actual/365), and
// 4 (European 30/360) are NOT covered here - their hand-computation
// risk (leap-day-window logic, multi-year averaging) was judged not
// worth taking on without the ability to execute the suite locally
// this same session (see docs/.scratch/p2-0-findings-d.md item 5).

final class DateFunctionsTests: DoctrineTestCase {

    private func fn(_ name: String) throws -> BuiltInFunction {
        try XCTUnwrap(FunctionRegistry.shared.lookup(name), "\(name) must be registered")
    }

    /// Builds a `Value.date` at local noon (never midnight) so DST
    /// transitions at day boundaries can never shift the calendar day
    /// this test intends - matching `DateArgs.calendar` (`Calendar
    /// .current`)'s own day/month/year component reading.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Value {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        let d = Calendar.current.date(from: comps)!
        return .date(d)
    }

    /// Plain Swift tuples are not `Equatable` (no protocol conformance
    /// for tuple types, even though a bespoke `==` exists up to arity
    /// 6), so `XCTAssertEqual` cannot compare them directly - this
    /// small `Equatable` struct is the fix, not a tuple.
    private struct YMD: Equatable, CustomStringConvertible {
        let year: Int
        let month: Int
        let day: Int
        var description: String { "\(year)-\(month)-\(day)" }
    }

    private func components(of value: Value) throws -> YMD {
        guard case .date(let d) = value else {
            XCTFail("expected a .date value, got \(value)")
            return YMD(year: 0, month: 0, day: 0)
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return YMD(year: c.year!, month: c.month!, day: c.day!)
    }

    // MARK: - EDATE
    // Declared: "The date a number of months before or after a start date."

    func testEDATEAddsMonthsForward() throws {
        let edate = try fn("EDATE")
        let result = try edate.call([date(2024, 3, 15), .number(2)])
        XCTAssertEqual(try components(of: result), YMD(year: 2024, month: 5, day: 15))
    }

    func testEDATESubtractsMonthsForNegativeArgument() throws {
        let edate = try fn("EDATE")
        let result = try edate.call([date(2024, 3, 15), .number(-3)])
        XCTAssertEqual(try components(of: result), YMD(year: 2023, month: 12, day: 15))
    }

    func testEDATEPropagatesFirstArgumentError() throws {
        let edate = try fn("EDATE")
        let result = try edate.call([.error(.divisionByZero), .number(1)])
        XCTAssertEqual(result, .error(.divisionByZero))
    }

    // MARK: - EOMONTH
    // Declared: "The last day of the month a number of months from a
    // start date."

    func testEOMONTHOfTheSameMonthReturnsThatMonthsLastDay() throws {
        let eomonth = try fn("EOMONTH")
        let result = try eomonth.call([date(2024, 3, 15), .number(0)])
        XCTAssertEqual(try components(of: result), YMD(year: 2024, month: 3, day: 31), "March has 31 days")
    }

    func testEOMONTHOneMonthForwardIntoALeapFebruaryReturns29() throws {
        let eomonth = try fn("EOMONTH")
        let result = try eomonth.call([date(2024, 1, 15), .number(1)])
        XCTAssertEqual(try components(of: result), YMD(year: 2024, month: 2, day: 29), "2024 is a leap year")
    }

    func testEOMONTHOneMonthForwardIntoANonLeapFebruaryReturns28() throws {
        let eomonth = try fn("EOMONTH")
        let result = try eomonth.call([date(2023, 1, 15), .number(1)])
        XCTAssertEqual(try components(of: result), YMD(year: 2023, month: 2, day: 28), "2023 is not a leap year")
    }

    // MARK: - WORKDAY
    // Declared: "The date a number of working days from a start date."
    // Optional 3rd argument: "holidays".

    func testWORKDAYSkipsWeekendsWithNoHolidays() throws {
        // 2024-01-01 is a Monday.
        let workday = try fn("WORKDAY")
        let result = try workday.call([date(2024, 1, 1), .number(5)])
        // Mon 1 -> Tue2,Wed3,Thu4,Fri5 (4 workdays) -> weekend Jan6/7 skipped -> Mon8 is the 5th workday.
        XCTAssertEqual(try components(of: result), YMD(year: 2024, month: 1, day: 8))
    }

    func testWORKDAYAlsoSkipsAnExplicitHolidayFallingOnAWeekday() throws {
        // Same span as above, but 2024-01-08 (a Monday) is a holiday,
        // pushing the 5th workday out to 2024-01-09.
        let workday = try fn("WORKDAY")
        let result = try workday.call([date(2024, 1, 1), .number(5), date(2024, 1, 8)])
        XCTAssertEqual(try components(of: result), YMD(year: 2024, month: 1, day: 9))
    }

    // MARK: - NETWORKDAYS
    // Declared: "The number of working days between two dates,
    // inclusive."

    func testNETWORKDAYSCountsInclusiveWeekdaysExcludingWeekend() throws {
        // 2024-01-01 (Mon) .. 2024-01-08 (Mon) inclusive: 1,2,3,4,5,8 = 6
        // weekdays; 6 (Sat) and 7 (Sun) excluded.
        let networkdays = try fn("NETWORKDAYS")
        let result = try networkdays.call([date(2024, 1, 1), date(2024, 1, 8)])
        XCTAssertEqual(result, .number(6))
    }

    func testNETWORKDAYSAlsoExcludesAnExplicitHoliday() throws {
        let networkdays = try fn("NETWORKDAYS")
        let result = try networkdays.call([date(2024, 1, 1), date(2024, 1, 8), date(2024, 1, 8)])
        XCTAssertEqual(result, .number(5))
    }

    /// Standard Excel NETWORKDAYS behavior: a start date after the end
    /// date returns the same magnitude, negated - not an error.
    func testNETWORKDAYSWithStartAfterEndReturnsNegativeCount() throws {
        let networkdays = try fn("NETWORKDAYS")
        let forward = try networkdays.call([date(2024, 1, 1), date(2024, 1, 8)])
        let reversed = try networkdays.call([date(2024, 1, 8), date(2024, 1, 1)])
        guard case .number(let f) = forward, case .number(let r) = reversed else {
            return XCTFail("expected numeric results")
        }
        XCTAssertEqual(r, -f)
    }

    // MARK: - YEARFRAC (basis 0 only - see file header for the stated scope cut)
    // Declared basis: "0 US 30/360, 1 actual/actual, 2 actual/360, 3
    // actual/365, 4 European 30/360."

    func testYEARFRACBasisZeroForExactlySixMonthsIsOneHalf() throws {
        let yearfrac = try fn("YEARFRAC")
        // US 30/360: neither day is the 31st, so days = (0*360) + (6*30) + 0 = 180 -> 180/360.
        let result = try yearfrac.call([date(2024, 1, 1), date(2024, 7, 1), .number(0)])
        XCTAssertEqual(result, .number(0.5))
    }

    func testYEARFRACBasisZeroForExactlyOneYearIsOne() throws {
        let yearfrac = try fn("YEARFRAC")
        let result = try yearfrac.call([date(2023, 1, 1), date(2024, 1, 1), .number(0)])
        XCTAssertEqual(result, .number(1.0))
    }

    func testYEARFRACOutOfRangeBasisReturnsNumberInvalidError() throws {
        let yearfrac = try fn("YEARFRAC")
        let result = try yearfrac.call([date(2024, 1, 1), date(2024, 7, 1), .number(5)])
        XCTAssertEqual(result, .error(.numberInvalid), "declared basis domain is 0-4; 5 is out of range")
    }
}
