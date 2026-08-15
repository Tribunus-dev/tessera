import XCTest
@testable import TesseraCore

/// Cell presentation: the format model, its storage in the block's
/// attribute bag, and the renderer that turns a computed value into
/// what the grid draws.
///
/// The invariant under all of it: formatting changes only what is
/// SHOWN. Nothing here may alter a stored value or what a formula
/// referencing the cell sees.
@MainActor
final class SheetCellFormatTests: XCTestCase {

    // MARK: - Model

    func testStandardFormatIsTheDefault() {
        let format = SheetCellFormat()
        XCTAssertTrue(format.isStandard)
        XCTAssertEqual(format.numberFormat, .general)
        XCTAssertEqual(format.decimals, 0)
        XCTAssertEqual(format.alignment, .automatic)
        XCTAssertTrue(format.borders.isEmpty)
    }

    /// Switching format adopts that format's conventional decimals, so
    /// one click on Currency lands on 2 places rather than 0.
    func testSettingNumberFormatAdoptsDefaultDecimals() {
        let currency = SheetCellFormat().settingNumberFormat(.currency)
        XCTAssertEqual(currency.numberFormat, .currency)
        XCTAssertEqual(currency.decimals, 2)

        let percent = SheetCellFormat().settingNumberFormat(.percent)
        XCTAssertEqual(percent.decimals, 0)
    }

    /// Re-applying the format a cell already has must not reset the
    /// decimals the user chose by hand.
    func testReapplyingTheSameFormatPreservesDecimals() {
        var format = SheetCellFormat().settingNumberFormat(.currency)
        format = format.steppingDecimals(by: 2)
        XCTAssertEqual(format.decimals, 4)

        let again = format.settingNumberFormat(.currency)
        XCTAssertEqual(again.decimals, 4, "clicking Currency twice must not discard the user's decimals")
    }

    /// "More decimals" on a General cell has to mean something, so it
    /// promotes the cell to a fixed-decimal format.
    func testSteppingDecimalsPromotesGeneralToNumber() {
        let stepped = SheetCellFormat().steppingDecimals(by: 1)
        XCTAssertEqual(stepped.numberFormat, .number)
        XCTAssertEqual(stepped.decimals, 1)
    }

    func testDecimalsClampAtZeroAndFifteen() {
        let floor = SheetCellFormat(numberFormat: .number, decimals: 0).steppingDecimals(by: -3)
        XCTAssertEqual(floor.decimals, 0)

        let ceiling = SheetCellFormat(numberFormat: .number, decimals: 15).steppingDecimals(by: 4)
        XCTAssertEqual(ceiling.decimals, 15)
    }

    func testBordersCompose() {
        XCTAssertTrue(SheetCellBorders.all.contains(.top))
        XCTAssertTrue(SheetCellBorders.all.contains(.trailing))
        XCTAssertFalse(SheetCellBorders.underline.contains(.top))
        XCTAssertTrue(SheetCellBorders.underline.contains(.bottom))
    }

    // MARK: - JSON round trip

    func testRoundTripThroughJSON() {
        let original = SheetCellFormat(
            numberFormat: .currency,
            decimals: 3,
            isBold: true,
            isItalic: true,
            fillHex: "#FFF3C4",
            textHex: "#B00020",
            borders: [.top, .bottom],
            alignment: .center
        )
        let decoded = SheetCellFormat(json: original.json)
        XCTAssertEqual(decoded, original)
    }

    /// The standard format writes an empty object, and an empty object
    /// decodes back to standard. That symmetry is what lets the store
    /// drop the attribute entirely.
    func testStandardFormatWritesNothing() {
        guard case .object(let dict) = SheetCellFormat.standard.json else {
            return XCTFail("expected an object")
        }
        XCTAssertTrue(dict.isEmpty)
        XCTAssertEqual(SheetCellFormat(json: .object([:])), .standard)
    }

    /// A cell stored before formats existed has no format key at all.
    func testMissingKeysDecodeToDefaults() {
        let decoded = SheetCellFormat(json: .object(["numberFormat": .string("percent")]))
        XCTAssertEqual(decoded?.numberFormat, .percent)
        XCTAssertEqual(decoded?.decimals, 0)
        XCTAssertEqual(decoded?.isBold, false)
    }

    func testUnknownFormatNameFallsBackToGeneral() {
        let decoded = SheetCellFormat(json: .object(["numberFormat": .string("klingon")]))
        XCTAssertEqual(decoded?.numberFormat, .general)
    }

    func testNonObjectJSONIsRejected() {
        XCTAssertNil(SheetCellFormat(json: .string("currency")))
        XCTAssertNil(SheetCellFormat(json: .null))
    }

    // MARK: - Sheet storage

