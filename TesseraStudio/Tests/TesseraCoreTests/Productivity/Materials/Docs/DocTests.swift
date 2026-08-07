import XCTest
@testable import TesseraCore

final class DocTests: XCTestCase {

    // MARK: - displayTitle

    func testDisplayTitlePrefersExplicitTitle() {
        var doc = Doc(title: "  Hello  ", body: .empty)
        XCTAssertEqual(doc.displayTitle, "Hello")
        doc.title = ""
        XCTAssertEqual(doc.displayTitle, "Untitled")
    }

    func testDisplayTitleFallsBackToFirstHeading() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .heading, content: [InlineRun(text: "My Heading")])
        ast.rootChildren = [bid]
        let doc = Doc(title: "", body: ast)
        XCTAssertEqual(doc.displayTitle, "My Heading")
    }

    func testDisplayTitleUntitledWhenEmpty() {
        XCTAssertEqual(Doc(title: "", body: .empty).displayTitle, "Untitled")
    }

    // MARK: - snippet / wordCount / readingTime

    func testSnippetEmptyForEmptyBody() {
        XCTAssertEqual(Doc(title: "t", body: .empty).snippet(), "")
    }

    func testWordCountEmptyIsZero() {
        XCTAssertEqual(Doc(title: "t", body: .empty).wordCount, 0)
    }

    func testReadingTimeZeroForEmpty() {
        XCTAssertEqual(Doc(title: "t", body: .empty).readingTimeMinutes, 0)
    }

    func testReadingTimeOneForShortDoc() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: "hello world")])
        ast.rootChildren = [bid]
        XCTAssertEqual(Doc(title: "t", body: ast).readingTimeMinutes, 1)
    }

    func testWordCountCountsTokens() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: "one two three")])
        ast.rootChildren = [bid]
        XCTAssertEqual(Doc(title: "t", body: ast).wordCount, 3)
    }

    // MARK: - normalizeTags

    func testNormalizeTagsLowercasesAndDedupes() {
        XCTAssertEqual(Doc.normalizeTags([" Swift ", "swift", "SWIFT", "  "]), ["swift"])
        XCTAssertEqual(Doc.normalizeTags(["a", "B", "a"]), ["a", "b"])
    }

    // MARK: - JSON round-trip

    func testJSONStringRoundTrip() throws {
        let doc = Doc(title: "Hello", body: .empty, tags: ["swift"], createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let s = try doc.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try Doc.from(jsonDataString: s)
        XCTAssertEqual(parsed, doc)
    }

    func testJSONDataRoundTrip() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let doc = Doc(title: "T", body: .empty, createdAt: fixed, updatedAt: fixed)
        let data = try doc.jsonData()
        let parsed = try Doc.from(jsonData: data)
        XCTAssertEqual(parsed, doc)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try Doc.from(jsonDataString: "not json"))
    }

    // MARK: - Cover / icon

    func testCoverAndIconPersistThroughJSON() throws {
        var doc = Doc(title: "t", body: .empty)
        doc.coverImageURL = URL(string: "https://example.com/cover.jpg")
        doc.iconEmoji = "📄"
        let parsed = try Doc.from(jsonData: doc.jsonData())
        XCTAssertEqual(parsed.coverImageURL, doc.coverImageURL)
        XCTAssertEqual(parsed.iconEmoji, "📄")
    }

    // MARK: - Flags

    func testFlagsDefaultFalse() {
        let doc = Doc(title: "t")
        XCTAssertFalse(doc.isArchived)
        XCTAssertFalse(doc.isTrashed)
        XCTAssertFalse(doc.isFavorite)
    }

    func testEntityTypeConstants() {
        XCTAssertEqual(Doc.entityType, "document")
        XCTAssertEqual(Doc.subtype, "doc")
    }
}
