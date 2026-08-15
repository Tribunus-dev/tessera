import XCTest
@testable import TesseraCore

// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, Calc cluster, item "1.12 ConditionalFormat evaluation":
// "integer priority (1 = highest, sheet-global), stopIfTrue... Documented
// cfvo math, hand-compute these exactly and pin as fixture cases: dataBar
// length = minLength + (v-min)/(max-min) * (maxLength-minLength);
// colorScale = per-channel linear interpolation between stop colors;
// iconSet = gte threshold buckets... Test: priority/stopIfTrue winner
// matrix on 3+ overlapping rules (construct a case where two rules would
// both fire and assert only the higher-priority one wins, then a
// stopIfTrue case that suppresses a lower-priority match entirely);
// databar/colorScale/iconSet numeric fixtures computed by hand from the
// formulas above, not read off whatever the code currently outputs."
final class SheetConditionalFormatTests: DoctrineTestCase {

    private func cellIsRule(
        id: UUID = UUID(), priority: Int, stopIfTrue: Bool = false,
        style: SheetCellFormatOverlay
    ) -> SheetConditionalFormat {
        // Always-true condition (value > 0, tested against 10) so every
        // rule in the matrix below unconditionally "would fire" - the
        // thing under test is priority/stopIfTrue resolution, not the
        // cellIs comparator itself.
        SheetConditionalFormat(
            id: id, kind: .cellValue, priority: priority, stopIfTrue: stopIfTrue,
            comparator: .greaterThan, minValue: "0",
            style: style,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
    }

    // MARK: - Priority winner matrix (per-property, not per-rule)

    func testHigherPriorityRuleWinsOnASharedPropertyWhileLowerPriorityFillsUnsetProperties() {
        let ruleA = cellIsRule(priority: 1, style: SheetCellFormatOverlay(fillHex: "#FF0000"))
        let ruleB = cellIsRule(priority: 2, style: SheetCellFormatOverlay(fillHex: "#0000FF", textHex: "#00FF00"))
        let overlay = [ruleA, ruleB].winningOverlay(for: .number(10))

        XCTAssertEqual(overlay.fillHex, "#FF0000", "priority 1 must win the shared fillHex property")
        XCTAssertEqual(overlay.textHex, "#00FF00", "priority 2 fills textHex - priority 1 never set it")
    }

    func testRuleOrderInTheArrayDoesNotAffectPriorityResolution() {
        // Same two rules as above, but stored in the opposite array
        // order - priority (not array position) must decide the winner.
        let ruleA = cellIsRule(priority: 1, style: SheetCellFormatOverlay(fillHex: "#FF0000"))
        let ruleB = cellIsRule(priority: 2, style: SheetCellFormatOverlay(fillHex: "#0000FF"))
        let overlay = [ruleB, ruleA].winningOverlay(for: .number(10))
        XCTAssertEqual(overlay.fillHex, "#FF0000")
    }

    /// "priority/stopIfTrue winner matrix on 3+ overlapping rules... a
    /// stopIfTrue case that suppresses a lower-priority match entirely."
    func testStopIfTrueSuppressesEveryLowerPriorityRuleEvenOnUnrelatedProperties() {
        let higherNumberButMiddlePriority = cellIsRule(priority: 2, style: SheetCellFormatOverlay(fillHex: "#AAAAAA"))
        let topPriorityStopIfTrue = cellIsRule(priority: 1, stopIfTrue: true, style: SheetCellFormatOverlay(fillHex: "#FF0000"))
        let lowestPriority = cellIsRule(priority: 3, style: SheetCellFormatOverlay(textHex: "#00FF00"))

        let overlay = [higherNumberButMiddlePriority, topPriorityStopIfTrue, lowestPriority]
            .winningOverlay(for: .number(10))

        XCTAssertEqual(overlay.fillHex, "#FF0000", "the stopIfTrue rule (priority 1) wins fillHex")
        XCTAssertNil(overlay.textHex, "priority 3's textHex must never be applied - stopIfTrue stops the walk entirely, not just outranks it")
    }

    func testNonMatchingHigherPriorityRuleDoesNotBlockALowerPriorityMatch() {
        // priority 1 does not match (value 10 fails a < 0 test);
        // priority 2 matches and must still apply.
        let doesNotMatch = SheetConditionalFormat(
            kind: .cellValue, priority: 1, comparator: .lessThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#FF0000"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let matches = cellIsRule(priority: 2, style: SheetCellFormatOverlay(fillHex: "#0000FF"))
        let overlay = [doesNotMatch, matches].winningOverlay(for: .number(10))
        XCTAssertEqual(overlay.fillHex, "#0000FF")
    }

    // MARK: - cfvo math: dataBar

    func testDataBarLengthMatchesTheDocumentedFormula() {
        // minLength + (v-min)/(max-min) * (maxLength-minLength)
        // = 10 + (5-0)/(10-0) * (90-10) = 10 + 0.5*80 = 50
        let length = SheetConditionalFormat.dataBarLength(value: 5, minValue: 0, maxValue: 10)
        XCTAssertEqual(length, 50, accuracy: 1e-9)
    }

    func testDataBarLengthAtRangeExtremesHitsMinAndMaxLength() {
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 0, minValue: 0, maxValue: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 10, minValue: 0, maxValue: 10), 90, accuracy: 1e-9)
    }

