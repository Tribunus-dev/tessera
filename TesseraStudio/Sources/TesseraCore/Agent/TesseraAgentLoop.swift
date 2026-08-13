import Foundation
import Observation

/// Events emitted by the agent loop during execution.
public enum AgentEvent: Sendable {
    case thinking(String)
    case text(String)
    case toolCall(name: String, arguments: [String: JSONValue])
    case toolResult(name: String, result: ToolResult)
    case error(String)
    case done
}

/// The prefix used in `AgentEvent.error(...)` to signal a hard stop
/// (paradox 5, Microsoft HAX G11). Consumers that want to render a
/// "stopped" confirmation distinct from a generic cancellation can
/// check the prefix. The canonical record of the stop is the loop's
/// `lastStopReason` field; the prefix is just a stream-level marker
/// so consumers that already switch on `.error` can react without
/// depending on a new AgentEvent case (which would ripple into every
/// exhaustive switch in the codebase).
public enum AgentEventMarker {
    public static let stoppedPrefix: String = "[stopped]"
}

// MARK: - PendingMutation (agent-ux-fatigue 4A, review #5)

/// The "WHAT the agent is about to change" payload surfaced at the
/// agent cursor (paradox 1: verification cost; review #5 of the
/// agent-ux-fatigue audit). The cursor overlay renders the payload
/// as a one-line chip next to the agent cursor so the user can see
/// the mutation in place, without navigating to the chat panel or
/// the audit log.
///
/// **Why a struct, not an AgentEvent case.** Adding a new
/// `AgentEvent.pendingMutation` case would force every exhaustive
/// switch in the codebase (ChatGraphBuilder, the chat controller,
/// the chat rows) to grow a new case, with the risk that one is
/// missed and the build breaks. Wave 3C's `AgentEventMarker` shows
/// the same trade-off: stream-level signal lives on the loop
/// instance, the `AgentEvent` surface stays stable. The chip reads
/// the loop's `pendingMutation` property directly; the loop
/// publishes it as a regular `@Observable` mutation so the SwiftUI
/// view re-renders without any new event plumbing.
///
/// **Lifetime.** The payload is non-nil from the moment the loop
/// yields `.toolCall(...)` until the matching `.toolResult(...)`
/// arrives (or the loop terminates for any reason). It is the
/// preview of an in-flight mutation, not a journal of past
/// mutations. Past mutations live in the audit log (Wave 1C's
/// `AuditLogHead` on the diff overlay).
///
/// **Chip vocabulary (review #5, section 4).** The chip renders at
/// most `fieldCap` fields. The vocabulary matches Wave 1C's
/// `AuditLogHead` (`field: value` shape, pipe separator, field
/// cap of 5). The four canonical keys are `tier:`, `risk:`,
/// `tool:`, `outcome:`. A 5th field (`summary:`) is appended
/// when present.
public struct PendingMutation: Sendable, Equatable {

    /// Outcome of the pending mutation from the user's perspective.
    /// `pending` = the agent has announced the call, the gate is
    /// not yet resolved. `approved` = the gate approved (auto- or
    /// user-approval), the tool is running. `blocked` = the safety
    /// policy rejected the call (the mutation will not run).
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        case pending
        case approved
        case blocked

