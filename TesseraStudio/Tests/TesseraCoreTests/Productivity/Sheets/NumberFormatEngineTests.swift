import XCTest
@testable import TesseraCore

/// `NumberFormatEngine`: format-code parsing (digit masks, sections,
/// color/currency tags, date/time tokens) and formatting against
/// `Value`. See the file header on `NumberFormatEngine.swift` for the
/// explicit scope note - this is a full format-CODE parser, not a
/// full port of every `svl/source/numbers/` locale table.
final class NumberFormatEngineTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US_POSIX")

    private func fmt(_ n: Double, _ code: String) -> String {
        NumberFormatEngine.format(n, using: NumberFormatEngine.parse(code), locale: enUS)
    }

    private func dfmt(_ d: Date, _ code: String) -> String {
        NumberFormatEngine.format(d, using: NumberFormatEngine.parse(code), locale: enUS)
    }

    // MARK: - General

    func testGeneralFormatsAnIntegerWithoutADecimalPoint() {
        XCTAssertEqual(fmt(42, "General"), "42")
    }

    func testGeneralPreservesDecimals() {
        XCTAssertEqual(fmt(3.14, "General"), "3.14")
    }

    /// An empty format code (a cell that never had one set) must behave
    /// like "General", not silently produce an empty string - found via
    /// the standalone verification harness before this shipped.
    func testEmptyCodeDefaultsToGeneral() {
        XCTAssertEqual(fmt(7, ""), "7")
    }

    // MARK: - Digit masks

    func testZeroForcesLeadingZeros() {
        XCTAssertEqual(fmt(5, "00"), "05")
    }

    func testHashDoesNotPadLeadingZeros() {
        XCTAssertEqual(fmt(5, "##"), "5")
    }

    func testFixedDecimalsAreForcedAndRounded() {
        XCTAssertEqual(fmt(3.1, "0.00"), "3.10")
        XCTAssertEqual(fmt(3.14159, "0.00"), "3.14")
    }

    // MARK: - Grouping and scale

    func testThousandsGrouping() {
        XCTAssertEqual(fmt(1234567, "#,##0"), "1,234,567")
        XCTAssertEqual(fmt(1234.5, "#,##0.00"), "1,234.50")
    }

    func testTrailingCommaScalesDownByThousand() {
        XCTAssertEqual(fmt(150000, "0,"), "150")
    }

    // MARK: - Percent and scientific

    func testPercentScalesByOneHundred() {
        XCTAssertEqual(fmt(0.5, "0%"), "50%")
        XCTAssertEqual(fmt(0.1234, "0.00%"), "12.34%")
    }

    func testScientificNotation() {
        XCTAssertEqual(fmt(12345, "0.00E+00"), "1.23E+04")
        XCTAssertEqual(fmt(0.001234, "0.00E+00"), "1.23E-03")
    }

    // MARK: - Sections

    func testTwoSectionsRouteBySign() {
        let code = "$#,##0.00;[Red]-$#,##0.00"
        XCTAssertEqual(fmt(1234.5, code), "$1,234.50")
        XCTAssertEqual(fmt(-1234.5, code), "-$1,234.50", "the negative section supplies its own sign - no double minus")
    }

    func testSingleSectionGetsAnImplicitMinusOnNegatives() {
        XCTAssertEqual(fmt(-42, "0"), "-42")
        XCTAssertEqual(fmt(-3.5, "0.00"), "-3.50")
    }

    func testThreeSectionsRoutePositiveNegativeZero() {
        let code = "0.00;(0.00);\"zero\""
        XCTAssertEqual(fmt(5, code), "5.00")
        XCTAssertEqual(fmt(-5, code), "(5.00)")
        XCTAssertEqual(fmt(0, code), "zero")
    }

    func testFourthSectionAppliesToTextValues() {
        let format = NumberFormatEngine.parse("0.00;(0.00);\"zero\";\"[tagged]\"")
        let result = NumberFormatEngine.format(.string("hi"), using: format, locale: enUS)
        XCTAssertTrue(result.contains("[tagged]"))
    }

    // MARK: - Dates

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return calendar.date(from: comps)!
    }

    func testISODateFormat() {
        let d = makeDate(year: 2024, month: 1, day: 2)
        XCTAssertEqual(dfmt(d, "yyyy-mm-dd"), "2024-01-02")
    }

    func testUSDateFormat() {
        let d = makeDate(year: 2024, month: 1, day: 2)
        XCTAssertEqual(dfmt(d, "mm/dd/yyyy"), "01/02/2024")
        XCTAssertEqual(dfmt(d, "m/d/yyyy"), "1/2/2024", "single-letter tokens don't pad")
    }

    func testTwoDigitYear() {
        let d = makeDate(year: 2024, month: 1, day: 2)
        XCTAssertEqual(dfmt(d, "yy"), "24")
    }

    /// "m" is month almost everywhere but minutes immediately after an
    /// hour token or immediately before a second token - the single
    /// most common gotcha in Excel-style format codes, and a bug this
    /// engine had before this test existed: an earlier version always
    /// resolved "mm" to month, so "hh:mm:ss" rendered the MONTH in the
    /// minutes slot.
    func testMinuteMonthDisambiguation() {
        let d = makeDate(year: 2024, month: 1, day: 2, hour: 15, minute: 4, second: 5)
        XCTAssertEqual(dfmt(d, "hh:mm:ss"), "15:04:05")
        XCTAssertEqual(dfmt(d, "yyyy-mm-dd"), "2024-01-02", "and 'mm' next to y/d is still month")
    }

    /// Date-component extraction must not depend on the host machine's
    /// timezone - a spreadsheet date/time value is a timezone-naive
    /// wall-clock value (matching Value.asNumber's Excel-epoch
    /// arithmetic, which is timezone-naive too). Constructing in UTC
    /// and formatting back must round-trip regardless of where the
    /// test runs.
    func testDateRenderingIsTimezoneDeterministic() {
        let d = makeDate(year: 2024, month: 6, day: 15, hour: 23, minute: 30, second: 0)
        XCTAssertEqual(dfmt(d, "hh:mm"), "23:30")
    }

    // MARK: - Literals and escapes

    func testBackslashEscapesALiteralCharacter() {
        XCTAssertEqual(fmt(5, "0\\%"), "5%")
    }

    func testQuotedLiteralText() {
        XCTAssertEqual(fmt(5, "0\" units\""), "5 units")
    }

    // MARK: - Value coercion

    func testErrorValueRendersItsDisplayString() {
        let result = NumberFormatEngine.format(.error(.divisionByZero), using: NumberFormatEngine.parse("0.00"), locale: enUS)
        XCTAssertEqual(result, ValueError.divisionByZero.displayString)
    }

    func testBooleanValueCoercesThroughAsNumber() {
        XCTAssertEqual(NumberFormatEngine.format(.bool(true), using: NumberFormatEngine.parse("0"), locale: enUS), "1")
        XCTAssertEqual(NumberFormatEngine.format(.bool(false), using: NumberFormatEngine.parse("0"), locale: enUS), "0")
    }

    // MARK: - Locale-ID currency tags (P1, 1.11)

    func testCurrencyCodeTagWithLocaleIDRendersTheCodeAsLiteralText() {
        XCTAssertEqual(fmt(1234.5, "[$EUR-407]#,##0.00"), "EUR1,234.50")
    }

    /// "[$-F800]" is a system-long-date FLAG, not a currency symbol - it
    /// must contribute nothing to the rendered text. Before this fixed
    /// `String.split(maxSplits:)`'s leading-empty-component drop, this
    /// rendered the locale ID ("F800") as if it were the symbol.
    func testSystemLongDateFlagCarriesNoVisibleText() {
        XCTAssertEqual(fmt(5, "[$-F800]0"), "5")
    }

    /// Same bug class as above, LO's own system-date flag.
    func testSystemSysdateFlagCarriesNoVisibleText() {
        XCTAssertEqual(fmt(5, "[$-x-sysdate]0"), "5")
    }

    /// "[$$-409]" - a literal "$" tagged with the en-US locale ID; the
    /// symbol is the single character before the first "-", not the
    /// whole "$-409" run.
    func testDollarLiteralWithLocaleIDTag() {
        XCTAssertEqual(fmt(5, "[$$-409]0"), "$5")
    }

    // MARK: - Fill '*' / pad '_' (P1, 1.11)

    func testFillDirectiveDropsInAWidthLessContext() {
        XCTAssertEqual(fmt(5, "0*x"), "5", "no column width to fill against, so '*' contributes nothing")
    }

    func testPadDirectiveEmitsOneSpace() {
        XCTAssertEqual(fmt(5, "0_)"), "5 ", "one space stands in for the reserved glyph's width")
    }

    /// Built-ins 41-44 shape (pad-open, literal "$", fill-space, digits,
    /// pad-close) - the exact combination the design doc cites as the
    /// frequency justification for closing this gap at P1.
    func testAccountingBuiltinWithFillAndPadParsesAndDegradesSanely() {
        XCTAssertEqual(fmt(1234.5, "_($* #,##0.00_)"), " $1,234.50 ")
    }
}
