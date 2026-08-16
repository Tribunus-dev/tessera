import XCTest
import Foundation
@testable import TesseraCore

// MARK: - CalcBridgeFilterTests
//
// Ungated coverage of CalcBridgeFilter's PURE fods->Sheet mapping half
// (`sheet(fromFlatODS:title:)`, `odfFormulaToTesseraSource(_:)`,
// `wouldSpillAsTopLevelResult(formulaSource:)`) - none of it touches
// `soffice`. This is the doctrine rule 11 "ungated shadow" of this same
// file's `CalcBridgeFilterFodsProbeTests` section below, matching
// ODGBridgeFilterTests.swift's split (hand-authored trees /
// `FlatODFReader().parse` against the pinned corpus fixtures, no live
// conversion) for the exact same reason: a plain `swift test` must cover
// the wiring logic even without LibreOffice installed.
//
// Contract source: CalcBridgeFilter.swift's own doc comment (P2-0 item
// 0.3/6, ratified decision 12) plus a real soffice conversion this pass
// actually ran (`soffice --headless --convert-to ods` then `--convert-to
// fods` against a hand-written CSV, LibreOffice 26.2.5.2
// (cd7284b4cbbfeb507e630c1aac019f4157393acb), 2026-08-15) to confirm the
// exact `table:formula="of:=SUM([.A1:.A2])"` bracket-reference wire
// shape this file's `odfFormulaToTesseraSource(_:)` converts - the same
// shape the pinned `sum-formula.fods` fixture already encodes.

final class CalcBridgeFilterTests: DoctrineTestCase {

    // MARK: - sheet(fromFlatODS:title:) against the pinned corpus fixtures

