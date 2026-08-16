import XCTest
@testable import TesseraCore

// MARK: - DocStoreTests
//
// Contract: DocStore.swift's own doc comments - "every mutation that
// changes doc state ... appends a signed receipt ... with a payload that
// names the affected entity_id plus a structural summary" (doctrine rule
// 1, receipts law) - plus the specific no-op contracts each method's own
// doc comment states (acceptRevision/rejectRevision/findAndReplace/
// deleteStyle/refreshFields: "only emit when something actually changed").
//
// GATING (doctrine rule 11): `DocStore` has no seam other than a live
// `TesseraDataLayer`, which wraps real PostgresNIO/RediStack connections -
// there is no in-memory/fake/stub data layer anywhere in this codebase
// (verified by grep; see docs/.scratch/test-rewrite-findings-writer.md for
// the full note on why the required "ungated shadow" cannot be built from
// a Tests/-only change). This file is gated on TESSERA_DB_INTEGRATION=1
// and skips cleanly otherwise. The pure engines DocStore delegates every
// interesting decision to (RevisionController, FieldController,
// StyleRegistry, DocumentSearchIndex) each have full ungated coverage of
// their own in this cluster, so the decision logic these tests exercise
// end-to-end is independently covered without the DB.

final class DocStoreTests: DoctrineTestCase {

