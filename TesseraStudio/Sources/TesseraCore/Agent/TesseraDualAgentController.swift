import Foundation
import Observation

/// One row in the dual-agent transcript. Value-typed so the view can diff it
/// cheaply. `speaker` is nil for user rows; assistant rows carry the persona.
public struct DualAgentMessage: Sendable, Identifiable {
    public let id: UUID
    public let role: ChatRole
    public let speaker: AgentPersona?
    public var content: String
    public let toolCalls: [ToolCallRecord]
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        speaker: AgentPersona? = nil,
        content: String,
        toolCalls: [ToolCallRecord] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.speaker = speaker
        self.content = content
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
    }
}

/// One row of the Tessy<->Sky handoff trace shown in the Collab surface.
/// Live-appended from the controller when the two agents collaborate.
public struct CollabTraceEntry: Sendable, Identifiable {
    public let id = UUID()
    public let from: AgentPersona
    public let text: String
    public let timestamp: Date = Date()
}

/// Owns the two agent loops (Tessy + Sky) and drives them concurrently for the
/// dual-agent chat surface. Each loop has its own approval engine - the
/// single-flight `pendingRequest`/continuation cannot be shared, and concurrent
/// approvals must not collide.
///
/// Streaming: the controller reads each loop's `run(...)` `AsyncStream<AgentEvent>`
/// and also calls the provider's `stream(...)` directly for the visible text.
/// The loop's own `.text` events are whole-response; the dual-agent surface
/// wants token-granular bubbles, so `sendTurn` calls the provider's `stream(...)`
/// for the display path and keeps the loop for tool dispatch + approval.
@MainActor
@Observable
public final class TesseraDualAgentController {
    public private(set) var messages: [DualAgentMessage] = []
    public private(set) var collabTrace: [CollabTraceEntry] = []
    public private(set) var statusPill: String = ""
    public private(set) var isRunning = false

    public let tessyLoop: TesseraAgentLoop
    public let skyLoop: TesseraAgentLoop
    /// Combined approval state: whichever engine has a pending request right
    /// now. The view presents an ApprovalSheet for the active one.
    public var pendingApproval: PendingApprovalUnion?

    private var tessyStreamingID: UUID?
    private var skyStreamingID: UUID?
    private var tasks: [Task<Void, Never>] = []

    public init(
        tessyLoop: TesseraAgentLoop? = nil,
        skyLoop: TesseraAgentLoop? = nil
    ) {
        // Two independent loops. Tessy uses the on-device/placeholder factory
        // (the local agent); Sky uses the cloud factory. Each gets its own
        // approval engine so concurrent approvals never share a continuation.
        let tessyProvider = TesseraLLMProviderFactory.makeFromSettings()
        let skyProvider = TesseraLLMProviderFactory.makeSky()
        self.tessyLoop = tessyLoop ?? TesseraAgentLoop(
            registry: TesseraToolRegistry.default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: tessyProvider,
            persona: .tessy
        )
        self.skyLoop = skyLoop ?? TesseraAgentLoop(
            registry: TesseraToolRegistry.default,
            approvalEngine: TesseraApprovalEngine(),
            llmProvider: skyProvider,
            persona: .sky
        )
    }

    /// MainActor-isolated convenience init used by SwiftUI views as a default
    /// argument. SwiftUI evaluates default args in a nonisolated context, so
    /// the surface-level default-arg form `init(controller:)` cannot call the
    /// isolated designated init directly; views call this via
    /// `MainActor.assumeIsolated` in their own default expression.
    public static func makeDefault() -> TesseraDualAgentController {
        TesseraDualAgentController()
    }

