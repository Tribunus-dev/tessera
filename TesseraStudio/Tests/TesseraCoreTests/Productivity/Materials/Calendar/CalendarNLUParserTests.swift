import XCTest
@testable import TesseraCore

/// Tests for ``CalendarNLUParser`` - every relative-date
/// expectation is anchored to ``CalendarFixtures``' pinned
/// reference date (Wed 2026-08-05 10:00) so the suite is
/// deterministic regardless of the wall clock. The parser
/// itself resolves against its injected `referenceDate`.
final class CalendarNLUParserTests: XCTestCase {

    private let calendar = CalendarFixtures.calendar()

    private var ref: Date { CalendarFixtures.referenceDate(calendar: calendar) }

    private func nextWeekday(_ weekday: Int, after date: Date) -> Date {
        var day = calendar.startOfDay(for: date)
        for _ in 1...7 {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            if calendar.component(.weekday, from: day) == weekday { return day }
        }
        return day
    }

    private func tomorrow(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    /// The next Jan 1st (strictly after `date`), matching
    /// how NSDataDetector resolves a bare "jan 1".
    private func nextJan1(after date: Date) -> Date {
        let year = calendar.component(.year, from: date)
        var comps = DateComponents()
        comps.month = 1
        comps.day = 1
        comps.year = year
        let candidate = calendar.date(from: comps)!
        if candidate > date { return candidate }
        comps.year = year + 1
        return calendar.date(from: comps)!
    }

    private func at(_ day: Date, hour: Int, minute: Int = 0) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: day)
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c)!
    }

    // MARK: - Spec example phrases

    func testLunchWithJohnTomorrowAtNoon() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Lunch with John tomorrow at noon")

        XCTAssertTrue(calendar.isDate(parsed.startAt, inSameDayAs: tomorrow(after: ref)))
        XCTAssertEqual(calendar.component(.hour, from: parsed.startAt), 12)
        XCTAssertEqual(calendar.component(.minute, from: parsed.startAt), 0)
        XCTAssertEqual(parsed.endAt.timeIntervalSince(parsed.startAt), CalendarEvent.defaultDuration)
        XCTAssertFalse(parsed.allDay)
        XCTAssertEqual(parsed.title, "Lunch")
        XCTAssertEqual(parsed.attendees.count, 1)
        XCTAssertEqual(parsed.attendees.first?.name, "John")
        XCTAssertNil(parsed.attendees.first?.contactID) // no contacts loaded
        XCTAssertNil(parsed.recurrence)
    }

    func testQ3ReviewNextMondayRangeAndLocation() {
        let coordinate = CalendarEvent.Coordinate(latitude: 37.7749, longitude: -122.4194)
        let parser = CalendarFixtures.parser(
            coordinates: ["the blue room": coordinate]
        )
        let parsed = parser.parse("Q3 review next monday 2pm-4pm in the blue room")

        let monday = nextWeekday(2, after: ref)
        XCTAssertTrue(calendar.isDate(parsed.startAt, inSameDayAs: monday))
        XCTAssertEqual(parsed.startAt, at(monday, hour: 14))
        XCTAssertEqual(parsed.endAt, at(monday, hour: 16))
        XCTAssertFalse(parsed.allDay)
        XCTAssertEqual(parsed.title, "Q3 review")
        XCTAssertEqual(parsed.location, "the blue room")
        XCTAssertEqual(parsed.locationCoordinate, coordinate)
    }

    func testLocationWithoutGeocodeCacheLeavesCoordinateNil() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Q3 review next monday 2pm-4pm in the blue room")
        XCTAssertEqual(parsed.location, "the blue room")
        XCTAssertNil(parsed.locationCoordinate)
    }

    func testWeeklyStandupEveryMondayStartingJan1() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Weekly standup every monday at 9am starting jan 1")

        guard let recurrence = parsed.recurrence else {
            return XCTFail("expected a recurrence")
        }
        XCTAssertTrue(recurrence.rrule.contains("FREQ=WEEKLY"))
        XCTAssertTrue(recurrence.rrule.contains("BYDAY=MO"))

        let jan1 = nextJan1(after: ref)
        XCTAssertTrue(calendar.isDate(parsed.startAt, inSameDayAs: jan1))
        XCTAssertEqual(calendar.component(.hour, from: parsed.startAt), 9)
        XCTAssertEqual(parsed.endAt.timeIntervalSince(parsed.startAt), CalendarEvent.defaultDuration)
        XCTAssertEqual(parsed.title, "Weekly standup")
    }

    func testCoffeeWithJohnDefaultsToToday() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Coffee with John")

        XCTAssertEqual(parsed.startAt, at(ref, hour: 9))
        XCTAssertEqual(parsed.endAt.timeIntervalSince(parsed.startAt), CalendarEvent.defaultDuration)
        XCTAssertFalse(parsed.allDay)
        XCTAssertEqual(parsed.title, "Coffee")
        XCTAssertEqual(parsed.attendees.first?.name, "John")
    }

    // MARK: - Attendee resolution

    func testAttendeeResolvesToContact() {
        let john = CalendarFixtures.contact(first: "John", last: "Appleseed", email: "john@acme.com")
        let parser = CalendarFixtures.parser(contacts: [john])
        let parsed = parser.parse("Lunch with John tomorrow at noon")

        XCTAssertEqual(parsed.attendees.count, 1)
        let attendee = parsed.attendees[0]
        XCTAssertEqual(attendee.contactID, john.id)
        XCTAssertEqual(attendee.email, "john@acme.com")
        XCTAssertEqual(attendee.name, "John Appleseed")
        XCTAssertEqual(attendee.responseStatus, .needsAction)
        XCTAssertTrue(attendee.isResolved)
    }

    func testMultipleAttendees() {
        let john = CalendarFixtures.contact(first: "John", last: "Appleseed")
        let jane = CalendarFixtures.contact(first: "Jane", last: "Doe")
        let parser = CalendarFixtures.parser(contacts: [john, jane])
        let parsed = parser.parse("Meeting with John and Jane tomorrow at 3pm")
        XCTAssertEqual(parsed.attendees.map(\.name), ["John Appleseed", "Jane Doe"])
    }

    // MARK: - Recurrence phrases

    func testWeeklyWithoutAnchorKeepsTime() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Standup every monday at 9am")

        let monday = nextWeekday(2, after: ref)
        XCTAssertTrue(calendar.isDate(parsed.startAt, inSameDayAs: monday))
        XCTAssertEqual(calendar.component(.hour, from: parsed.startAt), 9)
        XCTAssertEqual(parsed.recurrence?.rrule, "FREQ=WEEKLY;BYDAY=MO")
        XCTAssertEqual(parsed.title, "Standup")
    }

    func testEveryOtherWeekInterval() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Retro every other week")
        XCTAssertEqual(parsed.recurrence?.rrule, "FREQ=WEEKLY;INTERVAL=2")
    }

    func testEveryWeekdayExpandsToFiveDays() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Standup every weekday")
        XCTAssertEqual(parsed.recurrence?.rrule, "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
    }

    func testEveryTwoWeeksCapturesNumber() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Sync every 2 weeks")
        XCTAssertEqual(parsed.recurrence?.rrule, "FREQ=WEEKLY;INTERVAL=2")
    }

    func testDailyPhrase() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Journal daily")
        XCTAssertEqual(parsed.recurrence?.rrule, "FREQ=DAILY")
    }

    // MARK: - Defaults + fallbacks

    func testBareDayExpressionIsAllDay() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Q3 review tomorrow")
        XCTAssertTrue(parsed.allDay)
        XCTAssertTrue(calendar.isDate(parsed.startAt, inSameDayAs: tomorrow(after: ref)))
    }

    func testEmptyRemainderFallsBackToDefaultTitle() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("tomorrow at noon")
        XCTAssertEqual(parsed.title, "New event")
    }

    func testEmptyInputUsesEveryDefault() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("")
        XCTAssertEqual(parsed.title, "New event")
        XCTAssertEqual(parsed.startAt, at(ref, hour: 9))
        XCTAssertTrue(parsed.attendees.isEmpty)
        XCTAssertNil(parsed.location)
        XCTAssertNil(parsed.recurrence)
    }

    func testQueueVerbsAreStrippedFromTitle() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("schedule a meeting with John next monday at 2pm")
        XCTAssertEqual(parsed.title, "meeting")
        XCTAssertTrue(calendar.isDate(parsed.startAt, inSameDayAs: nextWeekday(2, after: ref)))
        XCTAssertEqual(calendar.component(.hour, from: parsed.startAt), 14)
    }

    // MARK: - Document linking

    func testQuotedTitlesLinkToDocuments() {
        let docID = UUID()
        let parser = CalendarFixtures.parser(
            documents: [ResolvedDocument(id: docID, title: "Q3 roadmap")]
        )
        let parsed = parser.parse("Review meeting tomorrow at 3pm, see \"Q3 roadmap\" first")

        XCTAssertEqual(parsed.linkedDocumentIDs, [docID])
        XCTAssertFalse(parsed.title.contains("Q3 roadmap"))
        XCTAssertTrue(parsed.title.contains("Review meeting"))
        XCTAssertEqual(calendar.component(.hour, from: parsed.startAt), 15)
    }

    func testUnmatchedQuotesStayInTitle() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Discuss \"unknown doc\" tomorrow at 3pm")
        XCTAssertTrue(parsed.linkedDocumentIDs.isEmpty)
        XCTAssertTrue(parsed.title.contains("unknown doc"))
    }

    // MARK: - makeEvent + firstDate

    func testMakeEventCarriesEveryField() {
        let parser = CalendarFixtures.parser()
        let parsed = parser.parse("Lunch with John tomorrow at noon")
        let id = UUID()
        let now = Date()
        let event = parsed.makeEvent(id: id, now: now)
        XCTAssertEqual(event.id, id)
        XCTAssertEqual(event.title, parsed.title)
        XCTAssertEqual(event.startAt, parsed.startAt)
        XCTAssertEqual(event.endAt, parsed.endAt)
        XCTAssertEqual(event.attendees, parsed.attendees)
        XCTAssertEqual(event.createdAt, now)
        XCTAssertEqual(event.updatedAt, now)
    }

    func testFirstDateHelper() {
        let parser = CalendarFixtures.parser()
        let friday = parser.firstDate(in: "friday")
        XCTAssertNotNil(friday)
        XCTAssertTrue(calendar.isDate(friday!, inSameDayAs: nextWeekday(6, after: ref)))
        XCTAssertNil(parser.firstDate(in: "no dates here"))
    }
}
