import XCTest
@testable import TesseraCore

/// `DependencyGraph`'s `RecalcState` tracking (P0 0.2a): formalizes the
/// dirty/clean state recalculation already computed implicitly (a cell
/// was "dirty" exactly when a `dirtySubgraph` BFS reached it) as an
/// explicit, queryable per-cell field. These tests exercise
/// `DependencyGraph` directly, independent of `SheetEngine`, since
/// `markCellsDirty`/`markCellClean`/`recalcState(for:)` are plain graph
/// operations with no locking or evaluation semantics of their own -
/// `SheetEngineTests.swift` covers the end-to-end integration through
/// the public `SheetEngine.recalcState(sheet:addr:)`.
final class DependencyGraphTests: XCTestCase {

    private var graph: DependencyGraph!

    override func setUp() {
        super.setUp()
        graph = DependencyGraph()
    }

    private func addr(_ col: Int, _ row: Int, sheet: String = "Sheet1") -> SheetCellAddr {
        SheetCellAddr(sheet: sheet, addr: CellAddr(col: col, row: row))
    }

    // MARK: - Defaults

    func testUntrackedCellIsClean() {
        XCTAssertEqual(graph.recalcState(for: addr(0, 0)), .clean)
    }

    func testCellWithNoFormulaStaysCleanEvenIfMarkedDirty() {
        // markCellsDirty only tracks formula cells - a plain address
        // with no formulaAST entry has nothing to recalculate.
        let key = addr(0, 0)
        graph.markCellsDirty([key])
        XCTAssertEqual(graph.recalcState(for: key), .clean)
    }

    // MARK: - Dirty / clean transitions

    func testFormulaCellCanBeMarkedDirtyThenClean() throws {
        let key = addr(1, 0)
        try graph.setFormula(key, ast: .number(1))

        graph.markCellsDirty([key])
        XCTAssertEqual(graph.recalcState(for: key), .dirty)

        graph.markCellClean(key)
        XCTAssertEqual(graph.recalcState(for: key), .clean)
    }

    func testMarkCellsDirtyOnlyAffectsCellsWithFormulas() throws {
        let formulaCell = addr(1, 0)
        let plainCell = addr(2, 0)
        try graph.setFormula(formulaCell, ast: .number(1))

        graph.markCellsDirty([formulaCell, plainCell])
        XCTAssertEqual(graph.recalcState(for: formulaCell), .dirty)
        XCTAssertEqual(graph.recalcState(for: plainCell), .clean)
    }

    // MARK: - Cleanup on removal

    func testClearFormulaResetsRecalcState() throws {
        let key = addr(1, 0)
        try graph.setFormula(key, ast: .number(1))
        graph.markCellsDirty([key])
        XCTAssertEqual(graph.recalcState(for: key), .dirty)

        graph.clearFormula(key)
        XCTAssertEqual(graph.recalcState(for: key), .clean, "a cleared cell has no formula, so nothing to track")
    }

    func testRemoveCellResetsRecalcState() throws {
        let key = addr(1, 0)
        try graph.setFormula(key, ast: .number(1))
        graph.markCellsDirty([key])

        graph.removeCell(key)
        XCTAssertEqual(graph.recalcState(for: key), .clean)
    }

    func testRemoveSheetResetsRecalcStateForItsCells() throws {
        let key = addr(1, 0, sheet: "Doomed")
        try graph.setFormula(key, ast: .number(1))
        graph.markCellsDirty([key])
        XCTAssertEqual(graph.recalcState(for: key), .dirty)

        graph.removeSheet("Doomed")
        XCTAssertEqual(graph.recalcState(for: key), .clean)
    }

    // MARK: - Rename

    func testRenameSheetCarriesDirtyStateToTheNewName() throws {
        let oldKey = addr(1, 0, sheet: "Old")
        try graph.setFormula(oldKey, ast: .number(1))
        graph.markCellsDirty([oldKey])
        XCTAssertEqual(graph.recalcState(for: oldKey), .dirty)

        graph.renameSheet(from: "Old", to: "New")

        let newKey = addr(1, 0, sheet: "New")
        XCTAssertEqual(graph.recalcState(for: newKey), .dirty, "the cell's dirty state must follow the rename")
        XCTAssertEqual(graph.recalcState(for: oldKey), .clean, "the old name is gone - nothing tracked under it")
    }

    // MARK: - Clear

    func testClearResetsEveryRecalcState() throws {
        let key = addr(1, 0)
        try graph.setFormula(key, ast: .number(1))
        graph.markCellsDirty([key])
        XCTAssertEqual(graph.recalcState(for: key), .dirty)

        graph.clear()
        XCTAssertEqual(graph.recalcState(for: key), .clean)
    }
}
