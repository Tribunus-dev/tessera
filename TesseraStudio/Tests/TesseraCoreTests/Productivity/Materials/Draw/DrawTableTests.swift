import XCTest
import Foundation
@testable import TesseraCore

// MARK: - DrawTableTests
//
// Contract: DrawTable.swift's own header comment (item 2.12, no prior
// design doc - the contract stub derived and recorded in this wave's
// findings file). Doctrine rule 2 (round-trip identity), rule 9
// (math gets fixtures - index(row:column:)/totalWidth/totalHeight).

final class DrawTableTests: DoctrineTestCase {

    // MARK: - Construction

    func testDefaultInitClampsRowAndColumnCountToAtLeastOne() {
        let table = DrawTable(rowCount: 0, columnCount: -2)
        XCTAssertEqual(table.rowCount, 1)
        XCTAssertEqual(table.columnCount, 1)
        XCTAssertEqual(table.cells.count, 1)
        XCTAssertEqual(table.columnWidths.count, 1)
        XCTAssertEqual(table.rowHeights.count, 1)
    }

    func testDefaultInitProducesRowCountTimesColumnCountEmptyCells() {
        let table = DrawTable(rowCount: 2, columnCount: 3)
        XCTAssertEqual(table.cells.count, 6)
        XCTAssertTrue(table.cells.allSatisfy { $0.text.plainText.isEmpty && $0.fill == nil })
    }

    // MARK: - index(row:column:) / cell(row:column:)

    func testIndexIsRowMajor() {
        let table = DrawTable(rowCount: 2, columnCount: 3)
        XCTAssertEqual(table.index(row: 0, column: 0), 0)
        XCTAssertEqual(table.index(row: 0, column: 2), 2)
        XCTAssertEqual(table.index(row: 1, column: 0), 3)
        XCTAssertEqual(table.index(row: 1, column: 2), 5)
    }

    func testIndexOutOfRangeReturnsNil() {
        let table = DrawTable(rowCount: 2, columnCount: 2)
        XCTAssertNil(table.index(row: -1, column: 0))
        XCTAssertNil(table.index(row: 0, column: 2))
        XCTAssertNil(table.index(row: 2, column: 0))
    }

    func testCellAtOutOfRangePositionReturnsNilRatherThanCrashing() {
        let table = DrawTable(rowCount: 1, columnCount: 1)
        XCTAssertNil(table.cell(row: 5, column: 5))
    }

    func testCellAtValidPositionReturnsInsertedContent() {
        var table = DrawTable(rowCount: 2, columnCount: 2)
        let cell = DrawTableCell(text: ShapeText(runs: [InlineRun(text: "hi")]))
        table = table.settingCell(cell, row: 1, column: 0)
        XCTAssertEqual(table.cell(row: 1, column: 0)?.text.plainText, "hi")
    }

    // MARK: - settingCell (pure, no-op contract)

    func testSettingCellAtOutOfRangePositionIsANoOp() {
        let table = DrawTable(rowCount: 1, columnCount: 1)
        let updated = table.settingCell(DrawTableCell(text: ShapeText(runs: [InlineRun(text: "x")])), row: 9, column: 9)
        XCTAssertEqual(updated, table)
    }

    func testSettingCellReplacesOnlyTheNamedCell() {
        let table = DrawTable(rowCount: 1, columnCount: 2)
        let updated = table.settingCell(DrawTableCell(text: ShapeText(runs: [InlineRun(text: "x")])), row: 0, column: 1)
        XCTAssertTrue(updated.cell(row: 0, column: 0)?.text.plainText.isEmpty ?? false)
        XCTAssertEqual(updated.cell(row: 0, column: 1)?.text.plainText, "x")
    }

    // MARK: - totalWidth / totalHeight

    func testTotalWidthAndHeightSumTheirRespectiveExtents() {
        let table = DrawTable(
            rowCount: 2, columnCount: 3,
            cells: Array(repeating: DrawTableCell(), count: 6),
            columnWidths: [10, 20, 30],
            rowHeights: [5, 15],
            gridStroke: nil
        )
        XCTAssertEqual(table.totalWidth, 60)
        XCTAssertEqual(table.totalHeight, 20)
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testDrawTableEncodeDecodeIsIdentity() throws {
        var table = DrawTable(rowCount: 2, columnCount: 2, defaultColumnWidth: 50, defaultRowHeight: 20)
        table = table.settingCell(DrawTableCell(text: ShapeText(runs: [InlineRun(text: "A1")]), fill: ShapeFill(colorHex: "#EEEEEE")), row: 0, column: 0)
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(DrawTable.self, from: data)
        XCTAssertEqual(decoded, table)
    }

    func testDrawTableCellEncodeDecodeIsIdentity() throws {
        let cell = DrawTableCell(text: ShapeText(runs: [InlineRun(text: "hello", annotations: [.bold])]), fill: ShapeFill(colorHex: "#FFFFFF", opacity: 0.5))
        let data = try JSONEncoder().encode(cell)
        let decoded = try JSONDecoder().decode(DrawTableCell.self, from: data)
        XCTAssertEqual(decoded, cell)
    }

    // MARK: - Shape.table round trip (ShapeKind.table + Shape.table payload)

    func testTableShapeEncodeDecodeIsIdentity() throws {
        let table = DrawTable(rowCount: 1, columnCount: 2)
        let shape = Shape(
            kind: .table,
            geometry: ShapeGeometry(x: 0, y: 0, width: table.totalWidth, height: table.totalHeight),
            table: table
        )
        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, shape)
        XCTAssertEqual(decoded.table?.rowCount, 1)
        XCTAssertEqual(decoded.table?.columnCount, 2)
    }

    func testShapeWithNoTableDefaultsToNil() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(shape.table)
    }
}
