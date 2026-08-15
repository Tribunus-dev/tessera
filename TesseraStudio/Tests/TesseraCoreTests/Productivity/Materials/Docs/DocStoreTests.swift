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

    func testArchivingAnAlreadyArchivedDocStillEmitsAReceiptWithWasAlreadyArchivedTrue() async throws {
        try requireDBIntegration()
        let store = try await makeStore()
        let docID = UUID()
        _ = try await store.upsert(Doc(id: docID, title: "Archive Test", isArchived: true))

        let doc = try await store.archive(docID)
        XCTAssertTrue(doc.isArchived)

        let receipts = try await store.receipts(forDoc: docID)
        let archiveReceipt = receipts.last { $0.receiptType == DocReceiptType.archive.rawValue }
        XCTAssertEqual(archiveReceipt?.payload["wasAlreadyArchived"], .bool(true))
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
