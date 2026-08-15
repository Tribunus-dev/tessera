import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Reminders/ReminderStore.swift
// doc comments + docs/tessera-productivity-materials-reminders-design.md
// section 7's receipt table. Ungated half for the REAL `ReminderStore`
// (see CalendarStoreTests.swift's header for the `.closed`-propagation
// mechanism). The full quartet against the `ReminderStoring` stub seam
// is in ReminderStoringContractTests.swift; the gated quartet against a
// live row is in ReminderStoreIntegrationTests.swift.

final class ReminderStoreTests: DoctrineTestCase {

    private func makeStore() -> ReminderStore {
        ReminderStore(dataLayer: TesseraDataLayer())
    }

    private func makeReminder() -> Reminder {
        Reminder(
            title: "15 min before Q3 review",
            calendarEventID: UUID(),
            offsetMinutes: -15,
            triggerAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Error propagation on a closed data layer

    func testUpsertOnClosedDataLayerThrowsRatherThanSucceeding() async {
        let store = makeStore()
        do {
            _ = try await store.upsert(makeReminder())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    func testGetOnClosedDataLayerThrowsRatherThanReturningNil() async {
        let store = makeStore()
        do {
            _ = try await store.get(id: UUID())
            XCTFail("expected the closed data layer's error to propagate")
        } catch {
            XCTAssertTrue(error is TesseraDataStoreError, "expected TesseraDataStoreError, got \(error)")
        }
    }

    // MARK: - Receipt type taxonomy pin (rule 5 + rule 7's independent
    // oracle: hardcoded from the design doc's table, section 7)

    func testReminderReceiptTypeRawValuesArePinned() {
        let expected: [ReminderReceiptType: String] = [
            .created: "reminder_created",
            .updated: "reminder_updated",
            .acknowledged: "reminder_acknowledged",
            .snoozed: "reminder_snoozed",
            .deleted: "reminder_deleted",
            .linkCreated: "reminder_link_created",
            .linkDeleted: "reminder_link_deleted",
        ]
        for (receiptType, rawValue) in expected {
            XCTAssertEqual(receiptType.rawValue, rawValue)
        }
    }

    func testReminderReceiptTypeHasNoUnexpectedCases() {
        let expected: Set<String> = [
            "reminder_created", "reminder_updated", "reminder_acknowledged",
            "reminder_snoozed", "reminder_deleted", "reminder_link_created",
            "reminder_link_deleted",
        ]
        XCTAssertEqual(Set(ReminderReceiptType.allCases.map(\.rawValue)), expected)
    }

    // MARK: - ReminderStoreError equality

    func testReminderStoreErrorNotFoundEqualityIsByID() {
        let id = UUID()
        XCTAssertEqual(ReminderStoreError.reminderNotFound(id: id), ReminderStoreError.reminderNotFound(id: id))
        XCTAssertNotEqual(ReminderStoreError.reminderNotFound(id: id), ReminderStoreError.reminderNotFound(id: UUID()))
    }

    // MARK: - Default-argument convenience (pure, no I/O: verifies the
    // `ReminderStoring` extension's `acknowledge(id:)`/`snooze(id:until:)`
    // shorthand delegate to the `at: Date()` overload without altering
    // arguments -- tested via the in-memory fake since it is the
    // conformer we can call synchronously-ish without a live store).

    func testAcknowledgeConvenienceOverloadDelegatesToAtNowOverload() async throws {
        let fake = InMemoryReminderStore()
        let reminder = makeReminder()
        _ = try await fake.upsert(reminder)
        let acknowledged = try await fake.acknowledge(id: reminder.id)
        XCTAssertNotNil(acknowledged?.acknowledgedAt)
    }
}
