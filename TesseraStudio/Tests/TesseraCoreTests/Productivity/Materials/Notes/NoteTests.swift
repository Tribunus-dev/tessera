import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Notes/Note.swift
// doc comments (normalizeTags, displayTitle, snippet/plainText,
// wordCount/readingTimeMinutes -- 250 wpm baseline cited in the doc
// comment) plus docs/tessera-productivity-materials-notes-design.md
// section 3 ("Note model") for the field shape and section 8's
// "hard-constraint compliance" line naming the receipt vocabulary
// (covered in NoteStoreTests.swift, not here).

final class NoteTests: DoctrineTestCase {

    private func heading(_ text: String) -> Block {
        Block(type: .heading, attributes: ["level": .number(1)], content: [InlineRun(text: text)])
    }

    private func paragraph(_ text: String) -> Block {
        Block(type: .paragraph, content: [InlineRun(text: text)])
    }

    private func makeAST(blocks: [Block]) -> DocumentAST {
        var dict: [UUID: Block] = [:]
        var root: [UUID] = []
        for b in blocks {
            dict[b.id] = b
            root.append(b.id)
        }
        return DocumentAST(blocks: dict, rootChildren: root)
    }

    private func makeNote(
        id: UUID = UUID(),
        title: String = "Q3 review",
        body: DocumentAST = .empty,
        tags: [String] = ["q3", "review"]
    ) -> Note {
        Note(
            id: id, title: title, body: body, tags: tags,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let ast = makeAST(blocks: [heading("Q3 Review"), paragraph("First paragraph.")])
        let original = makeNote(body: ast, tags: ["q3", "urgent"])
        let decoded = try Note.from(jsonData: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        let note = makeNote()
        XCTAssertEqual(try note.jsonData(), try note.jsonData())
    }

    // MARK: - entityType / subtype pins

    func testEntityTypeIsPinnedToNote() {
        XCTAssertEqual(Note.entityType, "note")
    }

    func testSubtypeIsPinnedToMarkdown() {
        XCTAssertEqual(Note.subtype, "markdown")
        XCTAssertEqual(makeNote().subtypeString, "markdown")
    }

    // MARK: - Tag normalization (fixtures, doctrine rule 9)

    func testNormalizeTagsLowercasesTrimsAndDeduplicates() {
        let normalized = Note.normalizeTags([" Q3 ", "q3", "Review", ""])
        XCTAssertEqual(normalized, ["q3", "review"])
    }

    func testInitNormalizesTagsAtConstruction() {
        let note = Note(title: "x", tags: [" Foo ", "foo"])
        XCTAssertEqual(note.tags, ["foo"])
    }

    // MARK: - isPinned / isArchived convenience

    func testIsPinnedTrueWhenPinnedAtSet() {
        var note = makeNote()
        note.pinnedAt = Date()
        XCTAssertTrue(note.isPinned)
    }

    func testIsPinnedFalseWhenPinnedAtNil() {
        XCTAssertFalse(makeNote().isPinned)
    }

    func testIsArchivedTrueWhenArchivedAtSet() {
        var note = makeNote()
        note.archivedAt = Date()
        XCTAssertTrue(note.isArchived)
    }

    // MARK: - displayTitle fallbacks

    func testDisplayTitleUsesExplicitTitleWhenPresent() {
        XCTAssertEqual(makeNote(title: "Explicit").displayTitle, "Explicit")
    }

    func testDisplayTitleFallsBackToFirstHeadingWhenTitleEmpty() {
        let ast = makeAST(blocks: [heading("From heading"), paragraph("body")])
        let note = makeNote(title: "", body: ast)
        XCTAssertEqual(note.displayTitle, "From heading")
    }

    func testDisplayTitleFallsBackToUntitledWhenNoTitleOrHeading() {
        let ast = makeAST(blocks: [paragraph("just a paragraph")])
        let note = makeNote(title: "  ", body: ast)
        XCTAssertEqual(note.displayTitle, "Untitled")
    }

    // MARK: - firstHeadingText

    func testFirstHeadingTextReturnsNilWhenNoHeadingBlocks() {
        let ast = makeAST(blocks: [paragraph("no headings here")])
        XCTAssertNil(Note.firstHeadingText(in: ast))
    }

    func testFirstHeadingTextReturnsTheFirstNonEmptyHeading() {
        let ast = makeAST(blocks: [heading("First"), heading("Second")])
        XCTAssertEqual(Note.firstHeadingText(in: ast), "First")
    }

    // MARK: - plainText / snippet / wordCount / readingTimeMinutes

    func testPlainTextOfEmptyASTIsEmptyString() {
        XCTAssertEqual(Note.plainText(of: .empty), "")
    }

    func testPlainTextJoinsParagraphsWithNewlines() {
        let ast = makeAST(blocks: [paragraph("first"), paragraph("second")])
        XCTAssertEqual(Note.plainText(of: ast), "first\nsecond")
    }

    func testWordCountOfEmptyASTIsZero() {
        XCTAssertEqual(Note.wordCount(of: .empty), 0)
        XCTAssertEqual(makeNote(body: .empty).wordCount, 0)
    }

    func testWordCountCountsWhitespaceSeparatedTokens() {
        let ast = makeAST(blocks: [paragraph("one two three four five")])
        XCTAssertEqual(Note.wordCount(of: ast), 5)
    }

    func testReadingTimeMinutesIsZeroForEmptyNote() {
        XCTAssertEqual(makeNote(body: .empty).readingTimeMinutes, 0)
    }

    func testReadingTimeMinutesIsAtLeastOneForAnyNonEmptyNote() {
        // Doc comment: "Returns 1 minute for any non-empty note (so a
        // 5-word note doesn't read as 0 min)."
        let ast = makeAST(blocks: [paragraph("just five words here now")])
        let note = makeNote(body: ast)
        XCTAssertEqual(note.wordCount, 5)
        XCTAssertEqual(note.readingTimeMinutes, 1)
    }

    func testReadingTimeMinutesIsCeilingOfWordCountOver250() {
        // 251 words -> ceil(251/250) = 2 minutes.
        let words = (1...251).map { "w\($0)" }.joined(separator: " ")
        let ast = makeAST(blocks: [paragraph(words)])
        let note = makeNote(body: ast)
        XCTAssertEqual(note.wordCount, 251)
        XCTAssertEqual(note.readingTimeMinutes, 2)
    }

    func testSnippetCapsAtMaxLengthWithEllipsis() {
        let longText = String(repeating: "a", count: 300)
        let ast = makeAST(blocks: [paragraph(longText)])
        let snippet = Note.plainTextSnippet(from: ast, maxLength: 200)
        XCTAssertEqual(snippet.count, 201) // 200 chars + the ellipsis char
        XCTAssertTrue(snippet.hasSuffix("\u{2026}"))
    }

    func testSnippetDoesNotTruncateWhenUnderMaxLength() {
        let ast = makeAST(blocks: [paragraph("short note")])
        XCTAssertEqual(Note.plainTextSnippet(from: ast, maxLength: 200), "short note")
    }
}
