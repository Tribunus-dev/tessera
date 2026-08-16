import XCTest
import CoreGraphics
import SceneKit
@testable import TesseraCore

// MARK: - ShapeExtrusionRendererTests
//
// Contract source: `ShapeExtrusion.swift`/`ShapeExtrusionRenderer.swift`'s
// own header comments (item 2.17, extrude-only-via-SceneKit) plus the
// task brief's own named test: "SCNShape construction from a known 2D
// path produces the expected bounding geometry (extrusionDepth/
// chamferRadius match the input ShapeExtrusion); a zero-depth extrusion
// is visually flat (degenerate-input test per doctrine rule 8)."

final class ShapeExtrusionRendererTests: DoctrineTestCase {

    private func rectShape(
        extrusion: ShapeExtrusion?,
        x: Double = 0, y: Double = 0, width: Double = 100, height: Double = 50
    ) -> Shape {
        Shape(
            kind: .rect,
            geometry: ShapeGeometry(x: x, y: y, width: width, height: height),
            fill: ShapeFill(colorHex: .literal("#FF0000")),
            extrusion: extrusion
        )
    }

    // MARK: - nil extrusion -> nil geometry

    func testShapeWithNoExtrusionProducesNoGeometry() {
        let shape = rectShape(extrusion: nil)
        XCTAssertNil(ShapeExtrusionRenderer().makeGeometry(for: shape))
    }

    // MARK: - Content (rule 8): SCNShape's own parameters match the input ShapeExtrusion

    func testExtrusionDepthAndChamferRadiusMatchTheInputShapeExtrusion() throws {
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 20, bevelDepth: 5))
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let scnShape = try XCTUnwrap(geometry as? SCNShape)
        XCTAssertEqual(Double(scnShape.extrusionDepth), 20, accuracy: 0.001)
        XCTAssertEqual(Double(scnShape.chamferRadius), 5, accuracy: 0.001)
    }

    func testBoundingBoxZExtentMatchesExtrusionDepth() throws {
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 30))
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let bounds = geometry.boundingBox
        XCTAssertEqual(Double(bounds.max.z - bounds.min.z), 30, accuracy: 0.5)
    }

    func testBoundingBoxXYExtentMatchesTheRectPathsOwnWidthAndHeight() throws {
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 5), width: 120, height: 40)
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let bounds = geometry.boundingBox
        XCTAssertEqual(Double(bounds.max.x - bounds.min.x), 120, accuracy: 0.5)
        XCTAssertEqual(Double(bounds.max.y - bounds.min.y), 40, accuracy: 0.5)
    }

    func testMaterialMetalnessAndRoughnessMatchTheInputShapeExtrusion() throws {
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 10, metalness: 0.9, roughness: 0.1))
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let material = try XCTUnwrap(geometry.firstMaterial)
        let metalness = try XCTUnwrap(material.metalness.contents as? NSNumber)
        let roughness = try XCTUnwrap(material.roughness.contents as? NSNumber)
        XCTAssertEqual(metalness.doubleValue, 0.9, accuracy: 0.001)
        XCTAssertEqual(roughness.doubleValue, 0.1, accuracy: 0.001)
    }

    // MARK: - Degenerate input (doctrine rule 8): zero-depth extrusion is visually flat

    func testZeroDepthExtrusionIsVisuallyFlat() throws {
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 0, bevelDepth: 0))
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let bounds = geometry.boundingBox
        XCTAssertEqual(
            Double(bounds.max.z - bounds.min.z), 0, accuracy: 0.001,
            "SceneKit documents extrusionDepth <= 0 as a flat 2D shape lying in the z=0 plane"
        )
    }

    func testChamferRadiusIsClampedToHalfTheSmallestBoundingDimension() throws {
        // bevelDepth (50) grossly exceeds anything a 20x10 rect with 4pt
        // depth can support - makeGeometry must clamp to half the
        // TIGHTEST of {width, height, depth} (here: depth/2 = 2) rather
        // than handing SceneKit a chamfer larger than the solid itself.
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 4, bevelDepth: 50), width: 20, height: 10)
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let scnShape = try XCTUnwrap(geometry as? SCNShape)
        XCTAssertEqual(Double(scnShape.chamferRadius), 2, accuracy: 0.001)
    }

    // MARK: - Determinism (rule 4)

    func testTwoIndependentCallsWithTheSameShapeProduceMatchingGeometry() throws {
        let shape = rectShape(extrusion: ShapeExtrusion(depth: 15, bevelDepth: 2, metalness: 0.4, roughness: 0.6))
        let renderer = ShapeExtrusionRenderer()
        let a = try XCTUnwrap(renderer.makeGeometry(for: shape) as? SCNShape)
        let b = try XCTUnwrap(renderer.makeGeometry(for: shape) as? SCNShape)

        XCTAssertEqual(a.extrusionDepth, b.extrusionDepth)
        XCTAssertEqual(a.chamferRadius, b.chamferRadius)
        XCTAssertEqual(a.boundingBox.min.x, b.boundingBox.min.x)
        XCTAssertEqual(a.boundingBox.max.x, b.boundingBox.max.x)
        XCTAssertEqual(a.boundingBox.min.z, b.boundingBox.min.z)
        XCTAssertEqual(a.boundingBox.max.z, b.boundingBox.max.z)
    }

    // MARK: - Reuses ShapeRenderer.path(for:), doesn't duplicate it

    func testBezierShapeWithNoPathDataDegradesToTheSameBoundingRectPlaceholderShapeRendererUses() throws {
        // ShapeKind.bezier with a nil shape.path is item 2.3's own
        // "malformed data" placeholder (ShapeRenderer.path(for:)'s
        // `.bezier` case) - this renderer must see the SAME fallback,
        // not diverge from it, since it calls that same function rather
        // than duplicating the per-ShapeKind path construction.
        var shape = rectShape(extrusion: ShapeExtrusion(depth: 8), width: 60, height: 30)
        shape.kind = .bezier
        shape.path = nil
        let geometry = try XCTUnwrap(ShapeExtrusionRenderer().makeGeometry(for: shape))
        let bounds = geometry.boundingBox
        XCTAssertEqual(Double(bounds.max.x - bounds.min.x), 60, accuracy: 0.5)
        XCTAssertEqual(Double(bounds.max.y - bounds.min.y), 30, accuracy: 0.5)
    }
}
