import XCTest
@testable import TesseraCore

// MARK: - AccessibilityPreflightTests
//
// Contract: this track's brief (P2-D item 2.20) item 3 ("native checks
// mirroring LO 7.1's own accessibility checker - missing image alt
// text, heading-level jumps ... missing document title, missing
// document language") + item 6 ("catches missing alt text / a
// heading-level jump / missing title / missing language on hand-built
// fixture ASTs, and does NOT false-positive on a well-formed fixture")
// + testing-doctrine.md rule 6 (one behavior per test, name is the
// contract sentence) and rule 9 (fixtures + at least one property).
//
// Fully ungated: `AccessibilityPreflight` is pure over a `Doc` (plus an
// ancillary `language` parameter - see AccessibilityPreflight.swift's
// own doc comment for why that is not a `Doc` field), no soffice, no I/O.

final class AccessibilityPreflightTests: DoctrineTestCase {

    // MARK: - Fixture builders

    private func heading(_ text: String, level: Int, id: UUID = UUID()) -> Block {
        Block(id: id, type: .heading, attributes: ["level": .number(Double(level))], content: [InlineRun(text: text)])
    }

    private func image(alt: String?, id: UUID = UUID()) -> Block {
        var attributes: [String: AnyCodable] = [:]
        if let alt { attributes["alt"] = .string(alt) }
        return Block(id: id, type: .image, attributes: attributes)
    }

    private func doc(title: String = "", blocks: [Block]) -> Doc {
        var ast = DocumentAST()
        for block in blocks {
            ast.blocks[block.id] = block
        }
        ast.rootChildren = blocks.map(\.id)
        return Doc(title: title, body: ast)
    }

    // MARK: - Missing alt text (Matterhorn 13-004)

