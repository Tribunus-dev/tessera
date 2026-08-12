import SwiftUI
import TesseraCore

// MARK: - CommentsSidebarView

/// The review panel showing comment threads and track changes.
/// Shown as a sheet on iOS / as a side popover on macOS.
/// The host passes the document AST so the sidebar stays reactive.
public struct CommentsSidebarView: View {
    @Binding var document: DocumentAST
    public let trackChangesEnabled: Bool
    public let onInsertComment: () -> Void
    public let onNavigateToComment: (UUID) -> Void
    public let onAcceptChange: (UUID) -> Void
    public let onRejectChange: (UUID) -> Void
    public let onResolveComment: (UUID) -> Void
    public let onDismiss: () -> Void

    @State private var selectedThreadID: UUID?
    @State private var replyText: String = ""
    @State private var showResolved: Bool = false

    public init(
        document: Binding<DocumentAST>,
        trackChangesEnabled: Bool,
        onInsertComment: @escaping () -> Void,
        onNavigateToComment: @escaping (UUID) -> Void,
        onAcceptChange: @escaping (UUID) -> Void,
        onRejectChange: @escaping (UUID) -> Void,
        onResolveComment: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self._document = document
        self.trackChangesEnabled = trackChangesEnabled
        self.onInsertComment = onInsertComment
        self.onNavigateToComment = onNavigateToComment
        self.onAcceptChange = onAcceptChange
        self.onRejectChange = onRejectChange
        self.onResolveComment = onResolveComment
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !threads.isEmpty {
                        commentThreadsSection
                    }
                    if !trackChanges.isEmpty {
                        trackChangesSection
                    }
                    if threads.isEmpty && trackChanges.isEmpty {
                        emptyState
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400, minHeight: 300, maxHeight: .infinity)
    }

    // MARK: - Data

    private var threads: [CommentThread] {
        CommentStore.threads(from: document, includeResolved: showResolved)
    }

    private var trackChanges: [TrackChange] {
        TrackChange.from(document: document)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Label("Review", systemImage: "text.badge.checkmark")
                .font(.headline)
            Spacer()
            Toggle("Show resolved", isOn: $showResolved)
                .controlSize(.small)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Show resolved comments")
            Button {
                onInsertComment()
            } label: {
                Label("New", systemImage: "plus.message")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add a comment")
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close review panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Comment threads

    private var commentThreadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comments")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("\(threads.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.quaternarySystemFill))
                    .cornerRadius(4)
                Spacer()
            }

            ForEach(threads) { thread in
                CommentThreadCard(
                    thread: thread,
                    isSelected: selectedThreadID == thread.id,
                    onSelect: { selectedThreadID = thread.id },
                    onNavigate: { onNavigateToComment(thread.id) },
                    onResolve: { onResolveComment(thread.id) },
                    onReply: { replyText = ""; selectedThreadID = thread.id }
                )
            }
        }
    }

    // MARK: - Track changes

    private var trackChangesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Track Changes")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if !trackChangesEnabled {
                    Text("Off")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
            }

            ForEach(trackChanges) { change in
                TrackChangeCard(
                    change: change,
                    onAccept: { onAcceptChange(change.id) },
                    onReject: { onRejectChange(change.id) }
                )
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No comments or changes")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Click 'New' to add a comment. Track Changes is \(trackChangesEnabled ? "on" : "off").")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - CommentThreadCard

private struct CommentThreadCard: View {
    let thread: CommentThread
    let isSelected: Bool
    let onSelect: () -> Void
    let onNavigate: () -> Void
    let onResolve: () -> Void
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Text(String(thread.author.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.author)
                        .font(.system(size: 11, weight: .semibold))
                    Text(thread.createdAt, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if thread.isResolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            if isSelected {
                // Expanded: show all messages
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(thread.messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(message.author)
                                    .font(.system(size: 10, weight: .semibold))
                                Spacer()
                                Text(message.createdAt, style: .time)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Text(message.text)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    // Action buttons
                    HStack {
                        Button("Go to", action: onNavigate)
                            .controlSize(.small)
                        Button("Reply", action: onReply)
                            .controlSize(.small)
                        Spacer()
                        if !thread.isResolved {
                            Button("Resolve", action: onResolve)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                // Collapsed: preview first message
                Text(thread.messages.first?.text ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - TrackChangeCard

private struct TrackChangeCard: View {
    let change: TrackChange
    let onAccept: () -> Void
    let onReject: () -> Void

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: change.createdAt)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: change.type == .insertion ? "plus.circle.fill" : "minus.circle.fill")
                .foregroundStyle(change.type == .insertion ? .green : .red)
                .font(.system(size: 14))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(change.author)
                        .font(.system(size: 11, weight: .semibold))
                    Text(dateString)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(change.text)
                    .font(.system(size: 12))
                    .strikethrough(change.type == .deletion)
                    .foregroundStyle(change.type == .deletion ? .red : .primary)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(
                        change.type == .insertion
                            ? Color.green.opacity(0.08)
                            : Color.red.opacity(0.08)
                    )
                    .cornerRadius(4)

                HStack {
                    Button("Accept", action: onAccept)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("Reject", action: onReject)
                        .controlSize(.small)
                        .tint(.red)
                }
            }
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}
