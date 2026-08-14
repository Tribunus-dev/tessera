import XCTest
@testable import TesseraCore

/// `DocumentExporter`'s HTML table rendering (P0 0.6). Previously every
/// cell in a table's flat `children` list was dumped into a single
/// hardcoded `<tr>` regardless of row boundaries - these tests pin the
/// fix (real per-row `<tr>`s), plus the two additions layered on top:
/// `rowspan`/`colspan` attributes and nested block content in a cell.
final class DocumentExporterTests: XCTestCase {

    private let exporter = DocumentExporter()

    private func makeDenseTable(rows: Int, cols: Int, text: (Int, Int) -> String) -> (ast: DocumentAST, tableID: UUID) {
        var ast = DocumentAST()
        var cellIDs: [UUID] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let cell = Block(type: .tableCell, content: [InlineRun(text: text(r, c))])
                ast.blocks[cell.id] = cell
                cellIDs.append(cell.id)
            }
        }
        var table = Block(type: .table, children: cellIDs)
        table.attributes["rows"] = .number(Double(rows))
        table.attributes["cols"] = .number(Double(cols))
        ast.blocks[table.id] = table
        ast.rootChildren = [table.id]
        return (ast, table.id)
    }

    private func html(for ast: DocumentAST) throws -> String {
        try exporter.htmlPreview(Doc(title: "T", body: ast))
    }

    // MARK: - Row boundaries

    /// The bug this whole file exists to pin: a 2x2 table used to
    /// render as one `<tr>` with 4 `<td>`s, losing every row break.
    func testMultiRowTableProducesOneTrPerRow() throws {
        let (ast, _) = makeDenseTable(rows: 2, cols: 2) { r, c in "R\(r)C\(c)" }
        let out = try html(for: ast)
        XCTAssertEqual(out.components(separatedBy: "<tr>").count - 1, 2, "expected exactly 2 <tr> opens")
        XCTAssertTrue(out.contains("<tr><td>R0C0</td><td>R0C1</td></tr>"))
        XCTAssertTrue(out.contains("<tr><td>R1C0</td><td>R1C1</td></tr>"))
    }

    func testSingleRowTableStillProducesOneTr() throws {
        let (ast, _) = makeDenseTable(rows: 1, cols: 3) { _, c in "C\(c)" }
        let out = try html(for: ast)
        XCTAssertEqual(out.components(separatedBy: "<tr>").count - 1, 1)
        XCTAssertTrue(out.contains("<tr><td>C0</td><td>C1</td><td>C2</td></tr>"))
    }

    // MARK: - Spans

    func testMergedCellEmitsRowspanAndColspanAttributes() throws {
        let (ast, tableID) = makeDenseTable(rows: 2, cols: 2) { r, c in "R\(r)C\(c)" }
        let merged = try ast.mergingTableCells(tableID: tableID, topLeftRow: 0, topLeftCol: 0, rowSpan: 2, colSpan: 2).get()
        let out = try html(for: merged)
        XCTAssertTrue(out.contains("<td rowspan=\"2\" colspan=\"2\">R0C0</td>"))
        XCTAssertFalse(out.contains("R0C1"), "the absorbed cell's content must be gone")
        // Only the merged cell's own row has content; the row it also
        // covers (row 1) contributes no <td> of its own.
        XCTAssertEqual(out.components(separatedBy: "<td").count - 1, 1)
    }

    func testUnspannedCellOmitsSpanAttributesEntirely() throws {
        let (ast, _) = makeDenseTable(rows: 1, cols: 1) { _, _ in "solo" }
        let out = try html(for: ast)
        XCTAssertTrue(out.contains("<td>solo</td>"))
        XCTAssertFalse(out.contains("rowspan"))
        XCTAssertFalse(out.contains("colspan"))
    }

    // MARK: - Nested children

    func testCellWithNestedParagraphChildrenRendersThemInsteadOfFlatContent() throws {
        var ast = DocumentAST()
        let para1 = Block(type: .paragraph, content: [InlineRun(text: "First")])
        let para2 = Block(type: .paragraph, content: [InlineRun(text: "Second")])
        ast.blocks[para1.id] = para1
        ast.blocks[para2.id] = para2

        var cell = Block(type: .tableCell, content: [InlineRun(text: "ignored flat text")])
        cell.children = [para1.id, para2.id]
        ast.blocks[cell.id] = cell

        var table = Block(type: .table, children: [cell.id])
        table.attributes["rows"] = .number(1)
        table.attributes["cols"] = .number(1)
        ast.blocks[table.id] = table
        ast.rootChildren = [table.id]

        let out = try html(for: ast)
        XCTAssertTrue(out.contains("<p>First</p>"))
        XCTAssertTrue(out.contains("<p>Second</p>"))
        XCTAssertFalse(out.contains("ignored flat text"), "children present must take priority over flat content")
    }

    func testCellWithoutChildrenStillRendersFlatContentUnchanged() throws {
        let (ast, _) = makeDenseTable(rows: 1, cols: 1) { _, _ in "plain text" }
        let out = try html(for: ast)
        XCTAssertTrue(out.contains("<td>plain text</td>"))
    }
}
