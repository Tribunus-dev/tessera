import Foundation
import XCTest
@testable import TesseraCore

/// `SnapEngine` (P1 1.17): pure snap-to-grid / snap-to-object /
/// alignment-guide logic layered on top of `Shape.geometry` and
/// `SnapContext`'s once-per-gesture candidate set.
final class SnapEngineTests: XCTestCase {

    private let defaultCanvas = CanvasSize(width: 800, height: 600)

    private func makeShape(
        x: Double, y: Double, width: Double, height: Double,
        rotation: Double = 0, layerID: UUID? = nil
    ) -> Shape {
        Shape(kind: .rect, geometry: ShapeGeometry(x: x, y: y, width: width, height: height, rotation: rotation), layerID: layerID)
    }

    // MARK: - Tier 1: object edge/center snap

    /// A proposed move within threshold of a neighbor's edge lands
    /// EXACTLY on that edge, with a matching `.alignment` guide naming
    /// the neighbor.
    func testWithinThresholdSnapsExactlyToNeighborEdge() {
        let neighbor = makeShape(x: 100, y: 0, width: 50, height: 50)
        let context = SnapContext.build(shapes: [neighbor], selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas)

        // Dragged minX = 155, 5pt right of the neighbor's maxX (150) -
        // within the zoomScale=1 threshold of 8. y is placed far from
        // every page/shape target so only the x axis snaps.
        let proposed = ShapeGeometry(x: 155, y: 200, width: 50, height: 50)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, -5)
        XCTAssertEqual(result.dy, 0)
        XCTAssertEqual(proposed.x + result.dx, 150)

