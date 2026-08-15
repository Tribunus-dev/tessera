import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraDenialCircuitBreaker.swift
// doc comment -- "Trips on 3 consecutive denials OR 10 denials in the
// last 50 actions." Listed as a "healthy surface, do not touch" in
// docs/AGENT-UX-FATIGUE-REVIEW.md Part 4 (approval engine section); still
// a first-class safety surface worth a named test per the doctrine's
// coverage-shape table.
final class TesseraDenialCircuitBreakerTests: DoctrineTestCase {

    func testFreshBreakerIsNotTripped() {
        XCTAssertFalse(TesseraDenialCircuitBreaker().isTripped)
    }

    func testConstantsMatchTheDocumentedThresholds() {
        XCTAssertEqual(TesseraDenialCircuitBreaker.consecutiveLimit, 3)
        XCTAssertEqual(TesseraDenialCircuitBreaker.windowSize, 50)
        XCTAssertEqual(TesseraDenialCircuitBreaker.windowLimit, 10)
    }

    // MARK: - Consecutive-denial rule

    func testTwoConsecutiveDenialsDoNotTrip() {
        let breaker = TesseraDenialCircuitBreaker()
        breaker.record(denied: true)
        breaker.record(denied: true)
        XCTAssertFalse(breaker.isTripped)
    }

    func testThreeConsecutiveDenialsTrip() {
        let breaker = TesseraDenialCircuitBreaker()
        breaker.record(denied: true)
        breaker.record(denied: true)
        breaker.record(denied: true)
        XCTAssertTrue(breaker.isTripped)
    }

    func testAnApprovalBetweenDenialsResetsTheConsecutiveCounter() {
        let breaker = TesseraDenialCircuitBreaker()
        breaker.record(denied: true)
        breaker.record(denied: true)
        breaker.record(denied: false) // approval breaks the streak
        breaker.record(denied: true)
        breaker.record(denied: true)
        XCTAssertFalse(breaker.isTripped, "only 2 consecutive denials since the approval")
    }

    func testThreeConsecutiveDenialsAfterAnEarlierResetStillTrips() {
        let breaker = TesseraDenialCircuitBreaker()
        breaker.record(denied: true)
        breaker.record(denied: false)
        breaker.record(denied: true)
        breaker.record(denied: true)
        breaker.record(denied: true)
        XCTAssertTrue(breaker.isTripped)
    }

    // MARK: - Windowed-rate rule (10 denials in the last 50 actions,
    // independent of consecutiveness)

    func testTenNonConsecutiveDenialsWithinWindowTrip() {
        let breaker = TesseraDenialCircuitBreaker()
        // Alternate approve/deny 9 times (9 denials, none consecutive
        // beyond 1), then one more denial to reach 10 total denials
        // inside the last 50 actions.
        for _ in 0..<9 {
            breaker.record(denied: false)
            breaker.record(denied: true)
        }
        XCTAssertFalse(breaker.isTripped, "9 denials, none consecutive, should not yet trip")
        breaker.record(denied: false)
        breaker.record(denied: true)
        XCTAssertTrue(breaker.isTripped, "10th non-consecutive denial should trip the windowed rule")
    }

    func testNineDenialsWithinWindowDoNotTrip() {
        let breaker = TesseraDenialCircuitBreaker()
        for _ in 0..<9 {
            breaker.record(denied: false)
            breaker.record(denied: true)
        }
        XCTAssertFalse(breaker.isTripped)
    }

    // MARK: - Sliding window cap: only the last `windowSize` outcomes count

    func testOutcomesOlderThanWindowSizeDoNotCountTowardTheRateRule() {
        let breaker = TesseraDenialCircuitBreaker()
        // 10 denials, then enough approvals to push them out of the
        // 50-action sliding window; the rate rule should no longer see them.
        for _ in 0..<10 {
            breaker.record(denied: true)
        }
        // The 10 denials trip the consecutive rule too (>= 3 in a row);
        // reset is the documented way to clear state for this test's
        // windowed-only assertion.
        breaker.reset()
        for _ in 0..<10 {
            breaker.record(denied: true)
        }
        XCTAssertTrue(breaker.isTripped, "sanity: 10 consecutive denials trip immediately")
        // Push 50 approvals through so the original 10 denials fall out
        // of the 50-entry sliding window.
        for _ in 0..<50 {
            breaker.record(denied: false)
        }
        XCTAssertFalse(breaker.isTripped, "old denials must fall out of the sliding window")
    }

    // MARK: - reset()

    func testResetClearsAllRecordedOutcomes() {
        let breaker = TesseraDenialCircuitBreaker()
        breaker.record(denied: true)
        breaker.record(denied: true)
        breaker.record(denied: true)
        XCTAssertTrue(breaker.isTripped)
        breaker.reset()
        XCTAssertFalse(breaker.isTripped)
    }

    // MARK: - Independent oracle (rule 7): pin the trip boundary against
    // a hand-rolled reference implementation of the documented rule, not
    // against the breaker's own internal state.

    func testTripBoundaryMatchesAHandRolledReferenceOverRandomizedSequences() {
        var seed: UInt64 = 0xC0FFEE
        func nextBool() -> Bool {
            // xorshift64*, deterministic given the fixed seed above.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed % 2 == 0
        }
        for trial in 0..<20 {
            let breaker = TesseraDenialCircuitBreaker()
            var reference: [Bool] = []
            let length = 5 + (trial * 3) % 60
            for _ in 0..<length {
                let denied = nextBool()
                breaker.record(denied: denied)
                reference.append(denied)
                if reference.count > 50 {
                    reference.removeFirst(reference.count - 50)
                }
                let consecutive = reference.reversed().prefix { $0 }.count
                let windowDenials = reference.filter { $0 }.count
                let expectedTripped = consecutive >= 3 || windowDenials >= 10
                XCTAssertEqual(
                    breaker.isTripped, expectedTripped,
                    "trial \(trial) diverged from the reference rule after \(reference.count) outcomes"
                )
            }
        }
    }
}