    private func fixturesRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/TesseraCoreTests/Productivity/ImportExport/CalcBridgeFilterTests.swift
        // -> Tests/TesseraCoreTests/Fixtures/RoundTrip
        return thisFile
            .deletingLastPathComponent() // ImportExport/
            .deletingLastPathComponent() // Productivity/
            .deletingLastPathComponent() // TesseraCoreTests/
            .appendingPathComponent("Fixtures/RoundTrip")
    }

    private func parsedFixture(_ name: String) async throws -> FlatODFReader.Result {
        let data = try Data(contentsOf: fixturesRoot().appendingPathComponent(name))
        return try await FlatODFReader().parse(data: data) { _ in URL(fileURLWithPath: "/dev/null") }
    }

    func testSheetFromFlatODSMapsBasicCellsFixtureLiteralValuesByPosition() async throws {
        let parsed = try await parsedFixture("basic-cells.fods")
        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: parsed, title: nil)

        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "Label")
        XCTAssertEqual(sheet.cellText(row: 0, col: 1), "10")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "Second")
        XCTAssertEqual(sheet.cellText(row: 1, col: 1), "20")
    }

    func testSheetFromFlatODSMapsSumFormulaFixtureAsLiveFormulaSourceNotABakedValue() async throws {
        // The exact contract this migration exists for: sum-formula.fods
        // pins `table:formula="of:=SUM([.A1:.A2])"` on its third row -
        // this must arrive as `"=SUM(A1:A2)"` (live source), never as
        // the baked "12" the pre-migration CSV path would have produced.
        let parsed = try await parsedFixture("sum-formula.fods")
        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: parsed, title: nil)

        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "5")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "7")
        XCTAssertEqual(sheet.cellText(row: 2, col: 0), "=SUM(A1:A2)")
        XCTAssertTrue(SheetWorkbook.isFormula(sheet.cellText(row: 2, col: 0)))
    }

    func testSheetFromFlatODSUsesTheExplicitTitleOverTheTableName() async throws {
        let parsed = try await parsedFixture("basic-cells.fods")
        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: parsed, title: "My Title")
        XCTAssertEqual(sheet.title, "My Title")
    }

    func testSheetFromFlatODSFallsBackToTheTableNameWhenNoTitleIsGiven() async throws {
        let parsed = try await parsedFixture("basic-cells.fods")
        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: parsed, title: nil)
        XCTAssertEqual(sheet.title, "Sheet1", "basic-cells.fods's table:table carries table:name=\"Sheet1\"")
    }

    func testSheetFromFlatODSThrowsMalformedDocumentForANonSpreadsheetContentType() async throws {
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.text"],
            children: [.element(FlatODFElement(name: "office:body"))]
        )
        let result = FlatODFReader.Result(contentType: .text, root: root)
        XCTAssertThrowsError(try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)) { error in
            guard case CalcBridgeFilter.FilterError.malformedDocument = error else {
                return XCTFail("expected .malformedDocument, got \(error)")
            }
        }
    }

    func testSheetFromFlatODSThrowsEmptyWorkbookWhenNoTableTableExists() async throws {
        let root = FlatODFElement(
            name: "office:document",
            attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"],
            children: [.element(FlatODFElement(name: "office:body", children: [
                .element(FlatODFElement(name: "office:spreadsheet")),
            ]))]
        )
        let result = FlatODFReader.Result(contentType: .spreadsheet, root: root)
        XCTAssertThrowsError(try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)) { error in
            guard case CalcBridgeFilter.FilterError.emptyWorkbook = error else {
                return XCTFail("expected .emptyWorkbook, got \(error)")
            }
        }
    }

    // MARK: - Hand-authored tree: row/column blank-run compaction (table:number-*-repeated)

    /// A `table:table` with a huge `table:number-rows-repeated` trailing
    /// blank run - real soffice output for a native .ods/.xls whose
    /// declared grid extent is far larger than its populated content
    /// (a fact this file's own doc comment states plainly, not
    /// reproduced by the CSV->ODS->fods probe this pass ran, since a
    /// CSV source has no such padding to carry forward). Must not force
    /// `Sheet.makeBlank` to allocate a million-row grid.
    private func tableWithHugeTrailingBlankRowRun() -> FlatODFElement {
        let row0 = FlatODFElement(name: "table:table-row", children: [
            .element(FlatODFElement(name: "table:table-cell", attributes: ["office:value-type": "string"], children: [
                .element(FlatODFElement(name: "text:p", children: [.text("only cell")])),
            ])),
        ])
        let blankRun = FlatODFElement(
            name: "table:table-row",
            attributes: ["table:number-rows-repeated": "1048575"],
            children: [.element(FlatODFElement(name: "table:table-cell"))]
        )
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "Huge"], children: [
            .element(row0), .element(blankRun),
        ])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        return root
    }

    func testSheetFromFlatODSDoesNotMaterializeAHugeTrailingBlankRowRun() throws {
        let root = tableWithHugeTrailingBlankRowRun()
        let result = FlatODFReader.Result(contentType: .spreadsheet, root: root)
        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)

        XCTAssertEqual(sheet.rowCount, 1, "the grid must be bounded to the last POPULATED row, not the declared repeat extent")
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "only cell")
    }

    func testSheetFromFlatODSExpandsARepeatedContentBearingCellUpToTheBoundedCeiling() throws {
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["office:value-type": "float", "office:value": "3", "table:number-columns-repeated": "5"],
            children: [.element(FlatODFElement(name: "text:p", children: [.text("3")]))]
        )
        let row = FlatODFElement(name: "table:table-row", children: [.element(cell)])
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "Repeated"], children: [.element(row)])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        let result = FlatODFReader.Result(contentType: .spreadsheet, root: root)

        let sheet = try CalcBridgeFilter.sheet(fromFlatODS: result, title: nil)

        XCTAssertEqual(sheet.columnCount, 5)
        for col in 0..<5 {
            XCTAssertEqual(sheet.cellText(row: 0, col: col), "3", "a genuinely content-bearing repeated cell duplicates its value across the repeat span")
        }
    }

    // MARK: - cellSourceText value-type coverage (hand-authored, one cell per test)

    private func singleCellSheet(_ cell: FlatODFElement) throws -> Sheet {
        let row = FlatODFElement(name: "table:table-row", children: [.element(cell)])
        let table = FlatODFElement(name: "table:table", attributes: ["table:name": "T"], children: [.element(row)])
        let spreadsheet = FlatODFElement(name: "office:spreadsheet", children: [.element(table)])
        let body = FlatODFElement(name: "office:body", children: [.element(spreadsheet)])
        let root = FlatODFElement(name: "office:document", attributes: ["office:mimetype": "application/vnd.oasis.opendocument.spreadsheet"], children: [.element(body)])
        return try CalcBridgeFilter.sheet(fromFlatODS: FlatODFReader.Result(contentType: .spreadsheet, root: root), title: nil)
    }

    func testCellSourceTextPrefersOfficeValueOverTheLocaleFormattedDisplayText() throws {
        // "1,234.5" is what a locale-formatted text:p would show; the
        // RAW office:value must be used instead so CellValue.classify
        // parses it as a number, not text containing a comma.
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["office:value-type": "float", "office:value": "1234.5"],
            children: [.element(FlatODFElement(name: "text:p", children: [.text("1,234.5")]))]
        )
        let sheet = try singleCellSheet(cell)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "1234.5")
    }

    func testCellSourceTextMapsBooleanValueTypeToUppercaseTrueFalse() throws {
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["office:value-type": "boolean", "office:boolean-value": "true"],
            children: [.element(FlatODFElement(name: "text:p", children: [.text("TRUE")]))]
        )
        let sheet = try singleCellSheet(cell)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "TRUE")
        XCTAssertEqual(CellValue.classify(sheet.cellText(row: 0, col: 0), columnType: .text), .checkbox(true))
    }

    func testCellSourceTextNormalizesABareDateValueSoItReclassifiesAsADate() throws {
        // Verified against a real soffice conversion this pass ran
        // (CSV "2026-08-15" -> ODS -> fods): office:date-value carries
        // a BARE date, no time, no timezone - which
        // ISO8601DateFormatter (CellValue.classify's parser, default
        // options) rejects outright without normalization.
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["office:value-type": "date", "office:date-value": "2026-08-15"],
            children: [.element(FlatODFElement(name: "text:p", children: [.text("2026-08-15")]))]
        )
        let sheet = try singleCellSheet(cell)
        let text = sheet.cellText(row: 0, col: 0)
        guard case .date = CellValue.classify(text, columnType: .date) else {
            return XCTFail("expected the normalized date text (\(text)) to reclassify as .date, not fall through to .text")
        }
    }

    func testCellSourceTextLeavesAFullyQualifiedDateTimeUntouched() throws {
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["office:value-type": "date", "office:date-value": "2026-08-15T14:30:00Z"],
            children: [.element(FlatODFElement(name: "text:p", children: [.text("2026-08-15 14:30")]))]
        )
        let sheet = try singleCellSheet(cell)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "2026-08-15T14:30:00Z")
    }

    func testCellSourceTextReturnsEmptyForATrulyEmptyCell() throws {
        let cell = FlatODFElement(name: "table:table-cell")
        let sheet = try singleCellSheet(cell)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "")
    }

    func testCellSourceTextFlattensNestedTextSpanMarkupToPlainText() throws {
        let cell = FlatODFElement(
            name: "table:table-cell",
            attributes: ["office:value-type": "string"],
            children: [.element(FlatODFElement(name: "text:p", children: [
                .text("Hello "),
                .element(FlatODFElement(name: "text:span", children: [.text("World")])),
                .text("!"),
            ]))]
        )
        let sheet = try singleCellSheet(cell)
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "Hello World!")
    }

    // MARK: - odfFormulaToTesseraSource(_:)

    func testOdfFormulaToTesseraSourceStripsTheOfNamespacePrefixAndBracketSyntaxForARange() {
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("of:=SUM([.A1:.A2])"), "=SUM(A1:A2)")
    }

    func testOdfFormulaToTesseraSourceConvertsABareCellReferenceWithNoSheetQualifier() {
        // Verified against the real soffice probe this pass ran:
        // `table:formula="of:=[.B1]"` for a plain same-sheet reference.
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("of:=[.B1]"), "=B1")
    }

    func testOdfFormulaToTesseraSourceConvertsABareSheetQualifiedCellReference() {
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("of:=[Sheet2.A1]"), "=Sheet2!A1")
    }

    func testOdfFormulaToTesseraSourceConvertsAQuotedSheetNameReference() {
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("of:=['My Sheet'.A1]"), "='My Sheet'!A1")
    }

    func testOdfFormulaToTesseraSourceDropsTheRepeatedSheetQualifierOnARangesRightCorner() {
        // Tessera's own range grammar carries a sheet qualifier on the
        // LEFT corner only (Lexer.scanRangeRef) - ODF may repeat it on
        // the right corner for a cross-sheet range; only the cell
        // address from that corner carries through.
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("of:=SUM([Sheet2.A1:Sheet2.B2])"), "=SUM(Sheet2!A1:B2)")
    }

    func testOdfFormulaToTesseraSourcePreservesAbsoluteDollarMarkers() {
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("of:=[.$A$1]"), "=$A$1")
    }

    func testOdfFormulaToTesseraSourceLeavesAStringLiteralContainingBracketsUntouched() {
        XCTAssertEqual(
            CalcBridgeFilter.odfFormulaToTesseraSource("of:=CONCATENATE(\"[not a ref]\",[.A1])"),
            "=CONCATENATE(\"[not a ref]\",A1)"
        )
    }

    func testOdfFormulaToTesseraSourceHandlesAPlainOooFormulaWithNoNamespacePrefixAtAll() {
        // Plain ODF 1.0/1.1 (no of:/oooc: namespace prefix at all) -
        // this file's own doc comment names this as a real, if older,
        // shape the same conversion must still handle.
        XCTAssertEqual(CalcBridgeFilter.odfFormulaToTesseraSource("=SUM([.A1:.A2])"), "=SUM(A1:A2)")
    }

    // MARK: - wouldSpillAsTopLevelResult(formulaSource:) - item 2's detection half
    //
    // These tests pin the DETECTION half only (unchanged since P2-0).
    // The MARKING half (`legacySpillGuarded`, wired into
    // `mapRows(of:)`) was unblocked at P2-B gap item b once Lexer/
    // Parser/Evaluator grew a real `@` operator - see
    // CalcBridgeFilterPivotAndSpillGuardTests.swift for its own coverage
    // (a separate new file per this track's file-ownership boundary).

    func testWouldSpillAsTopLevelResultIsTrueForATopLevelArrayReturningFunctionCall() {
        XCTAssertTrue(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=SEQUENCE(3)"))
        XCTAssertTrue(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=UNIQUE(A1:A10)"))
        XCTAssertTrue(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=FILTER(A1:A10,B1:B10)"))
    }

    func testWouldSpillAsTopLevelResultIsTrueForABareTopLevelMultiCellRange() {
        XCTAssertTrue(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=A1:A3"))
    }

    func testWouldSpillAsTopLevelResultIsFalseForABareTopLevelSingleCellRange() {
        // A "range" that happens to be one cell (A1:A1) has no
        // neighbours to spill into.
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=A1:A1"))
    }

    func testWouldSpillAsTopLevelResultIsFalseForAnOrdinaryScalarFormula() {
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=SUM(A1:A10)"))
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=A1+B1"))
    }

    func testWouldSpillAsTopLevelResultIsFalseForARangeUsedAsAFunctionArgumentNotTheWholeFormula() {
        // The range is an ARGUMENT here, not the top-level result -
        // SUM's own scalar result is what would land in the cell.
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=SUM(A1:A3)"))
    }

    func testWouldSpillAsTopLevelResultIsFalseForAPlainLiteralValue() {
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "42"))
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "hello"))
    }

    func testWouldSpillAsTopLevelResultIsFalseForAnUnparseableFormula() {
        XCTAssertFalse(CalcBridgeFilter.wouldSpillAsTopLevelResult(formulaSource: "=SUM(("))
    }
}

