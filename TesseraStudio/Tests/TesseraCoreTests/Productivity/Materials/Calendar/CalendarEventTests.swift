import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Calendar/CalendarEvent.swift
// doc comments (isValid invariants, occurrences(in:calendar:) semantics,
// entityType pin, JSON round-trip helpers) plus
// docs/tessera-productivity-materials-calendar-design.md section 3
// ("CalendarEvent model") and section 6 (receipt/link taxonomy is covered
// by CalendarStoreTests, not here).
//
// Doctrine rule 2: every Codable value type gets encode-decode identity +
// legacy-JSON decode (pinned fixture) + byte-identical re-encode where a
// canonical serialization exists (the type uses .sortedKeys, so it does).

final class CalendarEventTests: DoctrineTestCase {

    private func makeEvent(
        id: UUID = UUID(),
        title: String = "Q3 review",
        start: Date = Date(timeIntervalSince1970: 1_700_000_000),
        end: Date = Date(timeIntervalSince1970: 1_700_003_600),
        allDay: Bool = false,
        recurrence: CalendarEvent.Recurrence? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            notes: "prep notes",
            startAt: start,
            endAt: end,
            allDay: allDay,
            location: "Blue room",
            attendees: [
                CalendarEvent.Attendee(contactID: UUID(), email: "ada@example.com", name: "Ada"),
            ],
            recurrence: recurrence,
            reminders: [UUID()],
            linkedDocumentIDs: [UUID()],
            linkedTaskIDs: [UUID()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = makeEvent()
        let data = try original.jsonData()
        let decoded = try CalendarEvent.from(jsonData: data)
        XCTAssertEqual(decoded, original)
    }

    func testJSONDataStringRoundTripPreservesEveryField() throws {
        let original = makeEvent(recurrence: .init(rrule: "FREQ=WEEKLY;BYDAY=MO", exDates: [Date(timeIntervalSince1970: 1_700_500_000)]))
        let s = try original.jsonDataString()
        let decoded = try CalendarEvent.from(jsonDataString: s)
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        // The type encodes with .sortedKeys + iso8601, so two independent
        // encodes of the same value must be byte-identical (doctrine rule 4:
        // determinism; rule 2: byte-identical re-encode where a canonical
        // serialization exists).
        let event = makeEvent()
        let first = try event.jsonData()
        let second = try event.jsonData()
        XCTAssertEqual(first, second)
    }

    func testJSONDataStringThrowsInvalidEventBodyOnMalformedUTF8() {
        // The inverse helper's own doc comment names this contract:
        // "Decode from a UTF-8 string. Inverse of jsonDataString()."
        // Feeding it non-UTF8-decodable bytes exercises the guard.
        let bogus = "not valid json at all"
        XCTAssertThrowsError(try CalendarEvent.from(jsonDataString: bogus))
    }

    // MARK: - entityType pin (rule 5: traps stay pinned)

    func testEntityTypeIsPinnedToCalendarEvent() {
        XCTAssertEqual(CalendarEvent.entityType, "calendar_event")
    }

    func testDefaultDurationIsOneHour() {
        // Doc comment: "the default event duration ... Fantastical uses one hour too."
        XCTAssertEqual(CalendarEvent.defaultDuration, 3600)
    }

    // MARK: - isValid (fixtures, doctrine rule 9's "math gets fixtures" applied
    // to this boolean invariant check)

    func testIsValidTrueForOrdinaryEvent() {
        XCTAssertTrue(makeEvent().isValid)
    }

    func testIsValidFalseForEmptyTitle() {
        var event = makeEvent(title: "   ")
        event.title = "   "
        XCTAssertFalse(event.isValid)
    }

    func testIsValidFalseWhenEndBeforeStart() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(-60)
        let event = makeEvent(start: start, end: end)
        XCTAssertFalse(event.isValid)
    }

    func testIsValidFalseWhenEndBeforeStartEvenForAllDayEvent() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(-60)
        let event = makeEvent(start: start, end: end, allDay: true)
        XCTAssertFalse(event.isValid)
    }

    // MARK: - Attendee.isResolved

    func testAttendeeIsResolvedTrueWhenContactIDSet() {
        let attendee = CalendarEvent.Attendee(contactID: UUID(), name: "Ada")
        XCTAssertTrue(attendee.isResolved)
    }

    func testAttendeeIsResolvedFalseWhenNoContactID() {
        let attendee = CalendarEvent.Attendee(email: "ada@example.com", name: "Ada")
        XCTAssertFalse(attendee.isResolved)
    }

    // MARK: - occurrences(in:calendar:) - non-recurring event

    func testOccurrencesReturnsStartForNonRecurringEventOverlappingRange() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let event = makeEvent(start: start, end: end)
        let range = start.addingTimeInterval(-100)...end.addingTimeInterval(100)
        XCTAssertEqual(event.occurrences(in: range), [start])
    }

    func testOccurrencesReturnsEmptyForNonRecurringEventOutsideRange() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let event = makeEvent(start: start, end: end)
        let farRange = start.addingTimeInterval(10_000)...start.addingTimeInterval(20_000)
        XCTAssertEqual(event.occurrences(in: farRange), [])
    }

    func testOccurrencesSkipsExDateForRecurringEvent() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!
        // Weekly on Monday, no COUNT/UNTIL.
        let secondOccurrenceDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9))!
        let event = makeEvent(
            start: start,
            end: start.addingTimeInterval(3600),
            recurrence: .init(rrule: "FREQ=WEEKLY;COUNT=3;BYDAY=MO", exDates: [secondOccurrenceDay])
        )
        let range = start...calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))!
        let occurrences = event.occurrences(in: range, calendar: calendar)
        // The exDate day (Aug 10) must not appear; Aug 3 and Aug 17 should.
        let days = Set(occurrences.map { calendar.startOfDay(for: $0) })
        XCTAssertFalse(days.contains(calendar.startOfDay(for: secondOccurrenceDay)))
        XCTAssertTrue(days.contains(calendar.startOfDay(for: start)))
    }

    func testOccurrencesDegradesToSingleOccurrenceForUnparseableRRule() {
        // Doc comment: "An unparseable RRULE degrades to the single
        // occurrence (never silently drop the event)."
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let event = makeEvent(start: start, end: end, recurrence: .init(rrule: "NOT-A-VALID-RRULE"))
        let range = start.addingTimeInterval(-10)...end.addingTimeInterval(10)
        XCTAssertEqual(event.occurrences(in: range), [start])
    }

    // MARK: - occurs(on:calendar:)

    func testOccursOnTrueForTheEventsOwnDay() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!
        let event = makeEvent(start: start, end: start.addingTimeInterval(3600))
        XCTAssertTrue(event.occurs(on: start, calendar: calendar))
    }

    func testOccursOnFalseForAnUnrelatedDay() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!
        let farDay = calendar.date(from: DateComponents(year: 2026, month: 12, day: 25))!
        let event = makeEvent(start: start, end: start.addingTimeInterval(3600))
        XCTAssertFalse(event.occurs(on: farDay, calendar: calendar))
    }
}
