import SwiftUI

// ChatProgressFeed (review #2 of the agent-ux-fatigue Tessera Studio
// audit). Pull-to-open progress feed for the chat dock. Renders the
// live state already on `UnifiedChatController` (routing, tool
// calls, approval gates, hold queue, collab trace) without
// modifying the chat thread itself.
//
// **Pull, not push.** Nothing on the controller posts a
// notification, opens a sheet, or otherwise auto-surfaces the
// feed. The host view binds an `isPresented` binding; the binding
// is the single pull surface. The chat thread stays the user's
// prompt-and-reply record; the feed is the "what is the agent
// doing right now" surface (paradox 3, `references/paradoxes-deep.md:94-105`).
//
// **Chip vocabulary.** Each entry renders as a one-line chip with
// the same `field: value | field: value` shape the audit-log HEAD
// chip uses (review #5, `AuditLogHead.displayString`). The user
// reads one chip language on both surfaces, so the verification
// cost is shared between the dock and the diff overlay.
//
// **Latency budget.** The feed reads the controller's `liveState`
// directly; the @Observable projection is one observation tick.
// The P95 budget (<500ms) is asserted by
// `ChatProgressFeedTests.testSurfaceUpdateLatency` against the
// controller's append path.

// MARK: - ChatProgressFeed

/// The SwiftUI view that renders the progress feed.
///
/// The view is intentionally simple: a `List` of `LiveStateEntry`
/// rows, one per recent event, with a compact summary at the top.
/// The host view decides the *pull* trigger (a button in the dock
/// header, a swipe-down gesture, a menu item) and binds the
/// `isPresented` state.
///
/// - Parameters:
///   - controller: the chat controller. The view reads
///     ``UnifiedChatController/liveState`` and observes
///     the controller via @Observable.
///   - isPresented: the pull binding. The view never flips it
///     itself; the host is the only authority.
///   - compact: when true, the view renders each entry as a
///     single chip line. When false, entries render with their
///     kind label + timestamp. Default is true so the dock's
///     default sheet size stays scannable.
public struct ChatProgressFeed: View {
    @Bindable public var controller: UnifiedChatController
    @Binding public var isPresented: Bool
    public let compact: Bool

