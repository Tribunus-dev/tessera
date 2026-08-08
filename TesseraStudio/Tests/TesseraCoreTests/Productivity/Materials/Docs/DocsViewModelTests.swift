import XCTest
@testable import TesseraCore

@MainActor
final class DocsViewModelTests: XCTestCase {

    private func makeViewModel() -> DocsViewModel {
        let dataLayer = TesseraDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        return DocsViewModel(store: store, dataLayer: dataLayer)
    }

    private func makeDoc(title: String, updatedAt: Date = Date(timeIntervalSince1970: 1_000_000), tags: [String] = [], isFavorite: Bool = false, isArchived: Bool = false, isTrashed: Bool = false) -> Doc {
        Doc(id: UUID(), title: title, body: .empty, isArchived: isArchived, isTrashed: isTrashed, isFavorite: isFavorite, tags: Doc.normalizeTags(tags), createdAt: updatedAt, updatedAt: updatedAt)
    }

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.allDocs.count, 0)
        XCTAssertEqual(vm.rows.count, 0)
        XCTAssertEqual(vm.filter, .all)
        XCTAssertNil(vm.selectedDocID)
        XCTAssertNil(vm.activeTag)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertFalse(vm.isChatDriven)
        XCTAssertNil(vm.editor)
    }

    func testApplyFilterProjectsRows() {
        let vm = makeViewModel()
        vm.setAllDocsForTesting([
            makeDoc(title: "a", updatedAt: Date(timeIntervalSince1970: 2_000)),
            makeDoc(title: "b", updatedAt: Date(timeIntervalSince1970: 1_000)),
        ])
        XCTAssertEqual(vm.rows.map { $0.title }, ["a", "b"])
    }

    func testFavoritesFilter() {
        let vm = makeViewModel()
        vm.setAllDocsForTesting([
            makeDoc(title: "fav", isFavorite: true),
            makeDoc(title: "plain"),
        ])
        vm.filter = .favorites
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["fav"])
    }

    func testActiveTagFiltersRows() {
        let vm = makeViewModel()
        vm.setAllDocsForTesting([
            makeDoc(title: "A", tags: ["q3"]),
            makeDoc(title: "B", tags: ["other"]),
        ])
        vm.setActiveTag("q3")
        XCTAssertEqual(vm.rows.map { $0.title }, ["A"])
        vm.setActiveTag(nil)
        XCTAssertEqual(vm.rows.count, 2)
    }

    func testLocalSearchFilters() {
        let vm = makeViewModel()
        vm.setAllDocsForTesting([
            makeDoc(title: "Q3 Review"),
            makeDoc(title: "Random note"),
        ])
        vm.applyLocalSearch("q3")
        XCTAssertEqual(vm.rows.map { $0.title }, ["Q3 Review"])
        vm.applyLocalSearch("")
        XCTAssertEqual(vm.rows.count, 2)
    }

    func testAllTagsSorted() {
        let vm = makeViewModel()
        vm.setAllDocsForTesting([
            makeDoc(title: "a", tags: ["swift", "aTag"]),
            makeDoc(title: "b", tags: ["swift", "q3"]),
        ])
        XCTAssertEqual(vm.allTags, ["atag", "q3", "swift"])
    }

    func testSelectionCreatesEditor() {
        let vm = makeViewModel()
        let doc = makeDoc(title: "hello")
        vm.setAllDocsForTesting([doc])
        vm.select(doc.id)
        XCTAssertEqual(vm.selectedDocID, doc.id)
        XCTAssertNotNil(vm.editor)
        XCTAssertEqual(vm.editor?.doc.title, "hello")
        vm.select(nil)
        XCTAssertNil(vm.editor)
    }

    func testTrashFilter() {
        let vm = makeViewModel()
        vm.setAllDocsForTesting([
            makeDoc(title: "trashed", isTrashed: true),
            makeDoc(title: "active"),
        ])
        vm.filter = .trash
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["trashed"])
    }
}
