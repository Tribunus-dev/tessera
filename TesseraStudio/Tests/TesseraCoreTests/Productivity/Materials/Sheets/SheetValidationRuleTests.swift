import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.13 DataValidation evaluation":
// "validate at interactive entry (errorStyle stop/warning/info) PLUS
// audit-after (an 'invalid cells' query that surfaces violations);
// engine/agent/paste writes are RECORDED as invalid, never blocked...
// showDropDown is modeled internally as hideDropDown (the OOXML
// attribute is inverted - read the actual field name in
// SheetValidationRule.swift before writing an assertion that depends on
// the sense of this boolean...). Test: a typed entry violating a stop
// rule is rejected at the interactive path; an agent-tool-style direct
// write of the SAME invalid value lands (not rejected) and the audit
// query subsequently reports exactly that cell as violating."
final class SheetValidationRuleTests: DoctrineTestCase {

    private func sheetWithWholeNumberStopRule(min: String = "1", max: String = "10") -> Sheet {
        let sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 3)
        let rule = SheetValidationRule(
            kind: .wholeNumber, comparator: .between, minValue: min, maxValue: max,
            errorStyle: .stop,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        return sheet.addingValidationRule(rule)
    }

    // MARK: - Interactive entry: stop rule rejects

    func testInteractiveEntryViolatingAStopRuleIsRejected() {
        let sheet = sheetWithWholeNumberStopRule()
        let result = sheet.applyingInteractiveEntry(.number(999), row: 0, col: 0)
        guard case .rejected(let rule) = result else {
            return XCTFail("expected .rejected, got \(result)")
        }
        XCTAssertEqual(rule.effectiveErrorStyle, .stop)
    }

    func testInteractiveEntrySatisfyingAStopRuleIsAccepted() {
        let sheet = sheetWithWholeNumberStopRule()
        let result = sheet.applyingInteractiveEntry(.number(5), row: 0, col: 0)
        guard case .accepted(let updated, let nonBlocking) = result else {
            return XCTFail("expected .accepted")
        }
        XCTAssertTrue(nonBlocking.isEmpty)
        XCTAssertEqual(updated.cellValue(row: 0, col: 0), .number(5))
    }

    /// The other half of the same contract sentence: the SAME invalid
    /// value, written via the non-interactive path (engine/agent/paste),
    /// lands unconditionally.
    func testNonInteractiveWriteOfTheSameInvalidValueLandsWithoutRejection() {
        let sheet = sheetWithWholeNumberStopRule()
        let updated = sheet.applyingNonInteractiveWrite(.number(999), row: 0, col: 0)
        XCTAssertEqual(updated.cellValue(row: 0, col: 0), .number(999))
    }

    /// "...and the audit query subsequently reports exactly that cell as
    /// violating."
    func testAuditQueryReportsExactlyTheCellWrittenInvalidByTheNonInteractivePath() {
        let sheet = sheetWithWholeNumberStopRule()
        let updated = sheet.applyingNonInteractiveWrite(.number(999), row: 0, col: 0)
        XCTAssertEqual(updated.invalidCells(), [CellAddr(col: 0, row: 0)])
    }

    func testAuditQueryReportsNoViolationsWhenEveryCoveredCellSatisfiesItsRule() {
        let sheet = sheetWithWholeNumberStopRule()
        let updated = sheet.applyingNonInteractiveWrite(.number(5), row: 0, col: 0)
        XCTAssertTrue(updated.invalidCells().isEmpty)
    }

    // MARK: - warning/information styles never block interactive entry

