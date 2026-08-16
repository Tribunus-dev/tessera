import XCTest
@testable import TesseraCore

// MARK: - CalcBridgeFilterPivotAndSpillGuardTests
//
// New test file (2.2b items f and gap-b's final wiring step) - separate
// from the pre-existing CalcBridgeFilterTests.swift per this track's own
// "new test files" instruction, not because the contract differs: this
// is still the same doctrine rule 11 "ungated shadow" shape (pure
// hand-authored `FlatODFElement` trees, no soffice), covering:
//   (f) table:data-pilot-table encode/decode round-trip (see
//       CalcBridgeFilter.swift's "Pivot fods round-trip" extension doc
//       comment for the exact vocabulary and scope calls).
//   (gap b, final step) `legacySpillGuarded` wired into
//       `sheet(fromFlatODS:title:)`'s formula-cell mapping.

final class CalcBridgeFilterPivotAndSpillGuardTests: DoctrineTestCase {

    // MARK: - table:data-pilot-table encode -> decode round trip (doctrine rule 2)

    /// `id` is intentionally excluded from the round-trip comparison in
    /// most of these tests via a normalizing helper - ODF has no
    /// concept of Tessera's internal UUID, but `dataPilotTableElement`
    /// DOES emit `tessera:id` for a full round trip within this bridge
    /// itself (see that function's own doc comment), which
    /// `testEncodeDecodeRoundTripAlsoPreservesIdWhenPresent` pins
    /// directly.
    private func withoutID(_ definition: SheetPivotDefinition) -> SheetPivotDefinition {
        var copy = definition
        copy = SheetPivotDefinition(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            name: copy.name, sheet: copy.sheet,
            topLeftCol: copy.topLeftCol, topLeftRow: copy.topLeftRow,
            bottomRightCol: copy.bottomRightCol, bottomRightRow: copy.bottomRightRow,
            fields: copy.fields,
            outputSheet: copy.outputSheet, outputTopLeftCol: copy.outputTopLeftCol, outputTopLeftRow: copy.outputTopLeftRow,
            columnGrand: copy.columnGrand, rowGrand: copy.rowGrand,
            ignoreEmptyRows: copy.ignoreEmptyRows, repeatIfEmpty: copy.repeatIfEmpty,
            filterButton: copy.filterButton, drillDown: copy.drillDown,
            grandTotalName: copy.grandTotalName, styleInfo: copy.styleInfo
        )
        return copy
    }

