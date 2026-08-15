import XCTest
@testable import TesseraCore

/// `LOBridgeDeckIO` (P1 1.8). The `office:presentation` <-> `SlideDeck`
/// mapping (``LOBridgeDeckIO/mapToSlideDeck(root:titleFallback:)`` /
/// ``LOBridgeDeckIO/mapToFlatODFTree(_:)``) and the transition-tag
/// resolver are pure and tested directly against hand-written flat-XML
/// fixtures, no `soffice` needed - mirrors `FlatODFReaderTests`'s own
/// fixture style. The actual ODP/PPTX/PDF conversions are real
/// integration tests, skipped when LibreOffice isn't installed - see
/// `WriterBridgeFilterTests`/`CalcBridgeFilterTests` for the same
/// pattern this file follows.
final class LOBridgeDeckIOTests: XCTestCase {

    // MARK: - Fixtures

    static let deckFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
                      xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                      xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
                      xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
                      xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
                      xmlns:smil="urn:oasis:names:tc:opendocument:xmlns:smil-compatible:1.0"
                      xmlns:dc="http://purl.org/dc/elements/1.1/"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.presentation">
      <office:meta>
        <dc:title>Quarterly Review</dc:title>
      </office:meta>
      <office:automatic-styles>
        <style:style style:name="dp1" style:family="drawing-page">
          <style:drawing-page-properties draw:fill="solid" draw:fill-color="#112233"/>
        </style:style>
      </office:automatic-styles>
      <office:master-styles>
        <style:master-page style:name="Master_1" style:display-name="Corporate" draw:style-name="dp1"/>
      </office:master-styles>
      <office:body>
        <office:presentation>
          <draw:page draw:name="page1" draw:master-page-name="Master_1" smil:transitionType="fade">
            <draw:frame presentation:class="title">
              <draw:text-box>
                <text:p>Welcome</text:p>
              </draw:text-box>
            </draw:frame>
            <draw:frame presentation:class="outline">
              <draw:text-box>
                <text:p>First point</text:p>
                <text:p>Second point</text:p>
              </draw:text-box>
            </draw:frame>
            <draw:frame draw:name="Logo">
              <draw:image>
                <office:binary-data>aGVsbG8td29ybGQ=</office:binary-data>
              </draw:image>
            </draw:frame>
            <presentation:notes>
              <draw:frame presentation:class="notes">
                <draw:text-box>
                  <text:p>Remember to smile.</text:p>
                </draw:text-box>
              </draw:frame>
            </presentation:notes>
          </draw:page>
          <draw:page draw:name="page2">
            <draw:frame presentation:class="title">
              <draw:text-box>
                <text:p>Thank You</text:p>
              </draw:text-box>
            </draw:frame>
          </draw:page>
        </office:presentation>
      </office:body>
    </office:document>
    """

    static let textDocumentFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.text">
      <office:body>
        <office:text>
          <text:p>Hello</text:p>
        </office:text>
      </office:body>
    </office:document>
    """

