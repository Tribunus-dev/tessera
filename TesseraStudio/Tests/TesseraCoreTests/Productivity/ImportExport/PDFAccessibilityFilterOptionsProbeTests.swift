import XCTest
@testable import TesseraCore

// MARK: - PDFAccessibilityFilterOptionsProbeTests
//
// QUARANTINED EMPIRICAL PROBE (testing-doctrine.md rule 10). Shells out
// to a real `soffice` through all FOUR production PDF export paths this
// wave touches (`DocumentExporter.export`, `PDFExportBridge.export`,
// `LOBridgeDeckIO.exportDeck`, `CalcBridgeFilter.exportPDF`), each with
// `accessibility: .pdfUA`, proving TWO separate things per path:
//
//   1. The exact filter-name + FilterData JSON string each production
//      call site builds is SYNTACTICALLY VALID and ACCEPTED by soffice
//      (a wrong filter name errors outright - confirmed during this
//      probe's own research: `pdf:pdf_Export:{...}` (a plausible but
//      wrong bare name) fails with "Please verify input parameters...").
//      This is the strongest verification available without a mockable
//      LibreOfficeConverter seam (there is none - see
//      LibreOfficeConverter.swift; it is a concrete actor, not a
//      protocol, and is outside this track's owned file list).
//   2. Whether the OUTPUT is actually tagged - wrapped in
//      XCTExpectFailure per testing-doctrine.md's suspected-bug
//      protocol, because it currently is NOT, on this exact soffice
//      install, for a reason that is a LibreOffice CLI defect, not a
//      Tessera code bug (see below and AccessibilityTools... no -
//      AccessibilityPreflight.swift's own `PDFAccessibilityOptions` doc
//      comment for the full empirical writeup). If a future LO version
//      fixes this, XCTExpectFailure's default `strict: true` behavior
//      means THIS TEST FAILS (an unexpected pass), which is the correct
//      signal to remove the wrapping - re-verification happens by
//      re-running, never by trusting this comment (rule 10).
//
// PROBE DATE / TOOL VERSION (re-run TODAY, not copied from
// AccessibilityPreflight.swift's own doc comment):
//   - Probed: 2026-08-16
//   - `soffice --version`: LibreOffice 26.2.5.2
//     (cd7284b4cbbfeb507e630c1aac019f4157393acb)
//   - Finding: ANY explicit FilterData on a `*_pdf_Export` filter -
//     regardless of content, including the exact
//     `{"UseTaggedPDF":true,"PDFUACompliance":true}` this wave ships -
//     produces an UNTAGGED PDF (no `/StructTreeRoot`, no `/MarkInfo`),
//     while omitting FilterData entirely produces a TAGGED PDF by
//     default on this install (neither carries a PDF/UA XMP identity
//     claim - see AccessibilityPreflight.swift). Reproduced across
//     `writer_pdf_Export`, `writer_web_pdf_Export`, and
//     `calc_pdf_Export` by hand before writing this file; this file
//     re-confirms it through TESSERA'S OWN production code paths, not
//     just hand-typed `soffice` invocations. Matches a previously
//     reported LibreOffice issue (ask.libreoffice.org/t/68343, German:
//     "Der Filter writer_pdf_Export ignoriert alle Argumente aus den
//     mitgegebenen FilterData-Properties").
//
// Skips cleanly when soffice is absent. 120s allowance
// (DoctrineTimeout.probe) per rule 12. This is the closest thing to an
// "ungated shadow" (rule 11) available for a soffice-only contract: the
// pure filter-string-BUILDING logic (`PDFFilterOptions.build`,
// `PDFAccessibilityOptions.filterDataFragments`) has its own full
// ungated coverage in AccessibilityPreflightTests.swift.