    public func cancel() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        tessyLoop.cancel()
        skyLoop.cancel()
        isRunning = false
        statusPill = ""
    }

    /// Clear the chat transcript (the collab trace is kept - it's the
    /// handoff history, not the conversation).
    public func clearTranscript() {
        messages.removeAll()
        tessyStreamingID = nil
        skyStreamingID = nil
        statusPill = ""
        isRunning = false
    }

    /// Send a user message. Routes via keyword + override, then spawns one
    /// task per chosen assistant. Both stream concurrently into their own
    /// live bubble; the user bubble is appended immediately.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        let (decision, prompt) = DualAgentRouter.route(for: trimmed)
        guard decision.useTessy || decision.useSky else { return }

        // User bubble, immediately.
        messages.append(DualAgentMessage(role: .user, content: trimmed))
        isRunning = true
        updateStatus(decision: decision)

        // Seed the collab trace when both fire (the handoff narrative).
        if decision.isTeamUp {
            collabTrace.append(CollabTraceEntry(
                from: .tessy,
                text: "Got a complex task that touches personal context - I'll keep the sensitive parts local and ask Sky to help with the reasoning: \(prompt)"
            ))
            collabTrace.append(CollabTraceEntry(
                from: .sky,
                text: "Standing by - I'll reason over the abstracted task; the raw personal context stays on device."
            ))
        }

        if decision.useTessy {
            runAgent(.tessy, loop: tessyLoop, prompt: prompt)
        }
        if decision.useSky {
            runAgent(.sky, loop: skyLoop, prompt: prompt)
        }
    }

    // MARK: - Per-agent streaming

    private func runAgent(_ persona: AgentPersona, loop: TesseraAgentLoop, prompt: String) {
        // Seed an empty streaming bubble for this persona.
        let bubbleID = UUID()
        messages.append(DualAgentMessage(id: bubbleID, role: .assistant, speaker: persona, content: "", isStreaming: true))
        if persona == .tessy { tessyStreamingID = bubbleID } else { skyStreamingID = bubbleID }

        let history = messages.filter { $0.role == .user || $0.role == .assistant }
            .map { ChatMessage(role: $0.role, content: $0.content, speaker: $0.speaker?.rawValue) }
        let task = Task { @MainActor [weak self] in
            await self?.streamTurn(persona: persona, loop: loop, bubbleID: bubbleID, prompt: prompt, history: history)
            self?.agentFinished(persona)
        }
        tasks.append(task)
    }

    /// Drive one assistant turn by reading the loop's `run(...)` stream. Tool
    /// calls, approvals, and errors flow through the loop's events; the visible
    /// text is streamed token-by-token via the provider's `stream(...)`.
    private func streamTurn(
        persona: AgentPersona,
        loop: TesseraAgentLoop,
        bubbleID: UUID,
        prompt: String,
        history: [ChatMessage]
    ) async {
        // Build the system prompt the same way the loop does (persona +
        // tools + skills) so the streamed text matches the loop's framing.
        let stream: AsyncStream<LLMChunk>
        do {
            let systemPrompt = loop.systemPrompt(for: prompt)
            let provider = loop.llmProviderForStreaming
            let llmMessages = history.map { LLMMessage(role: $0.role.rawValue, content: $0.content) }
                + [LLMMessage(role: "user", content: prompt)]
            let tools = loop.toolDescriptors
            stream = try await provider.stream(
                system: systemPrompt,
                messages: llmMessages,
                tools: tools
            )
        } catch {
            appendError(persona: persona, bubbleID: bubbleID, message: error.localizedDescription)
            return
        }

        // Accumulate streamed text into the live bubble.
        for await chunk in stream {
            if Task.isCancelled { break }
            switch chunk {
            case .text(let delta):
                appendDelta(persona: persona, bubbleID: bubbleID, delta)
            case .toolCalls:
                // The display path doesn't dispatch tools; the agentic loop
                // (UnifiedChatController via ChatGraphBuilder) does.
                break
            case .done:
                finalizeBubble(persona: persona, bubbleID: bubbleID)
            }
        }
        finalizeBubble(persona: persona, bubbleID: bubbleID)
    }

    // MARK: - Bubble mutation helpers

    private func appendDelta(persona: AgentPersona, bubbleID: UUID, _ delta: String) {
        guard let idx = messages.firstIndex(where: { $0.id == bubbleID }) else { return }
        messages[idx].content += delta
    }

    private func finalizeBubble(persona: AgentPersona, bubbleID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == bubbleID }) else { return }
        if messages[idx].isStreaming {
            messages[idx].isStreaming = false
        }
    }

    private func appendError(persona: AgentPersona, bubbleID: UUID, message: String) {
        if let idx = messages.firstIndex(where: { $0.id == bubbleID }) {
            messages[idx].content = "[\(persona.displayName) error: \(message)]"
            messages[idx].isStreaming = false
        } else {
            messages.append(DualAgentMessage(
                role: .system, speaker: persona,
                content: "[\(persona.displayName) error: \(message)]"
            ))
        }
    }

    private func agentFinished(_ persona: AgentPersona) {
        if persona == .tessy { tessyStreamingID = nil } else { skyStreamingID = nil }
        tasks.removeAll { $0.isCancelled }
        // Both done -> clear the pill.
        if tessyStreamingID == nil && skyStreamingID == nil {
            isRunning = false
            statusPill = ""
        } else {
            // Update pill to reflect the remaining agent.
            let still = (tessyStreamingID != nil ? "Tessy" : "") + (skyStreamingID != nil ? "Sky" : "")
            statusPill = "\(still) thinking..."
        }
    }

    private func updateStatus(decision: DualAgentRoutingDecision) {
        if decision.isTeamUp {
            statusPill = "Tessy + Sky huddling..."
        } else if decision.useSky {
            statusPill = "Sky thinking... (cloud)"
        } else {
            statusPill = "Tessy thinking..."
        }
    }

    // MARK: - Collab trace

    public func clearCollabTrace() {
        collabTrace.removeAll()
    }

    /// Seed the trace with a short example so the surface isn't empty on first
    /// open. Mirrors the Linux collab surface's canned Q3 demo.
    public func seedCollabTraceIfNeeded() {
        guard collabTrace.isEmpty else { return }
        collabTrace.append(CollabTraceEntry(
            from: .tessy,
            text: "User asked to summarize Q3 notes and explain the trends. I'll keep the notes local and ask Sky to help reason about the trends."
        ))
        collabTrace.append(CollabTraceEntry(
            from: .sky,
            text: "Got the abstracted trends (no raw notes). Here's the reasoning: revenue up 12%, churn down - momentum is real."
        ))
        collabTrace.append(CollabTraceEntry(
            from: .tessy,
            text: "Thanks Sky. Synthesized for the user - sharing the summary without exposing the raw notes."
        ))
    }
}

/// Union type so the view can present a single approval sheet for whichever
/// engine has a pending request. Mirrors `TesseraApprovalEngine.PendingApproval`.
public struct PendingApprovalUnion: Sendable, Identifiable {
    public let id: UUID
    public let speaker: AgentPersona
    public let toolName: String
    public let arguments: [String: JSONValue]
    public let approve: @Sendable (Bool) -> Void
}
