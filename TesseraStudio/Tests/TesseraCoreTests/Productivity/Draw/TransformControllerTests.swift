import XCTest
@testable import TesseraCore

/// `TransformController` (P1 1.16): the 8-handle + rotation-handle
/// resize/rotate solve. Precision assertions use 1e-9 per the
/// deliverable's test contract; the actual float error observed is
/// far smaller (~1e-13, ULP-level), but 1e-9 is the documented bar.
final class TransformControllerTests: XCTestCase {

    private let tolerance = 1e-9

    private func assertPointsEqual(_ a: CGPoint, _ b: CGPoint, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(a.x), Double(b.x), accuracy: tolerance, "\(message) (x)", file: file, line: line)
        XCTAssertEqual(Double(a.y), Double(b.y), accuracy: tolerance, "\(message) (y)", file: file, line: line)
    }

    // MARK: - Handle model

    func testNineHandlesTotal() {
        XCTAssertEqual(TransformController.Handle.allCases.count, 9)
    }

    func testOppositeHandlesPairUpAndRotationHasNone() {
        XCTAssertEqual(TransformController.Handle.topLeft.opposite, .bottomRight)
        XCTAssertEqual(TransformController.Handle.bottomRight.opposite, .topLeft)
        XCTAssertEqual(TransformController.Handle.top.opposite, .bottom)
        XCTAssertEqual(TransformController.Handle.left.opposite, .right)
        XCTAssertNil(TransformController.Handle.rotation.opposite)
    }

    func testHandlePositionsUnrotated() {
        let g = ShapeGeometry(x: 0, y: 0, width: 100, height: 50)
        assertPointsEqual(TransformController.position(of: .topLeft, in: g), CGPoint(x: 0, y: 0))
        assertPointsEqual(TransformController.position(of: .topRight, in: g), CGPoint(x: 100, y: 0))
        assertPointsEqual(TransformController.position(of: .bottomRight, in: g), CGPoint(x: 100, y: 50))
        assertPointsEqual(TransformController.position(of: .bottomLeft, in: g), CGPoint(x: 0, y: 50))
        assertPointsEqual(TransformController.position(of: .top, in: g), CGPoint(x: 50, y: 0))
        assertPointsEqual(TransformController.position(of: .right, in: g), CGPoint(x: 100, y: 25))
        assertPointsEqual(TransformController.position(of: .bottom, in: g), CGPoint(x: 50, y: 50))
        assertPointsEqual(TransformController.position(of: .left, in: g), CGPoint(x: 0, y: 25))
    }

    func testRotationHandleSitsAboveTopCenterBeforeRotation() {
        let g = ShapeGeometry(x: 0, y: 0, width: 100, height: 50)
        let expected = CGPoint(x: 50, y: -TransformController.rotationHandleOffset)
        assertPointsEqual(TransformController.position(of: .rotation, in: g), expected)
    }

    func testHandlePositionsRespectRotation() {
        // A 100x100 square centered at (50,50), rotated 90 degrees
        // clockwise about its own center: topRight (100,0) should swing
        // to where bottomRight (100,100) used to be.
        let g = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 90, anchorX: 50, anchorY: 50)
        assertPointsEqual(TransformController.position(of: .topRight, in: g), CGPoint(x: 100, y: 100))
    }

    // MARK: - Rotated-resize solve: opposite handle stays world-fixed

    /// The deliverable's required test: construct a rotated shape,
    /// drag a corner handle, assert the OPPOSITE corner's world
    /// position is unchanged to within 1e-9 - the unrotate-resize-
    /// solve's whole point.
    func testOppositeCornerStaysWorldFixedAcrossRotatedResize() {
        let start = ShapeGeometry(x: 20, y: 30, width: 100, height: 60, rotation: 37, anchorX: 40, anchorY: 25)
        let oppositeBefore = TransformController.position(of: .topLeft, in: start)

        let result = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: CGVector(dx: 15, dy: -8)
        )

        let oppositeAfter = TransformController.position(of: .topLeft, in: result)
        assertPointsEqual(oppositeBefore, oppositeAfter, "opposite corner must stay world-fixed")
    }

    /// The harder direction: dragging a handle that moves the
    /// geometry's own origin (`topLeft`/`top`/`left`-side handles).
    /// The render pivot is `origin + anchorOffset`, so it shifts
    /// whenever origin does - the solve has to correct for that, not
    /// just hold width/height's opposite edge fixed the way an
    /// unrotated resize would.
    func testOppositeCornerStaysWorldFixedWhenDraggingAnOriginMovingHandle() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 90, anchorX: 50, anchorY: 50)
        let oppositeBefore = TransformController.position(of: .bottomRight, in: start)

        let result = TransformController.resize(
            handle: .topLeft,
            startGeometry: start,
            worldDelta: CGVector(dx: -40, dy: -40)
        )

        let oppositeAfter = TransformController.position(of: .bottomRight, in: result)
        assertPointsEqual(oppositeBefore, oppositeAfter, "opposite corner must stay world-fixed even when origin moves")
    }

    /// Same property holds with the DEFAULT (floating-center) pivot,
    /// not just an explicit `anchorX`/`anchorY` - `resize(...)` solves
    /// against whatever the anchor resolves to, so a shape that has
    /// never had its pivot set is no less precise.
    func testOppositeCornerStaysWorldFixedWithDefaultFloatingAnchor() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 45)
        XCTAssertNil(start.anchorX)
        let oppositeBefore = TransformController.position(of: .bottomRight, in: start)

        let result = TransformController.resize(
            handle: .topLeft,
            startGeometry: start,
            worldDelta: CGVector(dx: -20, dy: -20)
        )

        let oppositeAfter = TransformController.position(of: .bottomRight, in: result)
        assertPointsEqual(oppositeBefore, oppositeAfter, "opposite corner must stay world-fixed with a floating anchor too")
    }

    /// The dragged handle itself must land under the cursor, not just
    /// the opposite corner - both are the same pivot-consistent solve.
    func testDraggedHandleTracksTheCursorUnderRotation() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 90, anchorX: 50, anchorY: 50)
        let delta = CGVector(dx: -40, dy: -40)
        let expectedWorld = CGPoint(
            x: TransformController.position(of: .topLeft, in: start).x + delta.dx,
            y: TransformController.position(of: .topLeft, in: start).y + delta.dy
        )

        let result = TransformController.resize(handle: .topLeft, startGeometry: start, worldDelta: delta)

        assertPointsEqual(TransformController.position(of: .topLeft, in: result), expectedWorld)
    }

    // MARK: - Rotation pivot contract

    func testResizeNeverWritesAnchorXOrY() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 30, anchorX: 12, anchorY: 88)
        let result = TransformController.resize(handle: .bottomRight, startGeometry: start, worldDelta: CGVector(dx: 10, dy: 10))
        XCTAssertEqual(result.anchorX, 12)
        XCTAssertEqual(result.anchorY, 88)
    }

    func testResizeNeverWritesAnchorWhenUnset() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 30)
        let result = TransformController.resize(handle: .bottomRight, startGeometry: start, worldDelta: CGVector(dx: 10, dy: 10))
        XCTAssertNil(result.anchorX)
        XCTAssertNil(result.anchorY)
    }

    func testRotateOnlyChangesRotation() {
        let start = ShapeGeometry(x: 5, y: 5, width: 100, height: 100, rotation: 10, anchorX: 50, anchorY: 50, flipH: true)
        let result = TransformController.rotate(
            startGeometry: start,
            startPoint: CGPoint(x: 55, y: 5),
            currentPoint: CGPoint(x: 105, y: 55)
        )
        XCTAssertEqual(result.x, start.x)
        XCTAssertEqual(result.y, start.y)
        XCTAssertEqual(result.width, start.width)
        XCTAssertEqual(result.height, start.height)
        XCTAssertEqual(result.anchorX, start.anchorX)
        XCTAssertEqual(result.anchorY, start.anchorY)
        XCTAssertEqual(result.flipH, start.flipH)
        XCTAssertEqual(result.flipV, start.flipV)
        XCTAssertNotEqual(result.rotation, start.rotation)
    }

    // MARK: - Modifier keys

    func testOptionKeyResizesAboutTheShapesOwnCenter() {
        // anchorX/Y are set to exactly the frame's own center here, so
        // the render pivot and the resize-center coincide - the two
        // are still independent concepts in general (see the
        // rotation-pivot contract), this just keeps the fixture
        // simple to reason about.
        let start = ShapeGeometry(x: 5, y: 5, width: 60, height: 60, rotation: 60, anchorX: 30, anchorY: 30)
        let centerLocalBefore = CGPoint(x: start.x + start.width / 2, y: start.y + start.height / 2)
        let pivot = CGPoint(x: start.x + start.anchorPoint.x, y: start.y + start.anchorPoint.y)
        let centerWorldBefore = rotatedForTest(centerLocalBefore, around: pivot, byDegrees: start.rotation)

        // A delta that scales the bottomRight handle's world position
        // outward from the pivot by 1.5x. Rotation is linear, so this
        // is EXACTLY equivalent to scaling the local (unrotated) 30,30
        // offset by 1.5x too - both dimensions grow by a known,
        // rotation-independent factor, unlike an arbitrary world delta
        // (which at 60 degrees can shrink one local axis while growing
        // the other).
        let bottomRightWorldBefore = TransformController.position(of: .bottomRight, in: start)
        let delta = CGVector(dx: 0.5 * (bottomRightWorldBefore.x - pivot.x), dy: 0.5 * (bottomRightWorldBefore.y - pivot.y))

        let result = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: delta,
            options: TransformController.ResizeOptions(centerAnchored: true)
        )

        let centerLocalAfter = CGPoint(x: result.x + result.width / 2, y: result.y + result.height / 2)
        let pivotAfter = CGPoint(x: result.x + result.anchorPoint.x, y: result.y + result.anchorPoint.y)
        let centerWorldAfter = rotatedForTest(centerLocalAfter, around: pivotAfter, byDegrees: result.rotation)

        XCTAssertEqual(Double(centerWorldBefore.x), Double(centerWorldAfter.x), accuracy: tolerance)
        XCTAssertEqual(Double(centerWorldBefore.y), Double(centerWorldAfter.y), accuracy: tolerance)
        // Center-anchored growth is symmetric: both dimensions grew by
        // the same 1.5x factor.
        XCTAssertEqual(result.width / start.width, 1.5, accuracy: tolerance)
        XCTAssertEqual(result.height / start.height, 1.5, accuracy: tolerance)
    }

    func testShiftKeyPreservesAspectRatioOnACornerHandle() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 50)
        let result = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: CGVector(dx: 50, dy: 5),
            options: TransformController.ResizeOptions(aspectLocked: true)
        )
        XCTAssertEqual(result.width / result.height, start.width / start.height, accuracy: 1e-9)
    }

    func testShiftKeyOnAnEdgeHandleExtendsThePerpendicularAxisSymmetrically() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 50)
        let result = TransformController.resize(
            handle: .right,
            startGeometry: start,
            worldDelta: CGVector(dx: 50, dy: 0),
            options: TransformController.ResizeOptions(aspectLocked: true)
        )
        XCTAssertEqual(result.width / result.height, start.width / start.height, accuracy: 1e-9)
        // The un-dragged axis grows around the ORIGINAL center, not
        // pinned to the original top edge.
        let originalCenterY = start.y + start.height / 2
        XCTAssertEqual(result.y + result.height / 2, originalCenterY, accuracy: 1e-9)
    }

    // MARK: - Plain resize: axis independence

    func testEdgeHandleDoesNotChangeThePerpendicularAxis() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 50)
        let result = TransformController.resize(handle: .right, startGeometry: start, worldDelta: CGVector(dx: 20, dy: 0))
        XCTAssertEqual(result.height, start.height)
        XCTAssertEqual(result.y, start.y)
        XCTAssertGreaterThan(result.width, start.width)
    }

    // MARK: - Drag-past-opposite (flip)

    func testDraggingRightHandlePastLeftEdgeFlipsHorizontallyInsteadOfGoingNegative() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(start.flipH)

        let result = TransformController.resize(handle: .right, startGeometry: start, worldDelta: CGVector(dx: -150, dy: 0))

        XCTAssertGreaterThanOrEqual(result.width, 0)
        XCTAssertTrue(result.flipH)
        XCTAssertFalse(result.flipV)
    }

    func testDraggingBottomHandlePastTopEdgeFlipsVerticallyInsteadOfGoingNegative() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100)
        let result = TransformController.resize(handle: .bottom, startGeometry: start, worldDelta: CGVector(dx: 0, dy: -150))

        XCTAssertGreaterThanOrEqual(result.height, 0)
        XCTAssertTrue(result.flipV)
        XCTAssertFalse(result.flipH)
    }

    func testDraggingBackPastTheCrossingUnflips() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, flipH: true)
        // From a starting geometry that's already flipped, a drag that
        // crosses back the OTHER way toggles flipH off again - the
        // flag records net crossings for THIS gesture, computed fresh
        // from `startGeometry` each call (a live-updating caller
        // recomputes from the same gesture-start geometry every frame,
        // not incrementally).
        let result = TransformController.resize(handle: .right, startGeometry: start, worldDelta: CGVector(dx: -150, dy: 0))
        XCTAssertFalse(result.flipH)
    }

    func testHandleNotOnTheAffectedAxisNeverTogglesTheOtherFlip() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100)
        let result = TransformController.resize(handle: .right, startGeometry: start, worldDelta: CGVector(dx: -150, dy: 0))
        XCTAssertFalse(result.flipV, "dragging a purely-horizontal handle must never toggle flipV")
    }

    // MARK: - Multi-shape gesture: one call, one array, one undo unit

    /// The deliverable's "one drag = one undo unit" contract is a
    /// caller-side concern (`ReceiptUndoManager.group(_:)` over the
    /// receipts `DrawingStore.setGeometry` produces at commit time) -
    /// not something this pure type performs itself. What this type
    /// DOES guarantee is that a multi-shape drag composes into ONE
    /// array via a plain `.map`, with no store write hiding inside
    /// `resize(...)` - so the caller has exactly one place (this
    /// array) to hand to `ReceiptUndoManager.group(_:)`, never a
    /// series of individual commits. This test asserts that shape:
    /// one `.map` call over a multi-selection returns every shape's
    /// proposed geometry, each independently keeping its OWN opposite
    /// handle world-fixed.
    func testMultiShapeDragComposesIntoOneArrayEachShapeIndependentlyCorrect() {
        let shapes: [(id: UUID, geometry: ShapeGeometry)] = [
            (UUID(), ShapeGeometry(x: 0, y: 0, width: 50, height: 50, rotation: 0)),
            (UUID(), ShapeGeometry(x: 200, y: 200, width: 40, height: 80, rotation: 30, anchorX: 20, anchorY: 40)),
        ]
        let opposites = shapes.map { TransformController.position(of: .topLeft, in: $0.geometry) }

        let results = shapes.map { entry in
            (id: entry.id, geometry: TransformController.resize(handle: .bottomRight, startGeometry: entry.geometry, worldDelta: CGVector(dx: 5, dy: -3)))
        }

        XCTAssertEqual(results.count, shapes.count)
        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.id, shapes[index].id)
            let oppositeAfter = TransformController.position(of: .topLeft, in: result.geometry)
            XCTAssertEqual(Double(opposites[index].x), Double(oppositeAfter.x), accuracy: tolerance)
            XCTAssertEqual(Double(opposites[index].y), Double(oppositeAfter.y), accuracy: tolerance)
        }
    }

    // MARK: - Test helper

    private func rotatedForTest(_ point: CGPoint, around pivot: CGPoint, byDegrees degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let theta = degrees * .pi / 180
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let cosT = CGFloat(cos(theta))
        let sinT = CGFloat(sin(theta))
        return CGPoint(x: pivot.x + dx * cosT - dy * sinT, y: pivot.y + dx * sinT + dy * cosT)
    }
}
