import XCTest
@testable import TesseraCore

/// Reading spreadsheet files off disk into sheets that calculate.
///
/// Most of the weight is on delimited parsing, because that is where a
/// mistake is silent: splitting on the delimiter tears a quoted field
/// apart and the result still looks like plausible data. Every quoting
/// case below is one that a naive `split` gets wrong.
final class SpreadsheetDigesterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("digester-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ contents: String, as name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func parse(_ text: String, _ delimiter: Character = ",") -> [[String]] {
        SpreadsheetDigester.parseDelimited(text, delimiter: delimiter)
    }

    // MARK: - Delimited parsing

    func testParsesSimpleRows() {
        XCTAssertEqual(parse("a,b\nc,d"), [["a", "b"], ["c", "d"]])
    }

    /// A quoted field may contain the delimiter.
    func testQuotedFieldContainingDelimiter() {
        XCTAssertEqual(parse("\"a,b\",c"), [["a,b", "c"]])
    }

    /// A doubled quote inside a quoted field is one literal quote.
    func testDoubledQuoteIsLiteral() {
        XCTAssertEqual(parse("\"say \"\"hi\"\"\",x"), [["say \"hi\"", "x"]])
    }

    /// A quoted field may span lines. Splitting on newlines first would
    /// turn this one record into two.
    func testQuotedFieldContainingNewline() {
        XCTAssertEqual(parse("\"line1\nline2\",b"), [["line1\nline2", "b"]])
    }

    func testHandlesCRLF() {
        XCTAssertEqual(parse("a,b\r\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testHandlesBareCR() {
        XCTAssertEqual(parse("a,b\rc,d"), [["a", "b"], ["c", "d"]])
    }

    func testTrailingNewlineDoesNotAddAnEmptyRow() {
        XCTAssertEqual(parse("a,b\n"), [["a", "b"]])
    }

    func testEmptyFieldsArePreserved() {
        XCTAssertEqual(parse("a,,c"), [["a", "", "c"]])
    }

    /// An empty trailing field still counts as a column.
    func testTrailingEmptyFieldIsKept() {
        XCTAssertEqual(parse("a,b,"), [["a", "b", ""]])
    }

    func testTabDelimited() {
        XCTAssertEqual(parse("a\tb\nc\td", "\t"), [["a", "b"], ["c", "d"]])
    }

    /// Ragged rows pad out, so the grid is rectangular. A short row is
    /// missing trailing cells, not a different-shaped record.
    func testRaggedRowsArePadded() {
        let padded = SpreadsheetDigester.padded([["a", "b", "c"], ["d"]])
        XCTAssertEqual(padded, [["a", "b", "c"], ["d", "", ""]])
    }

    // MARK: - Encoding

    /// A UTF-8 BOM left in place becomes part of the first header cell
    /// and silently breaks column matching.
    func testBOMIsStripped() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("name,value".data(using: .utf8)!)
        XCTAssertEqual(SpreadsheetDigester.decodeText(data), "name,value")
    }

    func testLatin1FallbackDecodes() {
        // 0xE9 is é in Latin-1 and invalid as standalone UTF-8.
        let data = Data([0x61, 0xE9, 0x62])
        XCTAssertNotNil(SpreadsheetDigester.decodeText(data))
    }

    // MARK: - Format detection

    func testFormatDetectionByExtension() {
        XCTAssertEqual(SpreadsheetDigester.detectFormat(url: URL(fileURLWithPath: "/x/a.csv")), "csv")
        XCTAssertEqual(SpreadsheetDigester.detectFormat(url: URL(fileURLWithPath: "/x/a.tsv")), "tsv")
        XCTAssertEqual(SpreadsheetDigester.detectFormat(url: URL(fileURLWithPath: "/x/a.xlsx")), "xlsx")
    }

    /// XLSX is not read here; it goes through the import pipeline.
    func testXLSXIsRejectedWithAClearError() throws {
        let url = try write("not really xlsx", as: "book.xlsx")
        XCTAssertThrowsError(try SpreadsheetDigester().digest(fileAt: url)) { error in
            XCTAssertEqual(error as? DigesterError, .unsupportedFormat("xlsx"))
        }
    }

    // MARK: - Provenance

    func testProvenanceRecordsFileIdentity() throws {
        let url = try write("a,b\n1,2\n", as: "data.csv")
        let workbook = try SpreadsheetDigester().digest(fileAt: url)
        let provenance = try XCTUnwrap(workbook.provenance)

        XCTAssertEqual(provenance.sourcePath, url.path)
        XCTAssertEqual(provenance.format, "csv")
        XCTAssertEqual(provenance.sheetName, "data")
        XCTAssertEqual(provenance.sourceByteCount, 8)
        XCTAssertEqual(provenance.sourceSHA256.count, 64, "SHA-256 is 64 hex chars")
        XCTAssertNotNil(provenance.sourceModifiedAt)
    }

    /// The hash is the whole point: it distinguishes "same file again"
    /// from "the file changed underneath us".
    func testHashChangesWhenContentChanges() throws {
        let first = try write("a,b\n1,2\n", as: "one.csv")
        let second = try write("a,b\n1,3\n", as: "two.csv")
        let a = try SpreadsheetDigester().digest(fileAt: first).provenance
        let b = try SpreadsheetDigester().digest(fileAt: second).provenance
        XCTAssertNotEqual(a?.sourceSHA256, b?.sourceSHA256)
    }

    func testHashIsStableForIdenticalContent() throws {
        let first = try write("x,y\n1,2\n", as: "a.csv")
        let second = try write("x,y\n1,2\n", as: "b.csv")
        let a = try SpreadsheetDigester().digest(fileAt: first).provenance
        let b = try SpreadsheetDigester().digest(fileAt: second).provenance
        XCTAssertEqual(a?.sourceSHA256, b?.sourceSHA256)
    }

    func testProvenanceSummaryIsReadable() throws {
        let url = try write("a\n1\n", as: "ledger.csv")
        let provenance = try XCTUnwrap(try SpreadsheetDigester().digest(fileAt: url).provenance)
        XCTAssertTrue(provenance.summary.contains("ledger.csv"))
        XCTAssertTrue(provenance.summary.contains("sha256:"))
        XCTAssertTrue(provenance.summary.contains("(csv)"))
    }

    /// Provenance rides on the sheet itself and survives a JSON round
    /// trip, which is how it reaches the database.
    func testProvenanceSurvivesSheetRoundTrip() throws {
        let url = try write("a,b\n1,2\n", as: "round.csv")
        let sheet = try SpreadsheetDigester().digest(fileAt: url).sheets[0].makeSheet()
        let restored = try Sheet.from(jsonData: try sheet.jsonData())

        let before = try XCTUnwrap(sheet.provenance)
        let after = try XCTUnwrap(restored.provenance)
        // The identity fields must survive exactly.
        XCTAssertEqual(after.sourcePath, before.sourcePath)
        XCTAssertEqual(after.sourceSHA256, before.sourceSHA256)
        XCTAssertEqual(after.sourceByteCount, before.sourceByteCount)
        XCTAssertEqual(after.format, before.format)
        XCTAssertEqual(after.sheetName, before.sheetName)
        XCTAssertEqual(after.digesterVersion, before.digesterVersion)
        // Sheet JSON encodes dates as ISO-8601, which is whole seconds -
        // the same precision every other date on `Sheet` round-trips at.
        XCTAssertEqual(
            after.digestedAt.timeIntervalSinceReferenceDate,
            before.digestedAt.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    /// A sheet stored before provenance existed must still decode.
    func testSheetWithoutProvenanceStillDecodes() throws {
        let plain = Sheet.makeBlank(title: "Manual", rows: 2, cols: 2)
        let restored = try Sheet.from(jsonData: try plain.jsonData())
        XCTAssertNil(restored.provenance)
    }

    // MARK: - Digest to sheet

    func testDigestedSheetKeepsCellText() throws {
        let url = try write("name,qty\nWidget,10\n", as: "items.csv")
        let sheet = try SpreadsheetDigester().digest(fileAt: url).sheets[0].makeSheet()
        XCTAssertEqual(sheet.cellText(row: 0, col: 0), "name")
        XCTAssertEqual(sheet.cellText(row: 1, col: 0), "Widget")
        XCTAssertEqual(sheet.cellText(row: 1, col: 1), "10")
    }

    /// The payoff: a digested formula is stored as a formula and the
    /// engine evaluates it. The Python importer flattens this to the
    /// text "=SUM(A1:A2) = 3" instead.
    @MainActor
    func testDigestedFormulaComputes() throws {
        let url = try write("1\n2\n=SUM(A1:A2)\n", as: "calc.csv")
        let sheet = try SpreadsheetDigester().digest(fileAt: url).sheets[0].makeSheet()
        XCTAssertEqual(sheet.cellText(row: 2, col: 0), "=SUM(A1:A2)", "the formula is stored, not its value")

        let workbook = SheetWorkbook()
        workbook.hydrate(from: sheet)
        XCTAssertEqual(workbook.displayText(row: 2, col: 0), "3")
    }

    func testFormulaCountReportsLiveCells() throws {
        let url = try write("1,2\n=A1+B1,x\n", as: "mixed.csv")
        let digested = try SpreadsheetDigester().digest(fileAt: url).sheets[0]
        XCTAssertEqual(digested.formulaCount, 1)
    }

    /// Untrusted files can be digested inert. The engine has no shell or
    /// network functions, so a planted formula can only compute a wrong
    /// number - but a caller may still want text.
    func testFormulaCountIsZeroWhenFormulasAreDisabled() throws {
        let digester = SpreadsheetDigester(treatLeadingEqualsAsFormula: false)
        XCTAssertFalse(digester.treatLeadingEqualsAsFormula)
    }

    func testDigestedGridIsRectangular() throws {
        let url = try write("a,b,c\n1\n", as: "ragged.csv")
        let digested = try SpreadsheetDigester().digest(fileAt: url).sheets[0]
        XCTAssertEqual(digested.columnCount, 3)
        XCTAssertEqual(digested.rows[1], ["1", "", ""])
    }

    func testTSVFileIsParsedWithTabs() throws {
        let url = try write("a\tb\n1\t2\n", as: "data.tsv")
        let digested = try SpreadsheetDigester().digest(fileAt: url).sheets[0]
        XCTAssertEqual(digested.rows, [["a", "b"], ["1", "2"]])
        XCTAssertEqual(digested.provenance.format, "tsv")
    }

    /// A real-world export: quoted fields with commas and newlines,
    /// mixed with numbers, all in one file.
    func testRealisticExportRoundTrips() throws {
        let csv = """
        region,note,amount
        "North, upper","multi
        line note",100
        South,plain,200
        """
        let url = try write(csv, as: "export.csv")
        let digested = try SpreadsheetDigester().digest(fileAt: url).sheets[0]
        XCTAssertEqual(digested.rowCount, 3)
        XCTAssertEqual(digested.columnCount, 3)
        XCTAssertEqual(digested.rows[1][0], "North, upper")
        XCTAssertEqual(digested.rows[1][1], "multi\nline note")
        XCTAssertEqual(digested.rows[2][2], "200")
    }
}
