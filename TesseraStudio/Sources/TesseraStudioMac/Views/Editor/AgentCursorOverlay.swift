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

    public init(
        state: EditorCursorState,
        theme: EditorTheme = .light,
        screenPositionProvider: @escaping (TextCursor) -> CGPoint?,
        tier: TesseraTier = .tier1,
        onStop: (() -> Void)? = nil
    ) {
        self.state = state
        self.theme = theme
        self.screenPositionProvider = screenPositionProvider
        self.tier = tier
        self.onStop = onStop
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
