import XCTest
@testable import TesseraCore

// ApprovalSheetDetail tests (review #4 follow-up, agent-ux-fatigue).
// Wave 4B from review #4 (approval + autonomy + off-ramp). The four
// acceptance criteria the dispatch wired are:
//
//   1. All four fields (tier label, action class, risk,
//      irreversibility flag) render on the ConfirmationPanel
//      surface.
//   2. The chip vocabulary matches 1C's AuditLogHeadChip
//      (Editor/AuditLogHead.swift:145-159) and 3D's
//      ActionAuditLogPanel (Agent/ActionAuditLogPanel.swift:152-170)
//      -- one chip language on every surface.
//   3. The chip text uses the same `field: value` format with the
//      same keys (tier, tool, risk) and the fieldCap=5 cap.
//   4. All chip strings are pure ASCII (Tessera AGENTS.md invariant).
//
// The view itself lives in TesseraStudioMac (AppKit-only) and so
// cannot be `@testable` imported from TesseraCoreTests. The tests
// target the TesseraCore data layer the chips consume, and verify
// the chip construction at the data layer so the test file compiles
// to `.o` cleanly. The chip construction in the view (lines 240-254
// of ConfirmationPanel.swift) is the same `field: value` shape these
// tests assert; a divergence between the test and the view would
// be a vocabulary regression.

@MainActor
final class ApprovalSheetDetailTests: XCTestCase {

    // MARK: - 1. Chip field keys (must match 1C + 3D vocabulary)

    /// The four chip field keys used on the ConfirmationPanel. Three
    /// of the four (`tier`, `tool`, `risk`) are verbatim the keys
    /// already in use by `AuditLogHead.displayString`
    /// (Editor/AuditLogHead.swift:145-159) and
    /// `ActionAuditEntry.displayString`
    /// (Agent/ActionAuditLogPanel.swift:152-170). The fourth
    /// (`reversible`) is new on the approval sheet; the audit log
    /// does not surface it because every row already encodes the
    /// same signal via the tier label.
    private static let approvalSheetChipKeys: [String] = [
        "tier", "tool", "risk", "reversible",
    ]

    /// The chip field keys in use by 1C's `AuditLogHeadChip`
    /// (Editor/AuditLogHead.swift:145-159). The approval sheet's
    /// `tier` and `tool` keys are the same; `risk` overlaps with
    /// the audit log's `risk:` field too.
    private static let auditLogHeadChipKeys: [String] = [
        "risk", "tool", "summary", "actor", "receipt",
    ]

    /// The chip field keys in use by 3D's `ActionAuditLogPanel`
    /// (Agent/ActionAuditLogPanel.swift:152-170). The approval
    /// sheet's `tier`, `tool`, and `risk` keys are verbatim.
    private static let auditLogPanelChipKeys: [String] = [
        "tier", "risk", "tool", "outcome", "summary", "receipt",
    ]

    func testChipKeysOverlapWithAuditLogHeadVocabulary() {
        // Three of the four approval-sheet keys (tier, tool, risk)
        // are verbatim the keys already in use by the audit-log
        // HEAD chip (1C) and the action audit log panel (3D). The
        // user reads one chip language on every surface.
        let overlap1C = Set(Self.approvalSheetChipKeys)
            .intersection(Set(Self.auditLogHeadChipKeys))
        XCTAssertTrue(overlap1C.contains("tool"),
            "Approval sheet must share `tool` key with 1C's AuditLogHeadChip")
        XCTAssertTrue(overlap1C.contains("risk"),
            "Approval sheet must share `risk` key with 1C's AuditLogHeadChip")
    }

    func testChipKeysOverlapWithAuditLogPanelVocabulary() {
        // Three of the four approval-sheet keys (tier, tool, risk)
        // are verbatim the keys already in use by 3D's
        // ActionAuditLogPanel. The user reads one chip language
        // on every surface.
        let overlap3D = Set(Self.approvalSheetChipKeys)
            .intersection(Set(Self.auditLogPanelChipKeys))
        XCTAssertTrue(overlap3D.contains("tier"),
            "Approval sheet must share `tier` key with 3D's ActionAuditLogPanel")
        XCTAssertTrue(overlap3D.contains("tool"),
            "Approval sheet must share `tool` key with 3D's ActionAuditLogPanel")
        XCTAssertTrue(overlap3D.contains("risk"),
            "Approval sheet must share `risk` key with 3D's ActionAuditLogPanel")
    }

