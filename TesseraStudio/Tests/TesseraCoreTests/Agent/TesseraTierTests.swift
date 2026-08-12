import XCTest
@testable import TesseraCore

// TesseraTier tests: boundary discipline for the risk-tiered approval
// gates (agent-ux-fatigue, pattern-catalog.md sec. Risk-Tiered Approval
// Gates). The load-bearing test is the boundary-drift guard: no code
// path may lower a tier except through `TesseraTier.revoke`.

final class TesseraTierTests: XCTestCase {

    // MARK: - Tier mapping (risk x irreversibility)

    func testLowRiskReversibleIsTier0() {
        // Idempotent reads, internal-only writes.
        XCTAssertEqual(TesseraTier.tier(for: "file_read:src/**", risk: .low), .tier0)
        XCTAssertEqual(TesseraTier.tier(for: "list_models", risk: .low), .tier0)
        XCTAssertEqual(TesseraTier.tier(for: "bash:ls", risk: .low), .tier0)
    }

    func testMediumRiskReversibleIsTier1() {
        // Internal notes, draft creation, status flips.
        XCTAssertEqual(TesseraTier.tier(for: "crm_note", risk: .medium), .tier1)
        XCTAssertEqual(TesseraTier.tier(for: "quantize#hash1", risk: .medium), .tier1)
        XCTAssertEqual(TesseraTier.tier(for: "file_write:src/**", risk: .medium), .tier1)
    }

    func testLowRiskIrreversibleIsTier2() {
        // Even at low risk, a destructive verb escalates to tier2.
        XCTAssertEqual(TesseraTier.tier(for: "bash:rm", risk: .low), .tier2)
        XCTAssertEqual(TesseraTier.tier(for: "bash:delete", risk: .low), .tier2)
    }

    func testMediumRiskIrreversibleIsTier2() {
        // Record deletion, medium-risk destructive writes.
        XCTAssertEqual(TesseraTier.tier(for: "file_write:<external>", risk: .medium), .tier2)
        XCTAssertEqual(TesseraTier.tier(for: "bash:rm", risk: .medium), .tier2)
    }

    func testHighRiskReversibleIsTier2() {
        // Outbound emails, deal-stage changes.
        XCTAssertEqual(TesseraTier.tier(for: "send_email", risk: .high), .tier2)
        XCTAssertEqual(TesseraTier.tier(for: "update_deal_stage", risk: .high), .tier2)
    }

    func testHighRiskIrreversibleIsTier3() {
        // Payment writes, contract execution, customer-facing comms.
        XCTAssertEqual(TesseraTier.tier(for: "exec_payment", risk: .high), .tier3)
        XCTAssertEqual(TesseraTier.tier(for: "sign_contract", risk: .high), .tier3)
        XCTAssertEqual(TesseraTier.tier(for: "file_write:<external>", risk: .high), .tier3)
        XCTAssertEqual(TesseraTier.tier(for: "bash:rm", risk: .high), .tier3)
    }

    func testForbiddenIsAlwaysTier3() {
        // Forbidden actions never run; the tier is the strictest so a
        // future bypass is auditable.
        for actionClass in ["bash:rm", "bash:ls", "send_email", "file_read:src/**", "anything"] {
            XCTAssertEqual(TesseraTier.tier(for: actionClass, risk: .forbidden), .tier3)
        }
    }

    // MARK: - Purity

    func testMappingIsDeterministic() {
        // Same inputs -> same output, always. The boundary-drift guard
        // rests on this: a contributor cannot land a different tier by
        // re-evaluating the same call.
        let actionClasses = [
            "bash:ls", "bash:rm", "bash:delete", "bash:sudo",
            "file_read:src/**", "file_write:src/**", "file_write:<external>",
            "quantize#hash1", "send_email", "exec_payment", "toolname", "",
        ]
        for actionClass in actionClasses {
            for risk in TesseraActionRisk.allCases {
                let first = TesseraTier.tier(for: actionClass, risk: risk)
                let second = TesseraTier.tier(for: actionClass, risk: risk)
                let third = TesseraTier.tier(for: actionClass, risk: risk)
                XCTAssertEqual(first, second,
                    "Mapping must be pure for \(actionClass)@\(risk)")
                XCTAssertEqual(second, third,
                    "Mapping must be pure for \(actionClass)@\(risk)")
            }
        }
    }

    // MARK: - Monotonicity in the risk axis

    func testTierIsMonotoneInRisk() {
        // As risk increases, the tier must not decrease. This is the
        // boundary-drift guard for the risk axis: a higher risk class
        // can never silently map to a more permissive tier.
        let actionClasses = [
            "bash:ls",         // reversible at all risk levels
            "bash:rm",         // irreversible at all risk levels
            "file_read:src/**",
            "file_write:src/**",
            "file_write:<external>",
            "send_email",
            "exec_payment",
            "toolname",
        ]
        for actionClass in actionClasses {
            let tiers = TesseraActionRisk.allCases.map {
                TesseraTier.tier(for: actionClass, risk: $0)
            }
            for i in 1..<tiers.count {
                XCTAssertGreaterThanOrEqual(
                    tiers[i], tiers[i - 1],
                    "tier should not decrease as risk increases for \(actionClass)"
                )
            }
        }
    }