// MARK: - CalcBridgeFilterFodsProbeTests
//
// QUARANTINED EMPIRICAL PROBE (doctrine rule 10). Shells out to a real
// `soffice` to run CalcBridgeFilter's full ods->fods->Sheet import path
// (not hand-authored fixtures) - the gated counterpart of
// CalcBridgeFilterTests above.
//
// PROBE DATE / TOOL VERSION (re-run TODAY - doctrine rule 10:
// "re-verification happens by re-running them, not by trusting the
// comment"):
//   - Probed: 2026-08-15
//   - `soffice --version`: LibreOffice 26.2.5.2
//     (cd7284b4cbbfeb507e630c1aac019f4157393acb)
//   - Manually ran, outside this test file, immediately before writing
//     it: `soffice --headless --convert-to ods` on a hand-written CSV
//     containing `=SUM(B1:B2)`-style formulas, then `--convert-to fods`
//     on the result. Confirmed the exact wire shape
//     `odfFormulaToTesseraSource(_:)` converts: `table:formula="of:=SUM
//     ([.B1:.B2])"` for a range sum, `table:formula="of:=[.B1]"` for a
//     bare cell reference, `office:value-type="date"
//     office:date-value="2026-08-15"` (bare date, no time/timezone) for
//     a date cell, and NO `table:number-rows-repeated`/`-columns-
//     repeated` anywhere in a CSV-derived conversion (that padding is a
//     native .ods/.xls characteristic this probe's CSV source can't
//     reproduce - the bounded bootstrapped defense against it in
//     `mapRows(of:)` is exercised by the hand-authored fixture in
//     `testSheetFromFlatODSDoesNotMaterializeAHugeTrailingBlankRowRun`
//     above instead, not by this live probe).
//
// Skips cleanly when soffice is absent. 120s allowance
// (DoctrineTimeout.probe) per rule 12.

final class CalcBridgeFilterFodsProbeTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func skipIfSofficeUnavailable(_ filter: CalcBridgeFilter) throws {
        // `isAvailable` is `nonisolated` on the actor, so no await needed
        // (matches ODGConnectorWireFormatProbeTests's own convention).
        guard filter.isAvailable else {
            throw XCTSkip("soffice not found on this machine - skipping live CalcBridgeFilter fods probe.")
        }
    }

    func testImportWorkbookOfARealOdsFileCarriesLiveFormulaSourceThroughAFullSofficeConversion() async throws {
        let filter = CalcBridgeFilter()
        try skipIfSofficeUnavailable(filter)

        // Same single-column shape as the pinned sum-formula.fods
        // fixture (5, 7, =SUM(A1:A2)) - built fresh here through a
        // real CSV->ODS conversion rather than reading the fixture, so
        // this test genuinely exercises the ods->fods->Sheet path this
        // pass added, not just the hand-authored fixture.
        let csv = "5\r\n7\r\n=SUM(A1:A2)\r\n"
        let converter = LibreOfficeConverter()
        let odsData = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await converter.convert(data: Data(csv.utf8), sourceExtension: "csv", targetExtension: "ods")
        }

        let sheet = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.importWorkbook(data: odsData, format: "ods", title: "Probe")
        }

        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "5")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "7")
        XCTAssertEqual(sheet.cellText(row: 2, col: 0), "=SUM(A1:A2)", "a real soffice-produced ODS formula must arrive as live source, not a baked value")
        XCTAssertTrue(SheetWorkbook.isFormula(sheet.cellText(row: 2, col: 0)))
    }
}