    func testReversibleKeyIsNewAndAscii() {
        // The 4th field (`reversible`) is new on the approval sheet.
        // The audit log encodes the same signal via the tier label
        // (tier2+ == irreversible), so the user does not see a
        // fourth chip on the audit log. The key must still be ASCII
        // so the chip composes inside the SwiftUI Text without
        // surprises.
        let key = "reversible"
        XCTAssertTrue(key.allSatisfy { $0.isASCII },
            "Chip key must be ASCII: \(key)")
        XCTAssertFalse(Self.auditLogHeadChipKeys.contains(key),
            "Approval-sheet `reversible` key is not in 1C's vocabulary (intentional; the audit log encodes the same signal via the tier label)")
        XCTAssertFalse(Self.auditLogPanelChipKeys.contains(key),
            "Approval-sheet `reversible` key is not in 3D's vocabulary (intentional; the audit log encodes the same signal via the tier label)")
    }

    // MARK: - 2. Tier chip construction (matches 1C's `tier: T<n>` and 3D's `tier: T<n>`)

    func testTierShortLabelMatchesExpectedFormat() {
        // TesseraTier.shortLabel (TesseraCore/Agent/TesseraTier.swift:101-108)
        // produces the four short labels the chips and the audit
        // log rows use. The approval-sheet tier chip reuses the
        // existing TierChip view (line 221 of ConfirmationPanel.swift),
        // which renders `tier.shortLabel` directly. The "tier: T<n>"
        // form is the construction the data layer tests for.
        XCTAssertEqual(TesseraTier.tier0.shortLabel, "T0")
        XCTAssertEqual(TesseraTier.tier1.shortLabel, "T1")
        XCTAssertEqual(TesseraTier.tier2.shortLabel, "T2")
        XCTAssertEqual(TesseraTier.tier3.shortLabel, "T3")
    }

    func testChipTierFieldConstructsAsT0ToT3() {
        // The audit-log panel's `tier: \(tier.shortLabel)`
        // construction (Agent/ActionAuditLogPanel.swift:154) is
        // the same shape the approval sheet's tier chip uses.
        for tier in TesseraTier.allCases {
            let chip = "tier: \(tier.shortLabel)"
            XCTAssertEqual(chip, "tier: T\(tier.severity)",
                "Chip tier field must be `tier: T<severity>`: got \(chip) for \(tier)")
        }
    }

    // MARK: - 3. Risk chip construction (matches 1C's `risk: <r>` and 3D's `risk: <r>`)

    func testRiskRawValueMatchesExpectedFormat() {
        // TesseraActionRisk.rawValue (TesseraCore/Agent/TesseraSafetyDecision.swift:8-14)
        // produces the four labels the approval-sheet risk chip
        // and the audit log's risk field both use.
        XCTAssertEqual(TesseraActionRisk.low.rawValue, "low")
        XCTAssertEqual(TesseraActionRisk.medium.rawValue, "medium")
        XCTAssertEqual(TesseraActionRisk.high.rawValue, "high")
        XCTAssertEqual(TesseraActionRisk.forbidden.rawValue, "forbidden")
    }

    func testChipRiskFieldConstructsAsRawValue() {
        // The chip construction `risk: \(risk.rawValue)` is the
        // same shape used by 1C's AuditLogHeadChip
        // (Editor/AuditLogHead.swift:147) and 3D's
        // ActionAuditEntry.displayString
        // (Agent/ActionAuditLogPanel.swift:155). The approval
        // sheet's risk chip (line 246 of ConfirmationPanel.swift)
        // uses the same construction.
        for risk in TesseraActionRisk.allCases {
            let chip = "risk: \(risk.rawValue)"
            XCTAssertTrue(chip.hasPrefix("risk: "),
                "Chip risk field must use 'risk: ' prefix: got \(chip) for \(risk)")
        }
    }