    public init(
        controller: UnifiedChatController,
        isPresented: Binding<Bool>,
        compact: Bool = true
    ) {
        self._controller = Bindable(controller)
        self._isPresented = isPresented
        self.compact = compact
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if controller.liveState.isEmpty {
                emptyState
            } else {
                feedList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityLabel("Agent progress feed")
        .accessibilityHint("Pull surface: shows the agent's routing, tool calls, approval gates, hold queue, and team-up handoffs.")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent activity")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close progress feed")
            .accessibilityHint("Closes the agent activity feed. Nothing was changed.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var subtitle: String {
        let count = controller.liveState.count
        if count == 0 { return "No activity yet" }
        if count == 1 { return "1 event (pull surface, no auto-push)" }
        return "\(count) events (pull surface, no auto-push)"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing in flight")
                .font(.callout.bold())
            Text("Routing decisions, tool calls, approval gates, hold-queue changes, and team-up handoffs will show up here as the agent runs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        // Newest first. The controller appends to the tail; reversing
        // at render time keeps the capture path single-sourced.
        let entries = controller.liveState.reversed()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries)) { entry in
                    if compact {
                        ChatProgressFeedRow(entry: entry)
                    } else {
                        ChatProgressFeedRowExpanded(entry: entry)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - ChatProgressFeedRow

/// One row in the feed. A one-line chip with the same field
/// vocabulary as the audit-log HEAD chip (review #5). The chip is
/// non-interactive: tapping it does nothing. The chat thread is the
/// write surface; the feed is read-only.
public struct ChatProgressFeedRow: View {
    public let entry: LiveStateEntry

    public init(entry: LiveStateEntry) {
        self.entry = entry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(entry.tint)
                .font(.caption)
                .frame(width: 16)
            Text(entry.displayString)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(entry.tint.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kindLabel). \(entry.displayString)")
    }
}

// MARK: - ChatProgressFeedRowExpanded

/// The expanded variant: kind label + timestamp + the chip line.
/// Used when the host binds `compact: false`.
public struct ChatProgressFeedRowExpanded: View {
    public let entry: LiveStateEntry

    public init(entry: LiveStateEntry) {
        self.entry = entry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.kindLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(entry.tint)
                Spacer()
                Text(entry.timestampLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ChatProgressFeedRow(entry: entry)
        }
    }
}

// MARK: - LiveStateEntry + ChatProgressFeed display helpers

extension LiveStateEntry {
    /// SF Symbol per entry kind. Picked so the kind reads at a
    /// glance: arrow.triangle.branch for routing, terminal for tool
    /// calls, shield for approvals, arrow.left.arrow.right for
    /// handoffs, pause.circle for the hold queue.
    fileprivate var symbolName: String {
        switch self {
        case .routing:           return "arrow.triangle.branch"
        case .toolCall:          return "terminal"
        case .approvalPending:   return "shield.lefthalf.filled"
        case .collabHandoff:     return "arrow.left.arrow.right"
        case .holdQueue:         return "pause.circle"
        }
    }

    /// Tint per entry kind. Mirrors the audit-log HEAD chip's
    /// `risk`-keyed tint vocabulary (low/medium/high) where it
    /// applies; routing + hold use neutral, handoffs use the
    /// receiving persona's tint.
    fileprivate var tint: Color {
        switch self {
        case .routing:           return .blue
        case .toolCall:          return .secondary
        case .approvalPending:   return tintForRisk()
        case .collabHandoff:     return .purple
        case .holdQueue:         return holdTint()
        }
    }

    private func tintForRisk() -> Color {
        // Look up the risk label from the entry payload and map it
        // to a colour band. Avoids coupling the chip to the
        // `TesseraActionRisk` enum at the call site; the chip
        // vocabulary stays ASCII and self-describing.
        if case .approvalPending(let entry) = self {
            switch entry.riskLabel {
            case "low":       return .green
            case "medium":    return .yellow
            case "high":      return .orange
            case "forbidden": return .red
            default:          return .secondary
            }
        }
        return .secondary
    }

    private func holdTint() -> Color {
        if case .holdQueue(let entry) = self, entry.mode.isPaused {
            return .orange
        }
        return .secondary
    }

    /// "12:34:56" local-time form of `timestamp`. Cheap and matches
    /// the dock's transcript timestamp convention.
    fileprivate var timestampLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: timestamp)
    }
}

// MARK: - ChatProgressFeedTrigger

/// A reusable "what's happening" chip the host view can drop into
/// the dock header. Tapping flips the binding; nothing else. The
/// chip label is the event count so the user can see the feed has
/// activity without opening it.
public struct ChatProgressFeedTrigger: View {
    @Bindable public var controller: UnifiedChatController
    @Binding public var isPresented: Bool

    public init(
        controller: UnifiedChatController,
        isPresented: Binding<Bool>
    ) {
        self._controller = Bindable(controller)
        self._isPresented = isPresented
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption2)
                Text(labelText)
                    .font(.caption2.bold())
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open agent activity feed")
        .accessibilityHint("Pulls up the agent's routing, tool calls, approvals, hold queue, and team-up handoffs.")
    }

    /// The trigger's label. Read via `_controller.wrappedValue`
    /// so the dynamic-member lookup resolves under any body
    /// shape (explicit return, ViewBuilder, computed
    /// subexpressions). The wrapper's observation still fires
    /// because the read is inside `body`'s evaluation.
    private var labelText: String {
        let count = _controller.wrappedValue.liveState.count
        if count == 0 { return "Activity" }
        return "Activity (\(count))"
    }
}
