import XCTest
@testable import TesseraCore

final class DocReceiptTypeTests: XCTestCase {

    func testReceiptValuesAreStable() {
        XCTAssertEqual(DocReceiptType.upsert.rawValue, "doc_upsert")
        XCTAssertEqual(DocReceiptType.updateBody.rawValue, "doc_body_changed")
        XCTAssertEqual(DocReceiptType.archive.rawValue, "doc_archived")
        XCTAssertEqual(DocReceiptType.unarchive.rawValue, "doc_unarchived")
        XCTAssertEqual(DocReceiptType.trash.rawValue, "doc_trashed")
        XCTAssertEqual(DocReceiptType.restore.rawValue, "doc_restored")
        XCTAssertEqual(DocReceiptType.delete.rawValue, "doc_delete")
        XCTAssertEqual(DocReceiptType.favorite.rawValue, "doc_favorited")
        XCTAssertEqual(DocReceiptType.unfavorite.rawValue, "doc_unfavorited")
        XCTAssertEqual(DocReceiptType.tagChange.rawValue, "doc_tags_changed")
        XCTAssertEqual(DocReceiptType.tagAdded.rawValue, "doc_tag_added")
        XCTAssertEqual(DocReceiptType.tagRemoved.rawValue, "doc_tag_removed")
        XCTAssertEqual(DocReceiptType.link.rawValue, "doc_link_created")
        XCTAssertEqual(DocReceiptType.unlink.rawValue, "doc_link_deleted")
        XCTAssertEqual(DocReceiptType.import.rawValue, "doc_imported")
    }

    func testAllCasesHaveUniqueRawValues() {
        let values = DocReceiptType.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(values).count, values.count)
    }
}
