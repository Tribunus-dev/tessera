import Foundation
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Calendar/CalendarChatHandler.swift
// ("public protocol CalendarStoring") doc comment: "CalendarStore conforms
// (production); the test suite injects an in-memory fake so the create /
// list / update chat flows run without Postgres." Mirrors the historical
// shape docs/tessera-productivity-materials-calendar-design.md section 11
// names ("CalendarTestSupport provides InMemoryCalendarStore (with failure
// injection)").
//
// This is the doctrine rule-11 "in-memory/stub seam" for CalendarStore's
// own ungated shadow tests. NOTE: `CalendarStoring` does NOT expose
// `receipts(forEvent:)`, so this fake cannot stand in for receipt-emission
// assertions -- those require the real `CalendarStore` against a live
// data layer (see `CalendarStoreIntegrationTests.swift`, TESSERA_DB_INTEGRATION-gated).
// This fake verifies the CRUD/no-op/error-path *wiring contract* that
// `CalendarStoring` actually defines.

/// An in-memory `CalendarStoring` conformer for ungated tests. Not an
/// `actor` (the protocol requires only `Sendable`, and a lock-protected
/// class keeps the call sites free of `await self.lock...` ceremony);
/// synchronization is a simple `NSLock` around the dictionary.
final class InMemoryCalendarStore: CalendarStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: CalendarEvent] = [:]

    /// When set, every method throws this error instead of performing
    /// its normal work (failure injection, per the design doc's file
    /// index note for the historical `CalendarTestSupport.swift`).
    var forcedError: Error?

    func upsert(_ event: CalendarEvent) async throws -> CalendarEvent {
        if let forcedError { throw forcedError }
        guard event.isValid else {
            throw CalendarStoreError.invalidEvent(reason: "title empty or endAt before startAt")
        }
        lock.lock()
        storage[event.id] = event
        lock.unlock()
        return event
    }

    func get(id: UUID) async throws -> CalendarEvent? {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func delete(id: UUID) async throws -> Bool {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return storage.removeValue(forKey: id) != nil
    }

    func list(limit: Int) async throws -> [CalendarEvent] {
        if let forcedError { throw forcedError }
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.values.sorted { $0.startAt < $1.startAt }.prefix(limit))
    }

    func events(in range: ClosedRange<Date>, calendar: Calendar) async throws -> [CalendarEvent] {
        if let forcedError { throw forcedError }
        let all = try await list(limit: 10_000)
        return all
            .filter { !$0.occurrences(in: range, calendar: calendar).isEmpty }
            .sorted { $0.startAt < $1.startAt }
    }

    func search(matching query: String, limit: Int) async throws -> [CalendarEvent] {
        if let forcedError { throw forcedError }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let all = try await list(limit: 10_000)
        return Array(all.filter { $0.title.lowercased().contains(q) }.prefix(limit))
    }

    func respond(
        to eventID: UUID,
        attendeeIndex: Int?,
        attendeeName: String?,
        status: CalendarEvent.ResponseStatus
    ) async throws -> CalendarEvent {
        if let forcedError { throw forcedError }
        guard var event = try await get(id: eventID) else {
            throw CalendarStoreError.eventNotFound(id: eventID)
        }
        guard !event.attendees.isEmpty else {
            throw CalendarStoreError.noAttendees(eventID: eventID)
        }
        let index: Int
        if let attendeeIndex, event.attendees.indices.contains(attendeeIndex) {
            index = attendeeIndex
        } else if let attendeeName,
                  let found = event.attendees.firstIndex(where: {
                      $0.name.caseInsensitiveCompare(attendeeName) == .orderedSame
                  }) {
            index = found
        } else {
            index = 0
        }
        event.attendees[index].responseStatus = status
        lock.lock()
        storage[eventID] = event
        lock.unlock()
        return event
    }
}
