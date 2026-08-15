import Foundation
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Reminders/ReminderStore.swift
// doc comment on `ReminderStoring`: "ReminderStore is the production
// implementation (Postgres + receipts); unit tests pass a thin in-memory
// fake." Unlike `CalendarStoring`, `ReminderStoring` DOES declare
// `receipts(forReminder:)`, so this fake can stand in for the full
// receipt + persistence + no-op + error-path quartet (doctrine rule 11's
// in-memory/stub seam) -- it implements the SAME receipt-type/payload
// vocabulary as `ReminderReceiptType` (docs/tessera-productivity-materials-reminders-design.md
// section 7's table) so a caller of `ReminderStoring` (agent tools,
// view-model) sees identical receipt behavior whether backed by this
// fake or the real Postgres-backed store. The real store's Postgres
// wiring itself is separately verified by
// ReminderStoreIntegrationTests.swift (TESSERA_DB_INTEGRATION-gated).

/// An in-memory `ReminderStoring` conformer for ungated tests.
final class InMemoryReminderStore: ReminderStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: Reminder] = [:]
    private var receiptLog: [UUID: [GraphReceipt]] = [:]

    var forcedError: Error?

    private func appendReceipt(entityID: UUID, receiptType: ReminderReceiptType, payload: [String: JSONValue]) {
        let receipt = GraphReceipt(
            id: UUID(),
            entityID: entityID,
            receiptType: receiptType.rawValue,
            payload: payload,
            witnessedAt: Date()
        )
        receiptLog[entityID, default: []].append(receipt)
    }

    func upsert(_ reminder: Reminder) async throws -> Reminder {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        let isNew = storage[reminder.id] == nil
        storage[reminder.id] = reminder
        appendReceipt(
            entityID: reminder.id,
            receiptType: isNew ? .created : .updated,
            payload: [
                "title": .string(reminder.title),
                "calendarEventID": .string(reminder.calendarEventID.uuidString),
                "offsetMinutes": .number(Double(reminder.offsetMinutes)),
            ]
        )
        return reminder
    }

    func get(id: UUID) async throws -> Reminder? {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func list(limit: Int) async throws -> [Reminder] {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.values.sorted { $0.triggerAt < $1.triggerAt }.prefix(limit))
    }

    func listForCalendarEvent(_ eventID: UUID, limit: Int) async throws -> [Reminder] {
        if let forcedError { throw forcedError }
        let all = try await list(limit: 10_000)
        return Array(all.filter { $0.calendarEventID == eventID }.prefix(limit))
    }

    func acknowledge(id: UUID, at now: Date) async throws -> Reminder? {
        if let forcedError { throw forcedError }
        lock.lock()
        guard var reminder = storage[id] else { lock.unlock(); return nil }
        reminder.acknowledgedAt = now
        reminder.snoozedUntil = nil
        storage[id] = reminder
        lock.unlock()
        appendReceipt(entityID: id, receiptType: .acknowledged, payload: ["acknowledgedAt": .string(ReminderStore.iso8601(now))])
        return reminder
    }

    func snooze(id: UUID, until: Date, at now: Date) async throws -> Reminder? {
        if let forcedError { throw forcedError }
        lock.lock()
        guard var reminder = storage[id] else { lock.unlock(); return nil }
        reminder.snoozedUntil = until
        reminder.updatedAt = now
        storage[id] = reminder
        lock.unlock()
        appendReceipt(entityID: id, receiptType: .snoozed, payload: ["snoozedUntil": .string(ReminderStore.iso8601(until))])
        return reminder
    }

    func delete(id: UUID) async throws -> Bool {
        if let forcedError { throw forcedError }
        lock.lock()
        let removed = storage.removeValue(forKey: id) != nil
        lock.unlock()
        if removed {
            appendReceipt(entityID: id, receiptType: .deleted, payload: [:])
        }
        return removed
    }

    func receipts(forReminder reminderID: UUID) async throws -> [GraphReceipt] {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return receiptLog[reminderID] ?? []
    }
}