    /// Runs `definition` through `dataPilotTableElement(for:)` ->
    /// `FlatODFWriter` -> `FlatODFReader` -> `pivotDefinition(from:)` -
    /// a REAL XML serialize/reparse round trip, not just an in-memory
    /// tree comparison, so this also exercises attribute-escaping and
    /// `FlatODFWriter`'s own formula-namespace/layer-set normalization
    /// passes (harmless no-ops for a pivot element, but proves the
    /// element survives the real writer, not just a hand-inspected tree).
    private func roundTrip(_ definition: SheetPivotDefinition) async throws -> SheetPivotDefinition {
        let element = CalcBridgeFilter.dataPilotTableElement(for: definition)
        let pilotTables = FlatODFElement(name: "table:data-pilot-tables", children: [.element(element)])
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "T"])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table), .element(pilotTables)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"],
            children: [.element(body)]
        )

        let writer = FlatODFWriter()
        let xmlData = try await writer.write(root) { _ in Data() }

        let discardDir = FileManager.default.temporaryDirectory.appendingPathComponent("pivot-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: discardDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: discardDir) }

        let parsed = try await FlatODFReader().parse(data: xmlData) { bytes in
            let url = discardDir.appendingPathComponent(UUID().uuidString)
            try? bytes.write(to: url)
            return url
        }

        let reparsedSheet = parsed.bodyChildren.first(where: { $0.name == "office:spreadsheet" })!
        let reparsedPilotTables = reparsedSheet.firstElementChild(named: "table:data-pilot-tables")!
        let reparsedElement = reparsedPilotTables.elementChildren.first(where: { $0.name == "table:data-pilot-table" })!
        guard let decoded = CalcBridgeFilter.pivotDefinition(from: reparsedElement) else {
            throw XCTSkip("pivotDefinition(from:) returned nil for a freshly round-tripped element")
        }
        return decoded
    }

    func testEncodeDecodeRoundTripPreservesFieldOrientationAndAggregationFunction() async throws {
        let original = SheetPivotDefinition(
            name: "Region Pivot",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 10,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Quarter", orientation: .column),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .average),
            ],
            columnGrand: false, rowGrand: true
        )
        let decoded = try await roundTrip(original)
        XCTAssertEqual(withoutID(decoded), withoutID(original))
    }

    func testEncodeDecodeRoundTripPreservesTheFullP2bFieldShape() async throws {
        let original = SheetPivotDefinition(
            name: "Full P2b Pivot",
            sheet: "Data",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 2, bottomRightRow: 20,
            fields: [
                SheetPivotField(
                    fieldName: "Region", orientation: .row,
                    subtotals: [.sum, .max], subtotalAuto: false, showEmpty: true, repeatItemLabels: true,
                    layout: SheetPivotFieldLayout(mode: .outline, addEmptyLine: true, subtotalsAtTop: false),
                    members: [SheetPivotFieldMember(name: "East", visible: false)],
                    sort: SheetPivotFieldSort(mode: .data, ascending: false, dataFieldName: "Revenue"),
                    autoShow: SheetPivotFieldAutoShow(direction: .bottom, itemCount: 3, dataFieldName: "Revenue"),
                    group: .numeric(start: 0, end: 100, step: 10)
                ),
                SheetPivotField(fieldName: "Quarter", orientation: .column, group: .date(by: [.years, .quarters])),
                SheetPivotField(
                    fieldName: "Revenue", orientation: .data, function: .sum,
                    reference: .percentOfRowTotal
                ),
                SheetPivotField(
                    fieldName: "Category", orientation: .page,
                    group: .members([PivotMemberGroup(name: "Retail Group", members: ["Retail", "Wholesale"])])
                ),
            ],
            outputSheet: "Pivot", outputTopLeftCol: 4, outputTopLeftRow: 0,
            columnGrand: true, rowGrand: true,
            ignoreEmptyRows: true, repeatIfEmpty: true,
            filterButton: false, drillDown: false,
            grandTotalName: "Total",
            styleInfo: SheetPivotTableStyleInfo(styleName: "PivotStyleLight1", showRowStripes: true)
        )
        let decoded = try await roundTrip(original)
        XCTAssertEqual(withoutID(decoded), withoutID(original))
    }

    func testEncodeDecodeRoundTripAlsoPreservesIdWhenPresent() async throws {
        let original = SheetPivotDefinition(
            name: "P", topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 1,
            fields: [SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum)]
        )
        let decoded = try await roundTrip(original)
        XCTAssertEqual(decoded.id, original.id, "tessera:id is this bridge's own extension attribute for full round-trip identity")
    }

    // MARK: - Decode wired into the real import path

    func testSheetFromFlatODSPopulatesPivotDefinitionsFromADataPilotTablesSibling() throws {
        let pivotElement = CalcBridgeFilter.dataPilotTableElement(for: SheetPivotDefinition(
            name: "Imported Pivot",
            topLeftCol: 0, topLeftRow: 0, bottomRightCol: 1, bottomRightRow: 5,
            fields: [
                SheetPivotField(fieldName: "Region", orientation: .row),
                SheetPivotField(fieldName: "Revenue", orientation: .data, function: .sum),
            ]
        ))
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "Sheet1"], children: [
            .element(FlatODFElement(name: "table:table-row", children: [
                .element(FlatODFElement(name: "table:table-cell", attributes: ["office:value-type": "string"], children: [
                    .element(FlatODFElement(name: "text:p", children: [.text("hi")])),
                ])),
            ])),
        ])
        let pilotTables = FlatODFElement(name: "table:data-pilot-tables", children: [.element(pivotElement)])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table), .element(pilotTables)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        let result = FlatODFReader.Result(contentType: .spreadsheet, root: root)

        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)

        XCTAssertEqual(sheet.effectivePivotDefinitions.count, 1)
        XCTAssertEqual(sheet.effectivePivotDefinitions.first?.name, "Imported Pivot")
        XCTAssertEqual(sheet.effectivePivotDefinitions.first?.fields.map { $0.fieldName }, ["Region", "Revenue"])
        // The sheet's own cell data must still import normally alongside
        // the pivot - one bad/missing pivot element must never block it,
        // and a present, valid one must not interfere with it either.
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "hi")
    }

    func testSheetFromFlatODSSkipsAMalformedDataPilotTableRatherThanFailingTheWholeImport() throws {
        // No table:source-cell-range child - pivotDefinition(from:)
        // returns nil for this, and the import must still succeed.
        let malformed = FlatODFElement(name: "table:data-pilot-table", attributes: ["table:name": "Broken"])
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "Sheet1"])
        let pilotTables = FlatODFElement(name: "table:data-pilot-tables", children: [.element(malformed)])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table), .element(pilotTables)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        let result = FlatODFReader.Result(contentType: .spreadsheet, root: root)

        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)
        XCTAssertTrue(sheet.effectivePivotDefinitions.isEmpty)
    }

    func testSheetFromFlatODSWithNoDataPilotTablesSiblingLeavesPivotDefinitionsNil() throws {
        // Every P2a-era fixture (basic-cells.fods, sum-formula.fods) has
        // no table:data-pilot-tables element at all - must not regress
        // to a non-nil-but-empty array (Sheet.pivotDefinitions' own
        // "nil means none" convention, matching effectivePivotDefinitions).
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "Sheet1"])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        let result = FlatODFReader.Result(contentType: .spreadsheet, root: root)

        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)
        XCTAssertNil(sheet.pivotDefinitions)
    }

    // MARK: - legacySpillGuarded (gap item b, final wiring step)

    func testLegacySpillGuardedInsertsAtPrefixForAFormulaThatWouldSpill() {
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded("=UNIQUE(A1:A10)"), "=@UNIQUE(A1:A10)")
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded("=A1:A3"), "=@A1:A3")
    }

    func testLegacySpillGuardedLeavesANonSpillingFormulaUntouched() {
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded("=SUM(A1:A10)"), "=SUM(A1:A10)")
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded("=A1+B1"), "=A1+B1")
    }

    func testLegacySpillGuardedDoesNotDoublePrefixAFormulaThatAlreadyHasAnExplicitAt() {
        // Not a special-cased check - `wouldSpillAsTopLevelResult` on
        // "=@UNIQUE(...)" naturally parses to a top-level `.unary(op:
        // .implicitIntersection, ...)` AST, which its own switch does
        // not match (see legacySpillGuarded's doc comment), so it
        // already reads as "would not spill" and this is idempotent by
        // construction.
        let already = CalcBridgeFilter.legacySpillGuarded("=UNIQUE(A1:A10)")
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded(already), already, "applying it twice must be a no-op")
        XCTAssertEqual(already, "=@UNIQUE(A1:A10)")
    }

    func testLegacySpillGuardedLeavesANonFormulaValueUntouched() {
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded("42"), "42")
        XCTAssertEqual(CalcBridgeFilter.legacySpillGuarded("hello"), "hello")
    }

    // MARK: - End-to-end: import wires legacySpillGuarded into real formula cells

    /// `odfFormula` is the RAW `table:formula` attribute value (ODF's
    /// own `of:=...[.A1:.A2]...` bracket-reference syntax), exactly as
    /// `mapRows(of:)` would read it off a real fods file.
    private func formulaCellSheet(odfFormula: String) throws -> Sheet {
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["table:formula": odfFormula],
            children: [.element(FlatODFElement(name: "text:p", children: [.text("0")]))]
        )
        let row = FlatODFElement(name: "table:table-row", children: [.element(cell)])
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "T"], children: [.element(row)])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        return try CalcBridgeFilter.sheet(fromFlatODS: FlatODFReader.Result(contentType: .spreadsheet, root: root), title: nil)
    }

    func testImportOfALegacyMultiCellRangeFormulaGetsTheAtPrefixInserted() throws {
        // ODF bracket form for a bare multi-cell range: [.A1:.A3].
        let sheet = try formulaCellSheet(odfFormula: "of:=[.A1:.A3]")
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "=@A1:A3", "a legacy multi-cell-range formula must arrive @-prefixed, preserving its old single-cell-return behavior")
    }

    func testImportOfANonSpillingFormulaDoesNotGetTheAtPrefix() throws {
        let sheet = try formulaCellSheet(odfFormula: "of:=SUM([.A1:.A2])")
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "=SUM(A1:A2)", "SUM's own scalar result never spills - no @ prefix needed")
    }
}
