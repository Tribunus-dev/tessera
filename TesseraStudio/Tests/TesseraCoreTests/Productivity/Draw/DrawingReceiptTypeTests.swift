import XCTest
@testable import TesseraCore

final class DrawingReceiptTypeTests: XCTestCase {

    func testReceiptValuesAreStable() {
        XCTAssertEqual(DrawingReceiptType.upsert.rawValue, "drawing_upsert")
        XCTAssertEqual(DrawingReceiptType.delete.rawValue, "drawing_delete")
        XCTAssertEqual(DrawingReceiptType.archive.rawValue, "drawing_archived")
        XCTAssertEqual(DrawingReceiptType.unarchive.rawValue, "drawing_unarchived")
        XCTAssertEqual(DrawingReceiptType.trash.rawValue, "drawing_trashed")
        XCTAssertEqual(DrawingReceiptType.restore.rawValue, "drawing_restored")
        XCTAssertEqual(DrawingReceiptType.favorite.rawValue, "drawing_favorited")
        XCTAssertEqual(DrawingReceiptType.unfavorite.rawValue, "drawing_unfavorited")
        XCTAssertEqual(DrawingReceiptType.tagChange.rawValue, "drawing_tags_changed")
        XCTAssertEqual(DrawingReceiptType.tagAdded.rawValue, "drawing_tag_added")
        XCTAssertEqual(DrawingReceiptType.tagRemoved.rawValue, "drawing_tag_removed")
        XCTAssertEqual(DrawingReceiptType.link.rawValue, "drawing_link_created")
        XCTAssertEqual(DrawingReceiptType.unlink.rawValue, "drawing_link_deleted")
        XCTAssertEqual(DrawingReceiptType.insertShape.rawValue, "drawing_shape_inserted")
        XCTAssertEqual(DrawingReceiptType.deleteShape.rawValue, "drawing_shape_deleted")
        XCTAssertEqual(DrawingReceiptType.setGeometry.rawValue, "drawing_shape_geometry_changed")
        XCTAssertEqual(DrawingReceiptType.setFill.rawValue, "drawing_shape_fill_changed")
        XCTAssertEqual(DrawingReceiptType.setStroke.rawValue, "drawing_shape_stroke_changed")
        XCTAssertEqual(DrawingReceiptType.setText.rawValue, "drawing_shape_text_changed")
        XCTAssertEqual(DrawingReceiptType.setZOrder.rawValue, "drawing_shape_z_order_changed")
    }

    func testAllCasesHaveUniqueRawValues() {
        let values = DrawingReceiptType.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testAllCasesRoundTripThroughRawValue() {
        for c in DrawingReceiptType.allCases {
            XCTAssertEqual(DrawingReceiptType(rawValue: c.rawValue), c)
        }
    }
}
