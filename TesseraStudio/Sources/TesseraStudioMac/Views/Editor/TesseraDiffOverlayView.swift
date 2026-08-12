import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - DiffSegment

/// A single segment of a diff between original and rewritten text.
public enum DiffSegment: Identifiable, Sendable {
    case unchanged(String)
    case added(String)
    case deleted(String)

    public var id: String {
        switch self {
        case .unchanged(let s): return "u-\(s)"
        case .added(let s):     return "a-\(s)"
        case .deleted(let s):   return "d-\(s)"
        }
    }

    public var text: String {
        switch self {
        case .unchanged(let s): return s
        case .added(let s):     return s
        case .deleted(let s):   return s
        }
    }
}

// MARK: - DiffOverlayState

/// State for one active streaming diff session.
@MainActor
public enum DiffOverlayState: Sendable {
    case idle
    case streaming(originalRange: NSRange, partialText: String, segments: [DiffSegment])
    case diffComplete(originalRange: NSRange, originalText: String, rewrittenText: String, segments: [DiffSegment])
    case editable(originalRange: NSRange, originalText: String, currentText: String, segments: [DiffSegment])
}

// MARK: - TesseraDiffOverlayView

/// The SwiftUI view that renders a streaming diff overlay in the editor.
///
/// This view is embedded in an NSHostingView positioned over the selected text
/// rect by TesseraStreamingDiffView. It shows:
/// - Original text: normal styling
/// - Streaming rewrite: green for additions, red strikethrough for deletions
/// - Accept / Reject / Edit controls at the bottom
@MainActor
public struct TesseraDiffOverlayView: View {
    @Binding public var state: DiffOverlayState
    public let mode: RewriteMode
    public let onAccept: () -> Void
    public let onReject: () -> Void

    public init(
        state: Binding<DiffOverlayState>,
        mode: RewriteMode,
        onAccept: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        self._state = state
        self.mode = mode
        self.onAccept = onAccept
        self.onReject = onReject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            diffTextView
                .frame(minHeight: 60)

            controlBar
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.98))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var diffTextView: some View {
        switch state {
        case .idle:
            EmptyView()

        case .streaming(_, let partialText, let segments),
             .diffComplete(_, _, let partialText, let segments),
             .editable(_, _, let partialText, let segments):
            diffSegmentsView(segments: segments)
        }
    }

    @ViewBuilder
    private func diffSegmentsView(segments: [DiffSegment]) -> some View {
        Text(segments.map { segment -> AttributedString in
            var attr = AttributedString(segment.text)
            switch segment {
            case .unchanged:
                attr.foregroundColor = .primary
            case .added:
                attr.foregroundColor = Color.green
                attr.backgroundColor = Color.green.opacity(0.1)
            case .deleted:
                attr.foregroundColor = Color.red
                attr.strikethroughStyle = .single
                attr.backgroundColor = Color.red.opacity(0.1)
            }
            return attr
        }.joined())
        .font(.system(.body, design: .monospaced))
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            statusLabel

            Spacer()

            switch state {
            case .idle:
                EmptyView()

            case .streaming:
                Button("Cancel") { onReject() }
                    .buttonStyle(.bordered)

            case .diffComplete, .editable:
                Button("Reject") { onReject() }
                    .buttonStyle(.bordered)
                Button("Accept") { onAccept() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state {
        case .idle:
            EmptyView()
        case .streaming:
            Label("Rewriting...", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .diffComplete:
            Label("Rewrite complete", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .editable:
            Label("Edit to refine", systemImage: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
