import Foundation
import SwiftUI

// ActionAuditLogPanel (review #4 follow-up of the agent-ux-fatigue
// Tessera Studio audit). A side panel that renders the chronological
// list of every agent action + outcome, with the tier label, time,
// and receipt id. Pull surface, not a modal; default compact view
// with filter + search so the list does not become a wall.
//
// **Pattern: Action Audit Log** (references/pattern-catalog.md).
// Fatigue factor reduced: trust + reversibility. Failure mode if
// misused: forgetting the un-undo button; stale entries. The audit
// log is paired with the time-limited undo (item 2C) for that
// reason; this file owns only the read surface.
//
// **Chip vocabulary reuse.** Each row renders the same
// `field: value | field: value` shape as the audit-log HEAD chip
// from item 1C (`AuditLogHeadChip` in `Editor/AuditLogHead.swift`).
// The user reads one chip language on the diff overlay, the chat
// progress feed, and the audit log, so the verification cost is
// shared between surfaces (paradox 1, references/paradoxes-deep.md
// line 38).
//
// **IA distinct from the receipts drawer.** The receipts drawer is
// the document-scoped receipt chain: the user opens one receipt to
// see its full record (mutations, pre/post snapshots, actor). The
// audit log is the session-scoped timeline: one row per agent
// action, no per-row expansion, filter + search to skim. The two
// surfaces do not share a render path and do not share a data
// model; both read the receipt id so a row's `receipt: a1b2...`
// substring can route to the drawer's detail view when the user
// wants the full record.
//
// **Pull, not push.** The panel is opened by an explicit toggle on
// the existing `ConfirmationPanel` (item 3D's integration point).
// It is never auto-surfaced; opening it on a busy session would
// load the proactive-agent paradox (paradox 7) onto the audit
// surface.

// MARK: - ActionAuditOutcome

/// The outcome of one agent action, as recorded in the audit log.
/// Categorical so the chip vocabulary matches the audit-log HEAD
/// chip's categorical risk + tier style (no numeric confidence;
/// LLMs are themselves miscalibrated, per the skill's anti-pattern
/// on numeric confidence percentages).
public enum ActionAuditOutcome: String, Codable, CaseIterable, Sendable, Hashable {
    /// The action completed and produced the expected effect.
    case success
    /// The action ran but the result did not match the expected
    /// effect. The agent (or the verifier) reported a failure.
    case failure
    /// The action was approved, executed, and then undone by the
    /// user (via the time-limited undo path, item 2C).
    case reverted
    /// The action was blocked by the safety spine (forbidden risk,
    /// irreversible denylist, sandbox breach). The action did not
    /// run; the row is the audit record of the block.
    case blocked

    /// Short label for the chip. ASCII only.
    public var shortLabel: String {
        switch self {
        case .success:  return "ok"
        case .failure:  return "fail"
        case .reverted: return "undone"
        case .blocked:  return "blocked"
        }
    }

    /// Tint used by the row's outcome chip. Mirrors the
    /// confirmation panel's `TierChip` palette vocabulary so the
    /// user reads the same color language on every surface.
    public var tintName: String {
        switch self {
        case .success:  return "green"
        case .failure:  return "red"
        case .reverted: return "orange"
        case .blocked:  return "red"
        }
    }
}

// MARK: - ActionAuditEntry

