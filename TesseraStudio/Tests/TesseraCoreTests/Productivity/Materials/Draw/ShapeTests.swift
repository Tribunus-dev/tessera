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

    // MARK: - Item 2.12 (Draw advanced): callout - ShapeKind.callout +
    // Shape.calloutAnchor: ConnectorEndpoint? (reusing the existing type).

    func testCalloutShapeWithFreeAnchorEncodeDecodeIsIdentity() throws {
        let shape = Shape(
            kind: .callout,
            geometry: ShapeGeometry(x: 0, y: 0, width: 100, height: 40),
            text: ShapeText(runs: [InlineRun(text: "note")]),
            calloutAnchor: .free(x: 200, y: 150)
        )
        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, shape)
    }

    func testCalloutShapeWithAttachedAnchorEncodeDecodeIsIdentity() throws {
        let targetID = UUID()
        let shape = Shape(
            kind: .callout,
            geometry: ShapeGeometry(x: 0, y: 0, width: 100, height: 40),
            calloutAnchor: .attached(shapeID: targetID, gluePointIndex: 2)
        )
        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, shape)
        XCTAssertEqual(decoded.calloutAnchor, .attached(shapeID: targetID, gluePointIndex: 2))
    }

    func testShapeWithNoCalloutAnchorDefaultsToNil() {
        let shape = Shape(kind: .callout, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(shape.calloutAnchor)
    }

    func testLegacyShapeJSONMissingCalloutAnchorFieldDecodesAsNil() throws {
        // Additive-field back-compat (doctrine rule 2): a Shape JSON
        // blob written before calloutAnchor/dimensionInfo/table existed
        // must still decode, with all three absent (Swift's synthesized
        // Optional decoding, no custom Codable needed - see Shape.swift's
        // own doc comment on why this differs from ShapeGeometry's
        // flipH/flipV back-compat handling).
        let id = UUID()
        let json = """
        {"id": "\(id.uuidString)", "kind": "rect", "geometry": {"x": 0, "y": 0, "width": 10, "height": 10, "rotation": 0}, "zIndex": 0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Shape.self, from: json)
        XCTAssertNil(decoded.calloutAnchor)
        XCTAssertNil(decoded.dimensionInfo)
        XCTAssertNil(decoded.table)
    }

    // MARK: - Item 2.12: measure/dimension lines - ShapeKind.line +
    // Shape.dimensionInfo: ShapeDimensionInfo?

    func testShapeDimensionInfoEncodeDecodeIsIdentity() throws {
        let info = ShapeDimensionInfo(units: .millimeter, precision: 2, manualOverrideText: "12mm")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ShapeDimensionInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testShapeDimensionInfoPrecisionNeverGoesNegative() {
        XCTAssertEqual(ShapeDimensionInfo(precision: -4).precision, 0)
    }

    func testShapeDimensionInfoMeasuredLengthUsesGeometryWidthConvertedToUnits() {
        // 144 points == 2 inches (1 in == 72 pt, DimensionUnit's own
        // documented conversion factor).
        let geometry = ShapeGeometry(x: 0, y: 0, width: 144, height: 0)
        let info = ShapeDimensionInfo(units: .inch, precision: 2)
        XCTAssertEqual(info.measuredLength(for: geometry), 2, accuracy: 1e-9)
    }

    func testShapeDimensionInfoDisplayTextUsesManualOverrideWhenSet() {
        let geometry = ShapeGeometry(x: 0, y: 0, width: 100, height: 0)
        let info = ShapeDimensionInfo(units: .point, precision: 1, manualOverrideText: "custom label")
        XCTAssertEqual(info.displayText(for: geometry), "custom label")
    }

    func testShapeDimensionInfoDisplayTextAutoComputesWhenNoOverride() {
        let geometry = ShapeGeometry(x: 0, y: 0, width: 100, height: 0)
        let info = ShapeDimensionInfo(units: .point, precision: 1)
        XCTAssertEqual(info.displayText(for: geometry), "100.0pt")
    }

    func testDimensionLineShapeEncodeDecodeIsIdentity() throws {
        let shape = Shape(
            kind: .line,
            geometry: ShapeGeometry(x: 0, y: 0, width: 200, height: 0),
            stroke: ShapeStroke(colorHex: "#000000"),
            dimensionInfo: ShapeDimensionInfo(units: .centimeter, precision: 1)
        )
        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(Shape.self, from: data)
        XCTAssertEqual(decoded, shape)
    }

    // MARK: - Item 2.12: bullet lists inside shape text - ShapeText
    // .listItems: [ShapeTextListItem]? / .listStyle: ShapeTextListStyle?

    func testShapeTextListItemLevelNeverGoesNegative() {
        XCTAssertEqual(ShapeTextListItem(level: -3).level, 0)
    }

    func testShapeTextWithListItemsEncodeDecodeIsIdentity() throws {
        let text = ShapeText(
            listItems: [
                ShapeTextListItem(runs: [InlineRun(text: "first")], level: 0),
                ShapeTextListItem(runs: [InlineRun(text: "nested")], level: 1),
            ],
            listStyle: .ordered
        )
        let data = try JSONEncoder().encode(text)
        let decoded = try JSONDecoder().decode(ShapeText.self, from: data)
        XCTAssertEqual(decoded, text)
    }

    func testShapeTextWithNoListItemsDefaultsToNilPreservingOriginalPlainParagraphShape() {
        let text = ShapeText(runs: [InlineRun(text: "plain")])
        XCTAssertNil(text.listItems)
        XCTAssertNil(text.listStyle)
    }

    func testLegacyShapeTextJSONMissingListFieldsDecodesAsNilListItems() throws {
        let json = """
        {"runs": [{"text": "hello", "annotations": []}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ShapeText.self, from: json)
        XCTAssertNil(decoded.listItems)
        XCTAssertNil(decoded.listStyle)
        XCTAssertEqual(decoded.plainText, "hello")
    }

    func testShapeTextPlainTextJoinsListItemsWithNewlinesWhenListModeActive() {
        let text = ShapeText(
            runs: [InlineRun(text: "ignored while listItems is active")],
            listItems: [
                ShapeTextListItem(runs: [InlineRun(text: "one")]),
                ShapeTextListItem(runs: [InlineRun(text: "two")]),
            ],
            listStyle: .unordered
        )
        XCTAssertEqual(text.plainText, "one\ntwo")
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
        XCTAssertNotNil(decoded, "ShapeFill.colorHex should accept a ColorRef.theme wire value per the ratified contract")
    }
}
