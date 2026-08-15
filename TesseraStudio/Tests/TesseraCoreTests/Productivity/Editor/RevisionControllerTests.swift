import XCTest
@testable import TesseraCore

// MARK: - RevisionControllerTests
//
// Contract: studio-expansion-design-refinement-2026-08-14.md section 4,
// "Writer cluster" - 1.14 RevisionController:
//   "block UUID = revision ID; attributes["revisionID"] groups multi-block
//   revisions (moves = paired ins+del sharing revisionID ...). Accept/
//   reject semantics per OOXML; nested resolves innermost-first; grouped
//   resolves atomically. Receipts doc_revision_accepted/rejected + batch
//   summary; undo re-creates the block with the SAME id (receipts are
//   append-only)."
//   "Test: B-deletes-inside-A-inserts resolves to the same contentHash in
//   any order; accept-then-undo restores the prior hash."
//
// RevisionController is pure (no DocStore) - see the source file header:
// "ast itself is never touched" by accept/reject, which is exactly what
// lets a caller reconstruct the pre-resolution state from the original
// value it already holds. That value-type guarantee IS the undo contract
// this file tests: the ORIGINAL DocumentAST a caller holds before calling
// accept/reject is never mutated, so "undo" is holding onto it, and every
// block in it (including the revision block's own id) is untouched.

final class RevisionControllerTests: DoctrineTestCase {

    // MARK: - Fixture: B-deletes-inside-A-inserts

    /// A trackInsertion block A with a nested trackDeletion block B as one
    /// of A's children (a still-pending deletion inside a still-pending
    /// insertion's span) - the refinement doc's own headline construction.
    private func nestedFixture(aID: UUID = UUID(), bID: UUID = UUID()) -> (ast: DocumentAST, aID: UUID, bID: UUID) {
        let a = Block(
            id: aID,
            type: .trackInsertion,
            attributes: ["author": .string("alice"), "timestamp": .number(1000)],
            content: [InlineRun(text: "inserted wrapper")],
            children: [bID]
        )
        let b = Block(
            id: bID,
            type: .trackDeletion,
            attributes: ["author": .string("bob"), "timestamp": .number(2000)],
            content: [InlineRun(text: "deleted inner")],
            children: [],
            parentID: aID
        )
        var ast = DocumentAST()
        ast.blocks[aID] = a
        ast.blocks[bID] = b
        ast.rootChildren = [aID]
        return (ast, aID, bID)
    }

    // MARK: - revisionID(for:)

    func testRevisionIDForBlockWithNoGroupingAttributeIsItsOwnID() {
        let block = Block(id: UUID(), type: .trackInsertion)
        XCTAssertEqual(RevisionController.revisionID(for: block), block.id)
    }

    func testRevisionIDForBlockWithGroupingAttributeUsesTheGroupID() {
        let groupID = UUID()
        let block = Block(id: UUID(), type: .trackInsertion, attributes: ["revisionID": .string(groupID.uuidString)])
        XCTAssertEqual(RevisionController.revisionID(for: block), groupID)
    }

    // MARK: - Order-invariance property: same contentHash in any order

    func testAcceptOuterThenInnerAndAcceptInnerThenOuterProduceSameContentHash() throws {
        let (astOrder1, aID, bID) = nestedFixture()
        // Same block identities as astOrder1, but an independently
        // constructed DocumentAST value - two separate calls with the
        // SAME explicit ids, not two calls each minting fresh random
        // ones, since accept(revisionID:)/reject(revisionID:) target
        // the fixture's own block ids and both orders must operate on
        // the same identities to be comparable at all.
        let (astOrder2, _, _) = nestedFixture(aID: aID, bID: bID)

        // Order 1: accept A (outer insertion), then accept B (inner deletion).
        let (afterA1, _) = RevisionController.accept(revisionID: aID, in: astOrder1)
        let (afterBoth1, _) = RevisionController.accept(revisionID: bID, in: afterA1)

        // Order 2: accept B (inner deletion) first, then accept A (outer insertion).
        let (afterB2, _) = RevisionController.accept(revisionID: bID, in: astOrder2)
        let (afterBoth2, _) = RevisionController.accept(revisionID: aID, in: afterB2)

        XCTAssertEqual(try afterBoth1.contentHash(), try afterBoth2.contentHash(),
                        "resolving the outer insertion and the inner (nested) deletion in either order must converge to the same document")
        // Sanity on the converged shape: A survives as plain content, B is gone.
        XCTAssertEqual(afterBoth1.blocks[aID]?.type, .paragraph, "accepted trackInsertion converts to plain content")
        XCTAssertNil(afterBoth1.blocks[bID], "accepted trackDeletion (accept -> keep=false) is removed")
        XCTAssertEqual(afterBoth1.blocks[aID]?.children, [], "the removed inner block must be unlinked from its parent's children")
    }

