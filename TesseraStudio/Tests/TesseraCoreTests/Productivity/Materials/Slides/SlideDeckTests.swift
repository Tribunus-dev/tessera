import XCTest
@testable import TesseraCore

// MARK: - SlideDeckTests

final class SlideDeckTests: XCTestCase {

    // MARK: - displayTitle

    func testDisplayTitlePrefersExplicitTitle() {
        XCTAssertEqual(SlideDeck(title: "  Hi  ", body: .empty).displayTitle, "Hi")
        XCTAssertEqual(SlideDeck(title: "", body: .empty).displayTitle, "Untitled")
    }

    func testDisplayTitleFallsBackToFirstHeading() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .heading, content: [InlineRun(text: "My Deck")])
        ast.rootChildren = [bid]
        XCTAssertEqual(SlideDeck(title: "", body: ast).displayTitle, "My Deck")
    }

    // MARK: - snippet / wordCount

    func testSnippetEmptyForEmptyBody() {
        XCTAssertEqual(SlideDeck(title: "t", body: .empty).snippet(), "")
    }

    func testWordCountEmptyIsZero() {
        XCTAssertEqual(SlideDeck(title: "t", body: .empty).wordCount, 0)
    }

    func testWordCountCountsTokens() {
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: "one two three")])
        ast.rootChildren = [bid]
        XCTAssertEqual(SlideDeck(title: "t", body: ast).wordCount, 3)
    }

    // MARK: - slideCount / slides

    func testEmptyDeckHasNoSlides() {
        XCTAssertEqual(SlideDeck(title: "t").slideCount, 0)
        XCTAssertTrue(SlideDeck(title: "t").slides.isEmpty)
    }

    func testMakeBlankProducesOneSlide() {
        let deck = SlideDeck.makeBlank(title: "Hello")
        XCTAssertEqual(deck.slideCount, 1)
        XCTAssertEqual(deck.slides.count, 1)
    }

    func testInsertingSlideIncrementsCount() {
        let deck = SlideDeck.makeBlank(title: "t")
        let updated = deck.insertingSlide(at: 1, layout: .titleAndContent)
        XCTAssertEqual(updated.slideCount, 2)
        XCTAssertEqual(updated.slides[1].layout, .titleAndContent)
    }

    func testSlidesHaveCorrectIndices() {
        var deck = SlideDeck.makeEmpty(title: "t")
        deck = deck.insertingSlide(at: 0, layout: .title)
        deck = deck.insertingSlide(at: 1, layout: .blank)
        deck = deck.insertingSlide(at: 2, layout: .image)
        let slides = deck.slides
        XCTAssertEqual(slides.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(slides[0].layout, .title)
        XCTAssertEqual(slides[2].layout, .image)
    }

    func testSlideAtOutOfRangeReturnsNil() {
        let deck = SlideDeck.makeBlank(title: "t")
        XCTAssertNil(deck.slide(at: -1))
        XCTAssertNil(deck.slide(at: 5))
    }

    func testSlideIDLookup() {
        let deck = SlideDeck.makeBlank(title: "t")
        let id = deck.body.rootChildren[0]
        XCTAssertNotNil(deck.slide(id: id))
        XCTAssertNil(deck.slide(id: UUID()))
    }

    func testThumbnailHintNilWhenNoImage() {
        let deck = SlideDeck.makeBlank(title: "t")
        XCTAssertNil(deck.slides[0].thumbnailHint)
    }

    func testSlideLayoutDisplayNames() {
        XCTAssertEqual(SlideLayout.title.displayName, "Title")
        XCTAssertEqual(SlideLayout.blank.displayName, "Blank")
    }

    // MARK: - normalizeTags

    func testNormalizeTagsLowercasesAndDedupes() {
        XCTAssertEqual(SlideDeck.normalizeTags([" Swift ", "swift", "SWIFT", "  "]), ["swift"])
        XCTAssertEqual(SlideDeck.normalizeTags(["a", "B", "a"]), ["a", "b"])
    }

    // MARK: - JSON round-trip

    func testJSONStringRoundTrip() throws {
        let deck = SlideDeck(
            title: "Hello", body: .empty, tags: ["swift"],
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let s = try deck.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try SlideDeck.from(jsonDataString: s)
        XCTAssertEqual(parsed, deck)
    }

    func testJSONDataRoundTrip() throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let deck = SlideDeck(title: "T", body: .empty, createdAt: fixed, updatedAt: fixed)
        let data = try deck.jsonData()
        let parsed = try SlideDeck.from(jsonData: data)
        XCTAssertEqual(parsed, deck)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try SlideDeck.from(jsonDataString: "not json"))
    }

    func testInvalidJSONStringThrows() {
        XCTAssertThrowsError(try SlideDeck.from(jsonDataString: "{ invalid"))
    }

    // MARK: - Flags

    func testFlagsDefaultFalse() {
        let deck = SlideDeck(title: "t")
        XCTAssertFalse(deck.isArchived)
        XCTAssertFalse(deck.isTrashed)
        XCTAssertFalse(deck.isFavorite)
    }

    func testEntityTypeConstants() {
        XCTAssertEqual(SlideDeck.entityType, "document")
        XCTAssertEqual(SlideDeck.subtype, "slide")
    }

    // MARK: - Toggle slide title extraction

    func testTitleExtractionFromToggleGroup() {
        var deck = SlideDeck.makeEmpty(title: "")
        deck = deck.insertingSlide(at: 0, layout: .titleAndContent, title: "Grouped Title")
        let slide = deck.slides[0]
        XCTAssertEqual(slide.title, "Grouped Title")
    }
}
