import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - ShapeMorphEngineTests
//
// Contract: item 2.18 (ratified minimal design: id-matched
// interpolation, AGENTS.md's product-surface-expansion section,
// decision 11) plus this wave's own task brief's named test list:
// geometry lerp at 0/0.5/1 against hand-computed values; matching-
// segment-count bezier path interpolation; mismatched-segment-count
// degrades to geometry-only; id mismatch is handled explicitly
// (this file's own ratified call: THROWS - see ShapeMorphEngine.swift's
// MorphError.idMismatch doc comment for the reasoning). Doctrine rule 9
// (math gets fixtures).

final class ShapeMorphEngineTests: DoctrineTestCase {

    private let sharedID = UUID()

    private func shape(_ id: UUID, x: Double, y: Double, width: Double, height: Double, rotation: Double = 0, path: ShapePath? = nil, kind: ShapeKind = .rect) -> Shape {
        Shape(id: id, kind: kind, geometry: ShapeGeometry(x: x, y: y, width: width, height: height, rotation: rotation), path: path)
    }

    // MARK: - id mismatch (ratified: throws)

    func testInterpolateThrowsIdMismatchWhenShapeIDsDiffer() {
        let a = shape(UUID(), x: 0, y: 0, width: 10, height: 10)
        let b = shape(UUID(), x: 10, y: 10, width: 20, height: 20)
        XCTAssertThrowsError(try ShapeMorphEngine.interpolate(from: a, to: b, progress: 0.5)) { error in
            guard case ShapeMorphEngine.MorphError.idMismatch(let from, let to) = error else {
                return XCTFail("expected .idMismatch, got \(error)")
            }
            XCTAssertEqual(from, a.id)
            XCTAssertEqual(to, b.id)
        }
    }

    // MARK: - Geometry lerp at 0 / 0.5 / 1 (hand-computed)

