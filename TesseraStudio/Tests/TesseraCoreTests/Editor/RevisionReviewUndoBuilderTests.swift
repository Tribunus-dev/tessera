import XCTest
import CryptoKit
@testable import TesseraCore

// MARK: - RevisionReviewUndoBuilderTests
//
// Contract: sota-p2-core-report.md section 2.9 - "Accept-all / per-author
// = loop wrapped in ReceiptUndoManager.group (one Cmd-Z)" - plus this
// track's own tests list: "accept-all produces exactly one undo unit".
// `RevisionReviewUndoBuilder.mutations(for:baseAST:)` is the pure half of
// that bookkeeping (no signing, no ReceiptUndoManager, no store); this
// file also exercises it end to end through a REAL `ReceiptSigner`
// (injected key, per ReceiptSigner's own testing seam - no Keychain
// needed) and a REAL `ReceiptUndoManager`, neither of which touches a
// database, so "one undo unit" is verifiable without DocStore/
// TesseraDataLayer (this codebase has no in-memory stub for either - see
// DocStoreTests.swift's own header, and RevisionReviewStoreTests.swift
// for the DB-gated shadow of this same contract at the store level).
//
// "One undo unit" here means what ReceiptUndoManagerTests.swift's own
// ratified `testGroupAppendsEveryReceiptToTheUndoStackInOrder` contract
// means: every receipt from the batch lands on the undo stack via
// exactly ONE `ReceiptUndoManager.group(_:)` call, matching
// `DrawCanvasView.registerUndo`'s "one drag is one undo unit" framing -
// not that a single `undo()` call unwinds the whole batch atomically
// (ReceiptUndoManager pops one receipt per `undo()` call regardless of
// how it was pushed; that is the already-ratified contract, not
// something this track redefines).

final class RevisionReviewUndoBuilderTests: DoctrineTestCase {

    private func makeSigner() -> ReceiptSigner {
        ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())
    }

    /// Two independent pending insertions from the same author - the
    /// fixture "accept-all" exercises.
    private func twoInsertionFixture() -> (ast: DocumentAST, aID: UUID, bID: UUID) {
        let aID = UUID()
        let bID = UUID()
        var ast = DocumentAST()
        ast.blocks[aID] = Block(id: aID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "first")])
        ast.blocks[bID] = Block(id: bID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "second")])
        ast.rootChildren = [aID, bID]
        return (ast, aID, bID)
    }

    /// Runs the exact precompute `RevisionReviewStore.resolve` runs: pure
    /// `RevisionController.accept`/`reject` per id, threading the working
    /// AST through in order.
    private func plan(
        _ ids: [UUID], direction: RevisionDirection, from ast: DocumentAST
    ) -> (entries: [RevisionReviewUndoBuilder.ResolvedEntry], finalAST: DocumentAST) {
        var workingAST = ast
        var entries: [RevisionReviewUndoBuilder.ResolvedEntry] = []
        for id in ids {
            let (resolved, resolution) = direction == .accept
                ? RevisionController.accept(revisionID: id, in: workingAST)
                : RevisionController.reject(revisionID: id, in: workingAST)
            entries.append(.init(resolution: resolution, postAST: resolved))
            workingAST = resolved
        }
        return (entries, workingAST)
    }

    // MARK: - mutations(for:baseAST:)

    func testMutationsForAcceptedInsertionsReplayToTheSameFinalStateAsRevisionController() throws {
        let (ast, aID, bID) = twoInsertionFixture()
        let (entries, finalAST) = plan([aID, bID], direction: .accept, from: ast)

        let mutations = try RevisionReviewUndoBuilder.mutations(for: entries, baseAST: ast)
        XCTAssertEqual(mutations.count, 2, "one mutation per accepted revision")

        // Replaying the builder's own mutations from the SAME base AST
        // must reach the same final state RevisionController itself
        // produced - the local undo chain is not silently divergent from
        // the real, persisted resolution.
        var engine = MutationEngine()
        var replayed = ast
        for mutation in mutations { _ = try engine.apply(mutation, to: &replayed) }
        XCTAssertEqual(try replayed.contentHash(), try finalAST.contentHash())
    }

    func testMutationForAnAcceptedInsertionIsAReplaceToPlainParagraph() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "kept")])
        ast.rootChildren = [id]

        let (entries, _) = plan([id], direction: .accept, from: ast)
        let mutations = try RevisionReviewUndoBuilder.mutations(for: entries, baseAST: ast)

        guard case .replaceBlock(let blockID, let block) = mutations.first else {
            return XCTFail("expected exactly one replaceBlock mutation")
        }
        XCTAssertEqual(blockID, id)
        XCTAssertEqual(block.type, .paragraph)
    }

    func testMutationForARejectedInsertionIsADeletion() throws {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "unwanted")])
        ast.rootChildren = [id]

        let (entries, _) = plan([id], direction: .reject, from: ast)
        let mutations = try RevisionReviewUndoBuilder.mutations(for: entries, baseAST: ast)

        XCTAssertEqual(mutations, [.deleteBlock(blockID: id)])
    }

    func testEmptyResolutionProducesNoMutations() throws {
        // An unknown/already-resolved revisionID resolves to an EMPTY
        // RevisionResolution (RevisionController's own no-op contract) -
        // the builder must not synthesize a mutation for it.
        let (resolved, resolution) = RevisionController.accept(revisionID: UUID(), in: .empty)
        XCTAssertTrue(resolution.isEmpty)
        let mutations = try RevisionReviewUndoBuilder.mutations(
            for: [.init(resolution: resolution, postAST: resolved)], baseAST: .empty
        )
        XCTAssertTrue(mutations.isEmpty)
    }

    // MARK: - Accept-all = one undo unit

    func testAcceptAllGroupsEveryReceiptIntoOneUndoUnit() throws {
        let (ast, aID, bID) = twoInsertionFixture()
        let (entries, _) = plan([aID, bID], direction: .accept, from: ast)
        let mutations = try RevisionReviewUndoBuilder.mutations(for: entries, baseAST: ast)

        let documentID = UUID()
        let signer = makeSigner()
        let undoManager = ReceiptUndoManager(documentID: documentID)
        var engine = MutationEngine()
        var applyBody = ast
        var receipts: [Receipt] = []
        var priorID: UUID?
        for mutation in mutations {
            let pre = try engine.apply(mutation, to: &applyBody)
            let receipt = try signer.sign(
                documentID: documentID, mutations: [mutation], priorReceiptID: priorID,
                actor: .user(UUID()), preMutationSnapshot: pre
            )
            receipts.append(receipt)
            priorID = receipt.id
        }

        XCTAssertTrue(undoManager.snapshotUndoStack().isEmpty, "nothing registered before the batch")
        undoManager.group(receipts)

        XCTAssertEqual(undoManager.snapshotUndoStack(), receipts, "one group() call carries every receipt from the batch, in order")
        XCTAssertEqual(undoManager.snapshotUndoStack().count, 2, "one receipt per accepted revision, both from the SAME group() call")
    }
}
