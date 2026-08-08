import XCTest
@testable import TesseraCore

final class DocRowTests: XCTestCase {

    func testRelativeTimeJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(DocRow.relativeTimeString(for: now, now: now), "just now")
        XCTAssertEqual(DocRow.relativeTimeString(for: now.addingTimeInterval(-30), now: now), "just now")
    }

    func testRelativeTimeMinutesAndHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(DocRow.relativeTimeString(for: now.addingTimeInterval(-120), now: now), "2 min ago")
        XCTAssertEqual(DocRow.relativeTimeString(for: now.addingTimeInterval(-7200), now: now), "2 hr ago")
    }

    func testDocRowInit() {
        let doc = Doc(title: "Hello", body: .empty)
        let row = DocRow(doc: doc)
        XCTAssertEqual(row.title, "Hello")
        XCTAssertFalse(row.isFavorite)
        XCTAssertFalse(row.isArchived)
        XCTAssertFalse(row.isTrashed)
        XCTAssertFalse(row.hasCover)
        XCTAssertEqual(row.wordCount, 0)
    }

    func testDocRowWithCoverAndIcon() {
        var doc = Doc(title: "t", body: .empty)
        doc.coverImageURL = URL(string: "https://example.com/c.jpg")
        doc.iconEmoji = "📄"
        doc.isFavorite = true
        let row = DocRow(doc: doc)
        XCTAssertTrue(row.hasCover)
        XCTAssertEqual(row.iconEmoji, "📄")
        XCTAssertTrue(row.isFavorite)
    }

    func testDocRowReadingTime() {
        var ast = DocumentAST()
        let bid = UUID()
        // 500 words -> 2 min
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: Array(repeating: "word", count: 500).joined(separator: " "))])
        ast.rootChildren = [bid]
        let doc = Doc(title: "t", body: ast)
        XCTAssertEqual(DocRow(doc: doc).readingTimeMinutes, 2)
    }
}
