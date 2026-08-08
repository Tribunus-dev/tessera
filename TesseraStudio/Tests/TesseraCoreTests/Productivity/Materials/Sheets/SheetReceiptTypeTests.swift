import XCTest
@testable import TesseraCore

/// Tests for the receipt type vocabulary emitted by the Sheets surface.
/// Raw values are persisted to `graph_receipts.receipt_type`; changing
/// one is a schema migration.
final class SheetReceiptTypeTests: XCTestCase {

    func testAllCasesHaveRawValues() {
        for type in SheetReceiptType.allCases {
            XCTAssertFalse(type.rawValue.isEmpty, "receipt type \(type) must have a raw value")
            XCTAssertTrue(type.rawValue.hasPrefix("sheet_"), "receipt type \(type) should be prefixed sheet_")
        }
    }

    func testCountMatchesSpec() {
        // 14 logical vocab entries; if this breaks you added or
        // removed a case — update the pin list below.
        XCTAssertEqual(SheetReceiptType.allCases.count, 20)
    }

    func testUpsertIsStable() {
        XCTAssertEqual(SheetReceiptType.upsert.rawValue, "sheet_upsert")
    }

    func testUpdateBodyIsStable() {
        XCTAssertEqual(SheetReceiptType.updateBody.rawValue, "sheet_body_changed")
    }

    func testSetCellIsStable() {
        XCTAssertEqual(SheetReceiptType.setCell.rawValue, "sheet_cell_changed")
    }

    func testRowOpsAreStable() {
        XCTAssertEqual(SheetReceiptType.insertRow.rawValue, "sheet_row_inserted")
        XCTAssertEqual(SheetReceiptType.deleteRow.rawValue, "sheet_row_deleted")
    }

    func testColumnOpsAreStable() {
        XCTAssertEqual(SheetReceiptType.insertColumn.rawValue, "sheet_column_inserted")
        XCTAssertEqual(SheetReceiptType.deleteColumn.rawValue, "sheet_column_deleted")
    }

    func testArchiveUnarchiveAreStable() {
        XCTAssertEqual(SheetReceiptType.archive.rawValue, "sheet_archived")
        XCTAssertEqual(SheetReceiptType.unarchive.rawValue, "sheet_unarchived")
    }

    func testTrashRestoreAreStable() {
        XCTAssertEqual(SheetReceiptType.trash.rawValue, "sheet_trashed")
        XCTAssertEqual(SheetReceiptType.restore.rawValue, "sheet_restored")
        XCTAssertEqual(SheetReceiptType.delete.rawValue, "sheet_delete")
    }

    func testFavoriteUnfavoriteAreStable() {
        XCTAssertEqual(SheetReceiptType.favorite.rawValue, "sheet_favorited")
        XCTAssertEqual(SheetReceiptType.unfavorite.rawValue, "sheet_unfavorited")
    }

    func testTagReceiptsAreStable() {
        XCTAssertEqual(SheetReceiptType.tagChange.rawValue, "sheet_tags_changed")
        XCTAssertEqual(SheetReceiptType.tagAdded.rawValue, "sheet_tag_added")
        XCTAssertEqual(SheetReceiptType.tagRemoved.rawValue, "sheet_tag_removed")
    }

    func testLinkUnlinkAreStable() {
        XCTAssertEqual(SheetReceiptType.link.rawValue, "sheet_link_created")
        XCTAssertEqual(SheetReceiptType.unlink.rawValue, "sheet_link_deleted")
    }

    func testImportIsStable() {
        XCTAssertEqual(SheetReceiptType.import.rawValue, "sheet_imported")
    }

    func testReceiptTypeIsCodable() throws {
        let original: SheetReceiptType = .setCell
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SheetReceiptType.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testReceiptTypeRawValuesAreDistinct() {
        let values = SheetReceiptType.allCases.map { $0.rawValue }
        XCTAssertEqual(values.count, Set(values).count, "receipt raw values must be distinct")
    }

    func testReceiptTypeSendableEquatable() {
        let a = SheetReceiptType.favorite
        let b = SheetReceiptType.favorite
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, SheetReceiptType.unfavorite)
    }
}
