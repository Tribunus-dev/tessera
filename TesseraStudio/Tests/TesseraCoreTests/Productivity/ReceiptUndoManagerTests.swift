import XCTest
import CryptoKit
@testable import TesseraCore

/// Tests for the receipt-aware Undo/Redo manager.
final class ReceiptUndoManagerTests: XCTestCase {

    private var signer: ReceiptSigner!
    private var key: Curve25519.Signing.PrivateKey!
    private var documentID: UUID!

    override func setUp() {
        super.setUp()
        key = Curve25519.Signing.PrivateKey()
        signer = ReceiptSigner(signingKey: key)
        documentID = UUID()
    }

    // MARK: - Helpers

    /// Build a document with one heading + one paragraph.
    private func makeDocument() -> DocumentAST {
        let heading = Block(
            type: .heading,
            attributes: ["level": .number(1)],
            content: [InlineRun(text: "Title")]
        )
        let para = Block(
            type: .paragraph,
            content: [InlineRun(text: "Body text")]
        )
        return DocumentAST(
            blocks: [heading.id: heading, para.id: para],
            rootChildren: [heading.id, para.id]
        )
    }

    /// Apply a mutation to a document, then sign a receipt that
    /// captures the pre-mutation snapshot. Returns the receipt.
    /// The undo manager needs the pre-snapshot in the receipt so
    /// the undo can rebuild the inverse without the live document.
    private func applyAndSign(
        _ mutations: [Mutation],
        to document: inout DocumentAST,
        priorReceiptID: UUID? = nil,
        actor: Actor = .user(UUID())
    ) throws -> Receipt {
        var engine = MutationEngine()
        var preSnapshot: [UUID: Block] = [:]
        for mutation in mutations {
            let pre = try engine.apply(mutation, to: &document)
            for (k, v) in pre { preSnapshot[k] = v }
        }
        return try signer.sign(
            documentID: documentID,
            mutations: mutations,
            priorReceiptID: priorReceiptID,
            actor: actor,
            preMutationSnapshot: preSnapshot
        )
    }

    // MARK: - Single mutation: undo + redo