        XCTAssertEqual(result.guides.count, 1)
        guard case .alignment(let axis, let position, _, let matchedShapeID) = result.guides[0] else {
            return XCTFail("expected an alignment guide")
        }
        XCTAssertEqual(axis, .x)
        XCTAssertEqual(position, 150)
        XCTAssertEqual(matchedShapeID, neighbor.id)
    }

    /// A proposed move within threshold of a page edge snaps to it,
    /// with `matchedShapeID == nil` distinguishing "the page" from a
    /// shape match.
    func testWithinThresholdSnapsExactlyToPageEdge() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas)

        // minX = 3, 3pt right of the page's left edge (0).
        let proposed = ShapeGeometry(x: 3, y: 250, width: 50, height: 40)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, -3)
        XCTAssertEqual(result.dy, 0)
        XCTAssertEqual(proposed.x + result.dx, 0)

        XCTAssertEqual(result.guides.count, 1)
        guard case .alignment(let axis, let position, _, let matchedShapeID) = result.guides[0] else {
            return XCTFail("expected an alignment guide")
        }
        XCTAssertEqual(axis, .x)
        XCTAssertEqual(position, 0)
        XCTAssertNil(matchedShapeID)
    }

    /// Outside threshold: identity - no adjustment, no guides. The
    /// test contract's exact wording ("outside threshold = identity").
    func testOutsideThresholdIsIdentity() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas)

        // Nowhere near any page edge/center (0, 400, 800 on x; 0, 300,
        // 600 on y) at zoomScale=1's threshold of 8.
        let proposed = ShapeGeometry(x: 200, y: 200, width: 20, height: 20)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result, SnapResult.identity)
    }

    /// A selected, locked-layer, or hidden-layer shape is excluded
    /// from candidates - it contributes no snap targets at all. An
    /// unassigned shape, and one naming an unknown layer, both still
    /// count (banding with the implicit base layer, `LayerStore`'s own
    /// documented handling of that case).
    func testSelectedLockedAndHiddenShapesAreExcludedFromCandidates() {
        let locked = DrawLayer(name: "Locked", isLocked: true)
        let hidden = DrawLayer(name: "Hidden", isVisible: false)

        let selectedShape = makeShape(x: 0, y: 0, width: 10, height: 10)
        let lockedShape = makeShape(x: 20, y: 0, width: 10, height: 10, layerID: locked.id)
        let hiddenShape = makeShape(x: 40, y: 0, width: 10, height: 10, layerID: hidden.id)
        let unassignedShape = makeShape(x: 60, y: 0, width: 10, height: 10)
        let unknownLayerShape = makeShape(x: 80, y: 0, width: 10, height: 10, layerID: UUID())

        let context = SnapContext.build(
            shapes: [selectedShape, lockedShape, hiddenShape, unassignedShape, unknownLayerShape],
            selectedShapeIDs: [selectedShape.id],
            layers: [locked, hidden],
            canvasSize: defaultCanvas
        )

        XCTAssertEqual(Set(context.neighbors.map(\.id)), Set([unassignedShape.id, unknownLayerShape.id]))
    }

    /// `maxCandidates` truncates - the ~256 cap from the design
    /// contract, exercised here with a small cap so the test stays
    /// cheap.
    func testCandidatesAreTruncatedToMaxCandidates() {
        let shapes = (0..<5).map { i in makeShape(x: Double(i) * 100, y: 0, width: 10, height: 10) }
        let context = SnapContext.build(shapes: shapes, selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas, maxCandidates: 3)

        XCTAssertEqual(context.neighbors.count, 3)
        XCTAssertEqual(context.xTargets.count, 3 + 3 * 3) // page (3) + 3 per candidate shape
    }

    // MARK: - Tier 1: grid snap

    func testWithinThresholdSnapsExactlyToGridLine() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas, gridSpacing: 10)

        let proposed = ShapeGeometry(x: 203, y: 207, width: 20, height: 20)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, -3)
        XCTAssertEqual(result.dy, 3)
        XCTAssertEqual(proposed.x + result.dx, 200)
        XCTAssertEqual(proposed.y + result.dy, 210)

        XCTAssertTrue(result.guides.contains(.grid(axis: .x, position: 200)))
        XCTAssertTrue(result.guides.contains(.grid(axis: .y, position: 210)))
    }

    /// `gridSpacing == nil` (the default) never snaps to grid - only
    /// grid/page/object snap when a spacing is actually supplied.
    func testNoGridSpacingMeansNoGridSnap() {
        let context = SnapContext.build(shapes: [], selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas)
        let proposed = ShapeGeometry(x: 203, y: 207, width: 20, height: 20)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)
        XCTAssertEqual(result, SnapResult.identity)
    }

    // MARK: - Tier 2: gap / equal-spacing

    /// The dragged shape sits close to equidistant between two
    /// neighbors; the snap centers it EXACTLY, with a `.gap` guide
    /// naming both neighbors.
    func testNearEqualGapSnapsToExactlyEqualGaps() {
        let left = makeShape(x: 0, y: 0, width: 50, height: 50)
        let right = makeShape(x: 200, y: 0, width: 50, height: 50)
        let context = SnapContext.build(shapes: [left, right], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 2000, height: 2000))

        // Exact center (equal 55pt gaps each side) is x=105; 2pt off.
        let proposed = ShapeGeometry(x: 103, y: 0, width: 40, height: 50)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, 2)
        XCTAssertEqual(proposed.x + result.dx, 105)

        guard let gapGuide = result.guides.first(where: {
            if case .gap = $0 { return true } else { return false }
        }), case .gap(let axis, let gapSize, let between) = gapGuide else {
            return XCTFail("expected a gap guide")
        }
        XCTAssertEqual(axis, .x)
        XCTAssertEqual(gapSize, 55)
        XCTAssertEqual(between, [left.id, right.id])
    }

    /// A gap mismatch larger than threshold does not snap - the gap
    /// tier respects the same "adjustment must be within threshold"
    /// rule as tier 1.
    func testGapOutsideThresholdDoesNotSnap() {
        let left = makeShape(x: 0, y: 0, width: 50, height: 50)
        let right = makeShape(x: 200, y: 0, width: 50, height: 50)
        let context = SnapContext.build(shapes: [left, right], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 2000, height: 2000))

        // Center is x=105; 30pt off is well outside threshold.
        let proposed = ShapeGeometry(x: 75, y: 0, width: 40, height: 50)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, 0)
        XCTAssertFalse(result.guides.contains { if case .gap = $0 { return true } else { return false } })
    }

    /// A tier-1 match on an axis suppresses tier 2 on that SAME axis,
    /// even when a gap-equalizing move would also have been within
    /// threshold - the design contract's explicit priority order.
    func testTier1AlignmentTakesPriorityOverGapOnTheSameAxis() {
        let left = makeShape(x: 0, y: 0, width: 50, height: 50)
        let right = makeShape(x: 200, y: 0, width: 50, height: 50)
        // canvasWidth/2 == 105, 2pt from the proposed minX below - the
        // exact same distance the gap-equalizing move would also be,
        // so both tiers WOULD independently qualify; only tier 1 must
        // actually fire.
        let context = SnapContext.build(shapes: [left, right], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 210, height: 2000))

        let proposed = ShapeGeometry(x: 103, y: 0, width: 40, height: 50)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(result.dx, 2)
        let xGuides = result.guides.filter { guide in
            if case .alignment(let axis, _, _, _) = guide { return axis == .x }
            if case .gap(let axis, _, _) = guide { return axis == .x }
            return false
        }
        XCTAssertEqual(xGuides.count, 1)
        guard case .alignment(let axis, let position, _, let matchedShapeID) = xGuides[0] else {
            return XCTFail("expected tier 1's alignment guide, not a gap guide")
        }
        XCTAssertEqual(axis, .x)
        XCTAssertEqual(position, 105)
        XCTAssertNil(matchedShapeID)
    }

    // MARK: - Rotated-AABB

    /// A 100x100 square rotated 45 degrees about its own center
    /// bounds to a diamond whose AABB side is the diagonal
    /// (100 * sqrt(2)); snapping to that rotated-AABB's edge lands
    /// exactly on the analytically-known coordinate.
    func testRotatedShapeSnapsToItsRotatedAABBNotItsUnrotatedFrame() {
        let neighbor = makeShape(x: 0, y: 0, width: 100, height: 100, rotation: 45)
        let context = SnapContext.build(shapes: [neighbor], selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 2000, height: 2000))

        let expectedTargetX = 50 - 50 * 2.0.squareRoot()
        let proposed = ShapeGeometry(x: expectedTargetX + 5, y: 900, width: 10, height: 10)
        let result = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)

        XCTAssertEqual(proposed.x + result.dx, expectedTargetX, accuracy: 1e-6)
        XCTAssertEqual(result.dy, 0)

        guard let firstGuide = result.guides.first, case .alignment(let axis, _, _, let matchedShapeID) = firstGuide else {
            return XCTFail("expected an alignment guide")
        }
        XCTAssertEqual(axis, .x)
        XCTAssertEqual(matchedShapeID, neighbor.id)
    }

    // MARK: - zoomScale scales the threshold

    /// The same 5pt offset that snaps at zoomScale=1 (threshold 8) no
    /// longer does at zoomScale=4 (threshold 2) - `threshold = 8.0 /
    /// zoomScale` is screen-space, not world-space, so a higher zoom
    /// demands closer proximity in world points.
    func testHigherZoomShrinksTheWorldSpaceThreshold() {
        let neighbor = makeShape(x: 100, y: 0, width: 50, height: 50)
        let context = SnapContext.build(shapes: [neighbor], selectedShapeIDs: [], layers: [], canvasSize: defaultCanvas)
        let proposed = ShapeGeometry(x: 155, y: 200, width: 50, height: 50)

        let atZoom1 = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)
        XCTAssertEqual(atZoom1.dx, -5)

        let atZoom4 = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 4)
        XCTAssertEqual(atZoom4, SnapResult.identity)
    }

    // MARK: - Rotation snap

    func testRotationWithinThresholdSnapsExactlyToFifteenDegreeMultiple() {
        // handleDistance=100, zoomScale=1 -> angular threshold ~4.57deg
        // (atan(8/100) in degrees); 3deg off is comfortably inside it.
        let result = SnapEngine.snapRotation(12, handleDistance: 100, zoomScale: 1)
        XCTAssertEqual(result.degrees, 15)
        XCTAssertEqual(result.guide, .rotation(degrees: 15))
    }

    func testRotationOutsideThresholdIsIdentity() {
        // 7deg off the nearest multiple (15) is well outside the
        // ~4.57deg threshold from the same handleDistance/zoomScale.
        let result = SnapEngine.snapRotation(8, handleDistance: 100, zoomScale: 1)
        XCTAssertEqual(result.degrees, 8)
        XCTAssertNil(result.guide)
    }

    /// A shorter handle arm means the same screen-pixel threshold
    /// covers a WIDER angular window (closer to the pivot, a given
    /// screen distance sweeps a bigger angle) - the same 7deg offset
    /// that missed at handleDistance=100 snaps at handleDistance=10.
    func testShorterHandleDistanceWidensTheAngularThreshold() {
        let result = SnapEngine.snapRotation(8, handleDistance: 10, zoomScale: 1)
        XCTAssertEqual(result.degrees, 15)
        XCTAssertEqual(result.guide, .rotation(degrees: 15))
    }

    // MARK: - Perf sanity (not the hard <= 1ms bound, a smoke check)

    func testPerfSanityManyShapesStaysFast() {
        let shapes = (0..<1000).map { i -> Shape in
            let x = Double(i % 100) * 20
            let y = Double(i / 100) * 20
            return makeShape(x: x, y: y, width: 10, height: 10)
        }
        let context = SnapContext.build(shapes: shapes, selectedShapeIDs: [], layers: [], canvasSize: CanvasSize(width: 4000, height: 4000))
        XCTAssertEqual(context.neighbors.count, 256) // the default cap, even with 1000 candidates offered

        let start = Date()
        for i in 0..<200 {
            let proposed = ShapeGeometry(x: Double(i), y: Double(i), width: 10, height: 10)
            _ = SnapEngine.snap(context: context, proposedGeometry: proposed, zoomScale: 1)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0)
    }
}
