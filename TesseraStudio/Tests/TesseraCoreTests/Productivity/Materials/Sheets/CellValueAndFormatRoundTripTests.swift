import XCTest
@testable import TesseraCore

// Contract source: testing-doctrine.md rule 2 ("Round-trip identity...
// every Codable value type gets encode-decode identity, legacy-JSON
// decode ..., and - where the type has a canonical serialization -
// byte-identical re-encode") applied to the two per-cell value types
// named in the Calc cluster's item "1.11 per-cell styles":
// `CellValue` (`Materials/Sheets/CellValue.swift`) and
// `SheetCellFormat`/`SheetCellFormatOverlay`
// (`Materials/Sheets/SheetCellFormat.swift`). Both types' own doc
// comments state the legacy-compat contract directly: "a sheet written
// before this type existed decodes to .standard" (SheetCellFormat) /
// "cells written before CellValue existed... return .empty"
// (Sheet.cellValue) - not a bug pin, the type's documented default.
final class CellValueAndFormatRoundTripTests: DoctrineTestCase {

    // MARK: - CellValue: JSONValue bridge round-trip (not standard Codable - custom init?(json:)/var json)

    private static let everyCase: [CellValue] = [
        .empty,
        .text("hello"),
        .number(3.5),
        .date(Date(timeIntervalSince1970: 1_700_000_000)),
        .checkbox(true),
        .checkbox(false),
        .formula("=SUM(A1:A3)"),
        .error("#REF!"),
    ]

    func testEveryCellValueCaseRoundTripsThroughItsJSONBridge() {
        for value in Self.everyCase {
            let json = value.json
            let decoded = CellValue(json: json)
            XCTAssertEqual(decoded, value, "round trip failed for \(value)")
        }
    }

    func testCellValueJSONDecodeRejectsAMalformedObject() {
        XCTAssertNil(CellValue(json: .object(["kind": .string("not-a-real-kind")])))
        XCTAssertNil(CellValue(json: .string("not even an object")))
    }

    /// "cells written before CellValue existed ... return .empty" -
    /// `Sheet.cellValue(row:col:)`'s own documented default when the
    /// `cellValue` attribute key is simply absent (the legacy shape).
    func testCellWithNoStoredCellValueAttributeDecodesToEmpty() {
        let sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        XCTAssertEqual(sheet.cellValue(row: 0, col: 0), .empty)
    }

    // MARK: - SheetCellFormat: Codable round-trip + legacy decode + byte-identical re-encode

    func testSheetCellFormatEncodeDecodeIdentity() throws {
        let original = SheetCellFormat(
            numberFormat: .currency, decimals: 2, isBold: true, isItalic: true,
            fillHex: "#112233", textHex: "#445566", borders: .all, alignment: .center
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetCellFormat.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTwoIndependentEncodesOfTheSameSheetCellFormatAreByteIdentical() throws {
        let format = SheetCellFormat(numberFormat: .percent, decimals: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(format), try encoder.encode(format))
    }

    /// "a missing format key is .standard" - the documented legacy-decode
    /// contract, exercised through the JSONValue bridge Sheet actually
    /// uses (block.attributes), not the Codable path directly.
    func testCellWithNoStoredFormatAttributeDecodesToStandard() {
        let sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        XCTAssertEqual(sheet.cellFormat(row: 0, col: 0), .standard)
    }

    func testSettingThenClearingAFormatLeavesTheCellByteIdenticalToNeverStyled() throws {
        var sheet = Sheet.makeBlank(title: "t", rows: 1, cols: 1)
        let neverStyledJSON = try sheet.jsonData()
        sheet = sheet.settingCellFormat(row: 0, col: 0, SheetCellFormat(isBold: true, fillHex: "#FF0000"))
        sheet = sheet.settingCellFormat(row: 0, col: 0, .standard)
        XCTAssertEqual(try sheet.jsonData(), neverStyledJSON)
    }

    func testSheetCellFormatJSONBridgeRoundTrip() {
        let original = SheetCellFormat(numberFormat: .scientific, decimals: 4, borders: [.top, .bottom])
        let decoded = SheetCellFormat(json: original.json)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - SheetCellFormatOverlay (dxf subset): every field is genuinely three-state (unset/set)

    func testOverlayEncodeDecodeIdentityWithOnlySomeFieldsSet() throws {
        let original = SheetCellFormatOverlay(isBold: true, fillHex: "#ABCDEF")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetCellFormatOverlay.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.isItalic, "an overlay field left unset must decode back to nil, not a false default")
    }

    func testOverlayAppliedOverABaseFormatOnlyTouchesItsOwnSetFields() {
        let base = SheetCellFormat(numberFormat: .currency, decimals: 2, isItalic: true, borders: .all)
        let overlay = SheetCellFormatOverlay(isBold: true, fillHex: "#FFFF00")
        let result = overlay.applied(over: base)

        XCTAssertTrue(result.isBold, "overlay's own field applies")
        XCTAssertEqual(result.fillHex, "#FFFF00")
        XCTAssertEqual(result.numberFormat, .currency, "unset overlay fields pass the base through unchanged")
        XCTAssertTrue(result.isItalic)
        XCTAssertEqual(result.borders, .all)
    }

    func testEmptyOverlayIsANoOpWhenApplied() {
        let base = SheetCellFormat(numberFormat: .comma, decimals: 3, isBold: true)
        let result = SheetCellFormatOverlay().applied(over: base)
        XCTAssertEqual(result, base)
    }
}
