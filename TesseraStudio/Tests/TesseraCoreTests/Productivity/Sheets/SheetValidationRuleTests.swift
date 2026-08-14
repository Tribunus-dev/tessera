import XCTest
@testable import TesseraCore

/// `SheetValidationRule` (P0 0.1c): a data-validation rule bound to a
/// range on a `Sheet`. `SheetWorkbook` doesn't check these on cell
/// edit yet - this ships and tests the rule model itself.
final class SheetValidationRuleTests: XCTestCase {

    private func rule(
        kind: SheetValidationKind,
        comparator: SheetValidationComparator? = nil,
        min: String? = nil,
        max: String? = nil,
        list: [String]? = nil
    ) -> SheetValidationRule {
        SheetValidationRule(
            kind: kind, comparator: comparator, minValue: min, maxValue: max, listValues: list,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
    }

    // MARK: - Empty cells always pass

    func testEmptyCellAlwaysSatisfiesEveryKind() {
        for kind in SheetValidationKind.allCases {
            let r = rule(kind: kind, comparator: .greaterThan, min: "0")
            XCTAssertTrue(r.isSatisfied(by: .empty), "\(kind) should not reject an empty cell")
        }
    }

    // MARK: - Whole number / decimal

    func testWholeNumberRejectsFractional() {
        let r = rule(kind: .wholeNumber, comparator: .greaterThanOrEqual, min: "0")
        XCTAssertTrue(r.isSatisfied(by: .number(5)))
        XCTAssertFalse(r.isSatisfied(by: .number(5.5)))
    }

    func testDecimalAcceptsFractional() {
        let r = rule(kind: .decimal, comparator: .between, min: "0", max: "10")
        XCTAssertTrue(r.isSatisfied(by: .number(5.5)))
    }

    func testWrongValueKindFails() {
        let r = rule(kind: .wholeNumber, comparator: .greaterThan, min: "0")
        XCTAssertFalse(r.isSatisfied(by: .text("hello")))
    }

    // MARK: - Comparators

    func testBetween() {
        let r = rule(kind: .decimal, comparator: .between, min: "1", max: "10")
        XCTAssertTrue(r.isSatisfied(by: .number(5)))
        XCTAssertTrue(r.isSatisfied(by: .number(1)))
        XCTAssertTrue(r.isSatisfied(by: .number(10)))
        XCTAssertFalse(r.isSatisfied(by: .number(11)))
        XCTAssertFalse(r.isSatisfied(by: .number(0)))
    }

    func testNotBetween() {
        let r = rule(kind: .decimal, comparator: .notBetween, min: "1", max: "10")
        XCTAssertFalse(r.isSatisfied(by: .number(5)))
        XCTAssertTrue(r.isSatisfied(by: .number(11)))
    }

    func testEqualToAndNotEqualTo() {
        let eq = rule(kind: .decimal, comparator: .equalTo, min: "42")
        XCTAssertTrue(eq.isSatisfied(by: .number(42)))
        XCTAssertFalse(eq.isSatisfied(by: .number(41)))

        let ne = rule(kind: .decimal, comparator: .notEqualTo, min: "42")
        XCTAssertFalse(ne.isSatisfied(by: .number(42)))
        XCTAssertTrue(ne.isSatisfied(by: .number(41)))
    }

    func testStrictAndInclusiveComparators() {
        XCTAssertFalse(rule(kind: .decimal, comparator: .greaterThan, min: "5").isSatisfied(by: .number(5)))
        XCTAssertTrue(rule(kind: .decimal, comparator: .greaterThanOrEqual, min: "5").isSatisfied(by: .number(5)))
        XCTAssertFalse(rule(kind: .decimal, comparator: .lessThan, min: "5").isSatisfied(by: .number(5)))
        XCTAssertTrue(rule(kind: .decimal, comparator: .lessThanOrEqual, min: "5").isSatisfied(by: .number(5)))
    }

    // MARK: - List

    func testListMembership() {
        let r = rule(kind: .list, list: ["Red", "Green", "Blue"])
        XCTAssertTrue(r.isSatisfied(by: .text("Green")))
        XCTAssertFalse(r.isSatisfied(by: .text("Purple")))
    }

    // MARK: - Date

    func testDateComparator() {
        let jan1 = Date(timeIntervalSince1970: 1_704_067_200)
        let dec31 = Date(timeIntervalSince1970: 1_735_603_200)
        let r = rule(kind: .date, comparator: .greaterThanOrEqual, min: String(jan1.timeIntervalSince1970))
        XCTAssertTrue(r.isSatisfied(by: .date(dec31)))
        XCTAssertFalse(r.isSatisfied(by: .date(Date(timeIntervalSince1970: 0))))
    }

    // MARK: - Text length

    func testTextLength() {
        let r = rule(kind: .textLength, comparator: .lessThanOrEqual, min: "5")
        XCTAssertTrue(r.isSatisfied(by: .text("abc")))
        XCTAssertFalse(r.isSatisfied(by: .text("abcdefgh")))
    }

    // MARK: - Custom

    func testCustomAlwaysReportsSatisfied() {
        // Can't evaluate a formula without a live engine - see the
        // method's doc comment. The caller wiring .custom rules is
        // responsible for the actual check.
        let r = SheetValidationRule(kind: .custom, formula: "=A1>0", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(r.isSatisfied(by: .number(-1)))
    }

    // MARK: - Coverage

    func testCoversChecksTheBoundingBox() {
        let r = SheetValidationRule(kind: .decimal, topLeftCol: 1, topLeftRow: 1, bottomRightCol: 3, bottomRightRow: 3)
        XCTAssertTrue(r.covers(row: 2, col: 2))
        XCTAssertTrue(r.covers(row: 1, col: 1))
        XCTAssertTrue(r.covers(row: 3, col: 3))
        XCTAssertFalse(r.covers(row: 0, col: 2))
        XCTAssertFalse(r.covers(row: 2, col: 4))
    }

    func testNegativeCoordinateProducesNilRangeRef() {
        let r = SheetValidationRule(kind: .decimal, topLeftCol: -1, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2)
        XCTAssertNil(r.rangeRef)
    }

    // MARK: - Sheet storage

    private func blank() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 5, cols: 5)
    }

