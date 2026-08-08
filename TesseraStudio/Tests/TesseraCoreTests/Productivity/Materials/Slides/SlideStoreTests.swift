import XCTest
@testable import TesseraCore

final class SlideStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = SlideStore(dataLayer: dataLayer)
        _ = store
    }

    func testJSONStringRoundTripViaDeckHelper() throws {
        let deck = SlideDeck(title: "Hello", body: .empty, tags: ["a"])
        let s = try deck.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try SlideDeck.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    func testInvalidBodyEquatable() {
        XCTAssertEqual(SlideStoreError.invalidBody(reason: "x"), SlideStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(SlideStoreError.invalidBody(reason: "x"), SlideStoreError.invalidBody(reason: "y"))
    }

    func testDeckNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(SlideStoreError.deckNotFound(id: id), SlideStoreError.deckNotFound(id: id))
        XCTAssertNotEqual(SlideStoreError.deckNotFound(id: id), SlideStoreError.deckNotFound(id: UUID()))
    }

    func testSlideOutOfBoundsEquatable() {
        XCTAssertEqual(SlideStoreError.slideOutOfBounds(index: 3, count: 2), SlideStoreError.slideOutOfBounds(index: 3, count: 2))
        XCTAssertNotEqual(SlideStoreError.slideOutOfBounds(index: 3, count: 2), SlideStoreError.slideOutOfBounds(index: 4, count: 2))
    }

    func testListFilterApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = SlideDeck(id: UUID(), title: "a", body: .empty, isFavorite: true, createdAt: now, updatedAt: now)
        let b = SlideDeck(id: UUID(), title: "b", body: .empty, isArchived: true, createdAt: now, updatedAt: now)
        let c = SlideDeck(id: UUID(), title: "c", body: .empty, isTrashed: true, createdAt: now, updatedAt: now)
        let all = [a, b, c]
        XCTAssertEqual(SlideListFilter.all.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(SlideListFilter.favorites.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(SlideListFilter.archived.apply(to: all).map { $0.title }, ["b"])
        XCTAssertEqual(SlideListFilter.trash.apply(to: all).map { $0.title }, ["c"])
    }

    func testNormalizeTagsViaDeck() {
        XCTAssertEqual(SlideDeck.normalizeTags([" Hello ", "hello"]), ["hello"])
    }

    func testMakeBlankHasOneSlideWithDefaultLayout() {
        let deck = SlideDeck.makeBlank(title: "T")
        XCTAssertEqual(deck.slideCount, 1)
        XCTAssertEqual(deck.slides[0].layout, .title)
    }

    func testInsertingSlideClampBeyondCount() {
        let deck = SlideDeck.makeBlank(title: "t")
        let next = deck.insertingSlide(at: 99, layout: .blank)
        XCTAssertEqual(next.slideCount, 2)
    }

    func testInsertingSlideNegativeIndexClampsToZero() {
        let deck = SlideDeck.makeBlank(title: "t")
        let next = deck.insertingSlide(at: -5, layout: .blank)
        XCTAssertEqual(next.slideCount, 2)
        XCTAssertEqual(next.body.rootChildren.count, 2)
    }

    func testSlideDeckRowHasSlideCount() {
        let deck = SlideDeck.makeBlank(title: "Hi")
        let row = SlideDeckRow(deck: deck)
        XCTAssertEqual(row.slideCount, 1)
        XCTAssertEqual(row.title, "Hi")
        XCTAssertFalse(row.isFavorite)
    }

    func testSlideDeckRowReadingRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SlideDeckRow.relativeTimeString(for: now, now: now), "just now")
        XCTAssertEqual(
            SlideDeckRow.relativeTimeString(for: now.addingTimeInterval(-120), now: now),
            "2 min ago"
        )
    }

    func testSlideMetaCodable() throws {
        let meta = SlideMeta(layout: .image, notes: "hello notes")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SlideMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    func testSlideMetaDefault() {
        XCTAssertEqual(SlideMeta.default.layout, .titleAndContent)
        XCTAssertEqual(SlideMeta.default.notes, "")
    }
}
