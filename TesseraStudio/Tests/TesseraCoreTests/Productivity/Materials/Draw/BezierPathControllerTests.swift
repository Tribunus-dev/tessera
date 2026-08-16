import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - BezierPathControllerTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md's
// "2.3 BezierPathController" section ("enum-driven edit state machine;
// one receipt per completed operation") plus the wave brief's own
// elaboration ("idle -> placing points -> dragging a control handle ->
// closing/finishing a subpath... the bend tool is the one network-era
// UX adopted"). Tests the PURE state machine only - no live
// `DrawingStore` call, per the brief's own instruction.

final class BezierPathControllerTests: DoctrineTestCase {

    // MARK: - Placing a new subpath

    func testBeginSubpathStartsANewSubpathAndEntersPlacingState() {
        let result = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 0, y: 0)), to: ShapePath(), state: .idle)
        XCTAssertEqual(result.path.subpaths.count, 1)
        XCTAssertEqual(result.path.subpaths[0].segments, [.move(ShapePathPoint(x: 0, y: 0))])
        XCTAssertEqual(result.state, .placingSubpath(subpathIndex: 0))
        XCTAssertNil(result.completedOperation, "placing a point is not a completed operation")
    }

    func testPlaceLinePointAppendsALineSegmentWhilePlacing() {
        let began = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 0, y: 0)), to: ShapePath(), state: .idle)
        let result = BezierPathController.apply(.placeLinePoint(ShapePathPoint(x: 10, y: 0)), to: began.path, state: began.state)
        XCTAssertEqual(result.path.subpaths[0].segments, [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))])
        XCTAssertEqual(result.state, began.state, "still placing - no operation completed yet")
        XCTAssertNil(result.completedOperation)
    }

    func testPlaceCubicPointAppendsACubicSegmentWhilePlacing() {
        let began = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 0, y: 0)), to: ShapePath(), state: .idle)
        let result = BezierPathController.apply(
            .placeCubicPoint(
                control1: ShapePathPoint(x: 3, y: 3), control2: ShapePathPoint(x: 7, y: 3), end: ShapePathPoint(x: 10, y: 0)
            ),
            to: began.path, state: began.state
        )
        XCTAssertEqual(
            result.path.subpaths[0].segments,
            [.move(ShapePathPoint(x: 0, y: 0)), .cubic(control1: ShapePathPoint(x: 3, y: 3), control2: ShapePathPoint(x: 7, y: 3), end: ShapePathPoint(x: 10, y: 0))]
        )
    }

    func testFinishSubpathEndsPlacingWithoutClosingAndCompletesOneOperation() {
        let began = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 0, y: 0)), to: ShapePath(), state: .idle)
        let placed = BezierPathController.apply(.placeLinePoint(ShapePathPoint(x: 10, y: 0)), to: began.path, state: began.state)
        let result = BezierPathController.apply(.finishSubpath, to: placed.path, state: placed.state)

        XCTAssertEqual(result.state, .idle)
        XCTAssertFalse(result.path.subpaths[0].closed)
        XCTAssertEqual(result.completedOperation, .subpathFinished(subpathIndex: 0, closed: false))
        // finishSubpath does not itself mutate the path further.
        XCTAssertEqual(result.path, placed.path)
    }

    func testCloseSubpathClosesAndCompletesOneOperation() {
        let began = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 0, y: 0)), to: ShapePath(), state: .idle)
        let placed = BezierPathController.apply(.placeLinePoint(ShapePathPoint(x: 10, y: 0)), to: began.path, state: began.state)
        let result = BezierPathController.apply(.closeSubpath, to: placed.path, state: placed.state)

        XCTAssertEqual(result.state, .idle)
        XCTAssertTrue(result.path.subpaths[0].closed)
        XCTAssertEqual(result.completedOperation, .subpathFinished(subpathIndex: 0, closed: true))
    }

    func testResumeSubpathReentersPlacingForAnExistingOpenSubpath() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: false),
        ])
        let result = BezierPathController.apply(.resumeSubpath(subpathIndex: 0), to: path, state: .idle)
        XCTAssertEqual(result.state, .placingSubpath(subpathIndex: 0))
        XCTAssertEqual(result.path, path, "resuming does not itself mutate the path")
    }

    func testResumeSubpathIsANoOpForAnAlreadyClosedSubpath() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))], closed: true),
        ])
        let result = BezierPathController.apply(.resumeSubpath(subpathIndex: 0), to: path, state: .idle)
        XCTAssertEqual(result.state, .idle)
        XCTAssertNil(result.completedOperation)
    }

    // MARK: - Out-of-sequence commands degrade to no-ops

    func testPlaceLinePointWhileIdleIsANoOp() {
        let path = ShapePath()
        let result = BezierPathController.apply(.placeLinePoint(ShapePathPoint(x: 1, y: 1)), to: path, state: .idle)
        XCTAssertEqual(result.path, path)
        XCTAssertEqual(result.state, .idle)
        XCTAssertNil(result.completedOperation)
    }

    func testBeginSubpathWhileAlreadyPlacingIsANoOp() {
        // beginSubpath is only defined FROM .idle in this state machine
        // (a second, unrelated .beginSubpath mid-edit is out of
        // sequence) - degrades rather than starting a THIRD subpath
        // implicitly.
        let began = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 0, y: 0)), to: ShapePath(), state: .idle)
        let result = BezierPathController.apply(.beginSubpath(at: ShapePathPoint(x: 5, y: 5)), to: began.path, state: began.state)
        XCTAssertEqual(result.path, began.path)
        XCTAssertEqual(result.state, began.state)
    }

    func testFinishSubpathWithAStaleSubpathIndexIsANoOp() {
        let result = BezierPathController.apply(.finishSubpath, to: ShapePath(), state: .placingSubpath(subpathIndex: 4))
        XCTAssertEqual(result.state, .idle)
        XCTAssertNil(result.completedOperation)
        XCTAssertEqual(result.path, ShapePath())
    }

    // MARK: - Dragging a placed vertex (SegmentPointSlot.endpoint)

    func testBeginDragPointOnAnEndpointEntersDraggingState() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))]),
        ])
        let result = BezierPathController.apply(
            .beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .endpoint), to: path, state: .idle
        )
        XCTAssertEqual(
            result.state,
            .draggingPoint(subpathIndex: 0, segmentIndex: 1, slot: .endpoint, originalSegment: .line(ShapePathPoint(x: 10, y: 0)))
        )
    }

    func testDragPointMovesTheEndpointOnEachFrameWithoutCompletingAnOperation() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))]),
        ])
        let began = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .endpoint), to: path, state: .idle)
        let dragged = BezierPathController.apply(.dragPoint(to: ShapePathPoint(x: 20, y: 5)), to: began.path, state: began.state)

        XCTAssertEqual(dragged.path.subpaths[0].segments[1], .line(ShapePathPoint(x: 20, y: 5)))
        XCTAssertNil(dragged.completedOperation, "intermediate drag frames never complete an operation")
        XCTAssertEqual(dragged.state, began.state)
    }

    func testEndDragPointCompletesOneOperationAndReturnsToIdle() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))]),
        ])
        let began = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .endpoint), to: path, state: .idle)
        let dragged = BezierPathController.apply(.dragPoint(to: ShapePathPoint(x: 20, y: 5)), to: began.path, state: began.state)
        let ended = BezierPathController.apply(.endDragPoint, to: dragged.path, state: dragged.state)

        XCTAssertEqual(ended.state, .idle)
        XCTAssertEqual(ended.completedOperation, .pointMoved(subpathIndex: 0, segmentIndex: 1, slot: .endpoint))
        XCTAssertEqual(ended.path, dragged.path, "endDragPoint does not further mutate the path")
    }

    func testCancelDragPointRestoresTheOriginalSegmentVerbatim() {
        let originalSegment = ShapePathSegment.line(ShapePathPoint(x: 10, y: 0))
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), originalSegment])])
        let began = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .endpoint), to: path, state: .idle)
        let dragged = BezierPathController.apply(.dragPoint(to: ShapePathPoint(x: 999, y: 999)), to: began.path, state: began.state)
        let cancelled = BezierPathController.apply(.cancelDragPoint, to: dragged.path, state: dragged.state)

        XCTAssertEqual(cancelled.path, path, "cancel restores the pre-drag path exactly")
        XCTAssertEqual(cancelled.state, .idle)
        XCTAssertNil(cancelled.completedOperation, "a cancelled drag never completes an operation")
    }

    // MARK: - Dragging a control handle (SegmentPointSlot != .endpoint) -
    // "dragging a control handle" is this design contract's own named
    // state; SegmentPointSlot is what distinguishes it from a plain
    // vertex drag within the SAME draggingPoint family (see that type's
    // own doc comment for the reasoning).

    func testBeginDragPointOnAQuadControlHandleEntersDraggingState() {
        let segment = ShapePathSegment.quad(control: ShapePathPoint(x: 5, y: 5), end: ShapePathPoint(x: 10, y: 0))
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), segment])])
        let result = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .quadControl), to: path, state: .idle)
        XCTAssertEqual(result.state, .draggingPoint(subpathIndex: 0, segmentIndex: 1, slot: .quadControl, originalSegment: segment))
    }

    func testDraggingAQuadControlHandleLeavesTheEndpointUntouched() {
        let segment = ShapePathSegment.quad(control: ShapePathPoint(x: 5, y: 5), end: ShapePathPoint(x: 10, y: 0))
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), segment])])
        let began = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .quadControl), to: path, state: .idle)
        let dragged = BezierPathController.apply(.dragPoint(to: ShapePathPoint(x: 99, y: 99)), to: began.path, state: began.state)

        guard case .quad(let control, let end) = dragged.path.subpaths[0].segments[1] else {
            return XCTFail("expected the segment to remain .quad")
        }
        XCTAssertEqual(control, ShapePathPoint(x: 99, y: 99))
        XCTAssertEqual(end, ShapePathPoint(x: 10, y: 0), "endpoint is a different slot - must be untouched")
    }

    func testBeginDragPointWithASlotThatDoesNotMatchTheSegmentKindIsANoOp() {
        // .cubicControl1 does not exist on a .line segment.
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 0))])])
        let result = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .cubicControl1), to: path, state: .idle)
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.path, path)
    }

    func testDraggingCubicControl1LeavesControl2AndEndUntouched() {
        let segment = ShapePathSegment.cubic(
            control1: ShapePathPoint(x: 3, y: 3), control2: ShapePathPoint(x: 7, y: 3), end: ShapePathPoint(x: 10, y: 0)
        )
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), segment])])
        let began = BezierPathController.apply(.beginDragPoint(subpathIndex: 0, segmentIndex: 1, slot: .cubicControl1), to: path, state: .idle)
        let dragged = BezierPathController.apply(.dragPoint(to: ShapePathPoint(x: -50, y: -50)), to: began.path, state: began.state)

        guard case .cubic(let c1, let c2, let end) = dragged.path.subpaths[0].segments[1] else {
            return XCTFail("expected the segment to remain .cubic")
        }
        XCTAssertEqual(c1, ShapePathPoint(x: -50, y: -50))
        XCTAssertEqual(c2, ShapePathPoint(x: 7, y: 3))
        XCTAssertEqual(end, ShapePathPoint(x: 10, y: 0))
    }

    // MARK: - The bend tool (line -> curve)

    func testBeginBendOnALineSegmentEntersBendingState() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 100, y: 0))]),
        ])
        let result = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        XCTAssertEqual(
            result.state,
            .bending(subpathIndex: 0, segmentIndex: 1, originalSegment: .line(ShapePathPoint(x: 100, y: 0)))
        )
    }

    func testBeginBendOnANonLineSegmentIsANoOp() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .quad(control: ShapePathPoint(x: 50, y: 50), end: ShapePathPoint(x: 100, y: 0))]),
        ])
        let result = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        XCTAssertEqual(result.state, .idle)
    }

    func testBeginBendOnTheLeadingMoveSegmentIsANoOp() {
        // segmentIndex 0 (the subpath's own .move) has no predecessor
        // point to bend a line FROM.
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0))])])
        let result = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 0), to: path, state: .idle)
        XCTAssertEqual(result.state, .idle)
    }

    func testBendConvertsTheLineSegmentIntoACubicCurve() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 100, y: 0))]),
        ])
        let began = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        let bent = BezierPathController.apply(.bend(offset: CGVector(dx: 0, dy: 20)), to: began.path, state: began.state)

        guard case .cubic(let c1, let c2, let end) = bent.path.subpaths[0].segments[1] else {
            return XCTFail("expected the .line to become a .cubic")
        }
        XCTAssertEqual(end, ShapePathPoint(x: 100, y: 0), "endpoint is preserved by the bend")
        XCTAssertEqual(c1.x, 100.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(c1.y, 20, accuracy: 1e-9)
        XCTAssertEqual(c2.x, 200.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(c2.y, 20, accuracy: 1e-9)
        XCTAssertNil(bent.completedOperation, "still mid-gesture - bend does not itself complete the operation")
    }

    func testBendWithZeroOffsetProducesACubicThatStillTracesTheStraightLine() {
        // The exact identity this file's own `bentSegment` doc comment
        // promises: control points at 1/3 and 2/3 along the line, with
        // no displacement, parametrize the SAME straight line.
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 10, y: 20)), .line(ShapePathPoint(x: 110, y: 220))]),
        ])
        let began = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        let bent = BezierPathController.apply(.bend(offset: .zero), to: began.path, state: began.state)

        guard case .cubic(let c1, let c2, _) = bent.path.subpaths[0].segments[1] else {
            return XCTFail("expected .cubic")
        }
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            let mt = 1 - t
            let start = ShapePathPoint(x: 10, y: 20)
            let end = ShapePathPoint(x: 110, y: 220)
            let bx = mt * mt * mt * start.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * end.x
            let by = mt * mt * mt * start.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * end.y
            XCTAssertEqual(bx, start.x + (end.x - start.x) * t, accuracy: 1e-9)
            XCTAssertEqual(by, start.y + (end.y - start.y) * t, accuracy: 1e-9)
        }
    }

    func testEndBendCompletesOneOperationAndReturnsToIdle() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 100, y: 0))]),
        ])
        let began = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        let bent = BezierPathController.apply(.bend(offset: CGVector(dx: 5, dy: 10)), to: began.path, state: began.state)
        let ended = BezierPathController.apply(.endBend, to: bent.path, state: bent.state)

        XCTAssertEqual(ended.state, .idle)
        XCTAssertEqual(ended.completedOperation, .segmentBent(subpathIndex: 0, segmentIndex: 1))
        XCTAssertEqual(ended.path, bent.path, "endBend commits whatever the last .bend frame already produced")
    }

    func testCancelBendRestoresTheOriginalLineSegmentVerbatim() {
        let originalSegment = ShapePathSegment.line(ShapePathPoint(x: 100, y: 0))
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0)), originalSegment])])
        let began = BezierPathController.apply(.beginBend(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        let bent = BezierPathController.apply(.bend(offset: CGVector(dx: 30, dy: -30)), to: began.path, state: began.state)
        let cancelled = BezierPathController.apply(.cancelBend, to: bent.path, state: bent.state)

        XCTAssertEqual(cancelled.path, path)
        XCTAssertEqual(cancelled.state, .idle)
        XCTAssertNil(cancelled.completedOperation)
    }

    // MARK: - Deletion

    func testDeleteSegmentRemovesItAndCompletesOneOperation() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .line(ShapePathPoint(x: 10, y: 0)),
                .line(ShapePathPoint(x: 10, y: 10)),
            ]),
        ])
        let result = BezierPathController.apply(.deleteSegment(subpathIndex: 0, segmentIndex: 1), to: path, state: .idle)
        XCTAssertEqual(result.path.subpaths[0].segments, [.move(ShapePathPoint(x: 0, y: 0)), .line(ShapePathPoint(x: 10, y: 10))])
        XCTAssertEqual(result.completedOperation, .segmentDeleted(subpathIndex: 0, segmentIndex: 1))
    }

    func testDeletingTheLeadingMoveSegmentPromotesTheNewFirstSegmentToAnImplicitMove() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [
                .move(ShapePathPoint(x: 0, y: 0)),
                .line(ShapePathPoint(x: 10, y: 0)),
                .line(ShapePathPoint(x: 10, y: 10)),
            ]),
        ])
        let result = BezierPathController.apply(.deleteSegment(subpathIndex: 0, segmentIndex: 0), to: path, state: .idle)
        XCTAssertEqual(
            result.path.subpaths[0].segments,
            [.move(ShapePathPoint(x: 10, y: 0)), .line(ShapePathPoint(x: 10, y: 10))],
            "the subpath's first segment stays .move, matching ShapePathSegment's own invariant"
        )
    }

    func testDeletingTheLastRemainingSegmentInASubpathIsANoOp() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0))])])
        let result = BezierPathController.apply(.deleteSegment(subpathIndex: 0, segmentIndex: 0), to: path, state: .idle)
        XCTAssertEqual(result.path, path)
        XCTAssertNil(result.completedOperation)
    }

    func testDeleteSubpathRemovesItAndCompletesOneOperation() {
        let path = ShapePath(subpaths: [
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0))]),
            ShapeSubpath(segments: [.move(ShapePathPoint(x: 10, y: 10))]),
        ])
        let result = BezierPathController.apply(.deleteSubpath(subpathIndex: 0), to: path, state: .idle)
        XCTAssertEqual(result.path.subpaths.count, 1)
        XCTAssertEqual(result.path.subpaths[0].segments, [.move(ShapePathPoint(x: 10, y: 10))])
        XCTAssertEqual(result.completedOperation, .subpathDeleted(subpathIndex: 0))
    }

    func testDeleteSubpathWithAnOutOfRangeIndexIsANoOp() {
        let path = ShapePath(subpaths: [ShapeSubpath(segments: [.move(ShapePathPoint(x: 0, y: 0))])])
        let result = BezierPathController.apply(.deleteSubpath(subpathIndex: 9), to: path, state: .idle)
        XCTAssertEqual(result.path, path)
        XCTAssertNil(result.completedOperation)
    }
}
