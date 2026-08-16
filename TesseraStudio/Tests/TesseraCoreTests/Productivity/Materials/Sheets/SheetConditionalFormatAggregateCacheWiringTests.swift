import XCTest
@testable import TesseraCore

// MARK: - SheetConditionalFormatAggregateCacheWiringTests
//
// P2-0 gap item a: SheetConditionalFormatAggregateCache
// (SheetConditionalFormat.swift:708-744) was ALREADY BUILT and unit-
// tested for its own memoize/invalidate behavior; what P2-0 shipped was
// only the SAFE-default no-cache paint path
// (docs/.scratch/p2-0-findings-a.md: "SheetGridView.cellView(row:col:)
// calls ... conditionalFormatOverlay(row:col:) with no cache: argument
// ... .top10/.aboveAverage/.uniqueValues/.duplicateValues rules simply
// don't match without an aggregate"). This track wired a real,
// viewmodel-scoped cache instance through
// (SheetsViewModel.swift's `SheetEditorViewModel
// .conditionalFormatAggregateCache` + its invalidation call sites, and
// SheetGridView.swift:201's `conditionalFormatOverlay(row:col:cache:)`
// call).
//
// This file tests the MECHANISM that wiring now exercises - passing a
// live `SheetConditionalFormatAggregateCache` through
// `Sheet.conditionalFormatOverlay(row:col:cache:)` and invalidating it
// after an edit changes the underlying aggregate - directly against
// `Sheet`, rather than through the full `SheetEditorViewModel`/
// `SheetStore`/`TesseraDataLayer` stack. `p2-0-findings-a.md`'s own
// prior scope note ("a UI-logic test is likely impractical for SwiftUI
// view bodies... verify wiring by careful reading") established this
// exact precedent for this exact class pair; the viewmodel-level call
// sites themselves (cache instantiation on `SheetEditorViewModel`,
// `invalidateAll()` at every value-mutating method, the
// `cache:`-argument threaded into `SheetGridView`'s call) were verified
// by reading, named in this track's structured result rather than
// re-derived here as an untestable-without-a-live-store integration.

final class SheetConditionalFormatAggregateCacheWiringTests: DoctrineTestCase {

    private func sheetWithColumnOfNumbers(_ values: [Double]) -> Sheet {
        var sheet = Sheet.makeBlank(title: "t", rows: values.count, cols: 1)
        for (row, value) in values.enumerated() {
            sheet = sheet.settingCellValue(row: row, col: 0, .number(value))
        }
        return sheet
    }

    private func fullColumnRule(kind: SheetConditionalFormatKind, rowCount: Int, configure: (inout SheetConditionalFormat) -> Void = { _ in }) -> SheetConditionalFormat {
        var rule = SheetConditionalFormat(
            kind: kind,
            style: SheetCellFormatOverlay(fillHex: "#FF0000"),
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: rowCount - 1
        )
        configure(&rule)
        return rule
    }

    // MARK: - Each of the four aggregate-dependent kinds resolves to a real overlay when a cache is supplied

    func testTop10RuleResolvesToARealOverlayWhenACacheIsSupplied() {
        let sheet = sheetWithColumnOfNumbers([10, 20, 30, 40, 50]).addingConditionalFormat(
            fullColumnRule(kind: .top10, rowCount: 5) { rule in
                rule.top10Count = "1"
            }
        )
        let cache = SheetConditionalFormatAggregateCache()

        // Without a cache: the documented-safe inert fallback (still
        // correct, still what a caller with no cache gets - not what
        // this test is about).
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 4, col: 0).fillHex, "no cache supplied - top10 cannot resolve, matches the pre-wiring safe default")

        // With a cache: the highest value (50, row 4) actually paints.
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 4, col: 0, cache: cache).fillHex, "#FF0000")
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex, "row 0 (value 10) is not in the top 1")
    }

    func testAboveAverageRuleResolvesToARealOverlayWhenACacheIsSupplied() {
        let sheet = sheetWithColumnOfNumbers([10, 20, 30]).addingConditionalFormat(
            fullColumnRule(kind: .aboveAverage, rowCount: 3)
        )
        let cache = SheetConditionalFormatAggregateCache()
        // Average = 20. Row 2 (30) is above; row 0 (10) is not.
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache).fillHex, "#FF0000")
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex)
    }

    func testUniqueValuesRuleResolvesToARealOverlayWhenACacheIsSupplied() {
        let sheet = sheetWithColumnOfNumbers([1, 1, 2]).addingConditionalFormat(
            fullColumnRule(kind: .uniqueValues, rowCount: 3)
        )
        let cache = SheetConditionalFormatAggregateCache()
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache).fillHex, "#FF0000", "2 appears once - unique")
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex, "1 appears twice - not unique")
    }

    func testDuplicateValuesRuleResolvesToARealOverlayWhenACacheIsSupplied() {
        let sheet = sheetWithColumnOfNumbers([1, 1, 2]).addingConditionalFormat(
            fullColumnRule(kind: .duplicateValues, rowCount: 3)
        )
        let cache = SheetConditionalFormatAggregateCache()
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex, "#FF0000", "1 appears twice - duplicate")
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache).fillHex, "2 appears once - not a duplicate")
    }

    // MARK: - Invalidation: a stale overlay must not survive an edit that changes the aggregate

    func testInvalidatingTheCacheAfterAnEditPicksUpTheNewAggregateRatherThanStaleData() {
        var sheet = sheetWithColumnOfNumbers([10, 20, 30]).addingConditionalFormat(
            fullColumnRule(kind: .top10, rowCount: 3) { rule in
                rule.top10Count = "1"
            }
        )
        let rule = sheet.effectiveConditionalFormats[0]
        let cache = SheetConditionalFormatAggregateCache()

        // Prime the cache: row 2 (30) is the top-1 value.
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache).fillHex, "#FF0000")
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex)

        // Edit: row 0 becomes the new highest value. Without
        // invalidation, `cache` would keep answering from the OLD
        // sorted-values snapshot (30 still "wins") - a real bug the
        // viewmodel's invalidateAll() call sites (SheetsViewModel.swift)
        // exist specifically to prevent.
        sheet = sheet.settingCellValue(row: 0, col: 0, .number(1000))

        // Without invalidating first: stale answer (still says row 2).
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache).fillHex, "#FF0000", "cache not yet invalidated - still answers from the pre-edit snapshot")

        cache.invalidate(rule.id)

        // After invalidation: recomputed against the CURRENT sheet -
        // row 0 (1000) is now the top-1 value, row 2 (30) no longer is.
        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex, "#FF0000")
        XCTAssertNil(sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache).fillHex, "must not still be highlighted - the cache must not be stale after invalidation")
    }

    func testInvalidateAllDropsEveryRulesCachedAggregate() {
        var sheet = sheetWithColumnOfNumbers([1, 2, 3]).addingConditionalFormat(
            fullColumnRule(kind: .top10, rowCount: 3) { rule in
                rule.top10Count = "1"
            }
        )
        let cache = SheetConditionalFormatAggregateCache()
        _ = sheet.conditionalFormatOverlay(row: 2, col: 0, cache: cache) // prime

        sheet = sheet.settingCellValue(row: 0, col: 0, .number(100))
        cache.invalidateAll()

        XCTAssertEqual(sheet.conditionalFormatOverlay(row: 0, col: 0, cache: cache).fillHex, "#FF0000", "invalidateAll (the blanket bulk-edit path SheetEditorViewModel uses) picks up the new top value")
    }
}
