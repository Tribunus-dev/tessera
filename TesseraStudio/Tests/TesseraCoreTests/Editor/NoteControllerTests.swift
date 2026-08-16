import XCTest
@testable import TesseraCore

// MARK: - NoteControllerTests
//
// Contract: NoteController.swift's own file header + DocStore.swift's
// insertNote/deleteNote doc comments (P2-0 item 1) - "a safe no-op ...
// when kind isn't .footnote/.endnote, anchorBlockID isn't in the
// document, or offset falls outside [0, anchor's own content text
// length]"; "note bodies live in DocumentMeta.notes, never in
// ast.blocks"; "the reference marker is a real InlineRun ... never a
// rendered number"; "deleting a note removes the registry entry AND
// every dangling in-text reference". Plus Block.swift's derived-never-
// stored law for `DocumentAST.deriveNoteNumbering()`.
//
// NoteController is pure (no DocStore) - `insertNote`/`deleteNote` take
// a `DocumentAST` by value and return a NEW one; the caller's own `ast`
// is never mutated (RevisionControllerTests' own "undo contract" shape,
// asserted directly below).

final class NoteControllerTests: DoctrineTestCase {

    // MARK: - Fixtures

    private func singleParagraphAST(_ text: String, id: UUID = UUID()) -> (ast: DocumentAST, blockID: UUID) {
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: text)])
        ast.rootChildren = [id]
        return (ast, id)
    }

    // MARK: - insertNote: happy path

    func testInsertNoteAtEndOfContentAppendsMarkerRunAfterExistingText() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 5, noteText: "a note", in: ast))

        let content = try XCTUnwrap(result.ast.blocks[blockID]?.content)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0].text, "hello")
        XCTAssertTrue(content[0].annotations.isEmpty)
        XCTAssertEqual(content[1].text, NoteController.referenceMarkerText)
        XCTAssertEqual(content[1].annotations, [.noteRef(result.outcome.noteID)])
    }

    func testInsertNoteAtStartOfContentInsertsMarkerBeforeExistingText() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "a note", in: ast))

        let content = try XCTUnwrap(result.ast.blocks[blockID]?.content)
        XCTAssertEqual(content.map(\.text), [NoteController.referenceMarkerText, "hello"])
    }

    func testInsertNoteMidRunSplitsTheRunPreservingBothHalvesText() throws {
        let (ast, blockID) = singleParagraphAST("hello world")
        let result = try XCTUnwrap(NoteController.insertNote(kind: .endnote, anchorBlockID: blockID, at: 5, noteText: "a note", in: ast))

        let content = try XCTUnwrap(result.ast.blocks[blockID]?.content)
        XCTAssertEqual(content.map(\.text), ["hello", NoteController.referenceMarkerText, " world"])
    }

    func testInsertNoteMidRunPreservesTheOriginalRunsAnnotationsOnBothHalves() throws {
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "hello world", annotations: [.bold])])
        ast.rootChildren = [blockID]

        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 5, noteText: "n", in: ast))

        let content = try XCTUnwrap(result.ast.blocks[blockID]?.content)
        XCTAssertEqual(content[0].annotations, [.bold])
        XCTAssertEqual(content[2].annotations, [.bold])
    }

    func testInsertNoteBetweenTwoRunsInsertsMarkerOnceAtTheBoundary() throws {
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [
            InlineRun(text: "ab"),
            InlineRun(text: "cd", annotations: [.italic]),
        ])
        ast.rootChildren = [blockID]

        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 2, noteText: "n", in: ast))

        let content = try XCTUnwrap(result.ast.blocks[blockID]?.content)
        XCTAssertEqual(content.map(\.text), ["ab", NoteController.referenceMarkerText, "cd"])
        XCTAssertEqual(content[2].annotations, [.italic], "the untouched run keeps its own annotations")
    }

    func testInsertNoteOnEmptyContentProducesASingleMarkerRun() throws {
        let blockID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [])
        ast.rootChildren = [blockID]

        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))

        XCTAssertEqual(result.ast.blocks[blockID]?.content.map(\.text), [NoteController.referenceMarkerText])
    }

    func testInsertNoteRegistersTheNoteBodyInMetaNotesNeverInBlocks() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "the note body", in: ast))

        let noteID = result.outcome.noteID
        XCTAssertEqual(result.ast.meta.notes[noteID]?.type, .footnote)
        XCTAssertEqual(result.ast.meta.notes[noteID]?.content.map(\.text).joined(), "the note body")
        XCTAssertNil(result.ast.blocks[noteID], "note bodies never live in ast.blocks")
    }

    func testInsertNoteOutcomeCarriesTheReceiptShapedPayload() throws {
        let (ast, blockID) = singleParagraphAST("hi")
        let result = try XCTUnwrap(NoteController.insertNote(kind: .endnote, anchorBlockID: blockID, at: 1, noteText: "n", in: ast))

        XCTAssertEqual(result.outcome.receiptType, DocReceiptType.insertNote.rawValue)
        XCTAssertEqual(result.outcome.payload["noteID"], .string(result.outcome.noteID.uuidString))
        XCTAssertEqual(result.outcome.payload["kind"], .string("endnote"))
        XCTAssertEqual(result.outcome.payload["anchorBlockID"], .string(blockID.uuidString))
        XCTAssertEqual(result.outcome.payload["offset"], .number(1))
    }

    func testInsertNoteDerivesNumberOneForTheFirstFootnoteInTheDocument() throws {
        let (ast, blockID) = singleParagraphAST("hi")
        let result = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))

        let numbering = result.ast.deriveNoteNumbering()
        XCTAssertEqual(numbering.footnotes[result.outcome.noteID], 1)
        XCTAssertTrue(numbering.endnotes.isEmpty)
    }

    // MARK: - insertNote: undo-contract (the input `ast` is never mutated)

    func testInsertNoteNeverMutatesTheCallersOriginalAST() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let before = ast
        _ = NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast)

        XCTAssertEqual(ast, before)
    }

    // MARK: - insertNote: no-op (nil) cases

    func testInsertNoteWithNonNoteBlockTypeReturnsNil() {
        let (ast, blockID) = singleParagraphAST("hello")
        XCTAssertNil(NoteController.insertNote(kind: .paragraph, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))
    }

    func testInsertNoteWithUnknownAnchorBlockReturnsNil() {
        let (ast, _) = singleParagraphAST("hello")
        XCTAssertNil(NoteController.insertNote(kind: .footnote, anchorBlockID: UUID(), at: 0, noteText: "n", in: ast))
    }

    func testInsertNoteWithNegativeOffsetReturnsNil() {
        let (ast, blockID) = singleParagraphAST("hello")
        XCTAssertNil(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: -1, noteText: "n", in: ast))
    }

    func testInsertNoteWithOffsetPastContentLengthReturnsNil() {
        let (ast, blockID) = singleParagraphAST("hello") // length 5
        XCTAssertNil(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 6, noteText: "n", in: ast))
    }

    // MARK: - deleteNote: happy path

    func testDeleteNoteRemovesTheRegistryEntry() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let inserted = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))
        let noteID = inserted.outcome.noteID

        let deleted = try XCTUnwrap(NoteController.deleteNote(noteID: noteID, in: inserted.ast))

        XCTAssertNil(deleted.ast.meta.notes[noteID])
    }

    func testDeleteNoteStripsTheDanglingReferenceRunEntirelyWhenItWasPureMarker() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let inserted = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))
        let noteID = inserted.outcome.noteID
        XCTAssertEqual(inserted.ast.blocks[blockID]?.content.count, 2) // marker + "hello"

        let deleted = try XCTUnwrap(NoteController.deleteNote(noteID: noteID, in: inserted.ast))

        XCTAssertEqual(deleted.ast.blocks[blockID]?.content.map(\.text), ["hello"], "the pure-marker run is dropped, not left empty")
    }

    func testDeleteNoteKeepsTheRunButStripsOnlyTheMatchingAnnotationWhenOtherAnnotationsRemain() {
        let blockID = UUID()
        let noteID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [
            InlineRun(text: NoteController.referenceMarkerText, annotations: [.noteRef(noteID), .bold]),
        ])
        ast.meta.notes[noteID] = Block(id: noteID, type: .footnote, content: [InlineRun(text: "n")])
        ast.rootChildren = [blockID]

        let deleted = NoteController.deleteNote(noteID: noteID, in: ast)

        XCTAssertEqual(deleted?.ast.blocks[blockID]?.content.count, 1, "a run with other annotations is kept, not dropped")
        XCTAssertEqual(deleted?.ast.blocks[blockID]?.content.first?.annotations, [.bold])
    }

    func testDeleteNoteOnlyStripsReferencesToTheDeletedNoteLeavingOtherNoteRefsAlone() {
        let blockID = UUID()
        let deletedNoteID = UUID()
        let otherNoteID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [
            InlineRun(text: NoteController.referenceMarkerText, annotations: [.noteRef(deletedNoteID)]),
            InlineRun(text: "middle"),
            InlineRun(text: NoteController.referenceMarkerText, annotations: [.noteRef(otherNoteID)]),
        ])
        ast.meta.notes[deletedNoteID] = Block(id: deletedNoteID, type: .footnote, content: [InlineRun(text: "gone")])
        ast.meta.notes[otherNoteID] = Block(id: otherNoteID, type: .footnote, content: [InlineRun(text: "stays")])
        ast.rootChildren = [blockID]

        let deleted = NoteController.deleteNote(noteID: deletedNoteID, in: ast)

        XCTAssertNotNil(deleted?.ast.meta.notes[otherNoteID], "the other note's own registry entry is untouched")
        let remainingContent = deleted?.ast.blocks[blockID]?.content ?? []
        XCTAssertEqual(remainingContent.map(\.text), ["middle", NoteController.referenceMarkerText])
        XCTAssertEqual(remainingContent.last?.annotations, [.noteRef(otherNoteID)])
    }

    func testDeleteNoteCountsEveryReferenceAcrossMultipleBlocks() {
        let blockAID = UUID()
        let blockBID = UUID()
        let noteID = UUID()
        var ast = DocumentAST()
        ast.blocks[blockAID] = Block(id: blockAID, type: .paragraph, content: [
            InlineRun(text: NoteController.referenceMarkerText, annotations: [.noteRef(noteID)]),
        ])
        ast.blocks[blockBID] = Block(id: blockBID, type: .paragraph, content: [
            InlineRun(text: NoteController.referenceMarkerText, annotations: [.noteRef(noteID)]),
        ])
        ast.meta.notes[noteID] = Block(id: noteID, type: .footnote, content: [InlineRun(text: "n")])
        ast.rootChildren = [blockAID, blockBID]

        let deleted = NoteController.deleteNote(noteID: noteID, in: ast)

        XCTAssertEqual(deleted?.outcome.referencesRemoved, 2)
    }

    func testDeleteNoteOutcomeCarriesTheReceiptShapedPayload() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let inserted = try XCTUnwrap(NoteController.insertNote(kind: .endnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))

        let deleted = try XCTUnwrap(NoteController.deleteNote(noteID: inserted.outcome.noteID, in: inserted.ast))

        XCTAssertEqual(deleted.outcome.receiptType, DocReceiptType.deleteNote.rawValue)
        XCTAssertEqual(deleted.outcome.kind, .endnote)
        XCTAssertEqual(deleted.outcome.referencesRemoved, 1)
    }

    // MARK: - deleteNote: undo-contract + no-op

    func testDeleteNoteNeverMutatesTheCallersOriginalAST() throws {
        let (ast, blockID) = singleParagraphAST("hello")
        let inserted = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 0, noteText: "n", in: ast))
        let before = inserted.ast
        _ = NoteController.deleteNote(noteID: inserted.outcome.noteID, in: inserted.ast)

        XCTAssertEqual(inserted.ast, before)
    }

    func testDeleteNoteOfUnregisteredIDReturnsNil() {
        let (ast, _) = singleParagraphAST("hello")
        XCTAssertNil(NoteController.deleteNote(noteID: UUID(), in: ast))
    }

    // MARK: - Round trip: insert then delete leaves no dangling reference

    func testInsertThenDeleteRoundTripRemovesTheNoteAndTheMarkerLeavingOriginalTextIntact() throws {
        let (ast, blockID) = singleParagraphAST("hello world")
        let inserted = try XCTUnwrap(NoteController.insertNote(kind: .footnote, anchorBlockID: blockID, at: 5, noteText: "n", in: ast))
        let deleted = try XCTUnwrap(NoteController.deleteNote(noteID: inserted.outcome.noteID, in: inserted.ast))

        XCTAssertEqual(deleted.ast.blocks[blockID]?.content.map(\.text).joined(), "hello world")
        XCTAssertTrue(deleted.ast.meta.notes.isEmpty)
    }
}
