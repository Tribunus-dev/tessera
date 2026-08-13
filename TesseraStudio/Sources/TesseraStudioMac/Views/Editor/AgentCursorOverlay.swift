import SwiftUI
import AppKit
import TesseraCore

// MARK: - AgentCursorOverlay

/// A SwiftUI overlay that visualizes the agent cursor
/// (per spec section 6.5). The agent cursor is a small robot icon
/// at the agent's edit location with a subtle blue
/// background; the cursor blinks at the standard 530ms
/// rate when the agent is active. The user cursor is the
/// standard system text caret (no special treatment).
///
/// **Two cursors, no contention.** The user and the
/// agent have separate cursors in the same document.
/// Both can be active at the same time; the user can
/// click anywhere without affecting the agent's cursor.
/// The overlay reads its position from
/// `EditorCursorState.agentCursor` (the `TextCursor`
/// data model) and converts the offset to a screen
/// position via the text view's `layoutManager`.
///
/// **State.** The overlay is a passive view: it reads
/// `EditorCursorState` from the environment (provided
/// by the host window) and renders the agent cursor at
/// the position the host computes. The host is
/// responsible for mapping the AST offset to a screen
/// position; the overlay only knows how to draw.
///
/// **Inline stop button (paradox 5, Microsoft HAX G11).**
/// When the agent is active and a stop callback is
/// supplied, the overlay renders a tier-weighted stop
/// button next to the agent cursor. The button is the
/// off-ramp: it must be at the same surface as the
/// agent's action, not in a settings menu. The tier
/// parameter (Wave 1B's `TesseraTier`) weights the
/// button's prominence: higher-tier (more consequential)
/// agents get a larger, more saturated button. The
/// callback is the `TesseraAgentLoop.stop(reason:)`
/// entry point; the overlay only owns the rendering and
/// the hit-test, not the stop semantics.
///
/// **Pending-mutation preview (Wave 4A, review #5).**
/// When the host supplies a `pendingMutation` payload
/// (the loop publishes one whenever a tool call is
/// in flight), the overlay renders a one-line chip next
/// to the stop button. The chip shows WHAT the agent is
/// about to change (tier, risk, tool, outcome) so the
/// user verifies the mutation in place, not by opening
/// the audit log. The chip vocabulary matches Wave 1C's
/// `AuditLogHead` (`field: value` shape, pipe
/// separator, field cap of 5).
public struct AgentCursorOverlay: View {
    public let state: EditorCursorState
    public let theme: EditorTheme
    public let screenPositionProvider: (TextCursor) -> CGPoint?
    /// The risk tier of the agent's current action class.
    /// Drives the stop button's prominence (tier0/tier1:
    /// subtle gray; tier2: amber; tier3: red, larger).
    /// Defaults to `.tier1` so existing call sites that do
    /// not opt in to the tier-weighting render the same as
    /// before the inline-stop pattern was added.
    public let tier: TesseraTier
    /// Optional callback invoked when the user presses the
    /// inline stop button. The host wires this to
    /// `TesseraAgentLoop.stop(reason: .userRequest)`. When
    /// nil, the stop button is not rendered (the
    /// pre-existing surface shape, preserved for hosts that
    /// do not want the affordance yet).
    public let onStop: (() -> Void)?
    /// Optional pending-mutation payload (Wave 4A). When
    /// non-nil, the overlay renders the WHAT-not-WHERE
    /// preview chip next to the stop button. The chip is
    /// informational; no tap target. The host wires this to
    /// `TesseraAgentLoop.pendingMutation` (an `@Observable`
    /// property on the loop). When nil, the chip is not
    /// rendered (the pre-existing surface shape, preserved
    /// for hosts that do not opt in to the WHAT preview yet).
    public let pendingMutation: PendingMutation?

