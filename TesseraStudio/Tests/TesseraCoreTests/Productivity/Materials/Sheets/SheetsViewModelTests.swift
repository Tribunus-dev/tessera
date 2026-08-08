import XCTest
@testable import TesseraCore

/// Tests for the pure / in-memory parts of ``SheetsViewModel``:
/// filter application, local search, tag-chip logic, sorting.
/// Actor-backed load/save is env-gated for the integration test.
@MainActor
final class SheetsViewModelTests: XCTestCase {

    private func makeViewModel() -> SheetsViewModel {
        let dataLayer = TesseraDataLayer()
        let store = SheetStore(dataLayer: dataLayer)
        return SheetsViewModel(store: store, dataLayer: dataLayer)
    }

    private func makeSheet(
        title: String = "Untitled",
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        tags: [String] = [],
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false
    ) -> Sheet {
        Sheet(
            title: title,
            body: .empty,
            columns: [],
            isArchived: isArchived,
            isTrashed: isTrashed,
            isFavorite: isFavorite,
            tags: Sheet.normalizeTags(tags),
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Initial state

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.allSheets.count, 0)
        XCTAssertEqual(vm.rows.count, 0)
        XCTAssertEqual(vm.filter, .all)
        XCTAssertNil(vm.selectedSheetID)
        XCTAssertNil(vm.activeTag)
        XCTAssertFalse(vm.isChatDriven)
        XCTAssertNil(vm.selectedCell)
        XCTAssertNil(vm.editingCell)
        XCTAssertNil(vm.editor)
    }

    // MARK: - Filter: All excludes archived + trashed, sorted

    func testApplyFilterAllExcludesArchivedAndTrashed() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "active", updatedAt: Date(timeIntervalSince1970: 1_000)),
            makeSheet(title: "archived", isArchived: true),
            makeSheet(title: "trashed", isTrashed: true),
        ])
        vm.filter = .all
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["active"])
    }

    func testApplyFilterAllSortsDescending() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "old", updatedAt: Date(timeIntervalSince1970: 1_000)),
            makeSheet(title: "new", updatedAt: Date(timeIntervalSince1970: 3_000)),
            makeSheet(title: "mid", updatedAt: Date(timeIntervalSince1970: 2_000)),
        ])
        vm.filter = .all
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["new", "mid", "old"])
    }

    func testApplyFilterFavoritesIncludesOnlyFavoriteNonArchivedNonTrashed() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "fav", isFavorite: true),
            makeSheet(title: "fav+archived", isFavorite: true, isArchived: true),
            makeSheet(title: "fav+trashed", isFavorite: true, isTrashed: true),
            makeSheet(title: "plain"),
        ])
        vm.filter = .favorites
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["fav"])
    }

    func testApplyFilterArchivedIncludesOnlyArchivedNonTrashed() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "archived", isArchived: true),
            makeSheet(title: "archived+trashed", isArchived: true, isTrashed: true),
            makeSheet(title: "active"),
        ])
        vm.filter = .archived
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }, ["archived"])
    }

    func testApplyFilterTrashIncludesOnlyTrashed() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "trashed", isTrashed: true),
            makeSheet(title: "trashed+archived", isArchived: true, isTrashed: true),
            makeSheet(title: "active"),
        ])
        vm.filter = .trash
        vm.applyFilter()
        XCTAssertEqual(vm.rows.map { $0.title }.sorted(), ["trashed", "trashed+archived"].sorted())
    }

    // MARK: - Active tag chip

    func testActiveTagFiltersRows() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "A", tags: ["q3", "review"]),
            makeSheet(title: "B", tags: ["q3"]),
            makeSheet(title: "C", tags: ["other"]),
        ])
        vm.setActiveTag("q3")
        XCTAssertEqual(vm.rows.map { $0.title }.sorted(), ["A", "B"])
    }

    func testSetActiveTagNilClearsFilter() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "A", tags: ["q3"]),
            makeSheet(title: "B", tags: ["other"]),
        ])
        vm.setActiveTag("q3")
        XCTAssertEqual(vm.rows.count, 1)
        vm.setActiveTag(nil)
        XCTAssertEqual(vm.rows.count, 2)
    }

    // MARK: - allTags

    func testAllTagsCollectsDistinctSorted() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "A", tags: ["q3", "review"]),
            makeSheet(title: "B", tags: ["urgent", "q3"]),
            makeSheet(title: "C", tags: []),
        ])
        XCTAssertEqual(vm.allTags, ["q3", "review", "urgent"])
    }

    // MARK: - Local search

    func testLocalSearchByTitle() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "Budget 2026"),
            makeSheet(title: "Roadmap"),
        ])
        vm.applyLocalSearch("budget")
        XCTAssertEqual(vm.rows.map { $0.title }, ["Budget 2026"])
    }

    func testLocalSearchByTag() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([
            makeSheet(title: "A", tags: ["urgent"]),
            makeSheet(title: "B", tags: ["other"]),
        ])
        vm.applyLocalSearch("urgent")
        XCTAssertEqual(vm.rows.map { $0.title }, ["A"])
    }

    func testLocalSearchEmptyStringClears() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([makeSheet(title: "A"), makeSheet(title: "B")])
        vm.applyLocalSearch("zzz")
        XCTAssertEqual(vm.rows.count, 0)
        vm.applyLocalSearch("")
        XCTAssertEqual(vm.rows.count, 2)
    }

    func testLocalSearchCaseInsensitive() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([makeSheet(title: "Budget 2026")])
        vm.applyLocalSearch("BUDGET")
        XCTAssertEqual(vm.rows.map { $0.title }, ["Budget 2026"])
    }

    // MARK: - SheetListFilter metadata

    func testSheetListFilterDisplayNames() {
        XCTAssertEqual(SheetListFilter.all.displayName, "All")
        XCTAssertEqual(SheetListFilter.favorites.displayName, "Favorites")
        XCTAssertEqual(SheetListFilter.archived.displayName, "Archived")
        XCTAssertEqual(SheetListFilter.trash.displayName, "Trash")
    }

    func testSheetListFilterSystemImages() {
        XCTAssertFalse(SheetListFilter.all.systemImage.isEmpty)
        XCTAssertEqual(SheetListFilter.favorites.systemImage, "star.fill")
        XCTAssertEqual(SheetListFilter.archived.systemImage, "archivebox")
        XCTAssertEqual(SheetListFilter.trash.systemImage, "trash")
    }

    // MARK: - Selection resets grid state

    func testSelectResetsGridEditingState() {
        let vm = makeViewModel()
        let sheet = makeSheet(title: "T")
        vm.setAllSheetsForTesting([sheet])
        vm.selectCell(SheetCellCoord(row: 1, col: 2))
        vm.beginEditingCell(SheetCellCoord(row: 1, col: 2))
        vm.select(sheet.id)
        XCTAssertNil(vm.selectedCell)
        XCTAssertNil(vm.editingCell)
        XCTAssertNotNil(vm.editor)
    }

    func testSelectNilClearsEditor() {
        let vm = makeViewModel()
        vm.setAllSheetsForTesting([makeSheet(title: "T")])
        let sheet = vm.allSheets[0]
        vm.select(sheet.id)
        XCTAssertNotNil(vm.editor)
        vm.select(nil)
        XCTAssertNil(vm.editor)
    }
}
