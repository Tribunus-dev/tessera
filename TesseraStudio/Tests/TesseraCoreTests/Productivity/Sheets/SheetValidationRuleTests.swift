import XCTest
@testable import TesseraCore

/// `SheetValidationRule` (P0 0.1c rule model; P1 1.13 adds
/// `errorStyle`/`hideDropDown`/`listSourceRange` plus the write-path
/// enforcement below): a data-validation rule bound to a range on a
/// `Sheet`. `SheetWorkbook` doesn't call any of this on cell edit yet -
/// this ships and tests the rule model plus its evaluation surface
/// (`Sheet.applyingInteractiveEntry`, `applyingNonInteractiveWrite`,
/// `invalidCells`).
final class SheetValidationRuleTests: XCTestCase {

    private func rule(
        kind: SheetValidationKind,
        comparator: SheetValidationComparator? = nil,
        min: String? = nil,
        max: String? = nil,
        list: [String]? = nil,
        listSourceRange: String? = nil,
        errorStyle: SheetValidationErrorStyle? = nil,
        hideDropDown: Bool? = nil,
        topLeftCol: Int = 0,
        topLeftRow: Int = 0,
        bottomRightCol: Int = 0,
        bottomRightRow: Int = 0
    ) -> SheetValidationRule {
        SheetValidationRule(
            kind: kind, comparator: comparator, minValue: min, maxValue: max, listValues: list,
            listSourceRange: listSourceRange, hideDropDown: hideDropDown, errorStyle: errorStyle,
            topLeftCol: topLeftCol, topLeftRow: topLeftRow, bottomRightCol: bottomRightCol, bottomRightRow: bottomRightRow
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

    // MARK: - errorStyle

    func testErrorStyleDefaultsToStopWhenUnset() {
        let r = rule(kind: .wholeNumber, comparator: .greaterThan, min: "0")
        XCTAssertNil(r.errorStyle)
        XCTAssertEqual(r.effectiveErrorStyle, .stop)
    }

    func testErrorStyleRoundTripsExplicitValue() throws {
        let r = rule(kind: .wholeNumber, comparator: .greaterThan, min: "0", errorStyle: .warning)
        let sheet = blank().addingValidationRule(r)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        XCTAssertEqual(restored.effectiveValidationRules.first?.effectiveErrorStyle, .warning)
    }

    /// A rule persisted before `errorStyle` existed - the field must
    /// be optional or this decode throws `keyNotFound` instead of
    /// defaulting, breaking every sheet saved before P1 1.13.
    func testLegacyPersistedRuleWithoutNewFieldsDecodes() throws {
        let ruleID = UUID().uuidString
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Legacy", "body": {"blocks": {}, "rootChildren": []},
         "columns": [], "isArchived": false, "isTrashed": false, "isFavorite": false,
         "tags": [], "linkedEntityIDs": [], "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z",
         "validationRules": [{"id": "\(ruleID)", "kind": "wholeNumber", "comparator": "greaterThan",
         "minValue": "0", "topLeftCol": 0, "topLeftRow": 0, "bottomRightCol": 0, "bottomRightRow": 0}]}
        """
        let decoded = try Sheet.from(jsonData: Data(json.utf8))
        let r = try XCTUnwrap(decoded.effectiveValidationRules.first)
        XCTAssertNil(r.errorStyle)
        XCTAssertEqual(r.effectiveErrorStyle, .stop)
        XCTAssertNil(r.hideDropDown)
        XCTAssertFalse(r.effectiveHideDropDown)
        XCTAssertNil(r.listSourceRange)
    }

    // MARK: - hideDropDown

    func testHideDropDownDefaultsToShownWhenUnset() {
        let r = rule(kind: .list, list: ["A", "B"])
        XCTAssertNil(r.hideDropDown)
        XCTAssertFalse(r.effectiveHideDropDown, "OOXML's own default (showDropDown omitted) shows the dropdown")
    }

    func testHideDropDownExplicitTrueHidesIt() {
        let r = rule(kind: .list, list: ["A", "B"], hideDropDown: true)
        XCTAssertTrue(r.effectiveHideDropDown)
    }

    // MARK: - listSourceRange

    func testListSourceRangeParsesToRangeRef() {
        let r = rule(kind: .list, listSourceRange: "A1:A3")
        let range = r.listSourceRangeRef
        XCTAssertEqual(range?.topLeft, CellAddr(col: 0, row: 0))
        XCTAssertEqual(range?.bottomRight, CellAddr(col: 0, row: 2))
        XCTAssertNil(range?.sheet)
    }

    func testListSourceRangeUnparseableStringYieldsNilRangeRef() {
        let r = rule(kind: .list, listSourceRange: "not a range")
        XCTAssertNil(r.listSourceRangeRef)
    }

    func testResolvedListValuesFallsBackToInlineLiteralsWhenNoSourceRange() {
        let r = rule(kind: .list, list: ["Red", "Green", "Blue"])
        XCTAssertEqual(blank().resolvedListValues(for: r), ["Red", "Green", "Blue"])
    }

    func testResolvedListValuesReadsSameSheetRangeText() {
        var sheet = blank()
        sheet = sheet.settingCellText(row: 0, col: 0, "Red")
        sheet = sheet.settingCellText(row: 1, col: 0, "Green")
        sheet = sheet.settingCellText(row: 2, col: 0, "Blue")
        let r = rule(kind: .list, listSourceRange: "A1:A3")
        XCTAssertEqual(sheet.resolvedListValues(for: r), ["Red", "Green", "Blue"])
    }

    func testResolvedListValuesDefersForAnotherSheetsRange() {
        let r = rule(kind: .list, listSourceRange: "Other!A1:A3")
        XCTAssertNil(blank().resolvedListValues(for: r), "cross-sheet resolution needs SheetWorkbook, not a lone Sheet")
    }

    func testListRuleWithRangeSourceIsSatisfiedAgainstResolvedValues() {
        var sheet = blank()
        sheet = sheet.settingCellText(row: 0, col: 0, "Red")
        sheet = sheet.settingCellText(row: 1, col: 0, "Green")
        let r = rule(kind: .list, listSourceRange: "A1:A2")
        let resolved = sheet.resolvedListValues(for: r)
        XCTAssertTrue(r.isSatisfied(by: .text("Red"), resolvedListValues: resolved))
        XCTAssertFalse(r.isSatisfied(by: .text("Purple"), resolvedListValues: resolved))
    }

    // MARK: - Interactive entry (blocks on .stop)

    func testInteractiveEntryRejectsAStopRuleViolation() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", errorStyle: .stop, bottomRightRow: 4)
        let sheet = blank().addingValidationRule(r)
        let result = sheet.applyingInteractiveEntry(.number(999), row: 0, col: 0)
        switch result {
        case .rejected(let rejectingRule):
            XCTAssertEqual(rejectingRule.id, r.id)
        case .accepted:
            XCTFail("a value violating an errorStyle = .stop rule must be rejected, not written")
        }
    }

    func testInteractiveEntryAcceptsASatisfyingValue() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", bottomRightRow: 4)
        let sheet = blank().addingValidationRule(r)
        let result = sheet.applyingInteractiveEntry(.number(5), row: 0, col: 0)
        guard case .accepted(let written, let violations) = result else {
            return XCTFail("a value satisfying every covering rule must be accepted")
        }
        XCTAssertEqual(written.cellValue(row: 0, col: 0), .number(5))
        XCTAssertTrue(violations.isEmpty)
    }

    func testInteractiveEntryAcceptsAndReportsAWarningViolationWithoutBlocking() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", errorStyle: .warning, bottomRightRow: 4)
        let sheet = blank().addingValidationRule(r)
        let result = sheet.applyingInteractiveEntry(.number(999), row: 0, col: 0)
        guard case .accepted(let written, let violations) = result else {
            return XCTFail("an errorStyle = .warning violation must still write the value")
        }
        XCTAssertEqual(written.cellValue(row: 0, col: 0), .number(999))
        XCTAssertEqual(violations.map(\.id), [r.id])
    }

    func testInteractiveEntryUncoveredCellIsAlwaysAccepted() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10")
        let sheet = blank().addingValidationRule(r)
        let result = sheet.applyingInteractiveEntry(.number(999), row: 4, col: 4)
        guard case .accepted = result else {
            return XCTFail("a cell outside every rule's range has nothing to violate")
        }
    }

    // MARK: - Non-interactive write + audit (the core P1 1.13 contract)

    /// The exact scenario the deliverable is built around: a typed
    /// entry violating a stop rule is rejected, but the identical
    /// value written through the non-interactive path (engine/agent/
    /// paste) lands anyway, and the audit query then reports exactly
    /// that one cell.
    func testAgentToolWriteOfAnInvalidValueLandsAndAuditFindsExactlyThatCell() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", errorStyle: .stop, bottomRightRow: 4)
        var sheet = blank().addingValidationRule(r)

        // Path 1: interactive entry of the same value is rejected first,
        // proving the two paths really do enforce differently.
        if case .accepted = sheet.applyingInteractiveEntry(.number(999), row: 0, col: 0) {
            XCTFail("interactive entry should have rejected this value")
        }

        // Path 2: the non-interactive write (agent-tool / engine / paste
        // stand-in) always lands.
        sheet = sheet.applyingNonInteractiveWrite(.number(999), row: 0, col: 0)
        XCTAssertEqual(sheet.cellValue(row: 0, col: 0), .number(999), "non-interactive writes are never blocked")

        XCTAssertEqual(sheet.invalidCells(), [CellAddr(col: 0, row: 0)])
    }

    func testInvalidCellsIsEmptyWhenEveryCoveredCellSatisfiesItsRule() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", bottomRightRow: 4)
        var sheet = blank().addingValidationRule(r)
        sheet = sheet.applyingNonInteractiveWrite(.number(5), row: 0, col: 0)
        XCTAssertTrue(sheet.invalidCells().isEmpty)
    }

    func testInvalidCellsDeduplicatesWhenTwoRulesCoverTheSameViolatingCell() {
        // Both rules cover the same default (0,0)-(0,0) cell and both
        // reject 999 - a real overlap, not just two rules where only
        // one happens to fail.
        let stop = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", errorStyle: .stop)
        let warning = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "500", errorStyle: .warning)
        var sheet = blank().addingValidationRule(stop).addingValidationRule(warning)
        sheet = sheet.applyingNonInteractiveWrite(.number(999), row: 0, col: 0)
        XCTAssertEqual(sheet.invalidCells(), [CellAddr(col: 0, row: 0)])
    }

    func testInvalidCellsReturnsRowMajorSortedOrder() {
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", bottomRightCol: 4, bottomRightRow: 4)
        var sheet = blank().addingValidationRule(r)
        sheet = sheet.applyingNonInteractiveWrite(.number(999), row: 2, col: 3)
        sheet = sheet.applyingNonInteractiveWrite(.number(999), row: 0, col: 4)
        sheet = sheet.applyingNonInteractiveWrite(.number(999), row: 2, col: 0)
        XCTAssertEqual(
            sheet.invalidCells(),
            [CellAddr(col: 4, row: 0), CellAddr(col: 0, row: 2), CellAddr(col: 3, row: 2)]
        )
    }

    func testInvalidCellsClampsARuleRangeLargerThanTheSheetInsteadOfCrashing() {
        // A rule persisted over, say, a whole column extends far past
        // the 5x5 blank sheet's actual grid.
        let r = rule(kind: .wholeNumber, comparator: .lessThanOrEqual, min: "10", bottomRightRow: 100_000)
        var sheet = blank().addingValidationRule(r)
        sheet = sheet.applyingNonInteractiveWrite(.number(999), row: 4, col: 0)
        XCTAssertEqual(sheet.invalidCells(), [CellAddr(col: 0, row: 4)])
    }
}
