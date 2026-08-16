import XCTest
@testable import TesseraCore

// MARK: - BlockTests
//
// Contract: Block.swift's own doc comments (BlockType/InlineRun/Block/
// DocumentMeta/DocumentAST) - doctrine rule 2 (round-trip identity: encode-
// decode + legacy-JSON decode + byte-identical re-encode where canonical),
// rule 3 (derived-never-stored: note numbering), and the typed-attribute
// bridge pattern ("Block.shape 191-207 and Block.frame 217-234 - nested
// JSON object under one attribute key; the value type's own Codable is the
// wire truth" per sota-writer-slides-report.md).

final class BlockTests: DoctrineTestCase {

    // MARK: - InlineRun.Annotation round-trip (including associated values)

    func testInlineRunAnnotationEncodeDecodeIdentityEveryCase() throws {
        let annotations: [InlineRun.Annotation] = [
            .bold, .italic, .underline, .strikethrough, .code, .subscript, .superscript,
            .link(URL(string: "https://example.com")!),
            .color(hex: "#FF0000"),
            .noteRef(UUID()),
        ]
        for annotation in annotations {
            let data = try JSONEncoder().encode(annotation)
            let decoded = try JSONDecoder().decode(InlineRun.Annotation.self, from: data)
            XCTAssertEqual(decoded, annotation)
        }
    }

    func testInlineRunEncodeDecodeIdentity() throws {
        let run = InlineRun(text: "hello", annotations: [.bold, .link(URL(string: "https://x.example")!)])
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(InlineRun.self, from: data)
        XCTAssertEqual(decoded, run)
    }

    // MARK: - Block round-trip identity

    func testBlockEncodeDecodeIdentity() throws {
        let block = Block(
            type: .paragraph,
            attributes: ["custom": .string("value")],
            content: [InlineRun(text: "hi", annotations: [.italic])],
            children: [UUID()],
            parentID: UUID()
        )
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(Block.self, from: data)
        XCTAssertEqual(decoded, block)
    }

    // MARK: - BlockType.CaseIterable totality (independent oracle, doctrine rule 7)

    /// Hand-transcribed from BlockType.swift's own case list. A case added
    /// or removed there without updating THIS list is exactly the kind of
    /// silent catalog drift rule 7 exists to catch.
    private static let expectedBlockTypeRawValues: Set<String> = [
        "heading", "paragraph", "list", "listItem", "table", "tableCell",
        "image", "codeBlock", "callout", "divider", "quote", "toggle",
        "equation", "comment", "trackInsertion", "trackDeletion", "shape",
        "shapeGroup", "section", "frame", "chart", "field", "footnote",
        "endnote", "media", "toc",
    ]

    func testBlockTypeCaseIterableMatchesTheIndependentlyPinnedList() {
        let actual = Set(BlockType.allCases.map(\.rawValue))
        XCTAssertEqual(actual, Self.expectedBlockTypeRawValues)
    }

    // MARK: - Block.shape / .frame / .chart / .field / .media bridges

