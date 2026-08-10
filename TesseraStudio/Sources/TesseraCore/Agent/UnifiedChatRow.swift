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
