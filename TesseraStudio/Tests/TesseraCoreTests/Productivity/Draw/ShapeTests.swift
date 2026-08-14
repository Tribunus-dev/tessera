import XCTest
@testable import TesseraCore

/// `Shape`, `ShapeGeometry`, `ShapeFill`, `ShapeStroke`, `ShapeText` -
/// the Draw data model, peer of `Block`.
final class ShapeTests: XCTestCase {

    // MARK: - ShapeGeometry

    func testAnchorDefaultsToCenter() {
        let g = ShapeGeometry(x: 10, y: 20, width: 100, height: 50)
        XCTAssertNil(g.anchorX)
        XCTAssertNil(g.anchorY)
        XCTAssertEqual(g.anchorPoint.x, 50)
        XCTAssertEqual(g.anchorPoint.y, 25)
    }

    func testExplicitAnchorOverridesCenter() {
        let g = ShapeGeometry(x: 0, y: 0, width: 100, height: 50, anchorX: 0, anchorY: 0)
        XCTAssertEqual(g.anchorPoint.x, 0)
        XCTAssertEqual(g.anchorPoint.y, 0)
    }

    func testFrameMatchesXYWidthHeight() {
        let g = ShapeGeometry(x: 5, y: 7, width: 30, height: 40)
        XCTAssertEqual(g.frame, CGRect(x: 5, y: 7, width: 30, height: 40))
    }

    // MARK: - ShapeFill / ShapeStroke

    func testFillOpacityClampsToUnitRange() {
        XCTAssertEqual(ShapeFill(colorHex: "#FFF", opacity: 5).opacity, 1)
        XCTAssertEqual(ShapeFill(colorHex: "#FFF", opacity: -5).opacity, 0)
        XCTAssertEqual(ShapeFill(colorHex: "#FFF", opacity: 0.5).opacity, 0.5)
    }

    func testStrokeWidthCannotBeNegative() {
        XCTAssertEqual(ShapeStroke(colorHex: "#000", width: -3).width, 0)
        XCTAssertEqual(ShapeStroke(colorHex: "#000", width: 2).width, 2)
    }

    // MARK: - ShapeText

    func testShapeTextPlainTextJoinsRuns() {
        let text = ShapeText(runs: [InlineRun(text: "Hello "), InlineRun(text: "world")])
        XCTAssertEqual(text.plainText, "Hello world")
    }

    // MARK: - Shape

    func testShapeDefaults() {
        let s = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(s.fill)
        XCTAssertNil(s.stroke)
        XCTAssertNil(s.text)
        XCTAssertEqual(s.zIndex, 0)
        XCTAssertNil(s.parentGroupID)
    }

    func testShapeJSONRoundTrip() throws {
        let original = Shape(
            kind: .star,
            geometry: ShapeGeometry(x: 1, y: 2, width: 30, height: 40, rotation: 15, anchorX: 5, anchorY: 6),
            fill: ShapeFill(colorHex: "#FFD9D9", opacity: 0.8),
            stroke: ShapeStroke(colorHex: "#B84A4A", width: 2, dashPattern: [4, 2]),
            text: ShapeText(runs: [InlineRun(text: "label")]),
            zIndex: 3,
            parentGroupID: UUID()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Every `ShapeKind` case round-trips through its raw value - a
    /// stored drawing must not silently reinterpret one kind as
    /// another after a future case is added.
    func testEveryShapeKindEncodesAndDecodes() throws {
        for kind in ShapeKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(ShapeKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }
}
