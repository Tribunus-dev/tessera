import XCTest
@testable import TesseraCore

/// `TableLayout` (P0 0.6): resolves a `.table` block's flat, row-major
/// `children` list into actual grid positions, and `DocumentAST
/// .mergingTableCells` uses it to merge a rectangle of cells into one
/// spanning cell.
final class TableLayoutTests: XCTestCase {

    /// A `rows` x `cols` table with one `.tableCell` per grid slot, in
    /// row-major document order - the shape every table starts in
    /// today (`TesseraEditorView.insertTable`/`Sheet.makeBlank`).
    private func makeDenseTable(rows: Int, cols: Int) -> (ast: DocumentAST, tableID: UUID, cellIDs: [UUID]) {
        var ast = DocumentAST()
        var cellIDs: [UUID] = []
        for _ in 0..<(rows * cols) {
            let cell = Block(type: .tableCell)
            ast.blocks[cell.id] = cell
            cellIDs.append(cell.id)
        }
        var table = Block(type: .table, children: cellIDs)
        table.attributes["rows"] = .number(Double(rows))
        table.attributes["cols"] = .number(Double(cols))
        ast.blocks[table.id] = table
        ast.rootChildren = [table.id]
        return (ast, table.id, cellIDs)
    }

    // MARK: - Placements without spans

    func testDenseTablePlacementsAreRowMajor() {
        let (ast, tableID, cellIDs) = makeDenseTable(rows: 2, cols: 3)
        let placements = TableLayout.placements(for: ast.blocks[tableID]!, in: ast)
        XCTAssertEqual(placements.map(\.cellID), cellIDs)
        XCTAssertEqual(placements.map { [$0.row, $0.col] }, [
            [0, 0], [0, 1], [0, 2],
            [1, 0], [1, 1], [1, 2],
        ])
        XCTAssertTrue(placements.allSatisfy { $0.rowSpan == 1 && $0.colSpan == 1 })
    }

