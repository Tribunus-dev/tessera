import XCTest
@testable import TesseraCore

// MARK: - TableLayoutTests
//
// Contract: TableLayout.swift's own doc comments - "A table's children is
// a flat cell list with no per-cell row/col attribute... position is
// implicit in document order. Without spans that is just
// index = row * cols + col; a spanning cell occupies more than one grid
// slot, so a later cell in the same row must skip past it." Plus
// `DocumentAST.mergingTableCells`'s documented error cases and "never
// leaves a table half-merged" guarantee. Doctrine rule 9 (math gets
// fixtures AND a property).

final class TableLayoutTests: DoctrineTestCase {

    private func tableCell(id: UUID = UUID(), rowSpan: Int? = nil, colSpan: Int? = nil) -> Block {
        var cell = Block(id: id, type: .tableCell)
        cell.rowSpan = rowSpan
        cell.colSpan = colSpan
        return cell
    }

    // MARK: - Fixture: unspanned grid, index = row * cols + col

    func testPlacementsWithNoSpansPlaceCellsInRowMajorOrder() {
        let cellIDs = (0..<6).map { _ in UUID() }
        let tableID = UUID()
        var ast = DocumentAST()
        let table = Block(id: tableID, type: .table, attributes: ["cols": .number(3)], children: cellIDs)
        for id in cellIDs { ast.blocks[id] = tableCell(id: id) }
        ast.blocks[tableID] = table

        let placements = TableLayout.placements(for: table, in: ast)
        let expected: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)]
        XCTAssertEqual(placements.map { ($0.row, $0.col) }.map { "\($0.0),\($0.1)" }, expected.map { "\($0.0),\($0.1)" })
    }

    // MARK: - Fixture: a spanning cell displaces later cells in the same row

    func testPlacementsWithAColSpanningCellSkipsOccupiedSlots() {
        let wideID = UUID()
        let nextID = UUID()
        let tableID = UUID()
        var ast = DocumentAST()
        ast.blocks[wideID] = tableCell(id: wideID, colSpan: 2) // occupies (0,0) and (0,1)
        ast.blocks[nextID] = tableCell(id: nextID)
        let table = Block(id: tableID, type: .table, attributes: ["cols": .number(3)], children: [wideID, nextID])
        ast.blocks[tableID] = table

        let placements = TableLayout.placements(for: table, in: ast)
        XCTAssertEqual(placements.first { $0.cellID == wideID }.map { ($0.row, $0.col) }.map { "\($0.0),\($0.1)" }, "0,0")
        XCTAssertEqual(placements.first { $0.cellID == nextID }.map { ($0.row, $0.col) }.map { "\($0.0),\($0.1)" }, "0,2",
                        "the cell after a colSpan=2 cell must skip the slots the span already occupies")
    }

    func testPlacementsWithARowSpanningCellReservesTheSlotInTheNextRow() {
        let tallID = UUID()
        let belowID = UUID()
        let tableID = UUID()
        var ast = DocumentAST()
        ast.blocks[tallID] = tableCell(id: tallID, rowSpan: 2) // occupies (0,0) and (1,0)
        ast.blocks[belowID] = tableCell(id: belowID) // next cell in document order
        let table = Block(id: tableID, type: .table, attributes: ["cols": .number(2)], children: [tallID, belowID])
        ast.blocks[tableID] = table

        let placements = TableLayout.placements(for: table, in: ast)
        XCTAssertEqual(placements.first { $0.cellID == tallID }.map { ($0.row, $0.col) }.map { "\($0.0),\($0.1)" }, "0,0")
        // (0,1) is the next free slot in row 0 (row 1 col 0 is reserved by the span).
        XCTAssertEqual(placements.first { $0.cellID == belowID }.map { ($0.row, $0.col) }.map { "\($0.0),\($0.1)" }, "0,1")
    }

    // MARK: - Malformed cols falls back to 1, not an empty layout

    func testPlacementsWithMissingColsFallsBackToOnePerRow() {
        let cellIDs = [UUID(), UUID()]
        let tableID = UUID()
        var ast = DocumentAST()
        for id in cellIDs { ast.blocks[id] = tableCell(id: id) }
        let table = Block(id: tableID, type: .table, children: cellIDs) // no "cols" attribute at all
        ast.blocks[tableID] = table
        let placements = TableLayout.placements(for: table, in: ast)
        XCTAssertEqual(placements.map { ($0.row, $0.col) }.map { "\($0.0),\($0.1)" }, ["0,0", "1,0"])
    }

    // MARK: - rows(for:in:): grouped by row, sorted by column

    func testRowsGroupsPlacementsByRowSortedByColumn() {
        let cellIDs = (0..<4).map { _ in UUID() }
        let tableID = UUID()
        var ast = DocumentAST()
        for id in cellIDs { ast.blocks[id] = tableCell(id: id) }
        let table = Block(id: tableID, type: .table, attributes: ["cols": .number(2)], children: cellIDs)
        ast.blocks[tableID] = table
        let rows = TableLayout.rows(for: table, in: ast)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.cellID), [cellIDs[0], cellIDs[1]])
        XCTAssertEqual(rows[1].map(\.cellID), [cellIDs[2], cellIDs[3]])
    }

    // MARK: - Property: every occupied slot in the grid is covered by exactly one placement's span

    func testEveryPlacementsSpanCoversDisjointSlots() {
        let cellIDs = (0..<5).map { _ in UUID() }
        let tableID = UUID()
        var ast = DocumentAST()
        ast.blocks[cellIDs[0]] = tableCell(id: cellIDs[0], colSpan: 2)
        for id in cellIDs.dropFirst() { ast.blocks[id] = tableCell(id: id) }
        let table = Block(id: tableID, type: .table, attributes: ["cols": .number(3)], children: cellIDs)
        ast.blocks[tableID] = table

        let placements = TableLayout.placements(for: table, in: ast)
        var seenSlots: Set<Int> = []
        let cols = 3
        for placement in placements {
            for r in placement.row..<(placement.row + placement.rowSpan) {
                for c in placement.col..<(placement.col + placement.colSpan) {
                    let slot = r * cols + c
                    XCTAssertFalse(seenSlots.contains(slot), "no two placements may claim the same grid slot")
                    seenSlots.insert(slot)
                }
            }
        }
    }

    // MARK: - mergingTableCells: fixtures for every documented error + the success path

    private func gridTable(rows: Int, cols: Int) -> (ast: DocumentAST, tableID: UUID, cellIDs: [[UUID]]) {
        let tableID = UUID()
        var ast = DocumentAST()
        var grid: [[UUID]] = []
        var children: [UUID] = []
        for _ in 0..<rows {
            var rowIDs: [UUID] = []
            for _ in 0..<cols {
                let id = UUID()
                ast.blocks[id] = tableCell(id: id)
                rowIDs.append(id)
                children.append(id)
            }
            grid.append(rowIDs)
        }
        ast.blocks[tableID] = Block(id: tableID, type: .table, attributes: ["rows": .number(Double(rows)), "cols": .number(Double(cols))], children: children)
        ast.rootChildren = [tableID]
        return (ast, tableID, grid)
    }

    func testMergingTableCellsSetsSurvivorSpanAndRemovesOtherCells() {
        let (ast, tableID, grid) = gridTable(rows: 2, cols: 2)
        let result = ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 2, colSpan: 2)
        guard case .success(let merged) = result else { return XCTFail("expected success") }
        let survivorID = grid[0][0]
        XCTAssertEqual(merged.blocks[survivorID]?.rowSpan, 2)
        XCTAssertEqual(merged.blocks[survivorID]?.colSpan, 2)
        XCTAssertNil(merged.blocks[grid[0][1]])
        XCTAssertNil(merged.blocks[grid[1][0]])
        XCTAssertNil(merged.blocks[grid[1][1]])
        XCTAssertEqual(merged.blocks[tableID]?.children, [survivorID], "every removed cell must also be removed from the table's own children list")
    }

    /// `Result` has no conditional `Equatable` conformance in the standard
    /// library (unlike `Optional`), so failure cases are asserted via
    /// pattern match rather than `XCTAssertEqual(result, .failure(...))`.
    private func assertFailure(
        _ result: Result<DocumentAST, DocumentAST.TableMergeError>,
        is expected: DocumentAST.TableMergeError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("expected .failure(\(expected)), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    func testMergingTableCellsFailsWithTableNotFoundForAnUnknownID() {
        let (ast, _, _) = gridTable(rows: 1, cols: 1)
        let result = ast.mergingTableCells(tableID: UUID(), topLeftRow: 0, topLeftCol: 0, rowSpan: 1, colSpan: 1)
        assertFailure(result, is: .tableNotFound)
    }

    func testMergingTableCellsFailsWithNotATableWhenIDIsNotATableBlock() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph)
        let result = ast.mergingTableCells(tableID: id, topLeftRow: 0, topLeftCol: 0, rowSpan: 1, colSpan: 1)
        assertFailure(result, is: .notATable)
    }

    func testMergingTableCellsFailsWithRegionOutOfBoundsWhenRectangleExceedsTheTable() {
        let (ast, tableID, _) = gridTable(rows: 2, cols: 2)
        let result = ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 3, colSpan: 2)
        assertFailure(result, is: .regionOutOfBounds)
    }

    func testMergingTableCellsFailsWithRegionOverlapsExistingSpanWhenAnExistingMergeStraddlesTheEdge() {
        let (ast, tableID, grid) = gridTable(rows: 2, cols: 3)
        // First merge (0,0)-(0,1) into a colSpan=2 survivor.
        guard case .success(let firstMerge) = ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 1, colSpan: 2) else {
            return XCTFail("setup merge must succeed")
        }
        // Now attempt a merge whose rectangle straddles the existing span's edge (col 1 only, not the whole span).
        let result = firstMerge.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 1, rowSpan: 1, colSpan: 2)
        assertFailure(result, is: .regionOverlapsExistingSpan)
        _ = grid
    }

    func testMergingTableCellsNeverMutatesOnFailure() throws {
        let (ast, tableID, _) = gridTable(rows: 2, cols: 2)
        let originalHash = try ast.contentHash()
        _ = ast.mergingTableCells(tableID: tableID, topLeftRow: 5, topLeftCol: 5, rowSpan: 1, colSpan: 1)
        XCTAssertEqual(try ast.contentHash(), originalHash, "a failed merge must never mutate the caller's document")
    }
}
