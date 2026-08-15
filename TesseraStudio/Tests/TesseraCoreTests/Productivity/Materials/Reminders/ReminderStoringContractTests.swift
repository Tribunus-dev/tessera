import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Reminders/ReminderStore.swift
// `ReminderStoring` protocol doc comment + docs/tessera-productivity-materials-reminders-design.md
// section 7's receipt table. Doctrine rule 11's ungated shadow of the
// FULL quartet (receipt + persistence + no-op + error path), exercised
// against `InMemoryReminderStore` -- unlike `CalendarStoring`,
// `ReminderStoring` declares `receipts(forReminder:)`, so this fake can
// stand in for receipt assertions too (see ReminderTestSupport.swift's
// header comment for the reasoning). The real `ReminderStore`'s Postgres
// wiring is separately verified by ReminderStoreIntegrationTests.swift.

final class ReminderStoringContractTests: DoctrineTestCase {

    private func makeReminder(
        id: UUID = UUID(),
        offsetMinutes: Int = -15,
        eventID: UUID = UUID()
    ) -> Reminder {
        Reminder(
            id: id,
            title: "15 min before Q3 review",
            calendarEventID: eventID,
            offsetMinutes: offsetMinutes,
            triggerAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Receipt + persistence (create)

    func testUpsertOfNewReminderPersistsAndEmitsExactlyOneCreatedReceipt() async throws {
        let store = InMemoryReminderStore()
        let reminder = makeReminder()

        _ = try await store.upsert(reminder)

        let fetched = try await store.get(id: reminder.id)
        XCTAssertEqual(fetched, reminder)

        let receipts = try await store.receipts(forReminder: reminder.id)
        let created = receipts.filter { $0.receiptType == ReminderReceiptType.created.rawValue }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.payload["title"], .string(reminder.title))
    }

    func testUpsertOfExistingReminderEmitsUpdatedNotCreated() async throws {
        let store = InMemoryReminderStore()
        var reminder = makeReminder()
        _ = try await store.upsert(reminder)

        reminder.title = "5 min before Q3 review"
        _ = try await store.upsert(reminder)

        let receipts = try await store.receipts(forReminder: reminder.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.created.rawValue }.count, 1)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.updated.rawValue }.count, 1)
    }

    // MARK: - Error path: not found

    func testGetOfUnknownIDReturnsNil() async throws {
        let store = InMemoryReminderStore()
        let result = try await store.get(id: UUID())
        XCTAssertNil(result)
    }

    func testAcknowledgeOfUnknownIDReturnsNilAndEmitsZeroReceipts() async throws {
        let store = InMemoryReminderStore()
        let unknownID = UUID()
        let result = try await store.acknowledge(id: unknownID)
        XCTAssertNil(result)
        let receipts = try await store.receipts(forReminder: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    func testSnoozeOfUnknownIDReturnsNilAndEmitsZeroReceipts() async throws {
        let store = InMemoryReminderStore()
        let unknownID = UUID()
        let result = try await store.snooze(id: unknownID, until: Date())
        XCTAssertNil(result)
        let receipts = try await store.receipts(forReminder: unknownID)
        XCTAssertEqual(receipts.count, 0)
    }

    // MARK: - No-op: delete of unknown id

    func testDeleteOfUnknownIDReturnsFalseAndEmitsZeroReceipts() async throws {
        let store = InMemoryReminderStore()
        let kept = makeReminder()
        _ = try await store.upsert(kept)

        let didDelete = try await store.delete(id: UUID())
        XCTAssertFalse(didDelete)

        let stillThere = try await store.get(id: kept.id)
        XCTAssertEqual(stillThere, kept)
    }

    func testDeleteOfKnownReminderEmitsExactlyOneDeletedReceipt() async throws {
        let store = InMemoryReminderStore()
        let reminder = makeReminder()
        _ = try await store.upsert(reminder)

        let didDelete = try await store.delete(id: reminder.id)
        XCTAssertTrue(didDelete)

        let fetched = try await store.get(id: reminder.id)
        XCTAssertNil(fetched)

        let receipts = try await store.receipts(forReminder: reminder.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.deleted.rawValue }.count, 1)
    }

    // MARK: - Acknowledge / snooze receipts + state transitions

    func testAcknowledgeSetsAcknowledgedAtClearsSnoozeAndEmitsExactlyOneAcknowledgedReceipt() async throws {
        let store = InMemoryReminderStore()
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

    func testSnoozeSetsSnoozedUntilAndEmitsExactlyOneSnoozedReceipt() async throws {
        let store = InMemoryReminderStore()
        let reminder = makeReminder()
        _ = try await store.upsert(reminder)
        let snoozeUntil = Date(timeIntervalSince1970: 1_700_200_000)

        let updated = try await store.snooze(id: reminder.id, until: snoozeUntil, at: Date())

        XCTAssertEqual(updated?.snoozedUntil, snoozeUntil)

        let receipts = try await store.receipts(forReminder: reminder.id)
        XCTAssertEqual(receipts.filter { $0.receiptType == ReminderReceiptType.snoozed.rawValue }.count, 1)
    }

    // MARK: - listForCalendarEvent scoping

    func testListForCalendarEventReturnsOnlyRemindersForThatEvent() async throws {
        let store = InMemoryReminderStore()
        let eventA = UUID()
        let eventB = UUID()
        let reminderA = makeReminder(eventID: eventA)
        let reminderB = makeReminder(eventID: eventB)
        _ = try await store.upsert(reminderA)
        _ = try await store.upsert(reminderB)

        let forA = try await store.listForCalendarEvent(eventA, limit: 100)
        XCTAssertEqual(forA.map(\.id), [reminderA.id])
    }

    // MARK: - Failure injection (denial-path style)

    func testForcedErrorPropagatesFromUpsertWithoutPersisting() async {
        let store = InMemoryReminderStore()
        struct Boom: Error {}
        store.forcedError = Boom()
        do {
            _ = try await store.upsert(makeReminder())
            XCTFail("expected the forced error to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }
}
