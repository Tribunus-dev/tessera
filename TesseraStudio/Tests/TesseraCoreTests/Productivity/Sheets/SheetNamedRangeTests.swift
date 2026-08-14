import XCTest
@testable import TesseraCore

/// `SheetNamedRange` (P0 0.1b): the on-disk mirror of the formula
/// engine's own (non-persisted) `NamedRange`, plus `Sheet`'s storage
/// of it and `SheetWorkbook`'s registration into a live engine.
@MainActor
final class SheetNamedRangeTests: XCTestCase {

    // MARK: - SheetNamedRange model

    func testRangeRefRoundTrips() {
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 2, row: 4))
        let stored = SheetNamedRange(name: "Rate", range: range)
        XCTAssertEqual(stored.rangeRef, range)
    }

    func testNegativeCoordinateProducesNilRangeRefRatherThanCrashing() {
        // Simulating hand-edited/corrupt JSON, not something the
        // normal init path can produce.
        let stored = SheetNamedRange(
            name: "Bad", sheet: nil,
            topLeftCol: -1, topLeftRow: 0,
            bottomRightCol: 2, bottomRightRow: 4
        )
        XCTAssertNil(stored.rangeRef)
    }

    func testCodableRoundTrip() throws {
        let original = SheetNamedRange(name: "Base", sheet: "Sheet2", topLeftCol: 1, topLeftRow: 1, bottomRightCol: 1, bottomRightRow: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetNamedRange.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Sheet storage

    private func blank() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 5, cols: 5)
    }

    func testUntouchedSheetHasNoNamedRanges() {
        XCTAssertTrue(blank().effectiveNamedRanges.isEmpty)
    }

    func testSettingAndReadingBackANamedRange() {
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0))
        let sheet = blank().settingNamedRange("Rate", range: range)
        XCTAssertEqual(sheet.effectiveNamedRanges["RATE"]?.rangeRef, range)
        XCTAssertEqual(sheet.effectiveNamedRanges["RATE"]?.name, "Rate", "display name keeps original casing")
    }

    func testSettingIsCaseInsensitiveForLookupButNotDisplay() {
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0))
        var sheet = blank().settingNamedRange("Rate", range: range)
        XCTAssertEqual(sheet.effectiveNamedRanges.count, 1)
        // Re-defining under a different case replaces the same entry,
        // matching "the user edited this named range's definition
        // again" rather than creating a duplicate.
        let range2 = RangeRef(topLeft: CellAddr(col: 1, row: 1), bottomRight: CellAddr(col: 1, row: 1))
        sheet = sheet.settingNamedRange("RATE", range: range2)
        XCTAssertEqual(sheet.effectiveNamedRanges.count, 1)
        XCTAssertEqual(sheet.effectiveNamedRanges["RATE"]?.rangeRef, range2)
        XCTAssertEqual(sheet.effectiveNamedRanges["RATE"]?.name, "RATE")
    }

    func testRemovingANamedRange() {
        let range = RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0))
        var sheet = blank().settingNamedRange("Rate", range: range)
        sheet = sheet.removingNamedRange("rate")
        XCTAssertTrue(sheet.effectiveNamedRanges.isEmpty)
    }

    func testRemovingAnUndefinedNameIsANoOp() {
        let sheet = blank()
        XCTAssertEqual(sheet.removingNamedRange("Nope").effectiveNamedRanges.count, 0)
    }

    func testNamedRangeSurvivesDocumentRoundTrip() throws {
        let range = RangeRef(topLeft: CellAddr(col: 2, row: 3), bottomRight: CellAddr(col: 2, row: 3))
        let sheet = blank().settingNamedRange("Total", range: range)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        XCTAssertEqual(restored.effectiveNamedRanges["TOTAL"]?.rangeRef, range)
    }

    /// A `Sheet` document written before named ranges existed has no
    /// "namedRanges" key at all - must decode as empty, not throw.
    func testSheetWithoutNamedRangesKeyDecodesAsEmpty() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Legacy", "body": {"blocks": {}, "rootChildren": []},
         "columns": [], "isArchived": false, "isTrashed": false, "isFavorite": false,
         "tags": [], "linkedEntityIDs": [], "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"}
        """
        let decoded = try Sheet.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.effectiveNamedRanges.isEmpty)
    }

    // MARK: - SheetWorkbook registration

    func testHydrateRegistersNamedRangesIntoTheEngine() {
        let sheet = blank()
            .settingCellText(row: 0, col: 0, "42")
            .settingNamedRange("Rate", range: RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0)))
        let workbook = SheetWorkbook()
        workbook.hydrate(from: sheet)
        workbook.apply(text: "=Rate*2", row: 1, col: 0)
        XCTAssertEqual(workbook.value(row: 1, col: 0), .number(84))
    }

    /// Re-hydrating the same sheet with an UPDATED named-range set must
    /// leave the engine matching the new definitions, not still
    /// carrying stale ones (or failing to register the new ones
    /// because the stale entries are still occupying those names).
    func testRefreshingASheetUpdatesItsNamedRanges() {
        let workbook = SheetWorkbook()
        let sheet1 = blank()
            .settingCellText(row: 0, col: 0, "10")
            .settingCellText(row: 1, col: 0, "20")
            .settingNamedRange("Rate", range: RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0)))
        workbook.hydrate(from: sheet1)
        workbook.apply(text: "=Rate", row: 2, col: 0)
        XCTAssertEqual(workbook.value(row: 2, col: 0), .number(10))

        // Re-hydrate the SAME sheet.id with "Rate" now pointing
        // elsewhere.
        var sheet2 = sheet1
        sheet2 = sheet2.settingNamedRange("Rate", range: RangeRef(topLeft: CellAddr(col: 0, row: 1), bottomRight: CellAddr(col: 0, row: 1)))
        workbook.hydrate(from: sheet2)
        workbook.apply(text: "=Rate", row: 2, col: 0)
        XCTAssertEqual(workbook.value(row: 2, col: 0), .number(20), "the refreshed definition must take effect, not the stale one")
    }

    func testUnloadingASheetUndefinesItsNamedRanges() {
        let workbook = SheetWorkbook()
        let sheet = blank()
            .settingCellText(row: 0, col: 0, "5")
            .settingNamedRange("Rate", range: RangeRef(topLeft: CellAddr(col: 0, row: 0), bottomRight: CellAddr(col: 0, row: 0)))
        workbook.hydrate(from: sheet)
        XCTAssertTrue(workbook.engine.namedRanges.keys.contains("RATE"))
        workbook.unload()
        XCTAssertFalse(workbook.engine.namedRanges.keys.contains("RATE"))
    }
}
