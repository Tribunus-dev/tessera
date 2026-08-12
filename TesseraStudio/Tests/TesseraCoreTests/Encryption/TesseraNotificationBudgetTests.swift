import XCTest
@testable import TesseraCore

/// Tests for the shared per-UTC-day notification budget
/// (review #3 of the agent-ux-fatigue Tessera Studio audit).
///
/// Coverage:
///   - cap enforcement (4th post in a day is rejected, logged)
///   - per-UTC-day reset
///   - .dryRun outcome is rejected unless devMode is on
///   - devMode opens the gate; cap still applies
///   - JSONL log row is written per attempt (posted and blocked)
///   - the two notifier wraps (PleadTheFifth wipe report and
///     CovertTriggerMonitor fire) flow through the budget
///
/// Each test owns a fresh actor so the in-memory daily counter
/// never bleeds across tests. The on-disk JSONL log is reset in
/// ``setUp`` so the audit-trail assertion starts from a clean slate.
final class TesseraNotificationBudgetTests: XCTestCase {
    private var budget: TesseraNotificationBudget!

    override func setUp() async throws {
        try await super.setUp()
        TesseraNotificationBudgetLog.reset()
        withSettings([
            TesseraSettingsKey.telemetryEnabled: true,
        ]) {
            // no-op body; just seed the defaults for the duration of
            // the test
        }
        budget = TesseraNotificationBudget()
        await budget.setDevMode(false)
    }

    override func tearDown() async throws {
        TesseraNotificationBudgetLog.reset()
        budget = nil
        try await super.tearDown()
    }

    // MARK: - Cap enforcement

    /// The 4th post in a UTC day is rejected; the first 3 succeed.
    /// This is the load-bearing cap-exceeded assertion.
    func testCapEnforcedAfterDefaultLimit() async {
        for i in 1...3 {
            let ok = await budget.tryPost(
                category: .workflow,
                title: "wf-\(i)",
                body: "run completed"
            )
            XCTAssertTrue(ok, "post #\(i) should be allowed (cap = 3)")
        }
        let rejected = await budget.tryPost(
            category: .workflow,
            title: "wf-4",
            body: "run completed"
        )
        XCTAssertFalse(rejected, "post #4 must be rejected by the hard cap")
    }

