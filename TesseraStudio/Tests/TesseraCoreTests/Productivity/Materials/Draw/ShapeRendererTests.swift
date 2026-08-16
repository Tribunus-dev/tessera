import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - ShapeRendererTests
//
// Contract source: item 2.3's own instruction ("real '.bezier' case in
// 'path(for:allShapes:)' - build a real CGPath by walking
// shape.path.subpaths' segments... .closeSubpath() when a subpath's
// 'closed' is true") plus testing-doctrine.md's coverage shape for a
// renderer ("determinism + content + degenerate inputs"). `path(for:
// allShapes:)` was widened to module-internal by the P2-B item 2.17
// track (ShapeExtrusionRenderer's own reuse need) - this file calls it
// directly rather than round-tripping through `render(_:in:)`'s full
// fill/stroke pipeline, the same way a renderer test would inspect any
// other kind's geometry.

final class ShapeRendererTests: DoctrineTestCase {

    private let renderer = ShapeRenderer()

    private func bezierShape(_ path: ShapePath, x: Double = 100, y: Double = 50) -> Shape {
        Shape(kind: .bezier, geometry: ShapeGeometry(x: x, y: y, width: 40, height: 30), path: path)
    }

    /// Flattens a `CGPath` into a small value-type element list so tests
    /// can assert structure without depending on `CGPathElement`'s
    /// unsafe-pointer-based enumeration API directly in every test body.
    private enum FlatElement: Equatable {
        case moveTo(CGPoint)
        case lineTo(CGPoint)
        case quadCurveTo(CGPoint, CGPoint)
        case curveTo(CGPoint, CGPoint, CGPoint)
        case closeSubpath
    }

    private func flatten(_ path: CGPath) -> [FlatElement] {
        var elements: [FlatElement] = []
        path.applyWithBlock { rawElement in
            let element = rawElement.pointee
            switch element.type {
            case .moveToPoint:
                elements.append(.moveTo(element.points[0]))
            case .addLineToPoint:
                elements.append(.lineTo(element.points[0]))
            case .addQuadCurveToPoint:
                elements.append(.quadCurveTo(element.points[0], element.points[1]))
            case .addCurveToPoint:
                elements.append(.curveTo(element.points[0], element.points[1], element.points[2]))
            case .closeSubpath:
                elements.append(.closeSubpath)
            @unknown default:
                break
            }
        }
        return elements
    }

    // MARK: - Open subpath