    public init(
        state: EditorCursorState,
        theme: EditorTheme = .light,
        screenPositionProvider: @escaping (TextCursor) -> CGPoint?,
        tier: TesseraTier = .tier1,
        onStop: (() -> Void)? = nil,
        pendingMutation: PendingMutation? = nil
    ) {
        self.state = state
        self.theme = theme
        self.screenPositionProvider = screenPositionProvider
        self.tier = tier
        self.onStop = onStop
        self.pendingMutation = pendingMutation
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let agentCursor = state.agentCursor,
               let position = screenPositionProvider(agentCursor) {
                // The agent cursor glyph is the visual anchor for
                // the inline stop button. The button sits to the
                // right of the glyph so it does not overlap the
                // blinking caret (the audit-log HEAD chip from
                // Wave 1C lives in the diff overlay, not here, so
                // the two affordances cannot visually collide).
                AgentCursorGlyph(
                    isActive: state.agentCursorActive,
                    colorHex: theme.agentCursorColorHex
                )
                .position(x: position.x, y: position.y)
                .allowsHitTesting(false)

                if state.agentCursorActive, let onStop = onStop {
                    AgentInlineStopButton(
                        tier: tier,
                        onTap: onStop
                    )
                    // Offset 8pt to the right of the glyph center and
                    // vertically centered on the glyph baseline. The
                    // 8pt gap is the same as Apple's minimum tap
                    // target separation, so the two hit regions do
                    // not overlap.
                    .position(
                        x: position.x + InlineStopMetrics.glyphWidth + InlineStopMetrics.gap,
                        y: position.y
                    )
                }

                // Pending-mutation preview chip (Wave 4A). Sits to
                // the right of the stop button with a 8pt gap.
                // The chip is informational (no tap target); the
                // diff overlay's chip (Wave 1C) is the surface
                // for receipt-id taps. The chip's x position is
                // computed from the stop button's tier-weighted
                // width (per-tier constants in
                // `InlineStopMetrics`) so the layout does not
                // depend on SwiftUI measurement.
                if state.agentCursorActive, let mutation = pendingMutation {
                    PendingMutationChip(mutation: mutation)
                        .position(
                            x: position.x + InlineStopMetrics.glyphWidth
                                + InlineStopMetrics.gap
                                + InlineStopMetrics.stopButtonWidth(tier: tier)
                                + InlineStopMetrics.chipGap,
                            y: position.y
                        )
                }
            }
        }
    }
}

// MARK: - InlineStopMetrics

/// Layout constants for the inline stop button. Kept as a
/// file-private enum so the values are auditable in one
/// place; the `glyphWidth` matches the agent cursor's
/// frame width so the offset computation in `body` lands
/// the button's leading edge 8pt to the right of the
/// glyph's trailing edge.
private enum InlineStopMetrics {
    static let glyphWidth: CGFloat = 14
    static let gap: CGFloat = 12
    /// Gap between the inline stop button's trailing edge and
    /// the pending-mutation chip's leading edge. 8pt matches
    /// Apple's minimum tap-target separation so the two
    /// affordances do not visually merge.
    static let chipGap: CGFloat = 8
    /// Approximate width of the inline stop button at each
    /// tier. The exact width depends on font metrics; the
    /// layout only needs a leading-edge anchor for the
    /// pending-mutation chip, so a tier-keyed constant is
    /// sufficient. tier3 is the widest (the "Stop now" label
    /// has 8 characters vs 4 for the other tiers).
    static func stopButtonWidth(tier: TesseraTier) -> CGFloat {
        switch tier {
        case .tier0, .tier1: return 46
        case .tier2:        return 52
        case .tier3:        return 70
        }
    }
}

// MARK: - AgentCursorGlyph

/// The visual representation of the agent cursor. A
/// small robot icon with a subtle blue background that
/// blinks when the agent is active. The blink uses the
/// `cursorBlink` animation primitive (530ms cycle, 50/50
/// on/off; static under Reduce Motion).
private struct AgentCursorGlyph: View {
    let isActive: Bool
    let colorHex: String

    var body: some View {
        ZStack {
            // Background bar (subtle blue)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: colorHex)?.opacity(0.15) ?? Color.blue.opacity(0.15))
                .frame(width: 14, height: 18)
            // Robot icon
            Image(systemName: "cpu")
                .symbolRenderingMode(.hierarchical)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(hex: colorHex) ?? .blue)
        }
        .cursorBlink(isActive: isActive)
    }
}

// MARK: - AgentInlineStopButton

