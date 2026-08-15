import XCTest
import Foundation
@testable import TesseraCore

/// Tests for `RevisionController` (P1 item 1.14, accept/reject
/// lifecycle over `.trackInsertion`/`.trackDeletion` blocks). The
/// central proof this file carries is the design contract's own test:
/// a trackDeletion nested inside a trackInsertion's `children` resolves
/// to the SAME `contentHash` regardless of which of the two is accepted
/// first.
final class RevisionControllerTests: XCTestCase {

    // MARK: - Fixtures

    /// A single unrelated `.trackInsertion`, no grouping attribute -
    /// its own `id` is its revision id.
    private static func singleInsertionFixture() -> (ast: DocumentAST, revisionID: UUID) {
        let insID = UUID()
        let insertion = Block(
            id: insID,
            type: .trackInsertion,
            attributes: ["author": .string("alice"), "timestamp": .string("2026-08-14T00:00:00Z")],
            content: [InlineRun(text: "inserted text")]
        )
        let ast = DocumentAST(blocks: [insID: insertion], rootChildren: [insID])
        return (ast, insID)
    }

    private static func singleDeletionFixture() -> (ast: DocumentAST, revisionID: UUID) {
        let delID = UUID()
        let deletion = Block(
            id: delID,
            type: .trackDeletion,
            attributes: ["author": .string("alice"), "timestamp": .string("2026-08-14T00:00:00Z")],
            content: [InlineRun(text: "deleted text")]
        )
        let ast = DocumentAST(blocks: [delID: deletion], rootChildren: [delID])
        return (ast, delID)
    }

    /// Revision B (a `.trackDeletion`) nested inside revision A's (a
    /// `.trackInsertion`) `children`, alongside an unrelated plain
    /// paragraph sibling - the design contract's own
    /// "B-deletes-inside-A-inserts" scenario. A and B carry no
    /// `attributes["revisionID"]`, so each block's own `id` is its
    /// revision id (`revisionID(for:)`'s single-block fallback).
    private static func nestedRevisionFixture() -> (ast: DocumentAST, revisionA: UUID, revisionB: UUID, keptParagraph: UUID) {
        let aID = UUID()
        let bID = UUID()
        let p1ID = UUID()

        let a = Block(
            id: aID,
            type: .trackInsertion,
            attributes: ["author": .string("alice"), "timestamp": .string("2026-08-14T00:00:00Z")],
            children: [p1ID, bID]
        )
        let p1 = Block(id: p1ID, type: .paragraph, content: [InlineRun(text: "kept text")], parentID: aID)
        let b = Block(
            id: bID,
            type: .trackDeletion,
            attributes: ["author": .string("bob"), "timestamp": .string("2026-08-14T01:00:00Z")],
            content: [InlineRun(text: "deleted text")],
            parentID: aID
        )

        let ast = DocumentAST(blocks: [aID: a, p1ID: p1, bID: b], rootChildren: [aID])
        return (ast, aID, bID, p1ID)
    }

    /// Three sibling `.trackInsertion` paragraphs sharing one
    /// `attributes["revisionID"]` - the "paste inserted 3 paragraphs"
    /// multi-block revision.
    private static func multiBlockInsertionFixture() -> (ast: DocumentAST, revisionID: UUID, blockIDs: [UUID]) {
        let shared = UUID()
        let ids = [UUID(), UUID(), UUID()]
        var blocks: [UUID: Block] = [:]
        for (i, id) in ids.enumerated() {
            blocks[id] = Block(
                id: id,
                type: .trackInsertion,
                attributes: ["revisionID": .string(shared.uuidString)],
                content: [InlineRun(text: "paragraph \(i)")]
            )
        }
        let ast = DocumentAST(blocks: blocks, rootChildren: ids)
        return (ast, shared, ids)
    }

    /// A move: one `.trackInsertion` (the destination) paired with one
    /// `.trackDeletion` (the source), sharing `attributes["revisionID"]`
    /// - no dedicated moveFrom/moveTo block types.
    private static func moveFixture() -> (ast: DocumentAST, revisionID: UUID, insertionID: UUID, deletionID: UUID) {
        let shared = UUID()
        let insID = UUID()
        let delID = UUID()
        let insertion = Block(
            id: insID,
            type: .trackInsertion,
            attributes: ["revisionID": .string(shared.uuidString)],
            content: [InlineRun(text: "moved text")]
        )
        let deletion = Block(
            id: delID,
            type: .trackDeletion,
            attributes: ["revisionID": .string(shared.uuidString)],
            content: [InlineRun(text: "moved text")]
        )
        let ast = DocumentAST(blocks: [insID: insertion, delID: deletion], rootChildren: [insID, delID])
        return (ast, shared, insID, delID)
    }