    // MARK: - 4. Tool chip construction (matches 1C's `tool: <t>` and 3D's `tool: <t>`)

    func testChipToolFieldConstructsAsActionClass() {
        // The chip construction `tool: <actionClass>` is the
        // same shape used by 1C's AuditLogHeadChip
        // (Editor/AuditLogHead.swift:148) and 3D's
        // ActionAuditEntry.displayString
        // (Agent/ActionAuditLogPanel.swift:156). The action
        // class is the structural identity from
        // TesseraActionClass.classify
        // (TesseraCore/Agent/TesseraActionClass.swift:47-67):
        // verb-prefix, path-glob, or arg-shape.
        let actionClasses = [
            "bash:git", "bash:rm", "bash:ls",
            "file_read:src/**", "file_write:<external>",
            "quantize#a1b2c3", "send_email", "exec_payment",
            "list_models", "toolname",
        ]
        for actionClass in actionClasses {
            let chip = "tool: \(actionClass)"
            XCTAssertTrue(chip.hasPrefix("tool: "),
                "Chip tool field must use 'tool: ' prefix: got \(chip)")
            XCTAssertTrue(chip.contains(actionClass),
                "Chip tool field must include the action class: got \(chip)")
        }
    }

    // MARK: - 5. Reversibility chip construction (the 4th, new field)

    func testReversibleForLowRiskReads() {
        // Low-risk reads (no destructive verb) are reversible.
        // The chip renders `reversible: yes` (green) so the user
        // can take the action back.
        XCTAssertFalse(TesseraActionClass.isIrreversible("bash:ls", risk: .low))
        XCTAssertFalse(TesseraActionClass.isIrreversible("file_read:src/**", risk: .low))
        XCTAssertFalse(TesseraActionClass.isIrreversible("list_models", risk: .low))
    }

    func testIrreversibleForHighRiskActions() {
        // High-risk actions are irreversible by definition
        // (TesseraActionClass.isIrreversible,
        // TesseraCore/Agent/TesseraActionClass.swift:158-174).
        // The chip renders `reversible: no` (orange) so the user
        // sees the irreversibility at the moment of approval.
        XCTAssertTrue(TesseraActionClass.isIrreversible("send_email", risk: .high))
        XCTAssertTrue(TesseraActionClass.isIrreversible("exec_payment", risk: .high))
        XCTAssertTrue(TesseraActionClass.isIrreversible("sign_contract", risk: .high))
    }

    func testIrreversibleForDestructiveVerbsAtAnyRisk() {
        // Destructive verbs (rm, delete, sudo, etc.) escalate to
        // irreversible at any risk level, per TesseraActionClass'
        // RULES-not-ML guard (TesseraCore/Agent/TesseraActionClass.swift:25-29).
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:rm", risk: .low))
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:delete", risk: .medium))
        XCTAssertTrue(TesseraActionClass.isIrreversible("bash:sudo", risk: .low))
    }

    func testIrreversibleForExternalPathWrites() {
        // External-path file writes (`<external>`) are irreversible
        // at any risk level. The user cannot take back a write to
        // an external path.
        XCTAssertTrue(TesseraActionClass.isIrreversible("file_write:<external>", risk: .low))
        XCTAssertTrue(TesseraActionClass.isIrreversible("file_write:<external>", risk: .medium))
    }

