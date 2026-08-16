import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - TransformControllerTests
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md's
// Draw cluster item 1.16 ("Test: opposite corner world-fixed to 1e-9;
// one drag = one undo unit") plus TransformController.swift's own doc
// comments (drag-past-opposite flips flipH/flipV instead of going
// negative; anchorX/anchorY are read-only / never written by resize or
// rotate). The one-drag-one-undo half needs a gesture layer that does
// not exist yet (see this cluster's findings file); this file tests the
// pure-math half that IS callable.

final class TransformControllerTests: DoctrineTestCase {

    // MARK: - Resize: opposite handle stays world-fixed (unrotated)

    func testResizeFromBottomRightKeepsTopLeftWorldFixed() {
        let start = ShapeGeometry(x: 10, y: 10, width: 100, height: 50)
        let beforeOpposite = TransformController.position(of: .topLeft, in: start)

        let resized = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: CGVector(dx: 40, dy: 20)
        )
        let afterOpposite = TransformController.position(of: .topLeft, in: resized)

        XCTAssertEqual(afterOpposite.x, beforeOpposite.x, accuracy: 1e-9)
        XCTAssertEqual(afterOpposite.y, beforeOpposite.y, accuracy: 1e-9)
        XCTAssertEqual(resized.width, 140, accuracy: 1e-9)
        XCTAssertEqual(resized.height, 70, accuracy: 1e-9)
    }

    // MARK: - Resize: opposite handle stays world-fixed (ROTATED - the
    // harder case the design contract specifically calls out).

    func testResizeOfARotatedShapeKeepsOppositeCornerWorldFixedTo1e9() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 37)
        let beforeOpposite = TransformController.position(of: .topLeft, in: start)

        let resized = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: CGVector(dx: 15, dy: -8)
        )
        let afterOpposite = TransformController.position(of: .topLeft, in: resized)

        XCTAssertEqual(afterOpposite.x, beforeOpposite.x, accuracy: 1e-9)
        XCTAssertEqual(afterOpposite.y, beforeOpposite.y, accuracy: 1e-9)
        // rotation itself is untouched by a resize.
        XCTAssertEqual(resized.rotation, 37, accuracy: 1e-9)
    }

    func testResizeFromAnEdgeHandleOfARotatedShapeKeepsOppositeEdgeWorldFixed() {
        let start = ShapeGeometry(x: 20, y: 20, width: 80, height: 60, rotation: -52)
        let beforeOpposite = TransformController.position(of: .left, in: start)

        let resized = TransformController.resize(
            handle: .right,
            startGeometry: start,
            worldDelta: CGVector(dx: -10, dy: 25)
        )
        let afterOpposite = TransformController.position(of: .left, in: resized)

        XCTAssertEqual(afterOpposite.x, beforeOpposite.x, accuracy: 1e-9)
        XCTAssertEqual(afterOpposite.y, beforeOpposite.y, accuracy: 1e-9)
    }

    // MARK: - Resize: anchor is never written (transient gesture anchor contract)

    func testResizeNeverWritesAnchorXOrAnchorY() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, anchorX: 30, anchorY: 40)
        let resized = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: CGVector(dx: 10, dy: 10)
        )
        XCTAssertEqual(resized.anchorX, 30)
        XCTAssertEqual(resized.anchorY, 40)
    }

    func testResizeWithUnsetAnchorLeavesItUnsetAfterward() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(start.anchorX)
        let resized = TransformController.resize(handle: .bottomRight, startGeometry: start, worldDelta: CGVector(dx: 5, dy: 5))
        XCTAssertNil(resized.anchorX)
        XCTAssertNil(resized.anchorY)
    }

    // MARK: - Resize: Option (center-anchored) doubles the extent

    func testResizeWithCenterAnchoredOptionKeepsCenterFixedAndDoublesTheDelta() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100)
        let resized = TransformController.resize(
            handle: .right,
            startGeometry: start,
            worldDelta: CGVector(dx: 20, dy: 0),
            options: TransformController.ResizeOptions(centerAnchored: true)
        )
        // Center-anchored: the opposite edge mirrors the dragged one, so
        // width grows by 2x the raw delta (100 -> 140), centered on the
        // original center (50, 50).
        XCTAssertEqual(resized.width, 140, accuracy: 1e-9)
        XCTAssertEqual(resized.x, -20, accuracy: 1e-9)
    }

    // MARK: - Resize: Shift (aspect-locked)

    func testResizeWithAspectLockedPreservesStartingAspectRatio() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 50) // 2:1
        let resized = TransformController.resize(
            handle: .bottomRight,
            startGeometry: start,
            worldDelta: CGVector(dx: 100, dy: 0), // drag only widens
            options: TransformController.ResizeOptions(aspectLocked: true)
        )
        XCTAssertEqual(resized.width / resized.height, 2, accuracy: 1e-9)
    }

    // MARK: - Resize: drag-past-opposite flips instead of negating

    func testDraggingAResizeHandlePastItsOppositeFlipsRatherThanGoingNegative() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100)
        // Drag the right handle 150 units left - past the left (x=0) edge.
        let resized = TransformController.resize(
            handle: .right,
            startGeometry: start,
            worldDelta: CGVector(dx: -150, dy: 0)
        )
        XCTAssertGreaterThanOrEqual(resized.width, 0, "width must never go negative")
        XCTAssertTrue(resized.flipH, "dragging past the opposite reference point flips flipH instead of negating width")
        XCTAssertFalse(resized.flipV)
    }

    // MARK: - Rotate: pure delta, geometry otherwise untouched

    func testRotateAppliesTheSignedAngleBetweenStartAndCurrentPointers() {
        // Pivot is the shape's own (unset-anchor) center: (50, 50).
        // startPoint sits due east of the pivot (angle 0); currentPoint
        // sits due north (angle -90 degrees, y-down convention) - a
        // hand-computed -90 degree fixture, not a re-derivation of the
        // source's own atan2 formula.
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 0)
        let startPoint = CGPoint(x: 150, y: 50)
        let currentPoint = CGPoint(x: 50, y: -50)

        let rotated = TransformController.rotate(startGeometry: start, startPoint: startPoint, currentPoint: currentPoint)

        XCTAssertEqual(rotated.rotation, -90, accuracy: 1e-9)
        // rotate never touches position/size/flip.
        XCTAssertEqual(rotated.x, start.x)
        XCTAssertEqual(rotated.y, start.y)
        XCTAssertEqual(rotated.width, start.width)
        XCTAssertEqual(rotated.height, start.height)
        XCTAssertEqual(rotated.flipH, start.flipH)
        XCTAssertEqual(rotated.flipV, start.flipV)
    }

    func testRotateByAFullZeroDeltaIsAnIdentityOnRotation() {
        let start = ShapeGeometry(x: 0, y: 0, width: 100, height: 100, rotation: 22)
        let samePoint = CGPoint(x: 200, y: 50)
        let rotated = TransformController.rotate(startGeometry: start, startPoint: samePoint, currentPoint: samePoint)
        XCTAssertEqual(rotated.rotation, 22, accuracy: 1e-9)
    }

    // MARK: - Handle geometry sanity (fixture)

    func testHandlePositionsMatchTheirDocumentedFractionsWhenUnrotated() {
        let geometry = ShapeGeometry(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(TransformController.position(of: .topLeft, in: geometry), CGPoint(x: 0, y: 0))
        XCTAssertEqual(TransformController.position(of: .topRight, in: geometry), CGPoint(x: 200, y: 0))
        XCTAssertEqual(TransformController.position(of: .bottomRight, in: geometry), CGPoint(x: 200, y: 100))
        XCTAssertEqual(TransformController.position(of: .bottomLeft, in: geometry), CGPoint(x: 0, y: 100))
    }

    func testEveryResizeHandleHasAnOppositeExceptRotation() {
        for handle in TransformController.Handle.allCases where handle != .rotation {
            XCTAssertNotNil(handle.opposite, "\(handle) must have an opposite handle")
        }
        XCTAssertNil(TransformController.Handle.rotation.opposite)
    }

    // MARK: - Group transform (row 48, P2-0): the group-recursion entry
    // point. Contract source: this file's own header ("TransformController
    // recurses") plus applyingGroupDelta's own doc comment (a
    // `.shapeGroup` carries no geometry of its own - moving every
    // member by the same delta IS what transforming a group means).

    func testApplyingGroupDeltaMovesEveryMemberOfTheNamedGroupByTheSameDelta() {
        let groupID = UUID()
        var a = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        var b = Shape(kind: .ellipse, geometry: ShapeGeometry(x: 50, y: 30, width: 20, height: 20))
        a.parentGroupID = groupID
        b.parentGroupID = groupID
        let delta = CGVector(dx: 7, dy: -3)

        let result = TransformController.applyingGroupDelta(groupID: groupID, shapes: [a, b], worldDelta: delta)

        XCTAssertEqual(result[a.id]?.x ?? .nan, a.geometry.x + 7, accuracy: 1e-9)
        XCTAssertEqual(result[a.id]?.y ?? .nan, a.geometry.y - 3, accuracy: 1e-9)
        XCTAssertEqual(result[b.id]?.x ?? .nan, b.geometry.x + 7, accuracy: 1e-9)
        XCTAssertEqual(result[b.id]?.y ?? .nan, b.geometry.y - 3, accuracy: 1e-9)
    }

    func testApplyingGroupDeltaLeavesWidthHeightRotationUntouched() {
        let groupID = UUID()
        var a = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 40, height: 25, rotation: 15))
        a.parentGroupID = groupID

        let result = TransformController.applyingGroupDelta(groupID: groupID, shapes: [a], worldDelta: CGVector(dx: 5, dy: 5))

        XCTAssertEqual(result[a.id]?.width, 40)
        XCTAssertEqual(result[a.id]?.height, 25)
        XCTAssertEqual(result[a.id]?.rotation, 15)
    }

    func testApplyingGroupDeltaExcludesShapesOutsideTheNamedGroup() {
        let groupID = UUID()
        let otherGroupID = UUID()
        var member = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        var otherGroupMember = Shape(kind: .rect, geometry: ShapeGeometry(x: 100, y: 100, width: 10, height: 10))
        var ungrouped = Shape(kind: .rect, geometry: ShapeGeometry(x: 200, y: 200, width: 10, height: 10))
        member.parentGroupID = groupID
        otherGroupMember.parentGroupID = otherGroupID
        ungrouped.parentGroupID = nil

        let result = TransformController.applyingGroupDelta(
            groupID: groupID, shapes: [member, otherGroupMember, ungrouped], worldDelta: CGVector(dx: 1, dy: 1))

        XCTAssertEqual(Set(result.keys), [member.id], "only shapes carrying the exact named groupID move")
    }

    func testApplyingGroupDeltaOfAnUnusedGroupIDReturnsAnEmptyResult() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        let result = TransformController.applyingGroupDelta(groupID: UUID(), shapes: [shape], worldDelta: CGVector(dx: 3, dy: 3))
        XCTAssertTrue(result.isEmpty)
    }

    // Property: a zero delta is the identity on every member's origin
    // (idempotence-style property test, doctrine rule 9).
    func testApplyingGroupDeltaWithZeroVectorIsIdentityOnEveryMembersOrigin() {
        let groupID = UUID()
        var a = Shape(kind: .rect, geometry: ShapeGeometry(x: 12, y: 34, width: 10, height: 10))
        a.parentGroupID = groupID

        let result = TransformController.applyingGroupDelta(groupID: groupID, shapes: [a], worldDelta: .zero)

        XCTAssertEqual(result[a.id]?.x, a.geometry.x)
        XCTAssertEqual(result[a.id]?.y, a.geometry.y)
    }
}
