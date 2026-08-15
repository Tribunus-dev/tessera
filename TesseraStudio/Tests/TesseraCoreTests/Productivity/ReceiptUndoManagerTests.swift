import XCTest
import CryptoKit
@testable import TesseraCore

// MARK: - ReceiptUndoManagerTests
//
// Contract: ReceiptUndoManager.swift's own doc comments - "One undo unit =
// one receipt"; "register(_:) - Push a new receipt onto the undo stack.
// Clears the redo stack"; "undo(...) - The inverse is computed via
// Mutation/inverse(against:), applied to a copy of the document, and
// signed as a new receipt. The original receipt is marked voidedBy in
// memory"; "redo(...) - re-applies the inverse receipt's mutations to the
// document... signs a new 'redo' receipt that voids the inverse
// [original] receipt."

final class ReceiptUndoManagerTests: DoctrineTestCase {

    private func makeSigner() -> ReceiptSigner {
        ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())
    }

    /// A document with one block whose content is "original"; a signed
    /// receipt (with a real pre-mutation snapshot) that changed it to
    /// "changed"; and the document AFTER that mutation was applied - the
    /// state a caller would hold right after committing the original edit.
    private func editedDocumentFixture(documentID: UUID, signer: ReceiptSigner) throws -> (
        postMutationDocument: DocumentAST, originalReceipt: Receipt, blockID: UUID
    ) {
        let blockID = UUID()
        var document = DocumentAST()
        document.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "original")])
        document.rootChildren = [blockID]

        var engine = MutationEngine()
        let mutation = Mutation.setBlockContent(blockID: blockID, content: [InlineRun(text: "changed")])
        let pre = try engine.apply(mutation, to: &document)

        let receipt = try signer.sign(
            documentID: documentID, mutations: [mutation], priorReceiptID: nil,
            actor: .user(UUID()), preMutationSnapshot: pre
        )
        return (document, receipt, blockID)
    }

    // MARK: - register / canUndo / canRedo

    func testCanUndoFalseInitiallyWithNoInitialReceipt() {
        let manager = ReceiptUndoManager(documentID: UUID())
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
    }

    func testRegisterMakesCanUndoTrueAndClearsRedoStack() throws {
        let documentID = UUID()
        let manager = ReceiptUndoManager(documentID: documentID)
        let signer = makeSigner()
        let receipt = try signer.sign(documentID: documentID, mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        manager.register(receipt)
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.snapshotUndoStack(), [receipt])
    }

    func testGroupAppendsEveryReceiptToTheUndoStackInOrder() throws {
        let documentID = UUID()
        let manager = ReceiptUndoManager(documentID: documentID)
        let signer = makeSigner()
        let r1 = try signer.sign(documentID: documentID, mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        let r2 = try signer.sign(documentID: documentID, mutations: [], priorReceiptID: r1.id, actor: .user(UUID()))
        manager.group([r1, r2])
        XCTAssertEqual(manager.snapshotUndoStack(), [r1, r2])
    }

    // MARK: - undo(): computes the real inverse, restores content, voids the original

    func testUndoRestoresThePreMutationContentAndReturnsTheOriginalAsVoidedReceiptID() throws {
        let documentID = UUID()
        let signer = makeSigner()
        let (postMutationDocument, originalReceipt, blockID) = try editedDocumentFixture(documentID: documentID, signer: signer)
        let manager = ReceiptUndoManager(documentID: documentID, initialReceipt: originalReceipt)

        let result = try manager.undo(document: postMutationDocument, actor: .user(UUID()), signer: signer)

        XCTAssertEqual(result.updatedDocument.blocks[blockID]?.content, [InlineRun(text: "original")],
                        "undo must apply the real Mutation.inverse computed from the receipt's own pre-mutation snapshot")
        XCTAssertEqual(result.voidedReceiptID, originalReceipt.id)
        XCTAssertEqual(result.inverseReceipt.priorReceiptID, originalReceipt.id)
        XCTAssertFalse(manager.canUndo, "the undone receipt must leave the undo stack")
        XCTAssertTrue(manager.canRedo, "the undone receipt must become available to redo")
    }

    func testUndoMarksTheOriginalAsVoidedInTheVoidedReceiptsLog() throws {
        let documentID = UUID()
        let signer = makeSigner()
        let (postMutationDocument, originalReceipt, _) = try editedDocumentFixture(documentID: documentID, signer: signer)
        let manager = ReceiptUndoManager(documentID: documentID, initialReceipt: originalReceipt)

        let result = try manager.undo(document: postMutationDocument, actor: .user(UUID()), signer: signer)

        let voided = manager.snapshotVoidedReceipts()
        XCTAssertEqual(voided.count, 1)
        XCTAssertEqual(voided.first?.id, originalReceipt.id)
        XCTAssertEqual(voided.first?.voidedBy, result.inverseReceipt.id)
    }

    func testUndoOnEmptyStackThrowsEmptyStack() {
        let manager = ReceiptUndoManager(documentID: UUID())
        let signer = makeSigner()
        XCTAssertThrowsError(try manager.undo(document: .empty, actor: .user(UUID()), signer: signer)) { error in
            XCTAssertEqual(error as? UndoError, .emptyStack)
        }
    }

    // MARK: - redo(): re-applies the original's own mutations, voids via a new receipt

    func testRedoReappliesTheOriginalMutationAndRestoresThePostMutationState() throws {
        let documentID = UUID()
        let signer = makeSigner()
        let (postMutationDocument, originalReceipt, blockID) = try editedDocumentFixture(documentID: documentID, signer: signer)
        let manager = ReceiptUndoManager(documentID: documentID, initialReceipt: originalReceipt)

        let undoResult = try manager.undo(document: postMutationDocument, actor: .user(UUID()), signer: signer)
        let redoResult = try manager.redo(document: undoResult.updatedDocument, actor: .user(UUID()), signer: signer)

        XCTAssertEqual(redoResult.updatedDocument.blocks[blockID]?.content, [InlineRun(text: "changed")],
                        "redo must re-apply the original receipt's own mutations")
        XCTAssertTrue(manager.canUndo, "after redo, the redo receipt must be back on the undo stack")
        XCTAssertFalse(manager.canRedo)
    }

    func testRedoOnEmptyRedoStackThrowsEmptyStack() {
        let manager = ReceiptUndoManager(documentID: UUID())
        let signer = makeSigner()
        XCTAssertThrowsError(try manager.redo(document: .empty, actor: .user(UUID()), signer: signer)) { error in
            XCTAssertEqual(error as? UndoError, .emptyStack)
        }
    }

    // MARK: - restore(): rebuild in-memory state from a persisted snapshot

    func testRestoreReplacesTheStacksVerbatim() throws {
        let documentID = UUID()
        let signer = makeSigner()
        let manager = ReceiptUndoManager(documentID: documentID)
        let r1 = try signer.sign(documentID: documentID, mutations: [], priorReceiptID: nil, actor: .user(UUID()))
        let r2 = try signer.sign(documentID: documentID, mutations: [], priorReceiptID: r1.id, actor: .user(UUID()))

        manager.restore(undoStack: [r1], redoStack: [r2], voidedReceipts: [])
        XCTAssertEqual(manager.snapshotUndoStack(), [r1])
        XCTAssertEqual(manager.snapshotRedoStack(), [r2])
        XCTAssertTrue(manager.canUndo)
        XCTAssertTrue(manager.canRedo)
    }

    // MARK: - documentID is exposed for the caller's replay() step

    func testDocumentIDIsExposed() {
        let id = UUID()
        let manager = ReceiptUndoManager(documentID: id)
        XCTAssertEqual(manager.documentID, id)
    }
}