    func testDataBarLengthClampsValuesOutsideTheRange() {
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: -100, minValue: 0, maxValue: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 100, minValue: 0, maxValue: 10), 90, accuracy: 1e-9)
    }

    func testDataBarLengthWithDegenerateFlatRangeReturnsMinLength() {
        // "minValue == maxValue returns minLength ... rather than
        // dividing by zero" - documented degenerate case.
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 5, minValue: 5, maxValue: 5), 10, accuracy: 1e-9)
    }

    func testDataBarLengthHonorsCustomMinAndMaxLength() {
        // minLength 20, maxLength 80: 20 + 0.5*(80-20) = 50
        let length = SheetConditionalFormat.dataBarLength(value: 5, minValue: 0, maxValue: 10, minLength: 20, maxLength: 80)
        XCTAssertEqual(length, 50, accuracy: 1e-9)
    }

    // MARK: - cfvo math: colorScale

    func testInterpolatedColorAtHalfwayFractionAveragesEachChannel() {
        // (0,0,0) -> (255,255,255) at fraction 0.5: each channel
        // 0 + 0.5*(255-0) = 127.5, rounds to 128 = 0x80.
        let color = SheetConditionalFormat.interpolatedColor(from: "#000000", to: "#FFFFFF", fraction: 0.5)
        XCTAssertEqual(color, "#808080")
    }

    func testInterpolatedColorAtFractionZeroAndOneReturnsTheEndpointColorsExactly() {
        XCTAssertEqual(SheetConditionalFormat.interpolatedColor(from: "#102030", to: "#A0B0C0", fraction: 0), "#102030")
        XCTAssertEqual(SheetConditionalFormat.interpolatedColor(from: "#102030", to: "#A0B0C0", fraction: 1), "#A0B0C0")
    }

    func testInterpolatedColorPerChannelLinearMath() {
        // R: 10 -> 200, fraction 0.25 -> 10 + 0.25*190 = 57.5 -> 58 (0x3A)
        // G: 20 -> 220, fraction 0.25 -> 20 + 0.25*200 = 70       (0x46)
        // B: 30 -> 240, fraction 0.25 -> 30 + 0.25*210 = 82.5 -> 83 (0x53)
        let color = SheetConditionalFormat.interpolatedColor(from: "#0A141E", to: "#C8DCF0", fraction: 0.25)
        XCTAssertEqual(color, "#3A4653")
    }

    func testColorScaleColorOnARuleWithMinMaxStopsMatchesAggregateExtremes() {
        let rule = SheetConditionalFormat(
            kind: .colorScale,
            colorScaleStops: [
                SheetColorScaleStop(kind: .minimum, colorHex: "#000000"),
                SheetColorScaleStop(kind: .maximum, colorHex: "#FFFFFF"),
            ],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 1
        )
        let aggregate = SheetConditionalFormatRangeAggregate(values: [.number(0), .number(10)])
        XCTAssertEqual(rule.colorScaleColor(for: 0, aggregate: aggregate), "#000000")
        XCTAssertEqual(rule.colorScaleColor(for: 10, aggregate: aggregate), "#FFFFFF")
        XCTAssertEqual(rule.colorScaleColor(for: 5, aggregate: aggregate), "#808080")
    }

    func testColorScaleColorClampsToEndStopColorBeyondTheRange() {
        let rule = SheetConditionalFormat(
            kind: .colorScale,
            colorScaleStops: [
                SheetColorScaleStop(kind: .minimum, colorHex: "#000000"),
                SheetColorScaleStop(kind: .maximum, colorHex: "#FFFFFF"),
            ],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 1
        )
        let aggregate = SheetConditionalFormatRangeAggregate(values: [.number(0), .number(10)])
        XCTAssertEqual(rule.colorScaleColor(for: -100, aggregate: aggregate), "#000000")
        XCTAssertEqual(rule.colorScaleColor(for: 100, aggregate: aggregate), "#FFFFFF")
    }

    // MARK: - cfvo math: iconSet (gte threshold buckets)

    func testIconIndexUsesGreaterThanOrEqualThresholdBuckets() {
        // Documented default: 3TrafficLights1, ascending steps 0/33/67 -
        // two thresholds for a 3-icon set.
        let thresholds = [33.0, 67.0]
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 10, thresholds: thresholds), 0)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 33, thresholds: thresholds), 1, "gte: exactly AT a threshold counts as meeting it")
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 50, thresholds: thresholds), 1)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 67, thresholds: thresholds), 2)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 99, thresholds: thresholds), 2)
    }

    func testRuleIconIndexParsesStoredThresholdStrings() {
        let rule = SheetConditionalFormat(
            kind: .iconSet, iconSetID: "3TrafficLights1", iconSetThresholds: ["33", "67"],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        XCTAssertEqual(rule.iconIndex(for: 50), 1)
    }

    // MARK: - Round-trip identity (rule 2)

    func testEncodeDecodeIdentityForAFullyPopulatedRule() throws {
        let original = SheetConditionalFormat(
            kind: .dataBar,
            priority: 3,
            stopIfTrue: true,
            dataBarColorHex: "#336699",
            dataBarMinValue: "0",
            dataBarMaxValue: "100",
            sheet: "Sheet1",
            topLeftCol: 1, topLeftRow: 2, bottomRightCol: 5, bottomRightRow: 9
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SheetConditionalFormat.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Byte-identical re-encode (rule 2's third leg, where a canonical
    /// serialization exists - `.sortedKeys` output is deterministic for
    /// a synthesized `Codable` struct with no custom encode(to:)).
    func testTwoIndependentEncodesOfTheSameValueAreByteIdentical() throws {
        let rule = cellIsRule(priority: 1, style: SheetCellFormatOverlay(fillHex: "#ABCDEF"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(rule)
        let second = try encoder.encode(rule)
        XCTAssertEqual(first, second)
    }

    // MARK: - Formula anchoring (relative-shift, not structural-shift)

    func testAnchoredFormulaShiftsRelativeReferencesButNotAbsoluteOnes() {
        let rule = SheetConditionalFormat(
            kind: .formula, formula: "=A$1+$B1",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 4, bottomRightRow: 4
        )
        // Evaluated for the cell at (col 2, row 3): rowDelta=3, colDelta=2.
        // A$1: col relative (A->C), row absolute (stays $1).
        // $B1: col absolute (stays $B), row relative (1->4).
        XCTAssertEqual(rule.anchoredFormula(row: 3, col: 2), "=C$1+$B4")
    }

    func testAnchoredFormulaAtTheRulesOwnTopLeftIsUnchanged() {
        let rule = SheetConditionalFormat(
            kind: .formula, formula: "=A1>0",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 4, bottomRightRow: 4
        )
        XCTAssertEqual(rule.anchoredFormula(row: 0, col: 0), "=A1>0")
    }

    // MARK: - covers(row:col:)

    func testCoversReportsTrueOnlyInsideTheRulesRange() {
        let rule = SheetConditionalFormat(
            kind: .cellValue, topLeftCol: 1, topLeftRow: 1, bottomRightCol: 3, bottomRightRow: 3
        )
        XCTAssertTrue(rule.covers(row: 2, col: 2))
        XCTAssertTrue(rule.covers(row: 1, col: 1)) // top-left corner inclusive
        XCTAssertTrue(rule.covers(row: 3, col: 3)) // bottom-right corner inclusive
        XCTAssertFalse(rule.covers(row: 0, col: 2))
        XCTAssertFalse(rule.covers(row: 2, col: 4))
    }

    // MARK: - Sheet.effectiveConditionalFormats "nil means none" convention

    func testSheetWithNoConditionalFormatsReportsEmptyEffectiveList() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        XCTAssertTrue(sheet.effectiveConditionalFormats.isEmpty)
    }
}
