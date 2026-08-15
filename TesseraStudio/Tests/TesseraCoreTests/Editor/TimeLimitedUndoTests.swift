import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Editor/TimeLimitedUndo.swift doc
// comments (TimeLimitedUndoPolicy, TimeLimitedUndoBudget) plus AGENTS.md
// "TimeLimitedUndoPolicy + TimeLimitedUndoBudget + TimeLimitedUndoChip ...
// time-based undo cap (default 90s) replacing the depth cap" and
// docs/PROJECT-STATUS.md item 2C ("Time-limited undo... default 90s,
// configurable, lazy expiry on every canUndo read").
//
// `TimeLimitedUndoChip` and the AppKit host (`EditorUndoCoordinator.swift`)
// live in TesseraStudioMac, outside this target's reach -- see
// openQuestions in the wave report. This file covers the pure core value
// types only: `TimeLimitedUndoPolicy` and `TimeLimitedUndoBudget`.
final class TimeLimitedUndoTests: DoctrineTestCase {

    // MARK: - TimeLimitedUndoPolicy

    func testDefaultPolicyCapIsNinetySeconds() {
        XCTAssertEqual(TimeLimitedUndoPolicy.default.cap, 90.0)
    }

    func testDefaultPolicyClockIsRealWallClock() {
        // The default policy's clock should track the real system clock
        // (within a generous tolerance for test execution jitter), per
        // the doc comment "production uses Date()".
        let before = Date()
        let sampled = TimeLimitedUndoPolicy.default.clock()
        let after = Date()
        XCTAssertGreaterThanOrEqual(sampled, before)
        XCTAssertLessThanOrEqual(sampled, after.addingTimeInterval(1))
    }

    func testCustomPolicyUsesInjectedClockNotRealClock() {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        let policy = TimeLimitedUndoPolicy(cap: 30, clock: { fixed })
        XCTAssertEqual(policy.clock(), fixed)
        XCTAssertEqual(policy.cap, 30)
    }

    // MARK: - TimeLimitedUndoBudget.empty

    func testEmptyBudgetHasNoRegisteredEntry() {
        let budget = TimeLimitedUndoBudget.empty
        XCTAssertNil(budget.registeredAt)
    }

    func testEmptyBudgetIsExpired() {
        XCTAssertTrue(TimeLimitedUndoBudget.empty.isExpired)
    }

    func testEmptyBudgetIsNotAvailable() {
        XCTAssertFalse(TimeLimitedUndoBudget.empty.isAvailable)
    }

    func testEmptyBudgetHasZeroRemainingSeconds() {
        XCTAssertEqual(TimeLimitedUndoBudget.empty.remainingSeconds, 0)
    }

    // MARK: - Lazy expiry, injected clock (rule 4: determinism)

    func testBudgetIsAvailableBeforeCapElapses() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        // Clock reads 10s after registration; cap is 90s -> still available.
        let policy = TimeLimitedUndoPolicy(cap: 90, clock: { registeredAt.addingTimeInterval(10) })
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: policy)
        XCTAssertTrue(budget.isAvailable)
        XCTAssertFalse(budget.isExpired)
    }

    func testBudgetExpiresExactlyAtCapBoundary() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        // Clock reads exactly 90s after registration; the contract is
        // ">= cap is expired" (TimeLimitedUndoBudget.isExpired doc comment).
        let policy = TimeLimitedUndoPolicy(cap: 90, clock: { registeredAt.addingTimeInterval(90) })
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: policy)
        XCTAssertTrue(budget.isExpired)
        XCTAssertFalse(budget.isAvailable)
    }

    func testBudgetIsExpiredAfterCapElapses() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let policy = TimeLimitedUndoPolicy(cap: 90, clock: { registeredAt.addingTimeInterval(120) })
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: policy)
        XCTAssertTrue(budget.isExpired)
        XCTAssertFalse(budget.isAvailable)
    }

    func testRemainingSecondsAtGivenTimeCountsDownFromCap() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: TimeLimitedUndoPolicy(cap: 90))
        XCTAssertEqual(budget.remainingSeconds(at: registeredAt), 90, accuracy: 0.001)
        XCTAssertEqual(budget.remainingSeconds(at: registeredAt.addingTimeInterval(30)), 60, accuracy: 0.001)
        XCTAssertEqual(budget.remainingSeconds(at: registeredAt.addingTimeInterval(90)), 0, accuracy: 0.001)
    }

    func testRemainingSecondsNeverGoesNegative() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: TimeLimitedUndoPolicy(cap: 90))
        // Far past expiry: remaining clamps at 0, does not go negative.
        XCTAssertEqual(budget.remainingSeconds(at: registeredAt.addingTimeInterval(10_000)), 0)
    }

    func testRemainingSecondsWithNoEntryIsZero() {
        let budget = TimeLimitedUndoBudget(registeredAt: nil, policy: .default)
        XCTAssertEqual(budget.remainingSeconds(at: Date()), 0)
    }

    func testProgressIsZeroAtRegistrationAndOneAtCap() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: TimeLimitedUndoPolicy(cap: 90))
        XCTAssertEqual(budget.progress(at: registeredAt), 0, accuracy: 0.001)
        XCTAssertEqual(budget.progress(at: registeredAt.addingTimeInterval(45)), 0.5, accuracy: 0.001)
        XCTAssertEqual(budget.progress(at: registeredAt.addingTimeInterval(90)), 1.0, accuracy: 0.001)
    }

    func testProgressClampsAtOneAfterExpiry() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: TimeLimitedUndoPolicy(cap: 90))
        XCTAssertEqual(budget.progress(at: registeredAt.addingTimeInterval(500)), 1.0, accuracy: 0.001)
    }

    func testProgressWithNoEntryIsZero() {
        let budget = TimeLimitedUndoBudget(registeredAt: nil, policy: .default)
        XCTAssertEqual(budget.progress(at: Date()), 0)
    }

    func testRemainingLabelRoundsDownToWholeSeconds() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: TimeLimitedUndoPolicy(cap: 90))
        // 12.7s remaining -> "12s" (rounds down, per the doc comment: "the
        // user sees a count that ticks down, not up").
        let now = registeredAt.addingTimeInterval(90 - 12.7)
        XCTAssertEqual(budget.remainingLabel(at: now), "12s")
    }

    func testRemainingLabelAtExpiryIsZeroSeconds() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: TimeLimitedUndoPolicy(cap: 90))
        XCTAssertEqual(budget.remainingLabel(at: registeredAt.addingTimeInterval(200)), "0s")
    }

    // MARK: - Property: isAvailable and isExpired are always complements
    // for a registered entry (rule 9: property test).

    func testIsAvailableAndIsExpiredAreComplementsAcrossTheTimeline() {
        let registeredAt = Date(timeIntervalSince1970: 1_000_000)
        let offsets: [TimeInterval] = [-5, 0, 1, 44, 89, 89.999, 90, 91, 1000]
        for offset in offsets {
            let policy = TimeLimitedUndoPolicy(cap: 90, clock: { registeredAt.addingTimeInterval(offset) })
            let budget = TimeLimitedUndoBudget(registeredAt: registeredAt, policy: policy)
            XCTAssertEqual(
                budget.isAvailable, !budget.isExpired,
                "isAvailable and isExpired must be complements at offset \(offset)"
            )
        }
    }
}
