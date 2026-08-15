import XCTest
@testable import TesseraCore

// MARK: - MutationTests
//
// Contract: Mutation.swift's own doc comments on `inverse(preMutation:)` -
// "For an insertBlockAfter, the inverse is a deleteBlock... For a
// deleteBlock, the inverse is an insertBlockAfter that re-inserts the
// deleted block at its original anchor with its original parent... For a
// replaceBlock, the inverse is a replaceBlock with the old block (from the
// pre-snapshot)." This is the property `ReceiptUndoManager.undo` depends
// on: applying the inverse to the post-mutation document must restore the
// pre-mutation state. Tested here both as isolated fixtures (per doctrine
// rule 9: math/logic gets fixtures) and as an apply-inverse-apply
// round-trip property using `MutationEngine` (the cheap property test).

final class MutationTests: DoctrineTestCase {

    // MARK: - insertBlockAfter <-> deleteBlock

    func testInverseOfInsertBlockAfterIsDeleteBlock() {
        let block = Block(type: .paragraph)
        let mutation = Mutation.insertBlockAfter(parentID: nil, anchorID: nil, block: block)
        XCTAssertEqual(mutation.inverse(preMutation: [:]), [.deleteBlock(blockID: block.id)])
    }

    func testInverseOfDeleteBlockReinsertsAtOriginalAnchorAndParent() {
        let parentID = UUID()
        let siblingBeforeID = UUID()
        let deletedID = UUID()
        let deletedBlock = Block(id: deletedID, type: .paragraph, parentID: parentID)
        let pre: [UUID: Block] = [
            deletedID: deletedBlock,
            parentID: Block(id: parentID, type: .toggle, children: [siblingBeforeID, deletedID]),
        ]
        let mutation = Mutation.deleteBlock(blockID: deletedID)
        XCTAssertEqual(mutation.inverse(preMutation: pre), [
            .insertBlockAfter(parentID: parentID, anchorID: siblingBeforeID, block: deletedBlock),
        ])
    }

    func testInverseOfDeleteBlockOfFirstChildUsesNilAnchor() {
        let parentID = UUID()
        let deletedID = UUID()
        let deletedBlock = Block(id: deletedID, type: .paragraph, parentID: parentID)
        let pre: [UUID: Block] = [
            deletedID: deletedBlock,
            parentID: Block(id: parentID, type: .toggle, children: [deletedID]),
        ]
        let mutation = Mutation.deleteBlock(blockID: deletedID)
        XCTAssertEqual(mutation.inverse(preMutation: pre), [
            .insertBlockAfter(parentID: parentID, anchorID: nil, block: deletedBlock),
        ])
    }

    func testInverseOfDeleteBlockWithNoSnapshotEntryIsEmpty() {
        let mutation = Mutation.deleteBlock(blockID: UUID())
        XCTAssertEqual(mutation.inverse(preMutation: [:]), [])
    }

    // MARK: - replaceBlock

    func testInverseOfReplaceBlockRestoresTheOldBlock() {
        let id = UUID()
        let oldBlock = Block(id: id, type: .paragraph, content: [InlineRun(text: "old")])
        let mutation = Mutation.replaceBlock(blockID: id, block: Block(id: id, type: .paragraph, content: [InlineRun(text: "new")]))
        XCTAssertEqual(mutation.inverse(preMutation: [id: oldBlock]), [.replaceBlock(blockID: id, block: oldBlock)])
    }

    // MARK: - setBlockAttribute

    func testInverseOfSetBlockAttributeRestoresTheOldValue() {
        let id = UUID()
        let oldBlock = Block(id: id, type: .paragraph, attributes: ["k": .string("old")])
        let mutation = Mutation.setBlockAttribute(blockID: id, key: "k", value: .string("new"))
        XCTAssertEqual(mutation.inverse(preMutation: [id: oldBlock]), [.setBlockAttribute(blockID: id, key: "k", value: .string("old"))])
    }

    func testInverseOfSetBlockAttributeWithNoPriorValueIsEmpty() {
        let id = UUID()
        let oldBlock = Block(id: id, type: .paragraph) // attribute "k" never set
        let mutation = Mutation.setBlockAttribute(blockID: id, key: "k", value: .string("new"))
        XCTAssertEqual(mutation.inverse(preMutation: [id: oldBlock]), [])
    }

    // MARK: - appendInlineRun <-> deleteInlineRun <-> appendInlineRun

    func testInverseOfAppendInlineRunDeletesAtTheNewlyAppendedIndex() {
        let id = UUID()
        let oldBlock = Block(id: id, type: .paragraph, content: [InlineRun(text: "a"), InlineRun(text: "b")])
        let mutation = Mutation.appendInlineRun(blockID: id, run: InlineRun(text: "c"))
        XCTAssertEqual(mutation.inverse(preMutation: [id: oldBlock]), [.deleteInlineRun(blockID: id, index: 2)])
    }

