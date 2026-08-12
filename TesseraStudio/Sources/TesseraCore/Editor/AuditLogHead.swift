import Foundation
import SwiftUI

// MARK: - AuditLogRenderState

/// The render state the chip needs to decide whether to show
/// itself. Mirrors `DiffOverlayState` without coupling the chip
/// to the editor's full state enum (the chip is a self-contained
/// module; the overlay translates its state into one of these).
public enum AuditLogRenderState: Sendable {
    case idle
    case streaming
    case diffComplete
    case editable
}

// MARK: - AuditLogHead

/// The audit-log HEAD for one in-flight diff overlay session.
///
/// A single line of structural data the user can read at a glance:
/// `risk: medium | tool: rewrite | 2.1s | receipt: a1b2...`
///
/// From review #5 (paradox 1: verification cost). The chip inlines
/// the receipt's head where the user is deciding Accept/Reject, so
/// the user does not have to open the receipts drawer to see who
/// did what. The chip is the headline, not the article: when more
/// than `fieldCap` fields are requested, the extras are dropped and
/// the user is expected to open the drawer for the full record.
///
/// **State gating.** The chip renders only when the diff overlay
/// is in a verifiable state (`.diffComplete` or `.editable`). On
/// `.streaming` the chip is suppressed (the rewrite is in flight
/// and the audit log is incomplete). On `.idle` the chip is
/// suppressed (there is no diff to verify).
///
/// **Mutations-empty guard.** If the underlying receipt's
/// `mutations` is empty (a non-document receipt, per
/// `ReceiptExportService` "Mutations: (none - non-document
/// receipt)"), the chip is suppressed. An audit log with no
/// content is decoration.
public struct AuditLogHead: Sendable, Equatable {

    /// Categorical risk level for the rewrite. Mirrors
    /// `TesseraSafetyDecision`'s `low | medium | high | forbidden`
    /// enum. Categorical, not numeric confidence, per the
    /// skill's anti-pattern on numeric confidence.
    public enum Risk: String, Sendable, CaseIterable, Codable {
        case low
        case medium
        case high
        case forbidden

        public var displayLabel: String {
            switch self {
            case .low:       return "low"
            case .medium:    return "medium"
            case .high:      return "high"
            case .forbidden: return "forbidden"
            }
        }
    }

    /// The categorical risk for the rewrite.
    public let risk: Risk
    /// The tool name (e.g. "rewrite", "improve", or the
    /// `RewriteMode.rawValue`).
    public let tool: String
    /// Wall-clock seconds the rewrite consumed. One decimal.
    public let elapsedSeconds: Double
    /// The receipt id this chip is the head of. Short form
    /// (first 8 chars of the UUID) is what the chip displays;
    /// the full id is what the chip routes on tap.
    public let receiptID: UUID
    /// The mutations the receipt produced. Used both for the
    /// empty-suppression guard and for the optional
    /// `mutations: N` field.
    public let mutations: [Mutation]
    /// Optional one-line human-readable summary, surfaced as
    /// the 5th field when present.
    public let summary: String?
    /// Optional actor string (e.g. "agent:llama3" or
    /// "user:<uuid>"), surfaced as the 5th field when
    /// `summary` is nil.
    public let actor: String?

    /// Hard cap on rendered fields. The chip is the headline;
    /// when the head needs more, route to the drawer.
    public static let fieldCap: Int = 5

    public init(
        risk: Risk,
        tool: String,
        elapsedSeconds: Double,
        receiptID: UUID,
        mutations: [Mutation],
        summary: String? = nil,
        actor: String? = nil
    ) {
        self.risk = risk
        self.tool = tool
        self.elapsedSeconds = elapsedSeconds
        self.receiptID = receiptID
        self.mutations = mutations
        self.summary = summary
        self.actor = actor
    }

    /// True iff the chip should render for the given overlay
    /// state. Mirrors the gating from review #5: show on
    /// `.diffComplete` and `.editable`; suppress on `.streaming`
    /// and `.idle`. The mutations-empty guard is also enforced
    /// here so callers do not have to check both.
    public func shouldRender(for state: AuditLogRenderState) -> Bool {
        guard !mutations.isEmpty else { return false }
        switch state {
        case .diffComplete, .editable:
            return true
        case .idle, .streaming:
            return false
        }
    }

    /// Short form of the receipt id (first 8 chars of the UUID).
    /// The full id stays available via `receiptID` for the tap
    /// routing.
    public var shortReceiptID: String {
        let raw = receiptID.uuidString
        return String(raw.prefix(8))
    }

    /// The receipt-id substring the chip displays (e.g.
    /// `a1b2c3d4...`). Includes the trailing ellipsis so the
    /// displayed substring is unambiguous when concatenated
    /// into the chip's full string.
    public var receiptIDLabel: String {
        "\(shortReceiptID)..."
    }

    /// One-line string the chip renders. Format mirrors review #5:
    /// `risk: <r> | tool: <t> | <s>s | receipt: <short>...`. A
    /// 5th field (`summary` or `actor`) is appended when present.
    /// Field count is capped at ``fieldCap`` so the chip never
    /// becomes a wall of text.
    public var displayString: String {
        var fields: [String] = [
            "risk: \(risk.displayLabel)",
            "tool: \(tool)",
            String(format: "%.1fs", elapsedSeconds),
            "receipt: \(receiptIDLabel)",
        ]
        if let summary, !summary.isEmpty {
            fields.append("summary: \(summary)")
        } else if let actor, !actor.isEmpty {
            fields.append("actor: \(actor)")
        }
        let capped = Array(fields.prefix(Self.fieldCap))
        return capped.joined(separator: " | ")
    }
}

// MARK: - AuditLogHeadChip

/// The SwiftUI view that renders one `AuditLogHead` as a one-line
/// chip. The chip is intentionally narrow: one label, one tappable
/// receipt-id region, no buttons. Accept/Reject live in the
/// overlay's own control bar; the chip never blocks them.
public struct AuditLogHeadChip: View {
    public let head: AuditLogHead
    /// Tap on the receipt-id portion. The view layer routes the
    /// full `UUID` to the receipts coordinator; the chip itself
    /// only sees the closure.
    public let onTapReceipt: (UUID) -> Void

    public init(
        head: AuditLogHead,
        onTapReceipt: @escaping (UUID) -> Void
    ) {
        self.head = head
        self.onTapReceipt = onTapReceipt
    }

    public var body: some View {
        // Split the display string into the prefix (everything
        // before "receipt:") and the receipt-id label. Two
        // sub-views, one Button for the receipt id, give a
        // tappable region that does NOT extend over the
        // Accept/Reject controls in the control bar.
        let full = head.displayString
        let receiptLabel = head.receiptIDLabel
        let split = full.range(of: "receipt: ") ?? full.startIndex..<full.endIndex
        let prefix = String(full[full.startIndex..<split.upperBound])
        return HStack(spacing: 0) {
            Text(prefix)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: { onTapReceipt(head.receiptID) }) {
                Text(receiptLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.accentColor)
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open receipt \(head.shortReceiptID)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(full)
    }
}
