import XCTest
@testable import TesseraCore

// MARK: - MutationEngineTests
//
// Contract: MutationEngine.swift's own doc comments - "Validate a mutation
// against the current document state. Throws MutationError if the
// mutation is invalid"; "Apply a mutation to the document, in place...
// Returns a [UUID: Block] snapshot of the blocks the mutation touched, in
// their PRE-mutation state" - the snapshot ReceiptSigner/ReceiptUndoManager
// depend on for undo. Coverage shape (engine/controller): contract
// fixtures + property (apply-then-validate-fails-differently is out of
// scope; the cheap property tested here is "a validated mutation always
// applies without throwing") + trap guards (cycle prevention).

final class MutationEngineTests: DoctrineTestCase {

    private func emptyDocument() -> DocumentAST { .empty }

    private func documentWithOneBlock() -> (ast: DocumentAST, id: UUID) {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: "hi")])
        ast.rootChildren = [id]
        return (ast, id)
    }

    // MARK: - insertBlockAfter

    func testInsertBlockAfterNilAnchorPrependsToRootChildren() throws {
        var (ast, existingID) = documentWithOneBlock()
        var engine = MutationEngine()
        let newID = UUID()
        _ = try engine.apply(.insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: newID, type: .paragraph)), to: &ast)
        XCTAssertEqual(ast.rootChildren, [newID, existingID])
    }

    func testInsertBlockAfterAnchorInsertsImmediatelyAfterIt() throws {
        var (ast, anchorID) = documentWithOneBlock()
        var engine = MutationEngine()
        let newID = UUID()
        _ = try engine.apply(.insertBlockAfter(parentID: nil, anchorID: anchorID, block: Block(id: newID, type: .paragraph)), to: &ast)
        XCTAssertEqual(ast.rootChildren, [anchorID, newID])
    }

    func testInsertBlockAfterSetsParentIDOnTheNewBlock() throws {
        let parentID = UUID()
        var ast = DocumentAST()
        ast.blocks[parentID] = Block(id: parentID, type: .toggle)
        ast.rootChildren = [parentID]
        var engine = MutationEngine()
        let childID = UUID()
        _ = try engine.apply(.insertBlockAfter(parentID: parentID, anchorID: nil, block: Block(id: childID, type: .paragraph)), to: &ast)
        XCTAssertEqual(ast.blocks[childID]?.parentID, parentID)
        XCTAssertEqual(ast.blocks[parentID]?.children, [childID])
    }

    // MARK: - Validation errors (trap guards)

    func testInsertBlockAfterUnknownParentThrowsBlockNotFound() {
        var ast = emptyDocument()
        var engine = MutationEngine()
        let unknownParent = UUID()
        XCTAssertThrowsError(try engine.apply(.insertBlockAfter(parentID: unknownParent, anchorID: nil, block: Block(type: .paragraph)), to: &ast)) { error in
            XCTAssertEqual(error as? MutationError, .blockNotFound(blockID: unknownParent))
        }
    }

    func testInsertBlockAfterAnchorNotInThatParentThrowsAnchorNotFound() {
        let parentID = UUID()
        let anchorOutsideParentID = UUID()
        var ast = DocumentAST()
        ast.blocks[parentID] = Block(id: parentID, type: .toggle)
        ast.blocks[anchorOutsideParentID] = Block(id: anchorOutsideParentID, type: .paragraph) // a root block, not a child of parentID
        ast.rootChildren = [parentID, anchorOutsideParentID]
        var engine = MutationEngine()
        XCTAssertThrowsError(try engine.apply(.insertBlockAfter(parentID: parentID, anchorID: anchorOutsideParentID, block: Block(type: .paragraph)), to: &ast)) { error in
            XCTAssertEqual(error as? MutationError, .anchorNotFound(parentID: parentID, anchorID: anchorOutsideParentID))
        }
    }

    // MARK: - deleteBlock

    func testDeleteBlockRemovesItAndUnlinksFromRootChildren() throws {
        var (ast, id) = documentWithOneBlock()
        var engine = MutationEngine()
        _ = try engine.apply(.deleteBlock(blockID: id), to: &ast)
        XCTAssertNil(ast.blocks[id])
        XCTAssertFalse(ast.rootChildren.contains(id))
    }

    func testDeleteUnknownBlockThrowsBlockNotFoundWithoutMutating() {
        var (ast, existingID) = documentWithOneBlock()
        var engine = MutationEngine()
        let unknown = UUID()
        XCTAssertThrowsError(try engine.apply(.deleteBlock(blockID: unknown), to: &ast)) { error in
            XCTAssertEqual(error as? MutationError, .blockNotFound(blockID: unknown))
        }
        XCTAssertNotNil(ast.blocks[existingID], "a failed validation must leave the document untouched")
    }

    // MARK: - moveBlock: cycle guard

    func testMoveBlockIntoOwnDescendantThrowsWouldCreateCycle() {
        let parentID = UUID()
        let childID = UUID()
        var ast = DocumentAST()
        ast.blocks[parentID] = Block(id: parentID, type: .toggle, children: [childID])
        ast.blocks[childID] = Block(id: childID, type: .toggle, parentID: parentID)
        ast.rootChildren = [parentID]
        var engine = MutationEngine()
        XCTAssertThrowsError(try engine.apply(.moveBlock(blockID: parentID, newParent: childID, newIndex: 0), to: &ast)) { error in
            XCTAssertEqual(error as? MutationError, .wouldCreateCycle(blockID: parentID, newParent: childID))
        }
    }

    func testMoveBlockRelocatesUnderNewParentAtRequestedIndex() throws {
        let oldParentID = UUID()
        let newParentID = UUID()
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[oldParentID] = Block(id: oldParentID, type: .toggle, children: [blockID])
        ast.blocks[newParentID] = Block(id: newParentID, type: .toggle)
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, parentID: oldParentID)
        ast.rootChildren = [oldParentID, newParentID]
        var engine = MutationEngine()
        _ = try engine.apply(.moveBlock(blockID: blockID, newParent: newParentID, newIndex: 0), to: &ast)
        XCTAssertEqual(ast.blocks[oldParentID]?.children, [], "must be detached from the old parent")
        XCTAssertEqual(ast.blocks[newParentID]?.children, [blockID])
        XCTAssertEqual(ast.blocks[blockID]?.parentID, newParentID)
    }

    // MARK: - setBlockContent: divider guard

    func testSetBlockContentOnDividerThrowsInvalidOperation() {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .divider)
        ast.rootChildren = [id]
        var engine = MutationEngine()
        XCTAssertThrowsError(try engine.apply(.setBlockContent(blockID: id, content: [InlineRun(text: "x")]), to: &ast)) { error in
            guard case .invalidOperation = error as? MutationError else {
                return XCTFail("expected .invalidOperation, got \(error)")
            }
        }
    }

    // MARK: - Inline run mutations + bounds checks

    func testAppendInlineRunAppendsToContent() throws {
        var (ast, id) = documentWithOneBlock()
        var engine = MutationEngine()
        _ = try engine.apply(.appendInlineRun(blockID: id, run: InlineRun(text: " more")), to: &ast)
        XCTAssertEqual(ast.blocks[id]?.content.map(\.text), ["hi", " more"])
    }

    func testDeleteInlineRunOutOfRangeThrowsInlineIndexOutOfRange() {
        var (ast, id) = documentWithOneBlock()
        var engine = MutationEngine()
        XCTAssertThrowsError(try engine.apply(.deleteInlineRun(blockID: id, index: 5), to: &ast)) { error in
            XCTAssertEqual(error as? MutationError, .inlineIndexOutOfRange(blockID: id, index: 5, count: 1))
        }
    }

    func testSetInlineAnnotationEnabledTrueAddsAnnotationOnce() throws {
        var (ast, id) = documentWithOneBlock()
        var engine = MutationEngine()
        _ = try engine.apply(.setInlineAnnotation(blockID: id, index: 0, annotation: .bold, enabled: true), to: &ast)
        _ = try engine.apply(.setInlineAnnotation(blockID: id, index: 0, annotation: .bold, enabled: true), to: &ast)
        XCTAssertEqual(ast.blocks[id]?.content[0].annotations, [.bold], "enabling an already-present annotation must not duplicate it")
    }

    func testSetInlineAnnotationEnabledFalseRemovesAnnotation() throws {
        var (ast, id) = documentWithOneBlock()
        ast.blocks[id]?.content = [InlineRun(text: "hi", annotations: [.bold, .italic])]
        var engine = MutationEngine()
        _ = try engine.apply(.setInlineAnnotation(blockID: id, index: 0, annotation: .bold, enabled: false), to: &ast)
        XCTAssertEqual(ast.blocks[id]?.content[0].annotations, [.italic])
    }

    // MARK: - Pre-mutation snapshot (what ReceiptSigner/undo depend on)

    func testApplyReplaceBlockCapturesThePreMutationSnapshot() throws {
        var (ast, id) = documentWithOneBlock()
        let originalBlock = ast.blocks[id]!
        var engine = MutationEngine()
        let pre = try engine.apply(.replaceBlock(blockID: id, block: Block(id: id, type: .paragraph, content: [InlineRun(text: "changed")])), to: &ast)
        XCTAssertEqual(pre[id], originalBlock, "the snapshot must carry the block's state BEFORE the mutation ran")
        XCTAssertEqual(ast.blocks[id]?.content.first?.text, "changed")
    }

    func testApplyMoveBlockSnapshotsBothOldAndNewParent() throws {
        let oldParentID = UUID()
        let newParentID = UUID()
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[oldParentID] = Block(id: oldParentID, type: .toggle, children: [blockID])
        ast.blocks[newParentID] = Block(id: newParentID, type: .toggle)
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, parentID: oldParentID)
        ast.rootChildren = [oldParentID, newParentID]
        var engine = MutationEngine()
        let pre = try engine.apply(.moveBlock(blockID: blockID, newParent: newParentID, newIndex: 0), to: &ast)
        XCTAssertNotNil(pre[oldParentID])
        XCTAssertNotNil(pre[newParentID])
        XCTAssertNotNil(pre[blockID])
    }

    // MARK: - Property: a mutation that validates cleanly always applies without throwing

    func testValidateThenApplyNeverThrowsWhenValidationSucceeded() throws {
        let (ast, id) = documentWithOneBlock()
        let mutation = Mutation.setBlockAttribute(blockID: id, key: "k", value: .string("v"))
        var engine = MutationEngine()
        XCTAssertNoThrow(try engine.validate(mutation, against: ast))
        var mutableAst = ast
        XCTAssertNoThrow(try engine.apply(mutation, to: &mutableAst))
    }

    // MARK: - Document-level mutations touch no AST state

    func testValidateSetDocumentTitleAlwaysSucceeds() {
        var engine = MutationEngine()
        XCTAssertNoThrow(try engine.validate(.setDocumentTitle(title: "New Title"), against: .empty))
    }

    func testApplySetDocumentTitleReturnsEmptySnapshotAndDoesNotTouchBlocks() throws {
        var ast = emptyDocument()
        var engine = MutationEngine()
        let pre = try engine.apply(.setDocumentTitle(title: "x"), to: &ast)
        XCTAssertTrue(pre.isEmpty)
        XCTAssertTrue(ast.blocks.isEmpty)
    }
}