    func testWarningStyleNeverRejectsAtInteractiveEntryButSurfacesAsNonBlocking() {
        let sheet0 = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        let rule = SheetValidationRule(
            kind: .wholeNumber, comparator: .between, minValue: "1", maxValue: "10",
            errorStyle: .warning,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let sheet = sheet0.addingValidationRule(rule)
        let result = sheet.applyingInteractiveEntry(.number(999), row: 0, col: 0)
        guard case .accepted(let updated, let nonBlocking) = result else {
            return XCTFail("a .warning rule must never reject - only .stop does")
        }
        XCTAssertEqual(updated.cellValue(row: 0, col: 0), .number(999))
        XCTAssertEqual(nonBlocking.count, 1)
        XCTAssertEqual(nonBlocking.first?.effectiveErrorStyle, .warning)
    }

    func testInformationStyleNeverRejectsAtInteractiveEntryButSurfacesAsNonBlocking() {
        let sheet0 = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        let rule = SheetValidationRule(
            kind: .wholeNumber, comparator: .between, minValue: "1", maxValue: "10",
            errorStyle: .information,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let sheet = sheet0.addingValidationRule(rule)
        let result = sheet.applyingInteractiveEntry(.number(999), row: 0, col: 0)
        guard case .accepted(_, let nonBlocking) = result else {
            return XCTFail("a .information rule must never reject")
        }
        XCTAssertEqual(nonBlocking.count, 1)
    }

    func testUnspecifiedErrorStyleDefaultsToStopPerOOXML() {
        let rule = SheetValidationRule(
            kind: .wholeNumber, comparator: .greaterThan, minValue: "0",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        XCTAssertEqual(rule.effectiveErrorStyle, .stop)
    }

    // MARK: - hideDropDown polarity (the OOXML attribute is inverted)

    func testHideDropDownDefaultsFalseMeaningTheDropdownIsShown() {
        let rule = SheetValidationRule(
            kind: .list, listValues: ["a", "b"],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        XCTAssertNil(rule.hideDropDown)
        XCTAssertFalse(rule.effectiveHideDropDown, "OOXML default (showDropDown omitted) is 'shown', i.e. hideDropDown=false")
    }

    func testHideDropDownTrueSuppressesTheDropdownArrow() {
        var rule = SheetValidationRule(
            kind: .list, listValues: ["a", "b"],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        rule.hideDropDown = true
        XCTAssertTrue(rule.effectiveHideDropDown)
    }

    // MARK: - List source resolution (P1: inline literals + same-workbook range refs)

    func testListRuleWithInlineLiteralsIsSatisfiedByAnyListedValue() {
        let rule = SheetValidationRule(
            kind: .list, listValues: ["red", "green", "blue"],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        XCTAssertTrue(rule.isSatisfied(by: .text("green")))
        XCTAssertFalse(rule.isSatisfied(by: .text("purple")))
    }

    func testListRuleWithRangeSourceResolvesMembershipFromLiveCellText() {
        var sheet = Sheet.makeBlank(title: "t", rows: 3, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 1, "small")
        sheet = sheet.settingCellText(row: 1, col: 1, "medium")
        sheet = sheet.settingCellText(row: 2, col: 1, "large")
        let rule = SheetValidationRule(
            kind: .list, listSourceRange: "B1:B3",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let resolved = sheet.resolvedListValues(for: rule)
        XCTAssertEqual(resolved, ["small", "medium", "large"])
    }

    // MARK: - Round-trip identity (rule 2)

    func testEncodeDecodeIdentityForAFullyPopulatedRule() throws {
        let original = SheetValidationRule(
            kind: .decimal,
            comparator: .lessThanOrEqual,
            minValue: "3.5",
            hideDropDown: true,
            errorMessage: "must be small",
            errorStyle: .warning,
            sheet: "Sheet2",
            topLeftCol: 2, topLeftRow: 2, bottomRightCol: 6, bottomRightRow: 6
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetValidationRule.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTwoIndependentEncodesOfTheSameValueAreByteIdentical() throws {
        let rule = SheetValidationRule(
            kind: .list, listValues: ["x", "y"],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(rule), try encoder.encode(rule))
    }

    // MARK: - Empty cell always satisfies every kind (validation, not required-field enforcement)

    func testEmptyCellSatisfiesEveryValidationKind() {
        let kinds: [SheetValidationKind] = [.wholeNumber, .decimal, .list, .date, .textLength, .custom]
        for kind in kinds {
            let rule = SheetValidationRule(kind: kind, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
            XCTAssertTrue(rule.isSatisfied(by: .empty), "\(kind) must treat an empty cell as satisfying the rule")
        }
    }

    // MARK: - Sheet.effectiveValidationRules "nil means none" convention

    func testSheetWithNoValidationRulesReportsEmptyEffectiveList() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        XCTAssertTrue(sheet.effectiveValidationRules.isEmpty)
    }
}
