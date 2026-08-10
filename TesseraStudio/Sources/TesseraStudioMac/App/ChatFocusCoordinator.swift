import SwiftUI
import TesseraCore

/// The single source of truth for what the user is currently focused on, so
/// the persistent Tessy + Sky chat dock can augment its prompts with that
/// context and (for document surfaces) route agent mutations through the
/// per-document queue.
///
/// Constructed once per window in `ContentView` alongside the
/// `UnifiedChatController`, injected into each productivity surface, and
/// observed by the controller. Surfaces write to it when their focus changes
/// (an `.onChange(of: selectedID)`); the controller reads
/// `focusedDocumentContext` to augment the prompt.
///
/// Decoupled from `UnifiedChatController` so surfaces depend on a narrow,
/// testable contract rather than the whole chat controller, and so the
/// focus state is observable by anything else that needs it (future HUD,
/// status bar, receipts drawer).
@MainActor
@Observable
public final class ChatFocusCoordinator {
    /// The focused document context, or nil when no document surface is
    /// focused. The controller prepends `promptSection()` to the routed
    /// prompt. Set by document surfaces (Notes/Docs/Sheets/Slides) on focus.
    public var focusedDocumentContext: DocumentContext?

    /// A plain-text focus hint for non-document surfaces (Tasks, Email,
    /// Calendar, Contacts, Reminders). Used for prompt augmentation only;
    /// the per-document queue/receipt machinery does not apply. Example:
    /// "The user is looking at task: Buy milk (due Friday)".
    public var focusHint: String?

    /// The entity id backing the current focus (document id for document
    /// surfaces, the focused item id for non-document surfaces). Nil when no
    /// surface is focused.
    public var focusedEntityID: UUID?

    /// The TesseraDataLayer available to the focused surface, so the
    /// controller can construct a `DocumentStore` + `ChatPanelStateMachine`
    /// for receipt-linked runs. Set by surfaces whose bootstrap owns one.
    public var dataLayer: TesseraDataLayer?

    public init() {}

    /// Clear focus. Called on navigation away (when a surface's onDisappear
    /// fires, or when a non-document surface becomes focused).
    public func clear() {
        focusedDocumentContext = nil
        focusHint = nil
        focusedEntityID = nil
    }

    /// Focus a document surface. Builds a `DocumentContext` and records the
    /// entity id + data layer.
    public func focusDocument(
        id: UUID,
        title: String,
        dataLayer: TesseraDataLayer?,
        promptSection: @escaping @Sendable () async -> String
    ) {
        focusedEntityID = id
        self.dataLayer = dataLayer
        focusHint = nil
        focusedDocumentContext = DocumentContext(
            documentID: id, title: title, promptSection: promptSection, dataLayer: dataLayer)
    }

    /// Focus a non-document surface (prompt augmentation only).
    public func focusEntity(id: UUID, hint: String) {
        focusedDocumentContext = nil
        focusedEntityID = id
        dataLayer = nil
        focusHint = hint
    }
}