    func testRowsGroupsPlacementsInRowOrder() {
        let (ast, tableID, _) = makeDenseTable(rows: 2, cols: 2)
        let rows = TableLayout.rows(for: ast.blocks[tableID]!, in: ast)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.col), [0, 1])
        XCTAssertEqual(rows[1].map(\.col), [0, 1])
    }

    /// A missing/zero `cols` attribute must not crash or produce an
    /// empty layout - malformed data falls back to one cell per row.
    func testMissingColsAttributeFallsBackToOneColumn() {
        var ast = DocumentAST()
        let cell = Block(type: .tableCell)
        ast.blocks[cell.id] = cell
        let table = Block(type: .table, children: [cell.id])
        ast.blocks[table.id] = table
        let placements = TableLayout.placements(for: table, in: ast)
        XCTAssertEqual(placements, [TableCellPlacement(cellID: cell.id, row: 0, col: 0, rowSpan: 1, colSpan: 1)])
    }

    // MARK: - Placements with a pre-existing span

    /// A 2x2-spanning cell at (0,0) must push the row's next real cell
    /// to (0,2), not (0,1) - the same "occupied slot" skip HTML table
    /// layout performs.
    func testSpanningCellPushesLaterCellsInTheSameRow() {
        var ast = DocumentAST()
        var spanning = Block(type: .tableCell)
        spanning.rowSpan = 2
        spanning.colSpan = 2
        var plain1 = Block(type: .tableCell)
        var plain2 = Block(type: .tableCell)
        var plain3 = Block(type: .tableCell)
        for b in [spanning, plain1, plain2, plain3] { ast.blocks[b.id] = b }
        // Document order: the spanning cell, then the 2 real cells left
        // in row 0 (col 2), then 1 real cell left in row 1 (col 2).
        var table = Block(type: .table, children: [spanning.id, plain1.id, plain2.id, plain3.id])
        table.attributes["rows"] = .number(3)
        table.attributes["cols"] = .number(3)
        ast.blocks[table.id] = table

        let placements = TableLayout.placements(for: table, in: ast)
        XCTAssertEqual(placements[0], TableCellPlacement(cellID: spanning.id, row: 0, col: 0, rowSpan: 2, colSpan: 2))
        XCTAssertEqual(placements[1], TableCellPlacement(cellID: plain1.id, row: 0, col: 2, rowSpan: 1, colSpan: 1))
        XCTAssertEqual(placements[2], TableCellPlacement(cellID: plain2.id, row: 1, col: 2, rowSpan: 1, colSpan: 1))
        XCTAssertEqual(placements[3], TableCellPlacement(cellID: plain3.id, row: 2, col: 0, rowSpan: 1, colSpan: 1))
        _ = plain1; _ = plain2; _ = plain3
    }

    // MARK: - Block.rowSpan / colSpan

    func testRowSpanColSpanDefaultToNilAndClampToOne() {
        let cell = Block(type: .tableCell)
        XCTAssertNil(cell.rowSpan)
        XCTAssertNil(cell.colSpan)
        XCTAssertEqual(cell.effectiveRowSpan, 1)
        XCTAssertEqual(cell.effectiveColSpan, 1)
    }

    func testSettingSpanToOneClearsTheAttributeRatherThanStoringIt() {
        var cell = Block(type: .tableCell)
        cell.rowSpan = 3
        XCTAssertEqual(cell.rowSpan, 3)
        cell.rowSpan = 1
        XCTAssertNil(cell.rowSpan, "1 is the implicit default; storing it would just be noise")
    }

    func testSpanSettersAreNoOpsOnNonTableCellBlocks() {
        var paragraph = Block(type: .paragraph)
        paragraph.rowSpan = 2
        XCTAssertNil(paragraph.rowSpan)
    }

    // MARK: - Merging cells

    func testMergingARectangleSetsSpanOnTheTopLeftCellAndRemovesTheRest() throws {
        let (ast, tableID, cellIDs) = makeDenseTable(rows: 2, cols: 2)
        let result = ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 2, colSpan: 2)
        let merged = try result.get()

        let table = try XCTUnwrap(merged.blocks[tableID])
        XCTAssertEqual(table.children, [cellIDs[0]], "the other 3 cells must be gone from the table's children")
        XCTAssertEqual(merged.blocks[cellIDs[0]]?.rowSpan, 2)
        XCTAssertEqual(merged.blocks[cellIDs[0]]?.colSpan, 2)
        for removedID in cellIDs[1...] {
            XCTAssertNil(merged.blocks[removedID], "absorbed cells must be deleted from blocks entirely")
        }
    }

    func testMergingASingleColumnStripOnlySpansRows() throws {
        let (ast, tableID, cellIDs) = makeDenseTable(rows: 3, cols: 2)
        // Merge the left column's 3 rows into one cell.
        let merged = try ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 3, colSpan: 1).get()
        XCTAssertEqual(merged.blocks[cellIDs[0]]?.rowSpan, 3)
        XCTAssertNil(merged.blocks[cellIDs[0]]?.colSpan)
        // Right column (col 1) is untouched.
        XCTAssertEqual(merged.blocks[tableID]?.children.count, 4, "3 right-column cells + 1 merged left cell")
    }

    func testMergeOutOfBoundsFails() {
        let (ast, tableID, _) = makeDenseTable(rows: 2, cols: 2)
        let result = ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 3, colSpan: 1)
        XCTAssertEqual(result, .failure(.regionOutOfBounds))
    }

    func testMergeOnUnknownTableIDFails() {
        let (ast, _, _) = makeDenseTable(rows: 2, cols: 2)
        let result = ast.mergingTableCells(tableID: UUID(), topLeftRow: 0, topLeftCol: 0, rowSpan: 1, colSpan: 1)
        XCTAssertEqual(result, .failure(.tableNotFound))
    }

    func testMergeOnANonTableBlockFails() {
        var ast = DocumentAST()
        let paragraph = Block(type: .paragraph)
        ast.blocks[paragraph.id] = paragraph
        let result = ast.mergingTableCells(tableID: paragraph.id, topLeftRow: 0, topLeftCol: 0, rowSpan: 1, colSpan: 1)
        XCTAssertEqual(result, .failure(.notATable))
    }

    /// A rectangle that only partially covers an existing 2x2 merge
    /// must be refused - absorbing it would silently truncate that
    /// cell's span rather than growing it cleanly.
    func testMergeOverlappingAnExistingSpanAtTheEdgeFails() throws {
        let (ast, tableID, _) = makeDenseTable(rows: 3, cols: 3)
        let onceMerged = try ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 2, colSpan: 2).get()

        // This rectangle (rows 1-2, cols 1-2) only partially overlaps
        // the existing (0,0)-(1,1) merge - it does not fully contain it.
        let result = onceMerged.mergingTableCells(tableID: tableID, topLeftRow: 1, topLeftCol: 1, rowSpan: 2, colSpan: 2)
        XCTAssertEqual(result, .failure(.regionOverlapsExistingSpan))
    }

    /// A rectangle that fully re-covers an existing merge (and then
    /// some) is a legitimate re-merge, not an error.
    func testMergeThatFullyContainsAnExistingSpanSucceeds() throws {
        let (ast, tableID, cellIDs) = makeDenseTable(rows: 3, cols: 3)
        let onceMerged = try ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 2, colSpan: 2).get()

        let result = onceMerged.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 3, colSpan: 3)
        let merged = try result.get()
        XCTAssertEqual(merged.blocks[cellIDs[0]]?.rowSpan, 3)
        XCTAssertEqual(merged.blocks[cellIDs[0]]?.colSpan, 3)
        XCTAssertEqual(merged.blocks[tableID]?.children, [cellIDs[0]])
    }
}
