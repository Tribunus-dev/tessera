import Foundation

/// One row in the unified Tessy + Sky chat transcript. A display envelope
/// that carries the live-streaming fields (from the dual-agent path) AND
/// the optional graph/queue fields (from the per-document queue), so a single
/// transcript can render streaming bubbles, queued items, superseded rows,
/// and receipted turns without a schema migration.
///
/// `speaker` is nil for user rows; assistant rows carry the persona. Both
/// assistants use `ChatRole.assistant`; they are distinguished by `speaker`
/// (matching the existing ``ChatBubbleView`` rendering contract).
public struct UnifiedChatRow: Identifiable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var speaker: AgentPersona?
    public var content: String
    public var isStreaming: Bool
    public var toolCalls: [ToolCallRecord]

    // Graph + queue metadata (optional; nil for simple live turns).

    /// The StateGraph thread id that produced this row.
    public var threadId: String?
    /// The step index within the thread (for time-travel UI).
    public var checkpointStep: Int?
    /// Queue lifecycle state (pending/inProgress/applied/failed).
    public var queueState: QueueState?
    /// Receipt produced by this turn (when the agent produced mutations).
    public var producedReceiptID: UUID?
    /// Set when this row is superseded by a newer one (match-and-supersede).
    public var supersededByID: UUID?

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        speaker: AgentPersona? = nil,
        content: String,
        isStreaming: Bool = false,
        toolCalls: [ToolCallRecord] = [],
        threadId: String? = nil,
        checkpointStep: Int? = nil,
        queueState: QueueState? = nil,
        producedReceiptID: UUID? = nil,
        supersededByID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.speaker = speaker
        self.content = content
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
        self.threadId = threadId
        self.checkpointStep = checkpointStep
        self.queueState = queueState
        self.producedReceiptID = producedReceiptID
        self.supersededByID = supersededByID
    }

    public var isSuperseded: Bool { supersededByID != nil }
}

/// Mirror of ``ChatQueueItem.State`` for the display layer, so the unified
/// transcript can show queue lifecycle without depending on the per-document
/// queue model directly.
public enum QueueState: String, Sendable, Codable {
    case pending
    case inProgress
    case applied
    case failed
}

// MARK: - LiveState (chat-dock progress feed, review #2)
//
// The Progress Feed is a parallel surface to the chat transcript. The
// transcript is the user's prompt-and-reply record; the feed is the
// "what is the agent doing right now" surface. They are deliberately
// disjoint so expanding the feed does not bloat the transcript (the
// chat-default paradox, `references/paradoxes-deep.md:94-105`).
//
// The four (or five) entry kinds are the head of the data the
// controller already holds - the skill's anti-pattern "Long
// agent-authored prose without structural data" lands at exactly the
// shape the feed wants: parsed structural data, not narrative.
//   routing       the router's decision (tessy / sky / both)
//   toolCall      a tool call fired by the agent loop
//   approvalPending  a tool call waiting on the user
//   collabHandoff  one Tessy <-> Sky handoff turn
//   holdQueue     the hold-your-horses queue length
//
// Each entry carries a timestamp + an id so the feed can sort by
// recency and the controller can dedupe across its capture points.
// The entry payload matches the chip vocabulary from the audit-log
// HEAD chip (review #5, item 1C) so the dock and the diff overlay
// speak the same one-line language: `risk: ... | tool: ... | Ns |
// receipt: ...`.

/// One routing decision the controller made for a user message.
public struct LiveRoutingEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let useTessy: Bool
    public let useSky: Bool
    /// The first ~80 chars of the routed prompt, so the feed can
    /// identify the message without dumping the full transcript.
    public let promptSummary: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        useTessy: Bool,
        useSky: Bool,
        promptSummary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.useTessy = useTessy
        self.useSky = useSky
        self.promptSummary = promptSummary
    }

    /// "tessy", "sky", "tessy + sky (team-up)". One word, the chip
    /// vocabulary stays consistent with the audit-log HEAD chip's
    /// `tool: <name>` shape (review #5).
    public var chipLabel: String {
        switch (useTessy, useSky) {
        case (true, true):  return "tessy + sky (team-up)"
        case (true, false): return "tessy only"
        case (false, true): return "sky only"
        case (false, false): return "(unrouted)"
        }
    }

    /// The full chip-string. Mirrors the `risk: | tool: | Ns | receipt:`
    /// pattern from the audit-log HEAD chip; for routing there is no
    /// risk or receipt, so the chip collapses to a single labelled
    /// field plus the prompt summary.
    public var displayString: String {
        "route: \(chipLabel) | prompt: \(promptSummary)"
    }
}

/// One tool call fired by an agent loop. Mirrors ``ToolCallRecord``
/// but the feed needs only the name + a short args summary + the
/// tool's tier label (review #1, item 1B) for chip parity.
public struct LiveToolCallEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let persona: AgentPersona
    public let toolName: String
    public let argumentsSummary: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        persona: AgentPersona,
        toolName: String,
        argumentsSummary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.persona = persona
        self.toolName = toolName
        self.argumentsSummary = argumentsSummary
    }

    public var displayString: String {
        "tool: \(toolName) | persona: \(persona.displayName.lowercased()) | args: \(argumentsSummary)"
    }
}