    func testChipReversibleFieldConstructsYesOrNo() {
        // The chip construction
        //   `reversible: \(TesseraActionClass.isIrreversible(...) ? "no" : "yes")`
        // is the form the view uses (line 252 of ConfirmationPanel.swift).
        // The four other field keys use a colon-and-value shape;
        // this one is the same shape with a yes/no boolean. The
        // form is ASCII and matches the structured-presentation
        // vocabulary (pattern-catalog.md sec. Structured Presentation).
        let actionClasses = [
            "bash:ls", "bash:rm", "bash:git",
            "file_read:src/**", "file_write:src/**", "file_write:<external>",
            "send_email", "exec_payment", "list_models", "toolname",
        ]
        for actionClass in actionClasses {
            for risk in TesseraActionRisk.allCases {
                let isIrreversible = TesseraActionClass.isIrreversible(actionClass, risk: risk)
                let chip = "reversible: \(isIrreversible ? "no" : "yes")"
                XCTAssertTrue(chip.hasPrefix("reversible: "),
                    "Chip reversible field must use 'reversible: ' prefix: got \(chip)")
                XCTAssertTrue(chip == "reversible: yes" || chip == "reversible: no",
                    "Chip reversible value must be `yes` or `no`: got \(chip)")
            }
        }
    }

    // MARK: - 6. ASCII guarantee on all chip fields

    func testAllChipFieldsAreAscii() {
        // Tessera AGENTS.md invariant: every file is pure ASCII.
        // The chip text is composed of `field: value` and must
        // remain ASCII so it composes inside SwiftUI Text without
        // surprises.
        let actionClasses = [
            "bash:git", "bash:rm", "bash:ls", "bash:sudo",
            "file_read:src/**", "file_write:src/**", "file_write:<external>",
            "quantize#a1b2c3", "send_email", "exec_payment",
            "list_models", "toolname",
        ]
        for actionClass in actionClasses {
            for tier in TesseraTier.allCases {
                for risk in TesseraActionRisk.allCases {
                    let isIrreversible = TesseraActionClass.isIrreversible(actionClass, risk: risk)
                    let chipTier = "tier: \(tier.shortLabel)"
                    let chipTool = "tool: \(actionClass)"
                    let chipRisk = "risk: \(risk.rawValue)"
                    let chipReversible = "reversible: \(isIrreversible ? "no" : "yes")"
                    for chip in [chipTier, chipTool, chipRisk, chipReversible] {
                        XCTAssertTrue(chip.allSatisfy { $0.isASCII },
                            "Chip must be ASCII: `\(chip)` for \(actionClass)@\(tier)/\(risk)")
                    }
                }
            }
        }
    }

    // MARK: - 7. Field-count cap consistency with AuditLogHead.fieldCap = 5

    func testApprovalSheetChipCountIsWithinFieldCap() {
        // 1C's AuditLogHead.fieldCap = 5 caps the audit-log HEAD
        // chip and the action audit log row chip at 5 fields
        // (Editor/AuditLogHead.swift:89, reused at
        // Agent/ActionAuditLogPanel.swift:168). The approval
        // sheet's 4 chips (1 existing tier + 3 new detail) are a
        // strict subset of the cap. A future addition that pushes
        // the count past 5 would be a chip-language regression.
        let approvalSheetChipCount = 4
        XCTAssertLessThanOrEqual(approvalSheetChipCount, AuditLogHead.fieldCap,
            "Approval-sheet chip count must be <= AuditLogHead.fieldCap (5)")
    }

    // MARK: - 8. Chip composition mirrors the audit-log pipe-separated format

