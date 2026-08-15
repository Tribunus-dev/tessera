import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Reminders/Reminder.swift
// doc comments (isUpcoming/isSnoozed/isAcknowledged, formatOffset,
// TesseraTaskPriority ordering) plus
// docs/tessera-productivity-materials-reminders-design.md section 3
// (Reminder model) for the field shape.

final class ReminderTests: DoctrineTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeReminder(
        offsetMinutes: Int = -15,
        triggerAt: Date? = nil,
        acknowledgedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        priority: TesseraTaskPriority = .none
    ) -> Reminder {
        Reminder(
            title: "15 min before Q3 review",
            calendarEventID: UUID(),
            offsetMinutes: offsetMinutes,
            triggerAt: triggerAt ?? referenceDate,
            acknowledgedAt: acknowledgedAt,
            snoozedUntil: snoozedUntil,
            priority: priority,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = makeReminder(snoozedUntil: referenceDate.addingTimeInterval(600), priority: .high)
        let decoded = try Reminder.from(jsonData: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        let reminder = makeReminder()
        XCTAssertEqual(try reminder.jsonData(), try reminder.jsonData())
    }

    // MARK: - entityType pin

    func testEntityTypeIsPinnedToReminder() {
        XCTAssertEqual(Reminder.entityType, "reminder")
    }

    // MARK: - triggerTime math (doctrine rule 9: fixture + property)

    func testTriggerTimeAddsOffsetMinutesToEventStart() {
        let eventStart = Date(timeIntervalSince1970: 1_700_000_000)
        let trigger = ReminderStore.triggerTime(calendarEventStart: eventStart, offsetMinutes: -15)
        XCTAssertEqual(trigger, eventStart.addingTimeInterval(-15 * 60))
    }

    func testTriggerTimeWithZeroOffsetEqualsEventStart() {
        let eventStart = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ReminderStore.triggerTime(calendarEventStart: eventStart, offsetMinutes: 0), eventStart)
    }

    func testTriggerTimeIsInverseOfNegatingTheOffset() {
        // Property: triggerTime(start, m) and triggerTime(start, -m) are
        // symmetric around eventStart.
        let eventStart = Date(timeIntervalSince1970: 1_700_000_000)
        for minutes in [1, 15, 60, 1440] {
            let before = ReminderStore.triggerTime(calendarEventStart: eventStart, offsetMinutes: -minutes)
            let after = ReminderStore.triggerTime(calendarEventStart: eventStart, offsetMinutes: minutes)
            let beforeDelta = eventStart.timeIntervalSince(before)
            let afterDelta = after.timeIntervalSince(eventStart)
            XCTAssertEqual(beforeDelta, afterDelta, accuracy: 0.001)
        }
    }

    // MARK: - isUpcoming / isSnoozed / isAcknowledged

    func testIsUpcomingTrueForFutureUnacknowledgedUnsnoozedReminder() {
        let reminder = makeReminder(triggerAt: referenceDate.addingTimeInterval(3600))
        XCTAssertTrue(reminder.isUpcoming(now: referenceDate))
    }

    func testIsUpcomingFalseWhenAcknowledged() {
        let reminder = makeReminder(
            triggerAt: referenceDate.addingTimeInterval(3600),
            acknowledgedAt: referenceDate
        )
        XCTAssertFalse(reminder.isUpcoming(now: referenceDate))
    }

    func testIsUpcomingFalseWhenSnoozedIntoTheFuture() {
        let reminder = makeReminder(
            triggerAt: referenceDate.addingTimeInterval(3600),
            snoozedUntil: referenceDate.addingTimeInterval(7200)
        )
        XCTAssertFalse(reminder.isUpcoming(now: referenceDate))
    }

    func testIsUpcomingFalseWhenTriggerIsInThePast() {
        let reminder = makeReminder(triggerAt: referenceDate.addingTimeInterval(-3600))
        XCTAssertFalse(reminder.isUpcoming(now: referenceDate))
    }

    func testIsSnoozedTrueWhenSnoozedUntilIsInTheFuture() {
        let reminder = makeReminder(snoozedUntil: referenceDate.addingTimeInterval(600))
        XCTAssertTrue(reminder.isSnoozed(now: referenceDate))
    }

    func testIsSnoozedFalseWhenSnoozedUntilIsInThePast() {
        let reminder = makeReminder(snoozedUntil: referenceDate.addingTimeInterval(-600))
        XCTAssertFalse(reminder.isSnoozed(now: referenceDate))
    }

    func testIsSnoozedFalseWhenNeverSnoozed() {
        XCTAssertFalse(makeReminder().isSnoozed(now: referenceDate))
    }

    func testIsAcknowledgedTrueWhenAcknowledgedAtSet() {
        XCTAssertTrue(makeReminder(acknowledgedAt: referenceDate).isAcknowledged())
    }

    func testIsAcknowledgedFalseWhenNil() {
        XCTAssertFalse(makeReminder().isAcknowledged())
    }

    // MARK: - formatOffset (fixtures)

    func testFormatOffsetZeroIsAtStart() {
        XCTAssertEqual(Reminder.formatOffset(0), "at start")
    }

    func testFormatOffsetNegativeMinutesIsBefore() {
        XCTAssertEqual(Reminder.formatOffset(-15), "15 min before")
    }

    func testFormatOffsetPositiveMinutesIsAfter() {
        XCTAssertEqual(Reminder.formatOffset(60), "1 hour after")
    }

    func testFormatOffsetSingleMinuteIsSingular() {
        XCTAssertEqual(Reminder.formatOffset(-1), "1 min before")
    }

    func testFormatOffsetMultipleHoursIsPlural() {
        XCTAssertEqual(Reminder.formatOffset(-120), "2 hours before")
    }

    func testDisplayLineCombinesOffsetAndEventTitle() {
        let reminder = makeReminder(offsetMinutes: -15)
        XCTAssertEqual(reminder.displayLine(calendarEventTitle: "Q3 review"), "15 min before Q3 review")
    }

    func testDisplayLineFallsBackToEventWhenTitleMissing() {
        let reminder = makeReminder(offsetMinutes: -15)
        XCTAssertEqual(reminder.displayLine(), "15 min before event")
    }

    // MARK: - TesseraTaskPriority ordering (independent oracle: hand-fixed
    // expectation, not derived from the enum's own rank switch)

    func testPriorityOrderingHighSortsBeforeNone() {
        XCTAssertLessThan(TesseraTaskPriority.high, TesseraTaskPriority.none)
    }

    func testPriorityOrderingSortedDescendingIsHighMediumLowNone() {
        let sorted = [TesseraTaskPriority.none, .low, .high, .medium].sorted()
        XCTAssertEqual(sorted, [.high, .medium, .low, .none])
    }

    func testPriorityShortLabels() {
        XCTAssertEqual(TesseraTaskPriority.none.shortLabel, "")
        XCTAssertEqual(TesseraTaskPriority.low.shortLabel, "\u{00B7}")
        XCTAssertEqual(TesseraTaskPriority.medium.shortLabel, "\u{2022}")
        XCTAssertEqual(TesseraTaskPriority.high.shortLabel, "!")
    }
}
