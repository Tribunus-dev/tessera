import XCTest
@testable import TesseraCore

@MainActor
final class DrawingsViewModelTests: XCTestCase {

    private func makeViewModel() -> DrawingsViewModel {
        let dataLayer = TesseraDataLayer()
        let store = DrawingStore(dataLayer: dataLayer)
        return DrawingsViewModel(store: store, dataLayer: dataLayer)
    }

    private func makeDrawing(
        title: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        tags: [String] = [],
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false
    ) -> Drawing {
        Drawing(
            id: UUID(), title: title,
            isArchived: isArchived, isTrashed: isTrashed, isFavorite: isFavorite,
            tags: Drawing.normalizeTags(tags),
            createdAt: updatedAt, updatedAt: updatedAt
        )
    }

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.allDrawings.count, 0)
        XCTAssertEqual(vm.rows.count, 0)
        XCTAssertEqual(vm.filter, .all)
        XCTAssertNil(vm.selectedDrawingID)
        XCTAssertNil(vm.selectedDrawing)
        XCTAssertNil(vm.activeTag)
        XCTAssertEqual(vm.searchText, "")
    }

    func testApplyFilterProjectsRowsSortedByMostRecentlyUpdated() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([
            makeDrawing(title: "a", updatedAt: Date(timeIntervalSince1970: 1_000)),
            makeDrawing(title: "b", updatedAt: Date(timeIntervalSince1970: 2_000)),
        ])
        XCTAssertEqual(vm.rows.map { $0.title }, ["b", "a"])
    }

    func testFavoritesFilter() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "fav", isFavorite: true), makeDrawing(title: "plain")])
        vm.filter = .favorites
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["fav"])
    }

    func testArchivedFilterExcludesTrashed() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([
            makeDrawing(title: "archived", isArchived: true),
            makeDrawing(title: "archivedAndTrashed", isArchived: true, isTrashed: true),
        ])
        vm.filter = .archived
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["archived"])
    }

    func testTrashFilter() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "gone", isTrashed: true), makeDrawing(title: "here")])
        vm.filter = .trash
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["gone"])
    }

    func testActiveTagFiltersRows() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "A", tags: ["q3"]), makeDrawing(title: "B", tags: ["other"])])
        vm.setActiveTag("q3")
        XCTAssertEqual(vm.rows.map { $0.title }, ["A"])
    }

    func testSetActiveTagNilClearsFilter() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "A", tags: ["q3"]), makeDrawing(title: "B")])
        vm.setActiveTag("q3")
        vm.setActiveTag(nil)
        XCTAssertEqual(vm.rows.count, 2)
    }

    func testLocalSearchByTitle() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "Wireframe"), makeDrawing(title: "Icon set")])
        vm.applyLocalSearch("wire")
        XCTAssertEqual(vm.rows.map { $0.title }, ["Wireframe"])
    }

    func testLocalSearchByTag() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "A", tags: ["logo"]), makeDrawing(title: "B")])
        vm.applyLocalSearch("logo")
        XCTAssertEqual(vm.rows.map { $0.title }, ["A"])
    }

    func testAllTagsCollectsDistinctSorted() {
        let vm = makeViewModel()
        vm.setAllDrawingsForTesting([makeDrawing(title: "A", tags: ["b", "a"]), makeDrawing(title: "B", tags: ["a", "c"])])
        XCTAssertEqual(vm.allTags, ["a", "b", "c"])
    }

    func testSelectSetsSelectedDrawingID() {
        let vm = makeViewModel()
        let d = makeDrawing(title: "A")
        vm.setAllDrawingsForTesting([d])
        vm.select(d.id)
        XCTAssertEqual(vm.selectedDrawingID, d.id)
        XCTAssertEqual(vm.selectedDrawing?.id, d.id)
    }

    func testSelectNilClearsSelection() {
        let vm = makeViewModel()
        let d = makeDrawing(title: "A")
        vm.setAllDrawingsForTesting([d])
        vm.select(d.id)
        vm.select(nil)
        XCTAssertNil(vm.selectedDrawingID)
        XCTAssertNil(vm.selectedDrawing)
    }

    func testDrawingListFilterDisplayNamesAndSystemImages() {
        XCTAssertEqual(DrawingListFilter.all.displayName, "All")
        XCTAssertEqual(DrawingListFilter.favorites.displayName, "Favorites")
        XCTAssertEqual(DrawingListFilter.archived.displayName, "Archived")
        XCTAssertEqual(DrawingListFilter.trash.displayName, "Trash")
        for filter in DrawingListFilter.allCases {
            XCTAssertFalse(filter.systemImage.isEmpty)
        }
    }
}
