import XCTest
@testable import TesseraCore

final class SlideReceiptTypeTests: XCTestCase {

    func testReceiptValuesAreStable() {
        XCTAssertEqual(SlideReceiptType.upsert.rawValue, "slide_upsert")
        XCTAssertEqual(SlideReceiptType.updateBody.rawValue, "slide_body_changed")
        XCTAssertEqual(SlideReceiptType.insertSlide.rawValue, "slide_inserted")
        XCTAssertEqual(SlideReceiptType.deleteSlide.rawValue, "slide_deleted")
        XCTAssertEqual(SlideReceiptType.moveSlide.rawValue, "slide_moved")
        XCTAssertEqual(SlideReceiptType.duplicateSlide.rawValue, "slide_duplicated")
        XCTAssertEqual(SlideReceiptType.setSlideLayout.rawValue, "slide_layout_changed")
        XCTAssertEqual(SlideReceiptType.archive.rawValue, "slide_archived")
        XCTAssertEqual(SlideReceiptType.unarchive.rawValue, "slide_unarchived")
        XCTAssertEqual(SlideReceiptType.trash.rawValue, "slide_trashed")
        XCTAssertEqual(SlideReceiptType.restore.rawValue, "slide_restored")
        XCTAssertEqual(SlideReceiptType.delete.rawValue, "slide_delete")
        XCTAssertEqual(SlideReceiptType.favorite.rawValue, "slide_favorited")
        XCTAssertEqual(SlideReceiptType.unfavorite.rawValue, "slide_unfavorited")
        XCTAssertEqual(SlideReceiptType.tagChange.rawValue, "slide_tags_changed")
        XCTAssertEqual(SlideReceiptType.tagAdded.rawValue, "slide_tag_added")
        XCTAssertEqual(SlideReceiptType.tagRemoved.rawValue, "slide_tag_removed")
        XCTAssertEqual(SlideReceiptType.link.rawValue, "slide_link_created")
        XCTAssertEqual(SlideReceiptType.unlink.rawValue, "slide_link_deleted")
        XCTAssertEqual(SlideReceiptType.import.rawValue, "slide_imported")
    }

    func testAllCasesHaveUniqueRawValues() {
        let values = SlideReceiptType.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testAllCasesRoundTripThroughRawValue() {
        for c in SlideReceiptType.allCases {
            XCTAssertEqual(SlideReceiptType(rawValue: c.rawValue), c)
        }
    }
}
