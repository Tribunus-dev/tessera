import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Reminders/ReminderStore.swift
// doc comments + docs/tessera-productivity-materials-reminders-design.md
// section 7's receipt table. Doctrine rule 11's gated half for the real
// `ReminderStore` against a live Postgres row, paired with
// ReminderStoreTests.swift (closed-data-layer + taxonomy pin) and
// ReminderStoringContractTests.swift (full quartet against the
// `ReminderStoring` in-memory fake).

final class ReminderStoreIntegrationTests: DoctrineTestCase {
    override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }

    private func connectedDataLayer() async throws -> TesseraDataLayer {
        guard ProcessInfo.processInfo.environment["TESSERA_DB_INTEGRATION"] == "1" else {
            throw XCTSkip("TESSERA_DB_INTEGRATION not set; skipping live-Postgres ReminderStore tests")
        }
        let layer = TesseraDataLayer()
        let outcome = await layer.start()
        guard outcome == .ready else {
            throw XCTSkip("TesseraDataLayer did not reach .ready (\(outcome)); skipping live-Postgres ReminderStore tests")
        }
        return layer
    }

    private func makeReminder(eventID: UUID = UUID()) -> Reminder {
        // Explicit whole-second createdAt/updatedAt (doctrine rule 4: no
        // bare Date() in fixtures) - a sub-second Date() default would
        // round-trip through the .iso8601 encoder with its fractional
        // seconds truncated, breaking the fetched-equals-original check.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Reminder(
            title: "15 min before Q3 review",
            calendarEventID: eventID,
            offsetMinutes: -15,
            triggerAt: now,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Receipt + persistence (create)

    func testUpsertPersistsAndEmitsExactlyOneReminderCreatedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let reminder = makeReminder()

        _ = try await store.upsert(reminder)

        let fetched = try await store.get(id: reminder.id)
        XCTAssertEqual(fetched, reminder)

        let receipts = try await store.receipts(forReminder: reminder.id)
        let created = receipts.filter { $0.receiptType == ReminderReceiptType.created.rawValue }
        XCTAssertEqual(created.count, 1)
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let result = try await store.get(id: UUID())
        XCTAssertNil(result)
    }

    func testAcknowledgeOfUnknownIDReturnsNilAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let unknownID = UUID()
        let result = try await store.acknowledge(id: unknownID, at: Date())
        XCTAssertNil(result)
        let receipts = try await store.receipts(forReminder: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let unknownID = UUID()
        let didDelete = try await store.delete(id: unknownID)
        XCTAssertFalse(didDelete)
        let receipts = try await store.receipts(forReminder: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testDeleteOfKnownReminderEmitsExactlyOneDeletedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let reminder = makeReminder()
        _ = try await store.upsert(reminder)

        let didDelete = try await store.delete(id: reminder.id)
        XCTAssertTrue(didDelete)

        let receipts = try await store.receipts(forReminder: reminder.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.deleted.rawValue }.count, 1)
    }

    // MARK: - Acknowledge / snooze against a live row

    func testAcknowledgeEmitsExactlyOneAcknowledgedReceiptAndClearsSnooze() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        var reminder = makeReminder()
        reminder.snoozedUntil = Date().addingTimeInterval(600)
        _ = try await store.upsert(reminder)

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let updated = try await store.acknowledge(id: reminder.id, at: now)
        XCTAssertEqual(updated?.acknowledgedAt, now)
        XCTAssertNil(updated?.snoozedUntil)

        let receipts = try await store.receipts(forReminder: reminder.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.acknowledged.rawValue }.count, 1)
    }

    func testSnoozeEmitsExactlyOneSnoozedReceipt() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let reminder = makeReminder()
        _ = try await store.upsert(reminder)
        let snoozeUntil = Date(timeIntervalSince1970: 1_700_200_000)

        _ = try await store.snooze(id: reminder.id, until: snoozeUntil, at: Date())

        let receipts = try await store.receipts(forReminder: reminder.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.snoozed.rawValue }.count, 1)
    }

    // MARK: - listForCalendarEvent scoping (against a live row set)

    func testListForCalendarEventReturnsOnlyRemindersForThatEvent() async throws {
        let layer = try await connectedDataLayer()
        let store = ReminderStore(dataLayer: layer)
        let eventA = UUID()
        let reminderA = makeReminder(eventID: eventA)
        _ = try await store.upsert(reminderA)

        let forA = try await store.listForCalendarEvent(eventA, limit: 100)
        XCTAssertTrue(forA.contains { $0.id == reminderA.id })
        XCTAssertTrue(forA.allSatisfy { $0.calendarEventID == eventA })
    }
}
