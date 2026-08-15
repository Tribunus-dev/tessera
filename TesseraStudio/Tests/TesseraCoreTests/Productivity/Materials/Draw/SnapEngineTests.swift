import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - SnapEngineTests
//
// Contract source: SnapEngine.swift's own doc comments, which state the
// design contract directly (studio-expansion-design-refinement-2026-08-14.md
// Draw cluster item 1.17): threshold = 8.0 / zoomScale (screen-space,
// "the tldraw-evidenced standard"); SnapResult.identity is what "nothing
// within threshold" returns; rotation snaps to 15-degree multiples.
// Doctrine rule 9: hand-computed fixture cases from the spec formula,
// plus a property test.

final class SnapEngineTests: DoctrineTestCase {

    // MARK: Position snap - fixtures (hand-computed against the spec formula)

    /// Canvas 800x600 (SnapContext.build's page-edge/center targets are
    /// {0, 400, 800} on x and {0, 300, 600} on y). A shape proposed at
    /// x=2 sits 2 world units from the left page edge and exactly on the
    /// top page edge (y=300 is NOT top - recompute: box.minY == 300
    /// equals the y-center target, not top). zoomScale=1 => threshold=8.
    func testSnapWithinThresholdLandsExactlyOnThePageEdgeAndCenterTargets() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 800, height: 600))
        let proposed = ShapeGeometry(x: 2, y: 300, width: 50, height: 50)

        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        // x: box.minX=2 is 2 units from the left-edge target (0); within
        // the 8-unit threshold, nearer than the 400/800 targets.
        XCTAssertEqual(result.dx, -2, accuracy: 1e-9)
        // y: box.minY=300 lands EXACTLY on the vertical-center target
        // (canvasSize.height / 2 == 300).
        XCTAssertEqual(result.dy, 0, accuracy: 1e-9)
        XCTAssertEqual(result.guides.count, 2, "both axes resolved within threshold, so both produce an alignment guide")
    }

    func testSnapOutsideThresholdOnBothAxesReturnsIdentity() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 800, height: 600))
        // Center of the canvas, far (>8 units) from every page edge/center
        // target on both axes.
        let proposed = ShapeGeometry(x: 150, y: 150, width: 10, height: 10)

        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result, SnapResult.identity)
    }

    func testSnapThresholdScalesInverselyWithZoom() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 800, height: 600))
        // 20 units from the left edge: outside the zoomScale=1 threshold
        // (8) but inside the zoomScale=0.25 threshold (8 / 0.25 = 32).
        let proposed = ShapeGeometry(x: 20, y: 300, width: 10, height: 10)

        let atFullZoom = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)
        let atQuarterZoom = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 0.25)

        XCTAssertEqual(atFullZoom.dx, 0, accuracy: 1e-9, "20 world units is outside the zoomScale=1 (threshold 8) window on x")
        XCTAssertEqual(atQuarterZoom.dx, -20, accuracy: 1e-9, "the same 20-unit gap is within the zoomScale=0.25 (threshold 32) window")
    }

    func testSnapWithDegenerateZoomScaleNeverProducesNonFiniteResult() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 800, height: 600))
        let proposed = ShapeGeometry(x: 5, y: 5, width: 10, height: 10)

        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 0)

        XCTAssertTrue(result.dx.isFinite, "zoomScale <= 0 must be guarded, not produce an infinite/NaN threshold")
        XCTAssertTrue(result.dy.isFinite)
    }

    // MARK: Object snap

    func testSnapMatchesAnotherShapesEdgeWithinThreshold() {
        var target = Shape(kind: .rect, geometry: ShapeGeometry(x: 200, y: 200, width: 100, height: 100))
        target.layerID = nil
        let context = SnapContext.build(shapes: [target], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 800, height: 600))

        // Dragged shape's left edge (box.minX) sits at 303 - 3 units from
        // the target's right edge (200 + 100 = 300).
        let proposed = ShapeGeometry(x: 303, y: 400, width: 40, height: 40)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, -3, accuracy: 1e-9)
        guard case .alignment(_, let position, _, let matchedShapeID)? = result.guides.first(where: {
            if case .alignment(let axis, _, _, _) = $0 { return axis == .x }
            return false
        }) else {
            return XCTFail("expected an x-axis alignment guide")
        }
        XCTAssertEqual(position, 300, accuracy: 1e-9)
        XCTAssertEqual(matchedShapeID, target.id)
    }

    func testSnapContextExcludesSelectedShapesFromCandidates() {
        var selected = Shape(kind: .rect, geometry: ShapeGeometry(x: 200, y: 200, width: 100, height: 100))
        selected.layerID = nil
        let context = SnapContext.build(
            shapes: [selected],
            selectedShapeIDs: [selected.id],
            layers: [],
            canvasSize: CanvasSize(width: 800, height: 600)
        )
        // Same near-edge setup as the object-snap test above, but the
        // only candidate shape is excluded via selectedShapeIDs, so this
        // must fall through to "outside threshold" (no page edge/center
        // target is anywhere near x=303).
        let proposed = ShapeGeometry(x: 303, y: 400, width: 40, height: 40)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, 0, accuracy: 1e-9, "a shape must never snap to itself or its own multi-selection")
    }

    // MARK: Rotation snap - fixtures

    func testSnapRotationWithinThresholdSnapsToNearest15DegreeMultiple() {
        // nearest 15-multiple of 12 is 15 (delta 3); handleDistance=100,
        // zoomScale=1 => angularThreshold = atan(8/100)*180/pi ~= 4.57deg,
        // comfortably above the 3-degree delta needed.
        let result = SnapEngine.snapRotation(12, handleDistance: 100, zoomScale: 1)
        XCTAssertEqual(result.degrees, 15, accuracy: 1e-9)
        XCTAssertEqual(result.guide, .rotation(degrees: 15))
    }

    func testSnapRotationOutsideThresholdReturnsOriginalDegreesUnchangedWithNoGuide() {
        // nearest 15-multiple of 5 is 0 (delta 5); handleDistance=1000
        // makes the angular threshold tiny (~0.46deg), well under 5.
        let result = SnapEngine.snapRotation(5, handleDistance: 1000, zoomScale: 1)
        XCTAssertEqual(result.degrees, 5, accuracy: 1e-9)
        XCTAssertNil(result.guide)
    }

    // MARK: Property tests (rule 9)

    func testSnapRotationResultIsAlwaysEitherTheOriginalDegreesOrA15DegreeMultiple() {
        // Small handleDistance => huge angular threshold => every case
        // below snaps; verifies the property "result is a 15-multiple"
        // holds across a spread of inputs, not just the one hand-picked
        // fixture above.
        for degrees in stride(from: -40.0, through: 40.0, by: 3.7) {
            let result = SnapEngine.snapRotation(degrees, handleDistance: 0.001, zoomScale: 1)
            let remainder = result.degrees.truncatingRemainder(dividingBy: 15)
            XCTAssertEqual(min(abs(remainder), abs(abs(remainder) - 15)), 0, accuracy: 1e-6, "\(result.degrees) is not a 15-degree multiple")
        }
    }

    func testSnapIdentityHasZeroDeltaAndNoGuides() {
        XCTAssertEqual(SnapResult.identity.dx, 0)
        XCTAssertEqual(SnapResult.identity.dy, 0)
        XCTAssertTrue(SnapResult.identity.guides.isEmpty)
    }
}
