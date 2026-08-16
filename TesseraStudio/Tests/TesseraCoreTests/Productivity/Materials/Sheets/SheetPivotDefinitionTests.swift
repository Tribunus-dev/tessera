import XCTest
@testable import TesseraCore

// MARK: - SheetPivotDefinitionTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md's P2-A
// sota-p2-core-report.md section 2.2 ("PivotTableStore - Calc"),
// design-contract steps 1-3 (P2a slice):
//   1. `SheetPivotField {fieldName, orientation row|column|page|data|
//      hidden, function?, subtotals, subtotalAuto, showEmpty,
//      repeatItemLabels, layout?, members}` - decode fallback
//      synthesizes fields from the legacy rowFields/columnFields/
//      dataFields/filterFields arrays when the new shape is absent;
//      encode writes BOTH forms until a future P3.
//   2. SheetPivotAggregation gains median, stdDevP, varianceP (9 -> 12).
//   3. Table-level: columnGrand/rowGrand (default true), ignoreEmptyRows,
//      repeatIfEmpty, filterButton, drillDown, grandTotalName?,
//      styleInfo?.
// `sort`/`autoShow`/`reference`/`group` (PivotGroupSpec, design contract
// step 4) are explicitly P2b per that section's own "Slices" line and
// the wave brief's scope carve-out - not present on `SheetPivotField`
// yet; see the P2-A findings file for the reasoning.
//
// The pinned fixture (`Fixtures/sheet-pivot-definition-p0.json`) is the
// P0 (pre-2.2a) wire shape - a data contract per doctrine bookkeeping,
// never edited by this file.

final class SheetPivotDefinitionTests: DoctrineTestCase {