    // MARK: - Single-block accept/reject

    func testAcceptInsertionConvertsToPlainContentKeepingID() throws {
        let (ast, revisionID) = Self.singleInsertionFixture()
        let (result, resolution) = RevisionController.accept(revisionID: revisionID, in: ast)

        XCTAssertEqual(resolution.blocks.count, 1)
        XCTAssertEqual(resolution.blocks[0].action, .convertedToPlainContent)
        XCTAssertEqual(resolution.receiptType, DocReceiptType.revisionAccepted.rawValue)

        let block = try XCTUnwrap(result.blocks[revisionID])
        XCTAssertEqual(block.type, .paragraph)
        XCTAssertEqual(block.content.first?.text, "inserted text")
        XCTAssertNil(block.attributes["author"])
        XCTAssertNil(block.attributes["timestamp"])
        XCTAssertTrue(result.rootChildren.contains(revisionID))
    }

    func testAcceptDeletionRemovesBlockEntirely() throws {
        let (ast, revisionID) = Self.singleDeletionFixture()
        let (result, resolution) = RevisionController.accept(revisionID: revisionID, in: ast)

        XCTAssertEqual(resolution.blocks.count, 1)
        XCTAssertEqual(resolution.blocks[0].action, .removed)
        XCTAssertNil(result.blocks[revisionID])
        XCTAssertFalse(result.rootChildren.contains(revisionID))
    }

    func testRejectInsertionRemovesBlockEntirely() throws {
        let (ast, revisionID) = Self.singleInsertionFixture()
        let (result, resolution) = RevisionController.reject(revisionID: revisionID, in: ast)

        XCTAssertEqual(resolution.blocks[0].action, .removed)
        XCTAssertEqual(resolution.receiptType, DocReceiptType.revisionRejected.rawValue)
        XCTAssertNil(result.blocks[revisionID])
        XCTAssertFalse(result.rootChildren.contains(revisionID))
    }

    func testRejectDeletionConvertsToPlainContentRestoringText() throws {
        let (ast, revisionID) = Self.singleDeletionFixture()
        let (result, resolution) = RevisionController.reject(revisionID: revisionID, in: ast)

        XCTAssertEqual(resolution.blocks[0].action, .convertedToPlainContent)
        let block = try XCTUnwrap(result.blocks[revisionID])
        XCTAssertEqual(block.type, .paragraph)
        XCTAssertEqual(block.content.first?.text, "deleted text")
    }

    // MARK: - Unknown revision id is a safe no-op

    func testAcceptUnknownRevisionIDIsNoOp() {
        let (ast, _) = Self.singleInsertionFixture()
        let (result, resolution) = RevisionController.accept(revisionID: UUID(), in: ast)

        XCTAssertTrue(resolution.isEmpty)
        XCTAssertEqual(result, ast)
    }

    // MARK: - Multi-block grouped revision resolves atomically

    func testMultiBlockRevisionResolvesAllMembersAtomically() {
        let (ast, revisionID, ids) = Self.multiBlockInsertionFixture()
        let (result, resolution) = RevisionController.accept(revisionID: revisionID, in: ast)

        XCTAssertEqual(resolution.blocks.count, 3)
        XCTAssertTrue(resolution.blocks.allSatisfy { $0.action == .convertedToPlainContent })
        for id in ids {
            XCTAssertEqual(result.blocks[id]?.type, .paragraph)
        }
    }

    // MARK: - Move (paired insertion + deletion sharing revisionID)

    func testAcceptMoveKeepsDestinationDropsSource() {
        let (ast, revisionID, insID, delID) = Self.moveFixture()
        let (result, resolution) = RevisionController.accept(revisionID: revisionID, in: ast)

        XCTAssertTrue(resolution.isMove)
        XCTAssertEqual(result.blocks[insID]?.type, .paragraph)
        XCTAssertNil(result.blocks[delID])
        XCTAssertFalse(result.rootChildren.contains(delID))
        XCTAssertTrue(result.rootChildren.contains(insID))
    }

