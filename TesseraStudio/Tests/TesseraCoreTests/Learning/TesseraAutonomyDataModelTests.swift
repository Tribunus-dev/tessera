import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Learning/TesseraAutonomyDataModel.swift
// doc comments (autonomy-calibration-design.md sections 4/5/9/10/11.9) --
// `irreversible` is "Frozen at first sight... Once true, never false"
// (a documentable invariant of the TYPE's usage even though the type
// itself is a plain mutable struct field -- the freeze is enforced by
// TesseraAutonomyService, covered lightly below via TesseraNoopAutonomyService's
// contract), the two ceilings, the three user choices, and
// `TesseraYoloSession.isExpired`.
final class TesseraAutonomyDataModelTests: DoctrineTestCase {

    // MARK: - Categorical sets (independent oracle, rule 7)

    func testUserChoiceHasTheThreeDocumentedCases() {
        XCTAssertEqual(Set(TesseraUserChoice.allCases.map(\.rawValue)), ["approved", "denied", "none"])
    }

    func testRecommendationChoiceHasTheThreeDocumentedCases() {
        XCTAssertEqual(Set(TesseraRecommendationChoice.allCases.map(\.rawValue)), ["confirm", "notNow", "never"])
    }

    func testAutonomyCeilingHasTheTwoDocumentedCases() {
        XCTAssertEqual(Set(AutonomyCeiling.allCases.map(\.rawValue)), ["containedLowRiskOnly", "anyNonIrreversible"])
    }

    // MARK: - TesseraPermissionConfig defaults (section 5/16)

    func testPermissionConfigDefaults() {
        let config = TesseraPermissionConfig()
        XCTAssertEqual(config.grantThresholdN, 5)
        XCTAssertEqual(config.sessionThresholdM, 3)
        XCTAssertEqual(config.floor, .standard)
        XCTAssertEqual(config.ceiling, .containedLowRiskOnly)
        XCTAssertEqual(config.pathGlobDepth, 1)
        XCTAssertEqual(config.yoloDefaultMinutes, 30)
        XCTAssertEqual(config.recommendationFloor, 3)
    }

    // MARK: - TesseraLearnedPermission.id mirrors actionClass

    func testLearnedPermissionIDEqualsActionClass() {
        let permission = TesseraLearnedPermission(actionClass: "bash:git", riskAtFirstSeen: .low)
        XCTAssertEqual(permission.id, "bash:git")
    }

    func testLearnedPermissionDefaults() {
        let permission = TesseraLearnedPermission(actionClass: "bash:git")
        XCTAssertFalse(permission.irreversible)
        XCTAssertEqual(permission.riskAtFirstSeen, .medium)
        XCTAssertEqual(permission.consecutiveApprovals, 0)
        XCTAssertEqual(permission.totalApprovals, 0)
        XCTAssertEqual(permission.totalDenials, 0)
        XCTAssertFalse(permission.granted)
        XCTAssertFalse(permission.revoked)
    }

    // MARK: - TesseraRecommendation.message is generated (not stored
    // separately; pin the exact composed sentence shape)

    func testRecommendationMessageMentionsActionClassAndCounts() {
        let recommendation = TesseraRecommendation(actionClass: "bash:git", consecutiveApprovals: 5, distinctSessions: 3)
        XCTAssertTrue(recommendation.message.contains("bash:git"))
        XCTAssertTrue(recommendation.message.contains("5"))
        XCTAssertTrue(recommendation.message.contains("3 sessions"))
    }

    func testRecommendationMessageUsesSingularSessionWording() {
        let recommendation = TesseraRecommendation(actionClass: "bash:git", consecutiveApprovals: 5, distinctSessions: 1)
        XCTAssertTrue(recommendation.message.contains("1 session"))
        XCTAssertFalse(recommendation.message.contains("1 sessions"))
    }

    func testRecommendationIDEqualsActionClass() {
        let recommendation = TesseraRecommendation(actionClass: "bash:git", consecutiveApprovals: 1, distinctSessions: 1)
        XCTAssertEqual(recommendation.id, "bash:git")
    }

    // MARK: - TesseraYoloSession.isExpired

    func testYoloSessionIsExpiredWhenExpiresAtIsInThePast() {
        let session = TesseraYoloSession(sessionID: "s1", expiresAt: Date(timeIntervalSinceNow: -10))
        XCTAssertTrue(session.isExpired)
    }