        public var displayLabel: String {
            switch self {
            case .pending:  return "pending"
            case .approved: return "approved"
            case .blocked:  return "blocked"
            }
        }
    }

    /// The risk tier of the action (Wave 1B's `TesseraTier`). Drives
    /// the inline stop button's prominence (Wave 3C) AND the
    /// pending-mutation chip's first field. Tier is the surface
    /// for the blast-radius dimension (reversibility + scope); the
    /// chip shows the tier label so the user can decide whether to
    /// intervene before the tool runs.
    public let tier: TesseraTier
    /// The categorical risk level. Distinct from `tier`: risk is
    /// the rule-based classification (low | medium | high |
    /// forbidden), tier is the surface-facing label that combines
    /// risk with reversibility. Both surface on the chip.
    public let risk: TesseraActionRisk
    /// The tool name (e.g. "file_write", "bash", "calibrate").
    public let tool: String
    /// The structural action class id produced by
    /// `TesseraActionClass.classify(...)` (e.g. "bash:git",
    /// "file_write:src/**"). Distinct from `tool`: the class id
    /// encodes the verb head or path glob, which the tier
    /// computation depends on.
    public let actionClass: String
    /// Where the mutation stands in the gate/execute lifecycle.
    public let outcome: Outcome
    /// Optional one-line human-readable summary of the mutation
    /// (e.g. "rewrite line 42", "drop table foo"). Appended as
    /// the 5th chip field when present.
    public let summary: String?

    /// Hard cap on rendered chip fields. Same value as
    /// `AuditLogHead.fieldCap` (5). The chip is the headline; more
    /// is the article, which lives in the diff overlay's chip and
    /// the audit log.
    public static let fieldCap: Int = 5

    public init(
        tier: TesseraTier,
        risk: TesseraActionRisk,
        tool: String,
        actionClass: String,
        outcome: Outcome = .pending,
        summary: String? = nil
    ) {
        self.tier = tier
        self.risk = risk
        self.tool = tool
        self.actionClass = actionClass
        self.outcome = outcome
        self.summary = summary
    }

    /// One-line chip string. Format mirrors Wave 1C's
    /// `AuditLogHead.displayString`: `field: value` pairs joined
    /// by ` | `. The four canonical fields are
    /// `tier:`/`risk:`/`tool:`/`outcome:`; a 5th `summary:` field
    /// is appended when present. Field count is capped at
    /// `fieldCap` so the chip never becomes a wall of text.
    public var displayString: String {
        var fields: [String] = [
            "tier: \(tier.shortLabel)",
            "risk: \(risk.rawValue)",
            "tool: \(tool)",
            "outcome: \(outcome.displayLabel)",
        ]
        if let summary, !summary.isEmpty {
            fields.append("summary: \(summary)")
        }
        let capped = Array(fields.prefix(Self.fieldCap))
        return capped.joined(separator: " | ")
    }
}

/// Why the agent loop was stopped.
///
/// The agent loop exposes a hard stop (Microsoft HAX G11 "Support
/// efficient dismissal"; paradox 5 of agent-ux-fatigue). The hard
/// stop is a control surface, not a safety hatch: once the user
/// stops the loop, the loop does NOT auto-resume. A new `run()` call
/// is rejected with a clear error until the caller explicitly
/// invokes `clearStop()` (or constructs a new loop).
public enum StopReason {
    /// The user pressed the inline stop button (paradox 5). This is
    /// the load-bearing case; the off-ramp is the trust feature.
    case userRequest
    /// The loop exceeded its time budget without producing a result.
    /// Distinct from a user-initiated stop so the audit log and the
    /// receipt can record a different category.
    case timeout
    /// The loop stopped because of an unrecoverable error. The
    /// original error is preserved so the audit log and the UI can
    /// surface a meaningful message; the loop refuses to resume
    /// because the underlying condition is unknown.
    case error(any Error)

    /// Short, human-readable description of the reason. Stable
    /// across runs; suitable for the audit log, the event stream,
    /// and the inline stop button's confirmation label.
    public var description: String {
        switch self {
        case .userRequest:        return "Stopped by user"
        case .timeout:            return "Timed out"
        case .error(let err):     return "Stopped due to error: \(String(describing: err))"
        }
    }
}

/// The streaming agent loop. Takes a user message, calls the LLM,
/// parses tool calls, executes them via the registry with approval
/// gating, and streams events back to the UI.
@Observable
@MainActor
public final class TesseraAgentLoop {
    private let registry: TesseraToolRegistry
    public let approvalEngine: TesseraApprovalEngine
    private let llmProvider: any LLMProvider
    private let maxIterations: Int
    private let skillLoader: TesseraSkillLoader
    private let permissionProfile: TesseraPermissionProfile
    private let sandboxEnforceable: Bool
    /// Which assistant persona this loop speaks as. Drives the identity
    /// fragment of the system prompt and is forwarded to the UI so bubbles
    /// can be tinted and labeled per persona. Defaults to `.tessy` so the
    /// existing single-agent Playground is unchanged.
    public let persona: AgentPersona