    func testUntouchedSheetHasNoValidationRules() {
        XCTAssertTrue(blank().effectiveValidationRules.isEmpty)
    }

    func testAddingAndQueryingRules() {
        let r = SheetValidationRule(kind: .wholeNumber, comparator: .greaterThan, minValue: "0", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        let sheet = blank().addingValidationRule(r)
        XCTAssertEqual(sheet.effectiveValidationRules.count, 1)
        XCTAssertEqual(sheet.validationRules(row: 2, col: 0).first?.id, r.id)
        XCTAssertTrue(sheet.validationRules(row: 2, col: 1).isEmpty)
    }

    func testRemovingARule() {
        let r = SheetValidationRule(kind: .wholeNumber, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        var sheet = blank().addingValidationRule(r)
        sheet = sheet.removingValidationRule(r.id)
        XCTAssertTrue(sheet.effectiveValidationRules.isEmpty)
    }

    func testValidationRuleSurvivesDocumentRoundTrip() throws {
        let r = SheetValidationRule(
            kind: .list, listValues: ["A", "B"], errorMessage: "Pick A or B",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let sheet = blank().addingValidationRule(r)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        XCTAssertEqual(restored.effectiveValidationRules.first?.listValues, ["A", "B"])
        XCTAssertEqual(restored.effectiveValidationRules.first?.errorMessage, "Pick A or B")
    }

    func testSheetWithoutValidationRulesKeyDecodesAsEmpty() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Legacy", "body": {"blocks": {}, "rootChildren": []},
         "columns": [], "isArchived": false, "isTrashed": false, "isFavorite": false,
         "tags": [], "linkedEntityIDs": [], "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"}
        """
        let decoded = try Sheet.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.effectiveValidationRules.isEmpty)
    }
}
