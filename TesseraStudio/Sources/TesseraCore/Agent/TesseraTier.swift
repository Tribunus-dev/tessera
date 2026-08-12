import Foundation

// MARK: - Risk tier (agent-ux-fatigue: Risk-Tiered Approval Gates)

/// Naming layer on top of the existing safety decision. The dimension
/// is reversibility + blast radius, NOT action type. Pure: same inputs
/// always produce the same tier. The tier is metadata for the surface
/// and the audit log; the actual gate (auto / ask / reject) is still
/// computed by `TesseraSafetyDecision.check`.
///
/// Boundary discipline: a tier can ONLY be lowered through
/// `TesseraTier.revoke`. Any direct reassignment, mapping fork, or
/// numeric arithmetic that lands below the current tier without going
/// through `revoke()` is tier-boundary drift and must fail review
/// (pattern-catalog.md sec. Tier rules, point 3: drift direction is
/// always toward more gates; the defense is a single auditable surface,
/// and the audit point is this enum).
///
/// Canonical tier table (pattern-catalog.md sec. Risk-Tiered Approval Gates):
/// - tier0: internal-only, idempotent reads
/// - tier1: internal notes, draft creation, status flips on owned records
/// - tier2: outbound emails, deal-stage changes, record deletion, bulk >N
/// - tier3: payment writes, contract execution, customer-facing, regulated
public enum TesseraTier: String, Codable, CaseIterable, Sendable, Comparable {
    case tier0
    case tier1
    case tier2
    case tier3

    /// Numeric severity for comparison. Higher is stricter.
    public var severity: Int {
        switch self {
        case .tier0: return 0
        case .tier1: return 1
        case .tier2: return 2
        case .tier3: return 3
        }
    }

    public static func < (lhs: TesseraTier, rhs: TesseraTier) -> Bool {
        lhs.severity < rhs.severity
    }

    /// Compute the tier for an action class + risk. Pure. Delegates
    /// reversibility to `TesseraActionClass.isIrreversible` (the existing
    /// RULES-not-ML guard) so the tier policy never invents a new
    /// irreversibility signal of its own.
    public static func tier(
        for actionClass: String,
        risk: TesseraActionRisk
    ) -> TesseraTier {
        let irreversible = TesseraActionClass.isIrreversible(actionClass, risk: risk)
        return compute(risk: risk, irreversible: irreversible)
    }

    /// Compute a tier from the risk axis only. Use when the action
    /// class is unknown; the mapping assumes reversible (best case) and
    /// the caller's risk classification carries the load.
    public static func tier(forRisk risk: TesseraActionRisk) -> TesseraTier {
        compute(risk: risk, irreversible: false)
    }

    private static func compute(risk: TesseraActionRisk, irreversible: Bool) -> TesseraTier {
        switch (risk, irreversible) {
        case (.forbidden, _):
            // Forbidden actions never run; the tier is the strictest so
            // a future bypass is auditable.
            return .tier3
        case (.high, true):
            // Payment writes, contract execution, customer-facing comms.
            return .tier3
        case (.high, false):
            // Outbound emails, deal-stage changes - synchronous approval.
            return .tier2
        case (.medium, true):
            // Record deletion, medium-risk destructive writes.
            return .tier2
        case (.low, true):
            // Low-risk but irreversible (destructive verb, external path).
            return .tier2
        case (.medium, false):
            // Internal notes, draft creation, status flips.
            return .tier1
        case (.low, false):
            // Idempotent reads, internal-only writes.
            return .tier0
        }
    }

    /// Long label for surface use. Stays ASCII.
    public var displayName: String {
        switch self {
        case .tier0: return "Tier 0 (auto)"
        case .tier1: return "Tier 1 (notify)"
        case .tier2: return "Tier 2 (approval)"
        case .tier3: return "Tier 3 (multi-party)"
        }
    }

    /// Short label for chip use. ASCII only.
    public var shortLabel: String {
        switch self {
        case .tier0: return "T0"
        case .tier1: return "T1"
        case .tier2: return "T2"
        case .tier3: return "T3"
        }
    }

    /// Downgrade by one notch. The ONLY public path that lowers a tier;
    /// required for any drift correction (e.g. an explicit policy grant
    /// of a tier2-bypass for a single user). tier0 is the floor.
    public func revoke() -> TesseraTier {
        switch self {
        case .tier0: return .tier0
        case .tier1: return .tier0
        case .tier2: return .tier1
        case .tier3: return .tier2
        }
    }
}