    static let emptyPresentationBodyFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                      office:version="1.3"
                      office:mimetype="application/vnd.oasis.opendocument.presentation">
      <office:body/>
    </office:document>
    """

    private func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    // MARK: - Formats

    func testSupportedImportFormatsAreOdpAndPptx() {
        XCTAssertEqual(Set(LOBridgeDeckIO.supportedImportFormats), ["odp", "pptx"])
    }

    func testUnsupportedImportFormatThrowsWithoutTouchingSoffice() async throws {
        let io = LOBridgeDeckIO()
        do {
            _ = try await io.importDeck(from: URL(fileURLWithPath: "/nonexistent/deck.key"))
            XCTFail("expected unsupportedImportFormat")
        } catch LOBridgeDeckIO.FilterError.unsupportedImportFormat(let format) {
            XCTAssertEqual(format, "key")
        }
    }

    /// `DeckExportFormat` has exactly odp/pptx/pdf - no `.handoutPDF`.
    /// The exhaustive switch is the compile-time guarantee: adding a
    /// hypothetical `.handoutPDF` case would fail this file to build
    /// until a case is added here too, so the absence can't silently
    /// regress.
    func testDeckExportFormatHasNoHandoutPDFCase() {
        XCTAssertEqual(DeckExportFormat.allCases.count, 3)
        for format in DeckExportFormat.allCases {
            switch format {
            case .odp, .pptx, .pdf:
                break
            }
        }
    }

    // MARK: - Transition tag resolution (pure)

    func testResolveTransitionCatalogIDFromPageAttribute() {
        let page = FlatODFElement(name: "draw:page", attributes: ["smil:transitionType": "fade"])
        let root = FlatODFElement(name: "office:document")
        XCTAssertEqual(LOBridgeDeckIO.resolveTransitionCatalogID(forPage: page, root: root), "fade")
    }

    func testResolveTransitionCatalogIDFromReferencedStyle() {
        let page = FlatODFElement(name: "draw:page", attributes: ["draw:style-name": "dp1"])
        let styleElement = FlatODFElement(
            name: "style:style",
            attributes: ["style:name": "dp1", "smil:transitionType": "wipe"]
        )
        let automaticStyles = FlatODFElement(name: "office:automatic-styles", children: [.element(styleElement)])
        let root = FlatODFElement(name: "office:document", children: [.element(automaticStyles)])
        XCTAssertEqual(LOBridgeDeckIO.resolveTransitionCatalogID(forPage: page, root: root), "wipe")
    }

    func testResolveTransitionCatalogIDReturnsNilForUnmappableTag() {
        let page = FlatODFElement(name: "draw:page", attributes: ["smil:transitionType": "totallyMadeUpTag"])
        let root = FlatODFElement(name: "office:document")
        XCTAssertNil(LOBridgeDeckIO.resolveTransitionCatalogID(forPage: page, root: root))
    }

    func testResolveTransitionCatalogIDReturnsNilWhenAbsent() {
        let page = FlatODFElement(name: "draw:page")
        let root = FlatODFElement(name: "office:document")
        XCTAssertNil(LOBridgeDeckIO.resolveTransitionCatalogID(forPage: page, root: root))
    }

    // MARK: - mapToSlideDeck (pure)

    func testMapToSlideDeckExtractsDeckTitleAndSlideCount() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.deckFixture)) { _ in
            URL(string: "tessera-test://blob/1")!
        }
        let deck = try LOBridgeDeckIO.mapToSlideDeck(root: result.root, titleFallback: "fallback")
        XCTAssertEqual(deck.title, "Quarterly Review")
        XCTAssertEqual(deck.slideCount, 2)
    }

    func testMapToSlideDeckSlide1IsToggleWithHeadingBodyAndImage() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.deckFixture)) { _ in
            URL(string: "tessera-test://blob/1")!
        }
        let deck = try LOBridgeDeckIO.mapToSlideDeck(root: result.root)

        let rootID = deck.body.rootChildren[0]
        let root = try XCTUnwrap(deck.body.blocks[rootID])
        XCTAssertEqual(root.type, .toggle)
        XCTAssertEqual(root.children.count, 4)

        let heading = try XCTUnwrap(deck.body.blocks[root.children[0]])
        XCTAssertEqual(heading.type, .heading)
        XCTAssertEqual(heading.content.map(\.text).joined(), "Welcome")

        let para1 = try XCTUnwrap(deck.body.blocks[root.children[1]])
        XCTAssertEqual(para1.content.map(\.text).joined(), "First point")
        let para2 = try XCTUnwrap(deck.body.blocks[root.children[2]])
        XCTAssertEqual(para2.content.map(\.text).joined(), "Second point")

        let image = try XCTUnwrap(deck.body.blocks[root.children[3]])
        XCTAssertEqual(image.type, .image)
        XCTAssertEqual(image.attributes["source"]?.stringValue, "tessera-test://blob/1")
        XCTAssertEqual(image.attributes["alt"]?.stringValue, "Logo")

        let meta = try XCTUnwrap(deck.slideMeta[rootID.uuidString])
        XCTAssertEqual(meta.layout, .titleAndContent)
        XCTAssertEqual(meta.notes, "Remember to smile.")
        let masterID = try XCTUnwrap(meta.masterPageID)
        let master = try XCTUnwrap(deck.effectiveMasterPages[masterID.uuidString])
        XCTAssertEqual(master.name, "Corporate")
        XCTAssertEqual(master.backgroundColorHex, .literal("#112233"))
    }

    /// `deckFixture`'s page1 carries `smil:transitionType="fade"` -
    /// pins that `mapToSlideDeck` actually calls
    /// `resolveTransitionCatalogID` and lands the result on
    /// `SlideMeta.transitionID` (P1 1.6/1.8 gap closure), not just that
    /// the resolver works standalone (see the "Transition tag
    /// resolution" tests above for that).
    func testMapToSlideDeckResolvesTransitionIDOntoSlideMeta() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.deckFixture)) { _ in
            URL(string: "tessera-test://blob/1")!
        }
        let deck = try LOBridgeDeckIO.mapToSlideDeck(root: result.root)

        let rootID = deck.body.rootChildren[0]
        let meta = try XCTUnwrap(deck.slideMeta[rootID.uuidString])
        XCTAssertEqual(meta.transitionID, "fade")

        // page2 has no smil:transitionType attribute at all.
        let secondRootID = deck.body.rootChildren[1]
        let secondMeta = try XCTUnwrap(deck.slideMeta[secondRootID.uuidString])
        XCTAssertNil(secondMeta.transitionID)
    }

    func testMapToSlideDeckSlide2IsTitleOnlyHeadingWithNoMaster() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.deckFixture)) { _ in
            URL(string: "tessera-test://blob/1")!
        }
        let deck = try LOBridgeDeckIO.mapToSlideDeck(root: result.root)

        let rootID = deck.body.rootChildren[1]
        let root = try XCTUnwrap(deck.body.blocks[rootID])
        XCTAssertEqual(root.type, .heading)
        XCTAssertEqual(root.content.map(\.text).joined(), "Thank You")

        let meta = try XCTUnwrap(deck.slideMeta[rootID.uuidString])
        XCTAssertEqual(meta.layout, .title)
        XCTAssertNil(meta.masterPageID)
    }

    func testMapToSlideDeckThrowsNotAPresentationForOtherContentTypes() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.textDocumentFixture)) { _ in
            XCTFail("no binary data in this fixture")
            return URL(fileURLWithPath: "/dev/null")
        }
        XCTAssertThrowsError(try LOBridgeDeckIO.mapToSlideDeck(root: result.root)) { error in
            guard case LOBridgeDeckIO.FilterError.notAPresentation(let contentType) = error else {
                return XCTFail("expected notAPresentation, got \(error)")
            }
            XCTAssertEqual(contentType, .text)
        }
    }

    func testMapToSlideDeckThrowsMissingPresentationBodyWhenBodyLacksPresentationElement() async throws {
        let reader = FlatODFReader()
        let result = try await reader.parse(data: data(Self.emptyPresentationBodyFixture)) { _ in
            XCTFail("no binary data in this fixture")
            return URL(fileURLWithPath: "/dev/null")
        }
        XCTAssertThrowsError(try LOBridgeDeckIO.mapToSlideDeck(root: result.root)) { error in
            guard case LOBridgeDeckIO.FilterError.missingPresentationBody = error else {
                return XCTFail("expected missingPresentationBody, got \(error)")
            }
        }
    }

    // MARK: - mapToFlatODFTree (pure)

    func testMapToFlatODFTreeProducesExpectedStructure() throws {
        let master = SlideMasterPage(name: "Dark", backgroundColorHex: .literal("#000000"))
        var deck = SlideDeck.makeBlank(title: "Export Test")
        deck = deck.settingMasterPage(master)
        let slideID = deck.body.rootChildren[0]
        var meta = deck.slideMeta[slideID.uuidString] ?? .default
        meta.masterPageID = master.id
        meta.notes = "Speaker notes here"
        deck.slideMeta[slideID.uuidString] = meta

        let tree = LOBridgeDeckIO.mapToFlatODFTree(deck)
        XCTAssertEqual(tree.name, "office:document")
        XCTAssertEqual(tree.attributes["office:mimetype"], "application/vnd.oasis.opendocument.presentation")

        let title = try XCTUnwrap(tree.firstElementChild(named: "office:meta")?.firstElementChild(named: "dc:title"))
        XCTAssertEqual(title.children, [.text("Export Test")])

        let masterStyles = try XCTUnwrap(tree.firstElementChild(named: "office:master-styles"))
        let masterEntries = masterStyles.elementChildren.filter { $0.name == "style:master-page" }
        // The always-present "Default" sentinel (see mapToFlatODFTree's
        // doc comment) plus the one custom master this deck defines.
        XCTAssertEqual(masterEntries.count, 2)
        let customEntry = try XCTUnwrap(masterEntries.first { $0.attributes["style:display-name"] == "Dark" })

        let automaticStyles = try XCTUnwrap(tree.firstElementChild(named: "office:automatic-styles"))
        let drawingPageStyle = try XCTUnwrap(automaticStyles.elementChildren.first { $0.name == "style:style" })
        let props = try XCTUnwrap(drawingPageStyle.firstElementChild(named: "style:drawing-page-properties"))
        XCTAssertEqual(props.attributes["draw:fill-color"], "#000000")

        let page = try XCTUnwrap(
            tree.firstElementChild(named: "office:body")?
                .firstElementChild(named: "office:presentation")?
                .firstElementChild(named: "draw:page")
        )
        XCTAssertEqual(page.attributes["draw:master-page-name"], customEntry.attributes["style:name"])

        let titleParagraph = try XCTUnwrap(
            page.elementChildren.first { $0.attributes["presentation:class"] == "title" }?
                .firstElementChild(named: "draw:text-box")?
                .firstElementChild(named: "text:p")
        )
        XCTAssertEqual(titleParagraph.children, [.text("Slide 1")])

        let notesParagraph = try XCTUnwrap(
            page.firstElementChild(named: "presentation:notes")?
                .firstElementChild(named: "draw:frame")?
                .firstElementChild(named: "draw:text-box")?
                .firstElementChild(named: "text:p")
        )
        XCTAssertEqual(notesParagraph.children, [.text("Speaker notes here")])
    }

    func testMapToFlatODFTreeWithNoCustomMastersStillEmitsDefaultMaster() throws {
        let deck = SlideDeck.makeBlank(title: "No Masters")
        let tree = LOBridgeDeckIO.mapToFlatODFTree(deck)
        let masterStyles = try XCTUnwrap(tree.firstElementChild(named: "office:master-styles"))
        XCTAssertEqual(masterStyles.elementChildren.compactMap { $0.attributes["style:name"] }, ["Default"])

        let page = try XCTUnwrap(
            tree.firstElementChild(named: "office:body")?
                .firstElementChild(named: "office:presentation")?
                .firstElementChild(named: "draw:page")
        )
        XCTAssertEqual(page.attributes["draw:master-page-name"], "Default")
    }

    // MARK: - Real round trip + PDF export (needs soffice)

    func testRoundTripODPPreservesTitleAndSlideCount() async throws {
        let io = LOBridgeDeckIO()
        try await XCTSkipIf(!io.isAvailable, "soffice not installed")

        let deck = SlideDeck.makeBlank(title: "Round Trip Deck")
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lo-deck-io-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let odpURL = workDir.appendingPathComponent("deck.odp")

        try await io.exportDeck(deck, to: odpURL, format: .odp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: odpURL.path))

        let reimported = try await io.importDeck(from: odpURL)
        XCTAssertEqual(reimported.title, deck.title)
        XCTAssertEqual(reimported.slideCount, deck.slideCount)
    }

    func testExportToPDFProducesNonEmptyFile() async throws {
        let io = LOBridgeDeckIO()
        try await XCTSkipIf(!io.isAvailable, "soffice not installed")

        let deck = SlideDeck.makeBlank(title: "PDF Smoke Test")
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lo-deck-io-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let pdfURL = workDir.appendingPathComponent("deck.pdf")

        try await io.exportDeck(deck, to: pdfURL, format: .pdf)

        let attributes = try FileManager.default.attributesOfItem(atPath: pdfURL.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    /// Exercises the `.pdf` case's `filterOptions:
    /// "impress_pdf_Export:{\"ExportNotesPages\":true}"` argument
    /// end-to-end against real `soffice` with a deck that HAS speaker
    /// notes. A PDF's text is typically stream-compressed
    /// (FlateDecode), so this does not parse the PDF's internal
    /// structure to confirm the notes text is literally present -
    /// it instead pins the export succeeds and produces a non-empty
    /// file for a deck carrying notes, matching this file's own
    /// `testExportToPDFProducesNonEmptyFile` shape. The load-bearing
    /// assertion is `LibreOfficeConverterTests`' job for
    /// `filterOptions` itself; this test's job is that `exportDeck`
    /// actually threads the option through for `.pdf`, which the
    /// non-crashing, non-empty-output round trip demonstrates.
    func testExportToPDFWithSpeakerNotesProducesNonEmptyFile() async throws {
        let io = LOBridgeDeckIO()
        try await XCTSkipIf(!io.isAvailable, "soffice not installed")

        var deck = SlideDeck.makeBlank(title: "PDF Notes Smoke Test")
        let slideID = deck.body.rootChildren[0]
        var meta = deck.slideMeta[slideID.uuidString] ?? .default
        meta.notes = "Remember to smile and wave."
        deck.slideMeta[slideID.uuidString] = meta

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lo-deck-io-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let pdfURL = workDir.appendingPathComponent("deck-with-notes.pdf")

        try await io.exportDeck(deck, to: pdfURL, format: .pdf)

        let attributes = try FileManager.default.attributesOfItem(atPath: pdfURL.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }
}
