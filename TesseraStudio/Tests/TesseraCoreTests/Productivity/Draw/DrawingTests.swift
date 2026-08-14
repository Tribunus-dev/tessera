import XCTest
@testable import TesseraCore

/// `Drawing` (P0 0.15): the Draw material's durable entity - a flat,
/// z-ordered list of `Shape`s persisted as `.shape` blocks.
final class DrawingTests: XCTestCase {

    private func makeShape(id: UUID = UUID(), kind: ShapeKind = .rect, zIndex: Int = 0) -> Shape {
        Shape(id: id, kind: kind, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10), zIndex: zIndex)
    }

    // MARK: - Constants

    func testEntityTypeConstants() {
        XCTAssertEqual(Drawing.entityType, "document")
        XCTAssertEqual(Drawing.subtype, "drawing")
        XCTAssertEqual(Drawing.makeBlank().subtypeString, "drawing")
    }

    // MARK: - Display

    func testDisplayTitleFallsBackToUntitled() {
        XCTAssertEqual(Drawing(title: "").displayTitle, "Untitled")
        XCTAssertEqual(Drawing(title: "  ").displayTitle, "Untitled")
        XCTAssertEqual(Drawing(title: "My Drawing").displayTitle, "My Drawing")
    }

    // MARK: - Blank state

    func testMakeBlankHasNoShapes() {
        let drawing = Drawing.makeBlank(title: "T")
        XCTAssertEqual(drawing.shapeCount, 0)
        XCTAssertTrue(drawing.shapes.isEmpty)
    }

    func testMakeBlankUsesDefaultCanvasSize() {
        let drawing = Drawing.makeBlank(title: "T")
        XCTAssertEqual(drawing.canvasSize, .default)
    }

    // MARK: - Inserting shapes

    func testInsertingShapeAddsItToShapesInOrder() {
        let a = makeShape(kind: .rect)
        let b = makeShape(kind: .ellipse)
        let drawing = Drawing.makeBlank().insertingShape(a).insertingShape(b)
        XCTAssertEqual(drawing.shapes.map(\.id), [a.id, b.id])
        XCTAssertEqual(drawing.shapeCount, 2)
    }

    func testShapeLookupByID() {
        let shape = makeShape()
        let drawing = Drawing.makeBlank().insertingShape(shape)
        XCTAssertEqual(drawing.shape(id: shape.id)?.kind, .rect)
        XCTAssertNil(drawing.shape(id: UUID()))
    }

    // MARK: - Deleting shapes

    func testDeletingShapeRemovesItFromShapesAndBlocks() {
        let shape = makeShape()
        var drawing = Drawing.makeBlank().insertingShape(shape)
        drawing = drawing.deletingShape(shape.id)
        XCTAssertTrue(drawing.shapes.isEmpty)
        XCTAssertNil(drawing.body.blocks[shape.id])
    }

    func testDeletingAnUnknownShapeIsANoOp() {
        let shape = makeShape()
        let drawing = Drawing.makeBlank().insertingShape(shape)
        let unchanged = drawing.deletingShape(UUID())
        XCTAssertEqual(unchanged.shapes.map(\.id), [shape.id])
    }

    // MARK: - Updating shapes

    func testUpdatingShapeReplacesItInPlace() {
        var shape = makeShape(kind: .rect)
        var drawing = Drawing.makeBlank().insertingShape(shape)
        shape.geometry.width = 99
        drawing = drawing.updatingShape(shape)
        XCTAssertEqual(drawing.shape(id: shape.id)?.geometry.width, 99)
        XCTAssertEqual(drawing.shapeCount, 1, "updating must not duplicate the shape")
    }

    func testUpdatingAnUnknownShapeIsANoOp() {
        let drawing = Drawing.makeBlank()
        let ghost = makeShape()
        let unchanged = drawing.updatingShape(ghost)
        XCTAssertTrue(unchanged.shapes.isEmpty, "updatingShape must never insert")
    }

    // MARK: - Z-order

    func testApplyingZOrderReordersShapesAndBlocks() {
        let a = makeShape(zIndex: 0)
        let b = makeShape(zIndex: 1)
        var drawing = Drawing.makeBlank().insertingShape(a).insertingShape(b)
        drawing = drawing.applyingZOrder(.toBack, toShape: b.id)
        XCTAssertEqual(drawing.shapes.map(\.id), [b.id, a.id])
        XCTAssertEqual(drawing.shapes.map(\.zIndex), [0, 1], "zIndex must be densely renumbered")
    }

    // MARK: - Document round-trip

    func testDrawingSurvivesJSONRoundTrip() throws {
        let shape = Shape(
            kind: .ellipse,
            geometry: ShapeGeometry(x: 1, y: 2, width: 3, height: 4, rotation: 45),
            fill: ShapeFill(colorHex: "#FF0000"),
            stroke: ShapeStroke(colorHex: "#000000", width: 2)
        )
        let drawing = Drawing.makeBlank(title: "T", canvasSize: CanvasSize(width: 1000, height: 500))
            .insertingShape(shape)
        let restored = try Drawing.from(jsonData: drawing.jsonData())
        XCTAssertEqual(restored.canvasSize, CanvasSize(width: 1000, height: 500))
        XCTAssertEqual(restored.shapes.first?.kind, .ellipse)
        XCTAssertEqual(restored.shapes.first?.fill?.colorHex, "#FF0000")
        XCTAssertEqual(restored.shapes.first?.geometry.rotation, 45)
    }

    func testJSONStringRoundTrip() throws {
        let drawing = Drawing(title: "Hello", tags: ["a"])
        let s = try drawing.jsonDataString()
        XCTAssertTrue(s.contains("Hello"))
        let parsed = try Drawing.from(jsonDataString: s)
        XCTAssertEqual(parsed.title, "Hello")
    }

    // MARK: - Tag normalization

    func testNormalizeTagsLowercasesTrimsAndDedupes() {
        XCTAssertEqual(Drawing.normalizeTags([" Hello ", "hello", "World"]), ["hello", "world"])
    }
}