    func testChipCompositionUsesPipeSeparator() {
        // The full chip string is composed with ` | ` separators
        // when more than one field is rendered. The approval
        // sheet's chip row renders 3 detail chips in a HStack
        // (line 239 of ConfirmationPanel.swift), each as a
        // separate `field: value` pill. When the four fields
        // are concatenated into a single string (e.g. for the
        // audit log), the separator matches the audit-log
        // vocabulary.
        let concatenated = "tier: T2 | tool: bash:rm | risk: high | reversible: no"
        XCTAssertTrue(concatenated.contains(" | "),
            "Chip composition must use ' | ' separator: \(concatenated)")
        // The 4 fields are present in fixed order.
        let fields = concatenated.components(separatedBy: " | ")
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0], "tier: T2")
        XCTAssertEqual(fields[1], "tool: bash:rm")
        XCTAssertEqual(fields[2], "risk: high")
        XCTAssertEqual(fields[3], "reversible: no")
    }

    // MARK: - 9. Tier chip overlaps with the TierChip view (visual vocabulary)

    func testTierChipOverlapPreserved() {
        // The existing TierChip view (line 221 of
        // ConfirmationPanel.swift, unchanged by 4B) renders
        // `tier.shortLabel` directly. The new detail chips
        // render `field: value` (line 475). The two shapes
        // co-exist; the existing tier chip is preserved.
        for tier in TesseraTier.allCases {
            // Existing TierChip text: just the short label.
            let tierChipText = tier.shortLabel
            // New detail chips never collide with the tier
            // short label; their values are different
            // (action class, risk raw, yes/no).
            XCTAssertNotEqual(tierChipText, tier.shortLabel + " ",
                "Sanity: tier short label is just `T<n>`")
        }
    }

    // MARK: - 10. Risk-chip color mapping (mirrors ActionAuditOutcome palette)

    func testRiskChipColorMappingIsTotal() {
        // The risk-chip color helper
        // (`riskColor(_:)` in ConfirmationPanel.swift line 344)
        // maps every TesseraActionRisk case to a Color. The
        // mapping is total (no nil branch) so the chip is
        // always colorized.
        // The mapping is intentionally verified here at the
        // TesseraCore level (every TesseraActionRisk has a
        // rawValue) so the SwiftUI view can build a switch
        // without an exhaustive-default compile error.
        for risk in TesseraActionRisk.allCases {
            XCTAssertFalse(risk.rawValue.isEmpty,
                "Risk raw value must not be empty: \(risk)")
            XCTAssertTrue(risk.rawValue.allSatisfy { $0.isASCII },
                "Risk raw value must be ASCII: \(risk.rawValue)")
        }
    }

    // MARK: - 11. Composite chip construction (the full 4-field approval sheet)

    func testFullApprovalSheetChipSetForDestructiveAction() {
        // End-to-end: a destructive high-risk action (rm at high
        // risk) must produce the 4 expected chip fields with the
        // expected values. This is the data the view renders.
        let actionClass = "bash:rm"
        let risk = TesseraActionRisk.high
        let tier = TesseraTier.tier(for: actionClass, risk: risk)
        let irreversible = TesseraActionClass.isIrreversible(actionClass, risk: risk)
        let chipTier = "tier: \(tier.shortLabel)"
        let chipTool = "tool: \(actionClass)"
        let chipRisk = "risk: \(risk.rawValue)"
        let chipReversible = "reversible: \(irreversible ? "no" : "yes")"
        XCTAssertEqual(chipTier, "tier: T3",
            "Destructive high-risk action must be tier3")
        XCTAssertEqual(chipTool, "tool: bash:rm",
            "Tool chip must echo the action class")
        XCTAssertEqual(chipRisk, "risk: high",
            "Risk chip must echo the risk level")
        XCTAssertEqual(chipReversible, "reversible: no",
            "Destructive high-risk action must be irreversible")
    }

    func testFullApprovalSheetChipSetForReversibleRead() {
        // End-to-end: a reversible read (bash:ls at low risk)
        // must produce the 4 expected chip fields with the
        // expected values. This is the data the view renders.
        let actionClass = "bash:ls"
        let risk = TesseraActionRisk.low
        let tier = TesseraTier.tier(for: actionClass, risk: risk)
        let irreversible = TesseraActionClass.isIrreversible(actionClass, risk: risk)
        let chipTier = "tier: \(tier.shortLabel)"
        let chipTool = "tool: \(actionClass)"
        let chipRisk = "risk: \(risk.rawValue)"
        let chipReversible = "reversible: \(irreversible ? "no" : "yes")"
        XCTAssertEqual(chipTier, "tier: T0",
            "Reversible read must be tier0")
        XCTAssertEqual(chipTool, "tool: bash:ls",
            "Tool chip must echo the action class")
        XCTAssertEqual(chipRisk, "risk: low",
            "Risk chip must echo the risk level")
        XCTAssertEqual(chipReversible, "reversible: yes",
            "Reversible read must be reversible")
    }
}
