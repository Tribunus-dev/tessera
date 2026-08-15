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
            style: SheetCellFormatOverlay(isBold: true, fillHex: "#FF0000"),
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

    func testNewRuleFieldsSurviveDocumentRoundTrip() throws {
        let r = SheetConditionalFormat(
            kind: .top10, priority: 4, stopIfTrue: true,
            top10Count: "15", top10IsPercent: true, top10IsBottom: true,
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 9
        )
        let sheet = blank().addingConditionalFormat(r)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        let restoredRule = try XCTUnwrap(restored.effectiveConditionalFormats.first)
        XCTAssertEqual(restoredRule.priority, 4)
        XCTAssertTrue(restoredRule.stopIfTrue)
        XCTAssertEqual(restoredRule.top10Count, "15")
        XCTAssertTrue(restoredRule.top10IsPercent)
        XCTAssertTrue(restoredRule.top10IsBottom)
    }

    // MARK: - P1 rule kinds: text / blanks / errors

    func testTextOperators() {
        let contains = SheetConditionalFormat(kind: .text, textOperator: .contains, textValue: "wor", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(contains.matches(.text("hello world")))
        XCTAssertFalse(contains.matches(.text("goodbye")))
        XCTAssertFalse(contains.matches(.number(42)), "non-text cells never match a text rule")

        let notContains = SheetConditionalFormat(kind: .text, textOperator: .notContains, textValue: "wor", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertFalse(notContains.matches(.text("hello world")))
        XCTAssertTrue(notContains.matches(.text("goodbye")))

        let begins = SheetConditionalFormat(kind: .text, textOperator: .beginsWith, textValue: "hel", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(begins.matches(.text("hello")))
        XCTAssertFalse(begins.matches(.text("shell")))

        let ends = SheetConditionalFormat(kind: .text, textOperator: .endsWith, textValue: "llo", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(ends.matches(.text("hello")))
        XCTAssertFalse(ends.matches(.text("hollow")))
    }

    func testBlanksAndErrors() {
        let blanks = SheetConditionalFormat(kind: .blanks, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(blanks.matches(.empty))
        XCTAssertFalse(blanks.matches(.text("x")))

        let notBlanks = SheetConditionalFormat(kind: .blanks, negate: true, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertFalse(notBlanks.matches(.empty))
        XCTAssertTrue(notBlanks.matches(.text("x")))

        let errors = SheetConditionalFormat(kind: .errors, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertTrue(errors.matches(.error("#DIV/0!")))
        XCTAssertFalse(errors.matches(.number(1)))

        let notErrors = SheetConditionalFormat(kind: .errors, negate: true, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertFalse(notErrors.matches(.error("#DIV/0!")))
        XCTAssertTrue(notErrors.matches(.number(1)))
    }

    // MARK: - P1 rule kinds: top10 / aboveAverage / unique / duplicate (aggregate-dependent)

    func testTop10CountAndPercent() {
        let aggregate = SheetConditionalFormatRangeAggregate(values: (1...10).map { CellValue.number(Double($0)) })

        let top3 = SheetConditionalFormat(kind: .top10, top10Count: "3", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 9)
        XCTAssertTrue(top3.matches(.number(10), aggregate: aggregate))
        XCTAssertTrue(top3.matches(.number(8), aggregate: aggregate))
        XCTAssertFalse(top3.matches(.number(7), aggregate: aggregate))
        XCTAssertFalse(top3.matches(.number(10)), "no aggregate means no match")

        let bottom2 = SheetConditionalFormat(kind: .top10, top10Count: "2", top10IsBottom: true, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 9)
        XCTAssertTrue(bottom2.matches(.number(1), aggregate: aggregate))
        XCTAssertTrue(bottom2.matches(.number(2), aggregate: aggregate))
        XCTAssertFalse(bottom2.matches(.number(3), aggregate: aggregate))

        let top20Percent = SheetConditionalFormat(kind: .top10, top10Count: "20", top10IsPercent: true, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 9)
        XCTAssertEqual(aggregate.percentileValue(80)!, 8.2, accuracy: 0.0001)
        XCTAssertTrue(top20Percent.matches(.number(9), aggregate: aggregate))
        XCTAssertFalse(top20Percent.matches(.number(8), aggregate: aggregate))
    }

    func testAboveAverageVariants() {
        // values 1,2,3,4,5 -> average 3, population stdDev = sqrt(2)
        let aggregate = SheetConditionalFormatRangeAggregate(values: [1, 2, 3, 4, 5].map { CellValue.number(Double($0)) })
        XCTAssertEqual(aggregate.average!, 3)
        XCTAssertEqual(aggregate.standardDeviation!, 2.0.squareRoot(), accuracy: 0.0001)

        let above = SheetConditionalFormat(kind: .aboveAverage, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        XCTAssertFalse(above.matches(.number(3), aggregate: aggregate))
        XCTAssertTrue(above.matches(.number(4), aggregate: aggregate))

        let aboveOrEqual = SheetConditionalFormat(kind: .aboveAverage, aboveAverageIncludesEqual: true, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        XCTAssertTrue(aboveOrEqual.matches(.number(3), aggregate: aggregate))

        let below = SheetConditionalFormat(kind: .aboveAverage, aboveAverageIsBelow: true, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        XCTAssertTrue(below.matches(.number(2), aggregate: aggregate))
        XCTAssertFalse(below.matches(.number(3), aggregate: aggregate))

        let twoStdDevAbove = SheetConditionalFormat(kind: .aboveAverage, aboveAverageStdDevCount: 2, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        XCTAssertFalse(twoStdDevAbove.matches(.number(5), aggregate: aggregate), "threshold is 3 + 2*sqrt(2) ~= 5.83")
    }

    func testUniqueAndDuplicateValues() {
        let aggregate = SheetConditionalFormatRangeAggregate(values: [.number(1), .number(2), .number(2), .text("a")])

        let unique = SheetConditionalFormat(kind: .uniqueValues, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 3)
        XCTAssertTrue(unique.matches(.number(1), aggregate: aggregate))
        XCTAssertFalse(unique.matches(.number(2), aggregate: aggregate))
        XCTAssertTrue(unique.matches(.text("a"), aggregate: aggregate))
        XCTAssertFalse(unique.matches(.empty, aggregate: aggregate))

        let duplicate = SheetConditionalFormat(kind: .duplicateValues, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 3)
        XCTAssertFalse(duplicate.matches(.number(1), aggregate: aggregate))
        XCTAssertTrue(duplicate.matches(.number(2), aggregate: aggregate))
    }

    // MARK: - Formula anchoring (relative-shift semantics)

    func testShiftedFormulaNoOpAtZeroDelta() {
        XCTAssertEqual(SheetConditionalFormat.shiftedFormula("=A1+B2", rowDelta: 0, colDelta: 0), "=A1+B2")
    }

    func testAnchoredFormulaShiftsRelativeReferencesFromTopLeft() {
        let rule = SheetConditionalFormat(kind: .formula, formula: "=A1>$B$1", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 4)
        XCTAssertEqual(rule.anchoredFormula(row: 0, col: 0), "=A1>$B$1")
        XCTAssertEqual(rule.anchoredFormula(row: 2, col: 1), "=B3>$B$1")
    }

    func testAnchoredFormulaNilForNonFormulaKind() {
        let rule = SheetConditionalFormat(kind: .cellValue, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0)
        XCTAssertNil(rule.anchoredFormula(row: 0, col: 0))
    }

    // MARK: - cfvo math: dataBar

    func testDataBarLengthMatchesDocumentedFormula() {
        // minLength + (v-min)/(max-min) * (maxLength-minLength), defaults 10/90.
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 5, minValue: 0, maxValue: 10), 50)
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 0, minValue: 0, maxValue: 10), 10)
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 10, minValue: 0, maxValue: 10), 90)
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 25, minValue: 0, maxValue: 100, minLength: 0, maxLength: 100), 25)
        // out-of-range values clamp to a full/empty bar rather than extrapolating
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 999, minValue: 0, maxValue: 10), 90)
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: -999, minValue: 0, maxValue: 10), 10)
        // degenerate range: no divide-by-zero, falls back to an empty bar
        XCTAssertEqual(SheetConditionalFormat.dataBarLength(value: 5, minValue: 5, maxValue: 5), 10)
    }

    func testDataBarLengthForRuleUsesRangeAggregateWhenBoundsUnset() {
        let rule = SheetConditionalFormat(kind: .dataBar, topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4)
        let aggregate = SheetConditionalFormatRangeAggregate(values: [.number(0), .number(5), .number(10)])
        XCTAssertEqual(rule.dataBarLength(for: 5, aggregate: aggregate)!, 50)
    }

    // MARK: - cfvo math: colorScale

    func testInterpolatedColorMatchesDocumentedPerChannelMath() {
        XCTAssertEqual(SheetConditionalFormat.interpolatedColor(from: "#FF0000", to: "#00FF00", fraction: 0.5), "#808000")
        XCTAssertEqual(SheetConditionalFormat.interpolatedColor(from: "#FF0000", to: "#00FF00", fraction: 0), "#FF0000")
        XCTAssertEqual(SheetConditionalFormat.interpolatedColor(from: "#FF0000", to: "#00FF00", fraction: 1), "#00FF00")
    }

    func testColorScaleColorInterpolatesAcrossMultipleStops() {
        let rule = SheetConditionalFormat(
            kind: .colorScale,
            colorScaleStops: [
                SheetColorScaleStop(kind: .minimum, colorHex: "#FF0000"),
                SheetColorScaleStop(kind: .percentile, value: "50", colorHex: "#FFFF00"),
                SheetColorScaleStop(kind: .maximum, colorHex: "#00FF00"),
            ],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 1
        )
        let aggregate = SheetConditionalFormatRangeAggregate(values: [.number(0), .number(10)])
        XCTAssertEqual(rule.colorScaleColor(for: 0, aggregate: aggregate), "#FF0000")
        XCTAssertEqual(rule.colorScaleColor(for: 10, aggregate: aggregate), "#00FF00")
        XCTAssertEqual(rule.colorScaleColor(for: 5, aggregate: aggregate), "#FFFF00")
        XCTAssertEqual(rule.colorScaleColor(for: 2.5, aggregate: aggregate), "#FF8000")
    }

    // MARK: - cfvo math: iconSet

    func testIconIndexUsesGteThresholds() {
        let thresholds = [33.0, 67.0]
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 0, thresholds: thresholds), 0)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 32.9, thresholds: thresholds), 0)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 33, thresholds: thresholds), 1)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 66.9, thresholds: thresholds), 1)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 67, thresholds: thresholds), 2)
        XCTAssertEqual(SheetConditionalFormat.iconIndex(for: 100, thresholds: thresholds), 2)
    }

    func testIconIndexForRuleParsesStoredThresholds() {
        let rule = SheetConditionalFormat(
            kind: .iconSet, iconSetID: "3TrafficLights1", iconSetThresholds: ["33", "67"],
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4
        )
        XCTAssertEqual(rule.iconIndex(for: 50), 1)
    }

    // MARK: - Priority / stopIfTrue winner matrix

    func testStopIfTrueHaltsLowerPriorityRules() {
        let a = SheetConditionalFormat(
            kind: .cellValue, priority: 1, stopIfTrue: true, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#111111"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let b = SheetConditionalFormat(
            kind: .cellValue, priority: 2, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(isBold: true, fillHex: "#222222"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let overlay = [a, b].winningOverlay(for: .number(5))
        XCTAssertEqual(overlay.fillHex, "#111111")
        XCTAssertNil(overlay.isBold, "b never ran - a's stopIfTrue cut it off entirely")
    }

    func testNonStoppingRulesMergePerPropertyByPriority() {
        let a = SheetConditionalFormat(
            kind: .cellValue, priority: 1, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#111111"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let b = SheetConditionalFormat(
            kind: .cellValue, priority: 2, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(isBold: true, fillHex: "#222222"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let c = SheetConditionalFormat(
            kind: .cellValue, priority: 3, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#333333", textHex: "#AAAAAA"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        // Passed out of priority order to prove sorting happens
        // regardless of array order.
        let overlay = [c, a, b].winningOverlay(for: .number(5))
        XCTAssertEqual(overlay.fillHex, "#111111", "a (priority 1) wins the fillHex conflict")
        XCTAssertEqual(overlay.isBold, true, "only b sets isBold")
        XCTAssertEqual(overlay.textHex, "#AAAAAA", "only c sets textHex")
    }

    func testNonMatchingHigherPriorityRuleIsSkipped() {
        let a = SheetConditionalFormat(
            kind: .cellValue, priority: 1, comparator: .greaterThan, minValue: "100",
            style: SheetCellFormatOverlay(fillHex: "#111111"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let b = SheetConditionalFormat(
            kind: .cellValue, priority: 2, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#222222"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        XCTAssertEqual([a, b].winningOverlay(for: .number(5)).fillHex, "#222222")
    }

    func testEqualPriorityBreaksTiesOnArrayOrder() {
        let first = SheetConditionalFormat(
            kind: .cellValue, priority: 1, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#111111"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        let second = SheetConditionalFormat(
            kind: .cellValue, priority: 1, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#222222"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0
        )
        XCTAssertEqual([first, second].winningOverlay(for: .number(5)).fillHex, "#111111")
        XCTAssertEqual([second, first].winningOverlay(for: .number(5)).fillHex, "#222222")
    }

    func testSheetConditionalFormatOverlayResolvesPriorityAndStopIfTrue() {
        var sheet = blank()
        let low = SheetConditionalFormat(
            kind: .cellValue, priority: 3, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(textHex: "#AAAAAA"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4
        )
        let mid = SheetConditionalFormat(
            kind: .cellValue, priority: 2, stopIfTrue: true, comparator: .greaterThan, minValue: "0",
            style: SheetCellFormatOverlay(fillHex: "#00FF00"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4
        )
        let high = SheetConditionalFormat(
            kind: .cellValue, priority: 1, comparator: .greaterThan, minValue: "100",
            style: SheetCellFormatOverlay(fillHex: "#FF0000"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 4
        )
        sheet = sheet.addingConditionalFormat(low).addingConditionalFormat(mid).addingConditionalFormat(high)
        sheet = sheet.settingCellValue(row: 2, col: 0, .number(5))

        let overlay = sheet.conditionalFormatOverlay(row: 2, col: 0)
        // high (priority 1) doesn't match (5 is not > 100); mid
        // (priority 2) matches and stops evaluation before low
        // (priority 3) ever runs.
        XCTAssertEqual(overlay.fillHex, "#00FF00")
        XCTAssertNil(overlay.textHex)
    }

    // MARK: - Aggregate cache

    func testAggregateCacheHitsAndInvalidates() throws {
        let sheet = blank().settingCellValue(row: 0, col: 0, .number(1)).settingCellValue(row: 1, col: 0, .number(2))
        let rule = SheetConditionalFormat(kind: .top10, top10Count: "1", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 1)
        let cache = SheetConditionalFormatAggregateCache()

        let firstMax = try XCTUnwrap(cache.aggregate(for: rule, in: sheet)?.maximum)
        XCTAssertEqual(firstMax, 2)

        let mutated = sheet.settingCellValue(row: 1, col: 0, .number(20))
        let staleMax = try XCTUnwrap(cache.aggregate(for: rule, in: mutated)?.maximum)
        XCTAssertEqual(staleMax, 2, "stale until invalidate() is called")

        cache.invalidate(rule.id)
        let refreshedMax = try XCTUnwrap(cache.aggregate(for: rule, in: mutated)?.maximum)
        XCTAssertEqual(refreshedMax, 20)
    }
}