    private func fixtureURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/Productivity/Materials/Sheets/<this file>
        // -> Tests/TesseraCoreTests/Fixtures/sheet-pivot-definition-p0.json
        let testsRoot = thisFile
            .deletingLastPathComponent() // <this file> -> Sheets/
            .deletingLastPathComponent() // Sheets -> Materials/
            .deletingLastPathComponent() // Materials -> Productivity/
            .deletingLastPathComponent() // Productivity -> TesseraCoreTests/
        return testsRoot.appendingPathComponent("Fixtures/sheet-pivot-definition-p0.json")
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: fixtureURL())
    }

    // MARK: - Legacy P0 fixture decode (required test 1)

    func testLegacyFixtureDecodesToIdenticalSemanticsAsBeforeTheFieldAdditions() throws {
        let data = try fixtureData()
        let decoded = try JSONDecoder().decode(SheetPivotDefinition.self, from: data)

        XCTAssertEqual(decoded.id, UUID(uuidString: "9B1DE1B2-9EFF-4B9E-9B0C-9E0A6E1B0C11"))
        XCTAssertEqual(decoded.name, "Region Revenue Pivot")
        XCTAssertEqual(decoded.sheet, "Data")
        XCTAssertEqual(decoded.topLeftCol, 0)
        XCTAssertEqual(decoded.topLeftRow, 0)
        XCTAssertEqual(decoded.bottomRightCol, 3)
        XCTAssertEqual(decoded.bottomRightRow, 20)
        XCTAssertEqual(decoded.outputSheet, "Pivot")
        XCTAssertEqual(decoded.outputTopLeftCol, 5)
        XCTAssertEqual(decoded.outputTopLeftRow, 0)

        // The exact semantics the P0 type exposed, now derived from the
        // synthesized `fields` rather than independently stored.
        XCTAssertEqual(decoded.rowFields, ["Region", "Rep"])
        XCTAssertEqual(decoded.columnFields, ["Quarter"])
        XCTAssertEqual(decoded.dataFields, [
            SheetPivotDataField(fieldName: "Revenue", aggregation: .sum),
            SheetPivotDataField(fieldName: "Units", aggregation: .average),
        ])
        XCTAssertEqual(decoded.filterFields, ["Category"])

        // Table-level additions all fall back to their documented
        // defaults on a P0-shaped payload that carries none of them.
        XCTAssertTrue(decoded.columnGrand)
        XCTAssertTrue(decoded.rowGrand)
        XCTAssertFalse(decoded.ignoreEmptyRows)
        XCTAssertFalse(decoded.repeatIfEmpty)
        XCTAssertTrue(decoded.filterButton)
        XCTAssertTrue(decoded.drillDown)
        XCTAssertNil(decoded.grandTotalName)
        XCTAssertNil(decoded.styleInfo)
    }

    func testLegacyFixtureSynthesizesFieldsInLegacyArrayOrderWithCorrectOrientations() throws {
        let data = try fixtureData()
        let decoded = try JSONDecoder().decode(SheetPivotDefinition.self, from: data)

        XCTAssertEqual(decoded.fields.count, 6, "2 row + 1 column + 2 data + 1 filter field")
        // Exact synthesis order per `synthesizeFields`: row fields, then
        // column fields, then data fields, then (legacy "filter") page
        // fields - matching the fixture's own array order within each
        // group.
        XCTAssertEqual(decoded.fields.map { $0.fieldName }, ["Region", "Rep", "Quarter", "Revenue", "Units", "Category"])

        let byName = Dictionary(uniqueKeysWithValues: decoded.fields.map { ($0.fieldName, $0) })
        XCTAssertEqual(byName["Region"]?.orientation, .row)
        XCTAssertEqual(byName["Rep"]?.orientation, .row)
        XCTAssertEqual(byName["Quarter"]?.orientation, .column)
        XCTAssertEqual(byName["Revenue"]?.orientation, .data)
        XCTAssertEqual(byName["Revenue"]?.function, .sum)
        XCTAssertEqual(byName["Units"]?.orientation, .data)
        XCTAssertEqual(byName["Units"]?.function, .average)
        XCTAssertEqual(byName["Category"]?.orientation, .page)

        // Row-field order is preserved (outermost first), not just set
        // membership - the P0 array was ordered and that ordering is a
        // real semantic (which field is the outer grouping level).
        XCTAssertEqual(decoded.fields.filter { $0.orientation == .row }.map { $0.fieldName }, ["Region", "Rep"])
    }

    // MARK: - New-shape round trip (doctrine rule 2)

    func testEncodeDecodeIdentityForAFullyPopulatedDefinition() throws {
        let original = SheetPivotDefinition(
            name: "Full Pivot",
            sheet: "Data",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 10,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row, repeatItemLabels: true, members: [SheetPivotFieldMember(name: "East")]),
                SheetPivotField(fieldName: "Quarter", orientation: .column, layout: SheetPivotFieldLayout(addEmptyLine: true)),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .median, subtotals: [.sum, .average], subtotalAuto: false),
                SheetPivotField(fieldName: "Category", orientation: .page, members: [SheetPivotFieldMember(name: "Retail", visible: false)]),
                SheetPivotField(fieldName: "Notes", orientation: .hidden),
            ],
            outputSheet: "Pivot", outputTopLeftCol: 4, outputTopLeftRow: 0,
            columnGrand: false, rowGrand: false,
            ignoreEmptyRows: true, repeatIfEmpty: true,
            filterButton: false, drillDown: false,
            grandTotalName: "Total",
            styleInfo: SheetPivotTableStyleInfo(styleName: "PivotStyleLight1")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetPivotDefinition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// The new shape's `fields` is preferred over the legacy arrays when
    /// BOTH are present in the payload (post-2.2a JSON, since encode
    /// writes both forms) - proves decode does not re-synthesize (and
    /// potentially lose per-field metadata like `layout`/`members`) when
    /// the richer shape is already there.
    func testDecodePrefersTheNewFieldsShapeOverLegacyArraysWhenBothArePresent() throws {
        let original = SheetPivotDefinition(
            name: "Rich Pivot",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 5,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row, repeatItemLabels: true),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .max),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetPivotDefinition.self, from: data)
        XCTAssertEqual(decoded.fields, original.fields, "repeatItemLabels/function survive because decode trusted `fields`, not a re-synthesis from the (lossy) legacy arrays")
    }

    /// Byte-identical re-encode (rule 2's third leg).
    func testTwoIndependentEncodesOfTheSameValueAreByteIdentical() throws {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1,
            fields: [SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(definition)
        let second = try encoder.encode(definition)
        XCTAssertEqual(first, second)
    }

    // MARK: - SheetPivotAggregation: 9 -> 12 (rule 5: trap stays pinned as a totality check)

    func testSheetPivotAggregationHasExactlyTwelveCasesIncludingTheThreeNewOnes() {
        // Independent oracle (doctrine rule 7): hardcoded from the design
        // contract, not derived from `CaseIterable.allCases.count` alone.
        let expected: Set<SheetPivotAggregation> = [
            .sum, .count, .countNumbers, .average, .min, .max, .product,
            .stdDev, .variance, .median, .stdDevP, .varianceP,
        ]
        XCTAssertEqual(Set(SheetPivotAggregation.allCases), expected)
        XCTAssertEqual(SheetPivotAggregation.allCases.count, 12)
    }

    // MARK: - Legacy dataFields view: nil function defaults to .sum

    func testDataFieldsViewDefaultsANilFunctionToSum() {
        let definition = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 0, bottomRightRow: 0,
            fields: [SheetPivotField(fieldName: "Revenue", orientation: .data)]
        )
        XCTAssertEqual(definition.dataFields, [SheetPivotDataField(fieldName: "Revenue", aggregation: .sum)])
    }

    // MARK: - Sheet.effectivePivotDefinitions "nil means none" convention

    func testSheetWithNoPivotDefinitionsReportsEmptyEffectiveList() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        XCTAssertTrue(sheet.effectivePivotDefinitions.isEmpty)
    }

    func testAddingAndRemovingAPivotDefinitionRoundTrips() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
        let definition = SheetPivotDefinition(name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1)
        let withPivot = sheet.addingPivotDefinition(definition)
        XCTAssertEqual(withPivot.effectivePivotDefinitions.map { $0.id }, [definition.id])

        let withoutPivot = withPivot.removingPivotDefinition(definition.id)
        XCTAssertTrue(withoutPivot.effectivePivotDefinitions.isEmpty)
    }

    func testRemovingAnUnknownPivotDefinitionIDIsANoOp() {
        let sheet = Sheet.makeBlank(title: "t", rows: 2, cols: 2)
            .addingPivotDefinition(SheetPivotDefinition(name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1))
        let unchanged = sheet.removingPivotDefinition(UUID())
        XCTAssertEqual(unchanged.effectivePivotDefinitions.count, 1)
    }
}
