import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/ChatQueueItem.swift
// doc comments -- the type's own public API and doc comments are the
// contract per this cluster's brief ("before the 247-file deletion this
// had a real suite you can reconstruct the shape of purely from
// ChatQueueItem.swift's own public API and doc comments -- the method
// names strongly suggest their own contracts: insertAtFront, reorder,
// supersede, an ordered-by-order-field listing"). `ChatQueueItem`/
// `ChatQueue` are pure value types with no data-layer dependency, so
// this whole file is ungated.

final class ChatQueueItemTests: DoctrineTestCase {

    private func makeItem(
        id: UUID = UUID(),
        documentID: UUID = UUID(),
        order: Int,
        message: String = "summarize section 2",
        state: ChatQueueItem.State = .pending,
        createdAt: Date = Date()
    ) -> ChatQueueItem {
        ChatQueueItem(
            id: id,
            documentID: documentID,
            order: order,
            message: message,
            state: state,
            actor: .user(UUID()),
            createdAt: createdAt
        )
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = ChatQueueItem(
            documentID: UUID(),
            order: 2,
            message: "summarize section 2",
            state: .applied,
            actor: .agent(UUID(), model: "tessera-local", promptHash: "abc123"),
            producedReceiptID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            supersededByID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChatQueueItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testChatQueueRoundTrips() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let queue = ChatQueue(items: [
            makeItem(order: 0, createdAt: fixedDate),
            makeItem(order: 1, state: .inProgress, createdAt: fixedDate),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(queue)
        let decoded = try decoder.decode(ChatQueue.self, from: data)
        XCTAssertEqual(decoded, queue)
    }

    // MARK: - isSuperseded

    func testIsSupersededFalseWhenSupersededByIDIsNil() {
        XCTAssertFalse(makeItem(order: 0).isSuperseded)
    }

    func testIsSupersededTrueWhenSupersededByIDIsSet() {
        var item = makeItem(order: 0)
        item.supersededByID = UUID()
        XCTAssertTrue(item.isSuperseded)
    }

    // MARK: - displayPosition (1-based, order then createdAt tiebreak)

    func testDisplayPositionIsOneBasedByOrder() {
        let first = makeItem(order: 0)
        let second = makeItem(order: 1)
        let items = [second, first]
        XCTAssertEqual(first.displayPosition(among: items), 1)
        XCTAssertEqual(second.displayPosition(among: items), 2)
    }

    func testDisplayPositionBreaksTiesByCreatedAtWhenOrdersMatch() {
        let earlier = makeItem(order: 0, createdAt: Date(timeIntervalSince1970: 100))
        let later = makeItem(order: 0, createdAt: Date(timeIntervalSince1970: 200))
        let items = [later, earlier]
        XCTAssertEqual(earlier.displayPosition(among: items), 1)
        XCTAssertEqual(later.displayPosition(among: items), 2)
    }

    func testDisplayPositionNilWhenItemNotInList() {
        let item = makeItem(order: 0)
        XCTAssertNil(item.displayPosition(among: []))
    }

    // MARK: - ChatQueue.orderedItems

    func testOrderedItemsSortsByOrderAscending() {
        let a = makeItem(order: 2, message: "a")
        let b = makeItem(order: 0, message: "b")
        let c = makeItem(order: 1, message: "c")
        let queue = ChatQueue(items: [a, b, c])
        XCTAssertEqual(queue.orderedItems.map(\.message), ["b", "c", "a"])
    }

    func testEmptyQueueConstantHasNoItems() {
        XCTAssertEqual(ChatQueue.empty.items, [])
    }

    // MARK: - insertingAtFront

    func testInsertingAtFrontPlacesNewItemAtOrderZero() {
        let existing = makeItem(order: 0, message: "existing")
        let queue = ChatQueue(items: [existing])
        let newItem = makeItem(order: 99, message: "new")

        let updated = queue.insertingAtFront(newItem)

        XCTAssertEqual(updated.orderedItems.first?.message, "new")
        XCTAssertEqual(updated.orderedItems.first?.order, 0)
    }

    func testInsertingAtFrontShiftsExistingItemsBackByOne() {
        let existing = makeItem(order: 0, message: "existing")
        let queue = ChatQueue(items: [existing])
        let updated = queue.insertingAtFront(makeItem(order: 0, message: "new"))

        let existingAfter = updated.items.first { $0.id == existing.id }
        XCTAssertEqual(existingAfter?.order, 1)
    }

    // MARK: - reordering

    func testReorderingMovesItemToTheRequestedIndex() {
        let a = makeItem(order: 0, message: "a")
        let b = makeItem(order: 1, message: "b")
        let c = makeItem(order: 2, message: "c")
        let queue = ChatQueue(items: [a, b, c])

        let updated = queue.reordering(itemID: c.id, to: 0)

        XCTAssertEqual(updated.orderedItems.map(\.message), ["c", "a", "b"])
    }

    func testReorderingClampsNegativeIndexToZero() {
        let a = makeItem(order: 0, message: "a")
        let b = makeItem(order: 1, message: "b")
        let queue = ChatQueue(items: [a, b])

        let updated = queue.reordering(itemID: b.id, to: -5)

        XCTAssertEqual(updated.orderedItems.map(\.message), ["b", "a"])
    }

    func testReorderingClampsOutOfRangeIndexToTheLastPosition() {
        let a = makeItem(order: 0, message: "a")
        let b = makeItem(order: 1, message: "b")
        let queue = ChatQueue(items: [a, b])

        let updated = queue.reordering(itemID: a.id, to: 999)

        XCTAssertEqual(updated.orderedItems.map(\.message), ["b", "a"])
    }

    func testReorderingOfUnknownItemIDReturnsTheQueueUnchanged() {
        let a = makeItem(order: 0, message: "a")
        let queue = ChatQueue(items: [a])

        let updated = queue.reordering(itemID: UUID(), to: 0)

        XCTAssertEqual(updated, queue)
    }

    func testReorderingRenumbersCompactlyFromZero() {
        // Regression against the doc comment's "orders may have gaps"
        // for insertingAtFront, but reordering's own doc comment says it
        // DOES renumber compactly 0..n-1.
        let a = makeItem(order: 5, message: "a")
        let b = makeItem(order: 10, message: "b")
        let queue = ChatQueue(items: [a, b])

        let updated = queue.reordering(itemID: b.id, to: 0)

        XCTAssertEqual(updated.items.sorted { $0.order < $1.order }.map(\.order), [0, 1])
    }

    // MARK: - superseding

    func testSupersedingSetsSupersededByIDOnTheMatchingItem() {
        let a = makeItem(order: 0)
        let queue = ChatQueue(items: [a])
        let supersederID = UUID()

        let updated = queue.superseding(itemID: a.id, by: supersederID)

        XCTAssertEqual(updated.items.first?.supersededByID, supersederID)
        XCTAssertTrue(updated.items.first!.isSuperseded)
    }

    func testSupersedingOfUnknownItemIDIsANoOp() {
        let a = makeItem(order: 0)
        let queue = ChatQueue(items: [a])

        let updated = queue.superseding(itemID: UUID(), by: UUID())

        XCTAssertEqual(updated, queue)
    }

    // MARK: - starting / finishing / failing (lifecycle transitions)

    func testStartingSetsStateToInProgress() {
        let a = makeItem(order: 0, state: .pending)
        let queue = ChatQueue(items: [a])

        let updated = queue.starting(itemID: a.id)

        XCTAssertEqual(updated.items.first?.state, .inProgress)
    }

    func testFinishingSetsStateToAppliedAndRecordsTheReceiptID() {
        let a = makeItem(order: 0, state: .inProgress)
        let queue = ChatQueue(items: [a])
        let receiptID = UUID()

        let updated = queue.finishing(itemID: a.id, with: receiptID)

        XCTAssertEqual(updated.items.first?.state, .applied)
        XCTAssertEqual(updated.items.first?.producedReceiptID, receiptID)
    }

    func testFailingSetsStateToFailed() {
        let a = makeItem(order: 0, state: .inProgress)
        let queue = ChatQueue(items: [a])

        let updated = queue.failing(itemID: a.id)

        XCTAssertEqual(updated.items.first?.state, .failed)
    }

    func testLifecycleTransitionsOfUnknownItemIDAreNoOps() {
        let a = makeItem(order: 0, state: .pending)
        let queue = ChatQueue(items: [a])
        let unknownID = UUID()

        XCTAssertEqual(queue.starting(itemID: unknownID), queue)
        XCTAssertEqual(queue.finishing(itemID: unknownID, with: UUID()), queue)
        XCTAssertEqual(queue.failing(itemID: unknownID), queue)
    }
}
