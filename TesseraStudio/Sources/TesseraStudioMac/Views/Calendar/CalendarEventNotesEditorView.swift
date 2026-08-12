import SwiftUI
import TesseraCore

// MARK: - CalendarEventNotesEditorView

/// macOS surface wrapper for a calendar event detail pane.
/// Adds a TesseraEditorView-based notes editor to the read-only
/// ``CalendarEventDetailView`` from TesseraCore.
///
/// The editor is in ``.notes`` mode: markdown-ish surface with
/// callout/quote promotion, lighter animation set. All state is
/// local; scene-phase hooks flush pending edits when the app goes
/// to the background.
public struct CalendarEventNotesEditorView: View {

    public let event: CalendarEvent
    public let model: CalendarViewModel
    public let receipts: [GraphReceipt]
    public let links: [EntityLink]
    public let onRespond: (CalendarEvent.ResponseStatus) -> Void
    public let onDelete: () -> Void
    public let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var notesDocument: DocumentAST
    @State private var formattingState = FormattingState()
    @State private var isSaving = false
    @State private var lastError: String?

    /// Debounce gate: cancels the previous save Task if a new
    /// mutation arrives before it fires.
    @State private var saveTask: Task<Void, Never>?

    /// Pre-created coordinator injected into TesseraEditorView so
    /// the toolbar can route view-level commands to it. Nil here
    /// because the calendar surface doesn't expose toolbar commands.
    private var editorCoordinator: TesseraEditorView.Coordinator {
        TesseraEditorView.Coordinator(
            mode: .notes,
            theme: EditorTheme.current(isDark: colorScheme == .dark),
            onMutationCommitted: nil,
            onViewCommand: nil,
            onFormattingStateChanged: nil
        )
    }

    public init(
        event: CalendarEvent,
        model: CalendarViewModel,
        receipts: [GraphReceipt] = [],
        links: [EntityLink] = [],
        onRespond: @escaping (CalendarEvent.ResponseStatus) -> Void = { _ in },
        onDelete: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.event = event
        self.model = model
        self.receipts = receipts
        self.links = links
        self.onRespond = onRespond
        self.onDelete = onDelete
        self.onClose = onClose

        // Initialize the AST from the event's plain-text notes.
        let initialText = event.notes
        let bid = UUID()
        var ast = DocumentAST()
        ast.blocks[bid] = Block(
            id: bid,
            type: .paragraph,
            content: [InlineRun(text: initialText)]
        )
        ast.rootChildren = [bid]
        _notesDocument = State(initialValue: ast)
    }

    public var body: some View {
        VStack(spacing: 0) {
            CalendarEventDetailView(
                event: event,
                receipts: receipts,
                links: links,
                onRespond: onRespond,
                onDelete: onDelete,
                onClose: onClose
            )

            Divider()

            editorSection
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive, .background:
                flushNotes()
            default:
                break
            }
        }
    }

    // MARK: - Editor section

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            editorChrome

            TesseraEditorView(
                mode: .notes,
                theme: EditorTheme.current(isDark: colorScheme == .dark),
                document: $notesDocument,
                onMutationCommitted: { _, _ in
                    scheduleCommitNotes()
                }
            )
            .frame(minHeight: 120, maxHeight: 240)
        }
        .padding()
    }

    private var editorChrome: some View {
        SurfaceMetadataRow(
            isSaving: isSaving,
            lastError: lastError,
            stats: [
                (label: "words", value: "\(wordCount)")
            ]
        )
    }

    private var wordCount: Int {
        notesDocument.plainText()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    // MARK: - Save

    private func scheduleCommitNotes() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await saveNotes()
        }
    }

    private func flushNotes() {
        saveTask?.cancel()
        Task {
            await saveNotes()
        }
    }

    private func saveNotes() async {
        isSaving = true
        lastError = nil
        let text = notesDocument.plainText()
        await model.updateEventNotes(eventID: event.id, notes: text)
        isSaving = false
    }
}
