import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Learning/TesseraMiscalibrationDetector.swift
// doc comment (autonomy spec section 12) -- "a class... that was
// consistently approved flips to consistently denied. Response: TIGHTEN."
// Defaults: windowSize 20, hiThreshold 0.8, loThreshold 0.3. No design
// doc covers this subsystem beyond the source doc comment (contract
// fallback per this cluster's instructions).
final class TesseraMiscalibrationDetectorTests: DoctrineTestCase {

    func testDefaultsMatchTheDocumentedConstants() {
        let detector = TesseraMiscalibrationDetector()
        XCTAssertEqual(detector.windowSize, 20)
        XCTAssertEqual(detector.hiThreshold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(detector.loThreshold, 0.3, accuracy: 0.0001)
    }

    func testFreshDetectorIsNotTightenedForAnyClass() {
        let detector = TesseraMiscalibrationDetector()
        XCTAssertFalse(detector.isTightened("bash:git"))
        XCTAssertNil(detector.approvalRate(for: "bash:git"))
        XCTAssertNil(detector.globalApprovalRate())
    }

    // MARK: - Regime-shift TIGHTEN (small window for fast fixtures)

    func testHighApprovalThenConsistentDenialTriggersTighten() {
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        // Fill the window with a high-approval regime (rate 1.0 > 0.8).
        var triggered = false
        for _ in 0..<5 {
            triggered = detector.record(actionClass: "bash:git", approved: true) || triggered
        }
        XCTAssertFalse(triggered, "a purely high-approval regime never tightens")
        XCTAssertFalse(detector.isTightened("bash:git"))

        // Now flip to a consistent-denial regime (rate drops below 0.3).
        for _ in 0..<5 {
            triggered = detector.record(actionClass: "bash:git", approved: false) || triggered
        }
        XCTAssertTrue(triggered, "a regime shift from high-approval to high-denial must TIGHTEN")
        XCTAssertTrue(detector.isTightened("bash:git"))
    }

    func testConsistentDenialWithoutAPriorHighApprovalRegimeNeverTightens() {
        // Doc comment: "highRegimeSeen... A regime shift is only
        // meaningful for something that WAS approved". A class denied
        // from the very start never crosses the hi threshold, so it
        // must never tighten even at a 0% approval rate.
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        var triggered = false
        for _ in 0..<10 {
            triggered = detector.record(actionClass: "bash:rm", approved: false) || triggered
        }
        XCTAssertFalse(triggered)
        XCTAssertFalse(detector.isTightened("bash:rm"))
    }

    func testTighteningIsPerClassNotGlobalByDefault() {
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        // The global window is a single chronological stream of EVERY
        // class's outcomes (record()'s own "Global window" section), so
        // if class A were the only class ever recorded, A's own window
        // and the global window would be identical sequences and BOTH
        // would tighten together - that wouldn't actually distinguish
        // per-class from global. Class B is interleaved, always
        // approved, specifically to keep the global window's recent
        // approval rate diluted above loThreshold while A's own window
        // (which only accumulates A's own outcomes) tanks on its own.
        for _ in 0..<5 {
            _ = detector.record(actionClass: "A", approved: true)
            _ = detector.record(actionClass: "B", approved: true)
        }
        for _ in 0..<5 {
            _ = detector.record(actionClass: "A", approved: false)
            _ = detector.record(actionClass: "B", approved: true)
        }
        XCTAssertTrue(detector.isTightened("A"))
        // Class B: never denied, and the interleaving above keeps the
        // global window's rate above loThreshold throughout, so neither
        // B's own window nor the global flag tightens.
        XCTAssertFalse(detector.isTightened("B"))
    }

    func testAutoRecoveryUntightensWhenApprovalRateClimbsBackAboveHi() {
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: true) }
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: false) }
        XCTAssertTrue(detector.isTightened("A"))
        // Climb back above hiThreshold.
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: true) }
        XCTAssertFalse(detector.isTightened("A"), "auto-recovery: the class must un-tighten once approval rate climbs back above hi")
    }

    // MARK: - Global regime shift

    func testGlobalStreamTightensAndIsTightenedIsTrueForAnyClass() {
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        for _ in 0..<5 { _ = detector.record(actionClass: "unique-class-1", approved: true) }
        for _ in 0..<5 { _ = detector.record(actionClass: "unique-class-2", approved: false) }
        XCTAssertTrue(detector.isTightened("some-completely-different-class"), "a global tighten gates every class, per isTightened's doc comment")
    }

    // MARK: - approvalRate / globalApprovalRate

    func testApprovalRateReflectsTheRollingWindowOnly() throws {
        var detector = TesseraMiscalibrationDetector(windowSize: 3, hiThreshold: 0.99, loThreshold: 0.01)
        _ = detector.record(actionClass: "A", approved: true)
        _ = detector.record(actionClass: "A", approved: true)
        _ = detector.record(actionClass: "A", approved: false)
        let rate = try XCTUnwrap(detector.approvalRate(for: "A"))
        XCTAssertEqual(rate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testApprovalRateWindowSlidesPastWindowSize() throws {
        var detector = TesseraMiscalibrationDetector(windowSize: 2, hiThreshold: 0.99, loThreshold: 0.01)
        _ = detector.record(actionClass: "A", approved: true)
        _ = detector.record(actionClass: "A", approved: true)
        _ = detector.record(actionClass: "A", approved: false)
        // Only the last 2 outcomes count: [true, false] -> 0.5
        let rate = try XCTUnwrap(detector.approvalRate(for: "A"))
        XCTAssertEqual(rate, 0.5, accuracy: 0.0001)
    }

    // MARK: - reset()

    func testResetClearsAllTightenedStateAndWindows() {
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: true) }
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: false) }
        XCTAssertTrue(detector.isTightened("A"))
        detector.reset()
        XCTAssertFalse(detector.isTightened("A"))
        XCTAssertNil(detector.approvalRate(for: "A"))
    }

    // MARK: - Round-trip identity (rule 2)

    func testEncodeDecodeIdentityPreservesConfigAndTightenedState() throws {
        var detector = TesseraMiscalibrationDetector(windowSize: 5, hiThreshold: 0.8, loThreshold: 0.3)
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: true) }
        for _ in 0..<5 { _ = detector.record(actionClass: "A", approved: false) }
        let data = try JSONEncoder().encode(detector)
        let decoded = try JSONDecoder().decode(TesseraMiscalibrationDetector.self, from: data)
        XCTAssertTrue(decoded.isTightened("A"))
        XCTAssertEqual(decoded.windowSize, detector.windowSize)
    }
}
