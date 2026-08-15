import XCTest
import Foundation
@testable import TesseraCore

// MARK: - ShapeTests
//
// Value-type round-trip tests (doctrine rule 2) for Shape.swift's
// types, which live at Sources/TesseraCore/Productivity/Shape.swift
// (not under Materials/) - placed here per this cluster's brief ("a
// sensible new location... e.g. .../Draw/ShapeTests.swift").

final class ShapeTests: DoctrineTestCase {

    // MARK: - ShapeGeometry (custom Codable - back-compat for flipH/flipV)

    func testShapeGeometryEncodeDecodeIsIdentity() throws {
        let geometry = ShapeGeometry(x: 1, y: 2, width: 3, height: 4, rotation: 45, anchorX: 1.5, anchorY: 2.5, flipH: true, flipV: false)
        let data = try JSONEncoder().encode(geometry)
        let decoded = try JSONDecoder().decode(ShapeGeometry.self, from: data)
        XCTAssertEqual(decoded, geometry)
    }

    func testShapeGeometryDecodesLegacyJSONMissingFlipFieldsAsFalse() throws {
        // Pins the documented back-compat contract: "flipH/flipV were
        // added after this type shipped... decodeIfPresent falls back to
        // false (no mirroring)."
        let json = """
        {"x": 0, "y": 0, "width": 10, "height": 10, "rotation": 0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ShapeGeometry.self, from: json)
        XCTAssertEqual(decoded.flipH, false)
        XCTAssertEqual(decoded.flipV, false)
        XCTAssertNil(decoded.anchorX)
        XCTAssertNil(decoded.anchorY)
    }

    func testShapeGeometryAnchorPointFallsBackToCenterWhenUnset() {
        let geometry = ShapeGeometry(x: 0, y: 0, width: 100, height: 40)
        XCTAssertEqual(geometry.anchorPoint.x, 50)
        XCTAssertEqual(geometry.anchorPoint.y, 20)
    }

    // MARK: - ShapeFill / ShapeStroke round trip

    func testShapeFillEncodeDecodeIsIdentity() throws {
        let fill = ShapeFill(colorHex: "#AABBCC", opacity: 0.5)
        let data = try JSONEncoder().encode(fill)
        let decoded = try JSONDecoder().decode(ShapeFill.self, from: data)
        XCTAssertEqual(decoded, fill)
    }

    func testShapeFillOpacityClampsToZeroOneRange() {
        XCTAssertEqual(ShapeFill(colorHex: "#000000", opacity: 5).opacity, 1)
        XCTAssertEqual(ShapeFill(colorHex: "#000000", opacity: -5).opacity, 0)
    }

    func testShapeStrokeEncodeDecodeIsIdentity() throws {
        let stroke = ShapeStroke(colorHex: "#112233", width: 2.5, dashPattern: [4, 2])
        let data = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(ShapeStroke.self, from: data)
        XCTAssertEqual(decoded, stroke)
    }

    func testShapeStrokeWidthNeverGoesNegative() {
        XCTAssertEqual(ShapeStroke(colorHex: "#000000", width: -3).width, 0)
    }

    // MARK: - ConnectorInfo / ConnectorEndpoint round trip

    func testConnectorInfoWithAttachedEndpointsEncodeDecodeIsIdentity() throws {
        let info = ConnectorInfo(
            start: .attached(shapeID: UUID(), gluePointIndex: 1),
            end: .attached(shapeID: UUID(), gluePointIndex: 3),
            style: .curved
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ConnectorInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testConnectorInfoWithFreeEndpointsEncodeDecodeIsIdentity() throws {
        let info = ConnectorInfo(start: .free(x: 1, y: 2), end: .free(x: 3, y: 4), style: .straight)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ConnectorInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    // MARK: - Shape (whole aggregate) round trip

    func testShapeEncodeDecodeIsIdentityIncludingAllOptionalFields() throws {
        var shape = Shape(
            kind: .rect,
            geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10),
            fill: ShapeFill(colorHex: "#FFFFFF"),
            stroke: ShapeStroke(colorHex: "#000000"),
            text: ShapeText(runs: [InlineRun(text: "hello")]),
            zIndex: 3
        )
        shape.parentGroupID = UUID()
        shape.layerID = UUID()

        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, shape)
    }

    func testConnectorShapeEncodeDecodeIsIdentity() throws {
        let shape = Shape(
            kind: .connector,
            geometry: ShapeGeometry(x: 0, y: 0, width: 0, height: 0),
            connector: ConnectorInfo(start: .free(x: 0, y: 0), end: .free(x: 10, y: 10), style: .elbow)
        )
        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, shape)
    }

    func testShapeTextPlainTextJoinsRunTextInOrder() {
        let text = ShapeText(runs: [InlineRun(text: "Hello, "), InlineRun(text: "world")])
        XCTAssertEqual(text.plainText, "Hello, world")
    }

    // MARK: - ColorRef adoption gap (suspected code bug, per task brief)
    //
    // Contract: studio-expansion-design-refinement-2026-08-14.md section
    // 4 "Slides cluster" item 1.5 - "ColorRef... adopted by
    // StyleDefinition, master backgrounds, and Shape fills". Confirmed
    // still literal-only at HEAD per docs/p1-post-claim-audit-2026-08-15.md
    // item 1.5: "ColorRef adopted 1-of-3 (master backgrounds only;
    // StyleDefinition + ShapeFill literal)".
    //
    // ShapeFill.colorHex is declared `String`, not `ColorRef`, so it
    // cannot be constructed with a `.theme(...)` value at all (a compile
    // error, not a runtime one) - the contract-true, COMPILING way to
    // exercise this is decoding ColorRef's own wire shape
    // (`{"theme": {"slot": ..., "tint": ...}}`, Swift's synthesized
    // Codable encoding for an enum case with labeled associated values,
    // SE-0295) into a ShapeFill's colorHex field: per the contract this
    // should resolve to a theme reference; today it throws a
    // DecodingError because the field expects a plain string.
    func testShapeFillColorAcceptsThemeReferencePerColorRefContract() {
        let json = """
        {"colorHex": {"theme": {"slot": "accent1", "tint": 0}}, "opacity": 1}
        """.data(using: .utf8)!

        let decoded = try? JSONDecoder().decode(ShapeFill.self, from: json)
        XCTExpectFailure("SUSPECTED CODE BUG: ShapeFill.colorHex is still a literal String field, not ColorRef, so it cannot decode a theme color reference - contract: studio-expansion-design-refinement-2026-08-14.md section 4 Slides cluster item 1.5 (\"ColorRef... adopted by... Shape fills\"); confirmed still literal at docs/p1-post-claim-audit-2026-08-15.md item 1.5.") {
            XCTAssertNotNil(decoded, "ShapeFill.colorHex should accept a ColorRef.theme wire value per the ratified contract")
        }
    }
}