    public private(set) var isRunning = false
    public private(set) var currentTask: Task<Void, Never>?
    public private(set) var tokenBudget: TokenBudget
    /// The most recent in-flight mutation the agent has announced
    /// but not yet completed (Wave 4A, review #5 of the
    /// agent-ux-fatigue audit). Non-nil from the moment the loop
    /// yields `.toolCall(...)` until the matching `.toolResult(...)`
    /// arrives (or the loop terminates for any reason).
    ///
    /// The cursor overlay reads this property to render a
    /// one-line chip next to the agent cursor (paradox 1:
    /// verification cost -- the user sees WHAT the agent is about
    /// to change, not just WHERE). The property is published via
    /// `@Observable` so the SwiftUI view re-renders on every
    /// set/clear. The struct itself is the chip vocabulary
    /// (`tier:`/`risk:`/`tool:`/`outcome:`/`summary:`), matching
    /// Wave 1C's `AuditLogHead` chip shape.
    public private(set) var pendingMutation: PendingMutation?
    /// The reason the loop was last stopped, if any. Non-nil means
    /// the loop is in a HARD-STOP state: a new `run()` call is
    /// rejected with a `.error(...)` event until the caller invokes
    /// `clearStop()`. The agent does not auto-resume.
    ///
    /// This is the anti-metric guard for paradox 5: the
    /// "% of stop-button presses that were followed by an agent
    /// auto-resume" target is ==0. The state lives on the loop
    /// instance (not in the chat controller) so the hard stop is
    /// structural, not a flag the controller can forget to check.
    public private(set) var lastStopReason: StopReason?
    /// Stable id for this loop run; tags approval receipts (autonomy spec 14).
    public let sessionID = UUID().uuidString

    public init(
        registry: TesseraToolRegistry,
        approvalEngine: TesseraApprovalEngine,
        llmProvider: (any LLMProvider)? = nil,
        maxIterations: Int = 10,
        tokenLimit: Int = 8192,
        skillLoader: TesseraSkillLoader? = nil,
        permissionProfile: TesseraPermissionProfile = .standard,
        sandboxEnforceable: Bool? = nil,
        persona: AgentPersona = .tessy
    ) {
        self.registry = registry
        self.approvalEngine = approvalEngine
        // Fallback only when a caller passes nil. ContentView passes a real
        // provider from TesseraLLMProviderFactory.makeFromSettings().
        self.llmProvider = llmProvider ?? PlaceholderLLMProvider()
        self.maxIterations = max(1, maxIterations)
        self.tokenBudget = TokenBudget(used: 0, limit: tokenLimit)
        self.skillLoader = skillLoader ?? TesseraSkillLoader()
        self.permissionProfile = permissionProfile
        self.persona = persona
        // nil -> platform default: sandboxed on iOS (App Store), not on macOS
        // (Developer ID). Only matters once the safety spine's auto-approve path
        // is wired; the reject path it uses today is sandbox-independent.
        #if os(iOS)
        self.sandboxEnforceable = sandboxEnforceable ?? true
        #else
        self.sandboxEnforceable = sandboxEnforceable ?? false
        #endif
    }

