import XCTest
@testable import TesseraCore

/// Test-only mutable counter behind a class (not a captured `var`), used
/// to prove `TesseraDictionaryEvidence`'s capture closure re-runs on
/// every `snapshot()` call.
private final class EvidenceTestCounter: @unchecked Sendable {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

// Contract source: Sources/TesseraCore/Agent/TesseraActionVerifier.swift
// doc comments -- "implementations must fail CLOSED: any error, timeout,
// or malformed input yields authorized=false", the rule-based risk
// classifier's three verb buckets, the Tian Pan confidence-band mapping,
// and the state-diff verification helper (S1).
final class TesseraActionVerifierTests: DoctrineTestCase {

    // MARK: - ruleBasedRisk: three verb buckets + unknown-tool caution

    func testDestructiveVerbIsHighRisk() throws {
        let risk = try TesseraActionVerifier.ruleBasedRisk(for: PendingAction(toolName: "delete_model"))
        XCTAssertEqual(risk, .high)
    }

    func testMutatingVerbIsMediumRisk() throws {
        let risk = try TesseraActionVerifier.ruleBasedRisk(for: PendingAction(toolName: "quantize"))
        XCTAssertEqual(risk, .medium)
    }

    func testReadOnlyVerbIsLowRisk() throws {
        let risk = try TesseraActionVerifier.ruleBasedRisk(for: PendingAction(toolName: "list_models"))
        XCTAssertEqual(risk, .low)
    }

    func testUnknownToolIsTreatedAsMediumNeverAsLow() throws {
        // "unknown tools are treated cautiously (medium), never trusted as low"
        let risk = try TesseraActionVerifier.ruleBasedRisk(for: PendingAction(toolName: "frobnicate_the_gizmo"))
        XCTAssertEqual(risk, .medium)
    }

    func testDestructiveBucketWinsOverMutatingWhenBothWordsPresent() throws {
        // "delete" (destructive) should win priority over any mutating hint.
        let risk = try TesseraActionVerifier.ruleBasedRisk(for: PendingAction(toolName: "delete_and_write"))
        XCTAssertEqual(risk, .high)
    }

    // MARK: - verify(): authorized iff risk < .high; fail-closed on throw

    func testVerifyAuthorizesLowRisk() {
        let verifier = TesseraActionVerifier(assess: { _ in .low })
        let decision = verifier.verify(PendingAction(toolName: "anything"))
        XCTAssertTrue(decision.authorized)
        XCTAssertEqual(decision.riskLevel, .low)
    }

    func testVerifyAuthorizesMediumRisk() {
        let verifier = TesseraActionVerifier(assess: { _ in .medium })
        XCTAssertTrue(verifier.verify(PendingAction(toolName: "anything")).authorized)
    }

    func testVerifyDeniesHighRisk() {
        let verifier = TesseraActionVerifier(assess: { _ in .high })
        XCTAssertFalse(verifier.verify(PendingAction(toolName: "anything")).authorized)
    }

    func testVerifyDeniesForbiddenRisk() {
        let verifier = TesseraActionVerifier(assess: { _ in .forbidden })
        XCTAssertFalse(verifier.verify(PendingAction(toolName: "anything")).authorized)
    }

    func testVerifyFailsClosedWhenAssessThrows() {
        struct Boom: Error {}
        let verifier = TesseraActionVerifier(assess: { _ in throw Boom() })
        let decision = verifier.verify(PendingAction(toolName: "anything"))
        XCTAssertFalse(decision.authorized, "an erroring assessment must never authorize")
        XCTAssertEqual(decision.riskLevel, .high)
        XCTAssertFalse(decision.rationale.isEmpty)
    }

    func testDefaultVerifierUsesRuleBasedRisk() {
        let verifier = TesseraActionVerifier()
        let decision = verifier.verify(PendingAction(toolName: "list_models"))
        XCTAssertTrue(decision.authorized)
        XCTAssertEqual(decision.riskLevel, .low)
    }

    // MARK: - Confidence band mapping (Tian Pan 2026-04-12 split): the
    // mapping is monotone, highest risk -> lowest confidence.

    func testConfidenceBandMappingIsInverseAndMonotone() {
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .low), .high)
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .medium), .medium)
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .high), .low)
        XCTAssertEqual(TesseraActionVerifier.confidenceBand(for: .forbidden), .low)
    }

    // MARK: - State-diff verification (S1): a self-reported success is
    // not enough; the value must actually differ.

    func testVerifyStateChangeDetectsAddedKey() {
        XCTAssertTrue(TesseraActionVerifier.verifyStateChange(pre: [:], post: ["k": "v"], expect: "k"))
    }

    func testVerifyStateChangeDetectsRemovedKey() {
        XCTAssertTrue(TesseraActionVerifier.verifyStateChange(pre: ["k": "v"], post: [:], expect: "k"))
    }

    func testVerifyStateChangeDetectsChangedValue() {
        XCTAssertTrue(TesseraActionVerifier.verifyStateChange(pre: ["k": "v1"], post: ["k": "v2"], expect: "k"))
    }

    func testVerifyStateChangeIsFalseWhenValueUnchanged() {
        XCTAssertFalse(TesseraActionVerifier.verifyStateChange(pre: ["k": "v"], post: ["k": "v"], expect: "k"))
    }

    func testVerifyStateChangeIsFalseWhenKeyAbsentInBoth() {
        XCTAssertFalse(TesseraActionVerifier.verifyStateChange(pre: [:], post: [:], expect: "k"))
    }

    // MARK: - TesseraDictionaryEvidence: re-captures on each snapshot()

    func testDictionaryEvidenceStaticValuesNeverChange() {
        let evidence = TesseraDictionaryEvidence(static: ["a": "1"])
        XCTAssertEqual(evidence.snapshot(), ["a": "1"])
        XCTAssertEqual(evidence.snapshot(), ["a": "1"])
    }

    func testDictionaryEvidenceCaptureClosureReEvaluatesEachCall() {
        // A reference-type counter (not a captured `var`) so the
        // `@Sendable` capture closure body only calls a method, avoiding
        // the "captured var in concurrently-executing code" restriction.
        let counter = EvidenceTestCounter()
        let evidence = TesseraDictionaryEvidence {
            ["n": "\(counter.increment())"]
        }
        XCTAssertEqual(evidence.snapshot(), ["n": "1"])
        XCTAssertEqual(evidence.snapshot(), ["n": "2"])
    }

    // MARK: - Round-trip identity (rule 2) for VerifierDecision-adjacent
    // Codable types used by this module.

    func testActionRiskEncodeDecodeIdentity() throws {
        for risk in TesseraActionRisk.allCases {
            let data = try JSONEncoder().encode(risk)
            let decoded = try JSONDecoder().decode(TesseraActionRisk.self, from: data)
            XCTAssertEqual(decoded, risk)
        }
    }

    func testActionRiskSeverityOrdering() {
        XCTAssertLessThan(TesseraActionRisk.low, .medium)
        XCTAssertLessThan(TesseraActionRisk.medium, .high)
        XCTAssertLessThan(TesseraActionRisk.high, .forbidden)
    }
}
