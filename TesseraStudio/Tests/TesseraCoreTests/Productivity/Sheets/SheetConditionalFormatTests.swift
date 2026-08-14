import XCTest
@testable import TesseraCore

/// `SheetConditionalFormat` (P0 0.1d): a conditional-formatting rule
/// bound to a range on a `Sheet`. `SheetWorkbook` doesn't check these
/// on redraw yet - this ships and tests the rule model itself.
final class SheetConditionalFormatTests: XCTestCase {

    private func rule(
        kind: SheetConditionalFormatKind,
        comparator: SheetValidationComparator? = nil,
        min: String? = nil,
        max: String? = nil
    ) -> SheetConditionalFormat {
        SheetConditionalFormat(
            kind: kind, comparator: comparator, minValue: min, maxValue: max,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
    }

    // MARK: - Empty cells never match a cell-value rule

    func testEmptyCellNeverMatchesCellValue() {
        let r = rule(kind: .cellValue, comparator: .greaterThan, min: "0")
        XCTAssertFalse(r.matches(.empty))
    }

    func testWrongValueKindFails() {
        let r = rule(kind: .cellValue, comparator: .greaterThan, min: "0")
        XCTAssertFalse(r.matches(.text("hello")))
    }

    // MARK: - Comparators (mirrors SheetValidationRule's coverage)

    func testBetween() {
        let r = rule(kind: .cellValue, comparator: .between, min: "1", max: "10")
        XCTAssertTrue(r.matches(.number(5)))
        XCTAssertTrue(r.matches(.number(1)))
        XCTAssertTrue(r.matches(.number(10)))
        XCTAssertFalse(r.matches(.number(11)))
        XCTAssertFalse(r.matches(.number(0)))
    }

    func testNotBetween() {
        let r = rule(kind: .cellValue, comparator: .notBetween, min: "1", max: "10")
        XCTAssertFalse(r.matches(.number(5)))
        XCTAssertTrue(r.matches(.number(11)))
    }

    func testEqualToAndNotEqualTo() {
        let eq = rule(kind: .cellValue, comparator: .equalTo, min: "42")
        XCTAssertTrue(eq.matches(.number(42)))
        XCTAssertFalse(eq.matches(.number(41)))

        let ne = rule(kind: .cellValue, comparator: .notEqualTo, min: "42")
        XCTAssertFalse(ne.matches(.number(42)))
        XCTAssertTrue(ne.matches(.number(41)))
    }

    func testStrictAndInclusiveComparators() {
        XCTAssertFalse(rule(kind: .cellValue, comparator: .greaterThan, min: "5").matches(.number(5)))
        XCTAssertTrue(rule(kind: .cellValue, comparator: .greaterThanOrEqual, min: "5").matches(.number(5)))
        XCTAssertFalse(rule(kind: .cellValue, comparator: .lessThan, min: "5").matches(.number(5)))
        XCTAssertTrue(rule(kind: .cellValue, comparator: .lessThanOrEqual, min: "5").matches(.number(5)))
    }

    // MARK: - Formula / visualization kinds always "match"

    func testFormulaAlwaysReportsMatch() {
        let r = SheetConditionalFormat(kind: .formula, formula: "=A1>0", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(r.matches(.number(-1)))
        XCTAssertTrue(r.matches(.empty))
    }

    func testVisualizationKindsAlwaysReportMatch() {
        for kind in [SheetConditionalFormatKind.colorScale, .dataBar, .iconSet] {
            let r = SheetConditionalFormat(kind: kind, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
            XCTAssertTrue(r.matches(.empty), "\(kind) should always report a match")
            XCTAssertTrue(r.matches(.number(0)), "\(kind) should always report a match")
        }
    }

    // MARK: - Coverage

    func testCoversChecksTheBoundingBox() {
        let r = SheetConditionalFormat(kind: .cellValue, topLeftCol: 1, topLeftRow: 1, bottomRightCol: 3, bottomRightRow: 3)
        XCTAssertTrue(r.covers(row: 2, col: 2))
        XCTAssertTrue(r.covers(row: 1, col: 1))
        XCTAssertTrue(r.covers(row: 3, col: 3))
        XCTAssertFalse(r.covers(row: 0, col: 2))
        XCTAssertFalse(r.covers(row: 2, col: 4))
    }

    func testNegativeCoordinateProducesNilRangeRef() {
        let r = SheetConditionalFormat(kind: .cellValue, topLeftCol: -1, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2)
        XCTAssertNil(r.rangeRef)
    }

    // MARK: - Sheet storage

    private func blank() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 5, cols: 5)
    }

    func testUntouchedSheetHasNoConditionalFormats() {
        XCTAssertTrue(blank().effectiveConditionalFormats.isEmpty)
    }

    func testAddingAndQueryingRules() {
        let r = SheetConditionalFormat(kind: .cellValue, comparator: .greaterThan, minValue: "0", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        let sheet = blank().addingConditionalFormat(r)
        XCTAssertEqual(sheet.effectiveConditionalFormats.count, 1)
        XCTAssertEqual(sheet.conditionalFormats(row: 2, col: 0).first?.id, r.id)
        XCTAssertTrue(sheet.conditionalFormats(row: 2, col: 1).isEmpty)
    }

    func testRemovingARule() {
        let r = SheetConditionalFormat(kind: .cellValue, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        var sheet = blank().addingConditionalFormat(r)
        sheet = sheet.removingConditionalFormat(r.id)
        XCTAssertTrue(sheet.effectiveConditionalFormats.isEmpty)
    }

    // MARK: - Document round-trip

    func testCellValueRuleSurvivesDocumentRoundTrip() throws {
        let r = SheetConditionalFormat(
            kind: .cellValue, comparator: .greaterThan, minValue: "10",
            style: SheetCellFormat(isBold: true, fillHex: "#FF0000"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let sheet = blank().addingConditionalFormat(r)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        let restoredRule = try XCTUnwrap(restored.effectiveConditionalFormats.first)
        XCTAssertEqual(restoredRule.comparator, .greaterThan)
        XCTAssertEqual(restoredRule.minValue, "10")
        XCTAssertEqual(restoredRule.style?.isBold, true)
        XCTAssertEqual(restoredRule.style?.fillHex, "#FF0000")
    }

    func testColorScaleRuleSurvivesDocumentRoundTrip() throws {
        let r = SheetConditionalFormat(
            kind: .colorScale,
            colorScaleStops: [
                SheetColorScaleStop(kind: .minimum, colorHex: "#FF0000"),
                SheetColorScaleStop(kind: .percentile, value: "50", colorHex: "#FFFF00"),
                SheetColorScaleStop(kind: .maximum, colorHex: "#00FF00"),
            ],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4
        )
        let sheet = blank().addingConditionalFormat(r)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        let stops = try XCTUnwrap(restored.effectiveConditionalFormats.first?.colorScaleStops)
        XCTAssertEqual(stops.count, 3)
        XCTAssertEqual(stops[1].kind, .percentile)
        XCTAssertEqual(stops[1].value, "50")
    }

    func testSheetWithoutConditionalFormatsKeyDecodesAsEmpty() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Legacy", "body": {"blocks": {}, "rootChildren": []},
         "columns": [], "isArchived": false, "isTrashed": false, "isFavorite": false,
         "tags": [], "linkedEntityIDs": [], "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"}
        """
        let decoded = try Sheet.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.effectiveConditionalFormats.isEmpty)
    }
}
