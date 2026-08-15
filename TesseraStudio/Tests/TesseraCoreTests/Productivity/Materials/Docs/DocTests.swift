import XCTest
@testable import TesseraCore

// MARK: - DocTests
//
// Contract: `Doc` is the Docs material's value type (AGENTS.md's
// product-surface-expansion section: "Docs are a first-class Material...
// every mutation produces a signed receipt" - the mutation/receipt half is
// DocStore's job; this file covers the pure value-type behavior per
// doctrine rule 2 (round-trip identity) and the derived-display helpers
// Doc.swift itself documents (displayTitle/snippet/wordCount/
// readingTimeMinutes/normalizeTags/plainText).

final class DocTests: DoctrineTestCase {

    private func paragraph(_ text: String) -> Block {
        Block(type: .paragraph, content: text.isEmpty ? [] : [InlineRun(text: text)])
    }

    private func heading(_ text: String, level: Int = 1) -> Block {
        Block(type: .heading, attributes: ["level": .number(Double(level))], content: [InlineRun(text: text)])
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testDocEncodeDecodeIdentity() throws {
        let body = astWithOneParagraph("hello world")
        let original = Doc(
            title: "My Doc",
            body: body,
            coverImageURL: URL(string: "https://example.com/cover.png"),
            iconEmoji: "📄",
            isArchived: true,
            isFavorite: true,
            tags: ["work", "draft"],
            linkedEntityIDs: [UUID()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try original.jsonData()
        let decoded = try Doc.from(jsonData: data)
        XCTAssertEqual(decoded, original)
    }

    func testDocJSONDataStringRoundTrip() throws {
        let original = Doc(
            title: "Round Trip", body: astWithOneParagraph("content"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let jsonString = try original.jsonDataString()
        let decoded = try Doc.from(jsonDataString: jsonString)
        XCTAssertEqual(decoded, original)
    }

    private func astWithOneParagraph(_ text: String) -> DocumentAST {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = paragraph(text)
        ast.rootChildren = [id]
        return ast
    }

    // MARK: - displayTitle

    func testDisplayTitlePrefersExplicitTitle() {
        let doc = Doc(title: "Explicit", body: astWithHeading("Heading Text"))
        XCTAssertEqual(doc.displayTitle, "Explicit")
    }

    func testDisplayTitleFallsBackToFirstHeadingWhenTitleEmpty() {
        let doc = Doc(title: "", body: astWithHeading("From Heading"))
        XCTAssertEqual(doc.displayTitle, "From Heading")
    }

    func testDisplayTitleFallsBackToUntitledWhenNoTitleAndNoHeading() {
        let doc = Doc(title: "  ", body: astWithOneParagraph("just a paragraph"))
        XCTAssertEqual(doc.displayTitle, "Untitled")
    }

    private func astWithHeading(_ text: String) -> DocumentAST {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = heading(text)
        ast.rootChildren = [id]
        return ast
    }

    // MARK: - firstHeadingText

    func testFirstHeadingTextSkipsBlankHeadingsAndFindsFirstNonBlank() {
        let blankID = UUID()
        let realID = UUID()
        var ast = DocumentAST()
        ast.blocks[blankID] = heading("   ")
        ast.blocks[realID] = heading("Real Heading")
        ast.rootChildren = [blankID, realID]
        XCTAssertEqual(Doc.firstHeadingText(in: ast), "Real Heading")
    }

    func testFirstHeadingTextNilWhenNoHeadingsAtRoot() {
        XCTAssertNil(Doc.firstHeadingText(in: astWithOneParagraph("no headings here")))
    }

    // MARK: - normalizeTags

    func testNormalizeTagsTrimsLowercasesAndDedupes() {
        let normalized = Doc.normalizeTags([" Work ", "work", "Draft", "", "  "])
        XCTAssertEqual(normalized, ["work", "draft"])
    }

    func testDocInitNormalizesTagsAtConstruction() {
        let doc = Doc(tags: ["Foo", "foo", " Bar "])
        XCTAssertEqual(doc.tags, ["foo", "bar"])
    }

    // MARK: - wordCount / readingTimeMinutes

    func testWordCountOfEmptyDocumentIsZero() {
        XCTAssertEqual(Doc.wordCount(of: .empty), 0)
    }

    func testWordCountCountsWhitespaceSeparatedWords() {
        let ast = astWithOneParagraph("The quick brown fox jumps")
        XCTAssertEqual(Doc.wordCount(of: ast), 5)
    }

    func testReadingTimeMinutesIsZeroForEmptyDoc() {
        let doc = Doc(body: .empty)
        XCTAssertEqual(doc.readingTimeMinutes, 0)
    }

    func testReadingTimeMinutesRoundsUpAndIsAtLeastOneForAnyWords() {
        // 1 word: ceil(1/250) still clamped to a minimum of 1 minute.
        let doc = Doc(body: astWithOneParagraph("word"))
        XCTAssertEqual(doc.readingTimeMinutes, 1)
    }

    func testReadingTimeMinutesCeilsFractionalMinutes() {
        // 251 words = 1.004 minutes -> ceil -> 2.
        let words = Array(repeating: "w", count: 251).joined(separator: " ")
        let doc = Doc(body: astWithOneParagraph(words))
        XCTAssertEqual(doc.readingTimeMinutes, 2)
    }

    // MARK: - snippet / plainTextSnippet

    func testSnippetCollapsesNewlinesToSingleSpaces() {
        let firstID = UUID()
        let secondID = UUID()
        var ast = DocumentAST()
        ast.blocks[firstID] = paragraph("line one")
        ast.blocks[secondID] = paragraph("line two")
        ast.rootChildren = [firstID, secondID]
        let doc = Doc(body: ast)
        XCTAssertEqual(doc.snippet(), "line one line two")
    }

    func testSnippetTruncatesAtMaxLengthWithEllipsis() {
        let text = String(repeating: "a", count: 300)
        let doc = Doc(body: astWithOneParagraph(text))
        let snippet = doc.snippet(maxLength: 10)
        XCTAssertEqual(snippet.count, 11, "10 characters plus the ellipsis character")
        XCTAssertTrue(snippet.hasSuffix("\u{2026}"))
    }

    func testSnippetUnderMaxLengthIsNotTruncated() {
        let doc = Doc(body: astWithOneParagraph("short"))
        XCTAssertEqual(doc.snippet(maxLength: 200), "short")
    }

    // MARK: - plainText: depth-first, per-blocktype rules (Doc.plainText(of:))

    func testPlainTextJoinsRootBlocksWithNewlines() {
        let firstID = UUID()
        let secondID = UUID()
        var ast = DocumentAST()
        ast.blocks[firstID] = paragraph("first")
        ast.blocks[secondID] = paragraph("second")
        ast.rootChildren = [firstID, secondID]
        XCTAssertEqual(Doc.plainText(of: ast), "first\nsecond")
    }

    func testPlainTextSkipsBlocksWithNoTextContribution() {
        let dividerID = UUID()
        let paragraphID = UUID()
        var ast = DocumentAST()
        ast.blocks[dividerID] = Block(type: .divider)
        ast.blocks[paragraphID] = paragraph("visible")
        ast.rootChildren = [dividerID, paragraphID]
        XCTAssertEqual(Doc.plainText(of: ast), "visible", "a divider (and other no-text block types) must contribute nothing, not an empty line")
    }

    func testPlainTextWalksListChildrenWithoutAddingAnExtraLineForTheListItself() {
        let listID = UUID()
        let item1ID = UUID()
        let item2ID = UUID()
        var ast = DocumentAST()
        ast.blocks[listID] = Block(type: .list, children: [item1ID, item2ID])
        ast.blocks[item1ID] = Block(type: .listItem, content: [InlineRun(text: "one")], parentID: listID)
        ast.blocks[item2ID] = Block(type: .listItem, content: [InlineRun(text: "two")], parentID: listID)
        ast.rootChildren = [listID]
        XCTAssertEqual(Doc.plainText(of: ast), "one\ntwo")
    }

    func testPlainTextPrefixesCalloutWithEmoji() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(type: .callout, attributes: ["emoji": .string("💡")], content: [InlineRun(text: "idea")])
        ast.rootChildren = [id]
        XCTAssertEqual(Doc.plainText(of: ast), "💡 idea")
    }

    func testPlainTextOfEmptyDocumentIsEmptyString() {
        XCTAssertEqual(Doc.plainText(of: .empty), "")
    }

    // MARK: - subtype constants (a static contract, cheap to guard)

    func testEntityTypeAndSubtypeConstants() {
        XCTAssertEqual(Doc.entityType, "document")
        XCTAssertEqual(Doc.subtype, "doc")
        XCTAssertEqual(Doc(title: "x").subtypeString, "doc")
    }
}
