import Foundation

/// Which assistant(s) should answer a given user message. Ported from
/// `tessera-studio-linux/src/app/AppMain.cpp`'s `on_send` classifier.
public struct DualAgentRoutingDecision: Sendable, Equatable {
    public var useTessy: Bool
    public var useSky: Bool

    public init(useTessy: Bool, useSky: Bool) {
        self.useTessy = useTessy
        self.useSky = useSky
    }

    /// Both assistants fire (the "team up" case: a sensitive task that is also
    /// complex - Tessy keeps the personal context local, Sky handles the hard
    /// reasoning).
    public var isTeamUp: Bool { useTessy && useSky }
}

/// Routes a user message to Tessy (local), Sky (cloud), or both, and parses
/// explicit `@tessy` / `@sky` / `@both` overrides. Pure and testable.
public enum DualAgentRouter {
    /// Sensitive keywords force Tessy-only: the message looks like it touches
    /// personal context, so the cloud intellect is never invited. Mirrors the
    /// Linux heuristic verbatim.
    private static let sensitiveKeywords: Set<String> = [
        "my", "personal", "private", "notes", "email", "calendar",
        "remember", "contact"
    ]

    /// Complex keywords invite Sky: the message asks for the kind of reasoning
    /// a cloud model is better at. Mirrors the Linux heuristic verbatim.
    private static let complexKeywords: Set<String> = [
        "explain", "analyze", "code", "write", "plan", "design",
        "compare", "summarize", "translate", "why", "how to", "steps"
    ]

    /// Length past which a message is treated as complex regardless of keywords.
    private static let complexLengthThreshold = 120

    public static func isSensitive(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let words = Set(lowered.split(separator: " ").map(String.init))
        return !words.isDisjoint(with: sensitiveKeywords)
    }

    public static func isComplex(_ prompt: String) -> Bool {
        prompt.count > complexLengthThreshold
            || complexKeywords.contains(where: { prompt.lowercased().contains($0) })
    }

    /// Keyword-only routing (no override parse). Mirrors the Linux rule:
    /// `useTessy = sensitive || !complex`; `useSky = complex`.
    public static func route(keywordsFor prompt: String) -> DualAgentRoutingDecision {
        let sensitive = isSensitive(prompt)
        let complex = isComplex(prompt)
        return DualAgentRoutingDecision(
            useTessy: sensitive || !complex,
            useSky: complex
        )
    }

    /// Parse an explicit override prefix (`@tessy` / `@sky` / `@both`) and
    /// return the decision plus the prompt with the prefix stripped. When no
    /// override is present, falls back to the keyword classifier.
    public static func route(for prompt: String) -> (decision: DualAgentRoutingDecision, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(separator: " ").first.map(String.init)?.lowercased() ?? ""

        switch first {
        case "@tessy":
            let rest = stripFirstWord(trimmed)
            return (DualAgentRoutingDecision(useTessy: true, useSky: false), rest)
        case "@sky":
            let rest = stripFirstWord(trimmed)
            return (DualAgentRoutingDecision(useTessy: false, useSky: true), rest)
        case "@both":
            let rest = stripFirstWord(trimmed)
            return (DualAgentRoutingDecision(useTessy: true, useSky: true), rest)
        default:
            return (route(keywordsFor: trimmed), trimmed)
        }
    }

    private static func stripFirstWord(_ s: String) -> String {
        let firstSpace = s.firstIndex(of: " ") ?? s.endIndex
        return String(s[s.index(after: firstSpace)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