final class PDFAccessibilityFilterOptionsProbeTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func skipIfSofficeUnavailable() throws {
        guard LibreOfficeConverter().isAvailable else {
            throw XCTSkip("soffice not found on this machine - skipping live PDF accessibility filter-options probe.")
        }
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdfua-probe-\(UUID().uuidString)-\(name)")
    }

    /// Raw-byte heuristic for "this PDF's own structure tree is
    /// present" - the same signal `pdfinfo -Tagged` reports, checked
    /// directly on the file's bytes so this probe depends on nothing
    /// beyond `soffice` itself (no `pdfinfo`/poppler dependency).
    /// Confirmed against real soffice output during this probe's own
    /// research: an untagged export has neither marker; a tagged export
    /// has both, in cleartext (soffice's small test-fixture PDFs are not
    /// object-stream-compressed).
    private func looksTagged(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .isoLatin1) else { return false }
        return text.contains("/StructTreeRoot") && text.contains("/MarkInfo")
    }

    // MARK: - Writer (DocumentExporter)

    func testDocumentExporterAcceptsAccessibilityOptionsAndProducesAPDF() async throws {
        try skipIfSofficeUnavailable()
        var ast = DocumentAST()
        let headingID = UUID()
        ast.blocks[headingID] = Block(id: headingID, type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: "Probe Heading")])
        ast.rootChildren = [headingID]
        let doc = Doc(title: "Writer Probe", body: ast)

        let destination = tempURL("writer.pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let exporter = DocumentExporter()
        let produced = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await exporter.export(doc, to: .pdf, destination: destination, accessibility: .pdfUA)
        }
        let data = try Data(contentsOf: produced)
        XCTAssertFalse(data.isEmpty, "soffice must accept writer_web_pdf_Export with UseTaggedPDF/PDFUACompliance and produce a non-empty PDF")

        XCTExpectFailure("SUSPECTED LIBREOFFICE CLI BUG (not Tessera code): writer_web_pdf_Export ignores UseTaggedPDF/PDFUACompliance FilterData on LO 26.2.5.2 - see this file's header and AccessibilityPreflight.swift's PDFAccessibilityOptions doc comment") {
            XCTAssertTrue(looksTagged(data), "expected a tagged PDF once the underlying LO defect is fixed")
        }
    }

    // MARK: - Draw (PDFExportBridge)

    func testPDFExportBridgeAcceptsAccessibilityOptionsAndProducesAPDF() async throws {
        try skipIfSofficeUnavailable()
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 10, y: 10, width: 100, height: 60))
        let drawing = Drawing.makeBlank(title: "Draw Probe").insertingShape(shape)

        let destination = tempURL("draw.pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let bridge = PDFExportBridge()
        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await bridge.export(drawing, to: destination, accessibility: .pdfUA)
        }
        let data = try Data(contentsOf: destination)
        XCTAssertFalse(data.isEmpty, "soffice must accept draw_pdf_Export with UseTaggedPDF/PDFUACompliance and produce a non-empty PDF")

        XCTExpectFailure("SUSPECTED LIBREOFFICE CLI BUG (not Tessera code): draw_pdf_Export ignores UseTaggedPDF/PDFUACompliance FilterData on LO 26.2.5.2 - see this file's header") {
            XCTAssertTrue(looksTagged(data), "expected a tagged PDF once the underlying LO defect is fixed")
        }
    }

    // MARK: - Impress (LOBridgeDeckIO)

    func testLOBridgeDeckIOAcceptsAccessibilityOptionsAndProducesAPDF() async throws {
        try skipIfSofficeUnavailable()
        let deck = SlideDeck.makeBlank(title: "Impress Probe")

        let destination = tempURL("impress.pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let io = LOBridgeDeckIO()
        try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await io.exportDeck(deck, to: destination, format: .pdf, accessibility: .pdfUA)
        }
        let data = try Data(contentsOf: destination)
        XCTAssertFalse(data.isEmpty, "soffice must accept impress_pdf_Export with ExportNotesPages+UseTaggedPDF+PDFUACompliance combined and produce a non-empty PDF")

        XCTExpectFailure("SUSPECTED LIBREOFFICE CLI BUG (not Tessera code): impress_pdf_Export ignores UseTaggedPDF/PDFUACompliance FilterData on LO 26.2.5.2 - see this file's header") {
            XCTAssertTrue(looksTagged(data), "expected a tagged PDF once the underlying LO defect is fixed")
        }
    }

    // MARK: - Calc (CalcBridgeFilter)

    func testCalcBridgeFilterAcceptsAccessibilityOptionsAndProducesAPDF() async throws {
        try skipIfSofficeUnavailable()
        var sheet = Sheet.makeBlank(title: "Calc Probe", rows: 2, cols: 2)
        sheet = sheet.settingCellText(row: 0, col: 0, "Header")
        sheet = sheet.settingCellText(row: 1, col: 0, "Value")

        let filter = CalcBridgeFilter()
        let data = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.exportPDF(sheet, accessibility: .pdfUA)
        }
        XCTAssertFalse(data.isEmpty, "soffice must accept calc_pdf_Export with UseTaggedPDF/PDFUACompliance and produce non-empty PDF bytes")

        XCTExpectFailure("SUSPECTED LIBREOFFICE CLI BUG (not Tessera code): calc_pdf_Export ignores UseTaggedPDF/PDFUACompliance FilterData on LO 26.2.5.2 - see this file's header") {
            XCTAssertTrue(looksTagged(data), "expected a tagged PDF once the underlying LO defect is fixed")
        }
    }

    // MARK: - Control: the pre-2.20 default (accessibility: .off) is unaffected

    func testCalcBridgeFilterWithAccessibilityOffMatchesThePre2Point20BareFilterBehavior() async throws {
        try skipIfSofficeUnavailable()
        var sheet = Sheet.makeBlank(title: "Calc Control", rows: 1, cols: 1)
        sheet = sheet.settingCellText(row: 0, col: 0, "Hello")

        let filter = CalcBridgeFilter()
        let data = try await withDoctrineTimeout(seconds: DoctrineTimeout.probe) {
            try await filter.exportPDF(sheet, accessibility: .off)
        }
        XCTAssertFalse(data.isEmpty)
        // `.off` builds `filterOptions: nil` (PDFFilterOptions.build
        // returns nil for an empty fragment list), so this call is
        // byte-for-byte the same soffice invocation every pre-2.20
        // caller already made - and, per this file's header finding,
        // is CURRENTLY the one path that ends up tagged on this
        // install (soffice's own bare-filter default), unlike every
        // `.pdfUA` case above. Asserted directly (not XCTExpectFailure-
        // wrapped) since this is the expected-and-observed state, not a
        // suspected bug.
        XCTAssertTrue(looksTagged(data), "the bare-filter (no FilterData) default is expected to remain tagged on this LO install, per this file's header finding")
    }
}
