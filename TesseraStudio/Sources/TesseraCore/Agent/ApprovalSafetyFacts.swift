import Foundation

// MARK: - Approval safety facts

/// The structural facts about one pending action: what class it is, how
/// risky, which tier, and whether it can be undone. Pure - the same
/// action always yields the same facts.
///
/// Derived in one place on purpose. The approval sheet, the chat
/// progress feed, and the audit log all label the same gate; if each
/// recomputed the tier the user could read two different answers for
/// one action. Every surface reads this type instead.
public struct ApprovalSafetyFacts: Sendable, Equatable {
    public let toolName: String
    public let actionClass: String
    public let risk: TesseraActionRisk
    public let tier: TesseraTier
    public let isIrreversible: Bool

    /// Risk falls back to `.medium` when the rule-based verifier cannot
    /// classify the action: fail-closed, per the `TesseraActionVerifier`
    /// contract. medium maps to tier1, or tier2 with a destructive verb.
    public init(action: PendingAction) {
        let actionClass = TesseraActionClass.classify(action)
        let risk = (try? TesseraActionVerifier.ruleBasedRisk(for: action)) ?? .medium
        self.toolName = action.toolName
        self.actionClass = actionClass
        self.risk = risk
        self.tier = TesseraTier.tier(for: actionClass, risk: risk)
        self.isIrreversible = TesseraActionClass.isIrreversible(actionClass, risk: risk)
    }

    public init(toolName: String, arguments: [String: JSONValue] = [:]) {
        self.init(action: PendingAction(toolName: toolName, arguments: arguments))
    }

    /// Reversibility label for the chip. ASCII only.
    public var reversibilityLabel: String {
        isIrreversible ? "irreversible" : "reversible"
    }

    /// The shared `field: value | field: value` chip vocabulary from
    /// ``AuditLogHead/displayString``. Capped at ``AuditLogHead/fieldCap``
    /// fields so the approval surface reads as the same language as the
    /// diff overlay and the audit log.
    public var displayString: String {
        [
            "tier: \(tier.shortLabel)",
            "risk: \(risk.rawValue)",
            "tool: \(toolName)",
            "class: \(actionClass.isEmpty ? "unclassified" : actionClass)",
            "undo: \(reversibilityLabel)",
        ]
        .prefix(AuditLogHead.fieldCap)
        .joined(separator: " | ")
    }
}