    /// Run the agent loop on a user message, returning a stream of events.
    public func run(
        userMessage: String,
        history: [ChatMessage]
    ) -> AsyncStream<AgentEvent> {
        // Hard-stop guard (paradox 5 / Microsoft HAX G11). Once the user
        // has stopped the loop, the loop is in a parked state and refuses
        // to start a new run until the caller explicitly clears the stop.
        // The agent does not auto-resume; this is the structural defense
        // against the off-ramp paradox failure mode (the user has no
        // escape from the agent's actions).
        if let reason = lastStopReason {
            return AsyncStream { continuation in
                let description = "Loop is stopped (\(reason.description)). Call clearStop() to resume."
                // Mark this as a stop signal via the prefix so consumers
                // that already switch on `.error` can render a stop
                // confirmation without depending on a new AgentEvent
                // case (which would ripple into every exhaustive
                // switch in the codebase).
                continuation.yield(.error("\(AgentEventMarker.stoppedPrefix) \(description)"))
                continuation.yield(.done)
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                self.isRunning = true
                defer {
                    self.isRunning = false
                    continuation.finish()
                }

                do {
                    try await self.executeLoop(
                        userMessage: userMessage,
                        history: history,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    // Cancellation here is either a user-initiated stop
                    // (recorded via `lastStopReason` in `stop(reason:)`)
                    // or a sub-task cancellation (e.g. the stream's
                    // onTermination fired when the consumer dropped the
                    // stream). Distinguish the two by prefixing the
                    // error so consumers can render a "stopped"
                    // confirmation distinct from a generic "cancelled"
                    // message. The hard-stop state lives in
                    // `lastStopReason`; the prefix is just a stream-
                    // level marker.
                    self.pendingMutation = nil
                    if let reason = self.lastStopReason {
                        continuation.yield(.error("\(AgentEventMarker.stoppedPrefix) \(reason.description)"))
                    } else {
                        continuation.yield(.error("Cancelled"))
                    }
                } catch {
                    self.pendingMutation = nil
                    continuation.yield(.error(error.localizedDescription))
                }

                continuation.yield(.done)
            }
            self.currentTask = task

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func cancel() {
        currentTask?.cancel()
    }

    /// Hard-stop the agent loop (paradox 5, Microsoft HAX G11 "Support
    /// efficient dismissal"). Cancels the running task (which propagates
    /// cancellation into every awaited sub-task: the LLM stream, the
    /// tool execution, the approval prompt), records the reason on the
    /// loop instance, and signals the stop into the active stream via
    /// the `AgentEventMarker.stoppedPrefix` marker on the `.error` event.
    ///
    /// Hard-stop semantics: the agent does NOT auto-resume. A new
    /// `run()` call is rejected with a `.error(...)` event until the
    /// caller invokes `clearStop()`. The off-ramp is a control surface,
    /// not a safety hatch.
    ///
    /// Calling `stop` on a loop that is not running is a no-op (the
    /// loop is already in a stopped-or-idle state); the reason is still
    /// recorded so subsequent `run()` calls refuse to start.
    public func stop(reason: StopReason) {
        // Record the reason FIRST so the loop is in a hard-stop state
        // even if the cancellation races with the loop's own termination
        // path. The order matters: a stop signal must be observable on
        // the active stream BEFORE `isRunning` flips back to false, so
        // the user sees a "stopped" confirmation rather than a silent
        // disappearance. The signal is delivered as a prefixed
        // `.error(...)` event from the cancellation handler in `run`,
        // which checks `lastStopReason` to choose the prefix.
        lastStopReason = reason
        currentTask?.cancel()
    }

    /// Clear the hard-stop state. Required before a new `run()` call
    /// is accepted after `stop(reason:)` was invoked. The caller is
    /// the only party that can resume the agent; this is the second
    /// half of the thermostat-on-a-schedule metaphor (paradox 5):
    /// "a manual nudge holds until the next scheduled slot" -- the
    /// next slot is a user-initiated `clearStop()`.
    public func clearStop() {
        lastStopReason = nil
    }

    /// Exposed for the dual-agent controller, which drives the provider's
    /// `stream(...)` directly for token-granular bubbles while still using the
    /// loop's system-prompt + tool-descriptor construction so the streamed text
    /// matches the loop's framing.
    public func systemPrompt(for userMessage: String) -> String {
        buildSystemPrompt(userMessage: userMessage)
    }

    /// The provider the loop was constructed with. The dual-agent controller
    /// calls `stream(...)` on it for the visible text path.
    public var llmProviderForStreaming: any LLMProvider { llmProvider }

    /// Tool descriptors the loop registers, for the streaming call.
    public var toolDescriptors: [ToolDescriptor] {
        registry.allTools.map { ToolDescriptor(name: $0.name, description: $0.description, parameters: $0.parameters) }
    }

    // MARK: - Private

    private func executeLoop(
        userMessage: String,
        history: [ChatMessage],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws {
        // Publish the live session id so a YOLO session started from the UI
        // can bind to this loop (autonomy-calibration-design.md 10).
        approvalEngine.autonomy.setActiveSession(sessionID)
        let systemPrompt = buildSystemPrompt(userMessage: userMessage)
        var messages = history.map { LLMMessage(role: $0.role.rawValue, content: $0.content) }
        messages.append(LLMMessage(role: "user", content: userMessage))
        let tools = registry.allTools.map { ToolDescriptor(name: $0.name, description: $0.description, parameters: $0.parameters) }

        var iterations = 0

        while iterations < maxIterations {
            iterations += 1

            guard !Task.isCancelled else { throw CancellationError() }

            continuation.yield(.thinking("Calling model..."))

            // Stream the model response token-by-token. The stream emits
            // `.text` deltas as they arrive (forwarded live to the UI),
            // `.toolCalls` once all calls are assembled, then `.done`. This
            // unifies the agentic loop with the streaming display path: the
            // loop now streams while still dispatching tools + approvals.
            var content = ""
            var toolCalls: [LLMToolCall] = []
            let stream = try await llmProvider.stream(system: systemPrompt, messages: messages, tools: tools)
            for await chunk in stream {
                switch chunk {
                case .text(let delta):
                    content += delta
                    continuation.yield(.text(delta))
                case .toolCalls(let calls):
                    toolCalls = calls
                case .done:
                    break
                }
            }
            tokenBudget.used += content.count / 4

            // Echo the assistant turn into messages so multi-turn reasoning
            // carries forward (previously only role:"tool" entries were
            // appended, breaking continuity across tool-use turns).
            if !content.isEmpty {
                messages.append(LLMMessage(role: "assistant", content: content))
            }

            // No tool calls -> done
            guard !toolCalls.isEmpty else { break }

            // Execute each tool call
            for call in toolCalls {
                guard !Task.isCancelled else { throw CancellationError() }

                // Publish the pending-mutation preview (Wave 4A).
                // The chip vocabulary (tier/risk/tool/outcome) is
                // populated here, before the gate check resolves, so
                // the user sees the preview during the approval
                // prompt (the highest-value window: the user is
                // about to approve something). The cursor overlay
                // observes this property via `@Observable` and
                // re-renders the chip.
                let actionClass = TesseraActionClass.classify(
                    PendingAction(toolName: call.name, arguments: call.arguments)
                )
                let pendingRisk = (try? TesseraActionVerifier.ruleBasedRisk(
                    for: PendingAction(toolName: call.name, arguments: call.arguments)
                )) ?? .medium
                let pendingTier = TesseraTier.tier(
                    for: actionClass,
                    risk: pendingRisk
                )
                self.pendingMutation = PendingMutation(
                    tier: pendingTier,
                    risk: pendingRisk,
                    tool: call.name,
                    actionClass: actionClass,
                    outcome: .pending
                )

                continuation.yield(.toolCall(name: call.name, arguments: call.arguments))

                // Autonomy-aware gate (autonomy-calibration-design.md 7):
                // the base safety spine (S2/S3/S4) plus the learned-permission
                // ratchet (steps 4, 6). Three outcomes:
                //   reject     -> never run; recorded in the breaker.
                //   askUser    -> force a prompt; a user denial feeds the
                //                 breaker and revokes the class (ratchet).
                //   autoApprove-> run without prompting (base or learned).
                // Every outcome is receipt-logged (section 14).
                let action = PendingAction(toolName: call.name, arguments: call.arguments)
                let gate = approvalEngine.gateCheck(
                    for: action,
                    permissionProfile: permissionProfile,
                    sandboxEnforceable: sandboxEnforceable,
                    sessionID: sessionID
                )
                switch gate.check {
                case .reject:
                    approvalEngine.recordOutcome(
                        action: action,
                        risk: (try? TesseraActionVerifier.ruleBasedRisk(for: action)) ?? .medium,
                        sandboxed: sandboxEnforceable,
                        decision: .reject,
                        userChoice: .none,
                        source: gate.source,
                        sessionID: sessionID
                    )
                    // The mutation will not run; mark it blocked so
                    // the cursor chip's `outcome` field flips from
                    // `pending` to `blocked` in the same view tick
                    // the user sees the failure. The chip is cleared
                    // after the toolResult is yielded below.
                    self.pendingMutation = self.pendingMutation.map {
                        PendingMutation(
                            tier: $0.tier,
                            risk: $0.risk,
                            tool: $0.tool,
                            actionClass: $0.actionClass,
                            outcome: .blocked,
                            summary: $0.summary
                        )
                    }
                    let blocked = ToolResult.fail("Blocked by the safety policy before execution.")
                    continuation.yield(.toolResult(name: call.name, result: blocked))
                    self.pendingMutation = nil
                    messages.append(LLMMessage(role: "tool", content: "Tool '\(call.name)' was blocked by the safety policy."))
                    if approvalEngine.circuitBreaker.isTripped {
                        continuation.yield(.error("Interrupted: the denial circuit-breaker tripped (too many blocked actions)."))
                        return
                    }
                    continue
                case .askUser:
                    let approved = await approvalEngine.requestApprovalForced(
                        toolName: call.name,
                        arguments: call.arguments
                    )
                    let risk = (try? TesseraActionVerifier.ruleBasedRisk(for: action)) ?? .medium
                    approvalEngine.recordOutcome(
                        action: action,
                        risk: risk,
                        sandboxed: sandboxEnforceable,
                        decision: .askUser,
                        userChoice: approved ? .approved : .denied,
                        source: gate.source,
                        sessionID: sessionID
                    )
                    guard approved else {
                        approvalEngine.circuitBreaker.record(denied: true)
                        let denied = ToolResult.fail("Denied by user")
                        continuation.yield(.toolResult(name: call.name, result: denied))
                        self.pendingMutation = nil
                        messages.append(LLMMessage(role: "tool", content: "Tool '\(call.name)' was denied by the user."))
                        if approvalEngine.circuitBreaker.isTripped {
                            continuation.yield(.error("Interrupted: the denial circuit-breaker tripped (too many denied actions)."))
                            return
                        }
                        continue
                    }
                    // User approved the action. Flip the chip to
                    // `approved` so the user sees the gate resolve
                    // in place.
                    self.pendingMutation = self.pendingMutation.map {
                        PendingMutation(
                            tier: $0.tier,
                            risk: $0.risk,
                            tool: $0.tool,
                            actionClass: $0.actionClass,
                            outcome: .approved,
                            summary: $0.summary
                        )
                    }
                case .autoApprove:
                    approvalEngine.recordOutcome(
                        action: action,
                        risk: (try? TesseraActionVerifier.ruleBasedRisk(for: action)) ?? .medium,
                        sandboxed: sandboxEnforceable,
                        decision: .autoApprove,
                        userChoice: .none,
                        source: gate.source,
                        sessionID: sessionID
                    )
                    // Auto-approved; flip the chip to `approved`
                    // so the user sees the gate resolve.
                    self.pendingMutation = self.pendingMutation.map {
                        PendingMutation(
                            tier: $0.tier,
                            risk: $0.risk,
                            tool: $0.tool,
                            actionClass: $0.actionClass,
                            outcome: .approved,
                            summary: $0.summary
                        )
                    }
                }

                // Execute
                let result: ToolResult
                if let tool = registry.tool(named: call.name) {
                    do {
                        result = try await tool.execute(arguments: call.arguments)
                    } catch {
                        result = .fail(error.localizedDescription)
                    }
                } else {
                    result = .fail("Unknown tool: \(call.name)")
                }

                continuation.yield(.toolResult(name: call.name, result: result))
                // Mutation has completed (or failed); the cursor chip
                // hides until the next tool call announces a new
                // mutation. Past mutations live in the audit log;
                // the chip is a preview, not a journal.
                self.pendingMutation = nil
                // Forward the tool's output (string) + structured data (when
                // present) back to the model so rich tool results survive.
                var toolContent = result.output
                if let data = result.data, !data.isEmpty,
                   let jsonData = try? JSONSerialization.data(withJSONObject: data.mapValues { $0.toAny() }, options: [.sortedKeys]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    toolContent += "\n" + jsonString
                }
                messages.append(LLMMessage(role: "tool", content: toolContent))
            }
        }
    }

    private func buildSystemPrompt(userMessage: String) -> String {
        // Lead with the persona identity (privacy boundary + name), then the
        // studio tool/skill context. For the default `.tessy` persona this
        // preserves the original single-agent framing; for `.sky` it gives the
        // cloud intellect its own boundary.
        var prompt = """
        \(persona.systemPromptFragment)

        You are an assistant for quantizing, calibrating, and deploying LLMs
        with the Tessera engine. You help users manage models, run calibration,
        evolve quantization policies, and evaluate results.

        \(registry.systemPromptToolsBlock())
        """
        // On-demand skills (absorption I1): inject any skill whose manifest
        // matches the user's message. Empty until the user authors skills.
        let skills = skillLoader.systemPromptFragment(for: userMessage)
        if !skills.isEmpty {
            prompt += "\n\n# Relevant skills\n\n" + skills
        }
        return prompt
    }
}

// MARK: - Token Budget

public struct TokenBudget: Sendable {
    public var used: Int
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    public var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(Double(used) / Double(limit), 1.0)
    }

    public var remaining: Int { max(limit - used, 0) }
}

// MARK: - LLM Provider Protocol

public struct LLMMessage: Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct LLMToolCall: Sendable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct LLMResponse: Sendable {
    public let content: String
    public let toolCalls: [LLMToolCall]
    public let tokenCount: Int

    public init(content: String, toolCalls: [LLMToolCall], tokenCount: Int) {
        self.content = content
        self.toolCalls = toolCalls
        self.tokenCount = tokenCount
    }
}

/// One incremental piece of a streamed model response. Providers that can
/// stream token-by-token emit a sequence of `.text` chunks; tool calls are
/// assembled across deltas and emitted as a single `.toolCalls` chunk (since
/// a call must be fully assembled before it can be dispatched). The stream
/// ends with `.done`. Providers that can only return a whole response rely
/// on the protocol extension default, which yields the content + tool calls
/// at once.
public enum LLMChunk: Sendable {
    case text(String)
    case toolCalls([LLMToolCall])
    case done
}

public protocol LLMProvider: Sendable {
    /// Whole-response completion. Used by the default `stream()` and as a
    /// fallback for providers whose streaming is unreliable.
    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDescriptor]
    ) async throws -> LLMResponse

    /// Token-granular streaming of a single completion. Yields `.text` per
    /// delta, `.toolCalls` once all calls are assembled, and ends with
    /// `.done`. The default implementation wraps `complete`, so conformers
    /// that have no native streaming still work.
    func stream(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDescriptor]
    ) async throws -> AsyncStream<LLMChunk>
}