    func testBlockShapeBridgeRoundTripsAndIsNoOpOnWrongType() {
        var shapeBlock = Block(type: .shape)
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 1, y: 2, width: 3, height: 4))
        shapeBlock.shape = shape
        XCTAssertEqual(shapeBlock.shape, shape)
        XCTAssertNotNil(shapeBlock.attributes["shape"])
        shapeBlock.shape = nil
        XCTAssertNil(shapeBlock.attributes["shape"])

        var paragraphBlock = Block(type: .paragraph)
        paragraphBlock.shape = shape
        XCTAssertNil(paragraphBlock.shape, "setting .shape on a non-.shape block must be a no-op")
        XCTAssertNil(paragraphBlock.attributes["shape"])
    }

    func testBlockFrameBridgeRoundTripsAndIsNoOpOnWrongType() {
        var frameBlock = Block(type: .frame)
        let frame = FrameProperties(x: 0, y: 0, width: 100, height: 50)
        frameBlock.frame = frame
        XCTAssertEqual(frameBlock.frame, frame)
        frameBlock.frame = nil
        XCTAssertNil(frameBlock.attributes["frame"])

        var paragraphBlock = Block(type: .paragraph)
        paragraphBlock.frame = frame
        XCTAssertNil(paragraphBlock.frame)
    }

    func testBlockChartBridgeRoundTripsAndIsNoOpOnWrongType() {
        var chartBlock = Block(type: .chart)
        let chart = ChartSpec(kind: .line, title: "Revenue")
        chartBlock.chart = chart
        XCTAssertEqual(chartBlock.chart, chart)
        chartBlock.chart = nil
        XCTAssertNil(chartBlock.attributes["chart"])

        var paragraphBlock = Block(type: .paragraph)
        paragraphBlock.chart = chart
        XCTAssertNil(paragraphBlock.chart)
    }

    func testBlockMediaBridgeRoundTripsAndIsNoOpOnWrongType() {
        var mediaBlock = Block(type: .media)
        let media = MediaBlock(kind: .video, sourceURL: "file:///clip.mp4")
        mediaBlock.media = media
        XCTAssertEqual(mediaBlock.media, media)
        mediaBlock.media = nil
        XCTAssertNil(mediaBlock.attributes["media"])

        var paragraphBlock = Block(type: .paragraph)
        paragraphBlock.media = media
        XCTAssertNil(paragraphBlock.media)
    }

    // MARK: - DocumentMeta legacy decode: sections/notes/styles absent -> empty defaults

    func testDocumentMetaDecodesLegacyJSONMissingSectionsNotesStylesAsEmpty() throws {
        let legacyJSON = """
        {"pageLayout":{"pageWidth":595,"pageHeight":842,"marginTop":72,"marginBottom":72,"marginLeft":72,"marginRight":72,"columnCount":1,"columnGap":18,"pageColor":"#FFFFFF"}}
        """
        let decoded = try JSONDecoder().decode(DocumentMeta.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.sections.isEmpty)
        XCTAssertTrue(decoded.notes.isEmpty)
        XCTAssertTrue(decoded.styles.isEmpty)
        XCTAssertEqual(decoded.pageLayout.pageWidth, 595)
    }

    func testDocumentMetaEncodeDecodeIdentityWithStyles() throws {
        let styleID = UUID()
        let meta = DocumentMeta(styles: [styleID: StyleDefinition(id: styleID, name: "Body", family: .paragraph)])
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(DocumentMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    // MARK: - DocumentAST round-trip + byte-identical re-encode (canonical serialization)

    func testDocumentASTEncodeDecodeIdentity() throws {
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "hi")])
        ast.rootChildren = [blockID]
        let data = try ast.jsonData()
        let decoded = try DocumentAST.from(jsonData: data)
        XCTAssertEqual(decoded, ast)
    }

    func testDocumentASTByteIdenticalReencode() throws {
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .heading, attributes: ["level": .number(2)], content: [InlineRun(text: "Title")])
        ast.rootChildren = [blockID]
        let firstPass = try ast.jsonData()
        let decoded = try DocumentAST.from(jsonData: firstPass)
        let secondPass = try decoded.jsonData()
        XCTAssertEqual(firstPass, secondPass)
    }

    func testDocumentASTContentHashIsStableForSemanticallyEqualDocuments() throws {
        let blockID = UUID()
        var ast1 = DocumentAST()
        ast1.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "same")])
        ast1.rootChildren = [blockID]
        var ast2 = ast1
        XCTAssertEqual(try ast1.contentHash(), try ast2.contentHash())

        ast2.blocks[blockID]?.content = [InlineRun(text: "different")]
        XCTAssertNotEqual(try ast1.contentHash(), try ast2.contentHash(), "a genuine content change must change the hash")
    }

    func testDocumentASTContentHashIsPrefixedWithSha256() throws {
        let hash = try DocumentAST.empty.contentHash()
        XCTAssertTrue(hash.hasPrefix("sha256:"))
    }

    // MARK: - Tree helpers

    func testDepthFirstOrderWalksRootFirstThenChildren() {
        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        var ast = DocumentAST()
        ast.blocks[rootID] = Block(id: rootID, type: .toggle, children: [childID])
        ast.blocks[childID] = Block(id: childID, type: .toggle, children: [grandchildID], parentID: rootID)
        ast.blocks[grandchildID] = Block(id: grandchildID, type: .paragraph, parentID: childID)
        ast.rootChildren = [rootID]
        XCTAssertEqual(ast.depthFirstOrder(), [rootID, childID, grandchildID])
    }

    func testChildrenOfNilParentReturnsRootChildren() {
        let id = UUID()
        var ast = DocumentAST()
        ast.rootChildren = [id]
        XCTAssertEqual(ast.children(of: nil), [id])
    }

    func testContainsReflectsBlockPresence() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph)
        XCTAssertTrue(ast.contains(id))
        XCTAssertFalse(ast.contains(UUID()))
    }

    // MARK: - Note numbering: derived-never-stored (doctrine rule 3)

    /// Mutating the source (which note is referenced first) re-derives the
    /// numbering; nothing is stored on the block or in DocumentMeta.
    func testDeriveNoteNumberingReflectsReferenceOrderNotStorageOrder() {
        let noteAID = UUID()
        let noteBID = UUID()
        let paragraphID = UUID()
        var ast = DocumentAST()
        ast.meta.notes = [
            noteAID: Block(id: noteAID, type: .footnote, content: [InlineRun(text: "note A")]),
            noteBID: Block(id: noteBID, type: .footnote, content: [InlineRun(text: "note B")]),
        ]
        // Reference B before A in document order.
        ast.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph, content: [
            InlineRun(text: "ref", annotations: [.noteRef(noteBID)]),
            InlineRun(text: "ref", annotations: [.noteRef(noteAID)]),
        ])
        ast.rootChildren = [paragraphID]

        let numbering = ast.deriveNoteNumbering()
        XCTAssertEqual(numbering.footnotes[noteBID], 1, "B is referenced first in document order, so it gets number 1")
        XCTAssertEqual(numbering.footnotes[noteAID], 2)

        // No stored copy exists anywhere to drift: derive again after
        // reordering the reference order in the SAME document and confirm
        // the numbering follows the new order, proving nothing was cached.
        var reordered = ast
        reordered.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph, content: [
            InlineRun(text: "ref", annotations: [.noteRef(noteAID)]),
            InlineRun(text: "ref", annotations: [.noteRef(noteBID)]),
        ])
        let renumbered = reordered.deriveNoteNumbering()
        XCTAssertEqual(renumbered.footnotes[noteAID], 1, "after reordering, A is now referenced first")
        XCTAssertEqual(renumbered.footnotes[noteBID], 2)
    }

    func testDeriveNoteNumberingFootnotesAndEndnotesAreIndependentSequences() {
        let footnoteID = UUID()
        let endnoteID = UUID()
        let paragraphID = UUID()
        var ast = DocumentAST()
        ast.meta.notes = [
            footnoteID: Block(id: footnoteID, type: .footnote),
            endnoteID: Block(id: endnoteID, type: .endnote),
        ]
        ast.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph, content: [
            InlineRun(text: "a", annotations: [.noteRef(footnoteID)]),
            InlineRun(text: "b", annotations: [.noteRef(endnoteID)]),
        ])
        ast.rootChildren = [paragraphID]
        let numbering = ast.deriveNoteNumbering()
        XCTAssertEqual(numbering.footnotes[footnoteID], 1, "footnotes and endnotes must number independently, each its own 1..n")
        XCTAssertEqual(numbering.endnotes[endnoteID], 1)
    }

    func testDeriveNoteNumberingSkipsDanglingReferenceWithNoRegisteredNote() {
        let paragraphID = UUID()
        var ast = DocumentAST()
        ast.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph, content: [
            InlineRun(text: "ref", annotations: [.noteRef(UUID())]), // not in meta.notes
        ])
        ast.rootChildren = [paragraphID]
        let numbering = ast.deriveNoteNumbering()
        XCTAssertTrue(numbering.footnotes.isEmpty)
        XCTAssertTrue(numbering.endnotes.isEmpty)
    }

    // MARK: - Block.rowSpan / colSpan (TableLayout's own peer accessors, tested here since they live in Block's file family)

    func testEffectiveRowAndColSpanDefaultToOneWhenUnset() {
        let cell = Block(type: .tableCell)
        XCTAssertEqual(cell.effectiveRowSpan, 1)
        XCTAssertEqual(cell.effectiveColSpan, 1)
    }

    func testRowSpanSetterRemovesAttributeWhenSetToOneOrLess() {
        var cell = Block(type: .tableCell)
        cell.rowSpan = 3
        XCTAssertEqual(cell.rowSpan, 3)
        cell.rowSpan = 1
        XCTAssertNil(cell.rowSpan, "rowSpan of 1 is the implicit default and must not be stored")
    }
}