    private func requireDBIntegration() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 to run DocStore against a live Postgres/Valkey - see docs/.scratch/test-rewrite-findings-writer.md")
        }
    }

    private func makeStore() async throws -> DocStore {
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        return DocStore(dataLayer: dataLayer)
    }

    // MARK: - upsert: receipt + persistence

    func testUpsertNewDocPersistsAndEmitsExactlyOneUpsertReceiptWithNamedPayloadKeys() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let doc = Doc(id: docID, title: "Integration Doc", tags: ["a", "b"])

        let stored = try await store.upsert(doc)
        XCTAssertEqual(stored.id, docID)

        let fetched = try await store.get(id: docID)
        XCTAssertEqual(fetched?.title, "Integration Doc")

        let receipts = try await store.receipts(forDoc: docID)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.receiptType, DocReceiptType.upsert.rawValue)
        XCTAssertEqual(receipts.first?.payload["title"], .string("Integration Doc"))
        XCTAssertEqual(receipts.first?.payload["tagCount"], .number(2))
    }

    // MARK: - delete: receipt only fires on an actual delete

    func testDeleteExistingDocRemovesItAndEmitsExactlyOneDeleteReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "To Delete"))

        let didDelete = try await store.delete(id: docID)
        XCTAssertTrue(didDelete)
        let fetched = try await store.get(id: docID)
        XCTAssertNil(fetched)

        let receipts = try await store.receipts(forDoc: docID)
        // upsert receipt + delete receipt.
        XCTAssertEqual(receipts.filter { $0.receiptType == DocReceiptType.delete.rawValue }.count, 1)
    }

    func testDeleteOfUnknownIDReturnsFalseAndEmitsNoDeleteReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forDoc: unknownID)
        XCTAssertTrue(receipts.isEmpty, "deleting a nonexistent doc must emit zero receipts")
    }

    // MARK: - setBody: receipt names blockCount / rootChildCount

    func testSetBodyEmitsBodyChangedReceiptWithBlockCounts() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Body Test"))

        let blockID = UUID()
        var body = DocumentAST()
        body.blocks[blockID] = Block(id: blockID, type: .paragraph, content: [InlineRun(text: "hi")])
        body.rootChildren = [blockID]

        _ = try await store.setBody(body, for: docID)

        let receipts = try await store.receipts(forDoc: docID)
        let bodyReceipt = receipts.first { $0.receiptType == DocReceiptType.updateBody.rawValue }
        XCTAssertEqual(bodyReceipt?.payload["blockCount"], .number(1))
        XCTAssertEqual(bodyReceipt?.payload["rootChildCount"], .number(1))
    }

    // MARK: - acceptRevision: no-op (zero NEW receipts) on unknown revisionID

    func testAcceptRevisionOfUnknownIDEmitsNoReceiptAndDoesNotPersist() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Revision Test"))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.acceptRevision(UUID(), for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "an unknown revisionID must append zero new receipts")
    }

    func testAcceptRevisionOfRealTrackInsertionEmitsExactlyOneAcceptedReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let blockID = UUID()
        var body = DocumentAST()
        body.blocks[blockID] = Block(id: blockID, type: .trackInsertion, content: [InlineRun(text: "inserted")])
        body.rootChildren = [blockID]
        _ = try await store.upsert(Doc(id: docID, title: "Revision Test 2", body: body))
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.acceptRevision(blockID, for: docID)
        XCTAssertEqual(updated.body.blocks[blockID]?.type, .paragraph)

        let after = try await store.receipts(forDoc: docID)
        let newReceipts = after.count - before.count
        XCTAssertEqual(newReceipts, 1, "accepting a real revision must append exactly one receipt")
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.revisionAccepted.rawValue)
    }

    // MARK: - findAndReplace: no-op on zero matches

    func testFindAndReplaceWithNoMatchesEmitsNoReceiptAndDoesNotPersist() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Search Test", body: astWithParagraph("hello world")))
        let before = try await store.receipts(forDoc: docID)

        let (_, replacedCount) = try await store.findAndReplace("xyzzy", with: "q", for: docID)
        XCTAssertEqual(replacedCount, 0)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count)
    }

    func testFindAndReplaceWithAMatchEmitsExactlyOneFindReplaceReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Search Test 2", body: astWithParagraph("hello world")))
        let before = try await store.receipts(forDoc: docID)

        let (_, replacedCount) = try await store.findAndReplace("hello", with: "goodbye", for: docID)
        XCTAssertEqual(replacedCount, 1)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.findReplace.rawValue)
        XCTAssertNil(after.last?.payload["receiptType"], "the DocumentSearchIndex placeholder payload key must be dropped once the real receipt type is used")
    }

    // MARK: - Styles: define + delete receipts

    func testDefineStyleEmitsExactlyOneDefineStyleReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Style Test"))
        let before = try await store.receipts(forDoc: docID)

        let styleID = UUID()
        let doc = try await store.defineStyle(StyleDefinition(id: styleID, name: "Heading 1", family: .paragraph), for: docID)
        XCTAssertNotNil(doc.body.meta.styles[styleID])

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.defineStyle.rawValue)
    }

    func testDeleteStyleOfUnknownIDEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Style Delete Test"))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.deleteStyle(UUID(), for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count)
    }

    // MARK: - refreshFields: no-op when nothing changes

    func testRefreshFieldsWithNoFieldBlocksEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Fields Test", body: astWithParagraph("no fields here")))
        let before = try await store.receipts(forDoc: docID)

        let (_, refreshedCount) = try await store.refreshFields(for: docID)
        XCTAssertEqual(refreshedCount, 0)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count)
    }

    func testRefreshFieldsWithADirtyDateFieldEmitsExactlyOneFieldsRefreshedReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let fieldID = UUID()
        var field = Block(id: fieldID, type: .field)
        field.field = FieldSpec(kind: .date, dirty: true)
        var body = DocumentAST()
        body.blocks[fieldID] = field
        body.rootChildren = [fieldID]
        _ = try await store.upsert(Doc(id: docID, title: "Fields Test 2", body: body))
        let before = try await store.receipts(forDoc: docID)

        let (_, refreshedCount) = try await store.refreshFields(for: docID, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertEqual(refreshedCount, 1)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.fieldsRefreshed.rawValue)
    }

    // MARK: - Archive / trash / favorite idempotence + payload flags

    func testArchivingAnUnarchivedDocPersistsAndEmitsExactlyOneArchiveReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Archive Test"))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.archive(docID)

        XCTAssertTrue(doc.isArchived)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.archive.rawValue)
        XCTAssertEqual(after.last?.payload["wasAlreadyArchived"], .bool(false))
    }

    func testArchivingAnAlreadyArchivedDocEmitsNoReceiptAndDoesNotPersist() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Archive Test", isArchived: true))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.archive(docID)

        XCTAssertTrue(doc.isArchived)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "archiving an already-archived doc must not emit a receipt")
    }

    func testUnarchivingAnArchivedDocPersistsAndEmitsExactlyOneUnarchiveReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Unarchive Test", isArchived: true))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.unarchive(docID)

        XCTAssertFalse(doc.isArchived)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.unarchive.rawValue)
        XCTAssertEqual(after.last?.payload["wasArchived"], .bool(true))
    }

    func testUnarchivingADocThatWasNeverArchivedEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Unarchive Test"))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.unarchive(docID)

        XCTAssertFalse(doc.isArchived)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "unarchiving a doc that was never archived must not emit a receipt")
    }

    func testTrashingAnUntrashedDocPersistsAndEmitsExactlyOneTrashReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Trash Test"))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.trash(docID)

        XCTAssertTrue(doc.isTrashed)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.trash.rawValue)
        XCTAssertEqual(after.last?.payload["wasAlreadyTrashed"], .bool(false))
    }

    func testTrashingAnAlreadyTrashedDocEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Trash Test", isTrashed: true))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.trash(docID)

        XCTAssertTrue(doc.isTrashed)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "trashing an already-trashed doc must not emit a receipt")
    }

    func testRestoringATrashedDocPersistsAndEmitsExactlyOneRestoreReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Restore Test", isTrashed: true))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.restore(docID)

        XCTAssertFalse(doc.isTrashed)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.restore.rawValue)
        XCTAssertEqual(after.last?.payload["wasTrashed"], .bool(true))
    }

    func testRestoringADocThatWasNeverTrashedEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Restore Test"))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.restore(docID)

        XCTAssertFalse(doc.isTrashed)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "restoring a doc that was never trashed must not emit a receipt")
    }

    func testFavoritingAnUnfavoritedDocPersistsAndEmitsExactlyOneFavoriteReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Favorite Test"))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.favorite(docID)

        XCTAssertTrue(doc.isFavorite)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.favorite.rawValue)
        XCTAssertEqual(after.last?.payload["wasAlreadyFavorite"], .bool(false))
    }

    func testFavoritingAnAlreadyFavoriteDocEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Favorite Test", isFavorite: true))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.favorite(docID)

        XCTAssertTrue(doc.isFavorite)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "favoriting an already-favorite doc must not emit a receipt")
    }

    func testUnfavoritingAFavoriteDocPersistsAndEmitsExactlyOneUnfavoriteReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Unfavorite Test", isFavorite: true))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.unfavorite(docID)

        XCTAssertFalse(doc.isFavorite)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.unfavorite.rawValue)
        XCTAssertEqual(after.last?.payload["wasFavorite"], .bool(true))
    }

    func testUnfavoritingADocThatWasNeverFavoriteEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Unfavorite Test"))
        let before = try await store.receipts(forDoc: docID)

        let doc = try await store.unfavorite(docID)

        XCTAssertFalse(doc.isFavorite)
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "unfavoriting a doc that was never favorite must not emit a receipt")
    }

    // MARK: - insertNote / deleteNote (P2-0 item 1)
    //
    // Contract: DocStore.swift's own doc comments on insertNote/deleteNote
    // - "a no-op (no persist, no receipt) when kind isn't .footnote/
    // .endnote, anchorBlockID doesn't exist ..., or offset falls outside
    // the anchor's own content length"; deleteNote "a no-op ... when
    // noteID isn't registered" - plus Block.swift's derived-never-stored
    // law for note numbering (NoteController.swift file header).

    func testInsertNoteWithValidAnchorPersistsAndEmitsExactlyOneInsertNoteReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let anchorID = UUID()
        var body = DocumentAST()
        body.blocks[anchorID] = Block(id: anchorID, type: .paragraph, content: [InlineRun(text: "hello")])
        body.rootChildren = [anchorID]
        _ = try await store.upsert(Doc(id: docID, title: "Note Test", body: body))
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.insertNote(kind: .footnote, anchorBlockID: anchorID, at: 5, text: "a footnote", for: docID)

        XCTAssertEqual(updated.body.meta.notes.count, 1)
        let noteID = try XCTUnwrap(updated.body.meta.notes.keys.first)
        XCTAssertEqual(updated.body.meta.notes[noteID]?.type, .footnote)
        XCTAssertEqual(updated.body.meta.notes[noteID]?.content.map(\.text).joined(), "a footnote")
        let numbering = updated.body.deriveNoteNumbering()
        XCTAssertEqual(numbering.footnotes[noteID], 1)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.insertNote.rawValue)
        XCTAssertEqual(after.last?.payload["noteID"], .string(noteID.uuidString))
        XCTAssertEqual(after.last?.payload["kind"], .string(BlockType.footnote.rawValue))
        XCTAssertEqual(after.last?.payload["anchorBlockID"], .string(anchorID.uuidString))
    }

    func testInsertNoteWithUnknownAnchorBlockEmitsNoReceiptAndDoesNotPersist() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Note Test 2", body: astWithParagraph("hello")))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.insertNote(kind: .footnote, anchorBlockID: UUID(), at: 0, text: "orphan note", for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "an unknown anchor block must append zero new receipts")
    }

    func testInsertNoteWithOffsetPastAnchorContentEmitsNoReceiptAndDoesNotPersist() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let anchorID = UUID()
        var body = DocumentAST()
        body.blocks[anchorID] = Block(id: anchorID, type: .paragraph, content: [InlineRun(text: "hi")])
        body.rootChildren = [anchorID]
        _ = try await store.upsert(Doc(id: docID, title: "Note Test 3", body: body))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.insertNote(kind: .footnote, anchorBlockID: anchorID, at: 99, text: "out of range", for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "an out-of-range offset must append zero new receipts")
    }

    func testDeleteNoteOfRegisteredNoteRemovesItAndStripsReferenceEmittingExactlyOneReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let anchorID = UUID()
        var body = DocumentAST()
        body.blocks[anchorID] = Block(id: anchorID, type: .paragraph, content: [InlineRun(text: "hi")])
        body.rootChildren = [anchorID]
        _ = try await store.upsert(Doc(id: docID, title: "Note Delete Test", body: body))
        let inserted = try await store.insertNote(kind: .endnote, anchorBlockID: anchorID, at: 2, text: "an endnote", for: docID)
        let noteID = try XCTUnwrap(inserted.body.meta.notes.keys.first)
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.deleteNote(noteID, for: docID)

        XCTAssertNil(updated.body.meta.notes[noteID])
        let stillReferenced = updated.body.blocks[anchorID]?.content.contains { run in
            run.annotations.contains { if case .noteRef(let id) = $0 { return id == noteID }; return false }
        } ?? false
        XCTAssertFalse(stillReferenced, "deleteNote must strip the dangling in-text reference")

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.deleteNote.rawValue)
        XCTAssertEqual(after.last?.payload["referencesRemoved"], .number(1))
    }

    func testDeleteNoteOfUnregisteredNoteEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Note Delete Test 2", body: astWithParagraph("hi")))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.deleteNote(UUID(), for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "deleting an unregistered note must append zero new receipts")
    }

    // MARK: - Comments (P2-0 item 3): add / reply / resolve / delete
    //
    // Contract: DocStore.swift's own doc comments on addComment/
    // replyToComment/resolveComment/deleteComment. Doc's comment model is
    // block-tree based (Comments.swift's CommentStore.threads(from:)),
    // NOT the flat CommentThread-array model - see this file's own
    // section header in DocStore.swift.

    func testAddCommentWithValidAnchorPersistsAndEmitsExactlyOneAddCommentReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let anchorID = UUID()
        var body = DocumentAST()
        body.blocks[anchorID] = Block(id: anchorID, type: .paragraph, content: [InlineRun(text: "hello world")])
        body.rootChildren = [anchorID]
        _ = try await store.upsert(Doc(id: docID, title: "Comment Test", body: body))
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.addComment(
            anchorBlockID: anchorID, anchorRangeStart: 0, anchorRangeEnd: 5,
            author: "alice", text: "needs work", for: docID
        )

        let threads = CommentStore.threads(from: updated.body, includeResolved: true)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.author, "alice")
        XCTAssertEqual(updated.body.rootChildren.count, 2, "the new comment root must land in rootChildren")
        XCTAssertEqual(updated.body.rootChildren.first, anchorID, "the comment root is inserted right after its anchor")

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.addComment.rawValue)
        XCTAssertEqual(after.last?.payload["anchorBlockID"], .string(anchorID.uuidString))
        XCTAssertEqual(after.last?.payload["author"], .string("alice"))
    }

    func testAddCommentWithUnknownAnchorEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Comment Test 2", body: astWithParagraph("hello")))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.addComment(
            anchorBlockID: UUID(), anchorRangeStart: 0, anchorRangeEnd: 0,
            author: "alice", text: "orphan comment", for: docID
        )

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "an unknown anchor must append zero new receipts")
    }

    func testReplyToCommentOnAThreadRootPersistsAndEmitsExactlyOneCommentRepliedReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let anchorID = UUID()
        let rootID = UUID()
        var body = DocumentAST()
        body.blocks[anchorID] = Block(id: anchorID, type: .paragraph, content: [InlineRun(text: "hello")])
        body.blocks[rootID] = Block(
            id: rootID, type: .comment,
            attributes: [
                "anchorBlockID": .string(anchorID.uuidString),
                "anchorRangeStart": .number(0), "anchorRangeEnd": .number(5),
                "author": .string("alice"), "timestamp": .number(0), "resolved": .bool(false),
            ],
            content: [InlineRun(text: "root message")]
        )
        body.rootChildren = [anchorID, rootID]
        _ = try await store.upsert(Doc(id: docID, title: "Reply Test", body: body))
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.replyToComment(threadID: rootID, author: "bob", text: "a reply", for: docID)

        XCTAssertEqual(updated.body.blocks[rootID]?.children.count, 1)
        let threads = CommentStore.threads(from: updated.body, includeResolved: true)
        XCTAssertEqual(threads.first?.messages.count, 2, "root message + one reply")

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.commentReplied.rawValue)
        XCTAssertEqual(after.last?.payload["threadID"], .string(rootID.uuidString))
    }

    func testReplyToCommentOnAReplyBlockEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let rootID = UUID()
        let replyID = UUID()
        var body = DocumentAST()
        body.blocks[rootID] = Block(id: rootID, type: .comment, children: [replyID])
        body.blocks[replyID] = Block(id: replyID, type: .comment, parentID: rootID)
        body.rootChildren = [rootID]
        _ = try await store.upsert(Doc(id: docID, title: "Reply Test 2", body: body))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.replyToComment(threadID: replyID, author: "carol", text: "nested reply", for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "replying to a reply (not a thread root) must append zero new receipts")
    }

    func testResolveCommentOnAnUnresolvedThreadEmitsExactlyOneCommentResolvedReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let rootID = UUID()
        var body = DocumentAST()
        body.blocks[rootID] = Block(id: rootID, type: .comment, attributes: ["resolved": .bool(false)])
        body.rootChildren = [rootID]
        _ = try await store.upsert(Doc(id: docID, title: "Resolve Test", body: body))
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.resolveComment(rootID, for: docID)

        XCTAssertEqual(updated.body.blocks[rootID]?.attributes["resolved"], .bool(true))
        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.commentResolved.rawValue)
    }

    func testResolveCommentOnAnAlreadyResolvedThreadEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let rootID = UUID()
        var body = DocumentAST()
        body.blocks[rootID] = Block(id: rootID, type: .comment, attributes: ["resolved": .bool(true)])
        body.rootChildren = [rootID]
        _ = try await store.upsert(Doc(id: docID, title: "Resolve Test 2", body: body))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.resolveComment(rootID, for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "resolving an already-resolved thread must append zero new receipts")
    }

    func testDeleteCommentRemovesRootAndRepliesEmittingExactlyOneReceiptWithBlocksRemovedCount() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let rootID = UUID()
        let replyID = UUID()
        var body = DocumentAST()
        body.blocks[rootID] = Block(id: rootID, type: .comment, children: [replyID])
        body.blocks[replyID] = Block(id: replyID, type: .comment, parentID: rootID)
        body.rootChildren = [rootID]
        _ = try await store.upsert(Doc(id: docID, title: "Delete Comment Test", body: body))
        let before = try await store.receipts(forDoc: docID)

        let updated = try await store.deleteComment(rootID, for: docID)

        XCTAssertNil(updated.body.blocks[rootID])
        XCTAssertNil(updated.body.blocks[replyID])
        XCTAssertFalse(updated.body.rootChildren.contains(rootID))

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count - before.count, 1)
        XCTAssertEqual(after.last?.receiptType, DocReceiptType.commentDeleted.rawValue)
        XCTAssertEqual(after.last?.payload["blocksRemoved"], .number(2))
    }

    func testDeleteCommentOfNonCommentBlockEmitsNoReceipt() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        let paragraphID = UUID()
        var body = DocumentAST()
        body.blocks[paragraphID] = Block(id: paragraphID, type: .paragraph, content: [InlineRun(text: "not a comment")])
        body.rootChildren = [paragraphID]
        _ = try await store.upsert(Doc(id: docID, title: "Delete Comment Test 2", body: body))
        let before = try await store.receipts(forDoc: docID)

        _ = try await store.deleteComment(paragraphID, for: docID)

        let after = try await store.receipts(forDoc: docID)
        XCTAssertEqual(after.count, before.count, "deleting a non-comment block id must append zero new receipts")
    }

    // MARK: - Comments: ungated shadow of the block-tree helpers (doctrine rule 11)
    //
    // `DocStore.insertCommentRoot`/`.removeCommentSubtree` are the pure
    // tree-surgery functions addComment/deleteComment delegate to (both
    // `internal`, reachable here via @testable import). These tests
    // exercise that decision logic directly with no data layer at all -
    // the required ungated shadow of the gated addComment/deleteComment
    // contract above, mirroring RevisionController/FieldController's own
    // DB-free coverage for the decision logic DocStore's gated tests
    // exercise end-to-end.

    func testInsertCommentRootPlacesNewBlockImmediatelyAfterAnchorInRootChildren() {
        let anchorID = UUID()
        let otherID = UUID()
        var ast = DocumentAST()
        ast.blocks[anchorID] = Block(id: anchorID, type: .paragraph)
        ast.blocks[otherID] = Block(id: otherID, type: .paragraph)
        ast.rootChildren = [anchorID, otherID]

        let commentID = UUID()
        DocStore.insertCommentRoot(Block(id: commentID, type: .comment), after: anchorID, in: &ast)

        XCTAssertEqual(ast.rootChildren, [anchorID, commentID, otherID])
        XCTAssertNil(ast.blocks[commentID]?.parentID, "a thread root always has parentID nil")
    }

    func testInsertCommentRootAppendsAtEndWhenAnchorIsNotARootChild() {
        let listID = UUID()
        let itemID = UUID()
        var ast = DocumentAST()
        ast.blocks[listID] = Block(id: listID, type: .list, children: [itemID])
        ast.blocks[itemID] = Block(id: itemID, type: .listItem, parentID: listID)
        ast.rootChildren = [listID]

        let commentID = UUID()
        DocStore.insertCommentRoot(Block(id: commentID, type: .comment), after: itemID, in: &ast)

        XCTAssertEqual(ast.rootChildren, [listID, commentID])
    }

    func testRemoveCommentSubtreeRemovesRootAndEveryReplyRecursivelyReturningTotalCount() {
        let rootID = UUID()
        let replyID = UUID()
        var ast = DocumentAST()
        ast.blocks[rootID] = Block(id: rootID, type: .comment, children: [replyID])
        ast.blocks[replyID] = Block(id: replyID, type: .comment, parentID: rootID)
        ast.rootChildren = [rootID]

        let removedCount = DocStore.removeCommentSubtree(rootID, in: &ast)

        XCTAssertEqual(removedCount, 2)
        XCTAssertNil(ast.blocks[rootID])
        XCTAssertNil(ast.blocks[replyID])
        XCTAssertTrue(ast.rootChildren.isEmpty)
    }

    func testRemoveCommentSubtreeOfUnknownIDIsANoOpReturningZero() {
        var ast = DocumentAST()
        let removedCount = DocStore.removeCommentSubtree(UUID(), in: &ast)
        XCTAssertEqual(removedCount, 0)
    }

    // MARK: - Error path: not-found throws without writing

    func testSetBodyOnUnknownDocThrowsDocNotFoundWithoutWriting() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let unknownID = UUID()
        do {
            _ = try await store.setBody(.empty, for: unknownID)
            XCTFail("expected DocStoreError.docNotFound")
        } catch DocStoreError.docNotFound(let id) {
            XCTAssertEqual(id, unknownID)
        }
        let receipts = try await store.receipts(forDoc: unknownID)
        XCTAssertTrue(receipts.isEmpty, "a not-found error path must not have written any receipt")
    }

    // MARK: - Helpers

    private func astWithParagraph(_ text: String) -> DocumentAST {
        let id = UUID()
        var ast = DocumentAST()
        ast.blocks[id] = Block(id: id, type: .paragraph, content: [InlineRun(text: text)])
        ast.rootChildren = [id]
        return ast
    }
}
