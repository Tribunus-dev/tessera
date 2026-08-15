import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/TesseraSafetyDecision.swift
// doc comments -- "Fail-safe rule: auto-approve low-risk read-only
// actions by default... unless the tool's own policy is .prompt. Mutations
// and ambiguous actions ask the user; forbidden actions and disabled
// tools are rejected outright."
final class TesseraSafetyDecisionTests: DoctrineTestCase {

    private func decision(
        policy: ApprovalLevel = .auto,
        profile: TesseraPermissionProfile = .standard,
        sandboxEnforceable: Bool = false,
        risk: TesseraActionRisk = .low
    ) -> TesseraSafetyDecision {
        TesseraSafetyDecision(
            approvalPolicy: policy,
            permissionProfile: profile,
            sandboxEnforceable: sandboxEnforceable,
            actionRisk: risk
        )
    }

    // MARK: - Forbidden / denied always reject, regardless of everything else

    func testForbiddenRiskAlwaysRejectsEvenWithAutoPolicy() {
        XCTAssertEqual(decision(policy: .auto, risk: .forbidden).check, .reject)
    }

    func testDeniedPolicyAlwaysRejectsEvenAtLowRisk() {
        XCTAssertEqual(decision(policy: .denied, risk: .low).check, .reject)
    }

    func testForbiddenBeatsDeniedBothReject() {
        XCTAssertEqual(decision(policy: .denied, risk: .forbidden).check, .reject)
    }

    // MARK: - Explicit prompt policy always asks, even at low risk

    func testPromptPolicyAlwaysAsksEvenAtLowRisk() {
        XCTAssertEqual(decision(policy: .prompt, risk: .low).check, .askUser)
    }

    // MARK: - Restricted profile never auto-approves

    func testRestrictedProfileAsksEvenAtLowRiskWithAutoPolicy() {
        XCTAssertEqual(decision(policy: .auto, profile: .restricted, risk: .low).check, .askUser)
    }

    // MARK: - Low-risk auto-approves by default (the productivity-app
    // fail-safe rule)

    func testLowRiskAutoApprovesWithStandardProfileAndAutoPolicy() {
        XCTAssertEqual(decision(policy: .auto, profile: .standard, risk: .low).check, .autoApprove)
    }

    func testLowRiskAutoApprovesRegardlessOfSandboxEnforceability() {
        XCTAssertEqual(decision(policy: .auto, sandboxEnforceable: true, risk: .low).check, .autoApprove)
        XCTAssertEqual(decision(policy: .auto, sandboxEnforceable: false, risk: .low).check, .autoApprove)
    }

    func testElevatedProfileBehavesLikeStandardForLowRisk() {
        XCTAssertEqual(decision(policy: .auto, profile: .elevated, risk: .low).check, .autoApprove)
    }

    // MARK: - Medium/high risk asks the user (not forbidden, not low)

    func testMediumRiskAsksUser() {
        XCTAssertEqual(decision(policy: .auto, risk: .medium).check, .askUser)
    }

    func testHighRiskAsksUser() {
        // High risk is not .forbidden, so it falls through to askUser
        // rather than reject (forbidden is the only outright-reject risk).
        XCTAssertEqual(decision(policy: .auto, risk: .high).check, .askUser)
    }

    func testNotifyPolicyAtMediumRiskStillAsksUser() {
        XCTAssertEqual(decision(policy: .notify, risk: .medium).check, .askUser)
    }

    // MARK: - tier(forActionClass:) / riskOnlyTier delegate to TesseraTier
    // (AGENTS.md: "delegate to TesseraTier so the tier policy has one
    // auditable surface")

    func testTierForActionClassDelegatesToTesseraTier() {
        let d = decision(risk: .medium)
        XCTAssertEqual(d.tier(forActionClass: "file_write:src/**"), TesseraTier.tier(for: "file_write:src/**", risk: .medium))
    }

    func testRiskOnlyTierDelegatesToTesseraTier() {
        let d = decision(risk: .high)
        XCTAssertEqual(d.riskOnlyTier, TesseraTier.tier(forRisk: .high))
    }

    // MARK: - Equatable value semantics

    func testEqualInputsProduceEqualDecisions() {
        let a = decision(policy: .auto, profile: .standard, sandboxEnforceable: true, risk: .medium)
        let b = decision(policy: .auto, profile: .standard, sandboxEnforceable: true, risk: .medium)
        XCTAssertEqual(a, b)
    }

    func testDifferentRiskProducesUnequalDecisions() {
        let a = decision(risk: .low)
        let b = decision(risk: .medium)
        XCTAssertNotEqual(a, b)
    }
}