    func testGeometryLerpAtProgressZeroEqualsFromExactly() throws {
        let from = shape(sharedID, x: 0, y: 0, width: 100, height: 50, rotation: 0)
        let to = shape(sharedID, x: 100, y: 200, width: 300, height: 150, rotation: 90)
        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0)
        XCTAssertEqual(result.geometry.x, 0)
        XCTAssertEqual(result.geometry.y, 0)
        XCTAssertEqual(result.geometry.width, 100)
        XCTAssertEqual(result.geometry.height, 50)
        XCTAssertEqual(result.geometry.rotation, 0)
    }

    func testGeometryLerpAtProgressOneEqualsToExactly() throws {
        let from = shape(sharedID, x: 0, y: 0, width: 100, height: 50, rotation: 0)
        let to = shape(sharedID, x: 100, y: 200, width: 300, height: 150, rotation: 90)
        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 1)
        XCTAssertEqual(result.geometry.x, 100)
        XCTAssertEqual(result.geometry.y, 200)
        XCTAssertEqual(result.geometry.width, 300)
        XCTAssertEqual(result.geometry.height, 150)
        XCTAssertEqual(result.geometry.rotation, 90)
    }

    func testGeometryLerpAtProgressHalfIsTheArithmeticMidpoint() throws {
        let from = shape(sharedID, x: 0, y: 0, width: 100, height: 50, rotation: 0)
        let to = shape(sharedID, x: 100, y: 200, width: 300, height: 150, rotation: 90)
        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertEqual(result.geometry.x, 50)
        XCTAssertEqual(result.geometry.y, 100)
        XCTAssertEqual(result.geometry.width, 200)
        XCTAssertEqual(result.geometry.height, 100)
        XCTAssertEqual(result.geometry.rotation, 45)
    }

    func testProgressIsClampedToZeroOneRange() throws {
        let from = shape(sharedID, x: 0, y: 0, width: 100, height: 100)
        let to = shape(sharedID, x: 100, y: 100, width: 200, height: 200)
        let below = try ShapeMorphEngine.interpolate(from: from, to: to, progress: -5)
        let above = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 5)
        XCTAssertEqual(below.geometry.x, 0)
        XCTAssertEqual(above.geometry.x, 100)
    }

    // MARK: - Discrete fields cross over at the p < 0.5 threshold

    func testDiscreteFieldsUseFromBelowHalfAndToAtOrAboveHalf() throws {
        var from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, kind: .rect)
        from.fill = ShapeFill(colorHex: "#111111")
        var to = shape(sharedID, x: 10, y: 10, width: 20, height: 20, kind: .ellipse)
        to.fill = ShapeFill(colorHex: "#222222")

        let justBelow = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.49)
        XCTAssertEqual(justBelow.kind, .rect)
        XCTAssertEqual(justBelow.fill?.colorHex, ColorRef.literal("#111111"))

        let atHalf = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertEqual(atHalf.kind, .ellipse)
        XCTAssertEqual(atHalf.fill?.colorHex, ColorRef.literal("#222222"))
    }

    func testFlipHAndFlipVCrossOverAtTheSameHalfThreshold() throws {
        var from = shape(sharedID, x: 0, y: 0, width: 10, height: 10)
        from.geometry.flipH = false
        from.geometry.flipV = true
        var to = shape(sharedID, x: 0, y: 0, width: 10, height: 10)
        to.geometry.flipH = true
        to.geometry.flipV = false

        let justBelow = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.4)
        XCTAssertEqual(justBelow.geometry.flipH, false)
        XCTAssertEqual(justBelow.geometry.flipV, true)

        let atOrAbove = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.6)
        XCTAssertEqual(atOrAbove.geometry.flipH, true)
        XCTAssertEqual(atOrAbove.geometry.flipV, false)
    }

    // MARK: - anchorX/anchorY: both-nil stays nil; either-set resolves + lerps

    func testAnchorStaysNilWhenNeitherKeyframeSetIt() throws {
        let from = shape(sharedID, x: 0, y: 0, width: 100, height: 100)
        let to = shape(sharedID, x: 0, y: 0, width: 200, height: 200)
        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertNil(result.geometry.anchorX)
        XCTAssertNil(result.geometry.anchorY)
    }

    func testAnchorResolvesAndLerpsWhenEitherKeyframeSetIt() throws {
        var from = shape(sharedID, x: 0, y: 0, width: 100, height: 100)
        from.geometry.anchorX = 10
        from.geometry.anchorY = 10
        let to = shape(sharedID, x: 0, y: 0, width: 100, height: 100) // anchor nil -> resolves to center (50, 50)
        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertEqual(result.geometry.anchorX, 30) // lerp(10, 50, 0.5)
        XCTAssertEqual(result.geometry.anchorY, 30)
    }

    // MARK: - Path interpolation: matching subpath/segment shape

    func testMatchingSegmentCountBezierPathInterpolationProducesExpectedIntermediatePath() throws {
        let fromPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false),
        ])
        let toPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 20, y: 20))], closed: false),
        ])
        let from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: fromPath, kind: .bezier)
        let to = shape(sharedID, x: 0, y: 0, width: 20, height: 20, path: toPath, kind: .bezier)

        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)

        let expected = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 15, y: 10))], closed: false),
        ])
        XCTAssertEqual(result.path, expected)
    }

    func testMismatchedSegmentCountDegradesToGeometryOnlyLerpNotACrashNotAWrongShapedPath() throws {
        let fromPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false),
        ])
        let toPath = ShapePath(subpaths: [
            ShapeSubpath(
                segments: [
                    .move(ShapePathPoint(x: 0, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 0)),
                    .line(ShapePathPoint(x: 10, y: 10)),
                ],
                closed: false
            ),
        ])
        let from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: fromPath, kind: .bezier)
        let to = shape(sharedID, x: 0, y: 0, width: 20, height: 20, path: toPath, kind: .bezier)

        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)

        XCTAssertNil(result.path, "mismatched segment counts must degrade to a nil (geometry-only) path, never a wrong-shaped one")
        // Geometry itself still interpolates normally.
        XCTAssertEqual(result.geometry.width, 15)
    }

    func testMismatchedSubpathCountDegradesToGeometryOnlyLerp() throws {
        let fromPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false),
        ])
        let toPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false),
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 5, y: 5)), .line(ShapePathPoint(x: 15, y: 5))], closed: false),
        ])
        let from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: fromPath, kind: .bezier)
        let to = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: toPath, kind: .bezier)

        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertNil(result.path)
    }

    func testMismatchedSegmentCaseAtSameIndexDegradesToGeometryOnlyLerp() throws {
        // Same segment COUNT (2), but segment 1 is `.line` in `from` and
        // `.quad` in `to` - cannot lerp a line's single endpoint against
        // a quad's extra control point without inventing data.
        let fromPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false),
        ])
        let toPath = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .quad(control: ShapePathPoint(x: 5, y: 5), end: ShapePathPoint(x: 10, y: 0))], closed: false),
        ])
        let from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: fromPath, kind: .bezier)
        let to = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: toPath, kind: .bezier)

        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertNil(result.path)
    }

    func testEitherPathMissingDegradesToGeometryOnlyLerp() throws {
        let toPath = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))])])
        let from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: nil, kind: .bezier)
        let to = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: toPath, kind: .bezier)

        let result = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.5)
        XCTAssertNil(result.path)
    }

    // MARK: - Closed flag crosses over with the same p < 0.5 threshold

    func testClosedFlagCrossesOverAtTheSameHalfThresholdAsOtherDiscreteFields() throws {
        let fromPath = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false)])
        let toPath = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: true)])
        let from = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: fromPath, kind: .bezier)
        let to = shape(sharedID, x: 0, y: 0, width: 10, height: 10, path: toPath, kind: .bezier)

        let below = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.2)
        XCTAssertEqual(below.path?.subpaths.first?.closed, false)
        let atOrAbove = try ShapeMorphEngine.interpolate(from: from, to: to, progress: 0.8)
        XCTAssertEqual(atOrAbove.path?.subpaths.first?.closed, true)
    }
}
