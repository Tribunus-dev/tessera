import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Encryption/TesseraNotificationBudget.swift
// doc comments plus AGENTS.md "Notification budget (Wave 1, item 1D)" and
// the doctrine's explicit emphasis for this cluster: "budget respects the
// UTC-day boundary (inject a clock/date across a day rollover and assert
// the counter resets), .dryRun excluded from the postable set."
//
// Each test constructs its OWN `TesseraNotificationBudget` instance
// (never `.shared`) so per-day counter state never leaks between tests.
// The JSONL log, however, is a fixed on-disk path
// (`TesseraNotificationBudget.logFileURL()`) shared by every instance in
// the process; tests that touch it flip `TesseraSettings.telemetryEnabled`
// (also a shared UserDefaults key) and reset the log file in
// setUp/tearDown to stay deterministic (rule 4) regardless of run order.
final class TesseraNotificationBudgetTests: DoctrineTestCase {

    private static let telemetryKey = TesseraSettingsKey.telemetryEnabled

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.telemetryKey)
        TesseraNotificationBudgetLog.reset()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.telemetryKey)
        TesseraNotificationBudgetLog.reset()
        super.tearDown()
    }

    // MARK: - Hard cap: no force override (doctrine emphasis + AGENTS.md
    // "The cap on a budget is a HARD cap. There is no force: override.")

    func testDefaultCapPerDayIsThree() async {
        XCTAssertEqual(TesseraNotificationBudget.defaultCapPerDay, 3)
        let budget = TesseraNotificationBudget()
        XCTAssertEqual(budget.capPerDay, 3)
    }

    func testFirstThreePostsWithinTheCapSucceed() async {
        let budget = TesseraNotificationBudget()
        for i in 0..<3 {
            let ok = await budget.tryPost(category: .workflow, title: "t\(i)", body: "b")
            XCTAssertTrue(ok, "post #\(i) should be within the cap")
        }
    }

    func testFourthPostSameDayIsBlockedByTheHardCap() async {
        let budget = TesseraNotificationBudget()
        for _ in 0..<3 {
            _ = await budget.tryPost(category: .workflow, title: "t", body: "b")
        }
        let fourth = await budget.tryPost(category: .workflow, title: "t4", body: "b")
        XCTAssertFalse(fourth, "the 4th post the same day must be blocked by the hard cap")
    }

    func testCapIsHardAcrossCategoriesNotPerCategory() async {
        // The cap is one shared per-day counter, not per-category (doc
        // comment: "per-UTC-day counter, default cap 3" -- singular).
        let budget = TesseraNotificationBudget()
        _ = await budget.tryPost(category: .workflow, title: "a", body: "b")
        _ = await budget.tryPost(category: .training, title: "a", body: "b")
        _ = await budget.tryPost(category: .adaptation, title: "a", body: "b")
        let fourth = await budget.tryPost(category: .assessment, title: "a", body: "b")
        XCTAssertFalse(fourth, "the shared counter must block a 4th post regardless of category")
    }

    func testTesseraNotificationBudgetHasNoForceParameterAnywhereInItsPublicAPI() throws {
        // Structural guard (doctrine emphasis): grep the actor's own
        // source for a `force:` parameter label, ignoring comment lines
        // (the file's own doc comment documents the ABSENCE of a
        // force: override in prose, which would otherwise false-
        // positive a naive whole-file substring search).
        let url = try notificationBudgetSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        let codeLines = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertFalse(
            codeLines.contains { $0.contains("force:") },
            "TesseraNotificationBudget.swift must not gain a `force:` bypass -- the hard-cap invariant is structural"
        )
    }

    private func notificationBudgetSourceURL() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // Encryption/
            .deletingLastPathComponent() // TesseraCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // TesseraStudio/
        let sourceURL = repoRoot.appendingPathComponent("Sources/TesseraCore/Encryption/TesseraNotificationBudget.swift")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("TesseraNotificationBudget.swift not found at expected path; skipping structural grep")
        }
        return sourceURL
    }

    // MARK: - UTC-day boundary reset (doctrine emphasis: "inject a
    // clock/date across a day rollover and assert the counter resets").
    // `advanceDay(by:)` is the documented test-only seam for this.

    func testAdvanceDayResetsTheDailyCounter() async {
        let budget = TesseraNotificationBudget()
        for _ in 0..<3 {
            _ = await budget.tryPost(category: .workflow, title: "t", body: "b")
        }
        let fourth = await budget.tryPost(category: .workflow, title: "blocked", body: "b")
        XCTAssertFalse(fourth)
        await budget.advanceDay(by: 1)
        let afterReset = await budget.deliveredToday()
        XCTAssertEqual(afterReset, 0, "the counter must reset across the UTC-day boundary")
        let afterRollover = await budget.tryPost(category: .workflow, title: "new day", body: "b")
        XCTAssertTrue(afterRollover, "a fresh day must allow posts again, up to the cap")
    }

    func testDeliveredTodayTracksSuccessfulPostsOnly() async {
        let budget = TesseraNotificationBudget()
        let initial = await budget.deliveredToday()
        XCTAssertEqual(initial, 0)
        _ = await budget.tryPost(category: .workflow, title: "a", body: "b")
        _ = await budget.tryPost(category: .workflow, title: "b", body: "b")
        let afterTwo = await budget.deliveredToday()
        XCTAssertEqual(afterTwo, 2)
        // Exhaust the cap; blocked attempts must not inflate the count.
        _ = await budget.tryPost(category: .workflow, title: "c", body: "b")
        _ = await budget.tryPost(category: .workflow, title: "blocked", body: "b")
        let afterExhausted = await budget.deliveredToday()
        XCTAssertEqual(afterExhausted, 3)
    }

    // MARK: - .dryRun excluded from the postable set (doctrine emphasis),
    // gated behind devMode (AGENTS.md: "dropped from the postable set and
    // gated behind a separate devMode flag")

    func testDryRunOutcomeIsBlockedWhenDevModeIsOff() async {
        let budget = TesseraNotificationBudget()
        let devMode = await budget.isDevMode()
        XCTAssertFalse(devMode)
        let posted = await budget.tryPost(category: .training, title: "t", body: "b", outcome: "dryRun")
        XCTAssertFalse(posted, ".dryRun must be excluded from the postable set by default")
    }

    func testDryRunOutcomeIsAllowedOnceDevModeIsEnabled() async {
        let budget = TesseraNotificationBudget()
        await budget.setDevMode(true)
        let posted = await budget.tryPost(category: .training, title: "t", body: "b", outcome: "dryRun")
        XCTAssertTrue(posted, "devMode is the documented escape hatch for .dryRun")
    }

    func testDryRunBlockDoesNotConsumeTheDailyCounter() async {
        let budget = TesseraNotificationBudget()
        _ = await budget.tryPost(category: .training, title: "t", body: "b", outcome: "dryRun")
        let delivered = await budget.deliveredToday()
        XCTAssertEqual(delivered, 0, "a blocked dryRun post must not count toward the cap")
    }

    func testNonDryRunOutcomeIsUnaffectedByDevModeState() async {
        let budget = TesseraNotificationBudget()
        let posted = await budget.tryPost(category: .training, title: "t", body: "b", outcome: "success")
        XCTAssertTrue(posted)
    }

    // MARK: - JSONL log (respects TesseraSettings.telemetryEnabled)

    func testLogStaysEmptyWhenTelemetryIsDisabled() async {
        XCTAssertFalse(TesseraSettings.telemetryEnabled, "sanity: telemetry defaults to false")
        let budget = TesseraNotificationBudget()
        _ = await budget.tryPost(category: .workflow, title: "t", body: "b")
        XCTAssertTrue(TesseraNotificationBudgetLog.events().isEmpty, "no JSONL row should be written while telemetry is off")
    }

    func testLogRecordsAPostedEventWhenTelemetryIsEnabled() async {
        UserDefaults.standard.set(true, forKey: Self.telemetryKey)
        XCTAssertTrue(TesseraSettings.telemetryEnabled)
        let budget = TesseraNotificationBudget()
        let marker = "doctrine-test-\(UUID().uuidString)"
        _ = await budget.tryPost(category: .workflow, title: marker, body: "b")
        let events = TesseraNotificationBudgetLog.events()
        let mine = events.first { $0.title == marker }
        XCTAssertNotNil(mine, "a posted event must be logged when telemetry is enabled")
        XCTAssertEqual(mine?.posted, true)
        XCTAssertNil(mine?.blockedReason)
    }

    func testLogRecordsABlockedEventWithReasonCapExceeded() async {
        UserDefaults.standard.set(true, forKey: Self.telemetryKey)
        let budget = TesseraNotificationBudget()
        for _ in 0..<3 {
            _ = await budget.tryPost(category: .workflow, title: "filler", body: "b")
        }
        let marker = "doctrine-blocked-\(UUID().uuidString)"
        _ = await budget.tryPost(category: .workflow, title: marker, body: "b")
        let events = TesseraNotificationBudgetLog.events()
        let mine = events.first { $0.title == marker }
        XCTAssertEqual(mine?.posted, false)
        XCTAssertEqual(mine?.blockedReason, "cap_exceeded")
    }

    // MARK: - Round-trip identity (rule 2) for TesseraNotificationEvent

    func testNotificationEventEncodeDecodeIdentity() throws {
        let event = TesseraNotificationEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            utcDay: "2026-08-14",
            category: TesseraNotificationCategory.workflow.rawValue,
            title: "t", body: "b", outcome: "success", posted: true, blockedReason: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TesseraNotificationEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testNotificationCategoryHasTheSevenDocumentedCases() {
        // Independent oracle (rule 7): pinned against AGENTS.md's named
        // set, not against TesseraNotificationCategory.allCases (which
        // doesn't even exist -- this enum isn't CaseIterable, so the
        // pin is against the literal list in the doc comment).
        let expected: Set<String> = ["workflow", "training", "adaptation", "assessment", "covert", "wipeReport", "reminder"]
        let actual: Set<String> = [
            TesseraNotificationCategory.workflow.rawValue,
            TesseraNotificationCategory.training.rawValue,
            TesseraNotificationCategory.adaptation.rawValue,
            TesseraNotificationCategory.assessment.rawValue,
            TesseraNotificationCategory.covert.rawValue,
            TesseraNotificationCategory.wipeReport.rawValue,
            TesseraNotificationCategory.reminder.rawValue,
        ]
        XCTAssertEqual(actual, expected)
    }
}
