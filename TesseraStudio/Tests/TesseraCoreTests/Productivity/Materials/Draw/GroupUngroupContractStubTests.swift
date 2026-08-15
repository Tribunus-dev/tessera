import XCTest
import Foundation
@testable import TesseraCore

// MARK: - Group/ungroup - CONTRACT NOT TESTABLE (symbol does not exist)
//
// Contract source: studio-expansion-design-refinement-2026-08-14.md
// section 4, "Draw cluster", item 1.19: "Group/ungroup UX (row 48)
// rides this cluster: selection -> group receipt setting parentGroupID
// + a shapeGroup block; TransformController recurses."
//
// Per docs/p1-post-claim-audit-2026-08-15.md item 1.19: "group/ungroup
// (row 48) is ENTIRELY ABSENT - no API, no receipts... not built yet."
// Re-verified against the current tree while writing this test pass:
//   - `Shape.parentGroupID: UUID?` DOES exist (Shape.swift) and
//     `BlockType.shapeGroup` DOES exist (Block.swift) - so SOME
//     vocabulary is reserved, more than the audit's exact "not even
//     vocabulary reserved" phrasing suggests (apparently landed after
//     the audit was written). This note exists so this file doesn't
//     read as a blind copy of the audit.
//   - There is NO `DrawingStore.group(...)`/`.ungroup(...)` method, no
//     `DrawingReceiptType` case for it (`DrawingReceiptType.swift`'s own
//     doc comment: "group/ungroup/export/import/diff... have no
//     corresponding DrawingStore method yet, so they're not cases here
//     either"), and no `TransformController` group-recursion entry
//     point.
//
// Per the task brief and the doctrine's own guidance for this exact
// situation (item 1.19's note on the connector/shape-text contract):
// when a genuinely-missing symbol blocks writing even an
// XCTExpectFailure-wrapped test (there is no method to call, so there
// is no runtime assertion to make and wrap), the correct doctrine path
// is a comment-only stub describing exactly what the test would assert
// once the symbol exists - NOT inventing the missing API here (that is
// implementation work, out of scope for a test-only pass) and NOT
// silently skipping the contract. Logged in this cluster's findings
// file under "contract not testable - symbol does not exist", citing
// the audit's item 1.19.

final class GroupUngroupContractStubTests: DoctrineTestCase {

    /// STUB - not runnable. Once `DrawingStore.group(shapeIDs:in:)` (or
    /// equivalent) exists, this should assert:
    ///   1. Every shape id in `shapeIDs` gets `parentGroupID` set to a
    ///      freshly-created group shape's id.
    ///   2. A new `.shapeGroup`-kinded `Shape` (or `Block`, per whichever
    ///      the landed design picks) is inserted as the parent.
    ///   3. Exactly ONE receipt is appended, of a new
    ///      `DrawingReceiptType` case (e.g. `.groupShapes`), whose
    ///      payload names the new group id and the full member id set.
    ///   4. Grouping an EMPTY selection, or a selection containing an
    ///      unknown shape id, is a no-op: zero receipts, zero
    ///      persistence (doctrine rule 1) - the store-level "no receipt
    ///      without a mutation" contract this cluster's DrawingStoreTests
    ///      already enforces for the six existing layer methods.
    func testGroupingASelectionSetsParentGroupIDAndEmitsExactlyOneReceipt() throws {
        throw XCTSkip("contract not testable: DrawingStore has no group(...) method yet - see this file's header comment and the findings file's 'contract not testable' row citing p1-post-claim-audit-2026-08-15.md item 1.19")
    }

    /// STUB - not runnable. Once `DrawingStore.ungroup(groupID:in:)` (or
    /// equivalent) exists, this should assert:
    ///   1. Every former member's `parentGroupID` is cleared back to nil.
    ///   2. The group's own `.shapeGroup` shape/block is removed.
    ///   3. Exactly ONE receipt is appended (e.g. `.ungroupShapes`).
    ///   4. Ungrouping an id that does not name a group is a no-op
    ///      (zero receipts, zero persistence - same receipts-law shape).
    func testUngroupingRestoresIndividualShapesAndClearsParentGroupID() throws {
        throw XCTSkip("contract not testable: DrawingStore has no ungroup(...) method yet - see this file's header comment and the findings file's 'contract not testable' row citing p1-post-claim-audit-2026-08-15.md item 1.19")
    }

    /// STUB - not runnable. Once group/ungroup exists, this should
    /// assert the design contract's "TransformController recurses"
    /// clause: resizing/rotating a `.shapeGroup` shape via
    /// `TransformController.resize`/`.rotate` must transform every
    /// member shape's geometry consistently (the group acts as one
    /// rigid body), not just the group's own bounding geometry.
    func testTransformingAGroupRecursesIntoEveryMemberShapesGeometry() throws {
        throw XCTSkip("contract not testable: no group-aware entry point exists on TransformController yet - see this file's header comment and the findings file's 'contract not testable' row citing p1-post-claim-audit-2026-08-15.md item 1.19")
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