    func testImageWithNoAltAttributeReportsMissingAltText() {
        let img = image(alt: nil)
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [img]), language: "en")
        XCTAssertTrue(issues.contains { $0.kind == .missingAltText && $0.blockID == img.id })
    }

    func testImageWithEmptyAltAttributeReportsMissingAltText() {
        let img = image(alt: "   ")
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [img]), language: "en")
        XCTAssertTrue(issues.contains { $0.kind == .missingAltText && $0.blockID == img.id })
    }

    func testImageWithRealAltTextDoesNotReportMissingAltText() {
        let img = image(alt: "a red bicycle leaning against a brick wall")
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [img]), language: "en")
        XCTAssertFalse(issues.contains { $0.kind == .missingAltText })
    }

    func testMultipleImagesEachReportTheirOwnMissingAltTextIssue() {
        let a = image(alt: nil)
        let b = image(alt: nil)
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [a, b]), language: "en")
        let missingIDs = Set(issues.filter { $0.kind == .missingAltText }.compactMap(\.blockID))
        XCTAssertEqual(missingIDs, [a.id, b.id])
    }

    // MARK: - Heading-level jumps (Matterhorn 14-002)

    func testH1DirectlyToH3WithNoH2ReportsHeadingLevelJumpOnTheH3() {
        let h1 = heading("Title", level: 1)
        let h3 = heading("Subsection", level: 3)
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [h1, h3]), language: "en")
        XCTAssertTrue(issues.contains { $0.kind == .headingLevelJump && $0.blockID == h3.id })
    }

    func testWellOrderedHeadingSequenceReportsNoHeadingLevelJump() {
        let h1 = heading("Title", level: 1)
        let h2 = heading("Section", level: 2)
        let h3 = heading("Subsection", level: 3)
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [h1, h2, h3]), language: "en")
        XCTAssertFalse(issues.contains { $0.kind == .headingLevelJump })
    }

    func testHeadingLevelCanDecreaseWithoutReportingAJump() {
        let h1 = heading("Title", level: 1)
        let h2 = heading("Section", level: 2)
        let h2Again = heading("Another section", level: 2)
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [h1, h2, h2Again]), language: "en")
        XCTAssertFalse(issues.contains { $0.kind == .headingLevelJump })
    }

    func testFirstHeadingNeverReportsAJumpRegardlessOfItsOwnLevel() {
        // No preceding heading to jump from - a document that opens
        // straight at H3 is not, by itself, a "skipped level" per the
        // contract's own example (a SKIP between two headings), so this
        // is a design-judgment call recorded in this file's own doc
        // comment, not an oversight.
        let h3 = heading("Deep start", level: 3)
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: [h3]), language: "en")
        XCTAssertFalse(issues.contains { $0.kind == .headingLevelJump })
    }

    func testHeadingInsideANestedContainerStillParticipatesInTheDocumentWideSequence() {
        // depthFirstOrder() recurses into .toggle's children - a jump
        // straddling a container boundary must still be caught.
        let h1 = heading("Title", level: 1)
        let h3 = heading("Nested", level: 3)
        let toggleID = UUID()
        let toggle = Block(id: toggleID, type: .toggle, attributes: ["expanded": .bool(true)], children: [h3.id])
        var ast = DocumentAST()
        ast.blocks[h1.id] = h1
        ast.blocks[toggleID] = toggle
        ast.blocks[h3.id] = h3
        ast.rootChildren = [h1.id, toggleID]
        let issues = AccessibilityPreflight.run(Doc(title: "t", body: ast), language: "en")
        XCTAssertTrue(issues.contains { $0.kind == .headingLevelJump && $0.blockID == h3.id })
    }

    // MARK: - Missing title (Matterhorn 06-001)

    func testEmptyTitleAndNoHeadingReportsMissingTitle() {
        let paragraph = Block(type: .paragraph, content: [InlineRun(text: "no heading here")])
        let issues = AccessibilityPreflight.run(doc(title: "", blocks: [paragraph]), language: "en")
        XCTAssertTrue(issues.contains { $0.kind == .missingTitle })
    }

    func testExplicitTitleDoesNotReportMissingTitle() {
        let issues = AccessibilityPreflight.run(doc(title: "A Real Title", blocks: []), language: "en")
        XCTAssertFalse(issues.contains { $0.kind == .missingTitle })
    }

    func testEmptyTitleWithAFirstHeadingDoesNotReportMissingTitle() {
        // Matches Doc.displayTitle's own fallback chain - a doc that
        // leans on its first heading as the title is well-formed.
        let h1 = heading("Derived Title", level: 1)
        let issues = AccessibilityPreflight.run(doc(title: "", blocks: [h1]), language: "en")
        XCTAssertFalse(issues.contains { $0.kind == .missingTitle })
    }

    func testWhitespaceOnlyTitleAndNoHeadingReportsMissingTitle() {
        let issues = AccessibilityPreflight.run(doc(title: "   \n  ", blocks: []), language: "en")
        XCTAssertTrue(issues.contains { $0.kind == .missingTitle })
    }

    // MARK: - Missing language (Matterhorn 11-001)

    func testNilLanguageReportsMissingLanguage() {
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: []), language: nil)
        XCTAssertTrue(issues.contains { $0.kind == .missingLanguage })
    }

    func testWhitespaceOnlyLanguageReportsMissingLanguage() {
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: []), language: "   ")
        XCTAssertTrue(issues.contains { $0.kind == .missingLanguage })
    }

    func testRealLanguageTagDoesNotReportMissingLanguage() {
        let issues = AccessibilityPreflight.run(doc(title: "t", blocks: []), language: "en-US")
        XCTAssertFalse(issues.contains { $0.kind == .missingLanguage })
    }

    // MARK: - Well-formed fixture: no false positives (item 6's own "does NOT false-positive" clause)

    func testWellFormedFixtureReportsNoIssuesAtAllWhenLanguageIsSupplied() {
        let h1 = heading("Report Title", level: 1)
        let h2 = heading("Findings", level: 2)
        let paragraph = Block(type: .paragraph, content: [InlineRun(text: "Body text.")])
        let img = image(alt: "a bar chart showing quarterly revenue")
        let wellFormed = doc(title: "Quarterly Report", blocks: [h1, h2, paragraph, img])
        let issues = AccessibilityPreflight.run(wellFormed, language: "en")
        XCTAssertEqual(issues, [], "a well-formed fixture with a title, ordered headings, real alt text, and a supplied language must report zero issues")
    }

    func testWellFormedFixtureStillReportsOnlyMissingLanguageWhenNoneIsSupplied() {
        // Same fixture as above, but `language` omitted - honest per
        // AccessibilityPreflight's own doc comment: every Tessera
        // document is missing a real language declaration today.
        let h1 = heading("Report Title", level: 1)
        let paragraph = Block(type: .paragraph, content: [InlineRun(text: "Body text.")])
        let wellFormed = doc(title: "Quarterly Report", blocks: [h1, paragraph])
        let issues = AccessibilityPreflight.run(wellFormed)
        XCTAssertEqual(issues.map(\.kind), [.missingLanguage])
    }

    // MARK: - Determinism (doctrine rule 4)

    func testRunIsDeterministicAcrossTwoIndependentPasses() {
        let h1 = heading("Title", level: 1)
        let h3 = heading("Skip", level: 3)
        let img = image(alt: nil)
        let document = doc(title: "", blocks: [h1, h3, img])
        let first = AccessibilityPreflight.run(document, language: nil)
        let second = AccessibilityPreflight.run(document, language: nil)
        XCTAssertEqual(first, second)
    }

    // MARK: - Degenerate input: empty document

    func testEmptyDocumentWithNoTitleAndNoLanguageReportsExactlyMissingTitleAndMissingLanguage() {
        let issues = AccessibilityPreflight.run(Doc(title: "", body: .empty), language: nil)
        XCTAssertEqual(Set(issues.map(\.kind)), [.missingTitle, .missingLanguage])
    }
}

