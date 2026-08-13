import Foundation

/// Builds the canonical Tessy + Sky chat graph for one turn.
///
/// Topology (porting the Linux `WorkflowSurface.cpp:50-85` demo but wired to
/// the real agent loops):
///   entry `intake` -> router conditional edge -> `tessy` / `sky` / synthesis
///   -> `__end__`
///
/// The router reuses ``DualAgentRouter`` (keyword + `@tessy/@sky/@both`
/// override), so routing matches the legacy dual-agent controller exactly.
/// The Tessy/Sky nodes drive ``TesseraAgentLoop.run`` so tool calls execute
/// and the approval gate fires (unlike the legacy controller's
/// `provider.stream` short-circuit, which left approvals dormant).
public enum ChatGraphBuilder {
    /// Callbacks the nodes use to stream visible text/tool-calls back into
    /// the controller's transcript rows.
    public struct Hooks: Sendable {
        public let onText: @Sendable @MainActor (AgentPersona, String) -> Void
        public let onToolCall: @Sendable @MainActor (AgentPersona, String, [String: JSONValue]) -> Void
        /// Fires when a tool call completes. Added in Wave 3A so the
        /// controller can extract the tool's structured `data["sources"]`
        /// and lift it onto the row as a `Citation` set. The hook is
        /// optional (default no-op) so the call site that has no
        /// use for tool results (e.g. tests) can omit it.
        public let onToolResult: @Sendable @MainActor (AgentPersona, String, ToolResult) -> Void
        public let onFinalize: @Sendable @MainActor (AgentPersona) -> Void

        public init(
            onText: @escaping @Sendable @MainActor (AgentPersona, String) -> Void,
            onToolCall: @escaping @Sendable @MainActor (AgentPersona, String, [String: JSONValue]) -> Void,
            onFinalize: @escaping @Sendable @MainActor (AgentPersona) -> Void,
            onToolResult: @escaping @Sendable @MainActor (AgentPersona, String, ToolResult) -> Void = { _, _, _ in }
        ) {
            self.onText = onText
            self.onToolCall = onToolCall
            self.onToolResult = onToolResult
            self.onFinalize = onFinalize
        }
    }

    /// Build a chat graph for one turn. The node closures capture the loops
    /// and hooks so they can stream tokens and tool calls back as they run.
    public static func build(
        userMessage: String,
        decision: DualAgentRoutingDecision,
        prompt: String,
        tessyLoop: TesseraAgentLoop,
        skyLoop: TesseraAgentLoop,
        onText: @escaping @Sendable @MainActor (AgentPersona, String) -> Void,
        onToolCall: @escaping @Sendable @MainActor (AgentPersona, String, [String: JSONValue]) -> Void,
        onFinalize: @escaping @Sendable @MainActor (AgentPersona) -> Void,
        onToolResult: @escaping @Sendable @MainActor (AgentPersona, String, ToolResult) -> Void = { _, _, _ in }
    ) -> StateGraph {
        let g = StateGraph(name: "tessy-sky-chat")

        // Intake: record the user message into state. The user row is
        // appended by the controller directly; this node exists so the graph
        // has a single deterministic entry and so the router can read state.
        g.addNode("intake", "Intake") { state in
            var s = state
            s["user_message"] = .string(userMessage)
            s["route"] = .string(routeKey(decision: decision))
            return .init(updates: s)
        }

        // Router conditional edge. Reads the route key set by intake and
        // branches to tessy / sky / both. "both" goes to the synthesis path.
        g.addConditionalEdge(from: "intake", router: { state in
            state["route"]?.stringValue ?? "tessy"
        }, branches: [
            "tessy": "tessy",
            "sky": "sky",
            "both": "tessy"   // team-up: run tessy first, then sky via synthesis
        ])

        // Tessy node: run the on-device loop, streaming text + tool calls.
        g.addNode("tessy", "Tessy") { state in
            await runAgentLoop(
                persona: .tessy,
                loop: tessyLoop,
                prompt: prompt,
                history: chatHistory(from: state),
                onText: onText,
                onToolCall: onToolCall,
                onToolResult: onToolResult,
                onFinalize: onFinalize
            )
            return .init(updates: ["tessy_done": .bool(true)])
        }

        // Sky node: run the cloud loop.
        g.addNode("sky", "Sky") { state in
            await runAgentLoop(
                persona: .sky,
                loop: skyLoop,
                prompt: prompt,
                history: chatHistory(from: state),
                onText: onText,
                onToolCall: onToolCall,
                onToolResult: onToolResult,
                onFinalize: onFinalize
            )
            return .init(updates: ["sky_done": .bool(true)])
        }

        // Edges to finish.
        g.addEdge(from: "tessy", to: stateGraphEnd)
        g.addEdge(from: "sky", to: stateGraphEnd)

        // Team-up path: after Tessy, run Sky then finish.
        if decision.isTeamUp {
            g.addEdge(from: "tessy", to: "sky")
        }

        g.setEntryPoint("intake")
        return g
    }

    /// Build an empty chat graph (for the controller's stored executor, which
    /// is replaced per-turn anyway).
    public static func build() -> StateGraph {
        let g = StateGraph(name: "tessy-sky-chat")
        g.addNode("intake", "Intake", { state in .init(updates: state) })
        g.addEdge(from: "intake", to: stateGraphEnd)
        g.setEntryPoint("intake")
        return g
    }

    // MARK: - Helpers

    private static func routeKey(decision: DualAgentRoutingDecision) -> String {
        if decision.isTeamUp { return "both" }
        if decision.useSky { return "sky" }
        return "tessy"
    }

    private static func chatHistory(from state: GraphState) -> [ChatMessage] {
        // The graph state is a flat map; full history reconstruction from
        // checkpoints lands with the time-travel UI. For now the loops see
        // the user message as a single-turn prompt.
        guard let msg = state["user_message"]?.stringValue else { return [] }
        return [ChatMessage(role: .user, content: msg)]
    }

    /// Drive one agent loop, streaming its events back through the hooks.
    /// Routes through `loop.run(...)` (not `provider.stream`) so tool calls
    /// execute and the approval gate fires. `loop.run` is @MainActor, so the
    /// stream is created on the main actor and consumed here; the hooks hop
    /// back to the main actor themselves (they touch the controller).
    private static func runAgentLoop(
        persona: AgentPersona,
        loop: TesseraAgentLoop,
        prompt: String,
        history: [ChatMessage],
        onText: @escaping @Sendable @MainActor (AgentPersona, String) -> Void,
        onToolCall: @escaping @Sendable @MainActor (AgentPersona, String, [String: JSONValue]) -> Void,
        onToolResult: @escaping @Sendable @MainActor (AgentPersona, String, ToolResult) -> Void,
        onFinalize: @escaping @Sendable @MainActor (AgentPersona) -> Void
    ) async {
        let stream = await MainActor.run { loop.run(userMessage: prompt, history: history) }
        for await event in stream {
            switch event {
            case .text(let chunk):
                await onText(persona, chunk)
            case .toolCall(let name, let arguments):
                await onToolCall(persona, name, arguments)
            case .toolResult(let name, let result):
                // Forward tool results to the controller so it can lift
                // structured data (e.g. `data["sources"]` from the
                // research tool) onto the row. Without this hook the
                // controller never sees the tool's return value and
                // can only record the call, not its provenance.
                await onToolResult(persona, name, result)
            case .error(let message):
                await onText(persona, "[error: \(message)]")
            case .done:
                break
            case .thinking:
                break
            }
        }
        await onFinalize(persona)
    }
}