/// The inline stop button rendered at the agent cursor
/// (paradox 5, Microsoft HAX G11). The button is the
/// off-ramp: a visible, large, labelled button at the
/// same surface as the agent's action. The tier
/// parameter weights the prominence: higher-tier (more
/// consequential) actions get a larger, more saturated
/// button so the affordance matches the blast radius.
///
/// Visual rules:
/// - tier0/tier1: small, gray, label "Stop". Conservative
///   affordance for low-consequence actions.
/// - tier2: medium, amber, label "Stop". Synchronous-
///   approval-tier actions; the button is larger to match
///   the heavier tier.
/// - tier3: large, red, label "Stop now". Multi-party-
///   approval-tier actions; the button is the most
///   prominent, with the "now" suffix signaling the
///   irreversibility implied by the tier.
///
/// Accessibility: the button uses a non-decorative label
/// and an `accessibilityHint` describing the hard-stop
/// semantics, so VoiceOver users hear the same warning
/// sighted users see.
private struct AgentInlineStopButton: View {
    let tier: TesseraTier
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                Text(label)
                    .font(.system(size: labelSize, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop the agent")
        .accessibilityHint(hintText)
    }

    // MARK: Tier-weighted metrics

    private var iconSize: CGFloat {
        switch tier {
        case .tier0, .tier1: return 9
        case .tier2:        return 10
        case .tier3:        return 12
        }
    }

    private var labelSize: CGFloat {
        switch tier {
        case .tier0, .tier1: return 10
        case .tier2:        return 11
        case .tier3:        return 12
        }
    }

    private var horizontalPadding: CGFloat {
        switch tier {
        case .tier0, .tier1: return 6
        case .tier2:        return 8
        case .tier3:        return 10
        }
    }

    private var verticalPadding: CGFloat {
        switch tier {
        case .tier0, .tier1: return 2
        case .tier2:        return 3
        case .tier3:        return 4
        }
    }

    private var backgroundColor: Color {
        switch tier {
        case .tier0, .tier1: return Color.gray.opacity(0.85)
        case .tier2:        return Color.orange.opacity(0.90)
        case .tier3:        return Color.red.opacity(0.92)
        }
    }

    private var foregroundColor: Color {
        .white
    }

    private var borderColor: Color {
        switch tier {
        case .tier0, .tier1: return Color.gray.opacity(0.5)
        case .tier2:        return Color.orange.opacity(0.7)
        case .tier3:        return Color.red.opacity(0.8)
        }
    }

    private var label: String {
        switch tier {
        case .tier0, .tier1, .tier2: return "Stop"
        case .tier3:                return "Stop now"
        }
    }

    private var hintText: String {
        switch tier {
        case .tier0, .tier1:
            return "Stops the agent at its current step. The agent will not resume until you ask it to."
        case .tier2:
            return "Stops the agent. Approval-tier actions in progress will be cancelled. The agent will not resume until you ask it to."
        case .tier3:
            return "Hard-stops the agent. Multi-party-tier actions in progress will be cancelled. The agent will not resume until you ask it to."
        }
    }
}

// MARK: - PendingMutationChip

/// The WHAT-not-WHERE preview chip rendered next to the agent
/// cursor (Wave 4A, review #5 of the agent-ux-fatigue audit).
/// The chip is the headline, not the article: it shows at most
/// `fieldCap` fields in a `field: value` shape joined by ` | `,
/// matching Wave 1C's `AuditLogHead` chip vocabulary. The four
/// canonical keys are `tier:`/`risk:`/`tool:`/`outcome:`; a
/// 5th `summary:` field is appended when present.
///
/// **Why this lives here, not on the diff overlay.** The
/// agent cursor sits at the action's location; the diff
/// overlay sits at the action's surface. The cursor is the
/// "is the agent about to do the right thing?" surface
/// (paradox 1: verification cost -- the user wants to see
/// WHAT before the tool runs). The diff overlay is the
/// "did the agent do the right thing?" surface (Wave 1C:
/// the audit-log HEAD chip shows AFTER the tool has run).
/// Both surfaces share the chip vocabulary so the user
/// sees the same structural data either way.
///
/// **No tap target.** The chip is informational. Consumers
/// that want a tap target use Wave 1C's `AuditLogHeadChip`
/// on the diff overlay, which carries the receipt id. The
/// cursor chip does not need a tap target because the
/// cursor is the agent's live edit position, not a history
/// surface.
private struct PendingMutationChip: View {
    let mutation: PendingMutation

    var body: some View {
        // Match the AuditLogHeadChip shape: caption monospaced
        // text on a subtle background, no border, no padding
        // chrome that would compete with the stop button. The
        // outcome field is the only one that changes color
        // (pending/approved/blocked use a soft palette step)
        // so the user can read the gate state at a glance.
        Text(mutation.displayString)
            .font(.caption.monospaced())
            .foregroundStyle(textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    /// Soft color step on the `outcome` field. Mirrors the
    /// stop button's tier-weighting (Wave 3C) in spirit: the
    /// more consequential the state, the more saturated the
    /// background. `blocked` is the most saturated so a
    /// denied action is visible from across the editor.
    private var textColor: Color {
        switch mutation.outcome {
        case .pending:  return .secondary
        case .approved: return .secondary
        case .blocked:  return .red
        }
    }

    private var backgroundColor: Color {
        switch mutation.outcome {
        case .pending:  return Color.secondary.opacity(0.08)
        case .approved: return Color.secondary.opacity(0.08)
        case .blocked:  return Color.red.opacity(0.12)
        }
    }

    /// VoiceOver-friendly description. The displayString is
    /// already the chip's content; the accessibility label
    /// adds a leading phrase so VoiceOver users hear
    /// "Pending mutation: tier T2, risk medium, ..." rather
    /// than just the field/value pairs.
    private var accessibilityText: String {
        "Pending mutation: \(mutation.displayString)"
    }
}

// MARK: - Color(hex:) helper (SwiftUI Color)

private extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        } else {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        self = Color(red: r, green: g, blue: b, opacity: a)
    }
}