// MARK: - PDFAccessibilityOptionsTests

final class PDFAccessibilityOptionsTests: DoctrineTestCase {

    func testOffHasNoFilterDataFragmentsAndIsNotEnabled() {
        XCTAssertEqual(PDFAccessibilityOptions.off.filterDataFragments, [])
        XCTAssertFalse(PDFAccessibilityOptions.off.isEnabled)
    }

    func testPdfUAEmitsBothFragmentsInOrderAndIsEnabled() {
        XCTAssertEqual(
            PDFAccessibilityOptions.pdfUA.filterDataFragments,
            ["\"UseTaggedPDF\":true", "\"PDFUACompliance\":true"]
        )
        XCTAssertTrue(PDFAccessibilityOptions.pdfUA.isEnabled)
    }

    func testUseTaggedPDFAloneEmitsOnlyItsOwnFragment() {
        let options = PDFAccessibilityOptions(useTaggedPDF: true, pdfUACompliance: false)
        XCTAssertEqual(options.filterDataFragments, ["\"UseTaggedPDF\":true"])
        XCTAssertTrue(options.isEnabled)
    }

    func testPDFUAComplianceAloneEmitsOnlyItsOwnFragment() {
        let options = PDFAccessibilityOptions(useTaggedPDF: false, pdfUACompliance: true)
        XCTAssertEqual(options.filterDataFragments, ["\"PDFUACompliance\":true"])
        XCTAssertTrue(options.isEnabled)
    }

    // MARK: - PDFFilterOptions.build

    func testBuildReturnsNilForEmptyFragments() {
        XCTAssertNil(PDFFilterOptions.build(filterName: "writer_web_pdf_Export", fragments: []))
    }

    func testBuildJoinsFragmentsWithCommasInsideBraces() {
        let built = PDFFilterOptions.build(filterName: "calc_pdf_Export", fragments: PDFAccessibilityOptions.pdfUA.filterDataFragments)
        XCTAssertEqual(built, "calc_pdf_Export:{\"UseTaggedPDF\":true,\"PDFUACompliance\":true}")
    }

    func testBuildWithASingleFragmentHasNoTrailingComma() {
        let built = PDFFilterOptions.build(filterName: "draw_pdf_Export", fragments: ["\"UseTaggedPDF\":true"])
        XCTAssertEqual(built, "draw_pdf_Export:{\"UseTaggedPDF\":true}")
    }

    // MARK: - Per-path filter name pinning (item 6: "correctly constructed
    // for each of the 3-4 PDF export paths"). Mirrors the literal
    // filterName argument each production call site passes -
    // DocumentExporter.renderPDF ("writer_web_pdf_Export"),
    // PDFExportBridge.export ("draw_pdf_Export"), LOBridgeDeckIO.exportDeck
    // ("impress_pdf_Export"), CalcBridgeFilter.exportPDF
    // ("calc_pdf_Export") - so a rename in one place without the other is
    // at least visible as a diff here. The real, soffice-verified proof
    // that each of these four exact strings is ACCEPTED by soffice lives
    // in the gated probe (PDFAccessibilityFilterOptionsProbeTests.swift,
    // doctrine rule 10) - a pure test cannot reach soffice.

    func testWriterFilterNameMatchesDocumentExporterRenderPDF() {
        XCTAssertEqual(
            PDFFilterOptions.build(filterName: "writer_web_pdf_Export", fragments: PDFAccessibilityOptions.pdfUA.filterDataFragments),
            "writer_web_pdf_Export:{\"UseTaggedPDF\":true,\"PDFUACompliance\":true}"
        )
    }

    func testDrawFilterNameMatchesPDFExportBridgeExport() {
        XCTAssertEqual(
            PDFFilterOptions.build(filterName: "draw_pdf_Export", fragments: PDFAccessibilityOptions.pdfUA.filterDataFragments),
            "draw_pdf_Export:{\"UseTaggedPDF\":true,\"PDFUACompliance\":true}"
        )
    }

    func testImpressFilterNameMatchesLOBridgeDeckIOExportDeckAndCombinesWithExportNotesPages() {
        var fragments = ["\"ExportNotesPages\":true"]
        fragments.append(contentsOf: PDFAccessibilityOptions.pdfUA.filterDataFragments)
        XCTAssertEqual(
            PDFFilterOptions.build(filterName: "impress_pdf_Export", fragments: fragments),
            "impress_pdf_Export:{\"ExportNotesPages\":true,\"UseTaggedPDF\":true,\"PDFUACompliance\":true}"
        )
    }

    func testCalcFilterNameMatchesCalcBridgeFilterExportPDF() {
        XCTAssertEqual(
            PDFFilterOptions.build(filterName: "calc_pdf_Export", fragments: PDFAccessibilityOptions.pdfUA.filterDataFragments),
            "calc_pdf_Export:{\"UseTaggedPDF\":true,\"PDFUACompliance\":true}"
        )
    }
}
