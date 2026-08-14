import XCTest
@testable import TesseraCore

/// `DrawingStore` (P0 0.15). Async mutations need a live data layer
/// this test target doesn't stand up (see `SlideStoreTests`/
/// `DocStoreTests`, scoped the same way) - the mutation LOGIC itself
/// is pinned at the pure `Drawing` model level in `DrawingTests`.
final class DrawingStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = DrawingStore(dataLayer: dataLayer)
        _ = store
    }

    func testJSONStringRoundTripViaDrawingHelper() throws {
        let drawing = Drawing(title: "Hello", tags: ["a"])
        let s = try drawing.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try Drawing.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    func testDrawingNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(DrawingStoreError.drawingNotFound(id: id), DrawingStoreError.drawingNotFound(id: id))
        XCTAssertNotEqual(DrawingStoreError.drawingNotFound(id: id), DrawingStoreError.drawingNotFound(id: UUID()))
    }

    func testShapeNotFoundEquatable() {
        let id = UUID()
        XCTAssertEqual(DrawingStoreError.shapeNotFound(id: id), DrawingStoreError.shapeNotFound(id: id))
        XCTAssertNotEqual(DrawingStoreError.shapeNotFound(id: id), DrawingStoreError.shapeNotFound(id: UUID()))
    }

    func testInvalidBodyEquatable() {
        XCTAssertEqual(DrawingStoreError.invalidBody(reason: "x"), DrawingStoreError.invalidBody(reason: "x"))
        XCTAssertNotEqual(DrawingStoreError.invalidBody(reason: "x"), DrawingStoreError.invalidBody(reason: "y"))
    }

    func testListFilterApply() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = Drawing(id: UUID(), title: "a", isFavorite: true, createdAt: now, updatedAt: now)
        let b = Drawing(id: UUID(), title: "b", isArchived: true, createdAt: now, updatedAt: now)
        let c = Drawing(id: UUID(), title: "c", isTrashed: true, createdAt: now, updatedAt: now)
        let all = [a, b, c]
        XCTAssertEqual(DrawingListFilter.all.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DrawingListFilter.favorites.apply(to: all).map { $0.title }, ["a"])
        XCTAssertEqual(DrawingListFilter.archived.apply(to: all).map { $0.title }, ["b"])
        XCTAssertEqual(DrawingListFilter.trash.apply(to: all).map { $0.title }, ["c"])
    }

    func testDrawingRowProjection() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1))
        let drawing = Drawing(title: "T", isFavorite: true, tags: ["x"]).insertingShape(shape)
        let row = DrawingRow(drawing: drawing)
        XCTAssertEqual(row.title, "T")
        XCTAssertEqual(row.shapeCount, 1)
        XCTAssertEqual(row.tags, ["x"])
        XCTAssertTrue(row.isFavorite)
    }
}