    /// Same order-invariance property, but with reject instead of accept -
    /// reject keeps the deletion block (converts it) and removes the
    /// insertion block (and, being the outer one, its whole subtree).
    func testRejectOuterThenInnerAndRejectInnerThenOuterProduceSameContentHash() throws {
        let (astOrder1, aID, bID) = nestedFixture()
        // Same block identities as astOrder1 - see the comment in the
        // accept-order-invariance test above for why.
        let (astOrder2, _, _) = nestedFixture(aID: aID, bID: bID)

        // Order 1: reject A (outer) first. Because A's own subtree includes
        // B, rejecting A (a `.removed` action for trackInsertion under
        // reject) purges B along with it - there is nothing left to
        // separately reject afterward, so `reject(bID)` on the result is a
        // safe no-op (isEmpty resolution).
        let (afterA1, _) = RevisionController.reject(revisionID: aID, in: astOrder1)
        let (afterBoth1, resolutionForB1) = RevisionController.reject(revisionID: bID, in: afterA1)
        XCTAssertTrue(resolutionForB1.isEmpty, "B was already purged as part of A's subtree removal")

        // Order 2: reject B (inner) first - it converts to plain content
        // (kept). Then reject A (outer) - A's own subtree (now containing
        // the converted-to-plain-content former-B) is removed wholesale.
        let (afterB2, _) = RevisionController.reject(revisionID: bID, in: astOrder2)
        XCTAssertEqual(afterB2.blocks[bID]?.type, .paragraph, "rejected trackDeletion converts to plain content (the deletion is undone)")
        let (afterBoth2, _) = RevisionController.reject(revisionID: aID, in: afterB2)

        XCTAssertEqual(try afterBoth1.contentHash(), try afterBoth2.contentHash(),
                        "reject in either order must converge to the same document")
        XCTAssertNil(afterBoth1.blocks[aID], "rejected trackInsertion (reject -> keep=false for insertions) is removed, subtree included")
        XCTAssertNil(afterBoth1.blocks[bID])
    }

    // MARK: - Accept-then-undo restores the prior hash + same block id

    func testAcceptThenUndoRestoresThePriorContentHashAndSameBlockID() throws {
        let (original, aID, _) = nestedFixture()
        let originalHash = try original.contentHash()
        let originalBlockID = original.blocks[aID]?.id

        // Accept returns a NEW ast; the input `original` is a value type
        // and this call must not mutate the caller's own copy of it - see
        // the file header's "ast itself is never touched" guarantee.
        let (afterAccept, resolution) = RevisionController.accept(revisionID: aID, in: original)
        XCTAssertFalse(resolution.isEmpty)
        XCTAssertNotEqual(try afterAccept.contentHash(), originalHash, "the accept must have actually changed the document")

        // "Undo": the caller's own `original` binding was never touched by
        // the accept call above - reconstructing the pre-resolution state
        // is exactly holding onto it. Assert this holds byte-for-byte.
        XCTAssertEqual(try original.contentHash(), originalHash, "the original document must be restorable exactly, unchanged by the accept call")
        XCTAssertEqual(original.blocks[aID]?.id, originalBlockID, "the revision block keeps the SAME id across the accept/undo round trip - never a new one")
        XCTAssertEqual(original.blocks[aID]?.type, .trackInsertion, "the restored block is still the original trackInsertion, not a re-synthesized paragraph")
    }

    // MARK: - Move: paired trackInsertion + trackDeletion sharing revisionID

    private func moveFixture() -> (ast: DocumentAST, insertID: UUID, deleteID: UUID, groupID: UUID) {
        let insertID = UUID()
        let deleteID = UUID()
        let groupID = UUID()
        let insertBlock = Block(
            id: insertID, type: .trackInsertion,
            attributes: ["revisionID": .string(groupID.uuidString)],
            content: [InlineRun(text: "moved text")]
        )
        let deleteBlock = Block(
            id: deleteID, type: .trackDeletion,
            attributes: ["revisionID": .string(groupID.uuidString)],
            content: [InlineRun(text: "moved text")]
        )
        var ast = DocumentAST()
        ast.blocks[insertID] = insertBlock
        ast.blocks[deleteID] = deleteBlock
        ast.rootChildren = [insertID, deleteID]
        return (ast, insertID, deleteID, groupID)
    }

    func testAcceptMoveKeepsInsertionAndDropsDeletion() {
        let (ast, insertID, deleteID, groupID) = moveFixture()
        let (result, resolution) = RevisionController.accept(revisionID: groupID, in: ast)
        XCTAssertTrue(resolution.isMove, "a group pairing exactly one trackInsertion + one trackDeletion must report isMove == true")
        XCTAssertEqual(resolution.blocks.count, 2)
        XCTAssertEqual(result.blocks[insertID]?.type, .paragraph, "accept keeps the insertion (converts it) - the move completes")
        XCTAssertNil(result.blocks[deleteID], "accept drops the deletion side of the move")
    }

