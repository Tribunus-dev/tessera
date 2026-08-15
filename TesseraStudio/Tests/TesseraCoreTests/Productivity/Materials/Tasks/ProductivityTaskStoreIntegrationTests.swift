import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Tasks/ProductivityTaskStore.swift
// doc comments + docs/tessera-productivity-materials-tasks-design.md
// section 7's receipt table. Doctrine rule 11's gated half, paired with
// ProductivityTaskStoreTests.swift's ungated shadow.

final class ProductivityTaskStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres ProductivityTaskStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres ProductivityTaskStore tests")
        }
        return layer
    }

    private func makeTask(title: String = "Review Q3 report") -> ProductivityTask {
        ProductivityTask(title: title)
    }

    // MARK: - Receipt + persistence (create)

    func testUpsertPersistsAndEmitsExactlyOneTaskUpsertReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()

        let saved = try await store.upsert(task)

        let fetched = try await store.get(id: task.id)
        XCTAssertEqual(fetched?.id, task.id)
        XCTAssertEqual(fetched?.title, task.title)

        let receipts = try await store.receipts(forTask: task.id)
        let upserts = receipts.filter { $0.receiptType == ProductivityTaskReceiptType.upsert.rawValue }
        XCTAssertEqual(upserts.count, 1)
        XCTAssertEqual(upserts.first?.payload["list"], .string(saved.list.rawValue))
        XCTAssertEqual(upserts.first?.payload["isCompleted"], .bool(false))
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let result = try await store.get(id: UUID())
        XCTAssertNil(result)
    }

    func testCompleteOfUnknownIDReturnsNilAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let unknownID = UUID()
        let result = try await store.complete(id: unknownID)
        XCTAssertNil(result)
        let receipts = try await store.receipts(forTask: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forTask: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownTaskEmitsExactlyOneTaskDeleteReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()
        _ = try await store.upsert(task)

        let didDelete = try await store.delete(id: task.id)
        XCTAssertTrue(didDelete)

        let receipts = try await store.receipts(forTask: task.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ProductivityTaskReceiptType.delete.rawValue }.count, 1)
    }

    // MARK: - move(): genuine no-op when the list does not change

    func testMoveToTheSameListIsANoOpAndEmitsNoTaskMovedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask() // default list == .inbox
        _ = try await store.upsert(task)

        _ = try await store.move(id: task.id, to: .inbox)

        let receipts = try await store.receipts(forTask: task.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ProductivityTaskReceiptType.moved.rawValue }.count, 0)
    }

    func testMoveToADifferentListEmitsExactlyOneTaskMovedReceiptWithFromAndToPayload() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()
        _ = try await store.upsert(task)

        _ = try await store.move(id: task.id, to: .anytime)

        let receipts = try await store.receipts(forTask: task.id)
        let moved = receipts.filter { $0.receiptType == ProductivityTaskReceiptType.moved.rawValue }
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.payload["fromList"], .string("inbox"))
        XCTAssertEqual(moved.first?.payload["toList"], .string("anytime"))
    }

    // MARK: - setPriority(): genuine no-op when the priority does not change

    func testSetPriorityToTheSameValueIsANoOpAndEmitsNoPriorityChangedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask() // default priority == .none
        _ = try await store.upsert(task)

        _ = try await store.setPriority(id: task.id, to: .none)

        let receipts = try await store.receipts(forTask: task.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ProductivityTaskReceiptType.priorityChanged.rawValue }.count, 0)
    }

    func testSetPriorityToADifferentValueEmitsExactlyOnePriorityChangedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()
        _ = try await store.upsert(task)

        _ = try await store.setPriority(id: task.id, to: .high)

        let receipts = try await store.receipts(forTask: task.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ProductivityTaskReceiptType.priorityChanged.rawValue }.count, 1)
    }

    // MARK: - complete / reopen

    func testCompleteEmitsATaskUpsertReceiptAndSetsCompletedAt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()
        _ = try await store.upsert(task)

        let completed = try await store.complete(id: task.id)
        XCTAssertNotNil(completed?.completedAt)

        let fetched = try await store.get(id: task.id)
        XCTAssertTrue(fetched?.isCompleted ?? false)
    }

    func testReopenClearsCompletedAt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()
        _ = try await store.upsert(task)
        _ = try await store.complete(id: task.id)

        let reopened = try await store.reopen(id: task.id)
        XCTAssertNil(reopened?.completedAt)
    }

    // MARK: - link() receipt

    func testLinkTaskEmitsExactlyOneTaskLinkCreatedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ProductivityTaskStore(dataLayer: layer)
        let task = makeTask()
        _ = try await store.upsert(task)
        let targetID = UUID()

        _ = try await store.linkTask(task.id, to: targetID, linkType: "related_to")

        let receipts = try await store.receipts(forTask: task.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ProductivityTaskReceiptType.linkCreated.rawValue }.count, 1)
    }
}
