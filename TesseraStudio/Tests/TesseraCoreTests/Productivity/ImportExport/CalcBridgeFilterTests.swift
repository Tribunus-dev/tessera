import XCTest
@testable import TesseraCore

/// `CalcBridgeFilter` (P0 0.9). The CSV serializer is pure and tested
/// without `soffice`; the actual ODS/XLS conversion is a real
/// integration test, skipped when LibreOffice isn't installed.
final class CalcBridgeFilterTests: XCTestCase {

    // MARK: - Formats

    func testSupportedFormatsExcludeXLSXAndDelimitedFormats() {
        XCTAssertEqual(Set(CalcBridgeFilter.supportedImportFormats), ["ods", "xls"])
        XCTAssertEqual(Set(CalcBridgeFilter.supportedExportFormats), ["ods", "xls"])
    }

    func testUnsupportedImportFormatThrowsWithoutTouchingSoffice() async throws {
        let filter = CalcBridgeFilter()
        do {
            _ = try await filter.importWorkbook(data: Data(), format: "xlsx")
            XCTFail("expected unsupportedFormat")
        } catch CalcBridgeFilter.FilterError.unsupportedFormat(let format) {
            XCTAssertEqual(format, "xlsx")
        }
    }

    func testUnsupportedExportFormatThrowsWithoutTouchingSoffice() async throws {
        let filter = CalcBridgeFilter()
        do {
            _ = try await filter.exportWorkbook(Sheet.makeBlank(title: "T", rows: 1, cols: 1), format: "csv")
            XCTFail("expected unsupportedFormat")
        } catch CalcBridgeFilter.FilterError.unsupportedFormat(let format) {
            XCTAssertEqual(format, "csv")
        }
    }

    // MARK: - CSV serialization (pure, no soffice)

    func testCSVSerializationPlainValues() {
        var sheet = Sheet.makeBlank(title: "T", rows: 2, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "Name")
        sheet = sheet.settingCellText(row: 0, col: 1, "Score")
        sheet = sheet.settingCellText(row: 1, col: 0, "Alice")
        sheet = sheet.settingCellText(row: 1, col: 1, "90")
        let csv = String(data: CalcBridgeFilter.csvData(for: sheet), encoding: .utf8)
        XCTAssertEqual(csv, "Name,Score\r\nAlice,90\r\n")
    }

    func testCSVSerializationQuotesFieldsContainingCommaOrQuote() {
        var sheet = Sheet.makeBlank(title: "T", rows: 1, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "Smith, John")
        sheet = sheet.settingCellText(row: 0, col: 1, "Says \"hi\"")
        let csv = String(data: CalcBridgeFilter.csvData(for: sheet), encoding: .utf8)
        XCTAssertEqual(csv, "\"Smith, John\",\"Says \"\"hi\"\"\"\r\n")
    }

    func testCSVSerializationPreservesFormulaSourceText() {
        var sheet = Sheet.makeBlank(title: "T", rows: 1, cols: 1)
        sheet = sheet.settingCellText(row: 0, col: 0, "=SUM(A1:A10)")
        let csv = String(data: CalcBridgeFilter.csvData(for: sheet), encoding: .utf8)
        XCTAssertEqual(csv, "=SUM(A1:A10)\r\n")
    }

    func testCSVSerializationOfEmptySheetIsEmpty() {
        let sheet = Sheet.makeBlank(title: "T", rows: 0, cols: 0)
        XCTAssertEqual(CalcBridgeFilter.csvData(for: sheet).count, 0)
    }

    // MARK: - Real round-trip (needs soffice)

    func testImportODSProducesASheetWithValues() async throws {
        let filter = CalcBridgeFilter()
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        let converter = LibreOfficeConverter()
        let csv = Data("Name,Score\r\nAlice,90\r\nBob,85\r\n".utf8)
        let ods = try await converter.convert(data: csv, sourceExtension: "csv", targetExtension: "ods")

        let sheet = try await filter.importWorkbook(data: ods, format: "ods", title: "Imported")
        XCTAssertEqual(sheet.title, "Imported")
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "Name")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "Alice")
        XCTAssertEqual(sheet.cellText(row: 2, col: 1), "85")
    }

    /// A formula's SOURCE text survives export (Tessera CSV -> ODS: LO's
    /// CSV importer treats a leading `=` as live, verified in
    /// `LibreOfficeConverterTests.testConvertCSVToODSPreservesFormulaAsLiveFormula`)
    /// but NOT reimport (ODS -> CSV: LO's CSV EXPORT always writes each
    /// cell's last-computed VALUE, never formula source - confirmed
    /// empirically, not assumed). So a full export-then-reimport cycle
    /// through this filter is a values round trip, not a formula one -
    /// the formula computed correctly inside the exported .ods (that's
    /// what makes the reimported value "20" and not the literal text
    /// "=A1*2"), it just doesn't come back out as a live formula.
    func testExportThenImportRoundTripsValuesButNotFormulaSource() async throws {
        let filter = CalcBridgeFilter()
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        var sheet = Sheet.makeBlank(title: "RoundTrip", rows: 2, cols: 1)
        sheet = sheet.settingCellText(row: 0, col: 0, "10")
        sheet = sheet.settingCellText(row: 1, col: 0, "=A1*2")

        let odsData = try await filter.exportWorkbook(sheet, format: "ods")
        XCTAssertGreaterThan(odsData.count, 0)

        let reimported = try await filter.importWorkbook(data: odsData, format: "ods")
        XCTAssertEqual(reimported.cellText(row: 0, col: 0), "10")
        XCTAssertEqual(reimported.cellText(row: 1, col: 0), "20", "the formula computed correctly inside the .ods; CSV reimport can only see its resulting value")
    }

    func testExportToXLSProducesRealBinaryFormat() async throws {
        let filter = CalcBridgeFilter()
        try await XCTSkipIf(!filter.isAvailable, "soffice not installed")

        let sheet = Sheet.makeBlank(title: "T", rows: 1, cols: 1).settingCellText(row: 0, col: 0, "hello")
        let xlsData = try await filter.exportWorkbook(sheet, format: "xls")
        // The legacy binary XLS format (OLE Compound File) magic bytes -
        // confirms soffice picked the actual "MS Excel 97" filter, not
        // silently substituting the .xlsx filter under the .xls name
        // (a real bug found elsewhere in this codebase's own filter map).
        XCTAssertEqual(xlsData.prefix(8), Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
    }
}
