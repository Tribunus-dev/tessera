import XCTest
@testable import TesseraCore

/// `SheetPivotDefinition` (P0 0.1e, the "pivot list" half): the
/// lightweight pivot-table registry `SheetWorkbook` doesn't compute
/// against yet - this ships and tests the definition model itself.
final class SheetPivotDefinitionTests: XCTestCase {

    private func definition(
        rowFields: [String] = [],
        columnFields: [String] = [],
        dataFields: [SheetPivotDataField] = [],
        filterFields: [String] = []
    ) -> SheetPivotDefinition {
        SheetPivotDefinition(
            name: "Regional Sales",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 3, bottomRightRow: 20,
            rowFields: rowFields, columnFields: columnFields, dataFields: dataFields, filterFields: filterFields
        )
    }

    // MARK: - Source range

    func testSourceRangeRefRoundTrips() {
        let d = definition()
        XCTAssertEqual(d.sourceRangeRef?.topLeft, CellAddr(col: 0, row: 0))
        XCTAssertEqual(d.sourceRangeRef?.bottomRight, CellAddr(col: 3, row: 20))
    }

    func testNegativeCoordinateProducesNilSourceRangeRef() {
        let d = SheetPivotDefinition(name: "Bad", topLeftCol: -1, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 2)
        XCTAssertNil(d.sourceRangeRef)
    }

    // MARK: - Field lists

    func testFieldListsDefaultEmpty() {
        let d = SheetPivotDefinition(name: "Empty", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1)
        XCTAssertTrue(d.rowFields.isEmpty)
        XCTAssertTrue(d.columnFields.isEmpty)
        XCTAssertTrue(d.dataFields.isEmpty)
        XCTAssertTrue(d.filterFields.isEmpty)
    }

    func testFieldListsPreserveOrder() {
        let d = definition(
            rowFields: ["Region", "Rep"],
            columnFields: ["Quarter"],
            dataFields: [
                SheetPivotDataField(fieldName: "Revenue", aggregation: .sum),
                SheetPivotDataField(fieldName: "Units", aggregation: .count),
            ],
            filterFields: ["Status"]
        )
        XCTAssertEqual(d.rowFields, ["Region", "Rep"])
        XCTAssertEqual(d.dataFields.map(\.aggregation), [.sum, .count])
    }

    // MARK: - Sheet storage

    private func blank() -> Sheet {
        Sheet.makeBlank(title: "Model", rows: 21, cols: 4)
    }

    func testUntouchedSheetHasNoPivotDefinitions() {
        XCTAssertTrue(blank().effectivePivotDefinitions.isEmpty)
    }

    func testAddingAndRemovingADefinition() {
        let d = definition()
        var sheet = blank().addingPivotDefinition(d)
        XCTAssertEqual(sheet.effectivePivotDefinitions.count, 1)
        XCTAssertEqual(sheet.effectivePivotDefinitions.first?.id, d.id)

        sheet = sheet.removingPivotDefinition(d.id)
        XCTAssertTrue(sheet.effectivePivotDefinitions.isEmpty)
    }

    // MARK: - Document round-trip

    func testPivotDefinitionSurvivesDocumentRoundTrip() throws {
        let d = definition(
            rowFields: ["Region"],
            dataFields: [SheetPivotDataField(fieldName: "Revenue", aggregation: .average)]
        )
        let sheet = blank().addingPivotDefinition(d)
        let restored = try Sheet.from(jsonData: sheet.jsonData())
        let restoredDef = try XCTUnwrap(restored.effectivePivotDefinitions.first)
        XCTAssertEqual(restoredDef.name, "Regional Sales")
        XCTAssertEqual(restoredDef.rowFields, ["Region"])
        XCTAssertEqual(restoredDef.dataFields.first?.fieldName, "Revenue")
        XCTAssertEqual(restoredDef.dataFields.first?.aggregation, .average)
    }

    func testSheetWithoutPivotDefinitionsKeyDecodesAsEmpty() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Legacy", "body": {"blocks": {}, "rootChildren": []},
         "columns": [], "isArchived": false, "isTrashed": false, "isFavorite": false,
         "tags": [], "linkedEntityIDs": [], "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"}
        """
        let decoded = try Sheet.from(jsonData: Data(json.utf8))
        XCTAssertTrue(decoded.effectivePivotDefinitions.isEmpty)
    }
}