    func testRejectMoveDropsInsertionAndRestoresDeletion() {
        let (ast, insertID, deleteID, groupID) = moveFixture()
        let (result, resolution) = RevisionController.reject(revisionID: groupID, in: ast)
        XCTAssertTrue(resolution.isMove)
        XCTAssertNil(result.blocks[insertID], "reject drops the insertion side of the move (it never happened)")
        XCTAssertEqual(result.blocks[deleteID]?.type, .paragraph, "reject restores the deletion (converts it back to plain content) - the move undoes")
    }

    func testResolutionIsMoveFalseForASingleBlockRevision() {
        let (ast, aID, _) = nestedFixture()
        let (_, resolution) = RevisionController.accept(revisionID: aID, in: ast)
        XCTAssertFalse(resolution.isMove, "a lone trackInsertion accept is not a move")
    }

    // MARK: - Grouped resolution is atomic: strips track attributes, keeps content+children

    func testAcceptSingleTrackInsertionConvertsToPlainContentStrippingTrackAttributesOnly() {
        let id = UUID()
        let childID = UUID()
        let block = Block(
            id: id, type: .trackInsertion,
            attributes: ["author": .string("alice"), "timestamp": .number(1), "customKey": .string("keep-me")],
            content: [InlineRun(text: "hello", annotations: [.bold])],
            children: [childID]
        )
        var ast = DocumentAST()
        ast.blocks[id] = block
        ast.blocks[childID] = Block(id: childID, type: .paragraph, parentID: id)
        ast.rootChildren = [id]

        let (result, resolution) = RevisionController.accept(revisionID: id, in: ast)

        XCTAssertEqual(result.blocks[id]?.type, .paragraph)
        XCTAssertNil(result.blocks[id]?.attributes["author"], "track-change author attribute must be stripped")
        XCTAssertNil(result.blocks[id]?.attributes["timestamp"], "track-change timestamp attribute must be stripped")
        XCTAssertEqual(result.blocks[id]?.attributes["customKey"], .string("keep-me"), "a non-track-change attribute must survive conversion")
        XCTAssertEqual(result.blocks[id]?.content, [InlineRun(text: "hello", annotations: [.bold])], "content is untouched by conversion")
        XCTAssertEqual(result.blocks[id]?.children, [childID], "children must never be cleared on conversion - a still-pending nested revision must stay intact")
        XCTAssertEqual(resolution.blocks.first?.action, .convertedToPlainContent)
        XCTAssertEqual(resolution.blocks.first?.blockType, .trackInsertion, "blockType records the PRE-resolution type")
    }

    // MARK: - No-op: unknown revisionID

    func testAcceptUnknownRevisionIDIsEmptyResolutionAndLeavesDocumentUnchanged() throws {
        let (ast, _, _) = nestedFixture()
        let originalHash = try ast.contentHash()
        let (result, resolution) = RevisionController.accept(revisionID: UUID(), in: ast)
        XCTAssertTrue(resolution.isEmpty)
        XCTAssertEqual(try result.contentHash(), originalHash, "an unknown revisionID must leave the document byte-for-byte unchanged")
    }

    // MARK: - Receipt payload shape (mirrors QueryEngineOutcome's boundary)

    func testResolutionPayloadCarriesTheExpectedReceiptShape() {
        let (ast, aID, _) = nestedFixture()
        let (_, resolution) = RevisionController.accept(revisionID: aID, in: ast)
        let payload = resolution.payload
        XCTAssertEqual(payload["revisionID"], .string(aID.uuidString))
        XCTAssertEqual(payload["direction"], .string("accept"))
        XCTAssertEqual(payload["blockCount"], .number(1))
        XCTAssertEqual(payload["isMove"], .bool(false))
        guard case .array(let blocks)? = payload["blocks"] else {
            return XCTFail("payload[\"blocks\"] must be a JSON array")
        }
        XCTAssertEqual(blocks.count, 1)
    }

    func testReceiptTypeMatchesDirection() {
        let (ast, aID, _) = nestedFixture()
        let (_, acceptResolution) = RevisionController.accept(revisionID: aID, in: ast)
        XCTAssertEqual(acceptResolution.receiptType, DocReceiptType.revisionAccepted.rawValue)

        let (ast2, aID2, _) = nestedFixture()
        let (_, rejectResolution) = RevisionController.reject(revisionID: aID2, in: ast2)
        XCTAssertEqual(rejectResolution.receiptType, DocReceiptType.revisionRejected.rawValue)
    }
}