    private func blank() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 3, cols: 3)
    }

    func testUnstyledCellReturnsStandard() {
        XCTAssertEqual(blank().cellFormat(row: 0, col: 0), .standard)
    }

    func testSettingAndReadingBackACellFormat() {
        let format = SheetCellFormat(numberFormat: .percent, decimals: 1, isBold: true)
        let sheet = blank().settingCellFormat(row: 1, col: 2, format)
        XCTAssertEqual(sheet.cellFormat(row: 1, col: 2), format)
        XCTAssertEqual(sheet.cellFormat(row: 0, col: 0), .standard, "neighbours are untouched")
    }

    /// Clearing a format must leave the block as it was before it was
    /// ever styled, not carrying an empty object forever.
    func testClearingAFormatRemovesTheAttribute() {
        let sheet = blank()
            .settingCellFormat(row: 0, col: 0, SheetCellFormat(numberFormat: .currency))
            .settingCellFormat(row: 0, col: 0, .standard)

        let ids = sheet.tableCellIDs
        XCTAssertNil(sheet.body.blocks[ids[0]]?.attributes[SheetCellFormat.attributeKey])
    }

    func testFormattingDoesNotDisturbCellText() {
        let sheet = blank()
            .settingCellText(row: 0, col: 0, "=SUM(A2:A3)")
            .settingCellFormat(row: 0, col: 0, SheetCellFormat(numberFormat: .currency, decimals: 2))
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "=SUM(A2:A3)")
    }

    func testOutOfBoundsCoordinatesAreIgnored() {
        let sheet = blank()
        let unchanged = sheet.settingCellFormat(row: 99, col: 0, SheetCellFormat(isBold: true))
        XCTAssertEqual(unchanged.cellFormat(row: 99, col: 0), .standard)
        XCTAssertEqual(unchanged.body.blocks.count, sheet.body.blocks.count)
    }

    /// A format survives the document's own serialization, which is
    /// what makes it persist at all.
    func testFormatSurvivesDocumentRoundTrip() throws {
        let sheet = blank().settingCellFormat(
            row: 2,
            col: 1,
            SheetCellFormat(numberFormat: .comma, decimals: 2, borders: .underline)
        )
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        XCTAssertEqual(restored.cellFormat(row: 2, col: 1).numberFormat, .comma)
        XCTAssertEqual(restored.cellFormat(row: 2, col: 1).decimals, 2)
        XCTAssertEqual(restored.cellFormat(row: 2, col: 1).borders, .underline)
    }

    // MARK: - Rendering

    private let usd = Locale(identifier: "en_US")

    private func render(_ value: Value, _ format: SheetCellFormat) -> String {
        SheetValueRenderer.string(for: value, format: format, locale: usd)
    }

    func testGeneralRendersTheValuesOwnDescription() {
        XCTAssertEqual(render(.number(1234.5), .standard), Value.number(1234.5).asString)
        XCTAssertEqual(render(.string("hello"), .standard), "hello")
    }

    func testCurrencyUsesTheLocaleSymbolAndGrouping() {
        let format = SheetCellFormat(numberFormat: .currency, decimals: 2)
        XCTAssertEqual(render(.number(1234.5), format), "$1,234.50")
    }

    /// Negatives in parentheses: a minus sign is easy to miss in a
    /// column, and a misread sign is the expensive kind of error.
    func testNegativeCurrencyIsParenthesised() {
        let format = SheetCellFormat(numberFormat: .currency, decimals: 2)
        XCTAssertEqual(render(.number(-1234.5), format), "($1,234.50)")
    }

    func testCommaGroupsWithoutASymbol() {
        let format = SheetCellFormat(numberFormat: .comma, decimals: 0)
        XCTAssertEqual(render(.number(1_234_567), format), "1,234,567")
    }

    /// Excel semantics: the cell STORES the fraction and SHOWS the
    /// percentage. 0.25 must not display as 0%.
    func testPercentScalesByOneHundred() {
        let format = SheetCellFormat(numberFormat: .percent, decimals: 0)
        XCTAssertEqual(render(.number(0.25), format), "25%")

        let oneDecimal = SheetCellFormat(numberFormat: .percent, decimals: 1)
        XCTAssertEqual(render(.number(0.1234), oneDecimal), "12.3%")
    }

    func testNumberFormatHasNoGroupingSeparator() {
        let format = SheetCellFormat(numberFormat: .number, decimals: 2)
        XCTAssertEqual(render(.number(1234.5), format), "1234.50")
    }

    func testScientific() {
        let format = SheetCellFormat(numberFormat: .scientific, decimals: 2)
        XCTAssertEqual(render(.number(12345), format), "1.23E+04")
    }

    /// The renderer must agree with the formula engine's serial epoch,
    /// or `=TODAY()` formatted as a date would show the wrong day.
    /// `DateFunctions` pins serial 25569 to 1970-01-01, which is the
    /// 1899-12-30 epoch; this asserts the renderer lands on the same
    /// date from the same number.
    func testDateSerialMatchesTheFormulaEngineEpoch() {
        let format = SheetCellFormat(numberFormat: .date)
        XCTAssertEqual(render(.number(25569), format), "Jan 1, 1970")
    }

    func testDateSerialAdvancesByOneDayPerUnit() {
        let format = SheetCellFormat(numberFormat: .date)
        XCTAssertEqual(render(.number(25570), format), "Jan 2, 1970")
    }

    func testTextFormatLeavesNumbersAlone() {
        let format = SheetCellFormat(numberFormat: .text, decimals: 2)
        XCTAssertEqual(render(.number(1234.5), format), Value.number(1234.5).asString)
    }

    /// An error dressed up as currency would read as a real number, so
    /// errors ignore the format entirely.
    func testErrorsIgnoreTheNumberFormat() {
        let format = SheetCellFormat(numberFormat: .currency, decimals: 2)
        XCTAssertEqual(render(.error(.divisionByZero), format), "#DIV/0!")
        XCTAssertEqual(render(.error(.referenceInvalid), format), "#REF!")
    }

    /// Formatting a non-number must not invent a value: TRUE shown as
    /// "$1.00" hides what the cell holds.
    func testNonNumbersAreNotCoerced() {
        let format = SheetCellFormat(numberFormat: .currency, decimals: 2)
        XCTAssertEqual(render(.string("n/a"), format), "n/a")
        XCTAssertEqual(render(.bool(true), format), Value.bool(true).asString)
    }

    func testBlankStaysBlank() {
        let format = SheetCellFormat(numberFormat: .currency, decimals: 2)
        XCTAssertEqual(render(.null, format), Value.null.asString)
    }

    // MARK: - NumberFormatEngine wiring (1.11)

    /// The literal requirement behind 1.11: cell rendering routes
    /// through `NumberFormatEngine` rather than a second, hand-rolled
    /// formatter. Comparing the renderer's output directly against
    /// `NumberFormatEngine.format` invoked with that format's own
    /// preset code is what makes "wired" falsifiable - if
    /// `SheetValueRenderer` ever reverts to computing digits itself,
    /// the two sides of this assertion diverge.
    func testCellRenderingRoutesThroughNumberFormatEngine() {
        let format = SheetCellFormat(numberFormat: .currency, decimals: 3)
        let code = SheetNumberFormat.currency.formatCode(decimals: 3, currencySymbol: usd.currencySymbol ?? "$")
        let expected = NumberFormatEngine.format(-9876.54321, using: NumberFormatEngine.parse(code), locale: usd)
        XCTAssertEqual(expected, "($9,876.543)")
        XCTAssertEqual(render(.number(-9876.54321), format), expected)
    }

    /// `formatCode` quotes the currency symbol before splicing it into
    /// the preset code specifically so a symbol containing a
    /// digit-mask or date-token letter can't be mis-tokenized. "Md"
    /// contains "M" (a month token) - unquoted, this would render as a
    /// date field instead of literal text.
    func testCurrencySymbolContainingFormatTokenCharactersIsNotMisparsed() {
        let code = SheetNumberFormat.currency.formatCode(decimals: 2, currencySymbol: "Md")
        let parsed = NumberFormatEngine.parse(code)
        XCTAssertEqual(NumberFormatEngine.format(1234.5, using: parsed, locale: usd), "Md1,234.50")
    }

    // MARK: - SheetCellFormatOverlay (dxf subset, for 1.12)

    func testOverlayWithNoFieldsIsEmptyAndANoOp() {
        let overlay = SheetCellFormatOverlay()
        XCTAssertTrue(overlay.isEmpty)
        let base = SheetCellFormat(numberFormat: .currency, decimals: 2, isBold: true)
        XCTAssertEqual(overlay.applied(over: base), base)
    }

    func testOverlaySubstitutesOnlyItsOwnFields() {
        let base = SheetCellFormat(numberFormat: .currency, decimals: 2, isBold: true, borders: .underline, alignment: .center)
        let overlay = SheetCellFormatOverlay(fillHex: "#FFC7CE", textHex: "#9C0006")
        let result = overlay.applied(over: base)

        XCTAssertEqual(result.fillHex, "#FFC7CE")
        XCTAssertEqual(result.textHex, "#9C0006")
        // Everything the overlay didn't mention passes through untouched.
        XCTAssertEqual(result.numberFormat, .currency)
        XCTAssertEqual(result.decimals, 2)
        XCTAssertTrue(result.isBold)
        XCTAssertEqual(result.borders, .underline)
        XCTAssertEqual(result.alignment, .center)
        XCTAssertFalse(overlay.isEmpty)
    }

    /// `decimals` is a field of its own on the overlay - switching
    /// `numberFormat` alone must not silently reset it, unlike
    /// `SheetCellFormat.settingNumberFormat`'s UI-click behavior.
    func testOverlayNumberFormatWithoutDecimalsKeepsTheBaseDecimalCount() {
        let base = SheetCellFormat(numberFormat: .number, decimals: 4)
        let overlay = SheetCellFormatOverlay(numberFormat: .percent)
        let result = overlay.applied(over: base)
        XCTAssertEqual(result.numberFormat, .percent)
        XCTAssertEqual(result.decimals, 4)
    }

    func testOverlayDecimalsClampLikeSheetCellFormats() {
        let overlay = SheetCellFormatOverlay(decimals: 99)
        XCTAssertEqual(overlay.decimals, 15)
        XCTAssertEqual(overlay.applied(over: .standard).decimals, 15)
    }
}
