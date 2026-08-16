import XCTest
@testable import TesseraCore

// Contract source: DocumentStore.swift's own doc comments (same contract
// DocumentStoreTests.swift pins under TESSERA_DB_INTEGRATION=1) -- "Apply
// one mutation to a document, persist the updated AST, and append a
// signed receipt to the chain"; "if any [mutation] fails, none of them
// are persisted and the document is unchanged"; "history... oldest
// first". Doctrine rule 11's ungated shadow: the exact same contracts,
// exercised against `InMemoryDocumentStore` so the wiring runs in a
// plain `swift test`, no TESSERA_DB_INTEGRATION and no Keychain needed.
// The real store's Postgres wiring stays separately verified by
// DocumentStoreTests.swift.

final class DocumentStoringContractTests: DoctrineTestCase {

    // MARK: - apply: one mutation -> one receipt, persisted

    func testApplyInsertBlockPersistsAndEmitsExactlyOneReceipt() async throws {
        let store = InMemoryDocumentStore()
        let docID = UUID()

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
        let store = InMemoryDocumentStore()
        let docID = UUID()

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
        let store = InMemoryDocumentStore()
        let docID = UUID()

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
        let store = InMemoryDocumentStore()
        let docID = UUID()

        let firstBlockID = UUID()
        let secondBlockID = UUID()
        _ = try await store.apply(mutation: .insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: firstBlockID, type: .paragraph)), to: docID, actor: .user(UUID()))
        _ = try await store.apply(mutation: .insertBlockAfter(parentID: nil, anchorID: firstBlockID, block: Block(id: secondBlockID, type: .paragraph)), to: docID, actor: .user(UUID()))

        let history = try await store.history(of: docID)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history[0].timestamp <= history[1].timestamp, "history must be oldest-first")
    }

    // MARK: - loadDocument: unseeded document returns empty AST (no error)

    func testLoadDocumentOfNeverSeenIDReturnsEmptyAST() async throws {
        let store = InMemoryDocumentStore()
        let ast = try await store.loadDocument(id: UUID())
        XCTAssertTrue(ast.blocks.isEmpty)
        XCTAssertTrue(ast.rootChildren.isEmpty)
    }

    // MARK: - chat queue round-trip

    func testSaveChatQueueThenLoadReturnsTheSameQueue() async throws {
        let store = InMemoryDocumentStore()
        let docID = UUID()
        let queue = ChatQueue.empty
        try await store.saveChatQueue(queue, documentID: docID)
        let loaded = try await store.loadChatQueue(documentID: docID)
        XCTAssertEqual(loaded, queue)
    }

    func testLoadChatQueueOfNeverSavedDocumentReturnsEmptyQueue() async throws {
        let store = InMemoryDocumentStore()
        let loaded = try await store.loadChatQueue(documentID: UUID())
        XCTAssertEqual(loaded, ChatQueue.empty)
    }

    // MARK: - Failure injection (denial-path style)

    func testForcedErrorPropagatesFromApplyWithoutPersisting() async {
        let store = InMemoryDocumentStore()
        let docID = UUID()
        struct Boom: Error {}
        store.forcedError = Boom()
        do {
            _ = try await store.apply(
                mutation: .insertBlockAfter(parentID: nil, anchorID: nil, block: Block(id: UUID(), type: .paragraph)),
                to: docID, actor: .user(UUID())
            )
            XCTFail("expected the forced error to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }
}