    func testRejectMoveKeepsSourceDropsDestination() {
        let (ast, revisionID, insID, delID) = Self.moveFixture()
        let (result, resolution) = RevisionController.reject(revisionID: revisionID, in: ast)

        XCTAssertTrue(resolution.isMove)
        XCTAssertNil(result.blocks[insID])
        XCTAssertEqual(result.blocks[delID]?.type, .paragraph)
    }

    // MARK: - Nested revisions: nested state survives an outer convert

    func testAcceptingOuterInsertionNeverTouchesNestedPendingDeletion() throws {
        let (ast, revisionA, revisionB, _) = Self.nestedRevisionFixture()
        let (result, _) = RevisionController.accept(revisionID: revisionA, in: ast)

        // A converted in place...
        let a = try XCTUnwrap(result.blocks[revisionA])
        XCTAssertEqual(a.type, .paragraph)
        // ...but B, still unresolved, is completely untouched and still
        // reachable from A's own (unchanged) children list.
        XCTAssertTrue(a.children.contains(revisionB))
        let b = try XCTUnwrap(result.blocks[revisionB])
        XCTAssertEqual(b.type, .trackDeletion)
        XCTAssertEqual(b.content.first?.text, "deleted text")
    }

    // MARK: - The design contract's own test: order-independent contentHash

    /// "B-deletes-inside-A-inserts resolves to the same contentHash in
    /// any order": accepting A (the outer trackInsertion) then B (the
    /// nested trackDeletion) must produce a tree byte-identical to
    /// accepting B then A.
    func testNestedRevisionAcceptOrderProducesIdenticalContentHash() throws {
        // One fixture value, reused for both orderings - `DocumentAST`
        // is a struct, so each `accept` call below operates on its own
        // copy-on-write snapshot of the SAME starting ids; neither
        // order can see the other's mutations, and both start from
        // byte-identical input (unlike calling the fixture builder
        // twice, which would mint two unrelated sets of UUIDs).
        let (ast, revisionA, revisionB, _) = Self.nestedRevisionFixture()

        // Order 1: A then B.
        let (afterA, _) = RevisionController.accept(revisionID: revisionA, in: ast)
        let (aThenB, _) = RevisionController.accept(revisionID: revisionB, in: afterA)

        // Order 2: B then A.
        let (afterB, _) = RevisionController.accept(revisionID: revisionB, in: ast)
        let (bThenA, _) = RevisionController.accept(revisionID: revisionA, in: afterB)

        let hashAThenB = try aThenB.contentHash()
        let hashBThenA = try bThenA.contentHash()
        XCTAssertEqual(hashAThenB, hashBThenA)

        // And both fully-resolved trees agree structurally: A is plain
        // content with only the surviving paragraph left as a child;
        // B is gone.
        XCTAssertEqual(aThenB, bThenA)
        XCTAssertNil(aThenB.blocks[revisionB])
        XCTAssertEqual(aThenB.blocks[revisionA]?.type, .paragraph)
        XCTAssertFalse(aThenB.blocks[revisionA]?.children.contains(revisionB) ?? true)
    }

    // MARK: - Purity: accept never mutates its input, so "undo" is reconstructible

    /// Simulates the undo half of the design contract's test without a
    /// real `ReceiptUndoManager`: `accept` never mutates the `DocumentAST`
    /// passed in, so the ORIGINAL block value (same id) is still sitting
    /// in `originalAST` after the call and can be spliced back in place
    /// of the accepted one to reproduce the exact pre-accept hash.
    func testAcceptThenSimulatedUndoRestoresPriorHash() throws {
        let (originalAST, revisionID) = Self.singleInsertionFixture()
        let originalHash = try originalAST.contentHash()

        let (accepted, resolution) = RevisionController.accept(revisionID: revisionID, in: originalAST)
        XCTAssertFalse(resolution.isEmpty)
        XCTAssertNotEqual(try accepted.contentHash(), originalHash)

        // `originalAST` itself is untouched (pure function) - re-hashing
        // it directly already proves nothing was lost, but the receipt-
        // driven undo path re-creates the block by id rather than
        // keeping the old AST around, so simulate that path explicitly.
        var undone = accepted
        undone.blocks[revisionID] = originalAST.blocks[revisionID]
        XCTAssertEqual(try undone.contentHash(), originalHash)
        XCTAssertEqual(try originalAST.contentHash(), originalHash)
    }
}
