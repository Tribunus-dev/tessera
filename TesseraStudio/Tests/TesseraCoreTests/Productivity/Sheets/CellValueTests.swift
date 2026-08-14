import XCTest
@testable import TesseraCore

/// A cell's typed value: classification from raw text, storage in the
/// block's attribute bag, and JSON round-trip. Mirrors
/// `SheetCellFormatTests`'s shape for the sibling concept.
final class CellValueTests: XCTestCase {

    // MARK: - Classification

    func testEmptyTextClassifiesAsEmpty() {
        XCTAssertEqual(CellValue.classify("", columnType: .text), .empty)
        XCTAssertTrue(CellValue.classify("", columnType: .number).isEmpty)
    }

    func testFormulaTextClassifiesRegardlessOfColumnType() {
        XCTAssertEqual(CellValue.classify("=SUM(A1:A3)", columnType: .text), .formula("=SUM(A1:A3)"))
        XCTAssertEqual(CellValue.classify("=SUM(A1:A3)", columnType: .number), .formula("=SUM(A1:A3)"))
    }

    func testNumberTextClassifiesAsNumber() {
        XCTAssertEqual(CellValue.classify("42", columnType: .number), .number(42))
        XCTAssertEqual(CellValue.classify("3.14", columnType: .text), .number(3.14),
                        "the column type is a hint, not an enforced schema")
    }

    func testBooleanTextClassifiesAsCheckbox() {
        XCTAssertEqual(CellValue.classify("TRUE", columnType: .checkbox), .checkbox(true))
        XCTAssertEqual(CellValue.classify("false", columnType: .text), .checkbox(false))
    }

    func testPlainTextClassifiesAsText() {
        XCTAssertEqual(CellValue.classify("hello", columnType: .number), .text("hello"),
                        "text that doesn't parse as anything else stays text even in a number column")
    }

    func testDateColumnHintParsesISO8601() {
        let value = CellValue.classify("2024-01-02T00:00:00Z", columnType: .date)
        guard case .date(let d) = value else { return XCTFail("expected .date, got \(value)") }
        XCTAssertEqual(d.timeIntervalSince1970, 1_704_153_600, accuracy: 1)
    }

    // MARK: - JSON bridge

    func testEveryCaseRoundTripsThroughJSON() {
        let cases: [CellValue] = [
            .empty,
            .text("hello"),
            .number(42.5),
            .date(Date(timeIntervalSince1970: 1_700_000_000)),
            .checkbox(true),
            .formula("=A1+B1"),
            .error("#REF!"),
        ]
        for value in cases {
            let decoded = CellValue(json: value.json)
            XCTAssertEqual(decoded, value, "round-trip failed for \(value)")
        }
    }

    func testMalformedJSONDecodesToNil() {
        XCTAssertNil(CellValue(json: .string("not an object")))
        XCTAssertNil(CellValue(json: .object(["kind": .string("not-a-real-kind")])))
    }

    // MARK: - Sheet storage

    private func blank() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 3, cols: 3)
    }

    func testUntouchedCellReturnsEmpty() {
        XCTAssertEqual(blank().cellValue(row: 0, col: 0), .empty)
    }

    func testSettingAndReadingBackACellValue() {
        let sheet = blank().settingCellValue(row: 1, col: 2, .number(7))
        XCTAssertEqual(sheet.cellValue(row: 1, col: 2), .number(7))
        XCTAssertEqual(sheet.cellValue(row: 0, col: 0), .empty, "neighbours are untouched")
    }

    /// Clearing a value (setting `.empty`) must leave the block as it
    /// was before it was ever touched, not carrying an empty object
    /// forever - same convention `SheetCellFormat` uses for `.standard`.
    func testClearingAValueRemovesTheAttribute() {
        let sheet = blank()
            .settingCellValue(row: 0, col: 0, .number(1))
            .settingCellValue(row: 0, col: 0, .empty)
        let ids = sheet.tableCellIDs
        XCTAssertNil(sheet.body.blocks[ids[0]]?.attributes[CellValue.attributeKey])
    }

    func testCellValueDoesNotDisturbCellText() {
        let sheet = blank()
            .settingCellText(row: 0, col: 0, "=SUM(A2:A3)")
            .settingCellValue(row: 0, col: 0, .formula("=SUM(A2:A3)"))
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "=SUM(A2:A3)")
    }

    func testOutOfBoundsCoordinatesAreIgnored() {
        let sheet = blank()
        let unchanged = sheet.settingCellValue(row: 99, col: 0, .number(1))
        XCTAssertEqual(unchanged.cellValue(row: 99, col: 0), .empty)
        XCTAssertEqual(unchanged.body.blocks.count, sheet.body.blocks.count)
    }

    /// A value survives the document's own serialization, which is what
    /// makes it persist at all.
    func testValueSurvivesDocumentRoundTrip() throws {
        let sheet = blank().settingCellValue(row: 2, col: 1, .date(Date(timeIntervalSince1970: 1_700_000_000)))
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        guard case .date(let d) = restored.cellValue(row: 2, col: 1) else {
            return XCTFail("expected .date to survive round-trip")
        }
        XCTAssertEqual(d.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }
}