    func testYoloSessionIsNotExpiredWhenExpiresAtIsInTheFuture() {
        let session = TesseraYoloSession(sessionID: "s1", expiresAt: Date(timeIntervalSinceNow: 3600))
        XCTAssertFalse(session.isExpired)
    }

    func testYoloSessionDefaultsToZeroActionsAndEmptyReason() {
        let session = TesseraYoloSession(sessionID: "s1", expiresAt: Date())
        XCTAssertEqual(session.actionCount, 0)
        XCTAssertEqual(session.reason, "")
        XCTAssertNil(session.goal)
    }

    // MARK: - TesseraGateResolution

    func testGateResolutionCarriesCheckClassSourceAndOptionalConfidence() {
        let resolution = TesseraGateResolution(check: .autoApprove, actionClass: "bash:git", source: "ratchet", netConfidence: 0.9)
        XCTAssertEqual(resolution.check, .autoApprove)
        XCTAssertEqual(resolution.actionClass, "bash:git")
        XCTAssertEqual(resolution.source, "ratchet")
        XCTAssertEqual(resolution.netConfidence, 0.9)
    }

    func testGateResolutionNetConfidenceDefaultsToNil() {
        let resolution = TesseraGateResolution(check: .reject, actionClass: "x", source: "rule")
        XCTAssertNil(resolution.netConfidence)
    }

    // MARK: - Round-trip identity (rule 2)

    func testLearnedPermissionEncodeDecodeIdentity() throws {
        let permission = TesseraLearnedPermission(
            actionClass: "bash:git", irreversible: true, riskAtFirstSeen: .high,
            consecutiveApprovals: 4, distinctSessions: 2, totalApprovals: 6, totalDenials: 1,
            granted: true, grantedAt: Date(timeIntervalSince1970: 1000),
            revoked: false, lastSessionID: "sess-1", lastSeen: Date(timeIntervalSince1970: 2000)
        )
        let data = try JSONEncoder().encode(permission)
        let decoded = try JSONDecoder().decode(TesseraLearnedPermission.self, from: data)
        XCTAssertEqual(decoded, permission)
    }

    func testPermissionConfigEncodeDecodeIdentity() throws {
        let config = TesseraPermissionConfig(grantThresholdN: 7, ceiling: .anyNonIrreversible)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TesseraPermissionConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testYoloSessionEncodeDecodeIdentity() throws {
        let session = TesseraYoloSession(goal: "ship the feature", sessionID: "s1", expiresAt: Date(timeIntervalSince1970: 5000), reason: "batch refactor")
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TesseraYoloSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // MARK: - TesseraNoopAutonomyService: documented no-op defaults
    // (public API doc comment: "Default autonomy service. Real services
    // replace this at app launch.")

    func testNoopAutonomyServiceHasNoOpConfigAndState() {
        let service = TesseraNoopAutonomyService()
        XCTAssertEqual(service.activeSessionID, "")
        XCTAssertFalse(service.isNetWarm)
        XCTAssertEqual(service.entries(), [])
        XCTAssertEqual(service.recommendations(), [])
    }

    func testNoopAutonomyServiceResolvePassesTheBaseDecisionThrough() {
        let service = TesseraNoopAutonomyService()
        let resolution = service.resolve(base: .askUser, actionClass: "bash:git", risk: .medium, sandboxEnforceable: false, sessionID: "")
        XCTAssertEqual(resolution.check, .askUser, "the noop service must pass the base decision through unchanged")
        XCTAssertEqual(resolution.source, "rule")
    }

    func testNoopAutonomyServiceClassifyAndIsIrreversibleAreInert() {
        let service = TesseraNoopAutonomyService()
        XCTAssertEqual(service.classify(PendingAction(toolName: "bash", arguments: ["command": .string("rm x")])), "")
        XCTAssertFalse(service.isIrreversible("bash:rm", risk: .low))
    }

    func testNoopAutonomyServiceEndYoloAndActiveYoloAreNil() {
        let service = TesseraNoopAutonomyService()
        XCTAssertNil(service.activeYolo(for: nil))
        XCTAssertNil(service.endYolo())
    }

    func testNoopAutonomyServicePurgeReturnsZero() throws {
        XCTAssertEqual(try TesseraNoopAutonomyService().purgeTrainingData(), 0)
    }
}
