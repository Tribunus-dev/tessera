import XCTest
@testable import TesseraCore
import CryptoKit

// MARK: - DocumentStoreTests
//
// Contract: DocumentStore.swift's own doc comments - "Apply one mutation
// to a document, persist the updated AST, and append a signed receipt to
// the chain" (doctrine rule 1); "if any [mutation] fails, none of them are
// persisted and the document is unchanged" (the batch-atomicity contract).
//
// GATING (doctrine rule 11): same as DocStoreTests - `DocumentStore` has
// no seam other than a live `TesseraDataLayer`; no in-memory/stub data
// layer exists anywhere in this codebase (see
// docs/.scratch/test-rewrite-findings-writer.md). Gated on
// TESSERA_DB_INTEGRATION=1. The pure engine underneath every decision this
// store makes (`MutationEngine`) has full ungated coverage of its own in
// `MutationEngineTests.swift`, so the validation/apply logic itself is
// exercised without the DB.

final class DocumentStoreTests: DoctrineTestCase {

    private func requireDBIntegration() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("gated: set TESSERA_DB_INTEGRATION=1 to run DocumentStore against a live Postgres/Valkey - see docs/.scratch/test-rewrite-findings-writer.md")
        }
    }

    private func makeStore() async throws -> (store: DocumentStore, dataLayer: TesseraDataLayer) {
        let dataLayer = TesseraDataLayer()
        _ = await dataLayer.start()
        return (DocumentStore(dataLayer: dataLayer), dataLayer)
    }

    private func seedEmptyDocument(dataLayer: TesseraDataLayer, id: UUID) async throws {
        let emptyASTJSON = String(data: try DocumentAST.empty.jsonData(), encoding: .utf8)!
        _ = try await dataLayer.upsertEntity(GraphEntityUpsert(
            id: id, entityType: "document", subtype: "doc", label: "Mutation Test",
            body: emptyASTJSON
        ))
    }

    // MARK: - apply: one mutation -> one receipt, persisted

    func testApplyInsertBlockPersistsAndEmitsExactlyOneReceipt() async throws {
        try requireDBIntegration()
        let (store, dataLayer) = try await makeStore()
        let docID = UUID()
        try await seedEmptyDocument(dataLayer: dataLayer, id: docID)

        let newBlockID = UUID()
        let mutation = Mutation.insertBlockAfter(
            parentID: nil, anchorID: nil,
            block: Block(id: newBlockID, type: .paragraph, content: [InlineRun(text: "hello")])
        )
        let receipt = try await store.apply(mutation: mutation, to: docID, actor: .user(UUID()))
        XCTAssertEqual(receipt.mutations.count, 1)

        let persisted = try await store.loadDocument(id: docID)
        XCTAssertEqual(persisted.blocks[newBlockID]?.content.first?.text, "hello")

        let history = try await store.history(of: docID)
        XCTAssertEqual(history.count, 1)
    }

    // MARK: - applyBatch: atomicity - one failing mutation leaves nothing persisted

    func testApplyBatchWithAnInvalidMutationPersistsNothingAndAppendsNoReceipt() async throws {
        try requireDBIntegration()
        let (store, dataLayer) = try await makeStore()
        let docID = UUID()
        try await seedEmptyDocument(dataLayer: dataLayer, id: docID)

        let validBlockID = UUID()
        let mutations: [Mutation] = [
            .insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: validBlockID, type: .paragraph)),
            .deleteBlock(blockID: UUID()), // references a block that doesn't exist -> throws
        ]
        do {
            _ = try await store.applyBatch(mutations: mutations, to: docID, actor: .user(UUID()))
            XCTFail("expected MutationError.blockNotFound")
        } catch is MutationError {
            // expected
        }

        let persisted = try await store.loadDocument(id: docID)
        XCTAssertNil(persisted.blocks[validBlockID], "a failing batch must not persist even the mutations before the failing one")

        let history = try await store.history(of: docID)
        XCTAssertTrue(history.isEmpty, "a failing batch must append zero receipts")
    }

    func testApplyBatchOnEmptyMutationListThrowsWithoutPersistingOrAppending() async throws {
        try requireDBIntegration()
        let (store, dataLayer) = try await makeStore()
        let docID = UUID()
        try await seedEmptyDocument(dataLayer: dataLayer, id: docID)

        do {
            _ = try await store.applyBatch(mutations: [], to: docID, actor: .user(UUID()))
            XCTFail("expected DocumentStoreError.emptyMutationBatch")
        } catch DocumentStoreError.emptyMutationBatch {
            // expected
        }
        let history = try await store.history(of: docID)
        XCTAssertTrue(history.isEmpty)
    }

    // MARK: - history: oldest first, decodes to typed Receipt

    func testHistoryReturnsReceiptsOldestFirst() async throws {
        try requireDBIntegration()
        let (store, dataLayer) = try await makeStore()
        let docID = UUID()
        try await seedEmptyDocument(dataLayer: dataLayer, id: docID)

        let firstBlockID = UUID()
        let secondBlockID = UUID()
        _ = try await store.apply(mutation: .insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: firstBlockID, type: .paragraph)), to: docID, actor: .user(UUID()))
        _ = try await store.apply(mutation: .insertBlockAfter(parentID: nil, anchorID: firstBlockID, block: Block(id: secondBlockID, type: .paragraph)), to: docID, actor: .user(UUID()))

        let history = try await store.history(of: docID)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history[0].timestamp <= history[1].timestamp, "history must be oldest-first")
    }
}
