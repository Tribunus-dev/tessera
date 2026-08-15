import XCTest
@testable import TesseraCore

// MARK: - DocumentExporterTests
//
// Contract: DocumentExporter.swift's own doc comments per `renderBlock`'s
// per-BlockType switch (heading level -> hN tag, list style -> ol/ul,
// table -> TableLayout-driven rowspan/colspan, callout -> emoji + div,
// inline annotations -> strong/em/u/s/code/sub/sup/a). Coverage shape
// (renderer): determinism (doctrine rule 4) first, then content
// (doctrine rule 8) - pixel/byte/string checks at known locations, never
// only "did not crash". `export(...)`/`convertWithTextutil`/`renderPDF`
// shell out to `/usr/bin/textutil` and AppKit and are explicitly OUT of
// scope here - only `htmlPreview` (pure, no I/O) is exercised. A future
// textutil-shelling probe belongs in a doctrine rule-10 quarantined file,
// not here.

final class DocumentExporterTests: DoctrineTestCase {

    private let exporter = DocumentExporter()

    private func docWithOneParagraph(_ text: String) -> Doc {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: text)])
        ast.rootChildren = [id]
        return Doc(title: "Export Test", body: ast)
    }

    // MARK: - Determinism (doctrine rule 4): two independent passes are byte-identical

    func testHtmlPreviewIsDeterministicAcrossTwoIndependentPasses() throws {
        let doc = docWithOneParagraph("hello world")
        let first = try exporter.htmlPreview(doc)
        let second = try exporter.htmlPreview(doc)
        XCTAssertEqual(first, second)
    }

    // MARK: - Content: heading level -> hN tag

    func testHeadingLevelRendersTheMatchingHTag() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .heading, attributes: ["level": .number(3)], content: [InlineRun(text: "Section")])
        ast.rootChildren = [id]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("<h3>Section</h3>"), html)
    }

    func testHeadingLevelClampsToOneAndSixAtTheExtremes() throws {
        let lowID = UUID()
        let highID = UUID()
        var ast = DocumentAST()
        ast.blocks[lowID] = Block(id: lowID, type: .heading, attributes: ["level": .number(0)], content: [InlineRun(text: "Low")])
        ast.blocks[highID] = Block(id: highID, type: .heading, attributes: ["level": .number(99)], content: [InlineRun(text: "High")])
        ast.rootChildren = [lowID, highID]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("<h1>Low</h1>"))
        XCTAssertTrue(html.contains("<h6>High</h6>"))
    }

    // MARK: - Content: inline annotations compose in application order

    func testInlineAnnotationsComposeBoldThenItalic() throws {
        let doc = docWithOneParagraphRun(InlineRun(text: "styled", annotations: [.bold, .italic]))
        let html = try exporter.htmlPreview(doc)
        XCTAssertTrue(html.contains("<em><strong>styled</strong></em>"), html)
    }

    func testLinkAnnotationRendersAnchorWithEscapedHref() throws {
        let doc = docWithOneParagraphRun(InlineRun(text: "click", annotations: [.link(URL(string: "https://example.com/a&b")!)]))
        let html = try exporter.htmlPreview(doc)
        XCTAssertTrue(html.contains("href=\"https://example.com/a&amp;b\""), html)
    }

    private func docWithOneParagraphRun(_ run: InlineRun) -> Doc {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [run])
        ast.rootChildren = [id]
        return Doc(title: "t", body: ast)
    }

    // MARK: - Content: list style -> ol vs ul

    func testOrderedListRendersOlTagWithListItems() throws {
        let listID = UUID()
        let item1ID = UUID()
        let item2ID = UUID()
        var ast = DocumentAST()
        ast.blocks[listID] = Block(id: listID, type: .list, attributes: ["style": .string("ordered")], children: [item1ID, item2ID])
        ast.blocks[item1ID] = Block(id: item1ID, type: .listItem, content: [InlineRun(text: "one")], parentID: listID)
        ast.blocks[item2ID] = Block(id: item2ID, type: .listItem, content: [InlineRun(text: "two")], parentID: listID)
        ast.rootChildren = [listID]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<li>two</li>"))
    }

    func testUnorderedListIsTheDefaultWhenStyleAttributeAbsent() throws {
        let listID = UUID()
        var ast = DocumentAST()
        ast.blocks[listID] = Block(id: listID, type: .list, children: [])
        ast.rootChildren = [listID]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("<ul>"))
    }

    // MARK: - Content: table with a merged cell renders rowspan/colspan

    func testTableWithAColSpanningCellRendersColspanAttribute() throws {
        let tableID = UUID()
        let wideID = UUID()
        let nextID = UUID()
        var ast = DocumentAST()
        var wideCell = Block(id: wideID, type: .tableCell, content: [InlineRun(text: "wide")])
        wideCell.colSpan = 2
        ast.blocks[wideID] = wideCell
        ast.blocks[nextID] = Block(id: nextID, type: .tableCell, content: [InlineRun(text: "next")])
        ast.blocks[tableID] = Block(id: tableID, type: .table, attributes: ["cols": .number(3)], children: [wideID, nextID])
        ast.rootChildren = [tableID]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("colspan=\"2\""), html)
    }

    // MARK: - Content: callout emoji + div wrapper

    func testCalloutRendersEmojiAndDivWrapper() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .callout, attributes: ["emoji": .string("🔥")], content: [InlineRun(text: "hot take")])
        ast.rootChildren = [id]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("class=\"callout\""))
        XCTAssertTrue(html.contains("🔥"))
        XCTAssertTrue(html.contains("hot take"))
    }

    // MARK: - Content: comment/trackInsertion/trackDeletion render nothing (review-only)

    func testCommentBlockRendersEmptyString() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .comment, content: [InlineRun(text: "a comment")])
        ast.rootChildren = [id]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertFalse(html.contains("a comment"), "review-only blocks must not leak into the export HTML")
    }

    // MARK: - Content: escapeHTML on code blocks (no double-unescaping)

    func testCodeBlockEscapesHTMLSpecialCharacters() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .codeBlock, attributes: ["language": .string("html")], content: [InlineRun(text: "<script>alert(1)</script>")])
        ast.rootChildren = [id]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"), "raw code content must never appear unescaped in the export HTML")
    }

    // MARK: - Degenerate input: empty document still produces a valid HTML shell

    func testEmptyDocumentStillProducesAValidHTMLShellWithTitle() throws {
        let html = try exporter.htmlPreview(Doc(title: "Empty Doc", body: .empty))
        XCTAssertTrue(html.contains("<title>Empty Doc</title>"))
        XCTAssertTrue(html.contains("<body>"))
        XCTAssertTrue(html.contains("</html>"))
    }

    func testDividerRendersHorizontalRule() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .divider)
        ast.rootChildren = [id]
        let html = try exporter.htmlPreview(Doc(title: "t", body: ast))
        XCTAssertTrue(html.contains("<hr>"))
    }
}