/// One row in the audit log. Pure value type; constructed by the
/// host when an action is recorded. The store sorts by `timestamp`
/// newest-first at read time so the capture path is append-only and
/// the read path is single-sourced.
public struct ActionAuditEntry: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let timestamp: Date
    /// Structural action class (verb-prefix, path-glob, or arg-shape),
    /// per `TesseraActionClass.classify`. The chip's `tool:` field.
    public let actionClass: String
    /// Short human-readable summary the chip renders as the
    /// optional `summary:` field. Keep under ~40 chars; the chip is
    /// a one-line surface.
    public let summary: String?
    /// The risk tier for the action. The chip's `tier:` field.
    public let tier: TesseraTier
    /// The risk level (low | medium | high | forbidden). The chip's
    /// `risk:` field.
    public let risk: TesseraActionRisk
    /// What happened.
    public let outcome: ActionAuditOutcome
    /// The receipt id this row is the audit record of, when one
    /// was produced. Tier 0/1 actions do not produce a receipt;
    /// the field is nil for them and the chip omits `receipt:`.
    public let receiptID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        actionClass: String,
        summary: String? = nil,
        tier: TesseraTier,
        risk: TesseraActionRisk,
        outcome: ActionAuditOutcome,
        receiptID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actionClass = actionClass
        self.summary = summary
        self.tier = tier
        self.risk = risk
        self.outcome = outcome
        self.receiptID = receiptID
    }

    /// Short form of the receipt id (first 8 chars of the UUID),
    /// matching `AuditLogHead.shortReceiptID`. Returns nil when
    /// the entry has no receipt.
    public var shortReceiptID: String? {
        guard let receiptID = receiptID else { return nil }
        return String(receiptID.uuidString.prefix(8))
    }

    /// The one-line chip string for this entry. Uses the same
    /// `field: value | field: value` shape as `AuditLogHeadChip`
    /// (item 1C) so the user reads one chip language on every
    /// surface. Fields are emitted in a fixed order:
    ///
    ///     tier: T2 | risk: medium | tool: bash:git | outcome: ok
    ///         | summary: fetch from origin | receipt: a1b2c3d4...
    ///
    /// The summary and receipt fields are emitted only when
    /// present. The chip is the headline, not the article; the
    /// user opens the row (or the receipts drawer) for the full
    /// record.
    public var displayString: String {
        var fields: [String] = [
            "tier: \(tier.shortLabel)",
            "risk: \(risk.rawValue)",
            "tool: \(actionClass)",
            "outcome: \(outcome.shortLabel)",
        ]
        if let summary, !summary.isEmpty {
            fields.append("summary: \(summary)")
        }
        if let shortReceiptID = shortReceiptID {
            fields.append("receipt: \(shortReceiptID)...")
        }
        // Cap at AuditLogHead.fieldCap so the chip language stays
        // consistent across the diff overlay, the chat progress
        // feed, and the audit log.
        let capped = Array(fields.prefix(AuditLogHead.fieldCap))
        return capped.joined(separator: " | ")
    }
}

// MARK: - ActionAuditLogStore

/// The data layer for the audit log panel. `@Observable` so a
/// SwiftUI view can `@Bindable` it. Append-only on the writer
/// side; the reader path is the filtered + sorted slice the view
/// renders.
///
/// **Capacity cap.** The store trims to ``capacity`` entries
/// (default 500) so a long-running session does not grow the
/// array without bound. The cap is generous enough that the user
/// can scroll back through a multi-hour session; old entries are
/// dropped FIFO so the chronological list stays a "recent"
/// surface, not a full session log. The full record stays in the
/// receipts drawer for the long tail.
@Observable
@MainActor
public final class ActionAuditLogStore {
    /// The hard cap on stored entries. The cap is the failure
    /// mode the brief calls out ("the panel may have so many
    /// entries that it becomes a wall"). `nonisolated` so it
    /// can be referenced as a default parameter value from
    /// outside the @MainActor context (the AppKit presenter
    /// initializer is sync).
    public nonisolated static let defaultCapacity: Int = 500

    public private(set) var entries: [ActionAuditEntry] = []
    public let capacity: Int

    /// The current filter (tier allow-list). Empty set means
    /// "all tiers". Bound from the panel UI.
    public var tierFilter: Set<TesseraTier> = []
    /// The current outcome filter. Empty set means "all outcomes".
    public var outcomeFilter: Set<ActionAuditOutcome> = []
    /// The current search substring. Matched (case-insensitive)
    /// against `actionClass` and `summary`. Empty string means
    /// "no search".
    public var searchText: String = ""

    public init(capacity: Int = ActionAuditLogStore.defaultCapacity) {
        self.capacity = capacity
    }

