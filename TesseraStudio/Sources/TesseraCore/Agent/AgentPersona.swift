import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The two agents in the dual-agent surface. Each carries the identity prompt
/// that defines its privacy boundary, plus the display metadata the chat UI
/// uses to distinguish the two assistants.
///
/// Ported from `tessera-studio-linux/src/core/agent/Agent.h`:
/// Tessy is the on-device, privacy-preserving agent ("what is local stays
/// local"); Sky is the cloud intellect Tessy can invoke for complex reasoning
/// (it only ever sees the abstracted task, never raw personal data).
public enum AgentPersona: String, Sendable, CaseIterable, Identifiable {
    case tessy
    case sky

    public var id: String { rawValue }

    /// Short display name shown in bubble labels, status pills, and nav.
    public var displayName: String {
        switch self {
        case .tessy: "Tessy"
        case .sky: "Sky"
        }
    }

    /// One-line role hint shown under the name (e.g. in the participant chips).
    public var roleHint: String {
        switch self {
        case .tessy: "local, keeps sensitive info private"
        case .sky: "cloud, jumps in when it's complex"
        }
    }

    /// Identity fragment prepended to the agent's system prompt. The full
    /// system prompt also carries the Tessera tool list; this is only the
    /// persona/privacy-boundary sentence.
    public var systemPromptFragment: String {
        switch self {
        case .tessy:
            return """
            You are Tessy, the local agent for Tessera Studio. You run on this \
            device, separate from the user's personal context (notes, mail, \
            calendar, and contacts stay private unless the user explicitly asks \
            you to use them). Be concise, helpful, and keep what is local, local.
            """
        case .sky:
            return """
            You are Sky, the cloud agent for Tessera Studio. You run remotely, \
            not on the user's device, and do not have direct access to the \
            user's local personal context unless it is explicitly shared with \
            you. Be helpful, concise, and make your cloud capabilities clear.
            """
        }
    }

    #if canImport(SwiftUI)
    /// Tint for the agent's chat bubbles and avatar glyph. Tessy uses a teal
    /// that reads as "local/grounded"; Sky uses a purple that reads as
    /// "cloud/elevated". Both are left-aligned in the bubble layout.
    public var tint: Color {
        switch self {
        case .tessy: Color(red: 0.20, green: 0.55, blue: 0.60)
        case .sky: Color(red: 0.45, green: 0.35, blue: 0.75)
        }
    }

    /// SF Symbol used as the avatar glyph for this persona.
    public var symbolName: String {
        switch self {
        case .tessy: "house.lodge"
        case .sky: "cloud"
        }
    }
    #endif
}