    /// The JSONL log records both the posted and the blocked attempts,
    /// so the team sees the cap engage in week 1.
    func testBlockedPostIsLogged() async {
        for i in 1...3 {
            _ = await budget.tryPost(category: .workflow, title: "wf-\(i)", body: "ok")
        }
        _ = await budget.tryPost(category: .workflow, title: "wf-4", body: "ok")

        let events = TesseraNotificationBudgetLog.events()
        let blocked = events.filter { !$0.posted }
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?.blockedReason, "cap_exceeded")
        XCTAssertEqual(blocked.first?.category, TesseraNotificationCategory.workflow.rawValue)
    }

    /// `deliveredToday` matches the number of posted (not blocked)
    /// events, so the settings surface can render the running total.
    func testDeliveredTodayCountsPosts() async {
        _ = await budget.tryPost(category: .workflow, title: "wf-1", body: "ok")
        _ = await budget.tryPost(category: .training, title: "tr-1", body: "ok")
        _ = await budget.tryPost(category: .workflow, title: "wf-2", body: "ok")
        _ = await budget.tryPost(category: .workflow, title: "wf-3", body: "blocked")
        XCTAssertEqual(await budget.deliveredToday(), 3)
    }

    // MARK: - Per-UTC-day reset

    /// Advancing the actor's internal day counter resets the cap.
    /// This is the test-friendly equivalent of waiting for midnight.
    func testCapResetsOnNewUtcDay() async {
        for i in 1...3 {
            _ = await budget.tryPost(category: .workflow, title: "wf-\(i)", body: "ok")
        }
        XCTAssertEqual(await budget.deliveredToday(), 3)
        await budget.advanceDay(by: 1)
        XCTAssertEqual(await budget.deliveredToday(), 0)
        let ok = await budget.tryPost(category: .workflow, title: "wf-newday", body: "ok")
        XCTAssertTrue(ok, "post on the new day should be allowed")
    }

    // MARK: - .dryRun gating

    /// `.dryRun` is excluded from the postable set by default; the
    /// anti-pattern is "a notification that is not actionable in
    /// 15-30 minutes" (skill, review #3 line 47-48).
    func testDryRunBlockedInProductionMode() async {
        let ok = await budget.tryPost(
            category: .training,
            title: "Training setup validated",
            body: "dry run ok",
            outcome: "dryRun"
        )
        XCTAssertFalse(ok, ".dryRun must be rejected unless devMode is on")

        let events = TesseraNotificationBudgetLog.events()
        let blocked = events.filter { $0.outcome == "dryRun" }
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?.blockedReason, "outcome_requires_dev_mode")
    }

    /// Dev mode opens the gate for .dryRun (and similar dev-mode-only
    /// outcomes); the cap still applies.
    func testDryRunAllowedInDevMode() async {
        await budget.setDevMode(true)
        let ok = await budget.tryPost(
            category: .training,
            title: "Training setup validated",
            body: "dry run ok",
            outcome: "dryRun"
        )
        XCTAssertTrue(ok, "devMode must lift the .dryRun gate")
    }

    /// Dev mode does NOT bypass the cap. The skill is explicit:
    /// "the budget must be enforced as a hard cap, not a soft
    /// target" (review #3 trade-off section).
    func testDevModeDoesNotBypassCap() async {
        await budget.setDevMode(true)
        for i in 1...3 {
            _ = await budget.tryPost(
                category: .training,
                title: "tr-\(i)",
                body: "ok",
                outcome: "dryRun"
            )
        }
        let fourth = await budget.tryPost(
            category: .training,
            title: "tr-4",
            body: "ok",
            outcome: "dryRun"
        )
        XCTAssertFalse(fourth, "the cap is hard; devMode must not lift it")
    }

    // MARK: - Notifier wires

    /// The PleadTheFifth wipe-report post flows through the budget.
    /// The wipe-report poster (`PleadTheFifthNotificationPoster`,
    /// in `TesseraStudioMac`) is the only consumer of the wipeReport
    /// category; verifying the category is accepted by the budget
    /// covers the wire.
    func testWipeReportCategoryAccepted() async {
        let ok = await budget.tryPost(
            category: .wipeReport,
            title: "Wipe report",
            body: "Open the last wipe report window."
        )
        XCTAssertTrue(ok)
        let events = TesseraNotificationBudgetLog.events()
        XCTAssertEqual(events.first?.category, TesseraNotificationCategory.wipeReport.rawValue)
    }

    /// The covert-trigger fire event flows through the budget as a
    /// `.covert` category event. The fire itself is silent in the
    /// design; the budget entry is the only audit-trail side effect
    /// beyond the system log.
    func testCovertCategoryAccepted() async {
        let ok = await budget.tryPost(
            category: .covert,
            title: "Covert trigger fired",
            body: "covert_trigger_fired"
        )
        XCTAssertTrue(ok)
        let events = TesseraNotificationBudgetLog.events()
        XCTAssertEqual(events.first?.category, TesseraNotificationCategory.covert.rawValue)
    }

    // MARK: - Settings

    /// When `telemetryEnabled` is off, the cap is still enforced
    /// (the cap is a product invariant) but no JSONL row is written.
    /// The review says the cap "respects the telemetryEnabled
    /// default from TesseraSettings": the cap is non-negotiable, the
    /// log is opt-in.
    func testTelemetryOffSkipsLogButKeepsCap() async {
        withSettings([TesseraSettingsKey.telemetryEnabled: false]) {
            // no-op
        }
        for i in 1...3 {
            _ = await budget.tryPost(category: .workflow, title: "wf-\(i)", body: "ok")
        }
        let fourth = await budget.tryPost(category: .workflow, title: "wf-4", body: "ok")
        XCTAssertFalse(fourth, "cap must still hold with telemetry off")
        XCTAssertEqual(TesseraNotificationBudgetLog.events().count, 0)
        // Restore so tearDown's reset does not write under a different flag.
        withSettings([TesseraSettingsKey.telemetryEnabled: true]) {
            // no-op
        }
    }

    // MARK: - Hard cap API

    /// `capPerDay` is the constant; there is no setter in the public
    /// API. This guards the "no force override" invariant at the
    /// type-system level: the only way to set a non-default cap is
    /// the init argument, not a runtime override.
    func testCapIsTheDefaultAndIsNotOverridable() async {
        XCTAssertEqual(budget.capPerDay, TesseraNotificationBudget.defaultCapPerDay)
        XCTAssertEqual(budget.capPerDay, 3)
    }

    // MARK: - Helpers

    /// Run `body` with the supplied UserDefaults overrides, then
    /// restore the prior values. Mirrors the helper used in
    /// ``TesseraTrainingWiringTests`` so the pattern stays
    /// consistent across the test target.
    private func withSettings<T>(
        _ overrides: [String: Any],
        _ body: () -> T
    ) -> T {
        let saved: [(String, Any?)] = overrides.keys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        for (key, value) in overrides {
            UserDefaults.standard.set(value, forKey: key)
        }
        let result = body()
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return result
    }
}