    /// Append one entry. The store trims from the head so the
    /// newest `capacity` entries are retained.
    public func append(_ entry: ActionAuditEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Append a batch of entries (preserves order). Useful when
    /// the host re-hydrates the log from a snapshot on appear.
    public func append(contentsOf batch: [ActionAuditEntry]) {
        entries.append(contentsOf: batch)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Drop all entries. Does not reset the filter / search.
    public func clear() {
        entries.removeAll()
    }

    /// The filtered + sorted slice the panel renders. Newest
    /// first (matches the chat progress feed, so the user reads
    /// the same time direction on both surfaces). The sort is
    /// stable; ties on `timestamp` fall back to `id` so the
    /// order is deterministic for tests.
    public var visible: [ActionAuditEntry] {
        let needle = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let tierAllowed = tierFilter
        let outcomeAllowed = outcomeFilter
        return entries
            .filter { entry in
                if !tierAllowed.isEmpty, !tierAllowed.contains(entry.tier) {
                    return false
                }
                if !outcomeAllowed.isEmpty, !outcomeAllowed.contains(entry.outcome) {
                    return false
                }
                if !needle.isEmpty {
                    let haystack = (
                        entry.actionClass + " " + (entry.summary ?? "")
                    ).lowercased()
                    if !haystack.contains(needle) { return false }
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// Summary string for the panel header subtitle. "N actions"
    /// when no filter is active; "N of M actions" when a filter
    /// narrows the visible set.
    public var headerSubtitle: String {
        let visibleCount = visible.count
        let total = entries.count
        if visibleCount == total {
            return "\(total) action\(total == 1 ? "" : "s")"
        }
        return "\(visibleCount) of \(total) action\(total == 1 ? "" : "s")"
    }
}

// MARK: - ActionAuditLogPanel

/// The SwiftUI view that renders the audit log as a side panel.
///
/// The view is intentionally small: a header (title, subtitle,
/// search field, filter chips, close), and a scrolling list of
/// ``ActionAuditLogRow`` rows. The host view owns the
/// ``ActionAuditLogStore`` (the data layer is the same one the
/// production capture path writes to) and the `isPresented`
/// binding; this view does not flip the binding itself.
///
/// - Parameters:
///   - store: the audit log data layer. The view observes it
///     via `@Bindable` so the filter / search edits flow back.
///   - isPresented: the pull binding. Toggled only by the host.
///     The close button in the header sets it to false.
///   - onTapReceipt: tap on a row's `receipt: a1b2...` substring.
///     The view layer routes the full `UUID`; the panel itself
///     only knows about the closure. Default is a no-op so a
///     host that does not wire the route still compiles.
public struct ActionAuditLogPanel: View {
    @Bindable public var store: ActionAuditLogStore
    @Binding public var isPresented: Bool
    public let onTapReceipt: (UUID) -> Void

    public init(
        store: ActionAuditLogStore,
        isPresented: Binding<Bool>,
        onTapReceipt: @escaping (UUID) -> Void = { _ in }
    ) {
        self._store = Bindable(store)
        self._isPresented = isPresented
        self.onTapReceipt = onTapReceipt
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            content
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 480,
               minHeight: 320, idealHeight: 480, maxHeight: 720)
        .background(.regularMaterial)
        .accessibilityLabel("Action audit log")
        .accessibilityHint("Chronological list of every agent action + outcome. Filter or search to narrow. Tap a row's receipt id to open the full record.")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Action audit log")
                    .font(.headline)
                Text(store.headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
            .accessibilityLabel("Close audit log")
            .accessibilityHint("Closes the audit log. The list is preserved for next time.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            tierFilterRow
            outcomeFilterRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar.opacity(0.5))
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("filter by tool or summary", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Filter audit log by tool or summary")
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
    }

    private var tierFilterRow: some View {
        HStack(spacing: 4) {
            ForEach(TesseraTier.allCases, id: \.self) { tier in
                TierFilterChip(
                    tier: tier,
                    isOn: store.tierFilter.contains(tier)
                ) {
                    toggleTier(tier)
                }
            }
            Spacer()
        }
    }

    private var outcomeFilterRow: some View {
        HStack(spacing: 4) {
            ForEach(ActionAuditOutcome.allCases, id: \.self) { outcome in
                OutcomeFilterChip(
                    outcome: outcome,
                    isOn: store.outcomeFilter.contains(outcome)
                ) {
                    toggleOutcome(outcome)
                }
            }
            Spacer()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            emptyState
        } else if store.visible.isEmpty {
            noMatchesState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No agent actions yet")
                .font(.callout.bold())
            Text("Every agent action, approval, and outcome will land here as the session progresses. The list is append-only; older entries are kept in the receipts drawer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.callout.bold())
            Text("No actions match the current filter + search. Clear them to see the full list.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(store.visible) { entry in
                    ActionAuditLogRow(entry: entry, onTapReceipt: onTapReceipt)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Filter mutations

    private func toggleTier(_ tier: TesseraTier) {
        if store.tierFilter.contains(tier) {
            store.tierFilter.remove(tier)
        } else {
            store.tierFilter.insert(tier)
        }
    }

    private func toggleOutcome(_ outcome: ActionAuditOutcome) {
        if store.outcomeFilter.contains(outcome) {
            store.outcomeFilter.remove(outcome)
        } else {
            store.outcomeFilter.insert(outcome)
        }
    }
}

// MARK: - ActionAuditLogRow

/// One row in the panel. A one-line chip with the same
/// `field: value | field: value` vocabulary as `AuditLogHeadChip`
/// (item 1C) and `ChatProgressFeedRow` (item 2A). The row is
/// non-interactive except for the receipt-id tap, which routes
/// to the receipts drawer's detail view via `onTapReceipt`.
public struct ActionAuditLogRow: View {
    public let entry: ActionAuditEntry
    public let onTapReceipt: (UUID) -> Void

    public init(entry: ActionAuditEntry, onTapReceipt: @escaping (UUID) -> Void) {
        self.entry = entry
        self.onTapReceipt = onTapReceipt
    }

    public var body: some View {
        let full = entry.displayString
        // Split the display string at "receipt: " so the receipt
        // id can be its own tappable sub-view. Mirrors the
        // AuditLogHeadChip split (item 1C) so the user reads
        // the same affordance on both surfaces.
        let split = full.range(of: "receipt: ") ?? full.startIndex..<full.endIndex
        let prefix = String(full[full.startIndex..<split.upperBound])
        let receiptTail: String? = entry.shortReceiptID
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            outcomeGlyph
            Text(prefix)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let short = receiptTail, let receiptID = entry.receiptID {
                Button(action: { onTapReceipt(receiptID) }) {
                    Text("\(short)...")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.accentColor)
                        .underline()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open receipt \(short)")
            }
            Spacer(minLength: 0)
            Text(timestampLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowTint.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(full)
    }

    private var timestampLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: entry.timestamp)
    }

    private var outcomeGlyph: some View {
        Image(systemName: outcomeSymbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(rowTint)
            .font(.caption)
            .frame(width: 16)
    }

    private var outcomeSymbol: String {
        switch entry.outcome {
        case .success:  return "checkmark.circle"
        case .failure:  return "xmark.octagon"
        case .reverted: return "arrow.uturn.backward.circle"
        case .blocked:  return "nosign"
        }
    }

    private var rowTint: Color {
        switch entry.outcome.tintName {
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        default:       return .secondary
        }
    }
}

// MARK: - TierFilterChip

/// A small tier chip used in the panel's filter bar. Reuses the
/// `TesseraTier.shortLabel` vocabulary from the confirmation
/// panel's `TierChip` (item 1B) so the user reads the same tier
/// language on every surface.
private struct TierFilterChip: View {
    let tier: TesseraTier
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(tier.shortLabel)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isOn ? tint.opacity(0.20) : Color.secondary.opacity(0.05))
                )
                .foregroundStyle(isOn ? tint : .secondary)
                .overlay(
                    Capsule().stroke(isOn ? tint.opacity(0.5) : Color.secondary.opacity(0.20),
                                     lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(tier.displayName)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var tint: Color {
        switch tier {
        case .tier0: return .green
        case .tier1: return .blue
        case .tier2: return .orange
        case .tier3: return .red
        }
    }
}

// MARK: - OutcomeFilterChip

/// A small outcome chip used in the panel's filter bar. Same
/// shape as ``TierFilterChip`` so the filter bar reads as one
/// uniform row of toggles.
private struct OutcomeFilterChip: View {
    let outcome: ActionAuditOutcome
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(outcome.shortLabel)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isOn ? tint.opacity(0.20) : Color.secondary.opacity(0.05))
                )
                .foregroundStyle(isOn ? tint : .secondary)
                .overlay(
                    Capsule().stroke(isOn ? tint.opacity(0.5) : Color.secondary.opacity(0.20),
                                     lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(outcome.shortLabel) outcomes")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var tint: Color {
        switch outcome.tintName {
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        default:       return .secondary
        }
    }
}

// MARK: - ActionAuditLogTrigger

/// A button the host view can drop into its surface to toggle the
/// panel. Tapping flips the binding; the panel does not flip the
/// binding itself. Mirrors the `ChatProgressFeedTrigger` pattern
/// (item 2A) so the trigger affordance reads consistently across
/// surfaces.
public struct ActionAuditLogTrigger: View {
    @Bindable public var store: ActionAuditLogStore
    @Binding public var isPresented: Bool

    public init(
        store: ActionAuditLogStore,
        isPresented: Binding<Bool>
    ) {
        self._store = Bindable(store)
        self._isPresented = isPresented
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
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
        .accessibilityLabel("Open action audit log")
        .accessibilityHint("Pulls up the chronological list of every agent action + outcome.")
    }

    private var labelText: String {
        let count = _store.wrappedValue.entries.count
        if count == 0 { return "Audit" }
        return "Audit (\(count))"
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - ActionAuditLogPanelPresenter (macOS only)

/// The AppKit-side presenter. Owns the `NSPanel` (a non-activating
/// utility panel that does not steal focus from the main window)
/// and the shared ``ActionAuditLogStore``. The
/// ``ConfirmationPanel`` integration wires a trigger that calls
/// `present()` / `dismiss()` on this presenter; the panel itself
/// observes the same store.
///
/// **Why a non-activating panel.** The audit log is a side panel,
/// not a modal. Per the brief, the panel must not interrupt the
/// user's flow; a modal would re-load the chat-default paradox
/// (paradox 3) onto a read surface. `.nonactivatingPanel` keeps
/// the main window's text field focused; the user can keep typing
/// in the chat while the panel is open.
///
/// **Position.** The panel floats to the right of the main window
/// (or wherever `NSPanel` places it; the user can move it). The
/// default placement is "near the confirmation panel" because the
/// brief's integration point is the `ConfirmationPanel`; if the
/// confirmation panel is not on screen, the panel cascades to
/// the right edge of the main window.
@MainActor
public final class ActionAuditLogPanelPresenter: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    public let store: ActionAuditLogStore
    private let onTapReceipt: (UUID) -> Void

    public init(
        store: ActionAuditLogStore,
        onTapReceipt: @escaping (UUID) -> Void = { _ in }
    ) {
        self.store = store
        self.onTapReceipt = onTapReceipt
    }

    /// Show the panel. Idempotent: re-presenting when the panel is
    /// already visible just brings it to the front.
    public func present() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ActionAuditLogPanel(
            store: store,
            isPresented: Binding(
                get: { [weak self] in self?.window?.isVisible ?? false },
                set: { [weak self] newValue in
                    if !newValue { self?.dismiss() }
                }
            ),
            onTapReceipt: onTapReceipt
        )
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Action audit log"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.delegate = self
        positionNearMainWindow(panel)

        self.window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Close the panel. Safe to call when not visible.
    public func dismiss() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        if let window = self.window, notification.object as? NSWindow === window {
            self.window = nil
        }
    }

    // MARK: - Layout

    private func positionNearMainWindow(_ panel: NSPanel) {
        guard let main = NSApp.keyWindow ?? NSApp.mainWindow else {
            panel.center()
            return
        }
        let mainFrame = main.frame
        // Place the panel to the right of the main window, vertically
        // centered. If there is no room (small screens), cascade down
        // and to the right of the main window.
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: mainFrame.maxX + 12,
            y: mainFrame.midY - panelSize.height / 2
        )
        let candidate = NSRect(origin: origin, size: panelSize)
        if let screen = main.screen,
           screen.visibleFrame.contains(candidate) {
            panel.setFrameOrigin(origin)
        } else {
            // Cascade instead: right + 24, down -24.
            panel.setFrameOrigin(NSPoint(
                x: mainFrame.maxX + 24,
                y: mainFrame.maxY - panelSize.height - 24
            ))
        }
    }
}
#endif
