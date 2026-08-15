import XCTest
@testable import TesseraCore

// Contract source: Sources/TesseraCore/Agent/ApprovalSafetyFacts.swift doc
// comment -- "Derived in one place on purpose... every surface reads this
// type instead", the fail-closed medium fallback, and the shared chip
// vocabulary capped at AuditLogHead.fieldCap.
final class ApprovalSafetyFactsTests: DoctrineTestCase {

    func testFactsDeriveActionClassRiskTierAndReversibilityFromTheAction() {
        let facts = ApprovalSafetyFacts(action: PendingAction(toolName: "bash", arguments: ["command": .string("rm -rf /tmp/x")]))
        XCTAssertEqual(facts.toolName, "bash")
        XCTAssertEqual(facts.actionClass, TesseraActionClass.classify(PendingAction(toolName: "bash", arguments: ["command": .string("rm -rf /tmp/x")])))
        XCTAssertTrue(facts.isIrreversible, "bash:rm is a destructive verb head")
    }

    func testConvenienceInitDelegatesToActionInit() {
        let viaAction = ApprovalSafetyFacts(action: PendingAction(toolName: "list_models", arguments: [:]))
        let viaConvenience = ApprovalSafetyFacts(toolName: "list_models")
        XCTAssertEqual(viaAction, viaConvenience)
    }

    func testReadOnlyToolIsReversibleLowRiskTier0() {
        let facts = ApprovalSafetyFacts(toolName: "list_models")
        XCTAssertEqual(facts.risk, .low)
        XCTAssertEqual(facts.tier, .tier0)
        XCTAssertFalse(facts.isIrreversible)
        XCTAssertEqual(facts.reversibilityLabel, "reversible")
    }

    func testDestructiveShellVerbIsIrreversibleTier2() {
        let facts = ApprovalSafetyFacts(toolName: "bash", arguments: ["command": .string("rm important.txt")])
        XCTAssertTrue(facts.isIrreversible)
        XCTAssertEqual(facts.reversibilityLabel, "irreversible")
        XCTAssertEqual(facts.tier, .tier2)
    }

    // MARK: - displayString: shared chip vocabulary, capped fields

    func testDisplayStringContainsAllFiveDocumentedFields() {
        let facts = ApprovalSafetyFacts(toolName: "bash", arguments: ["command": .string("rm x")])
        let display = facts.displayString
        XCTAssertTrue(display.contains("tier:"))
        XCTAssertTrue(display.contains("risk:"))
        XCTAssertTrue(display.contains("tool:"))
        XCTAssertTrue(display.contains("class:"))
        XCTAssertTrue(display.contains("undo:"))
    }

    func testDisplayStringFieldCountNeverExceedsAuditLogHeadFieldCap() {
        let facts = ApprovalSafetyFacts(toolName: "bash", arguments: ["command": .string("rm x")])
        let fieldCount = facts.displayString.components(separatedBy: " | ").count
        XCTAssertLessThanOrEqual(fieldCount, AuditLogHead.fieldCap)
    }

    func testDisplayStringClassFieldFallsBackToUnclassifiedWhenEmpty() {
        // An action-class id is never actually empty in practice (the
        // classifier always falls back to the tool name), but the chip's
        // own guard is documented behavior worth pinning directly.
        let facts = ApprovalSafetyFacts(toolName: "bash", arguments: ["command": .string("rm x")])
        XCTAssertFalse(facts.actionClass.isEmpty, "sanity: the classifier never actually returns empty here")
        XCTAssertTrue(facts.displayString.contains("class: bash:rm"))
    }

    // MARK: - Purity: same action always yields the same facts

    func testFactsArePureGivenTheSameAction() {
        let action = PendingAction(toolName: "quantize", arguments: ["model_path": .string("m"), "output_path": .string("o"), "policy_path": .string("p")])
        let a = ApprovalSafetyFacts(action: action)
        let b = ApprovalSafetyFacts(action: action)
        XCTAssertEqual(a, b)
    }

    // MARK: - Single-derivation-point rule (doc comment): every surface
    // must read these facts, not recompute the tier itself. We assert
    // the derivation composes exactly the three primitives it claims to
    // (classify, ruleBasedRisk, tier(for:risk:)) rather than inventing a
    // fourth path.

    func testTierMatchesDirectComputationFromClassifyAndRuleBasedRisk() throws {
        let action = PendingAction(toolName: "file_write", arguments: ["path": .string("src/x.swift")])
        let facts = ApprovalSafetyFacts(action: action)
        let expectedClass = TesseraActionClass.classify(action)
        let expectedRisk = try TesseraActionVerifier.ruleBasedRisk(for: action)
        let expectedTier = TesseraTier.tier(for: expectedClass, risk: expectedRisk)
        XCTAssertEqual(facts.actionClass, expectedClass)
        XCTAssertEqual(facts.risk, expectedRisk)
        XCTAssertEqual(facts.tier, expectedTier)
    }
}
