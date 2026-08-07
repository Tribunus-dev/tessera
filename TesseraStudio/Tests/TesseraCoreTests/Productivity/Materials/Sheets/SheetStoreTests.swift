import XCTest
@testable import TesseraCore

/// Unit tests for ``SheetStore`` parts that do not need a live
/// Postgres connection. The end-to-end upsert -> receipt -> fetch
/// flow is exercised by the integration test (env-gated on
/// `TESSERA_DB_INTEGRATION=1`).
final class SheetStoreTests: XCTestCase {

    // MARK: - Receipt types

    func testReceiptTypesAreStable() {
        XCTAssertEqual(SheetReceiptType.upsert.rawValue, "sheet_upsert")
        XCTAssertEqual(SheetReceiptType.updateBody.rawValue, "sheet_body_changed")
        XCTAssertEqual(SheetReceiptType.setCell.rawValue, "sheet_cell_changed")
        XCTAssertEqual(SheetReceiptType.insertRow.rawValue, "sheet_row_inserted")
        XCTAssertEqual(SheetReceiptType.deleteRow.rawValue, "sheet_row_deleted")
        XCTAssertEqual(SheetReceiptType.insertColumn.rawValue, "sheet_column_inserted")
        XCTAssertEqual(SheetReceiptType.deleteColumn.rawValue, "sheet_column_deleted")
        XCTAssertEqual(SheetReceiptType.archive.rawValue, "sheet_archived")
        XCTAssertEqual(SheetReceiptType.unarchive.rawValue, "sheet_unarchived")
        XCTAssertEqual(SheetReceiptType.trash.rawValue, "sheet_trashed")
        XCTAssertEqual(SheetReceiptType.restore.rawValue, "sheet_restored")
        XCTAssertEqual(SheetReceiptType.delete.rawValue, "sheet_delete")
        XCTAssertEqual(SheetReceiptType.favorite.rawValue, "sheet_favorited")
        XCTAssertEqual(SheetReceiptType.unfavorite.rawValue, "sheet_unfavorited")
        XCTAssertEqual(SheetReceiptType.tagChange.rawValue, "sheet_tags_changed")
        XCTAssertEqual(SheetReceiptType.tagAdded.rawValue, "sheet_tag_added")
        XCTAssertEqual(SheetReceiptType.tagRemoved.rawValue, "sheet_tag_removed")
        XCTAssertEqual(SheetReceiptType.link.rawValue, "sheet_link_created")
        XCTAssertEqual(SheetReceiptType.unlink.rawValue, "sheet_link_deleted")
        XCTAssertEqual(SheetReceiptType.import.rawValue, "sheet_imported")
    }

    // MARK: - JSON helpers

    func testSheetJSONStringRoundTrip() throws {
        let sheet = Sheet(
            id: UUID(),
            title: "Budget 2026",
            body: .empty,
            tags: ["budget"],
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let body = try sheet.jsonDataString()
        XCTAssertTrue(body.contains("Budget 2026"))
        let parsed = try Sheet.from(jsonDataString: body)
        XCTAssertEqual(parsed, sheet)
    }

    func testInvalidJSONRejected() {
        let bad = "not json at all"
        XCTAssertThrowsError(try Sheet.from(jsonDataString: bad))
    }

    func testInvalidUTF8BodyRejected() {
        let empty = ""
        // Empty string is not valid Sheet JSON -> should throw.
        XCTAssertThrowsError(try Sheet.from(jsonDataString: empty))
    }

    // MARK: - Errors

    func testStoreErrorEquality() {
        let id = UUID()
        XCTAssertEqual(SheetStoreError.sheetNotFound(id: id), SheetStoreError.sheetNotFound(id: id))
        XCTAssertNotEqual(SheetStoreError.sheetNotFound(id: id), SheetStoreError.sheetNotFound(id: UUID()))
        XCTAssertEqual(SheetStoreError.invalidBody(reason: "x"), SheetStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(SheetStoreError.invalidBody(reason: "x"), SheetStoreError.invalidBody(reason: "y"))
        XCTAssertEqual(SheetStoreError.cannotDeleteLastRow, SheetStoreError.cannotDeleteLastRow)
        XCTAssertEqual(SheetStoreError.cannotDeleteLastColumn, SheetStoreError.cannotDeleteLastColumn)
        XCTAssertEqual(SheetStoreError.cellNotFound(row: 1, col: 2), SheetStoreError.cellNotFound(row: 1, col: 2))
        XCTAssertNotEqual(SheetStoreError.cellNotFound(row: 1, col: 2), SheetStoreError.cellNotFound(row: 1, col: 3))
    }

    func testCellOutOfBoundsEquality() {
        XCTAssertEqual(
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 3, cols: 3),
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 3, cols: 3)
        )
        XCTAssertNotEqual(
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 3, cols: 3),
            SheetStoreError.cellOutOfBounds(row: 5, col: 5, rows: 4, cols: 3)
        )
    }

    // MARK: - Construction smoke

    func testSheetStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = SheetStore(dataLayer: dataLayer)
        _ = store
    }
}