    func testInverseOfDeleteInlineRunAppendsTheDeletedRunBack() {
        let id = UUID()
        let runToDelete = InlineRun(text: "b")
        let oldBlock = Block(id: id, type: .paragraph, content: [InlineRun(text: "a"), runToDelete])
        let mutation = Mutation.deleteInlineRun(blockID: id, index: 1)
        XCTAssertEqual(mutation.inverse(preMutation: [id: oldBlock]), [.appendInlineRun(blockID: id, run: runToDelete)])
    }

    // MARK: - setInlineAnnotation flips to the pre-mutation presence flag

    func testInverseOfSetInlineAnnotationFlipsToPriorPresence() {
        let id = UUID()
        let oldBlock = Block(id: id, type: .paragraph, content: [InlineRun(text: "x", annotations: [.bold])])
        let mutation = Mutation.setInlineAnnotation(blockID: id, index: 0, annotation: .bold, enabled: false) // enabling->disabling
        XCTAssertEqual(mutation.inverse(preMutation: [id: oldBlock]), [
            .setInlineAnnotation(blockID: id, index: 0, annotation: .bold, enabled: true),
        ])
    }

    // MARK: - Document-level mutations have no in-AST inverse

    func testInverseOfSetDocumentTitleIsEmpty() {
        XCTAssertEqual(Mutation.setDocumentTitle(title: "x").inverse(preMutation: [:]), [])
    }

    // MARK: - Property: apply(mutation) then apply(inverse) restores the original document

    func testApplyThenApplyInverseRestoresOriginalDocumentForInsert() throws {
        let (ast, id) = try applyThenInverse(startingWith: .empty) { engine, ast in
            let newID = UUID()
            return (.insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: newID, type: .paragraph)), newID)
        }
        XCTAssertTrue(ast.blocks.isEmpty)
        _ = id
    }

    func testApplyThenApplyInverseRestoresOriginalDocumentForSetBlockAttribute() throws {
        let blockID = UUID()
        var original = DocumentAST()
        original.blocks[blockID] = Block(id: blockID, type: .paragraph, attributes: ["k": .string("original")])
        original.rootChildren = [blockID]
        let originalHash = try original.contentHash()

        var engine = MutationEngine()
        var working = original
        let mutation = Mutation.setBlockAttribute(blockID: blockID, key: "k", value: .string("changed"))
        let pre = try engine.apply(mutation, to: &working)
        XCTAssertEqual(working.blocks[blockID]?.attributes["k"], .string("changed"))

        for inverseMutation in mutation.inverse(preMutation: pre) {
            _ = try engine.apply(inverseMutation, to: &working)
        }
        XCTAssertEqual(try working.contentHash(), originalHash, "apply(mutation) -> apply(inverse) must restore the original document exactly")
    }

    func testApplyThenApplyInverseRestoresOriginalDocumentForDeleteBlock() throws {
        let parentID = UUID()
        let childID = UUID()
        var original = DocumentAST()
        original.blocks[parentID] = Block(id: parentID, type: .toggle, children: [childID])
        original.blocks[childID] = Block(id: childID, type: .paragraph, content: [InlineRun(text: "keep me")], parentID: parentID)
        original.rootChildren = [parentID]
        let originalHash = try original.contentHash()

        var engine = MutationEngine()
        var working = original
        let mutation = Mutation.deleteBlock(blockID: childID)
        let pre = try engine.apply(mutation, to: &working)
        XCTAssertNil(working.blocks[childID])

        for inverseMutation in mutation.inverse(preMutation: pre) {
            _ = try engine.apply(inverseMutation, to: &working)
        }
        XCTAssertEqual(try working.contentHash(), originalHash, "delete-then-undo-via-inverse must restore the original document exactly, including the block's original position")
    }

    // MARK: - shortDescription (used to compose the receipt summary)

    func testShortDescriptionForEmptyMutationsListIsHumanReadable() {
        XCTAssertEqual(Mutation.deleteBlock(blockID: UUID()).shortDescription, "delete block")
    }

    func testShortDescriptionNamesTheAttributeKey() {
        XCTAssertEqual(Mutation.setBlockAttribute(blockID: UUID(), key: "styleRef", value: .null).shortDescription, "set attribute 'styleRef'")
    }

    // MARK: - Helper

    private func applyThenInverse(
        startingWith ast: DocumentAST,
        build: (MutationEngine, DocumentAST) -> (Mutation, UUID)
    ) throws -> (ast: DocumentAST, id: UUID) {
        var engine = MutationEngine()
        var working = ast
        let (mutation, id) = build(engine, working)
        let pre = try engine.apply(mutation, to: &working)
        for inverseMutation in mutation.inverse(preMutation: pre) {
            _ = try engine.apply(inverseMutation, to: &working)
        }
        return (working, id)
    }
}
