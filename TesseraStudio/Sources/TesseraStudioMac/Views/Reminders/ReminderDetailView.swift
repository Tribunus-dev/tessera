#if os(macOS)
import SwiftUI
import TesseraCore

// MARK: - ReminderDetailView (macOS)

/// The detail pane for a single reminder. Renders the
/// reminder's metadata, its linked entities (calendar
/// event, task, contacts), and its constitutional receipt
/// chain.
///
/// The view is deliberately read-only on the right pane;
/// mutations happen via the toolbar's buttons (which call
/// the store + scheduler). The receipt chain below the
/// metadata is the audit trail the user can scroll.
public struct ReminderDetailView: View {

    let reminder: Reminder
    let store: any ReminderStoring
    let scheduler: ReminderNotificationScheduler

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var receipts: [GraphReceipt] = []
    @State private var showError: String?
    @State private var notesDocument: DocumentAST
    @State private var isSaving = false
    @State private var lastError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var formattingState = FormattingState()

    public init(
        reminder: Reminder,
        store: any ReminderStoring,
        scheduler: ReminderNotificationScheduler
    ) {
        self.reminder = reminder
        self.store = store
        self.scheduler = scheduler

        let initialText = reminder.notes
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                metadata
                Divider()
                notesEditorSection
                Divider()
                receiptChain
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !reminder.isAcknowledged() {
                    Button {
                        Task {
                            await scheduler.cancel(reminder)
                            _ = try? await store.acknowledge(id: reminder.id)
                        }
                    } label: {
                        Label("Acknowledge", systemImage: "checkmark.circle")
                    }
                    .help("Mark as acknowledged and cancel the notification")
                    .accessibilityLabel("Acknowledge")

                    Menu {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                            Button("\(m) min") { snooze(minutes: m) }
                        }
                    } label: {
                        Label("Snooze", systemImage: "moon.zzz")
                    }
                    .help("Snooze the reminder")
                    .accessibilityLabel("Snooze")
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    Task {
                        await scheduler.cancel(reminder)
                        _ = try? await store.delete(id: reminder.id)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete the reminder")
                .accessibilityLabel("Delete reminder")
            }
        }
        .task {
            await loadReceipts()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive, .background:
                saveTask?.cancel()
                Task { await saveNotes() }
            default:
                break
            }
        }
        .alert("Error",
               isPresented: Binding(
                get: { showError != nil },
                set: { if !$0 { showError = nil } }
               )) {
            Button("OK") { showError = nil }
        } message: {
            Text(showError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "bell")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.title2)
                Text(reminder.displayLine())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(reminder.priority.rawValue.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Trigger", reminder.triggerAt.formatted(date: .abbreviated, time: .shortened))
            row("Offset", reminder.offsetLabel)
            if let snooze = reminder.snoozedUntil {
                row("Snoozed until", snooze.formatted(date: .abbreviated, time: .shortened))
            }
            if let ack = reminder.acknowledgedAt {
                row("Acknowledged", ack.formatted(date: .abbreviated, time: .shortened))
            }
            row("Calendar event", reminder.calendarEventID.uuidString)
        }
    }

    private var notesEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            SurfaceMetadataRow(
                isSaving: isSaving,
                lastError: lastError,
                stats: [
                    (label: "words", value: "\(wordCount)")
                ]
            )

            TesseraEditorView(
                mode: .notes,
                theme: EditorTheme.current(isDark: colorScheme == .dark),
                document: $notesDocument,
                onMutationCommitted: { _, _ in
                    scheduleCommitNotes()
                }
            )
            .frame(minHeight: 100, maxHeight: 200)
        }
    }

    private var wordCount: Int {
        notesDocument.plainText()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private func scheduleCommitNotes() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await saveNotes()
        }
    }

    private func saveNotes() async {
        isSaving = true
        lastError = nil
        var updated = reminder
        updated.notes = notesDocument.plainText()
        do {
            _ = try await store.upsert(updated)
        } catch {
            lastError = String(describing: error)
        }
        isSaving = false
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Receipts

    private var receiptChain: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Receipts")
                .font(.subheadline)
                .fontWeight(.medium)
            if receipts.isEmpty {
                Text("No receipts yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(receipts) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "doc.text")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.receiptType)
                                .font(.caption)
                            Text(r.witnessedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !r.payload.isEmpty {
                                Text(Self.formatPayload(r.payload))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private static func formatPayload(_ payload: [String: JSONValue]) -> String {
        let parts = payload
            .sorted { $0.key < $1.key }
            .map { (k, v) in
                "\(k)=\(v.shortDescription)"
            }
        return parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private func snooze(minutes: Int) {
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        Task {
            do {
                _ = try await store.snooze(id: reminder.id, until: until)
                try await scheduler.snooze(reminder, until: until)
            } catch {
                showError = String(describing: error)
            }
        }
    }

    private func loadReceipts() async {
        do {
            receipts = try await store.receipts(forReminder: reminder.id)
        } catch {
            receipts = []
        }
    }
}
#endif
