import XCTest
@testable import TesseraCore

final class DocStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = DocStore(dataLayer: dataLayer)
        _ = store
    }

    func testDocJSONStringRoundTripViaStoreHelper() throws {
        let doc = Doc(title: "Hello", body: .empty, tags: ["a"])
        let s = try doc.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try Doc.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    func testInvalidBodyEquatable() {
        XCTAssertEqual(DocStoreError.invalidBody(reason: "x"), DocStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(DocStoreError.invalidBody(reason: "x"), DocStoreError.invalidBody(reason: "y"))
    }

    func testDocNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(DocStoreError.docNotFound(id: id), DocStoreError.docNotFound(id: id))
        XCTAssertNotEqual(DocStoreError.docNotFound(id: id), DocStoreError.docNotFound(id: UUID()))
    }

    func testListFilterApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = Doc(id: UUID(), title: "a", body: .empty, isFavorite: true, createdAt: now, updatedAt: now)
        let b = Doc(id: UUID(), title: "b", body: .empty, isArchived: true, createdAt: now, updatedAt: now)
        let c = Doc(id: UUID(), title: "c", body: .empty, isTrashed: true, createdAt: now, updatedAt: now)
        let all = [a, b, c]
        XCTAssertEqual(DocListFilter.all.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DocListFilter.favorites.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DocListFilter.archived.apply(to: all).map { $0.title }, ["b"])
        XCTAssertEqual(DocListFilter.trash.apply(to: all).map { $0.title }, ["c"])
    }

    func testNormalizeTagsViaDoc() {
        XCTAssertEqual(Doc.normalizeTags([" Hello ", "hello"]), ["hello"])
    }
}
