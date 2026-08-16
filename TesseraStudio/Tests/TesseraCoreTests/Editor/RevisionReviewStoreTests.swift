import XCTest
import CryptoKit
@testable import TesseraCore

// MARK: - RevisionReviewStoreTests
//
// Contract: sota-p2-core-report.md section 2.9's test list - "accept-
// from-panel matches DocStore's own contentHash + receipt after the
// call; author filter partitions exactly; accept-all = one undo unit."
// The author-filter and undo-unit contracts have full ungated coverage
// against the pure engines already (RevisionReviewFilteringTests,
// RevisionReviewUndoBuilderTests) - this file is the end-to-end shadow
// that actually calls `DocStore.acceptRevision`/`rejectRevision`.
//
// GATING (doctrine rule 11, matching DocStoreTests.swift's own header
// verbatim): `DocStore` has no seam other than a live `TesseraDataLayer`,
// which wraps real PostgresNIO/RediStack connections - there is no in-
// memory/fake/stub data layer anywhere in this codebase. This file is
// gated on TESSERA_DB_INTEGRATION=1 and skips cleanly otherwise; the
// decision logic it exercises end-to-end (RevisionController's
// accept/reject, RevisionReviewScan, RevisionReviewFiltering,
// RevisionReviewUndoBuilder) is independently, fully covered by its own
// ungated suites listed above.

final class RevisionReviewStoreTests: DoctrineTestCase {

    private func requireDBIntegration() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 to run RevisionReviewStore against a live Postgres/Valkey - see docs/.scratch/test-rewrite-findings-writer.md")
        }
    }

    private func makeStore() async throws -> (docStore: DocStore, dataLayer: TesseraDataLayer) {
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        return (DocStore(dataLayer: dataLayer), dataLayer)
    }

    @MainActor
    private func makeReviewStore(
        docStore: DocStore, dataLayer: TesseraDataLayer, docID: UUID
    ) -> RevisionReviewStore {
        RevisionReviewStore(
            docStore: docStore,
            dataLayer: dataLayer,
            docID: docID,
            undoManager: ReceiptUndoManager(documentID: docID),
            userID: UUID(),
            signer: ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())
        )
    }

    // MARK: - accept-from-panel matches DocStore's own contentHash + receipt

    @MainActor
    func testAcceptFromPanelMatchesDocStoreOwnContentHashAndReceipt() async throws {
        try requireDBIntegration()
        let (docStore, dataLayer) = try await makeStore()
        let docID = UUID()
        let blockID = UUID()
        var body = DocumentAST()
        body.blocks[blockID] = Block(id: blockID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "inserted")])
        body.rootChildren = [blockID]
        _ = try await docStore.upsert(Doc(id: docID, title: "Revision Review Test", body: body))

        let reviewStore = makeReviewStore(docStore: docStore, dataLayer: dataLayer, docID: docID)
        reviewStore.refresh(from: body)
        XCTAssertEqual(reviewStore.rows.map(\.id), [blockID])

        // The independent, direct call - what "DocStore's own" resolution is.
        let expected = try await docStore.acceptRevision(blockID, for: docID)

        // Reset to the SAME pre-accept state and accept again through the
        // panel's own store, on a second document, so the two resolutions
        // are directly comparable.
        let docID2 = UUID()
        var body2 = DocumentAST()
        body2.blocks[blockID] = Block(id: blockID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "inserted")])
        body2.rootChildren = [blockID]
        _ = try await docStore.upsert(Doc(id: docID2, title: "Revision Review Test 2", body: body2))
        let reviewStore2 = makeReviewStore(docStore: docStore, dataLayer: dataLayer, docID: docID2)
        reviewStore2.refresh(from: body2)
        let before = try await docStore.receipts(forDoc: docID2)

        await reviewStore2.accept(blockID)

        let after = try await docStore.receipts(forDoc: docID2)
        XCTAssertEqual(after.count - before.count, 1, "accept-from-panel appends exactly the one EXISTING doc_revision_accepted receipt - no new receipt types")
        XCTAssertEqual(after.first { $0.receiptType == DocReceiptType.revisionAccepted.rawValue }?.payload["revisionID"], .string(blockID.uuidString))

        let stored = try await docStore.get(id: docID2)
        XCTAssertEqual(try stored?.body.contentHash(), try expected.body.contentHash(),
                        "accept-from-panel must reach the same content hash a direct DocStore.acceptRevision call reaches")
        XCTAssertTrue(reviewStore2.rows.isEmpty, "the panel's own scan must no longer list the resolved revision")
    }

    // MARK: - accept-all = one undo unit (store-level shadow)

    @MainActor
    func testAcceptAllVisibleGroupsEveryReceiptIntoOneUndoUnit() async throws {
        try requireDBIntegration()
        let (docStore, dataLayer) = try await makeStore()
        let docID = UUID()
        let aID = UUID()
        let bID = UUID()
        var body = DocumentAST()
        body.blocks[aID] = Block(id: aID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "first")])
        body.blocks[bID] = Block(id: bID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "second")])
        body.rootChildren = [aID, bID]
        _ = try await docStore.upsert(Doc(id: docID, title: "Accept All Test", body: body))

        let undoManager = ReceiptUndoManager(documentID: docID)
        let reviewStore = RevisionReviewStore(
            docStore: docStore, dataLayer: dataLayer, docID: docID,
            undoManager: undoManager, userID: UUID(),
            signer: ReceiptSigner(signingKey: Curve25519.Signing.PrivateKey())
        )
        reviewStore.refresh(from: body)
        XCTAssertEqual(Set(reviewStore.rows.map(\.id)), [aID, bID])

        await reviewStore.acceptAllVisible()

        XCTAssertTrue(reviewStore.rows.isEmpty, "both revisions resolved")
        XCTAssertEqual(undoManager.snapshotUndoStack().count, 2, "one receipt per accepted revision, both from the SAME group() call")
    }

    // MARK: - author filter partitions exactly (store-level shadow)

    @MainActor
    func testAuthorFilterOnTheStorePartitionsExactly() async throws {
        try requireDBIntegration()
        let (docStore, dataLayer) = try await makeStore()
        let docID = UUID()
        let aliceID = UUID()
        let bobID = UUID()
        var body = DocumentAST()
        body.blocks[aliceID] = Block(id: aliceID, type: .trackInsertion, attributes: ["author": .string("alice")], content: [InlineRun(text: "from alice")])
        body.blocks[bobID] = Block(id: bobID, type: .trackInsertion, attributes: ["author": .string("bob")], content: [InlineRun(text: "from bob")])
        body.rootChildren = [aliceID, bobID]
        _ = try await docStore.upsert(Doc(id: docID, title: "Author Filter Test", body: body))

        let reviewStore = makeReviewStore(docStore: docStore, dataLayer: dataLayer, docID: docID)
        reviewStore.refresh(from: body)

        reviewStore.authorFilter = ["alice"]
        XCTAssertEqual(reviewStore.visible.map(\.id), [aliceID])

        reviewStore.authorFilter = ["bob"]
        XCTAssertEqual(reviewStore.visible.map(\.id), [bobID])

        reviewStore.authorFilter = []
        XCTAssertEqual(Set(reviewStore.visible.map(\.id)), [aliceID, bobID])
    }
}
