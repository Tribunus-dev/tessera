import XCTest
@testable import TesseraCore

@MainActor
final class SlideCanvasViewModelTests: XCTestCase {

    private func makeStore() -> SlideStore { SlideStore(dataLayer: TesseraDataLayer()) }

    private func makeDeck(title: String = "T") -> SlideDeck {
        SlideDeck.makeBlank(title: title)
    }

    private func makeEditor(deck: SlideDeck? = nil) -> SlideDeckEditorViewModel {
        let d = deck ?? makeDeck()
        return SlideDeckEditorViewModel(deck: d, store: makeStore(), userID: UUID())
    }

    func testInitialState() {
        let deck = makeDeck(title: "Hi")
        let editor = makeEditor(deck: deck)
        XCTAssertEqual(editor.deck.title, "Hi")
        XCTAssertEqual(editor.draftTitle, "Hi")
        XCTAssertEqual(editor.draftTag, "")
        XCTAssertFalse(editor.isSaving)
        XCTAssertNil(editor.lastError)
        XCTAssertEqual(editor.document, deck.body)
    }

    func testSetDocumentLocalDoesNotCommitDeck() {
        let editor = makeEditor()
        let originalBody = editor.deck.body
        var ast = DocumentAST()
        let bid = UUID()
        ast.blocks[bid] = Block(id: bid, type: .paragraph, content: [InlineRun(text: "new")])
        ast.rootChildren = [bid]
        editor.setDocumentLocal(ast)
        XCTAssertEqual(editor.document, ast)
        XCTAssertEqual(editor.deck.body, originalBody)
    }

    func testRefreshReplacesDeck() {
        let editor = makeEditor(deck: makeDeck(title: "old"))
        let newDeck = SlideDeck(title: "new", body: .empty)
        editor.refresh(with: newDeck)
        XCTAssertEqual(editor.deck.title, "new")
        XCTAssertEqual(editor.draftTitle, "new")
    }

    func testSlidesViewMatchesDeck() {
        var deck = SlideDeck.makeEmpty(title: "t")
        deck = deck.insertingSlide(at: 0, layout: .title)
        deck = deck.insertingSlide(at: 1, layout: .blank)
        let editor = makeEditor(deck: deck)
        XCTAssertEqual(editor.slides.count, 2)
        XCTAssertNotNil(editor.slide(at: 0))
        XCTAssertNil(editor.slide(at: 99))
    }

    func testDisplayTitleFallsBack() {
        XCTAssertEqual(SlideDeck(title: "  hi  ", body: .empty).displayTitle, "hi")
        XCTAssertEqual(SlideDeck(title: "", body: .empty).displayTitle, "Untitled")
    }

    func testSlideDeckRowRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SlideDeckRow.relativeTimeString(for: now, now: now), "just now")
        XCTAssertEqual(
            SlideDeckRow.relativeTimeString(for: now.addingTimeInterval(-7200), now: now),
            "2 hr ago"
        )
    }

    func testSlideDeckRowWithSlideCount() {
        let deck = makeDeck(title: "t")
        let row = SlideDeckRow(deck: deck)
        XCTAssertEqual(row.slideCount, deck.slideCount)
        XCTAssertFalse(row.isArchived)
    }

    func testSlideLayoutBindingPersistsThroughRoundTrip() throws {
        var deck = SlideDeck.makeBlank(title: "t")
        // Change layout and check it survives JSON.
        let id = deck.body.rootChildren[0].uuidString
        deck.slideMeta[id] = SlideMeta(layout: .image, notes: "my notes")
        let data = try deck.jsonData()
        let decoded = try SlideDeck.from(jsonData: data)
        XCTAssertEqual(decoded.slideMeta[id]?.layout, .image)
        XCTAssertEqual(decoded.slideMeta[id]?.notes, "my notes")
    }
}
