import XCTest
import Foundation
import CoreGraphics
@testable import TesseraCore

// MARK: - Group/ungroup (row 48, P2-0) - contract GRADUATED
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, "Draw cluster", item 1.19: "Group/ungroup UX (row 48)
// rides this cluster: selection -> group receipt setting parentGroupID
// + a shapeGroup block; TransformController recurses."
//
// STATUS UPDATE (P2-0): this file originally held 3 comment-only STUBs
// (`throw XCTSkip(...)`) because the symbols they described - a
// `DrawingStore.group(...)`/`.ungroup(...)` method pair and a
// `TransformController` group-recursion entry point - did not exist
// yet (per docs/p1-post-claim-audit-2026-08-15.md item 1.19). P2-0
// item 4 landed both:
//   - `DrawingStore.group(_:for:)` / `.ungroup(_:for:)` (plus the pure,
//     directly-testable `applyingGroup`/`applyingUngroup` helpers) -
//     the receipt-contract assertions the first 2 stubs described now
//     live in DrawingStoreTests.swift (DB-gated, mirroring that file's
//     established pattern for every other store mutation) rather than
//     duplicated here, to avoid two copies of the same DB-gated gate
//     helper drifting apart.
//   - `TransformController.applyingGroupDelta(groupID:shapes:worldDelta:)`
//     - the group-recursion entry point the 3rd stub anticipated. This
//     one IS pure (no store, no DB), so its real assertion replaces
//     the stub directly below, and gets a fuller fixture set in
//     TransformControllerTests.swift.
//
// The group is NOT a separate `.shapeGroup`-kinded `Shape`/`Block` at
// P0/P1 (verified against `Drawing.swift`'s doc comment: "Carries no
// geometry of its own at P0 - group bounds are derived from members,
// not stored") - `parentGroupID` membership alone is the group, so the
// "a new .shapeGroup shape is inserted as the parent" clause the
// original stub comments anticipated did not land; `BlockType
// .shapeGroup` stays reserved vocabulary (see the vocabulary tests
// below), available for whichever P2 design actually needs a stored
// group entity.

final class GroupUngroupContractStubTests: DoctrineTestCase {

    /// Was STUB #3 ("TransformController recurses"). Now real: asserts
    /// that transforming a group via `applyingGroupDelta` moves every
    /// member shape's geometry, not just one shape's - the exact
    /// "not just the group's own nominal bounds" contract line from
    /// this cluster's task brief. See TransformControllerTests.swift
    /// for the fuller fixture/property coverage of the same function.
    func testTransformingAGroupRecursesIntoEveryMemberShapesGeometry() {
        let groupID = UUID()
        var a = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 10, height: 10))
        var b = Shape(kind: .rect, geometry: ShapeGeometry(x: 50, y: 50, width: 10, height: 10))
        a.parentGroupID = groupID
        b.parentGroupID = groupID
        let unrelated = Shape(kind: .rect, geometry: ShapeGeometry(x: 200, y: 200, width: 10, height: 10))

        let moved = TransformController.applyingGroupDelta(
            groupID: groupID, shapes: [a, b, unrelated], worldDelta: CGVector(dx: 10, dy: 10))

        XCTAssertEqual(moved[a.id]?.x, 10)
        XCTAssertEqual(moved[b.id]?.x, 60)
        XCTAssertNil(moved[unrelated.id], "a shape outside the group must not be in the recursion's result at all")
    }

    // MARK: - What IS testable today: the reserved vocabulary itself

    func testParentGroupIDFieldExistsAndDefaultsToNil() {
        let shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(shape.parentGroupID, "P0/P1 leaves every shape's parentGroupID nil until group/ungroup lands")
    }

    func testParentGroupIDCanBeSetOnAShapeValueDirectly() {
        var shape = Shape(kind: .rect, geometry: ShapeGeometry(x: 0, y: 0, width: 1, height: 1))
        let groupID = UUID()
        shape.parentGroupID = groupID
        XCTAssertEqual(shape.parentGroupID, groupID)
    }

    func testShapeGroupBlockTypeCaseExists() {
        // .shapeGroup is reserved vocabulary (Block.swift) even though
        // no DrawingStore mutation creates one yet.
        XCTAssertEqual(BlockType.shapeGroup.rawValue, "shapeGroup")
    }
}
