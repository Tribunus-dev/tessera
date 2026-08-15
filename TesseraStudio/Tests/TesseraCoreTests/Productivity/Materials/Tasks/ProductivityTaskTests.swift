import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Productivity/Materials/Tasks/ProductivityTask.swift
// doc comments (isOverdue/isDueWithin24Hours/isDueWithin7DaysButNotToday/
// autoClassifiedList, Priority ordering, notesPreview) plus
// docs/tessera-productivity-materials-tasks-design.md section 3 (entity
// model) and section 4's list-filter table (Today = due <= now+24h
// including overdue; Upcoming = now+24h < due <= now+7d).

final class ProductivityTaskTests: DoctrineTestCase {

    // `isDueWithin7DaysButNotToday`/`autoClassifiedList` compute their
    // "today" boundary via `Calendar.current.startOfDay(for:)` (the
    // system's local calendar -- not injectable in the production code).
    // 13:00 UTC keeps the 1-hour and 3-day deltas used below safely away
    // from a local-midnight boundary crossing for every real-world IANA
    // offset (-12...+14), so the fixture stays deterministic across CI
    // machines in different time zones (doctrine rule 4).
    private let now: Date = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 13))!
    }()

    private func makeTask(
        id: UUID = UUID(),
        title: String = "Review Q3 report",
        dueAt: Date? = nil,
        completedAt: Date? = nil,
        priority: ProductivityTask.Priority = .none,
        list: ProductivityTask.List = .inbox
    ) -> ProductivityTask {
        ProductivityTask(id: id, title: title, dueAt: dueAt, completedAt: completedAt, priority: priority, list: list)
    }

    // MARK: - Round-trip identity (doctrine rule 2)

    func testJSONEncodeDecodeRoundTripPreservesEveryField() throws {
        let original = ProductivityTask(
            title: "Review Q3 report",
            notes: "check the numbers",
            dueAt: now,
            priority: .high,
            tags: ["work", "q3"],
            list: .today,
            linkedEntityIDs: [UUID()],
            sourceURL: "mailto:ada@example.com",
            createdAt: now,
            updatedAt: now
        )
        let decoded = try ProductivityTask.from(jsonData: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testByteIdenticalReEncodeIsDeterministic() throws {
        let task = makeTask()
        XCTAssertEqual(try task.jsonData(), try task.jsonData())
    }

    // MARK: - entityType / subtypeString pins

    func testEntityTypeIsPinnedToTask() {
        XCTAssertEqual(ProductivityTask.entityType, "task")
    }

    func testSubtypeStringMirrorsList() {
        XCTAssertEqual(makeTask(list: .anytime).subtypeString, "anytime")
        XCTAssertEqual(makeTask(list: .someday).subtypeString, "someday")
    }

    // MARK: - List cases serialize distinctly (independent oracle: the
    // exact raw-value set the design doc's section 4 table names)

    func testEveryListCaseHasItsOwnRawValue() {
        let expected: [ProductivityTask.List: String] = [
            .inbox: "inbox", .today: "today", .upcoming: "upcoming",
            .anytime: "anytime", .someday: "someday",
        ]
        for (list, rawValue) in expected {
            XCTAssertEqual(list.rawValue, rawValue)
        }
    }

    // MARK: - Priority is Comparable (fixtures)

    func testPriorityOrderingNoneIsLowest() {
        XCTAssertLessThan(ProductivityTask.Priority.none, .low)
        XCTAssertLessThan(ProductivityTask.Priority.low, .medium)
        XCTAssertLessThan(ProductivityTask.Priority.medium, .high)
    }

    func testPriorityDisplayNames() {
        XCTAssertEqual(ProductivityTask.Priority.none.displayName, "no priority")
        XCTAssertEqual(ProductivityTask.Priority.high.displayName, "high")
    }

    // MARK: - isCompleted

    func testIsCompletedTrueWhenCompletedAtSet() {
        XCTAssertTrue(makeTask(completedAt: now).isCompleted)
    }

    func testIsCompletedFalseWhenCompletedAtNil() {
        XCTAssertFalse(makeTask().isCompleted)
    }

    // MARK: - isOverdue

    func testIsOverdueTrueForPastDueDateNotCompleted() {
        let task = makeTask(dueAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(task.isOverdue(asOf: now))
    }

    func testIsOverdueFalseWhenCompleted() {
        let task = makeTask(dueAt: now.addingTimeInterval(-3600), completedAt: now)
        XCTAssertFalse(task.isOverdue(asOf: now))
    }

    func testIsOverdueFalseWhenNoDueDate() {
        XCTAssertFalse(makeTask().isOverdue(asOf: now))
    }

    func testIsOverdueFalseForFutureDueDate() {
        let task = makeTask(dueAt: now.addingTimeInterval(3600))
        XCTAssertFalse(task.isOverdue(asOf: now))
    }

    // MARK: - isDueWithin24Hours (drives Today; doc: "inclusive of overdue")

    func testIsDueWithin24HoursTrueForOverdueTask() {
        let task = makeTask(dueAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(task.isDueWithin24Hours(asOf: now))
    }

    func testIsDueWithin24HoursTrueExactlyAtTheBoundary() {
        let task = makeTask(dueAt: now.addingTimeInterval(24 * 60 * 60))
        XCTAssertTrue(task.isDueWithin24Hours(asOf: now))
    }

    func testIsDueWithin24HoursFalseJustPastTheBoundary() {
        let task = makeTask(dueAt: now.addingTimeInterval(24 * 60 * 60 + 1))
        XCTAssertFalse(task.isDueWithin24Hours(asOf: now))
    }

    func testIsDueWithin24HoursFalseWhenCompleted() {
        let task = makeTask(dueAt: now.addingTimeInterval(3600), completedAt: now)
        XCTAssertFalse(task.isDueWithin24Hours(asOf: now))
    }

    // MARK: - isDueWithin7DaysButNotToday (drives Upcoming)

    func testIsDueWithin7DaysButNotTodayFalseForTasksDueWithin24Hours() {
        let task = makeTask(dueAt: now.addingTimeInterval(3600))
        XCTAssertFalse(task.isDueWithin7DaysButNotToday(asOf: now))
    }

    func testIsDueWithin7DaysButNotTodayTrueForTaskDueInThreeDays() {
        let task = makeTask(dueAt: now.addingTimeInterval(3 * 24 * 60 * 60))
        XCTAssertTrue(task.isDueWithin7DaysButNotToday(asOf: now))
    }

    func testIsDueWithin7DaysButNotTodayFalseForTaskDueInEightDays() {
        let task = makeTask(dueAt: now.addingTimeInterval(8 * 24 * 60 * 60))
        XCTAssertFalse(task.isDueWithin7DaysButNotToday(asOf: now))
    }

    // MARK: - autoClassifiedList

    func testAutoClassifiedListReturnsAnytimeWhenNoDueDate() {
        XCTAssertEqual(makeTask().autoClassifiedList(asOf: now), .anytime)
    }

    func testAutoClassifiedListReturnsTodayWhenDueWithin24Hours() {
        let task = makeTask(dueAt: now.addingTimeInterval(3600))
        XCTAssertEqual(task.autoClassifiedList(asOf: now), .today)
    }

    func testAutoClassifiedListReturnsUpcomingWhenDueWithinAWeek() {
        let task = makeTask(dueAt: now.addingTimeInterval(3 * 24 * 60 * 60))
        XCTAssertEqual(task.autoClassifiedList(asOf: now), .upcoming)
    }

    func testAutoClassifiedListReturnsAnytimeWhenDueFarInFuture() {
        let task = makeTask(dueAt: now.addingTimeInterval(30 * 24 * 60 * 60))
        XCTAssertEqual(task.autoClassifiedList(asOf: now), .anytime)
    }

    func testAutoClassifiedListReturnsCurrentListWhenCompleted() {
        let task = makeTask(dueAt: now.addingTimeInterval(3600), completedAt: now, list: .someday)
        XCTAssertEqual(task.autoClassifiedList(asOf: now), .someday)
    }

    // MARK: - notesPreview

    func testNotesPreviewIsEmptyForEmptyNotes() {
        var task = makeTask()
        task.notes = "   "
        XCTAssertEqual(task.notesPreview, "")
    }

    func testNotesPreviewIsUnchangedWhenShort() {
        var task = makeTask()
        task.notes = "short note"
        XCTAssertEqual(task.notesPreview, "short note")
    }

    func testNotesPreviewIsTruncatedAt60CharsWithEllipsis() {
        var task = makeTask()
        task.notes = String(repeating: "a", count: 100)
        let preview = task.notesPreview
        XCTAssertEqual(preview.count, 61) // 60 chars + ellipsis
        XCTAssertTrue(preview.hasSuffix("\u{2026}"))
    }
}