extension LLMProvider {
    /// Default streaming: complete() once, emit the full content and the
    /// assembled tool calls, then finish. Providers with native SSE/token
    /// streaming override this to emit text deltas as they arrive.
    public func stream(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDescriptor]
    ) async throws -> AsyncStream<LLMChunk> {
        AsyncStream { continuation in
            let provider = self
            let task = Task {
                do {
                    let response = try await provider.complete(system: system, messages: messages, tools: tools)
                    if !response.content.isEmpty {
                        continuation.yield(.text(response.content))
                    }
                    if !response.toolCalls.isEmpty {
                        continuation.yield(.toolCalls(response.toolCalls))
                    }
                    continuation.yield(.done)
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Last-resort LLM that echoes the user message and recognizes a few tool
/// keywords. The factory (TesseraLLMProviderFactory.makeFromSettings) upgrades
/// to the on-device provider as soon as a model is available, so this is only
/// reached when the library is genuinely empty - it keeps the app responsive
/// instead of crashing on a missing model.
public struct PlaceholderLLMProvider: LLMProvider {
    public init() {}

    public func complete(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDescriptor]
    ) async throws -> LLMResponse {
        guard let last = messages.last else {
            return LLMResponse(content: "No input.", toolCalls: [], tokenCount: 0)
        }

        // Simple keyword-based tool dispatch for demonstration
        let lower = last.content.lowercased()
        if lower.contains("list") && lower.contains("model") {
            return LLMResponse(
                content: "",
                toolCalls: [LLMToolCall(name: "list_models", arguments: [:])],
                tokenCount: 25
            )
        }
        if lower.contains("inspect") || lower.contains("sidecar") {
            let path = extractPath(from: last.content) ?? ""
            return LLMResponse(
                content: "",
                toolCalls: [LLMToolCall(name: "inspect_sidecar", arguments: ["path": .string(path)])],
                tokenCount: 30
            )
        }
        if lower.contains("quantize") {
            return LLMResponse(
                content: "",
                toolCalls: [LLMToolCall(name: "quantize", arguments: [
                    "model_path": .string(extractPath(from: last.content) ?? ""),
                    "output_path": .string(""),
                    "policy_path": .string(""),
                ])],
                tokenCount: 35
            )
        }

        let reply = "I'm the Tessera Studio agent (placeholder). You said: \"\(last.content)\". " +
            "In production, this connects to a local or remote LLM. " +
            "Try asking me to list models, inspect a sidecar, or quantize a model."
        return LLMResponse(content: reply, toolCalls: [], tokenCount: reply.count / 4)
    }

    /// Word-by-word streaming so the dual-agent surface looks alive even
    /// without a configured provider. Mirrors the Linux PlaceholderProvider's
    /// 16-byte chunk cadence.
    public func stream(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDescriptor]
    ) async throws -> AsyncStream<LLMChunk> {
        AsyncStream { continuation in
            let task = Task {
                // Tool-call turns have nothing to stream; route through
                // complete() so the tool keyword dispatch still fires.
                if let last = messages.last {
                    let lower = last.content.lowercased()
                    let wantsTool = (lower.contains("list") && lower.contains("model"))
                        || lower.contains("inspect") || lower.contains("sidecar")
                        || lower.contains("quantize")
                    if wantsTool {
                        let response = try? await self.complete(system: system, messages: messages, tools: tools)
                        if let response, !response.content.isEmpty {
                            continuation.yield(.text(response.content))
                        }
                        continuation.yield(.done)
                        return
                    }
                }
                let response = (try? await self.complete(system: system, messages: messages, tools: tools))
                    ?? LLMResponse(content: "", toolCalls: [], tokenCount: 0)
                // Stream the placeholder reply word by word with a small delay
                // so two concurrent placeholder bubbles interleave visibly.
                let words = response.content.split(separator: " ")
                for (i, word) in words.enumerated() {
                    if Task.isCancelled { break }
                    let piece = (i == 0 ? "" : " ") + String(word)
                    continuation.yield(.text(piece))
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                continuation.yield(.done)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func extractPath(from text: String) -> String? {
        let words = text.split(separator: " ")
        return words.first { $0.contains("/") || $0.hasSuffix(".gguf") || $0.hasSuffix(".json") }
            .map(String.init)
    }
}