    func testBezierPathForOpenSubpathWithLineSegments() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 10)),
                ],
                closed: false
            ),
        ])
        let shape = bezierShape(path)
        let cgPath = renderer.path(for: shape)
        let flat = flatten(cgPath)

        // origin (100, 50) added to every LOCAL point (ShapeRenderer's
        // own documented coordinate-space contract for .bezier).
        XCTAssertEqual(flat, [
            .moveTo(CGPoint(x: 100, y: 50)),
            .lineTo(CGPoint(x: 110, y: 50)),
            .lineTo(CGPoint(x: 110, y: 60)),
        ])
    }

    // MARK: - Closed subpath

    func testBezierPathForClosedSubpathEmitsCloseSubpath() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 10)),
                ],
                closed: true
            ),
        ])
        let shape = bezierShape(path)
        let flat = flatten(renderer.path(for: shape))

        XCTAssertEqual(flat, [
            .moveTo(CGPoint(x: 100, y: 50)),
            .lineTo(CGPoint(x: 110, y: 50)),
            .lineTo(CGPoint(x: 110, y: 60)),
            .closeSubpath,
        ])
    }

    // MARK: - Quad / cubic segments

    func testBezierPathForQuadSegmentUsesAddQuadCurve() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .quad(control: ShapePathPoint(x: 5, y: 10), end: ShapePathPoint(x: 10, y: 0)),
            ]),
        ])
        let shape = bezierShape(path, x: 0, y: 0)
        let flat = flatten(renderer.path(for: shape))
        XCTAssertEqual(flat, [
            .moveTo(CGPoint(x: 0, y: 0)),
            .quadCurveTo(CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 0)),
        ])
    }

    func testBezierPathForCubicSegmentUsesAddCurve() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .cubic(control1: ShapePathPoint(x: 3, y: 10), control2: ShapePathPoint(x: 7, y: 10), end: ShapePathPoint(x: 10, y: 0)),
            ]),
        ])
        let shape = bezierShape(path, x: 0, y: 0)
        let flat = flatten(renderer.path(for: shape))
        XCTAssertEqual(flat, [
            .moveTo(CGPoint(x: 0, y: 0)),
            .curveTo(CGPoint(x: 3, y: 10), CGPoint(x: 7, y: 10), CGPoint(x: 10, y: 0)),
        ])
    }

    // MARK: - Multiple subpaths ("O" shape - outer ring + inner hole)

    func testBezierPathForMultipleSubpathsEmitsAMoveForEach() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .line(ShapePathPoint(x: 20, y: 0)),
                .line(ShapePathPoint(x: 20, y: 20)),
            ], closed: true),
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 5, y: 5)),
                .line(ShapePathPoint(x: 15, y: 5)),
            ], closed: false),
        ])
        let shape = bezierShape(path, x: 0, y: 0)
        let flat = flatten(renderer.path(for: shape))
        XCTAssertEqual(flat, [
            .moveTo(CGPoint(x: 0, y: 0)),
            .lineTo(CGPoint(x: 20, y: 0)),
            .lineTo(CGPoint(x: 20, y: 20)),
            .closeSubpath,
            .moveTo(CGPoint(x: 5, y: 5)),
            .lineTo(CGPoint(x: 15, y: 5)),
        ])
    }

    // MARK: - Degenerate inputs (doctrine rule 8: renderers cover these)

    func testBezierPathForNilPathFallsBackToBoundingRect() {
        let shape = Shape(kind: .bezier, geometry: ShapeGeometry(x: 10, y: 20, width: 30, height: 40), path: nil)
        let flat = flatten(renderer.path(for: shape))
        // Same shape as rectPath(shape.geometry) - a closed 4-point box.
        XCTAssertFalse(flat.isEmpty)
        XCTAssertTrue(flat.contains(.moveTo(CGPoint(x: 10, y: 20))))
    }

    func testBezierPathForEmptyShapePathProducesAnEmptyCGPath() {
        let shape = bezierShape(ShapePath(subpaths: []))
        let cgPath = renderer.path(for: shape)
        XCTAssertTrue(cgPath.isEmpty)
    }

    func testBezierPathForSubpathWithNoSegmentsIsSkippedWithoutCrashing() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [], closed: false)])
        let shape = bezierShape(path)
        XCTAssertTrue(renderer.path(for: shape).isEmpty)
    }

    // MARK: - Determinism (doctrine rule 4: two independent passes produce byte-identical output)

    func testBezierPathConstructionIsDeterministicAcrossTwoIndependentPasses() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .cubic(control1: ShapePathPoint(x: 3, y: 10), control2: ShapePathPoint(x: 7, y: 10), end: ShapePathPoint(x: 10, y: 0)),
            ], closed: true),
        ])
        let shape = bezierShape(path)
        let first = flatten(ShapeRenderer().path(for: shape))
        let second = flatten(ShapeRenderer().path(for: shape))
        XCTAssertEqual(first, second)
    }

    // MARK: - Fillability (kindIsFillable's own review point - reconsidered,
    // not changed, per this item's own doc comment; pinned here as a
    // guard test per doctrine rule 5).

    func testBezierShapeWithAnOpenSubpathStillFillsViaCoreGraphicsImplicitClose() {
        // An OPEN subpath's fill still produces a nonempty filled region
        // (CoreGraphics/PDF/SVG's own implicit-close-for-fill rule) -
        // asserted here by rendering into a tiny offscreen bitmap and
        // checking a pixel INSIDE the open triangle got painted.
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .line(ShapePathPoint(x: 20, y: 0)),
                .line(ShapePathPoint(x: 10, y: 20)),
                // No closing segment, and closed == false - yet a
                // filled triangle is still the expected visual result.
            ], closed: false),
        ])
        var shape = bezierShape(path, x: 0, y: 0)
        shape.geometry = ShapeGeometry(x: 0, y: 0, width: 20, height: 20)
        shape.fill = ShapeFill(colorHex: "#FF0000", opacity: 1)

        let width = 20, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return XCTFail("failed to create offscreen bitmap context")
        }
        renderer.render(shape, in: context)

        // Sample near the triangle's centroid ((10, 6.7) in the shape's
        // own y-down local space) - well inside the implicitly-closed
        // fill region.
        let sampleX = 10, sampleY = 7
        let offset = (sampleY * width + sampleX) * 4
        let alpha = pixels[offset + 3]
        XCTAssertGreaterThan(alpha, 0, "an open subpath must still fill (SVG/CoreGraphics implicit-close-for-fill)")
    }
}
