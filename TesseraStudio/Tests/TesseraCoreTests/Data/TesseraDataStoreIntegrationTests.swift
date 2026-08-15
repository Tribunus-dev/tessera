import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Data/TesseraDataStore.swift doc
// comments + docs/tessera-data-layer-design.md section 7.1/7.2 (env-gated
// integration tests, TESSERA_DB_INTEGRATION=1, docker-compose defaults)
// and section 3 (schema: graph_entities / entity_links / graph_receipts).
// Doctrine rule 11's gated half, paired with TesseraDataStoreTests.swift's
// ungated shadow (the `.closed` error-propagation contract).
//
// This is the foundation every other cluster's Store-quartet integration
// test assumes holds (upsert -> get round trip, delete returns a bool,
// appendReceipt -> receipts(forEntity:) chain, linkEntities -> outLinks).

final class TesseraDataStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedStore() async throws -> TesseraDataStore {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres TesseraDataStore tests")
        }
        let store = TesseraDataStore()
        do {
            try await store.connect()
        } catch {
            throw XCTSkip("TesseraDataStore could not connect (\(error)); skipping live-Postgres TesseraDataStore tests")
        }
        return store
    }

    // MARK: - upsertEntity -> getEntity round trip

    func testUpsertEntityThenGetEntityReturnsAMatchingRow() async throws {
        let store = try await connectedStore()
        let id = UUID()
        let input = GraphEntityUpsert(id: id, entityType: "note", label: "Data-layer smoke test note")

        let upserted = try await store.upsertEntity(input)
        XCTAssertEqual(upserted.id, id)
        XCTAssertEqual(upserted.entityType, "note")

        let fetched = try await store.getEntity(id: id)
        XCTAssertEqual(fetched?.id, id)
        XCTAssertEqual(fetched?.label, "Data-layer smoke test note")
    }

    // MARK: - Error path: not found

    func testGetEntityOfUnknownIDReturnsNil() async throws {
        let store = try await connectedStore()
        let fetched = try await store.getEntity(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteEntityOfUnknownIDReturnsFalse() async throws {
        let store = try await connectedStore()
        let didDelete = try await store.deleteEntity(id: UUID())
        XCTAssertFalse(didDelete)
    }

    func testDeleteEntityOfKnownRowReturnsTrueAndRemovesIt() async throws {
        let store = try await connectedStore()
        let id = UUID()
        _ = try await store.upsertEntity(GraphEntityUpsert(id: id, entityType: "note", label: "to delete"))

        let didDelete = try await store.deleteEntity(id: id)
        XCTAssertTrue(didDelete)

        let fetched = try await store.getEntity(id: id)
        XCTAssertNil(fetched)
    }

    // MARK: - Receipt append + chain (the contract every *Store above
    // this layer depends on)

    func testAppendReceiptThenReceiptsForEntityReturnsExactlyOneRowWithTheNamedPayload() async throws {
        let store = try await connectedStore()
        let id = UUID()
        _ = try await store.upsertEntity(GraphEntityUpsert(id: id, entityType: "note", label: "receipt test"))

        let appended = try await store.appendReceipt(
            entityID: id,
            receiptType: "note_upsert",
            payload: ["title": .string("receipt test"), "tagCount": .number(0)]
        )
        XCTAssertEqual(appended.entityID, id)
        XCTAssertEqual(appended.receiptType, "note_upsert")

        let receipts = try await store.receipts(forEntity: id)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.payload["title"], .string("receipt test"))
    }

    func testReceiptsForEntityWithNoReceiptsReturnsEmpty() async throws {
        let store = try await connectedStore()
        let receipts = try await store.receipts(forEntity: UUID())
        XCTAssertEqual(receipts, [])
    }

    // MARK: - linkEntities -> outLinks

    func testLinkEntitiesThenOutLinksReturnsTheLink() async throws {
        let store = try await connectedStore()
        let sourceID = UUID()
        let targetID = UUID()
        _ = try await store.upsertEntity(GraphEntityUpsert(id: sourceID, entityType: "note", label: "source"))
        _ = try await store.upsertEntity(GraphEntityUpsert(id: targetID, entityType: "note", label: "target"))

        let link = try await store.linkEntities(sourceID: sourceID, targetID: targetID, linkType: "related_to", weight: 1.0)
        XCTAssertEqual(link.sourceID, sourceID)
        XCTAssertEqual(link.targetID, targetID)

        let outLinks = try await store.outLinks(sourceID: sourceID, linkType: nil)
        XCTAssertTrue(outLinks.contains { $0.targetID == targetID && $0.linkType == "related_to" })
    }

    func testLinkEntitiesIsIdempotentForTheSameSourceTargetType() async throws {
        let store = try await connectedStore()
        let sourceID = UUID()
        let targetID = UUID()
        _ = try await store.upsertEntity(GraphEntityUpsert(id: sourceID, entityType: "note", label: "source"))
        _ = try await store.upsertEntity(GraphEntityUpsert(id: targetID, entityType: "note", label: "target"))

        _ = try await store.linkEntities(sourceID: sourceID, targetID: targetID, linkType: "related_to")
        _ = try await store.linkEntities(sourceID: sourceID, targetID: targetID, linkType: "related_to")

        let outLinks = try await store.outLinks(sourceID: sourceID, linkType: "related_to")
        XCTAssertEqual(outLinks.filter { $0.targetID == targetID }.count, 1)
    }

    // MARK: - listByEntityType

    func testListByEntityTypeReturnsUpsertedRowsOfThatTypeOnly() async throws {
        let store = try await connectedStore()
        let noteID = UUID()
        let taskID = UUID()
        let uniqueLabel = "listByEntityType-\(UUID().uuidString.prefix(8))"
        _ = try await store.upsertEntity(GraphEntityUpsert(id: noteID, entityType: "note", label: uniqueLabel))
        _ = try await store.upsertEntity(GraphEntityUpsert(id: taskID, entityType: "task", label: uniqueLabel))

        let notes = try await store.listByEntityType(entityType: "note", limit: 1000, offset: 0)
        XCTAssertTrue(notes.contains { $0.id == noteID })
        XCTAssertFalse(notes.contains { $0.id == taskID })
    }
}