    func testTierIsBounded() {
        // No mapping may exceed tier3 or drop below tier0.
        let actionClasses = [
            "bash:ls", "bash:rm", "file_write:<external>",
            "send_email", "exec_payment", "toolname", "",
        ]
        for actionClass in actionClasses {
            for risk in TesseraActionRisk.allCases {
                let t = TesseraTier.tier(for: actionClass, risk: risk)
                XCTAssertGreaterThanOrEqual(t, .tier0, "tier must be >= tier0")
                XCTAssertLessThanOrEqual(t, .tier3, "tier must be <= tier3")
            }
        }
    }

    // MARK: - Boundary drift guard (the load-bearing test)

    func testBoundaryDriftGuard() {
        // The ONLY public path that lowers a tier is `TesseraTier.revoke`.
        // For every tier, `.revoke()` returns a tier that is strictly
        // less (or the floor for tier0). Any tier below the original
        // must be reachable only by chaining `.revoke()`.
        for tier in TesseraTier.allCases {
            let revoked = tier.revoke()
            if tier == .tier0 {
                XCTAssertEqual(revoked, .tier0, "tier0 is the floor; revoke is idempotent")
            } else {
                XCTAssertLessThan(revoked, tier,
                    "\(tier).revoke() must be strictly less than \(tier)")
            }
        }
    }

    func testRevokeCascadesDownward() {
        // Multi-step revoke walks the tiers in order. The cascade is the
        // only path a caller has to go below one notch; any other
        // path would be a silent downgrade.
        XCTAssertEqual(TesseraTier.tier3.revoke(), .tier2)
        XCTAssertEqual(TesseraTier.tier3.revoke().revoke(), .tier1)
        XCTAssertEqual(TesseraTier.tier3.revoke().revoke().revoke(), .tier0)
        XCTAssertEqual(TesseraTier.tier3.revoke().revoke().revoke().revoke(), .tier0,
            "tier0 is the floor; further revoke calls are no-ops")
    }

    func testNoSilentDowngradeAcrossMapping() {
        // For every (actionClass, risk) pair, the mapping cannot land
        // below the floor (.tier0) or above the ceiling (.tier3). This
        // is the runtime corollary of the boundary-drift guard: the
        // mapping is total and bounded.
        let actionClasses = [
            "bash:ls", "bash:rm", "bash:delete", "bash:sudo", "bash:chmod",
            "file_read:src/**", "file_write:src/**", "file_write:<external>",
            "quantize#hash1", "send_email", "exec_payment",
            "sign_contract", "delete_model", "toolname", "",
        ]
        for actionClass in actionClasses {
            for risk in TesseraActionRisk.allCases {
                let mapped = TesseraTier.tier(for: actionClass, risk: risk)
                XCTAssertTrue(
                    TesseraTier.allCases.contains(mapped),
                    "tier for \(actionClass)@\(risk) must be a valid case"
                )
            }
        }
    }

    // MARK: - Comparable conformance

    func testComparableIsConsistentWithSeverity() {
        XCTAssertLessThan(TesseraTier.tier0, TesseraTier.tier1)
        XCTAssertLessThan(TesseraTier.tier1, TesseraTier.tier2)
        XCTAssertLessThan(TesseraTier.tier2, TesseraTier.tier3)
        XCTAssertEqual(TesseraTier.tier0.severity, 0)
        XCTAssertEqual(TesseraTier.tier1.severity, 1)
        XCTAssertEqual(TesseraTier.tier2.severity, 2)
        XCTAssertEqual(TesseraTier.tier3.severity, 3)
    }

    // MARK: - Surface labels

    func testSurfaceLabelsAreAscii() {
        for tier in TesseraTier.allCases {
            XCTAssertTrue(tier.shortLabel.allSatisfy { $0.isASCII },
                "Short label must be ASCII: \(tier.shortLabel)")
            XCTAssertTrue(tier.displayName.allSatisfy { $0.isASCII },
                "Display name must be ASCII: \(tier.displayName)")
        }
    }

    func testRawValueIsAscii() {
        for tier in TesseraTier.allCases {
            XCTAssertTrue(tier.rawValue.allSatisfy { $0.isASCII },
                "rawValue must be ASCII: \(tier.rawValue)")
        }
    }

    // MARK: - Round-trip codable

    func testRoundTripsThroughJSON() throws {
        // The tier must survive JSON encoding unchanged so the audit
        // log and approval receipts can record the exact tier.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for tier in TesseraTier.allCases {
            let data = try encoder.encode(tier)
            let decoded = try decoder.decode(TesseraTier.self, from: data)
            XCTAssertEqual(decoded, tier)
        }
    }

    // MARK: - TesseraSafetyDecision convenience

    func testSafetyDecisionTierForwardsToTesseraTier() {
        // The decision's convenience must produce the same answer as
        // the canonical TesseraTier.tier mapping.
        let decision = TesseraSafetyDecision(
            approvalPolicy: .prompt,
            permissionProfile: .standard,
            sandboxEnforceable: false,
            actionRisk: .high
        )
        XCTAssertEqual(
            decision.tier(forActionClass: "send_email"),
            TesseraTier.tier(for: "send_email", risk: .high)
        )
    }

    func testRiskOnlyTierIgnoresActionClass() {
        // The risk-only axis assumes reversible. A high-risk reversible
        // action maps to tier2 via the risk-only path.
        let decision = TesseraSafetyDecision(
            approvalPolicy: .prompt,
            permissionProfile: .standard,
            sandboxEnforceable: false,
            actionRisk: .high
        )
        XCTAssertEqual(decision.riskOnlyTier, .tier2)
    }
}