    func testSingleMutationUndoAndRedo() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(
            type: .heading,
            attributes: ["level": .number(1)],
            content: [InlineRun(text: "Original")]
        )
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])

        // 1. Register a "replace content" mutation.
        let receipt = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "Updated")]
            )],
            to: &doc
        )
        manager.register(receipt)
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertEqual(doc.blocks[heading.id]?.content.first?.text, "Updated")

        // 2. Undo: should restore the original content.
        let result = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            result.updatedDocument.blocks[heading.id]?.content.first?.text,
            "Original"
        )
        XCTAssertEqual(result.voidedReceiptID, receipt.id)
        XCTAssertEqual(result.inverseReceipt.mutations.count, 1)
        XCTAssertFalse(manager.canUndo)
        XCTAssertTrue(manager.canRedo)

        // 3. Redo: should re-apply the "Updated" content.
        let redoResult = try manager.redo(
            document: result.updatedDocument,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            redoResult.updatedDocument.blocks[heading.id]?.content.first?.text,
            "Updated"
        )
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
    }

    // MARK: - Empty stack

    func testUndoOnEmptyStackThrows() {
        let manager = ReceiptUndoManager(documentID: documentID)
        XCTAssertFalse(manager.canUndo)
        XCTAssertThrowsError(try manager.undo(
            document: DocumentAST.empty,
            actor: .user(UUID()),
            signer: signer
        )) { error in
            guard case UndoError.emptyStack = error else {
                XCTFail("expected emptyStack, got \(error)")
                return
            }
        }
    }

    func testRedoOnEmptyStackThrows() {
        let manager = ReceiptUndoManager(documentID: documentID)
        XCTAssertFalse(manager.canRedo)
        XCTAssertThrowsError(try manager.redo(
            document: DocumentAST.empty,
            actor: .user(UUID()),
            signer: signer
        )) { error in
            guard case UndoError.emptyStack = error else {
                XCTFail("expected emptyStack, got \(error)")
                return
            }
        }
    }

    // MARK: - Batched mutations

    func testBatchedMutationsUndoAsOneUnit() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        var doc = DocumentAST.empty
        let heading = Block(type: .heading, attributes: ["level": .number(1)])
        let para = Block(type: .paragraph)

        // Register the two mutations as one batch (single receipt).
        let receipt = try applyAndSign(
            [
                .insertBlockAfter(parentID: nil, anchorID: nil, block: heading),
                .insertBlockAfter(parentID: nil, anchorID: heading.id, block: para)
            ],
            to: &doc
        )
        manager.register(receipt)
        XCTAssertEqual(doc.rootChildren, [heading.id, para.id])

        // Undo: should remove both blocks.
        let result = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertTrue(result.updatedDocument.rootChildren.isEmpty)
        XCTAssertFalse(result.updatedDocument.contains(heading.id))
        XCTAssertFalse(result.updatedDocument.contains(para.id))
    }

    func testGroupMultipleReceiptsAsOneUndoUnit() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        var doc = DocumentAST.empty
        let heading = Block(type: .heading, attributes: ["level": .number(1)])
        let para = Block(type: .paragraph)
        let para2 = Block(type: .paragraph)
        let r1 = try applyAndSign(
            [.insertBlockAfter(parentID: nil, anchorID: nil, block: heading)],
            to: &doc
        )
        let r2 = try applyAndSign(
            [
                .insertBlockAfter(parentID: nil, anchorID: heading.id, block: para),
                .insertBlockAfter(parentID: nil, anchorID: para.id, block: para2)
            ],
            to: &doc,
            priorReceiptID: r1.id
        )
        manager.group([r1, r2])
        XCTAssertEqual(doc.rootChildren, [heading.id, para.id, para2.id])

        // Undo undoes both in reverse order.
        let result = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(result.updatedDocument.rootChildren, [heading.id])
    }

    // MARK: - Undo of undo

    func testUndoOfUndoRestoresOriginal() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(
            type: .heading,
            attributes: ["level": .number(1)],
            content: [InlineRun(text: "Original")]
        )
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])
        let receipt = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "Updated")]
            )],
            to: &doc
        )
        manager.register(receipt)

        // Undo.
        let undo1 = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            undo1.updatedDocument.blocks[heading.id]?.content.first?.text,
            "Original"
        )
        // Redo.
        let undo2 = try manager.redo(
            document: undo1.updatedDocument,
            actor: .user(UUID()),
            signer: signer
        )
        // After redo we should be back to "Updated".
        XCTAssertEqual(
            undo2.updatedDocument.blocks[heading.id]?.content.first?.text,
            "Updated"
        )
    }

    // MARK: - Redo stack semantics

    func testNewEditClearsRedoStack() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(type: .heading, content: [InlineRun(text: "h")])
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])

        let r1 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v1")]
            )],
            to: &doc
        )
        manager.register(r1)
        // Undo to populate the redo stack.
        _ = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertTrue(manager.canRedo)

        // New edit clears the redo stack.
        let r2 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v2")]
            )],
            to: &doc,
            priorReceiptID: r1.id
        )
        manager.register(r2)
        XCTAssertFalse(manager.canRedo)
    }

    // MARK: - Voiding

    func testUndoMarksOriginalVoidedInChain() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(
            type: .heading,
            content: [InlineRun(text: "Original")]
        )
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])
        let receipt = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "Updated")]
            )],
            to: &doc
        )
        manager.register(receipt)
        let result = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        // The original receipt should now be voided by the inverse.
        // Voided originals are kept in a separate log so the
        // audit trail captures the voiding.
        let voided = manager.snapshotVoidedReceipts()
        let original = voided.first { $0.id == receipt.id }
        XCTAssertEqual(original?.voidedBy, result.inverseReceipt.id)
    }

    // MARK: - Persistence: snapshot + restore

    func testSnapshotAndRestore() throws {
        let manager1 = ReceiptUndoManager(documentID: documentID)
        let heading = Block(type: .heading, content: [InlineRun(text: "h")])
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])
        let r1 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v1")]
            )],
            to: &doc
        )
        manager1.register(r1)
        _ = try manager1.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )

        // Simulate document close + reopen.
        let undoSnapshot = manager1.snapshotUndoStack()
        let redoSnapshot = manager1.snapshotRedoStack()

        let manager2 = ReceiptUndoManager(documentID: documentID)
        manager2.restore(undoStack: undoSnapshot, redoStack: redoSnapshot)
        XCTAssertEqual(manager2.snapshotUndoStack().count, undoSnapshot.count)
        XCTAssertEqual(manager2.snapshotRedoStack().count, redoSnapshot.count)
        XCTAssertTrue(manager2.canRedo)
    }

    func testDocumentOpenWithInitialReceipt() throws {
        let heading = Block(type: .heading, content: [InlineRun(text: "h")])
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])
        let r1 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v1")]
            )],
            to: &doc
        )
        let manager = ReceiptUndoManager(
            documentID: documentID,
            initialReceipt: r1
        )
        XCTAssertTrue(manager.canUndo)
        // Undoing the initial receipt restores the empty content.
        let result = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertNotNil(result.inverseReceipt)
    }

    // MARK: - Chain walking

    /// The inverse receipt's `priorReceiptID` is the original receipt's ID.
    /// This is the property that makes the chain walkable: each receipt
    /// points at the one that preceded it, so the full history can be
    /// reconstructed by following `priorReceiptID` links.
    func testInverseReceiptChainsToOriginal() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(
            type: .heading,
            content: [InlineRun(text: "v0")]
        )
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])

        // Receipt r1 sets "v0" -> "v1".
        let r1 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v1")]
            )],
            to: &doc
        )
        manager.register(r1)

        // Undo r1: the inverse should chain to r1.
        let undo1 = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(undo1.inverseReceipt.priorReceiptID, r1.id)
        XCTAssertEqual(undo1.inverseReceipt.documentID, documentID)
        XCTAssertEqual(undo1.inverseReceipt.signature.count, 64)
    }

    /// Undo/redo correctly walks the chain in reverse order. Three
    /// sequential edits (r1, r2, r3) can be undone in LIFO order
    /// (r3, r2, r1), and each undo creates a new receipt chained to
    /// the previous one.
    func testUndoManagerWalksChainBackward() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(
            type: .heading,
            content: [InlineRun(text: "v0")]
        )
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])

        // r1: v0 -> v1
        let r1 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v1")]
            )],
            to: &doc
        )
        manager.register(r1)

        // r2: v1 -> v2
        let r2 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v2")]
            )],
            to: &doc,
            priorReceiptID: r1.id
        )
        manager.register(r2)

        // r3: v2 -> v3
        let r3 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v3")]
            )],
            to: &doc,
            priorReceiptID: r2.id
        )
        manager.register(r3)

        XCTAssertEqual(doc.blocks[heading.id]?.content.first?.text, "v3")

        // Undo r3: should restore v2.
        let undo3 = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            undo3.updatedDocument.blocks[heading.id]?.content.first?.text,
            "v2"
        )
        XCTAssertEqual(undo3.inverseReceipt.priorReceiptID, r3.id)
        XCTAssertEqual(undo3.voidedReceiptID, r3.id)

        // Undo r2: should restore v1. The inverse of r2 should
        // have the original's mutations, chained to the inverse of r3.
        let undo2 = try manager.undo(
            document: undo3.updatedDocument,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            undo2.updatedDocument.blocks[heading.id]?.content.first?.text,
            "v1"
        )
        XCTAssertEqual(undo2.inverseReceipt.priorReceiptID, r2.id)

        // The two inverse receipts (undo3, undo2) have different IDs.
        XCTAssertNotEqual(undo3.inverseReceipt.id, undo2.inverseReceipt.id)

        // Both originals are in the voided log.
        let voided = manager.snapshotVoidedReceipts()
        let voidedIDs = Set(voided.map { $0.id })
        XCTAssertTrue(voidedIDs.contains(r3.id))
        XCTAssertTrue(voidedIDs.contains(r2.id))
        XCTAssertFalse(voidedIDs.contains(r1.id))
    }

    /// Redo correctly re-applies the original mutations. After
    /// undo( r3) -> v2, redo should restore v3.
    func testRedoRestoresOriginalState() throws {
        let manager = ReceiptUndoManager(documentID: documentID)
        let heading = Block(
            type: .heading,
            content: [InlineRun(text: "v0")]
        )
        var doc = DocumentAST(blocks: [heading.id: heading], rootChildren: [heading.id])

        let r1 = try applyAndSign(
            [.setBlockContent(
                blockID: heading.id,
                content: [InlineRun(text: "v1")]
            )],
            to: &doc
        )
        manager.register(r1)

        // Undo r1 -> v0.
        let undo1 = try manager.undo(
            document: doc,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            undo1.updatedDocument.blocks[heading.id]?.content.first?.text,
            "v0"
        )

        // Redo should bring us back to v1.
        let redo1 = try manager.redo(
            document: undo1.updatedDocument,
            actor: .user(UUID()),
            signer: signer
        )
        XCTAssertEqual(
            redo1.updatedDocument.blocks[heading.id]?.content.first?.text,
            "v1"
        )
        // The redo receipt voids r1 and is itself undoable.
        XCTAssertEqual(redo1.inverseReceipt.priorReceiptID, r1.id)
        XCTAssertEqual(redo1.voidedReceiptID, r1.id)
    }
}