/// An approval gate waiting on the user. The risk label and the tier
/// label are the chip vocabulary the user already sees on the
/// ``ConfirmationPanel`` (item 1B) and the audit-log HEAD chip
/// (item 1C); the feed reuses them so the surface language is one.
public struct LiveApprovalPendingEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let toolName: String
    public let tierLabel: String
    public let riskLabel: String
    public let reason: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        toolName: String,
        tierLabel: String,
        riskLabel: String,
        reason: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.toolName = toolName
        self.tierLabel = tierLabel
        self.riskLabel = riskLabel
        self.reason = reason
    }

    public var displayString: String {
        "approval: \(toolName) | risk: \(riskLabel) | tier: \(tierLabel) | \(reason)"
    }
}

/// One Tessy <-> Sky handoff turn. Maps to the existing
/// ``CollabTraceEntry`` array on the controller; the feed just
/// re-projects it under its own entry kind so the feed view can
/// render the four state types without depending on the
/// `TesseraDualAgentController` types (which the dock does not use).
public struct LiveCollabHandoffEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let from: AgentPersona
    public let to: AgentPersona
    public let text: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        from: AgentPersona,
        to: AgentPersona,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.text = text
    }

    public var displayString: String {
        "handoff: \(from.displayName.lowercased()) -> \(to.displayName.lowercased()) | \(text)"
    }
}

/// The hold-your-horses queue length + a resume hint. Mirrors the
/// existing ``HoldMode`` + ``pendingPrompts`` on the controller; the
/// feed is the place the user notices "three prompts are queued" and
/// is offered a one-tap resume.
public struct LiveHoldQueueEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let mode: HoldMode
    public let queuedCount: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        mode: HoldMode,
        queuedCount: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.queuedCount = queuedCount
    }

    public var displayString: String {
        if mode.isPaused {
            return "hold: \(mode.rawValue) | queued: \(queuedCount) | resume to drain"
        }
        return "hold: running | queued: 0"
    }
}

/// One entry in the chat-dock progress feed. A tagged union so the
/// feed view switches on the case and the controller can append one
/// per meaningful event without five separate collections.
///
/// New variants are added by extending this enum; the feed view, the
/// capture points on the controller, and the test surface must all
/// be updated together (the test pins the case count).
public enum LiveStateEntry: Sendable, Equatable, Identifiable {
    case routing(LiveRoutingEntry)
    case toolCall(LiveToolCallEntry)
    case approvalPending(LiveApprovalPendingEntry)
    case collabHandoff(LiveCollabHandoffEntry)
    case holdQueue(LiveHoldQueueEntry)

    public var id: UUID {
        switch self {
        case .routing(let e):           return e.id
        case .toolCall(let e):          return e.id
        case .approvalPending(let e):   return e.id
        case .collabHandoff(let e):     return e.id
        case .holdQueue(let e):         return e.id
        }
    }

    public var timestamp: Date {
        switch self {
        case .routing(let e):           return e.timestamp
        case .toolCall(let e):          return e.timestamp
        case .approvalPending(let e):   return e.timestamp
        case .collabHandoff(let e):     return e.timestamp
        case .holdQueue(let e):         return e.timestamp
        }
    }

    /// Short kind label for the section header.
    public var kindLabel: String {
        switch self {
        case .routing:           return "Routing"
        case .toolCall:          return "Tool calls"
        case .approvalPending:   return "Approvals"
        case .collabHandoff:     return "Team-up handoffs"
        case .holdQueue:         return "Hold queue"
        }
    }

    /// The chip-string the feed renders for this entry. Mirrors the
    /// vocabulary from the audit-log HEAD chip (review #5) so the
    /// user reads the same one-line language on both surfaces.
    public var displayString: String {
        switch self {
        case .routing(let e):           return e.displayString
        case .toolCall(let e):          return e.displayString
        case .approvalPending(let e):   return e.displayString
        case .collabHandoff(let e):     return e.displayString
        case .holdQueue(let e):         return e.displayString
        }
    }
}

/// The focused-document signal the unified chat uses to (a) augment the
/// prompt with document context and (b) link receipts onto rows when a turn
/// produces mutations. The dock is global; this context switches as the user
/// navigates between productivity surfaces. Surfaces construct one on focus
/// and pass it to `UnifiedChatController.setDocumentContext(_:)`.
public struct DocumentContext: Sendable {
    public let documentID: UUID
    public let title: String
    /// A closure that renders the document's context into a system-prompt
    /// section (mirrors `AgentContext.asPromptSection`). nil/empty when the
    /// surface doesn't supply one.
    public let promptSection: @Sendable () async -> String
    /// The data layer of the surface that owns this document, so the
    /// controller can build a `DocumentStore` + `ChatPanelStateMachine` for
    /// receipt-linked runs. nil for surfaces without one (then the controller
    /// falls back to prompt augmentation only).
    public let dataLayer: TesseraDataLayer?

    public init(documentID: UUID, title: String, promptSection: @escaping @Sendable () async -> String, dataLayer: TesseraDataLayer? = nil) {
        self.documentID = documentID
        self.title = title
        self.promptSection = promptSection
        self.dataLayer = dataLayer
    }
}
