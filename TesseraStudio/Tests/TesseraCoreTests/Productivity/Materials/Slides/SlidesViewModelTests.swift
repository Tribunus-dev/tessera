import XCTest
@testable import TesseraCore

@MainActor
final class SlidesViewModelTests: XCTestCase {

    private func makeViewModel() -> SlidesViewModel {
        let dataLayer = TesseraDataLayer()
        let store = SlideStore(dataLayer: dataLayer)
        return SlidesViewModel(store: store, dataLayer: dataLayer)
    }

    private func makeDeck(
        title: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        tags: [String] = [],
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false
    ) -> SlideDeck {
        SlideDeck(
            id: UUID(), title: title, body: .empty,
            isArchived: isArchived, isTrashed: isTrashed, isFavorite: isFavorite,
            tags: SlideDeck.normalizeTags(tags),
            createdAt: updatedAt, updatedAt: updatedAt)
    }

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.allDecks.count, 0)
        XCTAssertEqual(vm.rows.count, 0)
        XCTAssertEqual(vm.filter, .all)
        XCTAssertNil(vm.selectedDeckID)
        XCTAssertNil(vm.activeTag)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertFalse(vm.isChatDriven)
        XCTAssertNil(vm.editor)
        XCTAssertEqual(vm.selectedSlideIndex, 0)
    }

    func testApplyFilterProjectsRows() {
        let vm = makeViewModel()
        vm.setAllDecksForTesting([
            makeDeck(title: "a", updatedAt: Date(timeIntervalSince1970: 2_000)),
            makeDeck(title: "b", updatedAt: Date(timeIntervalSince1970: 1_000)),
        ])
        XCTAssertEqual(vm.rows.map { $0.title }, ["a", "b"])
    }

    func testFavoritesFilter() {
        let vm = makeViewModel()
        vm.setAllDecksForTesting([makeDeck(title: "fav", isFavorite: true), makeDeck(title: "plain")])
        vm.filter = .favorites
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["fav"])
    }

    func testActiveTagFiltersRows() {
        let vm = makeViewModel()
        vm.setAllDecksForTesting([makeDeck(title: "A", tags: ["q3"]), makeDeck(title: "B", tags: ["other"])])
        vm.setActiveTag("q3")
        XCTAssertEqual(vm.rows.map { $0.title }, ["A"])
        vm.setActiveTag(nil)
        XCTAssertEqual(vm.rows.count, 2)
    }

    func testLocalSearchFilters() {
        let vm = makeViewModel()
        vm.setAllDecksForTesting([makeDeck(title: "Q3 Review"), makeDeck(title: "Random deck")])
        vm.applyLocalSearch("q3")
        XCTAssertEqual(vm.rows.map { $0.title }, ["Q3 Review"])
        vm.applyLocalSearch("")
        XCTAssertEqual(vm.rows.count, 2)
    }

    func testAllTagsSorted() {
        let vm = makeViewModel()
        vm.setAllDecksForTesting([
            makeDeck(title: "a", tags: ["swift", "aTag"]),
            makeDeck(title: "b", tags: ["swift", "q3"]),
        ])
        XCTAssertEqual(vm.allTags, ["atag", "q3", "swift"])
    }

    func testSelectionCreatesEditor() {
        let vm = makeViewModel()
        let deck = makeDeck(title: "hello")
        vm.setAllDecksForTesting([deck])
        vm.select(deck.id)
        XCTAssertEqual(vm.selectedDeckID, deck.id)
        XCTAssertNotNil(vm.editor)
        XCTAssertEqual(vm.editor?.deck.title, "hello")
        vm.select(nil)
        XCTAssertNil(vm.editor)
    }

    func testTrashFilter() {
        let vm = makeViewModel()
        vm.setAllDecksForTesting([makeDeck(title: "trashed", isTrashed: true), makeDeck(title: "active")])
        vm.filter = .trash
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["trashed"])
    }

    func testSelectSlideClampsToDeckBounds() {
        let vm = makeViewModel()
        let deck = SlideDeck.makeBlank(title: "t")
        vm.setAllDecksForTesting([deck])
        vm.select(deck.id)
        vm.selectSlide(at: 99)
        XCTAssertEqual(vm.selectedSlideIndex, 0)
        vm.selectSlide(at: 0)
        XCTAssertEqual(vm.selectedSlideIndex, 0)
    }

    func testSelectResetsSlideIndex() {
        let vm = makeViewModel()
        let a = makeDeck(title: "a")
        let b = makeDeck(title: "b")
        vm.setAllDecksForTesting([a, b])
        vm.select(a.id)
        vm.selectSlide(at: 0)
        vm.select(b.id)
        XCTAssertEqual(vm.selectedSlideIndex, 0)
    }
}
